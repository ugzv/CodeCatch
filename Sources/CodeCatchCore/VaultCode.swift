import Foundation

/// A password-manager login with a TOTP secret, as CodeCatch keeps it: only what
/// the popover shows and searches, never the login's password.
public struct VaultCode: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let username: String?
    /// Registrable domain of the login's first web address, for the logo and search.
    public let domain: String?
    /// As the vault stores it: base32, otpauth:// or steam://.
    public let secret: String

    public var totp: TOTP? { TOTP(secret) }

    /// `bw list items` output → the logins whose TOTP secret CodeCatch can use, by name.
    public static func fromBitwarden(_ json: Data) throws -> [VaultCode] {
        struct Item: Decodable {
            struct Login: Decodable {
                struct URI: Decodable { let uri: String? }
                let username: String?
                let totp: String?
                let uris: [URI]?
            }
            let id: String
            let name: String
            let login: Login?
        }
        return try JSONDecoder().decode([Item].self, from: json).compactMap { item in
            guard let login = item.login, let secret = login.totp, TOTP(secret) != nil else { return nil }
            let host = login.uris?.lazy.compactMap(\.uri).compactMap(webHost).first
            return VaultCode(id: item.id, name: item.name, username: login.username.flatMap { $0.isEmpty ? nil : $0 },
                             domain: host.map(ServiceIdentity.registrable), secret: secret)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "https://sso.acme.co.uk/" or a bare "github.com"; not app links like "androidapp://acme".
    private static func webHost(_ uri: String) -> String? {
        let url = URL(string: uri.contains("://") ? uri : "https://" + uri)
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host, host.contains(".") else { return nil }
        return host
    }
}
