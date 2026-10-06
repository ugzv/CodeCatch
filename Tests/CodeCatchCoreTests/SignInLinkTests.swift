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
    ("New sign-in to your Slack account", [("https://slack.com/reset?t=1", "Reset your password"),
                                           ("https://slack.com/secure", "Secure your account")], nil),
    ("Sign in to Outlook", [("https://outlook.example.com/login?t=1", "Sign in to Exchange")], "https://outlook.example.com/login?t=1"),
    ("Pricing change for Instagram Profile Scraper – Followers, Bio, Posts, Verified",
     [("https://console.apify.com/actors/bGhA", "Instagram Profile Scraper – Followers, Bio, Posts, Verified")], nil),
] as [(String, [(String, String)], String?)])
func findsSignInLink(subject: String, links: [(String, String)], expected: String?) {
    let found = SignInLink.find(in: links.map { MailLink(url: $0.0, label: $0.1) }, subject: subject)
    #expect(found?.url.absoluteString == expected)
    #expect(found.map { $0.kind == .signIn } ?? true)
}

/// Reset mails count as their own kind; "your password was changed" alerts offer a reset but are not one.
@Test(arguments: [
    ("Reset Password for Zabec.net", [("https://zabec.net/help", "Help"), ("https://zabec.net/account/reset?t=1", "Reset Password")],
     "https://zabec.net/account/reset?t=1"),
    ("Forgot your password?", [("https://example.com/pw?t=1", "Choose a new password")], "https://example.com/pw?t=1"),
    ("Password reset request", [("https://example.com/not-me", "I didn't request this"), ("https://example.com/r?t=1", "Reset")],
     "https://example.com/r?t=1"),
    ("Change your password", [("https://example.com/account/password?t=1", "Change password")], "https://example.com/account/password?t=1"),
    ("Ponastavitev gesla", [("https://example.si/ponastavi?t=1", "Ponastavi geslo")], "https://example.si/ponastavi?t=1"),
    ("Passwort zurücksetzen", [("https://example.de/pw?t=1", "Passwort zurücksetzen")], "https://example.de/pw?t=1"),
    ("Your password has been changed", [("https://example.com/reset", "Reset password")], nil),
    ("Password reset successful", [("https://example.com/login", "Log in")], nil),
    ("Reset your password", [("https://example.com/unsubscribe", "Unsubscribe")], nil),
] as [(String, [(String, String)], String?)])
func findsPasswordResetLink(subject: String, links: [(String, String)], expected: String?) {
    let found = SignInLink.find(in: links.map { MailLink(url: $0.0, label: $0.1) }, subject: subject)
    #expect(found?.url.absoluteString == expected)
    #expect(found.map { $0.kind == .passwordReset } ?? true)
}

/// Company mail wraps every link in a scanner; unread, every link warns "Opens outlook.com" and the warning
/// stops meaning anything. Only the scanners' own hosts unwrap: a lookalike host must keep its own address.
@Test(arguments: [
    ("https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.notion.so%2Flogin%3Ft%3D1&data=05%7C02", "https://www.notion.so/login?t=1"),
    ("https://www.google.com/url?q=https://app.slack.com/verify&sa=D", "https://app.slack.com/verify"),
    ("https://urldefense.proofpoint.com/v2/url?u=https-3A__github.com_login-3Ft-3D1&d=DwMF", "https://github.com/login?t=1"),
    ("https://urldefense.com/v3/__https://github.com/login__;!!abc$", "https://github.com/login"),
    ("https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.google.com%2Furl%3Fq%3Dhttps%3A%2F%2Fevil.com", "https://evil.com"),
    ("https://safelinks.protection.outlook.com.evil.com/?url=https%3A%2F%2Fnotion.so", "https://safelinks.protection.outlook.com.evil.com/?url=https%3A%2F%2Fnotion.so"),
    ("https://www.google.com/url?q=javascript:alert(1)", "https://www.google.com/url?q=javascript:alert(1)"),
    ("https://www.notion.so/login?url=https://evil.com", "https://www.notion.so/login?url=https://evil.com"),
    // Click trackers that write the destination into the link (real shapes; most warnings on a real inbox).
    ("https://abcd.eu-west-1.resend-clicks-a.com/CL0/https:%2F%2Fexample.com%2Fauth%2Fverify%3Ftoken=x/1/0102/AbC=441", "https://example.com/auth/verify?token=x"),
    ("https://abcd.r.us-west-2.awstrack.me/L0/https:%2F%2Fapp.example.org%2Freset%3Ftoken=x/1/0101/AbC=453", "https://app.example.org/reset?token=x"),
    ("https://mandrillapp.com/track/click/12345/app.example.com?p=eyJwIjogIntcInVcIjogMSwgXCJ2XCI6IDIsIFwidXJsXCI6IFwiaHR0cHM6Ly9hcHAuZXhhbXBsZS5jb20vbG9naW4/dD1hYmNcIiwgXCJpZFwiOiBcInhcIn0ifQ==", "https://app.example.com/login?t=abc"),
    // The tracker path on anyone else's host is just a path.
    ("https://evil.com/CL0/https:%2F%2Fnotion.so/1/x", "https://evil.com/CL0/https:%2F%2Fnotion.so/1/x"),
])
func unwrapsLinkScanners(wrapped: String, expected: String) {
    #expect(LinkWrapper.destination(URL(string: wrapped)!).absoluteString == expected)
}
