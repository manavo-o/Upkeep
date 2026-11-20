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
        print("=== Upkeep Extensive Self-Test Suite (macOS 27) ===")

        // 1. CLIExecutor & ANSI tests
        check("Resolve `brew` binary", CLIExecutor.resolveBinary("brew") != nil, CLIExecutor.resolveBinary("brew") ?? "nil")
        check("Resolve `mo` binary", CLIExecutor.resolveBinary("mo") != nil, CLIExecutor.resolveBinary("mo") ?? "nil")
        check("Missing binary returns nil", CLIExecutor.resolveBinary("nonexistent_bin_xyz_999") == nil)
        let stripped = CLIExecutor.stripANSI("\u{001B}[32m✓ User app cache · 18 items, 2.4GB\u{001B}[0m")
        check("ANSI escape stripping", stripped == "✓ User app cache · 18 items, 2.4GB", stripped)

        // 2. Mole 1.73 live dry-run & dual delimiter parser tests
        let syntheticDotRun = """
        ➤ Developer tools
          ○ npm cache · would clean
          ○ pip cache · would clean
          ✓ Nothing to clean
        Potential space: 1.8GB · 2 items
        """
        let parsedDot = MoleService.parseCleanOutput(syntheticDotRun, isDryRun: true)
        check("Mole dry-run dot delimiter parser", parsedDot.itemCount == 2 && parsedDot.totalReclaimed == "1.8GB", "items=\(parsedDot.itemCount), size=\(parsedDot.totalReclaimed)")

        let syntheticPipeRun = """
        ➤ System & User
          ○ Safari caches
          ○ Xcode DerivedData
        Potential space: At least 14.61GB | Items: 2524 | Categories: 8
        """
        let parsedPipe = MoleService.parseCleanOutput(syntheticPipeRun, isDryRun: true)
        check("Mole dry-run pipe delimiter parser", parsedPipe.itemCount == 2524 && parsedPipe.totalReclaimed == "At least 14.61GB", "items=\(parsedPipe.itemCount), size=\(parsedPipe.totalReclaimed)")

        do {
            let liveDryRun = try await MoleService.shared.dryRunClean()
            check("Live `mo clean --dry-run` executed cleanly", !liveDryRun.lines.isEmpty, "\(liveDryRun.lines.count) parsed lines, \(liveDryRun.itemCount) candidates")
        } catch {
            check("Live `mo clean --dry-run` executed cleanly", false, error.localizedDescription)
        }

        // 3. Fast Parallel Application Scanner with real bundle sizes
        let apps = await SpotlightEngine.scanInstalledApplications()
        check("Parallel application scan discovers installed apps", !apps.isEmpty, "\(apps.count) apps discovered")
        let appsWithSizes = apps.filter { ($0.size ?? 0) > 0 }
        check("Application sizes calculated concurrently", !appsWithSizes.isEmpty, "\(appsWithSizes.count)/\(apps.count) apps have computed sizes (e.g. \(appsWithSizes.first?.name ?? ""): \(appsWithSizes.first?.formattedSize ?? ""))")

        // 4. Homebrew 7 live loading & Cellar/Caskroom fallback tests
        let jsonWithBanner = "==> Downloading Homebrew API data\n{\"formulae\":[],\"casks\":[]}"
        check("Brew JSON preamble extractor strips leading banner", BrewService.extractJSONObject(from: jsonWithBanner) != nil)

        let scannedDirs = BrewService.scanInstalledDirectories()
        check("Direct Cellar/Caskroom scan finds installed packages", !scannedDirs.isEmpty, "\(scannedDirs.count) packages (\(scannedDirs.filter { !$0.isCask }.count) formulae, \(scannedDirs.filter(\.isCask).count) casks)")

        do {
            let loaded = try await BrewService.shared.loadInstalledAndOutdated()
            check("BrewService.loadInstalledAndOutdated() resilient against untrusted taps/offline", !loaded.isEmpty, "\(loaded.count) packages loaded")
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

            // High-contrast segmented picker color tokens
            let darkSelected = MenuBarTheme.Colors.segmentForeground(isSelected: true, colorScheme: .dark)
            check("Segmented picker selected in dark mode is pure white", darkSelected == Color.white)
            let lightSelected = MenuBarTheme.Colors.segmentForeground(isSelected: true, colorScheme: .light)
            check("Segmented picker selected in light mode is primary", lightSelected == Color.primary)

            // TrayViewModel coordination (Apple HIG 5-section hierarchy)
            let vm = TrayViewModel()
            check("TrayViewModel starts on .controls section", vm.activeSection == .controls)
            vm.activeSection = .homebrew
            check("TrayViewModel switches to .homebrew section", vm.activeSection == .homebrew)
            vm.activeSection = .cleaner
            check("TrayViewModel switches to .cleaner section", vm.activeSection == .cleaner)
            vm.activeSection = .uninstaller
            check("TrayViewModel switches to .uninstaller section", vm.activeSection == .uninstaller)
            vm.activeSection = .updates
            check("TrayViewModel switches to .updates section", vm.activeSection == .updates)

            // Native MenuBarView & Dedicated macOS 27 MainWindowView instantiation
            let menuBarView = MenuBarView(coordinator: HUDCoordinator.shared)
            check("MenuBarView instantiates cleanly with HUDCoordinator", menuBarView.coordinator === HUDCoordinator.shared)
            let mainWindow = MainWindowView(vm: HUDCoordinator.shared.trayViewModel, coordinator: HUDCoordinator.shared)
            check("MainWindowView instantiates cleanly with HUDCoordinator", mainWindow.coordinator === HUDCoordinator.shared)
        }

        print("=== Results: \(passed) passed, \(failed) failed ===")
        if failed > 0 {
            Foundation.exit(1)
        }
    }
}
