# Upkeep (`AGENTS.md`)

Instructions and operational gotchas for AI agents working on **Upkeep** (`com.local.Upkeep`).

## Build, Signing & TCC Permissions (Important)

- **Do not rely on sandboxed builds for final signing/launching.** Running `./Scripts/build-app.sh` inside a sandboxed shell cannot access `~/Library/Keychains/login.keychain-db`, causing `build-app.sh` to fall back to ad-hoc signing (`codesign --sign -`).
- **Why this matters:** Ad-hoc signing changes the app's CDHash on every build, which invalidates macOS TCC **Accessibility** permissions and causes Clean Keys to prompt for Accessibility access even when Upkeep is already listed and enabled in System Settings.
- **Codex:** Run the signed build and relaunch directly outside the sandbox so the build can use the login keychain. Verify that `dist/Upkeep.app` has a persistent `Upkeep Local Signing` or `Apple Development` signature before replacing the running instance. If access is blocked, report the specific blocker. For an explicitly requested release, carry out the authorized release steps directly.
- For compilation checks, you may run `./Scripts/build-app.sh` in the sandbox and verify with `./.build/out/Products/Release/UpkeepSelfTest`.
- If an ad-hoc build was previously launched, remind the user to toggle **Upkeep** off and back on once in **System Settings → Privacy & Security → Accessibility** so TCC binds to the persistent certificate.

## App Behavior & Launching

- **Executable & Bundle:** `dist/Upkeep.app` (`CFBundleExecutable = Upkeep`, `CFBundleIdentifier = com.local.Upkeep`).
- **Menu Bar App (`LSUIElement = true`):** Launching `Upkeep.app` starts quietly in the top menu bar (arrow/cup icon) without popping open a window. Open the main window via the menu bar icon → **Open Upkeep…** (`⌘,`).

## Architecture & UI Conventions

- **Stack:** Swift 6 strict concurrency, SwiftUI + AppKit (`NavigationSplitView`, `NSPanel`, `NSGlassEffectView`), plus optional Rust C-ABI library in `rust/upkeep_core` (auto-built by `Scripts/build-app.sh` when `cargo` is installed).
- **macOS 27 Native UI System:**
  - Shared primitives live in `Sources/Upkeep/UI/UpkeepSettingsComponents.swift` (`.upkeepPrimary` / `.upkeepSecondary` glass button styles, `UpkeepSettingsFormView`, `UpkeepSettingsSection`, `UpkeepSettingsIcon`, `UpkeepSettingsCallout`, `UpkeepStatusRow`, `UpkeepResetButton`, `UpkeepKeycapGroup`, `.upkeepAnnotation(...)`, `.upkeepSoftTopScrollEdge()`).
  - Sidebar search (`⌘F`) and scroll-to-highlight targets live in `Sources/Upkeep/UI/UpkeepSettingsSearch.swift` (`.upkeepSearchTarget(...)`).
  - Keep every pane's toolbar populated in `MainWindowView.swift` so AppKit's `.unified` toolbar maintains a consistent two-line titlebar height across all tabs.
