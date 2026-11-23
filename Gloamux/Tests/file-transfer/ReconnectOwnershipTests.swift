import XCTest
import AppKit
@testable import App

/// An automatic reconnect belongs to its tab's connection: disconnecting or closing the tab while an attempt is under
/// way ends it for good, and nothing reconnects afterward.
@MainActor final class ReconnectOwnershipTests: XCTestCase {
    private var delays = WorkspaceModel.reconnectDelays

    override func tearDown() {
        WorkspaceModel.reconnectDelays = delays
        super.tearDown()
    }

    /// A saved session to the loopback server whose reconnect attempt is waiting at the host key prompt.
    private func reconnecting(_ port: Int) async throws -> (WorkspaceModel, SessionTab) {
        guard TerminalPreferences.reconnects else { throw XCTSkip("Automatic reconnect is turned off in this account") }
        WorkspaceModel.reconnectDelays = [0, 0, 0, 0, 0]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-reconnect-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root)
        let settings = SavedConnection(host: "127.0.0.1", port: port, username: "tester")
        let item = try XCTUnwrap(model.sessionTree.node(try model.sessionTree.add(name: "Loopback", parent: nil, connection: settings)))
        let tab = model.tabs[0]
        model.configureSaved(tab, item, settings)
        await model.vault.rememberWorking(id: tab.credentialID, secret: "secret", generation: await model.vault.sessionGeneration)
        // The connection was up and was lost: the tab reconnects by itself.
        tab.connected = true
        tab.transportLost = true
        model.scheduleReconnect(tab)
        for _ in 0..<500 where tab.hostKeyPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(tab.hostKeyPrompt, "The reconnect attempt reached the host key")
        return (model, tab)
    }

    /// Waits long enough for another attempt to start if one was scheduled.
    private func settle() async throws { try await Task.sleep(nanoseconds: 400_000_000) }

    func testDisconnectingDuringAReconnectStopsReconnecting() async throws {
        try await OpenSSHFixture.withServer { port, _ in
            let (model, tab) = try await self.reconnecting(port)
            await model.disconnect(tab)
            try await self.settle()
            XCTAssertNil(tab.hostKeyPrompt, "No new attempt asks about the host key")
            XCTAssertFalse(tab.connected)
            XCTAssertFalse(tab.busy)
            XCTAssertFalse(tab.transportLost, "A disconnected tab is not treated as lost")
            XCTAssertEqual(tab.status, "Disconnected")
            XCTAssertNil(tab.reconnectTask)
            await model.closeAll()
        }
    }

    func testClosingATabDuringAReconnectLeavesNoConnection() async throws {
        try await OpenSSHFixture.withServer { port, _ in
            let (model, tab) = try await self.reconnecting(port)
            await model.closeTab(tab)
            try await self.settle()
            XCTAssertFalse(model.tabs.contains { $0.id == tab.id })
            XCTAssertNil(tab.hostKeyPrompt)
            XCTAssertNil(tab.session)
            XCTAssertFalse(tab.busy)
            XCTAssertNil(tab.reconnectTask)
            await model.closeAll()
        }
    }

    /// A real connection keeps its session while it moves between its own window and the tab bar; closing its window,
    /// or the workspace window, ends it without a reconnect.
    func testAMovedSessionKeepsItsConnectionAndClosingItsWindowEndsIt() async throws {
        _ = NSApplication.shared
        try await OpenSSHFixture.withServer { port, _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-move-\(UUID())")
            self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let model = try WorkspaceModel(storage: root)
            let settings = SavedConnection(host: "127.0.0.1", port: port, username: "tester")
            let item = try XCTUnwrap(model.sessionTree.node(try model.sessionTree.add(name: "Loopback", parent: nil, connection: settings)))
            let tab = model.addTab()
            model.configureSaved(tab, item, settings)
            tab.password = "secret"
            let login = Task { await model.connect(tab) }
            for _ in 0..<500 where tab.hostKeyPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            model.answerHostKey(tab, approve: true)
            await login.value
            XCTAssertTrue(tab.connected, tab.error ?? "")
            let session = try XCTUnwrap(tab.session)
            let epoch = tab.epoch

            model.moveTabToWindow(tab)
            model.moveWindowToTabs(tab)
            model.moveTabToWindow(tab)
            XCTAssertTrue(tab.connected)
            XCTAssertTrue(tab.session === session, "Moving does not reconnect")
            XCTAssertEqual(tab.epoch, epoch)

            // Closing its own window disconnects it for good.
            model.sessionWindows[tab.id]?.window?.close()
            for _ in 0..<500 where tab.connected { try await Task.sleep(nanoseconds: 5_000_000) }
            try await self.settle()
            XCTAssertFalse(tab.connected)
            XCTAssertNil(tab.session)
            XCTAssertNil(model.sessionWindows[tab.id])
            XCTAssertNil(tab.reconnectTask)
            XCTAssertFalse(tab.transportLost)

            // Closing the workspace window closes the sessions in their own windows too.
            let other = model.addTab()
            model.configureSaved(other, item, settings)
            await model.connect(other)
            XCTAssertTrue(other.connected, other.error ?? "")
            model.moveTabToWindow(other)
            await model.closeWorkspaceWindow(lockingVault: false)
            XCTAssertTrue(model.sessionWindows.isEmpty)
            XCTAssertFalse(other.connected)
            XCTAssertNil(other.session)
        }
    }
}

/// The connection state of a tab: one value instead of separate connected and lost flags.
@MainActor final class ConnectionStateTests: XCTestCase {
    func testATabMovesBetweenLegalStatesOnly() async throws {
        try await OpenSSHFixture.withServer { port, _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-state-\(UUID())")
            self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let model = try WorkspaceModel(storage: root)
            let settings = SavedConnection(host: "127.0.0.1", port: port, username: "tester")
            let item = try XCTUnwrap(model.sessionTree.node(try model.sessionTree.add(name: "Loopback", parent: nil, connection: settings)))
            let tab = model.tabs[0]
            model.configureSaved(tab, item, settings)
            XCTAssertEqual(tab.connectionState, .disconnected)
            tab.password = "secret"
            let connecting = Task { await model.connect(tab) }
            for _ in 0..<500 where tab.hostKeyPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            model.answerHostKey(tab, approve: true)
            await connecting.value
            XCTAssertEqual(tab.connectionState, .connected, tab.error ?? "")
            XCTAssertTrue(tab.connected); XCTAssertFalse(tab.transportLost)

            // The server goes away: the tab is lost, never connected and lost at once.
            var seen: [ConnectionState] = []
            let watch = tab.$connectionState.sink { seen.append($0) }
            defer { watch.cancel() }
            try await tab.session?.close()
            for _ in 0..<500 where !tab.transportLost { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(tab.connectionState, .lost)
            XCTAssertFalse(tab.connected)
            XCTAssertEqual(seen, [.connected, .lost], "Straight from connected to lost")

            // Disconnecting stops any reconnect the loss scheduled.
            await model.disconnect(tab)
            XCTAssertEqual(tab.connectionState, .disconnected, "Disconnect ends a lost connection too")
            XCTAssertFalse(ConnectionState.disconnected.canMove(to: .lost), "Only a connection that was up can be lost")
        }
    }
}
