import Darwin
import Foundation

/// Settings → Agents → Connect: a `codecatch` skill in an agent's own skills folder. A skill loads only
/// when the agent needs a code, so it costs nothing in sessions that never sign in anywhere, unlike a
/// line in CLAUDE.md or AGENTS.md.
enum AgentSkill: CaseIterable, Identifiable {
    case claudeCode, codex, cursor
    var id: Self { self }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    /// For the logo.
    var domain: String {
        switch self {
        case .claudeCode: "claude.ai"
        case .codex: "openai.com"
        case .cursor: "cursor.com"
        }
    }

    /// The agent's own folder in the home folder; it exists once the agent has run.
    private var folder: String {
        switch self {
        case .claudeCode: ".claude"
        case .codex: ".codex"
        case .cursor: ".cursor"
        }
    }

    func isInstalled(home: URL) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(folder).path)
    }

    func file(home: URL) -> URL {
        home.appendingPathComponent("\(folder)/skills/codecatch/SKILL.md")
    }

    enum State: Equatable {
        case notConnected
        case connected
        /// Cursor also reads Claude Code's and Codex's skills; a second copy would show twice.
        case connectedThrough(AgentSkill)
        /// A codecatch skill CodeCatch didn't write: left alone.
        case taken
    }

    /// The Claude Code or Codex skill Cursor reads anyway, if CodeCatch wrote one.
    private func inherited(home: URL) -> AgentSkill? {
        guard self == .cursor else { return nil }
        return [.claudeCode, .codex].first { Self.owner($0.file(home: home)) == .ours }
    }

    func state(home: URL) -> State {
        if let other = inherited(home: home) { return .connectedThrough(other) }
        switch Self.owner(file(home: home)) {
        case .ours: return .connected
        case .foreign: return .taken
        case nil: return .notConnected
        }
    }

    /// Writes the skill, or rewrites CodeCatch's own. Never replaces a file CodeCatch didn't write.
    func connect(home: URL, guidance: String) throws {
        let url = file(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard Self.write(Self.skill(guidance), to: url) else {
            throw Failure(errorDescription: "\(name) already has a codecatch skill CodeCatch didn't write.")
        }
        // Cursor reads this one too: its own copy would now show twice.
        if self != .cursor { try? AgentSkill.cursor.disconnect(home: home) }
    }

    /// Removes only CodeCatch's own skill, and the folder only if that leaves it empty.
    func disconnect(home: URL) throws {
        let url = file(home: home)
        guard Self.removeOurs(url) else { return }
        rmdir(url.deletingLastPathComponent().path)  // fails, harmlessly, once anything else is in it
    }

    /// Keeps connected skills current: the tool's full path changes when the app moves or the text is updated.
    static func refresh(home: URL, guidance: String) {
        for agent in allCases where owner(agent.file(home: home)) == .ours {
            try? agent.connect(home: home, guidance: guidance)
        }
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Marks the file as CodeCatch's, so Disconnect never removes someone else's skill.
    private static let marker = "<!-- Written by CodeCatch. Settings → Agents → Disconnect removes it. -->"

    static func skill(_ guidance: String) -> String {
        """
        ---
        name: codecatch
        description: Get a 2FA verification code or sign-in link from the user's Mac with CodeCatch. Use when a site the user asked you to sign in to asks for a code or sends a sign-in link.
        ---
        \(marker)

        \(guidance)

        """
    }

    // Everything below works on one open file, never the path twice: what was checked is what gets
    // changed. O_NOFOLLOW makes a symlink someone else's, even one pointing at CodeCatch's file.

    private enum Owner { case ours, foreign }

    /// Nil when nothing is at the path.
    private static func owner(_ url: URL) -> Owner? {
        // O_NONBLOCK: a FIFO someone left at the path would otherwise hang the open.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? nil : .foreign }
        defer { close(fd) }
        return isOurs(fd) ? .ours : .foreign
    }

    private static func isOurs(_ fd: Int32) -> Bool { ownContent(fd) != nil }

    /// The file's bytes when it is a regular file CodeCatch wrote.
    private static func ownContent(_ fd: Int32) -> [UInt8]? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 64 * 1024 else { return nil }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).contains(marker) ? Array(data) : nil
    }

    /// Creates the file only if nothing is there, else rewrites it in place only if it is CodeCatch's.
    private static func write(_ text: String, to url: URL) -> Bool {
        var fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        var old: [UInt8]?
        if fd < 0 {
            guard errno == EEXIST else { return false }
            fd = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return false }
            old = ownContent(fd)
            guard old != nil else { close(fd); return false }
        }
        defer { close(fd) }
        func replace(with bytes: [UInt8]) -> Bool {
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress! + offset, bytes.count - offset, off_t(offset)) }
                guard n > 0 else { return false }
                offset += n
            }
            return ftruncate(fd, off_t(bytes.count)) == 0
        }
        // A write that stops halfway (a full disk) puts the old skill back, so it never stays half new.
        if replace(with: Array(text.utf8)) { return true }
        if let old { _ = replace(with: old) }
        return false
    }

    /// Moves the entry aside first, then checks what moved: deleting by path after the check could hit a
    /// file swapped in meanwhile. Ours is deleted; anything else goes back where it was.
    private static func removeOurs(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var opened = stat(), moved = stat()
        guard isOurs(fd), fstat(fd, &opened) == 0 else { return false }
        let aside = url.deletingLastPathComponent().appendingPathComponent(".codecatch-\(UUID().uuidString)").path
        guard renamex_np(url.path, aside, UInt32(RENAME_EXCL)) == 0 else { return false }
        if lstat(aside, &moved) == 0, moved.st_dev == opened.st_dev, moved.st_ino == opened.st_ino { return unlink(aside) == 0 }
        renamex_np(aside, url.path, UInt32(RENAME_EXCL))
        return false
    }
}
