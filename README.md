# Upkeep

Native macOS menu-bar utility for power control, Homebrew management, cache cleaning, and deep app uninstallation — built with Swift 6, SwiftUI Liquid Glass, AppKit, and a Rust C-ABI performance core (`upkeep_core`).

## What's New in v1.1

- **Mole-Parity Deep Uninstaller**: Native Rust leftover engine covering naming variants, channel/version suffix stripping, camelCase bundle-leaf splitting, embedded `.appex`/`.xpc`/`LoginItems` IDs, `Group Containers` (`<TeamID>.` boundary matching), UUID sandbox containers (`MCMMetadataIdentifier`), `ByHost`/`Cookies`/`HTTPStorages`/`sfl{2,3,4}`/`ShipIt`/crash reporters/`NativeMessagingHosts`/XDG/plug-ins, vendor-nested folders, special-app rules (VS Code, Xcode, JetBrains, Android Studio, Claude Desktop, Docker, Anki, Godot), `LaunchAgents` `Program`/`ProgramArguments[0]` ownership matching + `launchctl bootout`, and read-only system remnant detection (`/Library/*`, `/Users/Shared`, `/private/var/db/receipts`).
- **Built-In Safety Guards**:
  - **Sibling-App Protection**: Automatically detects co-installed channels/copies (e.g., *Zed* + *Zed Nightly*, *VS Code* + *VS Code Insiders*) and skips shared folders and Homebrew `--zap`.
  - **Independent CLI & Shared-Root Protection**: Preserves independent CLI data directories (Claude Code, Codex, Gemini, OpenCode), Steam, Epic, Unity, and shared XDG roots.
  - **Personal-Data Holdbacks**: Browser profiles, `Group Containers`, and VM/game libraries start **unchecked by default** with `Held back` badges and one-click **Reveal in Finder**.
  - **Official Uninstaller Warnings**: Flags security, MDM, and VPN suites (CrowdStrike, Jamf, SentinelOne, ESET, GlobalProtect, Cisco Secure Client, Malwarebytes, TeamViewer, etc.) to recommend their official vendor uninstallers.
- **Rust + SwiftUI Performance Overhaul**: macOS `getattrlistbulk` APFS sizing, zero-copy raw-byte Homebrew JSON API ingestion, ~5 ms in-place local Cellar/Caskroom refresh, instant native cache scanning (~50–150 ms), two-phase Uninstaller app loading (<15 ms first paint), and live streaming output for Homebrew and Cleaner.

## Features

### Power & Input
- **Caffeinate**: Native IOKit power assertions (*Display & System* or *System Only*) with quick timers (`30m`, `1h`, `2h`, `Indefinite`), `+30m` extension, and a live countdown badge in the toolbar and menu bar.
- **Clean Keys**: Temporarily locks keyboard (and optionally pointer/trackpad) input and dims the screen so you can wipe down your MacBook safely. Includes a hardware-safe **`⌘ + Esc` (hold 1s)** or **6× `⌘`** emergency unlock.

### Homebrew Search HUD
- Floating Liquid Glass search panel backed by an ETag-cached full Homebrew API index (~15,000 formulae and casks) indexed in Rust with `nucleo-matcher` for sub-millisecond fuzzy search.
- Scopes for **Installed**, **Formulae**, **Casks**, and **Upgrades**, plus one-click install, upgrade, pin/unpin, uninstall, and a persistent live-streaming **Last Operation Log** (including `brew doctor`).

### Cleaner
- **Two-Phase Cache Inspection**: Shows an instant (~50–150 ms) native Rust APFS scan of user app caches, developer caches (Xcode DerivedData, Homebrew, npm, pip, Cargo, Gradle, Yarn, pnpm), and logs, then refines with Mole (`mo clean --dry-run`) when installed.
- Filterable dry-run preview (*All*, *Candidates*, *Cleaned*) with explicit confirmation before deleting anything.

### Uninstaller
- Instant two-phase `/Applications` and `~/Applications` scanner with Name/Size sorting and fuzzy filtering.
- Interactive **Uninstall Review Sheet** showing exact leftover paths, APFS-accurate sizes, Homebrew Caskroom detection (`brew uninstall --cask --zap` when safe), safety banners, holdback badges, and **Reveal in Finder** on every row.

### Updates & System
- Built-in GitHub Releases updater (`manavo-o/Upkeep`) with automatic 6-hour background checks and one-click install & relaunch.
- Parallel CLI updater (`mo update` + `brew update`), live Accessibility / Homebrew / Mole status checks, and `⌘F` sidebar settings search.

## Keyboard Shortcuts

| Context | Shortcut | Action |
| --- | --- | --- |
| Main Window | `⌘F` | Focus sidebar settings search |
| Menu Bar | `⌘,` | Open Upkeep main window |
| Menu Bar | `⌘Q` | Quit Upkeep |
| Homebrew HUD | `⌘1` – `⌘4` | Switch scopes (Installed, Formulae, Casks, Upgrades) |
| Homebrew HUD | `⌘K` | Open package actions menu |
| Homebrew HUD | `Esc` | Dismiss Search HUD |
| Clean Keys | Hold `⌘ + Esc` (1s) | Emergency unlock keyboard |

## Architecture

| Layer | Technology | Role |
| --- | --- | --- |
| UI & Windowing | Swift 6, SwiftUI, AppKit | Native Liquid Glass sidebar window, menu bar extra, floating HUD |
| System Services | IOKit, CoreGraphics, POSIX PTY | Caffeinate assertions, Clean Keys event tap, streaming CLI runner |
| Native Core (`upkeep_core`) | Rust C-ABI (`libupkeep_core.a`) | `getattrlistbulk` APFS sizing, Rayon parallel scanners, `nucleo-matcher` fuzzy index, Mole-parity uninstaller inspection |

Upkeep compiles and runs with or without `libupkeep_core.a` (falling back seamlessly to Swift implementations when the Rust static library is not linked).

## Build & Run

### Requirements
- macOS 26.0+ (optimized for macOS 27)
- Swift 6 / Xcode Command Line Tools
- Rust toolchain (`cargo`) — optional, automatically built and linked by `Scripts/build-app.sh` when installed
- Homebrew and Mole CLI (`brew install tw93/tap/mole`) — optional, for Homebrew management and full `mo clean` execution

### Build Locally

Run in Terminal so macOS Keychain can use a persistent code-signing identity (preserving TCC Accessibility permissions across rebuilds):

```zsh
pkill -x Upkeep 2>/dev/null; ./Scripts/build-app.sh && open dist/Upkeep.app
```

### Run Self-Test Suite

```zsh
./.build/release/UpkeepSelfTest
```

## Releases

Pushing a version tag (e.g., `v1.1.0`) triggers `.github/workflows/release.yml` on `macos-26` to compile `upkeep_core`, build `Upkeep.app`, package `Upkeep-<tag>.zip`, and publish a GitHub Release compatible with Upkeep's built-in updater.
