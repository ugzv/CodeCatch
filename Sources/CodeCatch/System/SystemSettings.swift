import AppKit

enum SystemSettings {
    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    /// The pane has no "add this app" button for us to press, so also reveal the
    /// app in Finder: dragging it into the list is the quickest way to grant access.
    static func fullDiskAccess() {
        open("Privacy_AllFiles")
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    static func accessibility() { open("Privacy_Accessibility") }
}
