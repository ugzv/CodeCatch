import Darwin
import Foundation
import Testing
@testable import CodeCatchCore

/// A client that stops reading must not hold the app's writer: `send` gives up at its deadline,
/// even with a reply far larger than the socket buffer.
@Test func sendGivesUpWhenTheReaderStopsReading() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { close(fds[0]); close(fds[1]) }
    _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
    let started = ContinuousClock.now
    #expect(!LocalSocket.send(String(repeating: "x", count: 4 << 20), to: fds[0], within: 0.3))
    #expect(ContinuousClock.now - started < .seconds(2))
}
