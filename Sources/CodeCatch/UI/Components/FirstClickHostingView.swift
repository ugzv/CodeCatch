import AppKit
import SwiftUI

/// Buttons in a panel that never becomes key (the banner) must act on the
/// first click, without taking focus from the app the user is typing in.
final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
