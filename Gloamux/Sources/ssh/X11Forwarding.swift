import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Security

public struct SSHX11Configuration: Sendable {
    static let protocolName = "MIT-MAGIC-COOKIE-1"

    enum Endpoint: Equatable, Sendable {
        case socket(String)
        case tcp(String, Int)
    }

    let endpoint: Endpoint
    let screen: UInt32
    private let cookie: [UInt8]

    init(endpoint: Endpoint, screen: UInt32 = 0, cookie: [UInt8]) throws {
        guard cookie.count == 16 else { throw Self.authorizationUnavailable }
        self.endpoint = endpoint
        self.screen = screen
        self.cookie = cookie
    }

    /// Uses the local XQuartz display and its existing authorization. The SSH peer receives only a substitute cookie.
    public static func localDisplay() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let display = environment["DISPLAY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? localCommand("/bin/launchctl", ["getenv", "DISPLAY"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let display, let (endpoint, screen) = parseDisplay(display) else {
            throw SSHError.commandFailed("X11 display unavailable. Start XQuartz and try again.")
        }
        let tools = ["/opt/X11/bin/xauth", "/usr/X11/bin/xauth"]
        guard let xauth = tools.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let listing = localCommand(xauth, ["-i", "list", display]),
              let cookie = parseAuthority(listing) else {
            throw authorizationUnavailable
        }
        return try Self(endpoint: endpoint, screen: screen, cookie: cookie)
    }

    static func parseDisplay(_ display: String) -> (Endpoint, UInt32)? {
        guard !display.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let separator = display.lastIndex(of: ":") else { return nil }
        let host = String(display[..<separator])
        let fields = display[display.index(after: separator)...].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(fields.count), let displayNumber = Int(fields[0]), (0...59535).contains(displayNumber) else { return nil }
        let screen: UInt32
        if fields.count == 2 {
            guard let number = UInt32(fields[1]) else { return nil }
            screen = number
        } else {
            screen = 0
        }
        if host.hasPrefix("/") { return (.socket(host + ":\(displayNumber)"), screen) }
        if ["", "unix", "unix/"].contains(host) { return (.socket("/tmp/.X11-unix/X\(displayNumber)"), screen) }
        switch host {
        case "localhost", "127.0.0.1": return (.tcp("127.0.0.1", 6000 + displayNumber), screen)
        case "[::1]", "::1": return (.tcp("::1", 6000 + displayNumber), screen)
        default: return nil
        }
    }

    static func parseAuthority(_ listing: String) -> [UInt8]? {
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[1] == protocolName else { continue }
            let value = Array(fields[2].utf8)
            guard value.count == 32 else { continue }
            let bytes = stride(from: 0, to: value.count, by: 2).compactMap {
                UInt8(String(decoding: value[$0..<$0 + 2], as: UTF8.self), radix: 16)
            }
            if bytes.count == 16 { return bytes }
        }
        return nil
    }

    func makeForward() throws -> X11ForwardState {
        var substitute = [UInt8](repeating: 0, count: cookie.count)
        let status = substitute.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Self.authorizationUnavailable }
        return X11ForwardState(endpoint: endpoint, screen: screen, cookie: cookie, substitute: substitute)
    }

    private static var authorizationUnavailable: SSHError {
        .commandFailed("X11 authorization unavailable. Check XQuartz and its xauth settings.")
    }

    private static func localCommand(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Each shell owns its substitute and inbound X11 channels. Mutable state is confined to the SSH event loop.
final class X11ForwardState: @unchecked Sendable {
    let request: SSHChannelRequestEvent.X11ForwardingRequest
    private let endpoint: SSHX11Configuration.Endpoint
    private let cookie: [UInt8]
    private let substitute: [UInt8]
    private var channels: [ObjectIdentifier: Channel] = [:]
    var enabled = false

    init(endpoint: SSHX11Configuration.Endpoint, screen: UInt32, cookie: [UInt8], substitute: [UInt8]) {
        self.endpoint = endpoint
        self.cookie = cookie
        self.substitute = substitute
        request = .init(wantReply: true, singleConnection: false, authenticationProtocol: SSHX11Configuration.protocolName,
                        authenticationCookie: substitute.map { String(format: "%02x", $0) }.joined(), screenNumber: screen)
    }

    func accept(_ child: Channel) -> EventLoopFuture<Void> {
        guard enabled, channels.count < 32 else {
            return child.eventLoop.makeFailedFuture(SSHError.connectFailed("X11 forwarding was not enabled."))
        }
        let id = ObjectIdentifier(child)
        channels[id] = child
        child.closeFuture.whenComplete { [weak self] _ in self?.channels.removeValue(forKey: id) }
        let gate = X11SetupHandler(cookie: cookie, substitute: substitute) { [weak self] in
            guard let self, self.enabled, child.isActive else { return child.eventLoop.makeFailedFuture(SSHError.notConnected) }
            return self.relay(child)
        }
        return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            child.pipeline.addHandlers([SSHByteStream(), gate])
        }
    }

    func stop() {
        enabled = false
        let opened = Array(channels.values)
        channels.removeAll()
        for channel in opened { channel.close(promise: nil) }
    }

    private func relay(_ child: Channel) -> EventLoopFuture<Void> {
        let (client, server) = RelaySide.pair()
        let bootstrap = ClientBootstrap(group: child.eventLoop).connectTimeout(.seconds(5))
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { $0.pipeline.addHandler(client) }
        let connection: EventLoopFuture<Channel>
        switch endpoint {
        case .socket(let path): connection = bootstrap.connect(unixDomainSocketPath: path)
        case .tcp(let host, let port): connection = bootstrap.connect(host: host, port: port)
        }
        return connection.flatMap { local in
            child.closeFuture.whenComplete { _ in local.close(promise: nil) }
            return child.pipeline.addHandler(server)
        }
    }
}

enum X11Setup {
    /// Validates the fixed X11 setup header and rewrites its authorization in place, preserving trailing bytes.
    /// Returns false for a partial setup and throws for a nonmatching setup.
    static func rewrite(_ buffer: inout ByteBuffer, substitute: [UInt8], cookie: [UInt8]) throws -> Bool {
        let start = buffer.readerIndex
        guard buffer.readableBytes >= 12 else { return false }
        let order: Endianness
        switch buffer.getInteger(at: start, as: UInt8.self) {
        case 0x42: order = .big
        case 0x6c: order = .little
        default: throw invalid
        }
        let protocolBytes = Array(SSHX11Configuration.protocolName.utf8)
        let dataStart = start + 12 + (protocolBytes.count + 3) / 4 * 4
        guard buffer.getInteger(at: start + 2, endianness: order, as: UInt16.self) == 11,
              buffer.getInteger(at: start + 6, endianness: order, as: UInt16.self) == UInt16(protocolBytes.count),
              buffer.getInteger(at: start + 8, endianness: order, as: UInt16.self) == UInt16(substitute.count) else { throw invalid }
        guard let actual = buffer.getBytes(at: dataStart, length: substitute.count) else { return false }
        let mismatch = zip(actual, substitute).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard buffer.getBytes(at: start + 12, length: protocolBytes.count) == protocolBytes, mismatch == 0 else { throw invalid }
        buffer.setBytes(cookie, at: dataStart)
        return true
    }

    private static var invalid: SSHError { .connectFailed("X11 authorization was rejected.") }
}

/// Only an authorized setup opens the local display. While it connects, bound the incoming buffer.
final class X11SetupHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    private let cookie: [UInt8]
    private let substitute: [UInt8]
    private let connect: () -> EventLoopFuture<Void>
    private var pending = ByteBuffer()
    private var connecting = false
    private var deadline: Scheduled<Void>?

    init(cookie: [UInt8], substitute: [UInt8], connect: @escaping () -> EventLoopFuture<Void>) {
        self.cookie = cookie
        self.substitute = substitute
        self.connect = connect
    }

    func handlerAdded(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(10)) { context.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel() }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        guard pending.readableBytes + bytes.readableBytes <= 256 * 1024 else { context.close(promise: nil); return }
        pending.writeBuffer(&bytes)
        guard !connecting else { return }
        do {
            guard try X11Setup.rewrite(&pending, substitute: substitute, cookie: cookie) else { return }
        } catch {
            context.close(promise: nil)
            return
        }
        connecting = true
        connect().whenComplete { result in
            guard case .success = result, context.channel.isActive else { context.close(promise: nil); return }
            context.fireChannelRead(self.wrapInboundOut(self.pending))
            context.fireChannelReadComplete()
            self.pending.clear()
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        }
    }
}
