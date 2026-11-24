import AppKit
import Observation

public enum BrewHUDTab: Int, CaseIterable, Identifiable {
    case installed = 1
    case formulae = 2
    case casks = 3
    case upgrades = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .installed: return "Installed"
        case .formulae: return "Formulae"
        case .casks: return "Casks"
        case .upgrades: return "Upgrades"
        }
    }

    public var icon: String {
        switch self {
        case .installed: return "shippingbox"
        case .formulae: return "terminal"
        case .casks: return "app.dashed"
        case .upgrades: return "arrow.up.circle"
        }
    }

    public var shortcutLabel: String { "⌘\(rawValue)" }
}

@MainActor
@Observable
public final class HomebrewHUDModel {
    public var query: String = ""
    public var activeTab: BrewHUDTab? = nil
    public var packages: [BrewPackageItem] = []
    public var selectedID: String?
    public var isLoading: Bool = false
    public var statusBanner: String?
    public var errorBanner: String?
    public var activeOperationPackageID: String?
    public var copiedPackageID: String?

    public var onCatalogChanged: (() -> Void)?
    public var onOpenInSettings: (() -> Void)?

    private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var lastQueryChange: ContinuousClock.Instant?
    private var isPresented = false

    public var isOperating: Bool {
        activeOperationPackageID != nil || BrewLogStore.shared.isRunning
    }

    public var isShowingCategoryMenu: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activeTab == nil
    }

    public var selectedPackage: BrewPackageItem? {
        packages.first(where: { $0.id == selectedID }) ?? packages.first
    }

    func prepareForShow(query: String, tab: BrewHUDTab?) {
        isPresented = true
        self.query = query
        activeTab = tab
        statusBanner = nil
        onQueryChanged(resetResults: true)
    }

    public func resetForHide() {
        isPresented = false
        searchTask?.cancel()
        searchTask = nil
        lastQueryChange = nil
        query = ""
        activeTab = nil
        packages.removeAll()
        selectedID = nil
        isLoading = false
    }

    public func onQueryChanged() {
        onQueryChanged(resetResults: false)
    }

    private func onQueryChanged(resetResults: Bool) {
        searchTask?.cancel()
        searchTask = nil
        errorBanner = nil
        let currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = ContinuousClock.now
        let isRapidInput = !resetResults && lastQueryChange.map {
            $0.duration(to: now) < .milliseconds(40)
        } == true
        lastQueryChange = currentQuery.isEmpty || resetResults ? nil : now
        if resetResults || currentQuery.isEmpty {
            packages = []
            selectedID = nil
        }
        guard !isShowingCategoryMenu,
              !(currentQuery.isEmpty && (activeTab == .formulae || activeTab == .casks)) else {
            isLoading = false
            return
        }

        if currentQuery.isEmpty {
            isLoading = true
            searchTask = Task {
                do {
                    let items = try await BrewService.shared.loadInstalledAndOutdated()
                    guard !Task.isCancelled else { return }
                    packages = filterForTab(items)
                    selectedID = packages.first?.id
                } catch {
                    guard !Task.isCancelled else { return }
                    errorBanner = error.localizedDescription
                }
                isLoading = false
            }
            return
        }

        searchTask = Task {
            let isWarm = await BrewService.shared.hasWarmRemoteIndex()
            guard !Task.isCancelled else { return }
            let localOnly = activeTab == .installed || activeTab == .upgrades
            if !isWarm || localOnly {
                if localOnly {
                    _ = try? await BrewService.shared.loadInstalledAndOutdated()
                    guard !Task.isCancelled else { return }
                }
                let local = await BrewService.shared.fuzzySearchLocal(query: currentQuery, filterCasks: caskFilter)
                guard !Task.isCancelled else { return }
                packages = filterForTab(local)
                selectedID = packages.first?.id
            }

            if localOnly {
                isLoading = false
                return
            }

            // Coalesce only sub-frame input bursts. First queries, pastes, and scope changes run immediately.
            isLoading = !isWarm
            if isWarm && isRapidInput {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
            }

            let remote = try? await BrewService.shared.searchRemote(query: currentQuery, filterCasks: caskFilter)
            guard !Task.isCancelled else { return }
            if let remote {
                packages = filterForTab(remote)
                selectedID = packages.first?.id
            }
            isLoading = false
        }
    }

    public func selectTab(_ tab: BrewHUDTab?) {
        activeTab = tab
        onQueryChanged(resetResults: true)
    }

    public func moveSelection(delta: Int) {
        let count = min(packages.count, 40)
        guard count > 0 else { return }
        guard let current = selectedID,
              let idx = packages.prefix(count).firstIndex(where: { $0.id == current }) else {
            selectedID = packages.first?.id
            return
        }
        let nextIdx = max(0, min(count - 1, idx + delta))
        selectedID = packages[nextIdx].id
    }

    public func performPrimaryAction(for item: BrewPackageItem) {
        guard !isOperating else { return }
        if item.isInstalled && item.isOutdated {
            runAsync(packageID: item.id, label: "Upgrading \(item.name)…", success: "Upgraded \(item.name)") {
                _ = try await BrewService.shared.upgrade(name: item.name)
            }
        } else if item.isInstalled {
            uninstall(item)
        } else {
            runAsync(packageID: item.id, label: "Installing \(item.name)…", success: "Installed \(item.name)") {
                _ = try await BrewService.shared.install(name: item.name, isCask: item.isCask)
            }
        }
    }

    public func uninstall(_ item: BrewPackageItem) {
        guard !isOperating else { return }
        runAsync(packageID: item.id, label: "Uninstalling \(item.name)…", success: "Uninstalled \(item.name)") {
            _ = try await BrewService.shared.uninstall(name: item.name, isCask: item.isCask)
        }
    }

    public func togglePin(_ item: BrewPackageItem) {
        guard !isOperating else { return }
        guard !item.isCask else { return }
        if item.isPinned {
            runAsync(packageID: item.id, label: "Unpinning \(item.name)…", success: "Unpinned \(item.name)") {
                _ = try await BrewService.shared.unpin(name: item.name)
            }
        } else {
            runAsync(packageID: item.id, label: "Pinning \(item.name)…", success: "Pinned \(item.name)") {
                _ = try await BrewService.shared.pin(name: item.name)
            }
        }
    }

    public func copyInstallCommand(_ item: BrewPackageItem) {
        let cmd = item.isCask ? "brew install --cask \(item.name)" : "brew install \(item.name)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        statusBanner = "Copied `\(cmd)`"
        copiedPackageID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if self.copiedPackageID == item.id {
                self.copiedPackageID = nil
            }
        }
    }

    public func openHomepage(_ item: BrewPackageItem) {
        if let url = URL(string: item.homepage), !item.homepage.isEmpty {
            NSWorkspace.shared.open(url)
        }
    }

    public func runBrewDoctor() {
        guard !isOperating else { return }
        activeOperationPackageID = "__doctor__"
        statusBanner = "Running `brew doctor`…"
        errorBanner = nil
        Task {
            do {
                let output = try await BrewService.shared.runDoctor()
                let firstLine = output.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? "Your system is ready to brew."
                self.statusBanner = firstLine
            } catch {
                self.errorBanner = error.localizedDescription
                self.statusBanner = nil
            }
            self.activeOperationPackageID = nil
        }
    }

    private func runAsync(
        packageID: String,
        label: String,
        success: String,
        operation: @escaping () async throws -> Void
    ) {
        activeOperationPackageID = packageID
        statusBanner = label
        errorBanner = nil
        Task {
            do {
                try await operation()
                self.statusBanner = success
                self.onCatalogChanged?()
                _ = try await BrewService.shared.loadInstalledAndOutdated(forceRefresh: true)
                if self.isPresented {
                    self.onQueryChanged()
                }
            } catch {
                self.errorBanner = error.localizedDescription
                self.statusBanner = nil
            }
            self.activeOperationPackageID = nil
        }
    }

    private var caskFilter: Bool? {
        switch activeTab {
        case .formulae: return false
        case .casks: return true
        case .installed, .upgrades, .none: return nil
        }
    }

    private func filterForTab(_ items: [BrewPackageItem]) -> [BrewPackageItem] {
        switch activeTab {
        case .installed, .none: return items
        case .formulae: return items.filter { !$0.isCask }
        case .casks: return items.filter { $0.isCask }
        case .upgrades: return items.filter { $0.isOutdated }
        }
    }
}
