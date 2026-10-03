import CodeCatchCore
import Foundation
import SQLite3

/// The Mail app's own store (~/Library/Mail): every inbox Mail already fetches, with no
/// account or password to set up here. Read-only, so nothing is marked or moved.
final class AppleMailStore: LocalStore {
    static let sourceKey = "applemail"
    /// Mail lists a message before it has downloaded the body: look again for this long.
    static let bodyWait: TimeInterval = 60
    /// Codes live in the text, not attachments: the first 256 KB is enough, as for IMAP.
    static let readLimit = 262_144

    let name = "Apple Mail"
    private(set) var position: Int64 = 0
    private let root: URL
    private var version: URL?
    private var db: SQLiteReader?
    private var since = Date.distantPast
    /// Messages delivered from their subject alone, until their body arrives or the wait ends.
    private var waiting: [Int64: Date] = [:]

    init(root: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mail")) { self.root = root }

    func open(since: Date) -> String? {
        let notSetUp = "Add an account in Mail"
        let versions: [String]
        do { versions = try FileManager.default.contentsOfDirectory(atPath: root.path) } catch CocoaError.fileReadNoSuchFile {
            return notSetUp
        } catch { return SourceStatus.needsDiskAccess }
        // "V10": the store's layout version; Mail keeps only the current one up to date.
        guard let newest = versions.compactMap({ name in Int(name.dropFirst()).flatMap { name.hasPrefix("V") ? ($0, name) : nil } })
            .max(by: { $0.0 < $1.0 })?.1 else { return notSetUp }
        let version = root.appendingPathComponent(newest)
        let index = version.appendingPathComponent("MailData/Envelope Index").path
        guard FileManager.default.fileExists(atPath: index) else { return notSetUp }
        guard let db = SQLiteReader(path: index) else { return SourceStatus.needsDiskAccess }
        guard let inboxes = try? db.query("SELECT COUNT(*) FROM mailboxes WHERE \(Self.isInbox)", row: { sqlite3_column_int64($0, 0) }).first
        else { return "Can't read Apple Mail" }
        guard inboxes > 0 else { return notSetUp }
        (self.db, self.version, self.since, position, waiting) = (db, version, since, 0, [:])
        return nil
    }

    func close() { db = nil }

    private static let isInbox = "lower(url) LIKE '%/inbox'"

    /// The newest 60 since the last look (after a long gap only those can still hold a live code),
    /// and any message still waiting for its body.
    func newMessages() throws -> [IncomingMessage] {
        guard let db, let version else { return [] }
        let top = try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM messages") { sqlite3_column_int64($0, 0) }.first ?? position
        let now = Date()
        waiting = waiting.filter { $0.value > now }
        func text(_ s: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(s, column).map { String(cString: $0) } ?? "" }
        func rows(_ filter: String, limit: String = "") throws -> [IncomingMessage] {
            let sql = """
                SELECT m.ROWID, m.date_received, COALESCE(a.address, ''), COALESCE(a.comment, ''),
                       COALESCE(m.subject_prefix, '') || COALESCE(s.subject, ''), COALESCE(y.summary, ''), b.url
                FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox
                LEFT JOIN addresses a ON a.ROWID = m.sender LEFT JOIN subjects s ON s.ROWID = m.subject
                LEFT JOIN summaries y ON y.ROWID = m.summary
                WHERE \(filter) AND m.deleted = 0 AND m.date_received > \(Int64(since.timeIntervalSince1970)) AND \(Self.isInbox)
                ORDER BY m.date_received DESC \(limit)
                """
            return try db.query(sql, position) { s -> IncomingMessage? in
                let id = sqlite3_column_int64(s, 0)
                let mail = Self.body(of: id, mailbox: text(s, 6), in: version).map(MIME.parse)
                if mail != nil {
                    waiting[id] = nil
                } else if waiting[id] != nil {
                    return nil  // already delivered without its body
                } else {
                    waiting[id] = now.addingTimeInterval(Self.bodyWait)
                }
                return IncomingMessage(text: mail?.text ?? text(s, 5), subject: mail?.subject ?? text(s, 4),
                                       senderName: mail?.fromName ?? text(s, 3), senderID: mail?.fromAddress ?? text(s, 2),
                                       sourceKey: Self.sourceKey, sourceLabel: name,
                                       date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 1))), isMail: true,
                                       links: mail?.links ?? [], messageID: String(id))
            }.compactMap { $0 }.reversed()
        }
        let late = waiting.isEmpty ? [] : try rows("m.ROWID IN (\(waiting.keys.map(String.init).joined(separator: ",")))")
        let new = try rows("m.ROWID > ?1 AND m.ROWID <= \(top)", limit: "LIMIT 60")
        position = top
        return late + new
    }

    /// The raw message from `<account>/<mailbox>.mbox/<store>/Data/3/2/1/Messages/123456.emlx`
    /// (the thousands of the ROWID, reversed), or its `.partial.emlx` without attachments.
    static func body(of id: Int64, mailbox: String, in version: URL) -> Data? {
        guard let url = URL(string: mailbox), let account = url.host else { return nil }
        let box = url.pathComponents.dropFirst().reduce(version.appendingPathComponent(account)) { $0.appendingPathComponent($1 + ".mbox") }
        let shards = id < 1000 ? [] : String(id / 1000).reversed().map(String.init)
        for store in (try? FileManager.default.contentsOfDirectory(atPath: box.path)) ?? [] {
            let messages = shards.reduce(box.appendingPathComponent(store).appendingPathComponent("Data")) { $0.appendingPathComponent($1) }
                .appendingPathComponent("Messages")
            for name in ["\(id).emlx", "\(id).partial.emlx"] {
                guard let file = try? FileHandle(forReadingFrom: messages.appendingPathComponent(name)) else { continue }
                defer { try? file.close() }
                if let data = try? file.read(upToCount: readLimit), let message = message(inEMLX: data) { return message }
            }
        }
        return nil
    }

    /// An .emlx file is the message's byte count on a line, the message, then a property list.
    /// Nil while Mail is still writing it: fewer bytes than promised, short of the 256 KB read.
    static func message(inEMLX data: Data) -> Data? {
        guard let newline = data.firstIndex(of: 0x0A),
              let length = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)), length >= 0
        else { return nil }
        let message = data[(newline + 1)...].prefix(length)
        return message.count == length || data.count >= readLimit ? Data(message) : nil
    }
}
