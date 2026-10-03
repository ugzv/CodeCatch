import AppKit
import SwiftUI

/// Time left until the code expires: accent, orange in the last quarter, red at the
/// end (the last 30 s, or the last sixth of a short TOTP period).
struct ExpiryRing: View {
    let item: CodeItem
    let now: Date
    var size: CGFloat = 20

    var body: some View {
        let left = max(0, item.expires.timeIntervalSince(now))
        let fraction = item.lifetime > 0 ? left / item.lifetime : 0
        let color: Color = left < min(30, item.lifetime / 6) ? .red : fraction <= 0.25 ? .orange : .accentColor
        // A visible track and no sweep back to full when a new code starts: at 14 pt a
        // faint track with a moving arc reads as a loading spinner.
        let width = max(2, size * 0.14)
        ZStack {
            Circle().stroke(.primary.opacity(0.18), lineWidth: width)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(fraction > 0.95 ? nil : .linear(duration: 1), value: fraction)
        }
        .frame(width: size, height: size)
        .help(left > 0 ? "Expires in \(item.remaining(now: now))" : "Expired")
    }
}
