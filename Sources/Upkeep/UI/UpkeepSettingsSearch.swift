import SwiftUI

// MARK: - Settings Search Engine & Target Highlighting (DockDoor Pattern)

public struct UpkeepSearchItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let section: String
    public let tab: TraySection
    public let icon: String
    public let keywords: [String]

    public init(
        id: String,
        title: String,
        section: String,
        tab: TraySection,
        icon: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.section = section
        self.tab = tab
        self.icon = icon
        self.keywords = keywords
    }
}

public enum UpkeepSearchCatalog {
    public static let allItems: [UpkeepSearchItem] = [
        // Power & Input
        UpkeepSearchItem(
            id: "power.keepAwake",
            title: "Keep Mac Awake",
            section: "Caffeinate",
            tab: .controls,
            icon: "cup.and.saucer.fill",
            keywords: ["caffeinate", "sleep", "awake", "display", "prevent", "power"]
        ),
        UpkeepSearchItem(
            id: "power.assertionMode",
            title: "Assertion Mode",
            section: "Caffeinate",
            tab: .controls,
            icon: "display",
            keywords: ["display", "system only", "iokit", "caffeinate", "sleep"]
        ),
        UpkeepSearchItem(
            id: "power.quickDuration",
            title: "Quick Duration",
            section: "Caffeinate",
            tab: .controls,
            icon: "timer",
            keywords: ["30m", "1h", "2h", "indefinite", "timer", "duration"]
        ),
        UpkeepSearchItem(
            id: "power.cleanKeys",
            title: "Keyboard Cleaning Lock",
            section: "Clean Keys",
            tab: .controls,
            icon: "keyboard.badge.ellipsis",
            keywords: ["lock", "keyboard", "wipe", "clean", "keys", "input"]
        ),
        UpkeepSearchItem(
            id: "power.lockDuration",
            title: "Lock Duration",
            section: "Clean Keys",
            tab: .controls,
            icon: "clock",
            keywords: ["30 seconds", "60 seconds", "2 minutes", "clean keys"]
        ),
        UpkeepSearchItem(
            id: "power.dimScreen",
            title: "Dim Screen While Locked",
            section: "Clean Keys",
            tab: .controls,
            icon: "moon.fill",
            keywords: ["dim", "screen", "backdrop", "dark", "clean keys"]
        ),
        UpkeepSearchItem(
            id: "power.lockPointer",
            title: "Lock Pointer & Trackpad",
            section: "Clean Keys",
            tab: .controls,
            icon: "cursorarrow.slash",
            keywords: ["mouse", "pointer", "trackpad", "cursor", "clean keys"]
        ),

        // Homebrew
        UpkeepSearchItem(
            id: "brew.hud",
            title: "Homebrew Search HUD",
            section: "Packages",
            tab: .homebrew,
            icon: "magnifyingglass",
            keywords: ["brew", "search", "hud", "spotlight", "formulae", "casks"]
        ),
        UpkeepSearchItem(
            id: "brew.outdated",
            title: "Outdated Packages & Upgrades",
            section: "Packages",
            tab: .homebrew,
            icon: "arrow.up.circle",
            keywords: ["upgrade", "outdated", "updates", "brew", "packages"]
        ),
        UpkeepSearchItem(
            id: "brew.shortcuts",
            title: "HUD Keyboard Shortcuts",
            section: "HUD Shortcuts",
            tab: .homebrew,
            icon: "command",
            keywords: ["shortcuts", "keybinds", "cmd+k", "cmd+1", "esc"]
        ),

        // Cleaner
        UpkeepSearchItem(
            id: "cleaner.dryRun",
            title: "Cache Dry-Run Preview",
            section: "Cleaner",
            tab: .cleaner,
            icon: "sparkles",
            keywords: ["mole", "clean", "cache", "disk", "space", "storage", "dry-run"]
        ),

        // Uninstaller
        UpkeepSearchItem(
            id: "uninstaller.apps",
            title: "Uninstall Applications",
            section: "Uninstaller",
            tab: .uninstaller,
            icon: "trash",
            keywords: ["uninstall", "remove", "apps", "trash", "personal data", "mole"]
        ),

        // Updates & System
        UpkeepSearchItem(
            id: "updates.releases",
            title: "Upkeep Releases & Auto-Check",
            section: "Upkeep Releases",
            tab: .updates,
            icon: "arrow.triangle.2.circlepath",
            keywords: ["version", "update", "github", "release", "auto"]
        ),
        UpkeepSearchItem(
            id: "updates.cli",
            title: "Update CLI Utilities (Mole & Homebrew)",
            section: "CLI Utilities",
            tab: .updates,
            icon: "terminal",
            keywords: ["mole", "brew", "cli", "update", "terminal"]
        ),
        UpkeepSearchItem(
            id: "updates.permissions",
            title: "Permissions & System Environment",
            section: "Permissions & Environment",
            tab: .updates,
            icon: "lock.shield",
            keywords: ["accessibility", "permission", "environment", "status", "cli"]
        ),
        UpkeepSearchItem(
            id: "updates.preferences",
            title: "Interface Preferences & Reset",
            section: "Preferences",
            tab: .updates,
            icon: "slider.horizontal.3",
            keywords: ["descriptions", "reset", "defaults", "restart", "quit"]
        ),
    ]
}

@MainActor
@Observable
public final class UpkeepSearchEngine {
    public var query: String = ""

    public var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var results: [UpkeepSearchItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return UpkeepSearchCatalog.allItems.filter { item in
            item.title.lowercased().contains(q)
                || item.section.lowercased().contains(q)
                || item.tab.rawValue.lowercased().contains(q)
                || item.keywords.contains(where: { $0.contains(q) })
        }
    }

    public var groupedResults: [(tab: TraySection, items: [UpkeepSearchItem])] {
        let matched = results
        return TraySection.allCases.compactMap { tab in
            let items = matched.filter { $0.tab == tab }
            return items.isEmpty ? nil : (tab, items)
        }
    }

    public init() {}
}

// MARK: - Search Results View

public struct UpkeepSearchResultsView: View {
    let engine: UpkeepSearchEngine
    let onSelect: (UpkeepSearchItem) -> Void

    public init(engine: UpkeepSearchEngine, onSelect: @escaping (UpkeepSearchItem) -> Void) {
        self.engine = engine
        self.onSelect = onSelect
    }

    public var body: some View {
        if engine.results.isEmpty {
            ContentUnavailableView.search(text: engine.query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            UpkeepSettingsFormView {
                ForEach(engine.groupedResults, id: \.tab) { group in
                    UpkeepSettingsSection(group.tab.rawValue) {
                        ForEach(group.items) { item in
                            UpkeepSearchResultRow(item: item) {
                                onSelect(item)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct UpkeepSearchResultRow: View {
    let item: UpkeepSearchItem
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                UpkeepSettingsIcon(systemName: item.icon, color: item.tab.accentColor, size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(item.tab.rawValue) › \(item.section)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .listRowBackground(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}

// MARK: - Scroll-To & Highlight Flash Environment

private struct UpkeepScrollTargetKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    var upkeepScrollTarget: String? {
        get { self[UpkeepScrollTargetKey.self] }
        set { self[UpkeepScrollTargetKey.self] = newValue }
    }
}

public struct UpkeepSearchTargetModifier: ViewModifier {
    let targetId: String
    @Environment(\.upkeepScrollTarget) private var scrollTarget
    @State private var isHighlighted = false

    public func body(content: Content) -> some View {
        content
            .id(targetId)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .padding(-6)
                        .transition(.opacity)
                }
            }
            .onChange(of: scrollTarget) { _, newTarget in
                flash(if: newTarget)
            }
            .onAppear {
                flash(if: scrollTarget)
            }
    }

    private func flash(if target: String?) {
        guard target == targetId else {
            if isHighlighted {
                withAnimation(.easeOut(duration: 0.25)) { isHighlighted = false }
            }
            return
        }
        withAnimation(.easeIn(duration: 0.18)) { isHighlighted = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            withAnimation(.easeOut(duration: 0.45)) { isHighlighted = false }
        }
    }
}

public extension View {
    func upkeepSearchTarget(_ id: String) -> some View {
        modifier(UpkeepSearchTargetModifier(targetId: id))
    }
}
