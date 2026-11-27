import AppKit
import SwiftUI

struct UpdatesSettingsPane: View {
    @Bindable var updater: UpdateManager
    @Bindable var cleaning: CleaningModeManager
    @State private var showReleaseNotes = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        UpkeepSettingsFormView {
            versionStatus
                .upkeepSearchTarget("updates.releases")
        } content: {
            if updater.errorMessage != nil || updater.availableRelease != nil {
                UpkeepSettingsSection("Release Status") {
                    if let error = updater.errorMessage {
                        UpkeepSettingsCallout(
                            tone: .warning,
                            title: "Upkeep Update Failed",
                            message: error
                        )
                    }

                    if let release = updater.availableRelease {
                        LabeledContent {
                            Button {
                                Task { await updater.installAvailableUpdate() }
                            } label: {
                                UpkeepTaskLabel(
                                    title: release.downloadURL != nil ? "Install & Relaunch" : "Open Release",
                                    systemImage: release.downloadURL != nil ? "arrow.down.circle" : "arrow.up.right",
                                    runningTitle: "Installing…",
                                    isRunning: updater.isInstalling
                                )
                            }
                            .buttonStyle(.upkeepPrimary)
                            .tint(UpkeepSettingsPalette.accent)
                            .disabled(updater.isInstalling || updater.isChecking || updater.isUpdatingHomebrew)
                        } label: {
                            UpkeepSettingLabel("Version \(release.version)", subtitle: "An Upkeep update is available.")
                        }

                        if !release.releaseNotes.isEmpty {
                            DisclosureGroup("Release Notes", isExpanded: $showReleaseNotes) {
                                ScrollView {
                                    Text(release.releaseNotes)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 160)
                                .padding(.vertical, 6)
                            }
                            .animation(reduceMotion ? nil : UpkeepMotion.disclosure, value: showReleaseNotes)
                        }
                    }
                }
            }

            UpkeepSettingsSection(
                "Update Preferences",
                footer: "Upkeep checks for updates when it opens if at least six hours have passed since the last check."
            ) {
                Toggle(isOn: $updater.autoCheckUpdates) {
                    UpkeepSettingLabel("Automatically check for updates")
                }
                .tint(UpkeepSettingsPalette.accent)
                .upkeepSearchTarget("updates.autoCheck")

                LabeledContent {
                    TextField("GitHub Repository", text: $updater.githubRepo, prompt: Text("owner/Upkeep"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                } label: {
                    UpkeepSettingLabel("GitHub Repository")
                }
                .upkeepSearchTarget("updates.repository")
            }

            UpkeepSettingsSection(
                "Permissions",
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
            }
        }
    }

    private var versionStatus: some View {
        UpkeepSettingsFeature(title: "Upkeep v\(updater.currentVersion)", tint: UpkeepSettingsPalette.accent) {
            UpkeepAppIconView(size: 46)
        } detail: {
            Text(updater.statusMessage ?? lastCheckDescription)
        } actions: {
            Button {
                Task { await updater.checkForUpdates() }
            } label: {
                UpkeepTaskLabel(
                    title: "Check for Updates",
                    systemImage: "arrow.clockwise",
                    runningTitle: "Checking…",
                    isRunning: updater.isChecking
                )
            }
            .buttonStyle(.upkeepSecondary)
            .disabled(updater.isChecking || updater.isInstalling)
        }
    }

    private var lastCheckDescription: String {
        if let lastCheck = updater.lastCheckedAt {
            let formatted = lastCheck.formatted(date: .abbreviated, time: .shortened)
            return "Last checked \(formatted)"
        }
        return "No update checks recorded"
    }

}
