import AppKit
import CodeCatchCore
import Combine
import LocalAuthentication

@MainActor
final class AppModel: ObservableObject {
    #if DEBUG
    /// `--snapshot` swaps in a model with sample sources that needs no Touch ID.
    static var shared = AppModel()
    #else
    static let shared = AppModel()
    #endif
    /// Lifetime when the message doesn't state one; also the duplicate window.
    nonisolated static let defaultValidity: TimeInterval = 600
    /// Sign-in links usually live longer than codes.
    nonisolated static let linkValidity: TimeInterval = 1800
    nonisolated static let testSourceKey = "test"
    /// How far back codes are listed; re-read from the sources on launch, never stored.
    var history: TimeInterval { Prefs.history(in: defaults) }

    @Published private(set) var items: [CodeItem] = []
    @Published private(set) var now = Date()
    /// Why the last unlock failed; cleared when the next one starts.
    @Published private(set) var unlockError: String?
    /// Senders whose messages are never read for codes ("Ignore All from…").
    @Published private(set) var ignoredSenders: [String]
    let vaultSession: VaultSession
    let monitor: SourceMonitor
    let search: CodeSearch
    let recovery = RecoveryInbox()
    private var observations = Set<AnyCancellable>()
    private let defaults: UserDefaults
    private let copyToClipboard: (String, UUID) -> Void
    private let typeCode: (String) -> Void
    private let confirmOwner: @MainActor () async throws -> Void

    var vault: [VaultCode] { monitoring(Prefs.bitwarden) ? vaultSession.codes : [] }
    var isUnlocked: Bool { vaultSession.isUnlocked }
    var hasVault: Bool { defaults.object(forKey: Prefs.vaultImportedAt) != nil || !vault.isEmpty }
    var status: [String: SourceStatus] { monitor.health.mapValues(\.status) }
    /// A search to show in the popover, from a shortcut or a codecatch:// link; the popover takes it.
    @Published var searchRequest: String?
    @Published var accounts: [MailAccount] {
        didSet {
            MailAccount.save(accounts, in: defaults)
            retainRecoverySources()
            monitor.restartMail(accounts, onlyChanged: true)
        }
    }

    init(vaultSession: VaultSession? = nil, monitor: SourceMonitor? = nil, search: CodeSearch? = nil, defaults: UserDefaults = .standard,
         accounts: [MailAccount]? = nil,
         copyToClipboard: @escaping (String, UUID) -> Void = { Clipboard.copy($0, id: $1) },
         typeCode: (@MainActor (String) -> Void)? = nil,
         confirmOwner: (@MainActor () async throws -> Void)? = nil) {
        self.defaults = defaults
        self.accounts = accounts ?? MailAccount.load(from: defaults)
        Prefs.register(in: defaults)
        ignoredSenders = defaults.stringArray(forKey: Prefs.ignoredSenders) ?? []
        self.vaultSession = vaultSession ?? VaultStorage.session(defaults: defaults)
        self.monitor = monitor ?? SourceMonitor(defaults: defaults)
        self.search = search ?? CodeSearch(defaults: defaults)
        self.copyToClipboard = copyToClipboard
        self.confirmOwner = confirmOwner ?? { try await DeviceAuthentication().authenticate(reason: "show codes without asking each time") }
        let session = self.vaultSession
        self.typeCode = typeCode ?? { code in
            // Re-check the same session and settings when queued typing begins.
            KeyTyper.type(code) { KeyTyper.canType && session.isUnlocked && defaults.bool(forKey: Prefs.autoType) }
        }
        self.vaultSession.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        self.monitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        self.search.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        recovery.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        recovery.onRemove = { Clipboard.clearIfOurs(ids: $0) }
        self.monitor.deliver = { [weak self] in self?.ingest($0) }
    }

    var latest: CodeItem? { items.first(where: isFresh) }
    /// What the menu bar shows: codes only, never a link.
    var latestCode: CodeItem? { items.first { isFresh($0) && !$0.isLink } }
    /// Still valid: shown in the menu bar.
    func isFresh(_ item: CodeItem) -> Bool { now < item.expires }

    /// Sources in display order, each with its current status.
    var sources: [(key: String, label: String, status: SourceStatus)] {
        [(MessagesStore.sourceKey, "Messages", status[MessagesStore.sourceKey] ?? .off)]
            + (monitoring(Prefs.appleMail) ? [(AppleMailStore.sourceKey, "Apple Mail", status[AppleMailStore.sourceKey] ?? .off)] : [])
            + accounts.map { ($0.id.uuidString, $0.label, status[$0.id.uuidString] ?? .off) }
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.restartMessages()
                self?.restartMail()
                self?.unlockWithMac()
            }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.vaultSession.lock() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.vaultSession.lock()
                guard self.monitoring(Prefs.clearOnLock) else { return }
                self.clearHistory()
                Clipboard.clearIfOurs()
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.unlockWithMac() }
        }
        unlockWithMac()
        LoginItem.sync()
        Hotkeys.sync()
        monitor.start(accounts: accounts)
        // `open CodeCatch.app --args -demoCode YES`: a test code on launch, for trying the banner and chip.
        if monitoring("demoCode") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showTestCode() } }
    }

    private func tick() {
        now = Date()
        // Every window, including menus and tooltips, follows a change within a second; the banner,
        // the popover and Recent Emails are also covered from their first frame.
        let sharing: NSWindow.SharingType = monitoring(Prefs.hideFromCapture) ? .none : .readOnly
        for window in NSApp.windows where window.sharingType != sharing { window.sharingType = sharing }
        items.removeAll { now.timeIntervalSince($0.received) > history }
        recovery.prune(at: now)
    }

    // MARK: - Sources

    func monitoring(_ key: String) -> Bool { defaults.bool(forKey: key) }
    var receiving: Bool { [Prefs.receivedCodes, Prefs.signInLinks, Prefs.resetLinks].contains(where: monitoring) }

    func setMonitoring(_ key: String, enabled: Bool) {
        guard monitoring(key) != enabled else { return }
        objectWillChange.send()
        defaults.set(enabled, forKey: key)
        if key == Prefs.receivedCodes, !enabled { recovery.removeAll() }
        if key == Prefs.bitwarden {
            // Invalidate pending authentication and unload saved secrets, without deleting them.
            vaultSession.lock()
            return
        }
        let previous = items
        items = items.compactMap(filtered)
        let changed = Set(previous.filter { old in !items.contains(old) }.map(\.id))
        Clipboard.clearIfOurs(ids: changed)
        restartMessages()
        restartMail()
    }

    private func filtered(_ item: CodeItem) -> CodeItem? {
        var item = item
        if !monitoring(Prefs.receivedCodes) { item.code = "" }
        if !monitoring(item.linkSetting) { item.link = nil }
        return item.code.isEmpty && item.link == nil ? nil : item
    }

    func restartMessages() { monitor.restartMessages() }

    /// Every mail source: the Mail app's store and the IMAP accounts.
    func restartMail() {
        restartAppleMail()
        monitor.restartMail(accounts)
    }

    /// The Apple Mail switch: IMAP connections stay as they are.
    func restartAppleMail() {
        retainRecoverySources()
        monitor.restartAppleMail()
    }

    /// The mail sources that are on: all that Recent Emails can show, since it reads only mail.
    var mailSourceKeys: [String] {
        accounts.filter(\.enabled).map { $0.id.uuidString } + (monitoring(Prefs.appleMail) ? [AppleMailStore.sourceKey] : [])
    }

    private func retainRecoverySources() { recovery.retainSources(Set(mailSourceKeys)) }

    /// Adds the account, or replaces the saved one with the same id.
    func save(_ account: MailAccount) {
        let unchanged = accounts.contains(account)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        // A password or refresh token can change without changing account metadata.
        if unchanged { monitor.check(account.id.uuidString) }
    }

    enum AccountSaveError: LocalizedError {
        case duplicate
        var errorDescription: String? { "This mail account is already saved. Edit the existing account instead." }
    }

    /// Persist credentials before publishing metadata; never mutate another account's keys.
    func saveAccount(_ account: MailAccount, password: String, refreshToken: String?,
                     setSecret: (String, String) throws -> Void = { try Secrets.set($0, for: $1) },
                     removeSecret: (String) throws -> Void = Secrets.remove) throws {
        guard !accounts.contains(where: { $0.id != account.id && $0.secretKey == account.secretKey }) else {
            throw AccountSaveError.duplicate
        }
        var account = account
        if let refreshToken {
            try setSecret(refreshToken, account.refreshTokenKey)
            account.googleSignIn = true
        } else if !account.usesGoogle {
            if !password.isEmpty { try setSecret(password, account.secretKey) }
            try forgetGoogleSignIn(account, removeSecret)
        }
        save(account)
    }

    func remove(_ account: MailAccount, removeSecret: (String) throws -> Void = Secrets.remove) throws {
        guard let saved = accounts.first(where: { $0.id == account.id }) else { return }
        if !accounts.contains(where: { $0.id != saved.id && $0.secretKey == saved.secretKey }) {
            try removeSecret(saved.secretKey)
            try forgetGoogleSignIn(saved, removeSecret)
        }
        accounts.removeAll { $0.id == saved.id }
    }

    /// After an identity edit, remove old credentials only when no saved account uses them.
    func removeUnusedCredentials(for account: MailAccount, removeSecret: (String) throws -> Void = Secrets.remove) throws {
        guard !accounts.contains(where: { $0.secretKey == account.secretKey }) else { return }
        try removeSecret(account.secretKey)
        try forgetGoogleSignIn(account, removeSecret)
    }

    /// A Google sign-in CodeCatch forgets also ends on Google's side, once it is gone from the Keychain.
    private func forgetGoogleSignIn(_ account: MailAccount, _ removeSecret: (String) throws -> Void) throws {
        let token = Secrets.get(account.refreshTokenKey)
        try removeSecret(account.refreshTokenKey)
        if let token { Task { await GoogleOAuth.revoke(token) } }
    }

    // MARK: - Codes

    func ingest(_ message: IncomingMessage) {
        let age = Date().timeIntervalSince(message.date)
        guard age < history, message.date > clearedAt,
              !ignoredSenders.contains(message.senderID.lowercased()) else { return }
        let code = monitoring(Prefs.receivedCodes) ? CodeExtractor.code(in: message.fullText) : nil
        let detectedLink = message.isMail ? SignInLink.find(in: message.links, subject: message.subject ?? "") : nil
        let resets = detectedLink?.kind == .passwordReset
        let link = monitoring(resets ? Prefs.resetLinks : Prefs.signInLinks) ? detectedLink?.url : nil
        let item = CodeItem(message, code: code, link: link, resetsPassword: resets)
        guard !dismissed.contains(item.dismissKey) else { return }
        if code != nil || detectedLink != nil { recovery.remove(messageKey: message.dismissKey) }
        guard code != nil || link != nil else {
            if monitoring(Prefs.receivedCodes), detectedLink == nil { recovery.record(message) }
            return
        }
        monitor.receivedCode(sourceKey: message.sourceKey, date: message.date)
        if let index = items.firstIndex(where: { $0.dismissKey == item.dismissKey }) {
            var updated = item
            updated.id = items[index].id
            updated.used = items[index].used
            items[index] = updated
            return
        }
        guard !items.contains(where: { seen in
                  abs(seen.received.timeIntervalSince(message.date)) < Self.defaultValidity
                      && (item.isLink ? seen.link == item.link : seen.code == item.code)
              })
        else { return }
        items.append(item)
        items.sort { $0.received > $1.received }

        guard item.shouldAnnounce(at: Date()) else { return }  // backfill: list it, don't announce it
        if let code, isUnlocked {
            if defaults.bool(forKey: Prefs.autoCopy) { copyToClipboard(code, item.id) }
            // Opt-in: the code goes to whatever field has focus, so only as it arrives, never later.
            if defaults.bool(forKey: Prefs.autoType) { typeCode(code) }
        }
        if monitoring(Prefs.showBanner) {
            unlockError = nil  // a failure from an earlier code isn't about this one
            Banner.shared.show(item.id)
        }
        if monitoring(Prefs.sound) { NSSound(named: "Tink")?.play() }
    }

    /// The Unlock button. A code that arrived while locked is what the unlock was for: copy it.
    func unlock() async throws {
        try await authenticate()
        if monitoring(Prefs.autoCopy), let item = latestCode, !item.used, item.shouldAnnounce(at: Date()) { copy(item) }
    }

    /// A click on a hidden code: authenticate once, then do what was asked.
    @discardableResult
    func unlocked(_ action: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        if isUnlocked { action(); return nil }
        return Task { if (try? await authenticate()) != nil { action() } }
    }

    /// "Unlock with Your Mac": unlocks without a prompt at launch, on wake and when the screen unlocks.
    func unlockWithMac() {
        guard monitoring(Prefs.unlockWithMac), !isUnlocked, !Self.screenIsLocked else { return }
        Task { try? await authenticate() }
    }

    /// Turning the prompt off asks for it one last time, even while unlocked, so no one at an
    /// unlocked Mac can switch it off for later. Turning it back on locks now.
    func setUnlockWithMac(_ enabled: Bool) async {
        guard enabled else {
            objectWillChange.send()
            defaults.set(false, forKey: Prefs.unlockWithMac)
            vaultSession.lock()
            return
        }
        unlockError = nil
        do { try await confirmOwner() } catch {
            if !Self.isCancel(error) { unlockError = error.localizedDescription }
            return
        }
        objectWillChange.send()
        defaults.set(true, forKey: Prefs.unlockWithMac)
        try? await authenticate()
    }

    /// On wake the lock screen may still be up; codes wait for it.
    private static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Every unlock goes through here, so a failure is shown wherever the click came from.
    func authenticate() async throws {
        unlockError = nil
        do {
            try await vaultSession.unlock()
        } catch {
            if !Self.isCancel(error) { unlockError = error.localizedDescription }
            throw error
        }
    }

    /// Closing the password prompt, or a lock while it was open, is not a failure to report.
    static func isCancel(_ error: Error) -> Bool {
        if error is CancellationError || error as? VaultSession.Failure == .busy { return true }
        guard let code = (error as? LAError)?.code else { return false }
        return [.userCancel, .appCancel, .systemCancel].contains(code)
    }

    func copy(_ item: CodeItem, at date: Date = Date()) {
        let feature = item.origin == .vault ? Prefs.bitwarden : item.isLink ? item.linkSetting : Prefs.receivedCodes
        guard isUnlocked, monitoring(feature) else { return }
        var current = item
        if item.origin == .vault {
            guard let saved = vault.first(where: { $0.id == item.sourceKey }), let fresh = CodeItem(saved, at: date) else { return }
            current = fresh
            search.recordUse(current)
        }
        objectWillChange.send()  // the clipboard is not observed: redraw the "Copied" marks now, not on the next tick
        copyToClipboard(current.copyValue, current.id)
        markUsed(current)
    }

    func copyLink(_ item: CodeItem) {
        guard isUnlocked, monitoring(item.linkSetting), let link = item.link else { return }
        copyToClipboard(link.absoluteString, item.id)
    }

    /// Manual selection only; re-check retained state after an unlock or source change.
    @discardableResult
    func copyRecoveryText(_ text: String, from id: UUID, at date: Date = Date()) -> Bool {
        recovery.prune(at: date)
        guard isUnlocked, monitoring(Prefs.receivedCodes), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let entry = recovery.entries.first(where: { $0.id == id }), entry.message.fullText.contains(text) else { return false }
        copyToClipboard(text, id)
        return true
    }

    /// The shortcut: the newest live code onto the clipboard, shown briefly in the banner.
    func copyLatest() {
        guard let item = latestCode else { return NSSound.beep() }
        unlocked { [self] in
            copy(item)
            guard monitoring(Prefs.showBanner) else { return }
            Banner.shared.show(item.id)
            Banner.shared.hide(after: 1.5)
        }
    }

    /// Only ever on the user's click: links are never opened automatically.
    func open(_ item: CodeItem, leavingMenu: Bool = false) {
        guard isUnlocked, monitoring(item.linkSetting), let link = item.link else { return }
        if leavingMenu { NSApp.hide(nil) }
        NSWorkspace.shared.open(link)
        markUsed(item)
    }

    /// Lets the user try the card and copy without waiting for a real code.
    func showTestCode() {
        ingest(IncomingMessage(text: "Your CodeCatch code is \(Int.random(in: 100_000...999_999)).", senderName: "", senderID: "",
                               sourceKey: Self.testSourceKey, sourceLabel: "Test", date: Date(), isMail: false))
    }

    /// Opens the Messages thread or the user's default mail app.
    func openSource(_ item: CodeItem) {
        switch item.origin {
        case .messages:
            if let url = URL(string: "sms:\(item.sender.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")") {
                NSWorkspace.shared.open(url)
            }
        case .mail:
            if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        case .test, .vault: break
        }
    }

    /// "Clear" / "Not a Code": gone for good, even when the source is re-read later.
    func dismiss(_ item: CodeItem) {
        defaults.set(Array((dismissed + [item.dismissKey]).suffix(500)), forKey: Prefs.dismissed)
        remove { $0.id == item.id }
    }

    /// A removed code leaves the clipboard along with its row.
    private func remove(where gone: (CodeItem) -> Bool) {
        Clipboard.clearIfOurs(ids: Set(items.filter(gone).map(\.id)))
        items.removeAll(where: gone)
    }

    func ignoreSender(of item: CodeItem) {
        let sender = item.sender.lowercased()
        guard !sender.isEmpty, !ignoredSenders.contains(sender) else { return }
        ignoredSenders.append(sender)
        defaults.set(ignoredSenders, forKey: Prefs.ignoredSenders)
        remove { $0.sender.lowercased() == sender }
        recovery.remove(sender: sender)
    }

    func stopIgnoring(_ sender: String) {
        ignoredSenders.removeAll { $0 == sender }
        defaults.set(ignoredSenders, forKey: Prefs.ignoredSenders)
        restartMessages()  // re-read the sources so that sender's codes come back
        restartMail()
    }

    private var dismissed: [String] { defaults.stringArray(forKey: Prefs.dismissed) ?? [] }

    // MARK: - Bitwarden

    func saveVault(_ codes: [VaultCode]) throws {
        let previousIDs = Set(vault.compactMap { CodeItem($0, at: now)?.id })
        try vaultSession.replace(codes)
        Clipboard.clearIfOurs(ids: previousIDs)
    }

    func removeVault() async throws {
        try await authenticate()
        try vaultSession.remove()
    }

    /// The launcher handles matching across all sources in one place.
    var vaultItems: [CodeItem] { vault.compactMap { CodeItem($0, at: now) } }

    var hasHistory: Bool { !items.isEmpty || !recovery.entries.isEmpty }

    func clearHistory() {
        remove { _ in true }
        recovery.removeAll()
        defaults.set(Date().timeIntervalSince1970, forKey: Prefs.clearedAt)
    }

    /// Remembered across restarts: codes up to then are not re-read from the sources.
    private var clearedAt: Date { Date(timeIntervalSince1970: defaults.double(forKey: Prefs.clearedAt)) }

    private func markUsed(_ item: CodeItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }), !items[i].used else { return }
        items[i].used = true
    }
}
