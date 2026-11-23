import Darwin
import Foundation

/// A private local channel for workspace commands. The lock serializes offline catalog edits with the
/// running app, and requests to the app use the same in-memory stores as its windows.
@MainActor public final class WorkspaceCommandChannel {
    private struct Request: Codable {
        let expires: Date
        let arguments: [String]
    }

    public struct Reply: Codable {
        public let code: Int32
        public let text: String
    }

    /// How long a client waits for Gloamux to pick a request up. A request still waiting then is withdrawn, so it
    /// never runs. Gloamux refuses a request picked up after this.
    nonisolated(unsafe) static var pickupTimeout: TimeInterval = 20
    /// How long a client then waits for the answer. Commands that wait for Touch ID or a host search take longer
    /// than a query, and other requests are served meanwhile.
    nonisolated(unsafe) static var answerTimeout: TimeInterval = 300

    public let workspace: URL
    private let directory: URL
    /// Requests being answered, each in its own task, so a slow one does not hold up the rest.
    private var running: [UUID: Task<Void, Never>] = [:]
    private let descriptor: Int32
    private var watcher: DispatchSourceFileSystemObject?
    private var serving: Task<Void, Never>?
    private var requestsPending = false
    private var ownsWorkspace = false

    public init(workspace: URL) throws {
        self.workspace = workspace.standardizedFileURL
        directory = self.workspace.appendingPathComponent(".cli", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else {
            throw WorkspaceError.invalid("The CLI channel must be in a private directory owned by your account.")
        }
        let fd = Darwin.open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else {
            Darwin.close(fd)
            throw WorkspaceError.invalid("Invalid workspace CLI lock.")
        }
        descriptor = fd
    }

    deinit {
        watcher?.cancel()
        serving?.cancel()
        Darwin.close(descriptor)
    }

    public func claim() throws -> Bool {
        if ownsWorkspace { return true }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            ownsWorkspace = true
            return true
        }
        if errno == EWOULDBLOCK { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Gives the lock back, so a long-running client such as `gloamux mcp` does not keep Gloamux from serving.
    public func release() {
        guard ownsWorkspace, watcher == nil else { return }
        flock(descriptor, LOCK_UN)
        ownsWorkspace = false
    }

    /// `activeWorkspace` is the key window's workspace; `windows` lists every open workspace window.
    public func serve(activeWorkspace: @escaping @MainActor () -> WorkspaceModel?,
                      windows: @escaping @MainActor () -> [WorkspaceModel] = { [] }) throws {
        guard ownsWorkspace, watcher == nil else { return }
        let fd = Darwin.open(directory.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setCancelHandler { Darwin.close(fd) }
        let wake: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRequests(activeWorkspace, windows) }
        }
        // Scan once after registration to pick up requests written before the watch was installed.
        source.setRegistrationHandler(handler: wake)
        source.setEventHandler(handler: wake)
        watcher = source
        source.resume()
    }

    private func scheduleRequests(_ activeWorkspace: @escaping @MainActor () -> WorkspaceModel?,
                                  _ windows: @escaping @MainActor () -> [WorkspaceModel]) {
        guard watcher != nil else { return }
        requestsPending = true
        guard serving == nil else { return }
        serving = Task { [weak self] in
            await self?.drainRequests(activeWorkspace, windows)
        }
    }

    private func drainRequests(_ activeWorkspace: @MainActor () -> WorkspaceModel?, _ windows: @MainActor () -> [WorkspaceModel]) async {
        defer { serving = nil }
        while requestsPending, !Task.isCancelled {
            requestsPending = false
            if let model = activeWorkspace() { await processRequests(model, windows()) }
        }
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        requestsPending = false
        serving?.cancel()
        running.values.forEach { $0.cancel() }
        running = [:]
    }

    static let notPickedUp = "Gloamux did not pick up the command in time, so it did not run. Try again."
    static let stillRunning = "Gloamux is still running the command. Check whether it took effect before retrying."
    static let exitedWhileRunning = "Gloamux exited while handling the command. Check whether it took effect before retrying."

    /// Returns nil with the lock held if another CLI process owned the lock and finished
    /// without consuming the request. A request consumed by the app is never retried.
    ///
    /// A request is in one of three states, and each ending says which: still waiting (withdrawn by the client, so it
    /// never runs), picked up by Gloamux (it writes `ID.accepted`), or answered (`ID.reply`).
    public func send(_ arguments: [String]) async throws -> Reply? {
        let id = UUID().uuidString
        let pickup = Date().addingTimeInterval(Self.pickupTimeout)
        let request = directory.appendingPathComponent(id + ".request")
        let response = directory.appendingPathComponent(id + ".reply")
        let accepted = directory.appendingPathComponent(id + ".accepted")
        let data = try JSONEncoder().encode(Request(expires: pickup, arguments: arguments))
        guard data.count <= 65536 else { throw WorkspaceCommand.Usage("CLI request is too large.") }
        defer {
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: response)
            try? FileManager.default.removeItem(at: accepted)
        }
        try writePrivate(data, to: request)
        var answerBy: Date?
        // Most replies take a few milliseconds: look again soon, then less often.
        var wait = 2
        while true {
            if let data = try? Data(contentsOf: response) { return try JSONDecoder().decode(Reply.self, from: data) }
            if try claim() {
                if (try? FileManager.default.removeItem(at: request)) != nil { return nil }
                if let data = try? Data(contentsOf: response) { return try JSONDecoder().decode(Reply.self, from: data) }
                throw WorkspaceError.invalid(Self.exitedWhileRunning)
            }
            if answerBy == nil, FileManager.default.fileExists(atPath: accepted.path) {
                answerBy = Date().addingTimeInterval(Self.answerTimeout)
            }
            if answerBy == nil, Date() >= pickup {
                // Withdrawing the request proves it never ran. If it is already gone, Gloamux took it just now.
                if (try? FileManager.default.removeItem(at: request)) != nil { throw WorkspaceError.invalid(Self.notPickedUp) }
                answerBy = Date().addingTimeInterval(Self.answerTimeout)
            }
            if let answerBy, Date() >= answerBy { throw WorkspaceError.invalid(Self.stillRunning) }
            try await Task.sleep(for: .milliseconds(wait))
            wait = min(wait * 2, 100)
        }
    }

    private func processRequests(_ model: WorkspaceModel, _ windows: [WorkspaceModel]) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where ["reply", "accepted"].contains(file.pathExtension) {
            let age: TimeInterval = file.pathExtension == "reply" ? 60 : Self.answerTimeout + 60
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > age { try? FileManager.default.removeItem(at: file) }
        }
        for file in files where file.pathExtension == "request" {
            guard !Task.isCancelled, let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  running[id] == nil else { continue }
            let request = try? readRequest(file)
            // Taking the file is what picks the request up: the client can no longer withdraw it.
            guard (try? FileManager.default.removeItem(at: file)) != nil else { continue }
            guard let request, Date() < request.expires, request.expires.timeIntervalSinceNow <= Self.pickupTimeout else {
                // Taken too late (or unreadable): say it did not run, so the client is not left waiting.
                let refused = Reply(code: 1, text: request == nil ? "Invalid CLI request." : Self.notPickedUp)
                if let data = try? JSONEncoder().encode(refused) { try? writePrivate(data, to: directory.appendingPathComponent(id.uuidString + ".reply")) }
                continue
            }
            try? writePrivate(Data(), to: directory.appendingPathComponent(id.uuidString + ".accepted"))
            // Each request runs in its own task on the main actor: a command waiting for Touch ID or a search does
            // not hold up the others, and every change to shared data is still made on the main actor, in order.
            running[id] = Task { [weak self] in
                let reply = await Self.answer(request.arguments, model, windows)
                guard let self else { return }
                let response = self.directory.appendingPathComponent(id.uuidString + ".reply")
                if let data = try? JSONEncoder().encode(reply) { try? writePrivate(data, to: response) }
                self.running[id] = nil
            }
        }
    }

    private static func answer(_ arguments: [String], _ model: WorkspaceModel, _ windows: [WorkspaceModel]) async -> Reply {
        do {
            guard !model.workspaceLocked else { throw WorkspaceError.invalid("Unlock this workspace in Gloamux first.") }
            let data = try await WorkspaceCommand.run(arguments, model: model, live: true, windows: windows)
            return Reply(code: 0, text: String(decoding: data, as: UTF8.self))
        } catch let error as WorkspaceCommand.Usage {
            return Reply(code: 2, text: error.localizedDescription)
        } catch {
            return Reply(code: 1, text: error.localizedDescription)
        }
    }

    private func readRequest(_ file: URL) throws -> Request {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceError.invalid("Invalid CLI request.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(),
              let data = try handle.read(upToCount: 65537), data.count <= 65536 else {
            throw WorkspaceError.invalid("Invalid CLI request.")
        }
        return try JSONDecoder().decode(Request.self, from: data)
    }
}
