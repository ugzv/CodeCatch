import AppKit
import SwiftUI

/// Shown once on first launch, and again from the menu: a code to try, the one
/// permission that matters, and the shortcuts. Everything here also lives in Settings.
struct WelcomeView: View {
    static let windowID = "welcome"

    @ObservedObject private var model = AppModel.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.launchAtLogin) private var launchAtLogin = true
    @AppStorage(Prefs.hotkeys) private var hotkeys = true

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    CodeCatchMark().fill(.linearGradient(colors: AppBrand.colors, startPoint: .top, endPoint: .bottom))
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    Text("Welcome to \(AppBrand.name)").font(.title2.weight(.semibold))
                    Text("CodeCatch catches verification codes and sign-in links as they arrive, one click or ⌘V away. Find it in the menu bar.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("See It Work") {
                SettingRow(symbol: "rectangle.inset.topright.filled", color: .blue, title: "Show a Test Code",
                           subtitle: "A banner appears at the top right, as a real code would. Click it to unlock and copy.") {
                    Button("Try It") { model.showTestCode() }
                        .disabled(!model.monitoring(Prefs.receivedCodes))
                }
            }
            Section("What to Catch") {
                let messages = model.status[MessagesStore.sourceKey] ?? .off
                SettingRow(symbol: SourceKind.messages.symbol, color: SourceKind.messages.color, title: "Messages",
                           subtitle: messages == .attention(SourceStatus.needsDiskAccess)
                               ? "Needs Full Disk Access: drag CodeCatch into the list that opens, then turn it on."
                               : "iMessage, and SMS once Text Message Forwarding is on in your iPhone’s Messages settings", status: messages) {
                    switch messages {
                    case .live:
                        Label { Text("Watching").foregroundStyle(.secondary) } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    case .attention(SourceStatus.needsDiskAccess):
                        Button("Allow…") { SystemSettings.fullDiskAccess() }
                    default:
                        Text(messages.summary).foregroundStyle(.secondary)
                    }
                }
                SettingRow(symbol: SourceKind.appleMail.symbol, color: SourceKind.appleMail.color, title: "Apple Mail",
                           subtitle: "Mail app inboxes, with the same Full Disk Access",
                           status: model.status[AppleMailStore.sourceKey] ?? .off) {
                    AppleMailToggle()
                }
                SettingRow(symbol: SourceKind.mail.symbol, color: SourceKind.mail.color, title: "Mail Accounts and Bitwarden",
                           subtitle: "Gmail, iCloud, Yahoo, other mail and Bitwarden codes") {
                    Button("Set Up…") { openSettings(at: .sources) }
                }
            }
            Section("Good to Know") {
                if hotkeys {
                    ForEach(Hotkeys.all, id: \.label) { hotkey in
                        SettingRow(symbol: "command", color: .gray, title: hotkey.title) {
                            Text(hotkey.label).monospaced().foregroundStyle(.secondary)
                        }
                    }
                }
                SettingRow(symbol: "power", color: .green, title: "Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.sync(userChanged: true) }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("Reopen it from ••• → Welcome Guide.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .bottomBar()
        }
        .frame(width: 500, height: 740)
        .onAppear {
            UserDefaults.standard.set(true, forKey: Prefs.welcomed)
            NSApp.activate()
        }
    }
}
