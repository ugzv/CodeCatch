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

/// Toolbar-weight glyph button that only shows a background on hover.
struct GlyphButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// System Settings–style coloured icon tile.
struct IconTile: View {
    let symbol: String
    let color: Color

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
