import AppKit
import SwiftUI

// MARK: - macOS 27 Native Settings Components (Inspired by Apple System Settings, DockDoor & Handy)

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

/// Secondary action button style: native `.glass` on macOS 26/27, `.bordered` on earlier macOS.
public struct UpkeepSecondaryButtonStyle: PrimitiveButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(configuration)
                .buttonStyle(.glass)
        } else {
            Button(configuration)
                .buttonStyle(.bordered)
        }
    }
}

/// Primary action button style: native `.glassProminent` on macOS 26/27, `.borderedProminent` on earlier macOS.
public struct UpkeepPrimaryButtonStyle: PrimitiveButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(configuration)
                .buttonStyle(.glassProminent)
        } else {
            Button(configuration)
                .buttonStyle(.borderedProminent)
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

// MARK: - Native Grouped Settings Form Container (with Search Scroll-To Support)

public struct UpkeepSettingsFormView<Content: View>: View {
    @Environment(\.upkeepScrollTarget) private var scrollTarget
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            Form {
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
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

// MARK: - Grouped Section with Optional Footnote Footer

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
        } footer: {
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Row Icon Badge (DockDoor / System Settings Pattern)

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

// MARK: - Inline Setting Description & Info Popover (DockDoor + Handy Pattern)

public struct UpkeepSettingsAnnotationModifier: ViewModifier {
    let summary: String
    let more: String?

    @AppStorage(UpkeepSettingsPreferences.showDescriptionsKey) private var showDescriptions = true
    @State private var isShowingMore = false

    public func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
                        Button {
                            isShowingMore.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $isShowingMore, arrowEdge: .bottom) {
                            Text(more)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                                .padding(12)
                                .frame(width: 280, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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

// MARK: - Callout Banner (Warning / Info / Active Status — DockDoor Pattern)

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
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Permission / Environment Row (DockDoor SupportSettingsView Pattern)

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
            UpkeepSettingsIcon(systemName: icon, color: isGranted ? .green : .orange, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Label(
                    isGranted ? grantedLabel : missingLabel,
                    systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isGranted ? Color.green : Color.orange)

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

// MARK: - Subtle Reset-to-Default Button (DockDoor Pattern)

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
