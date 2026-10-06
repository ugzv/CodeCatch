import AppKit
import SwiftUI

/// Capsule actions with explicit colours, so they look the same in the
/// never-key banner panel as in a key window (system styles grey out there).
struct ActionButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .contentTransition(.symbolEffect(.replace))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 10)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.primary.opacity(0.08)))
                Capsule().strokeBorder(.primary.opacity(prominent ? 0 : 0.06), lineWidth: 0.5)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension Color {
    /// The fill behind whatever the pointer is over, the same strength everywhere.
    static func hoverFill(_ hovering: Bool, resting: Double = 0) -> Color { .primary.opacity(hovering ? 0.08 : resting) }
}

private struct HoverHighlight<S: Shape>: ViewModifier {
    let shape: S
    let outset: CGFloat
    @Local private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.hoverFill(hovering)).padding(-outset))
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Highlights the view in `shape` while the pointer is over it; `outset` grows the highlight past the view.
    func hoverHighlight(in shape: some Shape, outset: CGFloat = 0) -> some View {
        modifier(HoverHighlight(shape: shape, outset: outset))
    }
}

/// A toolbar-weight glyph: the face of GlyphButton and of the ••• and ? menus.
struct GlyphLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
    }
}

/// Toolbar-weight glyph button that only shows a background on hover.
struct GlyphButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlyphLabel(symbol: symbol)
                .hoverHighlight(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An error or warning, drawn the same everywhere: orange, with a warning sign. The caller
/// sets the font. `compact` keeps it to one line, with the full text on hover.
struct WarningText: View {
    let message: String
    var compact = false

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .lineLimit(compact ? 1 : nil)
            .fixedSize(horizontal: false, vertical: !compact)
            .help(compact ? message : "")
    }
}

/// Unlock, showing the same busy state wherever it is while Touch ID or the password is up.
struct VaultUnlockButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isBusy ? "Unlocking…" : "Unlock", systemImage: "lock.fill")
        }
        .disabled(isBusy)
    }
}

/// System Settings–style coloured icon tile.
/// What CodeCatch catches, drawn the same in Settings → What to Catch and on the cards.
enum CatchKind {
    case code, signIn, passwordReset

    var title: String { switch self { case .code: "Code"; case .signIn: "Sign-in link"; case .passwordReset: "Password reset" } }
    var symbol: String { switch self { case .code: "number"; case .signIn: "link"; case .passwordReset: "lock.rotation" } }
    var color: Color { switch self { case .code: .blue; case .signIn: .teal; case .passwordReset: .orange } }
}

extension CodeItem {
    var kind: CatchKind { !isLink ? .code : resetsPassword ? .passwordReset : .signIn }
}

/// Where codes come from, drawn the same in Welcome and Settings → Sources.
enum SourceKind {
    case messages, appleMail, mail

    var symbol: String { switch self { case .messages: "message.fill"; case .appleMail: "tray.fill"; case .mail: "envelope.fill" } }
    var color: Color { switch self { case .messages: .green; case .appleMail: .cyan; case .mail: .blue } }
}

struct IconTile: View {
    let symbol: String
    let color: Color

    init(symbol: String, color: Color) { self.symbol = symbol; self.color = color }
    init(_ kind: CatchKind) { self.init(symbol: kind.symbol, color: kind.color) }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.gradient)
            .frame(width: 22, height: 22)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
    }
}

extension View {
    /// The strip along the bottom of the Settings, Welcome and Find a Code windows.
    func bottomBar() -> some View {
        padding(.horizontal, 20).padding(.vertical, 10).background(.background).overlay(alignment: .top) { Divider() }
    }
}

/// Asks before something that can't be undone. An alert rather than a SwiftUI dialog,
/// so it works the same from the menu-bar popover as from Settings.
@MainActor
func confirmed(_ title: String, _ message: String, action: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: action).hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    NSApp.activate()
    return alert.runModal() == .alertFirstButtonReturn
}

/// Settings and the menu's Clear History: a clear outlasts restarts, so it asks first.
@MainActor
func confirmClearHistory(_ model: AppModel) {
    guard confirmed("Clear history?", "Codes and links you have received are removed and don't come back after a restart. Bitwarden codes are kept.",
                    action: "Clear") else { return }
    model.clearHistory()
}

extension View {
    /// Applies Hide from Screen Capture to this view's window as soon as it has one, before
    /// a code is drawn; `AppModel.tick` keeps every window current when the setting changes.
    func hiddenFromCapture() -> some View { background(CaptureGuard()) }
}

private struct CaptureGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.sharingType = Prefs[Prefs.hideFromCapture] ? .none : .readOnly
        }
    }
}
