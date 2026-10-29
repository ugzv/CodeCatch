import AppKit
import Testing

@testable import CodeCatch

/// A closed popover kept resizing against SwiftUI's own sizing forever, at 60% CPU; opening it must still fit it.
@MainActor @Test func popoverFitsOnlyWhileOpen() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 420, height: 354), styleMask: .borderless, backing: .buffered, defer: true)
    let anchor = TopAnchor.AnchorView()
    window.contentView?.addSubview(anchor)
    let top = window.frame.maxY

    anchor.fit(300)
    #expect(window.frame.height == 354)

    window.orderFront(nil)
    defer { window.orderOut(nil) }
    anchor.fit(300)
    #expect(window.frame.height == 300)
    #expect(window.frame.maxY == top)
}

/// With the menu bar hidden the popover opened above the display, out of view (AppKit itself pulls in a window
/// that is partly on the screen, so only one wholly off it shows the bug here). One taller than the space above
/// the Dock was pushed up past the top too, its header and search field cut off.
@MainActor @Test(arguments: [false, true]) func popoverTopStaysOnScreen(taller: Bool) throws {
    let screen = try #require(NSScreen.main)
    let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY + 500, width: 420, height: 354)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
    let anchor = TopAnchor.AnchorView()
    window.contentView?.addSubview(anchor)
    let height = taller ? (screen.visibleFrame.height + 100).rounded(.up) : 300

    window.orderFront(nil)
    defer { window.orderOut(nil) }
    anchor.fit(height)
    #expect(window.frame.height == height)
    #expect(window.frame.maxY <= screen.frame.maxY)
}
