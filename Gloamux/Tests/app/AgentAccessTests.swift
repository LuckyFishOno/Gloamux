import AppKit
import Terminal
import XCTest
@testable import App

/// AI agents through `gloamux mcp`: nothing without opt-in, only allowed sessions, commands only after review in
/// Gloamux and only in the live terminal they were proposed for, a history of every request, and revocation.
@MainActor final class AgentAccessTests: XCTestCase {
    override func setUp() async throws { _ = NSApplication.shared }

    private func workspace() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-agents-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try WorkspaceModel(storage: root)
    }

    private func call(_ tool: String, _ model: WorkspaceModel) async throws -> Any { try await call(tool, [:], model) }

    private func call(_ tool: String, _ input: [String: Any], _ model: WorkspaceModel, client: String = "Test agent") async throws -> Any {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let data = try await WorkspaceCommand.run(["agent", tool, json, client], model: model, live: true)
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func wait(for text: String, in tab: SessionTab) async throws {
        for _ in 0..<150 {
            if tab.transcript.contains(text) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Expected \(text) in terminal output:\n\(tab.transcript)")
    }

    func testNothingIsSharedUntilTheUserOptsInAndAllowsASession() async throws {
        let model = try workspace()
        try model.sessionTree.add(name: "Build", parent: nil, connection: SavedConnection(host: "build.test", username: "alice"))
        let hidden = try model.sessionTree.add(name: "Payroll", parent: nil, connection: SavedConnection(host: "pay.test", username: "bob"))
        do { _ = try await call("list_sessions", model); XCTFail("access is off by default") } catch {}
        XCTAssertTrue(model.agents.history.last?.outcome.hasPrefix("refused") == true, "refusals are recorded")

        model.agents.setEnabled(true)
        let none = try await call("list_sessions", model) as? [[String: Any]]
        XCTAssertEqual(none?.count, 0, "turning access on shows no session yet")
        let build = try XCTUnwrap(model.sessionTree.nodes.first { $0.name == "Build" })
        model.agents.allow(build.id, name: build.name)
        let listing = try await call("list_sessions", model)
        let listed = try XCTUnwrap(listing as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["name"] as? String }, ["Build"])
        XCTAssertEqual(listed.first?["destination"] as? String, "alice@build.test:22")
        do { _ = try await call("open_session", ["session": hidden.uuidString], model); XCTFail("a session not allowed stays closed") } catch {}
        do { _ = try await call("propose_command", ["session": "Build", "command": "uptime"], model); XCTFail("needs a live terminal") } catch {}

        // Access is per workspace folder and survives reopening it.
        let reopened = try WorkspaceModel(storage: model.storage)
        XCTAssertTrue(reopened.agents.allows(build.id))
        model.agents.revokeAll()
        XCTAssertFalse(model.agents.enabled)
        XCTAssertEqual(model.agents.allowedSessions, [])
    }

    func testProposedCommandRunsOnlyAfterReviewInItsOwnTerminal() async throws {
        let model = try workspace()
        let id = try model.sessionTree.add(name: "Shell", parent: nil, connection: SavedConnection(host: "shell.test", username: "carol"))
        model.agents.setEnabled(true)
        model.agents.allow(id, name: "Shell")
        let tab = model.addLocalTab()
        tab.savedSessionID = id
        XCTAssertTrue(tab.terminalReady)

        let reply = try await call("propose_command", ["session": "Shell", "command": "echo AGENT_$((40+2))", "reason": "check"], model)
        let proposed = try XCTUnwrap(reply as? [String: Any])
        let proposal = try XCTUnwrap(proposed["proposal"] as? String)
        XCTAssertEqual(model.agents.waiting(in: tab.id)?.command, "echo AGENT_$((40+2))")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(tab.transcript.contains("AGENT_42"), "nothing runs before the user answers")
        do { _ = try await call("get_proposal", ["proposal": proposal], model, client: "Other agent"); XCTFail("another client") } catch {}

        model.answerAgentProposal(tab, run: true)
        try await wait(for: "AGENT_42", in: tab)
        let status = try await call("get_proposal", ["proposal": proposal], model) as? [String: Any]
        XCTAssertEqual(status?["status"] as? String, "sent")

        // A proposal for a terminal that has since restarted cannot run.
        _ = try await call("propose_command", ["session": "Shell", "command": "echo STALE_$((1+1))"], model)
        tab.terminalID = UUID()
        model.answerAgentProposal(tab, run: true)
        XCTAssertEqual(model.agents.proposals.last?.status, .expired)

        // Removing the session revokes what is waiting, and the user can decline.
        _ = try await call("propose_command", ["session": "Shell", "command": "echo LATER"], model)
        model.agents.revoke(id, name: "Shell")
        XCTAssertEqual(model.agents.proposals.last?.status, .revoked)
        XCTAssertNil(model.agents.waiting(in: tab.id))
        model.agents.allow(id, name: "Shell")
        _ = try await call("propose_command", ["session": "Shell", "command": "echo NEVER"], model)
        model.answerAgentProposal(tab, run: false)
        XCTAssertEqual(model.agents.proposals.last?.status, .declined)

        let actions = model.agents.history.map(\.action)
        XCTAssertTrue(actions.contains("Command run after review"))
        XCTAssertTrue(actions.contains("Command declined"))
        await model.closeAll()
    }

    func testAgentsReadOnlyWhatTheUserShares() async throws {
        let model = try workspace()
        model.agents.setEnabled(true)
        let empty = try await call("read_shared_output", model) as? [String: Any]
        XCTAssertEqual((empty?["excerpts"] as? [Any])?.count, 0)
        let tab = model.addTab(); tab.title = "web-1"
        model.terminalReceived(tab, bytes: Array("SECRET_SCREEN".utf8))
        model.shareWithAgents(tab, selection: "only this part")
        let reading = try await call("read_shared_output", model)
        let shared = try XCTUnwrap(reading as? [String: Any])
        let excerpts = try XCTUnwrap(shared["excerpts"] as? [[String: Any]])
        XCTAssertEqual(excerpts.map { $0["text"] as? String }, ["only this part"])
        let first = try XCTUnwrap(excerpts.first?["id"] as? String)
        model.shareWithAgents(tab)
        let later = try await call("read_shared_output", ["after": first], model) as? [String: Any]
        XCTAssertEqual(((later?["excerpts"] as? [[String: Any]])?.first?["text"] as? String)?.contains("SECRET_SCREEN"), true)
    }

    private func sharedTexts(_ model: WorkspaceModel) async throws -> [String] {
        let shared = try await call("read_shared_output", model) as? [String: Any]
        return try XCTUnwrap(shared?["excerpts"] as? [[String: Any]]).compactMap { $0["text"] as? String }
    }

    private let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + String(repeating: "c3ludGhldGlj\n", count: 8_000) + "-----END OPENSSH PRIVATE KEY-----"

    func testSharedTextReachesAgentsWithSecretsRedacted() async throws {
        let model = try workspace()
        model.agents.setEnabled(true)
        let tab = model.addTab()
        model.shareWithAgents(tab, selection: "key AKIAABCDEFGHIJKLMNOP\npassword=hunter22 user=alice\nls -la")
        // The key is longer than an excerpt: cutting before redacting would keep its body without its first line.
        model.shareWithAgents(tab, selection: privateKey + "\nafter")
        let texts = try await sharedTexts(model)
        XCTAssertEqual(texts, ["key [REDACTED]\npassword=[REDACTED] user=alice\nls -la", "[REDACTED]\nafter"])
        // What Gloamux keeps is the same text agents read.
        XCTAssertEqual(model.agents.excerpts.map(\.text), texts)
    }

    func testSharedScreenRedactsASecretThatWrapsOrStartsAboveIt() async throws {
        let model = try workspace()
        model.agents.setEnabled(true)
        let wrapped = model.addTab()
        wrapped.screen.resize(rows: 5, cols: 30)
        model.terminalReceived(wrapped, bytes: Array("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 end".utf8))
        model.shareWithAgents(wrapped)
        let above = model.addTab()
        above.screen.resize(rows: 5, cols: 30)
        let key = "-----BEGIN PRIVATE KEY-----\r\n" + String(repeating: "c3ludGhldGlj\r\n", count: 12) + "-----END PRIVATE KEY-----\r\nafter"
        model.terminalReceived(above, bytes: Array(key.utf8))
        model.shareWithAgents(above)
        let texts = try await sharedTexts(model)
        // A new tab's screen starts with a line of its own.
        XCTAssertEqual(texts.first?.components(separatedBy: "\n").last, "token [REDACTED] end")
        XCTAssertEqual(texts.last, "[REDACTED]\nafter")
    }

    func testTerminalSelectionRedactsWrappedAndPartlySelectedSecrets() throws {
        let screen = TerminalScreen()
        screen.resize(rows: 5, cols: 30)
        screen.feed(Array("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 end".utf8))
        let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.screen = screen
        let rows = (0..<screen.rows).map { screen.text(lines: $0..<($0 + 1)) }
        view.string = rows.joined(separator: "\n")
        XCTAssertNil(view.redactedSelection())
        let all = view.string as NSString
        view.setSelectedRange(NSRange(location: 0, length: all.length))
        XCTAssertEqual(view.redactedSelection()?.trimmingCharacters(in: .newlines), "token [REDACTED] end")
        // Only the middle of the token.
        view.setSelectedRange(NSRange(location: 14, length: 10))
        XCTAssertEqual(view.redactedSelection(), "[REDACTED]")
        // Only its second row.
        view.setSelectedRange(all.range(of: rows[1]))
        XCTAssertEqual(view.redactedSelection(), "[REDACTED] end")
    }

    /// The real `gloamux mcp` process speaks MCP and reaches this process the way it reaches the running app.
    func testMCPServerRoundTripThroughTheRunningApp() async throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("gloamux")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "gloamux is not built")
        let model = try workspace()
        let id = try model.sessionTree.add(name: "Lab", parent: nil, connection: SavedConnection(host: "lab.test", username: "dana"))

        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["mcp", "--workspace", model.storage.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        func send(_ message: [String: Any]) async throws -> [String: Any] {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
            guard message["id"] != nil else { return [:] }
            let line = try await lines.next()
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(line).utf8)) as? [String: Any])
        }

        let hello = try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Fixture", "version": "1"]]])
        XCTAssertEqual((hello["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        _ = try await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let tools = try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["list_sessions", "open_session", "read_shared_output", "propose_command", "get_proposal"])

        // Gloamux is not serving yet: a clear error, and the lock is left for the app.
        let closed = try await send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_sessions", "arguments": [:]]])
        XCTAssertEqual((closed["result"] as? [String: Any])?["isError"] as? Bool, true)

        let channel = try WorkspaceCommandChannel(workspace: model.storage)
        XCTAssertTrue(try channel.claim(), "gloamux mcp gave the lock back")
        try channel.serve(activeWorkspace: { model })
        defer { channel.stop() }
        model.agents.setEnabled(true)
        model.agents.allow(id, name: "Lab")
        let listed = try await send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "list_sessions", "arguments": [:]]])
        let result = try XCTUnwrap(listed["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("dana@lab.test:22"), text)
        XCTAssertEqual(model.agents.history.last?.client, "Fixture")
        let unknown = try await send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "rm_rf", "arguments": [:]]])
        XCTAssertNotNil(unknown["error"])
    }
}
