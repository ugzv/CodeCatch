import CodeCatchCore
import Foundation

/// The Gmail API calls CodeCatch makes for an account signed in with Google. All of them read.
struct GmailAPI: MailAPI {
    let auth: APIAuth

    init(auth: APIAuth) { self.auth = auth }
    init(account: MailAccount) { self.init(auth: .saved(.google, tokenKey: account.refreshTokenKey)) }

    func emailAddress() async throws -> String {
        guard let email = try await get("profile")["emailAddress"] as? String else { throw MailAPIError.http(200, "no address") }
        return email
    }

    /// Gmail's history position.
    func cursor() async throws -> String {
        try await get("profile")["historyId"].map { "\($0)" } ?? ""
    }

    func inbox(since date: Date, limit: Int) async throws -> [String] {
        let json = try await get("messages", ["q": "in:inbox after:\(Int(date.timeIntervalSince1970))", "maxResults": "\(limit)"])
        return ((json["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.reversed()
    }

    func added(since historyID: String) async throws -> (ids: [String], cursor: String) {
        var ids: [String] = [], latest = historyID, page: String?
        repeat {
            var query = ["startHistoryId": historyID, "historyTypes": "messageAdded", "labelId": "INBOX"]
            query["pageToken"] = page
            let json: [String: Any]
            do { json = try await get("history", query) } catch MailAPIError.gone { throw MailAPIError.cursorExpired }
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
        do { json = try await get("messages/\(id)", ["format": "raw"]) } catch MailAPIError.gone { return nil }
        guard let raw = (json["raw"] as? String).flatMap(Data.init(base64URL:)) else { return nil }
        let m = MIME.parse(raw.prefix(262_144))
        let received = (json["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return IncomingMessage(text: m.text, subject: m.subject, senderName: m.fromName, senderID: m.fromAddress,
                               sourceKey: account.id.uuidString, sourceLabel: account.label, date: received ?? Date(),
                               isMail: true, links: m.links, messageID: "gmail:\(id)", senderVerified: m.senderVerified)
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        if !query.isEmpty { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let data = try await MailAPIError.send(URLRequest(url: url.url!, timeoutInterval: 60), auth: auth, provider: "Google")
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

private extension Data {
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
