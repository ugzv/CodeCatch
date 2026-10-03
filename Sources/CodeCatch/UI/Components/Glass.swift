import AppKit
import SwiftUI

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

enum Glass {
    /// Offscreen snapshots can't sample what's behind a window, so they use the material.
    static var useMaterial = false
}

/// Liquid Glass on macOS 26+, a vibrant material before that.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !Glass.useMaterial {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(VisualEffect().clipShape(shape))
                .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: shadowRadius, y: shadowY)
        }
    }
}
