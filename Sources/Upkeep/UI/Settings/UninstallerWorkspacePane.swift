import AppKit
import SwiftUI

struct UninstallerWorkspacePane: View {
    @Bindable var vm: TrayViewModel
    @State private var copiedError = false

    var body: some View {
        UpkeepSettingsFormView {
            HStack(spacing: 10) {
                UpkeepPaneSearchField(placeholder: "Filter installed applications…", text: $vm.appQuery)

                Picker("Sort by", selection: $vm.appSortOrder) {
                    ForEach(TrayViewModel.AppSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Button {
                    vm.loadApps(force: true)
                } label: {
                    UpkeepTaskLabel(
                        title: "Reload",
                        systemImage: "arrow.clockwise",
                        runningTitle: vm.isUpdatingAppSizes ? "Measuring sizes…" : "Loading…",
                        isRunning: vm.isLoadingApps || vm.isUpdatingAppSizes
                    )
                }
                .buttonStyle(.upkeepSecondary)
                .disabled(vm.isLoadingApps || vm.isUpdatingAppSizes || vm.isUninstallingApp)
            }
            .upkeepSearchTarget("uninstaller.apps")
        } content: {
            if let status = vm.uninstallStatus, !vm.isUninstallingApp {
                Section {
                    HStack {
                        UpkeepSettingsCallout(tone: .success, message: status)
                        Button("Dismiss", systemImage: "xmark") { vm.uninstallStatus = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }

            if let error = vm.uninstallError {
                Section {
                    UpkeepSettingsCallout(
                        title: "Uninstaller Error",
                        message: error,
                        actionTitle: copiedError ? "Copied" : "Copy Error"
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                        copiedError = true
                    }
                    .onChange(of: vm.uninstallError) {
                        copiedError = false
                    }
                    Button("Dismiss Error") { vm.uninstallError = nil }
                        .buttonStyle(.borderless)
                }
            }

            UpkeepSettingsSection("Installed Applications") {
                if vm.isLoadingApps && vm.installedApps.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finding installed applications…").foregroundStyle(.secondary)
                    }
                } else if vm.filteredApps.isEmpty {
                    emptyList
                } else {
                    ForEach(vm.filteredApps.prefix(200)) { app in
                        applicationRow(app)
                    }
                }
            }
        }
        .sheet(item: $vm.pendingUninstallApp) { app in
            UninstallReviewSheet(app: app, vm: vm)
                .interactiveDismissDisabled(vm.isUninstallingApp)
        }
    }

    private var emptyList: some View {
        HStack {
            if vm.installedApps.isEmpty {
                Label("No applications to show", systemImage: "app.dashed")
            } else {
                Label("No apps match “\(vm.appQuery)”", systemImage: "magnifyingglass")
                Spacer()
                Button("Clear Filter") { vm.appQuery = "" }
                    .buttonStyle(.upkeepSecondary)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func applicationRow(_ app: MoleInstalledApp) -> some View {
        HStack(spacing: 12) {
            AppIconView(path: app.path, size: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(app.source ?? app.path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(app.size == nil ? "—" : app.formattedSize)
                .font(.callout.monospacedDigit())
                .accessibilityLabel(app.size == nil ? "App size unavailable" : app.formattedSize)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("Review…") { vm.inspectForUninstall(app) }
                .buttonStyle(.upkeepSecondary)
                .controlSize(.small)
                .accessibilityLabel("Review removal of \(app.name)")
                .disabled(vm.isUninstallingApp || vm.isInspectingUninstall)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
        }
    }
}

private struct UninstallReviewSheet: View {
    let app: MoleInstalledApp
    @Bindable var vm: TrayViewModel
    @State private var selectedPaths: Set<String> = []
    @State private var useHomebrewCask = true

    private var inspection: UninstallInspection? { vm.uninstallInspection }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIconView(path: app.path, size: 46)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review Removal")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(app.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(22)

            if let inspection {
                reviewForm(inspection)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for files related to \(app.name)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            actionBar
        }
        .frame(width: 620, height: 520)
        .onChange(of: inspection, initial: true) { _, newInspection in
            selectedPaths = Set(newInspection?.leftovers.filter(\.defaultSelected).map(\.path) ?? [])
        }
    }

    private func reviewForm(_ inspection: UninstallInspection) -> some View {
        Form {
            if let error = vm.uninstallError {
                Section {
                    UpkeepSettingsCallout(title: "Removal Failed", message: error)
                }
            }

            if inspection.officialUninstallerVendor != nil || inspection.hasSiblingApp {
                Section {
                    if let vendor = inspection.officialUninstallerVendor {
                        UpkeepSettingsCallout(
                            title: "Official Uninstaller Recommended",
                            message: "\(vendor)’s uninstaller can also remove any system extensions, background services, and other installed components."
                        )
                    }
                    if inspection.hasSiblingApp {
                        UpkeepSettingsCallout(
                            tone: .info,
                            icon: "shield",
                            title: "Shared Data Protected",
                            message: "Upkeep found another copy or channel of this app and will preserve shared files."
                        )
                    }
                }
            }

            if let token = inspection.homebrewCaskToken {
                UpkeepSettingsSection("Removal Method") {
                    Toggle(isOn: $useHomebrewCask) {
                        UpkeepSettingLabel(
                            "Uninstall with Homebrew",
                            subtitle: "Installed as the \(token) cask."
                        )
                    }
                    .tint(UpkeepSettingsPalette.accent)
                    .accessibilityLabel("Uninstall with Homebrew")

                    if useHomebrewCask && !inspection.hasSiblingApp {
                        Text("Homebrew may also remove files listed by the cask, including preferences and support files outside this review.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            UpkeepSettingsSection("Related Files") {
                if inspection.leftovers.isEmpty {
                    Text("Upkeep found no related files to review.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("\(selectedPaths.count) selected") {
                        Menu("Select") {
                            Button("Recommended") {
                                selectedPaths = Set(inspection.leftovers.filter(\.defaultSelected).map(\.path))
                            }
                            Button("All User Files") {
                                selectedPaths = Set(inspection.leftovers.filter { !$0.isSystem }.map(\.path))
                            }
                            Button("Deselect All") { selectedPaths.removeAll() }
                        }
                        .fixedSize()
                    }
                    ForEach(inspection.leftovers) { item in
                        UpkeepReviewFileRow(
                            title: item.displayPath,
                            detail: item.category,
                            note: item.isSystem ? "Administrator access required" : item.holdbackReason,
                            size: item.formattedSize,
                            path: item.path,
                            isSelected: Binding(
                                get: { selectedPaths.contains(item.path) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedPaths.insert(item.path)
                                    } else {
                                        selectedPaths.remove(item.path)
                                    }
                                }
                            )
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .upkeepSoftTopScrollEdge()
        .disabled(vm.isUninstallingApp)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let inspection {
                let bytes = inspection.leftovers.reduce(app.size ?? 0) { total, item in
                    total + (selectedPaths.contains(item.path) ? item.sizeBytes : 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    if inspection.leftovers.contains(where: { $0.isSystem && selectedPaths.contains($0.path) }) {
                        Text("Administrator access required")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
            Button("Cancel") { vm.cancelUninstallReview() }
                .buttonStyle(.upkeepSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(vm.isUninstallingApp)
            Button(role: .destructive) {
                vm.executeReviewedUninstall(selectedLeftoverPaths: selectedPaths, useHomebrewCask: useHomebrewCask)
            } label: {
                UpkeepTaskLabel(
                    title: useHomebrewCask && inspection?.homebrewCaskToken != nil ? "Uninstall with Homebrew" : "Move to Trash",
                    systemImage: "trash",
                    runningTitle: "Removing…",
                    isRunning: vm.isUninstallingApp
                )
            }
            .buttonStyle(.upkeepPrimary)
            .tint(.red)
            .disabled(inspection == nil || vm.isUninstallingApp)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }
}
