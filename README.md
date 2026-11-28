<div align="center">
  <img src="Resources/Icons/AppIcon.png" width="112" height="112" alt="Upkeep app icon" />

  <h1 id="upkeep">Upkeep</h1>

  <p>A native macOS menu bar app for keeping your Mac awake, locking input during cleaning, managing Homebrew, and reclaiming disk space.</p>

  <a href="https://github.com/manavo-o/Upkeep/releases/latest"><strong>Download Upkeep</strong></a> ·
  <a href="RELEASE_NOTES.md">Release notes</a> ·
  <a href="#build-from-source">Build from source</a>

  <p>
    <a href="https://github.com/manavo-o/Upkeep/releases/latest"><img src="https://img.shields.io/github/v/release/manavo-o/Upkeep?display_name=tag" alt="Latest GitHub release" /></a>
    <img src="https://img.shields.io/badge/macOS-26%2B-1D1D1F?logo=apple" alt="macOS 26 or later" />
    <img src="https://img.shields.io/badge/Apple%20silicon-arm64-1D1D1F" alt="Apple silicon" />
  </p>
</div>

## Install

1. On an Apple silicon Mac running **macOS 26 or later**, download the `Upkeep-v*.zip` asset from the [latest GitHub release](https://github.com/manavo-o/Upkeep/releases/latest).
2. Extract the ZIP and move **Upkeep.app** into **Applications**.
3. Launch Upkeep and click the cup icon in the menu bar. Choose **Open Upkeep…** to open Settings.

Upkeep starts in the menu bar without opening a window or adding a Dock icon. The cup fills in while Caffeinate is active. macOS 27 adds a Caffeinate duration slider to the menu and native tabs to the Homebrew package browser. On macOS 26 the menu offers a one-hour start command and an off command, with duration controls available in Settings.

Homebrew is optional and enables package browsing, package commands, and Homebrew cask removal. Cleaner and Uninstaller’s native removal workflow work with the bundled engine, without installing Mole or Rust separately.

## New in 1.6.2

- Caffeinate updates the countdown only where it’s visible. Idle memory recovery waits for active work to finish without polling.
- Homebrew cancels searches as you change the query and keeps just the recent output in memory during interactive package operations.
- Uninstaller shows app names before calculating bundle sizes and shares the scan when requests overlap.
- Building from source requires the Rust toolchain. The download already includes the Rust core.

## What you can do

| Feature | Where to start | What it does |
| --- | --- | --- |
| [Caffeinate](#caffeinate) | Menu bar or **Settings → Caffeinate** | Prevent idle sleep for a set duration or until you stop the session. |
| [Clean Keys](#clean-keys) | Menu bar or **Settings → Clean Keys** | Temporarily pause keyboard input and optionally block pointer and trackpad input while cleaning. |
| [Homebrew](#homebrew) | **Search Homebrew…** or **Settings → Homebrew** | Find packages, review upgrades, run package commands, and inspect command output. |
| [Cleaner](#cleaner) | **Cleaner… → Scan** | Find caches and other reclaimable files, review estimates, and delete selected items. |
| [Uninstaller](#uninstaller) | **Uninstaller… → Review…** | Inspect an installed app and its related files, then choose what to remove. |
| [Updates](#updates-and-network-activity) | **Check for Updates…** or **Settings → About & Updates** | Check the installed version, review release notes, and install updates. |

In Settings, use <kbd>⌘</kbd> <kbd>F</kbd> to find a setting and jump to it.

### Caffeinate

Choose **Mac & Display** to prevent idle display sleep as well as idle system sleep, or **Mac Only** to let the display sleep. Drag **Session Duration** to start a timed session or reset the current timer. The slider ranges from 15 minutes to 2 hours in five-minute steps, with **Off** at the left. Settings also offers **Until Stopped**, **Stop Session**, and **Add 30 min** for an active timed session.

**Keep Awake With Lid Closed** is a separate setting in **Caffeinate**. Enabling it asks for administrator approval once to install a per-user launch daemon. The preference applies automatically to future sessions and takes effect for an active session when enabled. While engaged, the helper uses `pmset` to disable system sleep. It restores the previous sleep behavior when the session ends or Upkeep disconnects. A boot-time recovery job can restore sleep if the machine loses power during a session. Turn the setting off to stop using closed-lid mode.

### Clean Keys

Choose a lock duration of **30 seconds**, **1 minute**, or **2 minutes**. **Dim Screen** makes smudges easier to see, and **Lock Pointer & Trackpad** extends the lock to pointer input. Start the timer with **Lock Keyboard**.

Clean Keys needs **Accessibility** permission for its temporary input lock. Use **Grant Accessibility…** in Settings to open the relevant macOS settings, then enable **Upkeep** under **Privacy & Security → Accessibility**.

To unlock early, hold <kbd>⌘</kbd> + <kbd>Esc</kbd> for one second or press <kbd>⌘</kbd> six times. **Unlock Keyboard** is also available from Upkeep when you can reach its controls.

### Homebrew

Open **Search Homebrew…** from the menu bar to use the floating search window, or browse in **Settings → Homebrew**. Filter by **Installed**, **Formulae**, **Casks**, or **Upgrades**. Use **Floating Search** in Settings to open the current query in the floating window.

- **Search.** Upkeep caches formula and cask metadata and the Rust search index under `~/Library/Caches/com.local.Upkeep/BrewAPI`. The index ranks exact names, prefixes, substrings, fuzzy name matches, and description matches in that order. Upkeep reads installed versions, pins, and available upgrades from `brew info --json=v2 --installed` and `brew outdated --json=v2`.
- **Manage packages.** Install, upgrade, or uninstall a package. The floating window’s <kbd>⌘</kbd> <kbd>K</kbd> actions menu also exposes formula pinning and unpinning, install-command copying, and homepage links where available. The Homebrew pane offers a bulk upgrade action when updates are available.
- **Inspect activity.** Follow running commands and review their output under **Homebrew → Activity**. **Refresh Catalog** runs `brew update`. **Run Diagnostics** in Settings and **Run Brew Doctor** in the floating window both run `brew doctor`.
- **Set up Homebrew.** If Upkeep cannot find `brew`, the Homebrew pane offers **Copy Install Command**. With Homebrew installed, Upkeep uses your existing Homebrew setup for package operations.

### Cleaner

1. Select **Scan** to preview candidates and their estimated sizes.
2. Review the paths and selection total. **Recommended** restores the default selection, and you can change individual items or whole categories. Entries labeled **Running** are caches that the scan associated with running apps and left unchecked.
3. Confirm **Delete Files** to permanently delete the selected items. Entries marked **Administrator access required** start unchecked. Upkeep processes user items before requesting administrator authorization, so canceling that prompt leaves completed user deletions in place.

The full Rust scanner can report the following categories. A scan only shows categories with results.

<details>
<summary>Cleaner categories and examples</summary>

| Category | What the scanner looks for |
| --- | --- |
| **Developer Tools** | Xcode DerivedData, simulator caches and selected data from shut-down devices, plus caches from Homebrew, SwiftPM, CocoaPods, JetBrains, Android Studio, Node package managers, Python tools, Rust, Gradle, and other build tools. Some larger or harder-to-replace items, including Xcode Archives and Maven’s local repository, start unchecked. |
| **Browser Caches** | Cache locations for browsers such as Chrome, Brave, Edge, Arc, Firefox, Zen, Vivaldi, and Opera, plus known Chromium update leftovers. The scan targets cache data and avoids browser profiles. |
| **App Internal Caches** | Specific cache folders inside Application Support, including Electron and Chromium code or GPU caches, plus app-specific targets such as Adobe Media Cache. |
| **User App Caches** | User caches under `~/Library/Caches` and cache directories inside third-party app containers. The cleaner preserves designated parent directories. |
| **macOS & Apple Caches** | Quick Look thumbnails, icon services, Safari previews, WebKit network caches, and selected Apple app data. Stale Mail attachment copies, autosave data, and local iOS device backups start unchecked. |
| **Project Build Artifacts** | Directories such as `node_modules`, `target`, `.build`, `Pods`, and `.venv` in common project roots. A neighboring project marker such as `package.json`, `Cargo.toml`, or `Package.swift` must match the artifact rule. Results start unchecked. |
| **Orphaned App Leftovers** | Stale app caches, logs, saved state, and related files for bundle IDs no longer found on disk. Also looks for some non-Apple system launch agents and daemons whose programs are missing. |
| **Logs & Diagnostics** | User application logs, diagnostic reports, and older crash reports. |
| **Saved State & Temp** | Saved application state, older temporary files, and stale partial downloads. Saved state and partial downloads start unchecked. |
| **Old Installers** | `.dmg`, `.pkg`, `.mpkg`, `.iso`, and `.xip` files older than 24 hours in Downloads or Desktop. Results start unchecked. |
| **System Caches & Logs (Admin)** | Allowlisted system caches, logs, diagnostics, and temporary files. The scanner excludes live power-log databases. |
| **Trash** | Contents of the user’s Trash. This starts unchecked. |

</details>

The Rust cleaner checks candidates and revalidates selected paths before deleting. It rejects protected paths, traversal, and symlinked targets or ancestors in the user removal path. Explicit protections cover locations such as Keychains, SSH and GnuPG data, Mail stores, and Messages attachments. A holdback reason indicates a candidate that needs review and starts unchecked. Use the selected size as an estimate of space you may reclaim.

### Uninstaller

Upkeep lists apps from **Applications**, **~/Applications**, and their immediate subfolders, then fills in bundle sizes. Choose **Review…** to inspect a bundle and its related files. The review groups leftovers such as preferences, caches, logs, support files, containers, and launch agents. Use **Recommended**, **All User Files**, or **Deselect All** as a starting point, then review individual paths.

- **Native removal** attempts to quit the app, moves its bundle and selected user leftovers to Trash, and attempts to unregister the removed bundle from Launch Services.
- **System leftovers** require administrator authorization and are permanently deleted if selected. Upkeep limits these targets to known locations such as system launch agents, privileged helpers, and app support directories. Declining authorization can leave system leftovers in place after the app and user files have been moved to Trash.
- **Uninstall with Homebrew** appears for detected casks when Homebrew is available. Homebrew can remove files declared by the cask beyond the checked paths. Upkeep skips `--zap` when it detects a sibling app or release channel and preserves identified shared files.
- **Official Uninstaller Recommended** appears for certain device-management, security, and VPN products. The vendor’s uninstaller can handle components such as system extensions and background services.

## Keyboard shortcuts

| Context | Shortcut | Action |
| --- | --- | --- |
| Upkeep menu or active app | <kbd>⌘</kbd> <kbd>,</kbd> | Open Settings. From floating Homebrew search, open Homebrew Settings. |
| Upkeep menu or active app | <kbd>⌘</kbd> <kbd>Q</kbd> | Quit Upkeep. |
| Settings | <kbd>⌘</kbd> <kbd>F</kbd> | Focus settings search. |
| Settings | <kbd>⌘</kbd> <kbd>[</kbd> / <kbd>⌘</kbd> <kbd>]</kbd> | Go back or forward. |
| Floating Homebrew search | <kbd>⌘</kbd> <kbd>1</kbd>–<kbd>4</kbd> | Select Installed, Formulae, Casks, or Upgrades. |
| Floating Homebrew search | <kbd>↑</kbd> / <kbd>↓</kbd> | Move through the results. |
| Floating Homebrew search | <kbd>Return</kbd> | From the search field or results list, install a missing package, upgrade an outdated package, or uninstall an installed package with no upgrade available. |
| Floating Homebrew search | <kbd>⌘</kbd> <kbd>K</kbd> | Open the actions menu. |
| Floating Homebrew search | <kbd>Esc</kbd> | Clear the query and scope, or close the window when both are clear. |
| Clean Keys | Hold <kbd>⌘</kbd> + <kbd>Esc</kbd> for one second or press <kbd>⌘</kbd> six times | Unlock input early. |

## Updates and network activity

**About & Updates** shows the installed version and lets you choose whether to check automatically. Automatic checks are enabled by default. Upkeep checks GitHub Releases on launch or when Settings opens if six hours have elapsed since the previous check. **Check for Updates…** runs a manual check. The default repository is `manavo-o/Upkeep`.

**Install & Relaunch** downloads the release ZIP, verifies the extracted app’s code signature with `codesign`, and attempts to replace the current bundle and reopen it. Changing the repository in Settings changes the source of downloadable updates, so use a repository you trust.

File scans, package search, and preferences stay on the Mac. Upkeep has no analytics or telemetry. The app contacts GitHub for updates and `formulae.brew.sh` for package metadata. Homebrew commands can also contact taps, package registries, and download hosts.

## Build from source

Use an Apple silicon Mac, **Xcode 27** with the macOS 27 SDK to build the current interface, and a Rust toolchain with `cargo` and the `aarch64-apple-darwin` target. Use a Terminal session with access to your login keychain for a build you intend to launch.

```sh
git clone https://github.com/manavo-o/Upkeep.git
cd Upkeep
./Scripts/build-app.sh
codesign --verify --deep --strict dist/Upkeep.app
codesign -dv --verbose=4 dist/Upkeep.app
```

The script builds the Rust static library into `Frameworks/lib/`, compiles the Swift release executables, and packages `dist/Upkeep.app`. It also stamps the SDK version into the executable to enable native Liquid Glass controls. Wait for a successful build before running the verification commands.

For repeatable local builds, look for `Authority=Apple Development: …` or `Authority=Upkeep Local Signing` in the signature details, then run `open dist/Upkeep.app`. The script can create a persistent local signing identity when a development identity is unavailable. If it falls back to ad-hoc signing, rebuild with keychain access before replacing your running copy. After switching from an ad-hoc build to a persistent signature, toggle Upkeep off and on once in **System Settings → Privacy & Security → Accessibility** if Clean Keys still asks for access.

Upkeep requires the Rust core for every build. When invoking SwiftPM directly, run `./Scripts/build-rust-cabi.sh` first to build `Frameworks/lib/libupkeep_core.a`.

### Run the checks

Run these from the repository root after building. The main Swift self-test expects Homebrew on the machine and uses disposable temporary files to test Cleaner deletion.

```sh
cargo test --manifest-path rust/upkeep_core/Cargo.toml
./.build/release/UpkeepSelfTest
./.build/release/UpkeepSelfTest --status-menu
```

The status menu mode exercises the AppKit menu. To test idle process handoff in a logged-in macOS desktop session, run the opt-in memory recovery test.

```sh
recovery_results="$(mktemp -d)"
UPKEEP_MEMORY_TEST_DIRECTORY="$recovery_results" ./.build/release/UpkeepSelfTest --memory-recovery
```

The replacement process writes `result.json` shortly after the original command exits. Check `"$recovery_results/result.json"` for `"passed": true`.

The [release workflow](.github/workflows/release.yml) tests the Rust core, builds Upkeep, runs the main Swift self-test, and packages `Upkeep-v*.zip`. Builds from `v*` tags publish the archive to GitHub Releases. CI uses ad-hoc signing.

## Architecture

Swift 6, SwiftUI, and AppKit implement the status menu, the settings window, and the floating Homebrew and Clean Keys panels. Caffeinate uses IOKit power assertions. Clean Keys uses a CoreGraphics event tap. Swift calls the Rust core through `CUpkeepCore` for parallel filesystem scanning and sizing, app and leftover discovery, and package indexing.

| Path | Responsibility |
| --- | --- |
| [App entry point](Sources/UpkeepAppEntry/UpkeepApp.swift) | Launches the menu bar app. |
| [App coordination](Sources/Upkeep/App) | Status menu, window lifecycle, and idle process recovery. |
| [Services](Sources/Upkeep/Services) | Power and input control, Homebrew execution, cleanup and removal, and updates. |
| [UI](Sources/Upkeep/UI) | Settings navigation and search, shared controls, and floating panels. |
| [Rust core](rust/upkeep_core) | Cleaner rules, macOS bulk directory sizing, app discovery, and ranked package search. |
| [Build scripts](Scripts) and [self-tests](Sources/UpkeepSelfTest) | App packaging, Rust integration, and regression checks. |

Upkeep can evict the in-memory Homebrew index during idle periods and reload it from `catalog.bin` when needed. If memory use stays above its idle budget, Upkeep can replace its idle process to release framework caches. It hands off ordinary Caffeinate assertions before the old process exits. Open or minimized windows, tracked menus, Clean Keys, an engaged closed-lid helper, and maintenance operations defer process recovery.

## Report an issue

Include the Upkeep version from **About & Updates**, your macOS version, the pane or menu action involved, and the steps to reproduce the behavior. For a Homebrew problem, include the relevant **Activity** output with any private paths or credentials removed. [Open a GitHub issue](https://github.com/manavo-o/Upkeep/issues).
