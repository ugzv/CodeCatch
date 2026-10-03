// Renders the installer window background: a mid-tone backdrop (Finder draws icon labels
// black in light mode and white in dark mode, so both must stay readable), an arrow from
// the app icon to Applications and a caption. Geometry matches scripts/dmg-settings.py.
//   swift scripts/make-dmg-background.swift background.png   (also writes background@2x.png)
import AppKit

let out = CommandLine.arguments[1]
let size = NSSize(width: 640, height: 400)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    NSGradient(starting: NSColor(srgbRed: 0.74, green: 0.69, blue: 0.68, alpha: 1),
               ending: NSColor(srgbRed: 0.58, green: 0.53, blue: 0.53, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Icons are centred 190pt from the top at x = 170 and 470; AppKit's origin is bottom-left.
    let y = size.height - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 280, y: y))
    arrow.line(to: NSPoint(x: 360, y: y))
    arrow.move(to: NSPoint(x: 342, y: y + 18))
    arrow.line(to: NSPoint(x: 360, y: y))
    arrow.line(to: NSPoint(x: 342, y: y - 18))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.9).setStroke()
    arrow.stroke()

    let caption = NSAttributedString(string: "Drag CodeCatch to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9),
    ])
    // Above the icons: Finder's path and status bars, when shown, cover the bottom of the window.
    caption.draw(at: NSPoint(x: (size.width - caption.size().width) / 2, y: size.height - 70))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: out))
try! render(scale: 2).write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "@2x.png")))
