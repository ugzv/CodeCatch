import AppKit

/// Opens the menu-bar popover from a shortcut or a codecatch://search link, as if its
/// icon were clicked (SwiftUI's MenuBarExtra has no API for it).
@MainActor
enum MenuBarPopover {
    /// `retries`: a codecatch:// link can launch the app and arrive before the status item exists.
    static func open(query: String = "", retries: Int = 10) {
        AppModel.shared.searchRequest = query
        guard !NSApp.windows.contains(where: { $0.className.contains("MenuBarExtraWindow") && $0.isVisible }) else { return }
        // Only the status bar window has this key; asking any other window raises.
        let statusItem = NSApp.windows.lazy.filter { $0.className == "NSStatusBarWindow" && $0.responds(to: NSSelectorFromString("statusItem")) }
            .compactMap { $0.value(forKey: "statusItem") as? NSStatusItem }.first
        guard let statusItem else {
            if retries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { open(query: query, retries: retries - 1) } }
            return
        }
        NSApp.activate()
        // macOS 27+: SwiftUI shows the window when AppKit begins an "expanded interface session"
        // (SPI; the button has no target/action any more). Its timestamp argument debounces
        // re-opening; the largest one always passes. Earlier macOS: click the button.
        let begin = NSSelectorFromString("_beginExpandedInterfaceSession:")
        if statusItem.responds(to: begin), let implementation = statusItem.method(for: begin) {
            typealias Begin = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
            unsafeBitCast(implementation, to: Begin.self)(statusItem, begin, .greatestFiniteMagnitude)
        } else {
            statusItem.button?.performClick(nil)
        }
    }

    /// `codecatch://search?q=github`: for launchers (a Raycast or Alfred quicklink).
    static func handle(_ url: URL) {
        guard url.scheme == "codecatch" else { return }
        open(query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? "")
    }
}
