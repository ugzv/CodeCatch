#if DEBUG
import CodeCatchCore
import Foundation

/// `CodeCatch --probe…`: end-to-end checks against the real accounts, printed, codes masked.
enum Probe {
    static let all: [String: () async -> Void] = [
        "--probe": sources, "--probe-google": google, "--probe-vault": vault,
        "--probe-apple-mail": appleMail, "--probe-messages": messages, "--probe-links": links,
    ]

    /// Checks Google sign-in without a consent: the client is accepted, the redirect
    /// listener works, and Gmail's XOAUTH2 failure path returns instead of hanging.
    static func google() async {
        print("OAuth client imported: \(GoogleOAuth.isConfigured)")
        do { _ = try await GoogleOAuth.accessToken(refresh: "invalid-refresh-token") } catch {
            print("Token endpoint with a bogus refresh token: \(error.localizedDescription)")
        }
        async let code = GoogleOAuth.waitForRedirect(state: "probe")
        try? await Task.sleep(for: .milliseconds(300))
        _ = try? await URLSession.shared.data(from: URL(string: "http://localhost:8765/?code=probe-code&state=probe")!)
        print("Redirect listener received: \((try? await code) ?? "nothing")")
        guard let conn = try? IMAPConnection(host: MailAccount.gmailHost, port: 993) else { return }
        do { try await conn.open(user: "probe@gmail.com", auth: .accessToken("invalid-token")) } catch {
            print("Gmail XOAUTH2 with a bad token: \(error.localizedDescription)")
        }
        await conn.close()
    }

    /// The imported Bitwarden logins' TOTP settings: counts, anything non-standard,
    /// and the logins matching an optional search. Never a secret or a code.
    @MainActor static func vault() async {
        let session = AppModel.shared.vaultSession
        do { try await session.unlock() } catch { print("Unlock failed: \(error.localizedDescription)"); return }
        defer { session.lock() }
        let codes = session.codes
        let query = CommandLine.arguments.last.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? ""
        func describe(_ c: VaultCode) -> String {
            let form = c.secret.lowercased().hasPrefix("otpauth") ? "otpauth" : c.secret.lowercased().hasPrefix("steam") ? "steam" : "plain"
            let settings = c.totp.map { "\($0.algorithm.rawValue) \($0.digits) digits \(Int($0.period)) s" } ?? "unreadable"
            return "\(c.name) · \(c.domain ?? "no site") · \(form) · \(settings)"
        }
        let standard = codes.filter { $0.totp.map { $0.algorithm == .sha1 && $0.digits == 6 && $0.period == 30 && !$0.isSteam } ?? false }
        print("\(codes.count) logins, \(standard.count) standard (SHA-1, 6 digits, 30 s)")
        for c in codes where !standard.contains(c) { print("non-standard:", describe(c)) }
        for c in codes where !query.isEmpty && (c.name.localizedCaseInsensitiveContains(query) || (c.domain ?? "").contains(query)) { print("match:", describe(c)) }
    }

    /// Texts from businesses (named senders and short codes of up to 6 digits, never a person's
    /// number or address) over the last 180 days, each with the code it yields, for finding misses.
    /// Unmasked, so debug builds only: a released app must not hand its Full Disk Access to
    /// whoever launches it. Run `scripts/debug.sh --probe-messages` from a terminal that has the access.
    static func messages() async {
        var read: [IncomingMessage] = []
        let watcher = LocalWatcher(MessagesStore())
        watcher.start(lookback: 180 * 86400, status: { print("Messages: \($0.summary)") }) { read.append($0) }
        var last: Int64 = -1
        while watcher.position != last {  // reads 200 rows a second; done once it stops moving
            last = watcher.position
            try? await Task.sleep(for: .seconds(3))
        }
        watcher.stop()
        func business(_ id: String) -> Bool {
            // A person can't text from a name; short codes are businesses too.
            !id.isEmpty && !id.contains("@") && (id.contains(where: \.isLetter) || id.allSatisfy(\.isNumber) && id.count <= 6)
        }
        for m in read where business(m.senderID) {
            print("\(CodeExtractor.code(in: m.fullText) ?? "NONE") | \(m.senderID) | \(m.text.replacingOccurrences(of: "\n", with: "\\n"))")
        }
    }

    /// What the Mail app's store yields from the last 30 days: codes masked, sign-in links by host.
    /// Needs Full Disk Access for the debug executable; release bundles exclude probes.
    static func appleMail() async {
        let store = AppleMailStore()
        if let problem = store.open(since: Date().addingTimeInterval(-30 * 86400)) { return print("Apple Mail: \(problem)") }
        guard let read = try? store.newMessages() else { return print("Apple Mail: can't read the index") }
        print("Apple Mail: \(read.count) inbox mails read, \(read.filter { !$0.text.isEmpty }.count) with text")
        for m in read {
            let code = CodeExtractor.code(in: m.fullText).map { String(repeating: "•", count: max(0, $0.count - 2)) + $0.suffix(2) } ?? "—"
            let link = SignInLink.find(in: m.links, subject: m.subject ?? "").map { "  → \($0.url.host ?? "")" } ?? ""
            print("  \(m.date.formatted(date: .numeric, time: .shortened))  \(code.padding(toLength: 10, withPad: " ", startingAt: 0))  \(m.service.prefix(22))\(link)")
        }
    }

    /// A year of sign-in, verification and reset mail per account, through the link check: the sender's
    /// site and the server's verdict on it, where the link really goes, and the warning shown. Sites only:
    /// never a code, token, path or address. Then every sender the server didn't vouch for, with why.
    static func links() async {
        let terms = ["sign", "log", "verif", "confirm", "magic", "password", "reset", "activat", "approv", "prijav", "potrdi", "geslo"]
        let subjects = terms.dropFirst().reduce("SUBJECT \"\(terms[0])\"") { "OR \($0) SUBJECT \"\($1)\"" }
        for account in MailAccount.load() where account.enabled && account.hasCredential {
            guard let conn = try? IMAPConnection(account: account) else { continue }
            do {
                try await conn.openInbox(account)
                if account.host == MailAccount.gmailHost { _ = try await conn.command("EXAMINE \"[Gmail]/All Mail\"") }  // Gmail archives most of it
                let uids = try await conn.search("SINCE \(MailWatcher.imapDay(Date().addingTimeInterval(-365 * 86400))) \(subjects)").suffix(1500)
                var verdicts: [String: Int] = [:], unvouched: [String: Int] = [:], links = 0, warned = 0, unwrapped = 0
                print("\n\(account.label): \(uids.count) matching mails in a year")
                for batch in stride(from: 0, to: uids.count, by: 100).map({ Array(uids.dropFirst($0).prefix(100)) }) {
                    for m in try await conn.fetch(batch, account: account) {
                        let sender = ServiceIdentity.registrable(String(m.senderID.split(separator: "@").last ?? ""))
                        let verdict = m.senderVerified.map { $0 ? "pass" : "FAIL" } ?? "none"
                        verdicts[verdict, default: 0] += 1
                        if m.senderVerified != true, let uid = m.messageID?.split(separator: ":").last { unvouched["\(sender) \(uid)", default: 0] += 1 }
                        guard let found = SignInLink.find(in: m.links, subject: m.subject ?? "") else { continue }
                        let item = CodeItem(m, code: nil, link: found.url, resetsPassword: found.kind == .passwordReset)
                        let target = ServiceIdentity.registrable(item.destination?.host ?? "")
                        links += 1
                        if item.linkNotice?.warns == true { warned += 1 }
                        if item.destination != item.link { unwrapped += 1 }
                        print("  \(m.date.formatted(date: .numeric, time: .omitted))  \(sender.padding(toLength: 26, withPad: " ", startingAt: 0)) \(verdict.padding(toLength: 5, withPad: " ", startingAt: 0)) → \(target)\(item.destination != item.link ? " (unwrapped from \(ServiceIdentity.registrable(found.url.host ?? "")))" : "")\(item.linkNotice.map { "  \($0.warns ? "⚠︎" : "ℹ︎") \($0.text)" } ?? "")")
                    }
                }
                print("  verdicts \(verdicts.sorted { $0.key < $1.key }), sign-in links \(links), warned \(warned), unwrapped \(unwrapped)")
                // Why the server didn't vouch: its own results, domains only.
                let bySender = Dictionary(grouping: unvouched.keys, by: { String($0.split(separator: " ")[0]) })
                for (sender, keys) in bySender.sorted(by: { $0.key < $1.key }) {
                    guard let uid = keys.first?.split(separator: " ").last,
                          let header = try? await conn.command("UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (AUTHENTICATION-RESULTS)])").first?.literals.first
                    else { continue }
                    let results = String(decoding: header, as: UTF8.self)
                        .replacingOccurrences(of: #"\([^)]*\)|header\.[sb]=\S+|[^\s=;@]+@"#, with: "", options: .regularExpression)
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    print("  not vouched: \(sender) ×\(keys.count)  \(results.isEmpty ? "no Authentication-Results" : results)")
                }
            } catch {
                print("\(account.label): \(error.localizedDescription)")
            }
            await conn.close()
        }
    }

    /// Checks every source end to end and prints what the app would show from the newest 400
    /// mails of the last 60 days (codes masked, also in subjects; sign-in links by host), plus
    /// code-like subjects that yield nothing.
    static func sources() async {
        let readable = FileManager.default.isReadableFile(atPath: MessagesStore.dbPath)
        print("Messages: chat.db \(readable ? "readable" : "not readable (needs Full Disk Access)")")
        for account in MailAccount.load() where account.enabled {
            guard account.hasCredential else { print("\(account.label): not signed in"); continue }
            let conn: IMAPConnection
            do { conn = try IMAPConnection(account: account) }
            catch { print("\(account.label): \(error.localizedDescription)"); continue }
            do {
                try await conn.openInbox(account)
                let uids = try await conn.search("SINCE \(MailWatcher.imapDay(Date().addingTimeInterval(-60 * 86400)))")
                let idle = await conn.capabilities.contains("IDLE")
                print("\(account.label): signed in (IDLE \(idle ? "yes" : "no")), \(uids.count) mails in 60 days; newest 400 read:")
                for m in try await conn.fetch(Array(uids.suffix(400)), account: account) {
                    let code = CodeExtractor.code(in: m.fullText)
                    let codeLike = (m.subject ?? "").range(of: #"code|verif|sign|log ?in|password|confirm|one-time|otp|magic|koda|prijav|potrd"#,
                                                           options: [.regularExpression, .caseInsensitive]) != nil
                    let masked = code.map { String(repeating: "•", count: max(0, $0.count - 2)) + $0.suffix(2) } ?? "—"
                    let link = SignInLink.find(in: m.links, subject: m.subject ?? "").map { "  → \($0.url.host ?? "")" } ?? ""
                    guard code != nil || !link.isEmpty || codeLike else { continue }
                    // Subjects often carry a code ("…verification code: 884 720", "…is SZBPM"): mask every
                    // digit and every capitals-only word of 4+ letters.
                    let subject = String((m.subject ?? "").replacingOccurrences(of: #"\d|\b\p{Lu}{4,}\b"#, with: "•", options: .regularExpression).prefix(60))
                    print("  \(m.date.formatted(date: .numeric, time: .omitted))  \(masked.padding(toLength: 10, withPad: " ", startingAt: 0))  \(m.service.prefix(22).padding(toLength: 22, withPad: " ", startingAt: 0))  \(subject)\(link)")
                }
            } catch {
                print("\(account.label): \(error.localizedDescription)")
            }
            await conn.close()
        }
    }
}
#endif
