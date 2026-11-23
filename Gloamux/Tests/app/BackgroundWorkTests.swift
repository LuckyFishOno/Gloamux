import XCTest
@testable import App

/// Large work that used to run on the main actor: saving a recording and listing a folder on this Mac. The windows
/// keep answering meanwhile, and the results are the same as before.
@MainActor final class BackgroundWorkTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-background-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// The longest the main actor went without running a 5 ms ticker while `work` ran.
    private func longestStall(_ work: () async -> Void) async -> Double {
        var last = DispatchTime.now().uptimeNanoseconds, longest: UInt64 = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                longest = max(longest, now - last); last = now
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await work()
        ticker.cancel()
        return Double(longest) / 1e6
    }

    /// Output near the size limit, with a secret every so often.
    private func record(_ recordings: TerminalRecordings, _ tab: SessionTab, bytes: Int) {
        recordings.start(tab)
        let line = "drwxr-xr-x  2 ops staff  64 Nov 24 01:00 build-output-folder-name\r\n"
        var chunk = ""
        while chunk.utf8.count < 4096 { chunk += line }
        var n = 0, written = 0
        while written < bytes {
            let text = n % 16 == 0 ? chunk + "export TOKEN=abcdef\(n)\r\n" : chunk
            recordings.output(tab, bytes: Array(text.utf8))
            written += text.utf8.count; n += 1
        }
    }

    func testStoppingALongRecordingLeavesTheWindowsFree() async throws {
        let recordings = TerminalRecordings(folder: try folder())
        let tab = SessionTab()
        record(recordings, tab, bytes: 24 * 1024 * 1024)
        let expected = try XCTUnwrap(recordings.active[tab.id]).asciicast()

        var stopTook = 0.0
        var result: TerminalRecordings.StopResult?
        let stall = await longestStall {
            let start = DispatchTime.now().uptimeNanoseconds
            let saving = recordings.stop(tab)
            stopTook = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            XCTAssertFalse(recordings.isRecording(tab), "Recording stops at once")
            XCTAssertEqual(recordings.saving, 1)
            result = await saving.value
        }
        XCTAssertLessThan(stopTook, 100, "Stop returns before the file is written")
        XCTAssertLessThan(stall, 300, "The main actor kept running while the recording was saved")
        guard case .saved(let url) = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(recordings.saving, 0)
        XCTAssertEqual(try Data(contentsOf: url), expected, "The file is what the recorder held, masked the same way")
        XCTAssertFalse(String(decoding: expected, as: UTF8.self).contains("abcdef16"), "Secrets are masked")
        XCTAssertEqual(recordings.saved.map(\.url.lastPathComponent), [url.lastPathComponent])
    }

    func testSavesFinishInTheOrderTheRecordingsStopped() async throws {
        let recordings = TerminalRecordings(folder: try folder())
        let first = SessionTab(), second = SessionTab()
        record(recordings, first, bytes: 4 * 1024 * 1024)
        recordings.start(second)
        recordings.output(second, bytes: Array("short\r\n".utf8))
        var finished: [String] = []
        let one = recordings.stop(first), two = recordings.stop(second)
        let watchers = [Task { _ = await one.value; finished.append("first") }, Task { _ = await two.value; finished.append("second") }]
        for watcher in watchers { await watcher.value }
        XCTAssertEqual(finished, ["first", "second"])
        XCTAssertEqual(recordings.saved.count, 2, "Same title and second: both files are kept")
        guard case .saved(let a) = await one.value, case .saved(let b) = await two.value else { return XCTFail() }
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(try String(contentsOf: b, encoding: .utf8).contains("short"))
    }

    func testQuittingWaitsForSavesAndReportsOneThatFailed() async throws {
        let root = try folder()
        let model = try WorkspaceModel(storage: root.appendingPathComponent("workspace"))
        let tab = model.tabs[0]
        model.recordings.start(tab)
        model.recordings.output(tab, bytes: Array("still running at quit\r\n".utf8))
        let finished = await model.finishRecordingsBeforeQuit()
        XCTAssertTrue(finished)
        XCTAssertFalse(model.recordings.isRecording(tab), "Quitting stops a running recording")
        XCTAssertEqual(model.recordings.saved.count, 1, "and saves it before the app ends")

        // A recording that cannot be written is reported, not lost quietly.
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let recordings = TerminalRecordings(folder: blocked)
        recordings.start(tab)
        recordings.output(tab, bytes: Array("x\r\n".utf8))
        recordings.stop(tab)
        let saved = await recordings.finishSaving()
        XCTAssertTrue(saved, "The save finished")
        XCTAssertEqual(recordings.unsaved.count, 1, "and failed; it is kept")
    }

    func testListingALargeFolderLeavesTheWindowsFree() async throws {
        let big = try folder()
        for i in 0..<20_000 { FileManager.default.createFile(atPath: big.appendingPathComponent("file-\(i).txt").path, contents: nil) }
        let state = LocalBrowserState()
        var called = 0.0
        let stall = await longestStall {
            let start = DispatchTime.now().uptimeNanoseconds
            let loading = state.load(big)
            called = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            XCTAssertTrue(state.loading)
            await loading.value
        }
        XCTAssertLessThan(called, 20)
        XCTAssertLessThan(stall, 100)
        XCTAssertFalse(state.loading)
        XCTAssertEqual(state.items.count, 20_000)
        XCTAssertEqual(state.folder, big.standardizedFileURL)
    }

    func testOnlyTheLatestFolderIsShown() async throws {
        let big = try folder(), small = try folder()
        for i in 0..<20_000 { FileManager.default.createFile(atPath: big.appendingPathComponent("file-\(i).txt").path, contents: nil) }
        for name in ["a", "b", "c"] { FileManager.default.createFile(atPath: small.appendingPathComponent(name).path, contents: nil) }
        let state = LocalBrowserState()
        let slow = state.load(big)
        let fast = state.load(small)
        await fast.value
        await slow.value
        XCTAssertEqual(state.folder, small.standardizedFileURL, "The earlier, slower listing does not replace the latest")
        XCTAssertEqual(Set(state.items.map(\.name)), ["a", "b", "c"])
        XCTAssertFalse(state.loading)

        // A folder that cannot be read reports an error and keeps the last listing.
        await state.load(small.appendingPathComponent("missing")).value
        XCTAssertNotNil(state.error)
        XCTAssertEqual(state.folder, small.standardizedFileURL)
    }
}
