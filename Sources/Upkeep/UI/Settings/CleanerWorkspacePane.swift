import AppKit
import SwiftUI

struct CleanerWorkspacePane: View {
    @Bindable var vm: TrayViewModel
    @State private var collapsedCategories: Set<String> = []
    @State private var copiedError = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool { vm.isScanningClean || vm.isCleaning }

    var body: some View {
        Group {
            if let scan = vm.cleanerScan, !scan.categories.isEmpty {
                scanResults(scan)
            } else {
                emptyState
            }
        }
        .alert("Delete Selected Files?", isPresented: $vm.confirmClean) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Files", role: .destructive) { vm.executeMoleClean() }
                .disabled(vm.selectedCleanPaths.isEmpty || isBusy)
        } message: {
            Text(cleanupConfirmation)
        }
    }

    private func scanResults(_ scan: CleanerScanResult) -> some View {
        UpkeepSettingsFormView {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scan.formattedTotalSize)
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text("Found in \(scan.categories.count) \(scan.categories.count == 1 ? "category" : "categories")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                scanButton
            }
            .upkeepSearchTarget("cleaner.dryRun")
        } content: {
            if let result = vm.lastCleanResult {
                Section {
                    HStack {
                        UpkeepSettingsCallout(
                            tone: result.failedItems.isEmpty ? .success : .warning,
                            title: "Freed \(result.formattedReclaimedSize)",
                            message: cleanupSummary(result)
                        )
                        Button("Dismiss", systemImage: "xmark") { vm.lastCleanResult = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }

            ForEach(scan.categories) { category in
                categorySection(category)
            }
        }
        .disabled(isBusy)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            selectionBar(scan)
        }
    }

    private func selectionBar(_ scan: CleanerScanResult) -> some View {
        HStack(spacing: 10) {
            Menu {
                Button("Recommended") { vm.selectedCleanPaths = scan.defaultSelectedPaths }
                Button("Select All") { vm.selectedCleanPaths = Set(scan.allItems.map(\.path)) }
                Button("Deselect All") { vm.selectedCleanPaths.removeAll() }
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            .fixedSize()

            Text("\(vm.selectedCleanPaths.count) selected · \(vm.formattedSelectedCleanSize)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                vm.confirmClean = true
            } label: {
                UpkeepTaskLabel(
                    title: "Review Cleanup…",
                    systemImage: "trash",
                    runningTitle: "Cleaning…",
                    isRunning: vm.isCleaning
                )
            }
            .buttonStyle(.upkeepPrimary)
            .tint(UpkeepSettingsPalette.accent)
            .disabled(vm.selectedCleanPaths.isEmpty || isBusy)
        }
        .disabled(isBusy)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func categorySection(_ category: CleanerCategory) -> some View {
        let paths = Set(category.items.map(\.path))
        let count = vm.selectedCleanPaths.intersection(paths).count
        let allSelected = count == paths.count
        let isExpanded = Binding(
            get: { !collapsedCategories.contains(category.id) },
            set: { expanded in
                withAnimation(reduceMotion ? nil : UpkeepMotion.disclosure) {
                    if expanded {
                        collapsedCategories.remove(category.id)
                    } else {
                        collapsedCategories.insert(category.id)
                    }
                }
            }
        )

        return UpkeepSettingsSection(category.title) {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(category.items) { item in
                    let isAppRunning = item.holdbackReason == "App is currently running"
                    UpkeepReviewFileRow(
                        title: item.name,
                        detail: item.displayPath,
                        note: item.requiresAdmin ? "Administrator access required" : isAppRunning ? nil : item.holdbackReason,
                        size: item.formattedSize,
                        path: item.path,
                        isAppRunning: isAppRunning,
                        isSelected: Binding(
                            get: { vm.selectedCleanPaths.contains(item.path) },
                            set: { selected in
                                if selected {
                                    vm.selectedCleanPaths.insert(item.path)
                                } else {
                                    vm.selectedCleanPaths.remove(item.path)
                                }
                            }
                        )
                    )
                }
            } label: {
                HStack {
                    Text("\(count) of \(paths.count) selected")
                        .monospacedDigit()
                    Spacer()
                    Text(category.formattedTotalSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button(allSelected ? "Deselect Group" : "Select Group") {
                        if allSelected {
                            vm.selectedCleanPaths.subtract(paths)
                        } else {
                            vm.selectedCleanPaths.formUnion(paths)
                        }
                    }
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isBusy {
            VStack(spacing: 10) {
                ProgressView()
                Text(vm.isCleaning ? "Cleaning selected files…" : "Scanning for reclaimable files…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.cleanError {
            ContentUnavailableView {
                Label("Scan Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                HStack(spacing: 8) {
                    scanButton
                    Button(copiedError ? "Copied" : "Copy Error") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                        copiedError = true
                    }
                    .buttonStyle(.upkeepSecondary)
                }
            }
        } else if let result = vm.lastCleanResult {
            ContentUnavailableView {
                Label("Freed \(result.formattedReclaimedSize)",
                      systemImage: result.failedItems.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
            } description: {
                Text(cleanupSummary(result))
            } actions: {
                HStack(spacing: 8) {
                    scanButton
                    Button("Dismiss") { vm.lastCleanResult = nil }
                        .buttonStyle(.upkeepSecondary)
                }
            }
            .upkeepSearchTarget("cleaner.dryRun")
        } else {
            ContentUnavailableView {
                Label(vm.cleanerScan == nil ? "Ready to Scan" : "No Reclaimable Files", systemImage: "internaldrive")
            } description: {
                Text("Scan for caches and temporary files you can review before removing.")
            } actions: {
                scanButton
            }
            .upkeepSearchTarget("cleaner.dryRun")
        }
    }

    private var scanButton: some View {
        Button {
            copiedError = false
            vm.runMoleDryRun()
        } label: {
            UpkeepTaskLabel(
                title: vm.cleanerScan == nil ? "Scan" : "Scan Again",
                systemImage: "arrow.clockwise",
                runningTitle: "Scanning…",
                isRunning: vm.isScanningClean
            )
        }
        .buttonStyle(.upkeepSecondary)
        .disabled(isBusy)
    }

    private func cleanupSummary(_ result: CleanExecutionResult) -> String {
        let removed = "\(result.removedCount) items removed"
        return result.failedItems.isEmpty ? removed : "\(removed) · \(result.failedItems.count) skipped"
    }

    private var cleanupConfirmation: String {
        let summary = "Delete \(vm.selectedCleanPaths.count) selected items and reclaim up to \(vm.formattedSelectedCleanSize)."
        return vm.hasSelectedAdminCleanItems ? summary + " macOS will ask for an administrator password." : summary
    }
}
