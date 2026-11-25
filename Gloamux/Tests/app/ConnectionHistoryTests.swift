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
