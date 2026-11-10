import Foundation

/// A mailbox read through its provider's API (Gmail, Outlook) after signing in; a stand-in in tests.
protocol MailAPI: Sendable {
    /// Where new mail starts, taken before the backfill so mail landing during it is not missed.
    func cursor() async throws -> String
    /// Inbox messages received since `date`, oldest first.
    func inbox(since date: Date, limit: Int) async throws -> [String]
    /// Messages that reached the inbox after `cursor`, oldest first, and the cursor to continue from.
    func added(since cursor: String) async throws -> (ids: [String], cursor: String)
    func message(_ id: String, account: MailAccount) async throws -> IncomingMessage?
}

enum MailAPIError: LocalizedError {
    case cursorExpired, gone
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .cursorExpired: "The mailbox's change history expired"
        case .gone: "The message was deleted"
        case .http(let status, let message): "The mail service answered \(status): \(message)"
        }
    }
}

enum APIWatcher {
    /// The API for an account signed in with its provider.
    static func api(for account: MailAccount) -> any MailAPI {
        account.isOutlook ? OutlookAPI(account: account) : GmailAPI(account: account)
    }

    /// Watches the inbox of a signed-in account until cancelled: backfills recent mail, or carries on
    /// from `position`, then checks for new mail every `poll` seconds (neither Gmail nor Outlook can
    /// push to a Mac app).
    static func watch(
        _ account: MailAccount,
        from position: ReadPosition? = nil,
        status: @escaping @MainActor (SourceStatus) -> Void,
        deliver: @escaping @MainActor (IncomingMessage) -> Void,
        event: @escaping @MainActor (SourceEvent) -> Void = { _ in },
        lookback: TimeInterval = 7 * 86400,
        mailbox: (any MailAPI)? = nil,
        poll: TimeInterval = 10,
        retryDelay: TimeInterval = 5
    ) async {
        let mailbox = mailbox ?? api(for: account)
        var cursor: String? = if case .cursor(let saved) = position { saved } else { nil }
        var resuming = cursor != nil
        var seen = Set<String>()  // a message can show up twice: at the backfill's edge, or at the cursor's
        var backoff = retryDelay
        while !Task.isCancelled {
            do {
                await event(.retry(nil))
                await status(.connecting)

                func receive(_ ids: [String]) async throws {
                    var messages: [IncomingMessage] = []
                    for id in ids where !seen.contains(id) {
                        try Task.checkCancellation()
                        if let message = try await mailbox.message(id, account: account) { messages.append(message) }
                    }
                    try Task.checkCancellation()
                    if seen.count > 1000 { seen.removeAll() }
                    seen.formUnion(ids)
                    try await MailWatcher.hand(messages, event: event, deliver: deliver)
                }

                // Live once the provider has answered: a resumed account makes no call before its first check,
                // and counting it as working there also reset the backoff on every failed try.
                var live = false
                func answered() async {
                    guard !live else { return }
                    live = true
                    await status(.live)
                    backoff = retryDelay
                }

                if cursor == nil {
                    let start = try await mailbox.cursor()
                    try await receive(try await mailbox.inbox(since: Date().addingTimeInterval(-lookback), limit: MailWatcher.backfill))
                    cursor = start
                    await event(.read(.cursor(start)))
                    resuming = false
                    try Task.checkCancellation()
                    await answered()
                }
                try Task.checkCancellation()
                while !Task.isCancelled {
                    let (added, next) = try await mailbox.added(since: cursor!)
                    await answered()
                    // The same newest few on a retry, so a failed fetch can't widen the window to older mail.
                    let pending = (resuming ? added.suffix(MailWatcher.backfill) : added[...]).filter { !seen.contains($0) }
                    if pending.isEmpty { try await receive([]) }
                    // Bound memory while keeping every fresh message, including recovery bursts.
                    for start in stride(from: 0, to: pending.count, by: 50) {
                        try await receive(Array(pending[start..<min(start + 50, pending.count)]))
                    }
                    resuming = false
                    cursor = next
                    await event(.read(.cursor(next)))
                    try await Task.sleep(for: .seconds(poll))
                }
            } catch MailAPIError.cursorExpired {
                cursor = nil
            } catch {
                if Task.isCancelled { break }
                let signInFailed = error is OAuth.Failure
                await MailWatcher.wait(
                    after: signInFailed ? SourceStatus.signInExpired : MailWatcher.describe(error),
                    signIn: signInFailed, backoff: &backoff, status: status, event: event)
            }
        }
    }
}
