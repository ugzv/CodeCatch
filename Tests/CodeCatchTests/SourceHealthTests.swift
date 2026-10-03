import Foundation
import Testing
@testable import CodeCatch

@Test func successfulChecksDoNotInventMessageOrCodeActivity() {
    let newest = Date(timeIntervalSince1970: 200)
    let older = Date(timeIntervalSince1970: 100)
    var health = SourceHealth()
    health.record(.checked(newest))
    #expect(health.lastChecked == newest)
    #expect(health.lastMessage == nil)
    #expect(health.lastCode == nil)
    health.record(.message(newest))
    health.record(.message(older))
    health.record(.checked(older))
    #expect(health.lastMessage == newest)
    #expect(health.lastChecked == newest)
    health.record(.retry(newest))
    #expect(health.retryAt == newest)
    health.record(.retry(nil))
    #expect(health.retryAt == nil)
}

@Test @MainActor func checkingOneSourceRejectsItsOldCallbacksWithoutRestartingOthers() async throws {
    let suite = "SourceHealthTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = MailAccount(label: "A", host: "example.invalid", user: "a@example.invalid")
    let b = MailAccount(label: "B", host: "example.invalid", user: "b@example.invalid")
    let key = a.id.uuidString
    let starts = AsyncStream<String>.makeStream()
    var iterator = starts.stream.makeAsyncIterator()
    var callbacks: [String: [SourceMonitor.Callbacks]] = [:]
    let monitor = SourceMonitor(watchMail: { account, value in
        callbacks[account.id.uuidString, default: []].append(value)
        starts.continuation.yield(account.id.uuidString)
    }, hasCredential: { _ in true }, defaults: defaults)
    var delivered = 0
    monitor.deliver = { _ in delivered += 1 }
    monitor.restartMail([a, b])
    _ = await iterator.next()
    _ = await iterator.next()
    let original = callbacks[key]![0]
    let checked = Date(timeIntervalSince1970: 100)
    original.event(.checked(checked))
    monitor.receivedCode(sourceKey: key, date: checked)
    monitor.receivedCode(sourceKey: key, date: checked.addingTimeInterval(-1))

    monitor.check(key)
    #expect(await iterator.next() == key)
    let message = IncomingMessage(text: "test", senderName: "", senderID: "", sourceKey: key,
                                  sourceLabel: "A", date: checked, isMail: true)
    original.status(.failed("stale"))
    original.event(.checked(checked.addingTimeInterval(100)))
    original.deliver(message)
    #expect(monitor.health[key]?.status == .connecting)
    #expect(monitor.health[key]?.lastChecked == checked)
    #expect(monitor.health[key]?.lastCode == checked)
    #expect(delivered == 0)
    #expect(callbacks[b.id.uuidString]?.count == 1)
    callbacks[b.id.uuidString]![0].status(.live)
    #expect(monitor.health[b.id.uuidString]?.status == .live)

    let current = callbacks[key]![1]
    current.status(.live)
    current.deliver(message)
    #expect(delivered == 1)
    var disabled = a
    disabled.enabled = false
    monitor.restartMail([disabled, b])
    _ = await iterator.next()
    current.status(.live)
    current.deliver(message)
    #expect(monitor.health[key]?.status == .off)
    #expect(delivered == 1)
    monitor.restartMail([b])
    _ = await iterator.next()
    current.event(.checked(Date()))
    #expect(monitor.health[key] == nil)
}

@Test @MainActor func mailRecoversAfterOfflineAndInterfaceChanges() async throws {
    let suite = "SourceHealthTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let account = MailAccount(label: "Test", host: "example.invalid", user: "test@example.invalid")
    let key = account.id.uuidString
    let starts = AsyncStream<SourceMonitor.Callbacks>.makeStream()
    var iterator = starts.stream.makeAsyncIterator()
    var startCount = 0
    let monitor = SourceMonitor(watchMail: { _, callbacks in
        startCount += 1
        starts.continuation.yield(callbacks)
    }, hasCredential: { _ in true }, defaults: defaults)
    monitor.restartMail([account])
    let original = await iterator.next()!
    original.status(.live)
    monitor.networkChanged(online: true, interfaces: ["en0"])
    #expect(startCount == 1)
    monitor.networkChanged(online: false, interfaces: [])
    original.status(.live)
    #expect(monitor.health[key]?.status.needsAttention == true)
    monitor.networkChanged(online: true, interfaces: ["en0"])
    let restored = await iterator.next()!
    restored.status(.live)
    #expect(monitor.health[key]?.status == .live)
    monitor.networkChanged(online: true, interfaces: ["en1"])
    let switched = await iterator.next()!
    restored.status(.live)
    #expect(monitor.health[key]?.status == .connecting)
    switched.status(.live)
    #expect(monitor.health[key]?.status == .live)
    #expect(startCount == 3)
}

@Test @MainActor func editingOneAccountKeepsOtherInboxesConnected() async throws {
    let suite = "SourceHealthTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = MailAccount(label: "A", host: "example.invalid", user: "a@example.invalid")
    let b = MailAccount(label: "B", host: "example.invalid", user: "b@example.invalid")
    let starts = AsyncStream<String>.makeStream()
    var iterator = starts.stream.makeAsyncIterator()
    var callbacks: [String: SourceMonitor.Callbacks] = [:]
    let monitor = SourceMonitor(watchMail: { account, value in
        callbacks[account.id.uuidString] = value
        starts.continuation.yield(account.id.uuidString)
    }, hasCredential: { _ in true }, defaults: defaults)
    let session = VaultSession(authenticate: {}, read: { [] }, write: { _ in }, remove: {})
    let model = AppModel(vaultSession: session, monitor: monitor, defaults: defaults, accounts: [a, b])
    monitor.restartMail(model.accounts)
    _ = await iterator.next()
    _ = await iterator.next()
    let unaffected = try #require(callbacks[b.id.uuidString])
    unaffected.status(.live)

    var edited = a
    edited.label = "Renamed"
    model.save(edited)

    #expect(monitor.health[b.id.uuidString]?.status == .live)
    let checked = Date(timeIntervalSince1970: 123)
    unaffected.event(.checked(checked))
    #expect(monitor.health[b.id.uuidString]?.lastChecked == checked)
    #expect(await iterator.next() == a.id.uuidString)
    // Credential-only saves must reconnect the edited account too.
    let previous = try #require(callbacks[a.id.uuidString])
    previous.status(.live)
    model.save(edited)
    #expect(monitor.health[a.id.uuidString]?.status == .connecting)
    #expect(monitor.health[b.id.uuidString]?.status == .live)
    #expect(await iterator.next() == a.id.uuidString)
    monitor.restartMail([])
}
