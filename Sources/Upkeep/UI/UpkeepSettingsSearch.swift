import SwiftUI

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
    public static let allItems: [UpkeepSearchItem] =
        items(for: .general, in: "Interface", [
            ("updates.preferences", "Show setting descriptions", "text.alignleft", ["explanations", "appearance"]),
        ]) +
        items(for: .general, in: "Keyboard Shortcuts", [
            ("general.shortcuts", "Open and Find Settings", "command", ["keybind", "cmd", "⌘f", "⌘,"]),
        ]) +
        items(for: .general, in: "Application", [
            ("general.reset", "Restore Default Preferences", "arrow.counterclockwise", ["reset", "restore defaults"]),
            ("general.lifecycle", "Restart or Quit Upkeep", "power", ["relaunch", "exit", "close"]),
        ]) +
        items(for: .controls, in: "", [
            ("power.keepAwake", "Keep Mac Awake", "cup.and.saucer.fill", ["prevent sleep", "idle", "power", "stop", "extend"]),
            ("power.assertionMode", "Keep Awake", "display", ["screen", "mac only", "display sleep", "power & input"]),
            ("power.closedLid", "Keep Awake With Lid Closed", "laptopcomputer", ["clamshell", "sleep", "caffeinate"]),
            ("power.quickDuration", "Session Duration", "timer", ["start a session", "slider", "30m", "1h", "2h", "indefinite"]),
        ]) +
        items(for: .cleanKeys, in: "", [
            ("power.cleanKeys", "Lock Keyboard", "keyboard", ["wipe", "clean", "accessibility", "input", "power & input"]),
            ("power.lockDuration", "Lock Duration", "clock", ["30 seconds", "60 seconds", "2 minutes", "timer"]),
            ("power.dimScreen", "Dim Screen", "moon.fill", ["display", "brightness", "backdrop", "dark", "locked"]),
            ("power.lockPointer", "Lock Pointer & Trackpad", "cursorarrow.slash", ["mouse", "cursor", "clicks"]),
            ("power.unlock", "Unlock Early", "lock.open", ["escape", "esc", "command", "shortcut"]),
        ]) +
        items(for: .homebrew, in: "Packages", [
            ("brew.hud", "Find Homebrew Packages", "magnifyingglass", ["brew", "search", "floating hud", "formulae", "casks", "install"]),
            ("brew.outdated", "Package Upgrades", "arrow.up.circle", ["outdated", "update", "brew"]),
        ]) +
        items(for: .homebrew, in: "Activity", [
            ("brew.log", "Homebrew Activity", "doc.text", ["log", "output", "stdout", "stderr", "install"]),
            ("brew.diagnostics", "Homebrew Diagnostics", "stethoscope", ["doctor", "troubleshoot"]),
        ]) +
        items(for: .homebrew, in: "Installation", [
            ("brew.installation", "Homebrew CLI", "terminal", ["install", "not found", "binary", "environment"]),
            ("updates.cli", "Refresh Package Catalog", "arrow.clockwise", ["brew update", "definitions", "cli"]),
            ("brew.shortcuts", "Floating Search Shortcuts", "command", ["keybinds", "cmd+k", "cmd+1", "esc", "hud"]),
        ]) +
        items(for: .cleaner, in: "", [
            ("cleaner.dryRun", "Scan for Reclaimable Files", "sparkles", ["cache", "disk cleanup", "space", "storage", "dry run", "logs", "trash"]),
        ]) +
        items(for: .uninstaller, in: "", [
            ("uninstaller.apps", "Uninstall Applications", "trash", ["remove", "apps", "trash", "leftovers", "cask"]),
        ]) +
        items(for: .updates, in: "Upkeep", [
            ("updates.releases", "Check for Updates", "arrow.down.circle", ["version", "release", "install", "github"]),
            ("updates.autoCheck", "Automatically check for updates", "clock.arrow.circlepath", ["auto check", "release"]),
            ("updates.repository", "GitHub Repository", "link", ["source", "owner", "updates"]),
            ("updates.permissions", "Accessibility Permission", "accessibility", ["grant", "system permissions", "clean keys"]),
        ])

    private static func items(
        for tab: TraySection,
        in section: String,
        _ entries: [(id: String, title: String, icon: String, keywords: [String])]
    ) -> [UpkeepSearchItem] {
        entries.map {
            UpkeepSearchItem(id: $0.id, title: $0.title, section: section, tab: tab, icon: $0.icon, keywords: $0.keywords)
        }
    }
}

struct UpkeepSettingsReveal: Equatable {
    let tab: TraySection
    let target: String
    let request = UUID()
}

@MainActor
@Observable
public final class UpkeepSearchEngine {
    public var query = "" {
        didSet {
            if query != oldValue {
                recomputeResults()
            }
        }
    }

    public private(set) var results: [UpkeepSearchItem] = []
    public private(set) var groupedResults: [(tab: TraySection, items: [UpkeepSearchItem])] = []
    private(set) var highlightedItem: UpkeepSearchItem?
    private(set) var reveal: UpkeepSettingsReveal?

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init() {}

    func reveal(_ target: String, in tab: TraySection) {
        reveal = UpkeepSettingsReveal(tab: tab, target: target)
    }

    func reveal(for tab: TraySection) -> UpkeepSettingsReveal? {
        reveal?.tab == tab ? reveal : nil
    }

    func moveHighlight(by offset: Int) {
        let orderedItems = groupedResults.flatMap(\.items)
        guard !orderedItems.isEmpty else { return }
        let currentIndex = highlightedItem.flatMap { orderedItems.firstIndex(of: $0) }
        let newIndex = currentIndex.map { min(max($0 + offset, 0), orderedItems.count - 1) }
            ?? (offset < 0 ? orderedItems.count - 1 : 0)
        highlightedItem = orderedItems[newIndex]
    }

    func clear() {
        query = ""
        reveal = nil
    }

    private func recomputeResults() {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = phrase.split(whereSeparator: \.isWhitespace)
        highlightedItem = nil
        guard !words.isEmpty else {
            results = []
            groupedResults = []
            return
        }

        let matches = UpkeepSearchCatalog.allItems.enumerated().compactMap { index, item -> (Int, Int, UpkeepSearchItem)? in
            let fields = [item.title, item.section, item.tab.settingsTitle] + item.keywords
            guard words.allSatisfy({ word in fields.contains { $0.localizedStandardContains(word) } }) else {
                return nil
            }
            let score: Int
            if item.title.compare(phrase, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                score = 3
            } else if item.title.localizedStandardContains(phrase) {
                score = 2
            } else if words.contains(where: { item.title.localizedStandardContains($0) }) {
                score = 1
            } else {
                score = 0
            }
            return (score, index, item)
        }
        results = matches.sorted {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0
        }.map(\.2)

        var seenTabs = Set<TraySection>()
        groupedResults = results.compactMap { result in
            guard seenTabs.insert(result.tab).inserted else { return nil }
            return (result.tab, results.filter { $0.tab == result.tab })
        }
    }
}

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
            ScrollViewReader { proxy in
                UpkeepSettingsFormView {
                    ForEach(engine.groupedResults, id: \.tab) { group in
                        UpkeepSettingsSection(group.tab.settingsTitle) {
                            ForEach(group.items) { item in
                                UpkeepSearchResultRow(item: item, isHighlighted: item == engine.highlightedItem) {
                                    onSelect(item)
                                }
                                .id(item.id)
                            }
                        }
                    }
                }
                .onChange(of: engine.highlightedItem) { _, item in
                    if let item { proxy.scrollTo(item.id) }
                }
            }
        }
    }
}

private struct UpkeepSearchResultRow: View {
    let item: UpkeepSearchItem
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                UpkeepSettingsIcon(systemName: item.icon, color: item.tab.accentColor, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.body)
                    if !item.section.isEmpty {
                        Text(item.section)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .listRowBackground(isHighlighted ? UpkeepSettingsPalette.accent.opacity(0.20) : nil)
    }
}

private struct UpkeepSettingsRevealKey: EnvironmentKey {
    static let defaultValue: UpkeepSettingsReveal? = nil
}

extension EnvironmentValues {
    var upkeepSettingsReveal: UpkeepSettingsReveal? {
        get { self[UpkeepSettingsRevealKey.self] }
        set { self[UpkeepSettingsRevealKey.self] = newValue }
    }
}

private struct UpkeepSearchTargetModifier: ViewModifier {
    let id: String
    @Environment(\.upkeepSettingsReveal) private var reveal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(UpkeepSettingsPalette.accent.opacity(0.20))
                        .padding(-4)
                }
            }
            .id(id)
            .task(id: reveal) {
                guard reveal?.target == id else {
                    isHighlighted = false
                    return
                }
                isHighlighted = true
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                    isHighlighted = false
                }
            }
    }
}

public extension View {
    func upkeepSearchTarget(_ id: String) -> some View {
        modifier(UpkeepSearchTargetModifier(id: id))
    }
}
