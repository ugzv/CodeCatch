import SwiftUI

struct MonitoringTab: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Form {
            Section("Messages and Mail") {
                SettingRow(symbol: "number", color: .blue, title: "Verification Codes",
                           info: "Catch one-time codes from Messages and mail. Choose accounts in Sources. Turning this off pauses Messages; mail continues if Sign-In Links is on. Re-enabling re-reads recent history. Unlock with \(DeviceAuthentication.unlockMethods) to reveal or copy codes.",
                           isOn: setting(Prefs.receivedCodes))
                SettingRow(symbol: "link", color: .teal, title: "Sign-In Links",
                           info: "Catch sign-in and verification links from mail. Links open only when you choose, after unlocking CodeCatch. Mail pauses when both this and Verification Codes are off; re-enabling re-reads recent history.",
                           isOn: setting(Prefs.signInLinks))
            }
            Section("Saved Logins") {
                SettingRow(symbol: "key.fill", color: .indigo, title: "Bitwarden Authenticator",
                           subtitle: "Locks CodeCatch when changed",
                           info: "Generate two-step codes (TOTP) from saved Bitwarden logins. Set up or refresh the import in Sources. Turning this off hides saved logins without deleting the import. Unlock with \(DeviceAuthentication.unlockMethods) to use codes again.",
                           isOn: setting(Prefs.bitwarden))
            }
        }
        .formStyle(.grouped)
    }

    private func setting(_ key: String) -> Binding<Bool> {
        Binding(get: { model.monitoring(key) }, set: { model.setMonitoring(key, enabled: $0) })
    }
}
