import Foundation
import LocalAuthentication
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

@MainActor private final class MonitoringFixture {
    let suite = "MonitoringTests.\(UUID())"
    let defaults: UserDefaults
    let session: VaultSession
    let search: CodeSearch
    private(set) var copied: [String] = []
    private(set) var typed: [String] = []
    private(set) var writes = 0
    private(set) var removals = 0
    var authenticationAllowed = true
    let stored = [VaultCode(id: "saved-login", name: "Example", username: nil, domain: nil,
                            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")]
    var model: AppModel!

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        for key in ["messagesEnabled", "showHUD", "autoCopy", "sound"] {
            defaults.set(false, forKey: key)
        }
        defaults.set(7, forKey: "historyDays")
        Prefs.register(in: defaults)
        search = CodeSearch(defaults: defaults)
        // Storage stays in memory; no test reaches the keychain or system clipboard.
        session = VaultSession(authenticate: {}, read: { [] }, write: { _ in }, remove: {})
        model = makeModel()
    }

    func makeModel(session: VaultSession? = nil) -> AppModel {
        let monitor = SourceMonitor(watchMail: { _, _ in }, hasCredential: { _ in false }, defaults: defaults)
        return AppModel(vaultSession: session ?? self.session, monitor: monitor, search: search,
                        defaults: defaults, copyToClipboard: { [weak self] value, _ in self?.copied.append(value) },
                        typeCode: { [weak self] code in self?.typed.append(code) })
    }

    func storedSession() -> VaultSession {
        VaultSession(authenticate: { [self] in
            if !authenticationAllowed { throw CancellationError() }
        }, read: { [self] in stored }, write: { [self] _ in writes += 1 }, remove: { [self] in removals += 1 })
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private func monitoringMessage() -> IncomingMessage {
    IncomingMessage(text: "Your verification code is 482913. Confirm your sign-in.",
                    subject: "Confirm your sign-in", senderName: "Example", senderID: "support@example.com",
                    sourceKey: "test-mail", sourceLabel: "Test", date: Date().addingTimeInterval(-300), isMail: true,
                    links: [MailLink(url: "https://example.com/verify?token=example", label: "Confirm sign-in")])
}

@MainActor @Suite struct MonitoringTests {
    @Test func registrationEnablesAllFeaturesWithoutOverwritingSavedChoices() throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        for key in [Prefs.receivedCodes, Prefs.signInLinks, Prefs.resetLinks, Prefs.bitwarden] {
            #expect(fixture.defaults.bool(forKey: key))
            fixture.defaults.set(false, forKey: key)
        }
        Prefs.register(in: fixture.defaults)
        for key in [Prefs.receivedCodes, Prefs.signInLinks, Prefs.resetLinks, Prefs.bitwarden] {
            #expect(!fixture.defaults.bool(forKey: key))
        }
    }

    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func ingestionDoesNotLeakDisabledPortionsOfMixedMail(codes: Bool, links: Bool) throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        fixture.model.setMonitoring(Prefs.receivedCodes, enabled: codes)
        fixture.model.setMonitoring(Prefs.signInLinks, enabled: links)
        fixture.model.ingest(monitoringMessage())

        #expect(fixture.model.items.contains { !$0.code.isEmpty } == codes)
        #expect(fixture.model.items.contains { $0.link != nil } == links)
        if !codes && !links { #expect(fixture.model.items.isEmpty) }
    }

    /// Each link kind follows its own setting: turning off sign-in links must not hide resets, and the reverse.
    @Test(arguments: [(true, false), (false, true)])
    func passwordResetLinksFollowTheirOwnSetting(signIn: Bool, reset: Bool) throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        fixture.model.setMonitoring(Prefs.signInLinks, enabled: signIn)
        fixture.model.setMonitoring(Prefs.resetLinks, enabled: reset)
        let mail = { (subject: String, label: String) in
            IncomingMessage(text: label, subject: subject, senderName: "Example", senderID: "support@example.com",
                            sourceKey: "test-mail", sourceLabel: "Test", date: Date().addingTimeInterval(-300), isMail: true,
                            links: [MailLink(url: "https://example.com/\(label.count)?token=t", label: label)])
        }
        fixture.model.ingest(mail("Reset your password", "Reset password"))
        fixture.model.ingest(mail("Confirm your sign-in", "Confirm sign-in"))

        #expect(fixture.model.items.contains { $0.resetsPassword } == reset)
        #expect(fixture.model.items.contains { !$0.resetsPassword } == signIn)

        fixture.model.setMonitoring(Prefs.signInLinks, enabled: false)
        fixture.model.setMonitoring(Prefs.resetLinks, enabled: false)
        #expect(fixture.model.items.isEmpty)
    }

    @Test(arguments: [true, false])
    func disablingOnePortionKeepsTheOtherAndReingestionRestoresReenabledContent(disableCodes: Bool) throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        let message = monitoringMessage()
        fixture.model.ingest(message)
        #expect(fixture.model.items.contains { !$0.code.isEmpty })
        #expect(fixture.model.items.contains { $0.link != nil })
        let disabledKey = disableCodes ? Prefs.receivedCodes : Prefs.signInLinks
        fixture.model.setMonitoring(disabledKey, enabled: false)

        #expect(fixture.model.items.contains { !$0.code.isEmpty } == !disableCodes)
        #expect(fixture.model.items.contains { $0.link != nil } == disableCodes)

        fixture.model.setMonitoring(disabledKey, enabled: true)
        fixture.model.ingest(message)
        #expect(fixture.model.items.contains { !$0.code.isEmpty })
        #expect(fixture.model.items.contains { $0.link != nil })

        fixture.model.setMonitoring(Prefs.receivedCodes, enabled: false)
        fixture.model.setMonitoring(Prefs.signInLinks, enabled: false)
        #expect(fixture.model.items.isEmpty)
        fixture.model.ingest(message)
        #expect(fixture.model.items.isEmpty)
    }

    @Test(arguments: [true, false])
    func disablingReceivedContentBlocksPreviouslyVisibleRowsEvenAfterUnlock(code: Bool) async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        let message = IncomingMessage(
            text: code ? "Your verification code is 482913." : "Confirm your sign-in.",
            subject: "Confirm your sign-in", senderName: "Example", senderID: "support@example.com",
            sourceKey: "test-mail", sourceLabel: "Test", date: Date().addingTimeInterval(-300), isMail: true,
            links: code ? [] : [MailLink(url: "https://example.com/verify?token=example", label: "Confirm sign-in")])
        fixture.model.ingest(message)
        let retained = try #require(fixture.model.items.first)
        try await fixture.session.unlock()
        fixture.model.copy(retained)
        #expect(fixture.copied == [retained.copyValue])

        fixture.model.setMonitoring(code ? Prefs.receivedCodes : Prefs.signInLinks, enabled: false)
        #expect(fixture.model.items.isEmpty)
        fixture.model.copy(retained)
        #expect(fixture.copied.count == 1)
        fixture.session.lock()
        try await fixture.session.unlock()
        fixture.model.copy(retained)
        #expect(fixture.copied.count == 1)
    }

    /// Prevents a code being typed into the front app when not opted in, locked, unmonitored, stale, or already typed.
    @Test(arguments: [
        (autoType: true, unlocked: true, monitored: true, hasCode: true, age: 0.0, types: true),
        (autoType: false, unlocked: true, monitored: true, hasCode: true, age: 0.0, types: false),
        (autoType: true, unlocked: false, monitored: true, hasCode: true, age: 0.0, types: false),
        (autoType: true, unlocked: true, monitored: false, hasCode: true, age: 0.0, types: false),
        (autoType: true, unlocked: true, monitored: true, hasCode: false, age: 0.0, types: false),
        (autoType: true, unlocked: true, monitored: true, hasCode: true, age: 300.0, types: false),
    ])
    func codeIsTypedOnceOnlyWhenOptedInUnlockedMonitoredAndJustArrived(
        scenario: (autoType: Bool, unlocked: Bool, monitored: Bool, hasCode: Bool, age: TimeInterval, types: Bool)
    ) async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        #expect(!fixture.defaults.bool(forKey: Prefs.autoType))
        fixture.defaults.set(scenario.autoType, forKey: Prefs.autoType)
        fixture.model.setMonitoring(Prefs.receivedCodes, enabled: scenario.monitored)
        if scenario.unlocked { try await fixture.session.unlock() }
        let message = IncomingMessage(
            text: scenario.hasCode ? "Your verification code is 482913." : "Confirm your sign-in.",
            subject: "Confirm your sign-in", senderName: "Example", senderID: "support@example.com",
            sourceKey: "test-mail", sourceLabel: "Test", date: Date().addingTimeInterval(-scenario.age), isMail: true,
            links: scenario.hasCode ? [] : [MailLink(url: "https://example.com/verify?token=example", label: "Confirm sign-in")])

        fixture.model.ingest(message)
        fixture.model.ingest(message)
        #expect(fixture.model.items.contains { $0.code == "482913" } == (scenario.hasCode && scenario.monitored))
        // Unlocking afterwards must not type a code that arrived while locked.
        try await fixture.model.unlock()
        #expect(fixture.typed == (scenario.types ? ["482913"] : []))
    }

    @Test func mixedRowCopyLinkRequiresAuthenticationAndRejectsDisabledRetainedLinks() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        fixture.model.ingest(monitoringMessage())
        let retained = try #require(fixture.model.items.first { !$0.code.isEmpty && $0.link != nil })
        let link = try #require(retained.link)

        fixture.model.copyLink(retained)
        #expect(fixture.copied.isEmpty)
        try await fixture.session.unlock()
        fixture.model.copyLink(retained)
        #expect(fixture.copied == [link.absoluteString])

        fixture.model.setMonitoring(Prefs.signInLinks, enabled: false)
        fixture.model.copyLink(retained)
        #expect(fixture.copied.count == 1)
        fixture.session.lock()
        try await fixture.session.unlock()
        fixture.model.copyLink(retained)
        #expect(fixture.copied.count == 1)
    }

    @Test func newModelsHonorSavedMonitoringChoices() throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        for key in [Prefs.receivedCodes, Prefs.signInLinks, Prefs.resetLinks, Prefs.bitwarden] {
            fixture.model.setMonitoring(key, enabled: false)
            #expect(!fixture.defaults.bool(forKey: key))
        }
        let restored = fixture.makeModel()
        restored.ingest(monitoringMessage())
        #expect(restored.items.isEmpty)
        #expect(restored.vaultItems.isEmpty)
        restored.setMonitoring(Prefs.signInLinks, enabled: true)
        let next = fixture.makeModel()
        next.ingest(monitoringMessage())
        #expect(next.items.contains { $0.link != nil })
        #expect(next.items.allSatisfy { $0.code.isEmpty })
    }

    @Test func disablingBitwardenLocksWithoutDeletingAndBlocksRetainedRowsAfterUnlock() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        let session = fixture.storedSession()
        let model = fixture.makeModel(session: session)
        try await session.unlock()
        let retained = try #require(model.vaultItems.first)
        model.setMonitoring(Prefs.bitwarden, enabled: false)

        #expect(!session.isUnlocked)
        #expect(model.vaultItems.isEmpty)
        #expect(fixture.writes == 0)
        #expect(fixture.removals == 0)
        model.copy(retained)
        try await session.unlock()
        #expect(session.codes.map(\.id) == fixture.stored.map(\.id))
        #expect(model.vaultItems.isEmpty)
        model.copy(retained)
        #expect(fixture.copied.isEmpty)
        #expect(fixture.search.recents.isEmpty)

        model.setMonitoring(Prefs.bitwarden, enabled: true)
        try await session.unlock()
        #expect(model.vaultItems.map(\.sourceKey) == fixture.stored.map(\.id))
        model.copy(retained)
        #expect(fixture.copied.count == 1)
    }

    @Test func disablingBitwardenDoesNotBypassAuthenticationForReceivedCodes() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        let session = fixture.storedSession()
        let model = fixture.makeModel(session: session)
        model.setMonitoring(Prefs.bitwarden, enabled: false)
        let item = CodeItem(monitoringMessage(), code: "482913", link: nil)
        fixture.authenticationAllowed = false
        model.copy(item)
        await model.unlocked { model.copy(item) }?.value
        #expect(!model.isUnlocked)
        #expect(fixture.copied.isEmpty)

        fixture.authenticationAllowed = true
        await model.unlocked { model.copy(item) }?.value
        #expect(fixture.copied == ["482913"])
        session.lock()
        model.copy(item)
        #expect(fixture.copied == ["482913"])
    }

    /// A failed unlock from a click on a code used to do nothing at all; closing the prompt stays quiet.
    @Test(arguments: [(LAError(.authenticationFailed) as any Error, true), (LAError(.userCancel), false), (CancellationError(), false)])
    func unlockFailuresAreShownButCancelsAreNot(error: any Error, shown: Bool) async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(session: VaultSession(authenticate: { throw error }, read: { [] }, write: { _ in }, remove: {}))
        var ran = false
        await model.unlocked { ran = true }?.value
        #expect(!ran)
        #expect((model.unlockError != nil) == shown)
    }

    @Test func disabledMailRejectsOldCallbacksAndCannotRestartUntilOneFeatureIsEnabled() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.cleanUp() }
        let account = MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid")
        let key = account.id.uuidString
        let starts = AsyncStream<SourceMonitor.Callbacks>.makeStream()
        let stops = AsyncStream<Void>.makeStream()
        var started = starts.stream.makeAsyncIterator()
        var stopped = stops.stream.makeAsyncIterator()
        var startCount = 0
        var delivered = 0
        let monitor = SourceMonitor(watchMail: { _, callback in
            startCount += 1
            starts.continuation.yield(callback)
            defer { stops.continuation.yield(()) }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }, hasCredential: { _ in true }, defaults: fixture.defaults)
        monitor.deliver = { _ in delivered += 1 }
        monitor.restartMail([account])
        let original = try #require(await started.next())
        original.status(.live)
        original.deliver(monitoringMessage())
        #expect(delivered == 1)

        fixture.defaults.set(false, forKey: Prefs.receivedCodes)
        fixture.defaults.set(false, forKey: Prefs.signInLinks)
        fixture.defaults.set(false, forKey: Prefs.resetLinks)
        monitor.restartMail([account])
        _ = await stopped.next()
        original.status(.live)
        original.event(.checked(Date()))
        original.deliver(monitoringMessage())
        #expect(delivered == 1)
        #expect(monitor.health[key]?.status == .off)
        #expect(monitor.health[key]?.lastChecked == nil)

        monitor.check(key)
        monitor.networkChanged(online: false, interfaces: [])
        monitor.networkChanged(online: true, interfaces: ["en0"])
        monitor.networkChanged(online: true, interfaces: ["en1"])
        await Task.yield()
        #expect(startCount == 1)
        #expect(monitor.health[key]?.status == .off)

        fixture.defaults.set(true, forKey: Prefs.signInLinks)
        monitor.restartMail([account])
        let current = try #require(await started.next())
        #expect(startCount == 2)
        current.status(.live)
        current.deliver(monitoringMessage())
        #expect(monitor.health[key]?.status == .live)
        #expect(delivered == 2)
        monitor.restartMail([])
        _ = await stopped.next()
    }

    /// Prevents a code being typed scrambled with another, after permission was withdrawn, or into a held shortcut.
    @Test func keyTyperPressesWholeTextsInOrderAndOnlyWhileStillAllowed() async {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var text = ""
            func press(_ character: Character) { lock.withLock { text.append(character) } }
            var pressed: String { lock.withLock { text } }
        }
        let recorder = Recorder()
        var revoked = true, granted = false
        let type = { (text: String, allowed: @escaping @MainActor () -> Bool, held: Bool) in
            KeyTyper.type(text, allowed: allowed, modifiersHeld: { held }, press: recorder.press)
        }
        type("123", { true }, false)
        type("456", { true }, false)
        type("777", { revoked }, false)
        type("89", { granted }, false)
        // Flipped before the main actor is released, so only a call-time evaluation sees the old values.
        revoked = false
        granted = true
        type("000", { true }, true)
        await withCheckedContinuation { done in KeyTyper.queue.async { done.resume() } }
        #expect(recorder.pressed == "12345689")
    }
}
