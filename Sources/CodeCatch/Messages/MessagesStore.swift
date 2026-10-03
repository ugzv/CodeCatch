import CodeCatchCore
import Foundation
import SQLite3

/// ~/Library/Messages/chat.db: incoming iMessages and forwarded SMS.
final class MessagesStore: LocalStore {
    static let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
    static let sourceKey = "messages"

    let name = "Messages"
    private(set) var position: Int64 = 0
    private var db: SQLiteReader?

    /// Starts at the last ROWID before `since`.
    func open(since: Date) -> String? {
        guard let db = SQLiteReader(path: Self.dbPath),
              let start = try? db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message WHERE date < ?1",
                                        Int64(since.timeIntervalSinceReferenceDate * 1e9), row: { sqlite3_column_int64($0, 0) }).first
        else { return SourceStatus.needsDiskAccess }
        self.db = db
        position = start
        return nil
    }

    func close() { db = nil }

    func newMessages() throws -> [IncomingMessage] {
        guard let db else { return [] }
        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.date, COALESCE(h.id, ''), m.is_from_me
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID > ?1 ORDER BY m.ROWID LIMIT 200
            """
        return try db.query(sql, position) { s -> IncomingMessage? in
            position = sqlite3_column_int64(s, 0)
            guard sqlite3_column_int(s, 5) == 0 else { return nil }
            var text = sqlite3_column_text(s, 1).map { String(cString: $0) } ?? ""
            if text.isEmpty, let blob = sqlite3_column_blob(s, 2) {
                text = TypedStream.text(fromAttributedBody: Data(bytes: blob, count: Int(sqlite3_column_bytes(s, 2)))) ?? ""
            }
            guard !text.isEmpty else { return nil }
            let raw = sqlite3_column_int64(s, 3)
            let date = Date(timeIntervalSinceReferenceDate: raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw))
            let handle = String(cString: sqlite3_column_text(s, 4))
            return IncomingMessage(text: text, subject: nil, senderName: "", senderID: handle,
                                   sourceKey: Self.sourceKey, sourceLabel: "Messages", date: date, isMail: false,
                                   messageID: String(position))
        }.compactMap { $0 }
    }
}
