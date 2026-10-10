import AppKit
import CodeCatchCore
import LocalAuthentication

/// Keep the existing login-Keychain item; macOS authentication gates every session read.
@MainActor
enum VaultStorage {
    private static let key = "bitwarden.codes"

    static func unlockPolicy() -> UnlockPolicy {
        let authentication = DeviceAuthentication()
        return UnlockPolicy(load: { try Secrets.read("unlock-with-mac") == "true" },
                            save: { try Secrets.set($0 ? "true" : "false", for: "unlock-with-mac") },
                            authenticate: { try await authentication.authenticate() },
                            cancel: { authentication.cancel() })
    }

    static func session(defaults: UserDefaults = .standard, unlockPolicy: UnlockPolicy? = nil) -> VaultSession {
        let policy = unlockPolicy ?? self.unlockPolicy()
        let session = VaultSession(authenticate: { try await policy.authenticate() }, read: {
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
        session.cancelAuthentication = { policy.cancelAuthentication() }
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

    func authenticate(reason: String = "show your verification codes") async throws {
        let context = LAContext()
        self.context = context
        // The prompt is macOS's own window: it closes the popover and, when done, hands focus
        // to the app used before. Bring back what was open, unless a lock cancelled the prompt.
        // Plain activate() is refused here, as no app yields focus to us.
        let wasActive = NSApp.isActive, popoverWasOpen = MenuBarPopover.isOpen
        defer {
            if self.context === context {
                self.context = nil
                if wasActive || popoverWasOpen { NSApp.activate(ignoringOtherApps: true) }
                if popoverWasOpen { MenuBarPopover.open(query: nil) }
            }
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
            throw LAError(.authenticationFailed)
        }
    }

    func cancel() { context?.invalidate(); context = nil }
}
