import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

@MainActor private final class ControlledMailAuthentication {
    struct Request {
        let user: String
        let completion: CheckedContinuation<String, Error>
    }

    let requests: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation

    init() {
        (requests, continuation) = AsyncStream.makeStream()
    }

    func authenticate(_ user: String) async throws -> String {
        try await withCheckedThrowingContinuation { completion in
            continuation.yield(Request(user: user, completion: completion))
        }
    }
}

private enum MailAuthenticationFailure: Error { case denied }

@MainActor private func expectObsoleteSignInCancelled(_ task: Task<Void, Error>) async {
    do {
        try await task.value
        Issue.record("An obsolete sign-in must throw CancellationError")
    } catch is CancellationError {
    } catch {
        Issue.record("An obsolete sign-in threw an unexpected error: \(error)")
    }
}

@MainActor @Suite struct MailSignInTests {
    @Test func refreshTokenCannotBeUsedForAnotherUserOrHost() async throws {
        let authentication = ControlledMailAuthentication()
        var requests = authentication.requests.makeAsyncIterator()
        let signIn = MailSignIn(authenticate: { try await authentication.authenticate($0) })
        let account = MailAccount(label: "Work", host: "imap.example.com", user: "first@example.com")
        #expect(!signIn.isBusy)

        let task = Task { try await signIn.signIn(for: account) }
        let request = try #require(await requests.next())
        #expect(request.user == account.user)
        #expect(signIn.isBusy)
        #expect(signIn.token(for: account) == nil)
        request.completion.resume(returning: "first-refresh-token")
        try await task.value

        #expect(!signIn.isBusy)
        #expect(signIn.token(for: account) == "first-refresh-token")
        #expect(signIn.token(for: MailAccount(label: "Renamed", host: "imap.example.com",
                                               user: "first@example.com")) == "first-refresh-token")
        #expect(signIn.token(for: MailAccount(label: "Work", host: "imap.example.com",
                                               user: "second@example.com")) == nil)
        #expect(signIn.token(for: MailAccount(label: "Work", host: "other.example.com",
                                               user: "first@example.com")) == nil)
    }

    @Test func cancellingCompletedSignInImmediatelyClearsStagedToken() async throws {
        let signIn = MailSignIn(authenticate: { _ in "refresh-token" })
        let account = MailAccount(label: "Work", host: "imap.example.com", user: "first@example.com")
        try await signIn.signIn(for: account)
        #expect(signIn.token(for: account) == "refresh-token")

        signIn.cancel()

        #expect(!signIn.isBusy)
        #expect(signIn.token(for: account) == nil)
    }

    @Test(arguments: [true, false])
    func cancelledCompletionCannotClearNewBusyStateOrReplaceNewToken(oldCompletesFirst: Bool) async throws {
        let authentication = ControlledMailAuthentication()
        var requests = authentication.requests.makeAsyncIterator()
        let signIn = MailSignIn(authenticate: { try await authentication.authenticate($0) })
        let account = MailAccount(label: "Work", host: "imap.example.com", user: "first@example.com")
        let oldTask = Task { try await signIn.signIn(for: account) }
        let oldRequest = try #require(await requests.next())
        #expect(signIn.isBusy)

        signIn.cancel()
        #expect(!signIn.isBusy)
        #expect(signIn.token(for: account) == nil)
        let newTask = Task { try await signIn.signIn(for: account) }
        let newRequest = try #require(await requests.next())
        #expect(signIn.isBusy)

        if oldCompletesFirst {
            oldRequest.completion.resume(returning: "obsolete-token")
            await expectObsoleteSignInCancelled(oldTask)
            #expect(signIn.isBusy)
            #expect(signIn.token(for: account) == nil)
        }

        newRequest.completion.resume(returning: "current-token")
        try await newTask.value
        #expect(!signIn.isBusy)
        #expect(signIn.token(for: account) == "current-token")

        if !oldCompletesFirst {
            oldRequest.completion.resume(returning: "obsolete-token")
            await expectObsoleteSignInCancelled(oldTask)
            #expect(!signIn.isBusy)
            #expect(signIn.token(for: account) == "current-token")
        }
    }

    @Test func cancelledAuthenticationCannotStageTokenWhenProviderIgnoresCancellation() async throws {
        let authentication = ControlledMailAuthentication()
        var requests = authentication.requests.makeAsyncIterator()
        let signIn = MailSignIn(authenticate: { try await authentication.authenticate($0) })
        let account = MailAccount(label: "Work", host: "imap.example.com", user: "first@example.com")
        let task = Task { try await signIn.signIn(for: account) }
        let request = try #require(await requests.next())

        signIn.cancel()
        #expect(!signIn.isBusy)
        #expect(signIn.token(for: account) == nil)
        request.completion.resume(returning: "cancelled-token")
        await expectObsoleteSignInCancelled(task)

        #expect(!signIn.isBusy)
        #expect(signIn.token(for: account) == nil)
    }

    @Test func failedReauthenticationCannotRetainPreviouslyStagedToken() async throws {
        let authentication = ControlledMailAuthentication()
        var requests = authentication.requests.makeAsyncIterator()
        let signIn = MailSignIn(authenticate: { try await authentication.authenticate($0) })
        let account = MailAccount(label: "Work", host: "imap.example.com", user: "first@example.com")
        let firstTask = Task { try await signIn.signIn(for: account) }
        let firstRequest = try #require(await requests.next())
        firstRequest.completion.resume(returning: "earlier-token")
        try await firstTask.value
        #expect(signIn.token(for: account) == "earlier-token")

        let failedTask = Task { try await signIn.signIn(for: account) }
        let failedRequest = try #require(await requests.next())
        failedRequest.completion.resume(throwing: MailAuthenticationFailure.denied)
        do {
            try await failedTask.value
            Issue.record("Failed authentication must propagate its error")
        } catch MailAuthenticationFailure.denied {
        }

        #expect(!signIn.isBusy)
        #expect(signIn.token(for: account) == nil)
    }
}
