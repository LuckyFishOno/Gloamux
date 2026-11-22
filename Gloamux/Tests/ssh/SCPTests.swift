import XCTest
import Foundation
import CryptoKit
@testable import FileTransfer
@testable import Ssh

/// SCP against a loopback OpenSSH server with no SFTP subsystem, the case the fallback exists for.
final class SCPTests: XCTestCase {
    private var server: LocalSSHD!
    private var session: SSHSession!
    private var folder: URL!

    override func setUp() async throws {
        try XCTSkipUnless(LocalSSHD.available && FileManager.default.isExecutableFile(atPath: "/usr/bin/scp"), "OpenSSH is not installed")
        server = try LocalSSHD(sftp: false)
        let key = try server.addKey("scp", type: "ed25519")
        session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                               credential: SSHCredential.privateKeyFile(at: key, passphrase: ""), connectTimeoutSeconds: 15)
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("gloamux-scp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? await session?.close()
        server?.stop()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testSFTPIsRefusedAndSCPCopiesFilesBothWays() async throws {
        do { _ = try await SFTPTransfer.open(session); XCTFail("the fixture should have no SFTP") } catch {}
        let scp = try await SCPTransfer.open(session)
        XCTAssertEqual(scp.protocolName, "SCP")

        let home = try await scp.resolve(".")
        XCTAssertEqual(home, FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)

        // A name with a space and a quote, and contents that cross several reads.
        var payload = [UInt8](repeating: 0, count: 300_001)
        for index in payload.indices { payload[index] = UInt8((index * 31 + 7) & 0xFF) }
        let local = folder.appendingPathComponent("source.bin")
        try Data(payload).write(to: local)
        let remote = folder.appendingPathComponent("a 'b'.bin").path
        let updates = Updates()
        try await scp.upload(localURL: local, to: remote) { updates.add($0) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), Data(payload))
        XCTAssertEqual(updates.last?.bytesTransferred, 300_001)

        let listing = try await scp.readDirectory(folder.path)
        XCTAssertEqual(listing.path, folder.path)
        let entry = try XCTUnwrap(listing.entries.first { $0.name == "a 'b'.bin" })
        XCTAssertEqual(entry.size, 300_001)
        XCTAssertFalse(entry.isDirectory)
        let found = try await scp.entry(at: remote), missing = try await scp.entry(at: folder.appendingPathComponent("missing").path)
        XCTAssertEqual(found?.size, 300_001)
        XCTAssertNil(missing)

        let renamed = folder.appendingPathComponent("renamed.bin").path
        try await scp.rename(from: remote, to: renamed)
        let copy = folder.appendingPathComponent("copy.bin")
        try await scp.download(remotePath: renamed, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), Data(payload))

        let empty = folder.appendingPathComponent("empty.txt")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        try await scp.upload(localURL: empty, to: folder.appendingPathComponent("empty-remote.txt").path)
        let emptyEntry = try await scp.entry(at: folder.appendingPathComponent("empty-remote.txt").path)
        XCTAssertEqual(emptyEntry?.size, 0)

        let sub = folder.appendingPathComponent("sub dir").path
        try await scp.makeDirectory(sub)
        let subEntry = try await scp.entry(at: sub)
        XCTAssertEqual(subEntry?.isDirectory, true)
        try await scp.removeDirectory(sub)
        try await scp.removeFile(renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed))

        do {
            try await scp.download(remotePath: folder.appendingPathComponent("missing").path, to: folder.appendingPathComponent("x"))
            XCTFail("a missing file should fail")
        } catch TransferError.remoteError(let detail) { XCTAssertTrue(detail.contains("missing") || detail.contains("No such"), detail) }
        do { try await scp.makeDirectory(sub + "/a/b"); XCTFail("mkdir without parents should fail") } catch TransferError.remoteError {}
    }
}

final class SSHFileCLITests: XCTestCase {
    func testFileCLIRoundTripsSFTPAndSCP() throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("gloamux")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        for supportsSFTP in [true, false] {
            let server = try LocalSSHD(sftp: supportsSFTP)
            defer { server.stop() }
            let protocolName = supportsSFTP ? "SFTP" : "SCP"
            let key = try server.addKey("cli", type: "ed25519")
            let workspace = server.directory.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let config: [String: Any] = ["host": "127.0.0.1", "port": server.port, "username": server.user, "identityPath": key.path]
            let node: [String: Any] = ["id": UUID().uuidString, "name": "Fixture", "expanded": false, "connection": config]
            try JSONSerialization.data(withJSONObject: ["version": 1, "nodes": [node]])
                .write(to: workspace.appendingPathComponent("sessions.json"))
            let source = server.directory.appendingPathComponent("source file")
            let destination = server.directory.appendingPathComponent("destination file")
            let returned = server.directory.appendingPathComponent("download file")
            let expected = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
            try expected.write(to: source)
            let hostKey = try String(contentsOfFile: server.path("host_ed25519.pub"), encoding: .utf8)
            let keyBody = try XCTUnwrap(hostKey.split(separator: " ").dropFirst().first.flatMap { Data(base64Encoded: String($0)) })
            let fingerprint = "SHA256:" + Data(SHA256.hash(data: keyBody)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let options = ["--session", "Fixture", "--workspace", workspace.path, "--json"]
            let untrusted = try run(executable, ["files", "pwd"] + options)
            XCTAssertEqual(untrusted.status, 1)
            XCTAssertTrue(untrusted.text.contains(fingerprint), untrusted.text)
            let trusted = options + ["--host-key", fingerprint]
            let upload = try run(executable, ["files", "put", source.path, destination.path] + trusted)
            XCTAssertEqual(upload.status, 0, upload.text)
            XCTAssertTrue(upload.text.contains(protocolName))
            let download = try run(executable, ["files", "get", destination.path, returned.path] + trusted)
            XCTAssertEqual(download.status, 0, download.text)
            XCTAssertEqual(try Data(contentsOf: returned), expected)
            let newContents = Data("replacement".utf8)
            try newContents.write(to: source)
            let replaced = try run(executable, ["files", "put", source.path, destination.path, "--overwrite"] + trusted)
            XCTAssertEqual(replaced.status, 0, replaced.text)
            XCTAssertEqual(try Data(contentsOf: destination), newContents)
            let refused = try run(executable, ["files", "get", destination.path, returned.path] + trusted)
            XCTAssertEqual(refused.status, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("known-hosts.json").path))

            // A folder with a nested folder goes up, comes back, and is removed with its contents.
            let tree = server.directory.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree.appendingPathComponent("inner dir"), withIntermediateDirectories: true)
            try Data("top".utf8).write(to: tree.appendingPathComponent("a.txt"))
            try Data("nested".utf8).write(to: tree.appendingPathComponent("inner dir/b.txt"))
            let remoteTree = server.directory.appendingPathComponent("remote tree")
            let putTree = try run(executable, ["files", "put", tree.path, remoteTree.path, "--recursive"] + trusted)
            XCTAssertEqual(putTree.status, 0, putTree.text)
            XCTAssertTrue(putTree.text.contains("\"files\":2"), putTree.text)
            XCTAssertEqual(try String(contentsOf: remoteTree.appendingPathComponent("inner dir/b.txt"), encoding: .utf8), "nested")
            let again = try run(executable, ["files", "put", tree.path, remoteTree.path, "--recursive"] + trusted)
            XCTAssertEqual(again.status, 1, "an existing folder needs --overwrite")
            let localTree = server.directory.appendingPathComponent("local tree")
            let getTree = try run(executable, ["files", "get", remoteTree.path, localTree.path, "--recursive"] + trusted)
            XCTAssertEqual(getTree.status, 0, getTree.text)
            XCTAssertEqual(try String(contentsOf: localTree.appendingPathComponent("inner dir/b.txt"), encoding: .utf8), "nested")
            XCTAssertEqual(try String(contentsOf: localTree.appendingPathComponent("a.txt"), encoding: .utf8), "top")
            let notEmpty = try run(executable, ["files", "rmdir", remoteTree.path] + trusted)
            XCTAssertEqual(notEmpty.status, 1)
            let removed = try run(executable, ["files", "rm", remoteTree.path, "--recursive"] + trusted)
            XCTAssertEqual(removed.status, 0, removed.text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: remoteTree.path))
        }
    }

    private func run(_ executable: URL, _ args: [String]) throws -> (status: Int32, text: String) {
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TransferProgress] = []
    func add(_ value: TransferProgress) { lock.withLock { values.append(value) } }
    var last: TransferProgress? { lock.withLock { values.last } }
}
