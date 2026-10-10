import CodeCatchCore
import Foundation

/// The Microsoft Graph calls CodeCatch makes for an Outlook, Hotmail or Microsoft 365 account signed in
/// with Microsoft (Mail.Read). All of them read.
struct OutlookAPI: MailAPI {
    let auth: APIAuth

    init(auth: APIAuth) { self.auth = auth }
    init(account: MailAccount) { self.init(auth: .saved(.microsoft, tokenKey: account.refreshTokenKey)) }

    func emailAddress() async throws -> String {
        let me = try await json("me", ["$select": "mail,userPrincipalName"])
        // Personal accounts often have no "mail"; their sign-in name is the address.
        guard let email = (me["mail"] as? String) ?? (me["userPrincipalName"] as? String) else { throw MailAPIError.http(200, "no address") }
        return email
    }

    /// The newest inbox message's arrival time, in the server's clock: new mail is what arrives at or after it.
    func cursor() async throws -> String {
        let newest = try await list(["$orderby": "receivedDateTime desc", "$top": "1"])
        return newest.first?.received ?? Self.timestamp(Date().addingTimeInterval(-60))
    }

    func inbox(since date: Date, limit: Int) async throws -> [String] {
        try await list(["$filter": "receivedDateTime ge \(Self.timestamp(date))", "$orderby": "receivedDateTime desc",
                        "$top": "\(limit)"]).map(\.id).reversed()
    }

    /// Mail that arrived at or after `cursor`; the one at the cursor comes again and the watcher skips it.
    func added(since cursor: String) async throws -> (ids: [String], cursor: String) {
        let new = try await list(["$filter": "receivedDateTime ge \(cursor)", "$orderby": "receivedDateTime asc", "$top": "50"])
        return (new.map(\.id), new.last?.received ?? cursor)
    }

    /// One message's MIME source, parsed from its first 256 KB (codes live in the text, not attachments).
    func message(_ id: String, account: MailAccount) async throws -> IncomingMessage? {
        let info: [String: Any], raw: Data
        do {
            info = try await json("me/messages/\(id)", ["$select": "receivedDateTime,webLink"])
            raw = try await get("me/messages/\(id)/$value")
        } catch MailAPIError.gone { return nil }
        let m = MIME.parse(raw.prefix(262_144))
        let received = (info["receivedDateTime"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return IncomingMessage(text: m.text, subject: m.subject, senderName: m.fromName, senderID: m.fromAddress,
                               sourceKey: account.id.uuidString, sourceLabel: account.label, date: received ?? Date(),
                               isMail: true, links: m.links, messageID: "outlook:\(id)", senderVerified: m.senderVerified,
                               internetMessageID: m.messageID, webURL: (info["webLink"] as? String).flatMap(URL.init(string:)))
    }

    private func list(_ query: [String: String]) async throws -> [(id: String, received: String)] {
        let page = try await json("me/mailFolders/inbox/messages", query.merging(["$select": "id,receivedDateTime"]) { a, _ in a })
        return ((page["value"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let id = m["id"] as? String, let received = m["receivedDateTime"] as? String else { return nil }
            return (id, received)
        }
    }

    private func json(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        let data = try await get(path, query)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        var url = URLComponents(string: "https://graph.microsoft.com/v1.0/" + path)!
        if !query.isEmpty { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await MailAPIError.send(URLRequest(url: url.url!, timeoutInterval: 60), auth: auth, provider: "Microsoft")
    }

    private static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
