## What's New in v1.4.1

- **Live, Jitter-Free Caffeinate Menu Bar Countdown**:
  - Fixed the Caffeinate timer inside the menu bar dropdown not updating after launch by backing `formattedRemaining` with a lightweight observable `Timer` on `RunLoop.main`.
  - Scheduled the timer on `RunLoop.Mode.default` (pausing during `NSMenu` `.eventTracking`) so the countdown is always fresh to the second whenever you open the menu, while hovering over the **Caffeinate ▸** submenu stays rock-solid without collapsing or resizing the menu.
  - Applied monospaced digits to the `Caffeinate` and `Clean Keys` menu labels and simplified the top status header to prevent horizontal menu jitter.
- **Full Mole v1.74 Cleaner & Uninstaller Parity**:
  - **Opt-In Admin Removal of Uninstaller System Leftovers**: System remnants (`/Library/LaunchDaemons`, `/Library/LaunchAgents`, `/Library/PrivilegedHelperTools`, `/Library/Application Support`, `/Library/Caches`, `/Library/Logs`, `/Library/Preferences`, `/Users/Shared`, `/private/var/db/receipts`) are now toggleable in the Uninstaller review sheet with purple **Admin** badges, validated against a strict allowlist, unloaded via `launchctl bootout system`, and removed in a single native administrator prompt, followed by targeted `lsregister -u` on the removed bundle.
  - **Deeper App & Helper Discovery**: Reads `CFBundleName` and `CFBundleDisplayName` (catching apps like `Alfred 4.app` → `Alfred`), scans 1-level `/Applications` and `~/Applications` subfolders (Setapp, Utilities, Adobe), expands embedded helper bundle ID scanning (`Contents/Preferences`, `SharedSupport`, `QuickLook`, `Spotlight`), and adds `SplashBoard/Snapshots`, `KSCrash`, `SentryCrash`, `CrashReporter`, `DiagnosticReports`, and boundary-matched `Application Support/FileProvider` leftovers.
  - **iOS Simulator Per-Device & Browser Update Clone Cleanup**: Scans shut-down (`state == 1`) CoreSimulator devices' `data/{tmp,Library/Caches,Library/Logs}` when Simulator isn't running, plus Chromium `.code_sign_clone` update leftovers (Chrome, Brave, Edge, Helium) in `~/Library/Caches` and `$TMPDIR`.
  - **Expanded Developer, App & Orphan Coverage**: Added Bazel, Zig, sccache, ccache, Turborepo, esbuild, Biome, Prisma, Conda, Coursier, Ivy2, XCTest, Xcode iOS Device Logs, npm `_logs`, Vesktop `sessionData`, T3 Code preview partitions & `.t3/worktrees`, Adobe Media Cache, Apple Maps `GeoServices`, `com.apple.helpd`, and 30d+ deep-stale orphaned `~/Library/Logs`, `~/Library/HTTPStorages`, and `~/Library/WebKit` leftovers.
  - **Hardened Live-App & Safety Protections**: Added Chromium/Electron `SingletonLock` live-PID detection, 30-day deep child mtime checks for orphan detection, protected `~/Library/Caches/llama.cpp` and `~/Library/Caches/Buzz`, and held back Playwright/Puppeteer browser binaries, Raycast clipboard history cache, Mullvad Browser profile cache, and Spotify offline data.
- **Rust & APFS Performance Optimizations**:
  - Replaced the shared `Mutex<HashSet>` in `getattrlistbulk` APFS sizing with a lock-free `SizeAcc` accumulator and reusable `DfsArena` buffer (zero per-directory heap allocations).
  - Added a 36-character UUID filter before reading `.com.apple.containermanagerd.metadata.plist` (skipping hundreds of named containers for 5x–10x faster uninstaller inspection) and overlapped sibling-app + Homebrew Caskroom checks via `rayon::join`.
  - Replaced O(N) bundle-ID lookups with binary-searched `BundleIdIndex`, reused `symlink_metadata` file sizes (`known_file_size`), parallelized `collect_running_apps`, `scan_project_artifacts`, and parent-preserved folder deletion, and skipped post-delete recounts when all children delete cleanly.

### Included from v1.3.0

- **Complete Mole-Parity macOS Cleaner (12 Categories, Zero External CLI)**: Expanded Upkeep's native Rust Cleaner to cover every macOS cleanup surface in Mole (`mo clean`, `mo purge`, and `mo installer`) in one interactive workspace:
  - **System Caches & Logs (Admin)**: Opt-in, allowlisted system cleanup (`/Library/Developer/CoreSimulator/Caches/dyld`, `/Library/Logs/DiagnosticReports`, `/private/var/db/diagnostics/{Special,Persist}`, `/private/var/db/DiagnosticPipeline`, `/private/var/db/reportmemoryexception`, stale `/private/var/log`, `/Library/Caches`, `/private/tmp`, `/private/var/tmp`, and `/private/var/db/powerlog` excluding live `Current*` PerfPowerTelemetry databases) executed via a single native macOS administrator authorization prompt only when admin items are selected.
  - **Project Build Artifacts (`mo purge` Parity)**: Safely discovers rebuildable `node_modules`, `target`, `.build`, `Pods`, `.venv`, `venv`, `__pycache__`, `.next`, `.nuxt`, `.svelte-kit`, `.turbo`, `.parcel-cache`, `.gradle`, `.dart_tool`, `dist`, and `build` directories across standard developer roots (`~/Projects`, `~/projects`, `~/Developer`, `~/Code`, `~/GitHub`, `~/dev`, etc.) with sibling project-marker validation, nested `.git` protection, and 7-day activity badges (held back by default).
  - **macOS & Apple User Caches**: QuickLook thumbnails/cache, Icon Services cache, Safari Webpage Previews, WebKit Network cache, App Store cache, Media/Photo Analysis caches, Siri/Calendar/Address Book caches, Messages sticker/preview caches (never touching `~/Library/Messages/Attachments`), 30d+ Mail Downloads attachment copies (never touching `~/Library/Mail`), Autosave Information (held back), and local iOS Device Backups (held back).
  - **Electron/Chromium App Internal Caches & Sandboxed Container Caches**: Targets exact disposable cache leaves (`Cache`, `Code Cache`, `GPUCache`, `Dawn*`, `CachedData`, `Service Worker/CacheStorage`, `Crashpad/completed`) in `~/Library/Application Support/<App>/` and `~/Library/Containers/<bundle_id>/Data/Library/Caches`.
  - **Orphaned App Leftovers & System Services**: Detects 30d+ inactive caches/saved states from uninstalled apps (cross-checked against `/Applications`, `/System/Applications`, `~/Applications`, Setapp, and Homebrew Caskroom) plus orphaned non-Apple `/Library/LaunchDaemons` & `/Library/LaunchAgents` whose target binaries no longer exist (Admin).
  - **Incomplete Downloads & Old Installers**: Surfaces stale `.crdownload`/`.download`/`.part` files (>24h) and `.dmg`/`.pkg`/`.mpkg`/`.iso`/`.xip` installer archives in `~/Downloads` and `~/Desktop` (held back by default).
  - **Live Running-App Protection & Hardened Safety Guards**: Uses macOS `libproc` (`proc_listallpids` + `proc_pidpath`) to automatically hold back caches of currently running apps/browsers, plus device/inode deduplication, ancestor-symlink and control-character rejection, and explicit protection for Yarn Berry, Jupyter runtime, macOS aerial wallpapers, OrbStack/Docker/VM state, Keychains, Apple Notes, Messages attachments, and independent CLI directories.

### Included from v1.2.0

- **Native Rust App & System Cleaner (Zero `mo` Dependency)**: Replaced the external `mo` (Mole) CLI completely with a built-in parallel Rust cleaner (`upkeep_scan_cleaner_json` / `upkeep_clean_paths_json`).
- **Interactive macOS 27 Cleaner Workspace**: Collapsible grouped categories, per-category and per-item checkboxes, live selected-size badge, `Admin` and `Held back` pills, and Reveal-in-Finder buttons.
- **Compact Binary Homebrew Index Cache (`catalog.bin`)**: Persists the ~15k Homebrew API catalog in a lightweight versioned binary format for `<5 ms` cold startup, with automatic ETag `304` revalidation and in-place Cellar/Caskroom merging.
- **Rust & Swift Performance Optimizations**:
  - Eliminated the duplicate local Rust search index and double JSON round-trip by routing local searches directly through `rustRemoteIndex` (`installed_only` scoped search).
  - Enabled NEON/SIMD byte scanning via `memchr` (`memchr`, `memchr2`, `memmem`) for ANSI ESC checks, XML plist scanning, and case-insensitive substring search.
  - Replaced deep `PathBuf` allocations in `macos_bulk` (`getattrlistbulk`) with zero-`PathBuf` `openat` DFS and a single-FD deep fallback.
  - Short-circuited Tier 5 description scoring inside each `par_chunks(512)` worker once top-K name matches are full.
  - Pre-formatted `formattedSize` once at initialization on `MoleInstalledApp`, `UninstallLeftoverItem`, and `CleanerItem` to eliminate per-row `ByteCountFormatter` work during scrolling.

### Included from v1.1.2

- **Minimalist Native macOS Settings UI**: Redesigned the Settings window with a cleaner `216pt` sidebar, seamless transparent titlebar, centered `620pt` grouped reading columns, Canapé-style pane headers, inline `(i)` popovers, and zero per-row icon clutter.
- **Tiered Homebrew Search Ranking**: Upgraded the Rust and Swift search engines with 5-tier name-first scoring (Exact > Prefix > Substring > Fuzzy Name > Description) and cleaner cask version display so exact/prefix package names always rank first.
- **Larger macOS 27 HUD Buttons & Connected Settings Downloader**: Upgraded the floating Homebrew HUD to `.controlSize(.large)` Liquid Glass buttons with live operation spinners, and revamped the Homebrew Settings pane into a live inline search & package downloader sharing the same Rust index and live progress state as the HUD.

### Included from v1.1.1

- **Homebrew Search HUD Fix**: Fixed an issue where opening or switching to the **Casks** (`⌘3`) or **Formulae** (`⌘2`) search tabs without typing a query showed a pre-selected installed package instead of an empty search prompt, and reset HUD state cleanly when reopened.

### Included from v1.1.0

- **Mole-Parity Deep Uninstaller**: Native Rust leftover engine covering naming variants, channel/version suffix stripping, camelCase bundle-leaf splitting, embedded `.appex`/`.xpc`/`LoginItems` IDs, `Group Containers` (`<TeamID>.` boundary matching), UUID sandbox containers (`MCMMetadataIdentifier`), `ByHost`/`Cookies`/`HTTPStorages`/`sfl{2,3,4}`/`ShipIt`/crash reporters/`NativeMessagingHosts`/XDG/plug-ins, vendor-nested folders, special-app rules (VS Code, Xcode, JetBrains, Android Studio, Claude Desktop, Docker, Anki, Godot), `LaunchAgents` `Program`/`ProgramArguments[0]` ownership matching + `launchctl bootout`, and read-only system remnant detection (`/Library/*`, `/Users/Shared`, `/private/var/db/receipts`).
- **Built-In Safety Guards**:
  - **Sibling-App Protection**: Automatically detects co-installed channels/copies (e.g., *Zed* + *Zed Nightly*, *VS Code* + *VS Code Insiders*) and skips shared folders and Homebrew `--zap`.
  - **Independent CLI & Shared-Root Protection**: Preserves independent CLI data directories (Claude Code, Codex, Gemini, OpenCode), Steam, Epic, Unity, and shared XDG roots.
  - **Personal-Data Holdbacks**: Browser profiles, `Group Containers`, and VM/game libraries start **unchecked by default** with `Held back` badges and one-click **Reveal in Finder**.
  - **Official Uninstaller Warnings**: Flags security, MDM, and VPN suites (CrowdStrike, Jamf, SentinelOne, ESET, GlobalProtect, Cisco Secure Client, Malwarebytes, TeamViewer, etc.) to recommend their official vendor uninstallers.
- **Rust + SwiftUI Performance Overhaul**: macOS `getattrlistbulk` APFS sizing, zero-copy raw-byte Homebrew JSON API ingestion, ~5 ms in-place local Cellar/Caskroom refresh, instant native cache scanning (~50–150 ms), two-phase Uninstaller app loading (<15 ms first paint), and live streaming output for Homebrew and Cleaner.
