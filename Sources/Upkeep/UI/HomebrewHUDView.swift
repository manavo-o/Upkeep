import AppKit
import SwiftUI

public enum BrewHUDTab: Int, CaseIterable, Identifiable {
    case installed = 1
    case formulae = 2
    case casks = 3
    case upgrades = 4

    public var id: Int { rawValue }

    var title: String {
        switch self {
        case .installed: return "Installed"
        case .formulae: return "Formulae"
        case .casks: return "Casks"
        case .upgrades: return "Upgrades"
        }
    }

    var icon: String {
        switch self {
        case .installed: return "shippingbox"
        case .formulae: return "terminal"
        case .casks: return "app.dashed"
        case .upgrades: return "arrow.up.circle"
        }
    }

    var shortcutLabel: String { "⌘\(rawValue)" }
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

    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

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
                    self.packages = filterForTab(items)
                    self.selectedID = self.packages.first?.id
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
            Task {
                let local = await BrewService.shared.fuzzySearchLocal(query: "", filterCasks: caskFilter)
                self.packages = filterForTab(local)
                self.selectedID = self.packages.first?.id
            }
            return
        }

        searchTask = Task {
            let local = await BrewService.shared.fuzzySearchLocal(query: currentQuery, filterCasks: caskFilter)
            if !local.isEmpty {
                self.packages = filterForTab(local)
                self.selectedID = self.packages.first?.id
            }

            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }

            self.isLoading = true
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
        showActionMenu = false
        if item.isInstalled && item.isOutdated {
            runAsync(label: "Upgrading \(item.name)…", success: "Upgraded \(item.name)") {
                _ = try await BrewService.shared.upgrade(name: item.name)
            }
        } else if item.isInstalled {
            uninstall(item)
        } else {
            runAsync(label: "Installing \(item.name)…", success: "Installed \(item.name)") {
                _ = try await BrewService.shared.install(name: item.name, isCask: item.isCask)
            }
        }
    }

    public func uninstall(_ item: BrewPackageItem) {
        showActionMenu = false
        runAsync(label: "Uninstalling \(item.name)…", success: "Uninstalled \(item.name)") {
            _ = try await BrewService.shared.uninstall(name: item.name, isCask: item.isCask)
        }
    }

    public func togglePin(_ item: BrewPackageItem) {
        showActionMenu = false
        guard !item.isCask else { return }
        if item.isPinned {
            runAsync(label: "Unpinning \(item.name)…", success: "Unpinned \(item.name)") {
                _ = try await BrewService.shared.unpin(name: item.name)
            }
        } else {
            runAsync(label: "Pinning \(item.name)…", success: "Pinned \(item.name)") {
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
    }

    public func openHomepage(_ item: BrewPackageItem) {
        showActionMenu = false
        if let url = URL(string: item.homepage), !item.homepage.isEmpty {
            NSWorkspace.shared.open(url)
        }
    }

    public func runBrewDoctor() {
        showActionMenu = false
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
        }
    }

    private func runAsync(label: String, success: String, operation: @escaping () async throws -> Void) {
        statusBanner = label
        errorBanner = nil
        Task {
            do {
                try await operation()
                self.statusBanner = success
                let refreshed = try await BrewService.shared.loadInstalledAndOutdated()
                self.packages = filterForTab(refreshed)
            } catch {
                self.errorBanner = error.localizedDescription
                self.statusBanner = nil
            }
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

/// macOS 27 Golden Gate Spotlight-matched Homebrew HUD:
/// Top 60pt interactive Liquid Glass capsule + detached 20pt-radius Liquid Glass tray
/// with global ⌘1–⌘4 scope shortcuts, 60/40 split detail preview, and ⌘K Action Menu.
public struct HomebrewHUDView: View {
    @Bindable var model: HomebrewHUDModel
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
        .frame(width: 688)
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
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            TextField(
                model.activeTab == nil ? "Search Homebrew" : "Filter \(model.activeTab!.title)…",
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
        .spotlightGlass(in: Capsule(), interactive: true)
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
                    ContentUnavailableView(
                        model.isLoading ? "Searching Homebrew…" : "No Matching Packages",
                        systemImage: "shippingbox"
                    )
                    .frame(height: 220)
                } else {
                    // 60/40 Split List + Package Detail Preview Pane
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
                        .frame(width: 390, height: 300)

                        Divider().opacity(0.25)

                        if let pkg = model.selectedPackage {
                            detailPane(for: pkg)
                                .frame(width: 250, height: 300)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.tertiary)
                                Text("Select a package")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 250, height: 300)
                        }
                    }
                }

                // Bottom Action & Status Strip with ⌘K Popover Anchor
                Divider().opacity(0.2)
                HStack(spacing: 10) {
                    if let status = model.statusBanner {
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
                        model.showActionMenu.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Actions")
                            Text("⌘K")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $model.showActionMenu, arrowEdge: .bottom) {
                        actionMenuPopover
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
        }
        .spotlightGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func detailPane(for pkg: BrewPackageItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: pkg.isCask ? "app.dashed" : "terminal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(pkg.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(pkg.isCask ? "Cask" : "Formula")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                if !pkg.version.isEmpty {
                    Text(pkg.version)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                if pkg.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Text(pkg.description.isEmpty ? "No description available." : pkg.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !pkg.homepage.isEmpty {
                Button {
                    model.openHomepage(pkg)
                } label: {
                    Label(pkg.homepage, systemImage: "safari")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(pkg.isInstalled ? (pkg.isOutdated ? "Upgrade" : "Uninstall") : "Install") {
                    model.performPrimaryAction(for: pkg)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Copy CLI") {
                    model.copyInstallCommand(pkg)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionMenuPopover: some View {
        if let pkg = model.selectedPackage {
            VStack(alignment: .leading, spacing: 2) {
                actionMenuRow(
                    pkg.isInstalled ? (pkg.isOutdated ? "Upgrade \(pkg.name)" : "Reinstall / Uninstall") : "Install \(pkg.name)",
                    icon: pkg.isInstalled ? "arrow.up.circle" : "arrow.down.circle",
                    shortcut: "↩"
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

                if pkg.isInstalled {
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

                actionMenuRow("Run Brew Doctor", icon: "stethoscope", shortcut: "⌘D") {
                    model.runBrewDoctor()
                }
            }
            .padding(8)
            .frame(width: 240)
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
        return Button {
            model.selectedID = pkg.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: pkg.isCask ? "app.dashed" : "terminal")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pkg.name)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        Text(pkg.version)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !pkg.description.isEmpty {
                        Text(pkg.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                statusBadge(for: pkg)
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
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.22), in: Capsule())
        } else if pkg.isInstalled {
            Text("Installed")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Text("Install")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
