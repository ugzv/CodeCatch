@testable import CodeCatchCore
import Foundation
import Testing
@testable import CodeCatch

private let searchNow = Date(timeIntervalSince1970: 1_700_000_000)

private func searchItem(_ key: String, service: String, origin: CodeItem.Origin = .mail,
                        account: String = "Work", domain: String? = nil, preview: String = "",
                        expired: Bool = false) -> CodeItem {
    CodeItem(origin: origin, code: "593821", link: nil, service: service, sourceLabel: "Test",
             sourceKey: key, accountLabel: account, sender: "", preview: preview, snippet: preview,
             received: searchNow.addingTimeInterval(-10), expires: searchNow.addingTimeInterval(expired ? -1 : 30),
             domain: domain, dismissKey: key)
}

@MainActor private func withSearch(_ body: (CodeSearch, UserDefaults, String) throws -> Void) throws {
    let suite = "CodeSearchTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(CodeSearch(defaults: defaults), defaults, suite)
}

@Test @MainActor func exactReceivedMatchPrecedesPinnedVaultPrefixAndSubstring() throws {
    try withSearch { search, _, _ in
        let exact = searchItem("exact", service: "Acme")
        let prefix = searchItem("prefix", service: "Acme Personal", origin: .vault)
        let substring = searchItem("substring", service: "My Acme")
        let unrelated = searchItem("unrelated", service: "Other")
        search.togglePin(prefix)
        search.recordUse(prefix)
        #expect(search.ranked([substring, prefix, unrelated, exact], query: "  aCmE  ", now: searchNow).map(\.sourceKey)
                == ["exact", "prefix", "substring"])
    }
}

@Test(arguments: ["git.example", "work@example.com"])
@MainActor func exactDomainOrAccountMatchPrecedesMessageContext(_ query: String) throws {
    try withSearch { search, _, _ in
        let exact = searchItem("exact", service: "Git", origin: .vault, account: "work@example.com", domain: "git.example")
        let context = searchItem("context", service: "Other", preview: "Your \(query) verification")
        #expect(search.ranked([context, exact], query: query, now: searchNow).map(\.sourceKey) == ["exact", "context"])
        #expect(search.ranked([exact], query: "git work@example.com", now: searchNow).count == 1)
    }
}

@Test @MainActor func expiredExactMatchCannotDisplaceAUsableCode() throws {
    try withSearch { search, _, _ in
        let expired = searchItem("expired", service: "Acme", expired: true)
        let live = searchItem("live", service: "Acme Work")
        #expect(search.ranked([expired, live], query: "acme", now: searchNow).map(\.sourceKey) == ["live", "expired"])
        #expect(search.ranked([expired], query: "acme", now: searchNow).first?.sourceKey == "expired")
    }
}

@Test @MainActor func launcherPersistenceStoresOnlyVaultIDsAndNeverReceivedCodesOrAccountDetails() throws {
    try withSearch { search, defaults, suite in
        let vault = searchItem("vault-identity", service: "Private Service", origin: .vault, account: "private@example.com")
        let received = searchItem("received-identity", service: "Private Service")
        search.togglePin(vault)
        search.recordUse(vault)
        search.recordUse(vault)
        search.togglePin(received)
        search.recordUse(received)
        let stored = try #require(defaults.persistentDomain(forName: suite))
        #expect(stored.count == 2)
        for value in stored.values { #expect(value as? [String] == ["vault-identity"]) }
        let restored = CodeSearch(defaults: defaults)
        #expect(restored.pins == ["vault-identity"])
        #expect(restored.recents == ["vault-identity"])
        restored.togglePin(vault)
        #expect(CodeSearch(defaults: defaults).pins.isEmpty)
    }
}

@Test @MainActor func shortcutsPreferPinsDeduplicateRecentLoginsAndCapTheList() throws {
    try withSearch { search, _, _ in
        let items = (0...10).map { searchItem("vault-\($0)", service: "Service \($0)", origin: .vault) }
        for item in items { search.recordUse(item) }
        search.togglePin(items[10])
        #expect(search.recents.count == 8)
        #expect(search.shortcuts(from: items).map(\.sourceKey) == (3...10).reversed().map { "vault-\($0)" })
        #expect(search.shortcuts(from: Array(items.prefix(3))).isEmpty)
    }
}

@Test func vaultRowIdentityAndAccountSurviveCodeRotation() throws {
    let vault = VaultCode(id: "non-uuid-login", name: "Example", username: "work@example.com", domain: "example.com",
                          secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    let previous = try #require(CodeItem(vault, at: Date(timeIntervalSince1970: 59)))
    let current = try #require(CodeItem(vault, at: Date(timeIntervalSince1970: 60)))
    #expect(previous.id == current.id)
    #expect(previous.sourceKey == vault.id)
    #expect(current.accountLabel == vault.username)
    #expect(previous.code != current.code)
}

@Test @MainActor func unlockedVaultSuppliesLoginsToUnifiedSearchAndLockRemovesThem() async throws {
    let codes = [VaultCode(id: "login", name: "Example", username: "work@example.com", domain: "example.com",
                           secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")]
    let session = VaultSession(authenticate: {}, read: { codes }, write: { _ in }, remove: {})
    let suite = "CodeSearchTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(vaultSession: session, defaults: defaults)
    #expect(model.vaultItems.isEmpty)
    try await session.unlock()
    #expect(model.vaultItems.map(\.sourceKey) == ["login"])
    #expect(model.search.ranked(model.vaultItems, query: "work@", now: model.now).count == 1)
    #expect(model.search.ranked(model.vaultItems, query: "unrelated", now: model.now).isEmpty)
    session.lock()
    #expect(model.vaultItems.isEmpty)
}

/// Typing a code's digits or message text while locked must not surface its row.
@Test @MainActor func lockedSearchMatchesNamesButNotCodesOrMessageText() throws {
    try withSearch { search, _, _ in
        let item = searchItem("acme", service: "Acme", preview: "Your login code")
        #expect(search.ranked([item], query: "593821", now: searchNow, secrets: false).isEmpty)
        #expect(search.ranked([item], query: "login", now: searchNow, secrets: false).isEmpty)
        #expect(search.ranked([item], query: "acme", now: searchNow, secrets: false).count == 1)
        #expect(search.ranked([item], query: "593821", now: searchNow).count == 1)
    }
}
