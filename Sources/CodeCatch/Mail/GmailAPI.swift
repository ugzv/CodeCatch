import CodeCatchCore
import Foundation

/// The Gmail API calls CodeCatch makes for an account signed in with Google. All of them read.
struct GmailAPI: GmailMailbox {
    enum Failure: LocalizedError {
        case historyExpired, gone, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .historyExpired: "Gmail's change history expired"
            case .gone: "The message was deleted"
            case .http(let status, let message): "Gmail answered \(status): \(message)"
            }
        }
    }

    let refreshToken: String

    init(refreshToken: String) { self.refreshToken = refreshToken }

    init(account: MailAccount) throws {
        guard let refresh = try Secrets.read(account.refreshTokenKey) else { throw GoogleOAuth.Failure.token("no refresh token") }
        self.init(refreshToken: refresh)
    }

    func emailAddress() async throws -> String {
        guard let email = try await get("profile")["emailAddress"] as? String else { throw Failure.http(200, "no address") }
        return email
    }

    func historyID() async throws -> String {
        try await get("profile")["historyId"].map { "\($0)" } ?? ""
    }

    /// Inbox messages received since `date`, oldest first.
    func inbox(since date: Date, limit: Int) async throws -> [String] {
        let json = try await get("messages", ["q": "in:inbox after:\(Int(date.timeIntervalSince1970))", "maxResults": "\(limit)"])
        return ((json["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.reversed()
    }

    /// Messages added to the inbox after `historyID`, oldest first, and the position to continue from.
    func added(since historyID: String) async throws -> (ids: [String], historyID: String) {
        var ids: [String] = [], latest = historyID, page: String?
        repeat {
            var query = ["startHistoryId": historyID, "historyTypes": "messageAdded", "labelId": "INBOX"]
            query["pageToken"] = page
            let json = try await get("history", query)
            for record in (json["history"] as? [[String: Any]]) ?? [] {
                for added in (record["messagesAdded"] as? [[String: Any]]) ?? [] {
                    if let id = (added["message"] as? [String: Any])?["id"] as? String, !ids.contains(id) { ids.append(id) }
                }
            }
            latest = json["historyId"].map { "\($0)" } ?? latest
            page = json["nextPageToken"] as? String
        } while page != nil
        return (ids, latest)
    }

    /// One message, parsed from its first 256 KB (codes live in the text, not attachments).
    func message(_ id: String, account: MailAccount) async throws -> IncomingMessage? {
        let json: [String: Any]
        do { json = try await get("messages/\(id)", ["format": "raw"]) } catch Failure.gone { return nil }
        guard let raw = (json["raw"] as? String).flatMap(Data.init(base64URL:)) else { return nil }
        let m = MIME.parse(raw.prefix(262_144))
        let received = (json["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return IncomingMessage(text: m.text, subject: m.subject, senderName: m.fromName, senderID: m.fromAddress,
                               sourceKey: account.id.uuidString, sourceLabel: account.label, date: received ?? Date(),
                               isMail: true, links: m.links, messageID: "gmail:\(id)", senderVerified: m.senderVerified)
    }

    private func get(_ path: String, _ query: [String: String] = [:], retried: Bool = false) async throws -> [String: Any] {
        var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        if !query.isEmpty { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!, timeoutInterval: 60)
        request.setValue("Bearer \(try await GoogleOAuth.accessToken(refresh: refreshToken))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await GoogleOAuth.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 200: return json
        case 401 where !retried:
            GoogleOAuth.forgetAccessToken(for: refreshToken)
            return try await get(path, query, retried: true)
        case 401: throw GoogleOAuth.Failure.token("unauthorized")
        case 403 where message.localizedCaseInsensitiveContains("insufficient"): throw GoogleOAuth.Failure.noGmailAccess
        case 404 where path == "history": throw Failure.historyExpired
        case 404 where path.hasPrefix("messages/"): throw Failure.gone
        default: throw Failure.http(status, message)
        }
    }
}

private extension Data {
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
