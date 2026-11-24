import FileTransfer
import Foundation
import Ssh

public struct FileCommandAccess: Sendable {
    let hostKeys: Set<String>
    let answer: SSHLoginAnswerer?

    public init(hostKeys: Set<String> = [], answer: SSHLoginAnswerer? = nil) {
        self.hostKeys = hostKeys
        self.answer = answer
    }
}

extension WorkspaceModel {
    /// Opens only the transport and file channel for a saved profile, with no tab, shell, window, or saved forwards.
    /// Uses the same authentication and protocol selection as the file browser. Reads workspace data without writing
    /// it: host-key approvals and passwords stay in memory, so transfers can run alongside the app's catalog writer.
    public func withFileConnection<Result>(
        _ item: SessionTreeNode, protocol requested: String?, secret: String?, allowPlainFTP: Bool,
        access: FileCommandAccess, perform: (any RemoteFileSystem) async throws -> Result
    ) async throws -> Result {
        guard let settings = item.connection else { throw WorkspaceError.invalid("Choose a saved SSH or FTP connection.") }
        try settings.validate()
        let signIn = CommandSignIn(access: access, knownHosts: knownHosts)
        if let security = settings.ftpSecurity {
            let actual = security == .none ? "ftp" : "ftps"
            guard requested == nil || requested == actual else {
                throw WorkspaceError.invalid("This profile is configured for \(actual.uppercased()).")
            }
            guard security != .none || allowPlainFTP else {
                throw WorkspaceError.invalid("FTP sends data in cleartext. Use --allow-plain-ftp for this connection.")
            }
            let transfer: FTPTransfer
            do {
                transfer = try await connections.openFTP(
                    host: settings.host.trimmingCharacters(in: .whitespacesAndNewlines), port: settings.port,
                    username: settings.username, typedPassword: secret ?? "", security: security,
                    fingerprint: settings.ftpFingerprint, asksEachConnection: settings.asksEachConnection, handler: signIn)
            } catch { throw WorkspaceError.invalid(ConnectionService.failureText(error, reported: nil)) }
            return try await Self.closing({ try? await transfer.close() }) { try await perform(transfer) }
        }
        var choice = settings.fileProtocol
        if let requested {
            guard let chosen = FileProtocolChoice(rawValue: requested) else {
                throw WorkspaceError.invalid("This SSH profile supports SFTP and SCP.")
            }
            choice = chosen
        }
        let ssh = try await openCommandSSH(item, settings, secret: secret, signIn)
        let keepAlive = ConnectionService.keepAlive(ssh)
        return try await Self.closing({ keepAlive.cancel(); try? await ssh.close() }) {
            let files = try await ConnectionService.openFiles(ssh, choice: choice)
            return try await Self.closing({ try? await files.close() }) { try await perform(files) }
        }
    }

    /// Opens a saved SSH profile for `gloamux ssh` and runs `perform` with a shell on a pseudo-terminal. Signs in the
    /// same way as the file commands: nothing is saved, and new host keys need a verified fingerprint.
    public func withTerminalConnection<Result>(
        _ item: SessionTreeNode, secret: String?, access: FileCommandAccess, rows: Int, columns: Int, term: String?,
        perform: (SSHInteractiveShell) async throws -> Result
    ) async throws -> Result {
        guard let settings = item.connection, settings.ftpSecurity == nil else { throw WorkspaceError.invalid("Choose a saved SSH connection.") }
        try settings.validate()
        let ssh = try await openCommandSSH(item, settings, secret: secret, CommandSignIn(access: access, knownHosts: knownHosts))
        let keepAlive = ConnectionService.keepAlive(ssh)
        return try await Self.closing({ keepAlive.cancel(); try? await ssh.close() }) {
            let agent = settings.forwardsAgent == true ? (settings.agentSocket ?? SSHAgentClient.environment()?.socketPath) : nil
            let type = term.flatMap { $0.isEmpty || $0.utf8.count > 64 ? nil : $0 } ?? TerminalPreferences.terminalType
            let shell = try await ssh.openShell(rows: min(max(rows, 1), 500), columns: min(max(columns, 1), 1000),
                                                term: type, agentSocket: agent)
            return try await Self.closing({ await shell.close() }) { try await perform(shell) }
        }
    }

    /// Signs in to a saved SSH profile for a command: the profile's own settings and jump hosts, the typed secret if
    /// any, and nothing saved. Failures read as the connection form reports them.
    private func openCommandSSH(_ item: SessionTreeNode, _ settings: SavedConnection, secret: String?,
                                _ signIn: CommandSignIn) async throws -> SSHSession {
        if secret != nil, settings.usesAgent == true, settings.identityPath == nil {
            throw WorkspaceError.invalid("This profile signs in with an SSH agent. Omit --password-stdin.")
        }
        do {
            let target = ConnectionService.sshTarget(settings)
            let hops = try connections.jumpHosts(for: target, excluding: item.id)
            return try await connections.openSSH(target, hops: hops, secret: secret ?? "", handler: signIn)
        } catch {
            throw WorkspaceError.invalid(ConnectionService.failureText(error, reported: nil))
        }
    }

    /// Runs `body`, then `close`, whether `body` returned or threw.
    private static func closing<Result>(_ close: () async -> Void, _ body: () async throws -> Result) async throws -> Result {
        do {
            let result = try await body()
            await close()
            return result
        } catch {
            await close()
            throw error
        }
    }
}
