import XCTest
import Combine
import Foundation
@testable import App

@MainActor final class WorkspaceCommandStateTests: XCTestCase {
    private func model() throws -> WorkspaceModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-menu-state-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try WorkspaceModel(storage: url)
    }

    /// The snapshot is taken on the next turn of the run loop, after the change.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testMenusRebuildOnlyWhenWhatTheyShowChanges() throws {
        let model = try model()
        let state = model.commandState
        var published = 0
        let watch = state.objectWillChange.sink { _ in published += 1 }
        defer { watch.cancel() }

        // A workspace change the menus do not show publishes nothing.
        model.objectWillChange.send()
        model.commandPaletteShown = true
        settle()
        XCTAssertEqual(published, 0)

        model.lockWorkspace()
        settle()
        XCTAssertTrue(state.snapshot.workspaceLocked)
        XCTAssertEqual(published, 1)
    }

    func testTheFocusedTabsOwnChangesReachTheTerminalMenu() throws {
        let model = try model()
        let state = model.commandState
        let tab = try XCTUnwrap(model.selected)
        XCTAssertTrue(state.snapshot.hasSelection)
        XCTAssertFalse(state.snapshot.readOnly)

        tab.readOnly = true
        settle()
        XCTAssertTrue(state.snapshot.readOnly)

        tab.encoding = .big5
        settle()
        XCTAssertEqual(state.snapshot.encoding, .big5)
    }
}
