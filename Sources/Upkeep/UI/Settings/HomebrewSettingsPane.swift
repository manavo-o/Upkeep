import AppKit
import SwiftUI

private enum BrewSettingsScope: String, CaseIterable, Identifiable {
    case all = "All"
    case installed = "Installed"
    case formulae = "Formulae"
    case casks = "Casks"
    case upgrades = "Upgrades"

    var id: String { rawValue }

    var hudTab: BrewHUDTab? {
        switch self {
        case .all: return nil
        case .installed: return .installed
        case .formulae: return .formulae
        case .casks: return .casks
        case .upgrades: return .upgrades
        }
    }

    var caskFilter: Bool? {
        switch self {
        case .formulae: return false
        case .casks: return true
        case .all, .installed, .upgrades: return nil
        }
    }
}

struct HomebrewSettingsPane: View {
    @Bindable var vm: TrayViewModel
    let coordinator: HUDCoordinator
    @Bindable var logStore = BrewLogStore.shared
    @Bindable var updater = UpdateManager.shared

    @State private var scope: BrewSettingsScope = .upgrades
    @State private var query: String = ""
    @State private var packages: [BrewPackageItem] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showFullLog: Bool = false
    @State private var copiedInstallCommand = false
    @State private var copiedLog = false
    @State private var packageToRemove: BrewPackageItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.upkeepSettingsReveal) private var reveal

    private static let brewInstallCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    private var isOperating: Bool {
        vm.isHomebrewBusy
    }

    var body: some View {
        UpkeepSettingsFormView {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if vm.isHomebrewBusy {
                    Button {
                        coordinator.settingsSearch.reveal("brew.log", in: .homebrew)
                    } label: {
                        Label("View Activity", systemImage: "doc.text")
                    }
                    .buttonStyle(.upkeepSecondary)
                }

                if vm.brewOutdatedCount > 0 || vm.isUpgradingBrew {
                    Button {
                        coordinator.showHomebrewUpgrade()
                    } label: {
                        UpkeepTaskLabel(
                            title: vm.brewOutdatedCount == 1 ? "Upgrade 1 Package" : "Upgrade \(vm.brewOutdatedCount) Packages",
                            systemImage: "arrow.up.circle",
                            runningTitle: "Upgrading…",
                            isRunning: vm.isUpgradingBrew
                        )
                    }
                    .buttonStyle(.upkeepPrimary)
                    .tint(UpkeepSettingsPalette.accent)
                    .controlSize(.regular)
                    .disabled(isOperating)
                }

                Button {
                    coordinator.showHomebrewHUD(
                        initialQuery: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : query,
                        initialTab: scope.hudTab
                    )
                } label: {
                    Label("Floating Search", systemImage: "macwindow.on.rectangle")
                }
                .buttonStyle(.upkeepSecondary)
                .controlSize(.regular)
                .disabled(!BrewService.isInstalled())
                .help("Open this search in the floating Homebrew window")
            }
        } content: {
            if !BrewService.isInstalled() {
                Section {
                    UpkeepSettingsCallout(
                        tone: .warning,
                        icon: "terminal.fill",
                        title: "Homebrew CLI Not Found",
                        message: "Install Homebrew in /opt/homebrew/bin or /usr/local/bin to search, install, and upgrade packages.",
                        actionTitle: copiedInstallCommand ? "Copied" : "Copy Install Command"
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.brewInstallCommand, forType: .string)
                        copiedInstallCommand = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedInstallCommand = false
                        }
                    }
                    .upkeepSearchTarget("brew.unavailable")
                }
            }

            if BrewService.isInstalled() {
                if let error = vm.brewOverviewError {
                    Section {
                        UpkeepSettingsCallout(
                            tone: .warning,
                            icon: "exclamationmark.triangle",
                            title: "Couldn’t Refresh Packages",
                            message: error,
                            actionTitle: "Refresh Packages"
                        ) {
                            vm.refreshOverview(force: true)
                        }
                    }
                }
            }

            // Unified Search & Package Downloader (Same Rust Engine as Floating HUD)
            if BrewService.isInstalled() {
                UpkeepSettingsSection(
                    "Packages",
                    footer: "\(vm.brewInstalledCount) installed · \(vm.brewOutdatedCount) with upgrades"
                ) {
                    VStack(spacing: 10) {
                        UpkeepPaneSearchField(placeholder: searchPlaceholder, text: $query)
                        .onChange(of: query) { _, _ in
                            runSearch(resetResults: true)
                        }

                        packageScopeTabs
                            .tint(UpkeepSettingsPalette.accent)
                            .labelsHidden()
                            .upkeepSearchTarget("brew.outdated")
                            .onChange(of: scope) { _, _ in
                                runSearch(resetResults: true)
                            }
                    }
                    .padding(.vertical, 2)
                    .upkeepSearchTarget("brew.hud")

                    if isSearching && packages.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Searching Homebrew catalog…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                    } else if packages.isEmpty {
                        emptyPackagesRow
                    } else {
                        ForEach(packages.prefix(24)) { pkg in
                            brewDownloaderRow(pkg)
                        }
                        if packages.count > 24 {
                            HStack {
                                Text("Showing top 24 of \(packages.count) matches")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("View All in HUD") {
                                    coordinator.showHomebrewHUD(
                                        initialQuery: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : query,
                                        initialTab: scope.hudTab
                                    )
                                }
                                .buttonStyle(.upkeepSecondary)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if BrewService.isInstalled() {
                activitySection
            }

            UpkeepSettingsSection("Homebrew Installation") {
                UpkeepStatusRow(
                    title: "Homebrew CLI",
                    description: "Required to manage Homebrew packages",
                    icon: "terminal",
                    isGranted: BrewService.isInstalled()
                )
                .upkeepSearchTarget("brew.installation")

                LabeledContent {
                    Button {
                        Task {
                            await updater.updateCLIUtilities()
                            vm.refreshOverview(force: true)
                        }
                    } label: {
                        UpkeepTaskLabel(
                            title: "Refresh Catalog",
                            systemImage: "arrow.clockwise",
                            runningTitle: "Refreshing…",
                            isRunning: updater.isUpdatingHomebrew
                        )
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.small)
                    .disabled(updater.isInstalling || isOperating || !BrewService.isInstalled())
                } label: {
                    UpkeepSettingLabel(
                        "Package Catalog",
                        subtitle: updater.homebrewUpdateMessage ?? "Fetch the latest package definitions from Homebrew."
                    )
                }
                .upkeepSearchTarget("updates.cli")
            }

            UpkeepSettingsSection("Floating Search Shortcuts") {
                LabeledContent("Switch package tabs") {
                    UpkeepKeycapGroup(["⌘1", "–", "⌘4"])
                }
                .upkeepSearchTarget("brew.shortcuts")

                LabeledContent("Show package actions") {
                    UpkeepKeycapGroup(["⌘", "K"])
                }

                LabeledContent("Close floating search") {
                    UpkeepKeycapGroup(["Esc"])
                }
            }
        }
        .alert("Uninstall Package?", isPresented: isShowingRemoval, presenting: packageToRemove) { package in
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { performPackageAction(package) }
                .disabled(isOperating)
        } message: { package in
            Text("Homebrew will uninstall \(package.name).")
        }
        .onAppear { runSearch() }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: vm.homebrewActivityRequest) {
            showUpgrades()
        }
        .onChange(of: reveal, initial: true) { _, destination in
            if destination?.target == "brew.outdated" {
                showUpgrades()
            }
        }
        .onChange(of: logStore.isRunning) { _, isRunning in
            if isRunning {
                copiedLog = false
                showFullLog = false
            } else {
                runSearch()
            }
        }
        .onChange(of: vm.brewCatalogRevision) {
            runSearch()
        }
    }

    @ViewBuilder
    private var packageScopeTabs: some View {
        let picker = Picker("Package Scope", selection: $scope) {
            ForEach(BrewSettingsScope.allCases) { scope in
                Text(scope == .upgrades && vm.brewOutdatedCount > 0
                     ? "Upgrades (\(vm.brewOutdatedCount))"
                     : scope.rawValue)
                    .tag(scope)
            }
        }

        if #available(macOS 27.0, *) {
            picker.pickerStyle(.tabs)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var activitySection: some View {
        UpkeepSettingsSection("Activity") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    activityStatus
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let log = logStore.lastLog, !isOperating {
                        Menu {
                            Button(copiedLog ? "Copied" : "Copy Output") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(log.output, forType: .string)
                                copiedLog = true
                            }
                            Button("Clear Activity") {
                                showFullLog = false
                                copiedLog = false
                                logStore.clear()
                                vm.brewErrorText = nil
                            }
                        } label: {
                            Label("Activity Actions", systemImage: "ellipsis.circle")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                if let log = logStore.lastLog, logStore.isRunning || !isOperating {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            showFullLog.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showFullLog ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 9)
                                    .accessibilityHidden(true)
                                Text("Command Output")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showFullLog ? Text("Expanded") : Text("Collapsed"))

                        if showFullLog {
                            ScrollView([.vertical, .horizontal]) {
                                Text(log.output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                            }
                            .frame(maxWidth: .infinity, maxHeight: 150, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                            .padding(.top, 6)
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(.vertical, 3)
            .animation(reduceMotion ? nil : UpkeepMotion.disclosure, value: showFullLog)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isOperating)
            .upkeepSearchTarget("brew.log")

            LabeledContent {
                Button {
                    vm.runBrewDoctor()
                } label: {
                    UpkeepTaskLabel(
                        title: "Run Diagnostics",
                        systemImage: "stethoscope",
                        runningTitle: "Running…",
                        isRunning: vm.isRunningBrewDoctor
                    )
                }
                .buttonStyle(.upkeepSecondary)
                .controlSize(.small)
                .disabled(isOperating)
            } label: {
                UpkeepSettingLabel("Diagnostics", subtitle: "Check your Homebrew installation for common problems.")
            }
            .upkeepSearchTarget("brew.diagnostics")
        }
    }

    private var activityStatus: some View {
        let log = logStore.lastLog
        let error = vm.brewErrorText
        return HStack(alignment: .top, spacing: 8) {
            if isOperating {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                let failed = log.map { !$0.succeeded } ?? (error != nil)
                Image(systemName: failed ? "exclamationmark.circle.fill" : log == nil ? "clock" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Color.orange : log == nil ? Color.secondary : Color.green)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                if isOperating {
                    Text(vm.isUpgradingBrew ? "Upgrading Homebrew packages…" :
                            vm.isRunningBrewDoctor ? "Running Homebrew diagnostics…" : "Running Homebrew command…")
                        .font(.callout.weight(.semibold))
                    if let detail = logStore.liveStatusLine ?? logStore.activeCommand {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else if let log {
                    Text(log.succeeded ? "Command completed" : "Command failed")
                        .font(.callout.weight(.semibold))
                    Text(log.command)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let error {
                    Text("Homebrew command failed")
                        .font(.callout.weight(.semibold))
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                } else {
                    Text("No recent Homebrew activity")
                        .font(.callout.weight(.medium))
                    Text("Progress and results appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var searchPlaceholder: String {
        switch scope {
        case .all: return "Search formulae & casks…"
        case .installed: return "Filter installed packages…"
        case .formulae: return "Search Homebrew formulae…"
        case .casks: return "Search Homebrew casks…"
        case .upgrades: return "Filter outdated packages…"
        }
    }

    @ViewBuilder
    private var emptyPackagesRow: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 10) {
            Image(systemName: scope == .upgrades && trimmed.isEmpty ? "checkmark.circle.fill" : "magnifyingglass")
                .foregroundStyle(scope == .upgrades && trimmed.isEmpty ? Color.green : Color.secondary)

            if !trimmed.isEmpty {
                Text("No packages matching “\(trimmed)” in \(scope.rawValue).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if scope == .upgrades {
                Text("All \(vm.brewInstalledCount) installed packages are up to date.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if scope == .formulae || scope == .casks {
                Text("Type a package name above to search Homebrew \(scope.rawValue.lowercased()).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Type a package name to search Homebrew, or switch scopes above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var isShowingRemoval: Binding<Bool> {
        Binding(
            get: { packageToRemove != nil },
            set: { if !$0 { packageToRemove = nil } }
        )
    }

    private func brewDownloaderRow(_ package: BrewPackageItem) -> some View {
        let isRemoval = package.isInstalled && !package.isOutdated
        let actionTitle = package.isOutdated ? "Upgrade" : isRemoval ? "Uninstall…" : "Install"
        let runningTitle = package.isOutdated ? "Upgrading…" : isRemoval ? "Uninstalling…" : "Installing…"

        return HStack(spacing: 12) {
            UpkeepSettingsIcon(
                systemName: package.isCask ? "app" : "terminal",
                color: TraySection.homebrew.accentColor,
                size: 30
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if package.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                }

                Text(package.description.isEmpty ? (package.isCask ? "Cask" : "Formula") : package.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            if !package.displayVersion.isEmpty {
                Text(package.displayVersion)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if vm.brewActivePackageID == package.id {
                UpkeepTaskLabel(title: "", systemImage: "", runningTitle: runningTitle, isRunning: true)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button(actionTitle) {
                    if isRemoval {
                        packageToRemove = package
                    } else {
                        performPackageAction(package)
                    }
                }
                .buttonStyle(.upkeepSecondary)
                .controlSize(.small)
                .disabled(isOperating)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func showUpgrades() {
        scope = .upgrades
        query = ""
    }

    private func runSearch(resetResults: Bool = false) {
        searchTask?.cancel()
        if resetResults { packages = [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentScope = scope

        isSearching = true
        searchTask = Task {
            if trimmed.isEmpty {
                if currentScope == .formulae || currentScope == .casks {
                    self.packages = []
                    self.isSearching = false
                    return
                }
                let local = (try? await BrewService.shared.loadInstalledAndOutdated()) ?? []
                guard !Task.isCancelled else { return }
                switch currentScope {
                case .upgrades:
                    self.packages = local.filter(\.isOutdated)
                case .installed, .all:
                    self.packages = local
                case .formulae, .casks:
                    self.packages = []
                }
                self.isSearching = false
                return
            }

            if currentScope == .installed || currentScope == .upgrades {
                _ = try? await BrewService.shared.loadInstalledAndOutdated()
                guard !Task.isCancelled else { return }
                let local = await BrewService.shared.fuzzySearchLocal(
                    query: trimmed, filterCasks: nil, outdatedOnly: currentScope == .upgrades
                )
                guard !Task.isCancelled else { return }
                self.packages = local
                self.isSearching = false
                return
            }

            let isWarm = await BrewService.shared.hasWarmRemoteIndex()
            try? await Task.sleep(for: .milliseconds(isWarm ? 20 : 180))
            guard !Task.isCancelled else { return }

            let hits = try? await BrewService.shared.searchRemote(query: trimmed, filterCasks: currentScope.caskFilter)
            guard !Task.isCancelled else { return }
            self.packages = hits ?? []
            self.isSearching = false
        }
    }

    private func performPackageAction(_ pkg: BrewPackageItem) {
        guard !isOperating else { return }
        vm.brewActivePackageID = pkg.id
        vm.brewErrorText = nil

        Task {
            do {
                if pkg.isInstalled && pkg.isOutdated {
                    _ = try await BrewService.shared.upgrade(name: pkg.commandName, isCask: pkg.isCask)
                } else if pkg.isInstalled {
                    _ = try await BrewService.shared.uninstall(name: pkg.commandName, isCask: pkg.isCask)
                } else {
                    _ = try await BrewService.shared.install(name: pkg.commandName, isCask: pkg.isCask)
                }
            } catch {
                vm.brewErrorText = error.localizedDescription
            }
            vm.refreshOverview()
            vm.brewActivePackageID = nil
        }
    }
}
