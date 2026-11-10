import Foundation
import Network
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
    init(
        failFirstFetch: Bool = true, resetUIDs: Bool = false, emptyInbox: Bool = false,
        fetchStarted: AsyncStream<Void>.Continuation? = nil
    ) {
        self.failFirstFetch = failFirstFetch
        self.resetUIDs = resetUIDs
        self.emptyInbox = emptyInbox
        self.fetchStarted = fetchStarted
    }
    func openInbox(_ account: MailAccount) -> [IMAPConnection.Response] {
        attempts += 1
        return [
            .init(text: "* OK [UIDNEXT \(resetUIDs && attempts > 1 ? 3 : 42)]", literals: []),
            .init(text: "* OK [UIDVALIDITY \(resetUIDs && attempts > 1 ? 2 : 1)]", literals: []),
        ]
    }
    func search(_ criteria: String) -> [Int] {
        criteria.hasPrefix("SINCE") && !emptyInbox ? [resetUIDs && attempts > 1 ? 2 : 41] : []
    }
    func fetch(_ uids: [Int], account: MailAccount) async throws -> [IncomingMessage] {
        guard !uids.isEmpty else { return [] }
        requested.append(uids)
        if attempts == 1 && failFirstFetch { throw IMAPError.timeout }
        if let fetchStarted {
            await withCheckedContinuation {
                pendingFetch = $0
                fetchStarted.yield()
            }
        }
        return [
            IncomingMessage(
                text: "Your code is 482913", senderName: "Example", senderID: "example.com",
                sourceKey: account.id.uuidString, sourceLabel: "Test", date: Date(), isMail: true)
        ]
    }
    func idle(renewAfter: TimeInterval) async throws {
        if resetUIDs && attempts == 1 { throw IMAPError.timeout }
        try await Task.sleep(for: .seconds(60))
    }
    func command(_ cmd: String, timeout: TimeInterval) -> [IMAPConnection.Response] { [] }
    func close() {
        pendingFetch?.resume()
        pendingFetch = nil
    }
}

@Test @MainActor func mailboxUIDResetBackfillsCodesInTheNewNamespace() async {
    let inbox = InterruptedInbox(failFirstFetch: false, resetUIDs: true)
    let statuses = AsyncStream<SourceStatus>.makeStream()
    var delivered = [IncomingMessage]()
    let watcher = Task {
        await MailWatcher.watch(
            MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
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
        await MailWatcher.watch(
            MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
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
        await MailWatcher.watch(
            MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
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
        await MailWatcher.watch(
            MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
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
    let unreachable: Bool
    init(expireHistoryOnce: Bool = false, signInRevoked: Bool = false, unreachable: Bool = false) {
        self.expireHistoryOnce = expireHistoryOnce
        self.signInRevoked = signInRevoked
        self.unreachable = unreachable
    }
    func cursor() throws -> String {
        if signInRevoked { throw OAuth.Failure.token("invalid_grant") }
        return "100"
    }
    func inbox(since date: Date, limit: Int) -> [String] {
        backfills += 1
        return ["backfilled"]
    }
    func added(since cursor: String) throws -> (ids: [String], cursor: String) {
        historyChecks += 1
        if unreachable { throw URLError(.notConnectedToInternet) }
        if expireHistoryOnce && historyChecks == 1 { throw MailAPIError.cursorExpired }
        // The backfilled mail also shows up in the first history check, as it can when it lands mid-backfill.
        return (fetched.contains("new") ? [] : ["backfilled", "new"], "101")
    }
    func message(_ id: String, account: MailAccount) -> IncomingMessage? {
        fetched.append(id)
        return IncomingMessage(
            text: "Your code is 482913", senderName: "Example", senderID: "example.com",
            sourceKey: account.id.uuidString, sourceLabel: "Gmail", date: Date(), isMail: true, messageID: "gmail:\(id)")
    }
}

/// Watches until the "new" mail arrives, and returns every message the mailbox was asked for.
@MainActor private func gmailFetches(_ gmail: FakeGmail) async -> [String] {
    let delivered = AsyncStream<String?>.makeStream()
    let watcher = Task {
        await APIWatcher.watch(
            MailAccount(label: "Gmail", host: MailAccount.gmailHost, user: "test@gmail.com"),
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
        await APIWatcher.watch(
            MailAccount(label: "Gmail", host: MailAccount.gmailHost, user: "test@gmail.com"),
            status: { statuses.continuation.yield($0) }, deliver: { _ in },
            mailbox: FakeGmail(signInRevoked: true))
    }
    var reported: SourceStatus?
    for await status in statuses.stream where status != .connecting {
        reported = status
        break
    }
    watcher.cancel()
    await watcher.value
    #expect(reported == .failed(SourceStatus.signInExpired))
}

/// A resumed account makes no call before its first check: shown as working there, an unreachable
/// provider flickered between working and failed, and each failed try reset the retry backoff.
@Test @MainActor func resumedAccountIsNotLiveBeforeItsProviderAnswers() async {
    let statuses = AsyncStream<SourceStatus>.makeStream()
    let watcher = Task {
        await APIWatcher.watch(
            MailAccount(label: "Gmail", host: MailAccount.gmailHost, user: "test@gmail.com"), from: .cursor("100"),
            status: { statuses.continuation.yield($0) }, deliver: { _ in },
            mailbox: FakeGmail(unreachable: true))
    }
    var reported: SourceStatus?
    for await status in statuses.stream where status != .connecting {
        reported = status
        break
    }
    watcher.cancel()
    await watcher.value
    #expect(reported != .live)
}

/// The status shows in the menu's banner: a system error's own text there reads as gibberish.
@Test(
    arguments: [
        NWError.dns(-65554), NWError.posix(.ECONNREFUSED), NWError.posix(.ETIMEDOUT), NWError.tls(-9806),
        URLError(.notConnectedToInternet), URLError(.badServerResponse), MailAPIError.http(503, #"{"error":"backendError"}"#),
    ] as [any Error])
func rawSystemErrorTextNeverReachesTheSourceStatus(error: any Error) {
    let text = MailWatcher.describe(error)
    for raw in ["couldn’t be completed", "NWError", "NSURLErrorDomain", "{"] { #expect(!text.contains(raw)) }
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
    #expect(
        sqlite3_exec(
            db,
            """
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

/// Carrying on after sleep must not skip new texts: a saved ROWID counts only while the same message
/// is still there (a rebuilt or replaced database numbers its rows anew), else reading starts at the
/// history cutoff again.
@Test func messagesCarryOnFromTheirLastRowOnlyInTheSameDatabase() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("MessagesStoreTests-\(UUID()).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let now = Int64(Date().timeIntervalSinceReferenceDate * 1e9)
    /// Row 1 is older than the cutoff; the rest are recent.
    func write(_ rows: ClosedRange<Int>, guids: String, rebuilding: Bool = false) {
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let values = rows.map { "(\($0), '\(guids)\($0)', 'Your code is 48291\($0 % 10)', NULL, \($0 == 1 ? now - 3 * 86400 * 1_000_000_000 : now), 1, 0)" }
        #expect(
            sqlite3_exec(
                db,
                """
                CREATE TABLE IF NOT EXISTS handle (ROWID INTEGER PRIMARY KEY, id TEXT);
                CREATE TABLE IF NOT EXISTS message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, handle_id INTEGER, is_from_me INTEGER);
                INSERT OR IGNORE INTO handle VALUES (1, '+15550100');
                \(rebuilding ? "DELETE FROM message;" : "")
                INSERT INTO message VALUES \(values.joined(separator: ", "));
                """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
    }
    func read(after position: ReadPosition?) throws -> (ids: [String], position: ReadPosition?) {
        let store = MessagesStore(path: path, after: position)
        #expect(store.open(since: Date().addingTimeInterval(-86400)) == nil)
        return (try store.newMessages().compactMap(\.messageID), store.readPosition)
    }

    write(1...4, guids: "a")
    let first = try read(after: nil)
    #expect(first.ids == ["2", "3", "4"])
    write(5...5, guids: "a")
    #expect(try read(after: first.position).ids == ["5"])
    write(1...6, guids: "b", rebuilding: true)
    #expect(try read(after: first.position).ids == ["2", "3", "4", "5", "6"])
}

private actor BurstyAPIInbox: MailAPI {
    let completed: AsyncStream<String>.Continuation
    var failOnce: Bool
    let count: Int
    let failing: String
    var cursors: [String] = []
    init(failOnce: Bool, count: Int, failing: Int? = nil, completed: AsyncStream<String>.Continuation) {
        self.failOnce = failOnce
        self.count = count
        self.failing = String(failing ?? (count > 50 ? 58 : 8))
        self.completed = completed
    }
    func cursor() -> String { "start" }
    func inbox(since date: Date, limit: Int) -> [String] { [] }
    func added(since cursor: String) throws -> (ids: [String], cursor: String) {
        cursors.append(cursor)
        if cursor == "end" {
            completed.yield(cursor)
            throw CancellationError()
        }
        return ((1...count).map(String.init), "end")
    }
    func message(_ id: String, account: MailAccount) throws -> IncomingMessage? {
        if id == failing, failOnce {
            failOnce = false
            throw IMAPError.timeout
        }
        return burstMessage(id, account: account)
    }
}

private actor BurstyIMAPInbox: MailConnection {
    let capabilities: Set<String> = ["IDLE"]
    let completed: AsyncStream<String>.Continuation
    var failOnce: Bool
    let count: Int
    var fetches: [[Int]] = []
    init(failOnce: Bool, count: Int, completed: AsyncStream<String>.Continuation) {
        self.failOnce = failOnce
        self.count = count
        self.completed = completed
    }
    func openInbox(_ account: MailAccount) -> [IMAPConnection.Response] {
        [.init(text: "* OK [UIDVALIDITY 1]", literals: []), .init(text: "* OK [UIDNEXT 1]", literals: [])]
    }
    func search(_ criteria: String) throws -> [Int] {
        if criteria.hasPrefix("SINCE") { return [] }
        if criteria == "UID \(count + 1):*" {
            completed.yield(criteria)
            throw CancellationError()
        }
        let first = Int(criteria.dropFirst(4).prefix(while: { $0 != ":" }))!
        return Array(first...count)
    }
    func fetch(_ uids: [Int], account: MailAccount) throws -> [IncomingMessage] {
        guard !uids.isEmpty else { return [] }
        fetches.append(uids)
        if failOnce, uids.contains(count > 50 ? 58 : 8) {
            failOnce = false
            throw IMAPError.timeout
        }
        return uids.map { burstMessage(String($0), account: account) }
    }
    func idle(renewAfter: TimeInterval) {}
    func command(_ cmd: String, timeout: TimeInterval) -> [IMAPConnection.Response] { [] }
    func close() {}
}

private func burstMessage(_ id: String, account: MailAccount) -> IncomingMessage {
    IncomingMessage(
        text: "Your code is 482913", senderName: "Example", senderID: "example.com",
        sourceKey: account.id.uuidString, sourceLabel: "Test", date: Date(), isMail: true, messageID: id)
}

@Test(arguments: [false, true], [16, 76]) @MainActor
func apiCursorCannotSkipFreshMailAfterBurstOrFailedFetch(failOnce: Bool, count: Int) async {
    let completed = AsyncStream<String>.makeStream()
    let inbox = BurstyAPIInbox(failOnce: failOnce, count: count, completed: completed.continuation)
    var delivered: [String] = []
    let watcher = Task {
        await APIWatcher.watch(
            MailAccount(label: "Test", host: MailAccount.gmailHost, user: "test@example.invalid"),
            status: { _ in }, deliver: { if let id = $0.messageID { delivered.append(id) } },
            mailbox: inbox, poll: 0.001, retryDelay: 0)
    }
    // Only ends a hung watcher: a passing run stops at the end marker. With every test running at
    // once, CI's Intel runner needed close to 3 seconds here.
    let deadline = Task {
        try? await Task.sleep(for: .seconds(10))
        completed.continuation.finish()
    }
    var result: String?
    for await value in completed.stream {
        result = value
        break
    }
    watcher.cancel()
    deadline.cancel()
    await watcher.value
    #expect(result == "end")
    #expect(delivered == (1...count).map(String.init))
    #expect(await inbox.cursors.prefix(failOnce ? 3 : 2) == (failOnce ? ["start", "start", "end"] : ["start", "end"]))
}

@Test(arguments: [false, true], [16, 76]) @MainActor
func imapCursorCannotSkipFreshMailAfterBurstOrFailedFetch(failOnce: Bool, count: Int) async {
    let completed = AsyncStream<String>.makeStream()
    let inbox = BurstyIMAPInbox(failOnce: failOnce, count: count, completed: completed.continuation)
    var delivered: [String] = []
    let watcher = Task {
        await MailWatcher.watch(
            MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid"),
            status: { _ in }, deliver: { if let id = $0.messageID { delivered.append(id) } },
            connection: { inbox }, retryDelay: 0)
    }
    // Only ends a hung watcher: a passing run stops at the end marker. With every test running at
    // once, CI's Intel runner needed close to 3 seconds here.
    let deadline = Task {
        try? await Task.sleep(for: .seconds(10))
        completed.continuation.finish()
    }
    var result: String?
    for await value in completed.stream {
        result = value
        break
    }
    watcher.cancel()
    deadline.cancel()
    await watcher.value
    #expect(result == "UID \(count + 1):*")
    #expect(delivered == (1...count).map(String.init))
    var expected = stride(from: 1, through: count, by: 50).map { Array($0...min($0 + 49, count)) }
    if failOnce { expected.append(expected.last!) }
    #expect(await inbox.fetches == expected)
}

/// After sleep an inbox carries on from where it stopped instead of reading its history again, and a
/// long sleep reads no more than a fresh start would (the newest 60), even when a fetch fails and is
/// retried; an IMAP mailbox whose UIDs were reset starts over.
@Test(arguments: [(ReadPosition.uid(5, validity: 1), Array(17...76)), (.uid(5, validity: 2), Array(1...76)), (.cursor("resumed"), Array(17...76))])
@MainActor
func inboxCarriesOnAfterSleepWithoutRereadingHistory(from position: ReadPosition, expected: [Int]) async {
    let completed = AsyncStream<String>.makeStream()
    let account = MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid")
    var delivered: [String] = []
    var read: ReadPosition?
    let deliver: @MainActor (IncomingMessage) -> Void = { if let id = $0.messageID { delivered.append(id) } }
    let event: @MainActor (SourceEvent) -> Void = { if case .read(let position) = $0 { read = position } }
    let api = BurstyAPIInbox(failOnce: true, count: 76, failing: 70, completed: completed.continuation)
    let imap = BurstyIMAPInbox(failOnce: false, count: 76, completed: completed.continuation)
    let watcher = Task {
        if case .cursor = position {
            await APIWatcher.watch(account, from: position, status: { _ in }, deliver: deliver, event: event, mailbox: api, poll: 0.001, retryDelay: 0)
        } else {
            await MailWatcher.watch(account, from: position, status: { _ in }, deliver: deliver, event: event, connection: { imap }, retryDelay: 0)
        }
    }
    // Only ends a hung watcher: a passing run stops at the end marker.
    let deadline = Task {
        try? await Task.sleep(for: .seconds(10))
        completed.continuation.finish()
    }
    for await _ in completed.stream { break }
    watcher.cancel()
    deadline.cancel()
    await watcher.value
    #expect(delivered == expected.map(String.init))
    if case .cursor = position {
        #expect(await api.cursors == ["resumed", "resumed", "end"])
        #expect(read == .cursor("end"))
    } else {
        #expect(read == .uid(76, validity: 1))
    }
}

private actor GraphPages {
    var requests: [URL] = []
    let pages: [Data]
    init(_ pages: [[String: Any]]) throws {
        self.pages = try pages.map { try JSONSerialization.data(withJSONObject: $0) }
    }
    func send(_ request: URLRequest) throws -> Data {
        requests.append(request.url!)
        guard requests.count <= pages.count else { throw IMAPError.timeout }
        return pages[requests.count - 1]
    }
}

private let graphInbox = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages"

@Test(arguments: [graphInbox, "https://graph.microsoft.com/v1.0/users/mailbox-id/mailFolders/folder-id/messages"])
func outlookTimestampTiesCannotHideMailOnLaterPages(endpoint: String) async throws {
    let time = "2026-10-10T12:00:00Z"
    let first = (1...50).map { ["id": String($0), "receivedDateTime": time] }
    let last = [["id": "51", "receivedDateTime": time], ["id": "52", "receivedDateTime": "2026-10-10T12:00:01Z"]]
    let pages = try GraphPages([["value": first, "@odata.nextLink": endpoint + "?$skiptoken=opaque%2Btoken"], ["value": last]])
    let api = OutlookAPI(auth: .issued("fixture-unused"), send: { try await pages.send($0) })
    let result = try await api.added(since: time)
    #expect(result.ids == (1...52).map(String.init))
    #expect(result.cursor == "2026-10-10T12:00:01Z")
    #expect(await pages.requests.last?.absoluteString == endpoint + "?$skiptoken=opaque%2Btoken")
}

@Test(arguments: [
    "https://attacker.invalid/v1.0/me/mailFolders/inbox/messages?$skip=50",
    "http://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$skip=50",
    "https://graph.microsoft.com:8443/v1.0/me/mailFolders/inbox/messages?$skip=50",
    "https://attacker@graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$skip=50",
    "https://graph.microsoft.com/v1.0/me/messages?$skip=50#fragment",
])
func outlookUnsafeNextLinkCannotReceiveAnAuthenticatedRequest(nextLink: String) async throws {
    let pages = try GraphPages([
        [
            "value": [["id": "1", "receivedDateTime": "2026-10-10T12:00:00Z"]],
            "@odata.nextLink": nextLink,
        ]
    ])
    let api = OutlookAPI(auth: .issued("fixture-unused"), send: { try await pages.send($0) })
    await #expect(throws: (any Error).self) { try await api.added(since: "2026-10-10T11:00:00Z") }
    #expect(await pages.requests.count == 1)
}

@Test func outlookIncompletePageCannotAdvanceTheCursor() async throws {
    let pages = try GraphPages([
        [
            "value": [["id": "1", "receivedDateTime": "2026-10-10T12:00:00Z"]],
            "@odata.nextLink": graphInbox + "?$skip=50",
        ]
    ])
    let api = OutlookAPI(auth: .issued("fixture-unused"), send: { try await pages.send($0) })
    await #expect(throws: (any Error).self) { try await api.added(since: "2026-10-10T11:00:00Z") }
    #expect(await pages.requests.count == 2)
}

@Test func outlookPaginationCycleCannotPollForeverOrReturnPartialMail() async throws {
    let next = graphInbox + "?$skip=50"
    let pages = try GraphPages(Array(repeating: ["value": [], "@odata.nextLink": next], count: 3))
    let api = OutlookAPI(auth: .issued("fixture-unused"), send: { try await pages.send($0) })
    await #expect(throws: (any Error).self) { try await api.added(since: "2026-10-10T11:00:00Z") }
    #expect(await pages.requests.count == 2)
}

@Test func outlookLargeBacklogCannotStallAtAnArbitraryPageLimit() async throws {
    let pages = try GraphPages(
        (1...101).map {
            var page: [String: Any] = ["value": [["id": String($0), "receivedDateTime": "2026-10-10T12:00:00Z"]]]
            if $0 < 101 { page["@odata.nextLink"] = graphInbox + "?$skip=\($0)" }
            return page
        })
    let api = OutlookAPI(auth: .issued("fixture-unused"), send: { try await pages.send($0) })
    let result = try await api.added(since: "2026-10-10T11:00:00Z")
    #expect(result.ids == (1...101).map(String.init))
    #expect(result.cursor == "2026-10-10T12:00:00Z")
    #expect(await pages.requests.count == 101)
}

@Test func outlookMalformedPageCannotSilentlySkipMail() async throws {
    let pages = try GraphPages([["value": [["id": "missing-received-time"]]]])
    let api = OutlookAPI(auth: .issued("fixture-unused"), send: { try await pages.send($0) })
    await #expect(throws: (any Error).self) { try await api.added(since: "2026-10-10T11:00:00Z") }
}
