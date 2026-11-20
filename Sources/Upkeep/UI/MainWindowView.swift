import AppKit
import SwiftUI

/// Dedicated macOS 27 Native Liquid Glass Window for Upkeep.
/// Modeled on Apple System Settings, DockDoor, and Handy:
/// - Locked 232pt Floating Liquid Glass Sidebar with pinned Liquid Glass Search (`⌘F`)
/// - Consistent `.unified` titlebar & toolbar chrome across every pane (zero height jumps)
/// - Native `.formStyle(.grouped)` panes with `.scrollEdgeEffectStyle(.soft, for: .top)`
/// - Unified `.glass` / `.glassProminent` button hierarchy, leading `UpkeepSettingsIcon` badges,
///   toggleable inline annotations with `(i)` popovers, and search scroll-to highlight flash
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

    private var toolbarTitle: String {
        searchEngine.isSearching ? "Search" : vm.activeSection.rawValue
    }

    private var toolbarSubtitle: String {
        if searchEngine.isSearching {
            let count = searchEngine.results.count
            return count == 1 ? "1 matching setting" : "\(count) matching settings"
        }
        return vm.activeSection.subtitle
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detailPane
                .navigationTitle(toolbarTitle)
                .navigationSubtitle(toolbarSubtitle)
                .toolbar {
                    toolbarContent
                }
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
            vm.refreshOverview()
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

    // MARK: - Floating Liquid Glass Sidebar

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
            VStack(spacing: 8) {
                sidebarBrandHeader
                sidebarSearchField
            }
            .padding(.bottom, 6)
        }
        .navigationSplitViewColumnWidth(min: 232, ideal: 232, max: 232)
        .toolbar(removing: .sidebarToggle)
    }

    private func sidebarRow(_ section: TraySection) -> some View {
        let isSelected = !searchEngine.isSearching && vm.activeSection == section

        return HStack(spacing: 10) {
            UpkeepSectionIcon(section: section, size: 22)

            Text(section.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            if section == .controls && (keepAwake.isActive || cleaning.isLocked) {
                Circle()
                    .fill(isSelected ? Color.white : (keepAwake.isActive ? MenuBarTheme.Colors.caffeinate : MenuBarTheme.Colors.cleanKeys))
                    .frame(width: 7, height: 7)
            } else if section == .homebrew && vm.brewOutdatedCount > 0 {
                Text("\(vm.brewOutdatedCount)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .background(
                        isSelected ? Color.white.opacity(0.24) : Color.primary.opacity(0.09),
                        in: Capsule()
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            } else if section == .updates && updater.hasUpdateAvailable {
                Circle()
                    .fill(isSelected ? Color.white : MenuBarTheme.Colors.success)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 2)
        .tag(section)
    }

    private var sidebarBrandHeader: some View {
        HStack(spacing: 10) {
            UpkeepAppIconView(size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Upkeep")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("Version \(updater.currentVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search…", text: $searchEngine.query)
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
        .padding(.horizontal, 9)
        .padding(.vertical, 5.5)
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

    // MARK: - Unified Toolbar Controls (Always Populated for Consistent Titlebar Height)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if keepAwake.isActive {
                CaffeinateToolbarBadge(mode: keepAwake.mode, expiresAt: keepAwake.expiresAt) {
                    withAnimation(.snappy(duration: 0.2)) {
                        keepAwake.stop()
                    }
                }
            }

            if searchEngine.isSearching {
                Button {
                    searchEngine.query = ""
                    isSearchFieldFocused = false
                } label: {
                    Label("Clear Search", systemImage: "xmark")
                }
                .help("Clear search results")
            } else {
                switch vm.activeSection {
                case .controls:
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if keepAwake.isActive {
                                keepAwake.stop()
                            } else {
                                keepAwake.start(durationMinutes: 60, mode: vm.selectedAwakeMode)
                            }
                        }
                    } label: {
                        Label(
                            keepAwake.isActive ? "Stop Caffeinate" : "Keep Awake (1h)",
                            systemImage: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
                        )
                    }
                    .help(keepAwake.isActive ? "Turn off Caffeinate" : "Keep Mac awake for 1 hour")

                case .homebrew:
                    Button {
                        coordinator.showHomebrewHUD()
                    } label: {
                        Label("Search HUD", systemImage: "magnifyingglass")
                    }
                    .help("Open floating Homebrew Search HUD")

                case .cleaner:
                    Button {
                        vm.runMoleDryRun()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isScanningClean || vm.isCleaning)
                    .help("Rescan cleanable caches")

                case .uninstaller:
                    Button {
                        vm.loadApps(force: true)
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isLoadingApps)
                    .help("Reload installed applications")

                case .updates:
                    Button {
                        Task { await updater.checkForUpdates() }
                    } label: {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(updater.isChecking || updater.isInstalling)
                    .help("Check for Upkeep updates")
                }
            }
        }
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

    @ViewBuilder
    private func sectionView(for section: TraySection) -> some View {
        switch section {
        case .controls:
            PowerAndInputSettingsPane(vm: vm, keepAwake: keepAwake, cleaning: cleaning)
        case .homebrew:
            HomebrewSettingsPane(vm: vm, coordinator: coordinator)
        case .cleaner:
            CleanerWorkspacePane(vm: vm)
        case .uninstaller:
            UninstallerWorkspacePane(vm: vm)
        case .updates:
            UpdatesSettingsPane(updater: updater, cleaning: cleaning, vm: vm, coordinator: coordinator)
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

// MARK: - Isolated Live Caffeinate Toolbar Badge (Zero 1 Hz Parent Re-renders)

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

// MARK: - 1. Power & Input (Native macOS 27 Grouped Form)

private struct PowerAndInputSettingsPane: View {
    @Bindable var vm: TrayViewModel
    @Bindable var keepAwake: KeepAwakeManager
    @Bindable var cleaning: CleaningModeManager

    var body: some View {
        UpkeepSettingsFormView {
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
                        UpkeepSettingsIcon(systemName: "cup.and.saucer.fill", color: MenuBarTheme.Colors.caffeinate, size: 26)

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
                footer: "Uses native IOKit power assertions so your Mac stays awake cleanly without spawning background processes."
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
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "cup.and.saucer.fill", color: MenuBarTheme.Colors.caffeinate)
                        Text("Keep Mac Awake")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .tint(MenuBarTheme.Colors.caffeinate)
                .upkeepAnnotation("Prevent idle display and system sleep while running downloads, builds, or presentations.")
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
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "display", color: .blue)
                        Text("Assertion Mode")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .pickerStyle(.segmented)
                .upkeepAnnotation(
                    "Choose whether to keep the screen lit or allow the display to sleep while background tasks continue.",
                    more: "Display & System holds both kIOPMAssertionTypePreventUserIdleDisplaySleep and system sleep assertions. System Only lets your screen dim and lock normally."
                )
                .upkeepSearchTarget("power.assertionMode")

                LabeledContent {
                    HStack(spacing: 6) {
                        durationButton("30m", minutes: 30)
                        durationButton("1h", minutes: 60)
                        durationButton("2h", minutes: 120)
                        durationButton("Indefinite", minutes: nil)
                    }
                } label: {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "timer", color: .indigo)
                        Text("Quick Duration")
                            .font(.system(size: 13, weight: .medium))
                    }
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
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "keyboard.badge.ellipsis", color: MenuBarTheme.Colors.cleanKeys)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keyboard Cleaning Lock")
                                .font(.system(size: 13, weight: .medium))
                            if cleaning.isLocked {
                                Text("Locked · \(cleaning.remainingSeconds)s remaining")
                                    .font(.footnote)
                                    .foregroundStyle(MenuBarTheme.Colors.cleanKeys)
                            }
                        }
                    }
                }
                .upkeepAnnotation("Temporarily intercept all keyboard input so you can wipe down your MacBook without triggering shortcuts.")
                .upkeepSearchTarget("power.cleanKeys")

                HStack(spacing: 8) {
                    Picker(selection: $vm.cleaningDuration) {
                        Text("30 Seconds").tag(30)
                        Text("60 Seconds").tag(60)
                        Text("2 Minutes").tag(120)
                    } label: {
                        HStack(spacing: 10) {
                            UpkeepSettingsIcon(systemName: "clock", color: .teal)
                            Text("Lock Duration")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .pickerStyle(.segmented)

                    UpkeepResetButton(isModified: vm.cleaningDuration != 60) {
                        vm.cleaningDuration = 60
                    }
                }
                .upkeepSearchTarget("power.lockDuration")

                Toggle(isOn: $vm.cleaningDimScreen) {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "moon.fill", color: .purple)
                        Text("Dim Screen While Locked")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .upkeepAnnotation("Dims connected displays so smudges and dust are easier to spot while cleaning.")
                .upkeepSearchTarget("power.dimScreen")

                Toggle(isOn: $vm.cleaningLockPointer) {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "cursorarrow.slash", color: .pink)
                        Text("Lock Pointer & Trackpad")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .upkeepAnnotation("Also ignores accidental trackpad taps and clicks while Clean Keys is active.")
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

// MARK: - 2. Homebrew (Native macOS 27 Grouped Form)

private struct HomebrewSettingsPane: View {
    @Bindable var vm: TrayViewModel
    let coordinator: HUDCoordinator

    var body: some View {
        UpkeepSettingsFormView {
            if !BrewService.isInstalled() {
                Section {
                    UpkeepSettingsCallout(
                        tone: .warning,
                        icon: "terminal.fill",
                        title: "Homebrew CLI Not Found",
                        message: "Install Homebrew in /opt/homebrew/bin or /usr/local/bin to search, install, and upgrade packages."
                    )
                }
            }

            UpkeepSettingsSection(
                "Packages",
                footer: "The floating Search HUD caches Homebrew's public formulae and cask index with ETag validation for instant search."
            ) {
                LabeledContent {
                    HStack(spacing: 8) {
                        if vm.brewOutdatedCount > 0 {
                            Button {
                                vm.upgradeAllBrew()
                            } label: {
                                if vm.isUpgradingBrew {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Upgrade \(vm.brewOutdatedCount)")
                                }
                            }
                            .buttonStyle(.upkeepSecondary)
                            .disabled(vm.isUpgradingBrew)
                        }

                        Button("Open Search HUD") {
                            coordinator.showHomebrewHUD()
                        }
                        .buttonStyle(.upkeepPrimary)
                    }
                } label: {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "magnifyingglass", color: MenuBarTheme.Colors.homebrew)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Homebrew Search HUD")
                                .font(.system(size: 13, weight: .medium))
                            Text(statusSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .upkeepSearchTarget("brew.hud")

                LabeledContent {
                    Text("\(vm.brewInstalledCount)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                } label: {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "shippingbox.fill", color: .blue)
                        Text("Installed Packages")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                LabeledContent {
                    Text("\(vm.brewOutdatedCount)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(vm.brewOutdatedCount > 0 ? MenuBarTheme.Colors.warning : .secondary)
                } label: {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(
                            systemName: "arrow.up.circle.fill",
                            color: vm.brewOutdatedCount > 0 ? MenuBarTheme.Colors.warning : .secondary
                        )
                        Text("Outdated Packages")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .upkeepSearchTarget("brew.outdated")

                UpkeepStatusRow(
                    title: "Homebrew CLI",
                    description: "Local `brew` binary for package operations",
                    icon: "terminal",
                    isGranted: BrewService.isInstalled()
                )
            }

            UpkeepSettingsSection("HUD Shortcuts") {
                LabeledContent("Switch Scopes (Installed, Formulae, Casks, Upgrades)") {
                    UpkeepKeycapGroup(["⌘1", "–", "⌘4"])
                }
                .upkeepSearchTarget("brew.shortcuts")

                LabeledContent("Open Package Actions Menu") {
                    UpkeepKeycapGroup(["⌘", "K"])
                }

                LabeledContent("Dismiss Search HUD") {
                    UpkeepKeycapGroup(["Esc"])
                }
            }
        }
    }

    private var statusSummary: String {
        if let status = vm.brewStatusText { return status }
        if !BrewService.isInstalled() { return "Homebrew binary not found" }
        if vm.brewInstalledCount == 0 { return "Search formulae & casks in a floating Liquid Glass HUD" }
        if vm.brewOutdatedCount > 0 {
            return "\(vm.brewInstalledCount) installed · \(vm.brewOutdatedCount) updates available"
        }
        return "\(vm.brewInstalledCount) installed · All packages up to date"
    }
}

// MARK: - 3. Cleaner (Unified macOS 27 Workspace)

private enum CleanerFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case candidates = "Candidates"
    case cleaned = "Cleaned"

    var id: String { rawValue }
}

private struct CleanerWorkspacePane: View {
    @Bindable var vm: TrayViewModel
    @State private var hoveredIndex: Int?
    @State private var filter: CleanerFilter = .all

    private var filteredLines: [String] {
        guard let lines = vm.cleanPreview?.lines else { return [] }
        switch filter {
        case .all:
            return lines
        case .candidates:
            return lines.filter { $0.hasPrefix("➤") || $0.hasPrefix("○") || $0.hasPrefix("◎") }
        case .cleaned:
            return lines.filter { $0.hasPrefix("➤") || $0.hasPrefix("✓") }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Unified Summary Header Strip
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    UpkeepSectionIcon(section: .cleaner, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(vm.cleanPreview?.isDryRun == false ? "Cleanup Complete" : "Dry-Run Preview")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)

                            if let summary = vm.cleanPreview {
                                Text(summary.totalReclaimed)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(summary.isDryRun ? MenuBarTheme.Colors.moleClean : MenuBarTheme.Colors.success)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(
                                        (summary.isDryRun ? MenuBarTheme.Colors.moleClean : MenuBarTheme.Colors.success).opacity(0.14),
                                        in: Capsule()
                                    )
                            }
                        }

                        Text(headerSubtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let summary = vm.cleanPreview, summary.isDryRun, !vm.confirmClean {
                        Button(role: .destructive) {
                            withAnimation(.snappy) { vm.confirmClean = true }
                        } label: {
                            Text("Clean Now")
                        }
                        .buttonStyle(.upkeepPrimary)
                        .tint(.red)
                        .disabled(vm.isScanningClean || vm.isCleaning)
                    }
                }

                if let summary = vm.cleanPreview, summary.isDryRun, vm.confirmClean {
                    MenuBarDestructiveConfirmBar(
                        title: "Delete \(summary.totalReclaimed) of cached data?",
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

                if vm.cleanPreview != nil && !(vm.cleanPreview?.lines.isEmpty ?? true) {
                    HStack {
                        Picker("Filter", selection: $filter) {
                            ForEach(CleanerFilter.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260)

                        Spacer()

                        if let summary = vm.cleanPreview {
                            Text("\(summary.itemCount) items")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .upkeepSearchTarget("cleaner.dryRun")

            Divider().opacity(0.22)

            if vm.isScanningClean || vm.isCleaning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(vm.isCleaning ? "Cleaning caches…" : "Scanning caches safely…")
                        .font(.system(size: 13, weight: .medium))
                    Text(vm.isCleaning ? "Reclaiming disk space" : "Running `mo clean --dry-run` without deleting files")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = vm.cleanError {
                ContentUnavailableView {
                    Label("Scan Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("Retry Scan") { vm.runMoleDryRun() }
                        .buttonStyle(.upkeepPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summary = vm.cleanPreview {
                if summary.lines.isEmpty {
                    ContentUnavailableView {
                        Label("System is Clean", systemImage: "checkmark.circle")
                    } description: {
                        Text("No reclaimable caches reported by Mole.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(filteredLines.prefix(150).enumerated()), id: \.offset) { idx, line in
                                cleanerRow(line, index: idx)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                    .upkeepSoftTopScrollEdge()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Label("Ready to Scan", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Inspect caches safely without deleting any files.")
                } actions: {
                    Button("Start Dry-Run") { vm.runMoleDryRun() }
                        .buttonStyle(.upkeepPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerSubtitle: String {
        if let summary = vm.cleanPreview {
            return summary.isDryRun
                ? "\(summary.itemCount) candidate items found · No files deleted yet"
                : "\(summary.totalReclaimed) reclaimed safely"
        }
        return "Inspects system and app caches safely before deleting"
    }

    private func cleanerRow(_ line: String, index: Int) -> some View {
        let isHeader = line.hasPrefix("➤")
        let isCandidate = line.hasPrefix("○") || line.hasPrefix("◎")
        let isCleaned = line.hasPrefix("✓")
        let stripped = line.dropFirst().trimmingCharacters(in: .whitespaces)

        return HStack(spacing: 10) {
            if isHeader {
                Text(stripped)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, index == 0 ? 0 : 12)
                    .padding(.bottom, 4)
            } else {
                Image(systemName: isCleaned ? "checkmark.circle.fill" : (isCandidate ? "circle.dashed" : "info.circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(isCleaned ? MenuBarTheme.Colors.success : (isCandidate ? MenuBarTheme.Colors.moleClean : .secondary))
                    .frame(width: 14)

                Text(stripped)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isHeader ? 2 : 5)
        .background(
            hoveredIndex == index && !isHeader
                ? Color.primary.opacity(0.05)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { hoveredIndex = $0 ? index : nil }
    }
}

// MARK: - 4. Uninstaller (Unified macOS 27 Workspace)

private enum UninstallerSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"

    var id: String { rawValue }
}

private struct UninstallerWorkspacePane: View {
    @Bindable var vm: TrayViewModel
    @State private var sortOrder: UninstallerSort = .name

    private var sortedApps: [MoleInstalledApp] {
        switch sortOrder {
        case .name:
            return vm.filteredApps
        case .size:
            return vm.filteredApps.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    MenuBarSearchField(
                        text: $vm.appQuery,
                        placeholder: "Filter installed applications…",
                        onEscape: {
                            if vm.pendingUninstallApp != nil {
                                withAnimation(.snappy) { vm.pendingUninstallApp = nil }
                            }
                        }
                    )

                    Picker("Sort", selection: $sortOrder) {
                        ForEach(UninstallerSort.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                }

                HStack(spacing: 12) {
                    Toggle("Include personal data & support files", isOn: $vm.includePersonalData)
                        .toggleStyle(.checkbox)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .help("Also removes application support files, preferences, and caches (--with-data)")

                    Spacer()

                    if !vm.installedApps.isEmpty {
                        Text("\(vm.filteredApps.count) of \(vm.installedApps.count) apps")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                if let pending = vm.pendingUninstallApp {
                    MenuBarDestructiveConfirmBar(
                        title: "Move \(pending.name) to Trash?",
                        confirmLabel: "Move to Trash",
                        confirmIcon: "trash.fill",
                        onCancel: {
                            withAnimation(.snappy) { vm.pendingUninstallApp = nil }
                        },
                        onConfirm: {
                            vm.confirmUninstall(pending)
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
                    }
                }

                if let err = vm.uninstallError, !vm.installedApps.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(MenuBarTheme.Colors.destructive)
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(MenuBarTheme.Colors.destructive)
                            .lineLimit(2)
                        Spacer()
                        Button("Dismiss") {
                            vm.uninstallError = nil
                        }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .upkeepSearchTarget("uninstaller.apps")

            Divider().opacity(0.22)

            if vm.isLoadingApps {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading installed applications…")
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
                    Button("Retry") { vm.loadApps(force: true) }
                        .buttonStyle(.upkeepPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.filteredApps.isEmpty {
                ContentUnavailableView.search(text: vm.appQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sortedApps.prefix(200)) { app in
                            UninstallerAppRow(
                                app: app,
                                isPending: vm.pendingUninstallApp?.id == app.id,
                                onRemove: {
                                    withAnimation(.snappy) { vm.pendingUninstallApp = app }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .upkeepSoftTopScrollEdge()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 5. Updates & System (DockDoor SupportSettingsView + Handy AboutSettings Pattern)

private struct UpdatesSettingsPane: View {
    @Bindable var updater: UpdateManager
    @Bindable var cleaning: CleaningModeManager
    @Bindable var vm: TrayViewModel
    let coordinator: HUDCoordinator

    @AppStorage(UpkeepSettingsPreferences.showDescriptionsKey) private var showDescriptions = true
    @State private var showResetAlert = false

    var body: some View {
        UpkeepSettingsFormView {
            UpkeepSettingsSection(
                "Upkeep Releases",
                footer: "Automatic update checks run quietly every 6 hours when a GitHub repository is configured."
            ) {
                HStack(spacing: 12) {
                    UpkeepSettingsIcon(systemName: "checkmark.seal.fill", color: .green, size: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current Version")
                            .font(.system(size: 13, weight: .medium))
                        Text("Upkeep v\(updater.currentVersion)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    updateStatusBadge
                }
                .padding(.vertical, 2)
                .upkeepSearchTarget("updates.releases")

                HStack(spacing: 12) {
                    UpkeepSettingsIcon(systemName: "arrow.triangle.2.circlepath", color: .orange, size: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for Updates")
                            .font(.system(size: 13, weight: .medium))
                        Text(lastCheckDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Check Now") {
                        Task { await updater.checkForUpdates() }
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.small)
                    .disabled(updater.isChecking || updater.isInstalling)
                }
                .padding(.vertical, 2)

                Toggle(isOn: $updater.autoCheckUpdates) {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "clock.arrow.2.circlepath", color: .purple)
                        Text("Automatically check for updates")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                LabeledContent {
                    TextField("owner/Upkeep", text: $updater.githubRepo)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                } label: {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "chevron.left.forwardslash.chevron.right", color: .blue)
                        Text("GitHub Repository")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                if let release = updater.availableRelease {
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

                if let status = updater.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = updater.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(MenuBarTheme.Colors.destructive)
                }
            }

            UpkeepSettingsSection("CLI Utilities") {
                LabeledContent {
                    Button("Update CLI Tools") {
                        Task {
                            await updater.updateCLIUtilities()
                            vm.refreshOverview()
                        }
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.small)
                    .disabled(updater.isInstalling)
                } label: {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "terminal.fill", color: .indigo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Mole & Homebrew")
                                .font(.system(size: 13, weight: .medium))
                            Text("Runs `mo update` and `brew update` in parallel")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                    title: "Mole CLI",
                    description: "Powers dry-run cache scanning and app uninstallation",
                    icon: "sparkles",
                    isGranted: MoleService.isInstalled()
                )

                UpkeepStatusRow(
                    title: "Homebrew CLI",
                    description: "Powers package search, installation, and upgrades",
                    icon: "shippingbox",
                    isGranted: BrewService.isInstalled()
                )
            }

            UpkeepSettingsSection("Preferences & Application") {
                Toggle(isOn: $showDescriptions) {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "text.alignleft", color: .teal)
                        Text("Show setting descriptions")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .upkeepAnnotation("Display brief explanations underneath settings rows across Upkeep.")
                .upkeepSearchTarget("updates.preferences")

                LabeledContent {
                    Button("Reset…", role: .destructive) {
                        showResetAlert = true
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.small)
                } label: {
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "arrow.counterclockwise", color: .orange)
                        Text("Reset Preferences to Defaults")
                            .font(.system(size: 13, weight: .medium))
                    }
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
                    HStack(spacing: 10) {
                        UpkeepSettingsIcon(systemName: "power", color: .red)
                        Text("Application Lifecycle")
                            .font(.system(size: 13, weight: .medium))
                    }
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
            return "Last checked: \(formatted)"
        }
        return "No recent checks"
    }

    @ViewBuilder
    private var updateStatusBadge: some View {
        if updater.isChecking {
            ProgressView()
                .controlSize(.small)
        } else if let release = updater.availableRelease {
            Label("v\(release.version) available", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.blue)
        } else if updater.errorMessage != nil {
            Label("Check Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        } else {
            Label("Up to Date", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        }
    }
}
