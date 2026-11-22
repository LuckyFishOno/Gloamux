import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// How an FTP connection is protected.
public enum FTPSecurity: String, Codable, CaseIterable, Sendable {
    /// Plain FTP: the password and the files cross the network unencrypted.
    case none
    /// FTPS that starts with `AUTH TLS` on the usual port, 21.
    case explicitTLS
    /// FTPS that is encrypted from the first byte, usually on port 990.
    case implicitTLS

    public var defaultPort: Int { self == .implicitTLS ? 990 : 21 }
}

public struct FTPSettings: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var security: FTPSecurity
    /// A SHA-256 certificate fingerprint the user confirmed, for servers with self-signed certificates. When set, only
    /// a certificate with this fingerprint is accepted; otherwise the system's trust store and the host name decide.
    public var trustedFingerprint: String?
    public static func isFingerprint(_ text: String) -> Bool { FTPTransfer.normalizedFingerprint(text) != nil }
    /// Extra trust roots, for tests.
    var trustRoots: [NIOSSLCertificate] = []

    public init(host: String, port: Int, username: String, password: String, security: FTPSecurity, trustedFingerprint: String? = nil) {
        self.host = host; self.port = port; self.username = username.isEmpty ? "anonymous" : username; self.password = password
        self.security = security; self.trustedFingerprint = trustedFingerprint.flatMap { FTPTransfer.normalizedFingerprint($0) }
    }
}

public enum FTPError: Error, Equatable, LocalizedError {
    case reply(code: Int, text: String)
    case untrustedCertificate(fingerprint: String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .reply(let code, let text): return "\(code) \(text)"
        case .untrustedCertificate(let fingerprint):
            return "The server's certificate is not trusted. If you have checked that it belongs to this server, add its SHA-256 fingerprint to the session: \(fingerprint)"
        case .protocolError(let text): return text
        }
    }
}

/// An FTP or FTPS session: passive mode (EPSV, then PASV), binary transfers, MLSD listings when the server has them
/// and Unix `LIST` output otherwise. With FTPS the commands and every data connection are encrypted (`PROT P`). One
/// command runs at a time, since FTP has a single command channel.
public actor FTPTransfer: RemoteFileSystem {
    private let settings: FTPSettings
    private let control: Channel
    private let replies: ByteQueue
    private let tls: NIOSSLContext?
    private var machineListings = false
    /// The server takes `REST` with a byte offset, so copies can continue.
    private var restarts = false
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public nonisolated var protocolName: String { settings.security == .none ? "FTP" : "FTPS" }

    private init(settings: FTPSettings, control: Channel, replies: ByteQueue, tls: NIOSSLContext?) {
        self.settings = settings; self.control = control; self.replies = replies; self.tls = tls
    }

    public static func connect(_ settings: FTPSettings, timeoutSeconds: Int64 = 20) async throws -> FTPTransfer {
        guard (1...65535).contains(settings.port), !settings.host.isEmpty else { throw FTPError.protocolError("Enter a host and a valid port.") }
        let context: NIOSSLContext? = settings.security == .none ? nil : try makeContext(settings)
        let replies = ByteQueue()
        let channel: Channel
        do {
            channel = try await bootstrap(timeoutSeconds) { channel in
                var handlers: [ChannelHandler] = []
                if settings.security == .implicitTLS, let context {
                    do { handlers.append(try clientHandler(context, settings)) } catch { return channel.eventLoop.makeFailedFuture(error) }
                }
                handlers.append(QueueFeeder(queue: replies, data: false))
                return channel.pipeline.addHandlers(handlers)
            }.connect(host: settings.host, port: settings.port).get()
        } catch {
            throw FTPError.protocolError("Could not connect to \(settings.host):\(settings.port): \(Self.describe(error))")
        }
        let transfer = FTPTransfer(settings: settings, control: channel, replies: replies, tls: context)
        do { try await transfer.signIn() } catch {
            channel.close(promise: nil)
            if settings.security != .none, settings.trustedFingerprint == nil, Self.isCertificateFailure(error),
               let fingerprint = await probeFingerprint(settings, timeoutSeconds: timeoutSeconds) {
                throw FTPError.untrustedCertificate(fingerprint: fingerprint)
            }
            throw Self.wrap(error)
        }
        return transfer
    }

    private func signIn() async throws {
        try await expect(read(), 220)
        if settings.security == .explicitTLS, let tls {
            try await expect(command("AUTH TLS"), 234)
            let control = control, settings = settings
            try await control.eventLoop.submit {
                try control.pipeline.syncOperations.addHandler(Self.clientHandler(tls, settings), position: .first)
            }.get()
        }
        var reply = try await command("USER " + settings.username)
        if reply.code == 331 { reply = try await command("PASS " + settings.password, secret: true) }
        try expect(reply, 230)
        if settings.security != .none {
            try expect(try await command("PBSZ 0"), 200)
            try expect(try await command("PROT P"), 200)
        }
        try expect(try await command("TYPE I"), 200)
        _ = try await command("OPTS UTF8 ON")
        let features = try await command("FEAT")
        machineListings = features.code == 211 && features.text.uppercased().contains("MLST")
        restarts = features.code == 211 && features.text.uppercased().contains("REST STREAM")
    }

    // MARK: Replies

    struct Reply { var code: Int; var text: String }

    private func read() async throws -> Reply {
        guard let first = try await replies.readLine() else { throw FTPError.protocolError("The server closed the connection.") }
        guard first.count >= 3, let code = Int(first.prefix(3)) else { throw FTPError.protocolError("The server sent an unexpected reply: \(first.prefix(200))") }
        var lines = [String(first.dropFirst(4))]
        if first.dropFirst(3).first == "-" {
            // A multi-line reply ends with the same code and a space.
            while let line = try await replies.readLine() {
                if line.hasPrefix("\(code) ") { lines.append(String(line.dropFirst(4))); break }
                lines.append(line)
                if lines.count > 2000 { throw FTPError.protocolError("The server's reply is too long.") }
            }
        }
        return Reply(code: code, text: lines.joined(separator: "\n"))
    }

    private func command(_ line: String, secret: Bool = false) async throws -> Reply {
        // Scalars, not characters: "\r\n" is one Character and would slip past a character check.
        guard !line.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw TransferError.remoteError("This name cannot be used on the server.")
        }
        try await control.writeAndFlush(control.allocator.buffer(string: line + "\r\n")).get()
        return try await read()
    }

    private func expect(_ reply: Reply, _ codes: Int...) throws {
        guard codes.contains(reply.code) else { throw FTPError.reply(code: reply.code, text: reply.text) }
    }

    /// FTP has one command channel, so operations wait their turn.
    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        while running { await withCheckedContinuation { waiting.append($0) } }
        running = true
        defer { running = false; if !waiting.isEmpty { waiting.removeFirst().resume() } }
        do { return try await body() } catch { throw Self.wrap(error) }
    }

    // MARK: Data connections

    private func openData() async throws -> (Channel, ByteQueue) {
        var reply = try await command("EPSV")
        let port: Int
        if reply.code == 229, let range = reply.text.range(of: #"\(\|\|\|(\d+)\|\)"#, options: .regularExpression) {
            port = Int(reply.text[range].filter(\.isNumber)) ?? 0
        } else {
            reply = try await command("PASV")
            try expect(reply, 227)
            guard let range = reply.text.range(of: #"\d+,\d+,\d+,\d+,\d+,\d+"#, options: .regularExpression) else {
                throw FTPError.protocolError("The server sent an unexpected passive-mode reply.")
            }
            let numbers = reply.text[range].split(separator: ",").compactMap { Int($0) }
            port = numbers[4] * 256 + numbers[5]
        }
        guard (1...65535).contains(port) else { throw FTPError.protocolError("The server sent an invalid data port.") }
        // The data connection goes to the same host as the commands, never to an address the server names.
        let queue = ByteQueue()
        let settings = settings, tls = tls
        let session = tls == nil ? nil : await controlSession()
        let channel = try await Self.bootstrap(20) { channel in
            var handlers: [ChannelHandler] = []
            if let tls {
                do {
                    let handler = try Self.clientHandler(tls, settings)
                    if let session { handler.offerSession(session) }
                    handlers.append(handler)
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }
            handlers.append(QueueFeeder(queue: queue, data: true, handshake: tls == nil ? nil : HandshakeSignal()))
            return channel.pipeline.addHandlers(handlers)
        }.connect(host: settings.host, port: port).get()
        return (channel, queue)
    }

    /// The control connection's TLS session. Each data connection resumes it, as servers such as vsftpd with
    /// `require_ssl_reuse` accept only data connections that continue the signed-in session.
    private func controlSession() async -> NIOSSLSession? {
        let control = control
        return try? await control.eventLoop.submit {
            try control.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self).resumableSession
        }.get()
    }

    /// Opens a data connection, sends `line`, and runs `body` with it. The final reply is read afterwards. With
    /// `restart`, `REST` comes right before `line`, as the command it applies to must follow it.
    private func withData<T>(_ line: String, restart: UInt64 = 0, _ body: (Channel, ByteQueue) async throws -> T) async throws -> T {
        let (channel, queue) = try await openData()
        let start: Reply
        do {
            if restart > 0 { try expect(try await command("REST \(restart)"), 350) }
            start = try await command(line)
        } catch { channel.close(promise: nil); throw error }
        guard start.code == 150 || start.code == 125 else { channel.close(promise: nil); throw FTPError.reply(code: start.code, text: start.text) }
        let result: T
        do { result = try await body(channel, queue) } catch {
            channel.close(promise: nil)
            // The server answers the broken transfer; read that reply so the next command lines up.
            _ = try? await withTimeout(5) { try await self.read() }
            throw error
        }
        try expect(try await read(), 226, 250)
        return result
    }

    /// Returns once an encrypted data connection has finished its TLS handshake; at once for a plain one.
    private static func waitForHandshake(_ channel: Channel) async throws {
        guard let feeder = try? await channel.pipeline.handler(type: QueueFeeder.self).get(),
              let handshake = feeder.handshake else { return }
        try await handshake.wait()
    }

    private func withTimeout<T: Sendable>(_ seconds: UInt64, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(nanoseconds: seconds * 1_000_000_000); throw CancellationError() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Files

    public func readDirectory(_ path: String) async throws -> (path: String, entries: [RemoteEntry]) {
        try await exclusive {
            let folder = try await resolveLocked(path)
            let listing: [UInt8] = try await withData((machineListings ? "MLSD " : "LIST -a ") + folder) { _, queue in
                var bytes: [UInt8] = []
                while true {
                    let chunk = try await queue.read(upTo: 65536)
                    if chunk.isEmpty { break }
                    bytes += chunk
                    if bytes.count > 32 << 20 { throw FTPError.protocolError("The folder listing is too large.") }
                }
                return bytes
            }
            let lines = String(decoding: listing, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            let entries = machineListings ? lines.compactMap(Self.machineEntry) : lines.compactMap { UnixListing.parse($0) }
            return (folder, entries.filter { $0.name != "." && $0.name != ".." }.sorted { $0.name < $1.name })
        }
    }

    /// One `MLSD` or `MLST` line: `type=file;size=12;modify=20240101120000;UNIX.mode=0644; name`.
    static func machineEntry(_ line: String) -> RemoteEntry? {
        let trimmed = line.hasPrefix(" ") ? String(line.dropFirst()) : line
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let name = String(trimmed[trimmed.index(after: space)...])
        var facts: [String: String] = [:]
        for fact in trimmed[..<space].split(separator: ";") {
            let pair = fact.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
        }
        let type = facts["type"]?.lowercased() ?? "file"
        guard type != "cdir", type != "pdir", !name.isEmpty else { return nil }
        let directory = type == "dir" || type.hasPrefix("os.unix=slink:") && facts["size"] == nil
        var permissions = facts["unix.mode"].flatMap { UInt32($0, radix: 8) }
        if let mode = permissions { permissions = mode | (directory ? 0o040000 : 0o100000) }
        var modified: Date?
        if let stamp = facts["modify"], stamp.count >= 14 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMddHHmmss"
            modified = formatter.date(from: String(stamp.prefix(14)))
        }
        return RemoteEntry(name: name, size: facts["size"].flatMap { UInt64($0) }, isDirectory: directory,
                           permissions: permissions, modified: modified)
    }

    public func download(remotePath: String, to localURL: URL, progress: ProgressHandler?) async throws {
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw TransferError.localFileError("cannot write \(localURL.path)")
        }
        try await resumeDownload(remotePath: remotePath, to: localURL, offset: 0, progress: progress)
    }

    public func resumeDownload(remotePath: String, to localURL: URL, offset: UInt64, progress: ProgressHandler?) async throws {
        try await exclusive {
            if offset > 0, !restarts { throw TransferError.remoteError("The server cannot continue a copy.") }
            let size = try? await command("SIZE " + remotePath)
            let total = size?.code == 213 ? UInt64(size!.text.trimmingCharacters(in: .whitespaces)) : nil
            guard let out = try? FileHandle(forWritingTo: localURL), (try? out.truncate(atOffset: offset)) != nil,
                  (try? out.seek(toOffset: offset)) != nil else { throw TransferError.localFileError("cannot write \(localURL.path)") }
            defer { try? out.close() }
            try await withData("RETR " + remotePath, restart: offset) { _, queue in
                var received = offset
                progress?(TransferProgress(bytesTransferred: 0, totalBytes: total))
                while true {
                    try Task.checkCancellation()
                    let chunk = try await queue.read(upTo: 256 * 1024)
                    if chunk.isEmpty { break }
                    try out.write(contentsOf: chunk)
                    received += UInt64(chunk.count)
                    progress?(TransferProgress(bytesTransferred: received, totalBytes: total))
                }
            }
        }
    }

    public func upload(localURL: URL, to remotePath: String, progress: ProgressHandler?) async throws {
        try await resumeUpload(localURL: localURL, to: remotePath, offset: 0, progress: progress)
    }

    /// A resumed upload appends with `APPE` after the bytes the server already has.
    public func resumeUpload(localURL: URL, to remotePath: String, offset: UInt64, progress: ProgressHandler?) async throws {
        try await exclusive {
            if offset > 0, !restarts { throw TransferError.remoteError("The server cannot continue a copy.") }
            guard let input = try? FileHandle(forReadingFrom: localURL) else { throw TransferError.localFileError("cannot read \(localURL.path)") }
            defer { try? input.close() }
            let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value
            if offset > 0 {
                guard let total, offset <= total, (try? input.seek(toOffset: offset)) != nil else {
                    throw TransferError.localFileError("The file changed while it was being copied.")
                }
            }
            try await withData((offset > 0 ? "APPE " : "STOR ") + remotePath) { channel, _ in
                var sent = offset
                progress?(TransferProgress(bytesTransferred: 0, totalBytes: total))
                while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    try await channel.writeAndFlush(channel.allocator.buffer(bytes: data)).get()
                    sent += UInt64(data.count)
                    progress?(TransferProgress(bytesTransferred: sent, totalBytes: total ?? sent))
                }
                // An empty file sends nothing, so wait for the TLS handshake before closing: a connection closed
                // before it would be refused by the server as a failed handshake rather than read as an empty file.
                try await Self.waitForHandshake(channel)
                // Closing the data connection marks the end of the file; with TLS it sends close_notify first.
                try await channel.close()
            }
        }
    }

    public func entry(at path: String) async throws -> RemoteEntry? {
        try await exclusive {
            if machineListings {
                let reply = try await command("MLST " + path)
                guard reply.code == 250 else { return nil }
                let line = reply.text.split(separator: "\n").map(String.init).first { $0.hasPrefix(" ") || $0.contains("=") && $0.contains(";") }
                guard var entry = line.flatMap(Self.machineEntry) else { return nil }
                entry.name = (path as NSString).lastPathComponent
                return entry
            }
            let size = try await command("SIZE " + path)
            if size.code == 213 {
                return RemoteEntry(name: (path as NSString).lastPathComponent, size: UInt64(size.text.trimmingCharacters(in: .whitespaces)), isDirectory: false)
            }
            let current = try await resolveLocked(".")
            guard try await command("CWD " + path).code == 250 else { return nil }
            _ = try await command("CWD " + current)
            return RemoteEntry(name: (path as NSString).lastPathComponent, isDirectory: true)
        }
    }

    public func resolve(_ path: String) async throws -> String { try await exclusive { try await resolveLocked(path) } }

    private func resolveLocked(_ path: String) async throws -> String {
        if !(path.isEmpty || path == "." || path == "~") { try expect(try await command("CWD " + path), 250) }
        let reply = try await command("PWD")
        try expect(reply, 257)
        // 257 "/the/path" is current; quotes inside the path are doubled.
        guard let open = reply.text.firstIndex(of: "\"") else { throw FTPError.protocolError("The server did not say which folder is current.") }
        var result = "", index = reply.text.index(after: open)
        while index < reply.text.endIndex {
            let character = reply.text[index]
            if character == "\"" {
                let next = reply.text.index(after: index)
                if next < reply.text.endIndex, reply.text[next] == "\"" { result.append("\""); index = reply.text.index(after: next); continue }
                break
            }
            result.append(character); index = reply.text.index(after: index)
        }
        return result
    }

    public func makeDirectory(_ path: String) async throws { try await exclusive { try expect(try await command("MKD " + path), 257, 250) } }
    public func removeFile(_ path: String) async throws { try await exclusive { try expect(try await command("DELE " + path), 250) } }
    public func removeDirectory(_ path: String) async throws { try await exclusive { try expect(try await command("RMD " + path), 250) } }
    public func rename(from: String, to: String) async throws {
        try await exclusive {
            try expect(try await command("RNFR " + from), 350)
            try expect(try await command("RNTO " + to), 250)
        }
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        try await exclusive { try expect(try await command("SITE CHMOD \(octalMode(mode)) " + path), 200) }
    }

    public func canResume() -> Bool { restarts }
    public nonisolated var isOpen: Bool { control.isActive }

    public func close() async throws {
        _ = try? await withTimeout(3) { try await self.command("QUIT") }
        try? await control.close()
    }

    // MARK: TLS

    private static func bootstrap(_ timeoutSeconds: Int64, _ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> ClientBootstrap {
        ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(timeoutSeconds))
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: false)
            .channelInitializer(initializer)
    }

    private static func makeContext(_ settings: FTPSettings) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        // Pinning checks the exact certificate in the custom verifier, including for an IP
        // profile whose pinned certificate only names a DNS host.
        if settings.trustedFingerprint != nil { configuration.certificateVerification = .noHostnameVerification }
        if !settings.trustRoots.isEmpty { configuration.trustRoots = .certificates(settings.trustRoots) }
        return try NIOSSLContext(configuration: configuration)
    }

    private static func clientHandler(_ context: NIOSSLContext, _ settings: FTPSettings) throws -> NIOSSLClientHandler {
        let name = settings.host.isIPAddress ? nil : settings.host
        guard let pinned = settings.trustedFingerprint else { return try NIOSSLClientHandler(context: context, serverHostname: name) }
        return try NIOSSLClientHandler(context: context, serverHostname: name) { certificates, promise in
            let matches = certificates.first.flatMap { try? fingerprint($0) } == pinned
            promise.succeed(matches ? NIOSSLVerificationResult.certificateVerified : NIOSSLVerificationResult.failed)
        }
    }

    static func fingerprint(_ certificate: NIOSSLCertificate) throws -> String {
        SHA256.hash(data: try certificate.toDERBytes()).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func normalizedFingerprint(_ text: String) -> String? {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 64 else { return nil }
        return stride(from: 0, to: 64, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
    }

    /// Connects once more, only far enough to read the server's certificate, so the error can show its fingerprint.
    private static func probeFingerprint(_ settings: FTPSettings, timeoutSeconds: Int64) async -> String? {
        let captured = Captured()
        guard let context = try? NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration()) else { return nil }
        let replies = ByteQueue()
        let handler: () throws -> NIOSSLClientHandler = {
            try NIOSSLClientHandler(context: context, serverHostname: settings.host.isIPAddress ? nil : settings.host) { certificates, promise in
                captured.value = certificates.first.flatMap { try? fingerprint($0) }
                promise.succeed(NIOSSLVerificationResult.failed)
            }
        }
        guard let channel = try? await bootstrap(timeoutSeconds, { channel in
            var handlers: [ChannelHandler] = []
            if settings.security == .implicitTLS { do { handlers.append(try handler()) } catch { return channel.eventLoop.makeFailedFuture(error) } }
            handlers.append(QueueFeeder(queue: replies, data: false))
            return channel.pipeline.addHandlers(handlers)
        }).connect(host: settings.host, port: settings.port).get() else { return nil }
        defer { channel.close(promise: nil) }
        if settings.security == .explicitTLS {
            _ = try? await replies.readLine()
            _ = try? await channel.writeAndFlush(channel.allocator.buffer(string: "AUTH TLS\r\n")).get()
            guard let line = try? await replies.readLine(), line.hasPrefix("234") else { return nil }
            _ = try? await channel.eventLoop.submit { try channel.pipeline.syncOperations.addHandler(handler(), position: .first) }.get()
        }
        for _ in 0..<100 where captured.value == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        return captured.value
    }

    private static func isCertificateFailure(_ error: Error) -> Bool {
        if let ssl = error as? NIOSSLError, case .handshakeFailed = ssl { return true }
        if let ssl = error as? BoringSSLError, case .sslError = ssl { return true }
        return String(describing: error).contains("CERTIFICATE_VERIFY_FAILED")
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func wrap(_ error: Error) -> Error {
        switch error {
        case is TransferError, is FTPError, is CancellationError: return error
        default:
            if isCertificateFailure(error) { return FTPError.protocolError("The TLS connection failed: \(describe(error))") }
            return TransferError.remoteError(describe(error))
        }
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Hands a connection's bytes to a `ByteQueue`. A data connection that ends without a TLS close_notify still counts as
/// a finished transfer, as most servers close that way.
private final class QueueFeeder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let queue: ByteQueue
    private let data: Bool
    /// Set on an encrypted data connection; done once its TLS handshake has finished or failed.
    let handshake: HandshakeSignal?

    init(queue: ByteQueue, data: Bool, handshake: HandshakeSignal? = nil) { self.queue = queue; self.data = data; self.handshake = handshake }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { queue.push(Array(unwrapInboundIn(data).readableBytesView)) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent {
            if case .handshakeCompleted = tls { handshake?.finish(nil) }
            if data, tls == .shutdownCompleted { queue.finish() }
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) {
        handshake?.finish(FTPError.protocolError("The server closed the data connection before encrypting it."))
        queue.finish(); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if data, let ssl = error as? NIOSSLError, ssl == .uncleanShutdown { return }
        handshake?.finish(error)
        queue.finish(error); context.close(promise: nil)
    }
}

/// Finishes once, with or without an error; `wait` returns or throws when it has.
private final class HandshakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func finish(_ error: Error?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        outcome = result
        let waiting = waiters; waiters = []
        lock.unlock()
        waiting.forEach { $0.resume(with: result) }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome { lock.unlock(); continuation.resume(with: outcome); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

private extension String {
    var isIPAddress: Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, self, &v4) == 1 || inet_pton(AF_INET6, self, &v6) == 1
    }
}
