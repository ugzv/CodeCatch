import Foundation

enum SourceStatus: Equatable {
    case off, connecting, live
    case attention(String)
    case failed(String)

    /// What a local store reports until the app is allowed to read it.
    static let needsDiskAccess = "Needs Full Disk Access"
    /// What a signed-in mail account reports when its provider no longer accepts the sign-in.
    static let signInExpired = "Sign-in expired — sign in again"

    var needsAttention: Bool {
        switch self {
        case .attention, .failed: true
        default: false
        }
    }

    var summary: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .live: "Watching"
        case .attention(let s), .failed(let s): s
        }
    }
}
