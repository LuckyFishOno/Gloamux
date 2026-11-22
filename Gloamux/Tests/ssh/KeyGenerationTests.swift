import XCTest
@testable import Ssh

/// Keys Gloamux generates read back in Gloamux and in OpenSSH, and sign in to a loopback server.
final class KeyGenerationTests: XCTestCase {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keygen-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testGeneratedKeysReadBackWithAndWithoutPassphrase() throws {
        for passphrase in ["", "correct horse"] {
            let key = try GeneratedSSHKey.ed25519(comment: "me@test", passphrase: passphrase, rounds: 2)
            XCTAssertTrue(key.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
            XCTAssertTrue(key.publicKeyLine.hasPrefix("ssh-ed25519 ") && key.publicKeyLine.hasSuffix(" me@test"))
            let parsed = try SSHPrivateKeyFile.parse(key.privateKey, passphrase: passphrase)
            XCTAssertEqual(parsed.publicKeyLine.split(separator: " ").prefix(2), key.publicKeyLine.split(separator: " ").prefix(2))
            if !passphrase.isEmpty {
                XCTAssertThrowsError(try SSHPrivateKeyFile.parse(key.privateKey, passphrase: "wrong"))
            }
        }
    }

    func testWriteSetsPermissionsAndRefusesToOverwrite() throws {
        let url = try folder().appendingPathComponent("id_test")
        let key = try GeneratedSSHKey.ed25519(comment: "x")
        try key.write(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try String(contentsOf: url.appendingPathExtension("pub"), encoding: .utf8), key.publicKeyLine + "\n")
        XCTAssertThrowsError(try GeneratedSSHKey.ed25519(comment: "y").write(to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), key.privateKey, "the existing key is untouched")
    }

    func testOpenSSHReadsTheKeyAndSignsIn() async throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        let url = try folder().appendingPathComponent("id_ed25519")
        let key = try GeneratedSSHKey.ed25519(comment: "gen", passphrase: "pass phrase", rounds: 4)
        try key.write(to: url)
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-y", "-P", "pass phrase", "-f", url.path]
        let pipe = Pipe(); keygen.standardOutput = pipe; keygen.standardError = Pipe()
        try keygen.run(); keygen.waitUntilExit()
        let derived = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(keygen.terminationStatus, 0)
        XCTAssertEqual(derived.split(separator: " ").prefix(2), key.publicKeyLine.split(separator: " ").prefix(2))

        let server = try LocalSSHD()
        defer { server.stop() }
        try server.authorize(publicKey: key.publicKeyLine)
        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                                   credential: SSHCredential.privateKeyFile(at: url, passphrase: "pass phrase"),
                                                   connectTimeoutSeconds: 15)
        let output = try await session.runCommand("echo generated")
        try await session.close()
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "generated")
    }
}
