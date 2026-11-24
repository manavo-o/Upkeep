import AppKit
import SwiftUI

// MARK: - Settings preferences

/// Preference for displaying explanations under settings labels.
public enum UpkeepSettingsPreferences {
    public static let showDescriptionsKey = "UpkeepShowSettingDescriptions"
}

// MARK: - Scroll Edge Effect (macOS 26/27 Liquid Glass Soft Edge)

public struct UpkeepSoftTopScrollEdgeModifier: ViewModifier {
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

public extension View {
    func upkeepSoftTopScrollEdge() -> some View {
        modifier(UpkeepSoftTopScrollEdgeModifier())
    }
}

// MARK: - Unified macOS 27 Button Styles (.glass / .glassProminent with clean fallbacks)

/// Secondary action button style: native `.glass` capsule on macOS 26/27, `.bordered` on earlier macOS.
public struct UpkeepSecondaryButtonStyle: PrimitiveButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(configuration)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            Button(configuration)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

/// Primary action button style: native `.glassProminent` capsule on macOS 26/27, `.borderedProminent` on earlier macOS.
public struct UpkeepPrimaryButtonStyle: PrimitiveButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(configuration)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
        } else {
            Button(configuration)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
    }
}

public extension PrimitiveButtonStyle where Self == UpkeepSecondaryButtonStyle {
    static var upkeepSecondary: UpkeepSecondaryButtonStyle {
        UpkeepSecondaryButtonStyle()
    }
}

public extension PrimitiveButtonStyle where Self == UpkeepPrimaryButtonStyle {
    static var upkeepPrimary: UpkeepPrimaryButtonStyle {
        UpkeepPrimaryButtonStyle()
    }
}

// MARK: - Native Centered Grouped Settings Form Container (Canapé / DockDoor / Handy Rhythm)

public struct UpkeepSettingsFormView<Header: View, Content: View>: View {
    @Environment(\.upkeepSettingsReveal) private var reveal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let maxColumnWidth: CGFloat
    let hasHeader: Bool
    let header: Header
    let content: Content

    public init(
        maxColumnWidth: CGFloat = upkeepSettingsColumnWidth,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.maxColumnWidth = maxColumnWidth
        self.hasHeader = true
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        GeometryReader { geo in
            let columnWidth = min(maxColumnWidth, geo.size.width)
            VStack(spacing: 0) {
                if hasHeader {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                }

                ScrollViewReader { proxy in
                    Form {
                        content
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                    .contentMargins(.top, hasHeader ? 0 : 2, for: .scrollContent)
                    .contentMargins(.bottom, 24, for: .scrollContent)
                    .upkeepSoftTopScrollEdge()
                    .task(id: reveal) {
                        guard let reveal else { return }
                        // Allow the new pane's form to mount its row IDs.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                            proxy.scrollTo(reveal.target, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: columnWidth)
            .frame(width: geo.size.width, alignment: .top)
        }
    }
}

public extension UpkeepSettingsFormView where Header == EmptyView {
    init(maxColumnWidth: CGFloat = upkeepSettingsColumnWidth, @ViewBuilder content: () -> Content) {
        self.maxColumnWidth = maxColumnWidth
        self.hasHeader = false
        self.header = EmptyView()
        self.content = content()
    }
}

struct UpkeepTaskLabel: View {
    let title: String
    let systemImage: String
    let runningTitle: String
    let isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(isRunning ? runningTitle : title)
        }
        .lineLimit(1)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isRunning)
    }
}

// MARK: - Grouped Section with Left-Aligned Footnote Footer (DockDoor / System Settings Pattern)

public struct UpkeepSettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    public init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        Section {
            content
        } header: {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
        } footer: {
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

// MARK: - Handy-Style Inline Info Popover Button

public struct UpkeepInfoButton: View {
    let text: String
    @State private var isPresented = false

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More information")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Row Icon Badge (Reserved for Hero Cards, Banners & Search Results)

public struct UpkeepSettingsIcon: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 24

    public init(systemName: String, color: Color, size: CGFloat = 24) {
        self.systemName = systemName
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29)
                .fill(color.opacity(0.12))

            Image(systemName: systemName)
                .font(.system(size: size * 0.49, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Clean Setting Label (Minimalist DockDoor / Handy Typography — No Per-Row Icon Clutter)

public struct UpkeepSettingLabel: View {
    let title: String
    let subtitle: String?
    let info: String?

    @AppStorage(UpkeepSettingsPreferences.showDescriptionsKey) private var showDescriptions = true

    public init(_ title: String, subtitle: String? = nil, info: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let info {
                    UpkeepInfoButton(info)
                }
            }

            if showDescriptions, let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Inline Setting Description & Info Popover (Backward-Compatible Modifier)

public struct UpkeepSettingsAnnotationModifier: ViewModifier {
    let summary: String
    let more: String?

    @AppStorage(UpkeepSettingsPreferences.showDescriptionsKey) private var showDescriptions = true

    public func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content

            if showDescriptions || more != nil {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if showDescriptions {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let more {
                        UpkeepInfoButton(more)
                    }
                }
            }
        }
    }
}

public extension View {
    func upkeepAnnotation(_ summary: String, more: String? = nil) -> some View {
        modifier(UpkeepSettingsAnnotationModifier(summary: summary, more: more))
    }
}

// MARK: - Callout Banner (Warning / Info / Active Status — DockDoor / Canapé Pattern)

public struct UpkeepSettingsCallout: View {
    public enum Tone {
        case warning
        case info
        case success
        case active(Color)

        var color: Color {
            switch self {
            case .warning: return .orange
            case .info: return .secondary
            case .success: return .green
            case .active(let color): return color
            }
        }

        var defaultIcon: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .active: return "bolt.fill"
            }
        }
    }

    let tone: Tone
    let icon: String?
    let title: String?
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(
        tone: Tone = .warning,
        icon: String? = nil,
        title: String? = nil,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            UpkeepSettingsIcon(systemName: icon ?? tone.defaultIcon, color: tone.color, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text(message)
                    .font(title == nil ? .callout : .footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.upkeepSecondary)
                    .controlSize(.regular)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Minimalist Environment / Permission Status Row

public struct UpkeepStatusRow: View {
    let title: String
    let description: String
    let icon: String
    let isGranted: Bool
    let grantedLabel: String
    let missingLabel: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(
        title: String,
        description: String,
        icon: String,
        isGranted: Bool,
        grantedLabel: String = "Installed",
        missingLabel: String = "Not Found",
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.description = description
        self.icon = icon
        self.isGranted = isGranted
        self.grantedLabel = grantedLabel
        self.missingLabel = missingLabel
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 12) {
            UpkeepSettingsIcon(systemName: icon, color: isGranted ? .green : .orange, size: 28)
            UpkeepSettingLabel(title, subtitle: description)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Label(isGranted ? grantedLabel : missingLabel,
                      systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
                    .fixedSize()

                if !isGranted, let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.upkeepSecondary)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Subtle Reset-to-Default Button (DockDoor / Handy Pattern)

public struct UpkeepResetButton: View {
    let isModified: Bool
    let action: () -> Void

    public init(isModified: Bool, action: @escaping () -> Void) {
        self.isModified = isModified
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Reset to default")
        .accessibilityLabel("Reset to default")
        .opacity(isModified ? 1 : 0)
        .disabled(!isModified)
    }
}

// MARK: - Authentic macOS Keycap Shortcut Pills

public struct UpkeepKeycapGroup: View {
    let keys: [String]

    public init(_ keys: [String]) {
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
            }
        }
    }
}

/// A status and its controls share a single surface at the top of a pane.
struct UpkeepSettingsFeature<Icon: View, Detail: View, Actions: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                summary
                Spacer(minLength: 0)
                actions().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                summary
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(tint.opacity(0.15)), in: .rect(cornerRadius: 16))
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(tint.opacity(0.08))
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            icon()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                detail()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
    }
}

struct UpkeepSettingsShortcut: View {
    let title: String
    let keys: [String]

    var body: some View {
        LabeledContent(title) {
            UpkeepKeycapGroup(keys)
        }
    }
}

struct UpkeepPaneSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .accessibilityLabel(placeholder)
                .onExitCommand { text = "" }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                Capsule().fill(.quaternary.opacity(0.45))
            }
        }
    }
}

public let upkeepSettingsColumnWidth: CGFloat = 800

struct UpkeepReviewFileRow: View {
    let title: String
    let detail: String
    let note: String?
    let size: String
    let path: String
    var isAppRunning = false
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isSelected) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isAppRunning {
                            runningBadge
                        }
                    }
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(isAppRunning ? "\(title), app is currently running" : title)
            .accessibilityHint(note ?? detail)

            Spacer(minLength: 0)
            Text(size)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 3)
    }

    private var runningBadge: some View {
        let blue = Color(nsColor: .systemBlue)

        return HStack(spacing: 4) {
            Circle()
                .frame(width: 5, height: 5)
            Text("Running")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(blue)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(blue.opacity(0.13), in: Capsule())
        .fixedSize()
        .accessibilityHidden(true)
    }
}

enum UpkeepSettingsPalette {
    static let accent = Color(nsColor: NSColor(srgbRed: 0.05, green: 0.43, blue: 0.88, alpha: 1))

    static let selectedSidebarRow = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.30, green: 0.60, blue: 1.00, alpha: 0.28)
        }
        return NSColor(srgbRed: 0.09, green: 0.46, blue: 0.94, alpha: 0.16)
    })

    static let detail = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.108, green: 0.108, blue: 0.112, alpha: 1)
        }
        return NSColor(srgbRed: 0.985, green: 0.983, blue: 0.977, alpha: 1)
    })
}

struct UpkeepSettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
