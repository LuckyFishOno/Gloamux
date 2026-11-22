import XCTest
import AppKit
@testable import App

/// The operations behind `gloamux`, run the way the running app runs them for a CLI request.
@MainActor final class WorkspaceCommandTests: XCTestCase {
    private var saved: UserDefaults!

    override func setUp() async throws {
        _ = NSApplication.shared
        saved = WorkspaceCommand.preferences
        let name = "gloamux-test-\(UUID().uuidString)"
        WorkspaceCommand.preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    }

    override func tearDown() async throws { WorkspaceCommand.preferences = saved }

    private func workspace() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try WorkspaceModel(storage: root)
    }

    @discardableResult
    private func run(_ argv: [String], _ model: WorkspaceModel, live: Bool = true, windows: [WorkspaceModel] = []) async throws -> Any {
        let data = try await WorkspaceCommand.run(argv, model: model, live: live, windows: windows)
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    func testSettingsAreValidatedAndStoredInTheAppDomain() async throws {
        let model = try workspace()
        let size = try await run(["settings", "set", "terminal.font-size", "15"], model) as? [String: Any]
        XCTAssertEqual(size?["terminal.font-size"] as? Double, 15)
        XCTAssertEqual(WorkspaceCommand.preferences.double(forKey: TerminalPreferences.fontSizeKey), 15)
        try await run(["settings", "set", "terminal.bell", "sound"], model)
        try await run(["settings", "set", "ssh.reconnect", "off"], model)
        try await run(["settings", "set", "terminal.scrollback", "10000"], model)
        XCTAssertEqual(WorkspaceCommand.preferences.integer(forKey: TerminalPreferences.scrollbackKey), 10_000)
        try await run(["settings", "set", "safety.confirm-environments", "production,test"], model)
        let all = try await run(["settings", "list"], model) as? [String: Any]
        XCTAssertEqual(all?["terminal.bell"] as? String, "sound")
        XCTAssertEqual(all?["ssh.reconnect"] as? Bool, false)
        XCTAssertEqual(all?["safety.confirm-environments"] as? [String], ["production", "test"])
        XCTAssertNotNil(all?["language"])

        for bad in [["terminal.font-size", "99"], ["terminal.bell", "loud"], ["ssh.reconnect", "maybe"], ["safety.confirm-environments", "prod"],
                    ["safety.risky-patterns", "[\"(\"]"], ["nonexistent", "1"]] {
            do { try await run(["settings", "set"] + bad, model); XCTFail("Accepted \(bad)") }
            catch is WorkspaceCommand.Usage {} catch WorkspaceError.invalid {}
        }
        let reset = try await run(["settings", "reset", "terminal.bell"], model) as? [String: Any]
        XCTAssertEqual(reset?["terminal.bell"] as? String, "flash")
        do { try await run(["settings", "set", "language", "en"], model, live: false); XCTFail("Language needs the app") }
        catch WorkspaceError.invalid {}
    }

    func testTriggersCanBeAddedEditedDisabledAndRemoved() async throws {
        let model = try workspace()
        let added = try await run(["triggers", "add", "Build done", "BUILD (OK|FAILED)", "sound", "regex", "match-case"], model) as? [String: Any]
        let id = try XCTUnwrap(added?["id"] as? String)
        XCTAssertEqual(added?["regex"] as? Bool, true)
        XCTAssertEqual(added?["caseSensitive"] as? Bool, true)
        try await run(["triggers", "disable", id], model)
        XCTAssertEqual(model.triggers.triggers.first?.enabled, false)
        try await run(["triggers", "edit", id, "Renamed", "done"], model)
        XCTAssertEqual(model.triggers.triggers.first?.name, "Renamed")
        XCTAssertEqual(model.triggers.triggers.first?.pattern, "done")
        do { try await run(["triggers", "add", "Bad", "(", "notify", "regex"], model); XCTFail("Accepted a broken pattern") }
        catch WorkspaceError.invalid {}
        try await run(["triggers", "remove", id], model)
        XCTAssertTrue(model.triggers.triggers.isEmpty)
    }

    func testSessionEnvironmentLayoutAndVaultWithoutTheApp() async throws {
        let model = try workspace()
        let added = try await run(["sessions", "add", "Web", "ssh", "web.example", "tester"], model, live: false) as? [String: Any]
        let id = try XCTUnwrap(added?["id"] as? String)
        try await run(["sessions", "env", id, "production"], model, live: false)
        let shown = try await run(["sessions", "show", "Web"], model, live: false) as? [String: Any]
        XCTAssertEqual(shown?["environment"] as? String, "production")
        try await run(["sessions", "env", "Web", "-"], model, live: false)
        XCTAssertNil(model.sessionTree.nodes.first?.environment)

        let layout = try await run(["layout", "set", "workbench"], model, live: false) as? [String: Any]
        XCTAssertEqual(layout?["layout"] as? String, "workbench")
        XCTAssertEqual(WorkspaceLayout(argument: "mobaxterm"), .transfer, "Names from earlier versions still work")
        XCTAssertEqual(WorkspaceLayout(argument: "xshell"), .terminal)
        XCTAssertEqual(try WorkspaceLayout.load(from: model.storage), .transfer)
        let vault = try await run(["vault", "status"], model, live: false) as? [String: Any]
        XCTAssertEqual(vault?["vault"] as? String, "Not configured")
        do { try await run(["vault", "lock"], model, live: false); XCTFail("Locking needs the app") } catch WorkspaceError.invalid {}
    }

    func testTabsFromEveryWindowCanBeListedRenamedAndRead() async throws {
        let first = try workspace()
        let second = try WorkspaceModel(sharing: first)
        let tab = second.tabs[0]
        tab.feed("hello from the second window\r\n")
        do { try await run(["tabs", "list"], first, live: false); XCTFail("Tabs need the app") } catch WorkspaceError.invalid {}

        let listed = try await run(["tabs", "list"], first, windows: [first, second]) as? [[String: Any]]
        XCTAssertEqual(listed?.count, 2)
        XCTAssertEqual(listed?.last?["id"] as? String, tab.id.uuidString)
        XCTAssertEqual(listed?.last?["window"] as? Int, 2)

        try await run(["tabs", "rename", tab.id.uuidString, "Build box"], first, windows: [first, second])
        XCTAssertEqual(tab.title, "Build box")
        XCTAssertTrue(tab.renamed)
        let read = try await run(["tabs", "read", tab.id.uuidString], first, windows: [first, second]) as? [String: Any]
        XCTAssertTrue((read?["text"] as? String)?.contains("hello from the second window") == true)
        do { try await run(["tabs", "send", tab.id.uuidString, "ls"], first, windows: [first, second]); XCTFail("Not ready") }
        catch WorkspaceError.invalid {}
        do { try await run(["tabs", "rename", UUID().uuidString, "x"], first, windows: [first, second]); XCTFail("Unknown tab") }
        catch WorkspaceError.invalid {}
    }

    func testMultiExecAndTheTunnelListCoverEveryWindow() async throws {
        let first = try workspace()
        let second = try WorkspaceModel(sharing: first)
        let local = second.tabs[0]
        let turnedOn = try await run(["tabs", "multiexec", local.id.uuidString, "on"], first, windows: [first, second]) as? [String: Any]
        XCTAssertEqual(turnedOn?["multiExec"] as? Bool, true)
        XCTAssertTrue(second.multiExec)
        XCTAssertFalse(first.multiExec, "MultiExec belongs to the tab's own window")
        let shown = try await run(["tabs", "show", local.id.uuidString], first, windows: [first, second]) as? [String: Any]
        XCTAssertEqual(shown?["multiExec"] as? Bool, true)
        try await run(["tabs", "multiexec", local.id.uuidString, "off"], first, windows: [first, second])
        XCTAssertFalse(second.multiExec)
        do { try await run(["tabs", "multiexec", local.id.uuidString, "maybe"], first, windows: [first, second]); XCTFail("Bad switch") }
        catch is WorkspaceCommand.Usage {}

        // A blank new-connection tab, a local terminal, and an SSH tab: only the SSH session counts once connected.
        let ssh = second.addTab()
        ssh.host = "127.0.0.1"
        var tunnels = try await run(["forwards", "live-list"], first, windows: [first, second]) as? [[String: Any]]
        XCTAssertEqual(tunnels?.count, 0, "Tabs still showing the connection form are not sessions")
        ssh.connected = true
        tunnels = try await run(["forwards", "live-list"], first, windows: [first, second]) as? [[String: Any]]
        XCTAssertEqual(tunnels?.map { $0["id"] as? String }, [ssh.id.uuidString])
        XCTAssertEqual(tunnels?.first?["window"] as? Int, 2)
        XCTAssertEqual((tunnels?.first?["forwards"] as? [Any])?.count, 0)
        do { try await run(["forwards", "live-list"], first, live: false); XCTFail("Live forwards need the app") } catch WorkspaceError.invalid {}
        ssh.connected = false
    }

    func testRiskyCommandFromTheCommandLineWaitsForConfirmation() async throws {
        let model = try workspace()
        let tab = model.tabs[0]
        tab.terminalReady = true
        tab.environment = .production
        let result = try await run(["tabs", "run", tab.id.uuidString, "rm -rf /srv/data"], model) as? [String: Any]
        XCTAssertEqual(result?["status"] as? String, "waiting for confirmation in Gloamux")
        XCTAssertEqual(tab.riskyCommand?.command, "rm -rf /srv/data")

        tab.riskyCommand = nil
        tab.readOnly = true
        do { try await run(["tabs", "run", tab.id.uuidString, "ls"], model); XCTFail("Read-only") } catch WorkspaceError.invalid {}
        XCTAssertNil(tab.riskyCommand)

        tab.readOnly = false
        let command = try await run(["commands", "add", "Wipe", "rm -rf /srv/data"], model) as? [String: Any]
        let id = try XCTUnwrap(command?["id"] as? String)
        try await run(["commands", "run", id, tab.id.uuidString], model)
        XCTAssertEqual(tab.riskyCommand?.command, "rm -rf /srv/data")
    }

    func testRunbooksHostHistoryAndQuickConnect() async throws {
        let model = try workspace()
        let created = try await run(["runbooks", "create", "Deploy"], model, live: false) as? [String: Any]
        XCTAssertEqual(created?["name"] as? String, "Deploy.md")
        let listed = try await run(["runbooks", "list"], model, live: false) as? [[String: Any]]
        XCTAssertEqual(listed?.first?["blocks"] as? Int, 2)
        let shown = try await run(["runbooks", "show", "Deploy"], model, live: false) as? [String: Any]
        XCTAssertEqual((shown?["blocks"] as? [[String: Any]])?.first?["code"] as? String, "uname -a")
        do { try await run(["runbooks", "run", "Deploy", UUID().uuidString], model, live: false); XCTFail("Running needs the app") }
        catch WorkspaceError.invalid {}
        let tab = model.tabs[0]
        tab.terminalReady = true
        tab.environment = .production
        do { try await run(["runbooks", "run", "Deploy", tab.id.uuidString], model); XCTFail("Production runbooks are reviewed in Gloamux") }
        catch WorkspaceError.invalid {}

        let history = try await run(["hosts", "history"], model, live: false) as? [Any]
        XCTAssertEqual(history?.count, 0)
        do { try await run(["tabs", "connect", "not a target"], model); XCTFail("Accepted a bad target") } catch is WorkspaceCommand.Usage {}
        let before = model.tabs.count
        let opened = try await run(["tabs", "connect", "tester@127.0.0.1:9"], model) as? [String: Any]
        XCTAssertEqual(model.tabs.count, before + 1)
        XCTAssertEqual(model.tabs.last?.id.uuidString, opened?["id"] as? String)
        XCTAssertEqual(model.tabs.last?.host, "127.0.0.1")
        await model.closeAll()
    }

    func testOtherConnectionsAreCreatedAndEditedLikeTheForm() async throws {
        let model = try workspace()
        let folder = try await run(["sessions", "mkdir", "Lab"], model) as? [String: String]
        let added = try await run(["sessions", "add-other", "Switch", "serial", "/dev/cu.usbserial-1", "baud=115200", "data-bits=7",
                                   "parity=even", "stop-bits=2", "flow=dtr-dsr", "encoding=big5", "folder=Lab"], model) as? [String: String]
        let id = try XCTUnwrap(added?["id"])
        let node = try XCTUnwrap(model.sessionTree.node(try XCTUnwrap(UUID(uuidString: id))))
        XCTAssertEqual(node.parent?.uuidString, folder?["id"])
        XCTAssertEqual(node.container?.serialSettings, SerialPort.Settings(baud: 115200, format: "7E2", flow: .dtrDsr))
        XCTAssertEqual(node.container?.encoding, .big5)
        let shown = try await run(["sessions", "show", "Switch"], model) as? [String: Any]
        XCTAssertEqual(shown?["parity"] as? String, "even")
        XCTAssertEqual(shown?["flow"] as? String, "dtr-dsr")
        XCTAssertEqual(shown?["encoding"] as? String, "big5")

        try await run(["sessions", "edit-other", "Switch", "parity=-", "flow=xon-xoff", "encoding=-", "target=/dev/cu.usbmodem2"], model)
        let edited = try XCTUnwrap(model.sessionTree.node(try XCTUnwrap(UUID(uuidString: id)))?.container)
        XCTAssertEqual(edited.serialSettings.format, "7N2")
        XCTAssertEqual(edited.serialSettings.flow, .software)
        XCTAssertNil(edited.encoding)
        XCTAssertEqual(edited.target, "/dev/cu.usbmodem2")

        try await run(["sessions", "add-other", "Pod", "kubectl", "web-0", "context=prod", "namespace=shop", "container=app"], model)
        let pod = try XCTUnwrap(model.sessionTree.nodes.first { $0.name == "Pod" }?.container)
        XCTAssertEqual(pod.commandLine, "kubectl --context prod -n shop exec -it web-0 -c app -- /bin/sh")
        try await run(["sessions", "add-other", "Old router", "telnet", "10.0.0.1", "port=2323"], model)
        XCTAssertEqual(model.sessionTree.nodes.first { $0.name == "Old router" }?.container?.effectivePort, 2323)

        for bad in [["Bad", "serial", "/dev/cu.x", "baud=12345"], ["Bad", "serial", "/dev/cu.x", "region=us"],
                    ["Bad", "rdp", "host"], ["Bad", "serial", "/etc/passwd"], ["Bad", "docker", "web", "shell"]] {
            do { try await run(["sessions", "add-other"] + bad, model); XCTFail("\(bad) was accepted") } catch {}
        }
        let ports = try await run(["sessions", "serial-ports"], model)
        XCTAssertNotNil(ports as? [String])
    }
}
