import Foundation
import Testing
@testable import CodeCatchCore

/// Mail titles: a "noreply" display name must fall back to the text, then to the sender's domain.
@Test(arguments: [
    ("Fly.io Team", "noreply@fly.io", "Your login code: 889687", "Fly.io Team"),
    ("No-Reply", "no-reply@accounts.google.com", "Your code: 482913", "Google"),
    ("Notifications", "alerts@mail.bank.co.uk", "Your code: 482913", "Bank"),
    ("noreply", "noreply@x.com", "Use 482913 to sign in to Slack.", "Slack"),
] as [(String, String, String, String)])
func namesMailSender(name: String, address: String, text: String, expected: String) {
    #expect(ServiceIdentity.name(senderName: name, senderAddress: address, isMail: true, text: text) == expected)
}

/// The sign-in link warning compares registrable domains: a wrong one hides a
/// phishing warning ("acme.com" vs "acme-login.net", or two IPs sharing ".0.1") or raises a false one.
@Test(arguments: [
    ("accounts.google.com", "google.com"), ("mail.bank.co.uk", "bank.co.uk"), ("Acme.COM", "acme.com"),
    ("login.acme-secure.net", "acme-secure.net"), ("localhost", "localhost"), ("192.168.0.1", "192.168.0.1"),
    // Anyone can host under these: the site is the subdomain, not the suffix.
    ("evil.pages.dev", "evil.pages.dev"), ("login.someone.github.io", "someone.github.io"), ("project.supabase.co", "project.supabase.co"),
    // Public Suffix List rules a short hand-made list misses: every *.ne.jp site was one site to it.
    ("www.example.ne.jp", "example.ne.jp"), ("a.b.kawasaki.jp", "a.b.kawasaki.jp"), ("www.city.kawasaki.jp", "city.kawasaki.jp"),
])
func findsRegistrableDomain(host: String, expected: String) {
    #expect(ServiceIdentity.registrable(host) == expected)
}

/// The logo is fetched from this domain: a From address must not smuggle a path or port into the request.
@Test(arguments: [("a@evil.com/u/42", nil), ("a@evil.com:8443", nil), ("a@", nil), ("no-reply@Mail.Acme.com", "acme.com")] as [(String, String?)])
func takesOnlyHostnamesAsMailDomains(address: String, expected: String?) {
    #expect(ServiceIdentity.domain(senderAddress: address, isMail: true, text: "", service: "") == expected)
}

/// An ignored domain must catch its subdomains' mail and nothing else: "notacme.com" is someone else, an SMS sender is not a host.
@Test(arguments: [
    ("security@acme.com", "security@acme.com", true), ("security@acme.com", "Security@ACME.com", true),
    ("security@acme.com", "noreply@acme.com", false),
    ("acme.com", "noreply@acme.com", true), ("acme.com", "alerts@mail.acme.com", true), ("acme.com", "mail.acme.com", false),
    ("acme.com", "noreply@notacme.com", false), ("acme.com", "acme.com@evil.com", false), ("mail.acme.com", "noreply@acme.com", false),
    ("+38640123456", "+38640123456", true), ("google", "Google", true), ("google", "google.com", false),
] as [(String, String, Bool)])
func matchesIgnoredSenders(entry: String, sender: String, expected: Bool) {
    #expect(ServiceIdentity.ignores(entry, sender: sender) == expected)
}

/// A typed entry is stored the way senders arrive, or it never matches; text that is no sender, or would cover a whole public ending, is refused.
@Test(arguments: [
    (" Security@Acme.com ", "security@acme.com"), ("mailto:a@acme.com", "a@acme.com"), ("@Acme.com", "acme.com"),
    ("+386 40 123-456", "+38640123456"), ("(555) 123", "555123"), ("555.123.456", "555123456"), ("Google", "google"), ("Acme-Promo", "acme-promo"),
    // Wildcards people type for a whole domain; any other wildcard is refused.
    ("*@Acme.com", "acme.com"), ("*.acme.com", "acme.com"), ("*@*.acme.com", "acme.com"), ("sec*@acme.com", nil), ("*", nil), ("*.com", nil),
    // A public ending would ignore every sender under it.
    ("co.uk", nil), ("*.co.uk", nil), ("github.io", nil), ("someone.github.io", "someone.github.io"),
    ("", nil), ("a@", nil), ("@", nil), ("a@@acme.com", nil), ("a\tb@acme.com", nil), ("a@acme.com/x", nil), ("acme.com:8443", nil), ("not a sender at all", nil),
] as [(String, String?)])
func readsTypedIgnoreEntries(text: String, expected: String?) {
    #expect(ServiceIdentity.ignoreEntry(text) == expected)
}

/// "Ignore All from gmail.com" would drop every personal sender, so shared mail providers get no domain option.
@Test(arguments: [
    ("security@mail.acme.com", "acme.com"), ("noreply@id.apple.com", "apple.com"),
    ("friend@gmail.com", nil), ("someone@outlook.co.uk", nil), ("me@icloud.com", nil), ("you@me.com", nil), ("friend@live.co.uk", nil), ("security@web.dev", "web.dev"),
    ("+38640123456", nil), ("Google", nil),
] as [(String, String?)])
func offersIgnorableDomain(sender: String, expected: String?) {
    #expect(ServiceIdentity.ignorableDomain(of: sender) == expected)
}

/// What an agent passes to `codecatch get`: a URL, host, port or service name must find the site,
/// or the request waits for a code that is already there.
@Test(arguments: [
    ("github.com", "github.com"), ("https://github.com/login?return_to=x", "github.com"), ("GitHub", "github.com"),
    ("accounts.google.com", "google.com"), ("WWW.Example.co.uk:443/path", "example.co.uk"), ("github.com.", "github.com"),
    ("acme", "acme"),
])
func readsAgentSite(text: String, label: String) throws {
    #expect(try #require(SiteQuery(text)).label == label)
}

/// Junk must be a usage error, not a query that matches some SMS by accident.
@Test(arguments: ["", "  ", "not a site!", "@@@", String(repeating: "x", count: 65)])
func rejectsAgentSite(text: String) {
    #expect(SiteQuery(text) == nil)
}

/// Only the sender's domain counts for mail: a "GitHub" display name from evil.com, which picks its own
/// name, must never be handed out as the GitHub code. Aliases cover sites that mail from another domain.
@Test(arguments: [
    ("github.com", "github.com", "GitHub", true), ("github.com", "evil.com", "GitHub", false),
    ("github.com", "github.io", "GitHub", false), ("github.com", nil, "GitHub", true), ("github.com", nil, "Revolut", false),
    ("claude.ai", "anthropic.com", "Anthropic", true), ("anthropic.com", "claude.ai", "Claude", false),
    ("acme", "acme.co.uk", "Acme Ltd", true), ("GitHub", "github.com", "noreply", true),
] as [(String, String?, String, Bool)])
func matchesAgentSite(site: String, domain: String?, service: String, expected: Bool) throws {
    #expect(try #require(SiteQuery(site)).matches(domain: domain, service: service) == expected)
}
