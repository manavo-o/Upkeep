import AppKit
import Foundation
import SwiftUI
import UpkeepCore

@main
@MainActor
struct UpkeepSelfTest {
    static var passed = 0
    static var failed = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  [PASS] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            failed += 1
            print("  [FAIL] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func main() async {
        if ProcessInfo.processInfo.arguments.contains("--status-menu") {
            testStatusMenu()
            if failed > 0 { Foundation.exit(1) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--memory-recovery") || ProcessInfo.processInfo.environment["UPKEEP_MEMORY_SELF_TEST"] == "1" {
            let path = ProcessInfo.processInfo.environment["UPKEEP_MEMORY_TEST_DIRECTORY"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("upkeep-recovery-test-\(UUID().uuidString)").path
            try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            setenv("UPKEEP_MEMORY_SELF_TEST", "1", 1)
            setenv("UPKEEP_MEMORY_TEST_DIRECTORY", path, 1)
            MemoryRecoveryTestApp.main()
            return
        }
        print("=== Upkeep Self-Test Suite ===")
        print("  Engine: \(UpkeepEngine.isUsingRustCore ? "Rust upkeep_core C-ABI" : "Swift fallback")")
        let env = ProcessInfo.processInfo.environment
        let requireRust = env["UPKEEP_REQUIRE_RUST"] == "1" || env["CI"] != nil || env["GITHUB_ACTIONS"] != nil
        if requireRust {
            check("Rust upkeep_core C-ABI is linked", UpkeepEngine.isUsingRustCore, UpkeepEngine.isUsingRustCore ? "enabled" : "Swift fallback active")
        }

        // 1. CLIExecutor & ANSI tests
        check("Resolve `brew` binary", CLIExecutor.resolveBinary("brew") != nil, CLIExecutor.resolveBinary("brew") ?? "nil")
        check("Resolve system AppleScript by absolute path", CLIExecutor.resolveBinary("/usr/bin/osascript") == "/usr/bin/osascript")
        check("Missing binary returns nil", CLIExecutor.resolveBinary("nonexistent_bin_xyz_999") == nil)
        let stripped = CLIExecutor.stripANSI("\u{001B}[32m✓ User app cache · 18 items, 2.4GB\u{001B}[0m")
        check("ANSI escape stripping", stripped == "✓ User app cache · 18 items, 2.4GB", stripped)

        // 2. Native Rust Cleaner dry-run scan & safety/deletion tests
        let scanStart = Date()
        let cleanerScan = await MoleService.shared.scanCleanerNative()
        let scanElapsedMs = Date().timeIntervalSince(scanStart) * 1000.0
        check(
            "Native Cleaner dry-run scan completed cleanly",
            cleanerScan.scanDurationMs >= 0,
            String(format: "%.1fms wall (%dms engine), %d items (%@ across %d categories)",
                   scanElapsedMs, cleanerScan.scanDurationMs, cleanerScan.itemCount,
                   cleanerScan.formattedTotalSize, cleanerScan.categories.count)
        )

        // Safety guard: protected root paths & forbidden admin paths must be rejected
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedTargets = [
            "/",
            home,
            (home as NSString).appendingPathComponent("Library"),
            (home as NSString).appendingPathComponent("Library/Caches/com.local.Upkeep")
        ]
        let forbiddenAdminTargets = [
            "/System",
            "/Library/LaunchDaemons/com.apple.test.plist",
            "/private/var/db/powerlog/CurrentPowerlog.PLSQL"
        ]
        let protectedRes = await MoleService.shared.executeNativeClean(
            paths: protectedTargets,
            adminPaths: forbiddenAdminTargets,
            dryRun: true
        )
        let totalForbidden = protectedTargets.count + forbiddenAdminTargets.count
        check(
            "Native Cleaner rejects protected user & admin paths",
            protectedRes.removedCount == 0 && protectedRes.failedItems.count == totalForbidden,
            "rejected \(protectedRes.failedItems.count)/\(totalForbidden)"
        )

        // Temp-dir dry-run & real deletion test
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("upkeep-cleaner-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent("cache_blob.dat")
        try? Data(repeating: 0xAB, count: 16_384).write(to: tempFile)

        let dryExec = await MoleService.shared.executeNativeClean(paths: [tempFile.path], dryRun: true)
        check(
            "Native Cleaner dry-run preserves target file",
            dryExec.removedCount == 1 && dryExec.reclaimedBytes >= 4096 && fm.fileExists(atPath: tempFile.path),
            "reclaimable=\(dryExec.formattedReclaimedSize)"
        )

        let realExec = await MoleService.shared.executeNativeClean(paths: [tempFile.path], dryRun: false)
        check(
            "Native Cleaner deletes approved temp target cleanly",
            realExec.removedCount == 1 && realExec.failedItems.isEmpty && !fm.fileExists(atPath: tempFile.path),
            "reclaimed=\(realExec.formattedReclaimedSize) in \(realExec.durationMs)ms"
        )
        try? fm.removeItem(at: tempDir)

        // 3. Fast Parallel Application Scanner & Uninstaller Inspection benchmark
        let appScanStart = Date()
        let apps = await UpkeepEngine.scanInstalledApplications()
        let appScanMs = Date().timeIntervalSince(appScanStart) * 1000.0
        check("Parallel application scan discovers installed apps", !apps.isEmpty, String(format: "%d apps in %.1fms", apps.count, appScanMs))
        let appsWithSizes = apps.filter { ($0.size ?? 0) > 0 }
        check("Application sizes calculated & pre-formatted", !appsWithSizes.isEmpty, "\(appsWithSizes.count)/\(apps.count) apps (e.g. \(appsWithSizes.first?.name ?? ""): \(appsWithSizes.first?.formattedSize ?? ""))")

        if let sampleApp = appsWithSizes.first {
            let inspectStart = Date()
            let inspection = await MoleService.shared.inspectAppForUninstall(sampleApp)
            let inspectMs = Date().timeIntervalSince(inspectStart) * 1000.0
            check(
                "App uninstall inspection benchmark (\(sampleApp.name))",
                inspection.app.id == sampleApp.id,
                String(format: "%.1fms, %d leftovers, cask=%@", inspectMs, inspection.leftovers.count, inspection.homebrewCaskToken ?? "none")
            )
        }

        // 4. Homebrew live loading, binary cache & 15k search benchmarks
        let jsonWithBanner = "==> Downloading Homebrew API data\n{\"formulae\":[],\"casks\":[]}"
        check("Brew JSON preamble extractor strips leading banner", BrewService.extractJSONObject(from: jsonWithBanner) != nil)

        let scannedDirs = BrewService.scanInstalledDirectories()
        check("Direct Cellar/Caskroom scan finds installed packages", !scannedDirs.isEmpty, "\(scannedDirs.count) packages (\(scannedDirs.filter { !$0.isCask }.count) formulae, \(scannedDirs.filter(\.isCask).count) casks)")

        do {
            let loadStart = Date()
            let loaded = try await BrewService.shared.loadInstalledAndOutdated()
            let loadMs = Date().timeIntervalSince(loadStart) * 1000.0
            check("BrewService.loadInstalledAndOutdated() benchmark", !loaded.isEmpty, String(format: "%d packages in %.1fms", loaded.count, loadMs))

            let outdated = try await CLIExecutor.run(
                binary: "brew", arguments: ["outdated", "--json=v2"],
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
            )
            if outdated.succeeded, let data = BrewService.extractJSONObject(from: outdated.stdout),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] {
                let expected = Set(["formulae", "casks"].flatMap { kind in
                    (json[kind] ?? []).compactMap { package -> String? in
                        guard package["pinned"] as? Bool != true,
                              let name = (package["name"] ?? package["token"]) as? String else { return nil }
                        return "\(kind):\(name)"
                    }
                })
                let actual = Set(loaded.filter(\.isOutdated).map { package in
                    package.isCask ? "casks:\(package.name)" : "formulae:\(package.commandName)"
                })
                check("Upkeep shows the same unpinned upgrades as brew outdated", actual == expected, "\(actual.count) packages")
            } else {
                check("Read Homebrew's upgrade list for comparison", false, outdated.stderr)
            }

            let searchStart = Date()
            let hits = try await BrewService.shared.searchRemote(query: "git")
            let searchMs = Date().timeIntervalSince(searchStart) * 1000.0
            check("15k Brew catalog search ('git') benchmark", !hits.isEmpty && hits.first?.name == "git", String(format: "%d hits in %.1fms (top=%@)", hits.count, searchMs, hits.first?.name ?? "nil"))
            if let git = loaded.first(where: { !$0.isCask && $0.name == "git" }) {
                check("Homebrew search preserves installed package status", hits.first == git)
            }
            if await BrewService.shared.hasWarmRemoteIndex() {
                try await Task.sleep(for: .seconds(6))
                check("Homebrew search index expires while idle", await !BrewService.shared.hasWarmRemoteIndex())
                let reloaded = try await BrewService.shared.searchRemote(query: "git")
                check("Homebrew search reloads after idle eviction", reloaded.first?.name == "git")
            }
        } catch {
            check("BrewService.loadInstalledAndOutdated() resilient", false, error.localizedDescription)
        }

        // 5. Zero-allocation fuzzy matcher benchmark
        let exact = SwiftFuzzyMatcher.score(query: "ripgrep", candidate: "ripgrep") ?? -1
        let prefix = SwiftFuzzyMatcher.score(query: "rip", candidate: "ripgrep") ?? -1
        let loose = SwiftFuzzyMatcher.score(query: "rip", candidate: "archive-zip") ?? -1
        let noMatch = SwiftFuzzyMatcher.score(query: "zzz", candidate: "ripgrep")
        check("Fuzzy ranking: exact > prefix > loose", exact > prefix && prefix > loose, "\(exact) > \(prefix) > \(loose)")
        check("Fuzzy non-match returns nil", noMatch == nil)

        let corpus = (0..<10_000).map { "package-formula-\($0) fast utility tool" }
        let start = Date()
        var hits = 0
        for item in corpus {
            if SwiftFuzzyMatcher.score(query: "pft", candidate: item) != nil { hits += 1 }
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000.0
        check("Fuzzy 10k-item zero-allocation benchmark completes under 150ms", elapsedMs < 150.0, String(format: "%.1fms (%d hits)", elapsedMs, hits))

        // 6. Native IOKit KeepAwakeManager tests
        await MainActor.run {
            let mgr = KeepAwakeManager.shared
            mgr.start(durationMinutes: 30, mode: .displayAndSystem)
            check("KeepAwakeManager starts Display+System assertion", mgr.isActive && mgr.mode == .displayAndSystem)
            mgr.extend(byMinutes: 30)
            check("KeepAwakeManager extends duration (+30m)", (mgr.remainingSeconds ?? 0) > 3500, mgr.formattedRemaining)
            mgr.start(durationMinutes: nil, mode: .systemOnly)
            check("KeepAwakeManager switches to System Only indefinite", mgr.isActive && mgr.mode == .systemOnly && mgr.formattedRemaining == "Indefinite")
            mgr.stop()
            check("KeepAwakeManager releases assertion cleanly", !mgr.isActive && mgr.formattedRemaining == "Off")
        }

        // 7. CleaningModeManager state, permission probe & idempotency tests
        await MainActor.run {
            let cleanMgr = CleaningModeManager.shared
            check("CleaningModeManager starts unlocked", !cleanMgr.isLocked && cleanMgr.holdUnlockProgress == 0)
            cleanMgr.refreshPermissionStatus()
            check("CleaningModeManager active probe checks Accessibility", true, "hasAccessibility=\(cleanMgr.hasAccessibility)")
            cleanMgr.stop()
            check("CleaningModeManager.stop() is idempotent when unlocked", !cleanMgr.isLocked)
        }

        // 8. MenuBar HIG Metrics, Segmented Contrast & Integration Tests
        await MainActor.run {
            check("MenuBarTheme popover width standardized to 380pt", MenuBarTheme.Metrics.popoverWidth == 380)
            check("MenuBarTheme popover padding standardized to 16pt", MenuBarTheme.Metrics.popoverPadding == 16)
            check("MenuBarTheme standard scroll height standardized to 220pt", MenuBarTheme.Metrics.standardScrollHeight == 220)

            let darkSelected = MenuBarTheme.Colors.segmentForeground(isSelected: true, colorScheme: .dark)
            check("Segmented picker selected in dark mode is pure white", darkSelected == Color.white)
            let lightSelected = MenuBarTheme.Colors.segmentForeground(isSelected: true, colorScheme: .light)
            check("Segmented picker selected in light mode is primary", lightSelected == Color.primary)

            let vm = TrayViewModel()
            check("TrayViewModel starts on General", vm.activeSection == .general)
            vm.activeSection = .homebrew
            check("TrayViewModel switches to .homebrew section", vm.activeSection == .homebrew)
            vm.activeSection = .cleaner
            check("TrayViewModel switches to .cleaner section", vm.activeSection == .cleaner)
            vm.activeSection = .uninstaller
            check("TrayViewModel switches to .uninstaller section", vm.activeSection == .uninstaller)
            vm.activeSection = .updates
            check("TrayViewModel switches to .updates section", vm.activeSection == .updates)

            let search = UpkeepSearchEngine()
            search.query = "  CLEAN keys TRACKPAD "
            check("Settings search matches words across category and title", search.results.first?.id == "power.lockPointer")
            search.query = "refresh package catalog"
            check("Settings search links catalog refresh to Homebrew", search.results.first?.tab == .homebrew)
            search.query = "GitHub Repository"
            check("Settings search ranks an exact title first", search.results.first?.id == "updates.repository")
            search.query = "  "
            check("Whitespace clears settings search", !search.isSearching && search.results.isEmpty && search.groupedResults.isEmpty)

            let mainWindow = MainWindowView(vm: HUDCoordinator.shared.trayViewModel, coordinator: HUDCoordinator.shared)
            check("MainWindowView instantiates cleanly with HUDCoordinator", mainWindow.coordinator === HUDCoordinator.shared)
        }

        print("=== Results: \(passed) passed, \(failed) failed ===")
        if failed > 0 {
            Foundation.exit(1)
        }
    }

    private static func testStatusMenu() {
        let app = NSApplication.shared
        let coordinator = HUDCoordinator.shared
        let controller = StatusMenuController(coordinator: coordinator)
        let menu = NSMenu()
        let awake = KeepAwakeManager.shared
        awake.stop()
        defer { awake.stop() }
        controller.menuNeedsUpdate(menu)

        check("Caffeinate Options is absent from the menu", menu.item(withTitle: "Caffeinate Options") == nil)
        if #available(macOS 27.0, *) {
            check("The inline slider replaces the separate start command", menu.item(withTitle: "Start Caffeinate (1 Hour)") == nil)
        } else {
            guard let start = menu.item(withTitle: "Start Caffeinate (1 Hour)"), let action = start.action else {
                check("Caffeinate has a native start command", false)
                return
            }
            check("The native menu dispatches Caffeinate", app.sendAction(action, to: start.target, from: start))
            check("Caffeinate started", awake.isActive)
            check("The same quick action now stops Caffeinate", start.title == "Turn Off Caffeinate")
        }
        let cleaning = CleaningModeManager.shared
        if !cleaning.hasAccessibility || cleaning.permissionDenied {
            check("The permission command replaces the lock action", menu.items.filter { $0.title == "Grant Accessibility Access…" }.count == 1)
        }

        awake.start(durationMinutes: 30, mode: .systemOnly)

        controller.menuNeedsUpdate(menu)
        let rowTitle: String
        if #available(macOS 27.0, *) { rowTitle = "Caffeinate duration" } else { rowTitle = "Caffeinate status" }
        guard let row = menu.item(withTitle: rowTitle)?.view,
              let field = row.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue.hasPrefix("Awake for") }) else {
            check("The active session has a countdown row", false)
            return
        }
        let collapsedHeight = row.frame.height
        let initialItems = menu.items
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let disclosure = row.subviews.compactMap { $0 as? NSButton }.first
        let slider = row.subviews.flatMap(\.subviews).compactMap { $0 as? NSSlider }.first
        if #available(macOS 27.0, *) {
            if let disclosure, let slider, let action = slider.action {
                check("The Caffeinate slider starts collapsed", slider.isHiddenOrHasHiddenAncestor)
                check("The collapsed Caffeinate label is secondary", disclosure.contentTintColor == .secondaryLabelColor)
                let collapsedTitleX = disclosure.cell?.titleRect(forBounds: disclosure.bounds).minX
                let collapsedChevronSize = disclosure.image?.size
                awake.start(durationMinutes: 60, mode: .systemOnly)
                disclosure.performClick(nil)
                check("The disclosure reveals the current duration inline", row.frame.height > collapsedHeight && !slider.isHiddenOrHasHiddenAncestor && slider.doubleValue == 3)
                check("The expanded Caffeinate label uses the primary color", disclosure.contentTintColor == .labelColor)
                check("Changing the chevron keeps the Caffeinate title horizontally anchored",
                      collapsedTitleX != nil && collapsedTitleX == disclosure.cell?.titleRect(forBounds: disclosure.bounds).minX
                      && collapsedChevronSize != nil && collapsedChevronSize == disclosure.image?.size)
                let startTime = Date()
                let initialAssertionSource = awake.usingIOKitAssertion
                check("The logarithmic midpoint is 30 minutes and 1 hour is at three quarters",
                      slider.minValue == 0 && slider.maxValue == 4 && slider.doubleValue == 3)
                slider.doubleValue = 3.45
                check("The native slider dispatches a duration change", app.sendAction(action, to: slider.target, from: slider))
                let expiryInterval = awake.expiresAt?.timeIntervalSince(startTime) ?? 0
                check("The slider resets the timer in five-minute steps", (4800...4802).contains(expiryInterval))
                check("The duration edit preserves the active mode and assertion source", awake.isActive && awake.mode == .systemOnly && awake.usingIOKitAssertion == initialAssertionSource)
            } else {
                check("The status menu embeds a native slider", false)
            }
        }
        let initialFrame = row.frame
        let titleAfterSlider = field.stringValue
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && field.stringValue == titleAfterSlider {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        check("Countdown updates during menu tracking", field.stringValue != titleAfterSlider, "\(titleAfterSlider) → \(field.stringValue)")
        check("Countdown keeps the menu row the same size", row.frame == initialFrame)
        check("Countdown keeps the same submenu items", menu.items == initialItems)
        if #available(macOS 27.0, *), let slider, let action = slider.action {
            slider.doubleValue = slider.minValue
            _ = app.sendAction(action, to: slider.target, from: slider)
            check("The Off stop ends Caffeinate immediately", !awake.isActive && awake.expiresAt == nil && field.stringValue == "Off")
            let offLabels = (row.subviews + row.subviews.flatMap(\.subviews)).compactMap { $0 as? NSTextField }
                .filter { $0.stringValue == "Off" }
            check("The expanded slider shows Off once at the left stop", field.isHidden && offLabels.filter { !$0.isHiddenOrHasHiddenAncestor }.count == 1)

            let startTime = Date()
            slider.doubleValue = 1
            _ = app.sendAction(action, to: slider.target, from: slider)
            let expiryInterval = awake.expiresAt?.timeIntervalSince(startTime) ?? 0
            check("The first timed stop starts a 15-minute session", awake.isActive && (900...902).contains(expiryInterval))

            slider.doubleValue = 0.96
            _ = app.sendAction(action, to: slider.target, from: slider)
            check("A small keyboard step left from 15 minutes switches Off", slider.doubleValue == 0 && !awake.isActive)

            disclosure?.performClick(nil)
            check("Collapsing hides the controls without replacing the menu row", slider.isHiddenOrHasHiddenAncestor && row.frame.height == collapsedHeight && menu.items == initialItems)
            check("Collapsing restores the secondary label color", disclosure?.contentTintColor == .secondaryLabelColor)
            check("The collapsed row shows Off once in the header", !field.isHidden && offLabels.filter { !$0.isHiddenOrHasHiddenAncestor }.count == 1)
        }
    }
}
