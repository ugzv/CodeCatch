import Darwin
import Foundation
import Security

/// The Unix socket `codecatch` and the app talk over, and who is on the other end of it.
public enum LocalSocket {
    public struct Peer: Sendable {
        public let pid: pid_t
        public let uid: uid_t
        /// The kernel's audit token: unlike a pid, it can't be reused by a later process.
        public let auditToken: Data
    }

    public static func peer(of fd: Int32) -> Peer? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return nil }
        var token = audit_token_t()
        len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return nil }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return Peer(pid: pid, uid: uid, auditToken: withUnsafeBytes(of: &token) { Data($0) })
    }

    /// Nil when the path doesn't fit `sun_path` (104 bytes), as a very long home folder might not.
    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func socket() -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// A connected socket, or nil with `errno` set (ENOENT or ECONNREFUSED: nothing is listening).
    public static func connect(_ path: String) -> Int32? {
        guard var addr = address(path), let fd = socket() else { errno = ENAMETOOLONG; return nil }
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { let e = errno; close(fd); errno = e; return nil }
        return fd
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    /// Listens at `path`, replacing a socket a crashed run left behind. An exclusive lock on `path.lock`,
    /// held for the life of the process, makes one listener the only one that ever binds or removes it.
    public static func listen(_ path: String) throws -> Int32 {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        let lock = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            throw Failure(errorDescription: "Another copy of CodeCatch is answering on \(path).")
        }
        // Kept open on purpose while listening: closing it, or exiting, gives the lock up.
        unlink(path)
        guard var addr = address(path) else { close(lock); throw Failure(errorDescription: "The socket path is too long: \(path)") }
        guard let fd = socket() else { close(lock); throw Failure(errorDescription: String(cString: strerror(errno))) }
        // Created 0600 from the start: no moment where another user could connect.
        let mask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(mask)
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            close(lock)
            throw Failure(errorDescription: message)
        }
        return fd
    }

    /// Writes one JSON line; false when the other side has gone or hasn't taken it within `within`
    /// seconds in all. On a non-blocking socket the wait is a bounded `poll`, so a client that reads
    /// slowly can't hold the writer past the deadline.
    @discardableResult
    public static func send(_ reply: some Encodable, to fd: Int32, within: TimeInterval = 5) -> Bool {
        guard var data = try? AgentWire.encoder.encode(reply) else { return false }
        data.append(0x0A)
        // A monotonic clock, checked before every write: a reader that keeps taking a little at a time
        // can't stretch the deadline, and a clock change can't either.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(within)
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let left = clock.now.duration(to: deadline)
                guard left > .zero else { return false }
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                guard n < 0, errno == EINTR || errno == EAGAIN else { return false }
                var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ms = left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000 + 1
                guard poll(&ready, 1, Int32(clamping: ms)) > 0 else { return false }
            }
            return true
        }
    }

    /// Reads one line, without the newline. Nil at end of stream, past `limit` bytes, or after `within` seconds,
    /// which a client sending a byte at a time would otherwise never reach.
    public static func readLine(from fd: Int32, buffer: inout Data, limit: Int = AgentWire.maxRequest,
                                within: TimeInterval? = nil) -> Data? {
        let clock = ContinuousClock()
        let deadline = within.map { clock.now + .seconds($0) }
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            if let deadline, clock.now > deadline { return nil }
            if let newline = buffer.firstIndex(of: 0x0A) {
                guard newline - buffer.startIndex <= limit else { return nil }
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard buffer.count <= limit else { return nil }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// Who signed a running program. Only valid signatures that chain to Apple count (Developer ID,
/// App Store, Apple's own); ad-hoc or broken ones give nil.
public enum CodeSignature {
    public struct Identity: Equatable, Sendable {
        public let identifier: String
        /// Nil for Apple's own programs, such as Terminal.
        public let team: String?
        /// Where the signed code is, read from the signature check itself, so the two can't come from
        /// different programs (a process can exec another while it is looked at).
        public var path: String? = nil
    }

    public static func of(auditToken: Data) -> Identity? {
        guest([kSecGuestAttributeAudit: auditToken as CFData])
    }

    public static func of(pid: pid_t) -> Identity? {
        guest([kSecGuestAttributePid: NSNumber(value: pid)])
    }

    /// This program's own signer; nil for an unsigned development build.
    public static var current: Identity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return identity(code)
    }

    /// An app bundle's signer, checked on disk: the main executable and its Info.plist against the
    /// signature, though not every resource (VS Code's would take seconds).
    public static func of(bundle url: URL) -> Identity? {
        var code: SecStaticCode?
        guard let appleIssued, SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), appleIssued) == errSecSuccess else { return nil }
        return info(code)
    }

    private static func guest(_ attributes: [CFString: Any]) -> Identity? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess, let code else { return nil }
        return identity(code)
    }

    nonisolated(unsafe) private static let appleIssued: SecRequirement? = {
        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement)
        return requirement
    }()

    private static func identity(_ code: SecCode) -> Identity? {
        guard let appleIssued, SecCodeCheckValidity(code, [], appleIssued) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return info(staticCode)
    }

    private static func info(_ code: SecStaticCode) -> Identity? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let id = dict[kSecCodeInfoIdentifier as String] as? String else { return nil }
        var url: CFURL?
        SecCodeCopyPath(code, [], &url)
        return Identity(identifier: id, team: dict[kSecCodeInfoTeamIdentifier as String] as? String, path: (url as URL?)?.path)
    }
}
