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
    private enum CodingKeys: String, CodingKey {
        case id, label, host, port, user, enabled
        case signedIn = "googleSignIn"
    }

    var secretKey: String { "\(user.lowercased())@\(host.lowercased())" }
    var password: String? { Secrets.get(secretKey) }
    /// Where the sign-in's refresh token is kept; the suffix predates Microsoft sign-in.
    var refreshTokenKey: String { secretKey + "#google" }
    var usesSignIn: Bool { signedIn == true }
    var hasCredential: Bool { usesSignIn ? Secrets.get(refreshTokenKey) != nil : password != nil }
    var isGmail: Bool { [Self.gmailHost, "imap.googlemail.com"].contains(host.lowercased()) }
    var isOutlook: Bool { [Self.outlookHost, "imap-mail.outlook.com"].contains(host.lowercased()) }
    /// NetEase's 163 or 126 mailbox, which takes a client authorization code instead of the password.
    var isNetEase: Bool { Self.netEaseHosts.values.contains(host.lowercased()) }
    /// Who this account can sign in with.
    var provider: OAuth? { isGmail ? .google : isOutlook ? .microsoft : nil }
    /// The site whose logo stands for this mailbox: the provider's, not the address's (you@company.com on Gmail is Gmail).
    var iconDomain: String { isGmail ? "gmail.com" : isOutlook ? "outlook.com" : ServiceIdentity.registrable(host) }

    static let gmailHost = "imap.gmail.com"
    static let outlookHost = "outlook.office365.com"
    static let netEase163Host = "imap.163.com"
    static let netEase126Host = "imap.126.com"
    /// The IMAP servers for NetEase's two public mailboxes. Both use TLS on port 993 and want a
    /// client authorization code; the password used on the website is turned down.
    static let netEaseHosts = ["163.com": netEase163Host, "126.com": netEase126Host]
    static let appPasswordHelp = URL(string: "https://support.google.com/accounts/answer/185833")!
    /// NetEase's own instructions for turning on IMAP and making a client authorization code.
    static let netEaseHelp = URL(
        string: "https://help.mail.163.com/faqDetail.do?code=d7a5dc8471cd0c0e8b4b8f4f8e49998b374173cfe9171305fa1ce630d7f67ac2a5feb28b66796d3b")!

    static func guess(for user: String) -> MailAccount {
        let domain = user.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        let gmail = ["gmail.com", "googlemail.com"].contains(domain)
        let outlook = ["outlook.com", "hotmail.com", "live.com", "msn.com"].contains(domain)
        let netEase = netEaseHosts[domain]
        return MailAccount(
            label: gmail ? "Gmail" : outlook ? "Outlook" : (domain.split(separator: ".").first.map { $0.capitalized } ?? domain),
            host: gmail ? gmailHost : outlook ? outlookHost : netEase ?? "imap.\(domain)", user: user)
    }

    private static let storeKey = "mailAccounts"
    static func load(from defaults: UserDefaults = .standard) -> [MailAccount] {
        guard let data = defaults.data(forKey: storeKey),
            let accounts = try? JSONDecoder().decode([MailAccount].self, from: data)
        else { return [] }
        return accounts
    }

    static func save(_ accounts: [MailAccount], in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: storeKey)
    }
}
