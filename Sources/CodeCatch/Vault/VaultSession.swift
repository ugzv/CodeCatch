import CodeCatchCore
import Combine
import Foundation

/// The app's one lock: codes are shown and copied, and saved logins loaded, only between an
/// authentication (Touch ID, else the Mac password) and the next sleep or screen lock.
@MainActor
final class VaultSession: ObservableObject {
    enum Failure: LocalizedError {
        case locked, busy
        var errorDescription: String? { self == .locked ? "Unlock CodeCatch first." : "Unlock is already in progress." }
    }

    @Published private(set) var codes: [VaultCode] = []
    @Published private(set) var isUnlocked = false
    @Published private(set) var isBusy = false
    var didLock: ([VaultCode]) -> Void = { _ in }
    var cancelAuthentication: () -> Void = {}
    private let authenticate: () async throws -> Void
    private let read: () throws -> [VaultCode]
    private let write: ([VaultCode]) throws -> Void
    private let erase: () throws -> Void
    private(set) var generation = 0

    init(authenticate: @escaping () async throws -> Void, read: @escaping () throws -> [VaultCode],
         write: @escaping ([VaultCode]) throws -> Void, remove: @escaping () throws -> Void) {
        self.authenticate = authenticate; self.read = read; self.write = write; self.erase = remove
    }

    func unlock() async throws {
        if isUnlocked { return }
        guard !isBusy else { throw Failure.busy }
        isBusy = true
        let request = generation
        defer { if request == generation { isBusy = false } }
        try await authenticate()
        guard request == generation, !Task.isCancelled else { throw CancellationError() }
        let loaded = try read()
        codes = loaded
        isUnlocked = true
    }

    func lock() {
        generation += 1
        cancelAuthentication()
        didLock(codes)
        codes = []
        isUnlocked = false
        isBusy = false
    }

    func replace(_ codes: [VaultCode]) throws {
        guard isUnlocked else { throw Failure.locked }
        try write(codes)
        self.codes = codes
    }

    func remove() throws {
        guard isUnlocked else { throw Failure.locked }
        try erase()
        lock()
    }
}
