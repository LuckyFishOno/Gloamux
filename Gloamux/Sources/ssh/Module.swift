// SSH client built directly on SwiftNIO SSH (NIOSSH) plus NIOSOCKS for proxies. Citadel supplies the
// AES-CTR compatibility primitive; transport/session management and SFTP remain native NIO implementations.
//
// The proxy path is first-class: the bootstrap's channelInitializer installs the SOCKS handler ahead of
// the NIOSSH handler, so the SOCKS tunnel is established before the SSH handshake runs over it. Direct
// connections skip the SOCKS handler. SFTP is provided by the file-transfer module over this session.
import GloamuxShared
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NIOSOCKS
import Profiles
import GloamuxNetwork

public enum SSHCredential: Sendable {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
    /// Offers each key in turn, as OpenSSH does with agent keys followed by an identity file.
    case privateKeys([NIOSSHPrivateKey])
    /// Nothing to offer: the user answers the server's questions, or types a password when it only accepts one.
    case interactive
}

/// Questions a server asks while signing in (keyboard-interactive, RFC 4256), such as a password and a one-time code.
public struct SSHLoginChallenge: Equatable, Sendable {
    public struct Prompt: Equatable, Sendable {
        public var text: String
        /// True for secrets, which should not be shown as they are typed.
        public var hidden: Bool
        public init(text: String, hidden: Bool) { self.text = text; self.hidden = hidden }
    }
    public var name: String
    public var instruction: String
    public var prompts: [Prompt]
    public init(name: String, instruction: String, prompts: [Prompt]) { self.name = name; self.instruction = instruction; self.prompts = prompts }
}

/// Answers a login challenge with one answer per prompt, in order. Throwing cancels the sign-in.
public typealias SSHLoginAnswerer = @Sendable (SSHLoginChallenge) async throws -> [String]

public enum HostKeyPolicy: Sendable {
    /// Accept any host key. Convenient for first use; not safe for production (no trust store yet).
    case acceptAny
    /// Accept only keys in this set.
    case trusted([NIOSSHPublicKey])
    /// The application explicitly confirms/pins the presented OpenSSH public key before authentication.
    case confirm(@Sendable (String) async throws -> Void)
}

public struct SSHConnectionSettings: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    /// The key exchanges offered: Modern, or Compatible for servers that have only finite-field Diffie-Hellman.
    public var algorithms: SSHAlgorithmSet = .modern
    public init(host: String, port: Int = 22, username: String, algorithms: SSHAlgorithmSet = .modern) {
        self.host = host; self.port = port; self.username = username; self.algorithms = algorithms
    }

    public init(profile: SessionProfile) throws {
        guard !profile.connection.host.isEmpty else { throw SSHError.invalidSettings("session has no host") }
        switch profile.resolvedProtocol {
        case .ssh, .sftp: break
        default: throw SSHError.invalidSettings("session protocol is \(profile.connection.protocolName.isEmpty ? "unset" : profile.connection.protocolName), not SSH/SFTP")
        }
        self.host = profile.connection.host
        self.port = Int(profile.connection.port)
        self.username = profile.connection.userName
    }
}

public enum SSHError: Error, Equatable {
    case invalidSettings(String)
    case connectFailed(String)
    case authenticationFailed
    /// The user cancelled a sign-in question, such as a verification code.
    case signInCancelled
    case commandFailed(String)
    case notConnected
}

// MARK: - Auth and host-key delegates

/// Offers the credential's keys one at a time, then answers the server's questions (keyboard-interactive), then offers the
/// password, as OpenSSH does: a server that asks for a password and a verification code often lists both methods, and
/// refuses the password on its own. NIOSSH asks again after each rejection. Without anyone to answer, the password goes
/// first, since a verification code could not be answered.
final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var offers: [NIOSSHUserAuthenticationOffer]
    private let username: String
    private let password: String?
    private let answer: SSHLoginAnswerer?
    private let interactive: Bool
    private var questionsTried = false
    /// The password was sent to the server, as an answer or as a password sign-in.
    private var passwordSent = false
    /// The methods offered so far. A server that stops listing all of them accepted one as a partial success.
    private var offered: NIOSSHAvailableUserAuthenticationMethods = []
    /// Its timeout stops while the user answers.
    weak var watcher: AuthWatcher?

    init(username: String, credential: SSHCredential, answer: SSHLoginAnswerer? = nil) {
        self.username = username
        self.answer = answer
        if case .password(let p) = credential { password = p } else { password = nil }
        if case .interactive = credential { interactive = true } else { interactive = false }
        func key(_ k: NIOSSHPrivateKey) -> NIOSSHUserAuthenticationOffer {
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: k)))
        }
        switch credential {
        case .password, .interactive: offers = []
        case .privateKey(let k): offers = [key(k)]
        case .privateKeys(let keys): offers = keys.map(key)
        }
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        // A method that is no longer listed was accepted and another step follows.
        let nextStep = !offered.isEmpty && availableMethods.isDisjoint(with: offered)
        func offerQuestions() {
            questionsTried = true
            offered.insert(.keyboardInteractive)
            nextChallengePromise.succeed(.keyboardInteractive(username: username))
        }
        func offerPassword(_ value: String) {
            passwordSent = true
            offered.insert(.password)
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: value))))
        }
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            if availableMethods.contains(.publicKey) { offered.insert(.publicKey); nextChallengePromise.succeed(offer); return }
        }
        let asksQuestions = availableMethods.contains(.keyboardInteractive) && !questionsTried
        if asksQuestions, answer != nil { offerQuestions(); return }
        // The same password is not sent twice: a server may lock the account after a few wrong ones.
        if availableMethods.contains(.password), let password, !passwordSent || nextStep { offerPassword(password); return }
        if asksQuestions, password != nil, offered.isEmpty || nextStep { offerQuestions(); return }
        if interactive, let answer, availableMethods.contains(.password), !passwordSent, !questionsTried || nextStep {
            let loop = nextChallengePromise.futureResult.eventLoop
            let watcher = self.watcher
            watcher?.pauseTimeout()
            Task {
                do {
                    let typed = try await answer(SSHLoginChallenge(name: "", instruction: "", prompts: [.init(text: "Password:", hidden: true)]))
                    loop.execute { watcher?.resumeTimeout(); offerPassword(typed.first ?? "") }
                } catch {
                    nextChallengePromise.fail(SSHError.signInCancelled)
                }
            }
            return
        }
        nextChallengePromise.fail(SSHError.authenticationFailed)
    }

    func respondToKeyboardInteractive(_ challenge: NIOSSHKeyboardInteractiveChallenge, responsePromise: EventLoopPromise<[String]>) {
        // Some servers only send a message, with nothing to answer.
        if challenge.prompts.isEmpty { responsePromise.succeed([]); return }
        // The session's password answers the server's first password question, once: a second one means it was wrong.
        if let password, !passwordSent, challenge.prompts.count == 1, !challenge.prompts[0].echo,
           Self.asksForPassword(challenge.prompts[0].text) {
            passwordSent = true
            responsePromise.succeed([password])
            return
        }
        guard let answer else { responsePromise.fail(SSHError.authenticationFailed); return }
        let question = SSHLoginChallenge(name: challenge.name, instruction: challenge.instruction,
                                         prompts: challenge.prompts.map { .init(text: $0.text, hidden: !$0.echo) })
        let loop = responsePromise.futureResult.eventLoop
        let watcher = self.watcher
        watcher?.pauseTimeout()
        Task {
            do {
                let answers = try await answer(question)
                loop.execute { watcher?.resumeTimeout() }
                responsePromise.succeed(answers)
            } catch {
                responsePromise.fail(SSHError.signInCancelled)
            }
        }
    }

    private static let passwordWords = ["password", "passwort", "passwd", "mot de passe", "contraseña", "senha", "пароль",
                                        "パスワード", "비밀번호", "암호", "密碼", "密码"]

    static func asksForPassword(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        // A one-time password is a code, not the saved password.
        if text.range(of: #"one[- ]?time|\botp\b"#, options: .regularExpression) != nil { return false }
        return passwordWords.contains(where: text.contains)
    }
}

final class AcceptAllHostKeys: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) { validationCompletePromise.succeed(()) }
}

final class TrustedHostKeys: NIOSSHClientServerAuthenticationDelegate {
    private let trusted: [NIOSSHPublicKey]
    init(_ keys: [NIOSSHPublicKey]) { trusted = keys }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if trusted.contains(hostKey) { validationCompletePromise.succeed(()) } else { validationCompletePromise.fail(SSHError.connectFailed("untrusted host key")) }
    }
}

final class ConfirmHostKey: NIOSSHClientServerAuthenticationDelegate {
    let confirm: @Sendable (String) async throws -> Void
    init(_ confirm: @escaping @Sendable (String) async throws -> Void) { self.confirm = confirm }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        Task {
            do { try await confirm(key); validationCompletePromise.succeed(()) }
            catch { validationCompletePromise.fail(error) }
        }
    }
}

// Fulfilled when NIOSSH reports authentication success on the parent channel; failed if the channel
// closes first (auth failure or transport error).
final class AuthWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let promise: EventLoopPromise<Void>
    private var settled = false
    private var timeout: Scheduled<Void>?
    private let timeoutSeconds: Int64
    private var context: ChannelHandlerContext?
    /// A name with IPv6 and IPv4 addresses makes one channel for each address tried. Only the one that connected counts.
    private let adopts: Bool
    private var adopted: ObjectIdentifier?
    init(_ promise: EventLoopPromise<Void>, timeoutSeconds: Int64, adopts: Bool = false) {
        self.promise = promise; self.timeoutSeconds = timeoutSeconds; self.adopts = adopts
    }
    /// The channel that connected, when several addresses were tried. On the event loop.
    func adopt(_ channel: Channel) {
        adopted = ObjectIdentifier(channel)
        context = try? channel.pipeline.syncOperations.context(handler: self)
        if !channel.isActive { failIfPending(SSHError.connectFailed("SSH connection closed during authentication")) }
    }
    private func concerns(_ context: ChannelHandlerContext) -> Bool { !adopts || adopted == ObjectIdentifier(context.channel) }
    func handlerAdded(context: ChannelHandlerContext) {
        if !adopts { self.context = context }
        if timeout == nil { startTimeout(context.eventLoop) }
    }
    /// Stops the clock while the user answers a sign-in question. On the event loop.
    func pauseTimeout() { timeout?.cancel(); timeout = nil }
    /// Starts the full time again after an answer. On the event loop.
    func resumeTimeout() {
        guard !settled, timeout == nil, let context else { return }
        startTimeout(context.eventLoop)
    }
    private func startTimeout(_ eventLoop: EventLoop) {
        timeout = eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            guard !self.settled else { return }
            self.settled = true
            self.promise.fail(SSHError.connectFailed("SSH handshake/authentication timed out"))
            self.context?.close(promise: nil)
        }
    }
    func failIfPending(_ error: Error) {
        guard !settled else { return }
        settled = true
        timeout?.cancel()
        promise.fail(error)
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        guard concerns(context) else { return }
        self.context = nil
        failIfPending(SSHError.connectFailed("SSH connection closed during authentication"))
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !settled { settled = true; timeout?.cancel(); promise.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if concerns(context) { failIfPending(SSHError.connectFailed("SSH connection closed during authentication")) }
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if concerns(context) {
            failIfPending((error as? SSHError) ?? SSHError.connectFailed((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
        }
        context.close(promise: nil)
    }
}

// MARK: - Exec

// Runs one command on a session child channel and collects stdout as a string. Completes when the
// channel closes (EOF) or exit-status arrives.
final class CollectingExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let maxBytes: Int
    private let includeStandardError: Bool
    private var promise: EventLoopPromise<String>?
    private var stdout = ByteBuffer()
    private var exitStatus: Int?
    private var sawEOF = false

    init(command: String, maxBytes: Int, includeStandardError: Bool = false, promise: EventLoopPromise<String>) {
        self.command = command; self.maxBytes = maxBytes; self.includeStandardError = includeStandardError; self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { context.fireErrorCaught($0) }
    }
    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(exec).whenFailure { [weak self] error in self?.fail(error); context.close(promise: nil) }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = channelData.data else { return }
        if channelData.type == .channel || (includeStandardError && channelData.type == .stdErr) {
            guard bytes.readableBytes <= maxBytes - stdout.readableBytes else {
                fail(SSHError.commandFailed("command output exceeds limit")); context.close(promise: nil); return
            }
            let room = maxBytes - stdout.readableBytes
            if var slice = bytes.readSlice(length: min(room, bytes.readableBytes)) { stdout.writeBuffer(&slice) }
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = status.exitStatus
            if sawEOF { finish(); context.close(promise: nil) }
        } else if let event = event as? ChannelEvent, event == .inputClosed {
            sawEOF = true
            if exitStatus != nil { finish(); context.close(promise: nil) }
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error); context.close(promise: nil)
    }
    func failOpen(_ error: Error) { fail(error) }
    func failTimeout() { fail(SSHError.commandFailed("command timed out")) }
    private func fail(_ error: Error) {
        guard let p = promise else { return }; promise = nil; p.fail(error)
    }
    func channelInactive(context: ChannelHandlerContext) { finish(); context.fireChannelInactive() }
    func handlerRemoved(context: ChannelHandlerContext) { finish() }

    private func finish() {
        guard let p = promise else { return }
        promise = nil
        guard let exitStatus else { p.fail(SSHError.commandFailed("channel closed without an exit status")); return }
        guard exitStatus == 0 else {
            let output = includeStandardError ? String((stdout.getString(at: stdout.readerIndex, length: stdout.readableBytes) ?? "").prefix(2048)) : ""
            p.fail(SSHError.commandFailed("exit status \(exitStatus)" + (output.isEmpty ? "" : "\n" + output))); return
        }
        p.succeed(stdout.getString(at: stdout.readerIndex, length: stdout.readableBytes) ?? "")
    }
}

// MARK: - Session

/// One authenticated SSH connection over a NIO channel (direct or SOCKS5-tunneled). `implemented-ok`
/// means the wrapper built and authenticated; it is not evidence of matching Xshell behavior.
public actor SSHSession {
    let channel: Channel
    private(set) var closed = false
    private let jump: SSHSession?
    /// Hands channels the server opens (forwarded ports) to the forward that asked for them.
    let inbound: InboundChannelRouter

    /// False once the connection to the server is gone.
    public nonisolated var isOpen: Bool { channel.isActive }

    init(channel: Channel, jump: SSHSession? = nil, inbound: InboundChannelRouter = InboundChannelRouter()) {
        self.channel = channel
        self.jump = jump
        self.inbound = inbound
    }

    public static func connect(settings: SSHConnectionSettings, credential: SSHCredential,
                               hostKey: HostKeyPolicy = .acceptAny, answer: SSHLoginAnswerer? = nil,
                               connectTimeoutSeconds: Int64 = 30) async throws -> SSHSession {
        try await connect(settings: settings, credential: credential, proxy: .direct, hostKey: hostKey, answer: answer,
                          connectTimeoutSeconds: connectTimeoutSeconds)
    }

    /// Connects directly or through a SOCKS5, SOCKS4, or HTTP CONNECT proxy. The proxy handler (when present) is installed before
    /// the NIOSSH handler, so the tunnel is ready before the SSH handshake.
    public static func connect(settings: SSHConnectionSettings, credential: SSHCredential, proxy: ProxyConfiguration,
                               hostKey: HostKeyPolicy = .acceptAny, answer: SSHLoginAnswerer? = nil,
                               connectTimeoutSeconds: Int64 = 30) async throws -> SSHSession {
        guard !settings.host.isEmpty, settings.port > 0, settings.port <= 65535, connectTimeoutSeconds > 0, connectTimeoutSeconds <= 3600 else { throw SSHError.invalidSettings("\(settings.host):\(settings.port)") }

        let useProxy = proxy.kind != .none
        let connectHost = useProxy ? proxy.host : settings.host
        let connectPort = useProxy ? proxy.port : settings.port
        if useProxy { guard !proxy.host.isEmpty, proxy.port > 0, proxy.port <= 65535 else { throw SSHError.invalidSettings("proxy \(proxy.host):\(proxy.port)") } }

        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let router = InboundChannelRouter()
        let authPromise = loop.makePromise(of: Void.self)
        let watcher = AuthWatcher(authPromise, timeoutSeconds: connectTimeoutSeconds, adopts: true)
        let config = clientConfiguration(settings: settings, credential: credential, hostKey: hostKey, answer: answer, watcher: watcher)

        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(connectTimeoutSeconds))
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                var handlers = ProxyHandshake.handlers(for: proxy, host: settings.host, port: settings.port)
                handlers.append(NIOSSHHandler(role: .client(config), allocator: channel.allocator,
                                              inboundChildChannelInitializer: router.initializer))
                handlers.append(watcher)
                return channel.pipeline.addHandlers(handlers)
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: connectHost, port: connectPort).map { channel in
                watcher.adopt(channel)
                return channel
            }.get()
        }
        catch {
            let failure = SSHError.connectFailed(String(describing: error))
            loop.execute { watcher.failIfPending(failure) }
            throw failure
        }
        try await finishAuthenticating(channel, auth: authPromise.futureResult)
        return SSHSession(channel: channel, inbound: router)
    }

    /// Opens a second SSH handshake over an authenticated jump host. The returned
    /// session owns the jump, which the caller should close if this handshake fails.
    public static func connect(settings: SSHConnectionSettings, credential: SSHCredential, via jump: SSHSession,
                               hostKey: HostKeyPolicy, answer: SSHLoginAnswerer? = nil,
                               connectTimeoutSeconds: Int64 = 30) async throws -> SSHSession {
        guard connectTimeoutSeconds > 0, connectTimeoutSeconds <= 3600 else { throw SSHError.invalidSettings("Invalid SSH timeout.") }
        let loop = jump.channel.eventLoop
        let router = InboundChannelRouter()
        let auth = loop.makePromise(of: Void.self)
        let watcher = AuthWatcher(auth, timeoutSeconds: connectTimeoutSeconds)
        let config = clientConfiguration(settings: settings, credential: credential, hostKey: hostKey, answer: answer, watcher: watcher)
        let channel: Channel
        do {
            channel = try await jump.openTCPChannel(host: settings.host, port: settings.port, timeoutSeconds: connectTimeoutSeconds) { child in
                child.pipeline.addHandlers([SSHByteStream(), NIOSSHHandler(role: .client(config), allocator: child.allocator,
                                                                           inboundChildChannelInitializer: router.initializer), watcher])
            }
        } catch {
            loop.execute { watcher.failIfPending(error) }
            throw error
        }
        try await finishAuthenticating(channel, auth: auth.futureResult)
        return SSHSession(channel: channel, jump: jump, inbound: router)
    }

    private static func finishAuthenticating(_ channel: Channel, auth: EventLoopFuture<Void>) async throws {
        do {
            try await withTaskCancellationHandler {
                try await auth.get()
                try Task.checkCancellation()
            } onCancel: {
                channel.close(promise: nil)
            }
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    private static func clientConfiguration(settings: SSHConnectionSettings, credential: SSHCredential,
                                            hostKey: HostKeyPolicy, answer: SSHLoginAnswerer?, watcher: AuthWatcher) -> SSHClientConfiguration {
        let serverAuth: NIOSSHClientServerAuthenticationDelegate = { switch hostKey { case .acceptAny: return AcceptAllHostKeys(); case .trusted(let k): return TrustedHostKeys(k); case .confirm(let action): return ConfirmHostKey(action) } }()
        let userAuth = PasswordAuthDelegate(username: settings.username, credential: credential, answer: answer)
        userAuth.watcher = watcher
        var config = SSHClientConfiguration(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)
        config.transportProtectionSchemes.append(SHA2AES128CTR.self)
        // Finite-field groups come after the elliptic-curve ones, so a server that has both uses the faster exchange.
        config.keyExchangeAlgorithms += settings.algorithms.keyExchanges

        return config
    }

    public func waitForDisconnect() async {
        try? await channel.closeFuture.get()
    }

    /// Runs one command and returns its stdout as a UTF-8 string.
    public func runCommand(_ command: String, maxResponseBytes: Int = 1 << 20, timeoutSeconds: Int64 = 30, includeStandardError: Bool = false) async throws -> String {
        guard !closed else { throw SSHError.notConnected }
        guard maxResponseBytes > 0, timeoutSeconds > 0, timeoutSeconds <= 3600 else { throw SSHError.invalidSettings("invalid command limit/timeout") }
        do {
            let handler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
            let result = channel.eventLoop.makePromise(of: String.self)
            let child = channel.eventLoop.makePromise(of: Channel.self)
            let exec = CollectingExecHandler(command: command, maxBytes: maxResponseBytes, includeStandardError: includeStandardError, promise: result)
            // Bound both channel creation and command completion. A rejected channel must resolve
            // the result promise even when the child handler was never installed.
            let parent = channel
            var opened: Channel?
            let timeout = channel.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
                exec.failTimeout()
                if let opened { opened.close(promise: nil) }
                else { parent.close(promise: nil) }
            }
            defer { timeout.cancel() }
            child.futureResult.whenComplete { outcome in
                switch outcome {
                case .success(let childChannel): opened = childChannel
                case .failure(let error): exec.failOpen(error)
                }
            }
            try await channel.eventLoop.submit {
                handler.createChannel(child, channelType: .session) { childChannel, _ in childChannel.pipeline.addHandler(exec) }
            }.get()
            return try await result.futureResult.get()
        } catch let e as SSHError { throw e } catch { throw SSHError.commandFailed(String(describing: error)) }
    }

    /// One round trip to the server that runs nothing: a session channel is opened and closed at once. When the
    /// server does not answer within `timeoutSeconds`, the connection is treated as gone and closed, so whoever waits
    /// on `waitForDisconnect` hears about it. A refused channel still proves the server is there.
    public func checkAlive(timeoutSeconds: Int64 = 15) async -> Bool {
        do {
            let child = try await openChildChannel(timeoutSeconds: timeoutSeconds) { $0.eventLoop.makeSucceededVoidFuture() }
            try? await child.close().get()
            return true
        } catch {
            return !closed && channel.isActive
        }
    }

    /// Opens a new session child channel and adds the given handlers to it (used by the file-transfer
    /// module to start the SFTP subsystem). Returns the child channel once its initializer has run.
    public func openChildChannel(timeoutSeconds: Int64 = 30, _ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
        guard !closed else { throw SSHError.notConnected }
        let handler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        guard timeoutSeconds > 0, timeoutSeconds <= 3600 else { throw SSHError.invalidSettings("invalid channel timeout") }
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let parent = channel
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            promise.fail(SSHError.commandFailed("channel open timed out")); parent.close(promise: nil)
        }
        defer { timeout.cancel() }
        try await channel.eventLoop.submit {
            handler.createChannel(promise, channelType: .session) { child, _ in initializer(child) }
        }.get()
        return try await promise.futureResult.get()
    }

    /// Says goodbye to the server before closing, so it ends the login session at once; a server that does not take the
    /// message within two seconds is disconnected anyway. Then closes the jump host the same way.
    public func close() async throws {
        guard !closed else { return }
        closed = true
        if let handler = try? await channel.pipeline.handler(type: NIOSSHHandler.self).get() {
            let parent = channel
            let timeout = channel.eventLoop.scheduleTask(in: .seconds(2)) { parent.close(promise: nil) }
            let loop = channel.eventLoop
            _ = try? await loop.flatSubmit {
                do { return try handler.sendDisconnect(description: "Closed by Gloamux") } catch { return loop.makeFailedFuture(error) }
            }.get()
            timeout.cancel()
        }
        try? await channel.close().get()
        try? await jump?.close()
    }
}

// Feature entry. Live connection needs a reachable server, so the self-test only reports readiness.
// {"op":"settings","path":"<.xsh>"} or {"op":"settings","host":..,"port":..,"user":..} parses settings
// without connecting.
public enum SshFeature: GloamuxFeature {
    public static let id = "ssh"
    public static let contractSha256 = "f4f5b310b7a353be72677b4a3cc4c4cb2bfc8aa5241441bfdc4e391f1571ad9e"
    public static let dependsOn: [String] = ["network", "profiles", "master-password"]

    public static func run(_ request: FeatureRequest, dependencies: FeatureOutputs) throws -> FeatureResponse {
        if request.payload.isEmpty {
            return FeatureResponse(payload: #"{"ready":true,"library":"SwiftNIO SSH (NIOSSH)","auth":["password","publicKey"],"proxy":["none","socks5"],"note":"live connect not exercised in self-test"}"#)
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any], let op = obj["op"] as? String, op == "settings" else {
            throw FeatureError.failed(id, "expected JSON {op:\"settings\", ...}")
        }
        let settings: SSHConnectionSettings
        do {
            if let path = obj["path"] as? String {
                settings = try SSHConnectionSettings(profile: try SessionProfile(contentsOf: URL(fileURLWithPath: path)))
            } else {
                guard let host = obj["host"] as? String else { throw SSHError.invalidSettings("missing host") }
                settings = SSHConnectionSettings(host: host, port: (obj["port"] as? Int) ?? 22, username: (obj["user"] as? String) ?? "")
            }
        } catch let e as SSHError { throw FeatureError.failed(id, "\(e)") }
        let out: [String: Any] = ["host": settings.host, "port": settings.port, "user": settings.username]
        return FeatureResponse(payload: String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
    }
}
