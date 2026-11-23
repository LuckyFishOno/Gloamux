import XCTest
import AppKit
@testable import App

/// Saved data that cannot be read or written: the problem is shown, nothing is reported as saved, and the data
/// waits to be saved again.
@MainActor final class SaveFailureTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("triggers.json").path)
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    func testTriggerFileStatesAreToldApart() throws {
        let root = try folder()
        let url = root.appendingPathComponent("triggers.json")

        let missing = OutputTriggerStore(url: url)
        XCTAssertNil(missing.loadError, "No file yet is a normal start")
        XCTAssertEqual(missing.triggers, [])

        try Data("[]".utf8).write(to: url)
        let empty = OutputTriggerStore(url: url)
        XCTAssertNil(empty.loadError, "An empty list is valid")

        try Data("{\"version\": 9}".utf8).write(to: url)
        let damaged = OutputTriggerStore(url: url)
        XCTAssertEqual(damaged.loadError, OutputTriggerStore.damaged)
        XCTAssertThrowsError(try damaged.save(OutputTrigger(name: "x", pattern: "x")))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"version\": 9}")

        let tooMany = (0..<(OutputTriggerStore.limit + 1)).map { OutputTrigger(name: "\($0)", pattern: "p\($0)") }
        try JSONEncoder().encode(tooMany).write(to: url)
        XCTAssertEqual(OutputTriggerStore(url: url).loadError, OutputTriggerStore.damaged, "Extra rules are not dropped silently")

        try Data("[]".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let unreadable = OutputTriggerStore(url: url)
        XCTAssertEqual(unreadable.loadError, OutputTriggerStore.unreadable)
        XCTAssertThrowsError(try unreadable.remove(UUID()))

        // Once the file can be read again, reloading clears the problem.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        unreadable.reload()
        XCTAssertNil(unreadable.loadError)
        try unreadable.save(OutputTrigger(name: "Errors", pattern: "ERROR"))
        XCTAssertEqual(OutputTriggerStore(url: url).triggers.map(\.name), ["Errors"])
    }

    func testAFailedTriggerSaveIsNotShownAsSaved() throws {
        let root = try folder()
        let url = root.appendingPathComponent("triggers.json")
        let store = OutputTriggerStore(url: url)
        // A folder where the file should be makes the write fail.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("occupied"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.save(OutputTrigger(name: "Errors", pattern: "ERROR")))
        XCTAssertEqual(store.triggers, [], "The list still shows what is on disk")
    }

    func testARecordingThatCannotBeSavedIsKeptForAnotherTry() async throws {
        let root = try folder()
        let model = try WorkspaceModel(storage: root.appendingPathComponent("workspace"))
        let tab = model.tabs[0]
        // A file where the recordings folder should be makes the save fail.
        let blocked = root.appendingPathComponent("recordings")
        try Data().write(to: blocked)
        let recordings = TerminalRecordings(folder: blocked)

        recordings.start(tab)
        recordings.output(tab, bytes: Array("deploy finished\r\n".utf8))
        let failed = await recordings.stop(tab).value
        XCTAssertEqual(failed, .failed(TerminalRecordings.saveFailed))
        XCTAssertFalse(recordings.isRecording(tab))
        XCTAssertEqual(recordings.unsaved.count, 1, "The recording is kept")
        let retried = await recordings.retryUnsaved()
        XCTAssertEqual(retried, [], "Still blocked")
        XCTAssertEqual(recordings.unsaved.count, 1)

        try FileManager.default.removeItem(at: blocked)
        let written = await recordings.retryUnsaved()
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(recordings.unsaved.count, 0)
        XCTAssertEqual(recordings.saved.map(\.url.lastPathComponent), written.map(\.lastPathComponent))
        XCTAssertTrue(try String(contentsOf: written[0], encoding: .utf8).contains("deploy finished"))

        // Nothing recorded is not a failure; and the unsaved list stays bounded.
        recordings.start(tab)
        let nothing = await recordings.stop(tab).value
        XCTAssertEqual(nothing, .nothingRecorded)
        try FileManager.default.removeItem(at: blocked)
        try Data().write(to: blocked)
        for _ in 0..<(TerminalRecordings.unsavedLimit + 2) {
            recordings.start(tab)
            recordings.output(tab, bytes: Array("x\r\n".utf8))
            recordings.stop(tab)
        }
        let finished = await recordings.finishSaving()
        XCTAssertTrue(finished)
        XCTAssertEqual(recordings.unsaved.count, TerminalRecordings.unsavedLimit)
        recordings.discardUnsaved()
        XCTAssertEqual(recordings.unsaved.count, 0)
    }

    func testStoppingAFailedRecordingFromTheCommandLineSaysSo() async throws {
        let root = try folder()
        let model = try WorkspaceModel(storage: root)
        let tab = model.tabs[0]
        tab.terminalReady = true
        try await WorkspaceCommand.run(["tabs", "record", tab.id.uuidString, "on"], model: model, live: true)
        model.recordings.output(tab, bytes: Array("output\r\n".utf8))
        try Data().write(to: model.recordings.folder)
        do {
            _ = try await WorkspaceCommand.run(["tabs", "record", tab.id.uuidString, "off"], model: model, live: true)
            XCTFail("A failed save reported success")
        } catch WorkspaceError.invalid(let reason) {
            XCTAssertEqual(reason, TerminalRecordings.saveFailed)
        }
        XCTAssertNil(model.recordingSaved)
        XCTAssertEqual(model.recordings.unsaved.count, 1)
    }
}
