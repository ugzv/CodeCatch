import AppKit
import CryptoKit
import Network

/// "Sign in with Google" for Gmail over IMAP (XOAUTH2), so the account does not
/// depend on an app password. Uses your own Google OAuth client (type "Web
/// application", redirect http://localhost:8765/), imported from a .env.
enum GoogleOAuth {
    enum Failure: LocalizedError {
        case noClient, denied(String), timedOut, token(String)
        var errorDescription: String? {
            switch self {
            case .noClient: "No Google OAuth client. Import GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET from a .env first."
            case .denied(let why): "Google sign-in was not completed (\(why))."
            case .timedOut: "Google sign-in timed out."
            case .token(let why): "Google refused the token (\(why)). Sign in with Google again."
            }
        }
    }

    static let clientIDKey = "google.client-id", clientSecretKey = "google.client-secret"
    private static let port: NWEndpoint.Port = 8765
    private static let redirect = "http://localhost:8765/"
    private static let scope = "https://mail.google.com/"

    static var isConfigured: Bool { Secrets.get(clientIDKey) != nil && Secrets.get(clientSecretKey) != nil }

    /// Opens Google's consent page in the browser and returns a refresh token.
    static func signIn(email: String) async throws -> String {
        guard let clientID = Secrets.get(clientIDKey), let secret = Secrets.get(clientSecretKey) else { throw Failure.noClient }
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "login_hint", value: email), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
        ]
        async let code = waitForRedirect(state: state)
        NSWorkspace.shared.open(url.url!)
        let tokens = try await tokenRequest([
            "code": try await code, "client_id": clientID, "client_secret": secret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = tokens["refresh_token"] as? String else { throw Failure.token("no refresh token") }
        return refresh
    }

    private static var cache: [String: (token: String, expires: Date)] = [:]
    private static let lock = NSLock()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    /// A current access token for IMAP, refreshed a minute before it expires.
    static func accessToken(refresh: String) async throws -> String {
        if let hit = lock.withLock({ cache[refresh] }), hit.expires > Date().addingTimeInterval(60) { return hit.token }
        guard let clientID = Secrets.get(clientIDKey), let secret = Secrets.get(clientSecretKey) else { throw Failure.noClient }
        let tokens = try await tokenRequest(["refresh_token": refresh, "client_id": clientID, "client_secret": secret,
                                             "grant_type": "refresh_token"])
        guard let token = tokens["access_token"] as? String else { throw Failure.token("no access token") }
        let lifetime = (tokens["expires_in"] as? Double) ?? 3600
        lock.withLock { cache[refresh] = (token, Date().addingTimeInterval(lifetime)) }
        return token
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = json["error"] as? String { throw Failure.token(error) }
        return json
    }

    /// Ignore unrelated or ambiguous callbacks; only authenticated provider errors end sign-in.
    static func authorizationCode(in target: String, state: String) throws -> String? {
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              !target.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              target.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
              let url = URLComponents(string: target), url.path == "/", url.host == nil, url.fragment == nil else { return nil }
        let items = (url.queryItems ?? []).filter { ["state", "code", "error"].contains($0.name) }
        guard Set(items.map(\.name)).count == items.count else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard !state.isEmpty, values["state"] == state else { return nil }
        if let error = values["error"], !error.isEmpty { throw Failure.denied(error) }
        guard let code = values["code"], !code.isEmpty else { return nil }
        return code
    }

    /// The one-shot local redirect listener, reachable from this Mac only.
    static func waitForRedirect(state: String) async throws -> String {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        let queue = DispatchQueue(label: "google-oauth")
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let once = Once()
                func finish(_ result: Result<String, Error>) {
                    once.run {
                        listener.cancel()
                        cont.resume(with: result)
                    }
                }
                listener.newConnectionHandler = { conn in
                    conn.start(queue: queue)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        let request = String(decoding: data ?? Data(), as: UTF8.self)
                        let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                        let result: Result<String, Error>
                        do {
                            guard let code = try authorizationCode(in: target, state: state) else {
                                conn.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in conn.cancel() })
                                return
                            }
                            result = .success(code)
                        } catch { result = .failure(error) }
                        let page = (try? result.get()) != nil
                            ? "Signed in. You can close this tab and return to CodeCatch."
                            : "Sign-in was not completed. You can close this tab."
                        let body = "<!doctype html><meta charset=utf-8><title>CodeCatch</title><body style=\"font:15px -apple-system;padding:48px\">\(page)</body>"
                        conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
                                  completion: .contentProcessed { _ in conn.cancel() })
                        finish(result)
                    }
                }
                listener.stateUpdateHandler = { state in
                    if case .failed(let error) = state { finish(.failure(error)) }
                    if case .cancelled = state { finish(.failure(CancellationError())) }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 300) { finish(.failure(Failure.timedOut)) }
            }
        } onCancel: {
            listener.cancel()
        }
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
