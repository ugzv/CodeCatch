import Testing
@testable import CodeCatch
@testable import CodeCatchCore

@Test func vaultReviewDetectsSecretRotationAndRemovalWithoutTreatingReorderingAsChanges() {
    func code(_ id: String, secret: String = "old") -> VaultCode {
        VaultCode(id: id, name: id, username: "account", domain: nil, secret: secret)
    }
    let before = [code("same"), code("rotate"), code("remove")]
    let changes = VaultChanges(before: before, after: [code("rotate", secret: "new"), code("same"), code("add")])
    #expect(changes.added.map(\.id) == ["add"])
    #expect(changes.changed.map(\.id) == ["rotate"])
    #expect(changes.removed.map(\.id) == ["remove"])
    #expect(VaultChanges(before: before, after: before.reversed()).isEmpty)
}
