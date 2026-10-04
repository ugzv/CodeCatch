import Foundation
import Sparkle

/// Sparkle: checks the appcast at SUFeedURL (Info.plist) daily and installs updates signed
/// with the EdDSA key behind SUPublicEDKey. scripts/install.sh --release writes the appcast.
@MainActor enum Updater {
    /// Nil in an unbundled build (swift run, tests): there is no feed to check.
    static let controller: SPUStandardUpdaterController? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil ? nil
        : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: feed, userDriverDelegate: nil)
    private static let feed = FeedParameters()
}

/// Adds a random install ID, the build, macOS version and Mac model to each update check, so
/// codecatch.app can count installs per version (functions/_middleware.js). Nothing else is sent.
private final class FeedParameters: NSObject, SPUUpdaterDelegate {
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "installID") ?? UUID().uuidString
        defaults.set(id, forKey: "installID")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            ["key": "id", "value": id],
            ["key": "build", "value": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""],
            ["key": "os", "value": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"],
            ["key": "model", "value": Self.model],
        ]
    }

    private static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()
}
