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
    case cursorExpired, gone, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .cursorExpired: "The mailbox's change history expired"
        case .gone: "The message was deleted"
        case .http(let status, let message): "The mail service answered \(status): \(message)"
        }
    }

    /// Sends `request` with the account's access token, refreshing it once if it was refused,
    /// and maps the provider's errors. Returns the body of a successful answer.
    static func send(_ request: URLRequest, auth: APIAuth, provider: String) async throws -> Data {
        var request = request
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await OAuth.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 200: return data
        case 401 where auth.forget(): return try await send(request, auth: .issued(try await auth.accessToken()), provider: provider)
        case 401: throw OAuth.Failure.token("unauthorized")
        case 403 where message.localizedCaseInsensitiveContains("insufficient") || message.localizedCaseInsensitiveContains("denied"):
            throw OAuth.Failure.noMailAccess(provider)
        case 404: throw MailAPIError.gone
        default: throw MailAPIError.http(status, message)
        }
    }
}

enum APIWatcher {
    /// The API for an account signed in with its provider.
    static func api(for account: MailAccount) -> any MailAPI {
        account.isOutlook ? OutlookAPI(account: account) : GmailAPI(account: account)
    }

    /// Watches the inbox of a signed-in account until cancelled: backfills recent mail, then checks
    /// for new mail every `poll` seconds (neither Gmail nor Outlook can push to a Mac app).
    static func watch(_ account: MailAccount,
                      status: @escaping @MainActor (SourceStatus) -> Void,
                      deliver: @escaping @MainActor (IncomingMessage) -> Void,
                      event: @escaping @MainActor (SourceEvent) -> Void = { _ in },
                      lookback: TimeInterval = 7 * 86400,
                      mailbox: (any MailAPI)? = nil,
                      poll: TimeInterval = 10,
                      retryDelay: TimeInterval = 5) async {
        let mailbox = mailbox ?? api(for: account)
        var cursor: String?
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
                    await event(.checked(Date()))
                    if let newest = messages.map(\.date).max() { await event(.message(newest)) }
                    for message in messages {
                        try Task.checkCancellation()
                        await deliver(message)
                    }
                }

                if cursor == nil {
                    let start = try await mailbox.cursor()
                    try await receive(try await mailbox.inbox(since: Date().addingTimeInterval(-lookback), limit: 60))
                    cursor = start
                }
                try Task.checkCancellation()
                await status(.live)
                backoff = retryDelay
                while !Task.isCancelled {
                    let (added, next) = try await mailbox.added(since: cursor!)
                    // After a long outage only the newest can still hold a live code.
                    try await receive(Array(added.filter { !seen.contains($0) }.suffix(15)))
                    cursor = next
                    try await Task.sleep(for: .seconds(poll))
                }
            } catch MailAPIError.cursorExpired {
                cursor = nil
            } catch {
                if Task.isCancelled { break }
                let signInFailed = error is OAuth.Failure
                await status(.failed(signInFailed ? SourceStatus.signInExpired : error.localizedDescription))
                let delay = signInFailed ? 300 : backoff
                await event(.retry(Date().addingTimeInterval(delay)))
                try? await Task.sleep(for: .seconds(delay))
                backoff = min(backoff * 2, 120)
            }
        }
    }
}
