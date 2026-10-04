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
                SettingRow(symbol: "rectangle.inset.topright.filled", color: .blue, title: "Show Banner", info: "A card appears at the top right. It does not take focus from the app you are using.", isOn: $showBanner)
                SettingRow(symbol: "doc.on.clipboard.fill", color: .indigo, title: "Automatically Copy Codes", subtitle: "While unlocked", info: "New codes are ready to paste. Sign-in links are never copied.", isOn: $autoCopy)
                SettingRow(symbol: "text.cursor", color: .teal, title: "Automatically Type Codes", subtitle: "Into the field you are in, while unlocked", info: "Types each new code key by key, so split fields fill too. It types into whatever app is in front, so check you are on the real site before you ask for a code. Needs Accessibility access.", isOn: $autoType)
                    .onChange(of: autoType) { if autoType { Accessibility.requestTrust() } }
                if autoType {
                    let _ = model.now  // re-check once a second while open
                    let trusted = Accessibility.isTrusted
                    SettingRow(symbol: "accessibility", color: .blue, title: "Accessibility", subtitle: "Needed to type codes",
                               info: trusted ? nil : "Already on in System Settings? That entry is from an older version. Remove CodeCatch with −, then click Allow again.") {
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
            Section("Startup") {
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
                SettingRow(symbol: "arrow.down.circle.fill", color: .blue, title: "Update Automatically", subtitle: "Checks once a day", isOn: $autoUpdate)
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
