import CodeCatchCore
import SwiftUI

/// One code (or sign-in link), presented like a notification: who it's from, the
/// code or the link's destination as the hero in a well, and its actions.
/// Shared by the floating banner and the top of the menu-bar popover.
struct CodeCard: View {
    enum Style { case banner, menu }

    let item: CodeItem
    let style: Style
    @ObservedObject private var model = AppModel.shared
    @Local private var hoveringCard = false
    @Local private var hoveringCode = false
    @AppStorage(Prefs.blurCodes) private var blurCodes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            well
            if let notice = item.linkNotice {
                WarningText(message: notice.text, calm: !notice.warns).font(.subheadline)
            }
            HStack(spacing: 8) {
                if item.isLink {
                    Button(action: open) { Label(locked ? "Unlock" : "Open Link", systemImage: locked ? "lock.fill" : "safari") }
                        .buttonStyle(ActionButtonStyle(prominent: true))
                        .keyboardShortcut(style == .menu ? KeyboardShortcut(.return, modifiers: []) : nil)
                        .help(locked ? "" : item.link?.absoluteString ?? "")
                    Button(action: copy) {
                        Label(onClipboard ? "Copied" : "Copy Link", systemImage: onClipboard ? "checkmark" : "link")
                    }
                    .buttonStyle(ActionButtonStyle())
                } else {
                    codeActions
                }
            }
        }
        .padding(16)
        .onHover { on in
            withAnimation(.easeOut(duration: 0.15)) { hoveringCard = on }
            if style == .banner { Banner.shared.setHovering(on) }
        }
    }

    private var onClipboard: Bool { Clipboard.holds(item) }
    private var locked: Bool { !model.isUnlocked }

    @ViewBuilder private var codeActions: some View {
        Button(action: copy) {
            Label(locked ? "Unlock" : onClipboard ? "Copied" : "Copy", systemImage: locked ? "lock.fill" : onClipboard ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(ActionButtonStyle(prominent: true))
        .keyboardShortcut(style == .menu ? KeyboardShortcut("c") : nil)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ServiceIcon(item: item, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.service).font(.headline).lineLimit(1)
                // The banner has no footer, so a failed unlock shows here, in the same one line.
                if style == .banner, locked, let error = model.unlockError {
                    WarningText(message: error, compact: true).font(.subheadline)
                } else {
                    Text([item.origination, item.isLink ? item.kind.title : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !item.isLink, item.link != nil {
                GlyphButton(symbol: "link", help: "Open the \(item.resetsPassword ? "password reset" : "sign-in") link (\(item.destination?.host ?? ""))", action: open)
            }
            if style == .banner, hoveringCard {
                GlyphButton(symbol: "xmark", help: "Dismiss") { Banner.shared.hide() }
            } else {
                Text(item.age(now: model.now)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(height: 38)
    }

    private var well: some View {
        let live = model.isFresh(item)
        return HStack(spacing: 10) {
            if item.isLink, let link = item.destination {
                IconTile(item.kind).help(item.kind.title).accessibilityLabel(item.kind.title)
                VStack(alignment: .leading, spacing: 1) {
                    // The site, never truncated: it is what a phishing check reads.
                    Text(ServiceIdentity.registrable(link.host ?? "")).font(.system(size: 16, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text((link.host ?? "") + (locked ? "" : link.path))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .opacity(live ? 1 : 0.5)
            } else {
                CodeText(code: locked ? hiddenCode(item.code) : item.code, size: 36, concealed: blurCodes && !hoveringCard)
                    .foregroundStyle(live ? .primary : .tertiary)
            }
            Spacer(minLength: 6)
            if live {
                HStack(spacing: 8) {
                    Text(item.remaining(now: model.now))
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    ExpiryRing(item: item, now: model.now, size: 22)
                }
            } else {
                Label("Expired", systemImage: "clock.badge.xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 60)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.hoverFill(hoveringCode, resting: 0.05)))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { on in withAnimation(.easeOut(duration: 0.12)) { hoveringCode = on } }
        .onTapGesture(perform: item.isLink ? open : copy)
        .help(locked ? "Click to unlock" : item.isLink ? "Click to open \(item.link?.absoluteString ?? "")" : "Click to copy")
    }

    private func copy() {
        model.unlocked {
            withAnimation(.snappy) { model.copy(item) }
            if style == .banner { Banner.shared.hide(after: 1.0) }
        }
    }

    /// Locked, a click only unlocks: the full link shows before anything opens.
    private func open() {
        guard !locked else { model.unlocked {}; return }
        model.open(item, leavingMenu: style == .menu)
        if style == .banner { Banner.shared.hide(after: 0.3) }
    }
}
