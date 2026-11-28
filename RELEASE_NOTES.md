## What’s new in Upkeep v1.6.2

- Caffeinate updates its countdown only while it’s visible. Idle memory recovery resumes when active work finishes.
- Homebrew cancels older searches as you type and keeps recent command output in memory during interactive package operations. The activity log shows up to 64 KiB.
- Uninstaller shows app names first, then calculates sizes from the same scan. Overlapping requests share the scan.
- The Rust core is required for source builds and is included in the release archive.

The release archive supports Apple silicon Macs running macOS 26 or later. The Homebrew package browser uses native tabs on macOS 27.

[Previous releases](https://github.com/manavo-o/Upkeep/releases)
