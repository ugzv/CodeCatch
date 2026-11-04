import Foundation
import Network
import Testing

@testable import CodeCatch

struct IMAPInputTests {
    @Test(arguments: [true, false])
    func newMailBeforeOrAfterIdleContinuationDoesNotWaitForRenewal(_ beforeContinuation: Bool) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = AsyncThrowingStream<Void, Error>.makeStream()
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.continuation.yield(())
                ready.continuation.finish()
            case .failed(let error): ready.continuation.finish(throwing: error)
            default: break
            }
        }
        listener.newConnectionHandler = {
            accepted.continuation.yield($0)
            accepted.continuation.finish()
        }
        listener.start(queue: DispatchQueue(label: "imap-test-listener"))
        defer { listener.cancel() }
        for try await _ in ready.stream { break }
        let port = try #require(listener.port)
        let client = IMAPConnection(connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        let server = Task {
            for await connection in accepted.stream {
                connection.start(queue: DispatchQueue(label: "imap-test-server"))
                defer { connection.cancel() }
                let wire = IMAPTestWire(connection: connection)
                try await wire.send("* OK ready\r\n")
                #expect(try await wire.line() == "C1 LOGIN \"test\" \"test\"")
                try await wire.send("C1 OK authenticated\r\n")
                #expect(try await wire.line() == "C2 CAPABILITY")
                try await wire.send("* CAPABILITY IMAP4rev1 IDLE\r\nC2 OK capability\r\n")
                #expect(try await wire.line() == "C3 IDLE")
                try await wire.send(
                    beforeContinuation
                        ? "* 1 EXISTS\r\n+ idling\r\n" : "+ idling\r\n* 1 EXISTS\r\n")
                #expect(try await wire.line() == "DONE")
                try await wire.send("C3 OK idle ended\r\n")
                return
            }
        }
        // A missed notification used to block until renewal (nine minutes in production).
        let deadline = Task {
            try await Task.sleep(for: .seconds(3))
            await client.close()
        }
        defer { deadline.cancel() }
        do {
            try await client.open(user: "test", password: "test")
            try await client.idle(renewAfter: 60)
            try await server.value
            await client.close()
        } catch {
            await client.close()
            _ = await server.result
            throw error
        }
    }

    @Test func invalidPortsCannotCreateConnections() {
        for port in [-1, 0, 65_536, Int.max] {
            #expect(throws: (any Error).self) {
                try IMAPConnection(host: "example.invalid", port: port)
            }
        }
    }

    @Test func quotingPreservesCredentialsAndEscapesDelimiters() async throws {
        let connection = try IMAPConnection(host: "example.invalid", port: 993)
        let cases = [
            ("", "\"\""),
            ("user name", "\"user name\""),
            ("Uroš 🔑", "\"Uroš 🔑\""),
            ("a\"b\\c", "\"a\\\"b\\\\c\""),
        ]
        for (input, expected) in cases {
            #expect(try await connection.quote(input) == expected)
        }
    }

    @Test func credentialControlsCannotInjectIMAPCommands() async throws {
        let connection = try IMAPConnection(host: "example.invalid", port: 993)
        for input in ["user\rLOGOUT", "user\nLOGOUT", "user\0LOGOUT"] {
            await #expect(throws: (any Error).self) {
                try await connection.quote(input)
            }
        }
    }

    @Test(arguments: [0, 1, 262_144])
    func boundedLiteralLengthsAreAccepted(_ size: Int) throws {
        #expect(try IMAPConnection.Response.literalSize(in: "* 1 FETCH (BODY[] {\(size)}") == size)
    }

    @Test(arguments: ["tag OK completed", "* 1 FETCH (UID 42)", "* OK {12} ready"])
    func ordinaryResponseLinesDoNotStartLiteralReads(_ line: String) throws {
        #expect(try IMAPConnection.Response.literalSize(in: line) == nil)
    }

    @Test(arguments: ["-1", "262145", "999999999999999999999999999999", "nonsense"])
    func unsafeLiteralLengthsCannotAllocateBuffers(_ value: String) {
        #expect(throws: (any Error).self) {
            try IMAPConnection.Response.literalSize(in: "* 1 FETCH (BODY[] {\(value)}")
        }
    }

    @Test(arguments: ["private-password-123", "private-message-456"])
    func rejectedResponseErrorsDoNotExposeServerContent(_ token: String) {
        let error = IMAPError.rejected("tag NO \(token)")
        #expect(!error.localizedDescription.contains(token))
    }

    // MARK: - ID (RFC 2971)

    @Test func identificationNamesCodeCatchAtItsOwnVersion() throws {
        #expect(
            IMAPIdentification.command(capabilities: ["IMAP4REV1", "ID"], version: "2.0 (417)")
                == #"ID ("name" "CodeCatch" "version" "2.0 (417)" "vendor" "CodeCatch")"#)
    }

    @Test(arguments: [Set<String>(), ["IMAP4rev1"], ["IMAP4rev1", "IDLE"]])
    func serversThatDoNotAdvertiseIDAreNotSentIt(_ capabilities: Set<String>) {
        #expect(IMAPIdentification.command(capabilities: capabilities) == nil)
    }

    @Test func identificationValuesAreQuotedAndBounded() {
        #expect(IMAPIdentification.quoted(##"a"b\c"##) == #""a\"b\\c""#)
        #expect(IMAPIdentification.quoted("two\r\nlines") == #""twolines""#)
        #expect(IMAPIdentification.quoted(String(repeating: "x", count: 2000)).count == 1026)
    }

    @Test func identificationIsSentAfterLoginAndBeforeTheMailbox() async throws {
        let id = try #require(IMAPIdentification.command(capabilities: ["ID"]))
        #expect(id.hasPrefix(#"ID ("name" "CodeCatch" "version" "#))
        try await withScriptedServer([
            ("C1 LOGIN \"test\" \"test\"", "C1 OK authenticated\r\n"),
            ("C2 CAPABILITY", "* CAPABILITY IMAP4rev1 XLIST ID LITERAL+\r\nC2 OK capability\r\n"),
            ("C3 " + id, "* ID (\"name\" \"Coremail\")\r\nC3 OK ID completed\r\n"),
            ("C4 EXAMINE INBOX", "* OK [UIDVALIDITY 7] UIDs valid\r\nC4 OK [READ-ONLY] examined\r\n"),
        ]) { client in
            try await client.open(user: "test", password: "test")
            let examine = try await client.command("EXAMINE INBOX")
            #expect(examine.compactMap { $0.number(after: "UIDVALIDITY ") } == [7])
        }
    }

    @Test func identificationIsNotSentWhenTheServerDoesNotOfferIt() async throws {
        try await withScriptedServer([
            ("C1 LOGIN \"test\" \"test\"", "C1 OK authenticated\r\n"),
            ("C2 CAPABILITY", "* CAPABILITY IMAP4rev1 IDLE\r\nC2 OK capability\r\n"),
            ("C3 EXAMINE INBOX", "* OK [UIDVALIDITY 7] UIDs valid\r\nC3 OK [READ-ONLY] examined\r\n"),
        ]) { client in
            try await client.open(user: "test", password: "test")
            try await client.command("EXAMINE INBOX")
        }
    }

    @Test(arguments: ["* ID NIL\r\nC3 OK ID completed\r\n", "* ID (\"name\" \"Coremail\")\r\nC3 OK ID completed\r\n", "C3 OK ID completed\r\n"])
    func identificationAnswersAreAllAccepted(_ answer: String) async throws {
        let id = try #require(IMAPIdentification.command(capabilities: ["ID"]))
        try await withScriptedServer([
            ("C1 LOGIN \"test\" \"test\"", "C1 OK authenticated\r\n"),
            ("C2 CAPABILITY", "* CAPABILITY IMAP4rev1 ID\r\nC2 OK capability\r\n"),
            ("C3 " + id, answer),
            ("C4 EXAMINE INBOX", "C4 OK [READ-ONLY] examined\r\n"),
        ]) { client in
            try await client.open(user: "test", password: "test")
            try await client.command("EXAMINE INBOX")
        }
    }

    @Test(arguments: ["NO", "BAD"])
    func aRefusedIdentificationDoesNotEndTheSession(_ status: String) async throws {
        let id = try #require(IMAPIdentification.command(capabilities: ["ID"]))
        try await withScriptedServer([
            ("C1 LOGIN \"test\" \"test\"", "C1 OK authenticated\r\n"),
            ("C2 CAPABILITY", "* CAPABILITY IMAP4rev1 ID\r\nC2 OK capability\r\n"),
            ("C3 " + id, "C3 \(status) ID unsupported\r\n"),
            ("C4 EXAMINE INBOX", "C4 OK [READ-ONLY] examined\r\n"),
        ]) { client in
            try await client.open(user: "test", password: "test")
            try await client.command("EXAMINE INBOX")
        }
    }
}

/// A loopback IMAP server for one session: it greets, then for each step records the client's
/// line, checks it against the script, and sends the reply. `body` drives the client through them.
private func withScriptedServer(
    _ steps: [(line: String, reply: String)],
    _ body: @escaping @Sendable (IMAPConnection) async throws -> Void
) async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let ready = AsyncThrowingStream<Void, Error>.makeStream()
    let accepted = AsyncStream<NWConnection>.makeStream()
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            ready.continuation.yield(())
            ready.continuation.finish()
        case .failed(let error): ready.continuation.finish(throwing: error)
        default: break
        }
    }
    listener.newConnectionHandler = {
        accepted.continuation.yield($0)
        accepted.continuation.finish()
    }
    listener.start(queue: DispatchQueue(label: "imap-test-listener"))
    defer { listener.cancel() }
    for try await _ in ready.stream { break }
    let port = try #require(listener.port)
    let client = IMAPConnection(connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp))
    let server = Task {
        for await connection in accepted.stream {
            connection.start(queue: DispatchQueue(label: "imap-test-server"))
            defer { connection.cancel() }
            let wire = IMAPTestWire(connection: connection)
            try await wire.send("* OK ready\r\n")
            for step in steps {
                let line = try await wire.line()
                #expect(line == step.line)
                try await wire.send(step.reply)
            }
            return
        }
    }
    do {
        try await body(client)
        try await server.value
    } catch {
        await client.close()
        _ = await server.result
        throw error
    }
    await client.close()
}

private actor IMAPTestWire {
    let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) { self.connection = connection }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8),
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    func line() async throws -> String {
        while true {
            if let end = buffer.firstRange(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<end.upperBound)
                return line
            }
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: IMAPError.closed)
                    }
                }
            }
            buffer.append(data)
        }
    }
}
