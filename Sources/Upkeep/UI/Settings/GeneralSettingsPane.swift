import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var vm: TrayViewModel
    @Bindable var updater: UpdateManager
    let coordinator: HUDCoordinator

    @AppStorage(UpkeepSettingsPreferences.showDescriptionsKey) private var showDescriptions = true
    @State private var showResetAlert = false

    var body: some View {
        UpkeepSettingsFormView {
            UpkeepSettingsSection("Interface") {
                Toggle(isOn: $showDescriptions) {
                    UpkeepSettingLabel(
                        "Show setting descriptions",
                        subtitle: "Display explanations beneath settings throughout Upkeep."
                    )
                }
                .tint(UpkeepSettingsPalette.accent)
                .accessibilityLabel("Show setting descriptions")
                .upkeepSearchTarget("updates.preferences")
            }

            UpkeepSettingsSection("Keyboard Shortcuts") {
                UpkeepSettingsShortcut(title: "Open Upkeep", keys: ["⌘", ","])
                UpkeepSettingsShortcut(title: "Find a Setting", keys: ["⌘", "F"])
                    .upkeepSearchTarget("general.shortcuts")
            }

            UpkeepSettingsSection("Application") {
                LabeledContent {
                    Button("Reset…", role: .destructive) {
                        showResetAlert = true
                    }
                    .buttonStyle(.upkeepSecondary)
                } label: {
                    UpkeepSettingLabel("Restore Default Preferences")
                }
                .upkeepSearchTarget("general.reset")

                LabeledContent("Upkeep") {
                    HStack(spacing: 8) {
                        Button("Restart Upkeep") { coordinator.restartApp() }
                        Button("Quit Upkeep") { coordinator.quitApp() }
                    }
                    .buttonStyle(.upkeepSecondary)
                }
                .upkeepSearchTarget("general.lifecycle")
            }
        }
        .alert("Restore Default Preferences?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Defaults", role: .destructive) {
                vm.selectedAwakeMode = .displayAndSystem
                KeepAwakeManager.shared.setKeepsAwakeWithLidClosed(false)
                vm.cleaningDuration = 60
                vm.cleaningDimScreen = true
                vm.cleaningLockPointer = false
                vm.includePersonalData = false
                showDescriptions = true
                updater.autoCheckUpdates = true
            }
        } message: {
            Text("This restores the default Caffeinate, Clean Keys, uninstaller, interface, and automatic update preferences.")
        }
    }
}
