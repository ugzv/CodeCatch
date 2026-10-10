import Foundation
import Testing
@testable import CodeCatch

/// The /usr/local/bin link: Install, Repair and Remove must only ever touch CodeCatch's own link,
/// never a program the user put there, even if it appeared after Settings looked.
@Suite struct CommandLineToolTests {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cli-\(UUID())")
    var link: URL { folder.appendingPathComponent("bin/codecatch") }
    var helper: URL { folder.appendingPathComponent("CodeCatch.app/Contents/Helpers/codecatch") }

    init() throws {
        let files = FileManager.default
        try files.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }

    private func state() -> CommandLineTool.State {
        CommandLineTool.state(link: link, helper: helper, app: folder.appendingPathComponent("CodeCatch.app").path)
    }

    @Test func installsRemovesAndRepairsOnlyItsOwnLink() throws {
        #expect(state() == .notInstalled)
        try CommandLineTool.install(over: state(), link: link, helper: helper)
        #expect(state() == .installed)
        try CommandLineTool.remove(state(), link: link, helper: helper)
        #expect(state() == .notInstalled)

        let moved = "/Applications/Old/CodeCatch.app/Contents/Helpers/codecatch"
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: moved)
        #expect(state() == .stale(target: moved))
        try CommandLineTool.install(over: state(), link: link, helper: helper)
        #expect(state() == .installed)
    }

    @Test func leavesSomeoneElsesProgramAlone() throws {
        FileManager.default.createFile(atPath: link.path, contents: Data("other".utf8))
        #expect(state() == .taken)
        try CommandLineTool.remove(state(), link: link, helper: helper)
        try CommandLineTool.install(over: state(), link: link, helper: helper)
        #expect(try String(contentsOf: link, encoding: .utf8) == "other")
    }

    /// A file or a folder that appeared after Settings looked stays as it was: `ln` would have written
    /// a link inside a folder.
    @Test(arguments: [false, true])
    func doesNotTouchWhatAppearedAfterTheCheck(folderAppeared: Bool) throws {
        let checked = state()
        #expect(checked == .notInstalled)
        if folderAppeared {
            try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        } else {
            FileManager.default.createFile(atPath: link.path, contents: Data("other".utf8))
        }
        #expect(throws: CommandLineTool.Failure.self) { try CommandLineTool.install(over: checked, link: link, helper: helper) }
        if folderAppeared {
            #expect(try FileManager.default.contentsOfDirectory(atPath: link.path).isEmpty)
        } else {
            #expect(try String(contentsOf: link, encoding: .utf8) == "other")
        }
    }
}
