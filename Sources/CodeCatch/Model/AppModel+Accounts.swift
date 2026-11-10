import Foundation

/// Saving and removing mail accounts: credentials go into the Keychain before the account list changes.
extension AppModel {
    /// Adds the account, or replaces the saved one with the same id.
    func save(_ account: MailAccount) {
        let unchanged = accounts.contains(account)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        // A password or refresh token can change without changing account metadata.
        if unchanged { monitor.check(account.id.uuidString) }
    }

    enum AccountSaveError: LocalizedError {
        case duplicate
        var errorDescription: String? { "This mail account is already saved. Edit the existing account instead." }
    }

    /// Persist credentials before publishing metadata; never mutate another account's keys.
    func saveAccount(_ account: MailAccount, password: String, refreshToken: String?, keychain: AccountKeychain = .login) throws {
        guard !accounts.contains(where: { $0.id != account.id && $0.secretKey == account.secretKey }) else {
            throw AccountSaveError.duplicate
        }
        var account = account
        if let refreshToken {
            try keychain.write(refreshToken, account.refreshTokenKey)
            // The cached access token belongs to the old sign-in and its permissions.
            OAuth.forgetAccessToken(tokenKey: account.refreshTokenKey)
            account.signedIn = true
        } else if !account.usesSignIn {
            if !password.isEmpty { try keychain.write(password, account.secretKey) }
            try forgetSignIn(account, keychain)
        }
        save(account)
    }

    func remove(_ account: MailAccount, keychain: AccountKeychain = .login) throws {
        guard let saved = accounts.first(where: { $0.id == account.id }) else { return }
        if !accounts.contains(where: { $0.id != saved.id && $0.secretKey == saved.secretKey }) {
            try keychain.remove(saved.secretKey)
            try forgetSignIn(saved, keychain)
        }
        accounts.removeAll { $0.id == saved.id }
    }

    /// After an identity edit, remove old credentials only when no saved account uses them.
    func removeUnusedCredentials(for account: MailAccount, keychain: AccountKeychain = .login) throws {
        guard !accounts.contains(where: { $0.secretKey == account.secretKey }) else { return }
        try keychain.remove(account.secretKey)
        try forgetSignIn(account, keychain)
    }

    /// A sign-in CodeCatch forgets also ends on the provider's side, once it is gone from the Keychain.
    private func forgetSignIn(_ account: MailAccount, _ keychain: AccountKeychain) throws {
        let token = keychain.read(account.refreshTokenKey)
        try keychain.remove(account.refreshTokenKey)
        OAuth.forgetAccessToken(tokenKey: account.refreshTokenKey)
        if let token, let provider = account.provider { keychain.revoke(provider, token) }
    }
}

/// The Keychain and provider calls that saving or removing a mail account makes; tests pass their own.
struct AccountKeychain {
    var read: (String) -> String?
    var write: (String, String) throws -> Void
    var remove: (String) throws -> Void
    /// Ends a sign-in on the provider's side.
    var revoke: (OAuth, String) -> Void

    static var login: AccountKeychain {
        AccountKeychain(
            read: Secrets.get, write: { try Secrets.set($0, for: $1) }, remove: Secrets.remove,
            revoke: { provider, token in Task { await provider.revoke(token) } })
    }
}
