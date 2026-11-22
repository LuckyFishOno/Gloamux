import Foundation
import NIOCore
import NIOSSH
import Ssh

/// Files over SSH for servers with no SFTP subsystem, as WinSCP's SCP mode does: copies use the classic `scp -f` and
/// `scp -t` protocol, and listing, renaming, and deleting run POSIX commands through `sh`. The server needs `scp` and
/// a POSIX `ls`. Host-key checks and sign-in are the SSH session's own.
public actor SCPTransfer: RemoteFileSystem {
    private let session: SSHSession
    public nonisolated var protocolName: String { "SCP" }

    public init(session: SSHSession) { self.session = session }

    /// Checks that the server can run `scp` before the browser uses it.
    public static func open(_ session: SSHSession) async throws -> SCPTransfer {
        let transfer = SCPTransfer(session: session)
        let found = try await transfer.shell("command -v scp >/dev/null 2>&1 && echo yes || echo no")
        guard found.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" else {
            throw TransferError.remoteError("The server has neither SFTP nor scp.")
        }
        return transfer
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a script with `sh`, whatever the login shell is, and returns its output.
    private func shell(_ script: String, limit: Int = 8 << 20) async throws -> String {
        do { return try await session.runCommand("sh -c " + Self.quote(script), maxResponseBytes: limit, includeStandardError: true) }
        catch let SSHError.commandFailed(detail) {
            let lines = detail.split(separator: "\n", omittingEmptySubsequences: true)
            let output = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw TransferError.remoteError(output.isEmpty ? detail : output)
        }
    }

    public func readDirectory(_ path: String) async throws -> (path: String, entries: [RemoteEntry]) {
        let folder = path.isEmpty || path == "~" ? "." : try checkedPath(path)
        let output = try await shell("cd -- \(Self.quote(folder)) || exit 1; pwd; LC_ALL=C ls -lanL 2>/dev/null; :")
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let resolved = lines.first, resolved.hasPrefix("/") else { throw TransferError.remoteError(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        lines.removeFirst()
        let entries = lines.compactMap { UnixListing.parse($0) }
        return (resolved, entries.sorted { $0.name < $1.name })
    }

    public func entry(at path: String) async throws -> RemoteEntry? {
        let output = try await shell("if [ -e \(Self.quote(try checkedPath(path))) ]; then LC_ALL=C ls -ldnL -- \(Self.quote(path)); else echo GLOAMUX-MISSING; fi")
        let line = output.trimmingCharacters(in: .newlines)
        if line == "GLOAMUX-MISSING" { return nil }
        guard var entry = UnixListing.parse(line) else {
            throw TransferError.remoteError(line)
        }
        entry.name = (path as NSString).lastPathComponent
        return entry
    }

    public func resolve(_ path: String) async throws -> String {
        let folder = path.isEmpty || path == "~" ? "." : try checkedPath(path)
        let output = try await shell("cd -- \(Self.quote(folder)) && pwd").trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.hasPrefix("/") else { throw TransferError.remoteError(output) }
        return output
    }

    public func makeDirectory(_ path: String) async throws { _ = try await shell("mkdir -- \(Self.quote(try checkedPath(path)))") }
    public func removeFile(_ path: String) async throws { _ = try await shell("rm -f -- \(Self.quote(try checkedPath(path)))") }
    public func removeDirectory(_ path: String) async throws { _ = try await shell("rmdir -- \(Self.quote(try checkedPath(path)))") }
    public func rename(from: String, to: String) async throws {
        _ = try await shell("mv -- \(Self.quote(try checkedPath(from))) \(Self.quote(try checkedPath(to)))")
    }
    public func setPermissions(_ path: String, mode: UInt32) async throws {
        _ = try await shell("chmod -- \(octalMode(mode)) \(Self.quote(try checkedPath(path)))")
    }

    /// scp always copies a whole file.
    public func canResume() -> Bool { false }
    public func resumeDownload(remotePath: String, to localURL: URL, offset: UInt64, progress: ProgressHandler?) async throws {
        guard offset == 0 else { throw TransferError.remoteError("The server cannot continue a copy.") }
        try await download(remotePath: remotePath, to: localURL, progress: progress)
    }
    public func resumeUpload(localURL: URL, to remotePath: String, offset: UInt64, progress: ProgressHandler?) async throws {
        guard offset == 0 else { throw TransferError.remoteError("The server cannot continue a copy.") }
        try await upload(localURL: localURL, to: remotePath, progress: progress)
    }
    public nonisolated var isOpen: Bool { session.isOpen }
    public func close() async throws {}

    // MARK: Copies

    /// `scp -f`: the server sends `C<mode> <size> <name>`, then the bytes, each step answered with a zero byte.
    public func download(remotePath: String, to localURL: URL, progress: ProgressHandler?) async throws {
        let stream = try await SSHExecStream.open(session, command: "scp -f -- " + Self.quote(try checkedPath(remotePath)))
        defer { stream.close() }
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: localURL) else { throw TransferError.localFileError("cannot write \(localURL.path)") }
        defer { try? out.close() }
        stream.send([0])
        var header: String
        repeat {
            guard let line = try await Self.record(stream) else { throw TransferError.remoteError(await stream.failureText("scp stopped before sending the file.")) }
            header = line
            if header.hasPrefix("T") { stream.send([0]) }
        } while header.hasPrefix("T")
        if header.hasPrefix("D") { throw TransferError.remoteError("This is a folder.") }
        let fields = header.split(separator: " ", maxSplits: 2)
        guard header.hasPrefix("C"), fields.count == 3, let total = UInt64(fields[1]) else {
            throw TransferError.remoteError("scp sent an unexpected reply.")
        }
        stream.send([0])
        var received: UInt64 = 0
        progress?(TransferProgress(bytesTransferred: 0, totalBytes: total))
        while received < total {
            try Task.checkCancellation()
            let chunk = try await stream.output.read(upTo: Int(min(UInt64(256 * 1024), total - received)))
            guard !chunk.isEmpty else { throw TransferError.remoteError("The connection closed during the copy.") }
            try out.write(contentsOf: chunk)
            received += UInt64(chunk.count)
            progress?(TransferProgress(bytesTransferred: received, totalBytes: total))
        }
        try await Self.acknowledgement(stream)
        stream.send([0])
    }

    /// `scp -t`: Gloamux sends `C<mode> <size> <name>` and the bytes, and the server answers each step.
    public func upload(localURL: URL, to remotePath: String, progress: ProgressHandler?) async throws {
        guard let input = try? FileHandle(forReadingFrom: localURL) else { throw TransferError.localFileError("cannot read \(localURL.path)") }
        defer { try? input.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let mode = ((attributes?[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644) & 0o777
        let name = try checkedPath((remotePath as NSString).lastPathComponent)
        let stream = try await SSHExecStream.open(session, command: "scp -t -- " + Self.quote(try checkedPath(remotePath)))
        defer { stream.close() }
        try await Self.acknowledgement(stream)
        stream.send(Array(String(format: "C%04o %llu %@\n", mode, total, name).utf8))
        try await Self.acknowledgement(stream)
        var sent: UInt64 = 0
        progress?(TransferProgress(bytesTransferred: 0, totalBytes: total))
        while sent < total {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 64 * 1024), !data.isEmpty else { break }
            try await stream.write(Array(data))
            sent += UInt64(data.count)
            progress?(TransferProgress(bytesTransferred: sent, totalBytes: total))
        }
        guard sent == total else { throw TransferError.localFileError("The file changed while it was being copied.") }
        stream.send([0])
        try await Self.acknowledgement(stream)
        stream.finishInput()
        _ = await stream.exitStatus()
    }

    /// A protocol line, or nil when the stream ends. Warnings and errors (bytes 1 and 2) are thrown.
    private static func record(_ stream: SSHExecStream) async throws -> String? {
        guard let first = try await stream.output.readByte() else { return nil }
        if first == 1 || first == 2 {
            throw TransferError.remoteError((try await stream.output.readLine() ?? "scp failed").trimmingCharacters(in: .whitespaces))
        }
        let rest = try await stream.output.readLine() ?? ""
        return String(decoding: [first], as: UTF8.self) + rest
    }

    private static func acknowledgement(_ stream: SSHExecStream) async throws {
        guard let byte = try await stream.output.readByte() else { throw TransferError.remoteError(await stream.failureText("scp closed the connection.")) }
        guard byte == 0 else {
            let detail = (try await stream.output.readLine() ?? "").trimmingCharacters(in: .whitespaces)
            throw TransferError.remoteError(detail.isEmpty ? "scp refused the copy." : detail)
        }
    }
}

/// A command on its own SSH channel with its output as a byte stream, for protocols such as SCP.
final class SSHExecStream: @unchecked Sendable {
    let output: ByteQueue
    private let channel: Channel
    private let handler: ExecStreamHandler

    private init(channel: Channel, handler: ExecStreamHandler) { self.channel = channel; self.handler = handler; output = handler.output }

    static func open(_ session: SSHSession, command: String) async throws -> SSHExecStream {
        let handler = ExecStreamHandler(command: command, output: ByteQueue())
        let channel = try await session.openChildChannel { child in child.pipeline.addHandler(handler) }
        return SSHExecStream(channel: channel, handler: handler)
    }

    func send(_ bytes: [UInt8]) { channel.writeAndFlush(channel.allocator.buffer(bytes: bytes), promise: nil) }

    /// Writes and waits until the bytes are handed to the SSH connection, so a large file is not buffered whole.
    func write(_ bytes: [UInt8]) async throws { try await channel.writeAndFlush(channel.allocator.buffer(bytes: bytes)).get() }

    func finishInput() { channel.close(mode: .output, promise: nil) }

    func exitStatus() async -> Int? {
        try? await channel.closeFuture.get()
        return handler.status
    }

    /// The command's error output when it stopped, or `fallback`.
    func failureText(_ fallback: String) async -> String {
        try? await channel.closeFuture.get()
        let text = handler.errors.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : String(text.prefix(500))
    }

    func close() { channel.close(promise: nil) }
}

private final class ExecStreamHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    let output: ByteQueue
    private let lock = NSLock()
    private var exit: Int?
    private var standardError: [UInt8] = []

    var status: Int? { lock.withLock { exit } }
    var errors: String { lock.withLock { String(decoding: standardError, as: UTF8.self) } }

    init(command: String, output: ByteQueue) { self.command = command; self.output = output }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { context.fireErrorCaught($0) }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)).whenFailure { [output] error in
            output.finish(error); context.close(promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { return }
        if message.type == .channel { output.push(Array(bytes.readableBytesView)) }
        else { lock.withLock { if standardError.count < 8192 { standardError += bytes.readableBytesView.prefix(8192 - standardError.count) } } }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus { lock.withLock { exit = status.exitStatus } }
        else if let event = event as? ChannelEvent, event == .inputClosed { output.finish() }
        else { context.fireUserInboundEventTriggered(event) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { output.finish(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { output.finish(); context.fireChannelInactive() }
}
