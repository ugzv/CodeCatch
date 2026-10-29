import AppKit
import SwiftUI
import Testing

@testable import CodeCatch
@testable import CodeCatchCore

/// Hovering a hidden code moved every row below it: the row dropped its preview line while the code was hidden (#10).
/// From Parichay Agrawal's test in #18.
@MainActor @Test func hidingACodeKeepsItsRowsHeight() async throws {
    let session = VaultSession(authenticate: {}, read: { [] }, write: { _ in }, remove: {})
    try await session.unlock()
    AppModel.shared = AppModel(vaultSession: session, monitor: SourceMonitor(watchMail: { _, _ in }, hasCredential: { _ in false }), accounts: [])
    let message = IncomingMessage(
        text: "OTP is 343106 for txn of INR 273.00 at SWIGGY. Do not share.", senderName: "SWIGGY", senderID: "AX-SWIGGY",
        sourceKey: MessagesStore.sourceKey, sourceLabel: "Messages", date: Date(), isMail: false)
    let item = try #require(CodeItem(message, code: "343106", link: nil))

    let shown = try rowHeight(item, hidden: false, previews: true)
    let bare = try rowHeight(item, hidden: false, previews: false)
    let hidden = try rowHeight(item, hidden: true, previews: true)
    #expect(shown > bare, "no preview line, so nothing to keep")
    #expect(hidden == shown)
}

@MainActor private func rowHeight(_ item: CodeItem, hidden: Bool, previews: Bool) throws -> CGFloat {
    let suite = "RowLayoutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(hidden, forKey: Prefs.blurCodes)
    defaults.set(previews, forKey: Prefs.showPreviews)
    return NSHostingView(rootView: RowHost(item: item).frame(width: 380).defaultAppStorage(defaults)).fittingSize.height
}

private struct RowHost: View {
    let item: CodeItem
    @Namespace private var selection
    var body: some View { CodeRow(item: item, selection: selection) }
}
