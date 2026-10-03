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
