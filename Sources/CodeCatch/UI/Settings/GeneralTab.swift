import SwiftUI

struct GeneralTab: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(Prefs.autoType) private var autoType = false
    @AppStorage(Prefs.showBanner) private var showBanner = true
    @AppStorage(Prefs.autoCopy) private var autoCopy = true
    @AppStorage(Prefs.sound) private var sound = false
    @AppStorage(Prefs.launchAtLogin) private var launchAtLogin = true
    @AppStorage(Prefs.hotkeys) private var hotkeys = true
    @Local private var autoUpdate = Updater.controller?.updater.automaticallyChecksForUpdates ?? false

    var body: some View {
        Form {
            Section("When a Code or Link Arrives") {
                SettingRow(symbol: "rectangle.inset.topright.filled", color: .blue, title: "Show Banner", info: "Show a card in the top-right corner when a code or sign-in link arrives. The banner does not take focus from the app you are using.", isOn: $showBanner)
                SettingRow(symbol: "doc.on.clipboard.fill", color: .indigo, title: "Automatically Copy Codes", subtitle: "While unlocked", info: "Copy new verification codes so they are ready to paste. Sign-in links are never copied automatically.", isOn: $autoCopy)
                SettingRow(symbol: "text.cursor", color: .teal, title: "Automatically Type Codes", subtitle: "Into the focused field, while unlocked", info: "Type each new verification code into the field that has focus, as real key presses, so one-box-per-digit fields fill too. The code goes to whatever app and page is in front when it arrives, so check you are on the real site before asking for a code. Needs Accessibility access. Sign-in links are never opened for you.", isOn: $autoType)
                    .onChange(of: autoType) { if autoType { Accessibility.requestTrust() } }
                if autoType {
                    let _ = model.now  // re-check once a second while open
                    let trusted = Accessibility.isTrusted
                    SettingRow(symbol: "accessibility", color: .blue, title: "Accessibility",
                               subtitle: trusted ? "Needed to type codes" : "Needed to type codes. Already switched on in System Settings? That entry is from an older build: remove CodeCatch with −, then Allow again.") {
                        if trusted {
                            Label { Text("Allowed").foregroundStyle(.secondary) } icon: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        } else {
                            Button("Allow…") { Accessibility.requestTrust(force: true); SystemSettings.accessibility() }
                        }
                    }
                }
                SettingRow(symbol: "speaker.wave.2.fill", color: .pink, title: "Play Sound", isOn: $sound)
            }
            Section("Keyboard") {
                SettingRow(symbol: "command", color: .gray, title: "Keyboard Shortcuts",
                           info: Hotkeys.all.map { "\($0.label)  \($0.title)" }.joined(separator: "\n"), isOn: $hotkeys)
                    .onChange(of: hotkeys) { Hotkeys.sync() }
            }
            Section {
                SettingRow(symbol: "power", color: .green, title: "Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.sync(userChanged: true) }
            }
            Section("Updates") {
                let _ = model.now  // refresh the last-checked time while open
                let updater = Updater.controller?.updater
                HStack(spacing: 10) {
                    BrandTile()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CodeCatch \(AppBrand.version ?? "")")
                        if let checked = updater?.lastUpdateCheckDate {
                            Text("Last checked \(checked.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    Button("Check Now…") { updater?.checkForUpdates() }
                        .disabled(updater?.canCheckForUpdates != true)
                }
                SettingRow(symbol: "arrow.down.circle.fill", color: .blue, title: "Update Automatically", subtitle: "Checks once a day and installs new versions", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) {
                        updater?.automaticallyChecksForUpdates = autoUpdate
                        updater?.automaticallyDownloadsUpdates = autoUpdate
                    }
                Link("What’s New in CodeCatch", destination: URL(string: "https://codecatch.app/changelog/")!)
            }
        }
        .formStyle(.grouped)
    }
}
