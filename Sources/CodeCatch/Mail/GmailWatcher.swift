import Foundation

/// What GmailWatcher reads: the Gmail API in the app, a stand-in in tests.
protocol GmailMailbox: Sendable {
    func historyID() async throws -> String
    func inbox(since date: Date, limit: Int) async throws -> [String]
    func added(since historyID: String) async throws -> (ids: [String], historyID: String)
    func message(_ id: String, account: MailAccount) async throws -> IncomingMessage?
}

enum GmailWatcher {
    /// Watches the inbox of an account signed in with Google until cancelled: backfills recent mail,
    /// then checks the mailbox history every `poll` seconds (Gmail has no push to a Mac app).
    static func watch(_ account: MailAccount,
                      status: @escaping @MainActor (SourceStatus) -> Void,
                      deliver: @escaping @MainActor (IncomingMessage) -> Void,
                      event: @escaping @MainActor (SourceEvent) -> Void = { _ in },
                      lookback: TimeInterval = 7 * 86400,
                      mailbox: (any GmailMailbox)? = nil,
                      poll: TimeInterval = 10,
                      retryDelay: TimeInterval = 5) async {
        var historyID: String?
        var backfilled = Set<String>()
        var backoff = retryDelay
        while !Task.isCancelled {
            do {
                let mailbox = try mailbox ?? GmailAPI(account: account)
                await event(.retry(nil))
                await status(.connecting)

                func receive(_ ids: [String]) async throws {
                    var messages: [IncomingMessage] = []
                    for id in ids {
                        try Task.checkCancellation()
                        if let message = try await mailbox.message(id, account: account) { messages.append(message) }
                    }
                    try Task.checkCancellation()
                    await event(.checked(Date()))
                    if let newest = messages.map(\.date).max() { await event(.message(newest)) }
                    for message in messages {
                        try Task.checkCancellation()
                        await deliver(message)
                    }
                }

                if historyID == nil {
                    // Take the history position first, so mail arriving during the backfill is not missed.
                    let start = try await mailbox.historyID()
                    let recent = try await mailbox.inbox(since: Date().addingTimeInterval(-lookback), limit: 60)
                    try await receive(recent)
                    backfilled = Set(recent)
                    historyID = start
                }
                try Task.checkCancellation()
                await status(.live)
                backoff = retryDelay
                while !Task.isCancelled {
                    let (added, next) = try await mailbox.added(since: historyID!)
                    // After a long outage only the newest can still hold a live code.
                    try await receive(Array(added.filter { !backfilled.contains($0) }.suffix(15)))
                    historyID = next
                    try await Task.sleep(for: .seconds(poll))
                }
            } catch GmailAPI.Failure.historyExpired {
                historyID = nil
            } catch {
                if Task.isCancelled { break }
                let authFailed = error is GoogleOAuth.Failure
                await status(.failed(authFailed ? SourceStatus.googleSignInExpired : error.localizedDescription))
                let delay = authFailed ? 300 : backoff
                await event(.retry(Date().addingTimeInterval(delay)))
                try? await Task.sleep(for: .seconds(delay))
                backoff = min(backoff * 2, 120)
            }
        }
    }
}
