## What's New in v1.2.0

- **Native Rust App & System Cleaner (Zero `mo` Dependency)**: Replaced the external `mo` (Mole) CLI completely with a built-in parallel Rust cleaner (`upkeep_scan_cleaner_json` / `upkeep_clean_paths_json`) covering Developer Tools (Xcode DerivedData, DeviceSupport, CoreSimulator, Homebrew, SwiftPM, CocoaPods, npm, pnpm, Yarn, Bun, pip, uv, Cargo, Gradle, Maven, Go), Browser Caches (Chrome, Brave, Edge, Arc, Firefox, Zen, Vivaldi, Opera — caches only), User App Caches, Logs & Diagnostics, Saved Application State & stale temp files, and Trash.
- **Interactive macOS 27 Cleaner Workspace**: Upgraded the Cleaner pane with collapsible grouped categories, per-category and per-item checkboxes, live selected-size badge, held-back amber pills for optional items, Reveal-in-Finder buttons, and strict Rust safety guards (canonical path allowlist, symlink refusal, protected-path exclusions, and parent-directory preservation).
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
