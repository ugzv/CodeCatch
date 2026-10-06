import AppKit
import CodeCatchCore
import SwiftUI

/// Imports the vault's TOTP logins through the Bitwarden CLI, as a checklist that
/// re-checks itself: CLI installed, server, signed in, then unlock and import.
struct BitwardenSheet: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @Local private var status: BitwardenCLI.Status?
    @Local private var password = ""
    @Local private var session = ""
    @Local private var pasteSession = false
    @Local private var working = false
    @Local private var error: String?
    @Local private var pending: [VaultCode]?
    /// Logins in the vault whose authenticator key couldn't be read, from the last import.
    @Local private var unreadable: [String] = []
    @Local private var importGeneration: Int?
    @Local private var importTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bitwarden Codes").font(.title3.weight(.semibold))
                Text("CodeCatch saves only each login's name, username, site and authenticator key to your Keychain, then makes the codes itself. Login passwords are never saved.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let pending { review(pending) }
                // Nothing to change mid-read: a typed password is cleared when the import ends.
                else if let status { steps(status).disabled(working) }
                else { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.04)))
            if let error { WarningText(message: error).font(.callout) }
            HStack {
                Button("Check Again") { pending = nil; Task { await refresh() } }.disabled(working)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if pending != nil {
                    Button("Save Changes", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !model.vaultSession.isUnlocked)
                } else {
                    Button(working ? "Reading…" : "Review Import") { importTask = Task { await importCodes() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || status?.loggedIn != true || (pasteSession ? session : password).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { await refresh() }
        .onChange(of: model.vaultSession.isUnlocked) {
            if !model.vaultSession.isUnlocked { pending = nil; importGeneration = nil }
        }
        .onDisappear { importTask?.cancel(); pending = nil; password = ""; session = "" }
    }

    @ViewBuilder private func steps(_ status: BitwardenCLI.Status) -> some View {
        step(done: status.version != nil, "Bitwarden CLI", status.version.map { "Version \($0)" } ?? "Install it, then Check Again:",
             command: status.version == nil ? "brew install bitwarden-cli" : nil)
        if status.version == nil {
            Link("Bitwarden CLI installation options", destination: URL(string: "https://bitwarden.com/help/cli/")!)
        }
        if status.version != nil {
            step(done: status.region != nil || status.loggedIn, "Server", serverDetail(status)) {
                if !status.loggedIn {
                    Picker("", selection: Binding(get: { status.region ?? .us }, set: { region in Task { await setServer(region) } })) {
                        ForEach(BitwardenCLI.Region.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            step(done: status.loggedIn, "Account", status.email.map { "Signed in as \($0)" } ?? "Sign in once in Terminal (it asks for two-step login there), then Check Again:",
                 command: status.loggedIn ? nil : "bw login")
        }
        if status.loggedIn {
            step(done: false, "Unlock", pasteSession ? "A session from `bw unlock --raw`; CodeCatch doesn't lock it afterwards."
                 : "Your master password goes only to the Bitwarden CLI, once. The vault is locked again afterwards.")
            Group {
                if pasteSession { SecureField("Session", text: $session) } else { SecureField("Master password", text: $password) }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.leading, 28)
            Button(pasteSession ? "Use master password instead" : "Or paste a session from Terminal") { pasteSession.toggle() }
                .buttonStyle(.link).font(.caption).padding(.leading, 28)
        }
    }

    private func serverDetail(_ status: BitwardenCLI.Status) -> String {
        let name = status.region.map { "bitwarden.\($0 == .us ? "com" : "eu") (\($0.rawValue))" } ?? URL(string: status.server)?.host ?? status.server
        // The region is where the account was created, not where you live: a wrong one
        // makes `bw login` report the correct password as invalid.
        return status.loggedIn ? "\(name) · to switch, run `bw logout` first"
            : "\(name) · pick the one your web vault opens on (vault.bitwarden.com is US), not where you live"
    }

    private func step(done: Bool, _ title: String, _ detail: String, command: String? = nil) -> some View {
        step(done: done, title, command.map { "\(detail) `\($0)`" } ?? detail) {
            if let command {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
                    .controlSize(.small)
            }
        }
    }

    private func step<Trailing: View>(done: Bool, _ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                // Markdown only for `commands`: an email address would turn into a link.
                (detail.contains("`") ? Text(.init(detail)) : Text(verbatim: detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func refresh() async {
        working = true
        status = await BitwardenCLI.status()
        working = false
    }

    private func setServer(_ region: BitwardenCLI.Region) async {
        do { try await BitwardenCLI.setServer(region) } catch { self.error = error.localizedDescription }
        await refresh()
    }

    @ViewBuilder private func review(_ codes: [VaultCode]) -> some View {
        let changes = VaultChanges(before: model.vault, after: codes)
        Text("\(changes.added.count) added · \(changes.changed.count) changed · \(changes.removed.count) removed")
            .font(.headline)
        if codes.isEmpty, model.vault.isEmpty, unreadable.isEmpty {
            Text("No logins with an authenticator key were found in your vault.").foregroundStyle(.secondary)
        } else if changes.isEmpty {
            // With skipped logins, the warning below says what didn't come across.
            if unreadable.isEmpty { Text("Your saved codes are up to date.").foregroundStyle(.secondary) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    reviewGroup("Added", entries: changes.added)
                    reviewGroup("Changed", entries: changes.changed)
                    reviewGroup("Removed", entries: changes.removed)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 230)
        }
        if !unreadable.isEmpty {
            let named = unreadable.prefix(5) + (unreadable.count > 5 ? ["\(unreadable.count - 5) more"] : [])
            WarningText(message: "Skipped \(unreadable.count == 1 ? "1 login" : "\(unreadable.count) logins") with a key CodeCatch can't read: \(named.formatted(.list(type: .and))). Check the key in Bitwarden.")
                .font(.caption)
        }
        Text("Your saved codes stay unchanged until you save.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func reviewGroup(_ title: String, entries: [VaultChanges.Entry]) -> some View {
        if !entries.isEmpty {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    if !entry.account.isEmpty { Text(entry.account).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func save() {
        do {
            guard let pending, model.vaultSession.isUnlocked, importGeneration == model.vaultSession.generation else {
                throw VaultSession.Failure.locked
            }
            try model.saveVault(pending)
            self.pending = nil
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func importCodes() async {
        working = true
        error = nil
        defer { working = false; password = ""; session = "" }
        do {
            try await model.authenticate()
            let generation = model.vaultSession.generation
            let (codes, skipped) = try await BitwardenCLI.importCodes(password: pasteSession ? "" : password, session: pasteSession ? session : "")
            try Task.checkCancellation()
            guard model.vaultSession.isUnlocked, model.vaultSession.generation == generation else { throw VaultSession.Failure.locked }
            importGeneration = generation
            unreadable = skipped
            pending = codes
        } catch {
            if !AppModel.isCancel(error) { self.error = error.localizedDescription }
            await refresh()
        }
    }
}
