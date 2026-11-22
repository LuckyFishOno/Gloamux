import XCTest
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
@testable import FileTransfer

final class FTPTests: XCTestCase {
    // MARK: Listing parsers

    func testParsesUnixListings() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z")!
        let file = try XCTUnwrap(UnixListing.parse("-rw-r--r--@ 1 501 20  1234 Nov 20 09:15 notes with  spaces.txt", now: now))
        XCTAssertEqual(file.name, "notes with  spaces.txt")
        XCTAssertEqual(file.size, 1234)
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.permissions, 0o100644)
        XCTAssertEqual(file.modified, ISO8601DateFormatter().date(from: "2026-11-20T09:15:00Z"))
        let folder = try XCTUnwrap(UnixListing.parse("drwxr-sr-x  2 0 0 4096 Jan  5  2024 etc", now: now))
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.permissions, 0o042755)
        XCTAssertEqual(folder.modified, ISO8601DateFormatter().date(from: "2024-01-05T00:00:00Z"))
        // A December time seen in January belongs to the previous year.
        let january = ISO8601DateFormatter().date(from: "2027-01-03T12:00:00Z")!
        XCTAssertEqual(UnixListing.parse("-rw------- 1 0 0 1 Dec 30 23:00 x", now: january)?.modified,
                       ISO8601DateFormatter().date(from: "2026-12-30T23:00:00Z"))
        XCTAssertEqual(UnixListing.parse("lrwxrwxrwx 1 0 0 7 Nov 1 10:00 bin -> usr/bin", now: now)?.name, "bin")
        XCTAssertEqual(UnixListing.parse("crw-rw-rw- 1 0 0 1, 3 Nov 1 10:00 null", now: now)?.name, "null")
        XCTAssertEqual(UnixListing.parse("-rwsr-xr-t 1 0 0 1 Nov 1 10:00 s", now: now)?.permissions, 0o105755)
        XCTAssertNil(UnixListing.parse("total 48"))
        XCTAssertNil(UnixListing.parse("drwxr-xr-x 2 0 0 64 Nov 1 10:00 ."))
    }

    func testParsesMachineListings() throws {
        let entry = try XCTUnwrap(FTPTransfer.machineEntry("type=file;size=42;modify=20240102030405;UNIX.mode=0640; read me.txt"))
        XCTAssertEqual(entry.name, "read me.txt")
        XCTAssertEqual(entry.size, 42)
        XCTAssertEqual(entry.permissions, 0o100640)
        XCTAssertEqual(entry.modified, ISO8601DateFormatter().date(from: "2024-01-02T03:04:05Z"))
        XCTAssertEqual(FTPTransfer.machineEntry("Type=dir;Modify=20240102030405; logs")?.isDirectory, true)
        XCTAssertNil(FTPTransfer.machineEntry("type=cdir; /srv"))
        XCTAssertEqual(FTPTransfer.normalizedFingerprint(String(repeating: "ab", count: 32)), Array(repeating: "AB", count: 32).joined(separator: ":"))
        XCTAssertNil(FTPTransfer.normalizedFingerprint("abc"))
    }

    // MARK: Against a loopback server

    func testFileCLIOverPlainAndEncryptedFTP() async throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("gloamux")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-ftp-cli-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let variants: [(FTPSecurity, String)] = [(.none, "127.0.0.1"), (.explicitTLS, "localhost"),
                                                   (.explicitTLS, "127.0.0.1"), (.implicitTLS, "localhost")]
        for (security, host) in variants {
            let certificate = security == .none ? nil : try TestCertificate.make()
            let server = try await FakeFTPServer.start(security: security, modern: true, certificate: certificate)
            defer { server.stop() }
            let port = server.port
            if security != .none { server.requiresReuse = true }
            let mode = security == .none ? "ftp" : "ftps"
            let path = folder.appendingPathComponent("\(security.rawValue)-\(host)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            var profile: [String: Any] = ["host": host, "port": port,
                                          "username": "tester", "ftpSecurity": security.rawValue]
            if let certificate {
                profile["ftpFingerprint"] = try certificate.certificate.toDERBytes().withUnsafeBufferPointer {
                    SHA256.hash(data: Data(buffer: $0)).map { String(format: "%02x", $0) }.joined()
                }
            }
            let node: [String: Any] = ["id": UUID().uuidString, "name": "Fixture", "expanded": false, "connection": profile]
            try JSONSerialization.data(withJSONObject: ["version": 1, "nodes": [node]])
                .write(to: path.appendingPathComponent("sessions.json"))
            let local = path.appendingPathComponent("hello copy")
            let options = ["--session", "Fixture", "--workspace", path.path, "--password-stdin", "--protocol", mode, "--json"]
            let extra = security == .none ? ["--allow-plain-ftp"] : []
            if security == .none {
                let failure = try await Self.cli(executable, ["files", "ls"] + options)
                XCTAssertEqual(failure.status, 1)
                XCTAssertTrue(failure.text.contains("--allow-plain-ftp"))
            }
            let listing = try await Self.cli(executable, ["files", "ls", "/"] + options + extra)
            XCTAssertEqual(listing.status, 0, "\(security) on \(host): \(listing.text)")
            XCTAssertTrue(listing.text.contains("hello.txt"))
            let get = try await Self.cli(executable, ["files", "get", "/hello.txt", local.path] + options + extra)
            XCTAssertEqual(get.status, 0, get.text)
            XCTAssertEqual(try Data(contentsOf: local), Data("hello world".utf8))
            let put = try await Self.cli(executable, ["files", "put", local.path, "/new file.txt"] + options + extra)
            XCTAssertEqual(put.status, 0, put.text)
            XCTAssertEqual(server.file("/new file.txt"), Array("hello world".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("saved-sign-ins.json").path))
        }
    }

    private static func cli(_ executable: URL, _ args: [String]) async throws -> (status: Int32, text: String) {
        try await Task.detached {
            let process = Process()
            let output = Pipe(), input = Pipe()
            process.executableURL = executable
            process.arguments = args
            process.standardOutput = output
            process.standardError = output
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("secret\n".utf8))
            try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: response, as: UTF8.self))
        }.value
    }

    func testPlainFTPWithPASVAndLISTFallbacks() async throws {
        let server = try await FakeFTPServer.start(security: .none, modern: false)
        defer { server.stop() }
        let ftp = try await FTPTransfer.connect(FTPSettings(host: "127.0.0.1", port: server.port, username: "tester", password: "secret", security: .none))
        XCTAssertEqual(ftp.protocolName, "FTP")
        try await exercise(ftp, server: server)
        XCTAssertTrue(server.log.contains("PASV"), "EPSV was refused, so PASV is used")
        XCTAssertTrue(server.log.contains { $0.hasPrefix("LIST") })
        try await ftp.close()
    }

    func testCopiesContinueAndPermissionsChange() async throws {
        let server = try await FakeFTPServer.start(security: .none, modern: true)
        defer { server.stop() }
        let ftp = try await FTPTransfer.connect(FTPSettings(host: "127.0.0.1", port: server.port, username: "tester", password: "secret", security: .none))
        let canResume = await ftp.canResume()
        XCTAssertTrue(canResume)
        XCTAssertTrue(ftp.isOpen)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-ftp-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        // The first six bytes arrived before the copy stopped; a stray byte after them is dropped.
        try Data("hello X".utf8).write(to: local)
        try await ftp.resumeDownload(remotePath: "/hello.txt", to: local, offset: 6, progress: nil)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "hello world")
        XCTAssertTrue(server.log.contains("REST 6"))
        server.setFile("/up.txt", Array("hello".utf8))
        try await ftp.resumeUpload(localURL: local, to: "/up.txt", offset: 5, progress: nil)
        XCTAssertEqual(server.file("/up.txt").map { String(decoding: $0, as: UTF8.self) }, "hello world")
        XCTAssertTrue(server.log.contains("APPE /up.txt"))
        try await ftp.setPermissions("/hello.txt", mode: 0o100640)
        XCTAssertTrue(server.log.contains("SITE CHMOD 640 /hello.txt"))
        try await ftp.close()

        let legacy = try await FakeFTPServer.start(security: .none, modern: false)
        defer { legacy.stop() }
        let old = try await FTPTransfer.connect(FTPSettings(host: "127.0.0.1", port: legacy.port, username: "tester", password: "secret", security: .none))
        let oldResumes = await old.canResume()
        XCTAssertFalse(oldResumes)
        do {
            try await old.resumeDownload(remotePath: "/hello.txt", to: local, offset: 3, progress: nil)
            XCTFail("A server without REST cannot continue a copy")
        } catch {}
        try await old.close()
    }

    /// Servers such as vsftpd with `require_ssl_reuse` accept only data connections that resume the control
    /// connection's TLS session.
    func testFTPSDataConnectionsResumeTheControlSession() async throws {
        let certificate = try TestCertificate.make()
        for version in [TLSVersion.tlsv13, .tlsv12] {
            let server = try await FakeFTPServer.start(security: .explicitTLS, modern: true, certificate: certificate, maximumTLS: version)
            server.requiresReuse = true
            var settings = FTPSettings(host: "localhost", port: server.port, username: "tester", password: "secret", security: .explicitTLS)
            settings.trustRoots = [certificate.certificate]
            let ftp = try await FTPTransfer.connect(settings)
            let listing = try await ftp.listDirectory("/")
            XCTAssertTrue(listing.contains { $0.name == "hello.txt" }, "\(version)")
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-ftps-reuse-\(UUID().uuidString)")
            try await ftp.download(remotePath: "/hello.txt", to: local)
            XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "hello world")
            try await ftp.upload(localURL: local, to: "/copy.txt")
            XCTAssertEqual(server.file("/copy.txt").map { String(decoding: $0, as: UTF8.self) }, "hello world")
            try? FileManager.default.removeItem(at: local)
            XCTAssertEqual(server.dataReuse, [true, true, true], "Every data connection resumed the session over \(version)")
            try await ftp.close()
            server.stop()
        }
    }

    func testExplicitFTPSProtectsCommandsAndData() async throws {
        let certificate = try TestCertificate.make()
        let server = try await FakeFTPServer.start(security: .explicitTLS, modern: true, certificate: certificate)
        defer { server.stop() }
        var settings = FTPSettings(host: "localhost", port: server.port, username: "tester", password: "secret", security: .explicitTLS)
        settings.trustRoots = [certificate.certificate]
        let ftp = try await FTPTransfer.connect(settings)
        XCTAssertEqual(ftp.protocolName, "FTPS")
        try await exercise(ftp, server: server)
        XCTAssertEqual(Array(server.log.prefix(3)), ["AUTH TLS", "USER tester", "PASS secret"])
        XCTAssertTrue(server.log.contains("PROT P"))
        XCTAssertTrue(server.log.contains { $0.hasPrefix("MLSD") })
        XCTAssertTrue(server.dataWasEncrypted)
        try await ftp.close()
    }

    func testImplicitFTPSAndCertificatePinning() async throws {
        let certificate = try TestCertificate.make()
        let server = try await FakeFTPServer.start(security: .implicitTLS, modern: true, certificate: certificate)
        defer { server.stop() }
        // Not trusted by this Mac: the error carries the fingerprint to check and paste.
        let fingerprint = try FTPTransfer.fingerprint(certificate.certificate)
        do {
            _ = try await FTPTransfer.connect(FTPSettings(host: "localhost", port: server.port, username: "tester", password: "secret", security: .implicitTLS))
            XCTFail("an unknown self-signed certificate must be refused")
        } catch let FTPError.untrustedCertificate(shown) { XCTAssertEqual(shown, fingerprint) }
        XCTAssertFalse(server.log.contains("PASS secret"), "the password is never sent before the certificate is trusted")
        // Pinned by fingerprint, it connects.
        let pinned = FTPSettings(host: "localhost", port: server.port, username: "tester", password: "secret", security: .implicitTLS,
                                 trustedFingerprint: fingerprint.replacingOccurrences(of: ":", with: "").lowercased())
        let ftp = try await FTPTransfer.connect(pinned)
        let listing = try await ftp.readDirectory("/")
        XCTAssertEqual(listing.path, "/")
        try await ftp.close()
        let wrong = FTPSettings(host: "localhost", port: server.port, username: "tester", password: "secret", security: .implicitTLS,
                                trustedFingerprint: String(repeating: "00", count: 32))
        do { _ = try await FTPTransfer.connect(wrong); XCTFail("a different pinned fingerprint must be refused") } catch {}
    }

    func testWrongPasswordAndCommandInjectionAreRefused() async throws {
        let server = try await FakeFTPServer.start(security: .none, modern: true)
        defer { server.stop() }
        do {
            _ = try await FTPTransfer.connect(FTPSettings(host: "127.0.0.1", port: server.port, username: "tester", password: "nope", security: .none))
            XCTFail("a wrong password must fail")
        } catch let FTPError.reply(code, _) { XCTAssertEqual(code, 530) }
        let ftp = try await FTPTransfer.connect(FTPSettings(host: "127.0.0.1", port: server.port, username: "tester", password: "secret", security: .none))
        do { try await ftp.makeDirectory("/x\r\nDELE /hello.txt"); XCTFail("a line break must be refused") } catch {}
        XCTAssertNotNil(server.file("/hello.txt"))
        try await ftp.close()
    }

    private func exercise(_ ftp: FTPTransfer, server: FakeFTPServer) async throws {
        let home = try await ftp.resolve(".")
        XCTAssertEqual(home, "/")
        var listing = try await ftp.readDirectory("/")
        XCTAssertEqual(listing.entries.map(\.name), ["docs", "hello.txt"])
        XCTAssertEqual(listing.entries.last?.size, 11)
        XCTAssertEqual(listing.entries.first?.isDirectory, true)

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gloamux-ftp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloaded = folder.appendingPathComponent("hello.txt")
        try await ftp.download(remotePath: "/hello.txt", to: downloaded)
        XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), "hello world")

        var payload = [UInt8](repeating: 0, count: 200_003)
        for index in payload.indices { payload[index] = UInt8((index * 13) & 0xFF) }
        let source = folder.appendingPathComponent("big.bin")
        try Data(payload).write(to: source)
        try await ftp.upload(localURL: source, to: "/docs/big file.bin")
        XCTAssertEqual(server.file("/docs/big file.bin"), payload)
        // An empty file sends no data; over TLS the data connection must still finish its handshake.
        let empty = folder.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        try await ftp.upload(localURL: empty, to: "/docs/empty.txt")
        XCTAssertEqual(server.file("/docs/empty.txt"), [])
        try await ftp.removeFile("/docs/empty.txt")
        let found = try await ftp.entry(at: "/docs/big file.bin")
        XCTAssertEqual(found?.size, 200_003)
        let missing = try await ftp.entry(at: "/docs/none")
        XCTAssertNil(missing)

        try await ftp.rename(from: "/docs/big file.bin", to: "/docs/moved.bin")
        try await ftp.makeDirectory("/docs/new")
        listing = try await ftp.readDirectory("/docs")
        XCTAssertEqual(listing.entries.map(\.name), ["moved.bin", "new"])
        try await ftp.removeDirectory("/docs/new")
        try await ftp.removeFile("/docs/moved.bin")
        XCTAssertNil(server.file("/docs/moved.bin"))
        do { try await ftp.removeFile("/docs/none"); XCTFail("deleting a missing file fails") } catch let FTPError.reply(code, _) { XCTAssertEqual(code, 550) }
        // The command channel stays in step after the failure.
        let again = try await ftp.readDirectory("/")
        XCTAssertEqual(again.entries.count, 2)
    }
}

/// A self-signed certificate for `localhost`, made with the openssl tool for this test run.
struct TestCertificate {
    let certificate: NIOSSLCertificate
    let key: NIOSSLPrivateKey

    static func make() throws -> TestCertificate {
        let tool = ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { throw XCTSkip("openssl is not available") }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gloamux-cert-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                             "-keyout", folder.appendingPathComponent("key.pem").path, "-out", folder.appendingPathComponent("cert.pem").path,
                             "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("openssl could not make a certificate") }
        return TestCertificate(certificate: try NIOSSLCertificate(file: folder.appendingPathComponent("cert.pem").path, format: .pem),
                               key: try NIOSSLPrivateKey(file: folder.appendingPathComponent("key.pem").path, format: .pem))
    }
}

/// An in-memory FTP server with just enough of RFC 959, 2228, 2428, and 3659 for the client: one user, passive data
/// connections, and TLS when asked. `modern` turns on EPSV and MLSD; without it the client must fall back.
final class FakeFTPServer: @unchecked Sendable {
    let port: Int
    private let channel: Channel
    private let lock = NSLock()
    private var files: [String: [UInt8]] = ["/hello.txt": Array("hello world".utf8)]
    private var folders: Set<String> = ["/", "/docs"]
    private var commands: [String] = []
    private var encryptedData = false
    private var reuses: [Bool] = []
    /// Refuses data connections that do not resume the control connection's TLS session, like vsftpd's
    /// `require_ssl_reuse`.
    var requiresReuse = false
    let security: FTPSecurity
    let modern: Bool
    let context: NIOSSLContext?

    var log: [String] { lock.withLock { commands } }
    var dataWasEncrypted: Bool { lock.withLock { encryptedData } }
    /// For each protected data connection, whether it resumed a TLS session.
    var dataReuse: [Bool] { lock.withLock { reuses } }
    func file(_ path: String) -> [UInt8]? { lock.withLock { files[path] } }
    func setFile(_ path: String, _ bytes: [UInt8]) { lock.withLock { files[path] = bytes } }

    private init(channel: Channel, security: FTPSecurity, modern: Bool, context: NIOSSLContext?) {
        self.channel = channel; port = channel.localAddress!.port!; self.security = security; self.modern = modern; self.context = context
    }

    static func start(security: FTPSecurity, modern: Bool, certificate: TestCertificate? = nil, maximumTLS: TLSVersion? = nil) async throws -> FakeFTPServer {
        let context = try certificate.map {
            var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate($0.certificate)], privateKey: .privateKey($0.key))
            configuration.maximumTLSVersion = maximumTLS
            return try NIOSSLContext(configuration: configuration)
        }
        let box = Box()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                guard let server = box.server else { return child.eventLoop.makeSucceededVoidFuture() }
                var handlers: [ChannelHandler] = []
                if security == .implicitTLS, let context { handlers.append(NIOSSLServerHandler(context: context)) }
                handlers.append(ByteToMessageHandler(LineDecoder()))
                handlers.append(Session(server: server))
                return child.pipeline.addHandlers(handlers)
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let server = FakeFTPServer(channel: channel, security: security, modern: modern, context: context)
        box.server = server
        return server
    }

    func stop() { channel.close(promise: nil) }

    private final class Box: @unchecked Sendable { var server: FakeFTPServer? }

    private struct LineDecoder: ByteToMessageDecoder {
        typealias InboundOut = String
        mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
            guard let end = buffer.readableBytesView.firstIndex(of: 0x0A) else { return .needMoreData }
            let line = buffer.readString(length: end - buffer.readerIndex + 1)!.trimmingCharacters(in: .newlines)
            context.fireChannelRead(NIOAny(line))
            return .continue
        }
    }

    /// One control connection.
    private final class Session: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = String
        let server: FakeFTPServer
        var user = "", signedIn = false, protectData = false, cwd = "/", renameFrom: String?, restart = 0
        var listener: Channel?
        var dataChannel: EventLoopPromise<Channel>?

        init(server: FakeFTPServer) { self.server = server }

        func channelActive(context: ChannelHandlerContext) { reply(context, "220 fake ready") }

        func reply(_ context: ChannelHandlerContext, _ text: String) {
            context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: text + "\r\n")), promise: nil)
        }

        func path(_ argument: String) -> String {
            let joined = argument.hasPrefix("/") ? argument : (cwd == "/" ? "/" : cwd + "/") + argument
            return joined.count > 1 && joined.hasSuffix("/") ? String(joined.dropLast()) : joined
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let line = unwrapInboundIn(data)
            server.lock.withLock { server.commands.append(line) }
            let parts = line.split(separator: " ", maxSplits: 1)
            let verb = parts.first.map { $0.uppercased() } ?? ""
            let argument = parts.count > 1 ? String(parts[1]) : ""
            if !signedIn && !["USER", "PASS", "AUTH", "QUIT", "FEAT"].contains(verb) { reply(context, "530 Please sign in"); return }
            switch verb {
            case "AUTH":
                guard server.security == .explicitTLS, let tls = server.context else { reply(context, "502 no TLS"); return }
                reply(context, "234 Go ahead")
                try? context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls), position: .first)
            case "USER": user = argument; reply(context, "331 Password please")
            case "PASS":
                if user == "tester" && argument == "secret" { signedIn = true; reply(context, "230 Welcome") } else { reply(context, "530 Wrong password") }
            case "PBSZ": reply(context, "200 PBSZ=0")
            case "PROT": protectData = argument == "P"; reply(context, "200 OK")
            case "TYPE", "OPTS": reply(context, "200 OK")
            case "FEAT":
                reply(context, server.modern ? "211-Features:\r\n MLST type*;size*;modify*;\r\n EPSV\r\n REST STREAM\r\n UTF8\r\n211 End" : "211-Features:\r\n UTF8\r\n211 End")
            case "PWD": reply(context, "257 \"\(cwd)\" is current")
            case "CWD":
                let target = path(argument)
                if server.lock.withLock({ server.folders.contains(target) }) { cwd = target; reply(context, "250 OK") } else { reply(context, "550 No such folder") }
            case "EPSV", "PASV":
                if verb == "EPSV" && !server.modern { reply(context, "500 Not understood"); return }
                openListener(context, extended: verb == "EPSV")
            case "SIZE":
                if let bytes = server.file(path(argument)) { reply(context, "213 \(bytes.count)") } else { reply(context, "550 No such file") }
            case "MLST":
                let target = path(argument)
                if let bytes = server.file(target) { reply(context, "250-Listing\r\n type=file;size=\(bytes.count); \(target)\r\n250 End") }
                else if server.lock.withLock({ server.folders.contains(target) }) { reply(context, "250-Listing\r\n type=dir; \(target)\r\n250 End") }
                else { reply(context, "550 No such file") }
            case "MLSD", "LIST", "NLST":
                var target = argument.hasPrefix("-a") ? String(argument.dropFirst(2)).trimmingCharacters(in: .whitespaces) : argument
                if target.isEmpty { target = cwd }
                target = path(target)
                let listing = listing(of: target, machine: verb == "MLSD")
                send(context, Array(listing.utf8))
            case "REST":
                guard server.modern, let offset = Int(argument) else { reply(context, "502 Not implemented"); return }
                restart = offset; reply(context, "350 Restarting at \(offset)")
            case "RETR":
                guard let bytes = server.file(path(argument)) else { reply(context, "550 No such file"); return }
                let offset = min(restart, bytes.count); restart = 0
                send(context, Array(bytes[offset...]))
            case "STOR": receive(context, into: path(argument))
            case "APPE": receive(context, into: path(argument), appending: true)
            case "SITE":
                let words = argument.split(separator: " ", maxSplits: 2).map(String.init)
                guard words.count == 3, words[0].uppercased() == "CHMOD", server.file(path(words[2])) != nil else { reply(context, "550 Cannot change"); return }
                reply(context, "200 SITE CHMOD command ok")
            case "MKD":
                let target = path(argument)
                server.lock.withLock { _ = server.folders.insert(target) }
                reply(context, "257 \"\(target)\" created")
            case "RMD":
                let target = path(argument)
                if server.lock.withLock({ server.folders.remove(target) }) != nil { reply(context, "250 Removed") } else { reply(context, "550 No such folder") }
            case "DELE":
                let target = path(argument)
                if server.lock.withLock({ server.files.removeValue(forKey: target) }) != nil { reply(context, "250 Deleted") } else { reply(context, "550 No such file") }
            case "RNFR":
                let target = path(argument)
                if server.file(target) != nil { renameFrom = target; reply(context, "350 Ready") } else { reply(context, "550 No such file") }
            case "RNTO":
                guard let from = renameFrom else { reply(context, "503 RNFR first"); return }
                server.lock.withLock { server.files[path(argument)] = server.files.removeValue(forKey: from) }
                renameFrom = nil; reply(context, "250 Renamed")
            case "QUIT": reply(context, "221 Bye"); context.close(promise: nil)
            default: reply(context, "502 Not implemented")
            }
        }

        func listing(of folder: String, machine: Bool) -> String {
            server.lock.withLock {
                let prefix = folder == "/" ? "/" : folder + "/"
                var lines: [String] = []
                for name in server.folders where name.hasPrefix(prefix) && name != folder && !name.dropFirst(prefix.count).contains("/") {
                    let short = String(name.dropFirst(prefix.count))
                    lines.append(machine ? "type=dir;modify=20240101000000; \(short)" : "drwxr-xr-x 2 0 0 4096 Jan  1  2024 \(short)")
                }
                for (name, bytes) in server.files where name.hasPrefix(prefix) && !name.dropFirst(prefix.count).contains("/") {
                    let short = String(name.dropFirst(prefix.count))
                    lines.append(machine ? "type=file;size=\(bytes.count);modify=20240101000000; \(short)" : "-rw-r--r-- 1 0 0 \(bytes.count) Jan  1  2024 \(short)")
                }
                return ((machine ? ["type=cdir; \(folder)"] : []) + lines).map { $0 + "\r\n" }.joined()
            }
        }

        func openListener(_ context: ChannelHandlerContext, extended: Bool) {
            let promise = context.eventLoop.makePromise(of: Channel.self)
            dataChannel = promise
            let tls = protectData ? server.context : nil
            let server = self.server
            ServerBootstrap(group: context.eventLoop)
                .childChannelInitializer { child in
                    if let tls {
                        server.lock.withLock { server.encryptedData = true }
                        let gate = HandshakeGate { reused in
                            server.lock.withLock { server.reuses.append(reused) }
                            if reused || !server.requiresReuse { promise.succeed(child) }
                            else { promise.fail(ChannelError.ioOnClosedChannel); child.close(promise: nil) }
                        }
                        return child.pipeline.addHandlers([NIOSSLServerHandler(context: tls), gate])
                    }
                    promise.succeed(child)
                    return child.eventLoop.makeSucceededVoidFuture()
                }
                .bind(host: "127.0.0.1", port: 0)
                .whenSuccess { listener in
                    self.listener = listener
                    let port = listener.localAddress!.port!
                    self.reply(context, extended ? "229 Entering Extended Passive Mode (|||\(port)|)" : "227 Entering Passive Mode (10,0,0,1,\(port / 256),\(port % 256))")
                }
        }

        func send(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
            guard let dataChannel else { reply(context, "425 Use PASV first"); return }
            self.dataChannel = nil
            reply(context, "150 Opening data connection")
            dataChannel.futureResult.whenFailure { _ in self.reply(context, "522 SSL connection failed: session reuse required") }
            dataChannel.futureResult.whenSuccess { child in
                child.writeAndFlush(child.allocator.buffer(bytes: bytes)).flatMap { child.close() }.whenComplete { _ in
                    self.listener?.close(promise: nil); self.listener = nil
                    self.reply(context, "226 Transfer complete")
                }
            }
        }

        func receive(_ context: ChannelHandlerContext, into target: String, appending: Bool = false) {
            guard let dataChannel else { reply(context, "425 Use PASV first"); return }
            self.dataChannel = nil
            reply(context, "150 Ready for data")
            dataChannel.futureResult.whenFailure { _ in self.reply(context, "522 SSL connection failed: session reuse required") }
            let server = self.server
            dataChannel.futureResult.whenSuccess { child in
                let collector = Collector()
                _ = child.pipeline.addHandler(collector)
                child.closeFuture.whenComplete { _ in
                    server.lock.withLock { server.files[target] = (appending ? server.files[target] ?? [] : []) + collector.bytes }
                    self.listener?.close(promise: nil); self.listener = nil
                    self.reply(context, "226 Stored")
                }
            }
        }
    }

    /// Reports whether a data connection's handshake resumed a session once it completes.
    private final class HandshakeGate: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case TLSUserEvent.handshakeCompleted = event,
               let tls = try? context.pipeline.syncOperations.handler(type: NIOSSLServerHandler.self) {
                done(tls.sessionWasReused)
            }
            context.fireUserInboundEventTriggered(event)
        }
    }

    private final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        var bytes: [UInt8] = []
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { bytes += unwrapInboundIn(data).readableBytesView }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}
