import FileTransfer
import Foundation
import Ssh

/// Who answers one connection attempt's questions, and what the attempt may keep. A tab answers in its window and
/// keeps what worked; a command answers from its own options and keeps nothing.
@MainActor protocol SignInHandler: AnyObject, Sendable {
    /// False once the attempt was replaced or abandoned, for example by a disconnect.
    var isCurrent: Bool { get }
    /// Whether a password or passphrase that worked is kept for the session, and a refused saved one forgotten.
    var savesCredentials: Bool { get }
    /// A problem already explained to the user, which a failed sign-in reports instead of its own error.
    var reportedError: String? { get }
    func status(_ text: String)
    /// Returns when the server's host key may be used; throws to refuse it.
    func confirmHostKey(endpoint: String, key: String) async throws
    func answer(endpoint: String, challenge: SSHLoginChallenge) async throws -> [String]
}

/// A connection that failed at a jump host rather than at the destination.
struct JumpHostFailure: Error {
    let host: String
    /// The route has more than one jump host, so the message names this one.
    let ofMany: Bool
    let underlying: Error
}

/// Opens SSH and FTP connections from the data every window shares: the session catalog, known hosts, and the
/// vault. It keeps no window, tab, or connection state; each attempt brings a `SignInHandler`, and its caller owns
/// what it returns and closes it.
@MainActor struct ConnectionService {
    let sessionTree: SessionTreeStore
    let vault: CredentialVault
    /// Touch ID or the Mac password, for a session marked to ask on every connection.
    let confirmOwner: (String) async throws -> Void
    /// Called after a connection that saves credentials, so views of the vault update.
    let vaultChanged: () async -> Void

    // MARK: Settings

    /// The SSH settings a saved session connects with: the same values a tab filled from it connects with.
    static func sshTarget(_ settings: SavedConnection) -> SavedConnection {
        SavedConnection(host: settings.host.trimmingCharacters(in: .whitespacesAndNewlines), port: settings.port,
                        username: settings.username, proxyHost: settings.proxyHost,
                        proxyPort: settings.proxyHost == nil ? nil : settings.proxyPort ?? 1080,
                        identityPath: settings.identityPath, jumpSessionID: settings.jumpSessionID,
                        usesAgent: settings.usesAgent == true, agentSocket: settings.agentSocket,
                        proxyKind: settings.proxyKind ?? .socks5, confirmsEachConnection: settings.asksEachConnection)
    }

    /// The jump hosts before `target`, first hop first. `id` is the session being opened, so a route back to it fails.
    func jumpHosts(for target: SavedConnection, excluding id: UUID?) throws -> [SavedConnection] {
        try target.validate()
        guard let chain = sessionTree.jumpChain(for: target, excluding: id) else {
            throw WorkspaceError.invalid("Choose an available jump host in Connection settings.")
        }
        return chain
    }

    /// The vault entry of an account: `user@host:port` for SSH, `ftp:user@host:port` for FTP.
    static func credentialID(username: String, host: String, port: Int, ftp: Bool) -> String {
        (ftp ? "ftp:" : "") + "\(username.isEmpty && ftp ? "anonymous" : username)@"
            + KnownHosts.endpoint(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    }

    /// What a failed connection says: the error the user was already shown, or this one, naming the jump host.
    static func failureText(_ error: Error, reported: String?) -> String {
        guard let failure = error as? JumpHostFailure else { return reported ?? message(for: error) }
        let detail = reported ?? message(for: failure.underlying)
        let label = failure.ofMany ? "\(failure.host) – " + T(detail) : T(detail)
        return String(format: T("Jump host: %@"), label)
    }

    // MARK: SSH

    /// Confirms the owner where a session asks on every connection, reads passwords that only the locked vault holds
    /// with Touch ID, then signs in through each jump host to `target`. `jumped` sees each jump host session as it
    /// opens, so the owner of the attempt can close it if the attempt is abandoned. An attempt that stops being
    /// current throws `CancellationError`; a failure at a jump host throws `JumpHostFailure`.
    func openSSH(_ target: SavedConnection, hops: [SavedConnection], secret: String, jumpSecret: String,
                 handler: SignInHandler, jumped: (SSHSession) -> Void = { _ in }) async throws -> SSHSession {
        // An unlocked password vault already confirmed the owner for this launch, so it does not ask per connection.
        // While it is locked, a session marked to ask on every connection asks: Touch ID or the Mac password.
        let vaultUnlocked = await vault.state == "Unlocked"
        let asks = !vaultUnlocked
            && ((target.asksEachConnection && secret.isEmpty) || hops.contains(where: \.asksEachConnection))
        let reason = String(format: T("connect to %@"), "\(target.username)@\(target.host)")
        var confirmed = false
        // A password that only the locked vault holds is read with Touch ID for this one connection. That prompt is
        // also the per-connection check; the vault stays locked.
        if !vaultUnlocked, await vault.touchIDEnrolled {
            let accounts = (secret.isEmpty ? [target] : []) + hops
            let needed = Set(accounts.flatMap { connection in
                ["\(connection.username)@\(KnownHosts.endpoint(host: connection.host, port: connection.port))"]
                    + (connection.identityPath.map { [WorkspaceModel.passphraseID($0)] } ?? [])
            })
            let locked = await vault.lockedVaultIDs(needed)
            if !locked.isEmpty {
                handler.status("Waiting for Touch ID…")
                try await vault.readWithTouchID(ids: locked, reason: reason)
                guard handler.isCurrent else { throw CancellationError() }
                confirmed = true
                handler.status("Connecting…")
            }
        }
        if asks, !confirmed {
            handler.status("Waiting for Touch ID…")
            do { try await confirmOwner(reason) }
            catch { throw WorkspaceError.invalid("This session asks for Touch ID or the Mac password before it connects.") }
            guard handler.isCurrent else { throw CancellationError() }
            handler.status("Connecting…")
        }
        // Each hop is reached through the one before it. The typed jump secret belongs to the host the destination is
        // reached from; earlier hops use their key or the password remembered for this session.
        var jump: SSHSession?
        do {
            for (index, hop) in hops.enumerated() {
                handler.status("Connecting to jump host…")
                let server: SSHSession
                do {
                    server = try await establish(hop, secret: index == hops.count - 1 ? jumpSecret : "", handler: handler, via: jump)
                } catch {
                    throw JumpHostFailure(host: hop.host, ofMany: hops.count > 1, underlying: error)
                }
                guard handler.isCurrent else { try? await server.close(); throw CancellationError() }
                jump = server
                jumped(server)
                handler.status("Connecting…")
            }
            let ssh = try await establish(target, secret: secret, handler: handler, via: jump)
            guard handler.isCurrent else { try? await ssh.close(); throw CancellationError() }
            return ssh
        } catch {
            // Closing a session also closes the jump hosts it was reached through.
            try? await jump?.close()
            throw error
        }
    }

    private func establish(_ configuration: SavedConnection, secret: String, handler: SignInHandler,
                           via jump: SSHSession?) async throws -> SSHSession {
        let endpoint = KnownHosts.endpoint(host: configuration.host, port: configuration.port)
        let id = "\(configuration.username)@\(endpoint)"
        let settings = SSHConnectionSettings(host: configuration.host, port: configuration.port, username: configuration.username)
        let credentialGeneration = await vault.sessionGeneration
        let credential: SSHCredential
        let password: String?
        var keySecret: (id: String, value: String)?
        if configuration.usesKeys {
            var agent: SSHAgentClient?
            if configuration.usesAgent == true {
                agent = configuration.agentSocket.map { SSHAgentClient(socketPath: $0) } ?? SSHAgentClient.environment()
                if agent == nil && configuration.identityPath == nil { throw SSHAgentError.unavailable }
            }
            let file = configuration.identityPath.map { URL(fileURLWithPath: $0) }
            // A passphrase typed once is kept in the vault under the key's path.
            var passphrase = secret
            if passphrase.isEmpty, let path = configuration.identityPath {
                passphrase = (try? await vault.password(id: WorkspaceModel.passphraseID(path))) ?? ""
            }
            credential = try await Task.detached(priority: .userInitiated) { [agent, passphrase] in
                try SSHCredential.keys(agent: agent, identityFile: file, passphrase: passphrase)
            }.value
            keySecret = configuration.identityPath.map { (WorkspaceModel.passphraseID($0), passphrase) }
            password = nil
        } else {
            let value = secret.isEmpty ? try await vault.password(id: id) : secret
            credential = .password(value)
            password = value
        }
        guard handler.isCurrent else { throw CancellationError() }
        let policy: HostKeyPolicy = .confirm { key in
            try await handler.confirmHostKey(endpoint: endpoint, key: key)
        }
        let asked = LoginAsked()
        let answer: SSHLoginAnswerer = { challenge in
            asked.value = true
            return try await handler.answer(endpoint: endpoint, challenge: challenge)
        }
        do {
            let ssh: SSHSession
            if let jump {
                ssh = try await SSHSession.connect(settings: settings, credential: credential, via: jump, hostKey: policy, answer: answer)
            } else {
                ssh = try await SSHSession.connect(settings: settings, credential: credential, proxy: configuration.proxy, hostKey: policy,
                                                   answer: answer)
            }
            if handler.savesCredentials {
                if handler.isCurrent, let password {
                    await vault.rememberWorking(id: id, secret: password, generation: credentialGeneration)
                }
                if handler.isCurrent, let keySecret {
                    await vault.rememberWorking(id: keySecret.id, secret: keySecret.value, generation: credentialGeneration)
                }
                await vaultChanged()
            }
            return ssh
        } catch SSHError.authenticationFailed {
            // Answers the user typed were refused, not the saved password or key, so nothing is forgotten.
            if asked.value { throw WorkspaceError.invalid("Sign-in failed. Check your answers and try again.") }
            guard let password else {
                throw WorkspaceError.invalid("SSH authentication failed. Check the username and private key.")
            }
            if handler.savesCredentials, secret.isEmpty, handler.isCurrent, handler.reportedError == nil {
                await vault.forgetForSession(id: id, matching: password, generation: credentialGeneration)
            }
            throw SSHError.authenticationFailed
        }
    }

    /// Checks an idle command connection the way a tab does: one round trip every
    /// `TerminalPreferences.keepAliveInterval` seconds, so a server that went away ends the connection.
    static func keepAlive(_ ssh: SSHSession) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                let interval = TerminalPreferences.keepAliveInterval
                try? await Task.sleep(for: .seconds(interval > 0 ? interval : 30))
                guard !Task.isCancelled else { return }
                guard interval > 0 else { continue }
                _ = await ssh.checkAlive(timeoutSeconds: 15)
            }
        }
    }

    // MARK: Files

    /// The file channel over a signed-in SSH session: SCP when chosen, otherwise SFTP, falling back to SCP on servers
    /// without an SFTP subsystem unless SFTP was chosen.
    static func openFiles(_ ssh: SSHSession, choice: FileProtocolChoice?) async throws -> any RemoteFileSystem {
        if choice == .scp { return try await SCPTransfer.open(ssh) }
        do { return try await SFTPTransfer.open(ssh) } catch {
            guard choice == nil, !(error is CancellationError) else { throw error }
            return try await SCPTransfer.open(ssh)
        }
    }

    /// Signs in to an FTP or FTPS server. Passwords come from the vault like SSH passwords, under `ftp:user@host:port`;
    /// anonymous FTP has none.
    func openFTP(host: String, port: Int, username: String, typedPassword: String, security: FTPSecurity,
                 fingerprint: String?, asksEachConnection: Bool, handler: SignInHandler) async throws -> FTPTransfer {
        let account = Self.credentialID(username: username, host: host, port: port, ftp: true)
        let vaultUnlocked = await vault.state == "Unlocked"
        if asksEachConnection, !vaultUnlocked, typedPassword.isEmpty {
            handler.status("Waiting for Touch ID…")
            do { try await confirmOwner(String(format: T("connect to %@"), account)) }
            catch { throw WorkspaceError.invalid("This session asks for Touch ID or the Mac password before it connects.") }
            guard handler.isCurrent else { throw CancellationError() }
            handler.status("Connecting…")
        }
        let generation = await vault.sessionGeneration
        var password = typedPassword
        if password.isEmpty && !username.isEmpty && username != "anonymous" {
            password = try await vault.password(id: account)
        }
        let settings = FTPSettings(host: host, port: port, username: username, password: password,
                                   security: security, trustedFingerprint: fingerprint)
        let transfer = try await FTPTransfer.connect(settings)
        guard handler.isCurrent else { try? await transfer.close(); throw CancellationError() }
        if handler.savesCredentials {
            if !password.isEmpty { await vault.rememberWorking(id: account, secret: password, generation: generation) }
            await vaultChanged()
        }
        return transfer
    }
}

/// Set once the server's sign-in questions went to the user.
private final class LoginAsked: @unchecked Sendable {
    var value = false
}

/// A sign-in that answers in a tab: host keys and the server's questions are shown in its window, and a password or
/// passphrase that worked is kept for the session.
@MainActor final class TabSignIn: SignInHandler {
    private weak var model: WorkspaceModel?
    private weak var tab: SessionTab?
    let epoch: UUID

    init(model: WorkspaceModel, tab: SessionTab, epoch: UUID) {
        self.model = model; self.tab = tab; self.epoch = epoch
    }

    var isCurrent: Bool { tab?.epoch == epoch }
    var savesCredentials: Bool { true }
    var reportedError: String? { tab?.error }
    func status(_ text: String) { if isCurrent { tab?.status = text } }
    func confirmHostKey(endpoint: String, key: String) async throws {
        guard let model, let tab else { throw WorkspaceError.rejectedHostKey }
        try await model.confirmKey(tab, endpoint: endpoint, key: key, epoch: epoch)
    }
    func answer(endpoint: String, challenge: SSHLoginChallenge) async throws -> [String] {
        guard let model, let tab else { throw SSHError.signInCancelled }
        return try await model.askLogin(tab, endpoint: endpoint, challenge: challenge, epoch: epoch)
    }
}

/// A sign-in for a command: a host key must already be trusted or verified with `--host-key`, the server's questions
/// go to the command's answerer, and nothing is saved.
@MainActor final class CommandSignIn: SignInHandler {
    private let access: FileCommandAccess
    private let knownHosts: KnownHosts

    init(access: FileCommandAccess, knownHosts: KnownHosts) {
        self.access = access; self.knownHosts = knownHosts
    }

    var isCurrent: Bool { true }
    var savesCredentials: Bool { false }
    var reportedError: String? { nil }
    func status(_ text: String) {}
    func confirmHostKey(endpoint: String, key: String) async throws {
        if try knownHosts.isTrusted(endpoint: endpoint, key: key) { return }
        let fingerprint = try KnownHosts.fingerprint(key)
        guard access.hostKeys.contains(fingerprint) else {
            throw WorkspaceError.invalid("Unrecognized SSH host key for \(endpoint): \(fingerprint). Verify it before using --host-key.")
        }
    }
    func answer(endpoint: String, challenge: SSHLoginChallenge) async throws -> [String] {
        guard let answer = access.answer else {
            throw WorkspaceError.invalid("SSH requires interactive sign-in. Use --interactive from a terminal.")
        }
        return try await answer(challenge)
    }
}

extension WorkspaceModel {
    /// Opening connections from this workspace's shared data.
    var connections: ConnectionService {
        ConnectionService(sessionTree: sessionTree, vault: vault,
                          confirmOwner: { [weak self] reason in
                              guard let self else { throw CancellationError() }
                              try await self.confirmOwner(reason)
                          },
                          vaultChanged: { [weak self] in await self?.refreshVault() })
    }
}
