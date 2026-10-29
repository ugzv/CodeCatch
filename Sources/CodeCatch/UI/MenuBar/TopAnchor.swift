import AppKit
import SwiftUI

/// MenuBarExtra's window grows with its content but never shrinks back (macOS 27), and
/// AppKit resizes it from the bottom-left: the popover kept its tallest size with the
/// content floating in the middle, and slid away from the menu bar. This sizes the window
/// to the content's `height`, keeping its top edge where it opened and on the display.
struct TopAnchor: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.fit(height) }

    final class AnchorView: NSView {
        private var top: CGFloat?
        private var height: CGFloat = 0
        private var observers: [NSObjectProtocol] = []
        private var placing = false

        func fit(_ height: CGFloat) {
            self.height = height.rounded(.up)  // the window has whole-point heights
            place()
        }

        /// AppKit lays out before it draws, so a corrected frame is never seen.
        override func layout() {
            super.layout()
            place()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The Space observer is on the workspace's center; a center without the token ignores it.
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            observers = []
            guard let window else { return }
            top = window.frame.maxY
            let center = NotificationCenter.default
            // Opening places the window under the menu bar: that is the edge to keep.
            observers.append(
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.top = self.window?.frame.maxY
                        self.place()
                    }
                })
            // A restored frame arrives without a resize, so moves are checked too.
            for name in [
                NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                NSApplication.didChangeScreenParametersNotification,
            ] {
                observers.append(
                    center.addObserver(
                        forName: name,
                        object: name == NSApplication.didChangeScreenParametersNotification ? nil : window,
                        queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self.map { $0.place() } }
                    })
            }
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self.map { $0.place() } }
                })
            place()
        }

        private func place() {
            // A closed popover is left alone: resizing it could fight SwiftUI's own sizing.
            guard !placing, height > 0, let window, window.isVisible else { return }
            let frame = window.frame
            var top = top ?? frame.maxY
            // A panel restored off the display has no screen; the menu bar is on the main one.
            if let screen = window.screen ?? NSScreen.main {
                top = max(top, screen.visibleFrame.minY + height)  // never below the Dock
                top = min(top, screen.frame.maxY)  // never above the top of the display, even if taller than it
            }
            guard frame.height != height || abs(frame.maxY - top) > 0.5 else { return }
            placing = true
            defer { placing = false }
            window.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
        }
    }
}
