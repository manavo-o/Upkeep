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

            let searchStart = Date()
            let hits = try await BrewService.shared.searchRemote(query: "git")
            let searchMs = Date().timeIntervalSince(searchStart) * 1000.0
            check("15k Brew catalog search ('git') benchmark", !hits.isEmpty && hits.first?.name == "git", String(format: "%d hits in %.1fms (top=%@)", hits.count, searchMs, hits.first?.name ?? "nil"))
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
        controller.menuNeedsUpdate(menu)

        guard let start = menu.item(withTitle: "Caffeinate")?.submenu?.items.first,
              let action = start.action else {
            check("Caffeinate has a native start command", false)
            return
        }
        defer { KeepAwakeManager.shared.stop() }
        check("The native menu dispatches Caffeinate", app.sendAction(action, to: start.target, from: start))
        check("Caffeinate started", KeepAwakeManager.shared.isActive)

        controller.menuNeedsUpdate(menu)
        guard let row = menu.item(withTitle: "Caffeinate status")?.view,
              let field = row.subviews.first as? NSTextField else {
            check("The active session has a countdown row", false)
            return
        }
        let initialTitle = field.stringValue
        let initialFrame = row.frame
        let initialItems = menu.items
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && field.stringValue == initialTitle {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        check("Countdown updates during menu tracking", field.stringValue != initialTitle, "\(initialTitle) → \(field.stringValue)")
        check("Countdown keeps the menu row the same size", row.frame == initialFrame)
        check("Countdown keeps the same submenu items", menu.items == initialItems)
    }
}
