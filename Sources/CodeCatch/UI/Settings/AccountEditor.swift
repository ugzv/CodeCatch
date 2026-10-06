import AppKit
import SwiftUI

struct AccountEditor: View {
    @Local var account: MailAccount
    @Local private var password = ""
    @StateObject private var google = MailSignIn()
    @Local private var hasPassword = false
    @Local private var error: String?
    @Local private var original: MailAccount?
    @ObservedObject private var model = AppModel.shared
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { !model.accounts.contains { $0.id == account.id } }

    private var usesGoogle: Bool { google.token(for: account) != nil || account.usesGoogle }
    /// Google turned the saved sign-in down, and no new one was made here yet.
    private var signInExpired: Bool {
        account.usesGoogle && google.token(for: account) == nil
            && model.status[account.id.uuidString] == .failed(SourceStatus.googleSignInExpired)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Label", text: $account.label, prompt: Text("Personal"))
                if account.isGmail {
                    LabeledContent {
                        if google.isBusy {
                            HStack { ProgressView().controlSize(.small); Text("Finish in the Google window…").foregroundStyle(.secondary) }
                        } else if signInExpired {
                            HStack {
                                Label("Expired", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Button("Sign In Again…", action: signInWithGoogle)
                                Button("Sign Out") { account.googleSignIn = nil; google.cancel() }
                            }
                        } else if usesGoogle {
                            HStack {
                                Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                Button("Sign Out") { account.googleSignIn = nil; google.cancel() }
                            }
                        } else {
                            Button("Sign in with Google…", action: signInWithGoogle)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Google sign-in")
                            Text("Beta").font(.caption2.weight(.semibold)).foregroundStyle(.blue)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.blue.opacity(0.12)))
                        }
                    }
                }
                if usesGoogle {
                    // Google fills in the address, and the Gmail API needs no server settings.
                    LabeledContent("Email", value: account.user)
                } else {
                    TextField("Email", text: $account.user, prompt: Text("you@example.com"))
                        .onSubmit { if account.host.isEmpty { account.host = MailAccount.guess(for: account.user).host } }
                    TextField("IMAP server", text: $account.host, prompt: Text("imap.gmail.com"))
                    TextField("Port", value: $account.port, format: .number.grouping(.never))
                }
                if !usesGoogle {
                    SecureField("App password", text: $password,
                                prompt: Text(!hasPassword ? "Required" : "Saved — leave empty to keep"))
                    if account.isGmail {
                        Link("How to create a Google app password", destination: MailAccount.appPasswordHelp)
                            .font(.caption)
                    }
                }
                Toggle("Enabled", isOn: $account.enabled)
                if let error { WarningText(message: error).font(.caption) }
            }
            .formStyle(.grouped)
            .disabled(google.isBusy)
            HStack {
                if !isNew {
                    Button("Remove Account…", role: .destructive) {
                        // Name the saved account, which is what gets removed, not unsaved edits.
                        guard let saved = original, confirmed("Remove \(saved.label)?",
                            "CodeCatch stops watching \(saved.user) and forgets how to sign in to it. Your mail doesn't change.", action: "Remove") else { return }
                        do { try model.remove(account); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.user.isEmpty || account.host.isEmpty || !(1...65535).contains(account.port) || google.isBusy
                              || (!usesGoogle && !hasPassword && password.isEmpty))
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .onAppear {
            original = model.accounts.first { $0.id == account.id }
            hasPassword = account.password != nil
        }
        .onChange(of: account.secretKey) {
            hasPassword = account.password != nil
            guard google.token(for: account) == nil else { return }  // Google just filled in the address
            google.cancel()
            account.googleSignIn = account.secretKey == original?.secretKey ? original?.googleSignIn : nil
        }
        .onDisappear { google.cancel(); password = "" }
    }

    private func signInWithGoogle() {
        error = nil
        Task {
            do { account.user = try await google.signIn(for: account) }
            catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func save() {
        error = nil
        do {
            if account.label.isEmpty { account.label = MailAccount.guess(for: account.user).label }
            try model.saveAccount(account, password: password, refreshToken: google.token(for: account))
            if let original { try model.removeUnusedCredentials(for: original) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
