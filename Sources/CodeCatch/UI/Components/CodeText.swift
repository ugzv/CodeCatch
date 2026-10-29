import AppKit
import SwiftUI

/// "482 913" / "4829 1365": halves split by a thin space, like Passwords shows them.
func groupedCode(_ code: String, wide: Bool = false) -> String {
    guard code.count >= 6, code.count.isMultiple(of: 2), code.allSatisfy(\.isNumber) else { return code }
    return code.prefix(code.count / 2) + (wide ? "\u{2002}" : "\u{2009}") + code.suffix(code.count / 2)
}

/// Stands in for a code while the app is locked, so the digits are in no view or accessibility tree.
func hiddenCode(_ code: String) -> String { String(repeating: "•", count: code.count) }

/// A code as cards and rows draw it: SF Pro with tabular figures, open tracking.
struct CodeText: View {
    let code: String
    var size: CGFloat = 38
    var weight: Font.Weight = .semibold
    /// A dot in each digit's place, as Passwords hides a password until hover. Unlike a blur, dots carry nothing
    /// of the digits, and revealing the code moves nothing. Hide Codes Until Hover passes the code, for VoiceOver;
    /// a locked app passes `hiddenCode`, and looks the same.
    var concealed = false

    var body: some View {
        ZStack {
            if concealed {
                // Zeros that are never drawn hold each digit's width.
                let slots = groupedCode(String(code.map { $0.isLetter ? $0 : "0" }), wide: true)
                HStack(spacing: 0) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                        Text(String(slot)).hidden()
                            .overlay { if !slot.isWhitespace { Circle().frame(width: size * 0.3, height: size * 0.3) } }
                    }
                }
            } else {
                Text(groupedCode(code, wide: true))
            }
        }
        .animation(.easeOut(duration: 0.15), value: concealed)
        .font(.system(size: size, weight: weight).monospacedDigit())
        .tracking(size * 0.05)
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }
}
