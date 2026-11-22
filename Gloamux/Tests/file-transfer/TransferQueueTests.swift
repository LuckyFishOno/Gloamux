import XCTest
import Foundation
import Ssh
import Combine
@testable import App
@testable import FileTransfer

/// The transfer queue and file tree against a real `sftp-server`.
@MainActor final class TransferQueueTests: XCTestCase {
    private func connected(_ port: Int) async throws -> (WorkspaceModel, SessionTab, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root.appendingPathComponent("workspace")), tab = model.tabs[0]
        tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "tester"; tab.password = "secret"
        let connect = Task { await model.connect(tab) }
        for _ in 0..<300 {
            if tab.hostKeyPrompt != nil { model.answerHostKey(tab, approve: true); break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await connect.value
        XCTAssertTrue(tab.connected, tab.error ?? "")
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        return (model, tab, local)
    }

    private func settle(_ queue: TransferQueue) async throws {
        for _ in 0..<1000 where queue.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(queue.isActive, "The queue finished")
    }

    private func files(under url: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let base = url.standardizedFileURL.path
        for case let file as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)! {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue { found[String(file.standardizedFileURL.path.dropFirst(base.count + 1))] = try? Data(contentsOf: file) }
        }
        return found
    }

    func testFoldersUploadAndDownloadRecursivelyAndLargeFilesSurviveTheRoundTrip() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let (model, tab, local) = try await self.connected(port)
            let queue = model.transfers
            let project = local.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("empty"), withIntermediateDirectories: true)
            // Sizes around the chunk and window edges, plus one large enough to need many pipelined windows.
            let big = Data((0..<1_300_007).map { UInt8(($0 * 31) % 253) })
            try big.write(to: project.appendingPathComponent("src/deep/big.bin"))
            try Data(count: 0).write(to: project.appendingPathComponent("zero.txt"))
            try Data(repeating: 7, count: SFTPTransfer.chunkSize).write(to: project.appendingPathComponent("src/exact.bin"))
            try Data("readme".utf8).write(to: project.appendingPathComponent("README.md"))

            queue.upload([project], to: remote.path, via: tab, policy: .replace)
            try await self.settle(queue)
            XCTAssertEqual(queue.items.last?.state, .done)
            XCTAssertEqual(queue.items.last?.fileCount, 4)
            XCTAssertEqual(queue.items.last?.filesDone, 4)
            XCTAssertEqual(self.files(under: remote.appendingPathComponent("project")), self.files(under: project))
            XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("project/empty").path), "Empty folders are created")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("project").path)
                .contains { $0.hasSuffix(".partial") }, "No temporary upload names remain")

            let back = local.appendingPathComponent("back")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            queue.download([(remote.appendingPathComponent("project").path, true)], to: back, via: tab, policy: .replace)
            try await self.settle(queue)
            XCTAssertEqual(queue.items.last?.state, .done)
            XCTAssertEqual(self.files(under: back.appendingPathComponent("project")), self.files(under: project))
            XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("project/src/deep/big.bin")), big)
            await model.closeAll()
        }
    }

    func testConflictsAreReportedAndSkipKeepsTheExistingFileWhileReplaceOverwritesIt() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let (model, tab, local) = try await self.connected(port)
            let queue = model.transfers
            try Data("server copy".utf8).write(to: remote.appendingPathComponent("notes.txt"))
            let mine = local.appendingPathComponent("notes.txt"), other = local.appendingPathComponent("other.txt")
            try Data("my copy".utf8).write(to: mine); try Data("other".utf8).write(to: other)

            let conflicts = await queue.remoteConflicts(["notes.txt", "other.txt"], in: remote.path, via: tab)
            XCTAssertEqual(conflicts, ["notes.txt"])
            XCTAssertEqual(TransferQueue.localConflicts(["notes.txt", "missing.txt"], in: local), ["notes.txt"])

            queue.upload([mine, other], to: remote.path, via: tab, policy: .skip)
            try await self.settle(queue)
            XCTAssertEqual(queue.items.map(\.state), [.skipped, .done])
            XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("notes.txt"), encoding: .utf8), "server copy")
            XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("other.txt"), encoding: .utf8), "other")

            queue.upload([mine], to: remote.path, via: tab, policy: .replace)
            try await self.settle(queue)
            XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("notes.txt"), encoding: .utf8), "my copy")

            try Data("local edit".utf8).write(to: mine)
            queue.download([(remote.appendingPathComponent("missing.bin").path, false)], to: local, via: tab, policy: .replace)
            queue.download([(remote.appendingPathComponent("other.txt").path, false)], to: local, via: tab, policy: .skip)
            try await self.settle(queue)
            if case .failed = queue.items[queue.items.count - 2].state {} else { XCTFail("A missing file fails its item only") }
            XCTAssertEqual(queue.items.last?.state, .skipped)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: local.path).contains { $0.hasSuffix(".partial") })

            queue.clearFinished()
            XCTAssertTrue(queue.items.isEmpty)
            await model.closeAll()
        }
    }

    func testWaitingItemsCanBeCancelledAndADisconnectedSessionFailsCleanly() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let (model, tab, local) = try await self.connected(port)
            let queue = model.transfers
            let file = local.appendingPathComponent("a.txt")
            try Data("a".utf8).write(to: file)
            queue.upload([file], to: remote.path, via: tab, policy: .replace)
            queue.upload([file], to: remote.appendingPathComponent("nowhere").path, via: tab, policy: .replace)
            queue.cancel(queue.items[1])
            try await self.settle(queue)
            XCTAssertEqual(queue.items.map(\.state), [.done, .cancelled])

            await model.disconnect(tab)
            queue.upload([file], to: remote.path, via: tab, policy: .replace)
            try await self.settle(queue)
            if case .failed = queue.items.last?.state {} else { XCTFail("A disconnected session fails the item") }
            await model.closeAll()
        }
    }

    func testTheRemoteTreeOpensFoldersLazilyAndDeletesFoldersWithTheirContents() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let (model, tab, _) = try await self.connected(port)
            try FileManager.default.createDirectory(at: remote.appendingPathComponent("logs/2026"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: remote.appendingPathComponent("logs/2026/app.log"))
            try Data("y".utf8).write(to: remote.appendingPathComponent("top.txt"))
            let tree = tab.remoteTree
            await tree.open(remote.path, model: model, tab: tab)
            let root = try XCTUnwrap(tree.root)
            XCTAssertEqual(tree.children[root]?.map(\.name), ["logs", "top.txt"], "Folders first, then files")
            let logs = RemoteTreeState.child(root, "logs")
            XCTAssertNil(tree.children[logs], "Folders load only when opened")
            await tree.toggle(logs, model: model, tab: tab)
            XCTAssertEqual(tree.children[logs]?.map(\.name), ["2026"])
            await tree.toggle(logs, model: model, tab: tab)
            XCTAssertFalse(tree.expanded.contains(logs))
            XCTAssertEqual(tree.uploadFolder, root, "Nothing selected uploads to the top folder")
            tree.selection = logs
            XCTAssertEqual(tree.uploadFolder, logs, "A selected folder takes the upload")
            tree.selection = RemoteTreeState.child(root, "top.txt")
            XCTAssertEqual(tree.uploadFolder, root, "A selected file uploads beside it")

            try await RemoteDelete.remove(logs, isDirectory: true, with: model.sftp(for: tab))
            await tree.refresh(model: model, tab: tab)
            XCTAssertEqual(tree.children[root]?.map(\.name), ["top.txt"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("logs").path))

            await model.disconnect(tab)
            XCTAssertNil(tree.root, "Disconnecting clears the tree")
            await model.closeAll()
        }
    }

    func testTheLocalTreeStartsAtHomeAndOpensFoldersOnDemand() throws {
        let tree = LocalTreeState()
        XCTAssertEqual(tree.root, LocalTreeState.home, "The local tree opens at the home folder")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b-folder/inner"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("h".utf8).write(to: root.appendingPathComponent(".hidden"))
        tree.open(root.path)
        let top = tree.root
        XCTAssertEqual(tree.children[top]?.map(\.name), ["b-folder", "a.txt"], "Folders first, hidden files left out")
        let folder = LocalTreeState.child(top, "b-folder")
        tree.toggle(folder)
        XCTAssertEqual(tree.children[folder]?.map(\.name), ["inner"])
        tree.open(root.appendingPathComponent("a.txt").path)
        XCTAssertEqual(tree.root, top, "A file cannot become the top folder")
        XCTAssertNotNil(tree.error)
    }
}

/// Interrupted copies over a real `sftp-server`.
@MainActor final class TransferResumeTests: XCTestCase {
    func testSFTPContinuesCopiesFromAnOffsetAndChangesPermissions() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let ssh = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: port, username: "tester"), credential: .password("secret"), hostKey: .acceptAny)
            let sftp = try await SFTPTransfer.open(ssh)
            XCTAssertTrue(sftp.isOpen)
            let body = Data((0..<200_000).map { UInt8($0 % 251) })
            let source = remote.appendingPathComponent("source.bin")
            try body.write(to: source)
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-resume-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: local) }
            // The first 70,000 bytes arrived; a stray tail after them is replaced.
            try (body.prefix(70_000) + Data(repeating: 0xFF, count: 10)).write(to: local)
            try await sftp.resumeDownload(remotePath: source.path, to: local, offset: 70_000, progress: nil)
            XCTAssertEqual(try Data(contentsOf: local), body)

            let target = remote.appendingPathComponent("target.bin")
            try body.prefix(123_456).write(to: target)
            try await sftp.resumeUpload(localURL: local, to: target.path, offset: 123_456, progress: nil)
            XCTAssertEqual(try Data(contentsOf: target), body)

            try await sftp.setPermissions(target.path, mode: 0o640)
            let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.uint16Value, 0o640)
            try await sftp.close()
        }
    }

    func testABrokenConnectionIsRetriedAndTheCopyCompletes() async throws {
        let delays = TransferQueue.retryDelays
        TransferQueue.retryDelays = [0, 0, 0]
        defer { TransferQueue.retryDelays = delays }
        try await OpenSSHFixture.withServer { port, remote in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-retry-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = try WorkspaceModel(storage: root.appendingPathComponent("workspace")), tab = model.tabs[0]
            tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "tester"; tab.password = "secret"
            let connect = Task { await model.connect(tab) }
            for _ in 0..<300 {
                if tab.hostKeyPrompt != nil { model.answerHostKey(tab, approve: true); break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await connect.value
            XCTAssertTrue(tab.connected, tab.error ?? "")
            let body = Data((0..<24_000_000).map { UInt8(($0 * 7) % 253) })
            try body.write(to: remote.appendingPathComponent("large.bin"))
            let queue = model.transfers
            queue.download([(remote.appendingPathComponent("large.bin").path, false)], to: root, via: tab, policy: .replace)
            // Break the file channel once bytes are moving; the SSH connection itself stays up.
            for _ in 0..<2000 where (queue.items.first?.bytes ?? 0) == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            let first = try await model.sftp(for: tab)
            try await first.close()
            for _ in 0..<2000 where queue.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(queue.items.first?.state, .done)
            XCTAssertEqual(queue.items.first?.attempts, 2, "The broken copy was tried once more")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("large.bin")), body)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
            await model.closeAll()
        }
    }
}

extension TransferResumeTests {
    func testTryingAgainContinuesFromThePartialCopy() async throws {
        let delays = TransferQueue.retryDelays
        TransferQueue.retryDelays = []
        defer { TransferQueue.retryDelays = delays }
        try await OpenSSHFixture.withServer { port, remote in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-again-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = try WorkspaceModel(storage: root.appendingPathComponent("workspace")), tab = model.tabs[0]
            tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "tester"; tab.password = "secret"
            let connect = Task { await model.connect(tab) }
            for _ in 0..<300 {
                if tab.hostKeyPrompt != nil { model.answerHostKey(tab, approve: true); break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await connect.value
            let body = Data((0..<24_000_000).map { UInt8(($0 * 11) % 251) })
            try body.write(to: remote.appendingPathComponent("large.bin"))
            let queue = model.transfers
            queue.download([(remote.appendingPathComponent("large.bin").path, false)], to: root, via: tab, policy: .replace)
            for _ in 0..<2000 where (queue.items.first?.bytes ?? 0) == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            try await model.sftp(for: tab).close()
            for _ in 0..<2000 where queue.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            let item = try XCTUnwrap(queue.items.first)
            guard case .failed = item.state else { return XCTFail("Without automatic retries the copy fails") }
            let partial = try XCTUnwrap(item.partials.values.first?.path)
            let kept = (try FileManager.default.attributesOfItem(atPath: partial)[.size] as? NSNumber)?.uint64Value ?? 0
            XCTAssertGreaterThan(kept, 0, "The bytes already copied are kept")
            var lowest = UInt64.max
            let watch = item.$bytes.sink { if $0 > 0 { lowest = min(lowest, $0) } }
            queue.retry(item)
            for _ in 0..<2000 where queue.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            watch.cancel()
            XCTAssertEqual(item.state, .done)
            XCTAssertGreaterThanOrEqual(lowest, kept, "The second attempt started where the first stopped")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("large.bin")), body)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial))
            await model.closeAll()
        }
    }
}

/// Remote files edited on the Mac, permissions, and drag copies, over a real `sftp-server`.
@MainActor final class RemoteFileActionTests: XCTestCase {
    func testPermissionBitsKeepSpecialBits() {
        XCTAssertEqual(PermissionsSheet.mode(0o640, keeping: 0o104755), 0o4640)
        XCTAssertEqual(PermissionsSheet.mode(0o755, keeping: nil), 0o755)
        XCTAssertEqual(PermissionsSheet.symbolic(0o750), "rwxr-x---")
        XCTAssertTrue(RemoteFileDrag.isOwnCopy(RemoteFileDrag.dragFolder.appendingPathComponent("x/file.txt")))
        XCTAssertFalse(RemoteFileDrag.isOwnCopy(URL(fileURLWithPath: "/tmp/file.txt")))
    }

    func testEditedFilesUploadWithAConflictCheckAndKeepTheirPermissions() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-edit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = try WorkspaceModel(storage: root.appendingPathComponent("workspace")), tab = model.tabs[0]
            tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "tester"; tab.password = "secret"
            let connect = Task { await model.connect(tab) }
            for _ in 0..<300 {
                if tab.hostKeyPrompt != nil { model.answerHostKey(tab, approve: true); break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await connect.value
            XCTAssertTrue(tab.connected, tab.error ?? "")
            let script = remote.appendingPathComponent("run.sh")
            try Data("echo one\n".utf8).write(to: script)
            try await model.setPermissions([(script.path, 0o100644)], to: 0o755, in: tab)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.uint16Value, 0o755)

            let editor = RemoteEditor.shared
            await editor.open(script.path, size: nil, in: tab, model: model, launches: false)
            let edit = try XCTUnwrap(editor.edits.first { $0.remotePath == script.path })
            XCTAssertEqual(try String(contentsOf: edit.localURL, encoding: .utf8), "echo one\n")
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try Data("echo two\n".utf8).write(to: edit.localURL)
            editor.check()
            XCTAssertTrue(edit.changed)
            var asked = false
            await editor.upload(edit, model: model) { _ in asked = true; return true }
            XCTAssertFalse(asked, "Nobody else changed the server's copy")
            XCTAssertNil(edit.error)
            XCTAssertFalse(edit.changed)
            XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "echo two\n")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.uint16Value, 0o755,
                           "The uploaded copy keeps the execute bit")

            // Someone changes the server's copy; uploading now asks first.
            try Data("echo server\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: script.path)
            try Data("echo three\n".utf8).write(to: edit.localURL)
            await editor.upload(edit, model: model) { _ in asked = true; return false }
            XCTAssertTrue(asked)
            XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "echo server\n", "Declining keeps the server's copy")
            await editor.upload(edit, model: model) { _ in true }
            XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "echo three\n")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: remote.path).contains { $0.hasSuffix(".partial") })

            let folder = edit.localURL.deletingLastPathComponent()
            editor.close(edit)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

            // A drag to Finder copies the file, or a whole folder, into a private folder first.
            try FileManager.default.createDirectory(at: remote.appendingPathComponent("tree/inner"), withIntermediateDirectories: true)
            try Data("leaf".utf8).write(to: remote.appendingPathComponent("tree/inner/leaf.txt"))
            let copy = try await RemoteFileDrag.fetch(remote.appendingPathComponent("tree").path, isDirectory: true, tab: tab, model: model)
            XCTAssertTrue(RemoteFileDrag.isOwnCopy(copy))
            XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("inner/leaf.txt"), encoding: .utf8), "leaf")
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            await model.closeAll()
        }
    }
}
