import AppKit
import SwiftUI

// MARK: - Tray Section (Apple HIG Hierarchy)

public enum TraySection: String, CaseIterable, Identifiable, Sendable {
    case controls = "Power & Input"
    case homebrew = "Homebrew"
    case cleaner = "Cleaner"
    case uninstaller = "Uninstaller"
    case updates = "Updates"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .controls: return "switch.2"
        case .homebrew: return "mug.fill"
        case .cleaner: return "sparkles"
        case .uninstaller: return "trash"
        case .updates: return "arrow.down.circle"
        }
    }

    public var subtitle: String {
        switch self {
        case .controls: return "Caffeinate sleep prevention & keyboard cleaning lock"
        case .homebrew: return "Formulae, casks, upgrades & floating search HUD"
        case .cleaner: return "Safe dry-run cache inspection and disk cleanup"
        case .uninstaller: return "Remove installed applications and support files"
        case .updates: return "Upkeep releases, CLI tools & permissions"
        }
    }

    public var accentColor: Color {
        switch self {
        case .controls: return MenuBarTheme.Colors.caffeinate
        case .homebrew: return MenuBarTheme.Colors.homebrew
        case .cleaner: return MenuBarTheme.Colors.moleClean
        case .uninstaller: return MenuBarTheme.Colors.uninstaller
        case .updates: return MenuBarTheme.Colors.success
        }
    }
}

// MARK: - Tray View Model

@MainActor
@Observable
public final class TrayViewModel {
    public var activeSection: TraySection = .controls
    public var hoveredTile: String? = nil
    public var showUpdaterPanel: Bool = false

    public var brewInstalledCount: Int = 0
    public var brewOutdatedCount: Int = 0
    public var isUpgradingBrew: Bool = false
    public var brewStatusText: String?

    // Mole Cleaner state
    public var cleanPreview: MoleCleanSummary?
    public var confirmClean: Bool = false
    public var isScanningClean: Bool = false
    public var isCleaning: Bool = false
    public var cleanError: String?

    // Mole Uninstaller state
    public var installedApps: [MoleInstalledApp] = [] {
        didSet { recomputeFilteredApps() }
    }
    public var appQuery: String = "" {
        didSet { recomputeFilteredApps() }
    }
    public private(set) var filteredApps: [MoleInstalledApp] = []
    public var includePersonalData: Bool = false
    public var isLoadingApps: Bool = false
    public var pendingUninstallApp: MoleInstalledApp?
    public var uninstallStatus: String?
    public var uninstallError: String?

    // Cleaning Mode quick options
    public var cleaningDuration: Int = 60
    public var cleaningDimScreen: Bool = true
    public var cleaningLockPointer: Bool = false

    // Caffeinate quick mode option
    public var selectedAwakeMode: KeepAwakeMode = .displayAndSystem

    public init() {}

    private func recomputeFilteredApps() {
        let q = appQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            filteredApps = installedApps
            return
        }
        filteredApps = installedApps
            .compactMap { app -> (MoleInstalledApp, Int)? in
                guard let score = SwiftFuzzyMatcher.score(query: q, candidate: app.name) else { return nil }
                return (app, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    public func refreshOverview() {
        Task {
            if let items = try? await BrewService.shared.loadInstalledAndOutdated() {
                self.brewInstalledCount = items.count
                self.brewOutdatedCount = items.filter(\.isOutdated).count
            }
        }
    }

    public func upgradeAllBrew() {
        guard !isUpgradingBrew else { return }
        isUpgradingBrew = true
        brewStatusText = "Upgrading packages…"
        Task {
            do {
                _ = try await BrewService.shared.upgrade(name: nil)
                self.brewStatusText = "All packages up to date"
                self.refreshOverview()
            } catch {
                self.brewStatusText = error.localizedDescription
            }
            self.isUpgradingBrew = false
        }
    }

    public func runMoleDryRun() {
        guard !isScanningClean else { return }
        isScanningClean = true
        confirmClean = false
        cleanError = nil
        Task {
            do {
                self.cleanPreview = try await MoleService.shared.dryRunClean()
            } catch {
                self.cleanError = error.localizedDescription
            }
            self.isScanningClean = false
        }
    }

    public func executeMoleClean() {
        guard !isCleaning else { return }
        confirmClean = false
        isCleaning = true
        cleanError = nil
        Task {
            do {
                self.cleanPreview = try await MoleService.shared.runClean()
            } catch {
                self.cleanError = error.localizedDescription
            }
            self.isCleaning = false
        }
    }

    public func loadApps(force: Bool = false) {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        uninstallError = nil
        Task {
            do {
                self.installedApps = try await MoleService.shared.listInstalledApps(forceRefresh: force)
            } catch {
                self.uninstallError = error.localizedDescription
            }
            self.isLoadingApps = false
        }
    }

    public func confirmUninstall(_ app: MoleInstalledApp) {
        uninstallError = nil
        uninstallStatus = "Removing \(app.name)…"
        pendingUninstallApp = nil
        Task {
            do {
                let message = try await MoleService.shared.uninstallApp(app, withData: includePersonalData)
                self.uninstallStatus = message
                self.installedApps.removeAll { $0.id == app.id }
            } catch {
                self.uninstallError = error.localizedDescription
                self.uninstallStatus = nil
            }
        }
    }
}

// MARK: - MenuBarView (Native macOS 27 Liquid Glass Menu — DockDoor & Handy Pattern)

/// Native macOS 27 Liquid Glass Menu Bar Menu (`MenuBarExtraStyle(.menu)`).
/// Follows Apple HIG Menu Bar Extras hierarchy + DockDoor & Handy menu architecture:
/// 1. App Identity & Live Status + Actionable Warnings (Handy pattern)
/// 2. High-Priority Quick Actions & Checkmark Submenus (Caffeinate, Clean Keys, Homebrew)
/// 3. Maintenance Utilities (Deep-links into the dedicated macOS 27 Liquid Glass Window)
/// 4. Window & Updates (`Open Upkeep…` ⌘,, `Check for Updates…`)
/// 5. App Lifecycle (`Restart Upkeep`, `Quit Upkeep` ⌘Q)
public struct MenuBarView: View {
    public let coordinator: HUDCoordinator

    @Bindable var keepAwake = KeepAwakeManager.shared
    @Bindable var cleaning = CleaningModeManager.shared
    @Bindable var updater = UpdateManager.shared
    @Bindable var vm: TrayViewModel

    public init(coordinator: HUDCoordinator) {
        self.coordinator = coordinator
        self.vm = coordinator.trayViewModel
    }

    public var body: some View {
        // 1. Identity & Live Status (Handy pattern: disabled version line + urgent notices right below)
        Text(statusHeaderTitle)
            .disabled(true)

        if !cleaning.hasAccessibility || cleaning.permissionDenied {
            Button {
                cleaning.openAccessibilitySettings()
            } label: {
                Label("Accessibility Permission Required…", systemImage: "exclamationmark.triangle")
            }
        }

        if let release = updater.availableRelease {
            Button {
                coordinator.showMainWindow(section: .updates)
            } label: {
                Label("Update Available (v\(release.version))…", systemImage: "arrow.down.circle")
            }
        }

        Divider()

        // 2. Primary System Controls (Apple HIG: most frequent actions first, submenus with checkmarks)
        Menu {
            if keepAwake.isActive {
                Button {
                    keepAwake.stop()
                } label: {
                    Label("Turn Off Caffeinate", systemImage: "power")
                }
            } else {
                Button {
                    keepAwake.start(durationMinutes: 60, mode: vm.selectedAwakeMode)
                } label: {
                    Label("Start Caffeinate (1 Hour)", systemImage: "cup.and.saucer.fill")
                }
            }

            Divider()

            caffeinateDurationItem("30 Minutes", minutes: 30)
            caffeinateDurationItem("1 Hour", minutes: 60)
            caffeinateDurationItem("2 Hours", minutes: 120)
            caffeinateDurationItem("Indefinitely", minutes: nil)

            Divider()

            Toggle(isOn: Binding(
                get: { vm.selectedAwakeMode == .displayAndSystem },
                set: { isOn in
                    let mode: KeepAwakeMode = isOn ? .displayAndSystem : .systemOnly
                    vm.selectedAwakeMode = mode
                    if keepAwake.isActive {
                        let mins = keepAwake.remainingSeconds.map { max(1, $0 / 60) }
                        keepAwake.start(durationMinutes: mins, mode: mode)
                    }
                }
            )) {
                Text("Keep Display Awake")
            }
        } label: {
            Label(caffeinateMenuTitle, systemImage: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
        }

        Menu {
            if cleaning.permissionDenied || !cleaning.hasAccessibility {
                Button {
                    cleaning.openAccessibilitySettings()
                } label: {
                    Label("Grant Accessibility Access…", systemImage: "lock.shield")
                }
            } else if cleaning.isLocked {
                Button {
                    cleaning.stop()
                } label: {
                    Label("Unlock Keyboard", systemImage: "lock.open")
                }
            } else {
                Button {
                    cleaning.start(
                        durationSeconds: vm.cleaningDuration,
                        dimScreen: vm.cleaningDimScreen,
                        lockPointer: vm.cleaningLockPointer
                    )
                } label: {
                    Label("Lock Keyboard (\(formattedCleaningDuration))", systemImage: "lock")
                }
            }

            Divider()

            cleanKeysDurationItem("30 Seconds", seconds: 30)
            cleanKeysDurationItem("60 Seconds", seconds: 60)
            cleanKeysDurationItem("2 Minutes", seconds: 120)

            Divider()

            Toggle("Dim Screen While Locked", isOn: $vm.cleaningDimScreen)
            Toggle("Lock Pointer", isOn: $vm.cleaningLockPointer)
        } label: {
            Label(cleanKeysMenuTitle, systemImage: "keyboard.badge.ellipsis")
        }

        Button {
            coordinator.showHomebrewHUD()
        } label: {
            Label("Search Homebrew…", systemImage: "shippingbox")
        }

        if vm.brewOutdatedCount > 0 {
            Button {
                vm.upgradeAllBrew()
            } label: {
                Label("Upgrade \(vm.brewOutdatedCount) Outdated Packages", systemImage: "arrow.up.circle")
            }
            .disabled(vm.isUpgradingBrew)
        }

        Divider()

        // 3. Maintenance Utilities (Deep-links into dedicated macOS 27 native window)
        Button {
            coordinator.showMainWindow(section: .cleaner)
        } label: {
            Label("Cleaner…", systemImage: "sparkle")
        }

        Button {
            coordinator.showMainWindow(section: .uninstaller)
        } label: {
            Label("Uninstaller…", systemImage: "eject")
        }

        Divider()

        // 4. App Window & Updates (DockDoor + Handy pattern)
        Button {
            coordinator.showMainWindow(section: .controls)
        } label: {
            Label("Open Upkeep…", systemImage: "macwindow")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
            coordinator.showMainWindow(section: .updates, triggerUpdateCheck: true)
        } label: {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        // 5. App Lifecycle (DockDoor + Apple HIG standard)
        Button {
            coordinator.restartApp()
        } label: {
            Label("Restart Upkeep", systemImage: "arrow.clockwise")
        }

        Button {
            coordinator.quitApp()
        } label: {
            Label("Quit Upkeep", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Menu Helpers

    private var statusHeaderTitle: String {
        if keepAwake.isActive {
            return "Upkeep v\(updater.currentVersion) · Awake \(keepAwake.formattedRemaining)"
        }
        if cleaning.isLocked {
            return "Upkeep v\(updater.currentVersion) · Locked \(cleaning.remainingSeconds)s"
        }
        return "Upkeep v\(updater.currentVersion)"
    }

    private var caffeinateMenuTitle: String {
        keepAwake.isActive ? "Caffeinate (\(keepAwake.formattedRemaining))" : "Caffeinate"
    }

    private var cleanKeysMenuTitle: String {
        cleaning.isLocked ? "Clean Keys (\(cleaning.remainingSeconds)s)" : "Clean Keys"
    }

    private var formattedCleaningDuration: String {
        vm.cleaningDuration == 120 ? "2m" : "\(vm.cleaningDuration)s"
    }

    private func caffeinateDurationItem(_ title: String, minutes: Int?) -> some View {
        let isSelected: Bool = {
            guard keepAwake.isActive else { return false }
            guard let minutes else { return keepAwake.remainingSeconds == nil }
            guard let rem = keepAwake.remainingSeconds else { return false }
            return abs(rem - (minutes * 60)) <= 60
        }()

        return Toggle(title, isOn: Binding(
            get: { isSelected },
            set: { _ in
                keepAwake.start(durationMinutes: minutes, mode: vm.selectedAwakeMode)
            }
        ))
    }

    private func cleanKeysDurationItem(_ title: String, seconds: Int) -> some View {
        Toggle(title, isOn: Binding(
            get: { vm.cleaningDuration == seconds },
            set: { _ in
                vm.cleaningDuration = seconds
            }
        ))
    }
}
