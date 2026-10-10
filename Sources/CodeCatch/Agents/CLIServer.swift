import CodeCatchCore
import Foundation
import os

/// Answers `codecatch` on the local socket: one request per connection, progress lines while it
/// waits, then one result. A client that disconnects cancels its request and takes the card down.
enum CLIServer {
    private static let logger = Logger(subsystem: "com.uros.codecatch", category: "cli")
    nonisolated(unsafe) private static var source: DispatchSourceRead?
    /// Whether this instance holds the socket's lock, and so may remove it.
    nonisolated(unsafe) private static var owner = false
    /// Connections at once; more are closed until one ends.
    private static let slots = DispatchSemaphore(value: 4)

    @MainActor static func start(model: AppModel) {
        let path = AgentWire.socketPath()
        let listener: Int32
        do { listener = try LocalSocket.listen(path) } catch {
            logger.error("CLI socket: \(error.localizedDescription, privacy: .public)")
            return
        }
        owner = true
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .global())
        source.setEventHandler {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard slots.wait(timeout: .now()) == .success else { close(fd); return }
            DispatchQueue.global().async {
                connect(fd, model: model)
            }
        }
        source.setCancelHandler {
            close(listener)
            removeSocket()
        }
        source.resume()
        self.source = source
    }

    /// Removes the socket on quit, so `codecatch` knows the app isn't running.
    static func stop() {
        source?.cancel()
        removeSocket()  // now: the cancel handler may not run before the app exits
    }

    private static func removeSocket() {
        guard owner else { return }
        unlink(AgentWire.socketPath())
    }

    /// Runs on a worker thread and gives its slot back when the connection closes.
    private static func connect(_ fd: Int32, model: AppModel) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Replies are a few small lines; a client that stops reading can't hold the main thread.
        var sendLimit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendLimit, socklen_t(MemoryLayout<timeval>.size))
        var readLimit = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readLimit, socklen_t(MemoryLayout<timeval>.size))
        // Who asked is read at once, before the client has time to exit and leave its pid to another process.
        guard let peer = LocalSocket.peer(of: fd), peer.uid == getuid() else { close(fd); slots.signal(); return }
        // Only the codecatch this team signed, checked by audit token: the walk up from it then starts at a
        // process that can't be swapped. An unsigned development build skips this.
        if let team = CodeSignature.current?.team {
            let client = CodeSignature.of(auditToken: peer.auditToken)
            guard client?.identifier == "com.uros.codecatch.cli", client?.team == team else {
                LocalSocket.send(AgentReply(error: AgentError(.usage, "Use the codecatch tool that comes with CodeCatch.")), to: fd)
                close(fd)
                slots.signal()
                return
            }
        }
        let caller = CallerIdentity.caller(pid: peer.pid)
        logger.debug("Connection from \(caller.logLabel, privacy: .public)")
        // Five seconds in all to say what it wants.
        var buffer = Data()
        guard let line = LocalSocket.readLine(from: fd, buffer: &buffer, within: 5) else {
            close(fd); slots.signal(); return
        }
        guard let request = try? AgentWire.decoder.decode(AgentRequest.self, from: line), request.v <= AgentWire.version else {
            LocalSocket.send(AgentReply(error: AgentError(.usage, "CodeCatch couldn't read the request. Update CodeCatch and try again.")), to: fd)
            close(fd)
            slots.signal()
            return
        }

        // EOF from the client cancels the request. The fd is closed only after the reply is written,
        // so a cancelled request never writes into a number the system has handed to someone else.
        let queue = DispatchQueue(label: "com.uros.codecatch.cli.connection")
        let watch = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // From here writes don't block: `LocalSocket.send` waits with a deadline instead.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // Replies are written on this connection's queue, never the main thread, and before it closes.
        let reply = { (message: AgentReply) in queue.async { LocalSocket.send(message, to: fd) } }
        let task = Task { @MainActor in await serve(request, caller, reply, model) }
        var suspended = false
        watch.setEventHandler {
            var byte: UInt8 = 0
            if recv(fd, &byte, 1, MSG_PEEK) > 0 {
                var drain = [UInt8](repeating: 0, count: 512)
                _ = recv(fd, &drain, drain.count, 0)
                return
            }
            task.cancel()
            watch.suspend()
            suspended = true
        }
        watch.setCancelHandler {
            close(fd)
            slots.signal()
        }
        watch.resume()
        Task {
            await task.value
            queue.async {
                if suspended { watch.resume() }
                watch.cancel()
            }
        }
    }

    @MainActor private static func serve(_ request: AgentRequest, _ caller: AgentCaller, _ reply: @escaping (AgentReply) -> Void,
                                         _ model: AppModel) async {
        switch request.command {
        case .status:
            reply(AgentReply(status: model.agentStatus))
        case .get:
            guard let site = request.site, SiteQuery(site) != nil else {
                return reply(AgentReply(error: AgentError(.usage, "Name the site, such as github.com.")))
            }
            let result = await model.agents.get(site: site, since: request.since, timeout: request.timeout, caller: caller) { note in
                reply(AgentReply(progress: note))
            }
            switch result {
            case .success(let item): reply(AgentReply(item: AgentAccess.wire(item)))
            case .failure(let error): reply(AgentReply(error: error))
            }
        }
    }
}
