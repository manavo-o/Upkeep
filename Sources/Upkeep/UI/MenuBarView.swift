import AppKit
import SwiftUI

// MARK: - Tray Section (Apple HIG Hierarchy)

public enum TraySection: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case updates = "Updates"
    case controls = "Power & Input"
    case cleanKeys = "Clean Keys"
    case homebrew = "Homebrew"
    case cleaner = "Cleaner"
    case uninstaller = "Uninstaller"

    public var id: String { rawValue }

    var settingsTitle: String {
        switch self {
        case .controls: "Caffeinate"
        case .updates: "About & Updates"
        default: rawValue
        }
    }

    public var icon: String {
        switch self {
        case .general: return "gearshape"
        case .controls: return "cup.and.saucer"
        case .cleanKeys: return "keyboard"
        case .homebrew: return "shippingbox"
        case .cleaner: return "sparkles"
        case .uninstaller: return "trash"
        case .updates: return "info.circle"
        }
    }

    public var subtitle: String {
        switch self {
        case .general: return "Interface preferences and keyboard shortcuts."
        case .controls: return "Choose when your Mac and display stay awake."
        case .cleanKeys: return "Pause input while you clean your keyboard and trackpad."
        case .homebrew: return "Find, install, and upgrade packages."
        case .cleaner: return "Review caches and temporary files to free up space."
        case .uninstaller: return "Review apps and their related files before removing them."
        case .updates: return "Manage Upkeep releases and check permissions."
        }
    }

    public var accentColor: Color {
        switch self {
        case .general: return .secondary
        case .controls: return UpkeepSettingsPalette.accent
        case .cleanKeys: return UpkeepSettingsPalette.accent
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
    public var activeSection: TraySection = .general
    var homebrewActivityRequest = 0
    public var hoveredTile: String? = nil
    public var showUpdaterPanel: Bool = false

    public var brewInstalledCount: Int = 0
    public var brewOutdatedCount: Int = 0
    public var isRefreshingBrew: Bool = false
    public var isUpgradingBrew: Bool = false
    public var isRunningBrewDoctor: Bool = false
    public var brewStatusText: String?
    public var brewErrorText: String?
    public var brewOverviewError: String?
    private(set) var brewCatalogRevision = 0
    var brewActivePackageID: String?
    private var needsForcedBrewRefresh = false

    var isHomebrewBusy: Bool {
        isUpgradingBrew || isRunningBrewDoctor || brewActivePackageID != nil
            || UpdateManager.shared.isUpdatingHomebrew || BrewLogStore.shared.isRunning
    }

    // Native Cleaner state
    public var cleanerScan: CleanerScanResult? {
        didSet { recomputeCleanSelectionMetrics() }
    }
    public var selectedCleanPaths: Set<String> = [] {
        didSet { recomputeCleanSelectionMetrics() }
    }
    public var lastCleanResult: CleanExecutionResult?
    public var cleanPreview: MoleCleanSummary?
    public var confirmClean: Bool = false
    public var isScanningClean: Bool = false
    public var isCleaning: Bool = false
    public var cleanError: String?

    // Cached selection metrics so SwiftUI body renders never run flatMap + ByteCountFormatter per hover.
    public private(set) var selectedCleanBytes: Int64 = 0
    public private(set) var hasSelectedAdminCleanItems: Bool = false
    public private(set) var formattedSelectedCleanSize: String = "Zero KB"

    private func recomputeCleanSelectionMetrics() {
        guard let scan = cleanerScan, !selectedCleanPaths.isEmpty else {
            selectedCleanBytes = 0
            hasSelectedAdminCleanItems = false
            formattedSelectedCleanSize = "Zero KB"
            return
        }
        var bytes: Int64 = 0
        var hasAdmin = false
        for category in scan.categories {
            for item in category.items where selectedCleanPaths.contains(item.path) {
                bytes += item.sizeBytes
                if item.requiresAdmin { hasAdmin = true }
            }
        }
        selectedCleanBytes = bytes
        hasSelectedAdminCleanItems = hasAdmin
        formattedSelectedCleanSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Releases large scan/app arrays when the Settings window closes to keep menu-bar idle RAM low.
    public func releaseTransientCaches() {
        if !isScanningClean && !isCleaning {
            cleanerScan = nil
            cleanPreview = nil
            selectedCleanPaths.removeAll()
            confirmClean = false
        }
        if !isLoadingApps && !isInspectingUninstall && !isUninstallingApp && pendingUninstallApp == nil {
            installedApps.removeAll()
        }
    }

    public enum AppSortOrder: String, CaseIterable, Identifiable, Sendable {
        case name = "Name"
        case size = "Size"
        public var id: String { rawValue }
    }

    // Mole Uninstaller state
    public var installedApps: [MoleInstalledApp] = [] {
        didSet { recomputeFilteredApps() }
    }
    public var appQuery: String = "" {
        didSet { recomputeFilteredApps() }
    }
    public var appSortOrder: AppSortOrder = .name {
        didSet { recomputeFilteredApps() }
    }
    public private(set) var filteredApps: [MoleInstalledApp] = []
    public var includePersonalData: Bool = false
    public var isLoadingApps: Bool = false
    public private(set) var isUpdatingAppSizes: Bool = false
    public var pendingUninstallApp: MoleInstalledApp?
    public var uninstallInspection: UninstallInspection?
    public var isInspectingUninstall: Bool = false
    public var isUninstallingApp: Bool = false
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
        var base: [MoleInstalledApp]
        if q.isEmpty {
            base = installedApps
        } else {
            base = installedApps
                .compactMap { app -> (MoleInstalledApp, Int)? in
                    guard let score = SwiftFuzzyMatcher.score(query: q, candidate: app.name) else { return nil }
                    return (app, score)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        if appSortOrder == .size {
            base.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        }
        filteredApps = base
    }

    public func refreshOverview(force: Bool = false) {
        if isRefreshingBrew {
            needsForcedBrewRefresh = needsForcedBrewRefresh || force
            return
        }
        guard BrewService.isInstalled() else {
            brewInstalledCount = 0
            brewOutdatedCount = 0
            return
        }
        isRefreshingBrew = true
        Task {
            do {
                let items = try await BrewService.shared.loadInstalledAndOutdated(forceRefresh: force)
                self.brewInstalledCount = items.count
                self.brewOutdatedCount = items.filter(\.isOutdated).count
                self.brewOverviewError = nil
                self.brewCatalogRevision += 1
            } catch {
                self.brewOverviewError = error.localizedDescription
            }
            self.isRefreshingBrew = false
            if self.needsForcedBrewRefresh {
                self.needsForcedBrewRefresh = false
                self.refreshOverview(force: true)
            }
        }
    }

    public func upgradeAllBrew() {
        guard !isHomebrewBusy, BrewService.isInstalled() else { return }
        isUpgradingBrew = true
        brewErrorText = nil
        brewStatusText = "Upgrading packages…"
        Task {
            do {
                _ = try await BrewService.shared.upgrade(name: nil)
                self.brewStatusText = "Package upgrade finished"
            } catch {
                self.brewStatusText = nil
                self.brewErrorText = error.localizedDescription
            }
            self.refreshOverview()
            self.isUpgradingBrew = false
        }
    }

    public func runBrewDoctor() {
        guard !isHomebrewBusy else { return }
        isRunningBrewDoctor = true
        brewErrorText = nil
        Task {
            do {
                _ = try await BrewService.shared.runDoctor()
            } catch {
                self.brewErrorText = error.localizedDescription
            }
            self.isRunningBrewDoctor = false
        }
    }

    public func runMoleDryRun() {
        guard !isScanningClean else { return }
        isScanningClean = true
        confirmClean = false
        cleanError = nil
        lastCleanResult = nil
        Task {
            let scan = await MoleService.shared.scanCleanerNative()
            self.cleanerScan = scan
            self.selectedCleanPaths = scan.defaultSelectedPaths
            self.cleanPreview = scan.toSummary()
            self.isScanningClean = false
        }
    }

    public func executeMoleClean() {
        guard !isCleaning else { return }
        let allItems = cleanerScan?.allItems ?? []
        let adminSet = Set(allItems.filter(\.requiresAdmin).map(\.path))
        let userTargets = selectedCleanPaths.filter { !adminSet.contains($0) }
        let adminTargets = selectedCleanPaths.filter { adminSet.contains($0) }
        guard !userTargets.isEmpty || !adminTargets.isEmpty else { return }
        confirmClean = false
        isCleaning = true
        cleanError = nil
        Task {
            let exec = await MoleService.shared.executeNativeClean(
                paths: Array(userTargets),
                adminPaths: Array(adminTargets),
                dryRun: false
            )
            self.lastCleanResult = exec
            let refreshed = await MoleService.shared.scanCleanerNative()
            self.cleanerScan = refreshed
            self.selectedCleanPaths = refreshed.defaultSelectedPaths
            self.cleanPreview = MoleCleanSummary(
                totalReclaimed: exec.formattedReclaimedSize,
                itemCount: exec.removedCount,
                lines: refreshed.toSummary().lines,
                isDryRun: false
            )
            self.isCleaning = false
        }
    }

    public func loadApps(force: Bool = false) {
        guard !isLoadingApps && !isUpdatingAppSizes else { return }
        isLoadingApps = true
        uninstallError = nil
        Task {
            // Phase 1: instant app list (<15ms) when empty so UI never blocks on large bundles like Xcode
            if self.installedApps.isEmpty {
                let quickApps = await UpkeepEngine.scanInstalledApplicationsMetadata()
                if !quickApps.isEmpty {
                    self.installedApps = quickApps
                    self.isLoadingApps = false
                }
            }
            // Phase 2: populate APFS-accurate bundle sizes in parallel
            self.isUpdatingAppSizes = true
            defer { self.isUpdatingAppSizes = false }
            do {
                self.installedApps = try await MoleService.shared.listInstalledApps(forceRefresh: force)
            } catch {
                self.uninstallError = error.localizedDescription
            }
            self.isLoadingApps = false
        }
    }

    public func inspectForUninstall(_ app: MoleInstalledApp) {
        guard !isInspectingUninstall else { return }
        pendingUninstallApp = app
        uninstallInspection = nil
        isInspectingUninstall = true
        uninstallError = nil
        Task {
            let result = await MoleService.shared.inspectAppForUninstall(app)
            if self.pendingUninstallApp?.id == app.id {
                self.uninstallInspection = result
            }
            self.isInspectingUninstall = false
        }
    }

    public func cancelUninstallReview() {
        pendingUninstallApp = nil
        uninstallInspection = nil
        isInspectingUninstall = false
    }

    public func executeReviewedUninstall(selectedLeftoverPaths: Set<String>, useHomebrewCask: Bool) {
        guard let inspection = uninstallInspection, !isUninstallingApp else { return }
        let app = inspection.app
        let caskToken = useHomebrewCask ? inspection.homebrewCaskToken : nil

        isUninstallingApp = true
        uninstallError = nil
        uninstallStatus = caskToken != nil
            ? "Uninstalling \(app.name) via Homebrew…"
            : "Removing \(app.name)…"

        Task {
            do {
                let message = try await MoleService.shared.uninstallReviewedApp(
                    app,
                    selectedLeftoverPaths: selectedLeftoverPaths,
                    homebrewCaskToken: caskToken,
                    hasSiblingApp: inspection.hasSiblingApp
                )
                self.uninstallStatus = message
                self.installedApps.removeAll { $0.id == app.id }
                self.pendingUninstallApp = nil
                self.uninstallInspection = nil
                if caskToken != nil {
                    self.refreshOverview(force: true)
                }
            } catch {
                self.uninstallError = error.localizedDescription
                self.uninstallStatus = nil
            }
            self.isUninstallingApp = false
        }
    }

    public func confirmUninstall(_ app: MoleInstalledApp) {
        guard !isUninstallingApp else { return }
        isUninstallingApp = true
        uninstallError = nil
        uninstallStatus = "Removing \(app.name)…"
        pendingUninstallApp = nil
        Task {
            defer { self.isUninstallingApp = false }
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
