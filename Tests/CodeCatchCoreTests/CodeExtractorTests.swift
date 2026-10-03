import Foundation
import Testing
@testable import CodeCatchCore

/// Guards against both failure modes that make the app useless: missing a real code,
/// and surfacing a price, date, order number or phone number as one. Real-world
/// formats and hard negatives, one `EXPECTED | text` per line in code-samples.txt, so every
/// scoring tweak is checked against the whole corpus, not just the case at hand.
@Test func extractsCode() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("code-samples.txt")
    for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let text = parts[1].replacingOccurrences(of: "\\n", with: "\n")
        #expect(CodeExtractor.code(in: text) == (parts[0] == "NONE" ? nil : parts[0]), "\(text)")
    }
}

/// The card's title: a wrong or missing service makes codes indistinguishable.
@Test(arguments: [
    ("G-482913 is your Google verification code.", "Google"),
    ("[Facebook] 482913 is your login code.", "Facebook"),
    ("【京东】验证码：548393，您正在新设备上登录。", "京东"),
    ("Revolut: Your code is 482 913.", "Revolut"),
    ("Your Uber code is 4829.", "Uber"),
    ("Your Epic Games security code is: K7PX2Q", "Epic Games"),
    ("Use 482913 to sign in to Slack.", "Slack"),
    ("Koda za prijavo v NLB Klik: 48291365", "NLB Klik"),
    ("OTP banka: Enkratno geslo za nakup pri ZALANDO SE v znesku 89,90 EUR je 318842.", "OTP banka"),
    ("Your verification code: 482913", nil),
] as [(String, String?)])
func namesService(text: String, expected: String?) {
    #expect(CodeExtractor.service(in: text) == expected)
}

/// The countdown ring and "Expired" state: a wrong validity shows a dead code
/// as live (or hides a live one), so stated lifetimes must be read exactly.
@Test(arguments: [
    ("Your code is 482913. It expires in 10 minutes.", 600),
    ("This code will expire in 15 minutes.", 900),
    ("NLB Klik: enkratno geslo je 48219375. Geslo velja 3 minute.", 180),
    ("Intesa Sanpaolo: Vase enkratno geslo je 847366. Velja 5 minut.", 300),
    ("Ihr Code läuft in 10 Minuten ab.", 600),
    ("Ihr Bestätigungscode: 4829. Gültig für 5 Minuten.", 300),
    ("Your one-time password is 482913. Valid 5 min.", 300),
    ("Code 482913 is valid for 30 seconds.", 30),
    ("Use this code within 1 hour.", 3600),
    ("Your code is 482913.", nil),
    ("Your order arrives in 3 days. Code 482913", nil),
] as [(String, Int?)])
func readsValidity(text: String, seconds: Int?) {
    #expect(CodeExtractor.validity(in: text).map(Int.init) == seconds)
}

/// An origin-bound SMS ("@revolut.com #152828") names the site for the logo.
@Test func readsOriginDomain() {
    #expect(CodeExtractor.originDomain(in: "Use code: 152-828.\n\n@revolut.com #152828") == "revolut.com")
    #expect(CodeExtractor.originDomain(in: "816902 is your Instagram code. #ig") == nil)
}
