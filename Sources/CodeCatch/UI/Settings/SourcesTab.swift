import AppKit
import SwiftUI

struct SourcesTab: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(Prefs.messages) private var messagesEnabled = true
    @AppStorage(Prefs.appleMail) private var appleMailEnabled = false
    @Local private var editing: MailAccount?
    @Local private var adding = false
    @Local private var importResult: String?
    @Local private var bitwarden = false
    @Local private var vaultError: String?

    var body: some View {
        Form {
            if !model.receiving {
                Label("Messages and mail are paused. Choose what to catch in Monitoring to resume.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Messages") {
                let status = model.status[MessagesStore.sourceKey] ?? .off
                SettingRow(symbol: "message.fill", color: .green, title: "Messages", subtitle: "iMessage and forwarded SMS", status: status) {
                    sourceInfo(MessagesStore.sourceKey, title: "Messages",
                               detail: "Reads verification codes from Messages on this Mac. Requires Full Disk Access and Verification Codes enabled in Monitoring.",
                               enabled: messagesEnabled && model.monitoring(Prefs.receivedCodes))
                    Toggle("Messages", isOn: $messagesEnabled).labelsHidden()
                        .onChange(of: messagesEnabled) { model.restartMessages() }
                }
                if model.receiving, !model.monitoring(Prefs.receivedCodes) {
                    Text("Enable Verification Codes in Monitoring to read Messages.").font(.caption).foregroundStyle(.secondary)
                }
                if messagesEnabled { diskAccessRow(status) }
            }

            Section("Mail") {
                let appleMail = model.status[AppleMailStore.sourceKey] ?? .off
                SettingRow(symbol: "tray.fill", color: .cyan, title: "Apple Mail", subtitle: "Inboxes in the Mail app, no sign-in needed", status: appleMail) {
                    sourceInfo(AppleMailStore.sourceKey, title: "Apple Mail",
                               detail: "Reads new mail in the inboxes of the Mail app on this Mac, without changing it or marking it as read. Mail fetches while it is open. Requires Full Disk Access. An account added below as well is read twice; each code still appears once.",
                               enabled: appleMailEnabled && model.receiving)
                    Toggle("Apple Mail", isOn: $appleMailEnabled).labelsHidden()
                        .onChange(of: appleMailEnabled) { model.restartAppleMail() }
                }
                if appleMailEnabled { diskAccessRow(appleMail) }
                ForEach(model.accounts) { account in
                    let status = model.status[account.id.uuidString] ?? .off
                    SettingRow(symbol: "envelope.fill", color: account.isGmail ? .red : .blue,
                               title: account.label, subtitle: account.user, status: status) {
                        sourceInfo(account.id.uuidString, title: account.label,
                                   detail: "Mail is read without changing it or marking it as read. Credentials are kept in your login Keychain.",
                                   enabled: account.enabled && model.receiving)
                        Menu {
                            Button("Edit Account…") { editing = account }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Options for \(account.label)")
                        .help("Account options")
                        Toggle("Monitor \(account.label)", isOn: Binding(get: { account.enabled }, set: { enabled in
                            var updated = account
                            updated.enabled = enabled
                            model.save(updated)
                        })).labelsHidden()
                    }
                }
                HStack {
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
                }
            }

            Section("Authenticator") {
                SettingRow(symbol: "key.fill", color: .blue, title: "Bitwarden", subtitle: vaultSubtitle) {
                    if model.hasVault {
                        Button(model.vaultSession.isUnlocked ? "Lock" : "Unlock") {
                            vaultError = nil
                            if model.vaultSession.isUnlocked { model.vaultSession.lock() }
                            else { Task { do { try await model.vaultSession.unlock() } catch { vaultError = error.localizedDescription } } }
                        }.disabled(model.vaultSession.isBusy || (!model.vaultSession.isUnlocked && !model.monitoring(Prefs.bitwarden)))
                    } else {
                        Button("Set Up…") { bitwarden = true }
                            .disabled(!model.monitoring(Prefs.bitwarden))
                    }
                    SettingInfo(title: "Bitwarden") {
                        Text("Generate authenticator codes from your saved Bitwarden import. Unlock with \(DeviceAuthentication.unlockMethods); use Refresh to review changes from Bitwarden.")
                        Text("Turn Bitwarden on or off in Monitoring. Turning it off keeps your saved import.")
                            .foregroundStyle(.secondary)
                    }
                    if model.hasVault {
                        Menu {
                            Button("Refresh…") { bitwarden = true }
                                .disabled(!model.monitoring(Prefs.bitwarden))
                            Divider()
                            Button("Remove Saved Import", role: .destructive) {
                                vaultError = nil
                                Task { do { try await model.removeVault() } catch { vaultError = error.localizedDescription } }
                            }.disabled(model.vaultSession.isBusy)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Bitwarden options")
                        .help("Bitwarden options")
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
                    HStack {
                        Text("Ignored Senders")
                        SettingInfo(title: "Ignored Senders") {
                            Text("Messages from these senders are skipped. Ignore a sender from a code's right-click menu, or restore one here.")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { AccountEditor(account: $0) }
        .sheet(isPresented: $bitwarden) { BitwardenSheet() }
        .sheet(isPresented: $adding) { AddAccountSheet { editing = $0 } }
    }

    private var vaultSubtitle: String {
        guard model.monitoring(Prefs.bitwarden) else { return model.hasVault ? "Off · saved import kept" : "Off · enable in Monitoring to set up" }
        guard model.hasVault else { return "Not set up" }
        let state = model.vaultSession.isUnlocked ? "\(model.vault.count) codes · unlocked" : "Locked"
        guard let imported = UserDefaults.standard.object(forKey: Prefs.vaultImportedAt) as? Date else { return state }
        return state + " · imported " + imported.formatted(.relative(presentation: .named))
    }

    @ViewBuilder private func diskAccessRow(_ status: SourceStatus) -> some View {
        if status == .attention(SourceStatus.needsDiskAccess) {
            SettingRow(symbol: "lock.shield.fill", color: .orange, title: "Full Disk Access Needed",
                       subtitle: "Enable CodeCatch in Privacy & Security") {
                Button("Open Settings") { SystemSettings.fullDiskAccess() }
            }
        }
    }

    /// What is wrong, when something is, then the info button with the source's health.
    @ViewBuilder private func sourceInfo(_ key: String, title: String, detail: String, enabled: Bool) -> some View {
        let status = model.status[key] ?? .off
        if status.needsAttention {
            Text(status.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        SettingInfo(title: title) {
            SourceBadge(status: status)
            Text(detail).foregroundStyle(.secondary)
            Divider()
            SourceHealthDetails(health: model.monitor.health[key] ?? SourceHealth(), now: model.now)
            Button("Check Now") { model.monitor.check(key) }.disabled(!enabled)
        }
    }

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
}
