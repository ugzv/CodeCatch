import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

private enum AccountSaveFailure: Error { case denied }

private enum SaveMode: CaseIterable {
    case stagedToken, google, password, emptyPassword

    var refreshToken: String? { self == .stagedToken ? "new-token" : nil }
    var password: String { self == .emptyPassword ? "" : "new-password" }
}

private enum SecretOperation: Equatable {
    case write(String, String)
    case remove(String)
}

@MainActor private final class AccountSaveFixture {
    let suite = "MailAccountSaveTests.\(UUID())"
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

@MainActor @Suite struct MailAccountSaveTests {
    @Test(arguments: SaveMode.allCases)
    private func sharedCredentialIdentityIsRejectedBeforeAnyMutation(mode: SaveMode) throws {
        let fixture = try AccountSaveFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let saved = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        model.save(saved)
        var duplicate = saved
        duplicate.id = UUID()
        duplicate.label = "Duplicate"
        duplicate.signedIn = mode == .google
        var operations: [SecretOperation] = []
        var rejected = false

        do {
            try model.saveAccount(duplicate, password: mode.password, refreshToken: mode.refreshToken,
                                  setSecret: { operations.append(.write($0, $1)) },
                                  removeSecret: { operations.append(.remove($0)) })
        } catch {
            rejected = true
        }

        #expect(rejected)
        #expect(operations.isEmpty)
        for snapshot in [model, fixture.makeModel()] {
            #expect(snapshot.accounts.map(\.id) == [saved.id])
            #expect(snapshot.accounts.map(\.label) == [saved.label])
            #expect(snapshot.accounts.map(\.signedIn) == [saved.signedIn])
        }
    }

    @Test(arguments: SaveMode.allCases)
    private func sameIDUpdatesCredentialsBeforePersistingMetadata(mode: SaveMode) throws {
        let fixture = try AccountSaveFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let saved = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        model.save(saved)
        var edited = saved
        edited.label = "Updated"
        edited.signedIn = mode == .google
        var operations: [SecretOperation] = []

        try model.saveAccount(edited, password: mode.password, refreshToken: mode.refreshToken,
                              setSecret: { value, key in
            #expect(model.accounts.map(\.label) == [saved.label])
            #expect(fixture.makeModel().accounts.map(\.label) == [saved.label])
            operations.append(.write(value, key))
        }, removeSecret: { key in
            #expect(model.accounts.map(\.label) == [saved.label])
            #expect(fixture.makeModel().accounts.map(\.label) == [saved.label])
            operations.append(.remove(key))
        })

        switch mode {
        case .stagedToken:
            #expect(operations == [.write("new-token", saved.refreshTokenKey)])
        case .google:
            #expect(operations.isEmpty)
        case .password:
            #expect(operations == [.write("new-password", saved.secretKey), .remove(saved.refreshTokenKey)])
        case .emptyPassword:
            #expect(operations == [.remove(saved.refreshTokenKey)])
        }
        for snapshot in [model, fixture.makeModel()] {
            #expect(snapshot.accounts.map(\.id) == [saved.id])
            #expect(snapshot.accounts.map(\.label) == [edited.label])
            #expect(snapshot.accounts.map(\.signedIn) == [mode == .google || mode == .stagedToken])
        }
    }

    @Test(arguments: [(SaveMode.stagedToken, 1), (.password, 1), (.password, 2), (.emptyPassword, 1)])
    private func secretFailurePropagatesWithoutPersistingMetadata(scenario: (SaveMode, Int)) throws {
        let (mode, failingCall) = scenario
        let fixture = try AccountSaveFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let saved = MailAccount(label: "Work", host: "work.example.com", user: "work@example.com")
        model.save(saved)
        var edited = saved
        edited.label = "Updated"
        var attempts = 0

        func attempt() throws {
            attempts += 1
            if attempts == failingCall { throw AccountSaveFailure.denied }
        }

        do {
            try model.saveAccount(edited, password: mode.password, refreshToken: mode.refreshToken,
                                  setSecret: { _, _ in try attempt() },
                                  removeSecret: { _ in try attempt() })
            Issue.record("Credential failure must propagate")
        } catch AccountSaveFailure.denied {
        }

        #expect(attempts == failingCall)
        for snapshot in [model, fixture.makeModel()] {
            #expect(snapshot.accounts.map(\.id) == [saved.id])
            #expect(snapshot.accounts.map(\.label) == [saved.label])
            #expect(snapshot.accounts.map(\.signedIn) == [saved.signedIn])
        }
    }
}
