import AppKit
import SwiftUI

// MARK: - macOS 27 Native Settings Components (Inspired by Canapé, DockDoor, Handy & Apple System Settings)

/// Preference key for toggling inline setting descriptions across Upkeep (DockDoor pattern).
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
    @Environment(\.upkeepScrollTarget) private var scrollTarget
    let maxColumnWidth: CGFloat
    let hasHeader: Bool
    let header: Header
    let content: Content

    public init(
        maxColumnWidth: CGFloat = 600,
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
            let sideMargin = max(18, (geo.size.width - maxColumnWidth) / 2)
            VStack(spacing: 0) {
                if hasHeader {
                    header
                        .padding(.horizontal, sideMargin + 4)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                }

                ScrollViewReader { proxy in
                    Form {
                        content
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.horizontal, sideMargin, for: .scrollContent)
                    .contentMargins(.top, hasHeader ? 2 : 12, for: .scrollContent)
                    .contentMargins(.bottom, 24, for: .scrollContent)
                    .upkeepSoftTopScrollEdge()
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        guard let target = scrollTarget else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

public extension UpkeepSettingsFormView where Header == EmptyView {
    init(maxColumnWidth: CGFloat = 600, @ViewBuilder content: () -> Content) {
        self.maxColumnWidth = maxColumnWidth
        self.hasHeader = false
        self.header = EmptyView()
        self.content = content()
    }
}

// MARK: - Canapé-Style Minimalist Pane Header (Floats Directly on Canvas Aligned with Traffic Lights)

public struct UpkeepPaneHeader: View {
    let section: TraySection
    let subtitle: String?
    let trailing: AnyView?

    public init(section: TraySection, subtitle: String? = nil) {
        self.section = section
        self.subtitle = subtitle
        self.trailing = nil
    }

    public init<Trailing: View>(section: TraySection, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.section = section
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        HStack(spacing: 10) {
            UpkeepSectionIcon(section: section, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.rawValue)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.primary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let trailing {
                trailing
            }
        }
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
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
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
        .buttonStyle(.plain)
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
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(color.opacity(0.15))

            Image(systemName: systemName)
                .font(.system(size: size * 0.50, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
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
                    .font(.system(size: 13, weight: .regular))
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
            UpkeepSettingLabel(title, subtitle: description)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isGranted ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(isGranted ? grantedLabel : missingLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isGranted ? .secondary : Color.orange)
                }

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
                    .font(.system(size: 11, weight: .medium, design: .rounded))
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
