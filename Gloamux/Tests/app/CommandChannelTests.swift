import XCTest
@testable import App

/// The CLI channel to a running Gloamux: a command waiting for the owner does not hold up other commands, a request
/// Gloamux never picked up is withdrawn and reported as not run, and a change made during the wait is not undone.
@MainActor final class CommandChannelTests: XCTestCase {
    /// An owner confirmation that waits until the test answers it.
    private final class Owner {
        var waiting: CheckedContinuation<Void, Error>?
        var asked = 0
        func confirm() async throws {
            asked += 1
            try await withCheckedThrowingContinuation { waiting = $0 }
        }
        func approve() { waiting?.resume(); waiting = nil }
    }

    private var pickup = WorkspaceCommandChannel.pickupTimeout, answer = WorkspaceCommandChannel.answerTimeout

    override func tearDown() {
        WorkspaceCommandChannel.pickupTimeout = pickup
        WorkspaceCommandChannel.answerTimeout = answer
        super.tearDown()
    }

    private func workspace() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-channel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try WorkspaceModel(storage: root)
    }

    /// Gloamux serving `model`, and a client channel like the `gloamux` command's.
    private func serving(_ model: WorkspaceModel) throws -> (server: WorkspaceCommandChannel, client: WorkspaceCommandChannel) {
        let server = try WorkspaceCommandChannel(workspace: model.storage)
        XCTAssertTrue(try server.claim())
        try server.serve(activeWorkspace: { model })
        addTeardownBlock { @MainActor in server.stop() }
        let client = try WorkspaceCommandChannel(workspace: model.storage)
        XCTAssertFalse(try client.claim())
        return (server, client)
    }

    private func reply(_ client: WorkspaceCommandChannel, _ argv: [String]) async throws -> WorkspaceCommandChannel.Reply {
        let reply = try await client.send(argv)
        return try XCTUnwrap(reply)
    }

    private func web(_ model: WorkspaceModel) -> SavedConnection? {
        model.sessionTree.nodes.first { $0.connection != nil }?.connection
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Timed out")
    }

    func testACommandWaitingForTheOwnerDoesNotHoldUpOthers() async throws {
        let model = try workspace()
        try await WorkspaceCommand.run(["sessions", "add", "Web", "ssh", "web.example", "ops"], model: model, live: false)
        let owner = Owner()
        model.confirmOwner = { _ in try await owner.confirm() }
        let (_, client) = try serving(model)

        let slow = Task { try await self.reply(client, ["sessions", "options", "Web", "confirm=on"]) }
        try await until { owner.asked == 1 }
        // While Gloamux waits for Touch ID, a query is answered at once.
        let start = Date()
        let listed = try await reply(client, ["sessions", "list"])
        XCTAssertEqual(listed.code, 0, listed.text)
        XCTAssertTrue(listed.text.contains("Web"), listed.text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "The query did not wait for the confirmation")
        XCTAssertEqual(web(model)?.asksEachConnection, false)

        owner.approve()
        let changed = try await slow.value
        XCTAssertEqual(changed.code, 0, changed.text)
        XCTAssertEqual(web(model)?.asksEachConnection, true)
    }

    func testAChangeMadeWhileWaitingForTheOwnerIsNotUndone() async throws {
        let model = try workspace()
        try await WorkspaceCommand.run(["sessions", "add", "Web", "ssh", "web.example", "ops"], model: model, live: false)
        let owner = Owner()
        model.confirmOwner = { _ in try await owner.confirm() }
        let (_, client) = try serving(model)

        let slow = Task { try await self.reply(client, ["sessions", "options", "Web", "confirm=on"]) }
        try await until { owner.asked == 1 }
        let edited = try await reply(client, ["sessions", "edit", "Web", "web2.example", "ops", "2222"])
        XCTAssertEqual(edited.code, 0, edited.text)
        owner.approve()
        let changed = try await slow.value
        XCTAssertEqual(changed.code, 1, "The stale copy was saved: \(changed.text)")
        XCTAssertTrue(changed.text.contains("changed while Gloamux waited"), changed.text)
        let saved = try XCTUnwrap(web(model))
        XCTAssertEqual(saved.host, "web2.example", "The edit made during the wait is kept")
        XCTAssertEqual(saved.port, 2222)
        XCTAssertFalse(saved.asksEachConnection)
    }

    func testAnEditFromTheAppDuringTheWaitIsNotUndone() async throws {
        // The same, with the edit made in a Gloamux window rather than by another command.
        let model = try workspace()
        try await WorkspaceCommand.run(["sessions", "add", "Web", "ssh", "web.example", "ops"], model: model, live: false)
        let owner = Owner()
        model.confirmOwner = { _ in try await owner.confirm() }
        let slow = Task { try await WorkspaceCommand.run(["sessions", "options", "Web", "confirm=on"], model: model, live: true) }
        try await until { owner.asked == 1 }
        let node = try XCTUnwrap(model.sessionTree.nodes.first { $0.connection != nil })
        var edited = try XCTUnwrap(node.connection)
        edited.username = "deploy"
        try model.sessionTree.updateConnection(node.id, name: "Web (prod)", connection: edited)
        owner.approve()
        do { _ = try await slow.value; XCTFail("The copy made before the wait was saved") } catch WorkspaceError.invalid {}
        let saved = try XCTUnwrap(model.sessionTree.node(node.id))
        XCTAssertEqual(saved.name, "Web (prod)")
        XCTAssertEqual(saved.connection?.username, "deploy")
    }

    func testGloamuxQuittingMidCommandIsReportedAndNotRetried() async throws {
        let model = try workspace()
        try await WorkspaceCommand.run(["sessions", "add", "Web", "ssh", "web.example", "ops"], model: model, live: false)
        let owner = Owner()
        model.confirmOwner = { _ in try await owner.confirm() }
        let (server, client) = try serving(model)
        let slow = Task { try await client.send(["sessions", "options", "Web", "confirm=on"]) }
        try await until { owner.asked == 1 }
        // Gloamux quits with the command picked up but unanswered: the lock comes free.
        server.stop()
        server.release()
        let result = await slow.result
        XCTAssertThrowsError(try result.get()) {
            guard case WorkspaceError.invalid(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(reason, WorkspaceCommandChannel.exitedWhileRunning)
        }
        XCTAssertEqual(owner.asked, 1, "The command was not sent again")
        owner.approve()
    }

    func testARequestNotPickedUpIsWithdrawnAndReportedAsNotRun() async throws {
        WorkspaceCommandChannel.pickupTimeout = 0.3
        let model = try workspace()
        // Gloamux holds the lock but is not serving: nothing picks the request up.
        let server = try WorkspaceCommandChannel(workspace: model.storage)
        XCTAssertTrue(try server.claim())
        let client = try WorkspaceCommandChannel(workspace: model.storage)
        let start = Date()
        do {
            _ = try await client.send(["sessions", "add", "Late", "ssh", "late.example", "ops"])
            XCTFail("An unanswered request succeeded")
        } catch WorkspaceError.invalid(let reason) {
            XCTAssertEqual(reason, WorkspaceCommandChannel.notPickedUp)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let left = try FileManager.default.contentsOfDirectory(atPath: model.storage.appendingPathComponent(".cli").path)
        XCTAssertFalse(left.contains { $0.hasSuffix(".request") }, "The request was withdrawn: \(left)")

        // Serving now finds nothing to run.
        try server.serve(activeWorkspace: { model })
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.sessionTree.nodes.allSatisfy { $0.connection == nil }, "A withdrawn request never runs")
    }

    func testARequestStillRunningPastTheAnswerTimeoutIsReportedAsRunning() async throws {
        WorkspaceCommandChannel.answerTimeout = 0.3
        let model = try workspace()
        try await WorkspaceCommand.run(["sessions", "add", "Web", "ssh", "web.example", "ops"], model: model, live: false)
        let owner = Owner()
        model.confirmOwner = { _ in try await owner.confirm() }
        let (_, client) = try serving(model)
        do {
            _ = try await client.send(["sessions", "options", "Web", "confirm=on"])
            XCTFail("A command still waiting for the owner reported a result")
        } catch WorkspaceError.invalid(let reason) {
            XCTAssertEqual(reason, WorkspaceCommandChannel.stillRunning, "Picked up, so not reported as not run")
        }
        XCTAssertEqual(owner.asked, 1)
        owner.approve()
    }
}
