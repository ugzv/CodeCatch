import Foundation

/// Who a code is from: the card's title and the domain its logo and link check use.
public enum ServiceIdentity {
    /// "accounts.google.com" → "google.com", "mail.bank.co.uk" → "bank.co.uk"; an IP stays whole.
    public static func registrable(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".")
        guard parts.count > 2, !parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return parts.joined(separator: ".") }
        let secondLevel = ["co", "com", "org", "net", "gov", "ac"].contains(parts[parts.count - 2])
            || sharedHosts.contains(parts.suffix(2).joined(separator: "."))
        return parts.suffix(secondLevel ? 3 : 2).joined(separator: ".")
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
        return knownDomains[service.lowercased().filter { !$0.isWhitespace }]
    }

    /// Dot-separated labels and nothing else: no path, port or query a sender could add to the logo request.
    public static func isHostname(_ text: String) -> Bool {
        text.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Hosting anyone can sign up for: each subdomain is its own site.
    private static let sharedHosts: Set = [
        "pages.dev", "workers.dev", "github.io", "gitlab.io", "vercel.app", "netlify.app", "web.app", "firebaseapp.com",
        "herokuapp.com", "azurewebsites.net", "appspot.com", "blogspot.com", "cloudfront.net",
    ]

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
