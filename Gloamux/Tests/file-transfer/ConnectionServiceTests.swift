import XCTest
import Darwin
@testable import App
@testable import FileTransfer

/// The connection service that windows and commands share: a command signs in with the same settings and checks as
/// a tab, but owns no tab and keeps nothing; a tab's attempt ends quietly when the tab moves on.
@MainActor final class ConnectionServiceTests: XCTestCase {
    private func workspace() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-connections-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try WorkspaceModel(storage: root)
    }

    /// A loopback port nothing listens on.
    private func closedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && Darwin.getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw XCTSkip("No free loopback port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func add(_ model: WorkspaceModel, _ name: String, _ connection: SavedConnection) throws -> SessionTreeNode {
        try XCTUnwrap(model.sessionTree.node(try model.sessionTree.add(name: name, parent: nil, connection: connection)))
    }

    private func commandError(_ work: () async throws -> Void) async -> String? {
        do { try await work(); return nil }
        catch WorkspaceError.invalid(let reason) { return reason }
        catch { return "\(error)" }
    }

    func testACommandConnectsWithTheSameSettingsAsATab() throws {
        let model = try workspace()
        let jump = UUID()
        var socket = SavedConnection(host: "web.example", port: 2222, username: "ops", usesAgent: true, agentSocket: "/tmp/agent.sock")
        socket.forwardsAgent = true
        let variants: [SavedConnection] = [
            SavedConnection(host: "web.example", username: "ops"),
            SavedConnection(host: "web.example", username: "ops", proxyHost: "proxy.example", proxyPort: 3128, proxyKind: .http),
            SavedConnection(host: "web.example", username: "ops", proxyHost: "127.0.0.1", proxyPort: nil),
            SavedConnection(host: "web.example", username: "ops", identityPath: "/keys/id_ed25519", usesAgent: true),
            SavedConnection(host: "web.example", username: "ops", jumpSessionID: jump, confirmsEachConnection: true),
            socket,
        ]
        for settings in variants {
            let tab = SessionTab()
            model.configureSaved(tab, SessionTreeNode(name: "Web", connection: settings), settings)
            XCTAssertEqual(ConnectionService.sshTarget(settings), tab.sshTarget, "\(settings)")
        }
    }

    func testAFileCommandOwnsNoTabKeepsNothingAndClosesWhenDone() async throws {
        try await OpenSSHFixture.withServer { port, _ in
            let model = try self.workspace()
            let item = try self.add(model, "Loopback", SavedConnection(host: "127.0.0.1", port: port, username: "tester"))
            let tabs = model.tabs.map(\.id)

            // An unknown host key is refused with its fingerprint, as the command prints it.
            let refused = await self.commandError {
                try await model.withFileConnection(item, protocol: nil, secret: "secret", allowPlainFTP: false,
                                                   access: FileCommandAccess()) { _ in }
            }
            let fingerprint = try XCTUnwrap(refused?.range(of: #"SHA256:[A-Za-z0-9+/]+"#, options: .regularExpression)
                .map { String(refused![$0]) }, refused ?? "")
            XCTAssertTrue(refused?.contains("Unrecognized SSH host key") == true, refused ?? "")

            let access = FileCommandAccess(hostKeys: [fingerprint])
            var used: (any RemoteFileSystem)?
            let listed = try await model.withFileConnection(item, protocol: nil, secret: "secret", allowPlainFTP: false,
                                                            access: access) { fs in
                used = fs
                XCTAssertEqual(model.tabs.map(\.id), tabs, "No tab is made for a command")
                return try await fs.readDirectory(".").path
            }
            XCTAssertFalse(listed.isEmpty)
            XCTAssertEqual(used?.isOpen, false, "The file channel is closed afterward")
            XCTAssertEqual(model.tabs.map(\.id), tabs)
            XCTAssertFalse(model.tabs.contains { $0.connected && !$0.isLocal })
            XCTAssertNil(model.knownHosts.trustedKey(for: KnownHosts.endpoint(host: "127.0.0.1", port: port)),
                         "A key allowed for one command is not trusted afterward")
            let saved = try? await model.vault.password(id: "tester@" + KnownHosts.endpoint(host: "127.0.0.1", port: port))
            XCTAssertNil(saved, "The typed password is not kept")

            // A failing operation still closes the connection.
            struct Failed: Error {}
            do {
                _ = try await model.withFileConnection(item, protocol: "sftp", secret: "secret", allowPlainFTP: false,
                                                       access: access) { fs -> Int in used = fs; throw Failed() }
                XCTFail("The operation's error was lost")
            } catch is Failed {}
            XCTAssertEqual(used?.protocolName, "SFTP", "--protocol chooses the file channel")
            XCTAssertEqual(used?.isOpen, false)
        }
    }

    func testAJumpHostFailureReadsTheSameInAWindowAndInACommand() async throws {
        let model = try workspace()
        let first = try add(model, "First", SavedConnection(host: "first.example", username: "ops"))
        let second = try add(model, "Second", SavedConnection(host: "second.example", username: "ops", jumpSessionID: first.id))
        let one = try add(model, "One hop", SavedConnection(host: "web.example", username: "ops", jumpSessionID: first.id))
        let two = try add(model, "Two hops", SavedConnection(host: "web.example", username: "ops", jumpSessionID: second.id))
        for (item, named) in [(one, false), (two, true)] {
            let settings = try XCTUnwrap(item.connection)
            let tab = SessionTab()
            model.configureSaved(tab, item, settings)
            tab.password = "typed"
            await model.connect(tab)
            let window = try XCTUnwrap(tab.error)
            XCTAssertFalse(tab.connected)
            let command = await commandError {
                try await model.withFileConnection(item, protocol: nil, secret: "typed", allowPlainFTP: false,
                                                   access: FileCommandAccess()) { _ in }
            }
            XCTAssertEqual(command, window)
            XCTAssertTrue(window.hasPrefix(named ? "Jump host: first.example – " : "Jump host: "), window)
            XCTAssertEqual(window.contains("first.example"), named)
        }
    }

    func testACommandAsksTheOwnerForASessionThatAsksEveryTime() async throws {
        let model = try workspace()
        let port = try closedPort()
        let item = try add(model, "Asks", SavedConnection(host: "127.0.0.1", port: port, username: "ops",
                                                           confirmsEachConnection: true))
        var asked: [String] = []
        model.confirmOwner = { reason in asked.append(reason); throw CancellationError() }
        // Nothing is saved for a new session, so the first connection goes on without asking and finds no password.
        let first = await commandError {
            try await model.withFileConnection(item, protocol: nil, secret: nil, allowPlainFTP: false,
                                               access: FileCommandAccess()) { _ in }
        }
        XCTAssertEqual(asked, [])
        XCTAssertEqual(first, "No password is saved for this account. Enter a connection password.")

        try await model.vault.save(id: "ops@" + KnownHosts.endpoint(host: "127.0.0.1", port: port), password: "remembered")
        let refused = await commandError {
            try await model.withFileConnection(item, protocol: nil, secret: nil, allowPlainFTP: false,
                                               access: FileCommandAccess()) { _ in }
        }
        XCTAssertEqual(refused, "This session asks for Touch ID or the Mac password before it connects.")
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked.first?.contains("ops@127.0.0.1") == true, asked.first ?? "")

        // With the owner's approval the command goes on to connect (and here finds no password).
        model.confirmOwner = { reason in asked.append(reason) }
        let next = await commandError {
            try await model.withFileConnection(item, protocol: nil, secret: nil, allowPlainFTP: false,
                                               access: FileCommandAccess()) { _ in }
        }
        XCTAssertEqual(asked.count, 2)
        XCTAssertNotEqual(next, refused)
    }

    func testDisconnectingWhileTheOwnerConfirmsEndsTheAttemptQuietly() async throws {
        let model = try workspace()
        let port = try closedPort()
        let settings = SavedConnection(host: "127.0.0.1", port: port, username: "ops", confirmsEachConnection: true)
        let item = try add(model, "Asks", settings)
        try await model.vault.save(id: "ops@" + KnownHosts.endpoint(host: "127.0.0.1", port: port), password: "remembered")
        let tab = model.tabs[0]
        model.configureSaved(tab, item, settings)
        var waiting: CheckedContinuation<Void, Error>?
        model.confirmOwner = { _ in try await withCheckedThrowingContinuation { waiting = $0 } }
        let attempt = Task { await model.connect(tab) }
        for _ in 0..<500 where waiting == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(tab.status, "Waiting for Touch ID…")
        XCTAssertTrue(tab.busy)

        await model.disconnect(tab)
        waiting?.resume()
        await attempt.value
        XCTAssertFalse(tab.connected)
        XCTAssertFalse(tab.busy)
        XCTAssertNil(tab.error, "A replaced attempt reports nothing")
        XCTAssertEqual(tab.status, "Disconnected")
        XCTAssertNil(tab.session)
        XCTAssertNil(tab.pendingJump)
    }
}
