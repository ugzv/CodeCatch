import Foundation
import Testing
@testable import CodeCatch

struct IMAPInputTests {
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
}
