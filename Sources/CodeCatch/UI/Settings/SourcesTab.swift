import AppKit
import SwiftUI

struct SourcesTab: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(Prefs.messages) private var messagesEnabled = true
    @AppStorage(Prefs.appleMail) private var appleMailEnabled = false
    @Local private var editing: MailAccount?
    @Local private var adding = false
    #if DEBUG
    @Local private var importResult: String?
    #endif
    @Local private var bitwarden = false
    @Local private var vaultError: String?

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "number", color: .blue, title: "Verification Codes",
                           info: "Read from Messages and mail. Turning this off stops reading Messages. Turning it back on reads recent history again.",
                           isOn: setting(Prefs.receivedCodes))
                SettingRow(symbol: "link", color: .teal, title: "Sign-In Links",
                           info: "Read from mail. Links open only when you click them, after you unlock CodeCatch.",
                           isOn: setting(Prefs.signInLinks))
            } header: {
                Text("What to Catch")
            } footer: {
                if !model.receiving {
                    Text("Messages and mail are paused.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Messages") {
                let status = model.status[MessagesStore.sourceKey] ?? .off
                let codes = model.monitoring(Prefs.receivedCodes)
                let about = "Reads codes from iMessage and forwarded SMS on this Mac. Needs Full Disk Access."
                SettingRow(symbol: "message.fill", color: .green, title: "Messages",
                           subtitle: codes ? problem(status) : "Paused while Verification Codes is off", info: about, status: status,
                           details: sourceDetails(MessagesStore.sourceKey, about: about, enabled: messagesEnabled && codes)) {
                    Toggle("Messages", isOn: $messagesEnabled).labelsHidden()
                        .onChange(of: messagesEnabled) { model.restartMessages() }
                }
                if messagesEnabled { diskAccessRow(status) }
            }

            Section("Mail") {
                let appleMail = model.status[AppleMailStore.sourceKey] ?? .off
                let aboutMail = "Reads new mail in the Mail app on this Mac, with no sign-in. Nothing is changed or marked as read. Mail fetches new mail only while it is open. Needs Full Disk Access."
                SettingRow(symbol: "tray.fill", color: .cyan, title: "Apple Mail", subtitle: problem(appleMail), info: aboutMail, status: appleMail,
                           details: sourceDetails(AppleMailStore.sourceKey, about: aboutMail, enabled: appleMailEnabled && model.receiving)) {
                    Toggle("Apple Mail", isOn: $appleMailEnabled).labelsHidden()
                        .onChange(of: appleMailEnabled) { model.restartAppleMail() }
                }
                if appleMailEnabled { diskAccessRow(appleMail) }
                ForEach(model.accounts) { account in
                    let status = model.status[account.id.uuidString] ?? .off
                    let about = "Nothing is changed or marked as read. Your password stays in your Keychain."
                    SettingRow(symbol: "envelope.fill", color: account.isGmail ? .red : .blue,
                               title: account.label, subtitle: [account.user, problem(status)].compactMap { $0 }.joined(separator: " · "),
                               info: about, status: status,
                               details: sourceDetails(account.id.uuidString, about: about, enabled: account.enabled && model.receiving) { editing = account }) {
                        Toggle("Monitor \(account.label)", isOn: Binding(get: { account.enabled }, set: { enabled in
                            var updated = account
                            updated.enabled = enabled
                            model.save(updated)
                        })).labelsHidden()
                    }
                    .contextMenu {
                        Button("Edit Account…") { editing = account }
                        Button("Check Now") { model.monitor.check(account.id.uuidString) }
                            .disabled(!(account.enabled && model.receiving))
                    }
                }
                HStack {
                    #if DEBUG
                    Menu {
                        Button("Add Mail Account…") { adding = true }
                        Button("Import from .env…", action: importEnv)
                    } label: {
                        Text("Add Account…")
                    } primaryAction: {
                        adding = true
                    }
                    .fixedSize()
                    Spacer()
                    if let importResult { Text(importResult).font(.caption).foregroundStyle(.secondary) }
                    #else
                    Button("Add Account…") { adding = true }
                    Spacer()
                    #endif
                }
            }

            Section("Bitwarden") {
                SettingRow(symbol: "key.fill", color: .blue, title: "Bitwarden", subtitle: vaultSubtitle,
                           info: aboutBitwarden, details: model.hasVault ? bitwardenDetails : nil) {
                    if model.hasVault {
                        Toggle("Bitwarden", isOn: setting(Prefs.bitwarden)).labelsHidden()
                    } else {
                        Button("Set Up…") {
                            model.setMonitoring(Prefs.bitwarden, enabled: true)
                            bitwarden = true
                        }
                    }
                }
                if let vaultError { Text(vaultError).font(.caption).foregroundStyle(.orange) }
            }

            if !model.ignoredSenders.isEmpty {
                Section {
                    ForEach(model.ignoredSenders, id: \.self) { sender in
                        SettingRow(symbol: "nosign", color: .gray, title: sender) {
                            Button("Stop Ignoring") { model.stopIgnoring(sender) }
                        }
                    }
                } header: {
                    Text("Ignored Senders")
                        .hoverInfo("Ignored Senders", "Codes from these senders are skipped. To ignore a sender, right-click one of their codes.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { AccountEditor(account: $0) }
        .sheet(isPresented: $bitwarden) { BitwardenSheet() }
        .sheet(isPresented: $adding) { AddAccountSheet { editing = $0 } }
    }

    private var aboutBitwarden: String {
        let about = "Shows two-step codes for your saved Bitwarden logins. Codes are made on this Mac and stay hidden until you unlock with \(DeviceAuthentication.unlockMethods)."
        return model.hasVault ? about + " Turning this off hides the codes and keeps your import. It also locks CodeCatch." : about
    }

    private var bitwardenDetails: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            Text(aboutBitwarden).foregroundStyle(.secondary)
            Divider()
            HStack {
                PopoverButton("Refresh…") { bitwarden = true }
                    .disabled(!model.monitoring(Prefs.bitwarden))
                Button(model.vaultSession.isUnlocked ? "Lock" : "Unlock") {
                    vaultError = nil
                    if model.vaultSession.isUnlocked { model.vaultSession.lock() }
                    else { Task { do { try await model.vaultSession.unlock() } catch { vaultError = error.localizedDescription } } }
                }.disabled(model.vaultSession.isBusy || (!model.vaultSession.isUnlocked && !model.monitoring(Prefs.bitwarden)))
                Spacer()
                PopoverButton("Remove Import", role: .destructive) {
                    vaultError = nil
                    Task { do { try await model.removeVault() } catch { vaultError = error.localizedDescription } }
                }.disabled(model.vaultSession.isBusy)
            }
        })
    }

    private var vaultSubtitle: String? {
        guard model.hasVault else { return nil }
        guard model.monitoring(Prefs.bitwarden) else { return "Off · import kept" }
        let state = model.vaultSession.isUnlocked ? "\(model.vault.count) codes" : "Locked"
        guard let imported = UserDefaults.standard.object(forKey: Prefs.vaultImportedAt) as? Date else { return state }
        return state + " · imported " + imported.formatted(.relative(presentation: .named))
    }

    private func setting(_ key: String) -> Binding<Bool> {
        Binding(get: { model.monitoring(key) }, set: { model.setMonitoring(key, enabled: $0) })
    }

    @ViewBuilder private func diskAccessRow(_ status: SourceStatus) -> some View {
        if status == .attention(SourceStatus.needsDiskAccess) {
            SettingRow(symbol: "lock.shield.fill", color: .orange, title: "Full Disk Access Needed",
                       subtitle: "Turn on CodeCatch in Privacy & Security") {
                Button("Open Settings") { SystemSettings.fullDiskAccess() }
            }
        }
    }

    /// What is wrong, when something is. Missing Full Disk Access has its own row.
    private func problem(_ status: SourceStatus) -> String? {
        status.needsAttention && status != .attention(SourceStatus.needsDiskAccess) ? status.summary : nil
    }

    /// The source's health and actions, shown when its row is clicked.
    private func sourceDetails(_ key: String, about: String, enabled: Bool, edit: (() -> Void)? = nil) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            SourceBadge(status: model.status[key] ?? .off)
            Text(about).foregroundStyle(.secondary)
            Divider()
            SourceHealthDetails(health: model.monitor.health[key] ?? SourceHealth(), now: model.now)
            HStack {
                Button("Check Now") { model.monitor.check(key) }.disabled(!enabled)
                if let edit { PopoverButton("Edit Account…", action: edit) }
            }
        })
    }

    #if DEBUG
    private func importEnv() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.message = "Choose a .env file with *_USER / *_PASS pairs"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var accounts = model.accounts
        do {
            let n = try EnvImport.importCredentials(from: url.path, into: &accounts)
            model.accounts = accounts
            importResult = n == 1 ? "Imported 1 password" : "Imported \(n) passwords"
        } catch {
            importResult = error.localizedDescription
        }
    }
    #endif
}
