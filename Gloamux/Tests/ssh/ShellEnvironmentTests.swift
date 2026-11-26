import XCTest
@testable import Ssh

/// The shell gets the client's language settings and terminal modes, as OpenSSH's client sends them.
final class ShellEnvironmentTests: XCTestCase {
    func testShellReceivesLocaleVariablesAndTerminalModes() async throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        // The server accepts every name, so only the client's filter keeps other names out.
        let server = try LocalSSHD(extraConfig: "AcceptEnv *")
        defer { server.stop() }
        let key = try server.addKey("login", type: "ed25519")
        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                                   credential: SSHCredential.privateKeyFile(at: key, passphrase: ""), connectTimeoutSeconds: 15)
        let shell = try await session.openShell(rows: 24, columns: 120, environment: [
            "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "GLOAMUX_TEST_OTHER": "sent", "LC_BAD": "a\nb", "LC_EMPTY": "",
        ])
        // The markers are computed by the shell, so the echoed command line does not match them.
        try await shell.send(Array("echo \"BEGIN_$((40+2))[$LANG|$LC_CTYPE|${GLOAMUX_TEST_OTHER-none}|${LC_BAD-none}]\"; stty -a; echo END_$((40+2))\n".utf8))
        var text = ""
        for try await chunk in shell.output {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("END_42\r\n") { break }
        }
        XCTAssertTrue(text.contains("BEGIN_42[en_US.UTF-8|UTF-8|none|none]"), text)
        let modes = text.components(separatedBy: .whitespacesAndNewlines)
        for mode in ["iutf8", "icrnl", "ixon", "isig", "icanon", "echo", "echoe", "echok", "iexten", "echoctl", "echoke", "opost", "onlcr", "cs8"] {
            XCTAssertTrue(modes.contains(mode), "\(mode) is on: \(text)")
        }
        XCTAssertTrue(text.contains("erase = ^?"), text)
        XCTAssertTrue(text.contains("intr = ^C"), text)
        await shell.close()
        try? await session.close()
    }
}
