import Foundation
import ServiceManagement

/// Registers once, then only when the user flips the toggle: registering on every
/// launch made macOS post "Background Items Added" again after each reinstall.
enum LoginItem {
    private static let registeredKey = "loginItemRegistered"

    static func sync(userChanged: Bool = false) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let service = SMAppService.mainApp
        if Prefs[Prefs.launchAtLogin] {
            guard userChanged || !UserDefaults.standard.bool(forKey: registeredKey) else { return }
            if service.status != .enabled { try? service.register() }
            UserDefaults.standard.set(true, forKey: registeredKey)
        } else if userChanged, service.status == .enabled {
            try? service.unregister()
        }
    }
}
