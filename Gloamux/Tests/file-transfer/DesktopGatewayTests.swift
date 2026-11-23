import Darwin
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import App

/// A desktop reached through a saved SSH session opens only the tunnel it needs, asks about the gateway's host key in
/// the desktop pane, and closes everything when the desktop stops.
@MainActor final class DesktopGatewayTests: XCTestCase {
    private final class Accepts: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        static let lock = NSLock()
        nonisolated(unsafe) static var count = 0
        func channelActive(context: ChannelHandlerContext) {
            Self.lock.lock(); Self.count += 1; Self.lock.unlock()
            context.fireChannelActive()
        }
    }

    /// Whether something accepts TCP connections on this loopback port.
    nonisolated private static func listening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// A loopback port that was free a moment ago.
    private func freePort() throws -> Int {
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

    func testAGatewayOpensOnlyTheDesktopTunnel() async throws {
        let desktopServer = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(Accepts()) }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { desktopServer.close(promise: nil) }
        let desktopPort = try XCTUnwrap(desktopServer.localAddress?.port)
        let savedForwardPort = try freePort()
        try await OpenSSHFixture.withServer(route: .init(host: "desktop.gloamux.invalid", port: desktopPort)) { port, _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-gateway-\(UUID())")
            self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let model = try WorkspaceModel(storage: root)
            // The gateway session has a forward of its own, which belongs to its tab, not to the desktop.
            var bastion = SavedConnection(host: "127.0.0.1", port: port, username: "tester")
            bastion.forwardingRules = [ForwardingRule(kind: .local, listenPort: savedForwardPort, host: "127.0.0.1", port: desktopPort)]
            let id = try model.sessionTree.add(name: "Bastion", parent: nil, connection: bastion)
            await model.vault.rememberWorking(id: "tester@[127.0.0.1]:\(port)", secret: "secret", generation: await model.vault.sessionGeneration)
            let desktop = RemoteDesktopSession(profile: ContainerSession(tool: .vnc, target: "desktop.gloamux.invalid"), tab: SessionTab())
            let tabs = model.tabs.map(\.id)

            let opening = Task { try await model.openDesktopTunnel(desktop, gateway: id, host: "desktop.gloamux.invalid", port: desktopPort) }
            for _ in 0..<500 where desktop.gateway?.hostKeyPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            let prompt = try XCTUnwrap(desktop.gateway?.hostKeyPrompt, "The gateway's host key is asked about in the desktop pane")
            XCTAssertEqual(prompt.endpoint, "[127.0.0.1]:\(port)")
            desktop.gateway?.answerHostKey(approve: true, knownHosts: model.knownHosts)
            let tunnel = try await opening.value

            XCTAssertEqual(model.tabs.map(\.id), tabs, "No tab is made for the gateway")
            XCTAssertNotNil(model.knownHosts.trustedKey(for: prompt.endpoint), "An approved key is trusted, as in a tab")
            let reached = await Task.detached { Self.listening(tunnel) }.value
            XCTAssertTrue(reached, "The tunnel accepts connections")
            for _ in 0..<200 where { Accepts.lock.lock(); defer { Accepts.lock.unlock() }; return Accepts.count }() == 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertGreaterThan({ Accepts.lock.lock(); defer { Accepts.lock.unlock() }; return Accepts.count }(), 0, "and reach the desktop")
            let saved = await Task.detached { Self.listening(savedForwardPort) }.value
            XCTAssertFalse(saved, "The gateway session's own forward is not started")

            desktop.closeTunnel?()
            for _ in 0..<200 { if !(await Task.detached { Self.listening(tunnel) }.value) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let afterClose = await Task.detached { Self.listening(tunnel) }.value
            XCTAssertFalse(afterClose, "Stopping the desktop closes the tunnel")
        }
    }

    func testARefusedGatewayKeyReportsWhichSessionFailed() async throws {
        try await OpenSSHFixture.withServer { port, _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-gateway-\(UUID())")
            self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let model = try WorkspaceModel(storage: root)
            let id = try model.sessionTree.add(name: "Bastion", parent: nil, connection: SavedConnection(host: "127.0.0.1", port: port, username: "tester"))
            await model.vault.rememberWorking(id: "tester@[127.0.0.1]:\(port)", secret: "secret", generation: await model.vault.sessionGeneration)
            let desktop = RemoteDesktopSession(profile: ContainerSession(tool: .vnc, target: "desktop.example"), tab: SessionTab())
            let opening = Task { try await model.openDesktopTunnel(desktop, gateway: id, host: "desktop.example", port: 5900) }
            for _ in 0..<500 where desktop.gateway?.hostKeyPrompt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            desktop.gateway?.answerHostKey(approve: false, knownHosts: model.knownHosts)
            do {
                _ = try await opening.value
                XCTFail("A refused key opened the tunnel")
            } catch {
                XCTAssertTrue(message(for: error).hasPrefix("Cannot connect to Bastion to reach the desktop."), message(for: error))
            }
            XCTAssertNil(model.knownHosts.trustedKey(for: "[127.0.0.1]:\(port)"))
        }
    }
}
