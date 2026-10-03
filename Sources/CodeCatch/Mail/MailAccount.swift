import Foundation

struct MailAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var host: String
    var port = 993
    var user: String
    var enabled = true
    /// Signed in with Google (XOAUTH2) instead of an app password. Optional so older saved accounts still decode.
    var googleSignIn: Bool?

    var secretKey: String { "\(user.lowercased())@\(host.lowercased())" }
    var password: String? { Secrets.get(secretKey) }
    var refreshTokenKey: String { secretKey + "#google" }
    var usesGoogle: Bool { googleSignIn == true }
    var hasCredential: Bool { usesGoogle ? Secrets.get(refreshTokenKey) != nil : password != nil }
    var isGmail: Bool { [Self.gmailHost, "imap.googlemail.com"].contains(host.lowercased()) }

    /// What IMAP signs in with: a fresh Google access token, or the app password.
    func auth() async throws -> IMAPConnection.Auth {
        if usesGoogle {
            guard let refresh = try Secrets.read(refreshTokenKey) else { throw GoogleOAuth.Failure.token("no refresh token") }
            return .accessToken(try await GoogleOAuth.accessToken(refresh: refresh))
        }
        guard let password else { throw GoogleOAuth.Failure.token("no password") }
        return .password(password)
    }

    static let gmailHost = "imap.gmail.com"
    static let appPasswordHelp = URL(string: "https://support.google.com/accounts/answer/185833")!

    static func guess(for user: String) -> MailAccount {
        let domain = user.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        let gmail = ["gmail.com", "googlemail.com"].contains(domain)
        return MailAccount(label: gmail ? "Gmail" : (domain.split(separator: ".").first.map { $0.capitalized } ?? domain),
                           host: gmail ? gmailHost : "imap.\(domain)", user: user)
    }

    private static let storeKey = "mailAccounts"
    static func load(from defaults: UserDefaults = .standard) -> [MailAccount] {
        guard let data = defaults.data(forKey: storeKey),
              let accounts = try? JSONDecoder().decode([MailAccount].self, from: data) else { return [] }
        return accounts
    }

    static func save(_ accounts: [MailAccount], in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: storeKey)
    }
}
