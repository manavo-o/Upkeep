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
