# Upkeep (`AGENTS.md`)

Instructions and operational gotchas for AI agents working on **Upkeep** (`com.local.Upkeep`).

## Build, Signing & TCC Permissions (Important)

- **Do not rely on sandboxed builds for final signing/launching.** Running `./Scripts/build-app.sh` inside a sandboxed shell cannot access `~/Library/Keychains/login.keychain-db`, causing `build-app.sh` to fall back to ad-hoc signing (`codesign --sign -`).
- **Why this matters:** Ad-hoc signing changes the app's CDHash on every build, which invalidates macOS TCC **Accessibility** permissions and causes Clean Keys to prompt for Accessibility access even when Upkeep is already listed and enabled in System Settings.
- **Required handoff after making changes:**
  1. You may run `./Scripts/build-app.sh` in the sandbox to verify compilation and run `./.build/out/Products/Release/UpkeepSelfTest`.
  2. For the actual signed app launch, always give the user this single command to run in their own Terminal (outside the sandbox), where `build-app.sh` can create/access the persistent `Upkeep Local Signing` (or existing `SpotlightSuite Local Signing` / `Apple Development`) certificate in `login.keychain-db`:
     ```bash
     pkill -x Upkeep 2>/dev/null; ~/projects/Upkeep/Scripts/build-app.sh && open ~/projects/Upkeep/dist/Upkeep.app
     ```
  3. If an ad-hoc build was previously launched, remind the user to toggle **Upkeep** off and back on once in **System Settings → Privacy & Security → Accessibility** so TCC binds to the persistent certificate.

## App Behavior & Launching

- **Executable & Bundle:** `dist/Upkeep.app` (`CFBundleExecutable = Upkeep`, `CFBundleIdentifier = com.local.Upkeep`).
- **Menu Bar App (`LSUIElement = true`):** Launching `Upkeep.app` starts quietly in the top menu bar (arrow/cup icon) without popping open a window. Open the main window via the menu bar icon → **Open Upkeep…** (`⌘,`).

## Architecture & UI Conventions

- **Stack:** Swift 6 strict concurrency, SwiftUI + AppKit (`NavigationSplitView`, `NSPanel`, `NSGlassEffectView`), plus optional Rust C-ABI library in `rust/spotlight_core` (auto-built by `Scripts/build-app.sh` when `cargo` is installed).
- **macOS 27 Native UI System:**
  - Shared primitives live in `Sources/Upkeep/UI/UpkeepSettingsComponents.swift` (`.upkeepPrimary` / `.upkeepSecondary` glass button styles, `UpkeepSettingsFormView`, `UpkeepSettingsSection`, `UpkeepSettingsIcon`, `UpkeepSettingsCallout`, `UpkeepStatusRow`, `UpkeepResetButton`, `UpkeepKeycapGroup`, `.upkeepAnnotation(...)`, `.upkeepSoftTopScrollEdge()`).
  - Sidebar search (`⌘F`) and scroll-to-highlight targets live in `Sources/Upkeep/UI/UpkeepSettingsSearch.swift` (`.upkeepSearchTarget(...)`).
  - Keep every pane's toolbar populated in `MainWindowView.swift` so AppKit's `.unified` toolbar maintains a consistent two-line titlebar height across all tabs.
