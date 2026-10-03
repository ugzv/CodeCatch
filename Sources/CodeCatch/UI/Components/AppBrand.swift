import AppKit
import SwiftUI

/// The same three rounded strokes as Resources/AppIcon.icon/Assets/asterisk.svg.
struct CodeCatchMark: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let radius = size * 84 / 608
        let stroke = Path(roundedRect: CGRect(x: -radius, y: -size / 2, width: radius * 2, height: size),
                          cornerRadius: radius)
        var mark = Path()
        for angle in [0.0, Double.pi / 3, -Double.pi / 3] {
            mark.addPath(stroke, transform: CGAffineTransform(rotationAngle: angle)
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
        }
        return mark
    }
}

@MainActor
enum AppBrand {
    static let name = "CodeCatch"
    /// "1.0 (52)": marketing version and build. Nil in an unbundled build.
    static let version: String? = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        return "\(version) (\(build))"
    }()
    static let colors = [Color(red: 1, green: 0.63529, blue: 0.05882), Color(red: 1, green: 0.17647, blue: 0.33333)]
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(CodeCatchMark().path(in: bounds).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: name])
    }
}

/// The app icon at IconTile size, for the row that stands for CodeCatch itself.
struct BrandTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.linearGradient(colors: AppBrand.colors, startPoint: .top, endPoint: .bottom))
            .frame(width: 22, height: 22)
            .overlay(CodeCatchMark().fill(.white).frame(width: 13, height: 13))
            .accessibilityHidden(true)
    }
}

struct BrandHeading: View {
    var body: some View {
        HStack(spacing: 8) {
            CodeCatchMark().fill(.linearGradient(colors: AppBrand.colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(AppBrand.name).font(.headline)
        }
    }
}
