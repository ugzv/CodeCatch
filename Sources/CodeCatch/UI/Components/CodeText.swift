import AppKit
import SwiftUI

/// "482 913" / "4829 1365": halves split by a thin space, like Passwords shows them.
func groupedCode(_ code: String, wide: Bool = false) -> String {
    guard code.count >= 6, code.count.isMultiple(of: 2), code.allSatisfy(\.isNumber) else { return code }
    return code.prefix(code.count / 2) + (wide ? "\u{2002}" : "\u{2009}") + code.suffix(code.count / 2)
}

/// Stands in for a code while the app is locked, so the digits are in no view or accessibility tree.
func hiddenCode(_ code: String) -> String { String(repeating: "•", count: code.count) }

/// The code as the hero: SF Pro with tabular figures, open tracking.
struct CodeText: View {
    let code: String
    var size: CGFloat = 38
    var concealed = false

    var body: some View {
        Text(groupedCode(code, wide: true))
            .font(.system(size: size, weight: .semibold).monospacedDigit())
            .blur(radius: concealed ? size * 0.2 : 0)
            .animation(.easeOut(duration: 0.15), value: concealed)
            .tracking(size * 0.05)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }
}
