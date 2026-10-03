import Foundation

/// Resumes a continuation at most once across NWConnection state callbacks.
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; body() }
    }
}
