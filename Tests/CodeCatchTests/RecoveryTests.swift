import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

@MainActor private final class RecoveryFixture {
    let suite = "RecoveryTests.\(UUID())"
    let defaults: UserDefaults
    let session: VaultSession
    private(set) var copied: [String] = []
    var model: AppModel!

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        for key in ["messagesEnabled", "showHUD", "autoCopy", "sound"] {
            defaults.set(false, forKey: key)
        }
        Prefs.register(in: defaults)
        session = VaultSession(authenticate: {}, read: { [] }, write: { _ in }, remove: {})
        model = makeModel()
    }

    func makeModel() -> AppModel {
        let monitor = SourceMonitor(watchMail: { _, _ in }, hasCredential: { _ in false }, defaults: defaults)
        return AppModel(vaultSession: session, monitor: monitor, search: CodeSearch(defaults: defaults),
                        defaults: defaults, accounts: [], copyToClipboard: { [weak self] value, _ in self?.copied.append(value) })
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private func missedCode(date: Date = Date(), id: String = "mail-1", source: String = "test-mail",
                        sender: String = "login@example.invalid") -> IncomingMessage {
    IncomingMessage(text: "Your verification code: 4 · 8 · 2 · 9 · 1 · 3",
                    subject: "Verify your sign-in", senderName: "Example", senderID: sender,
                    sourceKey: source, sourceLabel: "Test", date: date, isMail: true, messageID: id)
}

@MainActor @Suite struct RecoveryTests {
    @Test func missedMailStaysOutOfMainListAndNeverAutoCopies() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "autoCopy")
        try await fixture.session.unlock()
        let message = missedCode()
        #expect(CodeExtractor.code(in: message.fullText) == nil)

        fixture.model.ingest(message)

        #expect(fixture.model.items.isEmpty)
        #expect(fixture.model.recovery.entries.count == 1)
        #expect(fixture.copied.isEmpty)
    }

    @Test func recoveryDoesNotBecomeAGeneralInboxOrDuplicateDetectedCodesAndLinks() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        var unrelated = missedCode(id: "newsletter")
        unrelated.subject = "A walk through the forest"
        unrelated.text = "Enjoy the trees and sunshine."
        var sms = missedCode(id: "sms")
        sms.isMail = false
        var detectedCode = missedCode(id: "detected-code")
        detectedCode.text = "Your verification code is 482913."
        var detectedLink = missedCode(id: "detected-link")
        detectedLink.text = "Confirm your sign-in."
        detectedLink.links = [MailLink(url: "https://example.invalid/verify?token=example", label: "Confirm sign-in")]

        for var message in [unrelated, sms, detectedCode, detectedLink] {
            message.date = Date().addingTimeInterval(-300)  // Backfill must not exercise real banners or sounds.
            fixture.model.ingest(message)
        }

        #expect(fixture.model.recovery.entries.isEmpty)
        #expect(fixture.model.items.contains { !$0.code.isEmpty })
        #expect(fixture.model.items.contains { $0.link != nil })
    }

    @Test func disablingLinkMonitoringDoesNotTurnDetectedLinksIntoMissedCodes() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.model.setMonitoring(Prefs.signInLinks, enabled: false)
        var message = missedCode()
        fixture.model.ingest(message)
        #expect(fixture.model.recovery.entries.count == 1)
        message.text = "Confirm your sign-in."
        message.links = [MailLink(url: "https://example.invalid/verify?token=example", label: "Confirm sign-in")]
        fixture.model.ingest(message)
        #expect(fixture.model.items.isEmpty)
        #expect(fixture.model.recovery.entries.isEmpty)
    }

    @Test func repeatedDeliveryKeepsIdentityButDifferentAccountsRemainDistinct() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = missedCode()
        fixture.model.ingest(message)
        let firstID = try #require(fixture.model.recovery.entries.first?.id)
        fixture.model.ingest(message)
        #expect(fixture.model.recovery.entries.map(\.id) == [firstID])
        fixture.model.ingest(missedCode(source: "other-mail"))
        #expect(fixture.model.recovery.entries.count == 2)
        #expect(fixture.model.recovery.entries.contains { $0.id == firstID })
    }

    @Test func oldMessagesCannotEnterRecoveryAndPruningExpiresRetainedBodies() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let now = Date()
        fixture.model.ingest(missedCode(date: now.addingTimeInterval(-1_801), id: "old"))
        #expect(fixture.model.recovery.entries.isEmpty)
        fixture.model.ingest(missedCode(date: now))
        #expect(fixture.model.recovery.entries.count == 1)
        fixture.model.recovery.prune(at: now.addingTimeInterval(1_801))
        #expect(fixture.model.recovery.entries.isEmpty)
    }

    @Test func recoveryBoundsMessageCountAndBodySizeWithoutPersistingRawMail() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let now = Date()
        for index in 0..<25 {
            fixture.model.ingest(missedCode(date: now.addingTimeInterval(Double(index - 25)), id: "mail-\(index)"))
        }
        #expect(fixture.model.recovery.entries.count == 20)
        #expect(!fixture.model.recovery.entries.contains { $0.message.messageID == "mail-0" })
        var long = missedCode(id: "large-body")
        long.text += String(repeating: " Ordinary message text.", count: 1_000)
        fixture.model.recovery.record(long)
        let retained = try #require(fixture.model.recovery.entries.first { $0.message.messageID == "large-body" })
        #expect(retained.message.text.count <= 16_000)
        #expect(fixture.model.recovery.entries.count == 20)
        #expect(fixture.makeModel().recovery.entries.isEmpty)
        #expect(!String(describing: fixture.defaults.persistentDomain(forName: fixture.suite)).contains("4 · 8 · 2 · 9 · 1 · 3"))
    }

    @Test func copyRequiresUnlockedCurrentEntryAndTextActuallyPresentInMessage() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.model.ingest(missedCode())
        let entry = try #require(fixture.model.recovery.entries.first)
        let selection = "4 · 8 · 2 · 9 · 1 · 3"
        #expect(!fixture.model.copyRecoveryText(selection, from: entry.id))
        #expect(fixture.copied.isEmpty)
        try await fixture.session.unlock()
        #expect(!fixture.model.copyRecoveryText(selection, from: UUID()))
        #expect(!fixture.model.copyRecoveryText("", from: entry.id))
        #expect(!fixture.model.copyRecoveryText("unrelated clipboard injection", from: entry.id))
        #expect(fixture.copied.isEmpty)
        #expect(fixture.model.copyRecoveryText(selection, from: entry.id))
        #expect(fixture.copied == [selection])
        fixture.session.lock()
        #expect(!fixture.model.copyRecoveryText(selection, from: entry.id))
        #expect(fixture.copied.count == 1)
    }

    @Test func expiredSelectionCannotCopyEvenBeforeTheViewPrunes() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = missedCode()
        fixture.model.ingest(message)
        let id = try #require(fixture.model.recovery.entries.first?.id)
        try await fixture.session.unlock()
        #expect(!fixture.model.copyRecoveryText(message.text, from: id, at: message.date.addingTimeInterval(1_801)))
        #expect(fixture.copied.isEmpty)
    }

    @Test func disablingCodesClearsRecoveryAndRejectsBothCallbacksAndRetainedSelections() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = missedCode()
        fixture.model.ingest(message)
        let id = try #require(fixture.model.recovery.entries.first?.id)
        try await fixture.session.unlock()
        fixture.model.setMonitoring(Prefs.receivedCodes, enabled: false)
        fixture.model.ingest(message)
        #expect(fixture.model.recovery.entries.isEmpty)
        #expect(!fixture.model.copyRecoveryText(message.text, from: id))
        #expect(fixture.copied.isEmpty)
    }

    @Test func clearingHistoryRejectsRetainedSelectionsAndOldMailRedelivery() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = missedCode(date: Date().addingTimeInterval(-5))
        fixture.model.ingest(message)
        let id = try #require(fixture.model.recovery.entries.first?.id)
        fixture.model.clearHistory()
        fixture.model.ingest(message)
        #expect(fixture.model.recovery.entries.isEmpty)
        try await fixture.session.unlock()
        #expect(!fixture.model.copyRecoveryText(message.text, from: id))
        #expect(fixture.copied.isEmpty)
    }

    @Test func purgingOneSourceOrIgnoredSenderPreservesOtherCandidates() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.model.ingest(missedCode(id: "first", source: "first-source", sender: "first@example.invalid"))
        fixture.model.ingest(missedCode(id: "second", source: "second-source", sender: "second@example.invalid"))
        fixture.model.ingest(missedCode(id: "third", source: "second-source", sender: "third@example.invalid"))
        fixture.model.recovery.remove(sourceKey: "first-source")
        #expect(fixture.model.recovery.entries.count == 2)
        #expect(!fixture.model.recovery.entries.contains { $0.message.sourceKey == "first-source" })
        fixture.model.recovery.remove(ignored: "second@example.invalid")
        #expect(fixture.model.recovery.entries.map(\.message.messageID) == ["third"])
    }

    /// Ignoring a domain takes its addresses' candidates with it and keeps earlier choices; an address under it then adds nothing.
    @Test func ignoringADomainCoversItsAddresses() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.model.ingest(missedCode(id: "covered", sender: "login@mail.example.invalid"))
        fixture.model.ingest(missedCode(id: "other", sender: "login@other.invalid"))
        fixture.model.ignore("Login@Example.invalid")
        fixture.model.ignore("example.invalid")
        fixture.model.ignore("security@example.invalid")
        #expect(fixture.model.ignoredSenders == ["login@example.invalid", "example.invalid"])
        #expect(fixture.model.recovery.entries.map(\.message.messageID) == ["other"])
        fixture.model.ingest(missedCode(id: "later", sender: "noreply@example.invalid"))
        #expect(fixture.model.recovery.entries.map(\.message.messageID) == ["other"])
    }

    /// Ignored senders must not come back after a relaunch or an upgrade from the old exact-sender format.
    @Test func ignoredSendersSurviveRelaunchAndLegacyUpgrade() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(["login@example.invalid"], forKey: "ignoredSenders")
        fixture.model = fixture.makeModel()
        #expect(fixture.model.ignoredSenders == ["login@example.invalid"])
        fixture.model.ingest(missedCode(id: "legacy", sender: "login@example.invalid"))
        fixture.model.ingest(missedCode(id: "kept", sender: "other@example.invalid"))
        #expect(fixture.model.recovery.entries.map(\.message.messageID) == ["kept"])

        fixture.model.ignore("acme.invalid")
        #expect(fixture.makeModel().ignoredSenders == ["login@example.invalid", "acme.invalid"])
        fixture.model.stopIgnoring(["login@example.invalid"])
        let reloaded = fixture.makeModel()
        #expect(reloaded.ignoredSenders == ["acme.invalid"])
    }
}
