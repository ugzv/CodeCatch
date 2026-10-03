#if DEBUG
import AppKit
import SwiftUI

/// Isolated UI fixture: no real mail, credentials, settings or clipboard access.
@MainActor
enum RecoveryPreview {
    static func run() {
        let defaults = UserDefaults(suiteName: "CodeCatch.RecoveryPreview.\(UUID())")!
        Prefs.register(in: defaults)
        defaults.set(false, forKey: Prefs.hideFromCapture)
        defaults.set(false, forKey: Prefs.messages)
        let session = VaultSession(authenticate: {}, read: { [] }, write: { _ in }, remove: {})
        let account = MailAccount(label: "Work", host: "mail.example.com", user: "you@example.com")
        let monitor = SourceMonitor(watchMail: { _, callbacks in callbacks.status(.live) }, hasCredential: { _ in true }, defaults: defaults)
        let model = AppModel(vaultSession: session, monitor: monitor, search: CodeSearch(defaults: defaults), defaults: defaults,
                             accounts: [account], copyToClipboard: { _, _ in })
        model.recovery.onRemove = { _ in }
        func populate() {
            for (index, sender) in ["Acme", "Example Workspace"].enumerated() {
                model.ingest(IncomingMessage(text: "Hello from \(sender),\n\nEnter these characters to finish signing in:\n\n4 · 8 · 2 · 9 · 1 · 3\n\nThis code expires in 10 minutes.\nIf you did not request it, you can ignore this email.",
                    subject: "Your verification code", senderName: sender, senderID: "security@example.com",
                    sourceKey: account.id.uuidString, sourceLabel: account.label,
                    date: Date().addingTimeInterval(-Double(300 + index * 60)), isMail: true, messageID: "preview-\(index)"))
            }
        }
        populate()
        monitor.restartMail([account])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        menu.addItem(item)
        app.mainMenu = menu
        let view = VStack(spacing: 0) {
            RecoveryView(model: model)
            Divider()
            HStack {
                Text("Isolated preview").foregroundStyle(.secondary)
                Button("Lock") { session.lock() }
                Button("Empty") { model.recovery.removeAll() }
                Button("Populate", action: populate)
            }.font(.caption).padding(8)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 462),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "CodeCatch Recovery Preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        app.run()
    }
}
#endif
