# Upkeep

Native macOS 27 menu-bar utility built with Swift 6, SwiftUI, AppKit, and an optional Rust C-ABI core (`spotlight_core`).

## Features

- **Power & Input**: Native IOKit Caffeinate assertions (Display & System or System Only, timed or indefinite) and Clean Keys keyboard/pointer cleaning lock with `⌘ + Esc` failsafe.
- **Homebrew Search HUD**: Floating Liquid Glass search panel with ETag-cached formulae/casks index, `⌘1`–`⌘4` scopes, `⌘K` actions, and one-click upgrades.
- **Cleaner**: Safe dry-run cache scanning and disk cleanup powered by `mo clean`.
- **Uninstaller**: Fast application scanner with Name/Size sorting and optional personal data removal (`mo uninstall`).
- **Updates & System**: GitHub Releases auto-updater, parallel CLI updates (`mo update` & `brew update`), live Accessibility/CLI status checks, and `⌘F` sidebar settings search.

## Build & Run

Run outside of any sandbox so macOS Keychain can create/use a persistent signing identity (preserving TCC Accessibility permissions across rebuilds):

```bash
pkill -x Upkeep 2>/dev/null; ./Scripts/build-app.sh && open dist/Upkeep.app
```

## Releases

Pushing a version tag (e.g., `v1.0.0`) triggers `.github/workflows/release.yml` to build `Upkeep.app`, package `Upkeep-<tag>.zip`, and publish a GitHub Release compatible with Upkeep's built-in updater.
