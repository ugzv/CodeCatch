import Foundation

/// Who a code is from: the card's title and the domain its logo and link check use.
public enum ServiceIdentity {
    /// "accounts.google.com" → "google.com", "mail.bank.co.uk" → "bank.co.uk", "evil.pages.dev" stays whole
    /// (anyone can host there); an IP stays whole.
    public static func registrable(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".")
        guard !parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return parts.joined(separator: ".") }
        return parts.suffix(PublicSuffix.length(of: parts) + 1).joined(separator: ".")
    }

    /// A mail's display name unless it is generic ("noreply"), else the service the
    /// text names, else the sender's domain ("Google") or, for SMS, the sender itself.
    public static func name(senderName: String, senderAddress: String, isMail: Bool, text: String) -> String {
        let name = senderName.trimmingCharacters(in: .whitespaces)
        if isMail, !name.isEmpty, !matches(genericSender, name) { return name }
        if let named = CodeExtractor.service(in: text) { return named }
        guard isMail, let host = senderAddress.split(separator: "@").last else { return senderAddress }
        let core = registrable(String(host)).split(separator: ".").first ?? host
        return core.prefix(1).uppercased() + core.dropFirst()
    }

    /// Registrable domain for the logo: the mail sender's, an origin-bound SMS's, or a known service's.
    public static func domain(senderAddress: String, isMail: Bool, text: String, service: String) -> String? {
        if isMail {
            let host = senderAddress.split(separator: "@", omittingEmptySubsequences: false).dropFirst().last.map(String.init) ?? ""
            return isHostname(host) ? registrable(host) : nil
        }
        if let origin = CodeExtractor.originDomain(in: text) { return registrable(origin) }
        return knownDomain(for: service)
    }

    /// "GitHub" → "github.com", for names in the known-service list.
    public static func knownDomain(for name: String) -> String? {
        knownDomains[name.lowercased().filter { !$0.isWhitespace }]
    }

    /// Dot-separated labels and nothing else: no path, port or query a sender could add to the logo request.
    public static func isHostname(_ text: String) -> Bool {
        text.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Ignored senders

    /// Whether an ignore entry covers `sender`: the same address or SMS sender, or, for a domain,
    /// any mail address at it or under it ("acme.com" covers "alerts@mail.acme.com", not "notacme.com").
    public static func ignores(_ entry: String, sender: String) -> Bool {
        let sender = sender.lowercased()
        guard sender != entry else { return true }
        guard isHostname(entry), let host = mailHost(sender) else { return false }
        return host == entry || host.hasSuffix("." + entry)
    }

    /// Typed text as an ignore entry, stored the way senders arrive: an address, a domain,
    /// a phone number or short code without spaces, or an SMS sender name. Nil for anything else.
    public static func ignoreEntry(_ text: String) -> String? {
        var entry = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if entry.hasPrefix("mailto:") { entry.removeFirst(7) }
        if entry.hasPrefix("@") { entry.removeFirst() }
        // "*@acme.com" and "*.acme.com" mean the whole domain, which a domain entry already is.
        if let wildcard = ["*@*.", "*@", "*."].first(where: entry.hasPrefix) {
            return domainEntry(String(entry.dropFirst(wildcard.count)))
        }
        guard !entry.contains("*") else { return nil }
        if let host = mailHost(entry) {
            let user = entry.dropLast(host.count + 1)
            return !user.isEmpty && !user.contains { $0.isWhitespace || $0 == "@" } && isHostname(host) ? entry : nil
        }
        // Before domains: "555.123.456" is a number, not a host.
        let number = entry.filter { !" -().".contains($0) }
        if number.range(of: #"^\+?\d{3,15}$"#, options: .regularExpression) != nil { return number }
        if isHostname(entry) { return domainEntry(entry) }
        // SMS sender names are at most 11 letters, digits, spaces and hyphens.
        return entry.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} -]{0,10}$"#, options: .regularExpression) != nil ? entry : nil
    }

    /// A domain to ignore, but never a public ending: "co.uk" or "github.io" would cover every site under it.
    private static func domainEntry(_ host: String) -> String? {
        let labels = host.split(separator: ".")
        return isHostname(host) && labels.count > PublicSuffix.length(of: labels) ? host : nil
    }

    /// The domain "Ignore All from…" offers for a mail sender. None for shared mail
    /// providers: ignoring gmail.com would drop every personal sender.
    public static func ignorableDomain(of sender: String) -> String? {
        guard let host = mailHost(sender.lowercased()), isHostname(host) else { return nil }
        let domain = registrable(host)
        let brand = String(domain.prefix { $0 != "." })
        return sharedMailBrands.contains(brand) || sharedMailDomains.contains(domain) ? nil : domain
    }

    /// The part after the last "@", for a mail address; nil for an SMS sender.
    private static func mailHost(_ sender: String) -> String? {
        sender.lastIndex(of: "@").map { String(sender[sender.index(after: $0)...]) }
    }

    /// Mail providers anyone can sign up to, under any country suffix (hotmail.co.uk, live.de). Matching the
    /// brand errs safe: a company that shares one only loses the shortcut, never every personal sender…
    private static let sharedMailBrands: Set<String> = [
        "gmail", "googlemail", "outlook", "hotmail", "live", "msn", "yahoo", "icloud", "aol", "proton", "protonmail",
        "gmx", "yandex", "zoho", "fastmail",
    ]
    /// …except brands that are common words, matched whole so "web.dev" keeps its option.
    private static let sharedMailDomains: Set<String> = ["me.com", "mac.com", "pm.me", "web.de", "mail.com", "mail.ru"]

    private static let genericSender = try! NSRegularExpression(
        pattern: #"(?i)no.?reply|do.?not.?reply|notifications?|^(info|support|security|accounts?|team|mailer)$"#)

    /// SMS senders carry no domain; these name the common ones.
    private static let knownDomains = [
        "google": "google.com", "apple": "apple.com", "appleaccount": "apple.com", "microsoft": "microsoft.com",
        "amazon": "amazon.com", "paypal": "paypal.com", "whatsapp": "whatsapp.com", "facebook": "facebook.com",
        "instagram": "instagram.com", "x": "x.com", "twitter": "x.com", "linkedin": "linkedin.com", "uber": "uber.com",
        "airbnb": "airbnb.com", "revolut": "revolut.com", "wise": "wise.com", "n26": "n26.com", "stripe": "stripe.com",
        "link": "link.com", "coinbase": "coinbase.com", "binance": "binance.com", "steam": "steampowered.com",
        "discord": "discord.com", "telegram": "telegram.org", "signal": "signal.org", "github": "github.com",
        "openai": "openai.com", "cloudflare": "cloudflare.com", "tiktok": "tiktok.com", "slack": "slack.com",
        "notion": "notion.so", "zoom": "zoom.us", "figma": "figma.com", "shopify": "shopify.com",
        "otpbanka": "otpbanka.si", "nlb": "nlb.si", "nlbklik": "nlb.si", "skb": "skb.si",
        "intesasanpaolo": "intesasanpaolobank.si", "telekom": "telekom.si", "mojtelekom": "telekom.si",
        "a1": "a1.si", "telemach": "telemach.si", "bolt": "bolt.eu", "wolt": "wolt.com",
    ]
}
