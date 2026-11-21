use crate::{
    calculate_path_size_accurate, cstr_to_str, is_protected_path, read_bundle_id, string_to_cstr,
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::raw::{c_char, c_int, c_void};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

extern "C" {
    fn getuid() -> u32;
}

#[cfg(target_os = "macos")]
extern "C" {
    fn proc_listallpids(buffer: *mut c_void, buffersize: c_int) -> c_int;
    fn proc_pidpath(pid: c_int, buffer: *mut c_void, buffersize: u32) -> c_int;
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
    pub requires_admin: bool,
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

#[derive(Deserialize)]
struct SystemLaunchPlist {
    #[serde(rename = "Program")]
    program: Option<String>,
    #[serde(rename = "ProgramArguments")]
    program_arguments: Option<Vec<String>>,
}

struct ScanTarget {
    category_id: &'static str,
    category_title: &'static str,
    name: String,
    path: PathBuf,
    default_selected: bool,
    holdback_reason: Option<&'static str>,
    requires_admin: bool,
}

struct RunningApps {
    bundle_ids: HashSet<String>,
    app_names: HashSet<String>,
}

const CATEGORY_ORDER: &[(&str, &str)] = &[
    ("developer_tools", "Developer Tools"),
    ("browser_caches", "Browser Caches"),
    ("app_internal_caches", "App Internal Caches"),
    ("user_app_caches", "User App Caches"),
    ("macos_user_caches", "macOS & Apple Caches"),
    ("project_artifacts", "Project Build Artifacts"),
    ("orphaned_leftovers", "Orphaned App Leftovers"),
    ("logs_diagnostics", "Logs & Diagnostics"),
    ("saved_state_temp", "Saved State & Temp"),
    ("old_installers", "Old Installers"),
    ("system_caches", "System Caches & Logs (Admin)"),
    ("user_trash", "Trash"),
];

/// Relative paths under `$HOME` whose children should be emptied while preserving the folder itself.
const PRESERVE_PARENT_REL_PATHS: &[&str] = &[
    "/library/developer/xcode/deriveddata",
    "/library/developer/xcode/archives",
    "/library/developer/xcode/products",
    "/library/developer/xcode/ios devicesupport",
    "/library/developer/xcode/watchos devicesupport",
    "/library/developer/xcode/tvos devicesupport",
    "/library/developer/xcode/userdata/previews/simulator devices",
    "/library/developer/coresimulator/caches",
    "/library/caches/com.apple.dt.xcode",
    "/library/caches/com.apple.quicklook.thumbnailcache",
    "/library/caches/qlmanage",
    "/library/caches/com.apple.iconservices.store",
    "/library/caches/com.apple.safari/webpage previews",
    "/library/caches/com.apple.webkit.networking",
    "/library/caches/com.apple.appstore",
    "/library/caches/com.apple.appstoreagent",
    "/library/caches/com.apple.mediaanalysisd",
    "/library/caches/com.apple.photoanalysisd",
    "/library/caches/com.apple.parsecd",
    "/library/caches/com.apple.siri",
    "/library/caches/com.apple.ical",
    "/library/caches/com.apple.addressbooksourcesync",
    "/library/messages/caches",
    "/library/messages/stickercache",
    "/library/autosave information",
    "/library/caches/homebrew",
    "/library/caches/org.swift.swiftpm",
    "/library/caches/cocoapods",
    "/library/caches/jetbrains",
    "/.docker/buildx/cache",
    "/.npm/_cacache",
    "/library/caches/pnpm",
    "/library/caches/yarn",
    "/.bun/install/cache",
    "/library/caches/pip",
    "/.cache/pip",
    "/.cache/uv",
    "/library/caches/pypoetry",
    "/library/caches/pipenv",
    "/.cargo/registry/cache",
    "/.cargo/registry/src",
    "/.rustup/downloads",
    "/.gradle/caches",
    "/.m2/repository",
    "/library/caches/go-build",
    "/.android/cache",
    "/.android/build-cache",
    "/library/caches/ms-playwright",
    "/.cache/ms-playwright",
    "/.cache/puppeteer",
    "/.cache/huggingface/hub",
    "/library/caches/node-gyp",
    "/.cache/node-gyp",
    "/library/caches/electron",
    "/.cache/deno",
    "/.cache/typescript",
    "/.cache/pre-commit",
    "/.cache/ruff",
    "/.cache/mypy",
    "/.composer/cache",
    "/.gem/cache",
    "/.pyenv/cache",
    "/.nvm/.cache",
    "/.nuget/packages",
    "/.pub-cache",
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

/// Explicit Apple user caches that are safe to empty (children only; parent preserved).
const SAFE_APPLE_CACHE_REL_PATHS: &[&str] = &[
    "/library/caches/com.apple.dt.xcode",
    "/library/caches/com.apple.quicklook.thumbnailcache",
    "/library/caches/qlmanage",
    "/library/caches/com.apple.iconservices.store",
    "/library/caches/com.apple.safari/webpage previews",
    "/library/caches/com.apple.webkit.networking",
    "/library/caches/com.apple.appstore",
    "/library/caches/com.apple.appstoreagent",
    "/library/caches/com.apple.mediaanalysisd",
    "/library/caches/com.apple.photoanalysisd",
    "/library/caches/com.apple.parsecd",
    "/library/caches/com.apple.siri",
    "/library/caches/com.apple.ical",
    "/library/caches/com.apple.addressbooksourcesync",
];

/// Exact disposable Electron/Chromium cache leaves under `~/Library/Application Support/<App>/`.
const ELECTRON_CACHE_LEAVES: &[(&str, &str)] = &[
    ("Cache", "Cache"),
    ("Code Cache", "Code Cache"),
    ("GPUCache", "GPU Cache"),
    ("DawnCache", "Dawn Cache"),
    ("DawnGraphiteCache", "Dawn Graphite Cache"),
    ("DawnWebGPUCache", "Dawn WebGPU Cache"),
    ("CachedData", "Cached Data"),
    ("Service Worker/CacheStorage", "Service Worker Cache"),
    ("Crashpad/completed", "Crash Reports"),
];

/// Maps `~/Library/Application Support/<folder>` names (lowercased) to their app bundle IDs for live-app detection.
const APP_SUPPORT_BUNDLE_ALIASES: &[(&str, &str)] = &[
    ("code", "com.microsoft.vscode"),
    ("code - insiders", "com.microsoft.vscodeinsiders"),
    ("cursor", "com.todesktop.230313mzl4w4u92"),
    ("slack", "com.tinyspeck.slackmacgap"),
    ("discord", "com.hnc.discord"),
    ("spotify", "com.spotify.client"),
    ("notion", "notion.id"),
    ("figma", "com.figma.desktop"),
    ("obsidian", "md.obsidian"),
    ("claude", "com.anthropic.claudefordesktop"),
    ("linear", "com.linear"),
    ("tradingview", "com.tradingview.tradingviewapp.desktop"),
    ("postman", "com.postmanlabs.mac"),
    ("whatsapp", "net.whatsapp.whatsapp"),
    ("microsoft teams", "com.microsoft.teams2"),
    ("zed", "dev.zed.zed"),
    ("windsurf", "com.exafunction.windsurf"),
];

const PROTECTED_APP_SUPPORT_NAMES: &[&str] = &[
    "addressbook",
    "anki2",
    "bitwarden",
    "callhistorydb",
    "callhistorytransactions",
    "clash",
    "clashx",
    "clouddocs",
    "com.apple.idleassetsd",
    "com.apple.sharedfilelist",
    "com.apple.tcc",
    "com.apple.wallpaper",
    "crashreporter",
    "crossover",
    "dock",
    "docker",
    "epic",
    "fileprovider",
    "icdd",
    "keepassxc",
    "knowledge",
    "lm studio",
    "minecraft",
    "mobilesync",
    "ollama",
    "orbstack",
    "parallels",
    "shadowsocksx-ng",
    "steam",
    "syncservices",
    "tailscale",
    "utm",
    "v2rayu",
    "whisky",
    "wireguard",
    "1password",
];

const PROTECTED_CONTAINER_PREFIXES: &[&str] = &[
    "com.apple.",
    "com.local.upkeep",
    "com.docker.",
    "dev.orbstack.",
    "dev.kdrag0n.macvirt",
    "com.utmapp.utm",
    "com.isaacmarovitz.whisky",
    "com.parallels.",
    "io.tailscale.",
    "com.wireguard.",
    "com.agilebits.",
    "com.1password.",
    "com.bitwarden.",
];

const INSTALLER_EXTENSIONS: &[&str] = &["dmg", "pkg", "mpkg", "iso", "xip"];
const INCOMPLETE_DOWNLOAD_EXTENSIONS: &[&str] = &["crdownload", "download", "part"];

/// Default project roots scanned for rebuildable build artifacts (`mo purge` parity).
const DEFAULT_PROJECT_ROOTS: &[&str] = &[
    "Projects",
    "projects",
    "Developer",
    "Code",
    "GitHub",
    "dev",
    "Workspace",
    "workspace",
    "src",
    "Repos",
];

/// Rebuildable project artifact directories and their required sibling project marker files.
const PROJECT_ARTIFACT_RULES: &[(&str, &[&str])] = &[
    ("node_modules", &["package.json"]),
    (".next", &["package.json", "next.config.js", "next.config.mjs", "next.config.ts"]),
    (".nuxt", &["package.json", "nuxt.config.ts", "nuxt.config.js"]),
    (".svelte-kit", &["package.json", "svelte.config.js"]),
    (".turbo", &["package.json", "turbo.json"]),
    (".parcel-cache", &["package.json"]),
    ("target", &["Cargo.toml", "pom.xml"]),
    (".build", &["Package.swift"]),
    ("Pods", &["Podfile"]),
    (".venv", &["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"]),
    ("venv", &["pyproject.toml", "requirements.txt", "setup.py"]),
    ("__pycache__", &["pyproject.toml", "requirements.txt", "setup.py"]),
    (".pytest_cache", &["pyproject.toml", "pytest.ini", "setup.py"]),
    (".mypy_cache", &["pyproject.toml", "mypy.ini", "setup.py"]),
    (".ruff_cache", &["pyproject.toml", "ruff.toml"]),
    (".gradle", &["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
    (".dart_tool", &["pubspec.yaml"]),
    ("dist", &["package.json", "tsconfig.json", "vite.config.ts", "vite.config.js", "pyproject.toml"]),
    ("build", &["package.json", "build.gradle", "build.gradle.kts", "CMakeLists.txt", "pubspec.yaml"]),
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

// MARK: - Live Running-App & Installed-App Detection

#[cfg(target_os = "macos")]
fn collect_running_apps() -> RunningApps {
    let mut bundle_ids = HashSet::new();
    let mut app_names = HashSet::new();

    let count = unsafe { proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return RunningApps {
            bundle_ids,
            app_names,
        };
    }

    let mut pids = vec![0 as c_int; (count as usize) + 64];
    let filled = unsafe {
        proc_listallpids(
            pids.as_mut_ptr() as *mut c_void,
            (pids.len() * std::mem::size_of::<c_int>()) as c_int,
        )
    };
    if filled <= 0 {
        return RunningApps {
            bundle_ids,
            app_names,
        };
    }

    let mut seen_bundles: HashSet<PathBuf> = HashSet::new();
    let mut path_buf = vec![0u8; 4096];

    for &pid in &pids[..(filled as usize).min(pids.len())] {
        if pid <= 0 {
            continue;
        }
        let len = unsafe {
            proc_pidpath(
                pid,
                path_buf.as_mut_ptr() as *mut c_void,
                path_buf.len() as u32,
            )
        };
        if len <= 0 {
            continue;
        }
        let Ok(exec_path) = std::str::from_utf8(&path_buf[..(len as usize).min(path_buf.len())])
        else {
            continue;
        };
        if let Some(app_idx) = exec_path.find(".app/") {
            let bundle_path = PathBuf::from(&exec_path[..app_idx + 4]);
            seen_bundles.insert(bundle_path);
        }
    }

    for bundle_path in seen_bundles {
        if let Some(stem) = bundle_path.file_stem().and_then(|s| s.to_str()) {
            let lower = stem.to_ascii_lowercase();
            if !lower.is_empty() {
                app_names.insert(lower);
            }
        }
        let bid = read_bundle_id(&bundle_path);
        if !bid.is_empty() {
            bundle_ids.insert(bid.to_ascii_lowercase());
        }
    }

    RunningApps {
        bundle_ids,
        app_names,
    }
}

#[cfg(not(target_os = "macos"))]
fn collect_running_apps() -> RunningApps {
    RunningApps {
        bundle_ids: HashSet::new(),
        app_names: HashSet::new(),
    }
}

impl RunningApps {
    fn is_bundle_running(&self, candidate_lower: &str) -> bool {
        bundle_id_matches_set(candidate_lower, &self.bundle_ids)
    }

    fn is_app_name_running(&self, name_lower: &str) -> bool {
        if self.app_names.contains(name_lower) {
            return true;
        }
        for &(folder_key, bid) in APP_SUPPORT_BUNDLE_ALIASES {
            if folder_key == name_lower && self.is_bundle_running(bid) {
                return true;
            }
        }
        false
    }
}

fn collect_installed_bundle_ids(home_path: &Path) -> HashSet<String> {
    let mut app_paths: Vec<PathBuf> = Vec::new();
    let app_roots = [
        PathBuf::from("/Applications"),
        PathBuf::from("/System/Applications"),
        home_path.join("Applications"),
        PathBuf::from("/Applications/Setapp"),
    ];

    for root in app_roots {
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) == Some("app") {
                app_paths.push(p);
            } else if p.is_dir() {
                if let Ok(sub_entries) = fs::read_dir(&p) {
                    for sub in sub_entries.flatten() {
                        let sp = sub.path();
                        if sp.extension().and_then(|e| e.to_str()) == Some("app") {
                            app_paths.push(sp);
                        }
                    }
                }
            }
        }
    }

    for caskroom in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
        let Ok(tokens) = fs::read_dir(caskroom) else {
            continue;
        };
        for token_entry in tokens.flatten() {
            let Ok(versions) = fs::read_dir(token_entry.path()) else {
                continue;
            };
            for ver_entry in versions.flatten() {
                let Ok(items) = fs::read_dir(ver_entry.path()) else {
                    continue;
                };
                for item in items.flatten() {
                    let ip = item.path();
                    if ip.extension().and_then(|e| e.to_str()) == Some("app") {
                        app_paths.push(ip);
                    }
                }
            }
        }
    }

    app_paths
        .par_iter()
        .filter_map(|p| {
            let bid = read_bundle_id(p);
            if bid.is_empty() {
                None
            } else {
                Some(bid.to_ascii_lowercase())
            }
        })
        .collect()
}

fn is_reverse_dns_bundle_id(name: &str) -> bool {
    let segments: Vec<&str> = name.split('.').collect();
    if segments.len() < 3 {
        return false;
    }
    let first = segments[0];
    if first.len() < 2 || !first.bytes().all(|b| b.is_ascii_alphabetic()) {
        return false;
    }
    let has_alpha_tail = segments[1..]
        .iter()
        .any(|seg| seg.bytes().any(|b| b.is_ascii_alphabetic()));
    if !has_alpha_tail {
        return false;
    }
    segments.iter().all(|seg| {
        !seg.is_empty()
            && seg
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    })
}

fn bundle_id_matches_set(candidate_lower: &str, set: &HashSet<String>) -> bool {
    if set.contains(candidate_lower) {
        return true;
    }
    let cand_bytes = candidate_lower.as_bytes();
    for id in set {
        let id_bytes = id.as_bytes();
        if cand_bytes.len() > id_bytes.len()
            && cand_bytes[id_bytes.len()] == b'.'
            && &cand_bytes[..id_bytes.len()] == id_bytes
        {
            return true;
        }
        if id_bytes.len() > cand_bytes.len()
            && id_bytes[cand_bytes.len()] == b'.'
            && &id_bytes[..cand_bytes.len()] == cand_bytes
        {
            return true;
        }
    }
    false
}

// MARK: - Project Artifact Discovery (`mo purge` parity, bounded & safe)

fn scan_project_artifacts(
    home_path: &Path,
    started: Instant,
    out: &mut Vec<(String, PathBuf, bool)>,
) {
    let recent_cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(7 * 24 * 3600))
        .unwrap_or(SystemTime::UNIX_EPOCH);
    let budget = Duration::from_millis(250);
    let mut visited_roots: HashSet<(u64, u64)> = HashSet::new();

    for root_name in DEFAULT_PROJECT_ROOTS {
        if started.elapsed() > budget {
            break;
        }
        let root_path = home_path.join(root_name);
        let Ok(meta) = fs::symlink_metadata(&root_path) else {
            continue;
        };
        if meta.file_type().is_symlink() || !meta.is_dir() {
            continue;
        }
        // Deduplicate case-insensitive macOS APFS roots (e.g. ~/Projects vs ~/projects)
        if !visited_roots.insert((meta.dev(), meta.ino())) {
            continue;
        }
        walk_project_dir(&root_path, 0, recent_cutoff, started, budget, out);
    }
}

fn walk_project_dir(
    dir: &Path,
    depth: u8,
    recent_cutoff: SystemTime,
    started: Instant,
    budget: Duration,
    out: &mut Vec<(String, PathBuf, bool)>,
) {
    if depth > 4 || started.elapsed() > budget || out.len() >= 120 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };

    let mut subdirs: Vec<(String, PathBuf)> = Vec::new();
    let mut sibling_names: HashSet<String> = HashSet::new();

    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let p = entry.path();
        let Ok(meta) = fs::symlink_metadata(&p) else {
            continue;
        };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_file() {
            sibling_names.insert(name);
        } else if meta.is_dir() {
            subdirs.push((name, p));
        }
    }

    for (name, sub_path) in subdirs {
        if started.elapsed() > budget || out.len() >= 120 {
            return;
        }
        if name == ".git" || name == ".tmp" || name == "vendor" || name == ".Trash" {
            continue;
        }
        if let Some((_, markers)) = PROJECT_ARTIFACT_RULES.iter().find(|(art, _)| *art == name) {
            let has_marker = markers.iter().any(|m| sibling_names.contains(*m));
            // Never delete a directory that contains a nested .git repository
            if has_marker && !sub_path.join(".git").exists() {
                let is_recent = fs::symlink_metadata(&sub_path)
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .map_or(true, |mtime| mtime > recent_cutoff);
                let project_label = dir
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("project");
                out.push((format!("{}/{}", project_label, name), sub_path, is_recent));
                // Do not recurse inside matched artifact (avoids nested node_modules over-deletion)
                continue;
            }
        }

        if name.starts_with('.') {
            continue;
        }
        walk_project_dir(&sub_path, depth + 1, recent_cutoff, started, budget, out);
    }
}

// MARK: - Path Protection & Validation

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
        "/.orbstack",
        "/.cargo/bin",
        "/.rustup/toolchains",
        "/.yarn/berry",
        "/library/caches/yarn/berry",
        "/library/jupyter/runtime",
        "/library/keychains",
        "/library/messages/attachments",
        "/library/mail",
        "/library/caches/com.local.upkeep",
        "/library/caches/cloudkit",
        "/library/application support/steam",
        "/library/application support/epic",
        "/library/application support/com.apple.wallpaper",
        "/library/application support/com.apple.idleassetsd",
        "/library/application support/dock",
        "/library/application support/clouddocs",
        "/library/application support/addressbook",
        "/library/group containers/group.com.apple.notes",
        "/library/unity",
    ];
    for prefix in PROTECTED_PREFIXES {
        if rel_lower == *prefix || rel_lower.starts_with(&format!("{}/", prefix)) {
            return true;
        }
    }
    if let Some(cache_entry) = rel_lower.strip_prefix("/library/caches/") {
        if cache_entry.starts_with("com.apple.") {
            let is_safe_apple = SAFE_APPLE_CACHE_REL_PATHS.iter().any(|safe| {
                rel_lower == *safe || rel_lower.starts_with(&format!("{}/", safe))
            });
            if !is_safe_apple {
                return true;
            }
        }
    }
    if let Some(group_entry) = rel_lower.strip_prefix("/library/group containers/") {
        if group_entry.contains("dev.orbstack") || group_entry.starts_with("group.com.apple.") {
            return true;
        }
    }
    if let Some(container_entry) = rel_lower.strip_prefix("/library/containers/") {
        // Allow Mail Downloads cached attachment copies only
        if rel_lower.starts_with("/library/containers/com.apple.mail/data/library/mail downloads/")
        {
            return false;
        }
        for pref in PROTECTED_CONTAINER_PREFIXES {
            if container_entry.starts_with(pref) {
                return true;
            }
        }
    }
    false
}

/// Checks that no directory component strictly between `base` and `target` is a symlink.
fn has_symlinked_ancestor(path: &Path, base: &Path) -> bool {
    let mut current = path.parent();
    while let Some(dir) = current {
        if dir == base || dir.as_os_str().is_empty() {
            break;
        }
        if let Ok(meta) = fs::symlink_metadata(dir) {
            if meta.file_type().is_symlink() {
                return true;
            }
        }
        current = dir.parent();
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
    let raw_str = path.to_string_lossy();
    if raw_str.chars().any(|c| c.is_control()) {
        return Err("Path contains control characters".to_string());
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

    if !home_trimmed.is_empty()
        && raw_str.len() > home_trimmed.len()
        && raw_str.starts_with(home_trimmed)
        && raw_str.as_bytes()[home_trimmed.len()] == b'/'
    {
        if has_symlinked_ancestor(path, Path::new(home_trimmed)) {
            return Err("Refused to traverse symlinked ancestor directory".to_string());
        }
    } else if !tmp_trimmed.is_empty()
        && raw_str.len() > tmp_trimmed.len()
        && raw_str.starts_with(tmp_trimmed)
        && raw_str.as_bytes()[tmp_trimmed.len()] == b'/'
    {
        if has_symlinked_ancestor(path, Path::new(tmp_trimmed)) {
            return Err("Refused to traverse symlinked ancestor directory".to_string());
        }
    }

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
            "/library/application support/mobilesync",
            "/library/logs",
            "/library/saved application state",
            "/library/developer",
            "/library/developer/xcode",
            "/library/preferences",
            "/library/containers",
            "/library/group containers",
            "/library/messages",
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

        let preserve_parent = PRESERVE_PARENT_REL_PATHS.contains(&rel_lower.as_str())
            || (rel_lower.starts_with("/library/containers/")
                && rel_lower.ends_with("/data/library/caches"));
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

// MARK: - Comprehensive Safe Dry-Run Scanner (Full Mole Parity)

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

    // Collect running apps, installed bundle IDs, and project artifacts in parallel
    let ((running_apps, installed_bundle_ids), project_artifacts) = rayon::join(
        || {
            rayon::join(collect_running_apps, || {
                collect_installed_bundle_ids(&home_path)
            })
        },
        || {
            let mut found = Vec::new();
            scan_project_artifacts(&home_path, started, &mut found);
            found
        },
    );

    let mut targets: Vec<ScanTarget> = Vec::new();
    let mut seen_paths: HashSet<PathBuf> = HashSet::new();
    let mut seen_inodes: HashSet<(u64, u64)> = HashSet::new();

    let mut push_target = |cat_id: &'static str,
                           cat_title: &'static str,
                           name: String,
                           path: PathBuf,
                           default_selected: bool,
                           holdback_reason: Option<&'static str>,
                           requires_admin: bool| {
        let Ok(meta) = fs::symlink_metadata(&path) else {
            return;
        };
        if meta.file_type().is_symlink() {
            return;
        }
        if !requires_admin && is_protected_path(&path, &home) {
            return;
        }
        let dev_ino = (meta.dev(), meta.ino());
        if !seen_paths.insert(path.clone()) || !seen_inodes.insert(dev_ino) {
            return;
        }
        targets.push(ScanTarget {
            category_id: cat_id,
            category_title: cat_title,
            name,
            path,
            default_selected,
            holdback_reason,
            requires_admin,
        });
    };

    // 1. Developer Tools, Package Managers & AI/ML Caches
    let dev_specs: &[(&str, &str, bool, Option<&str>)] = &[
        ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData", true, None),
        ("Xcode Caches", "Library/Caches/com.apple.dt.Xcode", true, None),
        ("Xcode Products", "Library/Developer/Xcode/Products", true, None),
        (
            "SwiftUI Previews",
            "Library/Developer/Xcode/UserData/Previews/Simulator Devices",
            true,
            None,
        ),
        (
            "Xcode Archives",
            "Library/Developer/Xcode/Archives",
            false,
            Some("Removes archived app builds"),
        ),
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
        ("JetBrains Caches", "Library/Caches/JetBrains", true, None),
        ("Docker Buildx Cache", ".docker/buildx/cache", true, None),
        ("npm Cache", ".npm/_cacache", true, None),
        ("pnpm Store Cache", "Library/Caches/pnpm", true, None),
        ("Yarn Classic Cache", "Library/Caches/Yarn", true, None),
        ("Bun Install Cache", ".bun/install/cache", true, None),
        ("node-gyp Cache (Library)", "Library/Caches/node-gyp", true, None),
        ("node-gyp Cache (~/.cache)", ".cache/node-gyp", true, None),
        ("Electron Download Cache", "Library/Caches/electron", true, None),
        ("Deno Cache", ".cache/deno", true, None),
        ("TypeScript Cache", ".cache/typescript", true, None),
        ("pip Cache (Library)", "Library/Caches/pip", true, None),
        ("pip Cache (~/.cache)", ".cache/pip", true, None),
        ("uv Cache", ".cache/uv", true, None),
        ("Poetry Cache", "Library/Caches/pypoetry", true, None),
        ("Pipenv Cache", "Library/Caches/pipenv", true, None),
        ("Ruff Cache", ".cache/ruff", true, None),
        ("Mypy Cache", ".cache/mypy", true, None),
        ("pre-commit Cache", ".cache/pre-commit", true, None),
        ("Cargo Registry Cache", ".cargo/registry/cache", true, None),
        ("Cargo Extracted Sources", ".cargo/registry/src", true, None),
        ("Rustup Downloads", ".rustup/downloads", true, None),
        ("Gradle Caches", ".gradle/caches", true, None),
        ("Android Cache", ".android/cache", true, None),
        ("Android Build Cache", ".android/build-cache", true, None),
        (
            "Maven Repository",
            ".m2/repository",
            false,
            Some("Re-downloads Maven dependencies"),
        ),
        ("Go Build Cache", "Library/Caches/go-build", true, None),
        ("Playwright Browsers (Library)", "Library/Caches/ms-playwright", true, None),
        ("Playwright Browsers (~/.cache)", ".cache/ms-playwright", true, None),
        ("Puppeteer Cache", ".cache/puppeteer", true, None),
        ("Composer Cache", ".composer/cache", true, None),
        ("RubyGems Cache", ".gem/cache", true, None),
        ("pyenv Cache", ".pyenv/cache", true, None),
        ("nvm Cache", ".nvm/.cache", true, None),
        (
            "Hugging Face Hub Cache",
            ".cache/huggingface/hub",
            false,
            Some("Re-downloads Hugging Face models"),
        ),
        (
            "NuGet Packages",
            ".nuget/packages",
            false,
            Some("Re-downloads NuGet packages"),
        ),
        (
            "Dart / Flutter Pub Cache",
            ".pub-cache",
            false,
            Some("Re-downloads Dart/Flutter packages"),
        ),
    ];
    for &(name, rel, default_sel, holdback) in dev_specs {
        push_target(
            "developer_tools",
            "Developer Tools",
            name.to_string(),
            home_path.join(rel),
            default_sel,
            holdback,
            false,
        );
    }

    // 2. Browser Caches (Caches ONLY — never profiles, cookies, bookmarks, or sessions)
    let browser_specs: &[(&str, &str, &str)] = &[
        ("Google Chrome Cache", "Library/Caches/Google/Chrome", "com.google.chrome"),
        ("Brave Cache", "Library/Caches/BraveSoftware", "com.brave.browser"),
        ("Microsoft Edge Cache", "Library/Caches/Microsoft Edge", "com.microsoft.edgemac"),
        ("Arc Cache", "Library/Caches/company.thebrowser.Browser", "company.thebrowser.browser"),
        ("Firefox Cache", "Library/Caches/Firefox", "org.mozilla.firefox"),
        ("Zen Cache", "Library/Caches/zen", "app.zen-browser.zen"),
        ("Vivaldi Cache", "Library/Caches/Vivaldi", "com.vivaldi.vivaldi"),
        ("Opera Cache", "Library/Caches/com.operasoftware.Opera", "com.operasoftware.opera"),
    ];
    for &(name, rel, bid) in browser_specs {
        let is_running = running_apps.is_bundle_running(bid);
        push_target(
            "browser_caches",
            "Browser Caches",
            name.to_string(),
            home_path.join(rel),
            !is_running,
            if is_running {
                Some("Browser is currently running")
            } else {
                None
            },
            false,
        );
    }

    // 3. Electron & Chromium App Internal Caches
    let app_support_dir = home_path.join("Library/Application Support");
    if let Ok(entries) = fs::read_dir(&app_support_dir) {
        for entry in entries.flatten() {
            let app_dir = entry.path();
            let Ok(meta) = fs::symlink_metadata(&app_dir) else {
                continue;
            };
            if meta.file_type().is_symlink() || !meta.is_dir() {
                continue;
            }
            let app_name = entry.file_name().to_string_lossy().into_owned();
            let app_lower = app_name.to_ascii_lowercase();
            if app_name.starts_with('.')
                || app_lower.starts_with("com.apple.")
                || PROTECTED_APP_SUPPORT_NAMES.contains(&app_lower.as_str())
            {
                continue;
            }
            let is_running = running_apps.is_app_name_running(&app_lower)
                || running_apps.is_bundle_running(&app_lower);
            for &(leaf_rel, leaf_label) in ELECTRON_CACHE_LEAVES {
                let leaf_path = app_dir.join(leaf_rel);
                if leaf_path.exists() {
                    push_target(
                        "app_internal_caches",
                        "App Internal Caches",
                        format!("{} — {}", app_name, leaf_label),
                        leaf_path,
                        !is_running,
                        if is_running {
                            Some("App is currently running")
                        } else {
                            None
                        },
                        false,
                    );
                }
            }
        }
    }

    let orphan_cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(30 * 24 * 3600))
        .unwrap_or(SystemTime::UNIX_EPOCH);
    let temp_cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(24 * 3600))
        .unwrap_or(SystemTime::UNIX_EPOCH);
    let sys_age_cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(7 * 24 * 3600))
        .unwrap_or(SystemTime::UNIX_EPOCH);

    // 4. User App Caches (~/Library/Caches/*) + Orphaned Cache Detection
    let caches_dir = home_path.join("Library/Caches");
    if let Ok(entries) = fs::read_dir(&caches_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let lower = name.to_ascii_lowercase();
            if name.starts_with('.')
                || lower.starts_with("com.apple.")
                || lower == "cloudkit"
                || lower == "qlmanage"
                || lower == "homebrew"
                || lower == "com.local.upkeep"
                || lower == "org.swift.swiftpm"
                || lower == "cocoapods"
                || lower == "jetbrains"
                || lower == "pnpm"
                || lower == "yarn"
                || lower == "pip"
                || lower == "pypoetry"
                || lower == "pipenv"
                || lower == "node-gyp"
                || lower == "electron"
                || lower == "ms-playwright"
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
                        let is_android_studio = gname.to_ascii_lowercase().starts_with("androidstudio");
                        push_target(
                            if is_android_studio { "developer_tools" } else { "user_app_caches" },
                            if is_android_studio { "Developer Tools" } else { "User App Caches" },
                            format!("Google {}", gname),
                            ge.path(),
                            true,
                            None,
                            false,
                        );
                    }
                }
                continue;
            }

            let entry_path = entry.path();
            let is_running = running_apps.is_bundle_running(&lower)
                || running_apps.is_app_name_running(&lower);

            if !is_running
                && is_reverse_dns_bundle_id(&lower)
                && !installed_bundle_ids.is_empty()
                && !bundle_id_matches_set(&lower, &installed_bundle_ids)
            {
                let is_stale_30d = fs::symlink_metadata(&entry_path)
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .map_or(false, |mtime| mtime <= orphan_cutoff);
                if is_stale_30d {
                    push_target(
                        "orphaned_leftovers",
                        "Orphaned App Leftovers",
                        format!("{} (Cache)", name),
                        entry_path,
                        false,
                        Some("App not installed (30d+ inactive)"),
                        false,
                    );
                    continue;
                }
            }

            push_target(
                "user_app_caches",
                "User App Caches",
                name,
                entry_path,
                !is_running,
                if is_running {
                    Some("App is currently running")
                } else {
                    None
                },
                false,
            );
        }
    }

    // 4b. Sandboxed App Container Caches (~/Library/Containers/<bundle_id>/Data/Library/Caches)
    let containers_dir = home_path.join("Library/Containers");
    if let Ok(entries) = fs::read_dir(&containers_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let lower = name.to_ascii_lowercase();
            if name.starts_with('.')
                || PROTECTED_CONTAINER_PREFIXES
                    .iter()
                    .any(|pref| lower.starts_with(pref))
            {
                continue;
            }
            let container_cache = entry.path().join("Data/Library/Caches");
            if !container_cache.is_dir() {
                continue;
            }
            let is_running = running_apps.is_bundle_running(&lower);
            push_target(
                "user_app_caches",
                "User App Caches",
                format!("{} (Container)", name),
                container_cache,
                !is_running,
                if is_running {
                    Some("App is currently running")
                } else {
                    None
                },
                false,
            );
        }
    }

    // 5. macOS & Apple User Caches (Mole `user.sh` parity — safe caches only, never Mail data or Messages attachments)
    let macos_cache_specs: &[(&str, &str, bool, Option<&str>)] = &[
        ("QuickLook Thumbnails", "Library/Caches/com.apple.QuickLook.thumbnailcache", true, None),
        ("QuickLook Cache", "Library/Caches/qlmanage", true, None),
        ("Icon Services Cache", "Library/Caches/com.apple.iconservices.store", true, None),
        ("Safari Webpage Previews", "Library/Caches/com.apple.Safari/Webpage Previews", true, None),
        ("WebKit Network Cache", "Library/Caches/com.apple.WebKit.Networking", true, None),
        ("App Store Cache", "Library/Caches/com.apple.appstore", true, None),
        ("App Store Agent Cache", "Library/Caches/com.apple.appstoreagent", true, None),
        ("Media Analysis Cache", "Library/Caches/com.apple.mediaanalysisd", true, None),
        ("Photo Analysis Cache", "Library/Caches/com.apple.photoanalysisd", true, None),
        ("Siri Suggestions Cache", "Library/Caches/com.apple.parsecd", true, None),
        ("Siri Cache", "Library/Caches/com.apple.Siri", true, None),
        ("Calendar Cache", "Library/Caches/com.apple.iCal", true, None),
        ("Address Book Photo Cache", "Library/Caches/com.apple.AddressBookSourceSync", true, None),
        ("Messages Caches", "Library/Messages/Caches", true, None),
        ("Messages Sticker Cache", "Library/Messages/StickerCache", true, None),
        (
            "Autosave Information",
            "Library/Autosave Information",
            false,
            Some("Removes unsaved document autosaves"),
        ),
        (
            "iOS Device Backups",
            "Library/Application Support/MobileSync/Backup",
            false,
            Some("Deletes local iPhone/iPad backups"),
        ),
    ];
    for &(name, rel, default_sel, holdback) in macos_cache_specs {
        push_target(
            "macos_user_caches",
            "macOS & Apple Caches",
            name.to_string(),
            home_path.join(rel),
            default_sel,
            holdback,
            false,
        );
    }

    // Mail Downloads cached attachment copies (>30d old — never touches ~/Library/Mail messages)
    for mail_dl in [
        home_path.join("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
        home_path.join("Library/Mail Downloads"),
    ] {
        if let Ok(entries) = fs::read_dir(&mail_dl) {
            for entry in entries.flatten() {
                let p = entry.path();
                let Ok(meta) = fs::symlink_metadata(&p) else {
                    continue;
                };
                if meta.file_type().is_symlink() {
                    continue;
                }
                let modified = meta.modified().unwrap_or(SystemTime::now());
                if modified <= orphan_cutoff {
                    let fname = entry.file_name().to_string_lossy().into_owned();
                    push_target(
                        "macos_user_caches",
                        "macOS & Apple Caches",
                        format!("Mail Download: {}", fname),
                        p,
                        false,
                        Some("Cached Mail attachment copy (30d+)"),
                        false,
                    );
                }
            }
        }
    }

    // 6. Project Build Artifacts (`mo purge` parity — held back by default)
    for (label, art_path, is_recent) in project_artifacts {
        push_target(
            "project_artifacts",
            "Project Build Artifacts",
            label,
            art_path,
            false,
            if is_recent {
                Some("Active project (<7d)")
            } else {
                Some("Rebuildable project artifact (7d+ idle)")
            },
            false,
        );
    }

    // 7. Logs & Diagnostics
    let logs_dir = home_path.join("Library/Logs");
    if let Ok(entries) = fs::read_dir(&logs_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name.eq_ignore_ascii_case("DiagnosticReports") {
                continue;
            }
            push_target("logs_diagnostics", "Logs & Diagnostics", name, entry.path(), true, None, false);
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
                false,
            );
        }
    }
    let crash_dir = home_path.join("Library/Application Support/CrashReporter");
    if let Ok(entries) = fs::read_dir(&crash_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            let Ok(meta) = fs::symlink_metadata(&p) else {
                continue;
            };
            if meta.file_type().is_symlink() || !meta.is_file() {
                continue;
            }
            if meta.modified().unwrap_or(SystemTime::now()) <= orphan_cutoff {
                let name = entry.file_name().to_string_lossy().into_owned();
                push_target(
                    "logs_diagnostics",
                    "Logs & Diagnostics",
                    format!("CrashReporter: {}", name),
                    p,
                    true,
                    None,
                    false,
                );
            }
        }
    }

    // 8. Saved Application State (+ Orphaned Saved State), Incomplete Downloads & Stale Temp Files (>24h)
    let saved_state_dir = home_path.join("Library/Saved Application State");
    if let Ok(entries) = fs::read_dir(&saved_state_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !name.ends_with(".savedState") {
                continue;
            }
            let clean_name = name.trim_end_matches(".savedState").to_string();
            let clean_lower = clean_name.to_ascii_lowercase();
            let entry_path = entry.path();

            if !clean_lower.starts_with("com.apple.")
                && !running_apps.is_bundle_running(&clean_lower)
                && is_reverse_dns_bundle_id(&clean_lower)
                && !installed_bundle_ids.is_empty()
                && !bundle_id_matches_set(&clean_lower, &installed_bundle_ids)
            {
                let is_stale_30d = fs::symlink_metadata(&entry_path)
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .map_or(false, |mtime| mtime <= orphan_cutoff);
                if is_stale_30d {
                    push_target(
                        "orphaned_leftovers",
                        "Orphaned App Leftovers",
                        format!("{} (Saved State)", clean_name),
                        entry_path,
                        false,
                        Some("App not installed (30d+ inactive)"),
                        false,
                    );
                    continue;
                }
            }

            push_target(
                "saved_state_temp",
                "Saved State & Temp",
                clean_name,
                entry_path,
                false,
                Some("Resets open window positions"),
                false,
            );
        }
    }

    if let Ok(tmpdir) = std::env::var("TMPDIR") {
        let tmp_path = PathBuf::from(&tmpdir);
        let my_uid = unsafe { getuid() };
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
                if modified > temp_cutoff {
                    continue;
                }
                push_target(
                    "saved_state_temp",
                    "Saved State & Temp",
                    format!("Temp: {}", name),
                    p,
                    true,
                    None,
                    false,
                );
            }
        }
    }

    // 9. Incomplete Downloads (>24h) & Old Installers (.dmg/.pkg/.mpkg/.iso/.xip >24h) in Downloads & Desktop
    for (dir_label, scan_dir) in [
        ("Downloads", home_path.join("Downloads")),
        ("Desktop", home_path.join("Desktop")),
    ] {
        if let Ok(entries) = fs::read_dir(&scan_dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                let Some(ext) = p.extension().and_then(|e| e.to_str()) else {
                    continue;
                };
                let ext_lower = ext.to_ascii_lowercase();
                let Ok(meta) = fs::symlink_metadata(&p) else {
                    continue;
                };
                if meta.file_type().is_symlink() {
                    continue;
                }
                let modified = meta.modified().unwrap_or(SystemTime::now());
                if modified > temp_cutoff {
                    continue;
                }
                let name = entry.file_name().to_string_lossy().into_owned();
                if INCOMPLETE_DOWNLOAD_EXTENSIONS.contains(&ext_lower.as_str()) {
                    push_target(
                        "saved_state_temp",
                        "Saved State & Temp",
                        format!("Incomplete Download: {}", name),
                        p,
                        false,
                        Some("Stale incomplete browser download"),
                        false,
                    );
                } else if meta.is_file() && INSTALLER_EXTENSIONS.contains(&ext_lower.as_str()) {
                    push_target(
                        "old_installers",
                        "Old Installers",
                        if dir_label == "Desktop" {
                            format!("{} (Desktop)", name)
                        } else {
                            name
                        },
                        p,
                        false,
                        Some("Installer archive"),
                        false,
                    );
                }
            }
        }
    }

    // 10. System Caches, Logs & Orphaned System Services (Mole `system.sh` + `apps.sh` parity, requires Admin)
    let system_dir_targets: &[(&str, &str)] = &[
        ("CoreSimulator dyld Caches", "/Library/Developer/CoreSimulator/Caches/dyld"),
        ("System Diagnostic Reports", "/Library/Logs/DiagnosticReports"),
        ("macOS Unified Logs (Special)", "/private/var/db/diagnostics/Special"),
        ("macOS Unified Logs (Persist)", "/private/var/db/diagnostics/Persist"),
        ("DiagnosticPipeline Logs", "/private/var/db/DiagnosticPipeline"),
        ("Memory Exception Reports", "/private/var/db/reportmemoryexception"),
    ];
    for &(name, sys_path) in system_dir_targets {
        let p = PathBuf::from(sys_path);
        if p.is_dir() {
            push_target(
                "system_caches",
                "System Caches & Logs (Admin)",
                name.to_string(),
                p,
                false,
                Some("Requires administrator password"),
                true,
            );
        }
    }

    // Stale files (>7d) in /private/var/log (*.log, *.gz, *.asl), /private/tmp, /private/var/tmp, /Library/Caches (*.cache, *.tmp, *.log)
    for (label, dir_str, allowed_exts) in [
        ("System Log", "/private/var/log", &["log", "gz", "asl"][..]),
        ("System Cache File", "/Library/Caches", &["cache", "tmp", "log"][..]),
        ("System Temp", "/private/tmp", &[][..]),
        ("System Var Temp", "/private/var/tmp", &[][..]),
    ] {
        if let Ok(entries) = fs::read_dir(dir_str) {
            for entry in entries.flatten() {
                let p = entry.path();
                let Ok(meta) = fs::symlink_metadata(&p) else {
                    continue;
                };
                if meta.file_type().is_symlink() || !meta.is_file() {
                    continue;
                }
                if !allowed_exts.is_empty() {
                    let ext = p
                        .extension()
                        .and_then(|e| e.to_str())
                        .map(|s| s.to_ascii_lowercase())
                        .unwrap_or_default();
                    if !allowed_exts.contains(&ext.as_str()) {
                        continue;
                    }
                }
                if meta.modified().unwrap_or(SystemTime::now()) <= sys_age_cutoff {
                    let fname = entry.file_name().to_string_lossy().into_owned();
                    push_target(
                        "system_caches",
                        "System Caches & Logs (Admin)",
                        format!("{}: {}", label, fname),
                        p,
                        false,
                        Some("Requires administrator password"),
                        true,
                    );
                }
            }
        }
    }

    // Power logs (/private/var/db/powerlog) — strictly skipping live Current* databases & -wal/-shm companions
    if let Ok(entries) = fs::read_dir("/private/var/db/powerlog") {
        for entry in entries.flatten() {
            let p = entry.path();
            let fname = entry.file_name().to_string_lossy().into_owned();
            let lower = fname.to_ascii_lowercase();
            if fname.starts_with('.')
                || lower.starts_with("current")
                || lower.ends_with("-wal")
                || lower.ends_with("-shm")
            {
                continue;
            }
            let Ok(meta) = fs::symlink_metadata(&p) else {
                continue;
            };
            if meta.file_type().is_symlink() || !meta.is_file() {
                continue;
            }
            if meta.modified().unwrap_or(SystemTime::now()) <= sys_age_cutoff {
                push_target(
                    "system_caches",
                    "System Caches & Logs (Admin)",
                    format!("Power Log: {}", fname),
                    p,
                    false,
                    Some("Requires administrator password"),
                    true,
                );
            }
        }
    }

    // Orphaned system LaunchDaemons / LaunchAgents (non-Apple, readable plist whose absolute Program binary no longer exists)
    for sys_launch_dir in ["/Library/LaunchDaemons", "/Library/LaunchAgents"] {
        if let Ok(entries) = fs::read_dir(sys_launch_dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                let fname = entry.file_name().to_string_lossy().into_owned();
                let lower = fname.to_ascii_lowercase();
                if !lower.ends_with(".plist") || lower.starts_with("com.apple.") {
                    continue;
                }
                let Ok(parsed) = plist::from_file::<_, SystemLaunchPlist>(&p) else {
                    continue; // fail closed on unreadable/root-only plists
                };
                let program = parsed
                    .program
                    .as_deref()
                    .or_else(|| parsed.program_arguments.as_ref().and_then(|v| v.first()).map(String::as_str));
                let Some(prog_path) = program else {
                    continue;
                };
                if !prog_path.starts_with('/')
                    || prog_path.starts_with("/usr/")
                    || prog_path.starts_with("/bin/")
                    || prog_path.starts_with("/sbin/")
                    || prog_path.starts_with("/System/")
                    || prog_path.starts_with("/opt/homebrew/")
                {
                    continue;
                }
                if !Path::new(prog_path).exists() {
                    push_target(
                        "orphaned_leftovers",
                        "Orphaned App Leftovers",
                        format!("Orphaned Service: {}", fname),
                        p,
                        false,
                        Some("Missing binary · Requires administrator password"),
                        true,
                    );
                }
            }
        }
    }

    // 11. User Trash (optional, unchecked by default)
    push_target(
        "user_trash",
        "Trash",
        "User Trash".to_string(),
        home_path.join(".Trash"),
        false,
        Some("Permanently empties Trash"),
        false,
    );

    // Parallel APFS sizing via getattrlistbulk + Rayon
    let scored: Vec<(&'static str, CleanerItem)> = targets
        .into_par_iter()
        .filter_map(|target| {
            let size = calculate_path_size_accurate(&target.path);
            if size < 4096 && !target.requires_admin {
                return None;
            }
            if size == 0 {
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
                    requires_admin: target.requires_admin,
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
        assert!(validate_clean_target(Path::new("/Users/tester/Library/Caches/bad\nname"), home, tmp).is_err());
        assert!(is_cleaner_protected_rel("/.yarn/berry/cache"));
        assert!(is_cleaner_protected_rel("/library/jupyter/runtime"));
        assert!(is_cleaner_protected_rel("/library/mail/v10"));
        assert!(is_cleaner_protected_rel("/library/messages/attachments/00"));
        assert!(is_cleaner_protected_rel("/library/application support/com.apple.wallpaper/aerials"));
        assert!(is_cleaner_protected_rel("/library/containers/com.docker.docker/data/library/caches"));
        assert!(is_cleaner_protected_rel("/.orbstack/data"));
        assert!(!is_cleaner_protected_rel("/library/caches/com.apple.quicklook.thumbnailcache"));
        assert!(!is_cleaner_protected_rel("/library/containers/com.apple.mail/data/library/mail downloads/report.pdf"));
    }

    #[test]
    fn reverse_dns_and_boundary_matching() {
        assert!(is_reverse_dns_bundle_id("com.spotify.client"));
        assert!(!is_reverse_dns_bundle_id("v1.2.3"));
        assert!(!is_reverse_dns_bundle_id("Homebrew"));

        let mut installed = HashSet::new();
        installed.insert("com.example.app".to_string());
        assert!(bundle_id_matches_set("com.example.app", &installed));
        assert!(bundle_id_matches_set("com.example.app.shipit", &installed));
        assert!(!bundle_id_matches_set("com.example.app2", &installed));
    }

    #[test]
    fn cleans_temp_target_and_rejects_symlink_and_symlinked_ancestor() {
        let base = std::env::temp_dir().join(format!("upkeep_cleaner_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();

        let file_a = base.join("stale_cache.bin");
        fs::write(&file_a, vec![42u8; 8192]).unwrap();

        let link_b = base.join("sneaky_link");
        symlink(&file_a, &link_b).unwrap();

        let real_dir = base.join("real_dir");
        fs::create_dir_all(&real_dir).unwrap();
        let nested_file = real_dir.join("inner.bin");
        fs::write(&nested_file, vec![7u8; 4096]).unwrap();
        let linked_dir = base.join("linked_dir");
        symlink(&real_dir, &linked_dir).unwrap();
        let via_linked_ancestor = linked_dir.join("inner.bin");

        let tmp_str = base.to_string_lossy().into_owned();
        let home_str = "/Users/nonexistent_test_home";

        assert!(validate_clean_target(&link_b, home_str, &tmp_str).is_err());
        assert!(validate_clean_target(&via_linked_ancestor, home_str, &tmp_str).is_err());

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
