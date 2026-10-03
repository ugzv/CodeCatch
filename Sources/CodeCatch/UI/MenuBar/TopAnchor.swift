import AppKit
import SwiftUI

/// MenuBarExtra's window grows with its content but never shrinks back (macOS 27), and
/// AppKit resizes it from the bottom-left: the popover kept its tallest size with the
/// content floating in the middle, and slid away from the menu bar. This sizes the window
/// to the content's `height`, keeping its top edge where it opened.
struct TopAnchor: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.fit(height) }

    final class AnchorView: NSView {
        private var top: CGFloat?
        private var height: CGFloat = 0
        private var observers: [NSObjectProtocol] = []

        func fit(_ height: CGFloat) {
            let height = height.rounded(.up)  // the window has whole-point heights
            self.height = height
            guard let window, let top, height > 0, window.frame.height != height || window.frame.maxY != top else { return }
            window.setFrame(NSRect(x: window.frame.minX, y: top - height, width: window.frame.width, height: height), display: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            top = window.frame.maxY
            let center = NotificationCenter.default
            // Opening places the window under the menu bar: that is the edge to keep.
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.top = self.window?.frame.maxY
                    self.fit(self.height)
                }
            })
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self.map { $0.fit($0.height) } }
            })
        }
    }
}
