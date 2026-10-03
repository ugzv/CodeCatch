import Foundation
import Testing
@testable import CodeCatchCore

/// A wrong code locks people out of their accounts: RFC 6238's own test table,
/// for each algorithm, 8 digits, through the otpauth:// form vaults store.
@Test(arguments: [
    ("sha1", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", [59: "94287082", 1_111_111_109: "07081804", 20_000_000_000: "65353130"]),
    ("sha256", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA", [59: "46119246", 1_111_111_109: "68084774", 20_000_000_000: "77737706"]),
    ("sha512", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA",
     [59: "90693936", 1_111_111_109: "25091201", 20_000_000_000: "47863826"]),
])
func matchesRFC6238(algorithm: String, secret: String, codes: [Int: String]) throws {
    let totp = try #require(TOTP("otpauth://totp/Test?secret=\(secret)&algorithm=\(algorithm.uppercased())&digits=8"))
    for (time, code) in codes { #expect(totp.code(at: Date(timeIntervalSince1970: TimeInterval(time))) == code) }
}

/// Secrets arrive as people pasted them: every accepted form must give the same
/// code, and a form that can't be read must be rejected rather than shown wrong.
@Test(arguments: [
    ("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "287082"),
    ("gezd gnbv gy3t qojq gezd gnbv gy3t qojq", "287082"),
    ("otpauth://totp/Acme:me?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Acme", "287082"),
    ("steam://GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "PV9M4"),
    ("not base32 1890", nil),
    ("otpauth://hotp/Acme?secret=GEZDGNBVGY3TQOJQ&counter=1", nil),
    ("otpauth://totp/Acme?secret=GEZDGNBVGY3TQOJQ&algorithm=MD5", nil),
    ("otpauth://totp/Acme?secret=GEZDGNBVGY3TQOJQ&period=1e-11", nil),  // the counter would overflow and trap
] as [(String, String?)])
func readsStoredSecrets(stored: String, codeAt59: String?) {
    #expect(TOTP(stored)?.code(at: Date(timeIntervalSince1970: 59)) == codeAt59)
}

/// The ring and "expires in" count from the start of the current period.
@Test func startsPeriodsOnTheBoundary() throws {
    let totp = try #require(TOTP("otpauth://totp/A?secret=GEZDGNBVGY3TQOJQ&period=60"))
    #expect(totp.periodStart(Date(timeIntervalSince1970: 119)) == Date(timeIntervalSince1970: 60))
}
