import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

@MainActor private final class PreferenceFixture {
    let suite = "PreferenceIsolationTests.\(UUID())"
    let defaults: UserDefaults
    private(set) var copied: [String] = []
    private(set) var typed: [String] = []

    init(historyDays: Int = 7, autoCopy: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        for key in ["messagesEnabled", "showHUD", "sound", Prefs.autoType] {
            defaults.set(false, forKey: key)
        }
        defaults.set(historyDays, forKey: "historyDays")
        defaults.set(autoCopy, forKey: "autoCopy")
        Prefs.register(in: defaults)
    }

    func makeModel() -> AppModel {
        let session = VaultSession(authenticate: {}, read: { [] }, write: { _ in }, remove: {})
        let monitor = SourceMonitor(watchMail: { _, _ in }, hasCredential: { _ in false }, defaults: defaults)
        return AppModel(vaultSession: session, monitor: monitor, search: CodeSearch(defaults: defaults),
                        defaults: defaults,
                        copyToClipboard: { [weak self] value, _ in self?.copied.append(value) },
                        typeCode: { [weak self] value in self?.typed.append(value) })
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private func preferenceMessage(age: TimeInterval) -> IncomingMessage {
    IncomingMessage(text: "Your verification code is 482913.", senderName: "Example",
                    senderID: "support@example.com", sourceKey: "preference-test-mail", sourceLabel: "Test",
                    date: Date().addingTimeInterval(-age), isMail: true)
}

@MainActor @Suite struct PreferenceIsolationTests {
    @Test(arguments: [1, 7])
    func ingestionUsesInjectedHistoryLimitToRejectOrRetainTwoDayOldCode(historyDays: Int) throws {
        let fixture = try PreferenceFixture(historyDays: historyDays)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()

        model.ingest(preferenceMessage(age: 2 * 24 * 60 * 60))

        #expect(model.items.contains { $0.code == "482913" } == (historyDays == 7))
    }

    @Test(arguments: [false, true])
    func unlockingCopiesReceivedCodeOnlyWhenInjectedAutoCopyIsEnabled(autoCopy: Bool) async throws {
        let fixture = try PreferenceFixture(autoCopy: autoCopy)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.ingest(preferenceMessage(age: 0))
        #expect(model.items.contains { $0.code == "482913" })
        #expect(fixture.copied.isEmpty)

        try await model.unlock()

        #expect(fixture.copied == (autoCopy ? ["482913"] : []))
        #expect(fixture.typed.isEmpty)
    }

    @Test func savedAccountsReloadOnlyFromTheirOwnInjectedDefaults() throws {
        let first = try PreferenceFixture()
        defer { first.cleanUp() }
        let second = try PreferenceFixture()
        defer { second.cleanUp() }
        let firstModel = first.makeModel()
        let secondModel = second.makeModel()
        #expect(firstModel.accounts.isEmpty)
        #expect(secondModel.accounts.isEmpty)

        firstModel.save(MailAccount(label: "First", host: "first.example.com", user: "first@example.com"))
        #expect(first.makeModel().accounts.map(\.user) == ["first@example.com"])
        #expect(second.makeModel().accounts.isEmpty)

        secondModel.save(MailAccount(label: "Second", host: "second.example.com", user: "second@example.com"))
        #expect(first.makeModel().accounts.map(\.user) == ["first@example.com"])
        #expect(second.makeModel().accounts.map(\.user) == ["second@example.com"])
    }
}
