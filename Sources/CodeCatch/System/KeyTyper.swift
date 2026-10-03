import AppKit

/// Types a code into the focused field of the frontmost app as real key presses,
/// which also fills split one-box-per-digit inputs. Needs Accessibility.
enum KeyTyper {
    private static let digitKeys: [Character: CGKeyCode] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
    /// One code at a time: two arriving together must not mix their digits.
    static let queue = DispatchQueue(label: "key-typer", qos: .userInteractive)

    /// Nothing without the permission, and never into CodeCatch's own windows.
    @MainActor static var canType: Bool { Accessibility.isTrusted && !NSApp.isActive }

    /// Types `text` once no modifier key is held, if `allowed` still holds at that moment.
    static func type(_ text: String, allowed: @escaping @MainActor () -> Bool,
                     modifiersHeld: @escaping () -> Bool = {
                         !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
                     }, press: @escaping (Character) -> Void = press) {
        queue.async {
            // A shortcut in progress would turn the digits into ⌘1…: wait up to a second for it to end.
            for _ in 0..<50 where modifiersHeld() { usleep(20_000) }
            guard !modifiersHeld(), DispatchQueue.main.sync(execute: { MainActor.assumeIsolated(allowed) }) else { return }
            for ch in text {
                press(ch)
                usleep(15_000)
            }
        }
    }

    private static func press(_ ch: Character) {
        let source = CGEventSource(stateID: .hidSystemState)
        var units = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: digitKeys[ch] ?? 0, keyDown: down)
            e?.flags = []
            e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            e?.post(tap: .cghidEventTap)
        }
    }
}
