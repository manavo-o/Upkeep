import AppKit
import SwiftUI

// MARK: - Upkeep App Icon (Loaded from Apple Icon Composer export)

/// Displays Upkeep's Liquid Glass app icon exported from Apple Icon Composer,
/// falling back cleanly to a matching SwiftUI vector mark during headless test runs.
public struct UpkeepAppIconView: View {
    public var size: CGFloat = 34

    public init(size: CGFloat = 34) {
        self.size = size
    }

    private static let cachedAppIcon: NSImage? = loadBundledAppIcon()

    public var body: some View {
        if let nsImage = Self.cachedAppIcon {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1.5)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.04, green: 0.56, blue: 1.0), Color(red: 0.0, green: 0.42, blue: 0.94)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                UpkeepAppGlyphShape()
                    .fill(.white)
                    .padding(size * 0.22)
            }
            .frame(width: size, height: size)
        }
    }

    private static func loadBundledAppIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }
}

private struct UpkeepAppGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.14))
        path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.64))
        path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.64))
        path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.86))
        path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.86))
        path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.64))
        path.addLine(to: CGPoint(x: w * 0.16, y: h * 0.64))
        path.closeSubpath()
        return path
    }
}

// MARK: - Bespoke Apple-Style Section Icons (No Generic SF Symbols)

/// Custom vector section badges modeled after macOS 27 System Settings icons:
/// continuous-corner squircle with subtle top specular rim and original geometric glyphs.
public struct UpkeepSectionIcon: View {
    public let section: TraySection
    public var size: CGFloat = 22

    public init(section: TraySection, size: CGFloat = 22) {
        self.section = section
        self.size = size
    }

    public var body: some View {
        let radius = size * 0.26
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )

            glyph
                .frame(width: size * 0.58, height: size * 0.58)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.14), radius: 1.5, x: 0, y: 0.75)
    }

    private var gradientColors: [Color] {
        switch section {
        case .controls:
            return [Color(red: 1.0, green: 0.62, blue: 0.16), Color(red: 0.94, green: 0.44, blue: 0.06)]
        case .homebrew:
            return [Color(red: 0.38, green: 0.42, blue: 0.98), Color(red: 0.25, green: 0.28, blue: 0.86)]
        case .cleaner:
            return [Color(red: 0.18, green: 0.80, blue: 0.72), Color(red: 0.06, green: 0.62, blue: 0.58)]
        case .uninstaller:
            return [Color(red: 0.98, green: 0.36, blue: 0.42), Color(red: 0.84, green: 0.20, blue: 0.28)]
        case .updates:
            return [Color(red: 0.22, green: 0.82, blue: 0.44), Color(red: 0.12, green: 0.66, blue: 0.30)]
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch section {
        case .controls:
            PowerDialGlyph()
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.4, size * 0.085), lineCap: .round, lineJoin: .round))
        case .homebrew:
            PackageCubeGlyph()
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.3, size * 0.08), lineCap: .round, lineJoin: .round))
        case .cleaner:
            CleanSweepGlyph()
                .fill(.white)
        case .uninstaller:
            EjectTrayGlyph()
                .fill(.white)
        case .updates:
            OrbitRefreshGlyph()
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.4, size * 0.085), lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Original Vector Glyph Shapes

private struct PowerDialGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) * 0.42
        path.addArc(center: c, radius: r, startAngle: .degrees(-50), endAngle: .degrees(230), clockwise: false)
        path.move(to: CGPoint(x: c.x, y: c.y - r * 1.12))
        path.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.10))
        return path
    }
}

private struct PackageCubeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let top = CGPoint(x: w * 0.50, y: h * 0.08)
        let rightTop = CGPoint(x: w * 0.90, y: h * 0.29)
        let rightBot = CGPoint(x: w * 0.90, y: h * 0.72)
        let bot = CGPoint(x: w * 0.50, y: h * 0.92)
        let leftBot = CGPoint(x: w * 0.10, y: h * 0.72)
        let leftTop = CGPoint(x: w * 0.10, y: h * 0.29)
        let center = CGPoint(x: w * 0.50, y: h * 0.50)

        path.move(to: top)
        path.addLine(to: rightTop)
        path.addLine(to: rightBot)
        path.addLine(to: bot)
        path.addLine(to: leftBot)
        path.addLine(to: leftTop)
        path.closeSubpath()

        path.move(to: leftTop)
        path.addLine(to: center)
        path.addLine(to: rightTop)
        path.move(to: center)
        path.addLine(to: bot)
        return path
    }
}

private struct CleanSweepGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        // Sculpted 4-point precision diamond star + subtle accent orb
        path.move(to: CGPoint(x: w * 0.48, y: h * 0.06))
        path.addQuadCurve(to: CGPoint(x: w * 0.90, y: h * 0.50), control: CGPoint(x: w * 0.56, y: h * 0.42))
        path.addQuadCurve(to: CGPoint(x: w * 0.48, y: h * 0.94), control: CGPoint(x: w * 0.56, y: h * 0.58))
        path.addQuadCurve(to: CGPoint(x: w * 0.06, y: h * 0.50), control: CGPoint(x: w * 0.40, y: h * 0.58))
        path.addQuadCurve(to: CGPoint(x: w * 0.48, y: h * 0.06), control: CGPoint(x: w * 0.40, y: h * 0.42))
        path.closeSubpath()
        return path
    }
}

private struct EjectTrayGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        // Upward eject triangle
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.14))
        path.addLine(to: CGPoint(x: w * 0.86, y: h * 0.58))
        path.addLine(to: CGPoint(x: w * 0.14, y: h * 0.58))
        path.closeSubpath()
        // Rounded base bar
        let barRect = CGRect(x: w * 0.14, y: h * 0.70, width: w * 0.72, height: h * 0.16)
        path.addRoundedRect(in: barRect, cornerSize: CGSize(width: h * 0.08, height: h * 0.08))
        return path
    }
}

private struct OrbitRefreshGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) * 0.40
        path.addArc(center: c, radius: r, startAngle: .degrees(-60), endAngle: .degrees(245), clockwise: false)
        // Arrowhead at top-right
        let tip = CGPoint(x: c.x + r * 0.55, y: c.y - r * 0.82)
        path.move(to: CGPoint(x: tip.x - r * 0.38, y: tip.y - r * 0.08))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + r * 0.08, y: tip.y + r * 0.38))
        return path
    }
}
