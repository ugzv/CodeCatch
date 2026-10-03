import Foundation

/// Messages stores most bodies only in `message.attributedBody`, a typedstream
/// (NSArchiver) NSAttributedString. Unarchiving it with NSUnarchiver raises an
/// uncatchable ObjC exception on a malformed blob, so read the NSString payload directly.
public enum TypedStream {
    public static func text(fromAttributedBody data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let start = Data(bytes).range(of: Data("NSString".utf8))?.upperBound else { return nil }
        var i = start + 5
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        if length == 0x81, i + 2 <= bytes.count {  // int16 follows
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
        } else if length == 0x82, i + 4 <= bytes.count {  // int32 follows
            length = (0..<4).reduce(0) { $0 | Int(bytes[i + $1]) << (8 * $1) }
            i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<i + length], encoding: .utf8)
    }
}
