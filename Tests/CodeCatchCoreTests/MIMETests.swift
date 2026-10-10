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
    Message-ID: <a1b2.c3@mail.github.com>\r
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
    // Kept bare: "Show in Mail" wraps it in its own brackets for message://.
    #expect(m.messageID == "a1b2.c3@mail.github.com")
    #expect(m.text == "Code:\n482913\n—")

    let qp = "Content-Type: text/plain; charset=iso-8859-2\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nVa=B9a koda je 4829=\r\n13"
    #expect(MIME.parse(Data(qp.utf8)).text == "Vaša koda je 482913")

    // Mails are read up to 256 KB: a base64 part cut mid-group must still decode up to the cut.
    let cut = "Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n" + Data("Your code: 482913. Thanks!".utf8).base64EncodedString().dropLast(3)
    #expect(MIME.parse(Data(cut.utf8)).text.hasPrefix("Your code: 482913"))

    let bare = "Subject: Vaša koda\r\nContent-Type: multipart/mixed; boundary=XX\r\n\r\n--XX\r\n\r\nYour code: 482913\r\n--XX--"
    #expect(MIME.parse(Data(bare.utf8)) == MailMessage(fromName: "", fromAddress: "", subject: "Vaša koda", text: "Your code: 482913\n"))
}

/// Raw headers do not establish trust; only the first result from the explicitly selected receiver can.
@Test(arguments: [
    (.gmail, ["mx.google.com; dmarc=pass header.from=notion.so"], true),
    (.gmail, ["mx.google.com; dmarc=fail header.from=notion.so"], false),
    (.gmail, ["mx.google.com; dkim=fail header.d=notion.so"], nil),
    (.microsoft, ["spf=pass smtp.mailfrom=notion.so; dkim=pass header.d=notion.so; dmarc=pass action=none header.from=notion.so"], true),
    (.microsoft, ["spf=fail; dmarc=fail header.from=notion.so", "dkim=pass; dmarc=pass header.from=notion.so"], false),
    (.gmail, ["mx.google.com; dmarc=fail header.from=notion.so", "mx.google.com; dmarc=pass header.from=notion.so"], false),
    (.gmail, ["attacker.invalid; dmarc=pass header.from=notion.so", "mx.google.com; dmarc=pass header.from=notion.so"], nil),
    (.gmail, ["mx.google.com.attacker.invalid; dmarc=pass header.from=notion.so"], nil),
    (.microsoft, ["attacker.invalid; dmarc=pass header.from=notion.so"], nil),
    (.gmail, ["mx.google.com; dmarc=passjunk header.from=notion.so"], nil),
    (.gmail, ["mx.google.com; spf=pass (forged; dmarc=pass header.from=notion.so)"], nil),
    (.gmail, ["mx.google.com; dmarc=pass (receiver verdict) header.from=\"notion.so\""], true),
    (.gmail, ["mx.google.com; dmarc=pass header.from=attacker.invalid"], nil),
    (.gmail, ["mx.google.com; dmarc=pass"], nil),
    (.gmail, ["mx.google.com; dmarc=pass header.from=notion.so; dmarc=fail header.from=notion.so"], nil),
    (.gmail, ["mx.google.com; dmarc=pass header.from=notion.so header.from=attacker.invalid"], nil),
    (nil, ["mx.google.com; dmarc=pass header.from=notion.so"], nil),
    (nil, ["spf=pass; dmarc=pass header.from=notion.so"], nil),
    (nil, ["dmarc.icloud.com; dmarc=pass header.from=notion.so"], nil),
    (nil, ["attacker.invalid; dmarc=pass header.from=notion.so"], nil),
    (nil, [], nil),
] as [(MIME.Receiver?, [String], Bool?)])
func untrustedOrConflictingHeadersCannotVerifySender(receiver: MIME.Receiver?, results: [String], expected: Bool?) {
    let raw = results.map { "Authentication-Results: \($0)\r\n" }.joined() + "Received: from x\r\nFrom: Notion <team@notion.so>\r\n\r\nHi"
    #expect(MIME.parse(Data(raw.utf8), receiver: receiver).senderVerified == expected)
}

/// Repeated unclosed tags must not monopolize the mailbox worker or expose hidden markup as codes.
@Test func malformedHTMLCannotStallMailProcessing() {
    let start = ContinuousClock.now
    let styles = String(repeating: "<style>x", count: 20_000)
    #expect(MIME.htmlToText("Your code: 482913" + styles) == "Your code: 482913")
    let anchors = String(repeating: "<a href=\"https://example.invalid/\">", count: 6_000)
    #expect(MIME.anchors(anchors).isEmpty)
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func missingHeadEndTagCannotHideTheMessageBody() {
    let html = "<head><meta charset=utf-8><title>Hidden</title><style>Hidden</style><body>482913 <a href='https://example.com/login'>Sign in</a>"
    #expect(MIME.htmlToText(html) == "482913 Sign in")
    #expect(MIME.anchors(html) == [MailLink(url: "https://example.com/login", label: "Sign in")])
}

/// A quoted greater-than sign is an attribute value, not the end of a tag.
@Test func quotedAttributesDoNotExposeHiddenTextOrBreakLinks() {
    #expect(MIME.htmlToText("<style data-example='>'>482913</style><p>Visible</p>") == "Visible")
    #expect(MIME.anchors("<a title='>' href='https://example.com/login'><span>Sign in</span></a>")
        == [MailLink(url: "https://example.com/login", label: "Sign in")])
    #expect(MIME.anchors("<!-- <a href='https://evil.invalid/login'>Sign in</a> -->").isEmpty)
    #expect(MIME.anchors("<script><a href='https://evil.invalid/login'>Sign in</a></script>").isEmpty)
}
