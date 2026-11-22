import XCTest
@testable import Ssh

/// A shell that prints faster than its reader keeps going: the channel waits for the reader instead of ending the shell.
final class ShellOutputTests: XCTestCase {
    func testFastOutputToASlowReaderArrivesWholeWithoutEndingTheShell() async throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        let server = try LocalSSHD()
        defer { server.stop() }
        let key = try server.addKey("login", type: "ed25519")
        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                                   credential: SSHCredential.privateKeyFile(at: key, passphrase: ""), connectTimeoutSeconds: 15)
        let shell = try await session.openShell(rows: 24, columns: 120)
        // The marker is computed by the shell, so the echoed command line does not match it.
        // About 2 MB, far more than the 64 chunks the reader may fall behind by.
        try await shell.send(Array("seq 1 300000; echo SHELL_OUTPUT_$((40+2))\n".utf8))
        var tail = ""
        var bytes = 0
        var chunks = 0
        for try await chunk in shell.output {
            bytes += chunk.count
            // The end of the output so far; the last chunk may also carry the next prompt.
            tail = String((tail + String(decoding: chunk, as: UTF8.self)).suffix(4096))
            chunks += 1
            // A reader slower than loopback: the old fixed buffer ended the shell here.
            if chunks % 4 == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
            if tail.contains("SHELL_OUTPUT_42\r\n") { break }
        }
        XCTAssertTrue(tail.contains("300000\r\nSHELL_OUTPUT_42\r\n"), "the output ended early: \(tail)")
        XCTAssertGreaterThan(bytes, 2_000_000)
        // The shell is still there and answers.
        try await shell.send(Array("echo STILL_$((40+2))\n".utf8))
        var after = ""
        for try await chunk in shell.output {
            after += String(decoding: chunk, as: UTF8.self)
            if after.contains("STILL_42\r\n") { break }
        }
        XCTAssertTrue(after.contains("STILL_42\r\n"))
        await shell.close()
        try? await session.close()
    }
}
