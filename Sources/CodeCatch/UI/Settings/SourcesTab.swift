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
                SettingRow(symbol: "number", color: .blue, title: "Verification Codes", subtitle: "From Messages and mail",
                           info: "Turning this off stops reading Messages. Turning it back on reads recent history again.",
                           isOn: setting(Prefs.receivedCodes))
                SettingRow(symbol: "link", color: .teal, title: "Sign-In Links", subtitle: "From mail",
                           info: "Links open only when you click them, after you unlock CodeCatch.",
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
                SettingRow(symbol: "message.fill", color: .green, title: "Messages",
                           subtitle: codes ? "iMessage and forwarded SMS" : "Paused while Verification Codes is off", status: status) {
                    sourceInfo(MessagesStore.sourceKey, title: "Messages",
                               detail: "Reads codes from Messages on this Mac. Needs Full Disk Access.",
                               enabled: messagesEnabled && codes)
                    Toggle("Messages", isOn: $messagesEnabled).labelsHidden()
                        .onChange(of: messagesEnabled) { model.restartMessages() }
                }
                if messagesEnabled { diskAccessRow(status) }
            }

            Section("Mail") {
                let appleMail = model.status[AppleMailStore.sourceKey] ?? .off
                SettingRow(symbol: "tray.fill", color: .cyan, title: "Apple Mail", subtitle: "Inboxes in the Mail app, no sign-in needed", status: appleMail) {
                    sourceInfo(AppleMailStore.sourceKey, title: "Apple Mail",
                               detail: "Reads new mail in the Mail app on this Mac. Nothing is changed or marked as read. Mail fetches new mail only while it is open. Needs Full Disk Access.",
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
                                   detail: "Nothing is changed or marked as read. Your password stays in your Keychain.",
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
                SettingRow(symbol: "key.fill", color: .blue, title: "Bitwarden", subtitle: vaultSubtitle) {
                    SettingInfo(title: "Bitwarden") {
                        Text("Shows two-step codes for your saved Bitwarden logins. Codes are made on this Mac and stay hidden until you unlock with \(DeviceAuthentication.unlockMethods).")
                        Text("Turning this off hides the codes and keeps your import. It also locks CodeCatch.")
                            .foregroundStyle(.secondary)
                    }
                    if model.hasVault {
                        Menu {
                            Button(model.vaultSession.isUnlocked ? "Lock" : "Unlock") {
                                vaultError = nil
                                if model.vaultSession.isUnlocked { model.vaultSession.lock() }
                                else { Task { do { try await model.vaultSession.unlock() } catch { vaultError = error.localizedDescription } } }
                            }.disabled(model.vaultSession.isBusy || (!model.vaultSession.isUnlocked && !model.monitoring(Prefs.bitwarden)))
                            Button("Refresh…") { bitwarden = true }
                                .disabled(!model.monitoring(Prefs.bitwarden))
                            Divider()
                            Button("Remove Import", role: .destructive) {
                                vaultError = nil
                                Task { do { try await model.removeVault() } catch { vaultError = error.localizedDescription } }
                            }.disabled(model.vaultSession.isBusy)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Bitwarden options")
                        .help("Bitwarden options")
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
                    HStack {
                        Text("Ignored Senders")
                        SettingInfo(title: "Ignored Senders") {
                            Text("Codes from these senders are skipped. To ignore a sender, right-click one of their codes.")
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
        guard model.hasVault else { return "Two-step codes from your saved logins" }
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
