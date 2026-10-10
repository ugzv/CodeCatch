import AppKit

/// `/usr/local/bin/codecatch`, a link to the binary inside the app. Sparkle replaces the app at the
/// same path, so the link survives updates; moving the app breaks it, and Settings offers Repair.
enum CommandLineTool {
    static let link = URL(fileURLWithPath: "/usr/local/bin/codecatch")
    static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codecatch") }

    enum State: Equatable {
        case unavailable(String)
        case notInstalled
        case installed
        /// A link to another copy of CodeCatch, moved or deleted: Repair replaces it.
        case stale(target: String)
        /// Something that isn't ours is at the path: leave it alone.
        case taken
    }

    static var state: State { state(link: link, helper: helper, app: Bundle.main.bundlePath) }

    static func state(link: URL, helper: URL, app: String) -> State {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: helper.path) else { return .unavailable("This build has no command-line tool.") }
        if app.contains("/AppTranslocation/") || app.hasPrefix("/Volumes/") {
            return .unavailable("Move CodeCatch to your Applications folder first.")
        }
        guard let target = try? files.destinationOfSymbolicLink(atPath: link.path) else {
            return files.fileExists(atPath: link.path) ? .taken : .notInstalled
        }
        if URL(fileURLWithPath: target).standardizedFileURL == helper.standardizedFileURL { return .installed }
        // Ours if it points at a CodeCatch bundle's helper; a bundle that's gone can't say, so its path must.
        let bundle = URL(fileURLWithPath: target).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard target.hasSuffix(".app/Contents/Helpers/codecatch") else { return .taken }
        if files.fileExists(atPath: bundle.path), Bundle(url: bundle)?.bundleIdentifier != "com.uros.codecatch" { return .taken }
        return .stale(target: target)
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Each change happens only if the path still holds what was checked: an admin prompt can sit open
    /// for a while, and whatever appeared there meanwhile isn't ours to replace.
    static func install(over state: State, link: URL = link, helper: URL = helper) throws {
        switch state {
        case .notInstalled:
            let admin = "mkdir -p \(quoted(link.deletingLastPathComponent().path)) && [ ! -e \(quoted(link.path)) ] && [ ! -L \(quoted(link.path)) ] && ln -sh \(quoted(helper.path)) \(quoted(link.path))"
            // symlink(2) fails if anything is at the path, a folder included; `ln` would write into a folder.
            try change(link, asAdmin: admin) { Darwin.symlink(helper.path, link.path) == 0 }
        case .stale(let target):
            let admin = "[ \"$(readlink \(quoted(link.path)))\" = \(quoted(target)) ] && [ ! -d \(quoted(link.path)) ] && ln -sfh \(quoted(helper.path)) \(quoted(link.path))"
            try change(link, asAdmin: admin) { isLink(link, to: target) && Darwin.unlink(link.path) == 0 && Darwin.symlink(helper.path, link.path) == 0 }
        default: return
        }
    }

    /// Only ever our own link, as it was when checked. unlink(2) can't remove a folder.
    static func remove(_ state: State, link: URL = link, helper: URL = helper) throws {
        let target: String
        switch state {
        case .installed: target = helper.path
        case .stale(let old): target = old
        default: return
        }
        let admin = "[ \"$(readlink \(quoted(link.path)))\" = \(quoted(target)) ] && [ ! -d \(quoted(link.path)) ] && rm -f \(quoted(link.path))"
        try change(link, asAdmin: admin) { isLink(link, to: target) && Darwin.unlink(link.path) == 0 }
    }

    private static func isLink(_ link: URL, to target: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target
    }

    /// In-process where the user owns the folder (Intel Homebrew's /usr/local/bin, a test's temp folder),
    /// else the shell command with an admin prompt. A false check fails either way: the path changed.
    private static func change(_ link: URL, asAdmin command: String, _ inProcess: () -> Bool) throws {
        if FileManager.default.isWritableFile(atPath: link.deletingLastPathComponent().path) {
            guard inProcess() else { throw changed }
            return
        }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return }
        // -128: the user cancelled the password prompt.
        if error[NSAppleScript.errorNumber] as? Int == -128 { throw CancellationError() }
        throw error[NSAppleScript.errorNumber] as? Int == 1 ? changed
            : Failure(errorDescription: error[NSAppleScript.errorMessage] as? String ?? "Couldn't change /usr/local/bin.")
    }

    private static let changed = Failure(errorDescription: "/usr/local/bin/codecatch changed meanwhile, so CodeCatch left it alone.")

    /// The path in single quotes for the shell.
    private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// For CLAUDE.md or AGENTS.md: that the tool exists, the two things that break a sign-in, and the
    /// one boundary. Flags, JSON and exit codes live in `codecatch --help`, where the agent uses them.
    static var instructions: String {
        """
        ## 2FA codes (CodeCatch)

        When a site I asked you to sign in to needs a code or a sign-in link, run `codecatch get <site>`. Full path: \(helper.path). Run `codecatch --help` once to see the options.

        A code may need my OK in CodeCatch first, so the command can wait up to two minutes. Set your tool timeout to at least 150 seconds.

        It only returns codes from the last 30 seconds. Run `date +%s` before you click "Send code", and pass the result with `--since`.

        Only ask for codes for sign-ins I asked for, because each code opens one of my accounts. If I say no, don't ask again.
        """
    }
}
