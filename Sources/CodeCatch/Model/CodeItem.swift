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
    /// The mail server's DMARC verdict on the sender; nil when it gave none.
    var senderVerified: Bool? = nil

    var lifetime: TimeInterval { expires.timeIntervalSince(received) }
    var isLink: Bool { code.isEmpty }
    /// The setting that lets this item's link show.
    var linkSetting: String { resetsPassword ? Prefs.resetLinks : Prefs.signInLinks }
    /// Where the link really goes: inside a company link scanner, the site it forwards to.
    var destination: URL? { link.map(LinkWrapper.destination) }
    /// Where the link goes, when that isn't the sender's own site. The user decides: a warning when the sender
    /// can't be read or verified (a lookalike, malformed or spoofed From), else a calm note, since a sender
    /// the mail server verified chose that site itself (claude.ai from anthropic.com).
    var linkNotice: (text: String, warns: Bool)? {
        guard let host = destination?.host else { return nil }
        let target = ServiceIdentity.registrable(host)
        guard target != domain else { return nil }
        let check = "Check it before you \(resetsPassword ? "change your password" : "sign in")."
        guard let domain else { return ("Opens \(target), from a sender we can't verify. \(check)", true) }
        return senderVerified == true ? ("Opens \(target), not \(domain). The sender is verified.", false)
            : ("Opens \(target), not \(domain). \(check)", true)
    }
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
                  // A spoofed sender gets neither its logo nor a pass on the link check.
                  domain: message.senderVerified == false ? nil
                      : ServiceIdentity.domain(senderAddress: message.senderID, isMail: message.isMail, text: message.fullText, service: service),
                  dismissKey: message.dismissKey, resetsPassword: resetsPassword, senderVerified: message.senderVerified)
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
