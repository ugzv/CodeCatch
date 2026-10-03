import Combine
import Foundation

/// Remembers login identities only; codes, account names and search text stay in memory.
@MainActor
final class CodeSearch: ObservableObject {
    @Published private(set) var pins: Set<String>
    @Published private(set) var recents: [String]
    private let defaults: UserDefaults
    private static let pinsKey = "launcher.pins"
    private static let recentsKey = "launcher.recents"
    private static let limit = 8

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = Set(defaults.stringArray(forKey: Self.pinsKey) ?? [])
        recents = Array((defaults.stringArray(forKey: Self.recentsKey) ?? []).prefix(Self.limit))
    }

    func isPinned(_ item: CodeItem) -> Bool { item.origin == .vault && pins.contains(item.sourceKey) }

    func togglePin(_ item: CodeItem) {
        guard item.origin == .vault else { return }
        if !pins.insert(item.sourceKey).inserted { pins.remove(item.sourceKey) }
        defaults.set(pins.sorted(), forKey: Self.pinsKey)
    }

    func recordUse(_ item: CodeItem) {
        guard item.origin == .vault else { return }
        recents.removeAll { $0 == item.sourceKey }
        recents.insert(item.sourceKey, at: 0)
        recents = Array(recents.prefix(Self.limit))
        defaults.set(recents, forKey: Self.recentsKey)
    }

    func shortcuts(from items: [CodeItem]) -> [CodeItem] {
        let logins = items.filter { $0.origin == .vault }
        let pinned = logins.filter(isPinned).sorted { $0.service.localizedStandardCompare($1.service) == .orderedAscending }
        let recent = recents.compactMap { id in logins.first { $0.sourceKey == id && !isPinned($0) } }
        return Array((pinned + recent).prefix(Self.limit))
    }

    /// `secrets`: also match codes and message text; off while the app is locked.
    func ranked(_ items: [CodeItem], query: String, now: Date, secrets: Bool = true) -> [CodeItem] {
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return items.compactMap { item in score(item, query: query, secrets: secrets).map { (item: item, score: $0) } }
            .sorted { lhs, rhs in
                let a = lhs.item, b = rhs.item
                let aLive = now < a.expires, bLive = now < b.expires
                if aLive != bLive { return aLive }
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if isPinned(a) != isPinned(b) { return isPinned(a) }
                let aRecent = a.origin == .vault ? recents.firstIndex(of: a.sourceKey) ?? Int.max : Int.max
                let bRecent = b.origin == .vault ? recents.firstIndex(of: b.sourceKey) ?? Int.max : Int.max
                if aRecent != bRecent { return aRecent < bRecent }
                if a.received != b.received { return a.received > b.received }
                return a.dismissKey < b.dismissKey
            }.map(\.item)
    }

    private func score(_ item: CodeItem, query: String, secrets: Bool) -> Int? {
        guard !query.isEmpty else { return 0 }
        let fields = [item.service, item.domain ?? "", item.accountLabel, item.link?.host ?? ""].map(normalized)
        if fields.contains(query) { return 0 }
        if fields.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if fields.contains(where: { $0.contains(query) }) { return 2 }
        let context = normalized((fields + (secrets ? [item.code, item.preview] : []) + [item.sender, item.sourceLabel]).joined(separator: " "))
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { context.contains($0) } ? 3 : nil
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
