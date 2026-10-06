import SwiftUI

/// A System Settings row: coloured tile, title and subtitle, controls on the trailing edge.
/// `info` shows in a popover on hover. With `details`, clicking the row opens them instead.
struct SettingRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String?
    var info: String?
    var status: SourceStatus?
    var details: AnyView?
    @ViewBuilder var trailing: Trailing
    @Local private var presented = false

    var body: some View {
        HStack(spacing: 10) {
            if let details {
                Button { presented.toggle() } label: { label }
                    .buttonStyle(.plain)
                    .hoverHighlight(in: RoundedRectangle(cornerRadius: 6), outset: 4)
                    .accessibilityHint("Shows status and options")
                    .popover(isPresented: $presented, arrowEdge: .bottom) { InfoCard(title: title) { details } }
            } else {
                label
            }
            HStack(spacing: 10) { trailing }
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                    if let status {
                        Circle().fill(status.color).frame(width: 6, height: 6)
                            .accessibilityLabel(status.summary)
                    }
                }
                .accessibilityElement(children: .combine)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
        }
        .contentShape(Rectangle())
        .hoverInfo(title, details == nil ? info : nil)
    }
}

extension SettingRow where Trailing == Switch {
    init(symbol: String, color: Color, title: String, subtitle: String? = nil, info: String? = nil, isOn: Binding<Bool>) {
        self.init(symbol: symbol, color: color, title: title, subtitle: subtitle, info: info) { Switch(isOn: isOn, label: title) }
    }
}

struct Switch: View {
    @Binding var isOn: Bool
    var label = ""
    var body: some View { Toggle(label, isOn: $isOn).labelsHidden() }
}

/// An info button with a popover, for headers that need a short explanation.
struct SettingInfo<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Local private var presented = false

    var body: some View {
        GlyphButton(symbol: "info.circle", help: "\(title) information") { presented.toggle() }
            .popover(isPresented: $presented) { InfoCard(title: title) { content } }
    }
}

/// A button inside a popover that closes it first, so a sheet it opens can show.
struct PopoverButton: View {
    let title: String
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View { Button(title, role: role) { dismiss(); action() } }
}

/// The popover body every settings explanation and details panel uses.
struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 300)
    }
}

/// Shows `text` in a popover after the pointer rests on the view for a moment.
private struct HoverInfo: ViewModifier {
    let title: String
    let text: String?
    @Local private var shown = false
    @Local private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                guard inside, text != nil else { shown = false; return }
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { shown = true }
                }
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                InfoCard(title: title) { Text(text ?? "").foregroundStyle(.secondary) }
            }
    }
}

extension View {
    func hoverInfo(_ title: String, _ text: String?) -> some View { modifier(HoverInfo(title: title, text: text)) }
}
