import Foundation
import Testing
@testable import CodeCatchCore

/// Sign-in link mails: the action button must win over unsubscribe, help,
/// "not you?" and social links; course enrollment must not count as signing in.
@Test(arguments: [
    ("Confirm your sign-in", [("https://slack.com/help", "Help"), ("https://app.slack.com/verify-yourself/T6xH", "Sign in with a verified link"),
                              ("https://slack.com/unsubscribe?u=1", "Unsubscribe")], "https://app.slack.com/verify-yourself/T6xH"),
    ("Your Slack sign-in link", [("https://slack.com/z-app-123-magic?token=abc", "Sign in to Slack"), ("https://twitter.com/slackhq", "")],
     "https://slack.com/z-app-123-magic?token=abc"),
    ("Verify your email address", [("https://example.com/not-you", "This wasn't me"), ("https://example.com/account/verify?t=9", "Verify email")],
     "https://example.com/account/verify?t=9"),
    ("Secure link to log in to Claude.ai", [("https://claude.ai/magic-link#a1b2", "Sign in to Claude.ai")], "https://claude.ai/magic-link#a1b2"),
    ("Potrdite prijavo", [("https://moj.example.si/potrdi?x=1", "Potrdi prijavo")], "https://moj.example.si/potrdi?x=1"),
    ("Povezava za prijavo", [("https://example.si/login?token=test", "Prijavite se")], "https://example.si/login?token=test"),
    ("Prijava v vaš račun", [("https://example.si/login?token=test", "Prijava")], "https://example.si/login?token=test"),
    ("Prijava v račun", [("https://example.si/login?token=test", "Prijava")], "https://example.si/login?token=test"),
    ("Start u utorak 06.10. Prijave po dodatno sniženoj ceni do 02.10.",
     [("https://example.com/r/campaign", "Prijavite se na obuku Data Analyst")], nil),
    ("Prijava na obuku Data Analyst", [("https://example.com/r/campaign", "Prijavite se na obuku Data Analyst")], nil),
    ("Confirm your sign-in", [("http://insecure.example.com/verify", "Verify")], nil),
    ("Your weekly newsletter", [("https://news.example.com/article/1", "Read more"), ("https://news.example.com/login", "Log in")], nil),
    ("Security alert: new sign-in", [("https://myaccount.google.com/notifications", "Check activity")], nil),
    ("Pricing change for Instagram Profile Scraper – Followers, Bio, Posts, Verified",
     [("https://console.apify.com/actors/bGhA", "Instagram Profile Scraper – Followers, Bio, Posts, Verified")], nil),
] as [(String, [(String, String)], String?)])
func findsSignInLink(subject: String, links: [(String, String)], expected: String?) {
    let found = SignInLink.find(in: links.map { MailLink(url: $0.0, label: $0.1) }, subject: subject)
    #expect(found?.absoluteString == expected)
}
