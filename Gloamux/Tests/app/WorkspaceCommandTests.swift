import XCTest
import AppKit
@testable import App
import GloamuxNetwork

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

    func testNewTabSettingTakesLocalFormOrASavedSession() async throws {
        let model = try workspace()
        let get = try await run(["settings", "get", "terminal.new-tab"], model) as? [String: Any]
        XCTAssertEqual(get?["terminal.new-tab"] as? String, "local", "The default is a local terminal")
        let web = try model.sessionTree.add(name: "web", parent: nil, connection: SavedConnection(host: "web.test", username: "u"))
        let byName = try await run(["settings", "set", "terminal.new-tab", "web"], model) as? [String: Any]
        XCTAssertEqual(byName?["terminal.new-tab"] as? String, web.uuidString, "A name is stored as the session's ID")
        try await run(["settings", "set", "terminal.new-tab", web.uuidString.lowercased()], model)
        XCTAssertEqual(WorkspaceCommand.preferences.string(forKey: TerminalPreferences.newTabKey), web.uuidString)
        try await run(["settings", "set", "terminal.new-tab", "form"], model)
        XCTAssertEqual(WorkspaceCommand.preferences.string(forKey: TerminalPreferences.newTabKey), "form")

        let folder = try model.sessionTree.add(name: "Folder", parent: nil)
        _ = try model.sessionTree.add(name: "web", parent: folder, connection: SavedConnection(host: "web2.test", username: "u"))
        for bad in ["web", "Folder", folder.uuidString, "nowhere"] {
            do { try await run(["settings", "set", "terminal.new-tab", bad], model); XCTFail("Accepted \(bad)") }
            catch is WorkspaceCommand.Usage {} catch WorkspaceError.invalid {}
        }
        let reset = try await run(["settings", "reset", "terminal.new-tab"], model) as? [String: Any]
        XCTAssertEqual(reset?["terminal.new-tab"] as? String, "local")
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
        // The empty rows below the cursor are not output: LINES counts back from the last printed line.
        tab.feed("second line\r\n")
        let tail = try await run(["tabs", "read", tab.id.uuidString, "1"], first, windows: [first, second]) as? [String: Any]
        XCTAssertEqual(tail?["text"] as? String, "second line")
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

    func testConnectionOptionsMatchTheEditForm() async throws {
        let model = try workspace()
        try await run(["sessions", "add", "Bastion", "ssh", "bastion.example.com", "ops"], model)
        try await run(["sessions", "add", "Web", "ssh", "web.example.com", "ops", "2222"], model)
        try await run(["sessions", "options", "Web", "jump=Bastion", "startup=cd /srv\\nls", "x11=on", "forward-agent=on",
                       "open-files=on", "files=sftp", "encoding=big5"], model)
        var web = try XCTUnwrap(model.sessionTree.nodes.first { $0.name == "Web" }?.connection)
        XCTAssertEqual(web.jumpSessionID, model.sessionTree.nodes.first { $0.name == "Bastion" }?.id)
        XCTAssertEqual(web.startupCommands, "cd /srv\nls")
        XCTAssertEqual(web.forwardsX11, true)
        XCTAssertEqual(web.forwardsAgent, true)
        XCTAssertEqual(web.opensFiles, true)
        XCTAssertEqual(web.fileProtocol, .sftp)
        XCTAssertEqual(web.encoding, .big5)
        let shown = try await run(["sessions", "show", "Web"], model) as? [String: Any]
        XCTAssertEqual(shown?["jump"] as? String, "Bastion")
        XCTAssertEqual(shown?["x11"] as? Bool, true)

        // A loop through jump hosts, and a proxy beside a jump host, are refused as the form refuses them.
        do { try await run(["sessions", "options", "Bastion", "jump=Web"], model); XCTFail("A jump loop was accepted") } catch {}
        do { try await run(["sessions", "options", "Web", "proxy=http", "proxy-host=proxy.example.com"], model); XCTFail("Proxy and jump host were both set") } catch {}
        try await run(["sessions", "options", "Web", "jump=-", "proxy=http", "proxy-host=proxy.example.com", "startup=-", "x11=off", "encoding=utf8"], model)
        web = try XCTUnwrap(model.sessionTree.nodes.first { $0.name == "Web" }?.connection)
        XCTAssertEqual(web.proxy, ProxyConfiguration(kind: .http, host: "proxy.example.com", port: 1080))
        XCTAssertNil(web.jumpSessionID)

        // Several jump hosts, first dialed first; a repeated one is refused.
        try await run(["sessions", "add", "Inner", "ssh", "inner.example.com", "ops"], model)
        try await run(["sessions", "options", "Web", "jump=Bastion,Inner"], model)
        web = try XCTUnwrap(model.sessionTree.nodes.first { $0.name == "Web" }?.connection)
        let ids = ["Bastion", "Inner"].compactMap { name in model.sessionTree.nodes.first { $0.name == name }?.id }
        XCTAssertEqual(web.jumpPath, ids)
        XCTAssertNil(web.proxyHost, "The proxy belongs on the jump host")
        let listed = try await run(["sessions", "show", "Web"], model) as? [String: Any]
        XCTAssertEqual(listed?["jump"] as? String, "Bastion,Inner")
        do { try await run(["sessions", "options", "Web", "jump=Bastion,Bastion"], model); XCTFail("A repeated hop was accepted") } catch {}
        try await run(["sessions", "options", "Web", "jump=-"], model)
        web = try XCTUnwrap(model.sessionTree.nodes.first { $0.name == "Web" }?.connection)
        XCTAssertTrue(web.jumpPath.isEmpty)
        XCTAssertNil(web.earlierJumpSessionIDs)
        XCTAssertNil(web.startupCommands)
        XCTAssertNil(web.forwardsX11)
        XCTAssertNil(web.encoding)
        try await run(["sessions", "options", "Web", "proxy=-"], model)
        XCTAssertNil(model.sessionTree.nodes.first { $0.name == "Web" }?.connection?.proxyHost)

        // Whether a session asks on every connection needs the owner, in the running app.
        do { try await run(["sessions", "options", "Web", "confirm=on"], model, live: false); XCTFail("confirm changed without the app") } catch {}
        do { try await run(["sessions", "options", "Web", "bogus=1"], model); XCTFail("An unknown option was accepted") } catch {}
        try await run(["sessions", "add", "Files", "ftp", "ftp.example.com", "-"], model)
        do { try await run(["sessions", "options", "Files", "x11=on"], model); XCTFail("FTP took an SSH option") } catch {}
    }

    func testRemoteDesktopOptionsAndGatewayMatchTheForm() async throws {
        let model = try workspace()
        try await run(["sessions", "add", "Bastion", "ssh", "bastion.example.com", "ops"], model)
        try await run(["sessions", "add", "Desk", "rdp", "10.0.0.5", "admin"], model)
        try await run(["sessions", "edit-other", "Desk", "gateway=Bastion", "resolution=1920x1080", "retina=on", "quality=low", "clipboard=off"], model)
        var desk = try XCTUnwrap(model.sessionTree.nodes.first { $0.name == "Desk" }?.container)
        XCTAssertEqual(desk.gatewaySessionID, model.sessionTree.nodes.first { $0.name == "Bastion" }?.id)
        XCTAssertEqual(desk.desktopResolution, DesktopResolution(width: 1920, height: 1080))
        XCTAssertEqual(desk.desktopQuality, .low)
        XCTAssertEqual(desk.sharesClipboard, false)
        let shown = try await run(["sessions", "show", "Desk"], model) as? [String: Any]
        XCTAssertEqual(shown?["gateway"] as? String, "Bastion")
        XCTAssertEqual(shown?["resolution"] as? String, "1920x1080")
        // Retina applies only when the desktop follows the window.
        XCTAssertEqual(shown?["retina"] as? Bool, false)
        try await run(["sessions", "edit-other", "Desk", "gateway=-", "resolution=fit", "quality=lan", "clipboard=-"], model)
        desk = try XCTUnwrap(model.sessionTree.nodes.first { $0.name == "Desk" }?.container)
        XCTAssertNil(desk.gatewaySessionID)
        XCTAssertNil(desk.desktopResolution)
        XCTAssertNil(desk.desktopQuality)
        XCTAssertNil(desk.sharesClipboard)
        for bad in ["resolution=1000x1000", "quality=best", "retina=maybe", "gateway=Desk"] {
            do { try await run(["sessions", "edit-other", "Desk", bad], model); XCTFail("\(bad) was accepted") } catch {}
        }
        try await run(["sessions", "add", "Mac", "vnc", "mac.local", "-"], model)
        do { try await run(["sessions", "edit-other", "Mac", "quality=low"], model); XCTFail("VNC took an RDP setting") } catch {}
        XCTAssertEqual(DesktopResolution("2560x1440"), DesktopResolution(width: 2560, height: 1440))
        XCTAssertNil(DesktopResolution("1234x567"))
    }

    func testHostKeysRecordingsAndAgentHistoryMatchTheirWindows() async throws {
        let model = try workspace()
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        try model.knownHosts.trust(endpoint: "[web.example.com]:22", key: key)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-known-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try await run(["hosts", "export", file.path], model)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "web.example.com " + key + "\n")
        try await run(["hosts", "remove", "[web.example.com]:22"], model)
        XCTAssertTrue(model.knownHosts.trusted.isEmpty)
        XCTAssertFalse(model.knownHosts.history.isEmpty)
        try await run(["hosts", "clear-history"], model)
        XCTAssertTrue(model.knownHosts.history.isEmpty)
        do { try await run(["hosts", "discover", "nowhere"], model); XCTFail("An unknown source was accepted") } catch {}

        let folder = model.recordings.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cast = folder.appendingPathComponent("2026-11-23 10.00.00 web.cast")
        try Data("{\"version\":2,\"width\":80,\"height\":24,\"title\":\"web\",\"timestamp\":1795000000,\"duration\":1.5}\n[0.5,\"o\",\"hi\"]\n".utf8).write(to: cast)
        let listed = try await run(["recordings", "list"], model) as? [[String: Any]]
        XCTAssertEqual(listed?.first?["file"] as? String, cast.lastPathComponent)
        XCTAssertEqual(listed?.first?["title"] as? String, "web")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-cast-\(UUID()).cast")
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        try await run(["recordings", "export", cast.lastPathComponent, copy.path], model)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: cast))
        do { try await run(["recordings", "export", cast.lastPathComponent, copy.path], model); XCTFail("An existing file was overwritten") } catch {}
        try await run(["recordings", "remove", cast.lastPathComponent], model)
        XCTAssertTrue(model.recordings.saved.isEmpty)

        model.agents.record(client: "test", action: "Listed sessions", outcome: "0 shown")
        XCTAssertFalse(model.agents.history.isEmpty)
        try await run(["agents", "clear-history"], model)
        XCTAssertTrue(model.agents.history.isEmpty)
    }
}
