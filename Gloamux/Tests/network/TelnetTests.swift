import XCTest
import Foundation
import NIOCore
import NIOPosix
@testable import GloamuxNetwork

final class TelnetTests: XCTestCase {
    typealias B = TelnetProtocol.Byte
    typealias O = TelnetProtocol.Option

    func testSeparatesDataFromCommandsAndUnescapesIAC() {
        var telnet = TelnetProtocol()
        let (data, replies) = telnet.receive([0x68, 0x69, B.iac, B.iac, 0x21, B.iac, 241, 0x0A])
        XCTAssertEqual(data, [0x68, 0x69, 0xFF, 0x21, 0x0A])
        XCTAssertEqual(replies, [])
    }

    func testCommandsSplitAcrossReadsStillParse() {
        var telnet = TelnetProtocol()
        XCTAssertEqual(telnet.receive([0x41, B.iac]).data, [0x41])
        let second = telnet.receive([B.will])
        XCTAssertEqual(second.data, []); XCTAssertEqual(second.replies, [])
        let third = telnet.receive([O.echo, 0x42])
        XCTAssertEqual(third.data, [0x42])
        XCTAssertEqual(third.replies, [B.iac, B.doOption, O.echo])
    }

    func testAcceptsKnownOptionsOnceAndRefusesOthers() {
        var telnet = TelnetProtocol(terminalType: "XTERM-256COLOR", rows: 40, columns: 120)
        XCTAssertEqual(telnet.receive([B.iac, B.will, O.suppressGoAhead]).replies, [B.iac, B.doOption, O.suppressGoAhead])
        XCTAssertEqual(telnet.receive([B.iac, B.will, O.suppressGoAhead]).replies, [], "no reply loop for a repeated offer")
        XCTAssertEqual(telnet.receive([B.iac, B.will, 39]).replies, [B.iac, B.dont, 39])
        XCTAssertEqual(telnet.receive([B.iac, B.doOption, 39]).replies, [B.iac, B.wont, 39])
        XCTAssertEqual(telnet.receive([B.iac, B.doOption, O.echo]).replies, [B.iac, B.wont, O.echo], "the client never echoes for the server")
        // NAWS: agree, then report 120 × 40 right away.
        XCTAssertEqual(telnet.receive([B.iac, B.doOption, O.windowSize]).replies,
                       [B.iac, B.will, O.windowSize, B.iac, B.sb, O.windowSize, 0, 120, 0, 40, B.iac, B.se])
        XCTAssertEqual(telnet.resize(rows: 50, columns: 255),
                       [B.iac, B.sb, O.windowSize, 0, 255, 255, 0, 50, B.iac, B.se], "a 255 in the size is doubled")
        XCTAssertEqual(telnet.receive([B.iac, B.dont, O.windowSize]).replies, [B.iac, B.wont, O.windowSize])
        XCTAssertEqual(telnet.resize(rows: 30, columns: 90), [], "no reports after the server turns NAWS off")
    }

    func testAnswersTerminalTypeOnlyAfterAgreeing() {
        var telnet = TelnetProtocol(terminalType: "VT100")
        let send: [UInt8] = [B.iac, B.sb, O.terminalType, 1, B.iac, B.se]
        XCTAssertEqual(telnet.receive(send).replies, [])
        XCTAssertEqual(telnet.receive([B.iac, B.doOption, O.terminalType]).replies, [B.iac, B.will, O.terminalType])
        XCTAssertEqual(telnet.receive(send).replies, [B.iac, B.sb, O.terminalType, 0] + Array("VT100".utf8) + [B.iac, B.se])
    }

    func testEncodesTypedBytesForTheWire() {
        var telnet = TelnetProtocol()
        XCTAssertEqual(telnet.encode([0x61, 0xFF, 0x0D]), [0x61, 0xFF, 0xFF, 0x0D, 0x00])
        XCTAssertEqual(telnet.encode([0x0D, 0x0A]), [0x0D, 0x0A])
        _ = telnet.receive([B.iac, B.doOption, O.binary])
        XCTAssertEqual(telnet.encode([0x0D]), [0x0D], "binary mode sends a bare carriage return")
    }

    func testNegotiatesWithALoopbackServer() async throws {
        let received = Collected()
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in channel.pipeline.addHandler(FakeTelnetServer(received: received)) }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        let output = Collected()
        let connection = try await TelnetConnection.connect(host: "127.0.0.1", port: server.localAddress!.port!, terminalType: "xterm-256color",
                                                            rows: 30, columns: 100) { output.append($0) }
        defer { connection.close() }
        try await waitUntil { output.bytes.count >= 12 }
        XCTAssertEqual(output.bytes, Array("login: ".utf8) + [0xFF] + Array("ok\r\n".utf8))
        try await waitUntil { received.bytes.contains(B.se) && received.bytes.count >= 30 }
        let replies = received.bytes
        XCTAssertTrue(replies.starts(with: [B.iac, B.doOption, O.echo, B.iac, B.doOption, O.suppressGoAhead]))
        XCTAssertTrue(replies.contains(subsequence: [B.iac, B.sb, O.windowSize, 0, 100, 0, 30, B.iac, B.se]))
        XCTAssertTrue(replies.contains(subsequence: [B.iac, B.sb, O.terminalType, 0] + Array("XTERM-256COLOR".utf8) + [B.iac, B.se]))
        let before = received.bytes.count
        connection.send(Array("ls\r".utf8))
        try await waitUntil { received.bytes.count >= before + 4 }
        XCTAssertEqual(Array(received.bytes[before...]), [0x6C, 0x73, 0x0D, 0x00])
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("timed out")
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []
    var bytes: [UInt8] { lock.withLock { storage } }
    func append(_ new: [UInt8]) { lock.withLock { storage += new } }
}

/// Offers ECHO and SGA, asks for NAWS and TTYPE, asks for the type, then prints a prompt with an escaped 255.
private final class FakeTelnetServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let received: Collected
    init(received: Collected) { self.received = received }

    func channelActive(context: ChannelHandlerContext) {
        typealias B = TelnetProtocol.Byte
        typealias O = TelnetProtocol.Option
        var bytes: [UInt8] = [B.iac, B.will, O.echo, B.iac, B.will, O.suppressGoAhead, B.iac, B.doOption, O.windowSize,
                              B.iac, B.doOption, O.terminalType, B.iac, B.sb, O.terminalType, 1, B.iac, B.se]
        bytes += Array("login: ".utf8) + [B.iac, B.iac] + Array("ok\r\n".utf8)
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(bytes: bytes)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received.append(Array(unwrapInboundIn(data).readableBytesView))
    }
}

private extension Array where Element == UInt8 {
    func contains(subsequence: [UInt8]) -> Bool {
        guard subsequence.count <= count else { return false }
        return (0...(count - subsequence.count)).contains { Array(self[$0..<($0 + subsequence.count)]) == subsequence }
    }
}
