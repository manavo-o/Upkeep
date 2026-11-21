<p align="center">
  <img src="Resources/Icons/AppIcon.png" width="120" height="120" alt="Upkeep App Icon" />
</p>

<h1 align="center">Upkeep</h1>

<p align="center">
  <strong>A fast, native macOS menu-bar toolkit for power control, Homebrew management, deep disk cleaning, and complete app uninstallation.</strong><br/>
  <code>macOS 26+ Liquid Glass</code> · <code>Swift 6</code> · <code>Rust upkeep_core</code> · <code>v1.3.0</code>
</p>

Upkeep sits quietly in your macOS menu bar and opens into a native Liquid Glass workspace modeled on System Settings. Everything runs locally with **zero third-party cleaner dependencies**: a Swift 6 / SwiftUI / AppKit interface paired with a Rust static library (`libupkeep_core.a`) for APFS-accurate disk sizing, sub-millisecond fuzzy search, parallel cache cleaning, and deep leftover discovery.

## Features at a Glance

| Module | What It Does |
| --- | --- |
| **Power & Input** | Native IOKit **Caffeinate** (Display & System or System Only) + **Clean Keys** keyboard & trackpad lock with screen dimming and emergency unlock failsafes. |
| **Homebrew** | Floating Liquid Glass **Search HUD** + unified Settings downloader over ~15,000 formulae & casks (`<5 ms` binary cache startup) with live streaming logs. |
| **Cleaner** | Native parallel Rust cleaner across **12 categories** — user, browser, Electron/Chromium, sandboxed container, Apple/macOS, 49 dev/AI/ML caches, project build artifacts, orphaned leftovers, old installers, and opt-in Admin system caches. |
| **Uninstaller** | Two-phase `<15 ms` app scanner + deep leftover inspector with Homebrew Caskroom `--zap` detection, sibling-app protection, and personal-data holdbacks. |
| **Updates & Diagnostics** | Built-in GitHub Releases auto-updater (`manavo-o/Upkeep`), `brew update` runner, Accessibility permission checks, and `⌘F` settings search. |

## Inside Upkeep

### 1. Power & Input
- **Caffeinate (Keep Mac Awake)**: Uses native macOS IOKit power assertions (`IOPMAssertionCreateWithName`) with no background subprocesses. Pick **Display & System** or **System Only**, choose quick presets (`30m`, `1h`, `2h`, `Indefinite`), extend by `+30m` in one click, and track remaining time from a live badge.
- **Clean Keys (Keyboard & Pointer Lock)**: Uses a CoreGraphics event tap to block accidental keystrokes (and optionally trackpad/pointer input) while you wipe down your MacBook. Includes configurable timers (`30s`, `60s`, `2m`), **Dim Screen While Locked**, and two hardware-safe emergency exits: **hold `⌘ + Esc` for 1 second** or **press `⌘` six times**.

### 2. Homebrew Search HUD & Package Manager
- **Instant Rust Catalog Index**: Persists Homebrew's ~15k `formula.json` / `cask.json` catalog in a compact versioned binary cache (`catalog.bin`) for `<5 ms` cold startup, revalidates quietly via HTTP `ETag` (`304 Not Modified`), and refreshes local `Cellar`/`Caskroom`/pinned state directly from disk in ~5 ms without invoking Ruby.
- **Tiered Name-First Search**: 5-tier ranking (Exact > Prefix > Substring > Fuzzy Name > Description) powered by `nucleo-matcher` and `memchr` NEON/SIMD byte scanning, shared between the floating Liquid Glass Search HUD and the Settings **Homebrew** pane.
- **Full Package Lifecycle**: Switch scopes (`Installed`, `Formulae`, `Casks`, `Upgrades`), open `⌘K` actions (**Install**, **Upgrade**, **Pin / Unpin**, **Uninstall**, **Homepage**), and inspect persisted live logs from `brew install`, `brew upgrade`, `brew uninstall`, and `brew doctor`.

### 3. Native Rust Cleaner (12 Categories)
Built directly into `upkeep_core` using macOS `getattrlistbulk` + `O_NOFOLLOW` + Rayon parallelism, Upkeep previews every reclaimable item with checkboxes, category totals, amber `Held back` pills, purple `Admin` pills, and one-click **Reveal in Finder** before deleting anything:

1. **Developer Tools (49 targets)** — Xcode (`DerivedData`, Caches, Products, SwiftUI Previews, held-back Archives & iOS/watchOS/tvOS DeviceSupport), CoreSimulator, Homebrew, SwiftPM, CocoaPods, JetBrains, Android Studio, Docker Buildx cache, npm, pnpm, Yarn Classic, Bun, `node-gyp`, Electron, Deno, TypeScript, pip, uv, Poetry, Pipenv, Ruff, Mypy, `pre-commit`, Cargo (`cache` & `src`), Rustup downloads, Gradle, Maven (held back), Go build cache, Playwright, Puppeteer, Composer, RubyGems, `pyenv`, `nvm`, Hugging Face Hub (held back), NuGet (held back), and Dart/Flutter Pub Cache (held back).
2. **Browser Caches** — Chrome, Brave, Edge, Arc, Firefox, Zen, Vivaldi, and Opera (**caches only** — never touches profiles, history, cookies, passwords, or sessions).
3. **App Internal Caches** — Exact disposable Electron/Chromium cache leaves (`Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `CachedData`, `Service Worker/CacheStorage`, `Crashpad/completed`) inside `~/Library/Application Support/<App>/`.
4. **User App & Sandboxed Container Caches** — `~/Library/Caches/*` and third-party `~/Library/Containers/<bundle_id>/Data/Library/Caches` (preserving parent directories).
5. **macOS & Apple Caches** — QuickLook thumbnails & cache, Icon Services, Safari Webpage Previews, WebKit Network cache, App Store caches, Media/Photo Analysis, Siri/Calendar/Address Book caches, Messages sticker/preview caches, 30d+ Mail Downloads attachment copies (held back), Autosave Information (held back), and local iOS Device Backups (held back).
6. **Project Build Artifacts** — Bounded, marker-verified discovery of rebuildable `node_modules`, `target`, `.build`, `Pods`, `.venv`, `venv`, `__pycache__`, `.next`, `.nuxt`, `.svelte-kit`, `.turbo`, `.parcel-cache`, `.gradle`, `.dart_tool`, `dist`, and `build` folders across standard developer roots (`~/Projects`, `~/Developer`, `~/Code`, `~/GitHub`, `~/dev`, etc.) with nested `.git` protection and 7-day activity badges (held back by default).
7. **Orphaned App Leftovers** — 30d+ inactive caches and saved states whose reverse-DNS bundle ID is no longer installed across `/Applications`, `/System/Applications`, `~/Applications`, Setapp, or Homebrew Caskroom, plus orphaned non-Apple `/Library/LaunchDaemons` & `/Library/LaunchAgents` whose target binaries no longer exist (`Admin`).
8. **Logs & Diagnostics** — `~/Library/Logs`, `DiagnosticReports`, and 30d+ `CrashReporter` entries.
9. **Saved State, Temp & Incomplete Downloads** — `Saved Application State` (held back), user-owned `$TMPDIR` files >24h old, and stale `.crdownload` / `.download` / `.part` files >24h old.
10. **Old Installers** — `.dmg`, `.pkg`, `.mpkg`, `.iso`, and `.xip` files older than 24h in `~/Downloads` and `~/Desktop` (held back).
11. **System Caches & Logs (Admin)** — Opt-in allowlisted system cleanup (`/Library/Developer/CoreSimulator/Caches/dyld`, `/Library/Logs/DiagnosticReports`, `/private/var/db/diagnostics/{Special,Persist}`, `/private/var/db/DiagnosticPipeline`, `/private/var/db/reportmemoryexception`, stale `/private/var/log`, `/Library/Caches`, `/private/tmp`, `/private/var/tmp`, and `/private/var/db/powerlog` excluding live `Current*` PerfPowerTelemetry files). Only prompts for an administrator password when you explicitly select Admin items.
12. **Trash** — `~/.Trash` (held back by default).

### 4. Deep App Uninstaller
- **Two-Phase Discovery**: Lists apps in `/Applications` and `~/Applications` with bundle IDs in `<15 ms`, then fills APFS-accurate sizes concurrently.
- **Comprehensive Leftover Inspector**: Discovers `Application Support`, `Caches`, `Preferences`, `ByHost`, `SyncedPreferences`, `Logs`, `Containers`, UUID sandbox containers (`MCMMetadataIdentifier`), `Group Containers` (`<TeamID>.` boundary matching), `HTTPStorages`, `WebKit`, `Cookies`, `Saved Application State`, `Autosave Information`, `FileProvider`, `ApplicationRecentDocuments` (`.sfl2`–`.sfl4`), `ShipIt`/updaters, crash reporters, `NativeMessagingHosts`, plug-ins, vendor-nested folders, special-app rules (VS Code, Xcode, JetBrains, Android Studio, Claude Desktop, Docker, Anki, Godot), and `LaunchAgents` (unloaded cleanly via `launchctl bootout` before trashing).
- **Homebrew Caskroom Integration**: Automatically detects Caskroom-managed apps and offers `brew uninstall --cask --zap <token>` (skipping `--zap` whenever a sibling channel is installed).

## Safety Architecture

Upkeep is built around conservative, review-before-delete defaults:

- **Live Running-App Protection**: Enumerates running `.app` bundles natively via macOS `libproc` (`proc_listallpids` + `proc_pidpath`) and automatically holds back caches of open apps and browsers so open SQLite caches (`-wal`/`-shm`) are never corrupted.
- **Strict Path & Symlink Guards**: Enforces canonicalized user-home and temp allowlists (plus a separate strict system-path allowlist for Admin targets), rejects parent-directory traversal, control characters, leaf symlinks, and symlinked ancestor directories, deduplicates targets by `(dev, ino)`, and preserves parent cache folders.
- **Protected User & System Data**: Permanently blocks deletion of Keychains, credential directories, independent CLI directories (Claude Code, Codex, Gemini, OpenCode), Yarn Berry archive stores, Jupyter runtime, macOS aerial wallpapers, OrbStack/Docker/VM state, Mail message stores, Messages attachments, Apple Notes group containers, Steam, Epic, Unity, and live `Current*` powerlog databases.
- **Uninstaller Holdbacks & Warnings**: Holds back browser profiles, `Group Containers`, and VM/game libraries unchecked by default; protects shared data when sibling channels exist (e.g., *VS Code* + *VS Code Insiders*); flags MDM/security/VPN suites (CrowdStrike, Jamf, SentinelOne, ESET, GlobalProtect, Cisco Secure Client, etc.) to recommend their official vendor uninstallers.

## Keyboard Shortcuts

| Context | Shortcut | Action |
| --- | --- | --- |
| Main Window | `⌘F` | Focus sidebar settings search |
| Menu Bar | `⌘,` | Open Upkeep window |
| Menu Bar | `⌘Q` | Quit Upkeep |
| Homebrew HUD | `⌘1` – `⌘4` | Switch scopes (Installed, Formulae, Casks, Upgrades) |
| Homebrew HUD | `⌘K` | Open package actions menu |
| Homebrew HUD | `Esc` | Dismiss Search HUD |
| Clean Keys | Hold `⌘ + Esc` (1s) | Emergency unlock keyboard |

## Architecture & Performance

| Layer | Stack | Highlights |
| --- | --- | --- |
| **UI & Windowing** | Swift 6, SwiftUI, AppKit | macOS 26/27 Liquid Glass sidebar window, `MenuBarExtra`, floating `NSPanel` HUD |
| **System Services** | IOKit, CoreGraphics | Native power assertions, keyboard/pointer event tap, single-prompt allowlisted admin helper |
| **Native Core** | Rust C-ABI (`rust/upkeep_core`) | Zero-`PathBuf` `openat` + `getattrlistbulk` APFS sizing, Rayon parallelism, `nucleo-matcher`, `memchr` NEON/SIMD, `libproc` live-app detection, `catalog.bin` cache |

Upkeep compiles and runs both **with** and **without** `libupkeep_core.a` (automatically falling back to Swift implementations if `cargo` is unavailable).

## Installation & Building from Source

### Download a Release
1. Download the latest `Upkeep-v*.zip` from GitHub Releases (`manavo-o/Upkeep`).
2. Unzip and move `Upkeep.app` into `/Applications`.
3. Launch **Upkeep** — it runs quietly from the top menu bar.

### Build Locally

**Prerequisites**
- **macOS 26.0+** (Liquid Glass UI; Swift package minimum deployment target macOS 15)
- **Swift 6** / Xcode Command Line Tools (`xcode-select --install`)
- **Rust (`cargo`)** *(recommended)* — compiled automatically into `Frameworks/lib/libupkeep_core.a` by `Scripts/build-app.sh`
- **Homebrew** *(optional)* — enables the Homebrew Search HUD and Caskroom integration

**Test, Build, Sign & Launch**

Run in your Terminal so `build-app.sh` can sign with a persistent local certificate and preserve macOS Accessibility permissions across rebuilds:

```zsh
cd Upkeep
(cd rust/upkeep_core && cargo test) && ./Scripts/build-app.sh && open dist/Upkeep.app
```

**Run the Swift Self-Test Suite**

```zsh
./.build/release/UpkeepSelfTest
```

### Permissions
- **Accessibility** *(Clean Keys only)*: Open **Upkeep → Power & Input** (or **Updates**) and click **Grant Accessibility…** to enable Upkeep in **System Settings → Privacy & Security → Accessibility**.
- **Administrator Password** *(optional)*: Never requested during normal cache cleans; macOS prompts once only if you explicitly check items under **System Caches & Logs (Admin)** or orphaned system services.
