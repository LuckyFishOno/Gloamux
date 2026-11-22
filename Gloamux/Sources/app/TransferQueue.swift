import Foundation
import FileTransfer

/// What to do when a file already exists where a transfer would write it.
enum TransferConflictPolicy: Sendable {
    case replace, skip
}

enum TransferDirection: Sendable {
    case upload, download
}

/// One queued upload or download: a file, or a folder copied with everything inside it.
@MainActor final class TransferItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting, running, done, skipped, cancelled
        /// The connection broke; the next attempt starts in this many seconds.
        case retrying(Int)
        case failed(String)
        var isFinished: Bool {
            switch self {
            case .waiting, .running, .retrying: return false
            default: return true
            }
        }
    }

    /// A file copied under a temporary name that an interrupted attempt left, so the next attempt can continue it.
    struct Partial: Equatable {
        /// The temporary copy: a Mac path for a download, a remote path for an upload.
        let path: String
        /// The source's size and modification time when the copy began. A retry continues only an unchanged source.
        let size: UInt64?
        let modified: Date?
    }

    let id = UUID()
    let direction: TransferDirection
    let name: String
    /// Local file path for an upload, remote path for a download.
    let source: String
    /// Folder the item is copied into: remote for an upload, local for a download.
    let destinationFolder: String
    let isFolder: Bool
    let host: String
    let policy: TransferConflictPolicy
    weak var tab: SessionTab?
    @Published var state: State = .waiting
    @Published var bytes: UInt64 = 0
    @Published var total: UInt64?
    @Published var filesDone = 0
    @Published var fileCount = 0
    /// The size known when it was queued, such as a listed file's size, until the transfer measures `total` itself.
    let expectedSize: UInt64?
    /// Partial copies by destination path, kept after a failure so a retry continues them.
    var partials: [String: Partial] = [:]
    /// Destinations an earlier attempt finished; a retried folder skips them.
    var completed: Set<String> = []
    /// Attempts made so far, counting retries after a broken connection.
    var attempts = 0
    /// The last attempt ended with a broken connection, so its partial copies are kept for "Try again".
    var interrupted = false
    /// Names the temporary copies of this item, so a retry finds them again.
    var tag: String { String(id.uuidString.prefix(8)).lowercased() }

    init(direction: TransferDirection, name: String, source: String, destinationFolder: String, isFolder: Bool,
         tab: SessionTab, policy: TransferConflictPolicy, expectedSize: UInt64? = nil) {
        self.direction = direction; self.name = name; self.source = source; self.destinationFolder = destinationFolder
        self.isFolder = isFolder; self.tab = tab; self.host = tab.host; self.policy = policy; self.expectedSize = expectedSize
    }

    /// When it began moving bytes and when it ended, for its speed and for how long it stays in the sidebar.
    var started: Date?
    @Published var finished: Date?

    /// Bytes this item will move, as far as is known yet.
    var size: UInt64? { total ?? expectedSize }

    var fraction: Double? {
        guard let total, total > 0 else { return state == .done ? 1 : nil }
        return min(1, Double(bytes) / Double(total))
    }
}

/// Runs uploads and downloads one after another, for every window and panel that starts them.
///
/// Files are written beside their destination under a temporary name and moved into place only when complete, so
/// a failed or cancelled transfer leaves an existing file as it was.
@MainActor final class TransferQueue: ObservableObject {
    @Published private(set) var items: [TransferItem] = []
    /// Bumped after each item ends, so file lists can refresh the folders it changed.
    @Published private(set) var revision = 0
    private weak var model: WorkspaceModel?
    private var runner: Task<Void, Never>?
    private var current: (id: UUID, task: Task<Void, Error>)?

    init(model: WorkspaceModel? = nil) { self.model = model }
    func attach(_ model: WorkspaceModel) { self.model = model }

    var isActive: Bool { items.contains { !$0.state.isFinished } }

    // MARK: Queueing

    func upload(_ urls: [URL], to remoteFolder: String, via tab: SessionTab, policy: TransferConflictPolicy) {
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            enqueue(TransferItem(direction: .upload, name: url.lastPathComponent, source: url.path, destinationFolder: remoteFolder,
                                 isFolder: isFolder, tab: tab, policy: policy, expectedSize: isFolder ? nil : Self.localSize(url.path)))
        }
        start()
    }

    /// `sizes` holds the listed size of files, keyed by remote path, so progress has a total before each one starts.
    func download(_ entries: [(path: String, isDirectory: Bool)], to localFolder: URL, via tab: SessionTab, policy: TransferConflictPolicy,
                  sizes: [String: UInt64] = [:]) {
        for entry in entries {
            enqueue(TransferItem(direction: .download, name: (entry.path as NSString).lastPathComponent, source: entry.path,
                                 destinationFolder: localFolder.path, isFolder: entry.isDirectory, tab: tab, policy: policy,
                                 expectedSize: entry.isDirectory ? nil : sizes[entry.path]))
        }
        start()
    }

    private func enqueue(_ item: TransferItem) {
        items.append(item)
    }

    /// Names among `names` that already exist in the remote folder, so the caller can ask before queueing.
    func remoteConflicts(_ names: [String], in folder: String, via tab: SessionTab) async -> [String] {
        guard let model, let transfer = try? await model.sftp(for: tab),
              let existing = try? await transfer.listDirectory(folder) else { return [] }
        let taken = Set(existing.map(\.name))
        return names.filter { taken.contains($0) }
    }

    nonisolated static func localConflicts(_ names: [String], in folder: URL) -> [String] {
        names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    func cancel(_ item: TransferItem) {
        if current?.id == item.id { current?.task.cancel() }
        else if item.state == .waiting { item.state = .cancelled; item.finished = Date() }
    }

    func cancelAll() {
        for item in items where item.state == .waiting { item.state = .cancelled; item.finished = Date() }
        current?.task.cancel()
    }

    /// Puts a failed item back in the queue. Files it finished are not copied again, and partial copies continue
    /// where the server allows it.
    func retry(_ item: TransferItem) {
        guard case .failed = item.state else { return }
        item.state = .waiting; item.finished = nil
        start()
    }

    /// Tells file lists that something on a server changed outside the queue, such as an uploaded edit.
    func noteChange() { revision += 1 }

    func clearFinished() {
        for item in items where item.state.isFinished { discardPartials(item) }
        items.removeAll { $0.state.isFinished }
    }

    /// Removes the temporary copies an item left, on this Mac and, when the session is still connected, on the server.
    private func discardPartials(_ item: TransferItem) {
        let partials = Array(item.partials.values)
        item.partials = [:]
        guard !partials.isEmpty else { return }
        if item.direction == .download {
            for partial in partials { try? FileManager.default.removeItem(atPath: partial.path) }
            return
        }
        guard let model, let tab = item.tab else { return }
        Task {
            guard let transfer = try? await model.sftp(for: tab) else { return }
            for partial in partials { try? await transfer.removeFile(partial.path) }
        }
    }

    // MARK: Running

    private func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let item = self.items.first(where: { $0.state == .waiting }) {
                await self.run(item)
            }
            self?.runner = nil
        }
    }

    private func run(_ item: TransferItem) async {
        item.started = Date()
        item.state = .running
        let task = Task { try await self.attempt(item) }
        current = (item.id, task)
        do {
            try await task.value
            if item.state == .running { item.state = .done }
        } catch is CancellationError {
            item.state = .cancelled
            discardPartials(item)
        } catch {
            item.state = .failed(message(for: error))
            // A refused copy has nothing worth continuing; an interrupted one keeps its bytes for "Try again".
            if !item.interrupted { discardPartials(item) }
        }
        current = nil
        item.finished = Date()
        revision += 1
    }

    /// Seconds to wait before each new attempt after the connection breaks.
    static var retryDelays: [UInt64] = [2, 5, 10]

    /// Runs the item, trying again after a broken connection. A copy the server refused is not tried again.
    private func attempt(_ item: TransferItem) async throws {
        var tries = 0
        while true {
            item.attempts += 1
            do { try await perform(item); return } catch {
                item.interrupted = retries(after: error, item)
                guard tries < Self.retryDelays.count, item.interrupted else { throw error }
                let delay = Self.retryDelays[tries]
                tries += 1
                item.state = .retrying(Int(delay))
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                item.state = .running
            }
        }
    }

    /// Whether `error` came from a broken connection rather than from the server or this Mac refusing the copy. A
    /// session the user disconnected is not waited for; one that lost its connection may reconnect in time.
    private func retries(after error: Error, _ item: TransferItem) -> Bool {
        guard let tab = item.tab else { return false }
        if !tab.connected { return tab.transportLost }
        switch error {
        case is CancellationError, TransferError.localFileError, is WorkspaceError: return false
        case let FTPError.reply(code, _) where (400..<500).contains(code): return true
        default:
            // A refusal leaves the connection working; a dropped connection does not.
            return tab.transfer?.isOpen == false
        }
    }

    private func perform(_ item: TransferItem) async throws {
        guard let model, let tab = item.tab else { throw WorkspaceError.disconnected }
        let transfer = try await model.sftp(for: tab)
        switch (item.direction, item.isFolder) {
        case (.upload, false):
            item.fileCount = 1
            item.total = Self.localSize(item.source)
            let skipped = try await uploadFile(URL(fileURLWithPath: item.source), into: item.destinationFolder, transfer, item, base: 0)
            if skipped { item.state = .skipped }
            item.filesDone = 1
        case (.upload, true):
            try await uploadFolder(URL(fileURLWithPath: item.source), into: item.destinationFolder, transfer, item)
        case (.download, false):
            item.fileCount = 1
            let entry = try await transfer.entry(at: item.source)
            item.total = entry?.size
            let skipped = try await downloadFile(item.source, entry: entry, into: URL(fileURLWithPath: item.destinationFolder), transfer, item, base: 0)
            if skipped { item.state = .skipped }
            item.filesDone = 1
        case (.download, true):
            try await downloadFolder(item.source, into: URL(fileURLWithPath: item.destinationFolder), transfer, item)
        }
    }

    nonisolated private static func localSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }

    private static func remoteChild(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : (folder as NSString).appendingPathComponent(name)
    }

    /// Uploads one file into `folder`. Returns true when it was skipped because the name was taken.
    private func uploadFile(_ url: URL, into folder: String, _ transfer: any RemoteFileSystem, _ item: TransferItem, base: UInt64) async throws -> Bool {
        let destination = Self.remoteChild(folder, url.lastPathComponent)
        if item.completed.contains(destination) { return false }
        let existing = try await transfer.entry(at: destination)
        if existing != nil, item.policy == .skip { return true }
        if existing?.isDirectory == true { throw WorkspaceError.invalid("A folder named \(url.lastPathComponent) is already there.") }
        let partial = Self.remoteChild(folder, ".\(url.lastPathComponent).gloamux-\(item.tag).partial")
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let source = TransferItem.Partial(path: partial, size: values?.fileSize.map { UInt64($0) }, modified: values?.contentModificationDate)
        var offset: UInt64 = 0
        // An earlier attempt of this item left part of the file; continue it when the Mac file is unchanged.
        if item.partials[destination] == source, await transfer.canResume(), let size = source.size,
           let sent = try? await transfer.entry(at: partial)?.size, sent <= size {
            offset = sent
        }
        item.partials[destination] = source
        do {
            try await transfer.resumeUpload(localURL: url, to: partial, offset: offset) { progress in
                Task { @MainActor in item.bytes = base + progress.bytesTransferred }
            }
            if existing != nil { try await transfer.removeFile(destination) }
            try await transfer.rename(from: partial, to: destination)
            item.partials[destination] = nil
            item.completed.insert(destination)
        } catch is CancellationError {
            item.partials[destination] = nil
            try? await transfer.removeFile(partial)
            throw CancellationError()
        }
        return false
    }

    private func uploadFolder(_ root: URL, into folder: String, _ transfer: any RemoteFileSystem, _ item: TransferItem) async throws {
        // Everything is listed first, so the progress bar knows the total before the first byte moves.
        let plan = try await Task.detached { try Self.localPlan(root) }.value
        item.fileCount = plan.files.count
        item.total = plan.files.reduce(0) { $0 + $1.size }
        let top = Self.remoteChild(folder, root.lastPathComponent)
        try await makeRemoteFolder(top, transfer)
        for relative in plan.folders { try await makeRemoteFolder(Self.remoteChild(top, relative), transfer) }
        var sent: UInt64 = 0
        item.filesDone = 0
        for file in plan.files {
            try Task.checkCancellation()
            let parent = (file.relative as NSString).deletingLastPathComponent
            _ = try await uploadFile(root.appendingPathComponent(file.relative), into: parent.isEmpty ? top : Self.remoteChild(top, parent),
                                     transfer, item, base: sent)
            sent += file.size; item.bytes = sent; item.filesDone += 1
        }
    }

    private func makeRemoteFolder(_ path: String, _ transfer: any RemoteFileSystem) async throws {
        if let existing = try await transfer.entry(at: path) {
            guard existing.isDirectory else { throw WorkspaceError.invalid("\((path as NSString).lastPathComponent) exists and is not a folder.") }
            return
        }
        try await transfer.makeDirectory(path)
    }

    nonisolated private static func localPlan(_ root: URL) throws -> (folders: [String], files: [(relative: String, size: UInt64)]) {
        var folders: [String] = [], files: [(String, UInt64)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw TransferError.localFileError("cannot read \(root.path)")
        }
        let base = root.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { folders.append(relative) }
            else { files.append((relative, UInt64(values.fileSize ?? 0))) }
        }
        return (folders, files)
    }

    /// Downloads one remote file into `folder`. Returns true when it was skipped because the name was taken.
    private func downloadFile(_ path: String, entry: RemoteEntry?, into folder: URL, _ transfer: any RemoteFileSystem, _ item: TransferItem,
                              base: UInt64) async throws -> Bool {
        let name = (path as NSString).lastPathComponent
        let destination = folder.appendingPathComponent(name)
        if item.completed.contains(destination.path) { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists, item.policy == .skip { return true }
        if exists, isDirectory.boolValue { throw WorkspaceError.invalid("A folder named \(destination.lastPathComponent) is already there.") }
        let partial = folder.appendingPathComponent(".\(name).gloamux-\(item.tag).partial")
        let source = TransferItem.Partial(path: partial.path, size: entry?.size, modified: entry?.modified)
        var offset: UInt64 = 0
        // An earlier attempt of this item left part of the file; continue it when the server's file is unchanged.
        if item.partials[destination.path] == source, source.size != nil || source.modified != nil, await transfer.canResume(),
           let received = Self.localSize(partial.path), received <= source.size ?? .max {
            offset = received
        } else {
            try? FileManager.default.removeItem(at: partial)
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw TransferError.localFileError("cannot write \(partial.path)")
            }
        }
        item.partials[destination.path] = source
        do {
            try await transfer.resumeDownload(remotePath: path, to: partial, offset: offset) { progress in
                Task { @MainActor in item.bytes = base + progress.bytesTransferred }
            }
            try Task.checkCancellation()
            if exists { _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial) }
            else { try FileManager.default.moveItem(at: partial, to: destination) }
            item.partials[destination.path] = nil
            item.completed.insert(destination.path)
        } catch is CancellationError {
            item.partials[destination.path] = nil
            try? FileManager.default.removeItem(at: partial)
            throw CancellationError()
        }
        return false
    }

    private func downloadFolder(_ path: String, into folder: URL, _ transfer: any RemoteFileSystem, _ item: TransferItem) async throws {
        var folders: [String] = [], files: [(path: String, entry: RemoteEntry)] = [], pending = [path]
        while let next = pending.popLast() {
            try Task.checkCancellation()
            for entry in try await transfer.listDirectory(next) {
                let child = Self.remoteChild(next, entry.name)
                if entry.isDirectory { folders.append(child); pending.append(child) }
                else { files.append((child, entry)) }
            }
        }
        item.fileCount = files.count
        item.total = files.reduce(0) { $0 + ($1.entry.size ?? 0) }
        item.filesDone = 0
        let parent = (path as NSString).deletingLastPathComponent
        func local(_ remote: String) -> URL {
            let relative = String(remote.dropFirst(parent == "/" ? 1 : parent.count + 1))
            return folder.appendingPathComponent(relative, isDirectory: true)
        }
        for target in [path] + folders {
            try FileManager.default.createDirectory(at: local(target), withIntermediateDirectories: true)
        }
        var received: UInt64 = 0
        for file in files {
            try Task.checkCancellation()
            _ = try await downloadFile(file.path, entry: file.entry, into: local((file.path as NSString).deletingLastPathComponent), transfer, item,
                                       base: received)
            received += file.entry.size ?? 0; item.bytes = received; item.filesDone += 1
        }
    }
}
