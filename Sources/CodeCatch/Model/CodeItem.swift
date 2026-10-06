import CodeCatchCore
import CryptoKit
import Foundation

struct CodeItem: Identifiable, Equatable {
    enum Origin { case messages, mail, test, vault }

    var id = UUID()
    let origin: Origin
    /// Empty for a sign-in link that came without a code.
    var code: String
    /// The mail's sign-in / verification button, when it has one.
    var link: URL?
    let service: String
    let sourceLabel: String
    let sourceKey: String
    let accountLabel: String
    let sender: String
    /// One line of context: the SMS itself, or the mail's subject.
    let preview: String
    let snippet: String
    let received: Date
    /// From the message's own "expires in 10 minutes", else `AppModel.defaultValidity`.
    let expires: Date
    /// Registrable domain for the logo: the mail sender's, an origin-bound SMS's, or a known service's.
    let domain: String?
    let dismissKey: String
    var used = false
    /// The link resets a password rather than signing in.
    var resetsPassword = false

    var lifetime: TimeInterval { expires.timeIntervalSince(received) }
    var isLink: Bool { code.isEmpty }
    /// The setting that lets this item's link show.
    var linkSetting: String { resetsPassword ? Prefs.resetLinks : Prefs.signInLinks }
    /// What Copy puts on the clipboard.
    var copyValue: String { isLink ? link?.absoluteString ?? "" : code }

    func shouldAnnounce(at date: Date) -> Bool {
        date.timeIntervalSince(received) < 180 && date < expires
    }
}

extension CodeItem {
    init(_ message: IncomingMessage, code: String?, link: URL?, resetsPassword: Bool = false) {
        let body = message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let service = message.service
        self.init(origin: message.sourceKey == AppModel.testSourceKey ? .test : message.isMail ? .mail : .messages,
                  code: code ?? "", link: link, service: service, sourceLabel: message.sourceLabel,
                  sourceKey: message.sourceKey, accountLabel: message.sourceLabel, sender: message.senderID,
                  preview: String((message.subject.flatMap { $0.isEmpty ? nil : $0 } ?? body).prefix(160)),
                  snippet: String(((message.subject.map { $0 + " — " } ?? "") + body).prefix(280)), received: message.date,
                  expires: message.date.addingTimeInterval(CodeExtractor.validity(in: message.fullText)
                      ?? (code == nil ? AppModel.linkValidity : AppModel.defaultValidity)),
                  domain: ServiceIdentity.domain(senderAddress: message.senderID, isMail: message.isMail, text: message.fullText, service: service),
                  dismissKey: message.dismissKey, resetsPassword: resetsPassword)
    }

    /// A vault login's code as it stands at `date`, under the login's own id for a stable row.
    init?(_ vault: VaultCode, at date: Date) {
        guard let totp = vault.totp else { return nil }
        let start = totp.periodStart(date)
        let context = vault.username ?? vault.domain ?? ""
        let digest = Array(SHA256.hash(data: Data(vault.id.utf8)).prefix(16))
        let stableID = digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        self.init(id: UUID(uuidString: vault.id) ?? stableID, origin: .vault, code: totp.code(at: date), link: nil, service: vault.name,
                  sourceLabel: "Bitwarden", sourceKey: vault.id, accountLabel: context, sender: "", preview: context,
                  snippet: [vault.name, context].joined(separator: " — "),
                  received: start, expires: start.addingTimeInterval(totp.period), domain: vault.domain, dismissKey: "vault:\(vault.id)")
    }
}

extension CodeItem {
    /// "Messages · 22000" / "Work" — where it came from, not when.
    var origination: String {
        // A phone number or short code tells SMS senders apart; for mail the account says enough.
        let from = sender.isEmpty || sender == service || sender.contains("@") ? nil : sender
        return [sourceLabel, from].compactMap { $0 }.joined(separator: " · ")
    }

    /// "9:41" / "0:12" / "1 h" until expiry.
    func remaining(now: Date) -> String {
        let s = Int(max(0, expires.timeIntervalSince(now)).rounded(.up))
        return s >= 3600 ? "\(s / 3600) h" : String(format: "%d:%02d", s / 60, s % 60)
    }

    func age(now: Date) -> String {
        let s = now.timeIntervalSince(received)
        return s < 60 ? "now" : s < 3600 ? "\(Int(s / 60)) min" : received.formatted(date: .omitted, time: .shortened)
    }
}
