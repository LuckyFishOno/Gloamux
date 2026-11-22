import Foundation
import NIOCore
import NIOSSH

public final class SSHInteractiveShell: @unchecked Sendable {
    public let output: SSHShellOutput
    private let channel: Channel
    private let exit: ShellExit
    init(channel: Channel, output: SSHShellOutput, exit: ShellExit) { self.channel = channel; self.output = output; self.exit = exit }
    /// Set once the server reports how the shell ended (`exit`, `logout`, a signal). It stays nil when the
    /// channel closed without one, such as a dropped connection.
    public var exitStatus: Int? { exit.status }
    public func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty, bytes.count <= 262144 else { if bytes.isEmpty { return }; throw SSHError.invalidSettings("Terminal input exceeds 256 KiB.") }
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))).get()
    }
    public func resize(rows: Int, columns: Int) async throws {
        guard (1...500).contains(rows), (1...1000).contains(columns) else { throw SSHError.invalidSettings("Invalid terminal dimensions.") }
        try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)).get()
    }
    public func close() async { try? await channel.close().get() }
}

/// What the shell prints, in the order it arrives. Reading it is what lets more arrive: while the reader is far behind,
/// the channel stops reading, the SSH window fills, and the server waits, so fast output (`cat` of a large file,
/// `yes`) slows to the reader's pace instead of piling up in memory or ending the shell.
public struct SSHShellOutput: AsyncSequence, Sendable {
    public typealias Element = [UInt8]
    let stream: AsyncThrowingStream<[UInt8], Error>
    let gate: ShellOutputGate
    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<[UInt8], Error>.AsyncIterator
        let gate: ShellOutputGate
        public mutating func next() async throws -> [UInt8]? {
            let bytes = try await base.next()
            if bytes != nil { gate.consumed() }
            return bytes
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: stream.makeAsyncIterator(), gate: gate) }
}

/// Counts chunks handed to the reader but not yet taken. Above `high` the channel holds its next read; once the
/// reader is back down to `low`, the held read goes ahead.
final class ShellOutputGate: @unchecked Sendable {
    static let high = 64, low = 16
    private let lock = NSLock()
    private var pending = 0
    private var held: Channel?
    func produced() { lock.withLock { pending += 1 } }
    /// On the event loop, for a read the channel wants: false when it should wait for the reader.
    func allowsRead(_ channel: Channel) -> Bool {
        lock.withLock {
            guard pending >= Self.high else { return true }
            held = channel
            return false
        }
    }
    func consumed() {
        let resume: Channel? = lock.withLock {
            pending -= 1
            guard pending <= Self.low, let channel = held else { return nil }
            held = nil
            return channel
        }
        resume?.read()
    }
}

/// Written on the event loop before the output stream finishes, read by the consumer afterwards.
final class ShellExit: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    var status: Int? { lock.withLock { value } }
    func record(_ status: Int) { lock.withLock { if value == nil { value = status } } }
}

final class InteractiveShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private let ready: EventLoopPromise<Void>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let rows: Int, columns: Int
    private let term: String
    private let forwardsAgent: Bool
    private let x11: X11ForwardState?
    private weak var router: InboundChannelRouter?
    private enum Stage { case starting, x11, pty, shell, ready }
    private var stage = Stage.starting
    private var finished = false
    let exit = ShellExit()
    let gate = ShellOutputGate()
    private var received: [UInt8] = []
    init(ready: EventLoopPromise<Void>, continuation: AsyncThrowingStream<[UInt8], Error>.Continuation, rows: Int, columns: Int,
         term: String = "xterm-256color", forwardsAgent: Bool = false, x11: X11ForwardState? = nil,
         router: InboundChannelRouter? = nil) {
        self.ready = ready; self.continuation = continuation; self.rows = rows; self.columns = columns
        self.term = term; self.forwardsAgent = forwardsAgent; self.x11 = x11; self.router = router
    }
    func channelActive(context: ChannelHandlerContext) {
        // Without a reply, as OpenSSH sends it: a server that refuses agent forwarding still opens the shell.
        if forwardsAgent { context.triggerUserOutboundEvent(SSHChannelRequestEvent.AgentForwardingRequest(wantReply: false), promise: nil) }
        if let x11 {
            guard let router, router.x11 == nil else {
                fail(SSHError.commandFailed("X11 forwarding is already enabled on this connection."))
                context.close(promise: nil)
                return
            }
            router.x11 = x11
            stage = .x11
            context.triggerUserOutboundEvent(x11.request).whenFailure { error in self.fail(error); context.close(promise: nil) }
        } else {
            requestPTY(context)
        }
        context.fireChannelActive()
    }
    private func requestPTY(_ context: ChannelHandlerContext) {
        stage = .pty
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: term, terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:])))
            .whenFailure { error in self.fail(error); context.close(promise: nil) }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            switch stage {
            case .x11:
                x11?.enabled = true
                requestPTY(context)
            case .pty:
                stage = .shell
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).whenFailure { error in self.fail(error); context.close(promise: nil) }
            case .shell:
                stage = .ready
                ready.succeed(())
            case .starting, .ready: break
            }
        } else if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exit.record(status.exitStatus)
        } else if event is SSHChannelRequestEvent.ExitSignal {
            exit.record(128)
        } else if event is ChannelFailureEvent {
            let reason: String
            switch stage {
            case .x11: reason = "The SSH server refused X11 forwarding."
            case .pty: reason = "Server rejected PTY request."
            default: reason = "Server rejected shell request."
            }
            fail(SSHError.commandFailed(reason))
            context.close(promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data, message.type == .channel || message.type == .stdErr else { return }
        // A shell's output arrives in many small packets (often a line each); one chunk per read keeps the reader's
        // work per byte low.
        received.append(contentsOf: bytes.readableBytesView)
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        if !received.isEmpty {
            gate.produced()
            continuation.yield(received)
            received = []
        }
        context.fireChannelReadComplete()
    }
    func read(context: ChannelHandlerContext) {
        if gate.allowsRead(context.channel) { context.read() }
    }
    func startupTimeout(channel: Channel) {
        guard stage != .ready, !finished else { return }
        fail(SSHError.commandFailed("PTY/shell startup timed out.")); channel.close(promise: nil)
    }
    func fail(_ error: Error) {
        guard !finished else { return }; finished = true
        if stage != .ready { ready.fail(error) }; continuation.finish(throwing: error)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) {
        if !received.isEmpty { gate.produced(); continuation.yield(received); received = [] }
        if let x11, router?.x11 === x11 { router?.x11 = nil }
        x11?.stop()
        if !finished {
            if stage != .ready { fail(SSHError.commandFailed("Shell closed before startup completed.")) }
            else { finished = true; continuation.finish() }
        }
        context.fireChannelInactive()
    }
}

extension SSHSession {
    /// Opens a shell on a pseudo-terminal. `term` is the TERM the server's programs see. With `agentSocket`, the server
    /// may reach that SSH agent through this shell's connection (`ssh -A`).
    public func openShell(rows: Int = 24, columns: Int = 80, term: String = "xterm-256color", agentSocket: String? = nil,
                          x11: SSHX11Configuration? = nil,
                          timeoutSeconds: Int64 = 15) async throws -> SSHInteractiveShell {
        guard (1...500).contains(rows), (1...1000).contains(columns), (1...120).contains(timeoutSeconds) else { throw SSHError.invalidSettings("Invalid terminal dimensions or timeout.") }
        guard !term.isEmpty, term.utf8.count <= 64, term.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.+".contains($0)) }) else {
            throw SSHError.invalidSettings("Invalid terminal type.")
        }
        if let agentSocket {
            let router = inbound
            try await channel.eventLoop.submit { router.agentSocket = agentSocket }.get()
        }
        let x11Forward = try x11?.makeForward()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        // Unbounded, since the gate and the SSH window bound it: at most a read's worth past the high mark.
        let pair = AsyncThrowingStream<[UInt8], Error>.makeStream(bufferingPolicy: .unbounded)
        let shellHandler = InteractiveShellHandler(ready: ready, continuation: pair.continuation, rows: rows, columns: columns,
                                                   term: term, forwardsAgent: agentSocket != nil, x11: x11Forward, router: inbound)
        // Consume ready failures even if channel creation is rejected before handler installation.
        ready.futureResult.whenFailure { _ in }
        let child: Channel
        do { child = try await openChildChannel(timeoutSeconds: timeoutSeconds) { $0.pipeline.addHandler(shellHandler) } }
        catch { try? await channel.eventLoop.submit { shellHandler.fail(error) }.get(); throw error }
        let deadline = child.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            shellHandler.startupTimeout(channel: child)
        }
        defer { deadline.cancel() }
        do { try await ready.futureResult.get() }
        catch { try? await child.close().get(); throw error }
        return SSHInteractiveShell(channel: child, output: SSHShellOutput(stream: pair.stream, gate: shellHandler.gate), exit: shellHandler.exit)
    }
}
