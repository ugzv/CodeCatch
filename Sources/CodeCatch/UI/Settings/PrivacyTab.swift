import SwiftUI

struct PrivacyTab: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(Prefs.hideFromCapture) private var hideFromCapture = true
    @AppStorage(Prefs.blurCodes) private var blurCodes = false
    @AppStorage(Prefs.codeInMenuBar) private var codeInMenuBar = true
    @AppStorage(Prefs.showPreviews) private var showPreviews = true
    @AppStorage(Prefs.clearClipboard) private var clearClipboard = true
    @AppStorage(Prefs.serviceIcons) private var serviceIcons = true
    @AppStorage(Prefs.historyDays) private var historyDays = 7
    @AppStorage(Prefs.clearOnLock) private var clearOnLock = false

    var body: some View {
        Form {
            Section("On Screen") {
                SettingRow(symbol: "rectangle.dashed.badge.record", color: .red, title: "Hide from Screen Capture",
                           info: "CodeCatch windows stay out of Zoom, Meet and screenshots", isOn: $hideFromCapture)
                SettingRow(symbol: "eye.slash.fill", color: .indigo, title: "Blur Codes Until Hover",
                           info: "Point at a code to read it; the menu bar shows only the app icon", isOn: $blurCodes)
                SettingRow(symbol: "menubar.rectangle", color: .gray, title: "Show Code in Menu Bar",
                           info: "For three minutes, or until used", isOn: $codeInMenuBar)
                SettingRow(symbol: "text.bubble.fill", color: .green, title: "Show Message Previews",
                           info: "The SMS text or email subject under each code", isOn: $showPreviews)
            }
            Section("Clipboard and Network") {
                SettingRow(symbol: "clock.arrow.circlepath", color: .orange, title: "Clear Clipboard After 90 Seconds",
                           info: "Only if nothing else was copied since. Universal Clipboard is disabled for these copies; clipboard managers are asked not to save them.", isOn: $clearClipboard)
                SettingRow(symbol: "app.badge.fill", color: .purple, title: "Show Service Logos",
                           info: "Logos load through Google, which receives your IP address and the requested service domain. CodeCatch does not contact service websites for logos. Turn this off to stop logo requests.", isOn: $serviceIcons)
            }
            Section("History") {
                SettingRow(symbol: "clock.fill", color: .teal, title: "Keep Codes For",
                           info: "Received history is re-read from Messages and mail, never written to disk. Changing this period refreshes the sources.") {
                    Picker("Keep Codes For", selection: $historyDays) {
                        Text("1 Day").tag(1)
                        Text("7 Days").tag(7)
                        Text("30 Days").tag(30)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: historyDays) {
                        model.restartMessages()
                        model.restartMail()
                    }
                }
                SettingRow(symbol: "lock.fill", color: .blue, title: "Clear History When Mac Locks",
                           info: "Clear received history and any code still on the clipboard when your Mac locks. Saved Bitwarden logins are kept.", isOn: $clearOnLock)
                SettingRow(symbol: "trash.fill", color: .gray, title: "Clear History",
                           subtitle: "Cleared codes won’t return after restarting",
                           info: "Clear all received history up to now. Saved Bitwarden logins are kept. New codes and links will still appear.") {
                    Button("Clear Now") { model.clearHistory() }.disabled(model.items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}
