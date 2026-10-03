import CodeCatchCore
import Foundation

/// Imports through the official Bitwarden CLI (`bw`). Its decrypted response is
/// transient; only VaultCode fields are retained. Secrets use the environment,
/// never command arguments. This does not protect against process inspection.
enum BitwardenCLI {
    struct Status: Equatable {
        /// nil: `bw` isn't installed (or not on the login shell's PATH).
        var version: String?
        var server = "https://bitwarden.com"
        var email: String?
        /// "unauthenticated", "locked" or "unlocked".
        var state = "unauthenticated"

        var region: Region? { Region.allCases.first { server.contains($0.domain) } }
        var loggedIn: Bool { state != "unauthenticated" }
    }

    enum Region: String, CaseIterable, Identifiable {
        case us = "US", eu = "EU"
        var id: Self { self }
        var domain: String { self == .us ? "bitwarden.com" : "bitwarden.eu" }
        var server: String { "https://vault.\(domain)" }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func status() async -> Status {
        guard let version = try? await run(["--version"]) else { return Status() }
        var status = Status(version: String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        if let data = try? await run(["status"]), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let server = json["serverUrl"] as? String { status.server = server }
            status.email = json["userEmail"] as? String
            status.state = json["status"] as? String ?? status.state
        }
        return status
    }

    /// Only while logged out: `bw` refuses to switch servers under a signed-in account.
    static func setServer(_ region: Region) async throws {
        _ = try await run(["config", "server", region.server])
    }

    /// Unlocks with the master password, or uses a session from `bw unlock --raw`;
    /// syncs, and returns the logins with a TOTP. A vault that was locked is locked
    /// again, and neither the password nor the session is kept.
    static func importCodes(password: String, session pasted: String) async throws -> [VaultCode] {
        var session = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasLocked = await status().state != "unlocked"
        if session.isEmpty {
            let raw = try await run(["unlock", "--passwordenv", "CODECATCH_BW_PASSWORD", "--raw"], env: ["CODECATCH_BW_PASSWORD": password])
            session = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let unlockedHere = pasted.isEmpty && wasLocked
        do {
            _ = try await run(["sync"], env: ["BW_SESSION": session])
            let items = try await run(["list", "items"], env: ["BW_SESSION": session], timeout: 120)
            if unlockedHere { _ = try? await run(["lock"]) }
            return try VaultCode.fromBitwarden(items)
        } catch {
            if unlockedHere { _ = try? await run(["lock"]) }
            throw error
        }
    }

    // MARK: - Running bw

    /// Apps opened from the Dock get a bare PATH; `bw` and the Node it runs on live
    /// wherever Homebrew or npm put them, which the login shell knows.
    private static let path: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        guard let out = try? execute(shell, ["-l", "-c", "printf %s \"$PATH\""], env: [:], timeout: 10),
              out.status == 0, !out.stdout.isEmpty else { return fallback }
        return String(decoding: out.stdout, as: UTF8.self) + ":" + fallback
    }()

    private static func run(_ args: [String], env: [String: String] = [:], timeout: TimeInterval = 60) async throws -> Data {
        try await Task.detached {
            let out = try execute("/usr/bin/env", ["bw"] + args + ["--nointeraction"], env: env.merging(["PATH": path]) { $1 }, timeout: timeout)
            guard out.status == 0 else {
                let message = String(decoding: out.stderr.isEmpty ? out.stdout : out.stderr, as: UTF8.self)
                    .split(separator: "\n").first.map(String.init) ?? "bw exited with \(out.status)"
                throw Failure(errorDescription: out.status == 127 ? "Bitwarden CLI not found" : message)
            }
            return out.stdout
        }.value
    }

    private static func execute(_ tool: String, _ args: [String], env: [String: String],
                                timeout: TimeInterval) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let stdout = Pipe(), stderr = Pipe()
        (process.standardOutput, process.standardError, process.standardInput) = (stdout, stderr, FileHandle.nullDevice)
        try process.run()
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Drain both pipes at once: a full stderr would otherwise stall a large stdout.
        var errData = Data()
        let drained = DispatchGroup()
        DispatchQueue.global().async(group: drained) { errData = stderr.fileHandleForReading.readDataToEndOfFile() }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, outData, errData)
    }
}
