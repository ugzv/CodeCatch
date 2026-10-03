import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

private enum AccountRemovalFailure: Error { case denied }

@MainActor private final class AccountRemovalFixture {
    let suite = "MailAccountRemovalTests.\(UUID())"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "messagesEnabled")
    }

    func makeModel() -> AppModel {
        let session = VaultSession(authenticate: {}, read: { [] }, write: { _ in }, remove: {})
        let monitor = SourceMonitor(watchMail: { _, _ in }, hasCredential: { _ in false }, defaults: defaults)
        return AppModel(vaultSession: session, monitor: monitor, defaults: defaults,
                        copyToClipboard: { _, _ in })
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor @Suite struct MailAccountRemovalTests {
    @Test func changedCallerFieldsCannotDeleteAnotherAccountsCredentials() throws {
        let fixture = try AccountRemovalFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let saved = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        let other = MailAccount(label: "Personal", host: "personal.example.com", user: "personal@example.com")
        model.save(saved)
        model.save(other)
        var supplied = saved
        supplied.host = other.host
        supplied.user = other.user
        var removed: [String] = []

        try model.remove(supplied, removeSecret: { key in
            #expect(Set(model.accounts.map(\.id)) == Set([saved.id, other.id]))
            removed.append(key)
        })

        #expect(removed.count == 2)
        #expect(Set(removed) == Set([saved.secretKey, saved.refreshTokenKey]))
        #expect(model.accounts.map(\.id) == [other.id])
        #expect(fixture.makeModel().accounts.map(\.id) == [other.id])
    }

    @Test func unknownIDCannotDeleteMatchingCredentialsOrSavedMetadata() throws {
        let fixture = try AccountRemovalFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let saved = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        model.save(saved)
        var unknown = saved
        unknown.id = UUID()
        var removed: [String] = []

        try model.remove(unknown, removeSecret: { removed.append($0) })

        #expect(removed.isEmpty)
        #expect(model.accounts.map(\.id) == [saved.id])
        #expect(fixture.makeModel().accounts.map(\.id) == [saved.id])
    }

    @Test func removingOneAccountPreservesCredentialsSharedByAnotherAccount() throws {
        let fixture = try AccountRemovalFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let first = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        var second = first
        second.id = UUID()
        second.label = "Also work"
        model.save(first)
        model.save(second)
        var removed: [String] = []

        try model.remove(first, removeSecret: { removed.append($0) })

        #expect(removed.isEmpty)
        #expect(model.accounts.map(\.id) == [second.id])
        #expect(fixture.makeModel().accounts.map(\.id) == [second.id])

        try model.remove(second, removeSecret: { removed.append($0) })
        #expect(removed.count == 2)
        #expect(Set(removed) == Set([second.secretKey, second.refreshTokenKey]))
        #expect(fixture.makeModel().accounts.isEmpty)
    }

    @Test(arguments: [1, 2])
    func credentialDeletionFailurePreservesAccountForRetry(failingCall: Int) throws {
        let fixture = try AccountRemovalFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let saved = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        model.save(saved)
        var attempted: [String] = []

        do {
            try model.remove(saved, removeSecret: { key in
                attempted.append(key)
                if attempted.count == failingCall { throw AccountRemovalFailure.denied }
            })
            Issue.record("Credential deletion failure must propagate")
        } catch AccountRemovalFailure.denied {
        }

        #expect(attempted.count == failingCall)
        #expect(model.accounts.map(\.id) == [saved.id])
        #expect(fixture.makeModel().accounts.map(\.id) == [saved.id])

        var retried: [String] = []
        try model.remove(saved, removeSecret: { retried.append($0) })
        #expect(retried.count == 2)
        #expect(Set(retried) == Set([saved.secretKey, saved.refreshTokenKey]))
        #expect(model.accounts.isEmpty)
        #expect(fixture.makeModel().accounts.isEmpty)
    }

    @Test(arguments: [false, true])
    func unusedCredentialCleanupPreservesSecretsReferencedByAnySavedAccount(differentID: Bool) throws {
        let fixture = try AccountRemovalFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let original = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        var saved = original
        if differentID { saved.id = UUID() }
        model.save(saved)
        var removed: [String] = []

        try model.removeUnusedCredentials(for: original, removeSecret: { removed.append($0) })

        #expect(removed.isEmpty)
        #expect(model.accounts.map(\.id) == [saved.id])
        #expect(model.accounts.map(\.secretKey) == [saved.secretKey])
        #expect(fixture.makeModel().accounts.map(\.id) == [saved.id])
    }

    @Test func identityChangeCleansOnlyOriginalCredentialsAndPreservesSavedReplacement() throws {
        let fixture = try AccountRemovalFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let original = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        model.save(original)
        var edited = original
        edited.host = "new.example.com"
        edited.user = "new@example.com"
        edited.label = "New work"
        model.save(edited)
        var removed: [String] = []

        try model.removeUnusedCredentials(for: original, removeSecret: { key in
            #expect(model.accounts.map(\.id) == [edited.id])
            #expect(model.accounts.map(\.secretKey) == [edited.secretKey])
            removed.append(key)
        })

        #expect(removed.count == 2)
        #expect(Set(removed) == Set([original.secretKey, original.refreshTokenKey]))
        let reloaded = fixture.makeModel()
        for snapshot in [model, reloaded] {
            #expect(snapshot.accounts.map(\.id) == [edited.id])
            #expect(snapshot.accounts.map(\.host) == [edited.host])
            #expect(snapshot.accounts.map(\.user) == [edited.user])
            #expect(snapshot.accounts.map(\.label) == [edited.label])
        }
    }

    @Test(arguments: [1, 2])
    func unusedCredentialCleanupFailureCannotRollBackSavedIdentity(failingCall: Int) throws {
        let fixture = try AccountRemovalFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let original = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        model.save(original)
        var edited = original
        edited.host = "new.example.com"
        edited.user = "new@example.com"
        edited.label = "New work"
        model.save(edited)
        var attempted: [String] = []

        do {
            try model.removeUnusedCredentials(for: original, removeSecret: { key in
                attempted.append(key)
                if attempted.count == failingCall { throw AccountRemovalFailure.denied }
            })
            Issue.record("Unused credential deletion failure must propagate")
        } catch AccountRemovalFailure.denied {
        }

        #expect(attempted.count == failingCall)
        #expect(Set(attempted).isSubset(of: Set([original.secretKey, original.refreshTokenKey])))
        let reloaded = fixture.makeModel()
        for snapshot in [model, reloaded] {
            #expect(snapshot.accounts.map(\.id) == [edited.id])
            #expect(snapshot.accounts.map(\.host) == [edited.host])
            #expect(snapshot.accounts.map(\.user) == [edited.user])
            #expect(snapshot.accounts.map(\.label) == [edited.label])
        }
    }
}
