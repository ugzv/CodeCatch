import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

private enum PolicyFailure: Error { case unavailable }

@MainActor private final class PolicyStorage {
    var stored = false
    var loadFails = false
    var saveFails = false
    var authFails = false
    var authCalls = 0
    var writes: [Bool] = []
    var onAuthenticate: (() async -> Void)?

    func policy() -> UnlockPolicy {
        UnlockPolicy(load: {
            if self.loadFails { throw PolicyFailure.unavailable }
            return self.stored
        }, save: { enabled in
            if self.saveFails { throw PolicyFailure.unavailable }
            self.writes.append(enabled)
            self.stored = enabled
        }, authenticate: {
            self.authCalls += 1
            await self.onAuthenticate?()
            if self.authFails { throw PolicyFailure.unavailable }
        })
    }
}

@MainActor @Suite struct UnlockPolicyTests {
    @Test func writableDefaultCannotBypassProtectedPolicyInProductionVaultSession() async throws {
        let suite = "UnlockPolicyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: Prefs.bitwarden)
        defaults.set(true, forKey: Prefs.unlockWithMac)
        let storage = PolicyStorage()
        storage.authFails = true
        let policy = storage.policy()
        policy.restore()
        let session = VaultStorage.session(defaults: defaults, unlockPolicy: policy)
        await #expect(throws: (any Error).self) { try await session.unlock() }
        #expect(storage.authCalls == 1)
        #expect(!session.isUnlocked)
        #expect(session.codes.isEmpty)
    }

    @Test(arguments: [false, true])
    func missingOrUnreadableProtectedConsentLeavesMacUnlockDisabled(_ unreadable: Bool) {
        let storage = PolicyStorage()
        storage.loadFails = unreadable
        let policy = storage.policy()
        policy.restore()
        #expect(!policy.enabled)
        #expect(storage.authCalls == 0)
    }

    @Test func protectedConsentRestoresMacUnlockAfterRestart() async throws {
        let storage = PolicyStorage()
        let policy = storage.policy()
        try await policy.setEnabled(true)
        #expect(policy.enabled)
        #expect(storage.authCalls == 1)
        #expect(storage.writes == [true])
        let restarted = storage.policy()
        restarted.restore()
        #expect(restarted.enabled)
    }

    @Test(arguments: [false, true])
    func failedAuthenticationOrConsentSaveCannotEnableMacUnlock(_ failSave: Bool) async {
        let storage = PolicyStorage()
        storage.saveFails = failSave
        storage.authFails = !failSave
        let policy = storage.policy()
        await #expect(throws: (any Error).self) { try await policy.setEnabled(true) }
        #expect(!policy.enabled)
        #expect(!storage.stored)
        #expect(storage.writes.isEmpty)
        #expect(storage.authCalls == 1)
    }

    @Test func disabledConsentRequiresFreshAuthenticationAndPropagatesFailure() async throws {
        let storage = PolicyStorage()
        let policy = storage.policy()
        policy.restore()
        try await policy.authenticate()
        #expect(storage.authCalls == 1)
        storage.authFails = true
        await #expect(throws: (any Error).self) { try await policy.authenticate() }
        #expect(storage.authCalls == 2)
    }

    @Test func protectedConsentSkipsUnlockPromptsButEnablingAgainStillAuthenticates() async throws {
        let storage = PolicyStorage()
        storage.stored = true
        let policy = storage.policy()
        policy.restore()
        try await policy.authenticate()
        try await policy.authenticate()
        #expect(storage.authCalls == 0)
        storage.authFails = true
        await #expect(throws: (any Error).self) { try await policy.setEnabled(true) }
        #expect(storage.authCalls == 1)
    }

    @Test func failedDisableSaveStillRevokesConsentInMemory() async {
        let storage = PolicyStorage()
        storage.stored = true
        let policy = storage.policy()
        policy.restore()
        storage.saveFails = true
        await #expect(throws: (any Error).self) { try await policy.setEnabled(false) }
        #expect(!policy.enabled)
        storage.authFails = true
        await #expect(throws: (any Error).self) { try await policy.authenticate() }
        #expect(storage.authCalls == 1)
    }

    @Test func disablingDuringEnableAuthenticationCannotBeUndoneByLateCompletion() async throws {
        let storage = PolicyStorage()
        let policy = storage.policy()
        var release: CheckedContinuation<Void, Never>?
        let enabling = Task { try? await policy.setEnabled(true) }
        await withCheckedContinuation { entered in
            storage.onAuthenticate = {
                await withCheckedContinuation { waiting in
                    release = waiting
                    entered.resume()
                }
            }
        }
        #expect(!policy.enabled)
        #expect(storage.writes.isEmpty)
        try await policy.setEnabled(false)
        release?.resume()
        await enabling.value
        #expect(!policy.enabled)
        #expect(!storage.stored)
        #expect(!storage.writes.contains(true))
    }
}
