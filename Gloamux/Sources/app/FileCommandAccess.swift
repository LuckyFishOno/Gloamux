import FileTransfer
import Foundation
import Ssh

public struct FileCommandAccess: Sendable {
    let hostKeys: Set<String>
    let answer: SSHLoginAnswerer?
    /// Asks about a host key seen for the first time, given its endpoint and fingerprint. A changed key is never asked about.
    let confirmHostKey: (@Sendable (String, String) async throws -> Bool)?

    public init(hostKeys: Set<String> = [], answer: SSHLoginAnswerer? = nil,
                confirmHostKey: (@Sendable (String, String) async throws -> Bool)? = nil) {
        self.hostKeys = hostKeys
        self.answer = answer
        self.confirmHostKey = confirmHostKey
    }
}

extension WorkspaceModel {
    /// Opens only the transport and file channel for a saved profile, with no tab, shell, window, or saved forwards.
    /// Uses the same authentication and protocol selection as the file browser. Reads workspace data without writing
    /// it, apart from adding to the connection history: host-key approvals and passwords stay in memory, so transfers can run alongside the app's catalog writer.
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
            commandHistoryID = history.begin(name: item.name, kind: actual, host: settings.host, port: settings.port,
                                             user: settings.username, source: "cli")
            do {
                transfer = try await connections.openFTP(
                    host: settings.host.trimmingCharacters(in: .whitespacesAndNewlines), port: settings.port,
                    username: settings.username, typedPassword: secret ?? "", security: security,
                    fingerprint: settings.ftpFingerprint, asksEachConnection: settings.asksEachConnection, handler: signIn)
            } catch {
                let text = ConnectionService.failureText(error, reported: nil)
                endCommandHistory(.failed, detail: text)
                throw WorkspaceError.invalid(text)
            }
            history.add(.connected, to: commandHistoryID)
            return try await Self.closing({ try? await transfer.close(); endCommandHistory(.closed) }) { try await perform(transfer) }
        }
        var choice = settings.fileProtocol
        if let requested {
            guard let chosen = FileProtocolChoice(rawValue: requested) else {
                throw WorkspaceError.invalid("This SSH profile supports SFTP and SCP.")
            }
            choice = chosen
        }
        let ssh = try await openCommandSSH(item, settings, secret: secret, signIn, kind: choice?.rawValue ?? "sftp")
        let keepAlive = ConnectionService.keepAlive(ssh)
        return try await Self.closing({ keepAlive.cancel(); try? await ssh.close(); endCommandHistory(.closed) }) {
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
        let ssh = try await openCommandSSH(item, settings, secret: secret, CommandSignIn(access: access, knownHosts: knownHosts), kind: "ssh")
        let keepAlive = ConnectionService.keepAlive(ssh)
        return try await Self.closing({ keepAlive.cancel(); try? await ssh.close(); endCommandHistory(.closed) }) {
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
                                _ signIn: CommandSignIn, kind: String) async throws -> SSHSession {
        var settings = settings, secret = secret
        var key = SessionKey.looksLikeKey(settings.username) ? settings.username : nil
        if settings.usesSessionKey {
            // The key is this session's secret: typed, or the line given with --password-stdin.
            let typed: String
            if let secret { typed = secret } else {
                typed = try await signIn.answer(endpoint: KnownHosts.endpoint(host: settings.host, port: settings.port),
                                                challenge: SSHLoginChallenge(name: "", instruction: "", prompts: [.init(text: "Session key: ", hidden: true)])).first ?? ""
            }
            let read = try SessionKey.read(typed, host: settings.host, port: settings.port).key
            settings.username = read
            settings.signIn = .questions
            key = read
            secret = nil
        }
        commandHistoryID = history.begin(name: item.name, kind: kind, host: settings.host, port: settings.port,
                                         user: settings.username, source: "cli", secret: key)
        if secret != nil, settings.usesAgent == true, settings.identityPath == nil {
            throw WorkspaceError.invalid("This profile signs in with an SSH agent. Omit --password-stdin.")
        }
        do {
            let target = ConnectionService.sshTarget(settings)
            let hops = try connections.jumpHosts(for: target, excluding: item.id)
            history.addRoute(to: commandHistoryID, target: target, hops: hops,
                             names: sessionTree.jumpRoute(for: target, excluding: item.id)?.map(\.name) ?? [])
            let ssh = try await connections.openSSH(target, hops: hops, secret: secret ?? "", handler: signIn)
            history.add(.connected, to: commandHistoryID)
            return ssh
        } catch {
            let text = ConnectionService.failureText(error, reported: nil)
            endCommandHistory(.failed, detail: text)
            throw WorkspaceError.invalid(text)
        }
    }

    /// Reads the commands typed in `gloamux ssh` into the history of its connection, or nil when they are not kept.
    public func commandCapture() -> CommandCapture? {
        guard let id = commandHistoryID, ConnectionHistory.keepsCommands else { return nil }
        return CommandCapture { [weak self] command in self?.history.add(.command, to: id, detail: command) }
    }

    /// Writes one change a command made on the server to the history of its connection.
    public func noteCommandChange(_ operation: String, _ paths: [String], mode: UInt32? = nil) {
        switch operation {
        case "mkdir": history.add(.folderCreated, to: commandHistoryID, detail: paths[0])
        case "mv", "rename": history.add(.renamed, to: commandHistoryID, detail: paths[0] + " → " + paths[1])
        case "rm", "rmdir": history.add(.deleted, to: commandHistoryID, detail: paths[0])
        case "chmod": history.add(.permissions, to: commandHistoryID, detail: String(mode ?? 0, radix: 8) + " " + paths[0])
        default: break
        }
    }

    private func endCommandHistory(_ event: ConnectionRecord.Event.Kind, detail: String? = nil) {
        history.add(event, to: commandHistoryID, detail: detail)
        commandHistoryID = nil
    }

    /// Writes one copy a command made to the history of its connection.
    public func noteCommandCopy(download: Bool, path: String, bytes: UInt64? = nil, error: String? = nil) {
        if let error { history.add(.transferFailed, to: commandHistoryID, detail: path + ": " + error) }
        else { history.add(download ? .downloaded : .uploaded, to: commandHistoryID, detail: path, bytes: bytes) }
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
