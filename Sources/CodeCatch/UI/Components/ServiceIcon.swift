import AppKit
import SwiftUI

/// The service's own logo when its site has one, else a monogram; with the
/// source app's icon as a badge, like a notification.
struct ServiceIcon: View {
    let item: CodeItem
    var size: CGFloat = 38
    @ObservedObject private var icons = IconStore.shared

    var body: some View {
        Group {
            if item.origin == .test {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: size * 1.2, height: size * 1.2)
            } else if let icon = icons.icon(for: item.domain) {
                LogoTile(icon: icon, size: size)
            } else {
                Monogram(name: item.service, size: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if let logo = icons.icon(for: mailbox) {
                    LogoTile(icon: logo, size: size * 0.46)
                } else if item.origin != .test, let badge = item.origin.appIcon(sourceKey: item.sourceKey) {
                    Image(nsImage: badge).resizable().frame(width: size * 0.46, height: size * 0.46)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .offset(x: size * 0.13, y: size * 0.12)
        }
    }

    /// A mail code's badge is the mailbox it came to (Gmail, Outlook, Fastmail), not the app it's read in.
    private var mailbox: String? {
        guard item.origin == .mail else { return nil }
        return AppModel.shared.accounts.first { $0.id.uuidString == item.sourceKey }?.iconDomain
    }
}

/// A site's logo as an app-icon tile.
private struct LogoTile: View {
    let icon: IconStore.Icon
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Group {
            if icon.fullBleed {
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFill()
            } else {
                Color.white.overlay(Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit().padding(size * 0.17))
            }
        }
        .frame(width: size, height: size)
        // The same light-to-dark sheen as a monogram's gradient, so logos and monograms sit together.
        .overlay(LinearGradient(colors: [.white.opacity(0.14), .black.opacity(0.08)], startPoint: .top, endPoint: .bottom))
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
    }
}

extension CodeItem.Origin {
    /// Messages, Apple Mail, the default mail app, or the vault, shown as a badge.
    func appIcon(sourceKey: String) -> NSImage? {
        switch self {
        case .messages: Self.icon("com.apple.MobileSMS")
        case .mail where sourceKey == AppleMailStore.sourceKey: Self.icon("com.apple.mail")
        case .mail: NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        case .test: NSApp.applicationIconImage
        case .vault: Self.icon("com.bitwarden.desktop")
        }
    }

    private static var cache: [String: NSImage] = [:]

    private static func icon(_ bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

/// Squircle monogram in a stable system colour.
struct Monogram: View {
    let name: String
    var size: CGFloat = 38

    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .green, .teal, .gray]

    var body: some View {
        let hash = name.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(Self.palette[Int(hash.magnitude % UInt(Self.palette.count))].gradient)
            .overlay {
                if let first = name.first, first.isLetter {
                    Text(String(first).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: "number").font(.system(size: size * 0.4, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
            .frame(width: size, height: size)
    }
}
