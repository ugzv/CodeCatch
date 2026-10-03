import ApplicationServices

/// The Accessibility permission, which only "Automatically Type Codes" needs.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static var asked = false

    /// The system dialog at most once per launch; Settings has the button for later.
    static func requestTrust(force: Bool = false) {
        guard force || !asked else { return }
        asked = true
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }
}
