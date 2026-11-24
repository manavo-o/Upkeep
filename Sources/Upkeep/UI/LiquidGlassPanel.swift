import AppKit
import SwiftUI

/// Borderless, non-activating floating NSPanel configured for macOS 27 Golden Gate Liquid Glass.
@MainActor
public final class LiquidGlassPanel: NSPanel {
    var hudShortcut: ((NSEvent) -> Bool)?

    init(contentRect: NSRect, level: NSWindow.Level = .floating, useWindowGlass: Bool = false, content: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = level
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = useWindowGlass
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.animationBehavior = .utilityWindow

        if useWindowGlass {
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: contentRect)
                glass.contentView = content
                self.contentView = glass
            } else {
                let visual = NSVisualEffectView(frame: contentRect)
                visual.material = .hudWindow
                visual.blendingMode = .behindWindow
                visual.state = .active
                visual.wantsLayer = true
                visual.layer?.cornerRadius = 20
                visual.layer?.masksToBounds = true
                content.translatesAutoresizingMaskIntoConstraints = false
                visual.addSubview(content)
                NSLayoutConstraint.activate([
                    content.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
                    content.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
                    content.topAnchor.constraint(equalTo: visual.topAnchor),
                    content.bottomAnchor.constraint(equalTo: visual.bottomAnchor)
                ])
                self.contentView = visual
            }
        } else {
            self.contentView = content
        }
    }

    public convenience init<Content: View>(
        contentRect: NSRect,
        level: NSWindow.Level = .floating,
        useWindowGlass: Bool = false,
        @ViewBuilder rootView: () -> Content
    ) {
        let hosting = NSHostingView(rootView: rootView())
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.init(contentRect: contentRect, level: level, useWindowGlass: useWindowGlass, content: hosting)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), hudShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, hudShortcut?(event) == true { return }
        super.sendEvent(event)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public func presentCenteredAtHUDHeight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            center()
            makeKeyAndOrderFront(nil)
            return
        }
        let visible = screen.visibleFrame
        let x = visible.midX - (frame.width / 2)
        let y = visible.maxY - frame.height - (visible.height * 0.16)
        setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 40, y)))
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

/// Applies native macOS 27 Golden Gate Liquid Glass with standard specular edge highlights.
public struct UpkeepGlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let interactive: Bool
    let tintColor: Color?

    public init(shape: S, interactive: Bool = false, tintColor: Color? = nil) {
        self.shape = shape
        self.interactive = interactive
        self.tintColor = tintColor
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let baseGlass: Glass = {
                var g: Glass = .regular
                if let tintColor {
                    g = g.tint(tintColor)
                }
                if interactive {
                    g = g.interactive()
                }
                return g
            }()
            content
                .containerShape(shape)
                .glassEffect(baseGlass, in: shape)
                .overlay {
                    if reduceTransparency {
                        shape.strokeBorder(.separator, lineWidth: 1)
                    } else {
                        shape.strokeBorder(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [Color.white.opacity(0.28), Color.white.opacity(0.06)]
                                    : [Color.white.opacity(0.70), Color.white.opacity(0.25)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                    }
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12),
                    radius: 14,
                    x: 0,
                    y: 7
                )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .containerShape(shape)
                .overlay {
                    if reduceTransparency {
                        shape.strokeBorder(.separator, lineWidth: 1)
                    } else {
                        shape.strokeBorder(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [Color.white.opacity(0.28), Color.white.opacity(0.06)]
                                    : [Color.white.opacity(0.70), Color.white.opacity(0.25)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                    }
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12),
                    radius: 14,
                    x: 0,
                    y: 7
                )
        }
    }
}

/// Quiet grouped content surface for macOS 27 Control Center–style sections.
/// Obeys Apple HIG's two-layer rule: Liquid Glass stays on the control/navigation layer,
/// while content containers use clean, legible grouped fills with concentric continuous corners.
public struct TrayTileSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let isActive: Bool
    let accent: Color
    let isHovered: Bool
    let isPressed: Bool
    let cornerRadius: CGFloat
    let innerPadding: CGFloat?

    public init(
        isActive: Bool = false,
        accent: Color = .accentColor,
        isHovered: Bool = false,
        isPressed: Bool = false,
        cornerRadius: CGFloat = MenuBarTheme.Metrics.tileCornerRadius,
        innerPadding: CGFloat? = nil
    ) {
        self.isActive = isActive
        self.accent = accent
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.cornerRadius = cornerRadius
        self.innerPadding = innerPadding
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .padding(innerPadding ?? 0)
            .background {
                if reduceTransparency {
                    shape.fill(
                        isActive
                            ? accent.opacity(0.28)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                } else {
                    shape.fill(
                        isActive
                            ? accent.opacity(colorScheme == .dark ? 0.14 : 0.10)
                            : (colorScheme == .dark
                                ? Color.white.opacity(isHovered ? 0.065 : 0.045)
                                : Color.black.opacity(isHovered ? 0.045 : 0.032))
                    )
                }
            }
            .containerShape(shape)
            .overlay {
                if reduceTransparency {
                    shape.strokeBorder(isActive ? accent : Color.secondary.opacity(0.35), lineWidth: 1)
                } else {
                    shape.strokeBorder(
                        isActive
                            ? accent.opacity(colorScheme == .dark ? 0.45 : 0.30)
                            : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                        lineWidth: 0.5
                    )
                }
            }
            .scaleEffect(isPressed ? 0.99 : 1.0)
            .animation(.snappy(duration: 0.16), value: isHovered)
            .animation(.snappy(duration: 0.12), value: isPressed)
            .contentShape(shape)
    }
}

public extension View {
    func upkeepGlass<S: InsettableShape>(
        in shape: S,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(UpkeepGlassSurface(shape: shape, interactive: interactive, tintColor: tint))
    }

    func trayTile(
        isActive: Bool = false,
        accent: Color = .accentColor,
        isHovered: Bool = false,
        isPressed: Bool = false,
        cornerRadius: CGFloat = MenuBarTheme.Metrics.tileCornerRadius,
        innerPadding: CGFloat? = nil
    ) -> some View {
        modifier(TrayTileSurface(
            isActive: isActive,
            accent: accent,
            isHovered: isHovered,
            isPressed: isPressed,
            cornerRadius: cornerRadius,
            innerPadding: innerPadding
        ))
    }
}
