import Foundation

protocol MailConnection: Sendable {
    var capabilities: Set<String> { get async }
    func openInbox(_ account: MailAccount) async throws -> [IMAPConnection.Response]
    func search(_ criteria: String) async throws -> [Int]
    func fetch(_ uids: [Int], account: MailAccount) async throws -> [IncomingMessage]
    func idle(renewAfter: TimeInterval) async throws
    func command(_ cmd: String, timeout: TimeInterval) async throws -> [IMAPConnection.Response]
    func close() async
}

extension IMAPConnection: MailConnection {}

enum MailWatcher {
    /// Watches one INBOX until cancelled: backfills history, then IDLEs, reconnecting with backoff.
    static func watch(_ account: MailAccount,
                      status: @escaping @MainActor (SourceStatus) -> Void,
                      deliver: @escaping @MainActor (IncomingMessage) -> Void,
                      event: @escaping @MainActor (SourceEvent) -> Void = { _ in },
                      lookback: TimeInterval = 7 * 86400,
                      connection: (@Sendable () -> any MailConnection)? = nil,
                      retryDelay: TimeInterval = 5) async {
        var lastUID: Int?
        var uidValidity: Int?
        var backoff = retryDelay
        while !Task.isCancelled {
            let conn: any MailConnection
            do { conn = try connection?() ?? IMAPConnection(account: account) }
            catch { await status(.failed(error.localizedDescription)); return }
            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    await event(.retry(nil))
                    await status(.connecting)
                    let examine = try await conn.openInbox(account)
                    try Task.checkCancellation()
                    let validity = examine.lazy.compactMap { $0.number(after: "UIDVALIDITY ") }.first
                    if validity != uidValidity { lastUID = nil }
                    uidValidity = validity

                    func receive(_ uids: [Int]) async throws {
                        try Task.checkCancellation()
                        let messages = try await conn.fetch(uids, account: account)
                        try Task.checkCancellation()
                        await event(.checked(Date()))
                        if let newest = messages.map(\.date).max() { await event(.message(newest)) }
                        for message in messages {
                            try Task.checkCancellation()
                            await deliver(message)
                        }
                    }

                    if lastUID == nil {
                        let recent = try await conn.search("SINCE \(imapDay(Date().addingTimeInterval(-lookback)))")
                        let next = examine.lazy.compactMap { $0.number(after: "UIDNEXT ") }.first
                        try await receive(Array(recent.suffix(60)))
                        lastUID = max((next ?? 1) - 1, recent.max() ?? 0)
                    }
                    try Task.checkCancellation()
                    await status(.live)
                    backoff = retryDelay
                    let canIdle = await conn.capabilities.contains("IDLE")
                    while !Task.isCancelled {
                        let new = try await conn.search("UID \(lastUID! + 1):*").filter { $0 > lastUID! }
                        // After a long outage only the newest can still hold a live code.
                        try await receive(Array(new.suffix(15)))
                        lastUID = new.max() ?? lastUID
                        if canIdle { try await conn.idle(renewAfter: 540) } else {
                            try await Task.sleep(for: .seconds(20))
                            _ = try await conn.command("NOOP", timeout: 30)
                        }
                    }
                } onCancel: {
                    Task { await conn.close() }
                }
            } catch {
                await conn.close()
                if Task.isCancelled { break }
                let noPassword = if case IMAPError.noPassword = error { true } else { false }
                let authFailed = noPassword || "\(error)".contains("AUTHENTICATIONFAILED")
                await status(.failed(authFailed ? "Sign-in failed — check the app password" : error.localizedDescription))
                let delay = authFailed ? 300 : backoff
                await event(.retry(Date().addingTimeInterval(delay)))
                try? await Task.sleep(for: .seconds(delay))
                backoff = min(backoff * 2, 120)
            }
        }
    }

    static func imapDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MMM-yyyy"
        return f.string(from: date)
    }
}
