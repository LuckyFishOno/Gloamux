import Foundation
import NIOCore
import NIOPosix

/// The Telnet protocol (RFC 854) for a terminal: separates data from commands, answers option negotiation, and
/// reports the window size (NAWS, RFC 1073) and terminal type (RFC 1091). It is a value with no I/O, so it can be
/// tested on its own.
public struct TelnetProtocol: Sendable {
    public enum Byte {
        public static let se: UInt8 = 240, sb: UInt8 = 250, will: UInt8 = 251, wont: UInt8 = 252, doOption: UInt8 = 253
        public static let dont: UInt8 = 254, iac: UInt8 = 255
    }
    public enum Option {
        public static let binary: UInt8 = 0, echo: UInt8 = 1, suppressGoAhead: UInt8 = 3, terminalType: UInt8 = 24
        public static let windowSize: UInt8 = 31
    }

    /// Options this side performs when asked, and options it asks the server to perform when offered.
    static let localOptions: Set<UInt8> = [Option.binary, Option.suppressGoAhead, Option.terminalType, Option.windowSize]
    static let remoteOptions: Set<UInt8> = [Option.binary, Option.echo, Option.suppressGoAhead]

    private enum State: Sendable { case data, command, option(UInt8), subnegotiation, subnegotiationCommand }
    private var state = State.data
    private var subnegotiation: [UInt8] = []
    public private(set) var local: Set<UInt8> = []
    public private(set) var remote: Set<UInt8> = []
    public var terminalType: String
    public var rows: Int
    public var columns: Int

    public init(terminalType: String = "XTERM-256COLOR", rows: Int = 24, columns: Int = 80) {
        self.terminalType = terminalType; self.rows = rows; self.columns = columns
    }

    /// Splits bytes from the server into terminal data and the replies to send back.
    public mutating func receive(_ bytes: [UInt8]) -> (data: [UInt8], replies: [UInt8]) {
        var data: [UInt8] = [], replies: [UInt8] = []
        data.reserveCapacity(bytes.count)
        for byte in bytes {
            switch state {
            case .data:
                if byte == Byte.iac { state = .command } else { data.append(byte) }
            case .command:
                switch byte {
                case Byte.iac: data.append(Byte.iac); state = .data
                case Byte.will, Byte.wont, Byte.doOption, Byte.dont: state = .option(byte)
                case Byte.sb: subnegotiation = []; state = .subnegotiation
                default: state = .data
                }
            case .option(let verb):
                replies += negotiate(verb, byte)
                state = .data
            case .subnegotiation:
                if byte == Byte.iac { state = .subnegotiationCommand }
                else if subnegotiation.count < 512 { subnegotiation.append(byte) }
            case .subnegotiationCommand:
                if byte == Byte.se { replies += answerSubnegotiation(); state = .data }
                else { if byte == Byte.iac, subnegotiation.count < 512 { subnegotiation.append(byte) }; state = .subnegotiation }
            }
        }
        return (data, replies)
    }

    private mutating func negotiate(_ verb: UInt8, _ option: UInt8) -> [UInt8] {
        switch verb {
        case Byte.doOption:
            guard Self.localOptions.contains(option) else { return [Byte.iac, Byte.wont, option] }
            guard local.insert(option).inserted else { return [] }
            return [Byte.iac, Byte.will, option] + (option == Option.windowSize ? windowSizeReport() : [])
        case Byte.dont:
            guard local.remove(option) != nil else { return [] }
            return [Byte.iac, Byte.wont, option]
        case Byte.will:
            guard Self.remoteOptions.contains(option) else { return [Byte.iac, Byte.dont, option] }
            guard remote.insert(option).inserted else { return [] }
            return [Byte.iac, Byte.doOption, option]
        default:
            guard remote.remove(option) != nil else { return [] }
            return [Byte.iac, Byte.dont, option]
        }
    }

    private func answerSubnegotiation() -> [UInt8] {
        // TERMINAL-TYPE SEND: reply IS and the type.
        guard subnegotiation == [Option.terminalType, 1], local.contains(Option.terminalType) else { return [] }
        return [Byte.iac, Byte.sb, Option.terminalType, 0] + Array(terminalType.utf8.prefix(40)) + [Byte.iac, Byte.se]
    }

    /// The window size, once the server has asked for it.
    public mutating func resize(rows: Int, columns: Int) -> [UInt8] {
        self.rows = rows; self.columns = columns
        return local.contains(Option.windowSize) ? windowSizeReport() : []
    }

    private func windowSizeReport() -> [UInt8] {
        let width = UInt16(clamping: columns), height = UInt16(clamping: rows)
        var body: [UInt8] = []
        for value in [UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)] {
            body.append(value)
            if value == Byte.iac { body.append(Byte.iac) }
        }
        return [Byte.iac, Byte.sb, Option.windowSize] + body + [Byte.iac, Byte.se]
    }

    /// Typed bytes for the wire: IAC doubled, and a carriage return followed by NUL outside binary mode, as NVT requires.
    public func encode(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count + 4)
        let binary = local.contains(Option.binary)
        for (index, byte) in input.enumerated() {
            output.append(byte)
            if byte == Byte.iac { output.append(Byte.iac) }
            else if byte == 0x0D, !binary, index + 1 >= input.count || input[index + 1] != 0x0A { output.append(0) }
        }
        return output
    }
}

/// A Telnet connection for a terminal: bytes from the server arrive through `output`, typed bytes go out with `send`.
public final class TelnetConnection: @unchecked Sendable {
    private let channel: Channel
    private let handler: TelnetHandler

    private init(channel: Channel, handler: TelnetHandler) { self.channel = channel; self.handler = handler }

    /// Connects directly or through a proxy. `output` gets terminal data; an empty array means the connection closed.
    public static func connect(host: String, port: Int, proxy: ProxyConfiguration = .direct, terminalType: String,
                               rows: Int, columns: Int, output: @escaping @Sendable ([UInt8]) -> Void) async throws -> TelnetConnection {
        let channel = try await NetworkConnector.connect(host: host, port: port, proxy: proxy,
                                                         group: MultiThreadedEventLoopGroup.singleton, connectTimeout: .seconds(15))
        let handler = TelnetHandler(protocol: TelnetProtocol(terminalType: terminalType.uppercased(), rows: rows, columns: columns), output: output)
        try await channel.pipeline.addHandler(handler).get()
        return TelnetConnection(channel: channel, handler: handler)
    }

    public func send(_ bytes: [UInt8]) {
        let handler = handler, channel = channel
        channel.eventLoop.execute { handler.send(bytes, on: channel) }
    }

    public func resize(rows: Int, columns: Int) {
        let handler = handler, channel = channel
        channel.eventLoop.execute { handler.resize(rows: rows, columns: columns, on: channel) }
    }

    public func close() { channel.close(promise: nil) }
}

/// Confined to the channel's event loop.
private final class TelnetHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var telnet: TelnetProtocol
    private let output: @Sendable ([UInt8]) -> Void

    init(protocol telnet: TelnetProtocol, output: @escaping @Sendable ([UInt8]) -> Void) { self.telnet = telnet; self.output = output }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let (bytes, replies) = telnet.receive(Array(buffer.readableBytesView))
        if !replies.isEmpty { context.writeAndFlush(NIOAny(context.channel.allocator.buffer(bytes: replies)), promise: nil) }
        if !bytes.isEmpty { output(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) { output([]); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    func send(_ bytes: [UInt8], on channel: Channel) {
        channel.writeAndFlush(channel.allocator.buffer(bytes: telnet.encode(bytes)), promise: nil)
    }

    func resize(rows: Int, columns: Int, on channel: Channel) {
        let report = telnet.resize(rows: rows, columns: columns)
        if !report.isEmpty { channel.writeAndFlush(channel.allocator.buffer(bytes: report), promise: nil) }
    }
}
