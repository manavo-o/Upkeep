import AppKit
import SwiftUI

// MARK: - Mole Cleaner Tab

/// macOS 27 Control Center-styled Cleaner Tab.
/// Features a live dry-run scan preview, categorized cache candidates,
/// progress states, and an Apple HIG-compliant destructive purge confirmation.
public struct MenuBarCleanerTab: View {
    @Bindable var vm: TrayViewModel
    @State private var hoveredLineIndex: Int?

    public init(vm: TrayViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            contentBody

            Spacer(minLength: 0)

            footerActionBar
        }
        .padding(MenuBarTheme.Metrics.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .trayTile(
            isActive: false,
            accent: MenuBarTheme.Colors.moleClean,
            isHovered: false,
            cornerRadius: MenuBarTheme.Metrics.tileCornerRadius
        )
        .onExitCommand {
            if vm.confirmClean {
                withAnimation(.snappy) {
                    vm.confirmClean = false
                }
            }
        }
        .onAppear {
            if vm.cleanPreview == nil && !vm.isScanningClean && !vm.isCleaning {
                vm.runMoleDryRun()
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(headerIconBackground)
                    .frame(
                        width: MenuBarTheme.Metrics.iconContainerSize,
                        height: MenuBarTheme.Metrics.iconContainerSize
                    )

                Image(systemName: headerIconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(headerIconForeground)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(MenuBarTheme.Typography.wideTileTitle)
                    .foregroundStyle(.primary)

                Text(headerSubtitle)
                    .font(MenuBarTheme.Typography.wideTileSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                vm.runMoleDryRun()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Rescan cleanable caches")
            .disabled(vm.isScanningClean || vm.isCleaning)
        }
    }

    private var headerTitle: String {
        if vm.cleanPreview?.isDryRun == false {
            return "Cleanup Complete"
        }
        return "Cache Dry-Run Preview"
    }

    private var headerSubtitle: String {
        if let summary = vm.cleanPreview {
            if summary.isDryRun {
                return "\(summary.totalReclaimed) reclaimable · \(summary.itemCount) candidate items"
            } else {
                return "\(summary.totalReclaimed) reclaimed safely"
            }
        }
        return "Scans caches safely without deleting"
    }

    private var headerIconName: String {
        if vm.cleanPreview?.isDryRun == false {
            return "checkmark.circle.fill"
        }
        return "sparkles"
    }

    private var headerIconBackground: Color {
        if vm.cleanPreview?.isDryRun == false {
            return MenuBarTheme.Colors.success.opacity(0.18)
        }
        return MenuBarTheme.Colors.moleClean.opacity(0.18)
    }

    private var headerIconForeground: Color {
        if vm.cleanPreview?.isDryRun == false {
            return MenuBarTheme.Colors.success
        }
        return MenuBarTheme.Colors.moleClean
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        if vm.isScanningClean || vm.isCleaning {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)

                Text(vm.isCleaning ? "Purging cleanable caches…" : "Scanning system caches safely…")
                    .font(MenuBarTheme.Typography.rowTitle)
                    .foregroundStyle(.primary)

                Text(vm.isCleaning ? "Freeing disk space safely" : "Analyzing user caches, logs & temp files")
                    .font(MenuBarTheme.Typography.rowDetail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = vm.cleanError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(MenuBarTheme.Colors.destructive)

                Text("Scan Failed")
                    .font(MenuBarTheme.Typography.wideTileTitle)

                Text(err)
                    .font(MenuBarTheme.Typography.rowDetail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                Button("Retry Scan") {
                    vm.runMoleDryRun()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary = vm.cleanPreview {
            if summary.lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 26))
                        .foregroundStyle(MenuBarTheme.Colors.moleClean)

                    Text("System is Clean")
                        .font(MenuBarTheme.Typography.wideTileTitle)

                    Text("No reclaimable caches found.")
                        .font(MenuBarTheme.Typography.wideTileSubtitle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(summary.lines.prefix(120).enumerated()), id: \.offset) { idx, line in
                            cleanLineRow(line, index: idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollIndicators(.automatic)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26))
                    .foregroundStyle(MenuBarTheme.Colors.moleClean)

                Text("Ready to Scan")
                    .font(MenuBarTheme.Typography.wideTileTitle)

                Text("Scan safely without deleting any files.")
                    .font(MenuBarTheme.Typography.wideTileSubtitle)
                    .foregroundStyle(.secondary)

                Button("Start Dry-Run") {
                    vm.runMoleDryRun()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Row Rendering

    private func cleanLineRow(_ line: String, index: Int) -> some View {
        let isHeader = line.hasPrefix("➤")
        let isCandidate = line.hasPrefix("○") || line.hasPrefix("◎")
        let isCleaned = line.hasPrefix("✓")
        let stripped = line.dropFirst().trimmingCharacters(in: .whitespaces)
        let a11yPrefix = isHeader ? "Category" : (isCandidate ? "Candidate" : (isCleaned ? "Cleaned" : "Info"))

        return HStack(alignment: .top, spacing: 7) {
            Group {
                if isHeader {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(MenuBarTheme.Colors.moleClean)
                } else if isCandidate {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(MenuBarTheme.Colors.warning)
                } else if isCleaned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MenuBarTheme.Colors.success)
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: isHeader ? 11 : 10))
            .padding(.top, isHeader ? 3 : 2)

            Text(stripped)
                .font(isHeader ? MenuBarTheme.Typography.categoryHeader : MenuBarTheme.Typography.rowDetail)
                .foregroundStyle(isHeader ? .primary : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, isHeader ? 4 : 2)
        .padding(.leading, isHeader ? 0 : 12)
        .background(
            hoveredLineIndex == index && !isHeader
                ? Color.primary.opacity(0.04)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered in
            hoveredLineIndex = isHovered ? index : nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(a11yPrefix): \(stripped)")
        .padding(.top, isHeader ? 4 : 0)
    }

    // MARK: - Footer Confirmation & Actions

    @ViewBuilder
    private var footerActionBar: some View {
        if let summary = vm.cleanPreview, summary.isDryRun {
            if vm.confirmClean {
                MenuBarDestructiveConfirmBar(
                    title: "Delete \(summary.totalReclaimed)?",
                    confirmLabel: "Clean",
                    confirmIcon: "trash",
                    onCancel: {
                        withAnimation(.snappy) {
                            vm.confirmClean = false
                        }
                    },
                    onConfirm: {
                        vm.executeMoleClean()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                HStack {
                    Text("Dry-run preview mode")
                        .font(MenuBarTheme.Typography.rowDetail)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(role: .destructive) {
                        withAnimation(.snappy) {
                            vm.confirmClean = true
                        }
                    } label: {
                        Label("Clean Now", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
        } else if let summary = vm.cleanPreview, !summary.isDryRun {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MenuBarTheme.Colors.success)
                    .font(.system(size: 12))

                Text("Successfully freed \(summary.totalReclaimed)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Rescan") {
                    vm.runMoleDryRun()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Mole Uninstaller Tab

/// macOS 27 Control Center-styled Uninstaller Tab.
/// Features a native macOS search field, personal data removal toggle,
/// crisp app icons via AppKit, and stable non-collapsing fixed-height ScrollView.
public struct MenuBarUninstallerTab: View {
    @Bindable var vm: TrayViewModel

    public init(vm: TrayViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MenuBarSearchField(
                text: $vm.appQuery,
                placeholder: "Filter installed apps…",
                onEscape: {
                    if vm.pendingUninstallApp != nil {
                        withAnimation(.snappy) {
                            vm.pendingUninstallApp = nil
                        }
                    }
                }
            )

            optionsRow

            if let pending = vm.pendingUninstallApp {
                MenuBarDestructiveConfirmBar(
                    title: "Move \(pending.name) to Trash?",
                    confirmLabel: "Trash",
                    confirmIcon: "trash.fill",
                    onCancel: {
                        withAnimation(.snappy) {
                            vm.pendingUninstallApp = nil
                        }
                    },
                    onConfirm: {
                        vm.confirmUninstall(pending)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            appListContainer

            Spacer(minLength: 0)

            statusBar
        }
        .padding(MenuBarTheme.Metrics.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .trayTile(
            isActive: false,
            accent: MenuBarTheme.Colors.uninstaller,
            isHovered: false,
            cornerRadius: MenuBarTheme.Metrics.tileCornerRadius
        )
        .onExitCommand {
            if vm.pendingUninstallApp != nil {
                withAnimation(.snappy) {
                    vm.pendingUninstallApp = nil
                }
            } else if !vm.appQuery.isEmpty {
                vm.appQuery = ""
            }
        }
        .onAppear {
            if vm.installedApps.isEmpty && !vm.isLoadingApps {
                vm.loadApps()
            }
        }
    }

    // MARK: - Options & Count

    private var optionsRow: some View {
        HStack {
            Toggle(isOn: $vm.includePersonalData) {
                HStack(spacing: 4) {
                    Text("Include personal data")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Also removes application support files, preferences, and caches (--with-data)")
                }
            }
            .toggleStyle(.checkbox)

            Spacer()

            if !vm.installedApps.isEmpty {
                Text("\(vm.filteredApps.count) apps")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - App List Container (Fixed Height)

    @ViewBuilder
    private var appListContainer: some View {
        if vm.isLoadingApps {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text("Loading installed applications…")
                    .font(MenuBarTheme.Typography.rowDetail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = vm.uninstallError {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MenuBarTheme.Colors.destructive)
                    .font(.system(size: 18))

                Text(err)
                    .font(MenuBarTheme.Typography.rowDetail)
                    .foregroundStyle(MenuBarTheme.Colors.destructive)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)

                Button("Retry") {
                    vm.loadApps(force: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.filteredApps.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)

                Text(vm.installedApps.isEmpty ? "No applications found" : "No results for “\(vm.appQuery)”")
                    .font(MenuBarTheme.Typography.rowTitle)
                    .foregroundStyle(.secondary)

                if !vm.appQuery.isEmpty {
                    Button("Clear Filter") {
                        vm.appQuery = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    Button("Reload Apps") {
                        vm.loadApps(force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(vm.filteredApps.prefix(150)) { app in
                        UninstallerAppRow(
                            app: app,
                            isPending: vm.pendingUninstallApp?.id == app.id,
                            onRemove: {
                                withAnimation(.snappy) {
                                    vm.pendingUninstallApp = app
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.automatic)
        }
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBar: some View {
        if let status = vm.uninstallStatus {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MenuBarTheme.Colors.success)
                    .font(.system(size: 10))

                Text(status)
                    .font(MenuBarTheme.Typography.footerText)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Supporting Row Views

/// Individual application row for the Uninstaller tab.
public struct UninstallerAppRow: View {
    let app: MoleInstalledApp
    let isPending: Bool
    let onRemove: () -> Void

    @State private var isHovered: Bool = false

    public var body: some View {
        HStack(spacing: 11) {
            AppIconView(path: app.path, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(app.formattedSize)
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)

                    if let source = app.source, !source.isEmpty {
                        Text("· \(source)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Button("Remove") {
                onRemove()
            }
            .buttonStyle(.upkeepSecondary)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isPending
                ? Color.red.opacity(0.12)
                : (isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.025)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isPending ? Color.red.opacity(0.35) : Color.primary.opacity(0.05),
                    lineWidth: 0.75
                )
        )
        .onHover { isHovered = $0 }
    }
}

/// Native macOS App Icon renderer with NSCache-backed asynchronous NSWorkspace icon lookup.
public struct AppIconView: View {
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    let path: String
    var size: CGFloat = 24

    @State private var loadedIcon: NSImage?

    public init(path: String, size: CGFloat = 24) {
        self.path = path
        self.size = size
        if !path.isEmpty {
            _loadedIcon = State(initialValue: Self.iconCache.object(forKey: path as NSString))
        }
    }

    public var body: some View {
        Group {
            if let nsImage = loadedIcon {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .task(id: path) {
            guard loadedIcon == nil, !path.isEmpty else { return }
            let key = path as NSString
            if let cached = Self.iconCache.object(forKey: key) {
                loadedIcon = cached
                return
            }
            let targetPath = path
            let icon: NSImage? = await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: targetPath) else { return nil }
                let rawIcon = NSWorkspace.shared.icon(forFile: targetPath)
                // Downscale to 84x84pt (2x retina for 42pt max) to avoid caching 1024x1024 bitmaps
                let thumbSize = NSSize(width: 84, height: 84)
                let thumb = NSImage(size: thumbSize, flipped: false) { rect in
                    rawIcon.draw(in: rect)
                    return true
                }
                return thumb
            }.value
            if let icon {
                Self.iconCache.setObject(icon, forKey: key)
                loadedIcon = icon
            }
        }
    }
}
