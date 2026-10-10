import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

// Written from the AgentAccess contract only. The gate must never let a code leave
// without the user's approval or a matching "always allow" rule.

private let agentApp = AgentApp(id: "com.example.agent", team: "TEAM1", name: "Agent")
private let verified = AgentCaller(app: agentApp, appPath: nil, process: "agent")
private let unverified = AgentCaller(app: nil, appPath: nil, process: "unknown")
private let secretCode = "482913"
private let secretToken = "SIGNINTOKEN77"

private func item(code: String = secretCode, link: URL? = nil, service: String = "GitHub", domain: String? = "github.com",
                  origin: CodeItem.Origin = .mail, age: TimeInterval = 1, expiresIn: TimeInterval = 600,
                  used: Bool = false, resetsPassword: Bool = false, senderVerified: Bool? = true, sender: String? = nil) -> CodeItem {
    let now = Date()
    return CodeItem(origin: origin, code: code, link: link, service: service, sourceLabel: "Work", sourceKey: "work",
                    accountLabel: "Work", sender: sender ?? "noreply@\(domain ?? "unknown")", preview: "Your code", snippet: "Your code",
                    received: now.addingTimeInterval(-age), expires: now.addingTimeInterval(expiresIn), domain: domain,
                    dismissKey: UUID().uuidString, used: used, resetsPassword: resetsPassword, senderVerified: senderVerified)
}

private func linkItem(_ url: String = "https://github.com/login/device?token=\(secretToken)", domain: String? = "github.com",
                      resetsPassword: Bool = false, senderVerified: Bool? = true, code: String = "") -> CodeItem {
    item(code: code, link: URL(string: url), domain: domain, resetsPassword: resetsPassword, senderVerified: senderVerified)
}

/// An SMS that names no site the agent asks for.
private func strangerSMS() -> CodeItem {
    item(service: "Unknown sender", domain: nil, origin: .messages, senderVerified: nil)
}

/// An SMS whose service is just its sender's number: it names no service at all.
private func selfNamedSMS(_ number: String = "12345") -> CodeItem {
    item(service: number, domain: nil, origin: .messages, senderVerified: nil, sender: number)
}

private struct Boom: Error {}

@MainActor private final class Harness {
    var items: [CodeItem] = []
    var marked: [CodeItem] = []
    var authCalls = 0
    var authFails = false
    var onAuthenticate: (() async -> Void)?
    var saved: [AgentConfig] = []
    var saveFails = false
    var cards = 0, notices = 0, hides = 0
    var noticeRules: [AgentRule?] = []
    var finished = false
    let defaults: UserDefaults
    let suite = "AgentAccessTests.\(UUID())"
    private(set) var access: AgentAccess!

    init(_ config: AgentConfig = AgentConfig(enabled: true)) {
        defaults = UserDefaults(suiteName: suite)!
        access = AgentAccess(
            items: { [unowned self] in self.items },
            markUsed: { [unowned self] used in
                self.marked.append(used)
                if let i = self.items.firstIndex(where: { $0.id == used.id }) { self.items[i].used = true }
            },
            authenticate: { [unowned self] _ in
                self.authCalls += 1
                await self.onAuthenticate?()
                if self.authFails { throw Boom() }
            },
            load: { config },
            save: { [unowned self] config in
                if self.saveFails { throw Boom() }
                self.saved.append(config)
            },
            defaults: defaults)
        access.approvalGrace = 1
        access.present = { [unowned self] p in
            switch p {
            case .card: self.cards += 1
            case .notice(_, _, let rule): self.notices += 1; self.noticeRules.append(rule)
            case .hide: self.hides += 1
            }
        }
        access.restore()
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    func add(_ new: CodeItem) {
        items.append(new)
        access.itemsChanged()
    }

    func start(_ site: String = "github.com", since: Date? = nil, timeout: TimeInterval = 1,
               caller: AgentCaller = verified) -> Task<Result<CodeItem, AgentError>, Never> {
        finished = false
        return Task {
            let result = await access.get(site: site, since: since, timeout: timeout, caller: caller, progress: { _ in })
            finished = true
            return result
        }
    }

    func until(_ condition: () -> Bool, within: TimeInterval = 1) async -> Bool {
        let end = Date().addingTimeInterval(within)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    func waitForCard() async throws {
        try #require(await until { access.request?.item != nil })
    }

    /// Whether the request offers a code on the card; denies it if so.
    func offered(_ site: String = "github.com", since: Date? = nil, timeout: TimeInterval = 0.2,
                 caller: AgentCaller = verified) async -> Bool {
        let task = start(site, since: since, timeout: timeout, caller: caller)
        _ = await until { access.request?.item != nil || finished }
        let shown = access.request?.item != nil
        if shown { access.deny() }
        _ = await task.value
        return shown
    }

    /// One request that shows the card, then the given decision.
    func decide(_ new: CodeItem, caller: AgentCaller = verified,
                _ decision: (AgentAccess) async -> Void) async throws -> Result<CodeItem, AgentError> {
        add(new)
        let task = start(new.domain ?? "github.com", caller: caller)
        try await waitForCard()
        await decision(access)
        return await task.value
    }
}

private extension Result where Success == CodeItem, Failure == AgentError {
    var code: AgentError.Code? {
        if case .failure(let e) = self { return e.code }
        return nil
    }
    var item: CodeItem? {
        if case .success(let item) = self { return item }
        return nil
    }
}

@MainActor @Suite struct AgentAccessTests {

    // MARK: Gate

    /// Access off must win over Allow All, or turning access off would leave codes flowing.
    @Test(arguments: [false, true])
    func accessOffReleasesNothingAndShowsNoCard(_ allowAll: Bool) async {
        let h = Harness(AgentConfig(enabled: false, allowAll: allowAll))
        h.items = [item()]
        let result = await h.access.get(site: "github.com", since: nil, timeout: 0.2, caller: unverified, progress: { _ in })
        #expect(result.code == .accessOff)
        #expect(h.marked.isEmpty)
        #expect(h.cards == 0)
    }

    @Test func secondRequestWhileOneIsPendingIsBusyNotQueued() async throws {
        let h = Harness()
        h.add(item())
        let first = h.start()
        try await h.waitForCard()
        let second = await h.access.get(site: "github.com", since: nil, timeout: 0.2, caller: verified, progress: { _ in })
        #expect(second.code == .busy)
        h.access.deny()
        #expect(await first.value.code == .denied)
        #expect(h.marked.isEmpty)
    }

    @Test func unparseableSiteIsAUsageError() async {
        let h = Harness()
        let result = await h.access.get(site: "not a site!", since: nil, timeout: 0.2, caller: verified, progress: { _ in })
        #expect(result.code == .usage)
    }

    @Test func noMatchingCodeTimesOutAsNoCodeAndIsLogged() async {
        let h = Harness()
        let before = h.access.log.count
        let result = await h.start(timeout: 0.2).value
        #expect(result.code == .noCode)
        #expect(h.access.log.count == before + 1)
    }

    // MARK: Approval

    @Test func codeArrivingWhileWaitingShowsCardAndWaitsForDecision() async throws {
        let h = Harness()
        let task = h.start()
        #expect(await h.until { h.access.isWaiting })
        let code = item()
        h.add(code)
        try await h.waitForCard()
        #expect(h.cards >= 1)
        #expect(h.access.request?.item?.id == code.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!h.finished, "get must not finish before the user decides")
        h.access.deny()
        _ = await task.value
    }

    @Test func allowAuthenticatesEveryTimeWithNoSessionReuse() async throws {
        let h = Harness()
        let first = item(), second = item()
        let r1 = try await h.decide(first) { await $0.allow() }
        #expect(r1.item?.id == first.id)
        #expect(h.authCalls == 1)
        #expect(h.marked.map(\.id) == [first.id])

        let r2 = try await h.decide(second) { await $0.allow() }
        #expect(r2.item?.id == second.id)
        #expect(h.authCalls == 2)
        #expect(h.marked.map(\.id) == [first.id, second.id])
    }

    @Test func failedAuthenticationReleasesNothingAndKeepsRequestPending() async throws {
        let h = Harness()
        h.authFails = true
        h.add(item())
        let task = h.start()
        try await h.waitForCard()
        await h.access.allow()
        #expect(h.authCalls == 1)
        #expect(h.marked.isEmpty)
        #expect(h.access.isWaiting)
        #expect(!h.finished)
        h.access.deny()
        #expect(await task.value.code == .denied)
        #expect(h.marked.isEmpty)
    }

    @Test func denyReleasesNothing() async throws {
        let h = Harness()
        let result = try await h.decide(item()) { $0.deny() }
        #expect(result.code == .denied)
        #expect(h.marked.isEmpty)
        #expect(h.authCalls == 0)
    }

    @Test func noDecisionTimesOutAndHidesCard() async throws {
        let h = Harness()
        h.access.approvalGrace = 0.1
        h.add(item())
        let result = await h.start(timeout: 0.2).value
        #expect(result.code == .approvalTimeout)
        #expect(h.cards >= 1)
        #expect(h.hides >= 1)
        #expect(h.marked.isEmpty)
    }

    @Test func cancelWhileCardIsUpTimesOutWithReasonAndReleasesNothing() async throws {
        let h = Harness()
        let why = "lock-\(UUID().uuidString)"
        let result = try await h.decide(item()) { $0.cancel(why) }
        #expect(result.code == .approvalTimeout)
        if case .failure(let e) = result { #expect(e.message.contains(why)) }
        #expect(h.marked.isEmpty)
    }

    @Test func cancelledClientTaskReleasesNothingAndHidesCard() async throws {
        let h = Harness()
        h.add(item())
        let task = h.start()
        try await h.waitForCard()
        task.cancel()
        let result = await task.value
        #expect(result.code != nil)
        #expect(h.marked.isEmpty)
        #expect(h.hides >= 1)
        // A late Allow on the vanished card must not release it either.
        await h.access.allow()
        #expect(h.marked.isEmpty)
    }

    @Test func allowReleasesTheShownCodeNotANewerOne() async throws {
        let h = Harness()
        let shown = item(age: 5)
        let newer = item(age: 0)
        let result = try await h.decide(shown) { access in
            h.add(newer)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await access.allow()
        }
        #expect(result.item?.id == shown.id)
        #expect(h.marked.map(\.id) == [shown.id])
    }

    @Test func shownCodeUsedDuringAuthenticationFailsInsteadOfReleasingAnother() async throws {
        let h = Harness()
        let shown = item(age: 5)
        let other = item(age: 0)
        h.onAuthenticate = {
            if let i = h.items.firstIndex(where: { $0.id == shown.id }) { h.items[i].used = true }
            h.add(other)
        }
        let result = try await h.decide(shown) { await $0.allow() }
        #expect(result.code != nil)
        #expect(h.marked.isEmpty)
    }

    @Test func shownCodeExpiringDuringAuthenticationFailsInsteadOfReleasingAnother() async throws {
        let h = Harness()
        let shown = item(age: 5, expiresIn: 0.5)
        h.onAuthenticate = {
            h.add(item(age: 0))
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        let result = try await h.decide(shown) { await $0.allow() }
        #expect(result.code != nil)
        #expect(h.marked.isEmpty)
    }

    @Test func repeatedDenialsTurnAccessOffAndSaveIt() async throws {
        let h = Harness()
        for _ in 0..<AgentAccess.denialLimit {
            _ = try await h.decide(item()) { $0.deny() }
        }
        #expect(h.access.config.enabled == false)
        #expect(h.saved.last == h.access.config)
    }

    @Test func allowBetweenDenialsResetsTheDenialCount() async throws {
        let h = Harness()
        for _ in 0..<(AgentAccess.denialLimit - 1) { _ = try await h.decide(item()) { $0.deny() } }
        _ = try await h.decide(item()) { await $0.allow() }
        for _ in 0..<(AgentAccess.denialLimit - 1) { _ = try await h.decide(item()) { $0.deny() } }
        #expect(h.access.config.enabled)
    }

    // MARK: Rules

    enum RuleHit: String, CaseIterable {
        case sameSite, allSites, linkWithLinksOn, appRenamed
        case allowAllCode, allowAllUnverifiedCaller, allowAllLink
        /// Allow All and a rule both match: the notice must credit Allow All, or turning it off looks like it changed nothing.
        case allowAllAndRule
    }

    @Test(arguments: RuleHit.allCases)
    func matchingRuleReleasesWithoutCardOrAuthentication(_ hit: RuleHit) async throws {
        var rule = AgentRule(app: agentApp, site: "github.com")
        var code = item()
        var site = "github.com"
        var caller = verified
        var allowAll = false
        var links = false
        switch hit {
        case .sameSite: break
        case .allSites: rule.site = nil; code = item(service: "GitLab", domain: "gitlab.com"); site = "gitlab.com"
        case .linkWithLinksOn: links = true; code = linkItem()
        case .appRenamed: rule.app = AgentApp(id: agentApp.id, team: agentApp.team, name: "Old name")
        case .allowAllCode: allowAll = true
        case .allowAllUnverifiedCaller: allowAll = true; caller = unverified
        case .allowAllLink: allowAll = true; links = true; caller = unverified; code = linkItem()
        case .allowAllAndRule: allowAll = true
        }
        let withRule = !allowAll || hit == .allowAllAndRule
        let h = Harness(AgentConfig(enabled: true, rules: withRule ? [rule] : [], allowAll: allowAll, links: links))
        h.add(code)
        let result = await h.start(site, caller: caller).value
        #expect(result.item?.id == code.id)
        #expect(h.cards == 0)
        #expect(h.notices == 1)
        #expect(h.marked.map(\.id) == [code.id])
        #expect(h.authCalls == 0)
        // The notice names the rule that released it; nil means Allow All did.
        let noticeRule = try #require(h.noticeRules.first)
        if allowAll { #expect(noticeRule == nil) } else { #expect(noticeRule?.id == rule.id) }
    }

    enum RuleMiss: String, CaseIterable {
        case otherApp, sameIdOtherTeam, sameIdNoTeam, unverifiedCaller, otherSite, unnamedSMS
        case unnamedSMSUnderAllowAll
        /// An SMS whose service is its own number must not match `get("12345")` and slip past the card.
        case selfNamedSMSAllSitesRule, selfNamedSMSUnderAllowAll
    }

    @Test(arguments: RuleMiss.allCases)
    func ruleDoesNotApplyOutsideItsScopeSoUserIsAsked(_ miss: RuleMiss) async throws {
        var rule = AgentRule(app: agentApp, site: "github.com")
        var caller = verified
        var code = item()
        var allowAll = false
        var site = "github.com"
        switch miss {
        case .otherApp: caller.app = AgentApp(id: "com.example.other", team: "TEAM1", name: "Agent")
        case .sameIdOtherTeam: caller.app = AgentApp(id: agentApp.id, team: "EVIL", name: "Agent")
        case .sameIdNoTeam: caller.app = AgentApp(id: agentApp.id, team: nil, name: "Agent")
        case .unverifiedCaller: caller = unverified; rule.site = nil
        case .otherSite: rule.site = "gitlab.com"
        case .unnamedSMS: rule.site = nil; code = strangerSMS()
        case .unnamedSMSUnderAllowAll: rule.site = nil; code = strangerSMS(); allowAll = true
        case .selfNamedSMSAllSitesRule: rule.site = nil; code = selfNamedSMS(); site = "12345"
        case .selfNamedSMSUnderAllowAll: rule.site = nil; code = selfNamedSMS(); site = "12345"; allowAll = true
        }
        let h = Harness(AgentConfig(enabled: true, rules: [rule], allowAll: allowAll))
        h.add(code)
        let task = h.start(site, caller: caller)
        try await h.waitForCard()
        #expect(h.marked.isEmpty)
        #expect(h.notices == 0)
        if code.origin == .messages { #expect(h.access.request?.unnamed == true) }
        h.access.deny()
        #expect(await task.value.code == .denied)
        #expect(h.marked.isEmpty)
    }

    enum CapSource: String, CaseIterable { case rule, allowAll, ruleThenAllowAll }

    @Test(arguments: [false, true], [Optional<Bool>.none, .some(false)])
    func unverifiedMailSenderCannotUseAutomaticApproval(_ allowAll: Bool, _ senderVerified: Bool?) async throws {
        let h = Harness(AgentConfig(enabled: true, rules: [AgentRule(app: agentApp, site: "github.com")],
                                    allowAll: allowAll))
        h.add(item(senderVerified: senderVerified))
        let task = h.start()
        try await h.waitForCard()
        #expect(h.marked.isEmpty)
        #expect(h.notices == 0)
        h.access.deny()
        #expect(await task.value.code == .denied)
    }

    enum MailIngressTrust: CaseIterable { case verifiedGmail, missingReceiver, forgedIssuer }

    @Test(arguments: MailIngressTrust.allCases, [false, true])
    func onlyTrustedReceiverVerificationSurvivesMailIngressToAutomaticRelease(
        _ trust: MailIngressTrust, _ allowAll: Bool
    ) async throws {
        let issuer = trust == .forgedIssuer ? "attacker.invalid" : "mx.google.com"
        let raw = "Authentication-Results: \(issuer); dmarc=pass header.from=github.com\r\n"
            + "Received: from mail.github.com\r\nFrom: GitHub <no-reply@github.com>\r\n"
            + "Subject: Your GitHub verification code\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
            + "Your GitHub verification code is 482913."
        let parsed = MIME.parse(Data(raw.utf8), receiver: trust == .missingReceiver ? nil : .gmail)
        var message = IncomingMessage(text: parsed.text, subject: parsed.subject, senderName: parsed.fromName,
                                      senderID: parsed.fromAddress, sourceKey: "test-mail", sourceLabel: "Test",
                                      date: Date().addingTimeInterval(-1), isMail: true, links: parsed.links)
        message.senderVerified = parsed.senderVerified
        let h = Harness(AgentConfig(enabled: true, rules: [AgentRule(app: agentApp, site: "github.com")],
                                    allowAll: allowAll))
        for key in ["autoCopy", "showHUD", "sound", "autoType"] { h.defaults.set(false, forKey: key) }
        Prefs.register(in: h.defaults)
        let model = AppModel(
            vaultSession: VaultSession(authenticate: {}, read: { [] }, write: { _ in }, remove: {}),
            monitor: SourceMonitor(watchMail: { _, _ in }, hasCredential: { _ in false }, defaults: h.defaults),
            defaults: h.defaults, accounts: [], copyToClipboard: { _, _ in })
        model.ingest(message)
        let extracted = try #require(model.items.first { $0.code == "482913" })
        h.items = model.items
        let task = h.start()
        if trust == .verifiedGmail {
            #expect(extracted.senderVerified == true)
            #expect(await task.value.item?.id == extracted.id)
            #expect(h.cards == 0)
            #expect(h.marked.map(\.id) == [extracted.id])
        } else {
            #expect(extracted.senderVerified != true)
            try await h.waitForCard()
            #expect(h.marked.isEmpty)
            #expect(h.notices == 0)
            h.access.deny()
            #expect(await task.value.code == .denied)
        }
        #expect(h.authCalls == 0)
    }

    @Test(arguments: [false, true])
    func clearingDefaultsCannotResetPersistedAutomaticReleaseLimit(_ allowAll: Bool) async throws {
        let h = Harness(AgentConfig(enabled: true, rules: [AgentRule(app: agentApp, site: nil)],
                                    allowAll: allowAll))
        for _ in 0..<20 {
            h.add(item())
            try #require(await h.start().value.item != nil)
        }
        let persisted = try #require(h.saved.last)
        #expect(persisted.releases.count == 20)
        h.defaults.removeObject(forKey: "agentRuleReleases")

        let restarted = Harness(persisted)
        restarted.defaults.set([], forKey: "agentRuleReleases")
        restarted.add(item())
        let task = restarted.start()
        try await restarted.waitForCard()
        #expect(restarted.marked.isEmpty)
        #expect(restarted.notices == 0)
        restarted.access.deny()
        #expect(await task.value.code == .denied)
    }

    @Test(arguments: [false, true])
    func failedReleaseHistorySaveCannotReleaseAutomatically(_ allowAll: Bool) async {
        let h = Harness(AgentConfig(enabled: true, rules: [AgentRule(app: agentApp, site: nil)],
                                    allowAll: allowAll))
        h.saveFails = true
        h.add(item())
        let task = h.start(timeout: 0.2)
        _ = await h.until { h.access.request?.item != nil || h.finished }
        if h.access.request?.item != nil { h.access.deny() }
        #expect(await task.value.item == nil)
        #expect(h.marked.isEmpty)
        #expect(h.notices == 0)
    }

    @Test func persistedReleaseHistorySurvivesCodableRoundTrip() throws {
        var config = AgentConfig(enabled: true)
        config.releases = [Date(timeIntervalSince1970: 1_790_000_000)]
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.releases == config.releases)
    }

    @Test func legacyConfigWithoutReleaseHistoryStillDecodes() throws {
        let config = AgentConfig(enabled: true)
        let encoded = try JSONEncoder().encode(config)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "releases")
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.enabled)
        #expect(decoded.releases.isEmpty)
    }

    /// Allow All must count against the same hourly cap as rules, not get a fresh one.
    @Test(arguments: CapSource.allCases)
    func pastHourlyRuleLimitTheUserIsAskedAgain(_ source: CapSource) async throws {
        let h = Harness(AgentConfig(enabled: true, rules: source == .allowAll ? [] : [AgentRule(app: agentApp, site: nil)],
                                    allowAll: source == .allowAll))
        var caller = source == .allowAll ? unverified : verified
        for i in 0..<AgentAccess.ruleLimit {
            if source == .ruleThenAllowAll, i == AgentAccess.ruleLimit / 2 {
                await h.access.setAllowAll(true)
                try #require(h.access.config.allowAll)
                caller = unverified  // from here only Allow All can release
            }
            h.add(item())
            #expect(await h.start(caller: caller).value.item != nil)
        }
        #expect(h.cards == 0)
        #expect(h.marked.count == AgentAccess.ruleLimit)
        h.add(item())
        let task = h.start(caller: caller)
        try await h.waitForCard()
        #expect(h.marked.count == AgentAccess.ruleLimit)
        h.access.deny()
        _ = await task.value
    }

    @Test func allowAlwaysForSiteAddsRuleForThatSiteAndApp() async throws {
        let h = Harness()
        let code = item()
        let result = try await h.decide(code) { await $0.allow(.site) }
        #expect(result.item?.id == code.id)
        let rule = try #require(h.access.config.rules.first)
        #expect(h.access.config.rules.count == 1)
        #expect(rule.site == "github.com")
        #expect(rule.app.same(as: agentApp))
        #expect(h.access.config.links == false, "an always-allow must not turn on sign-in links without its own authentication")
        #expect(h.saved.last == h.access.config)
    }

    /// A site-wide rule must replace every single-site rule of that app, so removing it later leaves nothing behind.
    @Test func allowAlwaysForAllSitesReplacesThatAppsSingleSiteRules() async throws {
        let renamed = AgentApp(id: agentApp.id, team: agentApp.team, name: "Old name")
        let otherApp = AgentApp(id: "com.example.other", team: "TEAM1", name: "Other")
        let otherRule = AgentRule(app: otherApp, site: "github.com")
        let h = Harness(AgentConfig(enabled: true, rules: [
            AgentRule(app: agentApp, site: "gitlab.com"),
            AgentRule(app: renamed, site: "example.org"),
            otherRule,
        ]))
        _ = try await h.decide(item()) { await $0.allow(.allSites) }
        let mine = h.access.config.rules.filter { $0.app.same(as: agentApp) }
        #expect(mine.count == 1)
        #expect(mine.first?.site == nil)
        #expect(h.access.config.rules.map(\.id).contains(otherRule.id))
        #expect(h.access.config.rules.count == 2)
    }

    @Test(arguments: [AgentAccess.Always.site, .allSites])
    func allowAlwaysNeverAddsRuleForUnverifiedCaller(_ always: AgentAccess.Always) async throws {
        let h = Harness()
        _ = try await h.decide(item(), caller: unverified) { await $0.allow(always) }
        #expect(h.access.config.rules.isEmpty)
        #expect(h.saved.allSatisfy { $0.rules.isEmpty })
    }

    @Test(arguments: [AgentAccess.Always.site, .allSites], [Optional<Bool>.none, .some(false)])
    func unverifiedSenderAllowsOnlyThisCodeAndCannotCreateAutomaticApproval(
        _ always: AgentAccess.Always, _ senderVerified: Bool?
    ) async throws {
        let h = Harness()
        let first = item(senderVerified: senderVerified)
        let result = try await h.decide(first) { await $0.allow(always) }
        #expect(result.item?.id == first.id)
        #expect(h.authCalls == 1)
        #expect(h.access.config.rules.isEmpty)
        #expect(h.saved.allSatisfy { $0.rules.isEmpty })

        h.add(item(senderVerified: senderVerified))
        let next = h.start()
        try await h.waitForCard()
        #expect(h.marked.map(\.id) == [first.id])
        #expect(h.notices == 0)
        h.access.deny()
        #expect(await next.value.code == .denied)
    }

    @Test(arguments: [AgentAccess.Always.site, .allSites])
    func allowAlwaysNeverAddsRuleForUnnamedSMS(_ always: AgentAccess.Always) async throws {
        let h = Harness()
        h.add(strangerSMS())
        let task = h.start()
        try await h.waitForCard()
        await h.access.allow(always)
        _ = await task.value
        #expect(h.access.config.rules.isEmpty)
        #expect(h.saved.allSatisfy { $0.rules.isEmpty })
    }

    // MARK: Which codes count

    struct Window: CustomTestStringConvertible, Sendable {
        let age: TimeInterval
        let sinceAgo: TimeInterval?
        let offered: Bool
        var testDescription: String { "age \(Int(age))s, since \(sinceAgo.map { "\(Int($0))s ago" } ?? "none") → \(offered)" }
    }

    @Test(arguments: [
        Window(age: 10, sinceAgo: nil, offered: true),
        Window(age: 45, sinceAgo: nil, offered: false),     // older than lookback
        Window(age: 100, sinceAgo: 120, offered: true),
        Window(age: 100, sinceAgo: 60, offered: false),     // before since
        Window(age: 200, sinceAgo: 600, offered: true),
        Window(age: 400, sinceAgo: 600, offered: false),    // since capped at maxLookback
    ])
    func oldCodesAreNotOffered(_ w: Window) async {
        let h = Harness()
        h.add(item(age: w.age))
        let since = w.sinceAgo.map { Date().addingTimeInterval(-$0) }
        #expect(await h.offered(since: since) == w.offered)
        #expect(h.marked.isEmpty)
    }

    enum Unusable: String, CaseIterable { case used, expired, vault }

    @Test(arguments: Unusable.allCases)
    func unusableCodesAreNeverOffered(_ kind: Unusable) async {
        let h = Harness()
        switch kind {
        case .used: h.add(item(used: true))
        case .expired: h.add(item(age: 10, expiresIn: -1))
        case .vault: h.add(item(origin: .vault))
        }
        let result = await h.start(timeout: 0.2).value
        #expect(result.code == .noCode)
        #expect(h.cards == 0)
        #expect(h.marked.isEmpty)
    }

    struct Match: CustomTestStringConvertible, Sendable {
        let site: String
        let domain: String?
        let service: String
        let matches: Bool
        var sms = false
        var testDescription: String { "\(site) vs \(service) <\(domain ?? "nil")>\(sms ? " sms" : "") → \(matches)" }
    }

    @Test(arguments: [
        Match(site: "github.com", domain: "github.com", service: "GitHub", matches: true),
        Match(site: "https://github.com/login", domain: "github.com", service: "GitHub", matches: true),
        Match(site: "GitHub", domain: "github.com", service: "GitHub", matches: true),
        Match(site: "github.com", domain: "evil.com", service: "GitHub", matches: false),
        Match(site: "GitHub", domain: "evil.com", service: "GitHub", matches: false),
        Match(site: "github.com", domain: "notgithub.com", service: "GitHub", matches: false),
        // An SMS whose service is only its sender's number names nothing, so asking for that number must not match it.
        Match(site: "12345", domain: nil, service: "12345", matches: false, sms: true),
    ])
    func matchingIsBySenderDomainNotDisplayName(_ m: Match) throws {
        let query = try #require(SiteQuery(m.site))
        let candidate = m.sms ? selfNamedSMS(m.service) : item(service: m.service, domain: m.domain)
        #expect(AgentAccess.matches(candidate, query) == m.matches)
    }

    @Test func spoofedServiceNameFromOtherDomainIsNeverOffered() async {
        let h = Harness()
        h.add(item(service: "GitHub", domain: "evil.com"))
        #expect(await h.start(timeout: 0.2).value.code == .noCode)
        #expect(h.cards == 0)
    }

    @Test func unmatchedSMSIsOfferedAsUnnamed() async throws {
        let h = Harness()
        let sms = strangerSMS()
        h.add(sms)
        let task = h.start()
        try await h.waitForCard()
        #expect(h.access.request?.item?.id == sms.id)
        #expect(h.access.request?.unnamed == true)
        h.access.deny()
        _ = await task.value
    }

    @Test(arguments: [false, true])
    func newestMatchingCodeWins(_ newestFirst: Bool) async throws {
        let h = Harness()
        let older = item(age: 10), newer = item(age: 2)
        h.items = newestFirst ? [newer, older] : [older, newer]
        let task = h.start()
        try await h.waitForCard()
        #expect(h.access.request?.item?.id == newer.id)
        h.access.deny()
        _ = await task.value
    }

    // MARK: Links

    struct LinkCase: CustomTestStringConvertible, Sendable {
        let name: String
        let item: CodeItem
        let site: String
        let releases: Bool
        var testDescription: String { name }
    }

    @Test(arguments: [
        LinkCase(name: "verified sender, own site", item: linkItem(), site: "github.com", releases: true),
        LinkCase(name: "subdomain of the site", item: linkItem("https://auth.github.com/x?t=1"), site: "github.com", releases: true),
        LinkCase(name: "alias claude.ai from anthropic.com",
                 item: linkItem("https://claude.ai/magic-link#t=1", domain: "anthropic.com"), site: "claude.ai", releases: true),
        LinkCase(name: "password reset", item: linkItem(resetsPassword: true), site: "github.com", releases: false),
        LinkCase(name: "sender unverified (nil)", item: linkItem(senderVerified: nil), site: "github.com", releases: false),
        LinkCase(name: "sender failed DMARC", item: linkItem(senderVerified: false), site: "github.com", releases: false),
        LinkCase(name: "lookalike warning", item: linkItem(domain: nil), site: "github.com", releases: false),
        LinkCase(name: "verified sender linking elsewhere",
                 item: linkItem("https://evil.com/login", domain: "github.com"), site: "github.com", releases: false),
        LinkCase(name: "destination is another site than asked",
                 item: linkItem("https://claude.ai/magic-link", domain: "anthropic.com"), site: "github.com", releases: false),
    ])
    func linkIsReleasedOnlyWhenSafe(_ c: LinkCase) throws {
        let query = try #require(SiteQuery(c.site))
        #expect(AgentAccess.releasesLink(c.item, for: query) == c.releases)
    }

    /// Even with Sign-In Links on, neither a rule nor Allow All may release a reset link or a link `releasesLink` rejects.
    @Test(arguments: [false, true])
    func unsafeLinkOnlyItemIsNeverOffered(_ allowAll: Bool) async {
        let h = Harness(allowAll ? AgentConfig(enabled: true, allowAll: true, links: true)
                                 : AgentConfig(enabled: true, rules: [AgentRule(app: agentApp, site: nil)], links: true))
        h.add(linkItem(resetsPassword: true))
        h.add(linkItem("https://evil.com/login"))
        h.add(linkItem(senderVerified: false))
        #expect(await h.start(timeout: 0.2, caller: allowAll ? unverified : verified).value.code == .noCode)
        #expect(h.cards == 0)
        #expect(h.marked.isEmpty)
    }

    enum LinkPath: String, CaseIterable { case card, rule, allowAll }

    /// With Sign-In Links off, a safe link-only item must not leave by any path, not even onto a card;
    /// with it on, each path must work as it does for a code.
    @Test(arguments: LinkPath.allCases, [false, true])
    func signInLinksSwitchGatesLinkOnlyItemsOnEveryPath(_ path: LinkPath, _ links: Bool) async throws {
        let h = Harness(AgentConfig(enabled: true, rules: path == .rule ? [AgentRule(app: agentApp, site: "github.com")] : [],
                                    allowAll: path == .allowAll, links: links))
        let link = linkItem()
        h.add(link)
        let task = h.start(timeout: 0.3, caller: path == .allowAll ? unverified : verified)
        guard links else {
            #expect(await task.value.code == .noCode)
            #expect(h.cards == 0)
            #expect(h.notices == 0)
            #expect(h.marked.isEmpty)
            return
        }
        switch path {
        case .card:
            try await h.waitForCard()
            #expect(h.access.request?.item?.id == link.id)
            h.access.deny()
            #expect(await task.value.code == .denied)
            #expect(h.marked.isEmpty)
        case .rule, .allowAll:
            #expect(await task.value.item?.id == link.id)
            #expect(h.cards == 0)
            #expect(h.authCalls == 0)
            #expect(h.marked.map(\.id) == [link.id])
        }
    }

    enum LinksOff: String, CaseIterable { case thenAllow, duringAuthentication }

    /// Turning Sign-In Links off must withdraw a link already on the card, so a late or in-flight Allow can't release it.
    @Test(arguments: LinksOff.allCases)
    func turningLinksOffCancelsALinkOnTheCard(_ when: LinksOff) async throws {
        let h = Harness(AgentConfig(enabled: true, links: true))
        h.add(linkItem())
        let task = h.start()
        try await h.waitForCard()
        switch when {
        case .thenAllow:
            await h.access.setLinks(false)
            await h.access.allow()
        case .duringAuthentication:
            h.onAuthenticate = { await h.access.setLinks(false) }
            await h.access.allow()
        }
        #expect(h.access.config.links == false)
        #expect(await task.value.code == .approvalTimeout)
        #expect(h.marked.isEmpty)
    }

    @Test func codeWithUnsafeLinkIsOfferedWithoutTheLink() async throws {
        let h = Harness()
        let mixed = linkItem("https://evil.com/login?token=\(secretToken)", senderVerified: false, code: secretCode)
        let result = try await h.decide(mixed) { await $0.allow() }
        let released = try #require(result.item)
        #expect(released.id == mixed.id)
        let wire = AgentAccess.wire(released)
        #expect(wire.link == nil)
        #expect(wire.kind == .code)
        #expect(wire.value == secretCode)
    }

    /// With Sign-In Links off, a mail with a code and a safe link must still go out as a code, and the link must not ride along.
    @Test func codeApprovalNeverCarriesItsSignInLink() async throws {
        let h = Harness()
        let mixed = linkItem(code: secretCode)
        let result = try await h.decide(mixed) { await $0.allow() }
        let wire = AgentAccess.wire(try #require(result.item))
        #expect(wire.link == nil)
        #expect(wire.kind == .code)
        #expect(wire.value == secretCode)
    }

    // MARK: Settings

    enum Switch: String, CaseIterable { case enabled, allowAll, links }

    /// Turning on access, Allow All or Sign-In Links without passing authentication would let anyone with the Mac open the gate.
    @Test(arguments: Switch.allCases)
    func turningOnRequiresAuthenticationAndFailureLeavesItOff(_ s: Switch) async {
        let h = Harness(AgentConfig(enabled: s != .enabled))
        let set = { (on: Bool) async in
            switch s {
            case .enabled: await h.access.setEnabled(on)
            case .allowAll: await h.access.setAllowAll(on)
            case .links: await h.access.setLinks(on)
            }
        }
        let value = {
            switch s {
            case .enabled: h.access.config.enabled
            case .allowAll: h.access.config.allowAll
            case .links: h.access.config.links
            }
        }
        h.authFails = true
        await set(true)
        #expect(h.authCalls == 1)
        #expect(value() == false)
        #expect(h.saved.isEmpty)

        h.authFails = false
        await set(true)
        #expect(h.authCalls == 2)
        #expect(value())
        #expect(h.saved.last == h.access.config)

        h.authFails = true
        await set(false)
        #expect(h.authCalls == 2)
        #expect(value() == false)
    }

    @Test func disablingNeedsNoAuthenticationAndCancelsPendingRequest() async throws {
        let h = Harness()
        h.add(item())
        let task = h.start()
        try await h.waitForCard()
        await h.access.setEnabled(false)
        #expect(h.authCalls == 0)
        #expect(h.access.config.enabled == false)
        #expect(await task.value.code != nil)
        #expect(h.marked.isEmpty)
    }

    /// Removing a rule is a revocation; asking for Touch ID first would let a cancelled prompt keep it in place.
    @Test func removingRuleNeedsNoAuthentication() async {
        let rule = AgentRule(app: agentApp, site: "github.com")
        let h = Harness(AgentConfig(enabled: true, rules: [rule]))
        h.authFails = true
        h.access.removeRule(rule.id)
        #expect(h.access.config.rules.isEmpty)
        #expect(h.authCalls == 0)
    }

    /// A grant that couldn't be saved must not take effect; a revocation must, or a Keychain error leaves access open.
    @Test func failedSaveBlocksGrantsButNotRevocations() async {
        let rule = AgentRule(app: agentApp, site: "github.com")
        let h = Harness(AgentConfig(enabled: false, rules: [rule], allowAll: true, links: true))
        let before = h.access.config
        h.saveFails = true
        await h.access.setEnabled(true)
        #expect(h.access.config == before)
        #expect(h.access.error != nil)
        h.access.removeRule(rule.id)
        #expect(h.access.config.rules.isEmpty)
        await h.access.setAllowAll(false)
        #expect(h.access.config.allowAll == false)
        await h.access.setAllowAll(true)
        #expect(h.access.config.allowAll == false)
        await h.access.setLinks(false)
        #expect(h.access.config.links == false)
        await h.access.setLinks(true)
        #expect(h.access.config.links == false)
        #expect(h.access.error != nil)
    }

    /// Config saved by an older version must still load, and must not come back with Allow All or Sign-In Links on,
    /// even when a rule still carries the old per-rule `"links": true`.
    @Test(arguments: [false, true])
    func oldConfigDecodesWithNewSwitchesOff(_ oldRuleLinks: Bool) throws {
        let rule = AgentRule(app: agentApp, site: "github.com")
        var ruleJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        if oldRuleLinks { ruleJSON["links"] = true }
        let json = try JSONSerialization.data(withJSONObject: ["enabled": true, "rules": [ruleJSON]])
        let config = try JSONDecoder().decode(AgentConfig.self, from: json)
        #expect(config.enabled)
        #expect(config.allowAll == false)
        #expect(config.links == false)
        #expect(config.rules.map(\.id) == [rule.id])
        #expect(config.rules.first?.site == "github.com")
    }

    @Test func logAndStoredLogNeverHoldCodesOrLinks() async throws {
        let h = Harness(AgentConfig(enabled: true, rules: [AgentRule(app: agentApp, site: "gitlab.com")], links: true))
        _ = try await h.decide(item()) { await $0.allow() }
        _ = try await h.decide(item(code: "771122")) { $0.deny() }
        h.add(item(code: "", link: URL(string: "https://gitlab.com/users/sign_in?token=\(secretToken)"),
                   service: "GitLab", domain: "gitlab.com"))
        #expect(await h.start("gitlab.com").value.item != nil)
        _ = await h.start("example.com", timeout: 0.2).value
        #expect(h.access.log.count >= 4)

        let secrets = [secretCode, "771122", secretToken, "https://gitlab.com/users"]
        for entry in h.access.log {
            for s in secrets {
                #expect(!entry.caller.contains(s) && !entry.site.contains(s) && !entry.outcome.contains(s))
            }
        }
        let stored = (UserDefaults().persistentDomain(forName: h.suite) ?? [:]).values.map { value -> String in
            if let data = value as? Data { return String(decoding: data, as: UTF8.self) }
            return String(describing: value)
        }.joined(separator: "\n")
        for s in secrets { #expect(!stored.contains(s)) }
    }
}
