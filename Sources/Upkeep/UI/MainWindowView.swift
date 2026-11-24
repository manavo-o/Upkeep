import AppKit
import SwiftUI

/// Dedicated macOS 27 Native Settings & Utility Window for Upkeep.
/// Modeled on Canapé, DockDoor, Handy, and Apple System Settings:
/// - Compact 780×560 default window with minimalist 208pt sidebar, pinned Liquid Glass Search (`⌘F`),
///   bespoke squircle section badges, and crisp version footer
/// - Frameless Canapé-style pane headers aligned directly with the macOS traffic lights (zero dead
///   titlebar band or orphaned toolbar icons)
/// - Centered grouped reading columns with left-aligned footers, zero per-row icon clutter, and
///   inline `(i)` popovers
/// - Revamped Homebrew Downloader seamlessly wired to the floating Liquid Glass Search HUD
public struct MainWindowView: View {
    @Bindable public var vm: TrayViewModel
    public let coordinator: HUDCoordinator

    @Bindable var keepAwake = KeepAwakeManager.shared
    @Bindable var cleaning = CleaningModeManager.shared
    @Bindable var updater = UpdateManager.shared

    @State private var searchEngine = UpkeepSearchEngine()
    @State private var scrollTarget: String?
    @FocusState private var isSearchFieldFocused: Bool

    public init(vm: TrayViewModel, coordinator: HUDCoordinator) {
        self.vm = vm
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detailPane
        }
        .background {
            Button("Find") {
                isSearchFieldFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .onAppear {
            vm.selectedAwakeMode = keepAwake.mode
            cleaning.refreshPermissionStatus()
            updater.checkIfDue()
            handleSectionAppear(vm.activeSection)
        }
        .onChange(of: vm.activeSection) { _, newSection in
            if searchEngine.isSearching {
                searchEngine.query = ""
            }
            handleSectionAppear(newSection)
        }
    }

    // MARK: - Minimalist Native macOS Sidebar (Canapé + DockDoor Pattern)

    private var sidebar: some View {
        List(selection: $vm.activeSection) {
            Section("System") {
                sidebarRow(.controls)
                sidebarRow(.homebrew)
            }

            Section("Maintenance") {
                sidebarRow(.cleaner)
                sidebarRow(.uninstaller)
            }

            Section("App") {
                sidebarRow(.updates)
            }
        }
        .listStyle(.sidebar)
        .upkeepSoftTopScrollEdge()
        .safeAreaInset(edge: .top, spacing: 0) {
            sidebarSearchField
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Text("Upkeep")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("v\(updater.currentVersion)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer()
                if updater.hasUpdateAvailable {
                    Button("Update") {
                        vm.activeSection = .updates
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 208, ideal: 208, max: 208)
        .toolbar(removing: .sidebarToggle)
    }

    private func sidebarRow(_ section: TraySection) -> some View {
        let isSelected = !searchEngine.isSearching && vm.activeSection == section

        return HStack(spacing: 10) {
            UpkeepSectionIcon(section: section, size: 21)

            Text(section.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 4)

            if section == .controls && (keepAwake.isActive || cleaning.isLocked) {
                Circle()
                    .fill(isSelected ? Color.white : (keepAwake.isActive ? MenuBarTheme.Colors.caffeinate : MenuBarTheme.Colors.cleanKeys))
                    .frame(width: 6.5, height: 6.5)
            } else if section == .homebrew && vm.brewOutdatedCount > 0 {
                Text("\(vm.brewOutdatedCount)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        isSelected ? Color.white.opacity(0.24) : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            } else if section == .updates && updater.hasUpdateAvailable {
                Circle()
                    .fill(isSelected ? Color.white : MenuBarTheme.Colors.success)
                    .frame(width: 6.5, height: 6.5)
            }
        }
        .padding(.vertical, 2)
        .tag(section)
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search settings…", text: $searchEngine.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isSearchFieldFocused)
                .onExitCommand {
                    if !searchEngine.query.isEmpty {
                        searchEngine.query = ""
                    }
                    isSearchFieldFocused = false
                }

            if !searchEngine.query.isEmpty {
                Button {
                    searchEngine.query = ""
                    isSearchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(in: Capsule())
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Detail Content Area

    @ViewBuilder
    private var detailPane: some View {
        if searchEngine.isSearching {
            UpkeepSearchResultsView(engine: searchEngine) { item in
                vm.activeSection = item.tab
                searchEngine.query = ""
                isSearchFieldFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    scrollTarget = item.id
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            sectionView(for: vm.activeSection)
                .environment(\.upkeepScrollTarget, scrollTarget)
                .onChange(of: scrollTarget) { _, newTarget in
                    if newTarget != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            scrollTarget = nil
                        }
                    }
                }
        }
    }

    private func sectionView(for section: TraySection) -> AnyView {
        // Keep inactive panes out of the enclosing view's generic type graph.
        switch section {
        case .controls:
            AnyView(PowerAndInputSettingsPane(vm: vm, keepAwake: keepAwake, cleaning: cleaning))
        case .homebrew:
            AnyView(HomebrewSettingsPane(vm: vm, coordinator: coordinator))
        case .cleaner:
            AnyView(CleanerWorkspacePane(vm: vm))
        case .uninstaller:
            AnyView(UninstallerWorkspacePane(vm: vm))
        case .updates:
            AnyView(UpdatesSettingsPane(updater: updater, cleaning: cleaning, vm: vm, coordinator: coordinator))
        }
    }

    private func handleSectionAppear(_ section: TraySection) {
        switch section {
        case .controls, .homebrew, .updates:
            vm.refreshOverview()
        case .cleaner:
            if vm.cleanPreview == nil && !vm.isScanningClean && !vm.isCleaning {
                vm.runMoleDryRun()
            }
        case .uninstaller:
            if vm.installedApps.isEmpty && !vm.isLoadingApps {
                vm.loadApps()
            }
        }
    }
}

// MARK: - Isolated Live Caffeinate Badge (Zero 1 Hz Parent Re-renders)

private struct CaffeinateToolbarBadge: View {
    let mode: KeepAwakeMode
    let expiresAt: Date?
    let onStop: () -> Void

    var body: some View {
        let scopeTag = mode == .displayAndSystem ? "Display" : "System"
        Button(action: onStop) {
            HStack(spacing: 5) {
                Circle()
                    .fill(MenuBarTheme.Colors.caffeinate)
                    .frame(width: 6, height: 6)
                Text("Awake · \(scopeTag)")
                if let expiresAt {
                    Text(expiresAt, style: .timer)
                } else {
                    Text("Indefinite")
                }
            }
            .font(MenuBarTheme.Typography.timerBadge)
            .foregroundStyle(MenuBarTheme.Colors.caffeinate)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(MenuBarTheme.Colors.caffeinate.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Click to turn off Caffeinate")
    }
}

// MARK: - 1. Power & Input (Minimalist DockDoor / Handy / Canapé Grouped Form)

private struct PowerAndInputSettingsPane: View {
    @Bindable var vm: TrayViewModel
    @Bindable var keepAwake: KeepAwakeManager
    @Bindable var cleaning: CleaningModeManager

    var body: some View {
        UpkeepSettingsFormView {
            UpkeepPaneHeader(section: .controls) {
                if keepAwake.isActive {
                    CaffeinateToolbarBadge(mode: keepAwake.mode, expiresAt: keepAwake.expiresAt) {
                        withAnimation(.snappy(duration: 0.2)) {
                            keepAwake.stop()
                        }
                    }
                }
            }
        } content: {
            if cleaning.permissionDenied || !cleaning.hasAccessibility {
                Section {
                    UpkeepSettingsCallout(
                        tone: .warning,
                        icon: "lock.shield.fill",
                        title: "Accessibility Permission Required",
                        message: "Clean Keys needs Accessibility access to temporarily block keystrokes while you wipe your keyboard.",
                        actionTitle: "Grant Access…"
                    ) {
                        cleaning.openAccessibilitySettings()
                    }
                }
            }

            if keepAwake.isActive {
                Section {
                    HStack(spacing: 12) {
                        UpkeepSettingsIcon(systemName: "cup.and.saucer.fill", color: MenuBarTheme.Colors.caffeinate, size: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Caffeinate is Active")
                                .font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 4) {
                                Text(keepAwake.mode == .displayAndSystem ? "Display & System" : "System Only")
                                Text("·")
                                if let expiresAt = keepAwake.expiresAt {
                                    Text(expiresAt, style: .timer)
                                        .monospacedDigit()
                                    Text("remaining")
                                } else {
                                    Text("Indefinite")
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(MenuBarTheme.Colors.caffeinate)
                        }

                        Spacer()

                        Button("+30m") {
                            keepAwake.extend(byMinutes: 30)
                        }
                        .buttonStyle(.upkeepSecondary)
                        .controlSize(.small)

                        Button("Stop") {
                            withAnimation(.snappy(duration: 0.2)) {
                                keepAwake.stop()
                            }
                        }
                        .buttonStyle(.upkeepSecondary)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }

            UpkeepSettingsSection(
                "Caffeinate",
                footer: "Uses native IOKit power assertions so your Mac stays awake cleanly without background processes."
            ) {
                Toggle(isOn: Binding(
                    get: { keepAwake.isActive },
                    set: { enabled in
                        withAnimation(.snappy(duration: 0.2)) {
                            if enabled {
                                keepAwake.start(durationMinutes: 60, mode: vm.selectedAwakeMode)
                            } else {
                                keepAwake.stop()
                            }
                        }
                    }
                )) {
                    UpkeepSettingLabel(
                        "Keep Mac Awake",
                        subtitle: "Prevent idle display and system sleep during downloads, builds, or presentations."
                    )
                }
                .tint(MenuBarTheme.Colors.caffeinate)
                .upkeepSearchTarget("power.keepAwake")

                Picker(selection: Binding(
                    get: { vm.selectedAwakeMode },
                    set: { mode in
                        vm.selectedAwakeMode = mode
                        if keepAwake.isActive {
                            let mins = keepAwake.remainingSeconds.map { max(1, $0 / 60) }
                            keepAwake.start(durationMinutes: mins, mode: mode)
                        }
                    }
                )) {
                    Text("Display & System").tag(KeepAwakeMode.displayAndSystem)
                    Text("System Only").tag(KeepAwakeMode.systemOnly)
                } label: {
                    UpkeepSettingLabel(
                        "Assertion Mode",
                        subtitle: "Keep the screen lit or let the display sleep while tasks continue.",
                        info: "Display & System holds both kIOPMAssertionTypePreventUserIdleDisplaySleep and system sleep assertions. System Only lets your screen dim and lock normally."
                    )
                }
                .pickerStyle(.segmented)
                .upkeepSearchTarget("power.assertionMode")

                LabeledContent {
                    HStack(spacing: 6) {
                        durationButton("30m", minutes: 30)
                        durationButton("1h", minutes: 60)
                        durationButton("2h", minutes: 120)
                        durationButton("Indefinite", minutes: nil)
                    }
                } label: {
                    UpkeepSettingLabel("Quick Duration")
                }
                .upkeepSearchTarget("power.quickDuration")
            }

            UpkeepSettingsSection(
                "Clean Keys",
                footer: "Hold ⌘ + Esc for 1 second (or press ⌘ six times) to unlock early at any time."
            ) {
                LabeledContent {
                    if cleaning.permissionDenied || !cleaning.hasAccessibility {
                        Button("Grant Accessibility…") {
                            cleaning.openAccessibilitySettings()
                        }
                        .buttonStyle(.upkeepSecondary)
                    } else {
                        Button(cleaning.isLocked ? "Unlock Keyboard" : "Lock Keyboard") {
                            withAnimation(.snappy(duration: 0.2)) {
                                if cleaning.isLocked {
                                    cleaning.stop()
                                } else {
                                    cleaning.start(
                                        durationSeconds: vm.cleaningDuration,
                                        dimScreen: vm.cleaningDimScreen,
                                        lockPointer: vm.cleaningLockPointer
                                    )
                                }
                            }
                        }
                        .buttonStyle(.upkeepPrimary)
                        .tint(cleaning.isLocked ? MenuBarTheme.Colors.cleanKeys : .accentColor)
                    }
                } label: {
                    UpkeepSettingLabel(
                        "Keyboard Cleaning Lock",
                        subtitle: cleaning.isLocked
                            ? "Locked · \(cleaning.remainingSeconds)s remaining"
                            : "Temporarily intercept keyboard input so you can wipe down your MacBook safely."
                    )
                }
                .upkeepSearchTarget("power.cleanKeys")

                HStack(spacing: 8) {
                    Picker(selection: $vm.cleaningDuration) {
                        Text("30s").tag(30)
                        Text("60s").tag(60)
                        Text("2m").tag(120)
                    } label: {
                        UpkeepSettingLabel("Lock Duration")
                    }
                    .pickerStyle(.segmented)

                    if vm.cleaningDuration != 60 {
                        UpkeepResetButton(isModified: true) {
                            vm.cleaningDuration = 60
                        }
                    }
                }
                .upkeepSearchTarget("power.lockDuration")

                Toggle(isOn: $vm.cleaningDimScreen) {
                    UpkeepSettingLabel(
                        "Dim Screen While Locked",
                        subtitle: "Dims connected displays so smudges and dust are easier to spot."
                    )
                }
                .upkeepSearchTarget("power.dimScreen")

                Toggle(isOn: $vm.cleaningLockPointer) {
                    UpkeepSettingLabel(
                        "Lock Pointer & Trackpad",
                        subtitle: "Ignore accidental trackpad taps and clicks while Clean Keys is active."
                    )
                }
                .upkeepSearchTarget("power.lockPointer")
            }
        }
    }

    @ViewBuilder
    private func durationButton(_ label: String, minutes: Int?) -> some View {
        let isSelected: Bool = {
            guard keepAwake.isActive else { return false }
            guard let minutes else { return keepAwake.remainingSeconds == nil }
            guard let rem = keepAwake.remainingSeconds else { return false }
            return abs(rem - (minutes * 60)) <= 60
        }()

        if isSelected {
            Button(label) {
                keepAwake.start(durationMinutes: minutes, mode: vm.selectedAwakeMode)
            }
            .buttonStyle(.upkeepPrimary)
            .tint(MenuBarTheme.Colors.caffeinate)
            .controlSize(.small)
        } else {
            Button(label) {
                keepAwake.start(durationMinutes: minutes, mode: vm.selectedAwakeMode)
            }
            .buttonStyle(.upkeepSecondary)
            .controlSize(.small)
        }
    }
}

// MARK: - 2. Homebrew (Revamped Unified Search & Package Downloader Connected to Floating HUD)

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

private struct HomebrewSettingsPane: View {
    @Bindable var vm: TrayViewModel
    let coordinator: HUDCoordinator
    @Bindable var logStore = BrewLogStore.shared

    @State private var scope: BrewSettingsScope = .upgrades
    @State private var query: String = ""
    @State private var packages: [BrewPackageItem] = []
    @State private var isSearching: Bool = false
    @State private var activePackageID: String? = nil
    @State private var searchTask: Task<Void, Never>?
    @State private var showFullLog: Bool = false
    @State private var copiedInstallCommand = false
    @State private var copiedLog = false

    private static let brewInstallCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    private var isOperating: Bool {
        activePackageID != nil || vm.isUpgradingBrew || logStore.isRunning
    }

    var body: some View {
        UpkeepSettingsFormView(maxColumnWidth: 640) {
            UpkeepPaneHeader(section: .homebrew) {
                HStack(spacing: 8) {
                    if vm.brewOutdatedCount > 0 {
                        Button {
                            vm.upgradeAllBrew()
                        } label: {
                            if vm.isUpgradingBrew {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Upgrade \(vm.brewOutdatedCount)", systemImage: "arrow.up.circle.fill")
                            }
                        }
                        .buttonStyle(.upkeepPrimary)
                        .tint(.orange)
                        .controlSize(.regular)
                        .disabled(isOperating)
                    }

                    Button {
                        coordinator.showHomebrewHUD(
                            initialQuery: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : query,
                            initialTab: scope.hudTab
                        )
                    } label: {
                        Label("Pop Out HUD", systemImage: "macwindow.on.rectangle")
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.regular)
                    .disabled(!BrewService.isInstalled())
                    .help("Open this search in the floating Liquid Glass HUD")
                }
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
                }
            } else if let error = vm.brewErrorText {
                Section {
                    UpkeepSettingsCallout(
                        tone: .warning,
                        icon: "exclamationmark.triangle.fill",
                        title: "Homebrew Operation Failed",
                        message: error,
                        actionTitle: "Retry"
                    ) {
                        vm.brewErrorText = nil
                        vm.refreshOverview(force: true)
                        runSearch()
                    }
                }
            }

            // Live Transfer / Activity Banner (Synced with both Settings & Floating HUD)
            if logStore.isRunning {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(logStore.activeCommand ?? "Running Homebrew operation…")
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            if let line = logStore.liveStatusLine {
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }

            // Unified Search & Package Downloader (Same Rust Engine as Floating HUD)
            if BrewService.isInstalled() {
                UpkeepSettingsSection(
                    "Packages",
                    footer: "\(vm.brewInstalledCount) installed · \(vm.brewOutdatedCount) outdated. Searches share the same instant Rust index as the floating HUD."
                ) {
                    VStack(spacing: 10) {
                        MenuBarSearchField(
                            text: $query,
                            placeholder: searchPlaceholder
                        )
                        .onChange(of: query) { _, _ in
                            runSearch()
                        }

                        Picker("Scope", selection: $scope) {
                            ForEach(BrewSettingsScope.allCases) { s in
                                if s == .upgrades && vm.brewOutdatedCount > 0 {
                                    Text("Upgrades (\(vm.brewOutdatedCount))").tag(s)
                                } else {
                                    Text(s.rawValue).tag(s)
                                }
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: scope) { _, _ in
                            runSearch()
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

            // Minimalist Collapsible Operation Log (No Giant Terminal Box Unless Expanded)
            UpkeepSettingsSection(
                "Activity",
                footer: "Captures output from installs, upgrades, and brew doctor across both Settings and the floating HUD."
            ) {
                if let log = logStore.lastLog {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: log.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(log.succeeded ? Color.green : Color.red)
                                .font(.system(size: 13))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(log.command)
                                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(log.succeeded ? "Succeeded" : "Failed (Exit \(log.exitCode))")
                                        .foregroundStyle(log.succeeded ? Color.secondary : Color.red)
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(log.timestamp, style: .relative)
                                        .foregroundStyle(.tertiary)
                                }
                                .font(.caption)
                            }

                            Spacer()

                            Button(copiedLog ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(log.output, forType: .string)
                                copiedLog = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedLog = false
                                }
                            }
                            .buttonStyle(.upkeepSecondary)
                            .controlSize(.small)

                            Button("Clear") {
                                withAnimation(.snappy(duration: 0.18)) {
                                    showFullLog = false
                                    logStore.clear()
                                }
                            }
                            .buttonStyle(.upkeepSecondary)
                            .controlSize(.small)
                        }

                        DisclosureGroup(isExpanded: $showFullLog) {
                            ScrollView([.vertical, .horizontal]) {
                                Text(log.output)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(maxHeight: 160)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.top, 4)
                        } label: {
                            Text(showFullLog ? "Hide Output" : "View Output")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .upkeepSearchTarget("brew.log")
                } else {
                    LabeledContent {
                        if BrewService.isInstalled() {
                            Button {
                                vm.runBrewDoctor()
                            } label: {
                                if vm.isRunningBrewDoctor {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Run Doctor")
                                }
                            }
                            .buttonStyle(.upkeepSecondary)
                            .controlSize(.small)
                            .disabled(vm.isRunningBrewDoctor)
                        }
                    } label: {
                        UpkeepSettingLabel(
                            "No Recent Operations",
                            subtitle: "Install, upgrade, or run brew doctor to view live progress and logs here."
                        )
                    }
                    .upkeepSearchTarget("brew.log")
                }
            }

            // Compact Environment & HUD Shortcuts
            UpkeepSettingsSection("Environment & Shortcuts") {
                UpkeepStatusRow(
                    title: "Homebrew CLI",
                    description: "Local `brew` binary for package operations",
                    icon: "terminal",
                    isGranted: BrewService.isInstalled()
                )
                .upkeepSearchTarget("brew.outdated")

                LabeledContent("Switch HUD Scopes (Installed, Formulae, Casks, Upgrades)") {
                    UpkeepKeycapGroup(["⌘1", "–", "⌘4"])
                }
                .upkeepSearchTarget("brew.shortcuts")

                LabeledContent("Package Actions Menu") {
                    UpkeepKeycapGroup(["⌘", "K"])
                }

                LabeledContent("Dismiss Floating HUD") {
                    UpkeepKeycapGroup(["Esc"])
                }
            }
        }
        .onAppear {
            if vm.brewOutdatedCount == 0 && scope == .upgrades {
                scope = .installed
            }
            runSearch()
        }
        .onChange(of: vm.brewInstalledCount) { _, _ in
            runSearch()
        }
        .onChange(of: vm.brewOutdatedCount) { _, _ in
            runSearch()
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

    private func brewDownloaderRow(_ pkg: BrewPackageItem) -> some View {
        let isThisOperating = activePackageID == pkg.id

        return HStack(spacing: 10) {
            Image(systemName: pkg.isCask ? "app.dashed" : "terminal")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pkg.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if !pkg.displayVersion.isEmpty {
                        Text(pkg.displayVersion)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(pkg.isCask ? "Cask" : "Formula")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.055), in: Capsule())

                    if pkg.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.orange)
                    }
                }

                if !pkg.description.isEmpty {
                    Text(pkg.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isThisOperating {
                ProgressView()
                    .controlSize(.small)
            } else if pkg.isInstalled && pkg.isOutdated {
                Button("Upgrade") {
                    performPackageAction(pkg)
                }
                .buttonStyle(.upkeepPrimary)
                .tint(.orange)
                .controlSize(.small)
                .disabled(isOperating)
            } else if pkg.isInstalled {
                Button("Uninstall") {
                    performPackageAction(pkg)
                }
                .buttonStyle(.upkeepSecondary)
                .controlSize(.small)
                .disabled(isOperating)
            } else {
                Button("Install") {
                    performPackageAction(pkg)
                }
                .buttonStyle(.upkeepPrimary)
                .controlSize(.small)
                .disabled(isOperating)
            }
        }
        .padding(.vertical, 2)
    }

    private func runSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentScope = scope

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
                let local = await BrewService.shared.fuzzySearchLocal(query: trimmed, filterCasks: nil)
                guard !Task.isCancelled else { return }
                self.packages = currentScope == .upgrades ? local.filter(\.isOutdated) : local
                self.isSearching = false
                return
            }

            let isWarm = await BrewService.shared.hasWarmRemoteIndex()
            if !isWarm {
                self.isSearching = true
            }
            try? await Task.sleep(for: .milliseconds(isWarm ? 20 : 180))
            guard !Task.isCancelled else { return }

            if let hits = try? await BrewService.shared.searchRemote(query: trimmed, filterCasks: currentScope.caskFilter),
               !Task.isCancelled {
                self.packages = hits
            }
            self.isSearching = false
        }
    }

    private func performPackageAction(_ pkg: BrewPackageItem) {
        guard !isOperating else { return }
        activePackageID = pkg.id
        vm.brewErrorText = nil

        Task {
            do {
                if pkg.isInstalled && pkg.isOutdated {
                    _ = try await BrewService.shared.upgrade(name: pkg.name)
                } else if pkg.isInstalled {
                    _ = try await BrewService.shared.uninstall(name: pkg.name, isCask: pkg.isCask)
                } else {
                    _ = try await BrewService.shared.install(name: pkg.name, isCask: pkg.isCask)
                }
                vm.refreshOverview(force: true)
                runSearch()
            } catch {
                vm.brewErrorText = error.localizedDescription
            }
            activePackageID = nil
        }
    }
}

// MARK: - 3. Cleaner (Centered macOS 27 Workspace Aligned with Traffic Lights)

private struct CleanerWorkspacePane: View {
    @Bindable var vm: TrayViewModel
    @State private var collapsedCategories: Set<String> = []
    @State private var copiedCleanError = false

    var body: some View {
        GeometryReader { geo in
            let sideMargin = max(22, (geo.size.width - 680) / 2)
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        UpkeepSectionIcon(section: .cleaner, size: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("Cleaner")
                                    .font(.system(size: 16.5, weight: .semibold))
                                    .foregroundStyle(.primary)

                                if let scan = vm.cleanerScan, scan.itemCount > 0 {
                                    Text("\(vm.formattedSelectedCleanSize) selected")
                                        .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                                        .foregroundStyle(MenuBarTheme.Colors.moleClean)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(
                                            MenuBarTheme.Colors.moleClean.opacity(0.14),
                                            in: Capsule()
                                        )
                                }
                            }

                            Text(headerSubtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button {
                                vm.runMoleDryRun()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.upkeepSecondary)
                            .controlSize(.regular)
                            .disabled(vm.isScanningClean || vm.isCleaning)
                            .help("Rescan cleanable caches")

                            if let scan = vm.cleanerScan, scan.itemCount > 0, !vm.confirmClean {
                                Button(role: .destructive) {
                                    withAnimation(.snappy) { vm.confirmClean = true }
                                } label: {
                                    Text("Clean Selected")
                                }
                                .buttonStyle(.upkeepPrimary)
                                .tint(.red)
                                .disabled(vm.selectedCleanPaths.isEmpty || vm.isScanningClean || vm.isCleaning)
                            }
                        }
                    }

                    if vm.confirmClean, !vm.selectedCleanPaths.isEmpty {
                        let adminSuffix = vm.hasSelectedAdminCleanItems ? " (will prompt for admin password)" : ""
                        MenuBarDestructiveConfirmBar(
                            title: "Delete \(vm.formattedSelectedCleanSize) across \(vm.selectedCleanPaths.count) selected items?\(adminSuffix)",
                            confirmLabel: "Clean",
                            confirmIcon: "trash",
                            onCancel: {
                                withAnimation(.snappy) { vm.confirmClean = false }
                            },
                            onConfirm: {
                                vm.executeMoleClean()
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    if let result = vm.lastCleanResult {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(MenuBarTheme.Colors.success)
                            Text("Reclaimed \(result.formattedReclaimedSize) across \(result.removedCount) \(result.removedCount == 1 ? "item" : "items") in \(result.durationMs) ms")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.primary)
                            if !result.failedItems.isEmpty {
                                Text("· \(result.failedItems.count) skipped")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Dismiss") {
                                withAnimation(.snappy) { vm.lastCleanResult = nil }
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(MenuBarTheme.Colors.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if let scan = vm.cleanerScan, scan.itemCount > 0 {
                        HStack(spacing: 8) {
                            Button("Select Safe") {
                                vm.selectedCleanPaths = scan.defaultSelectedPaths
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.accentColor)

                            Text("·").foregroundStyle(.tertiary)

                            Button("Select All") {
                                vm.selectedCleanPaths = Set(scan.allItems.map(\.path))
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)

                            Text("·").foregroundStyle(.tertiary)

                            Button("None") {
                                vm.selectedCleanPaths.removeAll()
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)

                            Spacer()

                            Text("\(scan.formattedTotalSize) total · \(scan.itemCount) items")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, sideMargin)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .upkeepSearchTarget("cleaner.dryRun")

                Divider().opacity(0.16)

                if vm.isScanningClean || vm.isCleaning {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(vm.isCleaning ? "Cleaning selected caches…" : "Scanning system & developer caches…")
                            .font(.system(size: 13, weight: .medium))
                        Text(vm.isCleaning ? "Removing selected items safely in parallel" : "Measuring APFS disk usage without deleting files")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = vm.cleanError {
                    ContentUnavailableView {
                        Label("Cache Scan Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(err)
                    } actions: {
                        HStack(spacing: 8) {
                            Button("Retry Scan") { vm.runMoleDryRun() }
                                .buttonStyle(.upkeepPrimary)

                            Button(copiedCleanError ? "Copied" : "Copy Error") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(err, forType: .string)
                                copiedCleanError = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedCleanError = false
                                }
                            }
                            .buttonStyle(.upkeepSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let scan = vm.cleanerScan {
                    if scan.categories.isEmpty {
                        ContentUnavailableView {
                            Label("System is Clean", systemImage: "checkmark.circle")
                        } description: {
                            Text("No reclaimable caches or stale temporary files were found.")
                        } actions: {
                            Button("Rescan") { vm.runMoleDryRun() }
                                .buttonStyle(.upkeepSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(scan.categories) { category in
                                    cleanerCategorySection(category)
                                }
                            }
                            .padding(.horizontal, sideMargin)
                            .padding(.vertical, 14)
                        }
                        .upkeepSoftTopScrollEdge()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Ready to Scan", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Inspect user, browser, and developer caches safely without deleting any files.")
                    } actions: {
                        Button("Start Scan") { vm.runMoleDryRun() }
                            .buttonStyle(.upkeepPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var headerSubtitle: String {
        if let scan = vm.cleanerScan {
            return "Native APFS dry-run · \(scan.categories.count) categories · Scanned in \(scan.scanDurationMs) ms"
        }
        return "Inspects user, browser, and developer caches safely before deleting"
    }

    private func cleanerCategorySection(_ category: CleanerCategory) -> some View {
        let isCollapsed = collapsedCategories.contains(category.id)
        let paths = category.items.map(\.path)
        let selectedCount = paths.filter { vm.selectedCleanPaths.contains($0) }.count
        let allSelected = selectedCount == paths.count && !paths.isEmpty
        let someSelected = selectedCount > 0 && !allSelected

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if allSelected {
                        for p in paths { vm.selectedCleanPaths.remove(p) }
                    } else {
                        for p in paths { vm.selectedCleanPaths.insert(p) }
                    }
                } label: {
                    Image(systemName: allSelected ? "checkmark.square.fill" : (someSelected ? "minus.square.fill" : "square"))
                        .foregroundStyle((allSelected || someSelected) ? Color.accentColor : Color.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help(allSelected ? "Deselect all in \(category.title)" : "Select all in \(category.title)")

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        if isCollapsed {
                            collapsedCategories.remove(category.id)
                        } else {
                            collapsedCategories.insert(category.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)

                        Text(category.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("(\(selectedCount)/\(category.items.count))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)

                        Spacer()

                        Text(category.formattedTotalSize)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !isCollapsed {
                VStack(spacing: 3) {
                    ForEach(category.items) { item in
                        let isChecked = vm.selectedCleanPaths.contains(item.path)
                        CleanerItemRow(item: item, isChecked: isChecked) {
                            if isChecked {
                                vm.selectedCleanPaths.remove(item.path)
                            } else {
                                vm.selectedCleanPaths.insert(item.path)
                            }
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}

/// Isolated Cleaner row so pointer hover never invalidates the parent `CleanerWorkspacePane`.
private struct CleanerItemRow: View {
    let item: CleanerItem
    let isChecked: Bool
    let onToggle: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                        .font(.system(size: 14))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if item.requiresAdmin {
                                Label("Admin", systemImage: "lock.fill")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.purple)
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.14), in: Capsule())
                            } else if !item.defaultSelected {
                                Text("Held back · \(item.holdbackReason ?? "Optional")")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.14), in: Capsule())
                            }
                        }

                        Text(item.displayPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 6)

                    Text(item.formattedSize)
                        .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isHovered
                ? Color.primary.opacity(0.055)
                : Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - 4. Uninstaller (Centered macOS 27 Workspace + Leftover & Homebrew Cask Review)

private struct UninstallerWorkspacePane: View {
    @Bindable var vm: TrayViewModel
    @State private var copiedError = false

    var body: some View {
        GeometryReader { geo in
            let sideMargin = max(22, (geo.size.width - 680) / 2)
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        UpkeepSectionIcon(section: .uninstaller, size: 24)
                        Text("Uninstaller")
                            .font(.system(size: 16.5, weight: .semibold))
                        Spacer()
                        if !vm.installedApps.isEmpty {
                            Text("\(vm.filteredApps.count) of \(vm.installedApps.count) apps")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            vm.loadApps(force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.upkeepSecondary)
                        .controlSize(.small)
                        .disabled(vm.isLoadingApps)
                        .help("Reload installed applications")
                    }

                    HStack(spacing: 10) {
                        MenuBarSearchField(
                            text: $vm.appQuery,
                            placeholder: "Filter installed applications…",
                            onEscape: {
                                if vm.pendingUninstallApp != nil {
                                    vm.cancelUninstallReview()
                                }
                            }
                        )

                        Picker("Sort", selection: $vm.appSortOrder) {
                            ForEach(TrayViewModel.AppSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    if let status = vm.uninstallStatus {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(MenuBarTheme.Colors.success)
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Dismiss") {
                                vm.uninstallStatus = nil
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.tertiary)
                        }
                    }

                    if let err = vm.uninstallError, !vm.installedApps.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(MenuBarTheme.Colors.destructive)
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(MenuBarTheme.Colors.destructive)
                                .lineLimit(2)
                            Spacer()
                            Button(copiedError ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(err, forType: .string)
                                copiedError = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedError = false
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)

                            Button("Dismiss") {
                                vm.uninstallError = nil
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, sideMargin)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .upkeepSearchTarget("uninstaller.apps")

                Divider().opacity(0.16)

                if vm.isLoadingApps {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning installed applications…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = vm.uninstallError, vm.installedApps.isEmpty {
                    ContentUnavailableView {
                        Label("Unable to Load Applications", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(err)
                    } actions: {
                        HStack(spacing: 8) {
                            Button("Retry") { vm.loadApps(force: true) }
                                .buttonStyle(.upkeepPrimary)
                            Button("Copy Error") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(err, forType: .string)
                            }
                            .buttonStyle(.upkeepSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.installedApps.isEmpty {
                    ContentUnavailableView {
                        Label("No Applications Found", systemImage: "app.dashed")
                    } description: {
                        Text("No apps were discovered in /Applications or ~/Applications.")
                    } actions: {
                        Button("Reload Applications") { vm.loadApps(force: true) }
                            .buttonStyle(.upkeepPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.filteredApps.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Applications", systemImage: "magnifyingglass")
                    } description: {
                        Text("No installed apps match “\(vm.appQuery)”.")
                    } actions: {
                        Button("Clear Filter") { vm.appQuery = "" }
                            .buttonStyle(.upkeepSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(vm.filteredApps.prefix(200)) { app in
                                UninstallerAppRow(
                                    app: app,
                                    isPending: vm.pendingUninstallApp?.id == app.id,
                                    onRemove: {
                                        vm.inspectForUninstall(app)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, sideMargin)
                        .padding(.vertical, 14)
                    }
                    .upkeepSoftTopScrollEdge()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $vm.pendingUninstallApp) { app in
            UninstallReviewSheet(app: app, vm: vm)
        }
    }
}

// MARK: - Interactive Uninstaller Leftover & Homebrew Cask Review Sheet

private struct UninstallReviewSheet: View {
    let app: MoleInstalledApp
    @Bindable var vm: TrayViewModel

    @State private var selectedLeftovers: Set<String> = []
    @State private var useHomebrewCask: Bool = true
    @State private var didSeedSelection: Bool = false

    private var selectedLeftoversBytes: Int64 {
        guard let inspection = vm.uninstallInspection else { return 0 }
        return inspection.leftovers
            .filter { selectedLeftovers.contains($0.path) }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    private var hasSelectedSystemLeftovers: Bool {
        guard let inspection = vm.uninstallInspection else { return false }
        return inspection.leftovers.contains { $0.isSystem && selectedLeftovers.contains($0.path) }
    }

    private var totalSelectedSizeFormatted: String {
        let total = (app.size ?? 0) + selectedLeftoversBytes
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(path: app.path, size: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall \(app.name)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(app.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(totalSelectedSizeFormatted)
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("Total selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider().opacity(0.25)

            if vm.isInspectingUninstall || vm.uninstallInspection == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Inspecting ~/Library leftovers & Homebrew Caskroom…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let inspection = vm.uninstallInspection {
                VStack(alignment: .leading, spacing: 12) {
                    if let vendor = inspection.officialUninstallerVendor {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Official \(vendor) Uninstaller Recommended")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Security, MDM, and VPN apps often install system extensions or daemons that are safest to remove with \(vendor)'s official uninstaller.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.75)
                        }
                    }

                    if inspection.hasSiblingApp {
                        HStack(spacing: 10) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 15))
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Sibling App Detected — Shared Data Protected")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Another channel or copy of this app is installed. Shared app-name folders and Homebrew --zap are skipped.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.blue.opacity(0.25), lineWidth: 0.75)
                        }
                    }

                    if let token = inspection.homebrewCaskToken {
                        let caskCmd = inspection.hasSiblingApp
                            ? "brew uninstall --cask \(token)"
                            : "brew uninstall --cask --zap \(token)"
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                UpkeepSettingsIcon(systemName: "shippingbox.fill", color: MenuBarTheme.Colors.homebrew, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Managed by Homebrew Cask")
                                        .font(.system(size: 12.5, weight: .semibold))
                                    Text("Found matching cask token `\(token)` in Caskroom.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            Toggle("Uninstall via `\(caskCmd)` (recommended)", isOn: $useHomebrewCask)
                                .toggleStyle(.checkbox)
                                .font(.footnote)
                        }
                        .padding(12)
                        .background(MenuBarTheme.Colors.homebrew.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(MenuBarTheme.Colors.homebrew.opacity(0.25), lineWidth: 0.75)
                        }
                    }

                    HStack {
                        Text("Related Files (\(inspection.leftovers.count))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if inspection.leftovers.contains(where: { !$0.isSystem }) {
                            Button("Select All") {
                                selectedLeftovers = Set(inspection.leftovers.filter { !$0.isSystem }.map(\.path))
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.accentColor)

                            Text("·").foregroundStyle(.tertiary)

                            Button("None") {
                                selectedLeftovers.removeAll()
                            }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                    }

                    if inspection.leftovers.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                            Text("No leftover files found — only the app bundle will be removed.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding()
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(inspection.leftovers) { item in
                                    let isChecked = selectedLeftovers.contains(item.path)
                                    HStack(spacing: 8) {
                                        Button {
                                            if isChecked {
                                                selectedLeftovers.remove(item.path)
                                            } else {
                                                selectedLeftovers.insert(item.path)
                                            }
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                                    .foregroundStyle(isChecked ? (item.isSystem ? Color.purple : Color.accentColor) : Color.secondary)
                                                    .font(.system(size: 14))
                                                    .frame(width: 16)

                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.displayPath)
                                                        .font(.system(size: 11.5, design: .monospaced))
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)

                                                    HStack(spacing: 6) {
                                                        Text(item.category)
                                                            .font(.caption2)
                                                            .foregroundStyle(.secondary)

                                                        if item.isSystem {
                                                            Label("Admin", systemImage: "lock.fill")
                                                                .font(.system(size: 9.5, weight: .semibold))
                                                                .foregroundStyle(.purple)
                                                                .padding(.horizontal, 5.5)
                                                                .padding(.vertical, 1)
                                                                .background(Color.purple.opacity(0.14), in: Capsule())
                                                        } else if !item.defaultSelected {
                                                            Text("Held back · \(item.holdbackReason ?? "Personal data")")
                                                                .font(.system(size: 9.5, weight: .semibold))
                                                                .foregroundStyle(.orange)
                                                                .padding(.horizontal, 5)
                                                                .padding(.vertical, 1)
                                                                .background(Color.orange.opacity(0.14), in: Capsule())
                                                        }
                                                    }
                                                }

                                                Spacer(minLength: 6)

                                                Text(item.formattedSize)
                                                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                                        } label: {
                                            Image(systemName: "folder")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 22, height: 22)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Reveal in Finder")
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .onAppear {
                    if !didSeedSelection {
                        selectedLeftovers = Set(inspection.leftovers.filter(\.defaultSelected).map(\.path))
                        didSeedSelection = true
                    }
                }
            }

            Divider().opacity(0.25)

            HStack {
                Button("Cancel") {
                    vm.cancelUninstallReview()
                }
                .buttonStyle(.upkeepSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(vm.isUninstallingApp)

                Spacer()

                Button(role: .destructive) {
                    vm.executeReviewedUninstall(
                        selectedLeftoverPaths: selectedLeftovers,
                        useHomebrewCask: useHomebrewCask
                    )
                } label: {
                    if vm.isUninstallingApp {
                        ProgressView().controlSize(.small)
                    } else if let token = vm.uninstallInspection?.homebrewCaskToken, useHomebrewCask {
                        Label(
                            hasSelectedSystemLeftovers ? "Uninstall Cask (\(token)) + Admin" : "Uninstall Cask (\(token))",
                            systemImage: "trash.fill"
                        )
                    } else {
                        Label(
                            hasSelectedSystemLeftovers ? "Move to Trash (Admin)" : "Move to Trash",
                            systemImage: "trash.fill"
                        )
                    }
                }
                .buttonStyle(.upkeepPrimary)
                .tint(.red)
                .disabled(vm.isInspectingUninstall || vm.uninstallInspection == nil || vm.isUninstallingApp)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 460)
    }
}

// MARK: - 5. Updates & System (Canapé Hero Card + Minimalist DockDoor / Handy Rows)

private struct UpdatesSettingsPane: View {
    @Bindable var updater: UpdateManager
    @Bindable var cleaning: CleaningModeManager
    @Bindable var vm: TrayViewModel
    let coordinator: HUDCoordinator

    @AppStorage(UpkeepSettingsPreferences.showDescriptionsKey) private var showDescriptions = true
    @State private var showResetAlert = false

    var body: some View {
        UpkeepSettingsFormView {
            UpkeepPaneHeader(section: .updates)
        } content: {
            // Canapé-style clean app identity & update status hero card
            Section {
                HStack(spacing: 14) {
                    UpkeepAppIconView(size: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Upkeep")
                                .font(.system(size: 14.5, weight: .semibold))
                            Text("v\(updater.currentVersion)")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Text(lastCheckDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    updateStatusBadge

                    Button("Check Now") {
                        Task { await updater.checkForUpdates() }
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.regular)
                    .disabled(updater.isChecking || updater.isInstalling)
                }
                .padding(.vertical, 4)
                .upkeepSearchTarget("updates.releases")
            }

            if let error = updater.errorMessage {
                Section {
                    UpkeepSettingsCallout(
                        tone: .warning,
                        icon: "exclamationmark.triangle.fill",
                        title: "Update Check Failed",
                        message: error,
                        actionTitle: "Retry"
                    ) {
                        Task { await updater.checkForUpdates() }
                    }
                }
            }

            if let release = updater.availableRelease {
                Section {
                    UpkeepSettingsCallout(
                        tone: .success,
                        icon: "arrow.down.circle.fill",
                        title: "Upkeep v\(release.version) is available",
                        message: release.releaseNotes.isEmpty ? "Ready to download and install." : release.releaseNotes,
                        actionTitle: release.downloadURL != nil ? "Install & Relaunch" : "Open Release"
                    ) {
                        Task { await updater.installAvailableUpdate() }
                    }
                }
            }

            UpkeepSettingsSection(
                "Releases",
                footer: "Automatic update checks run quietly every 6 hours when a GitHub repository is configured."
            ) {
                Toggle(isOn: $updater.autoCheckUpdates) {
                    UpkeepSettingLabel("Automatically check for updates")
                }

                LabeledContent {
                    TextField("", text: $updater.githubRepo, prompt: Text("owner/Upkeep"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                } label: {
                    UpkeepSettingLabel("GitHub Repository")
                }

                if let status = updater.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            UpkeepSettingsSection("CLI Utilities") {
                LabeledContent {
                    Button("Update Homebrew") {
                        Task {
                            await updater.updateCLIUtilities()
                            vm.refreshOverview(force: true)
                        }
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.small)
                    .disabled(updater.isInstalling || !BrewService.isInstalled())
                } label: {
                    UpkeepSettingLabel(
                        "Homebrew CLI",
                        subtitle: "Runs `brew update` to refresh local package definitions."
                    )
                }
                .upkeepSearchTarget("updates.cli")
            }

            UpkeepSettingsSection(
                "Permissions & Environment",
                footer: "Changes to macOS Accessibility permissions may require restarting Upkeep to take effect."
            ) {
                UpkeepStatusRow(
                    title: "Accessibility Permission",
                    description: "Required for Clean Keys to intercept keyboard and pointer input",
                    icon: "accessibility",
                    isGranted: cleaning.hasAccessibility,
                    grantedLabel: "Granted",
                    missingLabel: "Required",
                    actionTitle: "Grant…"
                ) {
                    cleaning.openAccessibilitySettings()
                }
                .upkeepSearchTarget("updates.permissions")

                UpkeepStatusRow(
                    title: "Homebrew CLI",
                    description: "Powers package search, installation, and upgrades",
                    icon: "shippingbox",
                    isGranted: BrewService.isInstalled()
                )
            }

            UpkeepSettingsSection("Preferences & Application") {
                Toggle(isOn: $showDescriptions) {
                    UpkeepSettingLabel(
                        "Show setting descriptions",
                        subtitle: "Display brief explanations underneath settings rows across Upkeep."
                    )
                }
                .upkeepSearchTarget("updates.preferences")

                LabeledContent {
                    Button("Reset…", role: .destructive) {
                        showResetAlert = true
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.small)
                } label: {
                    UpkeepSettingLabel("Reset Preferences to Defaults")
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Restart") {
                            coordinator.restartApp()
                        }
                        .buttonStyle(.upkeepSecondary)
                        .controlSize(.small)

                        Button("Quit Upkeep") {
                            coordinator.quitApp()
                        }
                        .buttonStyle(.upkeepSecondary)
                        .controlSize(.small)
                    }
                } label: {
                    UpkeepSettingLabel("Application Lifecycle")
                }
            }
        }
        .alert("Reset Preferences to Defaults?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                vm.selectedAwakeMode = .displayAndSystem
                vm.cleaningDuration = 60
                vm.cleaningDimScreen = true
                vm.cleaningLockPointer = false
                vm.includePersonalData = false
                showDescriptions = true
                updater.autoCheckUpdates = true
            }
        } message: {
            Text("This restores Caffeinate, Clean Keys, and interface preferences to their default values.")
        }
    }

    private var lastCheckDescription: String {
        if let lastCheck = updater.lastCheckedAt {
            let formatted = lastCheck.formatted(date: .abbreviated, time: .shortened)
            return "Last checked \(formatted)"
        }
        return "No recent checks"
    }

    @ViewBuilder
    private var updateStatusBadge: some View {
        if updater.isChecking {
            ProgressView()
                .controlSize(.small)
        } else if let release = updater.availableRelease {
            Text("v\(release.version)")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.14), in: Capsule())
        } else if updater.errorMessage != nil {
            Text("Error")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Up to Date")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
