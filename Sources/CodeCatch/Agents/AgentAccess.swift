import AppKit
import CodeCatchCore

/// The app a request came through, by its verified code signature: iTerm2, Terminal, Claude.
struct AgentApp: Codable, Hashable {
    /// The bundle identifier.
    let id: String
    /// Nil for Apple's own apps, such as Terminal.
    let team: String?
    let name: String

    func same(as other: AgentApp) -> Bool { id == other.id && team == other.team }
}

struct AgentCaller: Equatable {
    /// Nil when no app in the chain of parent processes has a valid signature (a script run by launchd, ssh).
    var app: AgentApp?
    var appPath: URL?
    /// The asking program's own name ("claude", "node"). Any program can call itself anything.
    var process: String

    var name: String { app?.name ?? "An unverified program" }
    var logLabel: String { [app?.name ?? "Unverified", process].joined(separator: " · ") }
}

/// "Always allow": codes for one site, or for every site, from one app. Sign-in links too while
/// `AgentConfig.links` is on.
struct AgentRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var app: AgentApp
    /// The sender's registrable domain; nil for every site.
    var site: String?
    var added = Date()
}

/// Kept in the login Keychain, not UserDefaults: a script can `defaults write` a switch on,
/// but can't write an item that only this team's builds may change without a prompt.
struct AgentConfig: Codable, Equatable {
    var enabled = false
    var rules: [AgentRule] = []
    /// Every code to any agent, without asking, like skipping permission prompts.
    var allowAll = false
    /// Sign-in links may go to agents at all. A link signs the agent in as the user, so it's off until
    /// turned on; then links follow the same card, rules and Allow All as codes.
    var links = false
    /// Automatic releases share the protected store with the grants they consume.
    var releases: [Date] = []

    init(enabled: Bool = false, rules: [AgentRule] = [], allowAll: Bool = false, links: Bool = false) {
        self.enabled = enabled; self.rules = rules; self.allowAll = allowAll; self.links = links
    }

    /// Settings saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        rules = try c.decodeIfPresent([AgentRule].self, forKey: .rules) ?? []
        allowAll = try c.decodeIfPresent(Bool.self, forKey: .allowAll) ?? false
        links = try c.decodeIfPresent(Bool.self, forKey: .links) ?? false
        releases = try c.decodeIfPresent([Date].self, forKey: .releases) ?? []
    }
}

struct AgentLogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let caller: String
    let site: String
    let outcome: String
}

/// Lets agents and scripts ask for a code through `codecatch`. Every release is the user's OK:
/// Touch ID or the Mac password on the request's card, or a rule they made the same way.
@MainActor
final class AgentAccess: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let caller: AgentCaller
        let query: SiteQuery
        let asked: Date
        /// The code the card offers, once one arrives. An approval covers this item and no other.
        var item: CodeItem?
        /// An SMS that names no site: only the user can tell it is the one asked for.
        var unnamed = false
    }

    enum Always: Equatable { case site, allSites }
    /// `notice` names the rule that released the code; nil when Allow All did.
    enum Presentation { case card, notice(CodeItem, AgentCaller, AgentRule?), hide }

    /// Codes this old still count when the request gives no `since`.
    static let lookback: TimeInterval = 30
    static let maxLookback: TimeInterval = 300
    /// Releases by rule in an hour; past this the user is asked again.
    static let ruleLimit = 20
    /// Denials in a row that turn access off.
    static let denialLimit = 3

    @Published private(set) var config = AgentConfig()
    @Published private(set) var request: Request?
    @Published private(set) var log: [AgentLogEntry]
    @Published private(set) var error: String?
    /// While Touch ID is up for the card.
    @Published private(set) var authenticating = false

    var present: (Presentation) -> Void = { _ in }
    /// A code that arrives near the end of the wait still gets this long for the user to approve it.
    var approvalGrace: TimeInterval = 45

    private let items: () -> [CodeItem]
    private let markUsed: (CodeItem) -> Void
    private let authenticate: (String) async throws -> Void
    private let load: () throws -> AgentConfig
    private let save: (AgentConfig) throws -> Void
    private let defaults: UserDefaults
    private let now: () -> Date

    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var decision: (request: UUID, continuation: CheckedContinuation<Decision, Never>)?
    private var denials = 0
    /// Set by a lock, sleep or turning access off once a code is on the card; ends the request even
    /// after Allow, up to the release itself.
    private var cancelled: String?
    private static let logKey = "agentLog"

    private enum Decision { case allow(Always?), deny, timeout, cancelled(String) }

    init(items: @escaping () -> [CodeItem], markUsed: @escaping (CodeItem) -> Void,
         authenticate: @escaping (String) async throws -> Void,
         load: @escaping () throws -> AgentConfig, save: @escaping (AgentConfig) throws -> Void,
         defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.items = items; self.markUsed = markUsed; self.authenticate = authenticate
        self.load = load; self.save = save; self.defaults = defaults; self.now = now
        log = defaults.data(forKey: Self.logKey).flatMap { try? JSONDecoder().decode([AgentLogEntry].self, from: $0) } ?? []
    }

    /// Reads the saved switch and rules. Not in `init`: tests and snapshots never touch the Keychain.
    func restore() {
        do { config = try load() } catch { self.error = error.localizedDescription }
    }

    // MARK: - Requests

    static let accessOff = AgentError(.accessOff, "Command-line access is off. The user can turn it on in CodeCatch → Settings → Agents.")

    /// Finds or waits for a code for `site` and releases it once allowed. One request at a time.
    func get(site: String, since: Date?, timeout: TimeInterval?, caller: AgentCaller,
             progress: @escaping (String) -> Void) async -> Result<CodeItem, AgentError> {
        guard config.enabled else { return .failure(Self.accessOff) }
        guard request == nil else { return .failure(AgentError(.busy, "CodeCatch is handling another request. Try again when it is done.")) }
        guard let query = SiteQuery(site) else { return .failure(AgentError(.usage, "\"\(site)\" isn't a site. Use a domain, URL or service name.")) }
        let asked = now()
        let wait = min(max(timeout ?? AgentWire.defaultTimeout, 1), AgentWire.maxTimeout)
        let deadline = asked.addingTimeInterval(wait)
        let from = since.map { max($0, asked.addingTimeInterval(-Self.maxLookback)) } ?? asked.addingTimeInterval(-Self.lookback)
        request = Request(caller: caller, query: query, asked: asked)
        cancelled = nil
        defer { request = nil }

        var announced = false
        while true {
            guard !Task.isCancelled else { return failure(.approvalTimeout, "The request was cancelled.", query, caller, log: "Cancelled") }
            guard config.enabled else { return .failure(Self.accessOff) }
            if let (item, unnamed) = candidate(for: query, from: from) {
                return await offer(item, unnamed: unnamed, deadline: deadline, progress: progress)
            }
            guard now() < deadline else {
                return failure(.noCode, "No \(query.label) code arrived in \(Int(wait)) seconds. Send a new one and try again.", query, caller, log: "No code arrived")
            }
            if !announced {
                progress("waiting up to \(Int(wait))s for a \(query.label) code…")
                announced = true
            }
            await nextChange(until: deadline)
        }
    }

    /// The newest unused, live code for the site since `from`; else an SMS that names no site.
    func candidate(for query: SiteQuery, from: Date) -> (CodeItem, unnamed: Bool)? {
        let fresh = items().filter { [.messages, .mail].contains($0.origin) && !$0.used && now() < $0.expires && $0.received >= from
            && (!$0.isLink || config.links) }
        let newest = { (a: CodeItem, b: CodeItem) in a.received < b.received }
        if let item = fresh.filter({ Self.matches($0, query) }).max(by: newest) { return (item, false) }
        if let sms = fresh.filter({ $0.origin == .messages && $0.domain == nil && !$0.code.isEmpty }).max(by: newest) { return (sms, true) }
        return nil
    }

    /// A code from the site; a link only where it can't hand the agent someone else's session. Mail
    /// without a domain failed sender verification: its display name proves nothing.
    /// An SMS that names no service gets its sender as its name ("12345"): that names no site, whatever
    /// the agent asks for, so it never matches and always goes to the card as unnamed.
    static func matches(_ item: CodeItem, _ query: SiteQuery) -> Bool {
        guard item.origin != .mail || item.domain != nil, item.domain != nil || item.service.lowercased() != item.sender.lowercased(),
              query.matches(domain: item.domain, service: item.service) else { return false }
        return !item.isLink || releasesLink(item, for: query)
    }

    /// Never a password reset, never a link the lookalike check warns about, and only from a sender the
    /// mail server verified, to the site that was asked for itself: an alias names who mails for a site
    /// (anthropic.com for claude.ai), not where its links may go.
    static func releasesLink(_ item: CodeItem, for query: SiteQuery) -> Bool {
        guard item.link != nil, !item.resetsPassword, item.senderVerified == true, item.linkNotice?.warns != true,
              let host = item.destination?.host, let domain = query.domain else { return false }
        return ServiceIdentity.registrable(host) == domain
    }

    private func offer(_ item: CodeItem, unnamed: Bool, deadline: Date, progress: (String) -> Void) async -> Result<CodeItem, AgentError> {
        guard let request else { return .failure(AgentError(.failed, "The request ended.")) }
        let query = request.query, caller = request.caller
        // A rule, or Allow All; never for an SMS that names no site, and past the hourly cap the user is asked.
        // Under Allow All the release is Allow All's, so the notice's Turn Off stops what released it.
        let rule = config.allowAll ? nil : rule(for: item, caller: caller), releases = recentRuleReleases
        if !unnamed, item.origin != .mail || item.senderVerified == true,
           rule != nil || config.allowAll, releases.count < Self.ruleLimit {
            var updated = config
            updated.releases = releases + [now()]
            // Count durably before releasing; a storage failure falls back to explicit approval.
            if store(updated) {
                release(item, query, caller, log: rule == nil ? "Allowed by Allow All" : "Allowed by rule")
                present(.notice(item, caller, rule))
                return .success(item)
            }
        }
        self.request?.item = item
        self.request?.unnamed = unnamed
        present(.card)
        progress("\(item.isLink ? "sign-in link" : "code") arrived. Ask the user to approve it in the CodeCatch banner.")
        let decision = await awaitDecision(for: request.id, until: max(deadline, now().addingTimeInterval(approvalGrace)))
        present(.hide)
        switch decision {
        case .allow(let always):
            if let why = cancelled ?? (Task.isCancelled ? "The request was cancelled." : nil) {
                return failure(.approvalTimeout, why, query, caller, log: "Cancelled")
            }
            // The approval covers what the card showed: not a newer message that took its row.
            guard config.enabled, !item.isLink || config.links, let current = items().first(where: { $0.id == item.id }), !current.used,
                  now() < current.expires, current.code == item.code, current.link == item.link else {
                return failure(.failed, "The code expired or changed before it was approved.", query, caller, log: "Expired")
            }
            denials = 0
            // A site rule needs the sender's domain; without one it must not quietly become "every site".
            if let always, let app = caller.app, !unnamed, item.origin != .mail || item.senderVerified == true,
               always == .allSites || item.domain != nil {
                addRule(AgentRule(app: app, site: always == .site ? item.domain : nil, added: now()))
            }
            release(item, query, caller, log: always == nil ? "Allowed" : "Allowed, and always from now on")
            return .success(item)
        case .deny:
            denials += 1
            if denials >= Self.denialLimit { turnOff(reason: "Turned off after you said no \(Self.denialLimit) times in a row") }
            return failure(.denied, "The user said no. Don't ask again unless they tell you to.", query, caller, log: "Denied")
        case .timeout:
            return failure(.approvalTimeout, "The user didn't approve the \(query.label) code in time. Ask them to watch for the CodeCatch banner, then try again.", query, caller, log: "Not approved in time")
        case .cancelled(let why):
            return failure(.approvalTimeout, why, query, caller, log: "Cancelled")
        }
    }

    func rule(for item: CodeItem, caller: AgentCaller) -> AgentRule? {
        guard let app = caller.app else { return nil }
        return config.rules.first { rule in
            rule.app.same(as: app) && (rule.site == nil || rule.site == item.domain)
        }
    }

    /// Releases by rule in the last hour. Kept across restarts, so quitting doesn't reset the cap.
    private var recentRuleReleases: [Date] {
        config.releases.filter { now().timeIntervalSince($0) < 3600 }
    }

    private func release(_ item: CodeItem, _ query: SiteQuery, _ caller: AgentCaller, log outcome: String) {
        markUsed(item)
        record(caller, query, outcome)
    }

    private func failure(_ code: AgentError.Code, _ message: String, _ query: SiteQuery, _ caller: AgentCaller, log outcome: String) -> Result<CodeItem, AgentError> {
        record(caller, query, outcome)
        return .failure(AgentError(code, message))
    }

    // MARK: - The card

    /// Allow, after Touch ID or the Mac password, every time: a click alone could come from a script
    /// with Accessibility access. A failed or cancelled prompt leaves the card up.
    func allow(_ always: Always? = nil) async {
        guard let request, let item = request.item, decision?.request == request.id, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let app = request.caller.name, site = item.domain ?? request.query.label
        // The prompt names what is granted, so a script that picked Always Allow can't pass it off as one code.
        let reason = switch always {
        case nil: "give \(app) \(item.isLink ? "a \(site) sign-in link" : "your \(site) code")"
        case .site: "give \(app) your \(site) code, and \(site) codes from now on without asking"
        case .allSites: "give \(app) your \(site) code, and all codes from now on without asking"
        }
        do { try await authenticate(reason) } catch { return }
        resolve(.allow(always), for: request.id)
    }

    func deny() {
        guard let request else { return }
        resolve(.deny, for: request.id)
    }

    /// Screen lock, sleep, access turned off: whoever was asked isn't there to answer. Ends a request
    /// whose code is on the card, until the moment of release. One still waiting for its code keeps
    /// waiting, so rules can serve an unattended run while the Mac is locked.
    func cancel(_ why: String) {
        guard let request, request.item != nil else { return }
        cancelled = why
        resolve(.cancelled(why), for: request.id)
    }

    private func awaitDecision(for id: UUID, until deadline: Date) async -> Decision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decision = (id, continuation)
                let delay = max(0, deadline.timeIntervalSince(now()))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.resolve(.timeout, for: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(.cancelled("The request was cancelled."), for: id) }
        }
    }

    private func resolve(_ value: Decision, for id: UUID) {
        guard let pending = decision, pending.request == id else { return }
        decision = nil
        pending.continuation.resume(returning: value)
    }

    // MARK: - Waiting for codes

    /// Called whenever the model's codes change.
    func itemsChanged() {
        for id in Array(waiters.keys) { wake(id) }
    }

    private func nextChange(until deadline: Date) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                let delay = max(0, deadline.timeIntervalSince(now()))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.wake(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id) }
        }
    }

    private func wake(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }

    /// Whether a request is waiting: new codes then skip auto-copy and auto-type, which would hand
    /// them to any program reading the clipboard, around the approval.
    var isWaiting: Bool { request != nil }

    // MARK: - Settings

    /// Turning access on asks for Touch ID or the Mac password; off never does.
    func setEnabled(_ on: Bool) async {
        guard on != config.enabled else { return }
        if on {
            do { try await authenticate("let agents and scripts ask for your codes") } catch { return }
        }
        var updated = config
        updated.enabled = on
        guard store(updated, revoking: !on) else { return }
        denials = 0
        if !on {
            cancel("Command-line access was turned off.")
            itemsChanged()  // a request still waiting for its code ends now, not at its deadline
        }
    }

    /// Links on asks again: a link signs the agent in, not just past a second step. Off never asks.
    func setLinks(_ on: Bool) async {
        guard on != config.links else { return }
        if on {
            do { try await authenticate("let agents get sign-in links, which sign them in as you") } catch { return }
        }
        var updated = config
        updated.links = on
        store(updated, revoking: !on)
        if !on, request?.item?.isLink == true { cancel("Sign-in links were turned off.") }
    }

    /// On asks for Touch ID or the Mac password, and says plainly what it grants; off never asks.
    func setAllowAll(_ on: Bool) async {
        guard on != config.allowAll else { return }
        if on {
            do { try await authenticate("give any agent your codes without asking") } catch { return }
        }
        var updated = config
        updated.allowAll = on
        store(updated, revoking: !on)
    }

    func removeRules(_ ids: Set<AgentRule.ID>) {
        var updated = config
        updated.rules.removeAll { ids.contains($0.id) }
        store(updated, revoking: true)
    }

    func removeRule(_ id: AgentRule.ID) { removeRules([id]) }

    private func addRule(_ rule: AgentRule) {
        var updated = config
        // One rule per app and site; "all sites" covers that app's single-site rules, so they go.
        updated.rules.removeAll { $0.app.same(as: rule.app) && ($0.site == rule.site || rule.site == nil) }
        updated.rules.append(rule)
        store(updated)
    }

    private func turnOff(reason: String) {
        var updated = config
        updated.enabled = false
        store(updated, revoking: true)
        log.insert(AgentLogEntry(date: now(), caller: "CodeCatch", site: "", outcome: reason), at: 0)
        saveLog()
    }

    /// A grant takes effect only once saved. A revocation takes effect now, even when the Keychain
    /// refuses the write: failing to save must not leave access open.
    @discardableResult
    private func store(_ updated: AgentConfig, revoking: Bool = false) -> Bool {
        if revoking { config = updated }
        do {
            try save(updated)
            config = updated
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return revoking
        }
    }

    // MARK: - Log

    /// Who asked for what and how it ended; never the code. Kept to the last 50.
    private func record(_ caller: AgentCaller, _ query: SiteQuery, _ outcome: String) {
        log.insert(AgentLogEntry(date: now(), caller: caller.logLabel, site: query.label, outcome: outcome), at: 0)
        saveLog()
    }

    private func saveLog() {
        log = Array(log.prefix(50))
        defaults.set(try? JSONEncoder().encode(log), forKey: Self.logKey)
    }

    func clearLog() {
        log = []
        defaults.removeObject(forKey: Self.logKey)
    }

    #if DEBUG
    /// `--snapshot`: a request, rules and log to draw, without a client or the Keychain.
    func preview(_ request: Request?, config: AgentConfig, log: [AgentLogEntry]) {
        self.request = request
        self.config = config
        self.log = log
    }
    #endif

    // MARK: - Wire

    /// What the CLI prints. A code goes alone: the link beside it was neither shown on the card nor
    /// covered by a code-only rule. A link-only item got here through `releasesLink`.
    static func wire(_ item: CodeItem) -> AgentItem {
        let code = item.code.isEmpty ? nil : item.code
        let link = code == nil ? item.link?.absoluteString : nil
        return AgentItem(kind: code == nil ? .link : .code, value: code ?? link ?? "", code: code, link: link, service: item.service,
                         domain: item.domain, source: item.origin == .mail ? "mail" : "messages", senderVerified: item.senderVerified,
                         received: item.received, expires: item.expires)
    }
}

/// The switch and rules in the login Keychain, beside the app's other secrets.
enum AgentStore {
    private static let key = "agent-access"

    static func load() throws -> AgentConfig {
        guard let json = try Secrets.read(key) else { return AgentConfig() }
        return try JSONDecoder().decode(AgentConfig.self, from: Data(json.utf8))
    }

    static func save(_ config: AgentConfig) throws {
        try Secrets.set(String(decoding: try JSONEncoder().encode(config), as: UTF8.self), for: key)
    }
}
