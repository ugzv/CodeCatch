import CodeCatchCore
import Foundation
import LocalAuthentication

/// Keep the existing login-Keychain item; macOS authentication gates every session read.
@MainActor
enum VaultStorage {
    private static let key = "bitwarden.codes"

    static func session(defaults: UserDefaults = .standard) -> VaultSession {
        let authentication = DeviceAuthentication()
        let session = VaultSession(authenticate: {
            // "Unlock with Your Mac": being past the Mac's own lock screen is enough.
            if !defaults.bool(forKey: Prefs.unlockWithMac) { try await authentication.authenticate() }
        }, read: {
            guard defaults.bool(forKey: Prefs.bitwarden) else { return [] }
            guard let json = try Secrets.read(key) else { return [] }
            return try JSONDecoder().decode([VaultCode].self, from: Data(json.utf8))
        }, write: { codes in
            let data = try JSONEncoder().encode(codes)
            try Secrets.set(String(decoding: data, as: UTF8.self), for: key)
            defaults.set(Date(), forKey: Prefs.vaultImportedAt)
        }, remove: {
            try Secrets.remove(key)
            defaults.removeObject(forKey: Prefs.vaultImportedAt)
        })
        session.cancelAuthentication = { authentication.cancel() }
        session.didLock = { _ in Clipboard.clearIfOurs() }
        return session
    }
}

@MainActor
final class DeviceAuthentication {
    static var unlockMethods: String {
        supportsTouchID() ? "Touch ID or your Mac password" : "your Mac password"
    }

    static func supportsTouchID(context: LAContext = LAContext()) -> Bool {
        // Ask each time: enrollment, lockout and external keyboards can change.
        context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            && context.biometryType == .touchID
    }

    private var context: LAContext?

    func authenticate() async throws {
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your verification codes") else {
            throw LAError(.authenticationFailed)
        }
    }

    func cancel() { context?.invalidate(); context = nil }
}
