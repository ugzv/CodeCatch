import CodeCatchCore
import Foundation

struct MailAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var host: String
    var port = 993
    var user: String
    var enabled = true
    /// Signed in with the provider (Google or Microsoft, by host) and read through its API instead of IMAP.
    /// Optional so older saved accounts still decode.
    var signedIn: Bool?

    /// `signedIn` is saved under its first name, from when only Google had sign-in.
    private enum CodingKeys: String, CodingKey { case id, label, host, port, user, enabled, signedIn = "googleSignIn" }

    var secretKey: String { "\(user.lowercased())@\(host.lowercased())" }
    var password: String? { Secrets.get(secretKey) }
    /// Where the sign-in's refresh token is kept; the suffix predates Microsoft sign-in.
    var refreshTokenKey: String { secretKey + "#google" }
    var usesSignIn: Bool { signedIn == true }
    var hasCredential: Bool { usesSignIn ? Secrets.get(refreshTokenKey) != nil : password != nil }
    var isGmail: Bool { [Self.gmailHost, "imap.googlemail.com"].contains(host.lowercased()) }
    var isOutlook: Bool { [Self.outlookHost, "imap-mail.outlook.com"].contains(host.lowercased()) }
    /// Who this account can sign in with.
    var provider: OAuth? { isGmail ? .google : isOutlook ? .microsoft : nil }
    /// The site whose logo stands for this mailbox: the provider's, not the address's (you@company.com on Gmail is Gmail).
    var iconDomain: String { isGmail ? "gmail.com" : isOutlook ? "outlook.com" : ServiceIdentity.registrable(host) }

    static let gmailHost = "imap.gmail.com"
    static let outlookHost = "outlook.office365.com"
    static let appPasswordHelp = URL(string: "https://support.google.com/accounts/answer/185833")!

    static func guess(for user: String) -> MailAccount {
        let domain = user.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        let gmail = ["gmail.com", "googlemail.com"].contains(domain)
        let outlook = ["outlook.com", "hotmail.com", "live.com", "msn.com"].contains(domain)
        return MailAccount(label: gmail ? "Gmail" : outlook ? "Outlook" : (domain.split(separator: ".").first.map { $0.capitalized } ?? domain),
                           host: gmail ? gmailHost : outlook ? outlookHost : "imap.\(domain)", user: user)
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
