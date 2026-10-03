import Foundation
import Testing
@testable import CodeCatchCore

/// Only logins with a usable TOTP become rows (a row without a code is useless),
/// the logo domain comes from the first web address, and passwords are never kept.
@Test func importsBitwardenLogins() throws {
    let json = """
    [
      {"object":"item","id":"b","type":1,"name":"github","login":{"username":"me","password":"hunter2",
        "totp":"GEZDGNBVGY3TQOJQ","uris":[{"match":null,"uri":"github.com/login"}]}},
      {"object":"item","id":"a","type":1,"name":"Acme","login":{"username":"","password":"pw",
        "totp":"otpauth://totp/Acme?secret=GEZDGNBVGY3TQOJQ","uris":[{"uri":"androidapp://acme"},{"uri":"https://sso.acme.co.uk/"}]}},
      {"object":"item","id":"c","type":1,"name":"No 2FA","login":{"username":"x","password":"pw","totp":null,"uris":[]}},
      {"object":"item","id":"d","type":1,"name":"Broken","login":{"username":"x","totp":"not a secret!"}},
      {"object":"item","id":"e","type":2,"name":"A note","notes":"GEZDGNBVGY3TQOJQ"}
    ]
    """
    let codes = try VaultCode.fromBitwarden(Data(json.utf8))
    #expect(codes.map(\.id) == ["a", "b"])
    #expect(codes.map(\.domain) == ["acme.co.uk", "github.com"])
    #expect(codes.map(\.username) == [nil, "me"])
    #expect(!String(decoding: try JSONEncoder().encode(codes), as: UTF8.self).contains("hunter2"))
}
