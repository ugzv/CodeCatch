import AppKit
@testable import CodeCatchCore
import Testing
@testable import CodeCatch

private func message(_ text: String, at date: Date) -> IncomingMessage {
    IncomingMessage(text: text, senderName: "Example", senderID: "sender@example.com",
                    sourceKey: "account", sourceLabel: "Test", date: date, isMail: true)
}

@Test func dismissalsDistinguishMessagesEvenFromTheSameSenderAndSecond() {
    var first = message("Your code is 482913", at: Date(timeIntervalSince1970: 1_700_000_000))
    first.messageID = "101"
    var second = first
    second.messageID = "102"
    #expect(CodeItem(first, code: "482913", link: nil).dismissKey != CodeItem(second, code: "482913", link: nil).dismissKey)
}

@Test func dismissalDoesNotPersistCodesOrSignInTokens() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let code = CodeItem(message("Your code is 482913", at: date), code: "482913", link: nil)
    let link = CodeItem(message("Sign in", at: date), code: nil, link: URL(string: "https://example.com/login?token=private-token")!)
    #expect(!code.dismissKey.contains(code.code))
    #expect(!link.dismissKey.contains("private-token"))
    #expect(code.dismissKey == CodeItem(message("Your code is 482913", at: date), code: "482913", link: nil).dismissKey)
}

@Test(arguments: [(90.0, false), (30.0, false), (29.0, true), (-1.0, true)])
func expiredCodesDoNotTriggerAutomaticCopyWhileClockSkewStillWorks(age: TimeInterval, expected: Bool) {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let item = CodeItem(message("Your code is 482913. Valid for 30 seconds.", at: now.addingTimeInterval(-age)), code: "482913", link: nil)
    #expect(item.shouldAnnounce(at: now) == expected)
}

@Suite(.serialized) struct ClipboardTests {
    @Test @MainActor func rotatedTOTPDoesNotClaimThePreviousCodeIsCopied() throws {
        let vault = VaultCode(id: UUID().uuidString, name: "Example", username: nil, domain: nil,
                              secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let previous = try #require(CodeItem(vault, at: Date(timeIntervalSince1970: 59)))
        let current = try #require(CodeItem(vault, at: Date(timeIntervalSince1970: 60)))
        #expect(previous.code != current.code)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        Clipboard.copy(previous.code, id: previous.id, pasteboard: pasteboard)
        #expect(Clipboard.holds(previous, pasteboard: pasteboard))
        #expect(!Clipboard.holds(current, pasteboard: pasteboard))
        Clipboard.copy(current.code, id: current.id, pasteboard: pasteboard)
        #expect(Clipboard.holds(current, pasteboard: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("unrelated", forType: .string)
        #expect(!Clipboard.holds(current, pasteboard: pasteboard))
    }
}

/// What the card says about the link: nothing on the sender's own site, a warning when the site differs or
/// the sender can't be read (lookalike, port, empty), and only a calm note when the mail server verified it.
@Test(arguments: [
    ("team@notion.so", "https://www.notion.so/login", nil as Bool?, nil as Bool?), ("team@notion.so", "https://evil.com/login", nil, true),
    ("team@nоtion.so", "https://evil.com/login", nil, true), ("team@evil.com:8443", "https://evil.com/login", nil, true),
    ("", "https://evil.com/login", nil, true),
    // The scanner's destination is what counts.
    ("team@notion.so", "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.notion.so%2Flogin", nil, nil),
    ("team@notion.so", "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fevil.com%2Flogin", nil, true),
    // Verified: another site is the sender's own choice, said calmly. Failed: never a pass, even on its own domain.
    ("team@notion.so", "https://notion-static.com/login", true, false), ("team@notion.so", "https://sites.notion.so/evil-login", false, true),
])
func linkNotice(sender: String, link: String, verified: Bool?, warns: Bool?) {
    var mail = IncomingMessage(text: "Sign in", senderName: "Notion", senderID: sender, sourceKey: "account", sourceLabel: "Test",
                               date: Date(timeIntervalSince1970: 1_700_000_000), isMail: true)
    mail.senderVerified = verified
    #expect(CodeItem(mail, code: nil, link: URL(string: link)!).linkNotice?.warns == warns)
}
