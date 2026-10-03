import Combine
import Foundation
import Network

@MainActor
final class SourceMonitor: ObservableObject {
    struct Callbacks {
        let status: @MainActor (SourceStatus) -> Void
        let deliver: @MainActor (IncomingMessage) -> Void
        let event: @MainActor (SourceEvent) -> Void
    }

    @Published private(set) var health: [String: SourceHealth] = [:]
    var deliver: (IncomingMessage) -> Void = { _ in }

    private let defaults: UserDefaults
    private var receiving: Bool { defaults.bool(forKey: Prefs.receivedCodes) || defaults.bool(forKey: Prefs.signInLinks) }
    private var accounts: [MailAccount] = []
    private var local: [String: LocalWatcher] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var pathMonitor: NWPathMonitor?
    private var network: (online: Bool, interfaces: [String])?
    private let watchMail: (MailAccount, Callbacks) async -> Void
    private let hasCredential: (MailAccount) -> Bool

    init(watchMail: ((MailAccount, Callbacks) async -> Void)? = nil, hasCredential: @escaping (MailAccount) -> Bool = { $0.hasCredential }, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Prefs.register(in: defaults)
        self.watchMail = watchMail ?? { account, callbacks in
            await MailWatcher.watch(account, status: callbacks.status, deliver: callbacks.deliver,
                                    event: callbacks.event, lookback: Prefs.history(in: defaults))
        }
        self.hasCredential = hasCredential
    }

    deinit {
        pathMonitor?.cancel()
        local.values.forEach { $0.stop() }
        tasks.values.forEach { $0.cancel() }
    }

    func start(accounts: [MailAccount]) {
        restartMessages()
        restartAppleMail()
        restartMail(accounts)
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).sorted()
            Task { @MainActor in self?.networkChanged(online: online, interfaces: interfaces) }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "codecatch.network"))
    }

    func restartMessages() {
        restart(MessagesStore.sourceKey, enabled: defaults.bool(forKey: Prefs.receivedCodes) && defaults.bool(forKey: Prefs.messages)) { MessagesStore() }
    }

    func restartAppleMail() {
        restart(AppleMailStore.sourceKey, enabled: receiving && defaults.bool(forKey: Prefs.appleMail)) { AppleMailStore() }
    }

    private func restart(_ key: String, enabled: Bool, store: () -> LocalStore) {
        local.removeValue(forKey: key)?.stop()
        let callbacks = begin(key)
        guard enabled else { return }
        health[key]?.status = .connecting
        let watcher = LocalWatcher(store())
        watcher.start(lookback: Prefs.history(in: defaults), status: callbacks.status, deliver: callbacks.deliver, event: callbacks.event)
        local[key] = watcher
    }

    func restartMail(_ accounts: [MailAccount], onlyChanged: Bool = false) {
        let previous = Set(self.accounts)
        self.accounts = accounts
        let keys = Set(accounts.map { $0.id.uuidString })
        for key in Array(health.keys) where ![MessagesStore.sourceKey, AppleMailStore.sourceKey].contains(key) && !keys.contains(key) {
            tasks.removeValue(forKey: key)?.cancel()
            generations.removeValue(forKey: key)
            health.removeValue(forKey: key)
        }
        for account in accounts where !onlyChanged || !previous.contains(account) { restart(account) }
    }

    func check(_ key: String) {
        if key == MessagesStore.sourceKey { restartMessages() }
        else if key == AppleMailStore.sourceKey { restartAppleMail() }
        else if let account = accounts.first(where: { $0.id.uuidString == key }) { restart(account) }
    }

    func receivedCode(sourceKey: String, date: Date) {
        guard var source = health[sourceKey] else { return }
        source.lastCode = max(source.lastCode ?? date, date)
        health[sourceKey] = source
    }

    /// Network transitions invalidate only mail workers; Messages and Apple Mail are local.
    func networkChanged(online: Bool, interfaces: [String]) {
        let previous = network
        network = (online, interfaces)
        guard let previous else {
            if !online { restartMail(accounts) }
            return
        }
        if previous.online != online || previous.interfaces != interfaces { restartMail(accounts) }
    }

    private func restart(_ account: MailAccount) {
        let key = account.id.uuidString
        tasks.removeValue(forKey: key)?.cancel()
        let callbacks = begin(key)
        guard receiving, account.enabled else { return }
        guard hasCredential(account) else {
            health[key]?.status = .attention("Needs sign-in")
            return
        }
        guard network?.online != false else {
            health[key]?.status = .attention("Waiting for network")
            return
        }
        health[key]?.status = .connecting
        let watch = watchMail
        tasks[key] = Task { await watch(account, callbacks) }
    }

    private func begin(_ key: String) -> Callbacks {
        let generation = UUID()
        generations[key] = generation
        var source = health[key] ?? SourceHealth()
        source.status = .off
        source.retryAt = nil
        health[key] = source
        return Callbacks(status: { [weak self] status in
            guard let self, self.generations[key] == generation else { return }
            self.health[key]?.status = status
        }, deliver: { [weak self] message in
            guard let self, self.generations[key] == generation else { return }
            self.deliver(message)
        }, event: { [weak self] event in
            guard let self, self.generations[key] == generation else { return }
            self.health[key]?.record(event)
        })
    }
}
