import Foundation
import Ssh

/// The SSH connection a remote desktop is reached through. It belongs to the desktop session, not to a tab: it opens
/// only the forward to the desktop (none of the gateway session's own forwards), and its host key and sign-in
/// questions show in the desktop pane.
@MainActor final class DesktopGateway: ObservableObject, Identifiable {
    let name: String
    @Published fileprivate(set) var hostKeyPrompt: HostKeyPrompt?
    @Published fileprivate(set) var loginChallenge: LoginChallengePrompt?
    /// The problem the user was shown, which the failed connection reports.
    fileprivate(set) var error: String?
    fileprivate var trustContinuation: CheckedContinuation<Void, Error>?
    fileprivate var loginContinuation: CheckedContinuation<[String], Error>?
    private(set) var closed = false
    private var session: SSHSession?
    private var forward: SSHLocalForward?
    private var keepAlive: Task<Void, Never>?

    init(name: String) { self.name = name }

    /// Trusts or refuses the key on screen.
    func answerHostKey(approve: Bool, knownHosts: KnownHosts) {
        guard let continuation = trustContinuation else { return }
        let prompt = hostKeyPrompt
        trustContinuation = nil; hostKeyPrompt = nil
        do {
            try WorkspaceModel.settleHostKey(prompt, approve: approve, knownHosts: knownHosts)
            continuation.resume()
        } catch { continuation.resume(throwing: error) }
    }

    /// Sends the answers to the server's sign-in questions, or cancels the sign-in with nil.
    func answerLogin(_ answers: [String]?) {
        guard let continuation = loginContinuation else { return }
        loginContinuation = nil; loginChallenge = nil
        if let answers { continuation.resume(returning: answers) } else { continuation.resume(throwing: SSHError.signInCancelled) }
    }

    fileprivate func opened(_ ssh: SSHSession, forward: SSHLocalForward) {
        session = ssh
        self.forward = forward
        keepAlive = ConnectionService.keepAlive(ssh)
    }

    /// Ends the forward and the connection, and any question still on screen.
    func close() {
        guard !closed else { return }
        closed = true
        keepAlive?.cancel(); keepAlive = nil
        trustContinuation?.resume(throwing: WorkspaceError.rejectedHostKey); trustContinuation = nil; hostKeyPrompt = nil
        loginContinuation?.resume(throwing: SSHError.signInCancelled); loginContinuation = nil; loginChallenge = nil
        let forward = forward, session = session
        self.forward = nil; self.session = nil
        Task {
            await forward?.close()
            try? await session?.close()
        }
    }
}

/// Answers a gateway's sign-in in the desktop pane. Like a tab, it keeps a password or passphrase that worked.
@MainActor final class GatewaySignIn: SignInHandler {
    private weak var gateway: DesktopGateway?
    private let knownHosts: KnownHosts

    init(gateway: DesktopGateway, knownHosts: KnownHosts) { self.gateway = gateway; self.knownHosts = knownHosts }

    var isCurrent: Bool { gateway.map { !$0.closed } ?? false }
    var savesCredentials: Bool { true }
    var reportedError: String? { gateway?.error }
    func status(_ text: String) {}
    func confirmHostKey(endpoint: String, key: String) async throws {
        guard let gateway, !gateway.closed else { throw WorkspaceError.rejectedHostKey }
        do { if try knownHosts.isTrusted(endpoint: endpoint, key: key) { return } }
        catch WorkspaceError.changedHostKey {
            if let saved = knownHosts.trustedKey(for: endpoint) { knownHosts.record(.blocked, endpoint: endpoint, key: key, previous: saved) }
            gateway.error = "The server host key has changed. Review its fingerprint before reconnecting."
            throw WorkspaceError.changedHostKey(endpoint)
        } catch { gateway.error = message(for: error); throw error }
        guard gateway.trustContinuation == nil else { throw WorkspaceError.rejectedHostKey }
        let prompt = HostKeyPrompt(endpoint: endpoint, fingerprint: try KnownHosts.fingerprint(key), key: key)
        try await withCheckedThrowingContinuation { continuation in
            gateway.trustContinuation = continuation; gateway.hostKeyPrompt = prompt
        }
        guard !gateway.closed else { throw WorkspaceError.rejectedHostKey }
    }
    func answer(endpoint: String, challenge: SSHLoginChallenge) async throws -> [String] {
        guard let gateway, !gateway.closed, gateway.loginContinuation == nil else { throw SSHError.signInCancelled }
        let prompt = LoginChallengePrompt(endpoint: endpoint, challenge: challenge)
        let answers = try await withCheckedThrowingContinuation { continuation in
            gateway.loginContinuation = continuation; gateway.loginChallenge = prompt
        }
        guard !gateway.closed else { throw SSHError.signInCancelled }
        return answers
    }
}

extension WorkspaceModel {
    /// Connects the desktop's saved SSH gateway and forwards a port on 127.0.0.1 to the desktop through it, returning
    /// that port. The desktop session closes the gateway when it stops.
    func openDesktopTunnel(_ desktop: RemoteDesktopSession, gateway id: UUID, host: String, port: Int) async throws -> Int {
        guard let item = sessionTree.node(id), let settings = item.connection, !settings.isFTP else {
            throw WorkspaceError.invalid("The SSH session this desktop connects through no longer exists.")
        }
        let gateway = DesktopGateway(name: item.name)
        desktop.gateway = gateway
        desktop.closeTunnel = { [weak gateway] in gateway?.close() }
        let service = connections
        let target = ConnectionService.sshTarget(settings)
        do {
            let hops = try service.jumpHosts(for: target, excluding: id)
            let signIn = GatewaySignIn(gateway: gateway, knownHosts: knownHosts)
            let ssh = try await service.openSSH(target, hops: hops, secret: "", handler: signIn)
            let forward: SSHLocalForward
            do { forward = try await ssh.startLocalForward(localPort: 0, targetHost: host, targetPort: port) }
            catch { try? await ssh.close(); throw error }
            guard !gateway.closed else { await forward.close(); try? await ssh.close(); throw CancellationError() }
            gateway.opened(ssh, forward: forward)
            return forward.port
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = ConnectionService.failureText(error, reported: gateway.error)
            gateway.close()
            throw WorkspaceError.invalid(String(format: T("Cannot connect to %@ to reach the desktop."), item.name) + " " + T(reason))
        }
    }

    /// Trusts an approved host key, or records a declined one. Shared by tabs and desktop gateways.
    static func settleHostKey(_ prompt: HostKeyPrompt?, approve: Bool, knownHosts: KnownHosts) throws {
        guard approve, let prompt else {
            if let prompt { knownHosts.record(.declined, endpoint: prompt.endpoint, key: prompt.key) }
            throw WorkspaceError.rejectedHostKey
        }
        try knownHosts.trust(endpoint: prompt.endpoint, key: prompt.key)
    }
}
