use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str, Utf32String};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::{c_char, c_int, c_void};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

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

struct IndexedPackage {
    pkg: BrewPackage,
    haystack: Utf32String,
}

impl IndexedPackage {
    fn new(pkg: BrewPackage) -> Self {
        let mut raw = String::with_capacity(pkg.name.len() + 1 + pkg.description.len());
        raw.push_str(&pkg.name);
        if !pkg.description.is_empty() {
            raw.push(' ');
            raw.push_str(&pkg.description);
        }
        let haystack = Utf32String::from(raw);
        Self { pkg, haystack }
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
}

#[derive(Debug, Clone, Serialize)]
pub struct UninstallInspectionPayload {
    pub leftovers: Vec<LeftoverRecord>,
    pub homebrew_cask_token: Option<String>,
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
    packages: RwLock<Vec<IndexedPackage>>,
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

// Thread-local Matcher & UTF-32 scratch buffer so single-pair fuzzy calls do zero heap allocations.
thread_local! {
    static TL_MATCHER: RefCell<(Matcher, Vec<char>)> =
        RefCell::new((Matcher::new(Config::DEFAULT), Vec::with_capacity(256)));
}

// MARK: - String & Sorting Helpers

fn cstr_to_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or("")
}

fn string_to_cstr(s: String) -> *mut c_char {
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

/// Fast zero-allocation ASCII case-insensitive substring search on raw byte slices.
#[inline]
fn contains_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() {
        return true;
    }
    if needle.len() > haystack.len() {
        return false;
    }
    let first_lo = needle[0].to_ascii_lowercase();
    let first_hi = needle[0].to_ascii_uppercase();
    let end = haystack.len() - needle.len();

    let mut i = 0;
    while i <= end {
        let b = haystack[i];
        if b == first_lo || b == first_hi {
            let mut matched = true;
            for k in 1..needle.len() {
                if !haystack[i + k].eq_ignore_ascii_case(&needle[k]) {
                    matched = false;
                    break;
                }
            }
            if matched {
                return true;
            }
        }
        i += 1;
    }
    false
}

// MARK: - macOS getattrlistbulk APFS-Accurate Directory Sizing

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
        fn close(fd: c_int) -> c_int;
        fn getattrlistbulk(
            dirfd: c_int,
            attrlist: *mut AttrList,
            attrbuf: *mut c_void,
            bufsize: usize,
            options: u64,
        ) -> c_int;
    }

    /// Walks a directory tree using macOS `getattrlistbulk` (fetching names, types, object IDs,
    /// link counts, and physical APFS allocated sizes for hundreds of entries per syscall).
    pub fn calculate_dir_size_bulk(path: &Path, seen_objs: &mut HashSet<u64>) -> Option<u64> {
        let mut path_buf = Vec::with_capacity(512);
        let mut stack: Vec<PathBuf> = vec![path.to_path_buf()];
        let mut buf = vec![0u8; 64 * 1024];
        let mut total: u64 = 0;

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

        while let Some(dir_path) = stack.pop() {
            path_buf.clear();
            path_buf.extend_from_slice(dir_path.as_os_str().as_encoded_bytes());
            path_buf.push(0);

            let fd = unsafe {
                open(
                    path_buf.as_ptr() as *const c_char,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                )
            };
            if fd < 0 {
                // If the root itself failed to open as a directory, return None to allow fallback.
                if dir_path == path {
                    return None;
                }
                continue;
            }

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
                    let returned: AttributeSet =
                        unsafe { std::ptr::read_unaligned(entry.as_ptr().add(field) as *const AttributeSet) };
                    field += std::mem::size_of::<AttributeSet>();

                    let mut name_bytes: &[u8] = &[];
                    if returned.commonattr & ATTR_CMN_NAME != 0 {
                        if field + std::mem::size_of::<AttrReference>() <= entry.len() {
                            let name_field_start = field;
                            let attr_ref: AttrReference = unsafe {
                                std::ptr::read_unaligned(entry.as_ptr().add(field) as *const AttrReference)
                            };
                            field += std::mem::size_of::<AttrReference>();
                            let start = name_field_start.wrapping_add(attr_ref.attr_dataoffset as usize);
                            let len = attr_ref.attr_length as usize;
                            if start < entry.len() && start + len <= entry.len() && len > 0 {
                                // Strip trailing NUL byte
                                let slice = &entry[start..start + len];
                                name_bytes = slice.strip_suffix(&[0]).unwrap_or(slice);
                            }
                        }
                    }

                    let mut obj_type: u32 = 0;
                    if returned.commonattr & ATTR_CMN_OBJTYPE != 0 {
                        if field + 4 <= entry.len() {
                            obj_type = u32::from_ne_bytes(entry[field..field + 4].try_into().unwrap());
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
                            if let Ok(name_str) = std::str::from_utf8(name_bytes) {
                                stack.push(dir_path.join(name_str));
                            }
                        }
                    } else if obj_type == VREG {
                        let mut link_count: u32 = 1;
                        if returned.fileattr & ATTR_FILE_LINKCOUNT != 0 && field + 4 <= entry.len() {
                            link_count = u32::from_ne_bytes(entry[field..field + 4].try_into().unwrap());
                            field += 4;
                        }

                        let mut total_size: i64 = 0;
                        if returned.fileattr & ATTR_FILE_TOTALSIZE != 0 && field + 8 <= entry.len() {
                            total_size = i64::from_ne_bytes(entry[field..field + 8].try_into().unwrap());
                            field += 8;
                        }

                        let mut alloc_size: i64 = 0;
                        if returned.fileattr & ATTR_FILE_ALLOCSIZE != 0 && field + 8 <= entry.len() {
                            alloc_size = i64::from_ne_bytes(entry[field..field + 8].try_into().unwrap());
                        }

                        if link_count > 1 && obj_key != 0 && !seen_objs.insert(obj_key) {
                            offset += entry_len;
                            continue;
                        }

                        let bytes = if alloc_size > 0 {
                            alloc_size as u64
                        } else if total_size > 0 {
                            total_size as u64
                        } else {
                            0
                        };
                        total = total.saturating_add(bytes);
                    }

                    offset += entry_len;
                }
            }

            unsafe { close(fd) };
        }

        Some(total)
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

fn calculate_path_size_accurate(path: &Path) -> u64 {
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
            let mut seen_objs = HashSet::new();
            if let Some(size) = macos_bulk::calculate_dir_size_bulk(path, &mut seen_objs) {
                return size;
            }
        }
        let mut seen = HashSet::new();
        return calculate_dir_size_fallback(path, &mut seen);
    }
    0
}

// MARK: - Homebrew Search Index & Direct Disk + API Merging

#[no_mangle]
pub extern "C" fn upkeep_brew_index_new() -> *mut BrewSearchIndex {
    let result = std::panic::catch_unwind(|| {
        Box::into_raw(Box::new(BrewSearchIndex {
            packages: RwLock::new(Vec::new()),
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

#[no_mangle]
pub extern "C" fn upkeep_brew_index_count(ptr: *const BrewSearchIndex) -> u32 {
    if ptr.is_null() {
        return 0;
    }
    let index = unsafe { &*ptr };
    index.packages.read().map(|g| g.len() as u32).unwrap_or(0)
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
        let indexed: Vec<IndexedPackage> = parsed.into_iter().map(IndexedPackage::new).collect();
        let count = indexed.len() as u32;
        if let Ok(mut guard) = index.packages.write() {
            *guard = indexed;
        }
        count
    });
    result.unwrap_or(0)
}

fn load_api_slices_internal(
    index: &BrewSearchIndex,
    formulae_bytes: &[u8],
    casks_bytes: &[u8],
    prefix: &str,
) -> u32 {
    // Parse formulae JSON, casks JSON, and local Cellar/Caskroom disk state in parallel.
    let ((formulae_res, casks_res), installed) = rayon::join(
        || {
            rayon::join(
                || {
                    if formulae_bytes.is_empty() {
                        Vec::new()
                    } else {
                        serde_json::from_slice::<Vec<ApiFormula>>(formulae_bytes).unwrap_or_default()
                    }
                },
                || {
                    if casks_bytes.is_empty() {
                        Vec::new()
                    } else {
                        serde_json::from_slice::<Vec<ApiCask>>(casks_bytes).unwrap_or_default()
                    }
                },
            )
        },
        || scan_brew_dirs_internal(prefix),
    );

    let mut installed_map: HashMap<(String, bool), BrewPackage> =
        HashMap::with_capacity(installed.len());
    for pkg in installed {
        installed_map.insert((pkg.name.clone(), pkg.is_cask), pkg);
    }

    let mut merged: Vec<IndexedPackage> =
        Vec::with_capacity(formulae_res.len() + casks_res.len() + installed_map.len());

    for f in formulae_res {
        let local = installed_map.remove(&(f.name.clone(), false));
        let api_stable = f.versions.and_then(|v| v.stable).unwrap_or_default();
        let api_full_version = if f.revision > 0 && !api_stable.is_empty() {
            format!("{}_{}", api_stable, f.revision)
        } else {
            api_stable
        };

        let (version, is_installed, is_outdated, is_pinned) = if let Some(loc) = local {
            let outdated = !loc.is_pinned
                && !loc.version.is_empty()
                && !api_full_version.is_empty()
                && cmp_versions_natural(&api_full_version, &loc.version) == Ordering::Greater;
            let ver = if !loc.version.is_empty() {
                loc.version
            } else {
                api_full_version
            };
            (ver, true, outdated, loc.is_pinned)
        } else {
            (api_full_version, false, false, false)
        };

        merged.push(IndexedPackage::new(BrewPackage {
            name: f.name,
            description: f.desc.unwrap_or_default(),
            version,
            is_cask: false,
            is_installed,
            is_outdated,
            is_pinned,
            homepage: f.homepage.unwrap_or_default(),
        }));
    }

    for c in casks_res {
        let local = installed_map.remove(&(c.token.clone(), true));
        let api_version = c.version.unwrap_or_default();

        let (version, is_installed, is_outdated) = if let Some(loc) = local {
            let outdated = !loc.version.is_empty()
                && !api_version.is_empty()
                && api_version != "latest"
                && loc.version != "latest"
                && api_version != loc.version
                && cmp_versions_natural(&api_version, &loc.version) == Ordering::Greater;
            let ver = if !loc.version.is_empty() {
                loc.version
            } else {
                api_version
            };
            (ver, true, outdated)
        } else {
            (api_version, false, false)
        };

        merged.push(IndexedPackage::new(BrewPackage {
            name: c.token,
            description: c.desc.unwrap_or_default(),
            version,
            is_cask: true,
            is_installed,
            is_outdated,
            is_pinned: false,
            homepage: c.homepage.unwrap_or_default(),
        }));
    }

    // Preserve any custom-tap installed packages not present in core API
    for (_, pkg) in installed_map {
        merged.push(IndexedPackage::new(pkg));
    }

    let count = merged.len() as u32;
    if let Ok(mut guard) = index.packages.write() {
        *guard = merged;
    }
    count
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

/// Returns all installed packages from the merged API + local index as JSON (sorted by name).
#[no_mangle]
pub extern "C" fn upkeep_brew_index_installed_json(ptr: *const BrewSearchIndex) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() {
            return string_to_cstr("[]".to_string());
        }
        let index = unsafe { &*ptr };
        let Ok(guard) = index.packages.read() else {
            return string_to_cstr("[]".to_string());
        };
        let mut installed: Vec<&BrewPackage> = guard
            .iter()
            .filter(|item| item.pkg.is_installed)
            .map(|item| &item.pkg)
            .collect();
        installed.sort_unstable_by(|a, b| cmp_ignore_ascii_case(&a.name, &b.name));
        string_to_cstr(serde_json::to_string(&installed).unwrap_or_else(|_| "[]".into()))
    });
    result.unwrap_or_else(|_| string_to_cstr("[]".to_string()))
}

fn parallel_score_indices(
    items: &[IndexedPackage],
    query: &str,
    filter_mode: i32,
    limit: usize,
) -> Vec<(u32, u32)> {
    let matches_filter = |p: &BrewPackage| match filter_mode {
        0 => !p.is_cask,
        1 => p.is_cask,
        _ => true,
    };

    if query.trim().is_empty() {
        return items
            .iter()
            .enumerate()
            .filter(|(_, item)| matches_filter(&item.pkg))
            .take(limit)
            .map(|(idx, _)| (1u32, idx as u32))
            .collect();
    }

    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);

    // Avoid Rayon thread-pool wakeup overhead for small local catalogs (< 1024 items).
    let mut scored: Vec<(u32, u32)> = if items.len() < 1024 {
        TL_MATCHER.with(|cell| {
            let mut guard = cell.borrow_mut();
            let (matcher, _) = &mut *guard;
            items
                .iter()
                .enumerate()
                .filter(|(_, item)| matches_filter(&item.pkg))
                .filter_map(|(idx, item)| {
                    let score = pattern.score(item.haystack.slice(..), matcher)?;
                    Some((score, idx as u32))
                })
                .collect()
        })
    } else {
        items
            .par_iter()
            .enumerate()
            .filter(|(_, item)| matches_filter(&item.pkg))
            .map_init(
                || Matcher::new(Config::DEFAULT),
                |matcher, (idx, item)| {
                    let score = pattern.score(item.haystack.slice(..), matcher)?;
                    Some((score, idx as u32))
                },
            )
            .flatten()
            .collect()
    };

    if scored.len() > limit && limit > 0 {
        scored.select_nth_unstable_by(limit, |a, b| b.0.cmp(&a.0));
        scored.truncate(limit);
    }
    scored.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    scored
}

#[no_mangle]
pub extern "C" fn upkeep_brew_index_search_json(
    ptr: *const BrewSearchIndex,
    query_utf8: *const c_char,
    limit: u32,
    filter_mode: i32,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() {
            return string_to_cstr("[]".to_string());
        }
        let index = unsafe { &*ptr };
        let query = cstr_to_str(query_utf8);
        let Ok(guard) = index.packages.read() else {
            return string_to_cstr("[]".to_string());
        };

        let top_indices = parallel_score_indices(&guard, query, filter_mode, limit as usize);
        let top: Vec<&BrewPackage> = top_indices
            .into_iter()
            .map(|(_, idx)| &guard[idx as usize].pkg)
            .collect();
        string_to_cstr(serde_json::to_string(&top).unwrap_or_else(|_| "[]".into()))
    });
    result.unwrap_or_else(|_| string_to_cstr("[]".to_string()))
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
        let Ok(guard) = index.packages.read() else {
            return 0;
        };

        let scored = parallel_score_indices(&guard, query, filter_mode, capacity as usize);
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
        TL_MATCHER.with(|cell| {
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

fn read_bundle_id(app_path: &Path) -> String {
    let plist_path = app_path.join("Contents").join("Info.plist");
    let Ok(val) = plist::Value::from_file(plist_path) else {
        return String::new();
    };
    val.as_dictionary()
        .and_then(|d| d.get("CFBundleIdentifier"))
        .and_then(|v| v.as_string())
        .unwrap_or("")
        .to_string()
}

fn collect_app_paths() -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let search_dirs = [
        PathBuf::from("/Applications"),
        PathBuf::from(format!("{}/Applications", home)),
    ];

    let mut app_paths = Vec::new();
    for dir in search_dirs {
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().map_or(false, |ext| ext == "app") {
                    app_paths.push(path);
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
        let mut records: Vec<(String, String, String, u64)> = app_paths
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
            .collect();

        records.sort_unstable_by(|a, b| cmp_ignore_ascii_case(&a.0, &b.0));
        write_app_records(records, out_apps, capacity)
    });
    result.unwrap_or(0)
}

/// Full multi-threaded parallel scanner of /Applications and ~/Applications using
/// Rayon + macOS `getattrlistbulk` for APFS-accurate sizes.
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
        let mut records: Vec<(String, String, String, u64)> = app_paths
            .par_iter()
            .map(|path| {
                let name = path
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned();
                let bundle_id = read_bundle_id(path);
                let path_str = path.to_string_lossy().into_owned();
                let size = calculate_path_size_accurate(path);
                (name, bundle_id, path_str, size)
            })
            .collect();

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

// MARK: - Parallel Uninstaller Inspector (~/Library Leftovers + Caskroom Matching)

fn categorize_leftover(path: &str) -> &'static str {
    if path.contains("/Application Support/") {
        "Application Support"
    } else if path.contains("/Caches/") {
        "Caches"
    } else if path.contains("/Preferences/") {
        "Preferences"
    } else if path.contains("/Logs/") {
        "Logs"
    } else if path.contains("/Group Containers/") {
        "Group Containers"
    } else if path.contains("/Containers/") {
        "Containers"
    } else if path.contains("/Saved Application State/") {
        "Saved State"
    } else if path.contains("/LaunchAgents/") {
        "Launch Agents"
    } else if path.contains("/HTTPStorages/") || path.contains("/WebKit/") {
        "Web & Network Data"
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

    // Phase 1: direct app bundle match or .metadata byte search in parallel
    let direct_match = tokens.par_iter().find_map_any(|token| {
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
                                        if contains_ascii_case_insensitive(&bytes, needle_bytes) {
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
    });

    if direct_match.is_some() {
        return direct_match;
    }

    // Phase 2: normalized token name fallback
    tokens
        .into_iter()
        .find(|token| normalize_token(token) == normalized_app)
}

/// Parallel inspector for Uninstaller: discovers ~/Library leftovers, computes their APFS sizes
/// concurrently via `getattrlistbulk`, and matches Homebrew Caskroom in parallel.
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
        let library = PathBuf::from(&home).join("Library");

        let (leftovers, cask_token) = rayon::join(
            || {
                let mut candidates: Vec<PathBuf> = Vec::new();
                let mut seen: HashSet<PathBuf> = HashSet::new();

                let mut add_if_exists = |p: PathBuf| {
                    if p.exists() && seen.insert(p.clone()) {
                        candidates.push(p);
                    }
                };

                let mut identifiers: Vec<&str> = Vec::with_capacity(2);
                if !bundle_id.is_empty() {
                    identifiers.push(bundle_id);
                }
                if !app_name.is_empty() && app_name != bundle_id {
                    identifiers.push(app_name);
                }

                const SUBDIRS: [&str; 8] = [
                    "Application Support",
                    "Caches",
                    "Logs",
                    "HTTPStorages",
                    "WebKit",
                    "Containers",
                    "Group Containers",
                    "Application Scripts",
                ];

                for subdir in SUBDIRS {
                    let dir = library.join(subdir);
                    for id in &identifiers {
                        add_if_exists(dir.join(id));
                    }
                }

                if !bundle_id.is_empty() {
                    add_if_exists(
                        library
                            .join("Saved Application State")
                            .join(format!("{}.savedState", bundle_id)),
                    );

                    let prefs_dir = library.join("Preferences");
                    add_if_exists(prefs_dir.join(format!("{}.plist", bundle_id)));
                    let pref_prefix = format!("{}.", bundle_id);
                    if let Ok(entries) = fs::read_dir(&prefs_dir) {
                        for entry in entries.flatten() {
                            let fname = entry.file_name().to_string_lossy().into_owned();
                            if fname.starts_with(&pref_prefix) && fname.ends_with(".plist") {
                                add_if_exists(entry.path());
                            }
                        }
                    }

                    let agents_dir = library.join("LaunchAgents");
                    if let Ok(entries) = fs::read_dir(&agents_dir) {
                        for entry in entries.flatten() {
                            let fname = entry.file_name().to_string_lossy().into_owned();
                            if fname.starts_with(bundle_id) && fname.ends_with(".plist") {
                                add_if_exists(entry.path());
                            }
                        }
                    }
                }

                let mut records: Vec<LeftoverRecord> = candidates
                    .into_par_iter()
                    .map(|p| {
                        let path_str = p.to_string_lossy().into_owned();
                        let display_path = if !home.is_empty() && path_str.starts_with(&home) {
                            format!("~{}", &path_str[home.len()..])
                        } else {
                            path_str.clone()
                        };
                        let category = categorize_leftover(&path_str).to_string();
                        let size_bytes = calculate_path_size_accurate(&p);
                        LeftoverRecord {
                            path: path_str,
                            display_path,
                            category,
                            size_bytes,
                        }
                    })
                    .collect();

                records.sort_unstable_by(|a, b| b.size_bytes.cmp(&a.size_bytes));
                records
            },
            || find_installed_cask_parallel(app_name, app_path, brew_prefix),
        );

        let payload = UninstallInspectionPayload {
            leftovers,
            homebrew_cask_token: cask_token,
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

    let mut packages: Vec<BrewPackage> = work
        .into_par_iter()
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
        .collect();

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
        if !raw.as_bytes().contains(&0x1b) {
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
        let cleaned = if raw.as_bytes().contains(&0x1b) {
            strip_ansi_escapes::strip_str(raw)
        } else {
            raw.to_string()
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
                    let parts: Vec<&str> = if tail.contains('|') {
                        tail.split('|').collect()
                    } else {
                        tail.split('·').collect()
                    };

                    if let Some(size_part) = parts.first() {
                        total_reclaimed = size_part.trim().to_string();
                    }

                    for part in &parts {
                        let p = part.trim();
                        if let Some(items_idx) = p.find("items") {
                            let num_str: String = p[..items_idx]
                                .chars()
                                .filter(|c| c.is_ascii_digit())
                                .collect();
                            if let Ok(n) = num_str.parse::<u32>() {
                                item_count = n;
                            }
                        } else if let Some(items_idx) = p.to_lowercase().find("items:") {
                            let num_str: String = p[items_idx + 6..]
                                .chars()
                                .filter(|c| c.is_ascii_digit())
                                .collect();
                            if let Ok(n) = num_str.parse::<u32>() {
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
