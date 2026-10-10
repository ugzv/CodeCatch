import Foundation
import Testing
@testable import CodeCatch

/// The `codecatch` skill file in coding agents' own folders: CodeCatch writes into another app's
/// configuration, so it must only ever change or remove a file it wrote itself.
@Suite struct AgentSkillTests {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("skills-\(UUID())")
    let foreign = "---\nname: codecatch\ndescription: the user's own skill\n---\nhand written\n"

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func read(_ agent: AgentSkill) throws -> String {
        try String(contentsOf: agent.file(home: home), encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func putForeignFile(for agent: AgentSkill) throws {
        let file = agent.file(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(foreign.utf8).write(to: file)
    }

    /// Settings would offer to connect an agent that isn't there, or hide one that is.
    @Test(arguments: [(AgentSkill.claudeCode, ".claude"), (.codex, ".codex"), (.cursor, ".cursor")])
    func isInstalledOnceItsFolderExists(agent: AgentSkill, folder: String) throws {
        #expect(!agent.isInstalled(home: home))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: false)
        #expect(agent.isInstalled(home: home))
    }

    /// The skill lands somewhere the agent doesn't look.
    @Test(arguments: [(AgentSkill.claudeCode, ".claude"), (.codex, ".codex"), (.cursor, ".cursor")])
    func fileLivesInTheAgentsSkillsFolder(agent: AgentSkill, folder: String) {
        #expect(agent.file(home: home).standardizedFileURL
            == home.appendingPathComponent("\(folder)/skills/codecatch/SKILL.md").standardizedFileURL)
    }

    /// The agent ignores a skill without front matter, a name and a description, or never sees the guidance.
    @Test(arguments: AgentSkill.allCases)
    func connectWritesAValidSkill(agent: AgentSkill) throws {
        #expect(agent.state(home: home) == .notConnected)
        try agent.connect(home: home, guidance: "GUIDANCE-MARKER")
        #expect(try read(agent) == AgentSkill.skill("GUIDANCE-MARKER"))
        #expect(agent.state(home: home) == .connected)

        let content = AgentSkill.skill("GUIDANCE-MARKER")
        let lines = content.components(separatedBy: "\n")
        #expect(lines.first == "---")
        let end = try #require(lines.dropFirst().firstIndex(of: "---"))
        let front = lines[1..<end].map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(front.contains("name: codecatch"))
        let description = front.first { $0.hasPrefix("description:") }?.dropFirst("description:".count)
        #expect(!(description ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).isEmpty)
        #expect(content.contains("GUIDANCE-MARKER"))
    }

    /// Overwriting or deleting a skill the user (or another tool) wrote at the same path.
    @Test(arguments: AgentSkill.allCases)
    func neverTouchesAFileItDidNotWrite(agent: AgentSkill) throws {
        try putForeignFile(for: agent)
        #expect(agent.state(home: home) == .taken)

        #expect(throws: AgentSkill.Failure.self) { try agent.connect(home: home, guidance: "g") }
        #expect(try read(agent) == foreign)

        try? agent.disconnect(home: home)
        #expect(try read(agent) == foreign)

        AgentSkill.refresh(home: home, guidance: "g")
        #expect(try read(agent) == foreign)
        #expect(agent.state(home: home) == .taken)
    }

    /// Following a symlink at the skill path and overwriting or deleting the file (or link) it points to;
    /// or, for a dangling link, calling it "not connected" and writing through it or replacing it.
    @Test(arguments: AgentSkill.allCases, [false, true])
    func neverTouchesASymlinkEvenToItsOwnFile(agent: AgentSkill, dangling: Bool) throws {
        let fm = FileManager.default
        let otherHome = home.appendingPathComponent("other-home")
        try fm.createDirectory(at: otherHome, withIntermediateDirectories: true)
        let target: URL
        if dangling {
            target = otherHome.appendingPathComponent("nowhere/SKILL.md")
        } else {
            try agent.connect(home: otherHome, guidance: "old")
            target = agent.file(home: otherHome)
        }
        let link = agent.file(home: home)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        func unchanged() throws {
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
            if dangling {
                #expect(!exists(target))
            } else {
                #expect(try String(contentsOf: target, encoding: .utf8) == AgentSkill.skill("old"))
            }
        }

        #expect(agent.state(home: home) == .taken)
        #expect(throws: AgentSkill.Failure.self) { try agent.connect(home: home, guidance: "new") }
        try unchanged()
        try? agent.disconnect(home: home)
        try unchanged()
        AgentSkill.refresh(home: home, guidance: "new")
        try unchanged()
        #expect(agent.state(home: home) == .taken)
    }

    /// Reading a FIFO at the skill path blocks forever with no writer, freezing the app, or replaces it.
    @Test(.timeLimit(.minutes(1)), arguments: AgentSkill.allCases)
    func fifoAtTheSkillPathIsTakenAndNeverBlocks(agent: AgentSkill) throws {
        let file = agent.file(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(file.path, 0o600) == 0)

        func isFIFO() -> Bool {
            var info = stat()
            return lstat(file.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
        }
        let clock = ContinuousClock()
        let limit = Duration.milliseconds(500)

        var state: AgentSkill.State?
        #expect(clock.measure { state = agent.state(home: home) } < limit)
        #expect(state == .taken)
        #expect(clock.measure {
            #expect(throws: AgentSkill.Failure.self) { try agent.connect(home: home, guidance: "g") }
        } < limit)
        #expect(isFIFO())
        #expect(clock.measure { try? agent.disconnect(home: home) } < limit)
        #expect(isFIFO())
        #expect(clock.measure { AgentSkill.refresh(home: home, guidance: "g") } < limit)
        #expect(isFIFO())
    }

    /// Disconnect leaves CodeCatch's file, a leftover temp file or an empty folder behind in the agent's config.
    @Test(arguments: AgentSkill.allCases)
    func disconnectRemovesItsFileAndEmptyFolder(agent: AgentSkill) throws {
        try agent.connect(home: home, guidance: "old")
        try agent.connect(home: home, guidance: "new")
        AgentSkill.refresh(home: home, guidance: "newer")
        try agent.disconnect(home: home)
        #expect(!exists(agent.file(home: home)))
        #expect(!exists(agent.file(home: home).deletingLastPathComponent()))
        #expect(agent.state(home: home) == .notConnected)
    }

    /// Disconnect deletes the user's other files that share the `codecatch` folder, or leaves hidden temp files there.
    @Test(arguments: AgentSkill.allCases)
    func disconnectKeepsOtherFilesInTheFolder(agent: AgentSkill) throws {
        try agent.connect(home: home, guidance: "g")
        let folder = agent.file(home: home).deletingLastPathComponent()
        let other = folder.appendingPathComponent("notes.md")
        try Data("mine".utf8).write(to: other)
        try agent.connect(home: home, guidance: "new")
        AgentSkill.refresh(home: home, guidance: "newer")

        try agent.disconnect(home: home)
        #expect(!exists(agent.file(home: home)))
        #expect(try String(contentsOf: other, encoding: .utf8) == "mine")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["notes.md"])
        #expect(agent.state(home: home) == .notConnected)
    }

    /// Connecting again fails as "taken", or leaves the old guidance in place after an update.
    @Test(arguments: AgentSkill.allCases)
    func connectAgainReplacesItsOwnContent(agent: AgentSkill) throws {
        try agent.connect(home: home, guidance: "old")
        try agent.connect(home: home, guidance: "old")
        #expect(agent.state(home: home) == .connected)

        try agent.connect(home: home, guidance: "new")
        #expect(try read(agent) == AgentSkill.skill("new"))
        #expect(agent.state(home: home) == .connected)
    }

    /// Agents keep stale guidance after CodeCatch updates it.
    @Test(arguments: AgentSkill.allCases)
    func refreshRewritesItsOwnStaleFile(agent: AgentSkill) throws {
        try agent.connect(home: home, guidance: "old")
        AgentSkill.refresh(home: home, guidance: "new")
        #expect(try read(agent) == AgentSkill.skill("new"))
        #expect(agent.state(home: home) == .connected)
    }

    /// Refresh connects an agent the user never connected.
    @Test func refreshCreatesNothingForUnconnectedAgents() throws {
        for folder in [".claude", ".codex", ".cursor"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        AgentSkill.refresh(home: home, guidance: "g")
        for agent in AgentSkill.allCases {
            #expect(!exists(agent.file(home: home)))
            #expect(agent.state(home: home) == .notConnected)
        }
    }

    /// Cursor shows "not connected" for a skill it already reads, inviting a duplicate.
    @Test(arguments: [AgentSkill.claudeCode, .codex])
    func cursorIsConnectedThroughAnotherAgent(source: AgentSkill) throws {
        try source.connect(home: home, guidance: "g")
        #expect(AgentSkill.cursor.state(home: home) == .connectedThrough(source))
        #expect(!exists(AgentSkill.cursor.file(home: home)))
    }

    /// Cursor loads the skill twice after the user connects Cursor first, then Claude Code or Codex.
    @Test(arguments: [AgentSkill.claudeCode, .codex])
    func connectingAnotherAgentRemovesCursorsDuplicate(source: AgentSkill) throws {
        try AgentSkill.cursor.connect(home: home, guidance: "g")
        try source.connect(home: home, guidance: "g")
        #expect(!exists(AgentSkill.cursor.file(home: home)))
        #expect(AgentSkill.cursor.state(home: home) == .connectedThrough(source))
    }

    /// Removing the user's own skill in Cursor's folder while clearing CodeCatch's duplicate.
    @Test(arguments: [AgentSkill.claudeCode, .codex])
    func duplicateCleanupKeepsAForeignCursorFile(source: AgentSkill) throws {
        try putForeignFile(for: .cursor)
        try source.connect(home: home, guidance: "g")
        #expect(try read(.cursor) == foreign)
        AgentSkill.refresh(home: home, guidance: "new")
        #expect(try read(.cursor) == foreign)
    }

    /// Refresh gives Cursor its own copy next to the one it already reads through Claude Code or Codex,
    /// or keeps a copy left in Cursor's folder from before.
    @Test(arguments: [AgentSkill.claudeCode, .codex], [false, true])
    func refreshGivesCursorNoDuplicate(source: AgentSkill, staleCursorCopy: Bool) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: false)
        try source.connect(home: home, guidance: "old")
        if staleCursorCopy {
            let file = AgentSkill.cursor.file(home: home)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(AgentSkill.skill("old").utf8).write(to: file)
        }
        AgentSkill.refresh(home: home, guidance: "new")
        #expect(!exists(AgentSkill.cursor.file(home: home)))
        #expect(AgentSkill.cursor.state(home: home) == .connectedThrough(source))
    }

    /// Cursor claims to be connected through a skill CodeCatch didn't write, or with no skill at all.
    @Test(arguments: [AgentSkill.claudeCode, .codex])
    func foreignSkillDoesNotConnectCursor(source: AgentSkill) throws {
        #expect(AgentSkill.cursor.state(home: home) == .notConnected)
        try putForeignFile(for: source)
        #expect(AgentSkill.cursor.state(home: home) == .notConnected)
    }

    /// Claude Code or Codex reports a connection it doesn't have, since neither reads other agents' skills.
    @Test(arguments: [AgentSkill.claudeCode, .codex])
    func onlyCursorIsConnectedThrough(agent: AgentSkill) throws {
        for other in AgentSkill.allCases where other != agent {
            try other.connect(home: home, guidance: "g")
        }
        #expect(agent.state(home: home) == .notConnected)
    }
}
