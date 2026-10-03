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
    ("evil.pages.dev", "evil.pages.dev"), ("login.someone.github.io", "someone.github.io"),
])
func findsRegistrableDomain(host: String, expected: String) {
    #expect(ServiceIdentity.registrable(host) == expected)
}

/// The logo is fetched from this domain: a From address must not smuggle a path or port into the request.
@Test(arguments: [("a@evil.com/u/42", nil), ("a@evil.com:8443", nil), ("a@", nil), ("no-reply@Mail.Acme.com", "acme.com")] as [(String, String?)])
func takesOnlyHostnamesAsMailDomains(address: String, expected: String?) {
    #expect(ServiceIdentity.domain(senderAddress: address, isMail: true, text: "", service: "") == expected)
}
