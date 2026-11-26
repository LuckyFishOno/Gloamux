import Combine
import XCTest
@testable import App

/// Output triggers, startup commands, reopening tabs, and the workspace lock.
@MainActor final class WorkspaceSessionTests: XCTestCase {
    private func storage() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testTriggersMatchWholeLinesAndStayQuietAfterFiring() throws {
        let error = OutputTrigger(name: "Errors", pattern: "error", action: .mark)
        let deploy = OutputTrigger(name: "", pattern: #"deploy (ok|done)"#, regex: true, caseSensitive: true)
        let compiled = try [error, deploy].map { ($0, try $0.compiled()) }
        var matcher = OutputTriggerMatcher()
        let start = Date()
        XCTAssertTrue(matcher.feed(Array("an ERR".utf8), triggers: compiled, now: start).isEmpty, "a line is matched once it ends")
        let first = matcher.feed(Array("OR here\r\n\u{1b}[32mdeploy done\u{1b}[0m\n".utf8), triggers: compiled, now: start)
        XCTAssertEqual(first.map(\.0.id), [error.id, deploy.id])
        XCTAssertEqual(first.first?.1, "an ERROR here", "escape sequences and carriage returns are removed")
        XCTAssertTrue(matcher.feed(Array("error again\n".utf8), triggers: compiled, now: start.addingTimeInterval(5)).isEmpty)
        XCTAssertEqual(matcher.feed(Array("error again\n".utf8), triggers: compiled, now: start.addingTimeInterval(11)).count, 1)
        XCTAssertTrue(matcher.feed(Array("Deploy Done\n".utf8), triggers: compiled, now: start.addingTimeInterval(30)).isEmpty, "case-sensitive rule")
    }

    func testTriggerStoreValidatesAndPersists() throws {
        let url = try storage().appendingPathComponent("triggers.json")
        let store = OutputTriggerStore(url: url)
        XCTAssertThrowsError(try store.save(OutputTrigger(name: "", pattern: "")))
        XCTAssertThrowsError(try store.save(OutputTrigger(name: "", pattern: "(", regex: true)))
        try store.save(OutputTrigger(name: "panic", pattern: "panic:"))
        XCTAssertEqual(OutputTriggerStore(url: url).triggers.map(\.name), ["panic"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testMarkTriggerFlagsATabInTheBackground() throws {
        let model = try WorkspaceModel(storage: storage())
        try model.triggers.save(OutputTrigger(name: "", pattern: "FAILED", action: .mark))
        let background = model.tabs[0]
        let front = model.addTab()
        XCTAssertEqual(model.selection, front.id)
        model.terminalReceived(background, bytes: Array("tests FAILED\n".utf8))
        XCTAssertTrue(background.attention)
    }

    func testStartupLinesSkipBlanksAndAreLimited() {
        XCTAssertEqual(WorkspaceModel.startupLines("  cd /srv \n\n\ttail -f log\r\n"), ["cd /srv", "tail -f log"])
        XCTAssertEqual(WorkspaceModel.startupLines((1...30).map { "echo \($0)" }.joined(separator: "\n")).count, 20)
    }

    func testOpenTabsListSavedSessionsAndLocalTerminals() throws {
        let model = try WorkspaceModel(storage: storage())
        let node = try model.sessionTree.add(name: "web", parent: nil, connection: SavedConnection(host: "web.example", username: "me"))
        model.tabs.removeAll()
        let saved = model.addTab(); saved.savedSessionID = node
        _ = model.addTab()
        let local = model.addTab(); local.isLocal = true
        model.selectTab(local.id)
        XCTAssertEqual(model.currentOpenTabs(), WorkspaceModel.OpenTabs(entries: [.saved(node), .local], selected: 1),
                       "an unsaved connection is left out")
    }

    func testNewTabsOpenTheChosenConnectionAndNewConnectionKeepsTheForm() async throws {
        let key = TerminalPreferences.newTabKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let model = try WorkspaceModel(storage: storage())

        UserDefaults.standard.removeObject(forKey: key)
        let local = model.newTab()
        XCTAssertTrue(local.isLocal, "By default a new tab is a terminal on this Mac")
        XCTAssertEqual(model.selection, local.id)

        UserDefaults.standard.set(NewTabChoice.form.raw, forKey: key)
        let form = model.newTab()
        XCTAssertFalse(form.isLocal)
        XCTAssertNotNil(form.newConnectionType, "Form opens the New connection form")

        let node = try model.sessionTree.add(name: "web", parent: nil, connection: SavedConnection(host: "web.example", username: "me"))
        UserDefaults.standard.set(NewTabChoice.saved(node).raw, forKey: key)
        let opened = model.newTab()
        opened.savedConnectionTask?.cancel()
        XCTAssertEqual(opened.savedSessionID, node, "A chosen saved session opens in the new tab")
        XCTAssertFalse(opened.isLocal)

        try model.sessionTree.remove(node)
        XCTAssertTrue(model.newTab().isLocal, "A deleted saved session falls back to the default")
        let folder = try model.sessionTree.add(name: "Folder", parent: nil)
        UserDefaults.standard.set(NewTabChoice.saved(folder).raw, forKey: key)
        XCTAssertTrue(model.newTab().isLocal, "A folder is not a connection")
        XCTAssertFalse(model.newConnectionTab().isLocal, "New connection still opens the form")
        for tab in model.tabs where tab.isLocal { await model.closeTab(tab) }
    }

    func testSelectingLocalTabPublishesItsKindBeforeFileSidebarRefresh() async throws {
        let model = try WorkspaceModel(storage: storage())
        var selectedKinds: [Bool] = []
        let selection = model.$selection.dropFirst().sink { id in
            if let tab = model.tabs.first(where: { $0.id == id }) { selectedKinds.append(tab.isLocal) }
        }
        _ = model.addLocalTab()
        XCTAssertEqual(selectedKinds, [true])
        selection.cancel()

        let connectionForm = model.newConnectionTab()
        XCTAssertFalse(connectionForm.isLocal)
        var sidebarRefreshes = 0
        let workspace = model.objectWillChange.sink {
            if model.selected === connectionForm, connectionForm.isLocal { sidebarRefreshes += 1 }
        }
        model.openLocalTerminal(in: connectionForm)
        XCTAssertEqual(model.selection, connectionForm.id)
        XCTAssertTrue(connectionForm.isLocal)
        XCTAssertGreaterThan(sidebarRefreshes, 0, "The existing selection must refresh from remote to local files")
        workspace.cancel()
        await model.closeAll()
    }

    func testWindowsShareSavedSessionsAndKeepIndependentTabs() async throws {
        let first = try WorkspaceModel(storage: storage())
        let second = try WorkspaceModel(sharing: first)
        XCTAssertTrue(first.sessionTree === second.sessionTree)
        XCTAssertTrue(first.vault === second.vault)
        let id = try second.sessionTree.add(name: "Saved from second window", parent: nil, container: .init(tool: .vnc, target: "screen.example"))
        let node = try XCTUnwrap(first.sessionTree.node(id))
        let tab = try XCTUnwrap(first.openSaved(node))
        XCTAssertEqual(first.selection, tab.id)
        XCTAssertFalse(second.tabs.contains { $0.id == tab.id })
        await second.closeWorkspaceWindow(lockingVault: false)
        XCTAssertEqual(first.selected?.desktop?.profile.tool, .vnc)
        XCTAssertFalse(second.restoresWorkspaceTabs)
    }

    func testLockedWorkspaceIgnoresTypingUntilTheOwnerUnlocks() async throws {
        let model = try WorkspaceModel(storage: storage())
        let tab = model.tabs[0]
        model.lockWorkspace()
        XCTAssertTrue(model.workspaceLocked)
        var asked = 0
        model.confirmOwner = { _ in asked += 1; throw WorkspaceError.invalid("no") }
        await model.unlockWorkspace()
        XCTAssertTrue(model.workspaceLocked, "a failed check leaves it locked")
        model.typeTerminal(tab, bytes: Array("rm -rf /\r".utf8))
        XCTAssertNil(tab.riskyCommand)
        model.confirmOwner = { _ in asked += 1 }
        await model.unlockWorkspace()
        XCTAssertFalse(model.workspaceLocked)
        XCTAssertEqual(asked, 2)
    }
}
