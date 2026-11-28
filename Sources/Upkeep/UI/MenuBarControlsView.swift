import AppKit
import SwiftUI

// MARK: - MenuBarHeaderView

/// macOS 27 Control Center–style header bar for Upkeep.
/// Displays app identity, live active status pill when running, and a Liquid Glass Updates button.
public struct MenuBarHeaderView: View {
    @Bindable public var updater: UpdateManager = .shared
    @Bindable public var keepAwake: KeepAwakeManager = .shared
    @Binding public var showUpdaterPanel: Bool

    @State private var isUpdateHovered: Bool = false

    public init(
        updater: UpdateManager = .shared,
        keepAwake: KeepAwakeManager = .shared,
        showUpdaterPanel: Binding<Bool>
    ) {
        self.updater = updater
        self.keepAwake = keepAwake
        self._showUpdaterPanel = showUpdaterPanel
    }

    public init(
        vm: TrayViewModel,
        updater: UpdateManager = .shared,
        keepAwake: KeepAwakeManager = .shared
    ) {
        self.updater = updater
        self.keepAwake = keepAwake
        self._showUpdaterPanel = Binding(
            get: { vm.showUpdaterPanel },
            set: { vm.showUpdaterPanel = $0 }
        )
    }

    public var body: some View {
        HStack(spacing: 10) {
            // App Title & Version
            VStack(alignment: .leading, spacing: 1) {
                Text("Upkeep")
                    .font(MenuBarTheme.Typography.popoverTitle)
                    .foregroundStyle(.primary)

                Text("v\(updater.currentVersion)")
                    .font(MenuBarTheme.Typography.popoverSubtitle)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            // Active Caffeinate indicator pill badge (quiet by default, tinted only when active)
            if keepAwake.isActive {
                let scopeTag = keepAwake.mode == .displayAndSystem ? "Display" : "System"
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 4) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("\(scopeTag) · \(keepAwake.formattedRemaining)")
                            .font(MenuBarTheme.Typography.timerBadge)
                    }
                    .foregroundStyle(MenuBarTheme.Colors.caffeinate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MenuBarTheme.Colors.caffeinate.opacity(0.16), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(MenuBarTheme.Colors.caffeinate.opacity(0.32), lineWidth: 0.75)
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .accessibilityLabel("Caffeinate active: \(scopeTag) mode, \(keepAwake.formattedRemaining) remaining")
                }
            }

            // Liquid Glass Updates / Settings Toggle Button
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    showUpdaterPanel.toggle()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: showUpdaterPanel ? "xmark" : "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            showUpdaterPanel
                                ? AnyShapeStyle(.primary)
                                : (updater.hasUpdateAvailable ? AnyShapeStyle(MenuBarTheme.Colors.success) : AnyShapeStyle(Color.secondary))
                        )
                        .frame(width: 28, height: 28)
                        .background {
                            if #available(macOS 26.0, *) {
                                Circle()
                                    .fill(Color.clear)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            } else {
                                Circle()
                                    .fill(isUpdateHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
                            }
                        }

                    if updater.hasUpdateAvailable && !showUpdaterPanel {
                        Circle()
                            .fill(MenuBarTheme.Colors.success)
                            .frame(width: 7, height: 7)
                            .overlay {
                                Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                            }
                            .offset(x: -1, y: 1)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isUpdateHovered = $0 }
            .help(
                updater.hasUpdateAvailable
                    ? "Update available · Click to review"
                    : (showUpdaterPanel ? "Close updates" : "Updates & CLI tools")
            )
            .accessibilityLabel(showUpdaterPanel ? "Close updates" : "Updates and CLI tools")
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - MenuBarControlsTab

/// Apple HIG macOS 27 Controls hierarchy:
/// - No minimized mode or duplicate quick-action mini-cards (Cleaner & Uninstaller live in their own tabs).
/// - Clean grouped sections with Title-Case section headers ("Power & Input", "Developer Tools").
/// - Full-width rows with primary native controls (Toggle, Lock button, Upgrade/Search) and Liquid Glass pills.
public struct MenuBarControlsTab: View {
    @Bindable public var vm: TrayViewModel
    public let coordinator: HUDCoordinator
    @Bindable public var keepAwake: KeepAwakeManager = .shared
    @Bindable public var cleaning: CleaningModeManager = .shared
    public var onSelectSection: ((TraySection) -> Void)?

    @State private var hoveredGroup: String? = nil

    public init(
        vm: TrayViewModel,
        coordinator: HUDCoordinator,
        keepAwake: KeepAwakeManager = .shared,
        cleaning: CleaningModeManager = .shared,
        onSelectSection: ((TraySection) -> Void)? = nil
    ) {
        self.vm = vm
        self.coordinator = coordinator
        self.keepAwake = keepAwake
        self.cleaning = cleaning
        self.onSelectSection = onSelectSection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section 1: Power & Input (Primary system utilities)
            VStack(alignment: .leading, spacing: 6) {
                Text("Power & Input")
                    .font(MenuBarTheme.Typography.sectionHeader)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    caffeinateRow
                    Divider().opacity(0.18).padding(.horizontal, 12)
                    cleanKeysRow
                }
                .trayTile(
                    isActive: keepAwake.isActive || cleaning.isLocked,
                    accent: keepAwake.isActive ? MenuBarTheme.Colors.caffeinate : MenuBarTheme.Colors.cleanKeys,
                    isHovered: hoveredGroup == "power",
                    cornerRadius: MenuBarTheme.Metrics.tileCornerRadius
                )
                .onHover { hoveredGroup = $0 ? "power" : nil }
            }

            // Section 2: Developer Tools
            VStack(alignment: .leading, spacing: 6) {
                Text("Developer Tools")
                    .font(MenuBarTheme.Typography.sectionHeader)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                homebrewRow
                    .trayTile(
                        isActive: false,
                        accent: MenuBarTheme.Colors.homebrew,
                        isHovered: hoveredGroup == "brew",
                        cornerRadius: MenuBarTheme.Metrics.tileCornerRadius
                    )
                    .onHover { hoveredGroup = $0 ? "brew" : nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Caffeinate Grouped Row

    private var caffeinateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            keepAwake.isActive
                                ? AnyShapeStyle(MenuBarTheme.Colors.caffeinate)
                                : AnyShapeStyle(Color.primary.opacity(0.08))
                        )
                        .frame(
                            width: MenuBarTheme.Metrics.iconContainerSize,
                            height: MenuBarTheme.Metrics.iconContainerSize
                        )

                    Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(keepAwake.isActive ? Color.white : Color.primary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Caffeinate")
                        .font(MenuBarTheme.Typography.cardTitle)
                        .foregroundStyle(.primary)

                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(keepAwake.isActive ? "Keeping Mac awake · \(keepAwake.formattedRemaining)" : "Prevent display & system sleep")
                            .font(MenuBarTheme.Typography.cardSubtitle)
                            .foregroundStyle(keepAwake.isActive ? MenuBarTheme.Colors.caffeinate : .secondary)
                    }
                }

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
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
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(MenuBarTheme.Colors.caffeinate)
                .accessibilityLabel("Toggle Caffeinate")
            }

            // Mode & Duration Controls
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    MenuBarPillButton(
                        title: "Display",
                        isSelected: vm.selectedAwakeMode == .displayAndSystem,
                        accent: MenuBarTheme.Colors.caffeinate
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            vm.selectedAwakeMode = .displayAndSystem
                            if keepAwake.isActive {
                                let mins = keepAwake.remainingSeconds.map { max(1, $0 / 60) }
                                keepAwake.start(durationMinutes: mins, mode: .displayAndSystem)
                            }
                        }
                    }

                    MenuBarPillButton(
                        title: "System",
                        isSelected: vm.selectedAwakeMode == .systemOnly,
                        accent: MenuBarTheme.Colors.caffeinate
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            vm.selectedAwakeMode = .systemOnly
                            if keepAwake.isActive {
                                let mins = keepAwake.remainingSeconds.map { max(1, $0 / 60) }
                                keepAwake.start(durationMinutes: mins, mode: .systemOnly)
                            }
                        }
                    }
                }
                .frame(width: 132)

                Divider().frame(height: 16).opacity(0.2)

                HStack(spacing: 4) {
                    durationPill(label: "30m", minutes: 30)
                    durationPill(label: "1h", minutes: 60)
                    durationPill(label: "2h", minutes: 120)
                    durationPill(label: "∞", minutes: nil)
                }
            }
        }
        .padding(MenuBarTheme.Metrics.tilePadding)
    }

    private func durationPill(label: String, minutes: Int?) -> some View {
        let isSelected: Bool = {
            guard keepAwake.isActive else { return false }
            guard let minutes else { return keepAwake.remainingSeconds == nil }
            guard let rem = keepAwake.remainingSeconds else { return false }
            return abs(rem - (minutes * 60)) <= 60
        }()

        return MenuBarPillButton(
            title: label,
            isSelected: isSelected,
            accent: MenuBarTheme.Colors.caffeinate,
            isMonospaced: true
        ) {
            withAnimation(.snappy(duration: 0.18)) {
                keepAwake.start(durationMinutes: minutes, mode: vm.selectedAwakeMode)
            }
        }
    }

    // MARK: - Clean Keys Grouped Row

    private var cleanKeysRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            cleaning.isLocked
                                ? AnyShapeStyle(MenuBarTheme.Colors.cleanKeys)
                                : AnyShapeStyle(Color.primary.opacity(0.08))
                        )
                        .frame(
                            width: MenuBarTheme.Metrics.iconContainerSize,
                            height: MenuBarTheme.Metrics.iconContainerSize
                        )

                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(cleaning.isLocked ? Color.white : Color.primary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Clean Keys")
                        .font(MenuBarTheme.Typography.cardTitle)
                        .foregroundStyle(.primary)

                    if cleaning.permissionDenied || !cleaning.hasAccessibility {
                        Label("Accessibility permission required", systemImage: "exclamationmark.triangle.fill")
                            .font(MenuBarTheme.Typography.cardSubtitle)
                            .foregroundStyle(MenuBarTheme.Colors.warning)
                    } else {
                        Text(cleaning.isLocked ? "Locked · \(cleaning.remainingSeconds)s remaining" : "Temporarily lock keyboard for cleaning")
                            .font(MenuBarTheme.Typography.cardSubtitle)
                            .foregroundStyle(cleaning.isLocked ? MenuBarTheme.Colors.cleanKeys : .secondary)
                    }
                }

                Spacer(minLength: 8)

                if cleaning.permissionDenied || !cleaning.hasAccessibility {
                    Button("Grant Access") {
                        cleaning.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MenuBarTheme.Colors.warning)
                    .controlSize(.small)
                } else {
                    Button(cleaning.isLocked ? "Unlock" : "Lock") {
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
                    .buttonStyle(.borderedProminent)
                    .tint(cleaning.isLocked ? MenuBarTheme.Colors.cleanKeys : .accentColor)
                    .controlSize(.small)
                    .accessibilityLabel(cleaning.isLocked ? "Unlock keyboard" : "Lock keyboard for cleaning")
                }
            }

            if cleaning.hasAccessibility && !cleaning.permissionDenied {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        MenuBarPillButton(
                            title: "Dim",
                            icon: vm.cleaningDimScreen ? "moon.fill" : "sun.max",
                            isSelected: vm.cleaningDimScreen,
                            accent: MenuBarTheme.Colors.cleanKeys
                        ) {
                            withAnimation(.snappy(duration: 0.15)) {
                                vm.cleaningDimScreen.toggle()
                            }
                        }

                        MenuBarPillButton(
                            title: "Mouse",
                            icon: vm.cleaningLockPointer ? "cursorarrow.slash" : "cursorarrow",
                            isSelected: vm.cleaningLockPointer,
                            accent: MenuBarTheme.Colors.cleanKeys
                        ) {
                            withAnimation(.snappy(duration: 0.15)) {
                                vm.cleaningLockPointer.toggle()
                            }
                        }
                    }
                    .frame(width: 132)

                    Divider().frame(height: 16).opacity(0.2)

                    HStack(spacing: 4) {
                        MenuBarPillButton(
                            title: "30s",
                            isSelected: vm.cleaningDuration == 30,
                            accent: MenuBarTheme.Colors.cleanKeys,
                            isMonospaced: true
                        ) {
                            withAnimation(.snappy(duration: 0.18)) { vm.cleaningDuration = 30 }
                        }

                        MenuBarPillButton(
                            title: "60s",
                            isSelected: vm.cleaningDuration == 60,
                            accent: MenuBarTheme.Colors.cleanKeys,
                            isMonospaced: true
                        ) {
                            withAnimation(.snappy(duration: 0.18)) { vm.cleaningDuration = 60 }
                        }

                        MenuBarPillButton(
                            title: "2m",
                            isSelected: vm.cleaningDuration == 120,
                            accent: MenuBarTheme.Colors.cleanKeys,
                            isMonospaced: true
                        ) {
                            withAnimation(.snappy(duration: 0.18)) { vm.cleaningDuration = 120 }
                        }
                    }
                }
            }
        }
        .padding(MenuBarTheme.Metrics.tilePadding)
    }

    // MARK: - Homebrew Grouped Row

    private var homebrewRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(MenuBarTheme.Colors.homebrew.opacity(0.16))
                    .frame(
                        width: MenuBarTheme.Metrics.iconContainerSize,
                        height: MenuBarTheme.Metrics.iconContainerSize
                    )
                Image(systemName: "mug.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MenuBarTheme.Colors.homebrew)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Homebrew")
                    .font(MenuBarTheme.Typography.cardTitle)
                    .foregroundStyle(.primary)

                Text(brewSubtitle)
                    .font(MenuBarTheme.Typography.cardSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if vm.brewOutdatedCount > 0 {
                Button {
                    vm.upgradeAllBrew()
                } label: {
                    if vm.isUpgradingBrew {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Upgrade \(vm.brewOutdatedCount)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MenuBarTheme.Colors.homebrew)
                .controlSize(.small)
                .disabled(vm.isUpgradingBrew)
            }

            Button("Search") {
                coordinator.showHomebrewHUD()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(MenuBarTheme.Metrics.tilePadding)
    }

    private var brewSubtitle: String {
        if let status = vm.brewStatusText { return status }
        if vm.brewInstalledCount == 0 { return "Search formulae & casks · ⌘1–⌘4, ⌘K" }
        if vm.brewOutdatedCount > 0 {
            return "\(vm.brewInstalledCount) installed · \(vm.brewOutdatedCount) outdated"
        }
        return "\(vm.brewInstalledCount) packages installed"
    }
}

// MARK: - MenuBarFooterView

/// Apple HIG-compliant footer bar displaying quiet environment status indicators
/// and a standard trailing Quit Upkeep (⌘Q) action.
public struct MenuBarFooterView: View {
    @Bindable public var cleaning: CleaningModeManager = .shared
    @Bindable public var keepAwake: KeepAwakeManager = .shared
    public var onQuit: (() -> Void)?

    @State private var isQuitHovered: Bool = false

    public init(
        cleaning: CleaningModeManager = .shared,
        keepAwake: KeepAwakeManager = .shared,
        onQuit: (() -> Void)? = nil
    ) {
        self.cleaning = cleaning
        self.keepAwake = keepAwake
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.18)

            HStack(spacing: 8) {
                MenuBarStatusBadge(
                    label: "Brew",
                    status: BrewService.isInstalled() ? .ok : .warning
                )

                MenuBarStatusBadge(
                    label: "Accessibility",
                    status: cleaning.hasAccessibility ? .ok : .warning
                ) {
                    cleaning.refreshPermissionStatus()
                    if !cleaning.hasAccessibility {
                        cleaning.openAccessibilitySettings()
                    }
                }
                .help(cleaning.hasAccessibility ? "Accessibility Granted" : "Click to refresh or open Settings")

                Spacer(minLength: 8)

                Button {
                    if let onQuit {
                        onQuit()
                    } else {
                        keepAwake.stop()
                        cleaning.stop()
                        NSApp.terminate(nil)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Quit")
                        Text("⌘Q")
                            .foregroundStyle(.tertiary)
                    }
                    .font(MenuBarTheme.Typography.footerText)
                    .foregroundStyle(isQuitHovered ? Color.primary : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        isQuitHovered ? Color.primary.opacity(0.07) : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
                .onHover { isQuitHovered = $0 }
                .help("Quit Upkeep (⌘Q)")
                .accessibilityLabel("Quit Upkeep")
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - MenuBarUpdaterPanel

/// Inline updater panel for reviewing updates, repository configuration,
/// auto-check preferences, and updating CLI tool dependencies.
public struct MenuBarUpdaterPanel: View {
    @Bindable public var updater: UpdateManager = .shared
    public var vm: TrayViewModel?
    public var onCLIUpdated: (() -> Void)?

    public init(
        updater: UpdateManager = .shared,
        vm: TrayViewModel? = nil,
        onCLIUpdated: (() -> Void)? = nil
    ) {
        self.updater = updater
        self.vm = vm
        self.onCLIUpdated = onCLIUpdated
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updates & CLI Tools")
                        .font(MenuBarTheme.Typography.wideTileTitle)
                        .foregroundStyle(.primary)

                    Text("Installed version: v\(updater.currentVersion)")
                        .font(MenuBarTheme.Typography.wideTileSubtitle)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await updater.checkForUpdates() }
                } label: {
                    if updater.isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Check Now")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(updater.isChecking || updater.isInstalling)
            }

            HStack(spacing: 6) {
                Text("Repo:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("owner/Upkeep", text: $updater.githubRepo)
                    .textFieldStyle(.roundedBorder)
                    .font(MenuBarTheme.Typography.searchField)
            }

            Toggle("Automatically check for updates", isOn: $updater.autoCheckUpdates)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let release = updater.availableRelease {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("v\(release.version) is ready", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MenuBarTheme.Colors.success)

                        Spacer()

                        Button(release.downloadURL != nil ? "Install & Relaunch" : "Open Release") {
                            Task { await updater.installAvailableUpdate() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MenuBarTheme.Colors.success)
                        .controlSize(.small)
                        .disabled(updater.isInstalling)
                    }

                    if !release.releaseNotes.isEmpty {
                        Text(release.releaseNotes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(9)
                .background(
                    MenuBarTheme.Colors.success.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: MenuBarTheme.Metrics.innerCornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: MenuBarTheme.Metrics.innerCornerRadius, style: .continuous)
                        .strokeBorder(MenuBarTheme.Colors.success.opacity(0.3), lineWidth: 0.75)
                }
            }

            Divider().opacity(0.2)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Homebrew CLI")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Runs `brew update`")
                        .font(MenuBarTheme.Typography.popoverSubtitle)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(updater.isUpdatingHomebrew ? "Refreshing…" : "Update Brew") {
                    Task {
                        await updater.updateCLIUtilities()
                        vm?.refreshOverview()
                        onCLIUpdated?()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(updater.isInstalling || updater.isUpdatingHomebrew || vm?.isHomebrewBusy == true || !BrewService.isInstalled())
            }

            if let homebrewMessage = updater.homebrewUpdateMessage {
                Text(homebrewMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = updater.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = updater.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(MenuBarTheme.Colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MenuBarTheme.Metrics.tilePadding)
        .trayTile(
            isActive: updater.hasUpdateAvailable,
            accent: MenuBarTheme.Colors.success,
            isHovered: false,
            cornerRadius: MenuBarTheme.Metrics.tileCornerRadius
        )
    }
}
