import CryptoKit
import Foundation

/// Time-based one-time passwords (RFC 6238) from the forms a password manager
/// stores: a base32 secret, an otpauth:// URI, or Steam Guard's steam:// secret.
public struct TOTP: Equatable, Sendable {
    public enum Algorithm: String, Sendable { case sha1, sha256, sha512 }

    let key: Data
    public let algorithm: Algorithm
    public let digits: Int
    public let period: TimeInterval
    /// Five characters from Steam's alphabet instead of digits.
    public let isSteam: Bool

    public init?(_ stored: String) {
        let text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = text, algorithm = Algorithm.sha1, digits = 6, period: TimeInterval = 30, steam = false
        if text.lowercased().hasPrefix("steam://") {
            secret = String(text.dropFirst(8))
            steam = true
            digits = 5
        } else if text.lowercased().hasPrefix("otpauth://") {
            guard let url = URLComponents(string: text), url.host?.lowercased() == "totp" else { return nil }
            let query = Dictionary((url.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            secret = query["secret"] ?? ""
            if let a = query["algorithm"] { guard let parsed = Algorithm(rawValue: a.lowercased()) else { return nil }; algorithm = parsed }
            if let d = query["digits"] { guard let parsed = Int(d), (5...10).contains(parsed) else { return nil }; digits = parsed }
            if let p = query["period"] { guard let parsed = TimeInterval(p), (1...86400).contains(parsed) else { return nil }; period = parsed }
        }
        guard let key = Self.base32(secret), !key.isEmpty else { return nil }
        (self.key, self.algorithm, self.digits, self.period, self.isSteam) = (key, algorithm, digits, period, steam)
    }

    public func code(at date: Date) -> String {
        var counter = UInt64(max(0, date.timeIntervalSince1970) / period).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let symmetric = SymmetricKey(data: key)
        let mac: Data = switch algorithm {
        case .sha1: Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
        case .sha256: Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
        case .sha512: Data(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        var value = mac[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) } & 0x7fff_ffff
        guard !isSteam else {
            let alphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
            return String((0..<digits).map { _ in defer { value /= 26 }; return alphabet[Int(value % 26)] })
        }
        let code = String(UInt64(value) % UInt64(pow(10, Double(digits))))
        return String(repeating: "0", count: digits - code.count) + code
    }

    /// When the code shown at `date` appeared.
    public func periodStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / period).rounded(.down) * period)
    }

    /// RFC 4648 base32, forgiving of case, spaces, dashes and padding as people paste them.
    static func base32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0, out = Data()
        for ch in text.uppercased() where !" -=".contains(ch) {
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            value = value << 5 | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8(value >> (bits - 8) & 0xff))
                bits -= 8
            }
        }
        return out
    }
}
