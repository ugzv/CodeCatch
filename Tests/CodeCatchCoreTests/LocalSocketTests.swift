import Darwin
import Foundation
import Testing

@testable import CodeCatchCore

/// A client that stops reading must not hold the app's writer: `send` gives up at its deadline,
/// even with a reply far larger than the socket buffer.
@Test func sendGivesUpWhenTheReaderStopsReading() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer {
        close(fds[0])
        close(fds[1])
    }
    _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
    let started = ContinuousClock.now
    #expect(!LocalSocket.send(String(repeating: "x", count: 4 << 20), to: fds[0], within: 0.3))
    #expect(ContinuousClock.now - started < .seconds(2))
}

/// The app reads requests with a short socket timeout and a longer deadline: a client that pauses
/// longer than the timeout, but within the deadline, must still be heard.
@Test func readLineWaitsOutSocketTimeoutsUntilItsDeadline() throws {
    var fds: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer {
        close(fds[0])
        close(fds[1])
    }
    var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
    try #require(setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
    let writer = fds[1]
    let wrote = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
        _ = write(writer, "hello\n", 6)
        wrote.signal()
    }
    // Runs before the close above: the late write must not land on a reused descriptor.
    defer { wrote.wait() }
    var buffer = Data()
    // A deadline far past the write: on a busy machine the writer above can start seconds late.
    #expect(LocalSocket.readLine(from: fds[0], buffer: &buffer, within: 30) == Data("hello".utf8))
}
