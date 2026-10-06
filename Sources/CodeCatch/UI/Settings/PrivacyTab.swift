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
                           info: "CodeCatch windows stay out of Zoom, Meet and screenshots.", isOn: $hideFromCapture)
                SettingRow(symbol: "eye.slash.fill", color: .indigo, title: "Blur Codes Until Hover",
                           info: "Point at a code to read it. The menu bar shows only the app icon.", isOn: $blurCodes)
                SettingRow(symbol: "menubar.rectangle", color: .gray, title: "Show Code in Menu Bar",
                           info: "Shows the newest code for three minutes, or until you use it.", isOn: $codeInMenuBar)
                SettingRow(symbol: "text.bubble.fill", color: .green, title: "Show Message Previews",
                           info: "Shows the SMS text or email subject under each code.", isOn: $showPreviews)
            }
            Section("Clipboard and Network") {
                SettingRow(symbol: "clock.arrow.circlepath", color: .orange, title: "Clear Clipboard After 90 Seconds",
                           info: "Only if you have not copied something else since. Codes do not sync to your other devices, and clipboard managers are asked to skip them.", isOn: $clearClipboard)
                SettingRow(symbol: "app.badge.fill", color: .purple, title: "Show Service Logos",
                           info: "Logos load through Google, or DuckDuckGo when Google has none. They see your IP address and the site name, such as github.com. Turn this off to stop it.", isOn: $serviceIcons)
            }
            Section("History") {
                SettingRow(symbol: "clock.fill", color: .teal, title: "Keep Codes For",
                           info: "CodeCatch rereads Messages and mail when it starts. It never saves codes to disk.") {
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
                           info: "Also clears a code still on the clipboard. Bitwarden codes are kept.", isOn: $clearOnLock)
                SettingRow(symbol: "trash.fill", color: .gray, title: "Clear History",
                           info: "Cleared codes stay gone after a restart. Bitwarden codes are kept. New codes and links still appear.") {
                    Button("Clear Now") { confirmClearHistory(model) }.disabled(!model.hasHistory)
                }
            }
        }
        .formStyle(.grouped)
    }
}
