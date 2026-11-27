import AppKit
import SwiftUI

public struct MainWindowView: View {
    @Bindable public var vm: TrayViewModel
    public let coordinator: HUDCoordinator

    private var keepAwake = KeepAwakeManager.shared
    private var cleaning = CleaningModeManager.shared
    private var updater = UpdateManager.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var isSidebarFocused: Bool

    public init(vm: TrayViewModel, coordinator: HUDCoordinator) {
        self.vm = vm
        self.coordinator = coordinator
    }

    private var search: UpkeepSearchEngine { coordinator.settingsSearch }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            ZStack {
                sectionView(for: vm.activeSection)
                    .environment(\.upkeepSettingsReveal, search.reveal(for: vm.activeSection))
                    .id(vm.activeSection)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
                .animation(reduceMotion ? nil : UpkeepMotion.paneEntrance, value: vm.activeSection)
                .opacity(search.isSearching ? 0 : 1)
                .accessibilityHidden(search.isSearching)
                .allowsHitTesting(!search.isSearching)
                .overlay {
                    if search.isSearching {
                        UpkeepSearchResultsView(engine: search) { item in
                            coordinator.revealSettingsItem(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    UpkeepSettingsPalette.detail.ignoresSafeArea()
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if keepAwake.isActive {
                vm.selectedAwakeMode = keepAwake.mode
            }
            cleaning.refreshPermissionStatus()
            updater.checkIfDue()
            handleSectionAppear(vm.activeSection)
        }
        .onChange(of: vm.activeSection) { _, section in
            handleSectionAppear(section)
            updateWindowTitle()
        }
        .onChange(of: search.query) {
            updateWindowTitle()
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sidebarGroup("Upkeep", sections: [.general, .updates])
                sidebarGroup("Tools", sections: [.controls, .cleanKeys])
                sidebarGroup("Maintenance", sections: [.homebrew, .cleaner, .uninstaller])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background {
            Group {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    UpkeepSettingsSidebarMaterial()
                }
            }
            .ignoresSafeArea()
        }
        .upkeepSoftTopScrollEdge()
        .frame(minWidth: 220, idealWidth: 220)
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 250)
        .toolbar(removing: .sidebarToggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
        .focusable(interactions: .edit)
        .focused($isSidebarFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            moveSidebarSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSidebarSelection(by: 1)
            return .handled
        }
    }

    private func sidebarGroup(_ title: String, sections: [TraySection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)

            ForEach(sections) { section in
                sidebarRow(section)
            }
        }
    }

    private func sidebarRow(_ section: TraySection) -> some View {
        let selected = vm.activeSection == section && !search.isSearching

        return Button {
            coordinator.selectSettingsSection(section)
            isSidebarFocused = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(section.settingsTitle)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                sidebarStatus(for: section)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(.rect(cornerRadius: 8))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(UpkeepSettingsPalette.selectedSidebarRow)
                        .overlay {
                            if isSidebarFocused {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(UpkeepSettingsPalette.accent.opacity(0.58))
                            }
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func moveSidebarSelection(by offset: Int) {
        let sections = TraySection.allCases
        guard let current = sections.firstIndex(of: vm.activeSection) else { return }
        let next = current + offset
        guard sections.indices.contains(next) else { return }
        coordinator.selectSettingsSection(sections[next])
    }

    @ViewBuilder
    private func sidebarStatus(for section: TraySection) -> some View {
        if section == .homebrew && vm.isHomebrewBusy {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Homebrew operation in progress")
        } else if section == .homebrew && vm.brewOutdatedCount > 0 {
            Text(vm.brewOutdatedCount, format: .number)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.08), in: .capsule)
                .accessibilityLabel("\(vm.brewOutdatedCount) package upgrades")
        } else if let status = status(for: section) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .accessibilityLabel(status.label)
        }
    }

    private func status(for section: TraySection) -> (label: String, color: Color)? {
        switch section {
        case .controls where keepAwake.isActive:
            ("Caffeinate is active", section.accentColor)
        case .cleanKeys where cleaning.isLocked:
            ("Keyboard is locked", section.accentColor)
        case .updates where updater.hasUpdateAvailable:
            ("Update available", section.accentColor)
        default:
            nil
        }
    }

    private func sectionView(for section: TraySection) -> AnyView {
        switch section {
        case .general:
            AnyView(GeneralSettingsPane(vm: vm, updater: updater, coordinator: coordinator))
        case .controls:
            AnyView(CaffeinateSettingsPane(vm: vm, keepAwake: keepAwake))
        case .cleanKeys:
            AnyView(CleanKeysSettingsPane(vm: vm, cleaning: cleaning))
        case .homebrew:
            AnyView(HomebrewSettingsPane(vm: vm, coordinator: coordinator))
        case .cleaner:
            AnyView(CleanerWorkspacePane(vm: vm))
        case .uninstaller:
            AnyView(UninstallerWorkspacePane(vm: vm))
        case .updates:
            AnyView(UpdatesSettingsPane(updater: updater, cleaning: cleaning))
        }
    }

    private func updateWindowTitle() {
        coordinator.updateSettingsTitle(
            section: vm.activeSection,
            resultCount: search.isSearching ? search.results.count : nil
        )
    }

    private func handleSectionAppear(_ section: TraySection) {
        switch section {
        case .homebrew:
            vm.refreshOverview()
        case .cleaner:
            if vm.cleanPreview == nil && !vm.isScanningClean && !vm.isCleaning {
                vm.runMoleDryRun()
            }
        case .uninstaller:
            if vm.installedApps.isEmpty && !vm.isLoadingApps {
                vm.loadApps()
            }
        case .general, .controls, .cleanKeys, .updates:
            break
        }
    }
}
