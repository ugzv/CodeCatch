import AppKit
import AuthenticationServices
import CryptoKit

/// "Sign in with Google" for Gmail, read-only. Google's consent opens in the system sign-in sheet.
/// CodeCatch's own OAuth client ships in the app: it is an iOS-type client, a public client with
/// no secret, which is what Google recommends for Mac apps.
enum GoogleOAuth {
    enum Failure: LocalizedError {
        case denied(String), noGmailAccess, token(String)
        var errorDescription: String? {
            switch self {
            case .denied(let why): "Google sign-in was not completed (\(why))."
            case .noGmailAccess: "CodeCatch needs to view your email to find codes. Sign in again and allow it."
            case .token(let why): "Google refused the token (\(why)). Sign in with Google again."
            }
        }
    }

    /// A finished sign-in: the long-lived token and the Gmail address it reads.
    struct Grant: Equatable { let refreshToken: String, email: String }

    private static let clientID = "374242175460-a4bpd97sclaa5k4bpc598ei64n67om6l.apps.googleusercontent.com"
    /// Google's redirect for iOS-type clients: the client ID reversed, as a URL scheme.
    private static let scheme = "com.googleusercontent.apps.374242175460-a4bpd97sclaa5k4bpc598ei64n67om6l"
    static let redirect = scheme + ":/oauth2redirect"
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    /// Shows Google's consent for `email` (or any account, when empty) and returns the grant.
    @MainActor static func signIn(email: String) async throws -> Grant {
        let verifier = randomString(64)
        let state = randomString(24)
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            .init(name: "code_challenge_method", value: "S256"),
        ] + (email.isEmpty ? [] : [.init(name: "login_hint", value: email)])
        let callback = try await authorize(url.url!)
        guard let code = try authorizationCode(in: callback.absoluteString, state: state) else {
            throw Failure.denied("Google sent no sign-in code")
        }
        let tokens = try await tokenRequest(["code": code, "client_id": clientID, "redirect_uri": redirect,
                                             "grant_type": "authorization_code", "code_verifier": verifier])
        guard let refresh = tokens["refresh_token"] as? String, let access = tokens["access_token"] as? String else {
            throw Failure.token("no refresh token")
        }
        // Google's consent page lets people untick Gmail and still finish.
        guard ((tokens["scope"] as? String) ?? "").split(separator: " ").contains(Substring(scope)) else {
            throw Failure.noGmailAccess
        }
        let lifetime = (tokens["expires_in"] as? Double) ?? 3600
        lock.withLock { cache[refresh] = (access, Date().addingTimeInterval(lifetime)) }
        return Grant(refreshToken: refresh, email: try await GmailAPI(refreshToken: refresh).emailAddress())
    }

    private static var cache: [String: (token: String, expires: Date)] = [:]
    private static let lock = NSLock()
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    /// A current access token, refreshed a minute before it expires.
    static func accessToken(refresh: String) async throws -> String {
        if let hit = lock.withLock({ cache[refresh] }), hit.expires > Date().addingTimeInterval(60) { return hit.token }
        let tokens = try await tokenRequest(["refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token"])
        guard let token = tokens["access_token"] as? String else { throw Failure.token("no access token") }
        let lifetime = (tokens["expires_in"] as? Double) ?? 3600
        lock.withLock { cache[refresh] = (token, Date().addingTimeInterval(lifetime)) }
        return token
    }

    /// Drops a cached access token Google stopped accepting, so the next request refreshes it.
    static func forgetAccessToken(for refresh: String) {
        lock.withLock { cache[refresh] = nil }
    }

    /// Ends the sign-in on Google's side as well. Best effort: CodeCatch forgets the token either way.
    static func revoke(_ refresh: String) async {
        forgetAccessToken(for: refresh)
        _ = try? await session.data(for: formRequest("https://oauth2.googleapis.com/revoke", ["token": refresh]))
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: formRequest("https://oauth2.googleapis.com/token", form))
        let status = (response as? HTTPURLResponse)?.statusCode
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // Only Google turning the token down means signing in again; an outage or a captive portal is retried.
        if let error = json["error"] as? String, status == 400 || status == 401 { throw Failure.token(error) }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return json
    }

    private static func formRequest(_ url: String, _ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        return request
    }

    /// Ignore unrelated or ambiguous callbacks; only authenticated provider errors end sign-in.
    static func authorizationCode(in callback: String, state: String) throws -> String? {
        guard callback.hasPrefix(redirect + "?"),
              !callback.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              callback.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
              let url = URLComponents(string: callback), url.fragment == nil else { return nil }
        let items = (url.queryItems ?? []).filter { ["state", "code", "error"].contains($0.name) }
        guard Set(items.map(\.name)).count == items.count else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard !state.isEmpty, values["state"] == state else { return nil }
        if let error = values["error"], !error.isEmpty { throw Failure.denied(error) }
        guard let code = values["code"], !code.isEmpty else { return nil }
        return code
    }

    /// Google's page in the system sign-in sheet, until it redirects back to CodeCatch.
    @MainActor private static func authorize(_ url: URL) async throws -> URL {
        let flow = SignInSheet()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let once = Once()
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { url, error in
                    once.run {
                        if let url { cont.resume(returning: url) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { cont.resume(throwing: CancellationError()) }
                        else { cont.resume(throwing: error ?? Failure.denied("no response")) }
                    }
                }
                session.presentationContextProvider = flow
                flow.session = session
                if !session.start() { once.run { cont.resume(throwing: Failure.denied("the sign-in sheet did not open")) } }
            }
        } onCancel: {
            Task { @MainActor in flow.session?.cancel() }
        }
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

/// Keeps the session alive for the whole sign-in and anchors its sheet to CodeCatch's front window.
private final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor() }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
