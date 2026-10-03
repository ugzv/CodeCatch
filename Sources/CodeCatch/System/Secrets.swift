import Foundation
import Security

/// Mail passwords, Google sign-ins and the OAuth client, in the login Keychain.
/// Builds signed with the same Developer ID team read them without asking (the
/// items' access list names the team, not one binary); any other binary gets a prompt.
enum Secrets {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "The Keychain request failed (\(status))."
        }
    }

    private static let service = "com.uros.codecatch"
    #if DEBUG
    /// Snapshots run unsigned, where a read would stop at a Keychain prompt.
    static var offline = false
    #endif

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        try? read(account)
    }

    static func read(_ account: String) throws -> String? {
        #if DEBUG
        if offline { return nil }
        #endif
        var q = query(account)
        q[kSecReturnData as String] = true
        var data: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &data)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = data as? Data else { throw Failure(status: status) }
        guard let value = String(data: data, encoding: .utf8) else { throw Failure(status: errSecDecode) }
        return value
    }

    static func set(_ value: String, for account: String,
                    update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
                    add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd) throws {
        let data = Data(value.utf8)
        let status = update(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var item = query(account)
        item[kSecValueData as String] = data
        let added = add(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
