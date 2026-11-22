import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import Ssh

final class X11ForwardingTests: XCTestCase {
    func testNewShellReplacesTheCookieValidatesBeforeDialingAndClosesWithTheShell() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let data = X11FixtureData()
        let cookie = Array(UInt8(0)..<16)
        let marker = Array("next request".utf8)
        let expected = Self.setup(cookie: cookie, order: .little, extra: marker)
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { child in
                data.recordDisplayConnection()
                return child.pipeline.addHandler(FakeDisplay(expected: Array(expected.readableBytesView)))
            }
            .bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try? await listener.close().get() }
        let display = try SSHX11Configuration(endpoint: .tcp("127.0.0.1", try XCTUnwrap(listener.localAddress?.port)),
                                               screen: 2, cookie: cookie)
        try await OpenSSHFixture.withServer(interactive: true, onTransport: { data.record($0) }, onX11: { data.record($0) }) { port, _ in
            let client = try await connect(port)
            addTeardownBlock { try? await client.close() }
            let transport = try XCTUnwrap(data.transport)
            do {
                _ = try await openX11(over: transport)
                XCTFail("accepted X11 before a shell opted in")
            } catch is NIOSSHError {}

            let shell = try await client.openShell(x11: display, timeoutSeconds: 5)
            let request = try XCTUnwrap(data.request)
            XCTAssertEqual(request.authenticationProtocol, "MIT-MAGIC-COOKIE-1")
            XCTAssertEqual(request.screenNumber, 2)
            let substitute = try XCTUnwrap(SSHX11Configuration.parseAuthority("localhost \(request.authenticationProtocol) \(request.authenticationCookie)"))
            XCTAssertNotEqual(substitute, cookie)

            let unauthorized = try await openX11(over: transport)
            try await unauthorized.writeAndFlush(Self.setup(cookie: cookie, order: .big)).get()
            try await awaitClose(unauthorized)
            XCTAssertEqual(data.displayConnections, 0)

            let authorized = try await openX11(over: transport)
            let received = authorized.eventLoop.makePromise(of: UInt8.self)
            try await authorized.pipeline.addHandler(X11Response(promise: received)).get()
            var packet = Self.setup(cookie: substitute, order: .little, extra: marker)
            let fragment = try XCTUnwrap(packet.readSlice(length: 7))
            try await authorized.writeAndFlush(fragment).get()
            try await authorized.writeAndFlush(packet).get()
            let reply = try await received.futureResult.get()
            XCTAssertEqual(reply, 1)
            XCTAssertEqual(data.displayConnections, 1)
            await shell.close()
            try await awaitClose(authorized)
            do {
                _ = try await openX11(over: transport)
                XCTFail("accepted X11 after the shell was closed")
            } catch is NIOSSHError {}
        }
    }

    func testRejectedX11DoesNotPoisonTheSSHConnection() async throws {
        try await OpenSSHFixture.withServer(interactive: true) { port, _ in
            let client = try await connect(port)
            addTeardownBlock { try? await client.close() }
            let display = try SSHX11Configuration(endpoint: .socket("/tmp/gloamux-test-unreachable"),
                                                   cookie: Array(repeating: 0, count: 16))
            do {
                _ = try await client.openShell(x11: display, timeoutSeconds: 5)
                XCTFail("X11 rejection should fail the opted-in shell")
            } catch SSHError.commandFailed(let detail) {
                XCTAssertEqual(detail, "The SSH server refused X11 forwarding.")
            }
            let shell = try await client.openShell(timeoutSeconds: 5)
            await shell.close()
        }
    }

    func testDisplayParsingAndBothByteOrders() throws {
        XCTAssertEqual(SSHX11Configuration.parseDisplay("/private/tmp/abc/org.xquartz:0.1")?.0,
                       .socket("/private/tmp/abc/org.xquartz:0"))
        XCTAssertEqual(SSHX11Configuration.parseDisplay(":3")?.0, .socket("/tmp/.X11-unix/X3"))
        XCTAssertEqual(SSHX11Configuration.parseDisplay("localhost:4.2")?.1, 2)
        XCTAssertNil(SSHX11Configuration.parseDisplay("other.example:4"))
        XCTAssertNil(SSHX11Configuration.parseDisplay(":0."))
        XCTAssertNil(SSHX11Configuration.parseAuthority("localhost MIT-MAGIC-COOKIE-1 zz"))
        for order in [Endianness.big, .little] {
            let substitute = Array(repeating: UInt8(1), count: 16)
            let cookie = Array(repeating: UInt8(3), count: 16)
            var packet = Self.setup(cookie: substitute, order: order)
            XCTAssertTrue(try X11Setup.rewrite(&packet, substitute: substitute, cookie: cookie))
            XCTAssertEqual(packet, Self.setup(cookie: cookie, order: order))
        }
    }

    private func connect(_ port: Int) async throws -> SSHSession {
        try await SSHSession.connect(settings: .init(host: "127.0.0.1", port: port, username: "tester"),
                                     credential: .password("secret"), connectTimeoutSeconds: 5)
    }

    private func openX11(over transport: Channel) async throws -> Channel {
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 6000)
        return try await transport.eventLoop.flatSubmit {
            transport.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let loop = transport.eventLoop
                let opened = loop.makePromise(of: Channel.self)
                let timeout = loop.scheduleTask(in: .seconds(5)) { transport.close(promise: nil) }
                opened.futureResult.whenComplete { _ in timeout.cancel() }
                ssh.createChannel(opened, channelType: .x11(originatorAddress: address)) { child, _ in
                    child.pipeline.addHandler(SSHByteStream())
                }
                return opened.futureResult
            }
        }.get()
    }

    private func awaitClose(_ channel: Channel) async throws {
        let result = channel.eventLoop.makePromise(of: Void.self)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) { result.fail(X11TestError.timeout) }
        defer { timeout.cancel() }
        channel.closeFuture.cascade(to: result)
        try await result.futureResult.get()
    }

    private static func setup(cookie: [UInt8], order: Endianness, extra: [UInt8] = []) -> ByteBuffer {
        let name = Array("MIT-MAGIC-COOKIE-1".utf8)
        var packet = ByteBuffer()
        packet.writeBytes([order == .little ? 0x6c : 0x42, 0])
        for number in [11, 0, UInt16(name.count), UInt16(cookie.count), 0] { packet.writeInteger(number, endianness: order) }
        packet.writeBytes(name)
        packet.writeRepeatingByte(0, count: (4 - name.count % 4) % 4)
        packet.writeBytes(cookie)
        packet.writeBytes(extra)
        return packet
    }
}

private enum X11TestError: Error { case timeout, closed }

private final class X11FixtureData: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var x11Request: SSHChannelRequestEvent.X11ForwardingRequest?
    private var connections = 0

    var transport: Channel? { lock.withLock { channel } }
    var request: SSHChannelRequestEvent.X11ForwardingRequest? { lock.withLock { x11Request } }
    var displayConnections: Int { lock.withLock { connections } }
    func record(_ channel: Channel) { lock.withLock { self.channel = channel } }
    func record(_ request: SSHChannelRequestEvent.X11ForwardingRequest) { lock.withLock { x11Request = request } }
    func recordDisplayConnection() { lock.withLock { connections += 1 } }
}

private final class FakeDisplay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let expected: [UInt8]
    var buffer = ByteBuffer()

    init(expected: [UInt8]) { self.expected = expected }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        buffer.writeBuffer(&bytes)
        if let received = buffer.readBytes(length: expected.count) {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [received == expected ? 1 : 0])), promise: nil)
        }
    }
}

private final class X11Response: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<UInt8>
    var deadline: Scheduled<Void>?

    init(promise: EventLoopPromise<UInt8>) { self.promise = promise }

    func handlerAdded(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(5)) { self.promise.fail(X11TestError.timeout) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if let byte: UInt8 = unwrapInboundIn(data).getInteger(at: 0) {
            deadline?.cancel()
            promise.succeed(byte)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        promise.fail(X11TestError.closed)
        context.fireChannelInactive()
    }
}
