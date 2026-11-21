use crate::{calculate_path_size_accurate, cstr_to_str, is_protected_path, string_to_cstr};
use rayon::prelude::*;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::raw::c_char;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

extern "C" {
    fn getuid() -> u32;
}

// MARK: - Data Structures

#[derive(Debug, Clone, Serialize)]
pub struct CleanerItem {
    pub id: String,
    pub category: String,
    pub name: String,
    pub path: String,
    pub display_path: String,
    pub size_bytes: u64,
    pub default_selected: bool,
    pub holdback_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CleanerCategory {
    pub id: String,
    pub title: String,
    pub total_bytes: u64,
    pub items: Vec<CleanerItem>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CleanerScanPayload {
    pub total_bytes: u64,
    pub selected_bytes: u64,
    pub item_count: usize,
    pub scan_duration_ms: u64,
    pub categories: Vec<CleanerCategory>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CleanFailedItem {
    pub path: String,
    pub error: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CleanExecutionPayload {
    pub reclaimed_bytes: u64,
    pub removed_count: usize,
    pub failed_items: Vec<CleanFailedItem>,
    pub duration_ms: u64,
    pub dry_run: bool,
}

struct ScanTarget {
    category_id: &'static str,
    category_title: &'static str,
    name: String,
    path: PathBuf,
    default_selected: bool,
    holdback_reason: Option<&'static str>,
}

const CATEGORY_ORDER: &[(&str, &str)] = &[
    ("developer_tools", "Developer Tools"),
    ("browser_caches", "Browser Caches"),
    ("user_app_caches", "User App Caches"),
    ("logs_diagnostics", "Logs & Diagnostics"),
    ("saved_state_temp", "Saved State & Temp"),
    ("user_trash", "Trash"),
];

/// Relative paths under `$HOME` whose children should be emptied while preserving the folder itself.
const PRESERVE_PARENT_REL_PATHS: &[&str] = &[
    "/library/developer/xcode/deriveddata",
    "/library/developer/xcode/ios devicesupport",
    "/library/developer/xcode/watchos devicesupport",
    "/library/developer/xcode/tvos devicesupport",
    "/library/developer/coresimulator/caches",
    "/library/caches/com.apple.dt.xcode",
    "/library/caches/homebrew",
    "/library/caches/org.swift.swiftpm",
    "/library/caches/cocoapods",
    "/.npm/_cacache",
    "/library/caches/pnpm",
    "/library/caches/yarn",
    "/.bun/install/cache",
    "/library/caches/pip",
    "/.cache/pip",
    "/.cache/uv",
    "/.cargo/registry/cache",
    "/.gradle/caches",
    "/.m2/repository",
    "/library/caches/go-build",
    "/library/caches/google/chrome",
    "/library/caches/bravesoftware",
    "/library/caches/microsoft edge",
    "/library/caches/company.thebrowser.browser",
    "/library/caches/firefox",
    "/library/caches/zen",
    "/library/caches/vivaldi",
    "/library/caches/com.operasoftware.opera",
    "/.trash",
];

fn format_display_path(path_str: &str, home: &str) -> String {
    if !home.is_empty() && path_str.starts_with(home) {
        let rest = &path_str[home.len()..];
        if rest.is_empty() || rest.starts_with('/') {
            return format!("~{}", rest);
        }
    }
    path_str.to_string()
}

fn is_cleaner_protected_rel(rel_lower: &str) -> bool {
    const PROTECTED_PREFIXES: &[&str] = &[
        "/.ssh",
        "/.gnupg",
        "/.aws",
        "/.kube",
        "/.claude",
        "/.codex",
        "/.gemini",
        "/.opencode",
        "/library/keychains",
        "/library/caches/com.local.upkeep",
        "/library/caches/cloudkit",
        "/library/application support/steam",
        "/library/application support/epic",
        "/library/unity",
    ];
    for prefix in PROTECTED_PREFIXES {
        if rel_lower == *prefix || rel_lower.starts_with(&format!("{}/", prefix)) {
            return true;
        }
    }
    if let Some(cache_entry) = rel_lower.strip_prefix("/library/caches/") {
        if cache_entry.starts_with("com.apple.")
            && cache_entry != "com.apple.dt.xcode"
            && !cache_entry.starts_with("com.apple.dt.xcode/")
        {
            return true;
        }
    }
    false
}

/// Validates that a path is strictly safe to delete under `$HOME` or `$TMPDIR`.
/// Returns `Ok(preserve_parent_dir)` or `Err(reason)`.
pub(crate) fn validate_clean_target(
    path: &Path,
    home: &str,
    tmpdir: &str,
) -> Result<bool, String> {
    if path.as_os_str().is_empty() {
        return Err("Empty path".to_string());
    }
    if !path.is_absolute() {
        return Err("Path must be absolute".to_string());
    }
    for comp in path.components() {
        if matches!(comp, Component::ParentDir) {
            return Err("Path traversal ('..') is not allowed".to_string());
        }
    }

    let meta = fs::symlink_metadata(path).map_err(|e| format!("Cannot stat path: {}", e))?;
    if meta.file_type().is_symlink() {
        return Err("Refused to follow symlink".to_string());
    }

    let home_trimmed = home.trim_end_matches('/');
    let tmp_trimmed = tmpdir.trim_end_matches('/');

    let canonical_target = if let (Some(parent), Some(fname)) = (path.parent(), path.file_name()) {
        if let Ok(canon_parent) = fs::canonicalize(parent) {
            canon_parent.join(fname)
        } else {
            path.to_path_buf()
        }
    } else {
        return Err("Cannot clean root directory".to_string());
    };

    let target_str = canonical_target.to_string_lossy();
    let target_trimmed = target_str.trim_end_matches('/');

    let canon_home = if !home_trimmed.is_empty() {
        fs::canonicalize(home_trimmed)
            .map(|p| p.to_string_lossy().trim_end_matches('/').to_string())
            .unwrap_or_else(|_| home_trimmed.to_string())
    } else {
        String::new()
    };
    let canon_tmp = if !tmp_trimmed.is_empty() {
        fs::canonicalize(tmp_trimmed)
            .map(|p| p.to_string_lossy().trim_end_matches('/').to_string())
            .unwrap_or_else(|_| tmp_trimmed.to_string())
    } else {
        String::new()
    };

    let in_home = !canon_home.is_empty()
        && target_trimmed.len() > canon_home.len()
        && target_trimmed.starts_with(&canon_home)
        && target_trimmed.as_bytes()[canon_home.len()] == b'/';

    let in_tmp = !canon_tmp.is_empty()
        && target_trimmed.len() > canon_tmp.len()
        && target_trimmed.starts_with(&canon_tmp)
        && target_trimmed.as_bytes()[canon_tmp.len()] == b'/';

    if !in_home && !in_tmp {
        return Err("Path is outside allowed user home/temp directories".to_string());
    }

    if in_home {
        if is_protected_path(&canonical_target, &canon_home) {
            return Err("Path is protected".to_string());
        }
        let rel_lower = target_trimmed[canon_home.len()..].to_ascii_lowercase();
        const FORBIDDEN_ROOTS: &[&str] = &[
            "/library",
            "/library/caches",
            "/library/application support",
            "/library/logs",
            "/library/saved application state",
            "/library/developer",
            "/library/developer/xcode",
            "/library/preferences",
            "/library/containers",
            "/library/group containers",
            "/desktop",
            "/documents",
            "/downloads",
            "/pictures",
            "/movies",
            "/music",
            "/.config",
            "/.local",
            "/.local/share",
            "/.cache",
        ];
        if FORBIDDEN_ROOTS.contains(&rel_lower.as_str()) {
            return Err("Refused to clean protected root folder".to_string());
        }
        if is_cleaner_protected_rel(&rel_lower) {
            return Err("Path is protected".to_string());
        }

        let preserve_parent = PRESERVE_PARENT_REL_PATHS.contains(&rel_lower.as_str());
        return Ok(preserve_parent);
    }

    Ok(false)
}

fn remove_entry_safely(path: &Path) -> Result<(), String> {
    let meta = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if meta.file_type().is_symlink() || meta.is_file() {
        fs::remove_file(path).map_err(|e| e.to_string())
    } else if meta.is_dir() {
        fs::remove_dir_all(path).map_err(|e| e.to_string())
    } else {
        Ok(())
    }
}

fn clean_single_target(path: &Path, preserve_parent: bool, dry_run: bool) -> Result<u64, String> {
    let size = calculate_path_size_accurate(path);
    if dry_run {
        return Ok(size);
    }

    if preserve_parent && path.is_dir() {
        let entries = fs::read_dir(path).map_err(|e| e.to_string())?;
        let mut first_err: Option<String> = None;
        for entry in entries.flatten() {
            let child = entry.path();
            if let Err(e) = remove_entry_safely(&child) {
                if first_err.is_none() {
                    first_err = Some(e);
                }
            }
        }
        let remaining = calculate_path_size_accurate(path);
        let reclaimed = size.saturating_sub(remaining);
        if let Some(err) = first_err {
            if reclaimed == 0 {
                return Err(err);
            }
        }
        Ok(reclaimed)
    } else {
        remove_entry_safely(path)?;
        Ok(size)
    }
}

// MARK: - Comprehensive Safe Dry-Run Scanner

pub(crate) fn scan_cleaner_internal() -> CleanerScanPayload {
    let started = Instant::now();
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        return CleanerScanPayload {
            total_bytes: 0,
            selected_bytes: 0,
            item_count: 0,
            scan_duration_ms: started.elapsed().as_millis() as u64,
            categories: Vec::new(),
        };
    }

    let home_path = PathBuf::from(&home);
    let mut targets: Vec<ScanTarget> = Vec::new();
    let mut seen_paths: HashSet<PathBuf> = HashSet::new();

    let mut push_target = |cat_id: &'static str,
                           cat_title: &'static str,
                           name: String,
                           path: PathBuf,
                           default_selected: bool,
                           holdback_reason: Option<&'static str>| {
        if let Ok(meta) = fs::symlink_metadata(&path) {
            if meta.file_type().is_symlink() {
                return;
            }
            if is_protected_path(&path, &home) {
                return;
            }
            if seen_paths.insert(path.clone()) {
                targets.push(ScanTarget {
                    category_id: cat_id,
                    category_title: cat_title,
                    name,
                    path,
                    default_selected,
                    holdback_reason,
                });
            }
        }
    };

    // 1. Developer Tools & Package Managers
    let dev_specs: &[(&str, &str, bool, Option<&str>)] = &[
        ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData", true, None),
        ("Xcode Caches", "Library/Caches/com.apple.dt.Xcode", true, None),
        (
            "iOS DeviceSupport",
            "Library/Developer/Xcode/iOS DeviceSupport",
            false,
            Some("Re-downloads when connecting device"),
        ),
        (
            "watchOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            false,
            Some("Re-downloads when connecting device"),
        ),
        (
            "tvOS DeviceSupport",
            "Library/Developer/Xcode/tvOS DeviceSupport",
            false,
            Some("Re-downloads when connecting device"),
        ),
        ("CoreSimulator Caches", "Library/Developer/CoreSimulator/Caches", true, None),
        ("Homebrew Download Cache", "Library/Caches/Homebrew", true, None),
        ("SwiftPM Cache", "Library/Caches/org.swift.swiftpm", true, None),
        ("CocoaPods Cache", "Library/Caches/CocoaPods", true, None),
        ("npm Cache", ".npm/_cacache", true, None),
        ("pnpm Store Cache", "Library/Caches/pnpm", true, None),
        ("Yarn Cache", "Library/Caches/Yarn", true, None),
        ("Bun Install Cache", ".bun/install/cache", true, None),
        ("pip Cache (Library)", "Library/Caches/pip", true, None),
        ("pip Cache (~/.cache)", ".cache/pip", true, None),
        ("uv Cache", ".cache/uv", true, None),
        ("Cargo Registry Cache", ".cargo/registry/cache", true, None),
        ("Gradle Caches", ".gradle/caches", true, None),
        (
            "Maven Repository",
            ".m2/repository",
            false,
            Some("Re-downloads Maven dependencies"),
        ),
        ("Go Build Cache", "Library/Caches/go-build", true, None),
    ];
    for &(name, rel, default_sel, holdback) in dev_specs {
        push_target(
            "developer_tools",
            "Developer Tools",
            name.to_string(),
            home_path.join(rel),
            default_sel,
            holdback,
        );
    }

    // 2. Browser Caches (Caches ONLY — never profiles, cookies, bookmarks, or sessions)
    let browser_specs: &[(&str, &str)] = &[
        ("Google Chrome Cache", "Library/Caches/Google/Chrome"),
        ("Brave Cache", "Library/Caches/BraveSoftware"),
        ("Microsoft Edge Cache", "Library/Caches/Microsoft Edge"),
        ("Arc Cache", "Library/Caches/company.thebrowser.Browser"),
        ("Firefox Cache", "Library/Caches/Firefox"),
        ("Zen Cache", "Library/Caches/zen"),
        ("Vivaldi Cache", "Library/Caches/Vivaldi"),
        ("Opera Cache", "Library/Caches/com.operasoftware.Opera"),
    ];
    for &(name, rel) in browser_specs {
        push_target(
            "browser_caches",
            "Browser Caches",
            name.to_string(),
            home_path.join(rel),
            true,
            None,
        );
    }

    // 3. User App Caches (~/Library/Caches/*)
    let caches_dir = home_path.join("Library/Caches");
    if let Ok(entries) = fs::read_dir(&caches_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let lower = name.to_ascii_lowercase();
            if name.starts_with('.')
                || lower.starts_with("com.apple.")
                || lower == "cloudkit"
                || lower == "homebrew"
                || lower == "com.local.upkeep"
                || lower == "org.swift.swiftpm"
                || lower == "cocoapods"
                || lower == "pnpm"
                || lower == "yarn"
                || lower == "pip"
                || lower == "go-build"
                || lower == "bravesoftware"
                || lower == "microsoft edge"
                || lower == "company.thebrowser.browser"
                || lower == "firefox"
                || lower == "zen"
                || lower == "vivaldi"
                || lower == "com.operasoftware.opera"
            {
                continue;
            }
            if lower == "google" && entry.path().is_dir() {
                if let Ok(google_entries) = fs::read_dir(entry.path()) {
                    for ge in google_entries.flatten() {
                        let gname = ge.file_name().to_string_lossy().into_owned();
                        if gname.starts_with('.') || gname.eq_ignore_ascii_case("chrome") {
                            continue;
                        }
                        push_target(
                            "user_app_caches",
                            "User App Caches",
                            format!("Google {}", gname),
                            ge.path(),
                            true,
                            None,
                        );
                    }
                }
                continue;
            }
            push_target("user_app_caches", "User App Caches", name, entry.path(), true, None);
        }
    }

    // 4. Logs & Diagnostics
    let logs_dir = home_path.join("Library/Logs");
    if let Ok(entries) = fs::read_dir(&logs_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name.eq_ignore_ascii_case("DiagnosticReports") {
                continue;
            }
            push_target("logs_diagnostics", "Logs & Diagnostics", name, entry.path(), true, None);
        }
    }
    let diag_dir = logs_dir.join("DiagnosticReports");
    if let Ok(entries) = fs::read_dir(&diag_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            push_target(
                "logs_diagnostics",
                "Logs & Diagnostics",
                format!("Diagnostic: {}", name),
                entry.path(),
                true,
                None,
            );
        }
    }

    // 5. Saved Application State & Stale Temp Files (>24h)
    let saved_state_dir = home_path.join("Library/Saved Application State");
    if let Ok(entries) = fs::read_dir(&saved_state_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !name.ends_with(".savedState") {
                continue;
            }
            let clean_name = name.trim_end_matches(".savedState").to_string();
            push_target(
                "saved_state_temp",
                "Saved State & Temp",
                clean_name,
                entry.path(),
                false,
                Some("Resets open window positions"),
            );
        }
    }

    if let Ok(tmpdir) = std::env::var("TMPDIR") {
        let tmp_path = PathBuf::from(&tmpdir);
        let my_uid = unsafe { getuid() };
        let cutoff = SystemTime::now()
            .checked_sub(Duration::from_secs(24 * 3600))
            .unwrap_or(SystemTime::UNIX_EPOCH);
        if let Ok(entries) = fs::read_dir(&tmp_path) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                let p = entry.path();
                let Ok(meta) = fs::symlink_metadata(&p) else {
                    continue;
                };
                let ft = meta.file_type();
                if ft.is_symlink()
                    || ft.is_socket()
                    || ft.is_fifo()
                    || ft.is_char_device()
                    || ft.is_block_device()
                {
                    continue;
                }
                if meta.uid() != my_uid {
                    continue;
                }
                let modified = meta.modified().unwrap_or(SystemTime::now());
                if modified > cutoff {
                    continue;
                }
                push_target(
                    "saved_state_temp",
                    "Saved State & Temp",
                    format!("Temp: {}", name),
                    p,
                    true,
                    None,
                );
            }
        }
    }

    // 6. User Trash (optional, unchecked by default)
    push_target(
        "user_trash",
        "Trash",
        "User Trash".to_string(),
        home_path.join(".Trash"),
        false,
        Some("Permanently empties Trash"),
    );

    // Parallel APFS sizing via getattrlistbulk + Rayon
    let scored: Vec<(&'static str, CleanerItem)> = targets
        .into_par_iter()
        .filter_map(|target| {
            let size = calculate_path_size_accurate(&target.path);
            if size < 4096 {
                return None;
            }
            let path_str = target.path.to_string_lossy().into_owned();
            let display_path = format_display_path(&path_str, &home);
            Some((
                target.category_id,
                CleanerItem {
                    id: path_str.clone(),
                    category: target.category_title.to_string(),
                    name: target.name,
                    path: path_str,
                    display_path,
                    size_bytes: size,
                    default_selected: target.default_selected,
                    holdback_reason: target.holdback_reason.map(|s| s.to_string()),
                },
            ))
        })
        .collect();

    let mut grouped: HashMap<&'static str, Vec<CleanerItem>> = HashMap::new();
    for (cat_id, item) in scored {
        grouped.entry(cat_id).or_default().push(item);
    }

    let mut categories: Vec<CleanerCategory> = Vec::new();
    let mut total_bytes: u64 = 0;
    let mut selected_bytes: u64 = 0;
    let mut item_count: usize = 0;

    for &(cat_id, cat_title) in CATEGORY_ORDER {
        let Some(mut items) = grouped.remove(cat_id) else {
            continue;
        };
        if items.is_empty() {
            continue;
        }
        items.sort_unstable_by(|a, b| {
            b.default_selected
                .cmp(&a.default_selected)
                .then_with(|| b.size_bytes.cmp(&a.size_bytes))
        });
        let cat_total: u64 = items.iter().map(|i| i.size_bytes).sum();
        let cat_selected: u64 = items
            .iter()
            .filter(|i| i.default_selected)
            .map(|i| i.size_bytes)
            .sum();
        total_bytes = total_bytes.saturating_add(cat_total);
        selected_bytes = selected_bytes.saturating_add(cat_selected);
        item_count += items.len();
        categories.push(CleanerCategory {
            id: cat_id.to_string(),
            title: cat_title.to_string(),
            total_bytes: cat_total,
            items,
        });
    }

    CleanerScanPayload {
        total_bytes,
        selected_bytes,
        item_count,
        scan_duration_ms: started.elapsed().as_millis() as u64,
        categories,
    }
}

// MARK: - Safe Parallel Cleaner Execution

pub(crate) fn clean_paths_internal(
    paths: Vec<String>,
    dry_run: bool,
    home: &str,
    tmpdir: &str,
) -> CleanExecutionPayload {
    let started = Instant::now();
    let mut unique_paths: Vec<String> = Vec::with_capacity(paths.len());
    let mut seen: HashSet<String> = HashSet::new();
    for p in paths {
        if seen.insert(p.clone()) {
            unique_paths.push(p);
        }
    }

    let outcomes: Vec<(String, Result<u64, String>)> = unique_paths
        .into_par_iter()
        .map(|p| {
            let path = Path::new(&p);
            let res = match validate_clean_target(path, home, tmpdir) {
                Ok(preserve_parent) => clean_single_target(path, preserve_parent, dry_run),
                Err(reason) => Err(reason),
            };
            (p, res)
        })
        .collect();

    let mut reclaimed_bytes: u64 = 0;
    let mut removed_count: usize = 0;
    let mut failed_items: Vec<CleanFailedItem> = Vec::new();

    for (path, res) in outcomes {
        match res {
            Ok(bytes) => {
                reclaimed_bytes = reclaimed_bytes.saturating_add(bytes);
                removed_count += 1;
            }
            Err(error) => {
                failed_items.push(CleanFailedItem { path, error });
            }
        }
    }

    CleanExecutionPayload {
        reclaimed_bytes,
        removed_count,
        failed_items,
        duration_ms: started.elapsed().as_millis() as u64,
        dry_run,
    }
}

// MARK: - C-ABI Exports

#[no_mangle]
pub extern "C" fn upkeep_scan_cleaner_json() -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let payload = scan_cleaner_internal();
        string_to_cstr(
            serde_json::to_string(&payload).unwrap_or_else(|_| {
                "{\"total_bytes\":0,\"selected_bytes\":0,\"item_count\":0,\"scan_duration_ms\":0,\"categories\":[]}".into()
            }),
        )
    });
    result.unwrap_or_else(|_| {
        string_to_cstr(
            "{\"total_bytes\":0,\"selected_bytes\":0,\"item_count\":0,\"scan_duration_ms\":0,\"categories\":[]}"
                .to_string(),
        )
    })
}

#[no_mangle]
pub extern "C" fn upkeep_clean_paths_json(
    paths_json_utf8: *const c_char,
    dry_run: bool,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let raw = cstr_to_str(paths_json_utf8);
        let paths: Vec<String> = serde_json::from_str(raw).unwrap_or_default();
        let home = std::env::var("HOME").unwrap_or_default();
        let tmpdir = std::env::var("TMPDIR").unwrap_or_default();
        let payload = clean_paths_internal(paths, dry_run, &home, &tmpdir);
        string_to_cstr(
            serde_json::to_string(&payload).unwrap_or_else(|_| {
                "{\"reclaimed_bytes\":0,\"removed_count\":0,\"failed_items\":[],\"duration_ms\":0,\"dry_run\":true}".into()
            }),
        )
    });
    result.unwrap_or_else(|_| {
        string_to_cstr(
            "{\"reclaimed_bytes\":0,\"removed_count\":0,\"failed_items\":[],\"duration_ms\":0,\"dry_run\":true}"
                .to_string(),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn rejects_protected_and_root_paths() {
        let home = "/Users/tester";
        let tmp = "/tmp/upkeep_test_tmp";
        assert!(validate_clean_target(Path::new("/"), home, tmp).is_err());
        assert!(validate_clean_target(Path::new(home), home, tmp).is_err());
        assert!(validate_clean_target(Path::new("/Users/tester/Library"), home, tmp).is_err());
        assert!(validate_clean_target(Path::new("/Users/tester/Library/Caches"), home, tmp).is_err());
        assert!(validate_clean_target(Path::new("/Users/tester/Library/Caches/com.local.Upkeep"), home, tmp).is_err());
        assert!(validate_clean_target(Path::new("/Users/tester/.ssh"), home, tmp).is_err());
        assert!(validate_clean_target(Path::new("/Users/tester/Library/Caches/../Documents"), home, tmp).is_err());
    }

    #[test]
    fn cleans_temp_target_and_rejects_symlink() {
        let base = std::env::temp_dir().join(format!("upkeep_cleaner_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();

        let file_a = base.join("stale_cache.bin");
        fs::write(&file_a, vec![42u8; 8192]).unwrap();

        let link_b = base.join("sneaky_link");
        symlink(&file_a, &link_b).unwrap();

        let tmp_str = base.to_string_lossy().into_owned();
        let home_str = "/Users/nonexistent_test_home";

        assert!(validate_clean_target(&link_b, home_str, &tmp_str).is_err());

        let dry = clean_paths_internal(vec![file_a.to_string_lossy().into_owned()], true, home_str, &tmp_str);
        assert_eq!(dry.removed_count, 1);
        assert!(dry.reclaimed_bytes >= 4096);
        assert!(file_a.exists());

        let real = clean_paths_internal(vec![file_a.to_string_lossy().into_owned()], false, home_str, &tmp_str);
        assert_eq!(real.removed_count, 1);
        assert!(real.failed_items.is_empty());
        assert!(!file_a.exists());

        let _ = fs::remove_dir_all(&base);
    }
}
