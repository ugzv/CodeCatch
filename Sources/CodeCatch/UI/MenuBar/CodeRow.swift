import SwiftUI

struct CodeRow: View {
    let item: CodeItem
    var selected = false
    /// Shared by the rows, so the one selection highlight slides between them.
    let selection: Namespace.ID
    @ObservedObject private var model = AppModel.shared
    @Local private var hovering = false
    @AppStorage(Prefs.blurCodes) private var blurCodes = false
    @AppStorage(Prefs.showPreviews) private var showPreviews = true

    /// The preview without a leading "OTP banka:" that only repeats the title.
    private var context: String {
        guard item.preview.lowercased().hasPrefix(item.service.lowercased() + ":") else { return item.preview }
        return item.preview.dropFirst(item.service.count + 1).trimmingCharacters(in: .whitespaces)
    }

    private var live: Bool { model.isFresh(item) }
    private var copied: Bool { Clipboard.holds(item) }
    private var locked: Bool { !model.isUnlocked }
    private var concealed: Bool { locked || blurCodes && !hovering }
    /// The row a click or Return acts on.
    private var active: Bool { hovering || selected }

    /// "codecatch.app", or "work@gmail.com · codecatch.app". A link that goes somewhere the sender can't
    /// vouch for marks just its site, while it can still be opened; the full warning is on hover and in the card.
    private var subtitle: Text? {
        if item.origin == .vault { return Text([item.accountLabel, item.sourceLabel].filter { !$0.isEmpty }.joined(separator: " · ")) }
        let origination = model.origination(item)
        guard var host = item.destination?.host else { return origination.isEmpty ? nil : Text(origination) }
        if host.hasPrefix("www.") { host.removeFirst(4) }  // shown only; the link keeps it
        let site = live && item.linkNotice?.warns == true
            ? Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(host)").foregroundStyle(.orange) : Text(host)
        return origination.isEmpty ? site : Text(origination + " · ") + site
    }

    var body: some View {
        HStack(spacing: 11) {
            ServiceIcon(item: item, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.service).font(.body.weight(.semibold)).lineLimit(1)
                    if model.search.isPinned(item) {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary).accessibilityLabel("Pinned")
                    }
                    if item.origin != .vault {
                        Text(item.age(now: model.now)).font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    if copied {
                        Text("Copied").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).transition(.opacity)
                    } else if !live {
                        Text("Expired").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                    }
                }
                // Cut in the middle: a lookalike site gives itself away at its end.
                if let subtitle {
                    subtitle
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(item.linkNotice?.text ?? "")
                }
                if item.origin != .vault, showPreviews, !concealed, !context.isEmpty {
                    Text(context).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.isLink {
                Button(action: activate) {
                    Label(locked ? "Unlock" : "Open", systemImage: locked ? "lock.fill" : item.kind.symbol)
                        // Faded once expired, like an expired code: still clickable, since the link may still work.
                        .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(live ? .primary : .tertiary))
                }
                    // Blue marks what a click or Return does, as Open Link does on the card.
                    .buttonStyle(ActionButtonStyle(prominent: active, compact: true))
                    .animation(nil, value: active)  // the row's highlight eases in; the button just switches
                    .accessibilityLabel(locked ? "Unlock" : "Open \(item.kind.title.lowercased())")
                    .help(concealed ? item.destination?.host ?? "" : item.link?.absoluteString ?? "")
            }
            if !item.isLink {
                // On the clipboard: the ring turns into a checkmark; the code itself stays put.
                HStack(spacing: 8) {
                    // A fixed slot: the mark pops in without pushing the code aside.
                    ZStack {
                        if copied {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .symbolEffect(.bounce, value: copied)
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                                .help("On the clipboard")
                                .accessibilityLabel("Copied")
                        } else if live && item.showsCountdown(now: model.now) {
                            ExpiryRing(item: item, now: model.now, size: 14).transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .font(.system(size: 14))
                    .frame(width: 14)
                    // The same pill as a link's Open, blue on the row a click or Return copies.
                    Button(action: activate) {
                        CodeText(code: locked ? hiddenCode(item.code) : item.code, size: 15, weight: .medium, concealed: concealed && !locked)
                            .foregroundStyle(active ? AnyShapeStyle(.white) : copied ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(live ? .primary : .tertiary))
                    }
                        .buttonStyle(ActionButtonStyle(prominent: active, compact: true))
                        .animation(nil, value: active)
                        .accessibilityLabel("Copy code")
                }
            }
            // The right-click actions, findable. Always there, quiet until hovered: the rows end on one
            // column, in line with the footer's ⋯, and nothing shifts under the pointer.
            Menu { CodeMenu(item: item) } label: { GlyphLabel(symbol: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 24)
                .opacity(active ? 1 : 0.45)
                .help("More")
                .accessibilityLabel("More actions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if selected {
                shape.fill(Color.accentColor.opacity(0.14)).matchedGeometryEffect(id: "selection", in: selection)
            } else {
                shape.fill(Color.hoverFill(hovering))
            }
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.2), value: copied)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contentShape(Rectangle())
        .onHover { on in withAnimation(hoverAnimation(on)) { hovering = on } }
        .onTapGesture(perform: activate)
        .contextMenu { CodeMenu(item: item) }
    }

    /// A click does what the card's well does: open a link, copy a code. Locked, a link only unlocks.
    private func activate() {
        if item.isLink, locked { model.unlocked {}; return }
        model.unlocked {
            if item.isLink { return model.open(item, leavingMenu: true) }
            withAnimation(.snappy(duration: 0.25, extraBounce: 0.15)) { model.copy(item) }
        }
    }
}

/// The right-click actions for a code, shared by the rows and the latest card.
struct CodeMenu: View {
    let item: CodeItem
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        if model.isUnlocked {
            unlockedActions
        } else {
            Button("Unlock…") { model.unlocked {} }
        }
    }

    @ViewBuilder private var unlockedActions: some View {
        if item.link != nil {
            Button("Open Link") { model.open(item, leavingMenu: true) }
            Button("Copy Link") { model.copyLink(item) }
        }
        if !item.isLink {
            Button("Copy Code") { model.copy(item) }
        }
        if item.origin == .vault {
            Button(model.search.isPinned(item) ? "Unpin Login" : "Pin Login") { model.search.togglePin(item) }
        }
        if item.origin != .vault { messageActions }
    }

    /// For received codes only: a vault login has no message, source or sender.
    @ViewBuilder private var messageActions: some View {
        Button("Copy Message") { Clipboard.copy(item.snippet, id: item.id) }
        Divider()
        if let source = model.source(of: item) {
            Button(source.title) { NSWorkspace.shared.open(source.url) }
            Divider()
        }
        Button("Clear") { model.dismiss(item) }
        Button(!item.isLink ? "Not a Code" : item.resetsPassword ? "Not a Password Reset Link" : "Not a Sign-In Link") { model.dismiss(item) }
        if !item.sender.isEmpty {
            Button("Ignore All from \(item.sender)") { model.ignoreSender(of: item) }
        }
    }
}
