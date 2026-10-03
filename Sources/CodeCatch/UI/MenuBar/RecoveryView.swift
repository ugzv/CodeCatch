import AppKit
import SwiftUI

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Local private var selectedID: UUID?
    @Local private var copied = false
    @Local private var unlockError: String?

    private var selected: RecoveryInbox.Entry? {
        model.recovery.entries.first { $0.id == selectedID } ?? model.recovery.entries.first
    }
    private var enabledAccounts: [MailAccount] { model.accounts.filter(\.enabled) }
    private var sourceKeys: [String] {
        enabledAccounts.map { $0.id.uuidString } + (model.monitoring(Prefs.appleMail) ? [AppleMailStore.sourceKey] : [])
    }
    private var checking: Bool { sourceKeys.contains { model.status[$0] == .connecting } }
    private var monitoringSummary: String {
        guard model.monitoring(Prefs.receivedCodes) else { return "Email monitoring paused" }
        let count = enabledAccounts.count
        let accounts = "\(count) email \(count == 1 ? "account" : "accounts")"
        if model.monitoring(Prefs.appleMail) {
            return count == 0 ? "Monitoring Apple Mail" : "Monitoring \(accounts) + Apple Mail"
        }
        return "Monitoring \(accounts)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Recent Emails").font(.title3.weight(.semibold))
                        SettingInfo(title: "Recent Emails") {
                            Text("Only emails from the last 30 minutes with verification-related wording appear here, when no code or sign-in link was detected. This is not your full inbox.")
                            Text("Detected codes and sign-in links appear in the main menu. Select a code in an email here and press ⌘C to copy it.")
                            Text("Up to 20 matching emails are kept in memory only. If nothing appears, request a new code and check again.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("Last 30 minutes").foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Button(monitoringSummary) { showSettings(.sources) }
                            .buttonStyle(.link)
                            .help("Open Sources to manage monitored email accounts")
                    }
                    .font(.caption)
                }
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button(action: refresh) {
                    Label(checking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(checking || sourceKeys.isEmpty || !model.monitoring(Prefs.receivedCodes))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Group {
                if !model.monitoring(Prefs.receivedCodes) {
                    notice("Verification code monitoring is off.") {
                        Button("Open Settings") { showSettings(.monitoring) }
                    }
                } else if !model.isUnlocked {
                    notice(unlockError ?? "Unlock to view recent emails.") {
                        Button(model.vaultSession.isBusy ? "Unlocking…" : "Unlock") {
                            unlockError = nil
                            Task {
                                do { try await model.vaultSession.unlock() }
                                catch { unlockError = error.localizedDescription }
                            }
                        }.disabled(model.vaultSession.isBusy)
                    }
                } else if enabledAccounts.isEmpty, !model.monitoring(Prefs.appleMail) {
                    notice("No email accounts enabled.") {
                        Button("Open Sources") { showSettings(.sources) }
                    }
                } else if model.recovery.entries.isEmpty {
                    notice(checking ? "Checking your inboxes…" : "No recent verification emails.") {
                        if let problem = enabledAccounts.first(where: { model.status[$0.id.uuidString]?.needsAttention == true }) {
                            Text("\(problem.label): \(model.status[problem.id.uuidString]?.summary ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Open Sources") { showSettings(.sources) }
                            .buttonStyle(.bordered)
                    }
                } else {
                    HStack(spacing: 0) {
                        List(selection: $selectedID) {
                            ForEach(model.recovery.entries) { entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.message.senderName.isEmpty ? entry.message.senderID : entry.message.senderName)
                                        .font(.headline).lineLimit(1)
                                    Text(entry.message.subject ?? "Email message")
                                        .font(.callout).lineLimit(2)
                                    Text("\(entry.message.sourceLabel) · \(entry.message.date.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 7)
                                .tag(entry.id)
                            }
                        }
                        .listStyle(.sidebar)
                        .frame(width: 210)
                        Divider()
                        if let selected { detail(selected) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                BrandHeading()
                Spacer()
            }
            .bottomBar()
        }
        .frame(minWidth: 660, minHeight: 430)
        .background(.background)
        .background(RecoveryWindowPrivacy(protect: model.monitoring(Prefs.hideFromCapture)))
        .onAppear {
            refresh()
            selectedID = selected?.id
        }
        .onChange(of: selected?.id) { _, id in selectedID = id; copied = false }
    }

    private func notice<Actions: View>(_ message: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            Text(message).foregroundStyle(.secondary)
            actions().buttonStyle(.bordered)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ entry: RecoveryInbox.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.message.subject ?? "Email message").font(.headline).lineLimit(3)
            Text(entry.message.senderID).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Divider()
            RecoveryMessageText(text: entry.message.text) { text in copy(text, from: entry.id) }
                .id(entry.id)
            if entry.truncated {
                Text("Long message shortened. Open your mail app to read the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(copied ? "Copied" : "Select the code, then ⌘C")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer()
                Button("Copy Message") { _ = copy(entry.message.fullText, from: entry.id) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func showSettings(_ tab: SettingsTab) {
        tab.select()
        NSApp.activate()
        openSettings()
    }
    private func refresh() {
        model.recovery.prune()
        guard model.monitoring(Prefs.receivedCodes) else { return }
        sourceKeys.forEach(model.monitor.check)
    }
    private func copy(_ text: String, from id: UUID) -> Bool {
        copied = model.copyRecoveryText(text, from: id)
        if !copied { NSSound.beep() }
        return copied
    }
}

private struct RecoveryWindowPrivacy: NSViewRepresentable {
    let protect: Bool
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) { view.protect = protect }
    final class View: NSView {
        var protect = true { didSet { apply() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        private func apply() { window?.sharingType = protect ? .none : .readOnly }
    }
}

/// Native selection with the same local-only, concealed clipboard as detected codes.
private struct RecoveryMessageText: NSViewRepresentable {
    let text: String
    let onCopy: (String) -> Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = MessageTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.setAccessibilityLabel("Email message")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MessageTextView else { return }
        if view.string != text { view.string = text }
        view.onCopy = onCopy
    }

    private final class MessageTextView: NSTextView {
        var onCopy: (String) -> Bool = { _ in false }
        override func copy(_ sender: Any?) {
            guard selectedRange().length > 0 else { return }
            _ = onCopy((string as NSString).substring(with: selectedRange()))
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "").target = self
            return menu
        }
        override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack slideFlag: Bool) -> Bool { false }
        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? { nil }
    }
}
