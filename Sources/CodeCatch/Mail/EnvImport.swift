#if DEBUG
import Foundation

/// Imports mail passwords from a dotenv file:
/// every `X_USER=<email>` paired with `X_PASS` or `X_PASSWORD` goes into the Keychain.
enum EnvImport {
    static func importCredentials(from path: String, into accounts: inout [MailAccount]) throws -> Int {
        var env: [String: String] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let key = l[..<eq].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            env[key] = l[l.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        var imported = 0
        var updated = accounts
        // The OAuth client for "Sign in with Google".
        if let id = env["GOOGLE_CLIENT_ID"], let secret = env["GOOGLE_CLIENT_SECRET"], !id.isEmpty, !secret.isEmpty {
            try Secrets.set(id, for: GoogleOAuth.clientIDKey)
            try Secrets.set(secret, for: GoogleOAuth.clientSecretKey)
        }
        for (key, user) in env where key.hasSuffix("_USER") && user.contains("@") {
            let base = key.dropLast("_USER".count)
            guard let pass = env[base + "_PASS"] ?? env[base + "_PASSWORD"], !pass.isEmpty else { continue }
            if !updated.contains(where: { $0.user.caseInsensitiveCompare(user) == .orderedSame }) {
                updated.append(.guess(for: user))
            }
            for a in updated where a.user.caseInsensitiveCompare(user) == .orderedSame {
                try Secrets.set(pass, for: a.secretKey)
                imported += 1
            }
        }
        accounts = updated
        return imported
    }
}
#endif
