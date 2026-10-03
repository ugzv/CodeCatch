import Carbon.HIToolbox

/// System-wide shortcuts. Carbon hot keys need no Accessibility access: they only
/// report their own key combination, never other typing.
@MainActor
enum Hotkeys {
    static let all: [(key: Int, label: String, title: String, action: @MainActor () -> Void)] = [
        (kVK_ANSI_C, "⌃⌥⌘C", "Copy Latest Code", { AppModel.shared.copyLatest() }),
        (kVK_ANSI_F, "⌃⌥⌘F", "Search Codes", { MenuBarPopover.open() }),
    ]

    private static var registered: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?

    static func sync() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []
        guard Prefs[Prefs.hotkeys] else { return }
        if handler == nil {
            var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                MainActor.assumeIsolated { Hotkeys.all.indices.contains(Int(id.id)) ? Hotkeys.all[Int(id.id)].action() : () }
                return noErr
            }, 1, &pressed, nil, &handler)
        }
        for (i, hotkey) in all.enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(hotkey.key), UInt32(controlKey | optionKey | cmdKey),
                                EventHotKeyID(signature: OSType(0x4343_4348), id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            if let ref { registered.append(ref) }
        }
    }
}
