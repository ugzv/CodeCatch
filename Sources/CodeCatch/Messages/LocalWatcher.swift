import Foundation
import SQLite3

/// A database on this Mac that needs Full Disk Access: Messages' chat.db or Apple Mail's index.
protocol LocalStore: AnyObject {
    /// For the status: "Can't read Messages".
    var name: String { get }
    /// How far the store has been read (a ROWID).
    var position: Int64 { get }
    /// Opens the store for messages from `since` on; returns what is in the way when it can't.
    func open(since: Date) -> String?
    func newMessages() throws -> [IncomingMessage]
    func close()
}

/// Polls a local store (read-only) once a second for new incoming messages.
final class LocalWatcher {
    private let store: LocalStore
    private let queue = DispatchQueue(label: "local-store")
    private var timer: DispatchSourceTimer?
    private var isOpen = false
    private var retryAt = Date.distantPast
    private var lastStatus: SourceStatus?

    init(_ store: LocalStore) { self.store = store }

    func start(lookback: TimeInterval, status: @escaping @MainActor (SourceStatus) -> Void,
               deliver: @escaping @MainActor (IncomingMessage) -> Void,
               event: @escaping @MainActor (SourceEvent) -> Void = { _ in }) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.poll(lookback: lookback, status: status, deliver: deliver, event: event) }
        t.resume()
        timer = t
    }

    /// For knowing when the watcher has caught up.
    var position: Int64 { queue.sync { store.position } }

    func stop() {
        timer?.cancel()
        queue.async { [store] in store.close() }
    }

    private func poll(lookback: TimeInterval, status: @escaping @MainActor (SourceStatus) -> Void,
                      deliver: @escaping @MainActor (IncomingMessage) -> Void,
                      event: @escaping @MainActor (SourceEvent) -> Void) {
        func report(_ s: SourceStatus) {
            guard s != lastStatus else { return }
            lastStatus = s
            Task { @MainActor in status(s) }
        }
        func retry(_ s: SourceStatus) {
            store.close()
            isOpen = false
            retryAt = Date().addingTimeInterval(5)
            let retry = retryAt
            Task { @MainActor in event(.retry(retry)) }
            report(s)
        }
        if !isOpen {
            guard Date() >= retryAt else { return }
            if let problem = store.open(since: Date().addingTimeInterval(-lookback)) { return retry(.attention(problem)) }
            isOpen = true
            Task { @MainActor in event(.retry(nil)) }
        }
        do {
            let messages = try store.newMessages()
            let checkedAt = Date()
            report(.live)
            Task { @MainActor in
                event(.checked(checkedAt))
                if let newest = messages.map(\.date).max() { event(.message(newest)) }
                for message in messages { deliver(message) }
            }
        } catch {
            retry(.failed("Can't read \(store.name)"))
        }
    }
}

/// A SQLite database opened read-only.
final class SQLiteReader {
    struct Failure: Error {}
    private var db: OpaquePointer?

    init?(path: String) {
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    func query<T>(_ sql: String, _ arg: Int64 = 0, row: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, arg)
        var out: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: out.append(row(stmt))
            case SQLITE_DONE: return out
            default: throw Failure()
            }
        }
    }
}
