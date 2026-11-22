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
    /// Opens only the transport and file channel for a saved profile. Uses the same authentication
    /// and protocol selection as the file browser, with no shell, window, or saved forwards.
    /// Reads workspace data without writing it. Keep host-key approvals and authentication
    /// changes in memory here so transfers can run alongside the app's catalog writer.
    public func withFileConnection<Result>(
        _ item: SessionTreeNode, protocol requested: String?, secret: String?, allowPlainFTP: Bool,
        access: FileCommandAccess, perform: (any RemoteFileSystem) async throws -> Result
    ) async throws -> Result {
        guard let settings = item.connection else { throw WorkspaceError.invalid("Choose a saved SSH or FTP connection.") }
        try settings.validate()
        let tab = SessionTab()
        configureSaved(tab, item, settings)
        tab.fileCommandAccess = access
        if let security = settings.ftpSecurity {
            let actual = security == .none ? "ftp" : "ftps"
            guard requested == nil || requested == actual else {
                throw WorkspaceError.invalid("This profile is configured for \(actual.uppercased()).")
            }
            guard security != .none || allowPlainFTP else {
                throw WorkspaceError.invalid("FTP sends data in cleartext. Use --allow-plain-ftp for this connection.")
            }
        } else if let requested {
            guard let choice = FileProtocolChoice(rawValue: requested) else {
                throw WorkspaceError.invalid("This SSH profile supports SFTP and SCP.")
            }
            tab.fileProtocol = choice
        }
        if let secret {
            if tab.useAgent, tab.identityPath == nil {
                throw WorkspaceError.invalid("This profile signs in with an SSH agent. Omit --password-stdin.")
            }
            if tab.identityPath == nil { tab.password = secret }
            else { tab.keyPassphrase = secret }
        }
        return try await withCommandTab(tab) { try await perform(try await self.sftp(for: $0)) }
    }

    /// Opens a saved SSH profile for `gloamux ssh` and runs `perform` with a shell on a pseudo-terminal. Signs in the
    /// same way as the file commands: nothing is saved, and new host keys need a verified fingerprint.
    public func withTerminalConnection<Result>(
        _ item: SessionTreeNode, secret: String?, access: FileCommandAccess, rows: Int, columns: Int, term: String?,
        perform: (SSHInteractiveShell) async throws -> Result
    ) async throws -> Result {
        guard let settings = item.connection, settings.ftpSecurity == nil else { throw WorkspaceError.invalid("Choose a saved SSH connection.") }
        try settings.validate()
        let tab = SessionTab()
        configureSaved(tab, item, settings)
        tab.fileCommandAccess = access
        if let secret {
            if tab.useAgent, tab.identityPath == nil {
                throw WorkspaceError.invalid("This profile signs in with an SSH agent. Omit --password-stdin.")
            }
            if tab.identityPath == nil { tab.password = secret }
            else { tab.keyPassphrase = secret }
        }
        return try await withCommandTab(tab) { tab in
            guard let ssh = tab.session else { throw WorkspaceError.invalid("Connection failed.") }
            let agent = tab.forwardsAgent ? (tab.agentSocket ?? SSHAgentClient.environment()?.socketPath) : nil
            let type = term.flatMap { $0.isEmpty || $0.utf8.count > 64 ? nil : $0 } ?? TerminalPreferences.terminalType
            let shell = try await ssh.openShell(rows: min(max(rows, 1), 500), columns: min(max(columns, 1), 1000),
                                                term: type, agentSocket: agent)
            do {
                let result = try await perform(shell)
                await shell.close()
                return result
            } catch {
                await shell.close()
                throw error
            }
        }
    }

    private func withCommandTab<Result>(_ tab: SessionTab, perform: (SessionTab) async throws -> Result) async throws -> Result {
        await connect(tab)
        do {
            guard tab.connected else { throw WorkspaceError.invalid(tab.error ?? "Connection failed.") }
            let result = try await perform(tab)
            await disconnect(tab)
            return result
        } catch {
            await disconnect(tab)
            throw error
        }
    }
}
