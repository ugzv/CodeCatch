import Foundation
import Testing
@testable import CodeCatchCore

/// Links are read from HTML anchors (with an image button's alt text) and from plain-text lines.
@Test func collectsLinks() {
    #expect(MIME.anchors(#"<a href="https://a.com/verify?x=1&amp;y=2"><b>Verify</b></a> <a href='https://a.com/u'><img alt="Unsubscribe"></a>"#)
        == [MailLink(url: "https://a.com/verify?x=1&y=2", label: "Verify"), MailLink(url: "https://a.com/u", label: "Unsubscribe")])
    // AlternativeTo writes "=" as "&#x3D;": left encoded, its "#" turned the token into a URL fragment.
    #expect(MIME.anchors(#"<a href="https://a.com/verify?token&#x3D;ab&amp;next&#61;%2Fme">Verify</a>"#)
        == [MailLink(url: "https://a.com/verify?token=ab&next=%2Fme", label: "Verify")])
    // Browsers drop tabs and newlines in an href; kept, the link would not parse and the button was lost.
    #expect(MIME.anchors("<a href=\"\nhttps://a.com/log\tin?t=1\n\">Log in</a>") == [MailLink(url: "https://a.com/login?t=1", label: "Log in")])
    #expect(MIME.bareLinks("Sign in here: https://t.me/login/27635\nThanks") == [MailLink(url: "https://t.me/login/27635", label: "Sign in here")])
    // The sentence's full stop is not part of the token.
    #expect(MIME.bareLinks("Sign in: https://a.com/login?t=abc.").map(\.url) == ["https://a.com/login?t=abc"])
    // A URL alone on its line takes the line above as its label; with an empty one the link was never offered.
    #expect(MIME.bareLinks("Hi,\nSign in here:\n\nhttps://a.com/login?t=1\nThanks") == [MailLink(url: "https://a.com/login?t=1", label: "Sign in here")])
}

/// Codes arrive in multipart, quoted-printable, base64 and encoded-word
/// subjects; any one of those failing to decode hides the code.
@Test func parsesMultipartEmail() {
    let raw = """
    From: =?UTF-8?Q?GitHub_Securit=C3=A9?= <noreply@github.com>\r
    Subject: =?UTF-8?B?WW91ciBjb2Rl?= is\r
     here\r
    Content-Type: multipart/alternative; boundary="b1"\r
    \r
    --b1\r
    Content-Type: text/html; charset=utf-8\r
    Content-Transfer-Encoding: base64\r
    \r
    \(Data("<html><style>p{}</style><p>Code:</p><td>482913</td>&nbsp;&#8212;</html>".utf8).base64EncodedString())\r
    --b1--\r
    """
    let m = MIME.parse(Data(raw.utf8))
    #expect(m.fromName == "GitHub Securité")
    #expect(m.fromAddress == "noreply@github.com")
    #expect(m.subject == "Your code is here")
    #expect(m.text == "Code:\n482913\n—")

    let qp = "Content-Type: text/plain; charset=iso-8859-2\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nVa=B9a koda je 4829=\r\n13"
    #expect(MIME.parse(Data(qp.utf8)).text == "Vaša koda je 482913")

    // Mails are read up to 256 KB: a base64 part cut mid-group must still decode up to the cut.
    let cut = "Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n" + Data("Your code: 482913. Thanks!".utf8).base64EncodedString().dropLast(3)
    #expect(MIME.parse(Data(cut.utf8)).text.hasPrefix("Your code: 482913"))

    let bare = "Subject: Vaša koda\r\nContent-Type: multipart/mixed; boundary=XX\r\n\r\n--XX\r\n\r\nYour code: 482913\r\n--XX--"
    #expect(MIME.parse(Data(bare.utf8)) == MailMessage(fromName: "", fromAddress: "", subject: "Vaša koda", text: "Your code: 482913\n"))
}

/// The receiving server's DMARC verdict on the From domain. Only the top block counts (lower ones came with
/// the message and can be forged); anything short of a DMARC verdict stays unknown, or genuine mail would warn.
@Test(arguments: [
    (["mx.google.com; dkim=pass header.i=@notion.so; spf=pass smtp.mailfrom=notion.so; dmarc=pass (p=REJECT) header.from=notion.so"], true),
    (["mx.google.com; spf=softfail smtp.mailfrom=evil.com; dmarc=fail (p=NONE) header.from=notion.so"], false),
    // A forwarding server breaks DKIM on most genuine mail: no verdict, not a failure.
    (["mail.example.net; dkim=fail reason=\"signature verification failed\" header.d=notion.so"], nil),
    // Microsoft writes no server id.
    (["spf=pass (sender IP is 1.2.3.4) smtp.mailfrom=notion.so; dkim=pass (signature was verified) header.d=notion.so;dmarc=pass action=none header.from=notion.so;compauth=pass"], true),
    // iCloud splits its verdict over several headers from its own hosts.
    (["dkim-verifier.icloud.com; dkim=none", "dmarc.icloud.com; dmarc=pass header.from=notion.so"], true),
    // A forged "pass" further down, below the server's own fail, is ignored.
    (["mx.google.com; dmarc=fail header.from=notion.so", "attacker.example; dmarc=pass header.from=notion.so"], false),
    ([], nil),
] as [([String], Bool?)])
func readsSenderVerdict(results: [String], expected: Bool?) {
    let raw = results.map { "Authentication-Results: \($0)\r\n" }.joined() + "Received: from x\r\nFrom: Notion <team@mail.notion.so>\r\n\r\nHi"
    #expect(MIME.parse(Data(raw.utf8)).senderVerified == expected)
}
