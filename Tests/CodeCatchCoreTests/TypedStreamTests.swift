import Foundation
import Testing
@testable import CodeCatchCore

/// Messages keeps most bodies only in the typedstream blob; a wrong length
/// prefix (the >127-byte int16 path) silently drops every long message.
@Test(arguments: ["Your code is 482913", String(repeating: "Long message ", count: 30) + "code 482913"])
func readsAttributedBody(text: String) throws {
    let blob = NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
    #expect(TypedStream.text(fromAttributedBody: blob) == text)
}
