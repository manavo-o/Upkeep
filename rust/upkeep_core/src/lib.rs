use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

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
    haystack: String,
}

impl IndexedPackage {
    fn new(pkg: BrewPackage) -> Self {
        let mut haystack = String::with_capacity(pkg.name.len() + 1 + pkg.description.len());
        haystack.push_str(&pkg.name);
        if !pkg.description.is_empty() {
            haystack.push(' ');
            haystack.push_str(&pkg.description);
        }
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
        let prefix = cstr_to_str(prefix_utf8);
        let installed = scan_brew_dirs_internal(prefix);
        let mut installed_map: HashMap<(String, bool), BrewPackage> =
            HashMap::with_capacity(installed.len());
        for pkg in installed {
            installed_map.insert((pkg.name.clone(), pkg.is_cask), pkg);
        }

        let mut merged: Vec<IndexedPackage> = Vec::with_capacity(16_000);

        let formulae_str = cstr_to_str(formulae_json_utf8);
        if !formulae_str.is_empty() {
            if let Ok(formulae) = serde_json::from_str::<Vec<ApiFormula>>(formulae_str) {
                for f in formulae {
                    let local = installed_map.remove(&(f.name.clone(), false));
                    let pkg = BrewPackage {
                        name: f.name,
                        description: f.desc.unwrap_or_default(),
                        version: local
                            .as_ref()
                            .map(|l| l.version.clone())
                            .filter(|v| !v.is_empty())
                            .or_else(|| f.versions.and_then(|v| v.stable))
                            .unwrap_or_default(),
                        is_cask: false,
                        is_installed: local.is_some(),
                        is_outdated: false,
                        is_pinned: local.as_ref().map_or(false, |l| l.is_pinned),
                        homepage: f.homepage.unwrap_or_default(),
                    };
                    merged.push(IndexedPackage::new(pkg));
                }
            }
        }

        let casks_str = cstr_to_str(casks_json_utf8);
        if !casks_str.is_empty() {
            if let Ok(casks) = serde_json::from_str::<Vec<ApiCask>>(casks_str) {
                for c in casks {
                    let local = installed_map.remove(&(c.token.clone(), true));
                    let pkg = BrewPackage {
                        name: c.token,
                        description: c.desc.unwrap_or_default(),
                        version: local
                            .as_ref()
                            .map(|l| l.version.clone())
                            .filter(|v| !v.is_empty())
                            .or(c.version)
                            .unwrap_or_default(),
                        is_cask: true,
                        is_installed: local.is_some(),
                        is_outdated: false,
                        is_pinned: false,
                        homepage: c.homepage.unwrap_or_default(),
                    };
                    merged.push(IndexedPackage::new(pkg));
                }
            }
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
    });
    result.unwrap_or(0)
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

    let mut scored: Vec<(u32, u32)> = items
        .par_iter()
        .enumerate()
        .filter(|(_, item)| matches_filter(&item.pkg))
        .map_init(
            || (Matcher::new(Config::DEFAULT), Vec::with_capacity(256)),
            |(matcher, buf), (idx, item)| {
                buf.clear();
                let score = pattern.score(Utf32Str::new(&item.haystack, buf), matcher)?;
                Some((score, idx as u32))
            },
        )
        .flatten()
        .collect();

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
        let mut matcher = Matcher::new(Config::DEFAULT);
        let mut buf = Vec::with_capacity(candidate.len());
        match pattern.score(Utf32Str::new(candidate, &mut buf), &mut matcher) {
            Some(score) => score as i32,
            None => -1,
        }
    });
    result.unwrap_or(-1)
}

fn calculate_dir_size_accurate(path: &Path, seen_inodes: &mut HashSet<(u64, u64)>) -> u64 {
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
            total += calculate_dir_size_accurate(&entry_path, seen_inodes);
        } else if meta.is_file() {
            if meta.nlink() > 1 && !seen_inodes.insert((meta.dev(), meta.ino())) {
                continue;
            }
            let disk_bytes = meta.blocks().saturating_mul(512);
            total += if disk_bytes > 0 { disk_bytes } else { meta.len() };
        }
    }
    total
}

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

/// Multi-threaded parallel scanner of /Applications and ~/Applications using Rayon.
#[no_mangle]
pub extern "C" fn upkeep_scan_applications(
    out_apps: *mut UpkeepAppRecord,
    capacity: u32,
) -> u32 {
    let result = std::panic::catch_unwind(|| {
        if out_apps.is_null() || capacity == 0 {
            return 0;
        }
        let home = std::env::var("HOME").unwrap_or_default();
        let search_dirs = vec![
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
                let mut seen = HashSet::new();
                let size = calculate_dir_size_accurate(path, &mut seen);
                (name, bundle_id, path_str, size)
            })
            .collect();

        records.sort_unstable_by(|a, b| a.0.to_lowercase().cmp(&b.0.to_lowercase()));

        let count = (records.len() as u32).min(capacity);
        for (i, (name, bundle_id, path, size)) in records.into_iter().take(count as usize).enumerate()
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
    });
    result.unwrap_or(0)
}

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
                    list.sort();
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

    packages.sort_unstable_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
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

#[no_mangle]
pub extern "C" fn upkeep_strip_ansi(raw_utf8: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let raw = cstr_to_str(raw_utf8);
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
        let cleaned = strip_ansi_escapes::strip_str(raw);
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
