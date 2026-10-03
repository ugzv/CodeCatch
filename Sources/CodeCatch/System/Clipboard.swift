import AppKit

/// Everything CodeCatch copies is a secret or holds one: a code, a sign-in link, the
/// message around them. So each copy stays on this Mac (no Universal Clipboard), is
/// marked for clipboard managers to neither record nor show (nspasteboard.org), and
/// is cleared after 90 s unless something else was copied since.
enum Clipboard {
    private static var copied: (id: UUID?, change: Int)?

    /// `id`: the code item on the clipboard, for the "Copied" checkmark.
    static func copy(_ text: String, id: UUID? = nil, pasteboard pb: NSPasteboard = .general) {
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(text, forType: .string)
        pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: .init("org.nspasteboard.TransientType"))
        let change = pb.changeCount
        copied = (id, change)
        guard Prefs[Prefs.clearClipboard] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if pb.changeCount == change { pb.clearContents() }
        }
    }

    /// Empties the clipboard if it still holds what we put there.
    static func clearIfOurs(ids: Set<UUID>? = nil) {
        if let ids, copied?.id.map(ids.contains) != true { return }
        if copied?.change == NSPasteboard.general.changeCount { NSPasteboard.general.clearContents() }
    }

    static func holds(_ item: CodeItem, pasteboard pb: NSPasteboard = .general) -> Bool {
        copied?.id == item.id && copied?.change == pb.changeCount && pb.string(forType: .string) == item.copyValue
    }
}
