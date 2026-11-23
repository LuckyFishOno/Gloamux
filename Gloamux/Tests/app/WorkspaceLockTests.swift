import XCTest
import AppKit
@testable import App

/// A locked window keeps its tabs to itself: commands sent through another, unlocked window cannot read, type into,
/// or change them, and anything that waited for an answer does not run after the window locks or the session reconnects.
@MainActor final class WorkspaceLockTests: XCTestCase {
    private var saved: UserDefaults!

    override func setUp() async throws {
        _ = NSApplication.shared
        saved = WorkspaceCommand.preferences
        let name = "gloamux-test-\(UUID().uuidString)"
        WorkspaceCommand.preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    }

    override func tearDown() async throws { WorkspaceCommand.preferences = saved }

    /// Two windows on one workspace: the first stays unlocked, the second is locked by the test.
    private func windows() throws -> (WorkspaceModel, WorkspaceModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-lock-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let first = try WorkspaceModel(storage: root)
        return (first, try WorkspaceModel(sharing: first))
    }

    @discardableResult
    private func run(_ argv: [String], _ model: WorkspaceModel, _ windows: [WorkspaceModel]) async throws -> Any {
        let data = try await WorkspaceCommand.run(argv, model: model, live: true, windows: windows)
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func refused(_ argv: [String], _ model: WorkspaceModel, _ windows: [WorkspaceModel],
                         file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await run(argv, model, windows)
            XCTFail("\(argv.prefix(2).joined(separator: " ")) reached a tab in a locked window", file: file, line: line)
        } catch WorkspaceError.invalid(let reason) {
            XCTAssertEqual(reason, WorkspaceCommand.lockedTab, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    func testCommandsFromAnUnlockedWindowCannotReachALockedWindowsTabs() async throws {
        let (first, second) = try windows()
        let open = [first, second]
        let tab = second.tabs[0]
        tab.feed("secret output in the second window\r\n")
        tab.terminalReady = true
        let ssh = second.addTab()
        ssh.host = "db.test"; ssh.username = "admin"; ssh.connected = true
        let quick = try await run(["commands", "add", "List", "ls"], first, open) as? [String: Any]
        let quickID = try XCTUnwrap(quick?["id"] as? String)
        try await run(["runbooks", "create", "Deploy"], first, open)
        second.lockWorkspace()
        XCTAssertTrue(second.workspaceLocked)
        XCTAssertFalse(first.workspaceLocked, "Each window locks on its own")

        let id = tab.id.uuidString
        await refused(["tabs", "read", id], first, open)
        await refused(["tabs", "read", id, "5"], first, open)
        await refused(["tabs", "send", id, "ls"], first, open)
        await refused(["tabs", "run", id, "ls"], first, open)
        await refused(["commands", "run", quickID, id], first, open)
        await refused(["runbooks", "run", "Deploy", id], first, open)
        await refused(["tabs", "rename", id, "Renamed"], first, open)
        await refused(["tabs", "readonly", id, "on"], first, open)
        await refused(["tabs", "show", id], first, open)
        await refused(["tabs", "record", id, "on"], first, open)
        await refused(["tabs", "close", id], first, open)
        await refused(["forwards", "live-list", ssh.id.uuidString], first, open)
        XCTAssertEqual(tab.bytesSent, 0, "Nothing was typed")
        XCTAssertNil(tab.riskyCommand)
        XCTAssertFalse(tab.readOnly)
        XCTAssertNotEqual(tab.title, "Renamed")
        XCTAssertFalse(second.recordings.isRecording(tab))
        XCTAssertTrue(second.tabs.contains { $0 === tab })

        // Lists name the locked window's tabs, as its tab bar does, and nothing more.
        let listedReply = try await run(["tabs", "list"], first, open)
        let listed = try XCTUnwrap(listedReply as? [[String: Any]])
        let locked = try XCTUnwrap(listed.first { $0["id"] as? String == ssh.id.uuidString })
        XCTAssertEqual(locked["locked"] as? Bool, true)
        XCTAssertEqual(Set(locked.keys), ["id", "title", "kind", "window", "locked"])
        XCTAssertEqual(listed.first { $0["id"] as? String == first.tabs[0].id.uuidString }?["locked"] as? Bool, false)
        let tunnelsReply = try await run(["forwards", "live-list"], first, open)
        let tunnels = try XCTUnwrap(tunnelsReply as? [[String: Any]])
        XCTAssertEqual(tunnels.map { $0["id"] as? String }, [ssh.id.uuidString])
        XCTAssertEqual(tunnels.first?["locked"] as? Bool, true)
        XCTAssertNil(tunnels.first?["forwards"], "A locked window's forwards are not listed")

        // Once the owner unlocks the window, the same commands work again.
        second.workspaceLocked = false
        let read = try await run(["tabs", "read", id], first, open) as? [String: Any]
        XCTAssertTrue((read?["text"] as? String)?.contains("secret output") == true)
        try await run(["tabs", "rename", id, "Renamed"], first, open)
        XCTAssertEqual(tab.title, "Renamed")
        ssh.connected = false
    }

    func testAgentsCannotReachASessionOpenOnlyInALockedWindow() async throws {
        let (first, second) = try windows()
        let open = [first, second]
        let session = try first.sessionTree.add(name: "Shell", parent: nil, connection: SavedConnection(host: "shell.test", username: "carol"))
        first.agents.setEnabled(true)
        first.agents.allow(session, name: "Shell")
        let tab = second.addLocalTab()
        tab.savedSessionID = session
        XCTAssertTrue(tab.terminalReady)
        func agent(_ tool: String, _ input: [String: Any]) async throws -> Any {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            return try await run(["agent", tool, json, "Test agent"], first, open)
        }

        // A proposal made while the window was open waits; locking the window stops it from being sent.
        let proposed = try await agent("propose_command", ["session": "Shell", "command": "echo LOCKED_$((40+2))"])
        let reply = try XCTUnwrap(proposed as? [String: Any])
        XCTAssertEqual(reply["tab"] as? String, tab.id.uuidString)
        second.lockWorkspace()
        second.answerAgentProposal(tab, run: true)
        XCTAssertEqual(first.agents.waiting(in: tab.id)?.command, "echo LOCKED_$((40+2))", "The proposal still waits for review")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(tab.transcript.contains("LOCKED_42"))

        let tabsBefore = first.tabs.count + second.tabs.count
        do { _ = try await agent("propose_command", ["session": "Shell", "command": "echo again"]); XCTFail("Reached a locked window") }
        catch { XCTAssertTrue(error.localizedDescription.contains("locked"), error.localizedDescription) }
        do { _ = try await agent("open_session", ["session": "Shell"]); XCTFail("Opened a second connection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("locked"), error.localizedDescription) }
        XCTAssertEqual(first.tabs.count + second.tabs.count, tabsBefore)
        let sessionsReply = try await agent("list_sessions", [:])
        let sessions = try XCTUnwrap(sessionsReply as? [[String: Any]])
        XCTAssertEqual((sessions.first?["tabs"] as? [Any])?.count, 0, "Tabs in a locked window are not shown to agents")

        second.workspaceLocked = false
        second.answerAgentProposal(tab, run: true)
        XCTAssertEqual(first.agents.proposals.first?.status, .sent)
        await second.closeAll()
    }

    func testAConfirmedRiskyCommandRunsOnlyUnlockedAndInTheSameConnection() async throws {
        let (first, second) = try windows()
        let tab = second.tabs[0]
        tab.terminalReady = true
        tab.environment = .production
        try await run(["tabs", "run", tab.id.uuidString, "rm -rf /srv/data"], first, [first, second])
        XCTAssertEqual(tab.riskyCommand?.command, "rm -rf /srv/data")

        // Locked: the question waits for the owner instead of running.
        second.lockWorkspace()
        second.confirmRiskyCommand(tab, run: true)
        XCTAssertNotNil(tab.riskyCommand)
        XCTAssertEqual(tab.bytesSent, 0)
        second.workspaceLocked = false

        // The session reconnected while the question was open: the old command is dropped, not sent to the new one.
        tab.terminalID = UUID()
        second.confirmRiskyCommand(tab, run: true)
        XCTAssertNil(tab.riskyCommand)
        XCTAssertEqual(tab.bytesSent, 0, "Nothing went to the new connection")
    }

    func testRunbookBlocksStopWhenTheWindowLocksOrTheSessionReconnects() async throws {
        let (_, second) = try windows()
        let tab = second.tabs[0]
        tab.terminalReady = true
        second.lockWorkspace()
        var result = await second.runBlock("echo hi", in: tab, terminal: tab.terminalID)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.output, "Not run: the workspace is locked.")
        second.workspaceLocked = false
        let started = tab.terminalID
        tab.terminalID = UUID()
        result = await second.runBlock("echo hi", in: tab, terminal: started)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.output, "Not run: the session reconnected.")
        XCTAssertEqual(tab.bytesSent, 0)
    }
}
