import Foundation

/// What CodeCatch says about itself when a server offers the IMAP ID command (RFC 2971).
///
/// NetEase's servers refuse `EXAMINE INBOX` with "Unsafe Login" until a client says who it is,
/// although RFC 2971 §3 says a server must not refuse service because of the answer. The fields
/// here are what the app is: RFC 2971 §3 forbids false information, so it never claims to be
/// another mail client.
enum IMAPIdentification {
    /// The ID command to send, or nil when the server didn't advertise ID (RFC 2971 §3).
    static func command(capabilities: Set<String>, version: String = appVersion) -> String? {
        guard capabilities.contains("ID") else { return nil }
        let fields = [("name", "CodeCatch"), ("version", version), ("vendor", "CodeCatch")]
        return "ID (" + fields.map { quoted($0.0) + " " + quoted($0.1) }.joined(separator: " ") + ")"
    }

    /// "2.0 (417)": the marketing version and build, from the app bundle. "dev" for a build
    /// without one, which is honest rather than a version the app doesn't have.
    static var appVersion: String {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !short.isEmpty
        else { return "dev" }
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty else {
            return short
        }
        return "\(short) (\(build))"
    }

    /// An IMAP quoted string (RFC 3501 §4.3): quotes and backslashes escaped. Control characters
    /// can't appear in one, and values are capped at RFC 2971 §3.3's 1024 octets.
    static func quoted(_ value: String) -> String {
        let clean = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(1024)
        return "\"" + String(clean).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
