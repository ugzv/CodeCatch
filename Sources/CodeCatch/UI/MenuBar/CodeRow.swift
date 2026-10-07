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
                Text(item.origin == .vault
                     ? [item.accountLabel, item.sourceLabel].filter { !$0.isEmpty }.joined(separator: " · ")
                     : [item.origination, item.destination?.host].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let notice = item.linkNotice {
                    // Never cut short: it is a phishing warning, and its end says what to check.
                    WarningText(message: notice.text, calm: !notice.warns).font(.caption)
                } else if item.origin != .vault, showPreviews, !concealed, !context.isEmpty {
                    Text(context).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.isLink {
                Button(action: activate) {
                    Label { Text(locked ? "Unlock" : "Open") } icon: {
                        Image(systemName: locked ? "lock.fill" : item.kind.symbol).foregroundStyle(locked ? AnyShapeStyle(.secondary) : AnyShapeStyle(item.kind.color))
                    }
                }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(locked ? "Unlock" : "Open \(item.kind.title.lowercased())")
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
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
                        } else if live {
                            ExpiryRing(item: item, now: model.now, size: 14).transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .font(.system(size: 14))
                    .frame(width: 14)
                    CodeText(code: locked ? hiddenCode(item.code) : item.code, size: 15, weight: .medium, concealed: concealed && !locked)
                        .foregroundStyle(copied ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(live ? .primary : .tertiary))
                }
            }
            // The right-click actions, findable: in a fixed slot so the code never shifts as it appears.
            Menu { CodeMenu(item: item) } label: { GlyphLabel(symbol: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 24)
                .opacity(hovering || selected ? 1 : 0)
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
        .onHover { on in withAnimation(.easeOut(duration: 0.12)) { hovering = on } }
        .onTapGesture(perform: activate)
        .help(concealed || !showPreviews ? item.origination : item.snippet)
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
        if item.origin != .test {
            Button(item.origin == .messages ? "Open in Messages" : "Open Mail App") { model.openSource(item) }
            Divider()
        }
        Button("Clear") { model.dismiss(item) }
        Button(!item.isLink ? "Not a Code" : item.resetsPassword ? "Not a Password Reset Link" : "Not a Sign-In Link") { model.dismiss(item) }
        if !item.sender.isEmpty {
            Button("Ignore All from \(item.sender)") { model.ignoreSender(of: item) }
        }
    }
}
