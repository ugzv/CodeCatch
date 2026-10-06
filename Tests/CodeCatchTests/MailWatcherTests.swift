import Foundation
import SQLite3
import Testing
@testable import CodeCatch

private actor InterruptedInbox: MailConnection {
    let capabilities: Set<String> = ["IDLE"]
    let failFirstFetch: Bool
    let resetUIDs: Bool
    let emptyInbox: Bool
    let fetchStarted: AsyncStream<Void>.Continuation?
    private var pendingFetch: CheckedContinuation<Void, Never>?
    var attempts = 0
    var requested: [[Int]] = []
    init(failFirstFetch: Bool = true, resetUIDs: Bool = false, emptyInbox: Bool = false,
         fetchStarted: AsyncStream<Void>.Continuation? = nil) {
        self.failFirstFetch = failFirstFetch
        self.resetUIDs = resetUIDs
        self.emptyInbox = emptyInbox
        self.fetchStarted = fetchStarted
    }
    func openInbox(_ account: MailAccount) -> [IMAPConnection.Response] {
        attempts += 1
        return [.init(text: "* OK [UIDNEXT \(resetUIDs && attempts > 1 ? 3 : 42)]", literals: []),
                .init(text: "* OK [UIDVALIDITY \(resetUIDs && attempts > 1 ? 2 : 1)]", literals: [])]
    }
    func search(_ criteria: String) -> [Int] {
        criteria.hasPrefix("SINCE") && !emptyInbox ? [resetUIDs && attempts > 1 ? 2 : 41] : []
    }
    func fetch(_ uids: [Int], account: MailAccount) async throws -> [IncomingMessage] {
        guard !uids.isEmpty else { return [] }
        requested.append(uids)
        if attempts == 1 && failFirstFetch { throw IMAPError.timeout }
        if let fetchStarted {
            await withCheckedContinuation { pendingFetch = $0; fetchStarted.yield() }
        }
        return [IncomingMessage(text: "Your code is 482913", senderName: "Example", senderID: "example.com",
                                sourceKey: account.id.uuidString, sourceLabel: "Test", date: Date(), isMail: true)]
    }
    func idle(renewAfter: TimeInterval) async throws {
        if resetUIDs && attempts == 1 { throw IMAPError.timeout }
        try await Task.sleep(for: .seconds(60))
    }
    func command(_ cmd: String, timeout: TimeInterval) -> [IMAPConnection.Response] { [] }
    func close() { pendingFetch?.resume(); pendingFetch = nil }
}

@Test @MainActor func mailboxUIDResetBackfillsCodesInTheNewNamespace() async {
    let inbox = InterruptedInbox(failFirstFetch: false, resetUIDs: true)
    let statuses = AsyncStream<SourceStatus>.makeStream()
    var delivered = [IncomingMessage]()
    let watcher = Task {
        await MailWatcher.watch(MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
                                status: { statuses.continuation.yield($0) }, deliver: { delivered.append($0) },
                                connection: { inbox }, retryDelay: 0)
    }
    var liveCount = 0
    for await status in statuses.stream where status == .live {
        liveCount += 1
        if liveCount == 2 { break }
    }
    watcher.cancel()
    await watcher.value
    #expect(delivered.count == 2)
    #expect(await inbox.requested == [[41], [2]])
}

@Test @MainActor func failedInitialFetchIsRetriedBeforeMailBecomesLive() async {
    let inbox = InterruptedInbox()
    let statuses = AsyncStream<SourceStatus>.makeStream()
    var delivered = [IncomingMessage]()
    var events = [SourceEvent]()
    let watcher = Task {
        await MailWatcher.watch(MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
                                status: { statuses.continuation.yield($0) }, deliver: { delivered.append($0) },
                                event: { events.append($0) },
                                connection: { inbox }, retryDelay: 0)
    }
    for await status in statuses.stream where status == .live { break }
    watcher.cancel()
    await watcher.value
    #expect(delivered.count == 1)
    #expect(await inbox.requested == [[41], [41]])
    #expect(events.contains { if case .retry(.some) = $0 { true } else { false } })
    #expect(events.contains(.retry(nil)))
    #expect(events.contains { if case .checked = $0 { true } else { false } })
    #expect(events.contains(.message(delivered[0].date)))
}

@Test @MainActor func emptyMailboxStillReportsASuccessfulCheck() async {
    let inbox = InterruptedInbox(failFirstFetch: false, emptyInbox: true)
    let statuses = AsyncStream<SourceStatus>.makeStream()
    var events = [SourceEvent]()
    let watcher = Task {
        await MailWatcher.watch(MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
                                status: { statuses.continuation.yield($0) }, deliver: { _ in },
                                event: { events.append($0) }, connection: { inbox })
    }
    for await status in statuses.stream where status == .live { break }
    watcher.cancel()
    await watcher.value
    #expect(events.contains { if case .checked = $0 { true } else { false } })
    #expect(!events.contains { if case .message = $0 { true } else { false } })
}

@Test @MainActor func canceledMailFetchCannotDeliverOrBecomeLive() async {
    let started = AsyncStream<Void>.makeStream()
    var iterator = started.stream.makeAsyncIterator()
    let inbox = InterruptedInbox(failFirstFetch: false, fetchStarted: started.continuation)
    var delivered = 0
    var statuses = [SourceStatus]()
    let watcher = Task {
        await MailWatcher.watch(MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
                                status: { statuses.append($0) }, deliver: { _ in delivered += 1 },
                                connection: { inbox })
    }
    _ = await iterator.next()
    watcher.cancel()
    await watcher.value
    #expect(delivered == 0)
    #expect(!statuses.contains(.live))
}

private actor FakeGmail: MailAPI {
    let expireHistoryOnce: Bool
    let signInRevoked: Bool
    var historyChecks = 0
    var backfills = 0
    var fetched: [String] = []
    init(expireHistoryOnce: Bool = false, signInRevoked: Bool = false) {
        self.expireHistoryOnce = expireHistoryOnce
        self.signInRevoked = signInRevoked
    }
    func cursor() throws -> String {
        if signInRevoked { throw OAuth.Failure.token("invalid_grant") }
        return "100"
    }
    func inbox(since date: Date, limit: Int) -> [String] { backfills += 1; return ["backfilled"] }
    func added(since cursor: String) throws -> (ids: [String], cursor: String) {
        historyChecks += 1
        if expireHistoryOnce && historyChecks == 1 { throw MailAPIError.cursorExpired }
        // The backfilled mail also shows up in the first history check, as it can when it lands mid-backfill.
        return (fetched.contains("new") ? [] : ["backfilled", "new"], "101")
    }
    func message(_ id: String, account: MailAccount) -> IncomingMessage? {
        fetched.append(id)
        return IncomingMessage(text: "Your code is 482913", senderName: "Example", senderID: "example.com",
                               sourceKey: account.id.uuidString, sourceLabel: "Gmail", date: Date(), isMail: true, messageID: "gmail:\(id)")
    }
}

/// Watches until the "new" mail arrives, and returns every message the mailbox was asked for.
@MainActor private func gmailFetches(_ gmail: FakeGmail) async -> [String] {
    let delivered = AsyncStream<String?>.makeStream()
    let watcher = Task {
        await APIWatcher.watch(MailAccount(label: "Gmail", host: MailAccount.gmailHost, user: "test@gmail.com"),
                                 status: { _ in }, deliver: { delivered.continuation.yield($0.messageID) },
                                 mailbox: gmail, poll: 0.01, retryDelay: 0)
    }
    for await id in delivered.stream where id == "gmail:new" { break }
    watcher.cancel()
    await watcher.value
    return await gmail.fetched
}

@Test @MainActor func gmailMailInBothBackfillAndHistoryIsDeliveredOnce() async {
    #expect(await gmailFetches(FakeGmail()) == ["backfilled", "new"])
}

@Test @MainActor func expiredGmailHistoryBackfillsAgainInsteadOfLosingMail() async {
    let gmail = FakeGmail(expireHistoryOnce: true)
    #expect(await gmailFetches(gmail) == ["backfilled", "new"])
    #expect(await gmail.backfills == 2)
}

@Test @MainActor func revokedGoogleSignInIsReportedAsExpired() async {
    let statuses = AsyncStream<SourceStatus>.makeStream()
    let watcher = Task {
        await APIWatcher.watch(MailAccount(label: "Gmail", host: MailAccount.gmailHost, user: "test@gmail.com"),
                                 status: { statuses.continuation.yield($0) }, deliver: { _ in },
                                 mailbox: FakeGmail(signInRevoked: true))
    }
    var reported: SourceStatus?
    for await status in statuses.stream where status != .connecting { reported = status; break }
    watcher.cancel()
    await watcher.value
    #expect(reported == .failed(SourceStatus.signInExpired))
}

/// Guards the Apple Mail source against reading other mailboxes, deleted or old mail, against
/// missing a body that Mail saves after listing the message, and against delivering one twice.
@Test func appleMailDeliversInboxMailOnceAndAgainWhenItsBodyArrivesLate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppleMailStoreTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppleMailStore(root: root)
    #expect(store.open(since: .distantPast) != nil)

    let version = root.appendingPathComponent("V10")
    try FileManager.default.createDirectory(at: version.appendingPathComponent("MailData"), withIntermediateDirectories: true)
    let now = Int(Date().timeIntervalSince1970)
    var db: OpaquePointer?
    #expect(sqlite3_open(version.appendingPathComponent("MailData/Envelope Index").path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, subject_prefix TEXT, subject INTEGER, summary INTEGER,
                               date_received INTEGER, mailbox INTEGER, deleted INTEGER);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCOUNT/INBOX'), (2, 'imap://ACCOUNT/Archive');
        INSERT INTO addresses VALUES (1, 'no-reply@example.com', 'Example');
        INSERT INTO subjects VALUES (1, 'Your code is 482913');
        INSERT INTO messages VALUES (1001, 1, '', 1, NULL, \(now - 20), 1, 0), (5, 1, '', 1, NULL, \(now - 10), 1, 0),
                                    (6, 1, '', 1, NULL, \(now - 10), 2, 0), (7, 1, '', 1, NULL, \(now - 10), 1, 1),
                                    (8, 1, '', 1, NULL, \(now - 3 * 86400), 1, 0);
        """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    func save(_ id: Int, shard: String, body: String) throws {
        let folder = version.appendingPathComponent("ACCOUNT/INBOX.mbox/STORE/Data\(shard)/Messages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mail = "From: Example <no-reply@example.com>\r\nSubject: Sign in\r\nContent-Type: text/html\r\n\r\n\(body)"
        try Data("\(mail.utf8.count)\n\(mail)<?xml version=\"1.0\"?><plist></plist>".utf8).write(to: folder.appendingPathComponent("\(id).emlx"))
    }
    try save(1001, shard: "/1", body: "<a href=\"https://example.com/verify?token=x\">Confirm sign-in</a>")

    #expect(store.open(since: Date().addingTimeInterval(-86400)) == nil)
    let first = try store.newMessages()
    #expect(first.map(\.messageID) == ["1001", "5"])
    #expect(first[0].links.map(\.url) == ["https://example.com/verify?token=x"])
    #expect(!first[0].text.contains("plist"))
    #expect(first[1].subject == "Your code is 482913" && first[1].senderID == "no-reply@example.com")
    #expect(try store.newMessages().isEmpty)

    // Half-written by Mail: more bytes promised than saved so far.
    let inbox = version.appendingPathComponent("ACCOUNT/INBOX.mbox/STORE/Data/Messages")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try Data("9000\nFrom: Example <no-reply@example.com>\r\n".utf8).write(to: inbox.appendingPathComponent("5.emlx"))
    #expect(try store.newMessages().isEmpty)
    #expect(AppleMailStore.message(inEMLX: Data("-1\nx".utf8)) == nil)

    try save(5, shard: "", body: "Use 482913 to sign in.")
    let late = try store.newMessages()
    #expect(late.map(\.messageID) == ["5"])
    #expect(late.first?.text.contains("Use 482913") == true)
    #expect(try store.newMessages().isEmpty)
}
