import XCTest
import Foundation
@testable import App
@testable import FileTransfer

/// A server folder on this Mac whose final move onto a file can be made to fail, the way a server refuses a rename
/// for lack of permission or a connection drops during it.
actor CommitFailingFileSystem: RemoteFileSystem {
    nonisolated var protocolName: String { "FTP" }
    nonisolated var isOpen: Bool { true }
    /// Paths a rename or replace onto fails, after the temporary copy is complete.
    var refusedTargets: Set<String> = []
    /// False for a server without an atomic replace, such as an SFTP server without `posix-rename@openssh.com`.
    var atomicReplace = true
    private(set) var removed: [String] = []

    func refuse(_ path: String) { refusedTargets.insert(path) }
    func withoutAtomicReplace() { atomicReplace = false }

    private var files: FileManager { .default }

    func readDirectory(_ path: String) async throws -> (path: String, entries: [RemoteEntry]) {
        let names = try files.contentsOfDirectory(atPath: path)
        var entries: [RemoteEntry] = []
        for name in names { if let found = try await entry(at: (path as NSString).appendingPathComponent(name)) { entries.append(found) } }
        return (path, entries)
    }
    func download(remotePath: String, to localURL: URL, progress: ProgressHandler?) async throws {
        try? files.removeItem(at: localURL)
        try files.copyItem(atPath: remotePath, toPath: localURL.path)
    }
    func upload(localURL: URL, to remotePath: String, progress: ProgressHandler?) async throws {
        try? files.removeItem(atPath: remotePath)
        try files.copyItem(atPath: localURL.path, toPath: remotePath)
    }
    func entry(at path: String) async throws -> RemoteEntry? {
        guard let attributes = try? files.attributesOfItem(atPath: path) else { return nil }
        return RemoteEntry(name: (path as NSString).lastPathComponent, size: (attributes[.size] as? NSNumber)?.uint64Value,
                           isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                           permissions: (attributes[.posixPermissions] as? NSNumber)?.uint32Value,
                           modified: attributes[.modificationDate] as? Date)
    }
    func resolve(_ path: String) async throws -> String { path }
    func makeDirectory(_ path: String) async throws { try files.createDirectory(atPath: path, withIntermediateDirectories: false) }
    func removeFile(_ path: String) async throws { removed.append(path); try files.removeItem(atPath: path) }
    func removeDirectory(_ path: String) async throws { try files.removeItem(atPath: path) }
    /// Like an SFTP rename: it never overwrites an existing file.
    func rename(from: String, to: String) async throws {
        if refusedTargets.contains(to) { throw TransferError.remoteError("Permission denied") }
        guard !files.fileExists(atPath: to) else { throw TransferError.remoteError("Failure") }
        try files.moveItem(atPath: from, toPath: to)
    }
    func replace(from: String, to: String) async throws {
        guard atomicReplace else { throw TransferError.remoteError("This SFTP server does not support atomic replacement.") }
        if refusedTargets.contains(to) { throw TransferError.remoteError("Permission denied") }
        guard Foundation.rename(from, to) == 0 else { throw TransferError.remoteError(String(cString: strerror(errno))) }
    }
    func setPermissions(_ path: String, mode: UInt32) async throws {
        try files.setAttributes([.posixPermissions: NSNumber(value: mode & 0o7777)], ofItemAtPath: path)
    }
    func canResume() async -> Bool { false }
    func resumeDownload(remotePath: String, to localURL: URL, offset: UInt64, progress: ProgressHandler?) async throws {
        try await download(remotePath: remotePath, to: localURL, progress: progress)
    }
    func resumeUpload(localURL: URL, to remotePath: String, offset: UInt64, progress: ProgressHandler?) async throws {
        try await upload(localURL: localURL, to: remotePath, progress: progress)
    }
    func close() async throws {}
}

/// Uploads over an existing file never delete it before the new copy is in place, in the transfer queue and when an
/// edited file goes back to the server.
@MainActor final class RemoteCommitTests: XCTestCase {
    private func setUp(_ fs: CommitFailingFileSystem) throws -> (WorkspaceModel, SessionTab, server: URL, mac: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-commit-\(UUID().uuidString)").resolvingSymlinksInPath()
        let server = root.appendingPathComponent("server"), mac = root.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root.appendingPathComponent("workspace")), tab = model.tabs[0]
        tab.ftpSecurity = FTPSecurity.none; tab.transfer = fs; tab.connected = true; tab.host = "files.test"; tab.port = "21"
        return (model, tab, server, mac)
    }

    private func settle(_ queue: TransferQueue) async throws {
        for _ in 0..<500 where queue.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(queue.isActive, "The queue finished")
    }

    private func leftovers(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".partial") }
    }

    func testAnUploadThatCannotBeMovedIntoPlaceKeepsTheServersFile() async throws {
        let fs = CommitFailingFileSystem()
        let (model, tab, server, mac) = try setUp(fs)
        let target = server.appendingPathComponent("notes.txt")
        try Data("server copy".utf8).write(to: target)
        let mine = mac.appendingPathComponent("notes.txt")
        try Data("my copy".utf8).write(to: mine)
        await fs.refuse(target.path)

        model.transfers.upload([mine], to: server.path, via: tab, policy: .replace)
        try await settle(model.transfers)
        guard case .failed = model.transfers.items.last?.state else { return XCTFail("The refused move fails the item") }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "server copy", "The server's file is never deleted first")
        let removed = await fs.removed
        XCTAssertFalse(removed.contains(target.path))
        XCTAssertEqual(try leftovers(server), [], "The temporary copy is cleaned up")
    }

    func testAServerWithoutAtomicReplaceRefusesTheOverwriteAndKeepsTheFile() async throws {
        let fs = CommitFailingFileSystem()
        let (model, tab, server, mac) = try setUp(fs)
        let target = server.appendingPathComponent("notes.txt")
        try Data("server copy".utf8).write(to: target)
        let mine = mac.appendingPathComponent("notes.txt")
        try Data("my copy".utf8).write(to: mine)
        await fs.withoutAtomicReplace()

        model.transfers.upload([mine], to: server.path, via: tab, policy: .replace)
        try await settle(model.transfers)
        guard case .failed(let reason) = model.transfers.items.last?.state else { return XCTFail("The overwrite fails") }
        XCTAssertTrue(reason.contains("atomic replacement"), reason)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "server copy")

        // A new file needs no replace, so it still arrives.
        let fresh = mac.appendingPathComponent("fresh.txt")
        try Data("new".utf8).write(to: fresh)
        model.transfers.upload([fresh], to: server.path, via: tab, policy: .replace)
        try await settle(model.transfers)
        XCTAssertEqual(model.transfers.items.last?.state, .done)
        XCTAssertEqual(try String(contentsOf: server.appendingPathComponent("fresh.txt"), encoding: .utf8), "new")
    }

    func testOverwritesStillReplaceTheFileInOneStep() async throws {
        let fs = CommitFailingFileSystem()
        let (model, tab, server, mac) = try setUp(fs)
        let target = server.appendingPathComponent("notes.txt")
        try Data("server copy".utf8).write(to: target)
        let mine = mac.appendingPathComponent("notes.txt")
        try Data("my copy".utf8).write(to: mine)

        model.transfers.upload([mine], to: server.path, via: tab, policy: .replace)
        try await settle(model.transfers)
        XCTAssertEqual(model.transfers.items.last?.state, .done)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "my copy")
        let removed = await fs.removed
        XCTAssertFalse(removed.contains(target.path), "The old file is swapped out, not deleted first")
        XCTAssertEqual(try leftovers(server), [])
    }

    func testAnEditThatCannotBeMovedIntoPlaceKeepsBothCopies() async throws {
        let fs = CommitFailingFileSystem()
        let (model, tab, server, _) = try setUp(fs)
        let script = server.appendingPathComponent("run.sh")
        try Data("echo one\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let editor = RemoteEditor.shared
        await editor.open(script.path, size: nil, in: tab, model: model, launches: false)
        let edit = try XCTUnwrap(editor.edits.first { $0.remotePath == script.path && $0.tab === tab })
        defer { editor.close(edit) }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try Data("echo two\n".utf8).write(to: edit.localURL)
        editor.check()
        await fs.refuse(script.path)

        await editor.upload(edit, model: model) { _ in true }
        XCTAssertNotNil(edit.error, "The failed save is reported")
        XCTAssertTrue(edit.changed, "The edit still needs saving")
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "echo one\n", "The server's file is unchanged")
        XCTAssertEqual(try String(contentsOf: edit.localURL, encoding: .utf8), "echo two\n", "The Mac copy is kept")
        XCTAssertEqual(try leftovers(server), [])

        // Once the server allows it, the same edit saves and keeps the execute bit.
        await fs.withoutRefusals()
        await editor.upload(edit, model: model) { _ in true }
        XCTAssertNil(edit.error)
        XCTAssertFalse(edit.changed)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "echo two\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.uint16Value, 0o755)
    }
}

extension CommitFailingFileSystem {
    func withoutRefusals() { refusedTargets = [] }
}
