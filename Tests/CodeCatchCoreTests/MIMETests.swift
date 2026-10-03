import Foundation
import Testing
@testable import CodeCatchCore

/// Links are read from HTML anchors (with an image button's alt text) and from plain-text lines.
@Test func collectsLinks() {
    #expect(MIME.anchors(#"<a href="https://a.com/verify?x=1&amp;y=2"><b>Verify</b></a> <a href='https://a.com/u'><img alt="Unsubscribe"></a>"#)
        == [MailLink(url: "https://a.com/verify?x=1&y=2", label: "Verify"), MailLink(url: "https://a.com/u", label: "Unsubscribe")])
    #expect(MIME.bareLinks("Sign in here: https://t.me/login/27635\nThanks") == [MailLink(url: "https://t.me/login/27635", label: "Sign in here")])
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

    let bare = "Subject: Vaša koda\r\nContent-Type: multipart/mixed; boundary=XX\r\n\r\n--XX\r\n\r\nYour code: 482913\r\n--XX--"
    #expect(MIME.parse(Data(bare.utf8)) == MailMessage(fromName: "", fromAddress: "", subject: "Vaša koda", text: "Your code: 482913\n"))
}
