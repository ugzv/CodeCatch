import AppKit
import AuthenticationServices
import CryptoKit

/// "Sign in with Google" and "Sign in with Microsoft", for reading mail. The provider's consent opens in the
/// system sign-in sheet (PKCE). CodeCatch's own clients ship in the app: public clients with no secret,
/// which is what both providers prescribe for desktop apps.
struct OAuth: Sendable {
    enum Failure: LocalizedError {
        case denied(String), noMailAccess(String), token(String)
        var errorDescription: String? {
            switch self {
            case .denied(let why): "Sign-in was not completed (\(why))."
            case .noMailAccess(let name): "CodeCatch needs to read your mail to find codes. Sign in with \(name) again and allow it."
            case .token(let why): "The sign-in was refused (\(why)). Sign in again."
            }
        }
    }

    /// A finished sign-in: the long-lived token and the address it reads.
    struct Grant: Equatable { let refreshToken: String, email: String }

    let name: String
    let clientID: String
    /// The custom-scheme redirect the provider sends the code back to; the sheet catches it.
    let redirect: String
    let scope: String
    /// The scope reading mail needs; consent pages may let people leave it out.
    let mailScope: String
    let authorizeURL: String, tokenURL: String
    /// Where a token is revoked, when the provider has one for apps like this.
    let revokeURL: String?
    /// The mailbox address, read with a just-issued access token.
    let address: @Sendable (String) async throws -> String

    static let google = OAuth(
        name: "Google",
        clientID: "374242175460-a4bpd97sclaa5k4bpc598ei64n67om6l.apps.googleusercontent.com",
        // An iOS-type client: Google's redirect is the client ID reversed, as a URL scheme.
        redirect: "com.googleusercontent.apps.374242175460-a4bpd97sclaa5k4bpc598ei64n67om6l:/oauth2redirect",
        scope: "https://www.googleapis.com/auth/gmail.readonly",
        mailScope: "https://www.googleapis.com/auth/gmail.readonly",
        authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth", tokenURL: "https://oauth2.googleapis.com/token",
        revokeURL: "https://oauth2.googleapis.com/revoke",
        address: { try await GmailAPI(auth: .issued($0)).emailAddress() })

    static let microsoft = OAuth(
        name: "Microsoft",
        clientID: "946bd1c2-64b4-443f-a51b-96f41bed07d1",
        redirect: "msauth.com.uros.codecatch://auth",
        scope: "offline_access User.Read Mail.Read",
        mailScope: "Mail.Read",
        // "common" takes both personal (Outlook.com) and work or school accounts.
        authorizeURL: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        tokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        revokeURL: nil,
        address: { try await OutlookAPI(auth: .issued($0)).emailAddress() })

    /// Shows the provider's consent for `email` (or any account, when empty) and returns the grant.
    @MainActor func signIn(email: String) async throws -> Grant {
        let verifier = Self.randomString(64)
        let state = Self.randomString(24)
        var url = URLComponents(string: authorizeURL)!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            .init(name: "code_challenge_method", value: "S256"),
        ] + (email.isEmpty ? [] : [.init(name: "login_hint", value: email)])
        let callback = try await authorize(url.url!)
        guard let code = try authorizationCode(in: callback.absoluteString, state: state) else {
            throw Failure.denied("no sign-in code came back")
        }
        let tokens = try await tokenRequest(["code": code, "client_id": clientID, "redirect_uri": redirect,
                                             "grant_type": "authorization_code", "code_verifier": verifier])
        guard let refresh = tokens["refresh_token"] as? String, let access = tokens["access_token"] as? String else {
            throw Failure.token("no refresh token")
        }
        // Google returns full scope URLs, Microsoft may too ("https://graph.microsoft.com/Mail.Read").
        let granted = ((tokens["scope"] as? String) ?? "").split(separator: " ")
        guard granted.contains(where: { $0 == mailScope || $0.hasSuffix("/" + mailScope) }) else { throw Failure.noMailAccess(name) }
        return Grant(refreshToken: refresh, email: try await address(access))
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

    /// A current access token for the sign-in saved under `key`, refreshed a minute before it expires.
    func accessToken(tokenKey key: String) async throws -> String {
        if let hit = Self.lock.withLock({ Self.cache[key] }), hit.expires > Date().addingTimeInterval(60) { return hit.token }
        guard let refresh = try Secrets.read(key) else { throw Failure.token("no refresh token") }
        let tokens = try await tokenRequest(["refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token"])
        guard let token = tokens["access_token"] as? String else { throw Failure.token("no access token") }
        // Microsoft hands out a new refresh token each time and the old one ages out; keep the new one.
        if let next = tokens["refresh_token"] as? String, next != refresh { try? Secrets.set(next, for: key) }
        let lifetime = (tokens["expires_in"] as? Double) ?? 3600
        Self.lock.withLock { Self.cache[key] = (token, Date().addingTimeInterval(lifetime)) }
        return token
    }

    /// Drops a cached access token the provider stopped accepting, so the next request refreshes it.
    static func forgetAccessToken(tokenKey key: String) {
        lock.withLock { cache[key] = nil }
    }

    /// Ends the sign-in on the provider's side as well, where it offers that. Best effort.
    func revoke(_ refresh: String) async {
        guard let revokeURL else { return }
        _ = try? await Self.session.data(for: Self.formRequest(revokeURL, ["token": refresh]))
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        let (data, response) = try await Self.session.data(for: Self.formRequest(tokenURL, form))
        let status = (response as? HTTPURLResponse)?.statusCode
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // Only the provider turning the token down means signing in again; an outage or a captive portal is retried.
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
    func authorizationCode(in callback: String, state: String) throws -> String? {
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

    /// The provider's page in the system sign-in sheet, until it redirects back to CodeCatch.
    @MainActor private func authorize(_ url: URL) async throws -> URL {
        let flow = SignInSheet()
        let scheme = String(redirect.prefix { $0 != ":" })
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

/// Where a mail API call's access token comes from: a saved sign-in, or one just issued at sign-in.
enum APIAuth: Sendable {
    case saved(OAuth, tokenKey: String), issued(String)

    func accessToken() async throws -> String {
        switch self {
        case .saved(let oauth, let key): try await oauth.accessToken(tokenKey: key)
        case .issued(let token): token
        }
    }

    /// Whether a refused token can be refreshed and the call tried again.
    func forget() -> Bool {
        guard case .saved(_, let key) = self else { return false }
        OAuth.forgetAccessToken(tokenKey: key)
        return true
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
