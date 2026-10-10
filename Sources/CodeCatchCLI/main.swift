import CodeCatchCore
import Darwin
import Foundation

let help = """
codecatch: get 2FA codes and sign-in links from CodeCatch, with the user's OK.

Usage:
  codecatch get <site> [--since T] [--timeout 90] [--json | --raw]
  codecatch status [--json]
  codecatch --version

get     Waits for a code for <site>, or a sign-in link if the user allows links, then
        prints it once the user approves it in the CodeCatch banner (or has allowed this
        site without asking).
        <site>: a domain, URL or service name: github.com, https://github.com/login, GitHub.
        Returns a code that arrived in the last 30 seconds, or after --since; else waits.
  --since T     Epoch seconds, an ISO 8601 time, or an age such as 2m (at most 5 minutes back).
                Take T=$(date +%s) before clicking "Send code", then pass --since $T.
  --timeout N   Seconds to wait for the code to arrive (default 90). Approval may add up to 45.
                Give your own tool call a longer limit than that.
  --json        Print {"v":1,"item":{"kind","value","code","link","service","domain",...}}.
                Errors print {"v":1,"error":{"code","message"}}.
  --raw         Print only the code or link.
status  Whether CodeCatch is running and command-line access is on, with a fix for each problem.

Progress goes to stderr as lines starting "codecatch:". When one says to approve in the
banner, tell the user.

Exit codes: 0 ok, 1 error, 2 denied by the user (stop, don't ask again), 3 no code
arrived (resend it once), 4 CodeCatch not running or access off (run status),
5 not approved in time (ask the user to watch for the banner), 64 usage.
"""

let stderr = FileHandle.standardError
func note(_ text: String) { stderr.write(Data("codecatch: \(text)\n".utf8)) }

var json = false

func finish(_ error: AgentError) -> Never {
    if json, let data = try? AgentWire.encoder.encode(AgentReply(error: error)) { print(String(decoding: data, as: UTF8.self)) }
    note(error.message)
    exit(error.exitCode)
}

func usage(_ message: String) -> Never { finish(AgentError(.usage, "\(message) Run codecatch --help.")) }

// MARK: - The app this copy belongs to

/// `CodeCatch.app` when this binary is its `Contents/Helpers/codecatch`, through any symlink.
let appBundle: URL? = {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    let app = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return path.deletingLastPathComponent().path.hasSuffix(".app/Contents/Helpers") ? app : nil
}()

/// "1.0 (170)", as the app's About shows it.
let version: String = {
    guard let app = appBundle, let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let short = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String else { return "dev" }
    return "\(short) (\(build))"
}()

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { usage("\(name) needs a value.") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

json = flag("--json")
let raw = flag("--raw")
if flag("--help") || flag("-h") || args.first == "help" { print(help); exit(0) }
if flag("--version") || flag("-v") || args.first == "version" { print("codecatch \(version)"); exit(0) }

/// Epoch seconds, ISO 8601, or an age: 45s, 2m.
func parseSince(_ text: String) -> Date? {
    if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds) }
    if let unit = text.last, let n = Double(text.dropLast()), n >= 0, let scale = ["s": 1.0, "m": 60.0][String(unit)] {
        return Date().addingTimeInterval(-n * scale)
    }
    return ISO8601DateFormatter().date(from: text)
}

let request: AgentRequest
switch args.first {
case "get":
    var since: Date?
    if let text = option("--since") {
        guard let date = parseSince(text) else { usage("--since takes epoch seconds, an ISO 8601 time, or an age like 2m.") }
        since = date
    }
    var timeout: TimeInterval?
    if let text = option("--timeout") {
        guard let seconds = Double(text), seconds > 0 else { usage("--timeout takes a number of seconds.") }
        timeout = seconds
    }
    guard args.count == 2, !args[1].hasPrefix("-") else { usage(args.count < 2 ? "Name the site, such as github.com." : "Unknown option \(args.dropFirst(2).first ?? args[1]).") }
    guard SiteQuery(args[1]) != nil else { usage("\"\(args[1])\" isn't a site. Use a domain, URL or service name.") }
    request = AgentRequest(command: .get, site: args[1], since: since, timeout: timeout)
case "status":
    guard args.count == 1 else { usage("status takes no arguments.") }
    request = AgentRequest(command: .status)
case nil:
    print(help)
    exit(64)
case let other?:
    usage("Unknown command \(other).")
}

// MARK: - Talking to the app

/// Only CodeCatch itself, signed by the same team as this binary, gets the request: anything else
/// listening at the path could answer with a phishing link.
func verifiedConnection() -> Int32 {
    let path = AgentWire.socketPath()
    var fd = LocalSocket.connect(path)
    if fd == nil, let app = appBundle {
        note("starting CodeCatch…")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", app.path]
        try? open.run()
        open.waitUntilExit()
        for _ in 0..<60 where fd == nil {
            usleep(250_000)
            fd = LocalSocket.connect(path)
        }
    }
    guard let fd else { finish(AgentError(.accessOff, "CodeCatch isn't running. Open it, then try again.")) }
    guard let peer = LocalSocket.peer(of: fd), peer.uid == getuid() else {
        finish(AgentError(.failed, "Something other than CodeCatch is listening at \(path). Not asking it."))
    }
    // Only CodeCatch from this tool's own team, or from CodeCatch's when this build is unsigned: anyone
    // can sign a program as com.uros.codecatch, but not under that team.
    let server = CodeSignature.of(auditToken: peer.auditToken)
    let team = CodeSignature.current?.team ?? "KS2HADLRV4"
    guard let server, server.identifier == "com.uros.codecatch", server.team == team else {
        finish(AgentError(.failed, "The program at \(path) isn't a signed CodeCatch. Not asking it."))
    }
    return fd
}

let fd = verifiedConnection()
guard LocalSocket.send(request, to: fd) else { finish(AgentError(.failed, "CodeCatch closed the connection.")) }

var buffer = Data()
while let line = LocalSocket.readLine(from: fd, buffer: &buffer, limit: 1 << 16) {
    guard let reply = try? AgentWire.decoder.decode(AgentReply.self, from: line) else { continue }
    if let progress = reply.progress { note(progress) }
    if let error = reply.error { finish(error) }
    if let item = reply.item {
        if json, let data = try? AgentWire.encoder.encode(AgentReply(item: item)) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(item.value)
            if !raw { note("\(item.kind == .link ? "sign-in link" : "code") from \(item.service), \(item.source == "mail" ? "Mail" : "Messages")") }
        }
        exit(0)
    }
    if let status = reply.status {
        if json, let data = try? AgentWire.encoder.encode(AgentReply(status: status)) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("CodeCatch \(status.appVersion ?? "") is running. This is codecatch \(version).")
            print("Command-line access: \(status.access ? "on" : "off")")
            if status.access {
                print("Allowed without asking: \(status.allowAll == true ? "everything" : status.rules == 0 ? "nothing, the user approves each code" : "\(status.rules) rule\(status.rules == 1 ? "" : "s")")")
                print("Sources: \(status.sourcesWorking) working\(status.sourcesFailing > 0 ? ", \(status.sourcesFailing) not working" : "")")
            }
        }
        if !status.access { note("Command-line access is off. Turn it on in CodeCatch → Settings → Agents.") }
        if status.sourcesFailing > 0 { note("Some sources aren't working. Check CodeCatch → Settings → Sources.") }
        if status.appVersion != version, version != "dev" { note("CodeCatch was updated. Quit and reopen it.") }
        exit(status.access ? 0 : 4)
    }
}
finish(AgentError(.failed, "CodeCatch closed the connection before answering."))
