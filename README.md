<p align="center">
  <img src="Resources/Icons/AppIcon.png" width="128" height="128" alt="Upkeep App Icon" />
</p>

<h1 align="center">Upkeep</h1>

<p align="center">
  <strong>Native macOS menu-bar utility for power control, Homebrew management, cache cleaning, and deep app uninstallation.</strong><br/>
  Built with Swift 6, SwiftUI Liquid Glass, AppKit, and a Rust C-ABI performance core (<code>upkeep_core</code>).
</p>

## Overview

Upkeep lives quietly in your macOS menu bar and opens into a native Liquid Glass workspace modeled on macOS System Settings. It combines five everyday Mac maintenance utilities into one fast, native app — with a Rust static library (`libupkeep_core.a`) accelerating APFS disk sizing, fuzzy package search, cache scanning, and deep application leftover discovery.

## Everything Inside Upkeep

### 1. Power & Input
- **Caffeinate (Keep Mac Awake)**:
  - Uses native macOS **IOKit power assertions** (`IOPMAssertionCreateWithName`) with zero background `caffeinate` subprocesses.
  - Supports **Display & System** (keeps screen lit and system awake) or **System Only** (lets display dim/lock while background tasks keep running).
  - Quick duration presets (`30m`, `1h`, `2h`, `Indefinite`), one-click `+30m` extension, and a live countdown badge in both the menu bar and main window toolbar.
- **Clean Keys (Keyboard & Pointer Cleaning Lock)**:
  - Intercepts keyboard events (and optionally trackpad/mouse pointer input) using a macOS CoreGraphics event tap so you can wipe down your MacBook safely without triggering shortcuts.
  - Configurable lock durations (`30s`, `60s`, `2m`) and optional **Dim Screen While Locked** to make dust and smudges easier to spot.
  - Built-in emergency unlock failsafes: **hold `⌘ + Esc` for 1 second** or **press `⌘` six times** to unlock immediately.

### 2. Homebrew Search HUD & Package Manager
- **Floating Liquid Glass Search HUD**:
  - Backed by an ETag-cached copy of Homebrew's public `formula.json` and `cask.json` catalog (~15,000 packages), ingested directly into Rust with zero-copy raw bytes and searched in sub-millisecond time via `nucleo-matcher`.
  - Pre-warms quietly in the background after launch and refreshes local `Cellar`/`Caskroom`/pinned state in ~5 ms without spawning Ruby.
  - Four instant filter scopes (**Installed**, **Formulae**, **Casks**, **Upgrades**) plus a `⌘K` package action menu for **Install**, **Upgrade**, **Pin / Unpin**, **Uninstall**, and opening homepages.
- **Persistent Live Operation Log**:
  - Streams live output from `brew install`, `brew upgrade`, `brew uninstall`, and `brew doctor`, and persists the latest operation log across app relaunches with one-click copy and clear.

### 3. Cleaner
- **Two-Phase Dry-Run Cache Inspection**:
  - **Phase 1 (Instant, ~50–150 ms)**: Native Rust scanner using macOS `getattrlistbulk` + Rayon walks user app caches (`~/Library/Caches`), developer caches (Xcode DerivedData, Homebrew downloads, npm, pip, Cargo, Gradle, Yarn, pnpm), and `~/Library/Logs` with APFS-accurate physical disk sizes.
  - **Phase 2 (Optional Refinement)**: Automatically enriches results with `mo clean --dry-run` when Mole CLI is installed.
- **Safe Confirmation Workflow**:
  - Filterable dry-run list (*All*, *Candidates*, *Cleaned*) showing estimated reclaimable space before deleting anything, gated behind an explicit confirmation bar.

### 4. Deep Uninstaller
- **Two-Phase Application Scanner**:
  - Discovers apps in `/Applications` and `~/Applications` with bundle IDs in under 15 ms (Phase 1), then computes APFS-accurate bundle sizes concurrently via `getattrlistbulk` (Phase 2).
  - Supports instant fuzzy filtering and **Name / Size** sorting.
- **Interactive Uninstall Review Sheet**:
  - Inspects related leftover files across `~/Library` and XDG locations — including naming variants, channel/version suffix stripping, camelCase bundle-leaf splitting, embedded `.appex`/`.xpc`/`LoginItems` bundle IDs, `Group Containers` (`<TeamID>.` boundary matching), UUID sandbox containers (`MCMMetadataIdentifier`), `ByHost`, `Cookies`, `HTTPStorages`, `SyncedPreferences`, `Autosave Information`, `FileProvider`, `ApplicationRecentDocuments` (`.sfl2`/`.sfl3`/`.sfl4`), `nsurlsessiond/Downloads`, `*.ShipIt`, `*-updater`, crash reporters, verified `NativeMessagingHosts`, user plug-ins, vendor-nested `<Vendor>/<Product>` directories, special-app rules (VS Code, Xcode, JetBrains, Android Studio, Claude Desktop, Docker, Anki, Godot), and `LaunchAgents` matched by `Program`/`ProgramArguments[0]`/`Label`.
  - Automatically unloads selected user `LaunchAgents` via `launchctl bootout` before moving them to Trash.
  - Detects system-level remnants (`/Library/*`, `/Library/PrivilegedHelperTools`, `/Users/Shared`, `/private/var/db/receipts`) as read-only entries with one-click **Reveal in Finder**.
  - Cross-checks Homebrew's `Caskroom` and offers `brew uninstall --cask --zap <token>` when safe.
- **Safety Guards**:
  - **Sibling-App Protection**: Detects co-installed channels/copies (e.g., *Zed* + *Zed Nightly*, *VS Code* + *VS Code Insiders*) and automatically skips shared folders and `--zap`.
  - **Independent CLI & Shared-Root Protection**: Never touches independent CLI data directories (Claude Code, Codex, Gemini, OpenCode), Steam, Epic, Unity, or shared XDG roots.
  - **Personal-Data Holdbacks**: Leaves browser profiles, `Group Containers`, and VM/game libraries unchecked by default with `Held back` badges.
  - **Official Uninstaller Warnings**: Highlights security, MDM, and VPN suites (CrowdStrike, Jamf, SentinelOne, ESET, GlobalProtect, Cisco Secure Client, Malwarebytes, TeamViewer, etc.) and recommends using the vendor's official uninstaller.

### 5. Updates, Permissions & Settings Search
- **Built-In Auto-Updater**: Checks GitHub Releases (`manavo-o/Upkeep`) automatically every 6 hours or on demand, with one-click download, install, and relaunch.
- **Parallel CLI Updates**: Runs `mo update` and `brew update` concurrently from the Updates pane.
- **Environment Diagnostics**: Live status indicators for macOS Accessibility permission, Homebrew CLI, and Mole CLI, plus `⌘F` sidebar settings search across all panes.

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

| Layer | Technology | Responsibility |
| --- | --- | --- |
| UI & Windowing | Swift 6, SwiftUI, AppKit | Native Liquid Glass sidebar window, `MenuBarExtra`, floating Search HUD |
| System Services | IOKit, CoreGraphics, POSIX PTY | Caffeinate power assertions, Clean Keys event tap, streaming CLI executor |
| Native Core (`upkeep_core`) | Rust C-ABI (`libupkeep_core.a`) | `getattrlistbulk` APFS sizing, Rayon parallel scanners, `nucleo-matcher` index, deep uninstaller inspection |

Upkeep builds and runs seamlessly both **with** and **without** `libupkeep_core.a` (falling back to Swift implementations if Cargo is not installed).

## How to Run Upkeep

### Option 1: Download a Prebuilt Release
1. Open the **Releases** page for `manavo-o/Upkeep` and download the latest `Upkeep-v*.zip`.
2. Unzip and drag `Upkeep.app` into `/Applications`.
3. Launch `Upkeep.app` — look for the Upkeep icon in your macOS menu bar.

### Option 2: Build & Run from Source

#### Prerequisites
- **macOS 26.0+** (built for macOS 26/27 Liquid Glass)
- **Swift 6** / Xcode Command Line Tools (`xcode-select --install`)
- **Rust (`cargo`)** *(optional, recommended)* — automatically compiled into `Frameworks/lib/libupkeep_core.a` by `Scripts/build-app.sh`
- **Homebrew** *(optional)* — enables the Homebrew Search HUD and Caskroom integration
- **Mole CLI** *(optional)* — `brew install tw93/tap/mole` for full `mo clean` execution

#### Build and Launch

Run in Terminal so macOS Keychain can create or reuse a persistent code-signing identity (preserving TCC Accessibility permissions across rebuilds):

```zsh
cd Upkeep
pkill -x Upkeep 2>/dev/null; ./Scripts/build-app.sh && open dist/Upkeep.app
```

#### Grant Accessibility Permission (for Clean Keys)
1. Open Upkeep from the menu bar (`⌘,`) and go to **Power & Input** or **Updates**.
2. Click **Grant Accessibility…** to open **System Settings → Privacy & Security → Accessibility**.
3. Enable **Upkeep** (if rebuilding locally, the persistent signing identity keeps this permission intact across builds).

#### Run the Self-Test Suite

```zsh
./.build/release/UpkeepSelfTest
```

## Releases

Pushing a version tag (for example `v1.1.0`) triggers `.github/workflows/release.yml` on `macos-26` to compile `upkeep_core`, build and package `Upkeep-<tag>.zip`, attach `RELEASE_NOTES.md`, and publish a GitHub Release compatible with Upkeep's built-in updater:

```zsh
git tag -f v1.1.0 && git push -f origin v1.1.0
```
