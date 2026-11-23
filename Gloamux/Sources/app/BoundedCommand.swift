import Foundation

/// Runs a program and collects its output with limits: the output stops at `outputLimit` bytes (an error, never a
/// cut-off result), error text is kept up to `errorLimit` bytes, and the program is stopped at the deadline or when the
/// calling task is cancelled. The program runs in a process group of its own, so stopping it also stops anything it
/// started, including a background child that still holds the output pipes. The result is delivered exactly once.
enum BoundedCommand {
    struct Output: Sendable {
        let status: Int32
        let output: Data
        let errors: Data
    }

    enum Failure: LocalizedError, Equatable {
        case timedOut
        case outputTooLarge(Int)
        case launch(Int32)

        var errorDescription: String? {
            switch self {
            case .timedOut: return "The command took too long and was stopped."
            case .outputTooLarge(let limit): return "The command printed more than \(limit / (1024 * 1024)) MB and was stopped."
            case .launch(let code): return "The command could not start (\(String(cString: strerror(code))))."
            }
        }
    }

    /// How long a program that has exited may keep its pipes open through a background child before the group is
    /// stopped and the output read so far is used.
    static var lingering: TimeInterval = 1

    static func run(_ executable: String, _ arguments: [String], directory: String? = nil, timeout: TimeInterval,
                    outputLimit: Int, errorLimit: Int = 64 * 1024) async throws -> Output {
        let job = Job(outputLimit: outputLimit, errorLimit: errorLimit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(executable, arguments, directory: directory, timeout: timeout, continuation)
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// One running program. Every field is used only on `queue`.
private final class Job: @unchecked Sendable {
    private let queue = DispatchQueue(label: "gloamux.bounded-command")
    private let outputLimit: Int, errorLimit: Int
    private var continuation: CheckedContinuation<BoundedCommand.Output, Error>?
    private var cancelledBeforeStart = false
    private var finished = false
    private var pid: pid_t = 0
    private var reaped = false
    private var status: Int32 = 0
    private var output = Data(), errors = Data()
    private var readers: [DispatchSourceRead] = []
    private var openPipes = 0
    private var exitWatch: DispatchSourceProcess?

    init(outputLimit: Int, errorLimit: Int) { self.outputLimit = outputLimit; self.errorLimit = errorLimit }

    func start(_ executable: String, _ arguments: [String], directory: String?, timeout: TimeInterval,
               _ continuation: CheckedContinuation<BoundedCommand.Output, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if cancelledBeforeStart { return finish(.failure(CancellationError())) }
            var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
            guard pipe(&outPipe) == 0 else { return finish(.failure(BoundedCommand.Failure.launch(errno))) }
            guard pipe(&errPipe) == 0 else {
                close(outPipe[0]); close(outPipe[1])
                return finish(.failure(BoundedCommand.Failure.launch(errno)))
            }
            let spawned = Self.spawn(executable, arguments, directory: directory, stdout: outPipe[1], stderr: errPipe[1])
            close(outPipe[1]); close(errPipe[1])
            guard case .success(let child) = spawned else {
                close(outPipe[0]); close(errPipe[0])
                if case .failure(let error) = spawned { finish(.failure(error)) }
                return
            }
            pid = child
            watchExit()
            read(outPipe[0], isOutput: true)
            read(errPipe[0], isOutput: false)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in stop(BoundedCommand.Failure.timedOut) }
        }
    }

    func cancel() {
        queue.async { [self] in
            if continuation == nil { cancelledBeforeStart = true } else { stop(CancellationError()) }
        }
    }

    // MARK: Launch

    private static func spawn(_ executable: String, _ arguments: [String], directory: String?, stdout: Int32, stderr: Int32)
        -> Result<pid_t, Error> {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        // A group of its own, so the whole group can be stopped; only the three descriptors above are inherited; and
        // the signal handling the program starts with is the default, not this app's.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none); sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let code = posix_spawn(&child, executable, &actions, &attributes, argv, environ)
        return code == 0 ? .success(child) : .failure(BoundedCommand.Failure.launch(code))
    }

    // MARK: Watching

    private func watchExit() {
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        watch.setEventHandler { [self] in reap() }
        exitWatch = watch
        watch.resume()
        // The program may have exited before the watch began.
        reap()
    }

    private func reap() {
        guard !reaped else { return }
        var raw: Int32 = 0
        guard waitpid(pid, &raw, WNOHANG) == pid else { return }
        reaped = true
        exitWatch?.cancel(); exitWatch = nil
        // WIFEXITED / WEXITSTATUS, and 128 + the signal number for a program a signal ended.
        status = raw & 0x7F == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
        if finished { return }
        if openPipes == 0 { return finish(.success(BoundedCommand.Output(status: status, output: output, errors: errors))) }
        // Something the program started in the background still holds the pipes.
        queue.asyncAfter(deadline: .now() + BoundedCommand.lingering) { [self] in
            guard !finished else { return }
            kill(-pid, SIGKILL)
            finish(.success(BoundedCommand.Output(status: status, output: output, errors: errors)))
        }
    }

    private func read(_ descriptor: Int32, isOutput: Bool) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        openPipes += 1
        var ended = false
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !ended {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    if isOutput {
                        guard output.count + count <= outputLimit else { return stop(BoundedCommand.Failure.outputTooLarge(outputLimit)) }
                        output.append(contentsOf: buffer[0..<count])
                    } else if errors.count < errorLimit {
                        errors.append(contentsOf: buffer[0..<min(count, errorLimit - errors.count)])
                    }
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    ended = true
                    source.cancel()
                    openPipes -= 1
                    if openPipes == 0, reaped, !finished {
                        finish(.success(BoundedCommand.Output(status: status, output: output, errors: errors)))
                    }
                } else if errno == EAGAIN {
                    return
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        readers.append(source)
        source.resume()
    }

    // MARK: Ending

    /// Ends the run with `error` and stops the program's whole group: politely, then for certain.
    private func stop(_ error: Error) {
        guard !finished else { return }
        if pid > 0, !reaped {
            kill(-pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + 2) { [self] in if !reaped { kill(-pid, SIGKILL) } }
        } else if pid > 0 {
            kill(-pid, SIGKILL)
        }
        finish(.failure(error))
    }

    private func finish(_ result: Result<BoundedCommand.Output, Error>) {
        guard !finished else { return }
        finished = true
        readers.forEach { $0.cancel() }
        readers = []
        continuation?.resume(with: result)
        continuation = nil
    }
}
