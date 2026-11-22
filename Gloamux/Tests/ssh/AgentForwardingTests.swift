import XCTest
@testable import Ssh

/// Agent forwarding (`ssh -A`) and the terminal type, through the loopback OpenSSH server and a throwaway ssh-agent.
final class AgentForwardingTests: XCTestCase {
    private func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Types `command` and collects output until `marker` appears.
    private func output(of shell: SSHInteractiveShell, after command: String, until marker: String) async throws -> String {
        try await shell.send(Array((command + "\n").utf8))
        var text = ""
        for try await chunk in shell.output {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains(marker) { break }
        }
        return text
    }

    func testShellReachesTheForwardedAgentAndSeesTheTerminalType() async throws {
        try XCTSkipUnless(LocalSSHD.available && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-agent"), "OpenSSH is not installed")
        let server = try LocalSSHD()
        defer { server.stop() }
        let login = try server.addKey("login", type: "ed25519")
        let agentKey = try server.addKey("agent-held", type: "ed25519")
        // A short path: Unix socket paths are limited to about 100 bytes.
        let socket = "/tmp/gloamux-agent-\(UUID().uuidString.prefix(8)).sock"
        let started = try run("/usr/bin/ssh-agent", ["-a", socket])
        let pid = started.components(separatedBy: "SSH_AGENT_PID=").last?.prefix { $0.isNumber } ?? ""
        defer {
            if let pid = Int32(pid) { kill(pid, SIGTERM) }
            try? FileManager.default.removeItem(atPath: socket)
        }
        _ = try run("/usr/bin/ssh-add", [agentKey.path], environment: ["SSH_AUTH_SOCK": socket])

        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                                   credential: SSHCredential.privateKeyFile(at: login, passphrase: ""), connectTimeoutSeconds: 15)
        let shell = try await session.openShell(rows: 24, columns: 120, term: "vt100", agentSocket: socket)
        let text = try await output(of: shell, after: "echo T=$TERM; ssh-add -l; echo DONE-$((40+2))", until: "DONE-42")
        await shell.close()

        try await session.close()

        // sshd keeps a forwarded agent for the rest of that connection, so the check without one uses a new connection.
        let other = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                                 credential: SSHCredential.privateKeyFile(at: login, passphrase: ""), connectTimeoutSeconds: 15)
        let plain = try await other.openShell(rows: 24, columns: 120)
        let without = try await output(of: plain, after: "ssh-add -l; echo DONE-$((40+2))", until: "DONE-42")
        await plain.close()
        try await other.close()

        XCTAssertTrue(text.contains("T=vt100"), text)
        XCTAssertTrue(text.contains("agent-held"), "the remote shell lists the key held by this Mac's agent:\n\(text)")
        XCTAssertFalse(without.contains("agent-held"), "a shell that did not ask gets no agent:\n\(without)")
    }

    func testInvalidTerminalTypeIsRefused() async throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        let server = try LocalSSHD()
        defer { server.stop() }
        let key = try server.addKey("k", type: "ed25519")
        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                                   credential: SSHCredential.privateKeyFile(at: key, passphrase: ""), connectTimeoutSeconds: 15)
        do { _ = try await session.openShell(term: "xterm; rm -rf"); XCTFail("accepted") } catch {}
        try await session.close()
    }
}
