import CodeCatchCore
import Darwin
import Foundation

/// Who is asking, as far as the kernel and code signatures can tell: the first app up the chain
/// of parent processes whose signature checks out (iTerm2, Terminal, Claude), and the program
/// that asked inside it. A program's own name is its choice, so the card marks it unverified.
///
/// Anything running inside an app counts as that app: a rule for iTerm2 covers every command in it.
enum CallerIdentity {
    /// Steps between the agent and the request that say nothing about who asked. `codecatch` sits
    /// inside CodeCatch.app, so it must be passed over before the app check, or every caller is CodeCatch.
    private static let plumbing: Set<String> = [
        "codecatch", "zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "login", "env", "sudo", "nohup", "timeout", "xargs", "script",
    ]

    /// `pid` is the connected client, alive while it waits for the reply. Each step up is checked by
    /// start time: a parent started before its child, and a process that took a dead parent's pid
    /// started after it. Each step is read again after its signature check, so a swap in between fails.
    static func caller(pid: pid_t) -> AgentCaller {
        var process = ""
        var current = pid
        var childStarted = UInt64.max
        for _ in 0..<32 {
            guard current > 1, let step = info(of: current), step.started <= childStarted, let path = path(of: current) else { break }
            let name = (path as NSString).lastPathComponent
            if !plumbing.contains(name) {
                if path.contains(".app/"), let (app, bundle) = verifiedApp(pid: current), info(of: current)?.started == step.started {
                    return AgentCaller(app: app, appPath: bundle, process: process)
                } else if process.isEmpty {
                    process = name
                }
            }
            childStarted = step.started
            current = step.parent
        }
        return AgentCaller(app: nil, appPath: nil, process: process)
    }

    /// The running process must have a valid signature; its bundle comes from that signature's own path.
    /// It is named for the outermost app (VS Code's terminal runs in "Code Helper (Plugin).app" inside it)
    /// when that bundle's signature checks out under the same team, by signing identifier, never Info.plist.
    private static func verifiedApp(pid: pid_t) -> (AgentApp, URL)? {
        // A bundle's main program reports the bundle itself ("…/Terminal.app"); a helper, its path inside one.
        guard let running = CodeSignature.of(pid: pid), let signed = running.path else { return nil }
        let path = signed.hasSuffix(".app") ? signed + "/" : signed
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        let name = FileManager.default.displayName(atPath: bundle.path).replacingOccurrences(of: ".app", with: "")
        if let outer = CodeSignature.of(bundle: bundle), outer.team == running.team {
            return (AgentApp(id: outer.identifier, team: outer.team, name: name), bundle)
        }
        return (AgentApp(id: running.identifier, team: running.team, name: running.identifier), bundle)
    }

    /// The parent's pid and this process's start time in microseconds: together they tell one process
    /// from a later one with the same pid.
    private static func info(of pid: pid_t) -> (parent: pid_t, started: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (pid_t(info.pbi_ppid), info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
