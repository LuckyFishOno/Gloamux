import AppKit
import XCTest
import Terminal
@testable import App

/// Tab numbering and moving with split groups, closing checks, Option as Meta, and saving output.
@MainActor final class TabCommandsTests: XCTestCase {
    private func model() throws -> WorkspaceModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try WorkspaceModel(storage: dir)
    }

    func testDuplicateOpensNextToTheOriginal() async throws {
        let model = try model()
        let local = model.addLocalTab()
        let remote = model.addTab()
        model.moveTab(remote.id, by: -1)
        XCTAssertFalse(model.canDuplicate(remote), "an unsaved connection has nothing to open again")
        XCTAssertNil(model.duplicateTab(remote))
        let copy = try XCTUnwrap(model.duplicateTab(local))
        XCTAssertTrue(copy.isLocal)
        XCTAssertEqual(model.tabs.firstIndex { $0.id == copy.id }, model.tabs.firstIndex { $0.id == local.id }.map { $0 + 1 })
        XCTAssertEqual(model.selection, copy.id)
        for tab in model.tabs { await model.closeTab(tab) }
    }

    func testMovingToAWindowAndBackKeepsTheSession() async throws {
        _ = NSApplication.shared
        let model = try model()
        let tab = model.addTab(); tab.title = "server"; tab.connected = true
        model.moveTabToWindow(tab)
        XCTAssertFalse(model.tabs.contains { $0.id == tab.id })
        XCTAssertNotNil(model.sessionWindows[tab.id])
        model.moveWindowToTabs(tab)
        XCTAssertNil(model.sessionWindows[tab.id])
        XCTAssertEqual(model.tabs.last?.id, tab.id)
        XCTAssertEqual(model.selection, tab.id)
        XCTAssertTrue(tab.connected, "closing the window on the way back does not disconnect")
        for tab in model.tabs { await model.closeTab(tab) }
    }

    func testInactiveTabMarksNewOutputUntilShown() throws {
        let model = try model()
        let hidden = model.addTab(select: false)
        model.terminalReceived(hidden, bytes: Array("hello".utf8))
        XCTAssertTrue(hidden.outputPending)
        model.terminalReceived(model.selected!, bytes: Array("shown".utf8))
        XCTAssertFalse(model.selected!.outputPending)
        model.selectTab(hidden.id)
        XCTAssertFalse(hidden.outputPending)
    }

    func testNumbersAndMovesCountASplitAsOneTab() throws {
        let model = try model()
        let first = model.tabs[0]
        let second = model.addTab()
        let left = model.addTab(); left.isLocal = true
        let right = model.addTab(); right.isLocal = true
        model.selectTab(left.id)
        model.splitWorkspace(.sideBySide)
        XCTAssertNotNil(model.group(containing: right.id))
        XCTAssertEqual(model.stripTabIDs, [first.id, second.id, left.id])

        model.selectTab(number: 2); XCTAssertEqual(model.selection, second.id)
        model.selectTab(number: 9); XCTAssertEqual(model.selection, left.id, "⌘9 is the last tab")
        model.selectTab(number: 7); XCTAssertEqual(model.selection, left.id, "a number past the end does nothing")

        model.selectTab(right.id)
        model.selectAdjacentTab(1); XCTAssertEqual(model.selection, first.id, "next wraps past the split")
        model.selectAdjacentTab(-1); XCTAssertEqual(model.selection, left.id)

        model.moveTab(second.id, by: 1)
        XCTAssertEqual(model.tabs.map(\.id), [first.id, left.id, right.id, second.id], "moves past the whole group")
        model.moveTab(second.id, by: 1)
        XCTAssertEqual(model.tabs.last?.id, second.id, "the last tab stays put")
        model.moveTab(second.id, by: -1)
        XCTAssertEqual(model.tabs.map(\.id), [first.id, second.id, left.id, right.id])
        model.moveTab(right.id, by: -1)
        XCTAssertEqual(model.tabs.map(\.id), [first.id, second.id, left.id, right.id], "a pane in a split stays with its group")
    }

    func testClosingAsksOnlyWhenSomethingWouldEnd() throws {
        let model = try model()
        let remote = model.tabs[0]
        XCTAssertFalse(model.closingInterrupts(remote))
        remote.connected = true
        XCTAssertTrue(model.closingInterrupts(remote))

        let local = model.addTab(); local.isLocal = true; local.terminalReady = true
        XCTAssertFalse(model.closingInterrupts(local), "no shell integration: an idle prompt is assumed")
        local.screen.feed("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}sleep 9\r\n\u{1b}]133;C\u{07}")
        XCTAssertTrue(model.closingInterrupts(local), "a command is running")
        local.screen.feed("\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}$ ")
        XCTAssertFalse(model.closingInterrupts(local), "back at the prompt")
    }

    func testOptionAsMetaSendsEscapeFirst() {
        XCTAssertEqual(TerminalKeyboard.metaBytes(keyCode: 11, characters: "b", control: false), [0x1B, 0x62])
        XCTAssertEqual(TerminalKeyboard.metaBytes(keyCode: 51, characters: "\u{7f}", control: false), [0x1B, 0x7F], "Option-Delete deletes a word")
        XCTAssertNil(TerminalKeyboard.metaBytes(keyCode: 0, characters: "", control: false))
    }

    func testOutputTextDropsTrailingSpacesAndBlankLines() throws {
        let model = try model()
        let tab = model.tabs[0]
        tab.screen = TerminalPreferences.newScreen(); tab.screen.resize(rows: 5, cols: 20)
        tab.screen.feed("one   \r\ntwo\r\n")
        XCTAssertEqual(model.outputText(tab), "one\ntwo\n")
    }

    func testResetColorsClearsImportedSchemeAndHighlights() throws {
        let model = try model()
        let tab = model.tabs[0]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-scheme-\(UUID()).xcs")
        try Data("nonsense".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try model.importColors(file, tab: tab))
        let revision = tab.screenRevision
        model.resetTerminalColors(tab)
        XCTAssertNil(tab.colorScheme); XCTAssertNil(tab.highlights)
        XCTAssertGreaterThan(tab.screenRevision, revision)
    }

    func testSelectionLineCount() {
        let text = "one\ntwo\nthree\n" as NSString
        XCTAssertEqual(TerminalTextView.lineCount(of: [NSRange(location: 0, length: 0)], in: text), 0)
        XCTAssertEqual(TerminalTextView.lineCount(of: [NSRange(location: 1, length: 2)], in: text), 1)
        XCTAssertEqual(TerminalTextView.lineCount(of: [NSRange(location: 2, length: 5)], in: text), 2)
        XCTAssertEqual(TerminalTextView.lineCount(of: [NSRange(location: 0, length: text.length)], in: text), 3)
    }

    func testRemovingATrustedHostKeyAsksAgainAndExportsKnownHosts() throws {
        let model = try model()
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        try model.knownHosts.trust(endpoint: KnownHosts.endpoint(host: "Web.example", port: 22), key: key)
        try model.knownHosts.trust(endpoint: KnownHosts.endpoint(host: "db", port: 2200), key: key)
        XCTAssertEqual(model.knownHosts.knownHostsText(), "[db]:2200 \(key)\nweb.example \(key)\n")
        try model.knownHosts.remove(endpoint: "[db]:2200")
        XCTAssertFalse(try model.knownHosts.isTrusted(endpoint: "[db]:2200", key: key))
        XCTAssertEqual(model.knownHosts.history.last?.action, .removed)
        XCTAssertEqual(model.knownHosts.trusted.map(\.endpoint), ["[web.example]:22"])
    }
}
