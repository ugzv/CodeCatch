import Foundation
import LocalAuthentication
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

private enum VaultTestFailure: Error { case unavailable }

@MainActor private func vaultCode(_ id: String) -> VaultCode {
    VaultCode(id: id, name: id, username: nil, domain: nil,
              secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
}

@MainActor private final class VaultStorage {
    var codes = [vaultCode("original")]
    var reads = 0
    var writes = 0
    var removals = 0
    var failsRead = false
    var failsWrite = false
    var failsRemoval = false

    func session(authenticate: @escaping () async throws -> Void = {}) -> VaultSession {
        VaultSession(authenticate: authenticate, read: {
            self.reads += 1
            if self.failsRead { throw VaultTestFailure.unavailable }
            return self.codes
        }, write: { codes in
            self.writes += 1
            if self.failsWrite { throw VaultTestFailure.unavailable }
            self.codes = codes
        }, remove: {
            self.removals += 1
            if self.failsRemoval { throw VaultTestFailure.unavailable }
            self.codes = []
        })
    }
}

@MainActor private final class AuthenticationGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var entered: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls = 0

    func authenticate() async {
        calls += 1
        entered?.resume()
        entered = nil
        if !released {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func waitUntilStarted() async {
        if calls == 0 {
            await withCheckedContinuation { entered = $0 }
        }
    }

    func release() {
        released = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@MainActor @Suite struct VaultSessionTests {
    @Test func lockedSessionNeverReadsOrExposesStoredCodes() {
        let storage = VaultStorage()
        let session = storage.session()

        #expect(storage.reads == 0)
        #expect(session.codes.isEmpty)
        #expect(!session.isUnlocked)
        #expect(!session.isBusy)
    }

    @Test func authenticationFinishesBeforeAnyCodesAreRead() async throws {
        let storage = VaultStorage()
        let gate = AuthenticationGate()
        let session = storage.session(authenticate: gate.authenticate)
        let unlocking = Task { try await session.unlock() }
        await gate.waitUntilStarted()

        #expect(session.isBusy)
        #expect(storage.reads == 0)
        #expect(session.codes.isEmpty)
        #expect(!session.isUnlocked)
        gate.release()
        try await unlocking.value

        #expect(storage.reads == 1)
        #expect(session.codes.map(\.id) == ["original"])
        #expect(session.isUnlocked)
        #expect(!session.isBusy)
    }

    @Test func deniedAuthenticationNeverReadsOrExposesCodes() async {
        let storage = VaultStorage()
        let session = storage.session(authenticate: { throw VaultTestFailure.unavailable })

        await #expect(throws: (any Error).self) { try await session.unlock() }

        #expect(storage.reads == 0)
        #expect(session.codes.isEmpty)
        #expect(!session.isUnlocked)
        #expect(!session.isBusy)
    }

    @Test func failedReadLeavesSessionLockedAndAllowsRetry() async throws {
        let storage = VaultStorage()
        storage.failsRead = true
        let session = storage.session()

        await #expect(throws: (any Error).self) { try await session.unlock() }
        #expect(session.codes.isEmpty)
        #expect(!session.isUnlocked)
        #expect(!session.isBusy)

        storage.failsRead = false
        try await session.unlock()
        #expect(session.isUnlocked)
        #expect(session.codes.map(\.id) == ["original"])
    }

    @Test func lockingClearsCodesWithoutDeletingStoredVault() async throws {
        let storage = VaultStorage()
        let session = storage.session()
        try await session.unlock()

        session.lock()

        #expect(session.codes.isEmpty)
        #expect(!session.isUnlocked)
        #expect(storage.codes.map(\.id) == ["original"])
        #expect(storage.removals == 0)
    }

    @Test func lockingDuringAuthenticationPreventsLateCodeExposure() async {
        let storage = VaultStorage()
        let gate = AuthenticationGate()
        let session = storage.session(authenticate: gate.authenticate)
        let unlocking = Task { try? await session.unlock() }
        await gate.waitUntilStarted()

        session.lock()
        gate.release()
        await unlocking.value

        #expect(session.codes.isEmpty)
        #expect(!session.isUnlocked)
        #expect(!session.isBusy)
    }

    @Test func overlappingUnlocksDoNotDuplicateAuthenticationOrReads() async {
        let storage = VaultStorage()
        let gate = AuthenticationGate()
        let session = storage.session(authenticate: gate.authenticate)
        let first = Task { try? await session.unlock() }
        await gate.waitUntilStarted()

        var second: Task<Void, Never>?
        await withCheckedContinuation { started in
            second = Task { @MainActor in
                started.resume()
                _ = try? await session.unlock()
            }
        }
        gate.release()
        await first.value
        await second?.value

        #expect(gate.calls == 1)
        #expect(storage.reads == 1)
        #expect(session.isUnlocked)
        #expect(!session.isBusy)
    }

    @Test func lockedMutationsCannotReachStorage() {
        let storage = VaultStorage()
        let session = storage.session()

        #expect(throws: (any Error).self) { try session.replace([vaultCode("replacement")]) }
        #expect(throws: (any Error).self) { try session.remove() }

        #expect(storage.writes == 0)
        #expect(storage.removals == 0)
        #expect(session.codes.isEmpty)
        #expect(!session.isUnlocked)
    }

    @Test func replacementBecomesVisibleOnlyAfterSuccessfulStorageWrite() async throws {
        let original = vaultCode("original")
        let replacement = vaultCode("replacement")
        var session: VaultSession!
        var failsWrite = true
        var writes = 0
        session = VaultSession(authenticate: {}, read: { [original] }, write: { codes in
            writes += 1
            #expect(session.codes.map(\.id) == ["original"])
            #expect(codes.map(\.id) == ["replacement"])
            if failsWrite { throw VaultTestFailure.unavailable }
        }, remove: {})
        try await session.unlock()

        #expect(throws: (any Error).self) { try session.replace([replacement]) }
        #expect(session.codes.map(\.id) == ["original"])
        #expect(session.isUnlocked)
        #expect(!session.isBusy)

        failsWrite = false
        try session.replace([replacement])
        #expect(writes == 2)
        #expect(session.codes.map(\.id) == ["replacement"])
        #expect(session.isUnlocked)
    }

    @Test func failedRemovalPreservesCodesAndSuccessfulRemovalLocksSession() async throws {
        let storage = VaultStorage()
        storage.failsRemoval = true
        let session = storage.session()
        try await session.unlock()

        #expect(throws: (any Error).self) { try session.remove() }
        #expect(session.codes.map(\.id) == ["original"])
        #expect(session.isUnlocked)
        #expect(!session.isBusy)

        storage.failsRemoval = false
        try session.remove()
        #expect(storage.removals == 2)
        #expect(storage.codes.isEmpty)
        #expect(session.codes.isEmpty)
        #expect(!session.isUnlocked)
        #expect(!session.isBusy)
    }
}


private final class BiometricContext: LAContext {
    var available = false
    var kind: LABiometryType = .none
    private(set) var evaluatedPolicy: LAPolicy?

    override var biometryType: LABiometryType { kind }
    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        evaluatedPolicy = policy
        return available
    }
}

@MainActor @Suite struct DeviceAuthenticationTests {
    @Test(arguments: [false, true], [.none, .touchID, .faceID] as [LABiometryType])
    func unavailableOrDifferentBiometricsNeverAdvertiseTouchID(available: Bool, kind: LABiometryType) {
        let context = BiometricContext()
        context.available = available
        context.kind = kind

        #expect(DeviceAuthentication.supportsTouchID(context: context) == (available && kind == .touchID))
        #expect(context.evaluatedPolicy == .deviceOwnerAuthenticationWithBiometrics)
    }

    @Test func removedOrLockedBiometricsAreNotCachedAsAvailable() {
        let context = BiometricContext()
        context.available = true
        context.kind = .touchID
        #expect(DeviceAuthentication.supportsTouchID(context: context))

        context.available = false
        #expect(!DeviceAuthentication.supportsTouchID(context: context))
    }
}
