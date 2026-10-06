import CodeCatchCore
import Foundation

extension IMAPConnection {
    init(account: MailAccount) throws { try self.init(host: account.host, port: account.port) }

    /// Signs in and opens the INBOX read-only (EXAMINE): CodeCatch never changes mail.
    @discardableResult
    func openInbox(_ account: MailAccount) async throws -> [Response] {
        try await open(user: account.user, auth: try await account.auth())
        let response = try await command("EXAMINE INBOX")
        uidValidity = response.lazy.compactMap { $0.number(after: "UIDVALIDITY ") }.first
        return response
    }

    func search(_ criteria: String) async throws -> [Int] {
        try await command("UID SEARCH \(criteria)").flatMap { r in
            r.text.hasPrefix("* SEARCH") ? r.text.split(separator: " ").dropFirst(2).compactMap { Int($0) } : []
        }
    }

    /// Fetches up to the first 256 KB of each message (codes live in the text, not attachments).
    func fetch(_ uids: [Int], account: MailAccount) async throws -> [IncomingMessage] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let internalDate = DateFormatter()
        internalDate.locale = Locale(identifier: "en_US_POSIX")
        internalDate.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return try await command("UID FETCH \(set) (UID INTERNALDATE BODY.PEEK[]<0.262144>)", timeout: 90).compactMap { r in
            guard let raw = r.literals.first, let q = r.text.range(of: "INTERNALDATE \"") else { return nil }
            let dateText = r.text[q.upperBound...].prefix(while: { $0 != "\"" }).trimmingCharacters(in: .whitespaces)
            let m = MIME.parse(raw)
            return IncomingMessage(text: m.text, subject: m.subject, senderName: m.fromName, senderID: m.fromAddress,
                                   sourceKey: account.id.uuidString, sourceLabel: account.label,
                                   date: internalDate.date(from: dateText) ?? Date(), isMail: true, links: m.links,
                                   messageID: r.number(after: "UID ").map { "\(uidValidity ?? 0):\($0)" }, senderVerified: m.senderVerified)
        }
    }
}
