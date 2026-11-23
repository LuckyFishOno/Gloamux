import XCTest
import Foundation
@testable import App
@testable import FileTransfer

/// A server whose folder listings wait until the test answers them, so replies can arrive in any order.
actor GatedFileSystem: RemoteFileSystem {
    nonisolated var protocolName: String { "FTP" }
    nonisolated var isOpen: Bool { true }
    private var waiting: [(path: String, reply: CheckedContinuation<[RemoteEntry], Error>)] = []

    func pending(_ path: String) -> Int { waiting.filter { $0.path == path }.count }

    /// Answers the oldest waiting listing of `path`, or the newest.
    func answer(_ path: String, with names: [String], newest: Bool = false) {
        guard let index = newest ? waiting.lastIndex(where: { $0.path == path }) : waiting.firstIndex(where: { $0.path == path }) else { return }
        waiting.remove(at: index).reply.resume(returning: names.map { RemoteEntry(name: $0, size: 1, isDirectory: false) })
    }
    func fail(_ path: String, _ text: String) {
        guard let index = waiting.firstIndex(where: { $0.path == path }) else { return }
        waiting.remove(at: index).reply.resume(throwing: TransferError.remoteError(text))
    }

    func readDirectory(_ path: String) async throws -> (path: String, entries: [RemoteEntry]) {
        let entries = try await withCheckedThrowingContinuation { waiting.append((path, $0)) }
        return (path, entries)
    }
    func resolve(_ path: String) async throws -> String { path == "." ? "/home" : path }
    func entry(at path: String) async throws -> RemoteEntry? { nil }
    func download(remotePath: String, to localURL: URL, progress: ProgressHandler?) async throws {}
    func upload(localURL: URL, to remotePath: String, progress: ProgressHandler?) async throws {}
    func makeDirectory(_ path: String) async throws {}
    func removeFile(_ path: String) async throws {}
    func removeDirectory(_ path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ path: String, mode: UInt32) async throws {}
    func canResume() async -> Bool { false }
    func resumeDownload(remotePath: String, to localURL: URL, offset: UInt64, progress: ProgressHandler?) async throws {}
    func resumeUpload(localURL: URL, to remotePath: String, offset: UInt64, progress: ProgressHandler?) async throws {}
    func close() async throws {}
}

/// Folder listings that finish out of order, fail late, or finish after a disconnect never replace what is shown now.
@MainActor final class RemoteLoadOrderTests: XCTestCase {
    private func connected(_ fs: GatedFileSystem) throws -> (WorkspaceModel, SessionTab) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-order-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root), tab = model.tabs[0]
        tab.ftpSecurity = FTPSecurity.none; tab.transfer = fs; tab.connected = true; tab.host = "files.test"; tab.port = "21"
        return (model, tab)
    }

    /// Waits until the listing of `path` has reached the server.
    private func requested(_ path: String, _ fs: GatedFileSystem, count: Int = 1) async throws {
        for _ in 0..<500 { if await fs.pending(path) >= count { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("No listing of \(path) arrived")
    }

    func testTheLastFolderOpenedStaysShownWhenAnEarlierOneAnswersLater() async throws {
        let fs = GatedFileSystem()
        let (model, tab) = try connected(fs)
        let browser = tab.remoteBrowser
        let a = Task { await browser.load("/a", model: model, tab: tab) }
        try await requested("/a", fs)
        let b = Task { await browser.load("/b", model: model, tab: tab) }
        try await requested("/b", fs)

        await fs.answer("/b", with: ["b.txt"])
        await b.value
        XCTAssertEqual(browser.folder, "/b")
        await fs.answer("/a", with: ["a.txt"])
        await a.value
        XCTAssertEqual(browser.folder, "/b", "The earlier folder does not come back")
        XCTAssertEqual(browser.items.map(\.name), ["b.txt"])
        XCTAssertFalse(browser.loading)
    }

    func testAnEarlierFolderFailingLateLeavesTheCurrentOneAlone() async throws {
        let fs = GatedFileSystem()
        let (model, tab) = try connected(fs)
        let browser = tab.remoteBrowser
        let a = Task { await browser.load("/a", model: model, tab: tab) }
        try await requested("/a", fs)
        let b = Task { await browser.load("/b", model: model, tab: tab) }
        try await requested("/b", fs)

        // The older request ends first: the newer one is still loading.
        await fs.fail("/a", "Permission denied")
        await a.value
        XCTAssertTrue(browser.loading, "An old request does not end the new one's loading state")
        XCTAssertNil(browser.error, "An old failure is not shown")
        await fs.answer("/b", with: ["b.txt"])
        await b.value
        XCTAssertFalse(browser.loading)
        XCTAssertEqual(browser.folder, "/b")
        XCTAssertNil(browser.error)
    }

    func testListingsFinishingAfterADisconnectAreDropped() async throws {
        let fs = GatedFileSystem()
        let (model, tab) = try connected(fs)
        let browser = tab.remoteBrowser, tree = tab.remoteTree
        let shown = Task { await browser.load("/a", model: model, tab: tab) }
        try await requested("/a", fs)
        let opened = Task { await tree.open("/srv", model: model, tab: tab) }
        try await requested("/srv", fs)

        await model.disconnect(tab)
        await fs.answer("/a", with: ["secret.txt"])
        await fs.answer("/srv", with: ["secret.txt"])
        await shown.value; await opened.value
        XCTAssertNil(browser.folder)
        XCTAssertEqual(browser.items, [])
        XCTAssertFalse(browser.loading)
        XCTAssertNil(tree.root)
        XCTAssertEqual(tree.children, [:], "Nothing from the old connection reappears")
        XCTAssertEqual(tree.loading, [])
    }

    func testAReconnectDropsRepliesFromTheOldConnection() async throws {
        let fs = GatedFileSystem()
        let (model, tab) = try connected(fs)
        let browser = tab.remoteBrowser
        let shown = Task { await browser.load("/a", model: model, tab: tab) }
        try await requested("/a", fs)
        tab.epoch = UUID()
        await fs.answer("/a", with: ["old.txt"])
        await shown.value
        XCTAssertEqual(browser.items, [])
        XCTAssertFalse(browser.loading)
    }

    func testFoldersOpenTogetherAndTheLatestReloadOfAFolderWins() async throws {
        let fs = GatedFileSystem()
        let (model, tab) = try connected(fs)
        let tree = tab.remoteTree
        let opened = Task { await tree.open(nil, model: model, tab: tab) }
        try await requested("/home", fs)
        await fs.answer("/home", with: ["x", "y"])
        await opened.value
        XCTAssertEqual(tree.root, "/home")

        // Two folders open at once and answer in the other order: both keep their own contents.
        let x = Task { await tree.toggle("/home/x", model: model, tab: tab) }
        try await requested("/home/x", fs)
        let y = Task { await tree.toggle("/home/y", model: model, tab: tab) }
        try await requested("/home/y", fs)
        XCTAssertEqual(tree.loading, ["/home/x", "/home/y"])
        await fs.answer("/home/y", with: ["y1"])
        await y.value
        XCTAssertEqual(tree.loading, ["/home/x"])
        await fs.answer("/home/x", with: ["x1"])
        await x.value
        XCTAssertEqual(tree.children["/home/x"]?.map(\.name), ["x1"])
        XCTAssertEqual(tree.children["/home/y"]?.map(\.name), ["y1"])
        XCTAssertEqual(tree.loading, [])

        // Two reloads of one folder: the older reply, arriving last, does not replace the newer one.
        let older = Task { await tree.load("/home/x", model: model, tab: tab) }
        try await requested("/home/x", fs)
        let newer = Task { await tree.load("/home/x", model: model, tab: tab) }
        try await requested("/home/x", fs, count: 2)
        await fs.answer("/home/x", with: ["stale"])
        await older.value
        XCTAssertTrue(tree.loading.contains("/home/x"), "The newer reload is still loading")
        await fs.answer("/home/x", with: ["fresh"])
        await newer.value
        XCTAssertEqual(tree.children["/home/x"]?.map(\.name), ["fresh"])
        XCTAssertEqual(tree.loading, [])

        // The same, with the newer reply first and the older one arriving last.
        let first = Task { await tree.load("/home/y", model: model, tab: tab) }
        try await requested("/home/y", fs)
        let second = Task { await tree.load("/home/y", model: model, tab: tab) }
        try await requested("/home/y", fs, count: 2)
        await fs.answer("/home/y", with: ["fresh"], newest: true)
        await second.value
        await fs.answer("/home/y", with: ["stale"])
        await first.value
        XCTAssertEqual(tree.children["/home/y"]?.map(\.name), ["fresh"])
        XCTAssertEqual(tree.loading, [])
        XCTAssertNil(tree.error)
    }
}
