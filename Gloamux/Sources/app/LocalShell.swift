import Foundation
import LocalPTY
import Darwin

/// What a local tab runs: the user's login shell, or a command such as `docker exec` started through it so it finds
/// the same tools as Terminal does.
struct LocalLaunch: Equatable {
    var executable: String
    /// argv, including argv[0].
    var arguments: [String]
    var directory: String
    var environment: [String: String] = [:]

    static var userShell: String {
        let candidate = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/zsh"
    }

    /// The login shell in `directory` (the home folder by default). With integration on, zsh loads Gloamux's prompt
    /// marks after the user's own startup files.
    static func loginShell(directory: String? = nil, integration: Bool) -> LocalLaunch {
        let shell = userShell
        var launch = LocalLaunch(executable: shell, arguments: [shell, "-l", "-i"], directory: validDirectory(directory))
        if integration, (shell as NSString).lastPathComponent == "zsh", let folder = ShellIntegration.zshDirectory() {
            if let current = ProcessInfo.processInfo.environment["ZDOTDIR"] { launch.environment["GLOAMUX_USER_ZDOTDIR"] = current }
            launch.environment["ZDOTDIR"] = folder.path
        }
        return launch
    }

    /// Runs `command` (already quoted for a POSIX shell) with `exec` through the login shell.
    static func command(_ command: String, directory: String? = nil) -> LocalLaunch {
        let shell = userShell
        return LocalLaunch(executable: shell, arguments: [shell, "-l", "-c", "exec " + command], directory: validDirectory(directory))
    }

    /// `LANG` for a local shell, as Terminal sets it. An app opened from Finder has no locale variables, so the shell
    /// ran in the C locale: `ls` printed non-ASCII names as `?`, and zsh garbled them in prompts and typed input. Only
    /// themes that set a UTF-8 locale themselves, such as Powerlevel10k, hid it. Empty when `environment` already
    /// names a locale. The language and region come from `locale`, falling back to `en_US.UTF-8` when this Mac has
    /// no such locale.
    static func localeEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                  locale: Locale = .current) -> [String: String] {
        if ["LC_ALL", "LC_CTYPE", "LANG"].contains(where: { !(environment[$0] ?? "").isEmpty }) { return [:] }
        var candidates: [String] = []
        if let language = locale.language.languageCode?.identifier {
            if let region = locale.region?.identifier { candidates.append("\(language)_\(region).UTF-8") }
            if let region = locale.language.region?.identifier { candidates.append("\(language)_\(region).UTF-8") }
        }
        let name = candidates.first(where: isAvailable) ?? "en_US.UTF-8"
        return ["LANG": name]
    }

    /// The locale variables an SSH shell gets, as `ssh` sends them from a Mac terminal (`SendEnv LANG LC_*`): this Mac's
    /// `LANG` and `LC_` variables, or the `LANG` a local shell gets when there are none. The server may refuse them.
    static func sshEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                               locale: Locale = .current) -> [String: String] {
        let own = environment.filter { ($0.key == "LANG" || $0.key.hasPrefix("LC_")) && !$0.value.isEmpty }
        return own.isEmpty ? localeEnvironment(environment, locale: locale) : own
    }

    private static func isAvailable(_ name: String) -> Bool {
        guard let handle = newlocale(LC_CTYPE_MASK | LC_MESSAGES_MASK, name, nil) else { return false }
        freelocale(handle)
        return true
    }

    private static func validDirectory(_ directory: String?) -> String {
        var isFolder: ObjCBool = false
        if let directory, FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder), isFolder.boolValue { return directory }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}

/// Carries a terminal's output from its reader thread to the screen, in order and a batch at a time: whatever
/// arrives while the main thread is busy is drawn together. Past `limit` bytes waiting, the transport stops reading
/// until the screen has taken them, so a program that prints without pause cannot pile up output in memory.
final class TerminalOutputPump: @unchecked Sendable {
    static let limit = 1 << 20
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var ended = false, scheduled = false, paused = false
    private weak var transport: (any TerminalTransport)?
    private let deliver: @MainActor ([UInt8], _ ended: Bool) -> Void

    init(deliver: @escaping @MainActor ([UInt8], _ ended: Bool) -> Void) { self.deliver = deliver }

    /// The transport to pause; set once it exists.
    func attach(_ transport: any TerminalTransport) { lock.withLock { self.transport = transport } }

    /// From the reader: output, or no bytes once the output has ended.
    func push(_ bytes: [UInt8]) {
        let (schedule, pause): (Bool, (any TerminalTransport)?) = lock.withLock {
            if bytes.isEmpty { ended = true } else { buffer.append(contentsOf: bytes) }
            var pause: (any TerminalTransport)?
            if !paused, !ended, buffer.count >= Self.limit, let transport { paused = true; pause = transport }
            defer { scheduled = true }
            return (!scheduled, pause)
        }
        pause?.setOutputPaused(true)
        if schedule { Task { @MainActor in self.drain() } }
    }

    @MainActor private func drain() {
        let (bytes, ended, resume): ([UInt8], Bool, (any TerminalTransport)?) = lock.withLock {
            let taken = buffer
            buffer = []
            scheduled = false
            var resume: (any TerminalTransport)?
            if paused { paused = false; resume = transport }
            return (taken, self.ended, resume)
        }
        resume?.setOutputPaused(false)
        deliver(bytes, ended)
    }
}

/// A real controlling PTY gives local shells job control, signals and terminal sizing.
final class LocalShell {
    private let handle: FileHandle
    private let pid: Int32
    private let writes = DispatchQueue(label: "Gloamux.local-input")
    private var stopped = false
    private let reader: DispatchSourceRead
    /// A suspended source must be resumed before it is cancelled or released.
    private let pause = NSLock()
    private var paused = false, ended = false
    let launch: LocalLaunch

    init(rows: Int, columns: Int, launch: LocalLaunch = .loginShell(integration: false), output: @escaping @Sendable (Data) -> Void) throws {
        self.launch = launch
        var descriptor: Int32 = -1
        // C strings for the child: kept alive until the fork has copied them.
        let arguments = launch.arguments.map { strdup($0) } + [nil]
        let variables = launch.environment.merging(LocalLaunch.localeEnvironment()) { own, _ in own }
        let environment = variables.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        pid = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { env in
                gloamux_spawn_command(launch.executable, argv.baseAddress, launch.directory, env.baseAddress,
                                     Int32(rows), Int32(columns), &descriptor)
            }
        }
        guard pid > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "Gloamux.local-output"))
        reader.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { output(Data(buffer.prefix(count))) }
            else if count == 0 || errno != EINTR { self.reader.cancel(); output(Data()) }
        }
        let file = handle, queue = writes
        reader.setCancelHandler { queue.async { try? file.close() } }
        reader.resume()
    }
    func send(_ bytes: [UInt8]) {
        let handle = handle
        writes.async { try? handle.write(contentsOf: Data(bytes)) }
    }
    func resize(rows: Int, columns: Int) { gloamux_resize(handle.fileDescriptor, Int32(rows), Int32(columns)) }
    /// While paused, the shell's writes wait once the PTY buffer is full, so a fast program runs at the screen's pace.
    func setOutputPaused(_ paused: Bool) {
        pause.withLock {
            guard !ended, paused != self.paused else { return }
            self.paused = paused
            if paused { reader.suspend() } else { reader.resume() }
        }
    }
    func close() {
        guard !stopped else { return }; stopped = true
        reader.cancel()
        pause.withLock {
            ended = true
            if paused { paused = false; reader.resume() }
        }
        gloamux_stop(pid)
    }
    deinit { close() }
}
