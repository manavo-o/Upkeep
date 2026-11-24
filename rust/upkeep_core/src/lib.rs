use memchr::{memchr, memchr2, memmem};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use rayon::prelude::*;
use serde::de::{DeserializeSeed, SeqAccess, Visitor};
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs::{self, File};
use std::io::{BufReader, Read};
use std::os::raw::{c_char, c_int, c_void};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{OnceLock, RwLock};

mod cleaner;
pub use cleaner::{upkeep_clean_paths_json, upkeep_scan_cleaner_json};

// MARK: - Bounded Dedicated Rayon Worker Pool (Prevents 8–16 Idle OS Threads in Menu-Bar App)

static WORKER_POOL: OnceLock<rayon::ThreadPool> = OnceLock::new();

pub(crate) fn worker_pool() -> &'static rayon::ThreadPool {
    WORKER_POOL.get_or_init(|| {
        let threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4)
            .clamp(2, 4);
        rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .thread_name(|idx| format!("upkeep-worker-{}", idx))
            .build()
            .expect("failed to build upkeep Rayon worker pool")
    })
}

// MARK: - Core Data Structures

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrewPackage {
    pub name: String,
    pub description: String,
    pub version: String,
    pub is_cask: bool,
    pub is_installed: bool,
    pub is_outdated: bool,
    pub is_pinned: bool,
    pub homepage: String,
}

/// Zero-copy borrowed wire projection for JSON serialization directly from the byte slab.
#[derive(Serialize)]
struct BrewPackageRef<'a> {
    name: &'a str,
    description: &'a str,
    version: &'a str,
    is_cask: bool,
    is_installed: bool,
    is_outdated: bool,
    is_pinned: bool,
    homepage: &'a str,
}

#[derive(Clone, Copy, Default)]
struct StrSpan {
    off: u32,
    len: u32,
}

const FLAG_CASK: u8 = 1 << 0;
const FLAG_INSTALLED: u8 = 1 << 1;
const FLAG_OUTDATED: u8 = 1 << 2;
const FLAG_PINNED: u8 = 1 << 3;

#[derive(Clone, Copy)]
struct SlabPackage {
    name: StrSpan,
    desc: StrSpan,
    api_ver: StrSpan,
    homepage: StrSpan,
    flags: u8,
}

impl SlabPackage {
    #[inline]
    fn is_cask(&self) -> bool {
        (self.flags & FLAG_CASK) != 0
    }
    #[inline]
    fn is_installed(&self) -> bool {
        (self.flags & FLAG_INSTALLED) != 0
    }
    #[inline]
    fn is_outdated(&self) -> bool {
        (self.flags & FLAG_OUTDATED) != 0
    }
    #[inline]
    fn is_pinned(&self) -> bool {
        (self.flags & FLAG_PINNED) != 0
    }
}

/// Contiguous byte-slab catalog: stores all ~15k Homebrew packages in 2 allocations
/// (`strings` + `entries`) instead of ~90k separate `malloc` chunks, with installed-only
/// local version overrides in a tiny map.
#[derive(Default)]
struct BrewCatalogSlab {
    strings: Vec<u8>,
    entries: Vec<SlabPackage>,
    local_versions: HashMap<u32, String>,
}

impl BrewCatalogSlab {
    fn with_capacity(entry_cap: usize, string_bytes_cap: usize) -> Self {
        Self {
            strings: Vec::with_capacity(string_bytes_cap),
            entries: Vec::with_capacity(entry_cap),
            local_versions: HashMap::new(),
        }
    }

    #[inline]
    fn push_str(&mut self, s: &str) -> StrSpan {
        if s.is_empty() {
            return StrSpan { off: 0, len: 0 };
        }
        let off = self.strings.len() as u32;
        self.strings.extend_from_slice(s.as_bytes());
        StrSpan {
            off,
            len: s.len() as u32,
        }
    }

    #[inline]
    fn str_of(&self, span: StrSpan) -> &str {
        if span.len == 0 {
            return "";
        }
        let start = span.off as usize;
        let end = start + span.len as usize;
        // SAFETY: `self.strings` is only ever populated with valid UTF-8 `&str` bytes in `push_str`.
        unsafe { std::str::from_utf8_unchecked(&self.strings[start..end]) }
    }

    #[inline]
    fn version_of(&self, idx: usize) -> &str {
        if let Some(local_ver) = self.local_versions.get(&(idx as u32)) {
            if !local_ver.is_empty() {
                return local_ver.as_str();
            }
        }
        self.str_of(self.entries[idx].api_ver)
    }

    #[inline]
    fn as_wire_ref(&self, idx: usize) -> BrewPackageRef<'_> {
        let e = &self.entries[idx];
        BrewPackageRef {
            name: self.str_of(e.name),
            description: self.str_of(e.desc),
            version: self.version_of(idx),
            is_cask: e.is_cask(),
            is_installed: e.is_installed(),
            is_outdated: e.is_outdated(),
            is_pinned: e.is_pinned(),
            homepage: self.str_of(e.homepage),
        }
    }

    fn push_package(
        &mut self,
        name: &str,
        desc: &str,
        api_ver: &str,
        homepage: &str,
        local_ver: Option<String>,
        is_cask: bool,
        is_installed: bool,
        is_outdated: bool,
        is_pinned: bool,
    ) {
        let name_span = self.push_str(name);
        let desc_span = self.push_str(desc);
        let api_span = self.push_str(api_ver);
        let hp_span = self.push_str(homepage);
        let mut flags = 0u8;
        if is_cask {
            flags |= FLAG_CASK;
        }
        if is_installed {
            flags |= FLAG_INSTALLED;
        }
        if is_outdated {
            flags |= FLAG_OUTDATED;
        }
        if is_pinned {
            flags |= FLAG_PINNED;
        }
        let idx = self.entries.len() as u32;
        self.entries.push(SlabPackage {
            name: name_span,
            desc: desc_span,
            api_ver: api_span,
            homepage: hp_span,
            flags,
        });
        if let Some(lv) = local_ver {
            if !lv.is_empty() && lv != api_ver {
                self.local_versions.insert(idx, lv);
            }
        }
    }

    fn push_local_only(&mut self, pkg: BrewPackage) {
        self.push_package(
            &pkg.name,
            &pkg.description,
            &pkg.version,
            &pkg.homepage,
            None,
            pkg.is_cask,
            pkg.is_installed,
            pkg.is_outdated,
            pkg.is_pinned,
        );
    }

    fn shrink_to_fit(&mut self) {
        self.strings.shrink_to_fit();
        self.entries.shrink_to_fit();
        self.local_versions.shrink_to_fit();
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct MoleCleanSummary {
    pub total_reclaimed: String,
    pub item_count: u32,
    pub lines: Vec<String>,
    pub is_dry_run: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct LeftoverRecord {
    pub path: String,
    pub display_path: String,
    pub category: String,
    pub size_bytes: u64,
    pub is_system: bool,
    pub default_selected: bool,
    pub holdback_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct UninstallInspectionPayload {
    pub leftovers: Vec<LeftoverRecord>,
    pub homebrew_cask_token: Option<String>,
    pub has_sibling_app: bool,
    pub official_uninstaller_vendor: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CacheScanItem {
    pub category: String,
    pub name: String,
    pub path: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct CacheScanPayload {
    pub total_bytes: u64,
    pub items: Vec<CacheScanItem>,
}

#[repr(C)]
pub struct UpkeepMatch {
    pub index: u32,
    pub score: u32,
}

#[repr(C)]
pub struct UpkeepAppRecord {
    pub name: [c_char; 256],
    pub bundle_id: [c_char; 256],
    pub path: [c_char; 1024],
    pub app_size_bytes: u64,
}

pub struct BrewSearchIndex {
    slab: RwLock<BrewCatalogSlab>,
}

#[derive(Deserialize)]
struct ApiFormulaVersions {
    stable: Option<String>,
}

#[derive(Deserialize)]
struct ApiFormula {
    name: String,
    #[serde(default)]
    desc: Option<String>,
    #[serde(default)]
    homepage: Option<String>,
    versions: Option<ApiFormulaVersions>,
    #[serde(default)]
    revision: u32,
}

#[derive(Deserialize)]
struct ApiCask {
    token: String,
    #[serde(default)]
    desc: Option<String>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    homepage: Option<String>,
}

// Thread-local Matcher ONLY for single-pair `upkeep_fuzzy_score` (never touched by Rayon workers).
thread_local! {
    static TL_SINGLE_MATCHER: RefCell<(Matcher, Vec<char>)> =
        RefCell::new((Matcher::new(Config::DEFAULT), Vec::with_capacity(256)));
}

// MARK: - Zero-Allocation String & Sorting Helpers

pub(crate) fn cstr_to_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or("")
}

pub(crate) fn string_to_cstr(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

fn write_fixed_cstr(src: &str, dst: &mut [c_char]) {
    let bytes = src.as_bytes();
    let max_len = dst.len().saturating_sub(1);
    let copy_len = bytes.len().min(max_len);
    for (i, b) in bytes[..copy_len].iter().enumerate() {
        dst[i] = *b as c_char;
    }
    dst[copy_len] = 0;
}

/// Zero-allocation check for `haystack == prefix || haystack.starts_with(format!("{prefix}{sep}"))`.
#[inline]
pub(crate) fn eq_or_starts_with_sep(haystack: &str, prefix: &str, sep: u8) -> bool {
    let hb = haystack.as_bytes();
    let pb = prefix.as_bytes();
    if hb.len() < pb.len() || &hb[..pb.len()] != pb {
        return false;
    }
    hb.len() == pb.len() || hb[pb.len()] == sep
}

/// Zero-allocation check for `haystack.starts_with(format!("{prefix}{sep}"))`.
#[inline]
pub(crate) fn starts_with_sep(haystack: &str, prefix: &str, sep: u8) -> bool {
    let hb = haystack.as_bytes();
    let pb = prefix.as_bytes();
    hb.len() > pb.len() && hb[pb.len()] == sep && &hb[..pb.len()] == pb
}

/// Zero-allocation check for `haystack == format!("{prefix}{suffix}")`.
#[inline]
fn eq_with_suffix(haystack: &str, prefix: &str, suffix: &str) -> bool {
    haystack.len() == prefix.len() + suffix.len()
        && haystack.starts_with(prefix)
        && haystack.ends_with(suffix)
}

/// Zero-allocation ASCII case-insensitive prefix check.
#[inline]
fn starts_with_ignore_ascii_case(haystack: &str, prefix: &str) -> bool {
    let hb = haystack.as_bytes();
    let pb = prefix.as_bytes();
    hb.len() >= pb.len() && hb[..pb.len()].eq_ignore_ascii_case(pb)
}

/// Zero-allocation ASCII case-insensitive comparison.
#[inline]
fn cmp_ignore_ascii_case(a: &str, b: &str) -> Ordering {
    let mut ai = a.bytes();
    let mut bi = b.bytes();
    loop {
        match (ai.next(), bi.next()) {
            (Some(ac), Some(bc)) => {
                let ord = ac.to_ascii_lowercase().cmp(&bc.to_ascii_lowercase());
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (None, None) => return Ordering::Equal,
        }
    }
}

/// Natural version comparison (e.g. "1.10.0" > "1.2.0", "1.2.3_1" > "1.2.3").
fn cmp_versions_natural(a: &str, b: &str) -> Ordering {
    let ab = a.as_bytes();
    let bb = b.as_bytes();
    let mut i = 0;
    let mut j = 0;

    while i < ab.len() && j < bb.len() {
        let ad = ab[i].is_ascii_digit();
        let bd = bb[j].is_ascii_digit();

        if ad && bd {
            let i0 = i;
            while i < ab.len() && ab[i].is_ascii_digit() {
                i += 1;
            }
            let j0 = j;
            while j < bb.len() && bb[j].is_ascii_digit() {
                j += 1;
            }
            let na: u64 = std::str::from_utf8(&ab[i0..i])
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let nb: u64 = std::str::from_utf8(&bb[j0..j])
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let ord = na.cmp(&nb);
            if ord != Ordering::Equal {
                return ord;
            }
        } else {
            let ord = ab[i].to_ascii_lowercase().cmp(&bb[j].to_ascii_lowercase());
            if ord != Ordering::Equal {
                return ord;
            }
            i += 1;
            j += 1;
        }
    }

    ab.len().cmp(&bb.len())
}

/// NEON/SIMD-accelerated zero-allocation ASCII case-insensitive substring position via `memchr2`.
#[inline]
fn find_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    if needle.len() > haystack.len() {
        return None;
    }
    let first_lo = needle[0].to_ascii_lowercase();
    let first_hi = needle[0].to_ascii_uppercase();
    let tail = &needle[1..];
    let max_start = haystack.len() - needle.len();
    let mut offset = 0usize;
    while offset <= max_start {
        let rel = memchr2(first_lo, first_hi, &haystack[offset..=max_start])?;
        let pos = offset + rel;
        if haystack[pos + 1..pos + needle.len()].eq_ignore_ascii_case(tail) {
            return Some(pos);
        }
        offset = pos + 1;
    }
    None
}

#[inline]
fn contains_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> bool {
    find_ascii_case_insensitive(haystack, needle).is_some()
}

// MARK: - macOS getattrlistbulk APFS-Accurate Directory Sizing (Scoped Scratch, Zero Nested Rayon)

#[cfg(target_os = "macos")]
mod macos_bulk {
    use super::*;

    const O_RDONLY: c_int = 0x0000;
    const O_NOFOLLOW: c_int = 0x0100;
    const O_DIRECTORY: c_int = 0x0010_0000;
    const O_CLOEXEC: c_int = 0x0100_0000;

    const ATTR_BIT_MAP_COUNT: u16 = 5;
    const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
    const ATTR_CMN_NAME: u32 = 0x0000_0001;
    const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
    const ATTR_CMN_OBJID: u32 = 0x0000_0020;

    const ATTR_FILE_LINKCOUNT: u32 = 0x0000_0001;
    const ATTR_FILE_TOTALSIZE: u32 = 0x0000_0002;
    const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;

    const VREG: u32 = 1;
    const VDIR: u32 = 2;

    #[repr(C)]
    struct AttrList {
        bitmapcount: u16,
        reserved: u16,
        commonattr: u32,
        volattr: u32,
        dirattr: u32,
        fileattr: u32,
        forkattr: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct AttributeSet {
        commonattr: u32,
        volattr: u32,
        dirattr: u32,
        fileattr: u32,
        forkattr: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct AttrReference {
        attr_dataoffset: i32,
        attr_length: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct FsObjId {
        objno: u32,
        objid: u32,
    }

    extern "C" {
        fn open(path: *const c_char, oflag: c_int, ...) -> c_int;
        fn openat(dirfd: c_int, path: *const c_char, oflag: c_int, ...) -> c_int;
        fn close(fd: c_int) -> c_int;
        fn getattrlistbulk(
            dirfd: c_int,
            attrlist: *mut AttrList,
            attrbuf: *mut c_void,
            bufsize: usize,
            options: u64,
        ) -> c_int;
    }

    /// Reusable arena across all DFS recursion levels so subdirectories incur zero Vec allocations.
    struct DfsArena {
        path_bytes: Vec<u8>,
        child_names: Vec<u8>,
        child_offsets: Vec<usize>,
    }

    /// Scoped per-worker scratch buffers (64 KB bulk buffer + reusable DFS arena).
    /// Allocated via `map_init` and automatically freed when the scan ends — zero permanent TLS RSS.
    pub(crate) struct BulkScratch {
        buf: Vec<u8>,
        path_buf: Vec<u8>,
        arena: DfsArena,
    }

    impl BulkScratch {
        pub(crate) fn new() -> Self {
            Self {
                buf: vec![0u8; 64 * 1024],
                path_buf: Vec::with_capacity(512),
                arena: DfsArena {
                    path_bytes: Vec::with_capacity(512),
                    child_names: Vec::with_capacity(4096),
                    child_offsets: Vec::with_capacity(256),
                },
            }
        }
    }

    /// Lock-free per-task accumulator: ordinary files sum directly into `bytes`, while
    /// hardlinked files (`link_count > 1`) record `(obj_key, bytes)` for a single top-level
    /// deduplication pass — zero `Mutex` contention across Rayon workers.
    #[derive(Default)]
    struct SizeAcc {
        bytes: u64,
        hardlinks: Vec<(u64, u64)>,
    }

    impl SizeAcc {
        #[inline]
        fn merge(&mut self, mut other: SizeAcc) {
            self.bytes = self.bytes.saturating_add(other.bytes);
            if !other.hardlinks.is_empty() {
                if self.hardlinks.is_empty() {
                    self.hardlinks = std::mem::take(&mut other.hardlinks);
                } else {
                    self.hardlinks.extend(other.hardlinks);
                }
            }
        }

        fn finalize(self) -> u64 {
            if self.hardlinks.is_empty() {
                return self.bytes;
            }
            let mut seen = HashSet::with_capacity(self.hardlinks.len());
            let mut total = self.bytes;
            for (obj_key, bytes) in self.hardlinks {
                if seen.insert(obj_key) {
                    total = total.saturating_add(bytes);
                }
            }
            total
        }
    }

    /// Shared lock-free `getattrlistbulk` parser for an open directory FD.
    fn parse_fd_bulk<F>(fd: c_int, buf: &mut [u8], acc: &mut SizeAcc, mut on_dir: F)
    where
        F: FnMut(&[u8]),
    {
        let mut attrlist = AttrList {
            bitmapcount: ATTR_BIT_MAP_COUNT,
            reserved: 0,
            commonattr: ATTR_CMN_RETURNED_ATTRS
                | ATTR_CMN_NAME
                | ATTR_CMN_OBJTYPE
                | ATTR_CMN_OBJID,
            volattr: 0,
            dirattr: 0,
            fileattr: ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
            forkattr: 0,
        };

        loop {
            let count = unsafe {
                getattrlistbulk(
                    fd,
                    &mut attrlist,
                    buf.as_mut_ptr() as *mut c_void,
                    buf.len(),
                    0,
                )
            };
            if count <= 0 {
                break;
            }

            let mut offset: usize = 0;
            for _ in 0..count {
                if offset + 4 > buf.len() {
                    break;
                }
                let entry_len =
                    u32::from_ne_bytes(buf[offset..offset + 4].try_into().unwrap()) as usize;
                if entry_len == 0 || offset + entry_len > buf.len() {
                    break;
                }

                let entry = &buf[offset..offset + entry_len];
                let mut field = 4usize;

                if field + std::mem::size_of::<AttributeSet>() > entry.len() {
                    offset += entry_len;
                    continue;
                }
                let returned: AttributeSet = unsafe {
                    std::ptr::read_unaligned(entry.as_ptr().add(field) as *const AttributeSet)
                };
                field += std::mem::size_of::<AttributeSet>();

                let mut name_bytes: &[u8] = &[];
                if returned.commonattr & ATTR_CMN_NAME != 0 {
                    if field + std::mem::size_of::<AttrReference>() <= entry.len() {
                        let name_field_start = field;
                        let attr_ref: AttrReference = unsafe {
                            std::ptr::read_unaligned(
                                entry.as_ptr().add(field) as *const AttrReference,
                            )
                        };
                        field += std::mem::size_of::<AttrReference>();
                        let start =
                            name_field_start.wrapping_add(attr_ref.attr_dataoffset as usize);
                        let len = attr_ref.attr_length as usize;
                        if start < entry.len() && start + len <= entry.len() && len > 0 {
                            let slice = &entry[start..start + len];
                            name_bytes = slice.strip_suffix(&[0]).unwrap_or(slice);
                        }
                    }
                }

                let mut obj_type: u32 = 0;
                if returned.commonattr & ATTR_CMN_OBJTYPE != 0 {
                    if field + 4 <= entry.len() {
                        obj_type =
                            u32::from_ne_bytes(entry[field..field + 4].try_into().unwrap());
                        field += 4;
                    }
                }

                let mut obj_key: u64 = 0;
                if returned.commonattr & ATTR_CMN_OBJID != 0 {
                    if field + std::mem::size_of::<FsObjId>() <= entry.len() {
                        let id: FsObjId = unsafe {
                            std::ptr::read_unaligned(entry.as_ptr().add(field) as *const FsObjId)
                        };
                        obj_key = ((id.objid as u64) << 32) | (id.objno as u64);
                        field += std::mem::size_of::<FsObjId>();
                    }
                }

                if obj_type == VDIR {
                    if !name_bytes.is_empty() && name_bytes != b"." && name_bytes != b".." {
                        on_dir(name_bytes);
                    }
                } else if obj_type == VREG {
                    let mut link_count: u32 = 1;
                    if returned.fileattr & ATTR_FILE_LINKCOUNT != 0 && field + 4 <= entry.len() {
                        link_count =
                            u32::from_ne_bytes(entry[field..field + 4].try_into().unwrap());
                        field += 4;
                    }

                    let mut total_size: i64 = 0;
                    if returned.fileattr & ATTR_FILE_TOTALSIZE != 0 && field + 8 <= entry.len() {
                        total_size =
                            i64::from_ne_bytes(entry[field..field + 8].try_into().unwrap());
                        field += 8;
                    }

                    let mut alloc_size: i64 = 0;
                    if returned.fileattr & ATTR_FILE_ALLOCSIZE != 0 && field + 8 <= entry.len() {
                        alloc_size =
                            i64::from_ne_bytes(entry[field..field + 8].try_into().unwrap());
                    }

                    let bytes = if alloc_size > 0 {
                        alloc_size as u64
                    } else if total_size > 0 {
                        total_size as u64
                    } else {
                        0
                    };

                    if link_count > 1 && obj_key != 0 {
                        acc.hardlinks.push((obj_key, bytes));
                    } else {
                        acc.bytes = acc.bytes.saturating_add(bytes);
                    }
                }

                offset += entry_len;
            }
        }
    }

    fn read_single_dir_bulk(
        dir_path: &Path,
        is_root: bool,
        scratch: &mut BulkScratch,
        subdirs_out: &mut Vec<PathBuf>,
    ) -> Option<SizeAcc> {
        scratch.path_buf.clear();
        scratch
            .path_buf
            .extend_from_slice(dir_path.as_os_str().as_encoded_bytes());
        scratch.path_buf.push(0);

        let fd = unsafe {
            open(
                scratch.path_buf.as_ptr() as *const c_char,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            )
        };
        if fd < 0 {
            return if is_root { None } else { Some(SizeAcc::default()) };
        }

        let mut acc = SizeAcc::default();
        parse_fd_bulk(fd, &mut scratch.buf, &mut acc, |name_bytes| {
            if let Ok(name_str) = std::str::from_utf8(name_bytes) {
                subdirs_out.push(dir_path.join(name_str));
            }
        });

        unsafe { close(fd) };
        Some(acc)
    }

    #[inline]
    fn read_fd_bulk(fd: c_int, buf: &mut [u8], acc: &mut SizeAcc, arena: &mut DfsArena) {
        parse_fd_bulk(fd, buf, acc, |name_bytes| {
            arena.child_offsets.push(arena.child_names.len());
            arena.child_names.extend_from_slice(name_bytes);
            arena.child_names.push(0);
        });
    }

    /// Single-FD zero-PathBuf DFS fallback for extreme nesting depths (> 16), keeping FD usage at 1.
    fn walk_deep_single_fd(
        buf: &mut [u8],
        arena: &mut DfsArena,
        depth: u16,
        acc: &mut SizeAcc,
    ) {
        if depth > 256 {
            return;
        }
        arena.path_bytes.push(0);
        let fd = unsafe {
            open(
                arena.path_bytes.as_ptr() as *const c_char,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            )
        };
        arena.path_bytes.pop();
        if fd < 0 {
            return;
        }

        let names_base = arena.child_names.len();
        let offsets_base = arena.child_offsets.len();
        read_fd_bulk(fd, buf, acc, arena);
        unsafe { close(fd) };

        let offsets_end = arena.child_offsets.len();
        let names_end = arena.child_names.len();
        let saved_len = arena.path_bytes.len();
        for idx in offsets_base..offsets_end {
            let start = arena.child_offsets[idx];
            let end_with_nul = if idx + 1 < offsets_end {
                arena.child_offsets[idx + 1]
            } else {
                names_end
            };
            let name_len = end_with_nul.saturating_sub(start + 1);
            arena.path_bytes.push(b'/');
            arena
                .path_bytes
                .extend_from_slice(&arena.child_names[start..start + name_len]);
            walk_deep_single_fd(buf, arena, depth + 1, acc);
            arena.path_bytes.truncate(saved_len);
        }
        arena.child_names.truncate(names_base);
        arena.child_offsets.truncate(offsets_base);
    }

    /// Zero-PathBuf `openat` DFS bounded to 16 open FDs per thread.
    /// Avoids touching `arena.path_bytes` at depth < 16; lazily reconstructs full path only if depth == 16.
    fn walk_openat_dfs(
        dirfd: c_int,
        depth: u8,
        root_len: usize,
        ancestors: &mut [(usize, usize); 16],
        buf: &mut [u8],
        arena: &mut DfsArena,
        acc: &mut SizeAcc,
    ) {
        let names_base = arena.child_names.len();
        let offsets_base = arena.child_offsets.len();
        read_fd_bulk(dirfd, buf, acc, arena);

        let offsets_end = arena.child_offsets.len();
        let names_end = arena.child_names.len();
        for idx in offsets_base..offsets_end {
            let start = arena.child_offsets[idx];
            let end_with_nul = if idx + 1 < offsets_end {
                arena.child_offsets[idx + 1]
            } else {
                names_end
            };
            let name_len = end_with_nul.saturating_sub(start + 1);

            if depth < 16 {
                ancestors[depth as usize] = (start, name_len);
                let name_ptr = unsafe { arena.child_names.as_ptr().add(start) as *const c_char };
                let child_fd = unsafe {
                    openat(
                        dirfd,
                        name_ptr,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                    )
                };
                if child_fd >= 0 {
                    walk_openat_dfs(child_fd, depth + 1, root_len, ancestors, buf, arena, acc);
                    unsafe { close(child_fd) };
                }
            } else {
                // Rare deep-tree boundary: reconstruct full path lazily from root + 16 ancestors
                arena.path_bytes.truncate(root_len);
                for &(a_start, a_len) in ancestors.iter() {
                    arena.path_bytes.push(b'/');
                    arena
                        .path_bytes
                        .extend_from_slice(&arena.child_names[a_start..a_start + a_len]);
                }
                arena.path_bytes.push(b'/');
                arena
                    .path_bytes
                    .extend_from_slice(&arena.child_names[start..start + name_len]);
                walk_deep_single_fd(buf, arena, 0, acc);
                arena.path_bytes.truncate(root_len);
            }
        }
        arena.child_names.truncate(names_base);
        arena.child_offsets.truncate(offsets_base);
    }

    fn walk_subtree_dfs(root: &Path, scratch: &mut BulkScratch) -> Option<SizeAcc> {
        let arena = &mut scratch.arena;
        arena.path_bytes.clear();
        arena.child_names.clear();
        arena.child_offsets.clear();
        arena
            .path_bytes
            .extend_from_slice(root.as_os_str().as_encoded_bytes());
        let root_len = arena.path_bytes.len();
        arena.path_bytes.push(0);
        let fd = unsafe {
            open(
                arena.path_bytes.as_ptr() as *const c_char,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            )
        };
        arena.path_bytes.pop();
        if fd < 0 {
            return None;
        }
        let mut acc = SizeAcc::default();
        let mut ancestors = [(0usize, 0usize); 16];
        walk_openat_dfs(
            fd,
            0,
            root_len,
            &mut ancestors,
            &mut scratch.buf,
            arena,
            &mut acc,
        );
        unsafe { close(fd) };
        Some(acc)
    }

    /// Serial `getattrlistbulk` DFS using a caller-owned scoped `BulkScratch`.
    /// Intended for callers already parallelizing across multiple targets via Rayon (zero nested parallelism).
    pub fn calculate_dir_size_bulk_serial(path: &Path, scratch: &mut BulkScratch) -> Option<u64> {
        walk_subtree_dfs(path, scratch).map(SizeAcc::finalize)
    }

    /// Single-root parallel `getattrlistbulk` walker using the bounded worker pool and scoped scratch.
    pub fn calculate_dir_size_bulk(path: &Path) -> Option<u64> {
        let mut root_scratch = BulkScratch::new();
        let mut subdirs: Vec<PathBuf> = Vec::new();
        let mut own = read_single_dir_bulk(path, true, &mut root_scratch, &mut subdirs)?;
        if subdirs.is_empty() {
            return Some(own.finalize());
        }
        if subdirs.len() < 2 {
            for sub in &subdirs {
                if let Some(sub_acc) = walk_subtree_dfs(sub, &mut root_scratch) {
                    own.merge(sub_acc);
                }
            }
            return Some(own.finalize());
        }
        drop(root_scratch);

        let children = worker_pool().install(|| {
            subdirs
                .into_par_iter()
                .map_init(BulkScratch::new, |scratch, sub| {
                    walk_subtree_dfs(&sub, scratch).unwrap_or_default()
                })
                .reduce(SizeAcc::default, |mut a, b| {
                    a.merge(b);
                    a
                })
        });
        own.merge(children);
        Some(own.finalize())
    }
}

#[cfg(target_os = "macos")]
pub(crate) use macos_bulk::BulkScratch;

#[cfg(not(target_os = "macos"))]
pub(crate) struct BulkScratch;

#[cfg(not(target_os = "macos"))]
impl BulkScratch {
    pub(crate) fn new() -> Self {
        Self
    }
}

fn calculate_dir_size_fallback(path: &Path, seen_inodes: &mut HashSet<(u64, u64)>) -> u64 {
    let mut total = 0u64;
    let Ok(entries) = fs::read_dir(path) else {
        return 0;
    };
    for entry in entries.flatten() {
        let entry_path = entry.path();
        let Ok(meta) = fs::symlink_metadata(&entry_path) else {
            continue;
        };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            total = total.saturating_add(calculate_dir_size_fallback(&entry_path, seen_inodes));
        } else if meta.is_file() {
            if meta.nlink() > 1 && !seen_inodes.insert((meta.dev(), meta.ino())) {
                continue;
            }
            let disk_bytes = meta.blocks().saturating_mul(512);
            total = total.saturating_add(if disk_bytes > 0 { disk_bytes } else { meta.len() });
        }
    }
    total
}

/// Accurate physical disk size using a scoped `BulkScratch` (zero nested Rayon, zero permanent TLS).
pub(crate) fn calculate_path_size_accurate_with_scratch(
    path: &Path,
    #[allow(unused_variables)] scratch: &mut BulkScratch,
) -> u64 {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return 0;
    };
    if meta.file_type().is_symlink() {
        return 0;
    }
    if meta.is_file() {
        let disk_bytes = meta.blocks().saturating_mul(512);
        return if disk_bytes > 0 { disk_bytes } else { meta.len() };
    }
    if meta.is_dir() {
        #[cfg(target_os = "macos")]
        {
            if let Some(size) = macos_bulk::calculate_dir_size_bulk_serial(path, scratch) {
                return size;
            }
        }
        let mut seen = HashSet::new();
        return calculate_dir_size_fallback(path, &mut seen);
    }
    0
}

pub(crate) fn calculate_path_size_accurate(path: &Path) -> u64 {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return 0;
    };
    if meta.file_type().is_symlink() {
        return 0;
    }
    if meta.is_file() {
        let disk_bytes = meta.blocks().saturating_mul(512);
        return if disk_bytes > 0 { disk_bytes } else { meta.len() };
    }
    if meta.is_dir() {
        #[cfg(target_os = "macos")]
        {
            if let Some(size) = macos_bulk::calculate_dir_size_bulk(path) {
                return size;
            }
        }
        let mut seen = HashSet::new();
        return calculate_dir_size_fallback(path, &mut seen);
    }
    0
}

// MARK: - Streaming JSON Ingestion Directly into Contiguous Byte Slab

struct FormulaStreamSeed<'a> {
    slab: &'a mut BrewCatalogSlab,
    installed: &'a mut HashMap<String, BrewPackage>,
}

impl<'de, 'a> DeserializeSeed<'de> for FormulaStreamSeed<'a> {
    type Value = ();

    fn deserialize<D>(self, deserializer: D) -> Result<(), D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct FormulaSeqVisitor<'a> {
            slab: &'a mut BrewCatalogSlab,
            installed: &'a mut HashMap<String, BrewPackage>,
        }

        impl<'de, 'a> Visitor<'de> for FormulaSeqVisitor<'a> {
            type Value = ();

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a JSON array of Homebrew formulae")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<(), A::Error>
            where
                A: SeqAccess<'de>,
            {
                let mut ver_buf = String::with_capacity(32);
                while let Some(f) = seq.next_element::<ApiFormula>()? {
                    let local = self.installed.remove(f.name.as_str());
                    let api_stable = f.versions.and_then(|v| v.stable).unwrap_or_default();
                    let api_full: &str = if f.revision > 0 && !api_stable.is_empty() {
                        ver_buf.clear();
                        ver_buf.push_str(&api_stable);
                        ver_buf.push('_');
                        use std::fmt::Write;
                        let _ = write!(&mut ver_buf, "{}", f.revision);
                        ver_buf.as_str()
                    } else {
                        api_stable.as_str()
                    };

                    let (local_ver, is_installed, is_outdated, is_pinned) =
                        if let Some(loc) = local {
                            let outdated = !loc.is_pinned
                                && !loc.version.is_empty()
                                && !api_full.is_empty()
                                && cmp_versions_natural(api_full, &loc.version)
                                    == Ordering::Greater;
                            (Some(loc.version), true, outdated, loc.is_pinned)
                        } else {
                            (None, false, false, false)
                        };

                    self.slab.push_package(
                        &f.name,
                        f.desc.as_deref().unwrap_or(""),
                        api_full,
                        f.homepage.as_deref().unwrap_or(""),
                        local_ver,
                        false,
                        is_installed,
                        is_outdated,
                        is_pinned,
                    );
                }
                Ok(())
            }
        }

        deserializer.deserialize_seq(FormulaSeqVisitor {
            slab: self.slab,
            installed: self.installed,
        })
    }
}

struct CaskStreamSeed<'a> {
    slab: &'a mut BrewCatalogSlab,
    installed: &'a mut HashMap<String, BrewPackage>,
}

impl<'de, 'a> DeserializeSeed<'de> for CaskStreamSeed<'a> {
    type Value = ();

    fn deserialize<D>(self, deserializer: D) -> Result<(), D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct CaskSeqVisitor<'a> {
            slab: &'a mut BrewCatalogSlab,
            installed: &'a mut HashMap<String, BrewPackage>,
        }

        impl<'de, 'a> Visitor<'de> for CaskSeqVisitor<'a> {
            type Value = ();

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a JSON array of Homebrew casks")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<(), A::Error>
            where
                A: SeqAccess<'de>,
            {
                while let Some(c) = seq.next_element::<ApiCask>()? {
                    let local = self.installed.remove(c.token.as_str());
                    let api_ver = c.version.as_deref().unwrap_or("");

                    let (local_ver, is_installed, is_outdated) = if let Some(loc) = local {
                        let outdated = !loc.version.is_empty()
                            && !api_ver.is_empty()
                            && api_ver != "latest"
                            && loc.version != "latest"
                            && api_ver != loc.version
                            && cmp_versions_natural(api_ver, &loc.version) == Ordering::Greater;
                        (Some(loc.version), true, outdated)
                    } else {
                        (None, false, false)
                    };

                    self.slab.push_package(
                        &c.token,
                        c.desc.as_deref().unwrap_or(""),
                        api_ver,
                        c.homepage.as_deref().unwrap_or(""),
                        local_ver,
                        true,
                        is_installed,
                        is_outdated,
                        false,
                    );
                }
                Ok(())
            }
        }

        deserializer.deserialize_seq(CaskSeqVisitor {
            slab: self.slab,
            installed: self.installed,
        })
    }
}

// MARK: - Homebrew Search Index & Direct Disk + API Merging

#[no_mangle]
pub extern "C" fn upkeep_brew_index_new() -> *mut BrewSearchIndex {
    let result = std::panic::catch_unwind(|| {
        Box::into_raw(Box::new(BrewSearchIndex {
            slab: RwLock::new(BrewCatalogSlab::default()),
        }))
    });
    result.unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn upkeep_brew_index_free(ptr: *mut BrewSearchIndex) {
    if !ptr.is_null() {
        let _ = std::panic::catch_unwind(|| unsafe { drop(Box::from_raw(ptr)) });
    }
}

#[cfg(target_os = "macos")]
extern "C" {
    fn malloc_zone_pressure_relief(zone: *mut c_void, goal: usize) -> usize;
}

/// Immediately evicts all indexed packages and releases slab buffers back to macOS.
#[no_mangle]
pub extern "C" fn upkeep_brew_index_clear(ptr: *mut BrewSearchIndex) {
    if ptr.is_null() {
        return;
    }
    let _ = std::panic::catch_unwind(|| {
        let index = unsafe { &*ptr };
        if let Ok(mut guard) = index.slab.write() {
            *guard = BrewCatalogSlab::default();
        }
        #[cfg(target_os = "macos")]
        unsafe {
            malloc_zone_pressure_relief(std::ptr::null_mut(), 0);
        }
    });
}

#[no_mangle]
pub extern "C" fn upkeep_brew_index_count(ptr: *const BrewSearchIndex) -> u32 {
    if ptr.is_null() {
        return 0;
    }
    let index = unsafe { &*ptr };
    index
        .slab
        .read()
        .map(|g| g.entries.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn upkeep_brew_index_load_json(
    ptr: *mut BrewSearchIndex,
    json_utf8: *const c_char,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() || json_utf8.is_null() {
            return 0;
        }
        let index = unsafe { &*ptr };
        let json = cstr_to_str(json_utf8);
        let Ok(parsed) = serde_json::from_str::<Vec<BrewPackage>>(json) else {
            return 0;
        };
        let mut slab = BrewCatalogSlab::with_capacity(parsed.len(), parsed.len() * 80);
        for pkg in parsed {
            slab.push_local_only(pkg);
        }
        slab.shrink_to_fit();
        let count = slab.entries.len() as u32;
        if let Ok(mut guard) = index.slab.write() {
            *guard = slab;
        }
        count
    });
    result.unwrap_or(0)
}

fn split_installed_maps(
    installed: Vec<BrewPackage>,
) -> (HashMap<String, BrewPackage>, HashMap<String, BrewPackage>) {
    let mut installed_formulae: HashMap<String, BrewPackage> = HashMap::new();
    let mut installed_casks: HashMap<String, BrewPackage> = HashMap::new();
    for pkg in installed {
        if pkg.is_cask {
            installed_casks.insert(pkg.name.clone(), pkg);
        } else {
            installed_formulae.insert(pkg.name.clone(), pkg);
        }
    }
    (installed_formulae, installed_casks)
}

fn load_api_readers_internal<R1: Read, R2: Read>(
    index: &BrewSearchIndex,
    formulae_reader: Option<R1>,
    casks_reader: Option<R2>,
    prefix: &str,
) -> u32 {
    // Release old slab before building the new one to prevent 2x steady-state peak RSS.
    if let Ok(mut guard) = index.slab.write() {
        *guard = BrewCatalogSlab::default();
    }

    let installed = scan_brew_dirs_internal(prefix);
    let (mut installed_formulae, mut installed_casks) = split_installed_maps(installed);

    let mut slab = BrewCatalogSlab::with_capacity(16_000, 1_800_000);

    if let Some(r1) = formulae_reader {
        let mut de = serde_json::Deserializer::from_reader(r1);
        let _ = FormulaStreamSeed {
            slab: &mut slab,
            installed: &mut installed_formulae,
        }
        .deserialize(&mut de);
    }

    if let Some(r2) = casks_reader {
        let mut de = serde_json::Deserializer::from_reader(r2);
        let _ = CaskStreamSeed {
            slab: &mut slab,
            installed: &mut installed_casks,
        }
        .deserialize(&mut de);
    }

    for (_, pkg) in installed_formulae {
        slab.push_local_only(pkg);
    }
    for (_, pkg) in installed_casks {
        slab.push_local_only(pkg);
    }

    slab.shrink_to_fit();
    let count = slab.entries.len() as u32;
    if let Ok(mut guard) = index.slab.write() {
        *guard = slab;
    }
    count
}

fn load_api_slices_internal(
    index: &BrewSearchIndex,
    formulae_bytes: &[u8],
    casks_bytes: &[u8],
    prefix: &str,
) -> u32 {
    let r1 = if formulae_bytes.is_empty() {
        None
    } else {
        Some(formulae_bytes)
    };
    let r2 = if casks_bytes.is_empty() {
        None
    } else {
        Some(casks_bytes)
    };
    load_api_readers_internal(index, r1, r2, prefix)
}

/// Streams `formula.json` and `cask.json` directly from disk into the compact byte slab
/// without ever holding raw 30 MB JSON buffers in Swift or Rust RAM.
#[no_mangle]
pub extern "C" fn upkeep_brew_index_load_api_files(
    ptr: *mut BrewSearchIndex,
    formulae_path_utf8: *const c_char,
    casks_path_utf8: *const c_char,
    prefix_utf8: *const c_char,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() {
            return 0;
        }
        let index = unsafe { &*ptr };
        let f_path = cstr_to_str(formulae_path_utf8);
        let c_path = cstr_to_str(casks_path_utf8);
        let prefix = cstr_to_str(prefix_utf8);

        let f_reader = if f_path.is_empty() {
            None
        } else {
            File::open(f_path)
                .ok()
                .map(|f| BufReader::with_capacity(64 * 1024, f))
        };
        let c_reader = if c_path.is_empty() {
            None
        } else {
            File::open(c_path)
                .ok()
                .map(|f| BufReader::with_capacity(64 * 1024, f))
        };

        load_api_readers_internal(index, f_reader, c_reader, prefix)
    });
    result.unwrap_or(0)
}

/// Zero-copy raw byte slice loader for Homebrew `formula.json` and `cask.json`.
#[no_mangle]
pub extern "C" fn upkeep_brew_index_load_api_bytes(
    ptr: *mut BrewSearchIndex,
    formulae_bytes: *const u8,
    formulae_len: usize,
    casks_bytes: *const u8,
    casks_len: usize,
    prefix_utf8: *const c_char,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() {
            return 0;
        }
        let index = unsafe { &*ptr };
        let f_slice = if formulae_bytes.is_null() || formulae_len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(formulae_bytes, formulae_len) }
        };
        let c_slice = if casks_bytes.is_null() || casks_len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(casks_bytes, casks_len) }
        };
        let prefix = cstr_to_str(prefix_utf8);
        load_api_slices_internal(index, f_slice, c_slice, prefix)
    });
    result.unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn upkeep_brew_index_load_api_json(
    ptr: *mut BrewSearchIndex,
    formulae_json_utf8: *const c_char,
    casks_json_utf8: *const c_char,
    prefix_utf8: *const c_char,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() {
            return 0;
        }
        let index = unsafe { &*ptr };
        let f_bytes = cstr_to_str(formulae_json_utf8).as_bytes();
        let c_bytes = cstr_to_str(casks_json_utf8).as_bytes();
        let prefix = cstr_to_str(prefix_utf8);
        load_api_slices_internal(index, f_bytes, c_bytes, prefix)
    });
    result.unwrap_or(0)
}

const BREW_CACHE_MAGIC: &[u8; 4] = b"UKBC";
const BREW_CACHE_VERSION: u32 = 1;

#[inline]
fn write_len_str(buf: &mut Vec<u8>, s: &str) {
    let bytes = s.as_bytes();
    buf.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    buf.extend_from_slice(bytes);
}

#[inline]
fn read_len_str<'a>(data: &'a [u8], cursor: &mut usize) -> Option<&'a str> {
    if *cursor + 4 > data.len() {
        return None;
    }
    let len = u32::from_le_bytes(data[*cursor..*cursor + 4].try_into().ok()?) as usize;
    *cursor += 4;
    if *cursor + len > data.len() {
        return None;
    }
    let s = std::str::from_utf8(&data[*cursor..*cursor + len]).ok()?;
    *cursor += len;
    Some(s)
}

fn save_binary_cache_internal(index: &BrewSearchIndex, cache_path: &Path) -> bool {
    let Ok(guard) = index.slab.read() else {
        return false;
    };
    if guard.entries.is_empty() {
        return false;
    }
    let mut buf = Vec::with_capacity(guard.strings.len() + guard.entries.len() * 17 + 12);
    buf.extend_from_slice(BREW_CACHE_MAGIC);
    buf.extend_from_slice(&BREW_CACHE_VERSION.to_le_bytes());
    buf.extend_from_slice(&(guard.entries.len() as u32).to_le_bytes());
    for entry in &guard.entries {
        let flags: u8 = if entry.is_cask() { 1 } else { 0 };
        buf.push(flags);
        write_len_str(&mut buf, guard.str_of(entry.name));
        write_len_str(&mut buf, guard.str_of(entry.desc));
        write_len_str(&mut buf, guard.str_of(entry.api_ver));
        write_len_str(&mut buf, guard.str_of(entry.homepage));
    }
    if let Some(parent) = cache_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let tmp_path = cache_path.with_extension("bin.tmp");
    if fs::write(&tmp_path, &buf).is_err() {
        return false;
    }
    fs::rename(&tmp_path, cache_path).is_ok()
}

fn load_binary_cache_internal(index: &BrewSearchIndex, cache_path: &Path, prefix: &str) -> u32 {
    let (raw_res, installed) = worker_pool().install(|| {
        rayon::join(|| fs::read(cache_path), || scan_brew_dirs_internal(prefix))
    });
    let Ok(data) = raw_res else {
        return 0;
    };
    if data.len() < 12 || &data[0..4] != BREW_CACHE_MAGIC {
        return 0;
    }
    let version = u32::from_le_bytes(data[4..8].try_into().unwrap());
    if version != BREW_CACHE_VERSION {
        return 0;
    }
    let count = u32::from_le_bytes(data[8..12].try_into().unwrap()) as usize;
    let mut cursor = 12usize;

    let (mut installed_formulae, mut installed_casks) = split_installed_maps(installed);

    let est_string_bytes = data.len().saturating_sub(count.saturating_mul(17));
    let mut slab = BrewCatalogSlab::with_capacity(count + 32, est_string_bytes);
    for _ in 0..count {
        if cursor >= data.len() {
            return 0;
        }
        let flags = data[cursor];
        cursor += 1;
        let is_cask = (flags & 1) != 0;
        let Some(name_str) = read_len_str(&data, &mut cursor) else {
            return 0;
        };
        let Some(desc_str) = read_len_str(&data, &mut cursor) else {
            return 0;
        };
        let Some(api_ver_str) = read_len_str(&data, &mut cursor) else {
            return 0;
        };
        let Some(homepage_str) = read_len_str(&data, &mut cursor) else {
            return 0;
        };

        let local = if is_cask {
            installed_casks.remove(name_str)
        } else {
            installed_formulae.remove(name_str)
        };

        let (local_ver, is_installed, is_outdated, is_pinned) = if let Some(loc) = local {
            let outdated = if is_cask {
                !loc.version.is_empty()
                    && !api_ver_str.is_empty()
                    && api_ver_str != "latest"
                    && loc.version != "latest"
                    && api_ver_str != loc.version
                    && cmp_versions_natural(api_ver_str, &loc.version) == Ordering::Greater
            } else {
                !loc.is_pinned
                    && !loc.version.is_empty()
                    && !api_ver_str.is_empty()
                    && cmp_versions_natural(api_ver_str, &loc.version) == Ordering::Greater
            };
            (Some(loc.version), true, outdated, loc.is_pinned)
        } else {
            (None, false, false, false)
        };

        slab.push_package(
            name_str,
            desc_str,
            api_ver_str,
            homepage_str,
            local_ver,
            is_cask,
            is_installed,
            is_outdated,
            is_pinned,
        );
    }

    for (_, pkg) in installed_formulae {
        slab.push_local_only(pkg);
    }
    for (_, pkg) in installed_casks {
        slab.push_local_only(pkg);
    }

    slab.shrink_to_fit();
    let loaded = slab.entries.len() as u32;
    if let Ok(mut guard) = index.slab.write() {
        *guard = slab;
    }
    loaded
}

/// Loads a compact binary Homebrew catalog cache from disk (<5ms) into the contiguous slab
/// and merges local Cellar/Caskroom state in parallel.
#[no_mangle]
pub extern "C" fn upkeep_brew_index_load_binary_cache(
    ptr: *mut BrewSearchIndex,
    cache_path_utf8: *const c_char,
    prefix_utf8: *const c_char,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() || cache_path_utf8.is_null() {
            return 0;
        }
        let index = unsafe { &*ptr };
        let cache_path = cstr_to_str(cache_path_utf8);
        if cache_path.is_empty() {
            return 0;
        }
        let prefix = cstr_to_str(prefix_utf8);
        load_binary_cache_internal(index, Path::new(cache_path), prefix)
    });
    result.unwrap_or(0)
}

/// Persists the current Homebrew catalog index to a compact binary cache file atomically.
#[no_mangle]
pub extern "C" fn upkeep_brew_index_save_binary_cache(
    ptr: *const BrewSearchIndex,
    cache_path_utf8: *const c_char,
) -> bool {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() || cache_path_utf8.is_null() {
            return false;
        }
        let index = unsafe { &*ptr };
        let cache_path = cstr_to_str(cache_path_utf8);
        if cache_path.is_empty() {
            return false;
        }
        save_binary_cache_internal(index, Path::new(cache_path))
    });
    result.unwrap_or(false)
}

/// Refreshes only local Cellar/Caskroom/pinned state in-place (~5ms) without re-parsing API JSON.
#[no_mangle]
pub extern "C" fn upkeep_brew_index_refresh_local(
    ptr: *mut BrewSearchIndex,
    prefix_utf8: *const c_char,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() {
            return 0;
        }
        let index = unsafe { &*ptr };
        let prefix = cstr_to_str(prefix_utf8);
        let installed = scan_brew_dirs_internal(prefix);
        let (mut installed_formulae, mut installed_casks) = split_installed_maps(installed);

        let Ok(mut guard) = index.slab.write() else {
            return 0;
        };

        guard.local_versions.clear();
        let mut installed_count: u32 = 0;
        let len = guard.entries.len();

        for i in 0..len {
            let is_cask = guard.entries[i].is_cask();
            let name_span = guard.entries[i].name;
            let api_span = guard.entries[i].api_ver;

            let local = {
                let name = guard.str_of(name_span);
                if is_cask {
                    installed_casks.remove(name)
                } else {
                    installed_formulae.remove(name)
                }
            };

            if let Some(loc) = local {
                installed_count += 1;
                let api_ver = guard.str_of(api_span);
                let outdated = if is_cask {
                    !loc.version.is_empty()
                        && !api_ver.is_empty()
                        && api_ver != "latest"
                        && loc.version != "latest"
                        && api_ver != loc.version
                        && cmp_versions_natural(api_ver, &loc.version) == Ordering::Greater
                } else {
                    !loc.is_pinned
                        && !loc.version.is_empty()
                        && !api_ver.is_empty()
                        && cmp_versions_natural(api_ver, &loc.version) == Ordering::Greater
                };
                let mut flags = if is_cask { FLAG_CASK } else { 0 } | FLAG_INSTALLED;
                if outdated {
                    flags |= FLAG_OUTDATED;
                }
                if loc.is_pinned {
                    flags |= FLAG_PINNED;
                }
                let diff_ver = !loc.version.is_empty() && loc.version != api_ver;
                guard.entries[i].flags = flags;
                if diff_ver {
                    guard.local_versions.insert(i as u32, loc.version);
                }
            } else {
                guard.entries[i].flags = if is_cask { FLAG_CASK } else { 0 };
            }
        }

        for (_, pkg) in installed_formulae {
            installed_count += 1;
            guard.push_local_only(pkg);
        }
        for (_, pkg) in installed_casks {
            installed_count += 1;
            guard.push_local_only(pkg);
        }
        installed_count
    });
    result.unwrap_or(0)
}

/// Fast parallel native macOS user cache scanner using getattrlistbulk + bounded Rayon pool.
#[no_mangle]
pub extern "C" fn upkeep_scan_caches_json() -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let home = std::env::var("HOME").unwrap_or_default();
        if home.is_empty() {
            return string_to_cstr("{\"total_bytes\":0,\"items\":[]}".to_string());
        }
        let home_path = PathBuf::from(&home);
        let mut targets: Vec<(&'static str, String, PathBuf)> = Vec::new();

        // 1. User App Caches (top-level entries in ~/Library/Caches, skipping protected Apple caches)
        let caches_dir = home_path.join("Library/Caches");
        if let Ok(entries) = fs::read_dir(&caches_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.')
                    || name.starts_with("com.apple.")
                    || name == "CloudKit"
                    || name == "Homebrew"
                {
                    continue;
                }
                targets.push(("User App Caches", name, entry.path()));
            }
        }

        // 2. Developer & Package Manager Caches
        let dev_targets: [(&str, &str, PathBuf); 8] = [
            (
                "Developer Tools",
                "Xcode DerivedData",
                home_path.join("Library/Developer/Xcode/DerivedData"),
            ),
            (
                "Developer Tools",
                "Homebrew Download Cache",
                home_path.join("Library/Caches/Homebrew"),
            ),
            ("Developer Tools", "npm Cache", home_path.join(".npm/_cacache")),
            ("Developer Tools", "pip Cache", home_path.join(".cache/pip")),
            (
                "Developer Tools",
                "Cargo Registry Cache",
                home_path.join(".cargo/registry/cache"),
            ),
            (
                "Developer Tools",
                "Gradle Cache",
                home_path.join(".gradle/caches"),
            ),
            (
                "Developer Tools",
                "Yarn Cache",
                home_path.join("Library/Caches/Yarn"),
            ),
            (
                "Developer Tools",
                "pnpm Store Cache",
                home_path.join("Library/Caches/pnpm"),
            ),
        ];
        for (cat, name, p) in dev_targets {
            if p.exists() {
                targets.push((cat, name.to_string(), p));
            }
        }

        // 3. User Logs
        let logs_dir = home_path.join("Library/Logs");
        if let Ok(entries) = fs::read_dir(&logs_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if !name.starts_with('.') {
                    targets.push(("User Logs", name, entry.path()));
                }
            }
        }

        let mut items: Vec<CacheScanItem> = worker_pool().install(|| {
            targets
                .into_par_iter()
                .map_init(BulkScratch::new, |scratch, (cat, name, p)| {
                    let size = calculate_path_size_accurate_with_scratch(&p, scratch);
                    if size < 4096 {
                        return None;
                    }
                    Some(CacheScanItem {
                        category: cat.to_string(),
                        name,
                        path: p.to_string_lossy().into_owned(),
                        size_bytes: size,
                    })
                })
                .flatten()
                .collect()
        });

        items.sort_unstable_by(|a, b| b.size_bytes.cmp(&a.size_bytes));
        let total_bytes: u64 = items.iter().map(|i| i.size_bytes).sum();
        let payload = CacheScanPayload { total_bytes, items };
        string_to_cstr(
            serde_json::to_string(&payload)
                .unwrap_or_else(|_| "{\"total_bytes\":0,\"items\":[]}".into()),
        )
    });
    result.unwrap_or_else(|_| string_to_cstr("{\"total_bytes\":0,\"items\":[]}".to_string()))
}

/// Returns all installed packages from the merged API + local index as JSON (sorted by name).
#[no_mangle]
pub extern "C" fn upkeep_brew_index_installed_json(ptr: *const BrewSearchIndex) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() {
            return string_to_cstr("[]".to_string());
        }
        let index = unsafe { &*ptr };
        let Ok(guard) = index.slab.read() else {
            return string_to_cstr("[]".to_string());
        };
        let mut installed: Vec<BrewPackageRef<'_>> = guard
            .entries
            .iter()
            .enumerate()
            .filter(|(_, e)| e.is_installed())
            .map(|(idx, _)| guard.as_wire_ref(idx))
            .collect();
        installed.sort_unstable_by(|a, b| cmp_ignore_ascii_case(a.name, b.name));
        string_to_cstr(serde_json::to_string(&installed).unwrap_or_else(|_| "[]".into()))
    });
    result.unwrap_or_else(|_| string_to_cstr("[]".to_string()))
}

#[inline]
fn score_slab_package(
    slab: &BrewCatalogSlab,
    entry: &SlabPackage,
    query_lower: &str,
    q_bytes: &[u8],
    pattern: &Pattern,
    matcher: &mut Matcher,
    char_buf: &mut Vec<char>,
    skip_description: bool,
) -> Option<u32> {
    let installed_bonus: u32 = if entry.is_installed() { 180 } else { 0 };
    let name = slab.str_of(entry.name);

    // Tier 1: Exact name match
    if name.eq_ignore_ascii_case(query_lower) {
        return Some(200_000 + installed_bonus);
    }

    // Tier 2: Prefix name match (prefer shorter, closer names)
    if starts_with_ignore_ascii_case(name, query_lower) {
        let extra = (name.len().saturating_sub(query_lower.len()) as u32).min(4_000);
        return Some(120_000 - extra * 10 + installed_bonus);
    }

    // Tier 3: Substring name match (SIMD memchr2, zero allocs)
    if let Some(pos) = find_ascii_case_insensitive(name.as_bytes(), q_bytes) {
        let boundary_bonus: u32 = if pos > 0 {
            let prev = name.as_bytes()[pos - 1];
            if prev == b'-' || prev == b'_' || prev == b'@' || prev == b'/' || prev == b'.' {
                5_000
            } else {
                0
            }
        } else {
            5_000
        };
        let pos_penalty = (pos as u32).min(500) * 40;
        let len_penalty = (name.len().saturating_sub(query_lower.len()) as u32).min(500) * 15;
        return Some(75_000 + boundary_bonus - pos_penalty - len_penalty + installed_bonus);
    }

    // Tier 4: Fuzzy name match (zero-copy Utf32Str for ASCII package names)
    char_buf.clear();
    if let Some(name_score) = pattern.score(Utf32Str::new(name, char_buf), matcher) {
        let len_penalty = (name.len() as u32).min(200) * 10;
        return Some(
            25_000u32
                .saturating_add(name_score)
                .saturating_sub(len_penalty)
                + installed_bonus,
        );
    }

    // Short-circuit Tier 5 description scan when top-K name matches are already full.
    if skip_description {
        return None;
    }

    // Tier 5: Description match
    let desc = slab.str_of(entry.desc);
    if !desc.is_empty() {
        let desc_bytes = desc.as_bytes();
        if contains_ascii_case_insensitive(desc_bytes, q_bytes) {
            char_buf.clear();
            let desc_score = pattern
                .score(Utf32Str::new(desc, char_buf), matcher)
                .unwrap_or(100);
            return Some(8_000u32.saturating_add(desc_score) + installed_bonus);
        }
        if query_lower.len() >= 4 {
            char_buf.clear();
            if let Some(desc_score) = pattern.score(Utf32Str::new(desc, char_buf), matcher) {
                if desc_score >= (query_lower.len() as u32) * 28 {
                    return Some(desc_score.min(4_000) + installed_bonus);
                }
            }
        }
    }

    None
}

fn parallel_score_indices(
    slab: &BrewCatalogSlab,
    query: &str,
    filter_mode: i32,
    limit: usize,
    installed_only: bool,
) -> Vec<(u32, u32)> {
    let entries = &slab.entries;
    let matches_filter = |e: &SlabPackage| {
        (!installed_only || e.is_installed())
            && match filter_mode {
                0 => !e.is_cask(),
                1 => e.is_cask(),
                _ => true,
            }
    };

    let trimmed = query.trim();
    if trimmed.is_empty() {
        return entries
            .iter()
            .enumerate()
            .filter(|(_, e)| matches_filter(e))
            .take(limit)
            .map(|(idx, _)| (1u32, idx as u32))
            .collect();
    }

    let query_lower = trimmed.to_ascii_lowercase();
    let q_bytes = query_lower.as_bytes();
    let pattern = Pattern::parse(trimmed, CaseMatching::Smart, Normalization::Smart);

    // Avoid Rayon wakeup overhead for small catalogs or installed-only scans.
    let mut scored: Vec<(u32, u32)> = if entries.len() < 1024 || installed_only {
        let mut matcher = Matcher::new(Config::DEFAULT);
        let mut char_buf = Vec::with_capacity(256);
        let mut high_tier_count = 0usize;
        let mut local = Vec::new();
        for (idx, entry) in entries.iter().enumerate() {
            if !matches_filter(entry) {
                continue;
            }
            let skip_desc = limit > 0 && high_tier_count >= limit;
            if let Some(score) = score_slab_package(
                slab,
                entry,
                &query_lower,
                q_bytes,
                &pattern,
                &mut matcher,
                &mut char_buf,
                skip_desc,
            ) {
                if score >= 25_000 {
                    high_tier_count += 1;
                }
                local.push((score, idx as u32));
            }
        }
        local
    } else {
        // Chunked parallel scan on bounded worker pool with scoped Matcher (freed immediately after search).
        const CHUNK_SIZE: usize = 1024;
        let chunk_results: Vec<Vec<(u32, u32)>> = worker_pool().install(|| {
            entries
                .par_chunks(CHUNK_SIZE)
                .enumerate()
                .map_init(
                    || (Matcher::new(Config::DEFAULT), Vec::with_capacity(256)),
                    |(matcher, char_buf), (chunk_idx, chunk)| {
                        let base_idx = chunk_idx * CHUNK_SIZE;
                        let mut high_tier_count = 0usize;
                        let mut local = Vec::new();
                        for (offset, entry) in chunk.iter().enumerate() {
                            if !matches_filter(entry) {
                                continue;
                            }
                            let skip_desc = limit > 0 && high_tier_count >= limit;
                            if let Some(score) = score_slab_package(
                                slab,
                                entry,
                                &query_lower,
                                q_bytes,
                                &pattern,
                                matcher,
                                char_buf,
                                skip_desc,
                            ) {
                                if score >= 25_000 {
                                    high_tier_count += 1;
                                }
                                local.push((score, (base_idx + offset) as u32));
                            }
                        }
                        if limit > 0 && local.len() > limit {
                            local.select_nth_unstable_by(limit, |a, b| b.0.cmp(&a.0));
                            local.truncate(limit);
                        }
                        local
                    },
                )
                .collect()
        });
        let total_len: usize = chunk_results.iter().map(Vec::len).sum();
        let mut merged = Vec::with_capacity(total_len);
        for chunk in chunk_results {
            merged.extend(chunk);
        }
        merged
    };

    if scored.len() > limit && limit > 0 {
        scored.select_nth_unstable_by(limit, |a, b| b.0.cmp(&a.0));
        scored.truncate(limit);
    }
    scored.sort_unstable_by(|a, b| {
        b.0.cmp(&a.0).then_with(|| {
            cmp_ignore_ascii_case(
                slab.str_of(entries[a.1 as usize].name),
                slab.str_of(entries[b.1 as usize].name),
            )
        })
    });
    scored
}

#[no_mangle]
pub extern "C" fn upkeep_brew_index_search_scoped_json(
    ptr: *const BrewSearchIndex,
    query_utf8: *const c_char,
    limit: u32,
    filter_mode: i32,
    installed_only: bool,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() {
            return string_to_cstr("[]".to_string());
        }
        let index = unsafe { &*ptr };
        let query = cstr_to_str(query_utf8);
        let Ok(guard) = index.slab.read() else {
            return string_to_cstr("[]".to_string());
        };

        let top_indices =
            parallel_score_indices(&guard, query, filter_mode, limit as usize, installed_only);
        let top: Vec<BrewPackageRef<'_>> = top_indices
            .into_iter()
            .map(|(_, idx)| guard.as_wire_ref(idx as usize))
            .collect();
        string_to_cstr(serde_json::to_string(&top).unwrap_or_else(|_| "[]".into()))
    });
    result.unwrap_or_else(|_| string_to_cstr("[]".to_string()))
}

#[no_mangle]
pub extern "C" fn upkeep_brew_index_search_json(
    ptr: *const BrewSearchIndex,
    query_utf8: *const c_char,
    limit: u32,
    filter_mode: i32,
) -> *mut c_char {
    upkeep_brew_index_search_scoped_json(ptr, query_utf8, limit, filter_mode, false)
}

/// Zero-allocation parallel search: writes matches into caller-allocated UpkeepMatch array.
#[no_mangle]
pub extern "C" fn upkeep_brew_index_search_fast(
    ptr: *const BrewSearchIndex,
    query_utf8: *const c_char,
    filter_mode: i32,
    out_matches: *mut UpkeepMatch,
    capacity: u32,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() || out_matches.is_null() || capacity == 0 {
            return 0;
        }
        let index = unsafe { &*ptr };
        let query = cstr_to_str(query_utf8);
        let Ok(guard) = index.slab.read() else {
            return 0;
        };

        let scored = parallel_score_indices(&guard, query, filter_mode, capacity as usize, false);
        let count = (scored.len() as u32).min(capacity);
        for (i, (score, idx)) in scored.into_iter().take(count as usize).enumerate() {
            unsafe {
                *out_matches.add(i) = UpkeepMatch { index: idx, score };
            }
        }
        count
    });
    result.unwrap_or(0)
}

/// Thread-local zero-allocation nucleo fuzzy score for single-pair calls.
#[no_mangle]
pub extern "C" fn upkeep_fuzzy_score(
    query_utf8: *const c_char,
    candidate_utf8: *const c_char,
) -> i32 {
    let result = std::panic::catch_unwind(|| {
        let query = cstr_to_str(query_utf8);
        if query.is_empty() {
            return 0;
        }
        let candidate = cstr_to_str(candidate_utf8);
        let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
        TL_SINGLE_MATCHER.with(|cell| {
            let mut guard = cell.borrow_mut();
            let (matcher, buf) = &mut *guard;
            buf.clear();
            match pattern.score(Utf32Str::new(candidate, buf), matcher) {
                Some(score) => score as i32,
                None => -1,
            }
        })
    });
    result.unwrap_or(-1)
}

// MARK: - Application Scanner (Two-Phase Metadata + Parallel APFS Sizing)

#[derive(Deserialize)]
struct BundleIdPlist {
    #[serde(rename = "CFBundleIdentifier")]
    bundle_id: Option<String>,
}

#[derive(Deserialize)]
struct BundleNamesPlist {
    #[serde(rename = "CFBundleName")]
    bundle_name: Option<String>,
    #[serde(rename = "CFBundleDisplayName")]
    display_name: Option<String>,
}

#[derive(Deserialize)]
struct ContainerMetaPlist {
    #[serde(rename = "MCMMetadataIdentifier")]
    identifier: Option<String>,
}

#[derive(Deserialize)]
struct LaunchAgentPlist {
    #[serde(rename = "Label")]
    label: Option<String>,
    #[serde(rename = "Program")]
    program: Option<String>,
    #[serde(rename = "ProgramArguments")]
    program_arguments: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct JetBrainsProps {
    #[serde(rename = "idea.paths.selector")]
    paths_selector: Option<String>,
}

#[derive(Deserialize)]
struct JetBrainsJvmOptions {
    #[serde(rename = "Properties")]
    properties: Option<JetBrainsProps>,
}

#[derive(Deserialize)]
struct JetBrainsInfoPlist {
    #[serde(rename = "JVMOptions")]
    jvm_options: Option<JetBrainsJvmOptions>,
}

pub(crate) fn extract_xml_plist_string(bytes: &[u8], key_tag: &[u8]) -> Option<String> {
    let pos = memmem::find(bytes, key_tag)?;
    let after_key = &bytes[pos + key_tag.len()..];
    let open_tag = b"<string>";
    let open_pos = memmem::find(after_key, open_tag)?;
    if memmem::find(&after_key[..open_pos], b"<key>").is_some() {
        return None;
    }
    let rest = &after_key[open_pos + open_tag.len()..];
    let close_tag = b"</string>";
    let close_pos = memmem::find(rest, close_tag)?;
    let raw = std::str::from_utf8(&rest[..close_pos]).ok()?.trim();
    if memchr(b'&', raw.as_bytes()).is_some() {
        return None;
    }
    Some(raw.to_string())
}

pub(crate) fn read_bundle_id(app_path: &Path) -> String {
    let plist_path = app_path.join("Contents").join("Info.plist");
    let Ok(bytes) = fs::read(&plist_path) else {
        return String::new();
    };
    if !bytes.starts_with(b"bplist00") {
        if let Some(id) = extract_xml_plist_string(&bytes, b"<key>CFBundleIdentifier</key>") {
            return id;
        }
    }
    plist::from_bytes::<BundleIdPlist>(&bytes)
        .ok()
        .and_then(|p| p.bundle_id)
        .unwrap_or_default()
}

/// Reads `CFBundleName` and `CFBundleDisplayName` from `Contents/Info.plist`.
fn read_bundle_names(app_path: &Path) -> Vec<String> {
    let plist_path = app_path.join("Contents").join("Info.plist");
    let Ok(bytes) = fs::read(&plist_path) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    if !bytes.starts_with(b"bplist00") {
        if let Some(n) = extract_xml_plist_string(&bytes, b"<key>CFBundleName</key>") {
            if !n.is_empty() {
                out.push(n);
            }
        }
        if let Some(d) = extract_xml_plist_string(&bytes, b"<key>CFBundleDisplayName</key>") {
            if !d.is_empty() && !out.iter().any(|x| x.eq_ignore_ascii_case(&d)) {
                out.push(d);
            }
        }
        if !out.is_empty() {
            return out;
        }
    }
    if let Ok(parsed) = plist::from_bytes::<BundleNamesPlist>(&bytes) {
        if let Some(n) = parsed.bundle_name {
            if !n.is_empty() {
                out.push(n);
            }
        }
        if let Some(d) = parsed.display_name {
            if !d.is_empty() && !out.iter().any(|x| x.eq_ignore_ascii_case(&d)) {
                out.push(d);
            }
        }
    }
    out
}

/// Discovers installed `.app` bundles across `/Applications` and `~/Applications` (including
/// 1-level subfolders like `/Applications/Setapp`, `/Applications/Utilities`, and Adobe suites),
/// skipping dot-prefixed updater staging folders (e.g. `/Applications/.x-update/`).
fn collect_app_paths() -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let search_dirs = [
        PathBuf::from("/Applications"),
        PathBuf::from(format!("{}/Applications", home)),
    ];

    let mut app_paths = Vec::new();
    for dir in search_dirs {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let fname = entry.file_name();
            let fname_str = fname.to_string_lossy();
            if path.extension().map_or(false, |ext| ext == "app") {
                app_paths.push(path);
            } else if !fname_str.starts_with('.') {
                let Ok(ft) = entry.file_type() else {
                    continue;
                };
                if ft.is_dir() {
                    if let Ok(sub_entries) = fs::read_dir(&path) {
                        for sub in sub_entries.flatten() {
                            let sp = sub.path();
                            if sp.extension().map_or(false, |ext| ext == "app") {
                                app_paths.push(sp);
                            }
                        }
                    }
                }
            }
        }
    }
    app_paths
}

fn write_app_records(
    records: Vec<(String, String, String, u64)>,
    out_apps: *mut UpkeepAppRecord,
    capacity: u32,
) -> u32 {
    let count = (records.len() as u32).min(capacity);
    for (i, (name, bundle_id, path, size)) in
        records.into_iter().take(count as usize).enumerate()
    {
        unsafe {
            let rec = &mut *out_apps.add(i);
            write_fixed_cstr(&name, &mut rec.name);
            write_fixed_cstr(&bundle_id, &mut rec.bundle_id);
            write_fixed_cstr(&path, &mut rec.path);
            rec.app_size_bytes = size;
        }
    }
    count
}

/// Phase 1 instant app scanner: discovers /Applications and ~/Applications with Info.plist
/// bundle IDs in parallel without walking bundle contents (`app_size_bytes = 0`).
#[no_mangle]
pub extern "C" fn upkeep_scan_applications_metadata(
    out_apps: *mut UpkeepAppRecord,
    capacity: u32,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if out_apps.is_null() || capacity == 0 {
            return 0;
        }
        let app_paths = collect_app_paths();
        let mut records: Vec<(String, String, String, u64)> = worker_pool().install(|| {
            app_paths
                .par_iter()
                .map(|path| {
                    let name = path
                        .file_stem()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned();
                    let bundle_id = read_bundle_id(path);
                    let path_str = path.to_string_lossy().into_owned();
                    (name, bundle_id, path_str, 0u64)
                })
                .collect()
        });

        records.sort_unstable_by(|a, b| cmp_ignore_ascii_case(&a.0, &b.0));
        write_app_records(records, out_apps, capacity)
    });
    result.unwrap_or(0)
}

/// Full multi-threaded parallel scanner of /Applications and ~/Applications using
/// bounded Rayon pool + scoped serial `getattrlistbulk` per app (zero nested Rayon).
#[no_mangle]
pub extern "C" fn upkeep_scan_applications(
    out_apps: *mut UpkeepAppRecord,
    capacity: u32,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if out_apps.is_null() || capacity == 0 {
            return 0;
        }
        let app_paths = collect_app_paths();
        let mut records: Vec<(String, String, String, u64)> = worker_pool().install(|| {
            app_paths
                .par_iter()
                .map_init(BulkScratch::new, |scratch, path| {
                    let name = path
                        .file_stem()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned();
                    let bundle_id = read_bundle_id(path);
                    let path_str = path.to_string_lossy().into_owned();
                    let size = calculate_path_size_accurate_with_scratch(path, scratch);
                    (name, bundle_id, path_str, size)
                })
                .collect()
        });

        records.sort_unstable_by(|a, b| cmp_ignore_ascii_case(&a.0, &b.0));
        write_app_records(records, out_apps, capacity)
    });
    result.unwrap_or(0)
}

/// Computes APFS-accurate physical disk usage for a single file or directory path.
#[no_mangle]
pub extern "C" fn upkeep_calculate_path_size(path_utf8: *const c_char) -> u64 {
    let result = std::panic::catch_unwind(|| {
        let path_str = cstr_to_str(path_utf8);
        if path_str.is_empty() {
            return 0;
        }
        calculate_path_size_accurate(Path::new(path_str))
    });
    result.unwrap_or(0)
}

// MARK: - Parallel Uninstaller Inspector (Mole-Parity Leftovers + Safety Guards + Caskroom)

const COMMON_APP_NAMES: &[&str] = &[
    "music", "notes", "photos", "finder", "safari", "preview", "calendar",
    "contacts", "messages", "reminders", "clock", "weather", "stocks", "books",
    "news", "podcasts", "voice", "files", "store", "system", "helper", "agent",
    "daemon", "service", "update", "sync", "backup", "cloud", "manager",
    "monitor", "server", "client", "worker", "runner", "launcher", "driver",
    "plugin", "extension", "widget", "utility", "app", "mac", "macos", "desktop",
];

const CHANNEL_SUFFIXES: &[&str] = &[
    "developer edition",
    "technology preview",
    "insiders",
    "insider",
    "nightly",
    "canary",
    "preview",
    "release",
    "stable",
    "alpha",
    "beta",
    "edge",
    "dev",
    "lts",
    "rc",
];

const OFFICIAL_UNINSTALLER_RULES: &[(&str, &str)] = &[
    ("com.eset.", "ESET"),
    ("com.jamf.", "Jamf"),
    ("com.jamfsoftware.", "Jamf"),
    ("com.crowdstrike.", "CrowdStrike"),
    ("com.sentinelone.", "SentinelOne"),
    ("com.sentinel-labs.", "SentinelOne"),
    ("com.paloaltonetworks.", "Palo Alto GlobalProtect"),
    ("com.cisco.anyconnect", "Cisco AnyConnect"),
    ("com.cisco.secureclient", "Cisco Secure Client"),
    ("com.alibaba.security.", "Alibaba Cloud Security"),
    ("com.adobe.gcclient", "Adobe Genuine Service"),
    ("com.avast.", "Avast"),
    ("com.avg.hub", "AVG"),
    ("com.malwarebytes.mbam", "Malwarebytes"),
    ("com.teamviewer.", "TeamViewer"),
    ("com.bitdefender.antivirusformac", "Bitdefender"),
    ("com.intego.virusbarrier", "Intego"),
    ("com.kaspersky.kav", "Kaspersky"),
    ("com.symantec.nfm", "Norton"),
    ("com.trendmicro.", "Trend Micro"),
];

const HOLDBACK_BROWSER_PREFIXES: &[&str] = &[
    "google/chrome",
    "bravesoftware",
    "microsoft edge",
    "com.operasoftware.opera",
    "chromium",
    "vivaldi",
    "arc",
    "firefox",
    "zen",
];

const HOLDBACK_DATA_LIBRARY_NAMES: &[&str] = &[
    "crossover",
    "virtualbuddy",
    "openemu",
    "dolphin",
    "pcsx2",
    "retroarch",
    "prismlauncher",
    "minecraft",
    "citra",
    "cemu",
    "ryujinx",
    "ppsspp",
    "rpcs3",
    "multimc",
    "atlauncher",
    "anki2",
];

fn is_common_generic_name(name: &str) -> bool {
    let trimmed = name.trim();
    if trimmed.len() < 3 {
        return true;
    }
    COMMON_APP_NAMES
        .iter()
        .any(|c| trimmed.eq_ignore_ascii_case(c))
}

/// Zero-allocation channel/version suffix stripper (eliminates 60 `format!()` allocs per call).
fn strip_channel_suffix(name: &str) -> Option<String> {
    let trimmed = name.trim();
    let bytes = trimmed.as_bytes();

    for suffix in CHANNEL_SUFFIXES {
        let sb = suffix.as_bytes();
        if bytes.len() <= sb.len() {
            continue;
        }
        let tail_start = bytes.len() - sb.len();
        if !bytes[tail_start..].eq_ignore_ascii_case(sb) {
            continue;
        }
        let head = &trimmed[..tail_start];
        for sep in [" - ", " ", "-", "_"] {
            if let Some(base) = head.strip_suffix(sep) {
                let base = base.trim();
                if base.len() >= 3 {
                    return Some(base.to_string());
                }
            }
        }
    }

    // Strip trailing version numbers (e.g. "App 2", "App 2025")
    if let Some((head, tail)) = trimmed.rsplit_once(' ') {
        if !tail.is_empty()
            && tail.bytes().all(|b| b.is_ascii_digit() || b == b'.')
            && head.trim().len() >= 3
        {
            return Some(head.trim().to_string());
        }
    }
    None
}

fn split_camel_case(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    let mut prev_lower = false;
    for ch in s.chars() {
        if ch.is_ascii_uppercase() && prev_lower {
            out.push(' ');
        }
        out.push(ch);
        prev_lower = ch.is_ascii_lowercase();
    }
    out
}

fn collect_name_variants(name: &str, out: &mut Vec<String>) {
    let trimmed = name.trim();
    if is_common_generic_name(trimmed) {
        return;
    }
    let mut push_unique = |s: String| {
        if !is_common_generic_name(&s) && !out.iter().any(|existing| existing == &s) {
            out.push(s);
        }
    };
    push_unique(trimmed.to_string());
    if trimmed.contains(' ') {
        push_unique(trimmed.replace(' ', ""));
        push_unique(trimmed.replace(' ', "_"));
        push_unique(trimmed.replace(' ', "-"));
    }
    let lower = trimmed.to_ascii_lowercase();
    push_unique(lower.clone());
    if lower.contains(' ') {
        push_unique(lower.replace(' ', ""));
        push_unique(lower.replace(' ', "-"));
        push_unique(lower.replace(' ', "_"));
    }
}

fn detect_official_uninstaller_vendor(bundle_id: &str) -> Option<String> {
    for (prefix, vendor) in OFFICIAL_UNINSTALLER_RULES {
        if starts_with_ignore_ascii_case(bundle_id, prefix) {
            return Some((*vendor).to_string());
        }
    }
    None
}

#[inline]
fn is_uuid_dir_name(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b[8] == b'-'
        && b[13] == b'-'
        && b[18] == b'-'
        && b[23] == b'-'
        && b.iter()
            .enumerate()
            .all(|(i, &c)| matches!(i, 8 | 13 | 18 | 23) || c.is_ascii_hexdigit())
}

/// Boundary-aware bundle ID matcher for container, script, and FileProvider directories:
/// matches `<bid>`, `<bid>.*`, `group.<bid>`, `<TeamID>.<bid>`, `<TeamID>.<bid>.*`.
fn matches_bundle_id_dir(fname_lower: &str, bundle_ids_lower: &[String]) -> bool {
    bundle_ids_lower.iter().any(|b| {
        if eq_or_starts_with_sep(fname_lower, b, b'.') {
            return true;
        }
        if let Some(rest) = fname_lower.strip_prefix("group.") {
            if eq_or_starts_with_sep(rest, b, b'.') {
                return true;
            }
        }
        if let Some((prefix, rest)) = fname_lower.split_once('.') {
            if prefix.len() == 10 && prefix.bytes().all(|c| c.is_ascii_alphanumeric()) {
                if eq_or_starts_with_sep(rest, b, b'.') {
                    return true;
                }
                if let Some(grest) = rest.strip_prefix("group.") {
                    if eq_or_starts_with_sep(grest, b, b'.') {
                        return true;
                    }
                }
            }
        }
        false
    })
}

fn detect_sibling_app(app_name: &str, bundle_id: &str, app_path: &str) -> bool {
    let target_path = Path::new(app_path);
    let target_canonical =
        fs::canonicalize(target_path).unwrap_or_else(|_| target_path.to_path_buf());
    let target_base = strip_channel_suffix(app_name)
        .unwrap_or_else(|| app_name.to_string())
        .to_ascii_lowercase();
    if is_common_generic_name(&target_base) {
        return false;
    }

    let target_bid_lower = bundle_id.to_ascii_lowercase();
    let target_bid_base =
        strip_channel_suffix(&target_bid_lower).unwrap_or_else(|| target_bid_lower.clone());

    let app_paths = collect_app_paths();
    worker_pool().install(|| {
        app_paths.par_iter().any(|other_path| {
            if other_path.as_path() == target_path {
                return false;
            }
            let other_name = other_path
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            let other_base = strip_channel_suffix(&other_name)
                .unwrap_or_else(|| other_name.clone())
                .to_ascii_lowercase();

            if other_base == target_base {
                let other_canonical =
                    fs::canonicalize(other_path).unwrap_or_else(|_| other_path.clone());
                return other_canonical != target_canonical;
            }

            if !target_bid_base.is_empty() {
                let other_bid = read_bundle_id(other_path).to_ascii_lowercase();
                if !other_bid.is_empty() && other_bid != target_bid_lower {
                    let other_bid_base =
                        strip_channel_suffix(&other_bid).unwrap_or_else(|| other_bid.clone());
                    if other_bid_base == target_bid_base {
                        let other_canonical =
                            fs::canonicalize(other_path).unwrap_or_else(|_| other_path.clone());
                        return other_canonical != target_canonical;
                    }
                }
            }
            false
        })
    })
}

fn collect_embedded_bundle_ids(app_path: &Path) -> Vec<String> {
    let mut ids: Vec<String> = Vec::new();
    let contents = app_path.join("Contents");
    let subdirs = [
        "PlugIns",
        "XPCServices",
        "Library/LoginItems",
        "Library/SystemExtensions",
        "Library/QuickLook",
        "Library/Spotlight",
        "Helpers",
        "Preferences",
        "SharedSupport",
    ];
    for rel in subdirs {
        let dir = contents.join(rel);
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let p = entry.path();
            let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("");
            if matches!(
                ext,
                "appex" | "xpc" | "app" | "systemextension" | "qlgenerator" | "mdimporter"
            ) {
                let bid = read_bundle_id(&p);
                if !bid.is_empty() && !ids.iter().any(|x| x == &bid) {
                    ids.push(bid);
                }
            }
        }
    }
    ids
}

fn read_jetbrains_paths_selector(app_path: &Path) -> Option<String> {
    let plist_path = app_path.join("Contents/Info.plist");
    plist::from_file::<_, JetBrainsInfoPlist>(plist_path)
        .ok()?
        .jvm_options?
        .properties?
        .paths_selector
}

pub(crate) fn is_protected_path(path: &Path, home: &str) -> bool {
    let path_str = path.to_string_lossy();
    let path_bytes = path_str.as_bytes();
    let home_bytes = home.as_bytes();
    if path_bytes.len() <= home_bytes.len()
        || !path_bytes[..home_bytes.len()].eq_ignore_ascii_case(home_bytes)
    {
        return false;
    }
    let rest = &path_bytes[home_bytes.len()..];

    // Shared roots that must never be deleted wholesale (zero heap allocations)
    const PROTECTED_EXACT: &[&[u8]] = &[
        b"/.config",
        b"/.cache",
        b"/.local",
        b"/.local/share",
        b"/library/unity",
        b"/library/application support/epic",
        b"/library/application support/steam",
    ];
    if PROTECTED_EXACT.iter().any(|p| rest.eq_ignore_ascii_case(p)) {
        return true;
    }

    // Independent CLI tools (never removed when uninstalling a desktop GUI app)
    const PROTECTED_CLI_PATHS: &[&[u8]] = &[
        b"/.claude", b"/claude", b"/.config/claude", b"/.local/share/claude", b"/.cache/claude",
        b"/.opencode", b"/opencode", b"/.config/opencode", b"/.local/share/opencode", b"/.cache/opencode",
        b"/.codex", b"/codex", b"/.config/codex", b"/.local/share/codex", b"/.cache/codex",
        b"/.gemini", b"/gemini", b"/.config/gemini", b"/.local/share/gemini", b"/.cache/gemini",
    ];
    PROTECTED_CLI_PATHS.iter().any(|p| rest.eq_ignore_ascii_case(p))
}

fn evaluate_holdback(path_str: &str, home: &str, is_system: bool) -> (bool, Option<String>) {
    if is_system {
        return (false, Some("Requires admin privileges".to_string()));
    }
    let lower = path_str.to_ascii_lowercase();
    let home_lower = home.to_ascii_lowercase();
    let rel = lower.strip_prefix(&home_lower).unwrap_or(&lower);

    if rel.starts_with("/library/group containers/") {
        return (false, Some("App Group container".to_string()));
    }
    if eq_or_starts_with_sep(rel, "/library/caches/com.raycast.macos", b'/') {
        return (false, Some("Raycast clipboard history".to_string()));
    }
    if eq_or_starts_with_sep(rel, "/library/caches/mullvadbrowser", b'/') {
        return (false, Some("Browser profile".to_string()));
    }
    if eq_or_starts_with_sep(rel, "/library/caches/buzz", b'/') {
        return (false, Some("Whisper models & plugins".to_string()));
    }
    if eq_or_starts_with_sep(rel, "/library/caches/llama.cpp", b'/') {
        return (false, Some("Downloaded LLM models".to_string()));
    }
    if rel.starts_with("/library/containers/com.isaacmarovitz.whisky")
        || rel.starts_with("/library/containers/com.utmapp.utm")
    {
        return (false, Some("VM / Game library".to_string()));
    }
    if let Some(app_sup_rel) = rel.strip_prefix("/library/application support/") {
        if eq_or_starts_with_sep(app_sup_rel, "spotify", b'/') {
            return (false, Some("Offline music & settings".to_string()));
        }
        for browser in HOLDBACK_BROWSER_PREFIXES {
            if eq_or_starts_with_sep(app_sup_rel, browser, b'/') {
                return (false, Some("Browser profile".to_string()));
            }
        }
        for lib_name in HOLDBACK_DATA_LIBRARY_NAMES {
            if eq_or_starts_with_sep(app_sup_rel, lib_name, b'/') {
                return (false, Some("VM / Game library".to_string()));
            }
        }
    }
    (true, None)
}

fn launch_plist_owned_by_app(plist_path: &Path, bundle_ids: &[String], app_path: &str) -> bool {
    let Ok(parsed) = plist::from_file::<_, LaunchAgentPlist>(plist_path) else {
        return false;
    };
    if let Some(label) = parsed.label.as_deref() {
        let label_bytes = label.as_bytes();
        for bid in bundle_ids {
            let bid_bytes = bid.as_bytes();
            if label_bytes.eq_ignore_ascii_case(bid_bytes)
                || (label_bytes.len() > bid_bytes.len()
                    && label_bytes[bid_bytes.len()] == b'.'
                    && label_bytes[..bid_bytes.len()].eq_ignore_ascii_case(bid_bytes))
            {
                return true;
            }
        }
    }
    if !app_path.is_empty() {
        let app_trimmed = app_path.trim_end_matches('/');
        let matches_app_path = |p: &str| {
            p == app_path || starts_with_sep(p, app_trimmed, b'/')
        };
        if let Some(prog) = parsed.program.as_deref() {
            if matches_app_path(prog) {
                return true;
            }
        }
        if let Some(first) = parsed.program_arguments.as_ref().and_then(|v| v.first()) {
            if matches_app_path(first) {
                return true;
            }
        }
    }
    false
}

fn categorize_leftover(path: &str) -> &'static str {
    if path.starts_with("/private/var/db/receipts/") {
        "System Receipts"
    } else if path.starts_with("/Library/LaunchDaemons/") {
        "System Launch Daemons"
    } else if path.starts_with("/Library/PrivilegedHelperTools/") {
        "Privileged Helpers"
    } else if path.starts_with("/Users/Shared/") {
        "Shared Data"
    } else if path.starts_with("/Library/") {
        "System Library"
    } else if path.contains("/Application Support/") {
        "Application Support"
    } else if path.contains("/Caches/") {
        "Caches"
    } else if path.contains("/Preferences/") || path.contains("/SyncedPreferences/") {
        "Preferences"
    } else if path.contains("/Logs/") {
        "Logs"
    } else if path.contains("/Group Containers/") {
        "Group Containers"
    } else if path.contains("/Containers/") {
        "Containers"
    } else if path.contains("/Saved Application State/") || path.contains("/Autosave Information/") {
        "Saved State"
    } else if path.contains("/LaunchAgents/") {
        "Launch Agents"
    } else if path.contains("/HTTPStorages/")
        || path.contains("/WebKit/")
        || path.contains("/Cookies/")
    {
        "Web & Network Data"
    } else if path.contains("/NativeMessagingHosts/") {
        "Browser Extensions"
    } else if path.contains("/.config/") || path.contains("/.cache/") || path.contains("/.local/") {
        "XDG Config & Data"
    } else if path.contains("/QuickLook/")
        || path.contains("/Spotlight/")
        || path.contains("/Internet Plug-Ins/")
        || path.contains("/PreferencePanes/")
        || path.contains("/Services/")
        || path.contains("/Screen Savers/")
    {
        "Plug-Ins & Services"
    } else {
        "Library Data"
    }
}

fn normalize_token(value: &str) -> String {
    value
        .bytes()
        .filter(|b| b.is_ascii_alphanumeric())
        .map(|b| (b.to_ascii_lowercase()) as char)
        .collect()
}

fn find_installed_cask_parallel(app_name: &str, app_path: &str, prefix: &str) -> Option<String> {
    let base = if !prefix.is_empty() && Path::new(prefix).join("Caskroom").exists() {
        prefix
    } else if Path::new("/opt/homebrew/Caskroom").exists() {
        "/opt/homebrew"
    } else {
        "/usr/local"
    };

    let caskroom = Path::new(base).join("Caskroom");
    let entries = fs::read_dir(&caskroom).ok()?;
    let tokens: Vec<String> = entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') { None } else { Some(name) }
        })
        .collect();

    let app_bundle_name = Path::new(app_path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let needle_bytes = app_bundle_name.as_bytes();
    let normalized_app = normalize_token(app_name);

    // Phase 1: direct app bundle match or .metadata byte search on bounded worker pool
    let direct_match = worker_pool().install(|| {
        tokens.par_iter().find_map_any(|token| {
            let token_dir = caskroom.join(token);
            if let Ok(versions) = fs::read_dir(&token_dir) {
                for entry in versions.flatten() {
                    let name = entry.file_name();
                    if name.to_string_lossy().starts_with('.') {
                        continue;
                    }
                    if entry.path().join(&app_bundle_name).exists() {
                        return Some(token.clone());
                    }
                }
            }

            if !needle_bytes.is_empty() {
                let meta_dir = token_dir.join(".metadata");
                if meta_dir.exists() {
                    let mut stack = vec![meta_dir];
                    while let Some(dir) = stack.pop() {
                        if let Ok(meta_entries) = fs::read_dir(dir) {
                            for entry in meta_entries.flatten() {
                                let p = entry.path();
                                if p.is_dir() {
                                    stack.push(p);
                                } else if let Some(ext) = p.extension().and_then(|e| e.to_str()) {
                                    if ext == "rb" || ext == "json" {
                                        if let Ok(bytes) = fs::read(&p) {
                                            if contains_ascii_case_insensitive(&bytes, needle_bytes)
                                            {
                                                return Some(token.clone());
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            None
        })
    });

    if direct_match.is_some() {
        return direct_match;
    }

    // Phase 2: normalized token name fallback
    tokens
        .into_iter()
        .find(|token| normalize_token(token) == normalized_app)
}

/// Parallel Mole-parity inspector for Uninstaller: discovers user & system leftovers,
/// applies sibling-app & independent-CLI safety guards, computes APFS sizes concurrently
/// via scoped `getattrlistbulk`, and matches Homebrew Caskroom in parallel.
#[no_mangle]
pub extern "C" fn upkeep_inspect_app_uninstall_json(
    app_name_utf8: *const c_char,
    bundle_id_utf8: *const c_char,
    app_path_utf8: *const c_char,
    brew_prefix_utf8: *const c_char,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let app_name = cstr_to_str(app_name_utf8).trim();
        let bundle_id = cstr_to_str(bundle_id_utf8).trim();
        let app_path = cstr_to_str(app_path_utf8);
        let brew_prefix = cstr_to_str(brew_prefix_utf8);

        let home = std::env::var("HOME").unwrap_or_default();
        let home_path = PathBuf::from(&home);
        let library = home_path.join("Library");
        let app_path_buf = PathBuf::from(app_path);

        let official_uninstaller_vendor = detect_official_uninstaller_vendor(bundle_id);

        // Run sibling-app detection and Homebrew Caskroom lookup in parallel on bounded pool
        let (has_sibling_app, cask_token) = worker_pool().install(|| {
            rayon::join(
                || detect_sibling_app(app_name, bundle_id, app_path),
                || find_installed_cask_parallel(app_name, app_path, brew_prefix),
            )
        });

        let leftovers = {
            let mut candidates: Vec<(PathBuf, bool)> = Vec::new();
            let mut seen: HashSet<PathBuf> = HashSet::new();

            let mut add_if_exists = |p: PathBuf, is_system: bool| {
                if is_protected_path(&p, &home) {
                    return;
                }
                if p.exists() && seen.insert(p.clone()) {
                    candidates.push((p, is_system));
                }
            };

            // 1. Collect all bundle IDs (primary + embedded .appex/.xpc/LoginItems/Preferences/Helpers)
            let mut bundle_ids: Vec<String> = Vec::new();
            if !bundle_id.is_empty() {
                bundle_ids.push(bundle_id.to_string());
            }
            if !app_path.is_empty() {
                for emb in collect_embedded_bundle_ids(&app_path_buf) {
                    if !bundle_ids.iter().any(|x| x == &emb) {
                        bundle_ids.push(emb);
                    }
                }
            }
            let bundle_ids_lower: Vec<String> = bundle_ids
                .iter()
                .map(|b| b.to_ascii_lowercase())
                .collect();
            let is_apple_bundle = bundle_ids_lower
                .iter()
                .any(|b| b.starts_with("com.apple."));

            // 2. Collect naming variants (filename + CFBundleName/CFBundleDisplayName, respecting sibling-app guard)
            let mut name_keys: Vec<String> = Vec::new();
            collect_name_variants(app_name, &mut name_keys);
            if !has_sibling_app {
                if !app_path.is_empty() {
                    for bname in read_bundle_names(&app_path_buf) {
                        collect_name_variants(&bname, &mut name_keys);
                        if let Some(stripped) = strip_channel_suffix(&bname) {
                            collect_name_variants(&stripped, &mut name_keys);
                        }
                    }
                }
                if let Some(stripped) = strip_channel_suffix(app_name) {
                    collect_name_variants(&stripped, &mut name_keys);
                }
                if let Some(leaf) = bundle_id.rsplit('.').next() {
                    if leaf.len() >= 3 {
                        collect_name_variants(leaf, &mut name_keys);
                        let split = split_camel_case(leaf);
                        if split != leaf {
                            collect_name_variants(&split, &mut name_keys);
                        }
                    }
                }
            }
            let name_keys_lower: Vec<String> = name_keys
                .iter()
                .map(|k| k.to_ascii_lowercase())
                .collect();

            // 3. Standard ~/Library subdirectories
            const SUBDIRS: [&str; 10] = [
                "Application Support",
                "Caches",
                "Logs",
                "HTTPStorages",
                "WebKit",
                "Containers",
                "Application Scripts",
                "Application Support/FileProvider",
                "Autosave Information",
                "SplashBoard/Snapshots",
            ];

            for subdir in SUBDIRS {
                let dir = library.join(subdir);
                for bid in &bundle_ids {
                    add_if_exists(dir.join(bid), false);
                }
                for nk in &name_keys {
                    add_if_exists(dir.join(nk), false);
                }
            }

            // 4. Boundary-matched extension & group directories
            if !bundle_ids_lower.is_empty() {
                for rel_dir in [
                    "Group Containers",
                    "Containers",
                    "Application Scripts",
                    "Application Support/FileProvider",
                ] {
                    let scan_dir = library.join(rel_dir);
                    if let Ok(entries) = fs::read_dir(&scan_dir) {
                        for entry in entries.flatten() {
                            let fname = entry.file_name().to_string_lossy().into_owned();
                            let fname_lower = fname.to_ascii_lowercase();
                            if !is_apple_bundle && fname_lower.starts_with("com.apple.") {
                                continue;
                            }
                            if matches_bundle_id_dir(&fname_lower, &bundle_ids_lower) {
                                add_if_exists(entry.path(), false);
                            }
                        }
                    }
                }
            }

            // 5. UUID Sandbox Containers (.com.apple.containermanagerd.metadata.plist) — UUID-filtered parallel scan
            let containers_dir = library.join("Containers");
            if !bundle_ids_lower.is_empty() {
                if let Ok(entries) = fs::read_dir(&containers_dir) {
                    let uuid_containers: Vec<PathBuf> = entries
                        .flatten()
                        .filter_map(|entry| {
                            let fname = entry.file_name();
                            let fname_str = fname.to_string_lossy();
                            if !is_uuid_dir_name(&fname_str) {
                                return None;
                            }
                            Some(entry.path())
                        })
                        .collect();
                    if !uuid_containers.is_empty() {
                        let matched_containers: Vec<PathBuf> = worker_pool().install(|| {
                            uuid_containers
                                .into_par_iter()
                                .filter(|p| {
                                    let meta =
                                        p.join(".com.apple.containermanagerd.metadata.plist");
                                    let Ok(parsed) =
                                        plist::from_file::<_, ContainerMetaPlist>(&meta)
                                    else {
                                        return false;
                                    };
                                    parsed.identifier.as_deref().map_or(false, |id| {
                                        let id_lower = id.to_ascii_lowercase();
                                        matches_bundle_id_dir(&id_lower, &bundle_ids_lower)
                                    })
                                })
                                .collect()
                        });
                        for p in matched_containers {
                            add_if_exists(p, false);
                        }
                    }
                }
            }

            // 6. Saved State, Preferences, ByHost, SyncedPreferences, Cookies, HTTPStorages.binarycookies
            let prefs_dir = library.join("Preferences");
            let byhost_dir = prefs_dir.join("ByHost");
            let synced_dir = library.join("SyncedPreferences");
            let cookies_dir = library.join("Cookies");
            let http_dir = library.join("HTTPStorages");
            let sfl_dir = library.join("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments");

            for bid in &bundle_ids {
                add_if_exists(
                    library
                        .join("Saved Application State")
                        .join(format!("{}.savedState", bid)),
                    false,
                );
                add_if_exists(prefs_dir.join(format!("{}.plist", bid)), false);
                add_if_exists(synced_dir.join(format!("{}.plist", bid)), false);
                add_if_exists(cookies_dir.join(format!("{}.binarycookies", bid)), false);
                add_if_exists(http_dir.join(format!("{}.binarycookies", bid)), false);
                add_if_exists(
                    library
                        .join("Caches/com.apple.nsurlsessiond/Downloads")
                        .join(bid),
                    false,
                );
                add_if_exists(library.join("Caches").join(format!("{}.ShipIt", bid)), false);
                add_if_exists(
                    library
                        .join("Caches/com.plausiblelabs.crashreporter.data")
                        .join(bid),
                    false,
                );
                add_if_exists(library.join("Caches/com.crashlytics.data").join(bid), false);
                add_if_exists(library.join("Caches/Bugsnag").join(bid), false);
                add_if_exists(library.join("Caches/KSCrash").join(bid), false);
                add_if_exists(library.join("Caches/SentryCrash").join(bid), false);

                let bid_lower = bid.to_ascii_lowercase();
                for ext in ["sfl2", "sfl3", "sfl4"] {
                    add_if_exists(sfl_dir.join(format!("{}.{}", bid_lower, ext)), false);
                }
            }

            // Prefix-scan Preferences, ByHost, SyncedPreferences (zero inner-loop format! allocs)
            for scan_dir in [&prefs_dir, &byhost_dir, &synced_dir] {
                if let Ok(entries) = fs::read_dir(scan_dir) {
                    for entry in entries.flatten() {
                        let fname = entry.file_name().to_string_lossy().into_owned();
                        if !fname.ends_with(".plist") {
                            continue;
                        }
                        let fname_lower = fname.to_ascii_lowercase();
                        if bundle_ids_lower.iter().any(|bl| {
                            eq_with_suffix(&fname_lower, bl, ".plist")
                                || starts_with_sep(&fname_lower, bl, b'.')
                        }) {
                            add_if_exists(entry.path(), false);
                        }
                    }
                }
            }

            // 7. ShipIt, CrashReporter, Updaters, Cookies, DiagnosticReports by name & bundle ID
            for nk in &name_keys {
                add_if_exists(library.join("Caches").join(format!("{}.ShipIt", nk)), false);
                add_if_exists(
                    library.join("Caches").join(format!("{}-updater", nk)),
                    false,
                );
                add_if_exists(library.join("Caches/KSCrash").join(nk), false);
                add_if_exists(library.join("Caches/SentryCrash").join(nk), false);
                add_if_exists(cookies_dir.join(format!("{}.binarycookies", nk)), false);
            }

            let crash_dir = library.join("Application Support/CrashReporter");
            if let Ok(entries) = fs::read_dir(&crash_dir) {
                for entry in entries.flatten() {
                    let fname = entry.file_name().to_string_lossy().into_owned();
                    if fname.ends_with(".plist") {
                        let fl = fname.to_ascii_lowercase();
                        let matched = name_keys_lower
                            .iter()
                            .any(|nkl| starts_with_sep(&fl, nkl, b'_'))
                            || bundle_ids_lower
                                .iter()
                                .any(|bl| starts_with_sep(&fl, bl, b'_'));
                        if matched {
                            add_if_exists(entry.path(), false);
                        }
                    }
                }
            }

            let diag_dir = library.join("Logs/DiagnosticReports");
            if let Ok(entries) = fs::read_dir(&diag_dir) {
                for entry in entries.flatten() {
                    let fname = entry.file_name().to_string_lossy().into_owned();
                    let fl = fname.to_ascii_lowercase();
                    if fl.ends_with(".ips") || fl.ends_with(".crash") || fl.ends_with(".diag") {
                        if name_keys_lower.iter().any(|nkl| {
                            starts_with_sep(&fl, nkl, b'-') || starts_with_sep(&fl, nkl, b'_')
                        }) {
                            add_if_exists(entry.path(), false);
                        }
                    }
                }
            }

            // 8. NativeMessagingHosts JSON manifests pointing inside app_path
            if !app_path.is_empty() {
                let nmh_dirs = [
                    library.join("Application Support/Google/Chrome/NativeMessagingHosts"),
                    library
                        .join("Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"),
                    library.join("Application Support/Microsoft Edge/NativeMessagingHosts"),
                    library.join("Application Support/Arc/User Data/NativeMessagingHosts"),
                    library.join("Application Support/Mozilla/NativeMessagingHosts"),
                ];
                let app_trimmed = app_path.trim_end_matches('/');
                for nmh_dir in nmh_dirs {
                    if let Ok(entries) = fs::read_dir(&nmh_dir) {
                        for entry in entries.flatten() {
                            let p = entry.path();
                            if p.extension().and_then(|e| e.to_str()) == Some("json") {
                                if let Ok(text) = fs::read_to_string(&p) {
                                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text)
                                    {
                                        if let Some(target) = v.get("path").and_then(|x| x.as_str())
                                        {
                                            if target == app_path
                                                || starts_with_sep(target, app_trimmed, b'/')
                                            {
                                                add_if_exists(p, false);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 9. XDG paths (~/.config, ~/.cache, ~/.local/share) & User Plug-Ins
            if !has_sibling_app {
                for xdg_root in [
                    home_path.join(".config"),
                    home_path.join(".cache"),
                    home_path.join(".local/share"),
                ] {
                    for nk in &name_keys {
                        add_if_exists(xdg_root.join(nk), false);
                    }
                }
            }
            for plugin_dir_name in [
                "Internet Plug-Ins",
                "QuickLook",
                "Spotlight",
                "Screen Savers",
                "PreferencePanes",
                "Services",
            ] {
                let dir = library.join(plugin_dir_name);
                if let Ok(entries) = fs::read_dir(&dir) {
                    for entry in entries.flatten() {
                        let fname = entry.file_name().to_string_lossy().into_owned();
                        let stem = Path::new(&fname)
                            .file_stem()
                            .map(|s| s.to_string_lossy().into_owned())
                            .unwrap_or_default();
                        if name_keys.iter().any(|nk| nk.eq_ignore_ascii_case(&stem))
                            || bundle_ids.iter().any(|b| b.eq_ignore_ascii_case(&stem))
                        {
                            add_if_exists(entry.path(), false);
                        }
                    }
                }
            }

            // 10. Vendor-nested folders (<Vendor>/<Product>)
            let parts: Vec<&str> = bundle_id.split('.').collect();
            if parts.len() >= 3 {
                let vendor = parts[1];
                if !is_common_generic_name(vendor) {
                    for sub in ["Application Support", "Caches", "Logs"] {
                        let base_dir = library.join(sub);
                        if let Ok(v_entries) = fs::read_dir(&base_dir) {
                            for ve in v_entries.flatten() {
                                let vname = ve.file_name().to_string_lossy().into_owned();
                                if vname.eq_ignore_ascii_case(vendor) && ve.path().is_dir() {
                                    for nk in &name_keys {
                                        add_if_exists(ve.path().join(nk), false);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 11. Special-app rules (VS Code, Xcode, JetBrains, Android Studio, Claude Desktop, Docker, Anki, Godot)
            let bid_lower = bundle_id.to_ascii_lowercase();
            if bid_lower == "com.microsoft.vscode" {
                add_if_exists(library.join("Application Support/Code"), false);
                add_if_exists(home_path.join(".vscode"), false);
            } else if bid_lower == "com.microsoft.vscodeinsiders" {
                add_if_exists(library.join("Application Support/Code - Insiders"), false);
                add_if_exists(home_path.join(".vscode-insiders"), false);
            } else if bid_lower == "com.apple.dt.xcode" {
                add_if_exists(library.join("Developer/Xcode"), false);
            } else if bid_lower.starts_with("com.jetbrains.") {
                if let Some(sel) = read_jetbrains_paths_selector(&app_path_buf) {
                    add_if_exists(
                        library.join("Application Support/JetBrains").join(&sel),
                        false,
                    );
                    add_if_exists(library.join("Caches/JetBrains").join(&sel), false);
                    add_if_exists(library.join("Logs/JetBrains").join(&sel), false);
                }
            } else if bid_lower.starts_with("com.google.android.studio") {
                if let Some(sel) = read_jetbrains_paths_selector(&app_path_buf) {
                    add_if_exists(library.join("Application Support/Google").join(&sel), false);
                    add_if_exists(library.join("Caches/Google").join(&sel), false);
                    add_if_exists(library.join("Logs/Google").join(&sel), false);
                }
            } else if bid_lower == "com.anthropic.claudefordesktop" {
                add_if_exists(library.join("Application Support/Claude"), false);
                add_if_exists(library.join("Application Support/Claude-3p"), false);
            } else if bid_lower == "com.docker.docker" {
                add_if_exists(home_path.join(".docker/buildx"), false);
                add_if_exists(home_path.join(".docker/scan"), false);
                add_if_exists(library.join("Group Containers/group.com.docker"), false);
            } else if bid_lower == "net.ankiweb.dtop" || bid_lower == "net.ankisrs.anki" {
                add_if_exists(library.join("Application Support/Anki2"), false);
            } else if bid_lower == "org.godotengine.godot" {
                add_if_exists(library.join("Application Support/Godot"), false);
                add_if_exists(library.join("Caches/Godot"), false);
            }

            // 12. User LaunchAgents
            let agents_dir = library.join("LaunchAgents");
            if let Ok(entries) = fs::read_dir(&agents_dir) {
                for entry in entries.flatten() {
                    let p = entry.path();
                    let fname = entry.file_name().to_string_lossy().into_owned();
                    if !fname.ends_with(".plist") {
                        continue;
                    }
                    let fname_lower = fname.to_ascii_lowercase();
                    if !is_apple_bundle && fname_lower.starts_with("com.apple.") {
                        continue;
                    }
                    let name_match = bundle_ids_lower.iter().any(|bl| {
                        eq_with_suffix(&fname_lower, bl, ".plist")
                            || starts_with_sep(&fname_lower, bl, b'.')
                    });
                    if name_match || launch_plist_owned_by_app(&p, &bundle_ids, app_path) {
                        add_if_exists(p, false);
                    }
                }
            }

            // 13. System-level remnants (unchecked by default; removable with explicit user opt-in + admin auth)
            let sys_lib = Path::new("/Library");
            for subdir in ["Application Support", "Caches", "Logs"] {
                let dir = sys_lib.join(subdir);
                for bid in &bundle_ids {
                    add_if_exists(dir.join(bid), true);
                }
                if !has_sibling_app {
                    for nk in &name_keys {
                        add_if_exists(dir.join(nk), true);
                    }
                }
            }
            for bid in &bundle_ids {
                add_if_exists(
                    sys_lib.join("Preferences").join(format!("{}.plist", bid)),
                    true,
                );
                add_if_exists(sys_lib.join("PrivilegedHelperTools").join(bid), true);
            }
            if !has_sibling_app {
                for nk in &name_keys {
                    add_if_exists(Path::new("/Users/Shared").join(nk), true);
                }
            }
            for sys_launch in [sys_lib.join("LaunchAgents"), sys_lib.join("LaunchDaemons")] {
                if let Ok(entries) = fs::read_dir(&sys_launch) {
                    for entry in entries.flatten() {
                        let p = entry.path();
                        let fname = entry.file_name().to_string_lossy().into_owned();
                        if !fname.ends_with(".plist") {
                            continue;
                        }
                        let fl = fname.to_ascii_lowercase();
                        if !is_apple_bundle && fl.starts_with("com.apple.") {
                            continue;
                        }
                        let name_match = bundle_ids_lower.iter().any(|bl| {
                            eq_with_suffix(&fl, bl, ".plist") || starts_with_sep(&fl, bl, b'.')
                        });
                        if name_match || launch_plist_owned_by_app(&p, &bundle_ids, app_path) {
                            add_if_exists(p, true);
                        }
                    }
                }
            }
            if !bundle_ids_lower.is_empty() {
                if let Ok(entries) = fs::read_dir("/private/var/db/receipts") {
                    for entry in entries.flatten() {
                        let fname = entry.file_name().to_string_lossy().into_owned();
                        let fl = fname.to_ascii_lowercase();
                        if (fl.ends_with(".plist") || fl.ends_with(".bom"))
                            && bundle_ids_lower
                                .iter()
                                .any(|bl| starts_with_sep(&fl, bl, b'.'))
                        {
                            add_if_exists(entry.path(), true);
                        }
                    }
                }
            }

            let mut records: Vec<LeftoverRecord> = worker_pool().install(|| {
                candidates
                    .into_par_iter()
                    .map_init(BulkScratch::new, |scratch, (p, is_system)| {
                        let path_str = p.to_string_lossy().into_owned();
                        let display_path = if !home.is_empty() && path_str.starts_with(&home) {
                            format!("~{}", &path_str[home.len()..])
                        } else {
                            path_str.clone()
                        };
                        let category = categorize_leftover(&path_str).to_string();
                        let size_bytes = calculate_path_size_accurate_with_scratch(&p, scratch);
                        let (default_selected, holdback_reason) =
                            evaluate_holdback(&path_str, &home, is_system);
                        LeftoverRecord {
                            path: path_str,
                            display_path,
                            category,
                            size_bytes,
                            is_system,
                            default_selected,
                            holdback_reason,
                        }
                    })
                    .collect()
            });

            // Sort user items first (selected first, then held-back), system items last; within each group largest first
            records.sort_unstable_by(|a, b| {
                a.is_system
                    .cmp(&b.is_system)
                    .then_with(|| b.default_selected.cmp(&a.default_selected))
                    .then_with(|| b.size_bytes.cmp(&a.size_bytes))
            });
            records
        };

        let payload = UninstallInspectionPayload {
            leftovers,
            homebrew_cask_token: cask_token,
            has_sibling_app,
            official_uninstaller_vendor,
        };
        string_to_cstr(serde_json::to_string(&payload).unwrap_or_else(|_| "{}".into()))
    });
    result.unwrap_or_else(|_| string_to_cstr("{}".to_string()))
}

// MARK: - Homebrew Cellar & Caskroom Direct Disk Scanner

fn scan_brew_dirs_internal(prefix: &str) -> Vec<BrewPackage> {
    let base = if !prefix.is_empty() && Path::new(prefix).exists() {
        prefix
    } else if Path::new("/opt/homebrew").exists() {
        "/opt/homebrew"
    } else {
        "/usr/local"
    };

    let mut pinned_set = HashSet::new();
    let pinned_dir = Path::new(base).join("var/homebrew/pinned");
    if let Ok(entries) = fs::read_dir(pinned_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with('.') {
                pinned_set.insert(name);
            }
        }
    }

    let mut work: Vec<(PathBuf, String, bool)> = Vec::new();
    for (subdir, is_cask) in [("Cellar", false), ("Caskroom", true)] {
        let dir_path = Path::new(base).join(subdir);
        let Ok(entries) = fs::read_dir(dir_path) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(ft) = entry.file_type() else {
                continue;
            };
            if !ft.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            work.push((entry.path(), name, is_cask));
        }
    }

    let mut packages: Vec<BrewPackage> = worker_pool().install(|| {
        work.into_par_iter()
            .map(|(pkg_dir, name, is_cask)| {
                let version = fs::read_dir(&pkg_dir)
                    .ok()
                    .map(|versions| {
                        let mut list: Vec<String> = versions
                            .flatten()
                            .filter_map(|v| {
                                let s = v.file_name().to_string_lossy().into_owned();
                                if s.starts_with('.') { None } else { Some(s) }
                            })
                            .collect();
                        list.sort_unstable_by(|a, b| cmp_versions_natural(a, b));
                        list.pop().unwrap_or_default()
                    })
                    .unwrap_or_default();

                let is_pinned = !is_cask && pinned_set.contains(&name);
                BrewPackage {
                    name,
                    description: if is_cask {
                        "Installed Cask".to_string()
                    } else {
                        "Installed Formula".to_string()
                    },
                    version,
                    is_cask,
                    is_installed: true,
                    is_outdated: false,
                    is_pinned,
                    homepage: String::new(),
                }
            })
            .collect()
    });

    packages.sort_unstable_by(|a, b| cmp_ignore_ascii_case(&a.name, &b.name));
    packages
}

#[no_mangle]
pub extern "C" fn upkeep_scan_brew_dirs_json(prefix_utf8: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let prefix = cstr_to_str(prefix_utf8);
        let packages = scan_brew_dirs_internal(prefix);
        string_to_cstr(serde_json::to_string(&packages).unwrap_or_else(|_| "[]".into()))
    });
    result.unwrap_or_else(|_| string_to_cstr("[]".to_string()))
}

// MARK: - ANSI Stripping & Mole Clean Parser

#[no_mangle]
pub extern "C" fn upkeep_strip_ansi(raw_utf8: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let raw = cstr_to_str(raw_utf8);
        if memchr(0x1b, raw.as_bytes()).is_none() {
            return string_to_cstr(raw.to_string());
        }
        string_to_cstr(strip_ansi_escapes::strip_str(raw))
    });
    result.unwrap_or_else(|_| string_to_cstr(String::new()))
}

#[no_mangle]
pub extern "C" fn upkeep_is_ascii(raw_utf8: *const c_char, len: u32) -> bool {
    if raw_utf8.is_null() {
        return true;
    }
    let slice = unsafe { std::slice::from_raw_parts(raw_utf8 as *const u8, len as usize) };
    slice.is_ascii()
}

#[no_mangle]
pub extern "C" fn upkeep_parse_mole_clean_json(
    raw_utf8: *const c_char,
    is_dry_run: bool,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let raw = cstr_to_str(raw_utf8);
        let cleaned: Cow<'_, str> = if memchr(0x1b, raw.as_bytes()).is_some() {
            Cow::Owned(strip_ansi_escapes::strip_str(raw))
        } else {
            Cow::Borrowed(raw)
        };
        let mut lines = Vec::new();
        let mut total_reclaimed = String::from("0 B");
        let mut item_count: u32 = 0;

        for line in cleaned.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if trimmed.starts_with('✓')
                || trimmed.starts_with('○')
                || trimmed.starts_with('➤')
                || trimmed.starts_with('◎')
            {
                lines.push(trimmed.to_string());
            }

            for marker in ["Removed:", "Would remove:", "Potential space:"] {
                if let Some(idx) = trimmed.find(marker) {
                    let tail = &trimmed[idx + marker.len()..];
                    let sep = if tail.contains('|') { '|' } else { '·' };
                    let mut parts = tail.split(sep);

                    if let Some(size_part) = parts.next() {
                        total_reclaimed.clear();
                        total_reclaimed.push_str(size_part.trim());
                    }

                    for part in parts {
                        let p = part.trim();
                        if let Some(items_idx) = p.find("items") {
                            let mut n: u32 = 0;
                            let mut has_digit = false;
                            for b in p[..items_idx].bytes() {
                                if b.is_ascii_digit() {
                                    has_digit = true;
                                    n = n.saturating_mul(10).saturating_add((b - b'0') as u32);
                                }
                            }
                            if has_digit {
                                item_count = n;
                            }
                        } else if p.len() >= 6 && p.as_bytes()[..6].eq_ignore_ascii_case(b"items:")
                        {
                            let mut n: u32 = 0;
                            let mut has_digit = false;
                            for b in p[6..].bytes() {
                                if b.is_ascii_digit() {
                                    has_digit = true;
                                    n = n.saturating_mul(10).saturating_add((b - b'0') as u32);
                                }
                            }
                            if has_digit {
                                item_count = n;
                            }
                        }
                    }
                }
            }
        }

        if item_count == 0 {
            for line in &lines {
                if (line.starts_with('✓') && !line.contains("Nothing to clean"))
                    || line.starts_with('○')
                {
                    item_count += 1;
                }
            }
        }

        let summary = MoleCleanSummary {
            total_reclaimed,
            item_count,
            lines,
            is_dry_run,
        };
        string_to_cstr(serde_json::to_string(&summary).unwrap_or_else(|_| "{}".into()))
    });
    result.unwrap_or_else(|_| string_to_cstr("{}".to_string()))
}

#[no_mangle]
pub extern "C" fn upkeep_string_free(s: *mut c_char) {
    if !s.is_null() {
        let _ = std::panic::catch_unwind(|| unsafe { drop(CString::from_raw(s)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slab_streaming_search_and_clear() {
        let idx = BrewSearchIndex {
            slab: RwLock::new(BrewCatalogSlab::default()),
        };
        let formulae = br#"[
            {"name":"ripgrep","desc":"Search tool like grep","homepage":"https://example.com/rg","versions":{"stable":"14.1.0"},"revision":1},
            {"name":"git","desc":"Distributed revision control system","homepage":"https://git-scm.com","versions":{"stable":"2.47.0"},"revision":0}
        ]"#;
        let casks = br#"[
            {"token":"visual-studio-code","desc":"Open-source code editor","version":"1.95.0","homepage":"https://code.visualstudio.com"}
        ]"#;

        let empty_prefix = std::env::temp_dir()
            .join(format!("upkeep_slab_test_prefix_{}", std::process::id()));
        let _ = fs::create_dir_all(&empty_prefix);
        let prefix_str = empty_prefix.to_string_lossy().into_owned();

        let loaded = load_api_slices_internal(&idx, formulae, casks, &prefix_str);
        let _ = fs::remove_dir_all(&empty_prefix);
        assert_eq!(loaded, 3);

        let guard = idx.slab.read().unwrap();
        let hits = parallel_score_indices(&guard, "rg", -1, 10, false);
        assert!(!hits.is_empty());
        assert_eq!(guard.str_of(guard.entries[hits[0].1 as usize].name), "ripgrep");
        assert_eq!(guard.version_of(hits[0].1 as usize), "14.1.0_1");
        drop(guard);

        // Clear releases slab memory back to 0
        let raw = Box::into_raw(Box::new(idx));
        upkeep_brew_index_clear(raw);
        assert_eq!(upkeep_brew_index_count(raw), 0);
        upkeep_brew_index_free(raw);
    }

    #[test]
    fn zero_alloc_prefix_and_channel_helpers() {
        assert!(eq_or_starts_with_sep("google/chrome/default", "google/chrome", b'/'));
        assert!(eq_or_starts_with_sep("google/chrome", "google/chrome", b'/'));
        assert!(!eq_or_starts_with_sep("google/chrome2", "google/chrome", b'/'));
        assert_eq!(strip_channel_suffix("Firefox Nightly").as_deref(), Some("Firefox"));
        assert_eq!(strip_channel_suffix("Visual Studio Code - Insiders").as_deref(), Some("Visual Studio Code"));
        assert_eq!(strip_channel_suffix("Alfred 5").as_deref(), Some("Alfred"));
    }
}
