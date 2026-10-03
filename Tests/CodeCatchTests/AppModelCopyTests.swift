import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

private func copyVault(_ id: String = "saved-login",
                       secret: String = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") -> VaultCode {
    VaultCode(id: id, name: "Example", username: nil, domain: nil, secret: secret)
}

@MainActor private final class CopySink {
    var values: [String] = []
    var ids: [UUID] = []

    func copy(_ value: String, id: UUID) {
        values.append(value)
        ids.append(id)
    }
}

@MainActor private func withCopyModel(
    codes: @escaping () -> [VaultCode],
    _ body: (AppModel, VaultSession, CodeSearch, CopySink) async throws -> Void
) async throws {
    let suite = "AppModelCopyTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let search = CodeSearch(defaults: defaults)
    let session = VaultSession(authenticate: {}, read: codes, write: { _ in }, remove: {})
    let sink = CopySink()
    let model = AppModel(vaultSession: session, search: search, defaults: defaults, copyToClipboard: sink.copy)
    try await body(model, session, search, sink)
}

@MainActor @Suite struct AppModelCopyTests {
    @Test func lockedVaultRejectsBothSuppliedAndPreviouslyVisibleRows() async throws {
        let vault = copyVault()
        let date = Date(timeIntervalSince1970: 60)
        let supplied = try #require(CodeItem(vault, at: date))
        try await withCopyModel(codes: { [vault] }) { model, session, search, sink in
            model.copy(supplied, at: date)
            #expect(sink.values.isEmpty)
            #expect(search.recents.isEmpty)

            try await session.unlock()
            let retained = try #require(model.vaultItems.first)
            session.lock()
            model.copy(retained, at: date)

            #expect(sink.values.isEmpty)
            #expect(search.recents.isEmpty)
        }
    }

    @Test func staleRowCopiesCurrentSessionsSecretAtCurrentTime() async throws {
        let earlier = Date(timeIntervalSince1970: 59)
        let now = Date(timeIntervalSince1970: 60)
        let staleVault = copyVault()
        let currentVault = copyVault(secret: "JBSWY3DPEHPK3PXP")
        let staleRow = try #require(CodeItem(staleVault, at: earlier))
        let currentTOTP = try #require(currentVault.totp)
        let expected = currentTOTP.code(at: now)
        #expect(expected != staleRow.copyValue)
        #expect(expected != currentTOTP.code(at: earlier))
        #expect(expected != (try #require(staleVault.totp)).code(at: now))

        try await withCopyModel(codes: { [currentVault] }) { model, session, search, sink in
            try await session.unlock()
            model.copy(staleRow, at: now)

            #expect(sink.values == [expected])
            #expect(sink.ids == [staleRow.id])
            #expect(search.recents == [currentVault.id])
        }
    }

    @Test func unknownAndRemovedLoginsCannotCopyOrEnterRecents() async throws {
        let vault = copyVault()
        let date = Date(timeIntervalSince1970: 60)
        let unknown = try #require(CodeItem(copyVault("unknown-login"), at: date))
        var stored = [vault]
        try await withCopyModel(codes: { stored }) { model, session, search, sink in
            try await session.unlock()
            let retained = try #require(model.vaultItems.first)
            model.copy(unknown, at: date)
            #expect(sink.values.isEmpty)
            #expect(search.recents.isEmpty)

            session.lock()
            stored = []
            try await session.unlock()
            model.copy(retained, at: date)

            #expect(sink.values.isEmpty)
            #expect(search.recents.isEmpty)
        }
    }

    /// A locked app must not hand out a received code, and a refused authentication must not run the action.
    @Test func receivedCodeCopiesOnlyAfterAuthentication() async throws {
        let item = CodeItem(IncomingMessage(text: "Your code is 482913", senderName: "", senderID: "Example", sourceKey: "s",
                                            sourceLabel: "Messages", date: Date(), isMail: false), code: "482913", link: nil)
        var allowed = false
        let session = VaultSession(authenticate: { if !allowed { throw CancellationError() } }, read: { [] }, write: { _ in }, remove: {})
        let suite = "AppModelCopyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sink = CopySink()
        let model = AppModel(vaultSession: session, search: CodeSearch(defaults: defaults), defaults: defaults, copyToClipboard: sink.copy)

        model.copy(item)
        await model.unlocked { model.copy(item) }?.value
        #expect(sink.values.isEmpty)
        #expect(!model.isUnlocked)

        allowed = true
        await model.unlocked { model.copy(item) }?.value
        #expect(sink.values == ["482913"])

        session.lock()
        model.copy(item)
        #expect(sink.values == ["482913"])
    }
}
