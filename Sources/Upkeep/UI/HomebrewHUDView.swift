import AppKit
import SwiftUI

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
    public var showActionMenu: Bool = false
    public var statusBanner: String?
    public var errorBanner: String?
    public var activeOperationPackageID: String?
    public var copiedPackageID: String?

    public var onCatalogChanged: (() -> Void)?
    public var onOpenInSettings: (() -> Void)?

    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    public var isOperating: Bool {
        activeOperationPackageID != nil
    }

    public var isShowingCategoryMenu: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activeTab == nil
    }

    public var selectedPackage: BrewPackageItem? {
        packages.first(where: { $0.id == selectedID }) ?? packages.first
    }

    public func loadInitial() {
        loadTask?.cancel()
        isLoading = true
        errorBanner = nil
        loadTask = Task {
            do {
                let items = try await BrewService.shared.loadInstalledAndOutdated()
                guard !Task.isCancelled else { return }
                if self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if self.activeTab == .formulae || self.activeTab == .casks {
                        self.packages = []
                        self.selectedID = nil
                    } else {
                        self.packages = filterForTab(items)
                        self.selectedID = self.packages.first?.id
                    }
                }
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.errorBanner = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    public func onQueryChanged() {
        loadTask?.cancel()
        searchTask?.cancel()
        let currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentQuery.isEmpty {
            if activeTab == .formulae || activeTab == .casks {
                self.packages = []
                self.selectedID = nil
                self.isLoading = false
                return
            }
            searchTask = Task {
                let local = await BrewService.shared.fuzzySearchLocal(query: "", filterCasks: caskFilter)
                guard !Task.isCancelled else { return }
                self.packages = filterForTab(local)
                self.selectedID = self.packages.first?.id
            }
            return
        }

        searchTask = Task {
            // Only seed from local installed packages when searching Installed/Upgrades or before remote index is warm
            let isWarm = await BrewService.shared.hasWarmRemoteIndex()
            if !isWarm || activeTab == .installed || activeTab == .upgrades {
                let local = await BrewService.shared.fuzzySearchLocal(query: currentQuery, filterCasks: caskFilter)
                guard !Task.isCancelled else { return }
                if !local.isEmpty {
                    self.packages = filterForTab(local)
                    self.selectedID = self.packages.first?.id
                }
            }

            // Skip artificial lag when the remote catalog is already warm in memory (~1-3ms search)
            let debounceMs = isWarm ? 20 : 200
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard !Task.isCancelled else { return }

            if activeTab == .installed || activeTab == .upgrades {
                self.isLoading = false
                return
            }

            if !isWarm {
                self.isLoading = true
            }
            if let remote = try? await BrewService.shared.searchRemote(query: currentQuery, filterCasks: caskFilter), !Task.isCancelled {
                self.packages = filterForTab(remote)
                self.selectedID = self.packages.first?.id
            }
            self.isLoading = false
        }
    }

    public func selectTab(_ tab: BrewHUDTab?) {
        withAnimation(.snappy(duration: 0.22)) {
            activeTab = tab
            showActionMenu = false
        }
        onQueryChanged()
    }

    public func moveSelection(delta: Int) {
        let count = min(packages.count, 60)
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
        showActionMenu = false
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
        showActionMenu = false
        runAsync(packageID: item.id, label: "Uninstalling \(item.name)…", success: "Uninstalled \(item.name)") {
            _ = try await BrewService.shared.uninstall(name: item.name, isCask: item.isCask)
        }
    }

    public func togglePin(_ item: BrewPackageItem) {
        guard !isOperating else { return }
        showActionMenu = false
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
        showActionMenu = false
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
        showActionMenu = false
        if let url = URL(string: item.homepage), !item.homepage.isEmpty {
            NSWorkspace.shared.open(url)
        }
    }

    public func runBrewDoctor() {
        guard !isOperating else { return }
        showActionMenu = false
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
                let trimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    let refreshed = try await BrewService.shared.loadInstalledAndOutdated(forceRefresh: true)
                    self.packages = filterForTab(refreshed)
                } else {
                    _ = try? await BrewService.shared.loadInstalledAndOutdated(forceRefresh: true)
                    if let remote = try? await BrewService.shared.searchRemote(query: trimmed, filterCasks: caskFilter) {
                        self.packages = filterForTab(remote)
                    }
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

/// macOS 27 Golden Gate Liquid Glass Homebrew HUD:
/// Top 60pt interactive Liquid Glass capsule + detached 20pt-radius Liquid Glass tray
/// with tiered Rust search, global ⌘1–⌘4 scope shortcuts, larger macOS 27 glass action buttons,
/// and seamless handoff to the Settings Homebrew manager.
public struct HomebrewHUDView: View {
    @Bindable var model: HomebrewHUDModel
    @Bindable var logStore = BrewLogStore.shared
    let onDismiss: () -> Void
    @FocusState private var isSearchFocused: Bool

    public init(model: HomebrewHUDModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    hudStack
                }
            } else {
                hudStack
            }
        }
        .padding(24)
        .frame(width: 736)
        .background {
            // Global shortcuts active across both category menu and search results
            Group {
                Button("") { model.selectTab(.installed) }.keyboardShortcut("1", modifiers: .command)
                Button("") { model.selectTab(.formulae) }.keyboardShortcut("2", modifiers: .command)
                Button("") { model.selectTab(.casks) }.keyboardShortcut("3", modifiers: .command)
                Button("") { model.selectTab(.upgrades) }.keyboardShortcut("4", modifiers: .command)
                Button("") {
                    if !model.isShowingCategoryMenu {
                        model.showActionMenu.toggle()
                    }
                }.keyboardShortcut("k", modifiers: .command)
                Button("") {
                    model.onOpenInSettings?()
                }.keyboardShortcut(",", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onAppear {
            isSearchFocused = true
            model.loadInitial()
            HUDCoordinator.shared.updateHomebrewPanelHeight(isCategoryMenu: model.isShowingCategoryMenu)
        }
        .onChange(of: model.isShowingCategoryMenu) { _, isCat in
            HUDCoordinator.shared.updateHomebrewPanelHeight(isCategoryMenu: isCat)
        }
        .onKeyPress(.upArrow) {
            model.moveSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(delta: 1)
            return .handled
        }
        .onExitCommand {
            if model.showActionMenu {
                model.showActionMenu = false
                isSearchFocused = true
            } else if model.activeTab != nil || !model.query.isEmpty {
                model.query = ""
                model.selectTab(nil)
                isSearchFocused = true
            } else {
                onDismiss()
            }
        }
    }

    private var hudStack: some View {
        VStack(spacing: 12) {
            searchPill
            resultsTray
        }
    }

    private var searchPlaceholder: String {
        guard let tab = model.activeTab else { return "Search Homebrew" }
        switch tab {
        case .formulae, .casks:
            return "Search \(tab.title)…"
        case .installed, .upgrades:
            return "Filter \(tab.title)…"
        }
    }

    private var searchPill: some View {
        HStack(spacing: 12) {
            if let tab = model.activeTab {
                Button {
                    model.selectTab(nil)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            TextField(
                searchPlaceholder,
                text: $model.query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 21, weight: .regular))
            .focused($isSearchFocused)
            .onChange(of: model.query) { _, _ in
                model.onQueryChanged()
            }
            .onSubmit {
                if let selected = model.selectedPackage {
                    model.performPrimaryAction(for: selected)
                }
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.onQueryChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "mug")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 26)
        .frame(height: 60)
        .upkeepGlass(in: Capsule(), interactive: true)
    }

    private var resultsTray: some View {
        VStack(spacing: 0) {
            if model.isShowingCategoryMenu {
                VStack(spacing: 2) {
                    ForEach(BrewHUDTab.allCases) { tab in
                        Button {
                            model.selectTab(tab)
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 18, weight: .regular))
                                    .frame(width: 24)
                                    .foregroundStyle(.primary)

                                Text(tab.title)
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundStyle(.primary)

                                Spacer()

                                Text(tab.shortcutLabel)
                                    .font(.system(size: 14, weight: .regular, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 22)
                            .frame(height: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)
            } else {
                if let error = model.errorBanner {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.packages.isEmpty {
                    if let tab = model.activeTab,
                       (tab == .formulae || tab == .casks),
                       model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView {
                            Label("Search Homebrew \(tab.title)", systemImage: tab.icon)
                        } description: {
                            Text("Start typing a name or keyword to search Homebrew \(tab.title.lowercased()).")
                        }
                        .frame(height: 240)
                    } else {
                        ContentUnavailableView(
                            model.isLoading ? "Searching Homebrew…" : "No Matching Packages",
                            systemImage: "shippingbox"
                        )
                        .frame(height: 240)
                    }
                } else {
                    // 58/42 Split List + Roomy Detail Pane with macOS 27 Large Glass Buttons
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(model.packages.prefix(60)) { pkg in
                                    packageRow(pkg)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        }
                        .frame(width: 400, height: 336)

                        Divider().opacity(0.25)

                        if let pkg = model.selectedPackage {
                            detailPane(for: pkg)
                                .frame(width: 288, height: 336)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.tertiary)
                                Text("Select a package")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 288, height: 336)
                        }
                    }
                }

                // Bottom Action & Live Transfer Strip with ⌘K Popover Anchor
                Divider().opacity(0.2)
                HStack(spacing: 10) {
                    if logStore.isRunning, let live = logStore.liveStatusLine {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(live)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else if let status = model.statusBanner {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("⌘1 Installed · ⌘2 Formulae · ⌘3 Casks · ⌘4 Upgrades")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button {
                        model.onOpenInSettings?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "macwindow")
                            Text("Settings")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.7), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open Homebrew in Upkeep Settings (⌘,)")

                    Button {
                        model.showActionMenu.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Actions")
                            Text("⌘K")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $model.showActionMenu, arrowEdge: .bottom) {
                        actionMenuPopover
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
            }
        }
        .upkeepGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func detailPane(for pkg: BrewPackageItem) -> some View {
        let isThisOperating = model.activeOperationPackageID == pkg.id
        let isCopied = model.copiedPackageID == pkg.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                UpkeepSettingsIcon(
                    systemName: pkg.isCask ? "app.dashed" : "terminal",
                    color: pkg.isOutdated ? .orange : MenuBarTheme.Colors.homebrew,
                    size: 30
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(pkg.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(pkg.isCask ? "Cask" : "Formula")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)

                        if !pkg.displayVersion.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(pkg.displayVersion)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if pkg.isInstalled || pkg.isPinned || pkg.isOutdated {
                HStack(spacing: 6) {
                    if pkg.isOutdated {
                        Label("Update Available", systemImage: "arrow.up.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                    } else if pkg.isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }

                    if pkg.isPinned {
                        Label("Pinned", systemImage: "pin.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                }
            }

            Text(pkg.description.isEmpty ? "No description available." : pkg.description)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if !pkg.homepage.isEmpty {
                Button {
                    model.openHomepage(pkg)
                } label: {
                    Label(pkg.homepage, systemImage: "safari")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            Spacer(minLength: 8)

            // Large macOS 27 Liquid Glass Action Buttons
            VStack(spacing: 8) {
                Button {
                    model.performPrimaryAction(for: pkg)
                } label: {
                    HStack(spacing: 7) {
                        if isThisOperating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: primaryActionIcon(for: pkg))
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        Text(primaryActionLabel(for: pkg, isOperating: isThisOperating))
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.upkeepPrimary)
                .tint(primaryActionTint(for: pkg))
                .controlSize(.large)
                .disabled(model.isOperating)

                HStack(spacing: 8) {
                    Button {
                        model.copyInstallCommand(pkg)
                    } label: {
                        Label(isCopied ? "Copied" : "Copy CLI", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.large)

                    if !pkg.homepage.isEmpty {
                        Button {
                            model.openHomepage(pkg)
                        } label: {
                            Image(systemName: "safari")
                                .font(.system(size: 13.5, weight: .medium))
                        }
                        .buttonStyle(.upkeepSecondary)
                        .controlSize(.large)
                        .help("Open Homepage")
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryActionLabel(for pkg: BrewPackageItem, isOperating: Bool) -> String {
        if isOperating {
            if pkg.isInstalled && pkg.isOutdated { return "Upgrading…" }
            if pkg.isInstalled { return "Uninstalling…" }
            return "Installing…"
        }
        if pkg.isInstalled && pkg.isOutdated { return "Upgrade" }
        if pkg.isInstalled { return "Uninstall" }
        return "Install"
    }

    private func primaryActionIcon(for pkg: BrewPackageItem) -> String {
        if pkg.isInstalled && pkg.isOutdated { return "arrow.up.circle.fill" }
        if pkg.isInstalled { return "trash" }
        return "arrow.down.circle.fill"
    }

    private func primaryActionTint(for pkg: BrewPackageItem) -> Color {
        if pkg.isInstalled && pkg.isOutdated { return .orange }
        if pkg.isInstalled { return .red }
        return .accentColor
    }

    @ViewBuilder
    private var actionMenuPopover: some View {
        if let pkg = model.selectedPackage {
            VStack(alignment: .leading, spacing: 2) {
                actionMenuRow(
                    pkg.isInstalled ? (pkg.isOutdated ? "Upgrade \(pkg.name)" : "Uninstall \(pkg.name)") : "Install \(pkg.name)",
                    icon: pkg.isInstalled ? (pkg.isOutdated ? "arrow.up.circle" : "trash") : "arrow.down.circle",
                    shortcut: "↩",
                    destructive: pkg.isInstalled && !pkg.isOutdated
                ) {
                    model.performPrimaryAction(for: pkg)
                }

                if pkg.isInstalled && !pkg.isCask {
                    actionMenuRow(
                        pkg.isPinned ? "Unpin Formula" : "Pin Formula",
                        icon: pkg.isPinned ? "pin.slash" : "pin",
                        shortcut: "⌘P"
                    ) {
                        model.togglePin(pkg)
                    }
                }

                if pkg.isInstalled && pkg.isOutdated {
                    actionMenuRow("Uninstall \(pkg.name)", icon: "trash", shortcut: "⌘⌫", destructive: true) {
                        model.uninstall(pkg)
                    }
                }

                Divider().padding(.vertical, 4)

                actionMenuRow("Copy Install Command", icon: "doc.on.doc", shortcut: "⌘C") {
                    model.copyInstallCommand(pkg)
                }

                if !pkg.homepage.isEmpty {
                    actionMenuRow("Open Homepage", icon: "safari", shortcut: "⌘O") {
                        model.openHomepage(pkg)
                    }
                }

                actionMenuRow("Open in Upkeep Settings", icon: "macwindow", shortcut: "⌘,") {
                    model.onOpenInSettings?()
                }

                actionMenuRow("Run Brew Doctor", icon: "stethoscope", shortcut: "⌘D") {
                    model.runBrewDoctor()
                }
            }
            .padding(8)
            .frame(width: 248)
        }
    }

    private func actionMenuRow(
        _ title: String,
        icon: String,
        shortcut: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer()
                Text(shortcut)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func packageRow(_ pkg: BrewPackageItem) -> some View {
        let isSelected = model.selectedID == pkg.id
        let isOperatingHere = model.activeOperationPackageID == pkg.id

        return Button {
            model.selectedID = pkg.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: pkg.isCask ? "app.dashed" : "terminal")
                    .font(.system(size: 14.5, weight: .regular))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pkg.name)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1)
                        if !pkg.displayVersion.isEmpty {
                            Text(pkg.displayVersion)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !pkg.description.isEmpty {
                        Text(pkg.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isOperatingHere {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    statusBadge(for: pkg)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusBadge(for pkg: BrewPackageItem) -> some View {
        if pkg.isOutdated {
            Text("Update")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.18), in: Capsule())
        } else if pkg.isInstalled {
            Text("Installed")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        } else {
            Text("Install")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
