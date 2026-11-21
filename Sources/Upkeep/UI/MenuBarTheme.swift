import AppKit
import SwiftUI

/// Apple Human Interface Guidelines (HIG) theme definitions for macOS 27 Liquid Glass Menu Bar Tray.
/// Follows Apple's two-layer architecture:
/// - Control & Navigation Layer: Native Liquid Glass (`GlassEffectContainer`, `.glassEffect`, `.glass` buttons).
/// - Content Layer: Quiet, legible grouped surfaces with concentric continuous corners and title-style headers.
public enum MenuBarTheme {

    // MARK: - Standardized Layout Metrics

    public enum Metrics {
        /// Standard popover width for macOS 27 Control Center tray (380pt).
        public static let popoverWidth: CGFloat = 380

        /// Unified outer content insets for the popover (16pt).
        public static let popoverPadding: CGFloat = 16

        /// Inter-section vertical spacing between header, switcher, groups, and footer (12pt).
        public static let sectionSpacing: CGFloat = 12

        /// Inner spacing between sibling cards or rows (10pt).
        public static let itemSpacing: CGFloat = 10

        /// Standard inner padding for grouped sections and cards (12pt).
        public static let tilePadding: CGFloat = 12

        /// Compact inner padding for smaller rows or nested sections (10pt).
        public static let compactTilePadding: CGFloat = 10

        /// Micro padding for duration pills and toggle chips.
        public static let pillPaddingHorizontal: CGFloat = 8
        public static let pillPaddingVertical: CGFloat = 4

        /// Standard continuous corner radius for grouped content containers (14pt).
        public static let tileCornerRadius: CGFloat = 14

        /// Inner continuous corner radius for nested banners and rows (10pt).
        public static let innerCornerRadius: CGFloat = 10

        /// Outer container continuous corner radius for segmented controls (18pt capsule-like).
        public static let segmentTrackCornerRadius: CGFloat = 18

        /// Active pill continuous corner radius for segmented controls.
        public static let segmentPillCornerRadius: CGFloat = 14

        /// Circular icon container dimension for standard rows (30pt).
        public static let iconContainerSize: CGFloat = 30

        /// Circular icon container dimension for prominent rows (34pt).
        public static let largeIconContainerSize: CGFloat = 34

        /// Fixed scroll height for candidate lists (Mole Clean, Uninstaller) preventing layout jumps (220pt).
        public static let standardScrollHeight: CGFloat = 220
    }

    // MARK: - SF Pro Typography Tokens

    public enum Typography {
        /// Popover header title: SF Pro 14pt Semibold.
        public static let popoverTitle = Font.system(size: 14, weight: .semibold)

        /// Popover subtitle / version label: SF Pro 11pt Regular.
        public static let popoverSubtitle = Font.system(size: 11, weight: .regular)

        /// Title-style section header (macOS 26/27 HIG): SF Pro 11.5pt Semibold.
        public static let sectionHeader = Font.system(size: 11.5, weight: .semibold)

        /// Card / row title: SF Pro 13pt Semibold.
        public static let cardTitle = Font.system(size: 13, weight: .semibold)

        /// Card subtitle / metadata: SF Pro 11pt Regular.
        public static let cardSubtitle = Font.system(size: 11, weight: .regular)

        /// Wide tile header title: SF Pro 13pt Semibold.
        public static let wideTileTitle = Font.system(size: 13, weight: .semibold)

        /// Wide tile subtitle: SF Pro 11pt Regular.
        public static let wideTileSubtitle = Font.system(size: 11, weight: .regular)

        /// Segmented tab picker label: SF Pro 12pt (Semibold when active, Medium when inactive).
        public static func segmentLabel(isSelected: Bool) -> Font {
            .system(size: 12, weight: isSelected ? .semibold : .medium)
        }

        /// Duration and mode pill label: SF Pro 10.5pt (Semibold when active, Medium when inactive).
        public static func pillLabel(isSelected: Bool, isMonospaced: Bool = false) -> Font {
            if isMonospaced {
                return .system(size: 10.5, weight: isSelected ? .semibold : .medium, design: .rounded).monospacedDigit()
            }
            return .system(size: 10.5, weight: isSelected ? .semibold : .medium)
        }

        /// Live timer and countdown badge: SF Rounded 11pt Medium with monospaced digits.
        public static let timerBadge = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()

        /// Prominent countdown timer: SF Rounded 12pt Semibold with monospaced digits.
        public static let prominentTimer = Font.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()

        /// Search field text: SF Pro 12.5pt Regular.
        public static let searchField = Font.system(size: 12.5, weight: .regular)

        /// Candidate / list row primary title: SF Pro 12pt Medium.
        public static let rowTitle = Font.system(size: 12, weight: .medium)

        /// Candidate / list row secondary metadata (size, path): SF Pro 10.5pt Regular.
        public static let rowDetail = Font.system(size: 10.5, weight: .regular)

        /// Category header row: SF Pro 11.5pt Semibold.
        public static let categoryHeader = Font.system(size: 11.5, weight: .semibold)

        /// Destructive confirmation banner title: SF Pro 11.5pt Medium.
        public static let confirmationTitle = Font.system(size: 11.5, weight: .medium)

        /// Footer status chip and quit button text: SF Pro 10.5pt Medium.
        public static let footerText = Font.system(size: 10.5, weight: .medium)
    }

    // MARK: - Semantic Color Tokens & Contrast Resolvers

    public enum Colors {
        public static let caffeinate = Color.orange
        public static let cleanKeys = Color.blue
        public static let homebrew = Color.indigo
        public static let moleClean = Color.mint
        public static let uninstaller = Color.pink
        public static let destructive = Color.red
        public static let success = Color.green
        public static let warning = Color.orange

        public static func segmentForeground(
            isSelected: Bool,
            colorScheme: ColorScheme,
            isHovered: Bool = false
        ) -> Color {
            if isSelected {
                return colorScheme == .dark ? Color.white : Color.primary
            } else if isHovered {
                return colorScheme == .dark ? Color.white.opacity(0.95) : Color.primary
            } else {
                return colorScheme == .dark ? Color.white.opacity(0.68) : Color.secondary
            }
        }

        public static func segmentTrackBackground(colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? Color.black.opacity(0.22) : Color.black.opacity(0.055)
        }

        public static func segmentTrackBorder(colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        }

        public static func pillBackground(
            isSelected: Bool,
            accent: Color,
            colorScheme: ColorScheme,
            isHovered: Bool = false
        ) -> Color {
            if isSelected {
                return accent.opacity(colorScheme == .dark ? 0.24 : 0.18)
            } else if isHovered {
                return colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08)
            } else {
                return colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)
            }
        }

        public static func pillForeground(
            isSelected: Bool,
            accent: Color,
            colorScheme: ColorScheme,
            isHovered: Bool = false
        ) -> Color {
            if isSelected {
                return colorScheme == .dark ? Color.white : accent
            } else if isHovered {
                return colorScheme == .dark ? Color.white : Color.primary
            } else {
                return colorScheme == .dark ? Color.white.opacity(0.82) : Color.secondary
            }
        }
    }
}

// MARK: - Native Liquid Glass Segmented Picker Component

/// macOS 27 Liquid Glass Segmented Picker for the top Navigation / Control Layer.
/// Uses `GlassEffectContainer` + `.glassEffect(.regular, in: Capsule())` on macOS 26+
/// so the active pill refracts and morphs smoothly, with clean high-contrast labels.
public struct MenuBarSegmentedPicker<Item: Identifiable & Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let items: [Item]
    @Binding public var selection: Item
    public let title: (Item) -> String
    public let icon: ((Item) -> String)?
    public let badge: ((Item) -> Int?)?

    @Namespace private var segmentNamespace
    @State private var hoveredItem: Item? = nil
    @FocusState private var focusedItem: Item?

    public init(
        items: [Item],
        selection: Binding<Item>,
        title: @escaping (Item) -> String,
        icon: ((Item) -> String)? = nil,
        badge: ((Item) -> Int?)? = nil
    ) {
        self.items = items
        self._selection = selection
        self.title = title
        self.icon = icon
        self.badge = badge
    }

    public var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 4) {
                    pickerRow
                }
            } else {
                pickerRow
            }
        }
        .padding(3)
        .background {
            Capsule()
                .fill(MenuBarTheme.Colors.segmentTrackBackground(colorScheme: colorScheme))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    MenuBarTheme.Colors.segmentTrackBorder(colorScheme: colorScheme),
                    lineWidth: 0.75
                )
        }
    }

    private var pickerRow: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                let isSelected = selection == item
                let isHovered = hoveredItem == item && !isSelected
                let isFocused = focusedItem == item

                Button {
                    selectItem(item)
                } label: {
                    HStack(spacing: 6) {
                        if let iconName = icon?(item) {
                            Image(systemName: iconName)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        }
                        Text(title(item))
                            .font(MenuBarTheme.Typography.segmentLabel(isSelected: isSelected))
                            .lineLimit(1)

                        if let count = badge?(item), count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    isSelected
                                        ? (colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.10))
                                        : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)),
                                    in: Capsule()
                                )
                        }
                    }
                    .foregroundStyle(
                        MenuBarTheme.Colors.segmentForeground(
                            isSelected: isSelected,
                            colorScheme: colorScheme,
                            isHovered: isHovered
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .background {
                        if isSelected {
                            activePill
                                .matchedGeometryEffect(id: "activeSegmentPill", in: segmentNamespace)
                        } else if isHovered {
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04))
                                .transition(.opacity)
                        }
                    }
                    .overlay {
                        if isFocused {
                            Capsule()
                                .strokeBorder(Color.accentColor, lineWidth: 1.75)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .zIndex(isSelected ? 1 : 0)
                .onHover { isHovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        hoveredItem = isHovering ? item : nil
                    }
                }
                .focusable()
                .focused($focusedItem, equals: item)
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
            }
        }
    }

    @ViewBuilder
    private var activePill: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(Color.clear)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color.white)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08),
                    radius: 2.5,
                    x: 0,
                    y: 1
                )
        }
    }

    private func selectItem(_ item: Item) {
        if reduceMotion {
            selection = item
        } else {
            withAnimation(.snappy(duration: 0.22, extraBounce: 0.02)) {
                selection = item
            }
        }
    }
}

public extension MenuBarSegmentedPicker where Item: CaseIterable {
    init(
        selection: Binding<Item>,
        title: @escaping (Item) -> String,
        icon: ((Item) -> String)? = nil,
        badge: ((Item) -> Int?)? = nil
    ) {
        self.init(
            items: Array(Item.allCases),
            selection: selection,
            title: title,
            icon: icon,
            badge: badge
        )
    }
}

// MARK: - Reusable Liquid Glass Pill Button Component

/// Interactive Liquid Glass capsule pill for transient options (duration, mode, toggles).
public struct MenuBarPillButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String?
    let isSelected: Bool
    let accent: Color
    let isMonospaced: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        title: String,
        icon: String? = nil,
        isSelected: Bool,
        accent: Color = .accentColor,
        isMonospaced: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.accent = accent
        self.isMonospaced = isMonospaced
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                }
                Text(title)
                    .font(MenuBarTheme.Typography.pillLabel(isSelected: isSelected, isMonospaced: isMonospaced))
            }
            .foregroundStyle(
                MenuBarTheme.Colors.pillForeground(
                    isSelected: isSelected,
                    accent: accent,
                    colorScheme: colorScheme,
                    isHovered: isHovered
                )
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, MenuBarTheme.Metrics.pillPaddingVertical)
            .padding(.horizontal, 4)
            .background {
                pillBackground
            }
            .overlay {
                if isSelected {
                    Capsule()
                        .strokeBorder(accent.opacity(colorScheme == .dark ? 0.55 : 0.38), lineWidth: 0.75)
                } else {
                    Capsule()
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                            lineWidth: 0.5
                        )
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    @ViewBuilder
    private var pillBackground: some View {
        if #available(macOS 26.0, *), isSelected {
            Capsule()
                .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.16))
                .glassEffect(.regular.interactive().tint(accent), in: Capsule())
        } else {
            Capsule()
                .fill(
                    MenuBarTheme.Colors.pillBackground(
                        isSelected: isSelected,
                        accent: accent,
                        colorScheme: colorScheme,
                        isHovered: isHovered
                    )
                )
        }
    }
}

// MARK: - Destructive Confirmation Bar Component

/// HIG-compliant destructive confirmation bar (e.g. "Delete 4.5GB?" or "Move app to Trash?").
public struct MenuBarDestructiveConfirmBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let confirmLabel: String
    let confirmIcon: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    public init(
        title: String,
        confirmLabel: String = "Clean",
        confirmIcon: String = "trash",
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.confirmIcon = confirmIcon
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(MenuBarTheme.Typography.confirmationTitle)
                .foregroundStyle(.red)
                .lineLimit(1)

            Spacer()

            Button("Cancel") {
                withAnimation(.snappy) { onCancel() }
            }
            .buttonStyle(.upkeepSecondary)
            .controlSize(.small)

            Button(role: .destructive) {
                onConfirm()
            } label: {
                Label(confirmLabel, systemImage: confirmIcon)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.upkeepPrimary)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(8)
        .background(
            Color.red.opacity(colorScheme == .dark ? 0.16 : 0.10),
            in: RoundedRectangle(cornerRadius: MenuBarTheme.Metrics.innerCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MenuBarTheme.Metrics.innerCornerRadius, style: .continuous)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 0.75)
        }
    }
}

// MARK: - Native Liquid Glass Search Field Component

/// Native Apple-style search capsule with magnifying glass, clear button, and Escape dismissal.
public struct MenuBarSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let placeholder: String
    var onEscape: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        placeholder: String = "Filter…",
        onEscape: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.onEscape = onEscape
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(MenuBarTheme.Typography.searchField)
                .focused($isFocused)
                .onExitCommand {
                    if !text.isEmpty {
                        text = ""
                    } else {
                        onEscape?()
                    }
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background {
            if #available(macOS 26.0, *) {
                Capsule()
                    .fill(Color.clear)
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
            }
        }
        .overlay {
            if isFocused {
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1)
            } else {
                Capsule()
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
            }
        }
    }
}

// MARK: - Status Indicator Component

/// Quiet, non-intrusive status indicator for the footer bar (no fake button chrome unless clickable).
public struct MenuBarStatusBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    public enum Status {
        case ok
        case warning
        case off
        case custom(Color)

        var color: Color {
            switch self {
            case .ok: return .green
            case .warning: return .orange
            case .off: return .secondary
            case .custom(let color): return color
            }
        }
    }

    let label: String
    let status: Status
    let icon: String?
    let action: (() -> Void)?

    public init(
        label: String,
        status: Status,
        icon: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.status = status
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        let content = HStack(spacing: 4.5) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)

            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.70) : .secondary)
            }

            Text(label)
                .font(MenuBarTheme.Typography.footerText)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.78) : .secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            action != nil
                ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                : Color.clear,
            in: Capsule()
        )
        .overlay {
            if action != nil {
                Capsule()
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                        lineWidth: 0.5
                    )
            }
        }

        if let action {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Standard Popover Container Modifier

public struct MenuBarPopoverContainer: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(MenuBarTheme.Metrics.popoverPadding)
            .frame(width: MenuBarTheme.Metrics.popoverWidth)
    }
}

public extension View {
    /// Applies the standard 380pt width and 16pt unified insets for the menu bar tray.
    func menuBarPopoverContainer() -> some View {
        modifier(MenuBarPopoverContainer())
    }
}
