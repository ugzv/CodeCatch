import Foundation
import Network

enum IMAPError: LocalizedError {
    case closed, timeout, invalidPort, invalidCredentials, invalidResponse, rejected(String)
    var errorDescription: String? {
        switch self {
        case .closed: "Connection closed"
        case .timeout: "Server stopped responding"
        case .invalidPort: "The IMAP port must be between 1 and 65535"
        case .invalidCredentials: "The IMAP credentials contain unsupported control characters"
        case .invalidResponse: "The mail server sent an invalid or oversized response"
        case .rejected: "The mail server rejected the request"
        }
    }
}

/// A minimal IMAP4rev1 client over TLS: tagged commands, literals, and IDLE.
actor IMAPConnection {
    struct Response {
        var text: String
        var literals: [Data]

        static func literalSize(in line: String) throws -> Int? {
            guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
            guard let count = Int(line[line.index(after: open)..<line.index(before: line.endIndex)]),
                  (0...262_144).contains(count) else { throw IMAPError.invalidResponse }
            return count
        }

        /// The number following `marker`, e.g. "UIDNEXT " in `* OK [UIDNEXT 4392]`.
        func number(after marker: String) -> Int? {
            guard let r = text.range(of: marker) else { return nil }
            return Int(text[r.upperBound...].prefix(while: \.isNumber))
        }
    }

    private let connection: NWConnection
    private var buffer = Data()
    /// A `* n EXISTS` seen outside IDLE (inside a SEARCH/FETCH reply): new mail the next idle() must not wait for.
    private var pendingExists = false
    private var tag = 0
    private(set) var capabilities: Set<String> = []
    var uidValidity: Int?

    init(host: String, port: Int) throws {
        guard (1...65535).contains(port) else { throw IMAPError.invalidPort }
        connection = NWConnection(host: .init(host), port: .init(integerLiteral: UInt16(port)), using: .tls)
    }

    enum Auth { case password(String), accessToken(String) }

    func open(user: String, auth: Auth) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e), .waiting(let e): once.run { cont.resume(throwing: e) }
                case .cancelled: once.run { cont.resume(throwing: IMAPError.closed) }
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "imap"))
        }
        _ = try await withTimeout(20) { try await self.readResponse() }  // greeting
        switch auth {
        case .password(let password):
            _ = try await command("LOGIN \(quote(user)) \(quote(password))")
        case .accessToken(let token):
            try await xoauth2(user: user, token: token)
        }
        let caps = try await command("CAPABILITY")
        capabilities = Set(caps.flatMap { $0.text.uppercased().split(separator: " ").map(String.init) })
    }

    func close() { connection.cancel() }

    /// SASL XOAUTH2 with the initial response inline. On failure Gmail sends a "+"
    /// challenge carrying the error; an empty reply then gets the tagged NO.
    private func xoauth2(user: String, token: String) async throws {
        tag += 1
        let t = "C\(tag)"
        let payload = Data("user=\(user)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
        try await send("\(t) AUTHENTICATE XOAUTH2 \(payload)\r\n")
        try await withTimeout(30) {
            while true {
                let r = try await self.readResponse()
                if r.text.hasPrefix("+") { try await self.send("\r\n"); continue }
                if r.text.hasPrefix(t + " ") {
                    guard r.text.dropFirst(t.count + 1).hasPrefix("OK") else { throw IMAPError.rejected(r.text) }
                    return
                }
            }
        }
    }

    /// Runs one command and returns its untagged responses; throws on NO/BAD.
    @discardableResult
    func command(_ cmd: String, timeout: TimeInterval = 30) async throws -> [Response] {
        tag += 1
        let t = "C\(tag)"
        try await send("\(t) \(cmd)\r\n")
        return try await withTimeout(timeout) { try await self.readUntilTagged(t) }
    }

    /// Waits in IDLE until the mailbox reports new mail or `renewAfter` elapses.
    func idle(renewAfter: TimeInterval = 540) async throws {
        tag += 1
        let t = "C\(tag)"
        if pendingExists { pendingExists = false; return }
        try await send("\(t) IDLE\r\n")
        while !(try await withTimeout(30, { try await self.readResponse() }).text.hasPrefix("+")) {}
        let renew = Task { [weak self] in
            try await Task.sleep(for: .seconds(renewAfter))
            try await self?.send("DONE\r\n")
            try await Task.sleep(for: .seconds(30))
            await self?.expire()  // no reply to DONE: the connection is dead
        }
        defer { renew.cancel() }
        while true {
            let r = try await readResponse()
            if r.text.hasPrefix(t + " ") { return }
            if pendingExists {
                pendingExists = false
                renew.cancel()
                try await send("DONE\r\n")
                _ = try await withTimeout(30) { try await self.readUntilTagged(t) }
                return
            }
        }
    }

    // MARK: - Wire

    private func readUntilTagged(_ t: String) async throws -> [Response] {
        var out: [Response] = []
        var bytes = 0
        while true {
            let r = try await readResponse()
            if r.text.hasPrefix(t + " ") {
                guard r.text.dropFirst(t.count + 1).hasPrefix("OK") else { throw IMAPError.rejected(r.text) }
                return out
            }
            bytes += r.text.utf8.count + r.literals.reduce(0) { $0 + $1.count }
            guard out.count < 1_000, bytes <= 128 * 1024 * 1024 else { throw IMAPError.invalidResponse }
            out.append(r)
        }
    }

    private func readResponse() async throws -> Response {
        var r = Response(text: "", literals: [])
        while true {
            let line = String(decoding: try await readLine(), as: UTF8.self)
            r.text += line
            guard r.text.utf8.count + r.literals.reduce(0, { $0 + $1.count }) <= 1_048_576 else { throw IMAPError.invalidResponse }
            if line.hasPrefix("* "), line.hasSuffix(" EXISTS") { pendingExists = true }
            guard let n = try Response.literalSize(in: line) else { return r }
            r.literals.append(try await read(count: n))
        }
    }

    private func readLine() async throws -> Data {
        while true {
            if let i = buffer.firstRange(of: Data("\r\n".utf8)) {
                guard i.lowerBound - buffer.startIndex <= 1_048_576 else { throw IMAPError.invalidResponse }
                let line = buffer[buffer.startIndex..<i.lowerBound]
                buffer = Data(buffer[i.upperBound...])
                return Data(line)
            }
            guard buffer.count <= 1_048_576 else { throw IMAPError.invalidResponse }
            try await fill()
        }
    }

    private func read(count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let out = buffer.prefix(count)
        buffer = Data(buffer.dropFirst(count))
        return Data(out)
    }

    private func fill() async throws {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if complete { cont.resume(throwing: IMAPError.closed) }
                else { cont.resume(returning: Data()) }
            }
        }
        buffer.append(data)
    }

    private func send(_ s: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(s.utf8), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: .seconds(seconds))
            await self?.expire()
        }
        defer { watchdog.cancel() }
        do { return try await body() } catch { throw timedOut ? IMAPError.timeout : error }
    }

    private var timedOut = false
    private func expire() { timedOut = true; close() }

    func quote(_ s: String) throws -> String {
        guard !s.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else { throw IMAPError.invalidCredentials }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
