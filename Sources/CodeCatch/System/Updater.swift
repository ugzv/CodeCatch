import Sparkle

/// Sparkle: checks the appcast at SUFeedURL (Info.plist) daily and installs updates signed
/// with the EdDSA key behind SUPublicEDKey. scripts/install.sh --release writes the appcast.
@MainActor enum Updater {
    /// Nil in an unbundled build (swift run, tests): there is no feed to check.
    static let controller: SPUStandardUpdaterController? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil ? nil
        : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}
