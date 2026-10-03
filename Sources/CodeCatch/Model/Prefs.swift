import Foundation

enum Prefs {
    static let showBanner = "showHUD", autoCopy = "autoCopy", autoType = "autoType", clearClipboard = "clearClipboard"
    static let codeInMenuBar = "codeInMenuBar", sound = "sound", messages = "messagesEnabled", appleMail = "appleMailEnabled", launchAtLogin = "launchAtLogin"
    static let historyDays = "historyDays", serviceIcons = "serviceIcons"
    static let hideFromCapture = "hideFromCapture", blurCodes = "blurCodes", showPreviews = "showPreviews"
    static let clearOnLock = "clearOnLock", clearedAt = "historyClearedAt"
    static let ignoredSenders = "ignoredSenders", dismissed = "dismissedMessages", vaultImportedAt = "vaultImportedAt"
    static let hotkeys = "hotkeys", welcomed = "welcomed"

    static let receivedCodes = "receivedCodes", signInLinks = "signInLinks", bitwarden = "bitwardenEnabled"

    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            receivedCodes: true, signInLinks: true, bitwarden: true,
            showBanner: true, autoCopy: true, autoType: false, clearClipboard: true, codeInMenuBar: true,
            sound: false, messages: true, appleMail: false, launchAtLogin: true, historyDays: 7, serviceIcons: true,
            hideFromCapture: true, blurCodes: false, showPreviews: true, clearOnLock: false, hotkeys: true,
        ])
    }

    static func history(in defaults: UserDefaults = .standard) -> TimeInterval {
        Double(max(1, defaults.integer(forKey: historyDays))) * 86400
    }

    static subscript(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    /// Old records contained the code or full sign-in URL between sender and date.
    static func migrateDismissals(in defaults: UserDefaults = .standard) {
        guard let saved = defaults.stringArray(forKey: dismissed) else { return }
        let migrated = saved.compactMap { key -> String? in
            if key.hasPrefix("message:") || key.hasPrefix("legacy:") { return key }
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3, let timestamp = parts.last, Int(timestamp) != nil else { return nil }
            return "legacy:\(parts[0])|\(timestamp)"
        }
        if migrated != saved { defaults.set(migrated, forKey: dismissed) }
    }
}
