import App
import Darwin
import Foundation
import Ssh

/// `gloamux ssh`: a saved SSH session's shell in the terminal the command runs in, signed in like `gloamux files`.
enum SSHCommand {
    static let usage = """
    Usage: gloamux ssh SESSION [options]
           gloamux ssh --session <name-or-id> [options]

    Opens the saved session's shell in this terminal. It uses the saved profile's authentication, proxy, jump hosts,
    and trusted host keys, and saves nothing. The command exits with the remote shell's exit status.

    Options:
      --workspace PATH             Use a separate Gloamux workspace
      --password-stdin             Read the password or key passphrase as one line
      --vault-password-stdin       Unlock the vault for this command (first line if both are set)
      --host-key FINGERPRINT       Permit a verified new SSH host key for this run (repeatable)
      --interactive                Answer SSH keyboard-interactive prompts on the terminal
    """

    @MainActor static func run(_ arguments: [String]) async throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] { print(usage); return 0 }
        let args = try CLIArguments(arguments, values: ["--session", "--workspace", "--host-key"],
                                    switches: ["--password-stdin", "--vault-password-stdin", "--interactive"], repeated: ["--host-key"])
        let selector: String
        switch (args.option("--session"), args.operands.count) {
        case (let named?, 0): selector = named
        case (nil, 1): selector = args.operands[0]
        default: throw CLIUsageError(usage)
        }
        let hostKeys = try FilesCommand.verifiedHostKeys(args)
        let model = try WorkspaceModel(storage: args.workspace)
        let item = try WorkspaceCommand.item(selector, in: model.sessionTree)
        if args.has("--vault-password-stdin") { try await model.vault.unlock(password: try FilesCommand.stdinSecret()) }
        let secret = args.has("--password-stdin") ? try FilesCommand.stdinSecret() : nil
        let answer: SSHLoginAnswerer? = args.has("--interactive") ? { @Sendable challenge in try FilesCommand.terminalAnswers(challenge) } : nil
        let size = windowSize()
        return try await model.withTerminalConnection(
            item, secret: secret, access: FileCommandAccess(hostKeys: hostKeys, answer: answer),
            rows: size.rows, columns: size.columns, term: ProcessInfo.processInfo.environment["TERM"]
        ) { shell in try await session(shell) }
    }

    @MainActor private static func session(_ shell: SSHInteractiveShell) async throws -> Int32 {
        let terminal = RawTerminal()
        defer { terminal.restore() }
        var sources: [DispatchSourceSignal] = []
        defer { for source in sources { source.cancel() } }
        signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        resize.setEventHandler {
            let size = windowSize()
            Task { try? await shell.resize(rows: size.rows, columns: size.columns) }
        }
        sources.append(resize)
        // Leave the terminal usable if the command is stopped from outside.
        for number in [SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { terminal.restore(); exit(128 + number) }
            sources.append(source)
        }
        for source in sources { source.resume() }

        let input = standardInput()
        let sending = Task.detached {
            for await chunk in input { try? await shell.send(chunk) }
        }
        defer { sending.cancel() }
        for try await bytes in shell.output { writeAll(bytes) }
        return Int32(clamping: shell.exitStatus ?? 255)
    }

    /// Reads standard input on its own thread, so a blocking read never holds up the shell's output.
    private static func standardInput() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let thread = Thread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(STDIN_FILENO, &buffer, buffer.count)
                    if count > 0 { continuation.yield(Array(buffer[0..<count])) }
                    else if count < 0, errno == EINTR { continue }
                    else { break }
                }
                continuation.finish()
            }
            thread.start()
        }
    }

    private static func writeAll(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written }
                else if written < 0, errno == EINTR { continue }
                else { return }
            }
        }
    }

    private static func windowSize() -> (rows: Int, columns: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 else { return (24, 80) }
        return (Int(size.ws_row), Int(size.ws_col))
    }
}

/// Puts an interactive terminal in raw mode, so keys such as Ctrl-C reach the remote shell, and restores it after.
private final class RawTerminal: @unchecked Sendable {
    private var saved = termios()
    private var active = false

    init() {
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &saved) == 0 else { return }
        var raw = saved
        cfmakeraw(&raw)
        active = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0
    }

    func restore() {
        guard active else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        active = false
    }
}
