import CodeCatchCore
import Combine
import Foundation

/// A small, memory-only fallback. These messages never become detected codes or alerts.
@MainActor
final class RecoveryInbox: ObservableObject {
    struct Entry: Identifiable {
        let id: UUID
        let message: IncomingMessage
        let truncated: Bool
    }

    static let lifetime: TimeInterval = 30 * 60
    @Published private(set) var entries: [Entry] = []
    var onRemove: (Set<UUID>) -> Void = { _ in }

    func record(_ message: IncomingMessage, at date: Date = Date()) {
        prune(at: date)
        guard message.isMail, (0..<Self.lifetime).contains(date.timeIntervalSince(message.date)) else { return }
        var bounded = message
        bounded.text = String(message.text.prefix(16_000))
        bounded.subject = message.subject.map { String($0.prefix(1_000)) }
        bounded.links = []
        guard CodeExtractor.hasCodeContext(in: bounded.fullText) else { return }
        let id = entries.first { $0.message.dismissKey == message.dismissKey }?.id ?? UUID()
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, message: bounded, truncated: bounded.text != message.text || bounded.subject != message.subject))
        entries.sort { $0.message.date > $1.message.date }
        let overflow = Set(entries.dropFirst(20).map(\.id))
        remove { overflow.contains($0.id) }
    }

    func prune(at date: Date = Date()) {
        remove { !(0..<Self.lifetime).contains(date.timeIntervalSince($0.message.date)) }
    }

    func removeAll() { remove { _ in true } }
    func remove(sourceKey: String) { remove { $0.message.sourceKey == sourceKey } }
    func remove(sender: String) { remove { $0.message.senderID.lowercased() == sender.lowercased() } }
    func remove(messageKey: String) { remove { $0.message.dismissKey == messageKey } }
    func retainSources(_ keys: Set<String>) { remove { !keys.contains($0.message.sourceKey) } }

    private func remove(where predicate: (Entry) -> Bool) {
        let ids = Set(entries.filter(predicate).map(\.id))
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        onRemove(ids)
    }
}
