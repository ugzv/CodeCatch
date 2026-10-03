// Renders the fallback icon for systems without Liquid Glass icons,
// from Resources/AppIcon.icon (the Icon Composer source): its default vertical background
// gradient plus each layer back to front, masked to the macOS icon grid (824/1024 body).
// Flat on purpose: depth, highlights and shadows are the system's job, per the HIG.
//   swift scripts/make-icon.swift /tmp/AppIcon.icns [/tmp/preview.png]
import AppKit

let out = CommandLine.arguments[1]
let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Resources/AppIcon.icon")
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: src.appending(path: "icon.json"))) as! [String: Any]
let fill = (json["fill-specializations"] as! [[String: Any]]).first { $0["appearance"] == nil }!["value"] as! [String: Any]
let gradient = NSGradient(colors: (fill["linear-gradient"] as! [String]).map {  // "srgb:r,g,b,a"
    let c = $0.split(separator: ":")[1].split(separator: ",").map { CGFloat(Double($0)!) }
    return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
})!
// Groups and layers are listed front to back.
let layers = (json["groups"] as! [[String: Any]]).reversed().flatMap { ($0["layers"] as! [[String: Any]]).reversed() }
    .map { NSImage(contentsOf: src.appending(path: "Assets/\($0["image-name"] as! String)"))! }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)  // draw in 1024 units
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).addClip()
    gradient.draw(in: body, angle: -90)
    for layer in layers { layer.draw(in: body) }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 { try! render(512).write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", out]
try! p.run()
p.waitUntilExit()
