import Combine
import Foundation

/// Stages browser consent in memory. Only the account editor's Save persists it.
@MainActor
final class MailSignIn: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private var credential: (key: String, token: String)?
    private var generation = 0
    private var task: Task<OAuth.Grant, Error>?
    private let authenticate: (MailAccount) async throws -> OAuth.Grant

    init(authenticate: @escaping (MailAccount) async throws -> OAuth.Grant = {
        guard let provider = $0.provider else { throw OAuth.Failure.denied("this server has no sign-in") }
        return try await provider.signIn(email: $0.user)
    }) {
        self.authenticate = authenticate
    }

    func token(for account: MailAccount) -> String? {
        credential?.key == account.secretKey ? credential?.token : nil
    }

    /// Stages the token for the address Google signed in, which may differ from the one typed, and returns it.
    @discardableResult
    func signIn(for account: MailAccount) async throws -> String {
        cancel()
        let request = generation
        isBusy = true
        let authenticate = self.authenticate
        let task = Task { try await authenticate(account) }
        self.task = task
        defer {
            if request == generation { isBusy = false; self.task = nil }
        }
        let result = await task.result
        guard request == generation, !Task.isCancelled else { throw CancellationError() }
        let grant = try result.get()
        var signedIn = account
        signedIn.user = grant.email
        credential = (signedIn.secretKey, grant.refreshToken)
        return grant.email
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        credential = nil
        isBusy = false
    }
}
