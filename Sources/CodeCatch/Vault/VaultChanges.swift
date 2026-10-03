import CodeCatchCore

/// Account metadata for review; secrets are compared but never included in the summary.
struct VaultChanges {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let account: String
        init(_ code: VaultCode) {
            id = code.id; name = code.name; account = code.username ?? code.domain ?? ""
        }
    }
    let added: [Entry]
    let changed: [Entry]
    let removed: [Entry]
    var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }

    init(before: [VaultCode], after: [VaultCode]) {
        let old = before.reduce(into: [String: VaultCode]()) { $0[$1.id] = $1 }
        let new = after.reduce(into: [String: VaultCode]()) { $0[$1.id] = $1 }
        added = after.filter { old[$0.id] == nil }.map(Entry.init)
        changed = after.filter { old[$0.id] != nil && old[$0.id] != $0 }.map(Entry.init)
        removed = before.filter { new[$0.id] == nil }.map(Entry.init)
    }
}
