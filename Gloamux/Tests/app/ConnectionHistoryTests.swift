import XCTest
@testable import App

@MainActor final class ConnectionHistoryTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-history-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testARecordFromStartToEnd() throws {
        let file = try scratch().appendingPathComponent("history.jsonl")
        let history = ConnectionHistory(url: file)
        let key = "shortkey"
        let id = try XCTUnwrap(history.begin(name: "Gateway", kind: "sftp", host: "192.0.2.10", port: 4997, user: key, secret: key))
        history.add(.connected, to: id)
        history.add(.downloaded, to: id, detail: "/tmp/a.csv", bytes: 12)
        history.add(.transferFailed, to: id, detail: "refused \(key) password=hunter22")
        history.add(.lost, to: id)
        history.add(.closed, to: id)

        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(stored.contains(key))
        XCTAssertFalse(stored.contains("hunter22"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)

        let again = ConnectionHistory(url: file)
        again.reload()
        let record = try XCTUnwrap(again.records.first)
        XCTAssertEqual(record.events.map(\.kind), [.connected, .downloaded, .transferFailed, .lost])
        XCTAssertEqual(record.state(open: false), .lost)
        XCTAssertEqual(record.transfers.first?.bytes, 12)
        XCTAssertTrue(again.report(record).contains("/tmp/a.csv"))
    }

    /// Commands append while the app has the workspace open, and a rewrite keeps their lines.
    func testTwoWritersAndRemoving() throws {
        let file = try scratch().appendingPathComponent("history.jsonl")
        let app = ConnectionHistory(url: file), command = ConnectionHistory(url: file)
        let open = try XCTUnwrap(app.begin(name: "A", kind: "ssh", host: "a", port: 22, user: "u"))
        let other = try XCTUnwrap(command.begin(name: "B", kind: "sftp", host: "b", port: 22, user: "u", source: "cli"))
        command.add(.closed, to: other)
        app.reload()
        XCTAssertEqual(app.records.map(\.name), ["B", "A"])
        XCTAssertEqual(app.records[1].state(open: true), .connecting)
        // What was open when its process stopped has no known end.
        XCTAssertEqual(app.records[1].state(open: false), .unknown)
        try app.clear()
        XCTAssertEqual(app.records.map(\.id), [open])
        app.add(.closed, to: open)
        command.reload()
        XCTAssertEqual(command.records.map(\.id), [open])
        try command.remove([open])
        app.reload()
        XCTAssertEqual(app.records, [])
    }

    func testCommandsRouteAndChanges() throws {
        let history = ConnectionHistory(url: try scratch().appendingPathComponent("history.jsonl"))
        let target = SavedConnection(host: "web", port: 22, username: "deploy")
        let hop = SavedConnection(host: "bastion", port: 2222, username: "ops", proxyHost: "127.0.0.1", proxyPort: 1080)
        let id = try XCTUnwrap(history.begin(name: "Web", kind: "ssh", host: "web", port: 22, user: "deploy"))
        history.addRoute(to: id, target: target, hops: [hop], names: ["Bastion"])
        history.add(.connected, to: id)
        history.add(.command, to: id, detail: "df -h")
        for secret in ["mysql -u root -phunter22 app", "deploy --password hunter22", "curl -u me:hunter22 https://x", "git clone https://me:hunter22@x/r",
                       "sshpass -p hunter22 ssh x", "export DB_PASSWORD='hunter22'", "tool --api-key=hunter22"] {
            history.add(.command, to: id, detail: secret)
        }
        history.add(.renamed, to: id, detail: "/a → /b")
        history.add(.forwardStarted, to: id, detail: "127.0.0.1:8080 → db:5432")
        history.add(.closed, to: id)
        XCTAssertFalse(try String(contentsOf: history.url, encoding: .utf8).contains("hunter22"))

        history.reload()
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.route, ["SOCKS5 127.0.0.1:1080", "Bastion (ops@bastion:2222)"])
        XCTAssertEqual(record.commands.count, 8)
        XCTAssertEqual(record.state(open: false), .closed)
        XCTAssertEqual(history.matching("df -h").count, 1)
        XCTAssertEqual(history.matching("bastion").count, 1)
        XCTAssertEqual(history.json(record)["commands"] as? Int, 8)
        XCTAssertEqual(history.json(record)["route"] as? [String], record.route)
        XCTAssertTrue(history.csv([record]).contains("Bastion (ops@bastion:2222)"))
        XCTAssertTrue(history.report(record).contains("command  df -h"))

        let direct = try XCTUnwrap(history.begin(name: "Web", kind: "ssh", host: "web", port: 22, user: "deploy"))
        history.addRoute(to: direct, target: target, hops: [], names: [])
        XCTAssertEqual(history.records.first?.route, [])
        // Records made before routes were kept say nothing about them.
        _ = history.begin(name: "Old", kind: "ssh", host: "web", port: 22, user: "deploy")
        XCTAssertNil(history.records.first?.route)
    }

    func testSearchAndTheSessionLogView() throws {
        let model = try WorkspaceModel(storage: scratch())
        let id = try XCTUnwrap(model.history.begin(name: "Gateway", kind: "sftp", host: "192.0.2.10", port: 4997, user: "u"))
        model.history.add(.downloaded, to: id, detail: "/tmp/report.csv")
        _ = model.history.begin(name: "Other", kind: "ssh", host: "192.0.2.11", port: 22, user: "u")
        model.history.reload()
        XCTAssertEqual(model.history.matching("").count, 2)
        XCTAssertEqual(model.history.matching("gateway REPORT").map(\.id), [id])
        XCTAssertEqual(model.history.matching("gateway other").count, 0)

        let tab = model.addTab()
        model.showConnectionHistory(search: "Gateway")
        XCTAssertEqual(model.workspaceMode, .log)
        XCTAssertEqual(model.history.search, "Gateway")
        // Choosing a tab leaves the log, and opening the log again starts with everything.
        model.selectTab(tab.id)
        XCTAssertEqual(model.workspaceMode, .terminal)
        model.showConnectionHistory()
        XCTAssertEqual(model.history.search, "")
        model.openFileTransfer(for: nil)
        XCTAssertEqual(model.workspaceMode, .files)
    }

    func testDamagedLinesAndLogsOutsideTheFolder() throws {
        let root = try scratch()
        let file = root.appendingPathComponent("history.jsonl")
        let history = ConnectionHistory(url: file)
        let id = try XCTUnwrap(history.begin(name: "=cmd()", kind: "ssh", host: "h", port: 22, user: "u"))
        let outside = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        history.add(.log, to: id, detail: outside.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("not json\n{\"id\":1}\n".utf8)); try handle.close()
        history.reload()
        let record = try XCTUnwrap(history.records.first)
        XCTAssertNil(history.logText(record))
        XCTAssertTrue(history.csv(history.records).contains("\"'=cmd()\""))

        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: logs.appendingPathComponent("a.log"))
        history.add(.log, to: id, detail: logs.appendingPathComponent("a.log").path)
        XCTAssertEqual(history.logText(try XCTUnwrap(history.records.first)), "hello")
    }
}
