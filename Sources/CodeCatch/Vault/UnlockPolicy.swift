import Foundation

/// Permission to skip the per-unlock prompt comes from protected storage, never preferences.
@MainActor
final class UnlockPolicy {
    private(set) var enabled = false
    private let load: () throws -> Bool
    private let save: (Bool) throws -> Void
    private let authenticateOwner: () async throws -> Void
    private let cancel: () -> Void
    private var generation = 0

    init(load: @escaping () throws -> Bool, save: @escaping (Bool) throws -> Void,
         authenticate: @escaping () async throws -> Void, cancel: @escaping () -> Void = {}) {
        self.load = load
        self.save = save
        self.authenticateOwner = authenticate
        self.cancel = cancel
    }

    func restore() { enabled = (try? load()) ?? false }

    func setEnabled(_ enabled: Bool) async throws {
        generation += 1
        let request = generation
        if !enabled {
            self.enabled = false
            cancel()
            try save(false)
            return
        }
        try await authenticateOwner()
        guard request == generation, !Task.isCancelled else { throw CancellationError() }
        try save(true)
        self.enabled = true
    }

    func authenticate() async throws {
        if !enabled { try await authenticateOwner() }
    }

    func cancelAuthentication() {
        generation += 1
        cancel()
    }
}
