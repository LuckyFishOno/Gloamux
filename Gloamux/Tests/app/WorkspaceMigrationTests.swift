import XCTest
@testable import App

@MainActor final class WorkspaceMigrationTests: XCTestCase {
    func testPreviewThenImportPersistsNestedCatalogWithoutCredentialsOrUnsupportedRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sessions")
        let devices = source.appendingPathComponent("Factory/Devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Empty"), withIntermediateDirectories: false)
        func write(_ name: String, protocolName: String = "SSH", port: String = "22", options: String = "") throws {
            let body = "[SessionInfo]\r\nHost=node.example\r\nUserName=ops\r\nProtocol=\(protocolName)\r\nPort=\(port)\r\nPassword=fixture-secret\r\n\(options)"
            try Data(body.utf8).write(to: devices.appendingPathComponent(name))
        }
        try write("Switch10.xsh", port: "2222", options: "AuthMethod=Public Key\r\n")
        try write("Switch10.xfp", protocolName: "SFTP")
        try write("Old.xsh", protocolName: "TELNET")
        try write("Invalid.xsh", port: "70000")
        try write("Private.xsh", options: "Proxy=Corporate\r\n")
        try FileManager.default.createSymbolicLink(at: devices.appendingPathComponent("Linked.xsh"),
                                                   withDestinationURL: devices.appendingPathComponent("Switch10.xsh"))

        let catalog = root.appendingPathComponent("sessions.json")
        let tree = try SessionTreeStore(url: catalog)
        let existing = try tree.add(name: "Sessions", parent: nil)
        let before = try Data(contentsOf: catalog)
        let preview = try ProfileImport.scan(source)
        XCTAssertEqual(preview.entries.count, 2)
        XCTAssertEqual(preview.skipped.count, 4)
        XCTAssertEqual(preview.entries.first { $0.components.last == "Switch10.xsh" }?.notes.count, 1)
        XCTAssertEqual(try Data(contentsOf: catalog), before)

        XCTAssertThrowsError(try tree.importProfiles(preview, name: "Sessions", parent: nil))
        XCTAssertEqual(try Data(contentsOf: catalog), before)

        let imported = try tree.importProfiles(preview, name: tree.availableImportName(preview.name, parent: nil), parent: nil)
        let reloaded = try SessionTreeStore(url: catalog)
        XCTAssertEqual(reloaded.node(existing)?.name, "Sessions")
        XCTAssertEqual(reloaded.node(imported)?.name, "Sessions (2)")
        XCTAssertTrue(reloaded.children(of: imported).contains { $0.name == "Empty" && $0.isFolder })
        let sessions = reloaded.connections(in: imported)
        XCTAssertEqual(sessions.map(\.name), ["Switch10", "Switch10 (2)"])
        let folder = try XCTUnwrap(reloaded.node(sessions.first?.parent))
        XCTAssertEqual(folder.name, "Devices")
        XCTAssertEqual(reloaded.node(folder.parent)?.name, "Factory")
        XCTAssertEqual(sessions.compactMap { $0.connection?.port }.sorted(), [22, 2222])
        XCTAssertEqual(sessions.first { $0.connection?.port == 22 }?.connection?.opensFiles, true)
        XCTAssertFalse(String(decoding: try Data(contentsOf: catalog), as: UTF8.self).contains("fixture-secret"))

        let session = try XCTUnwrap(sessions.first)
        try reloaded.updateConnection(session.id, name: "Edited", connection: SavedConnection(
            host: "replacement.test", username: "ops", proxyHost: "proxy.test", proxyPort: 1080,
            identityPath: "/tmp/user-chosen-ed25519"
        ))
        let edited = try XCTUnwrap(try SessionTreeStore(url: catalog).node(session.id))
        XCTAssertEqual(edited.name, "Edited")
        XCTAssertEqual(edited.connection?.identityPath, "/tmp/user-chosen-ed25519")
        XCTAssertEqual(edited.parent, session.parent)
    }

    func testXshellBackupImportsItsSessionsAndAMissingUserNameTakesTheMacUser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-xts-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("content")
        for folder in ["Xshell/Lab", "Xftp", "xsl/ColorScheme Files"] {
            try FileManager.default.createDirectory(at: content.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // Xshell leaves UserName empty when it asks for the name on connecting.
        try Data("[CONNECTION]\r\nHost=192.0.2.10\r\nPort=22\r\nProtocol=SSH\r\n[CONNECTION:AUTHENTICATION]\r\nUserName=\r\nPassword=\r\n".utf8)
            .write(to: content.appendingPathComponent("Xshell/Lab/edge.xsh"))
        try Data("[SessionInfo]\r\nHost=files.example\r\nUserName=ops\r\nProtocol=SFTP\r\n".utf8)
            .write(to: content.appendingPathComponent("Xftp/files.xfp"))
        try Data("[Names]\r\n".utf8).write(to: content.appendingPathComponent("xsl/ColorScheme Files/Dark.scs"))
        let archive = root.appendingPathComponent("xbackup.xts")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = content
        zip.arguments = ["-qr", archive.path, "."]
        try zip.run(); zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let draft = try ProfileImport.scan(archive, localUser: "me")
        XCTAssertEqual(draft.name, "xbackup")
        XCTAssertEqual(draft.folders, [["Lab"]], "The backup's own Xshell folder is not a level of its own")
        let edge = try XCTUnwrap(draft.entries.first { $0.path == "Lab / edge.xsh" })
        XCTAssertEqual(edge.connection?.host, "192.0.2.10")
        XCTAssertEqual(edge.connection?.username, "me")
        XCTAssertTrue(edge.notes.contains { $0.contains("asks for the user name") })
        let files = try XCTUnwrap(draft.entries.first { $0.path == "files.xfp" })
        XCTAssertEqual(files.connection?.opensFiles, true)
        XCTAssertEqual(files.connection?.username, "ops")
        XCTAssertTrue(files.notes.isEmpty)
        XCTAssertEqual(draft.entries.count, 2, "Color schemes and other backup files are not sessions")
        XCTAssertTrue(draft.skipped.isEmpty)

        let empty = root.appendingPathComponent("empty.xts")
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        other.currentDirectoryURL = content
        other.arguments = ["-qr", empty.path, "xsl"]
        try other.run(); other.waitUntilExit()
        XCTAssertThrowsError(try ProfileImport.scan(empty)) { error in
            XCTAssertEqual(error.localizedDescription, "No Xshell sessions were found in this backup.")
        }
        try Data("not a zip".utf8).write(to: root.appendingPathComponent("broken.xts"))
        XCTAssertThrowsError(try ProfileImport.scan(root.appendingPathComponent("broken.xts")))
    }

    func testQuickConnectTargetsAndMalformedInput() {
        XCTAssertEqual(SavedConnection.quickTarget("ssh ops@node.test:2201"),
                       SavedConnection(host: "node.test", port: 2201, username: "ops"))
        XCTAssertEqual(SavedConnection.quickTarget("ops@[2001:db8::1]"),
                       SavedConnection(host: "2001:db8::1", username: "ops"))
        for invalid in ["ops@", "ops@host:", "a@b@c", "ops@[]", "ops@host:hello", "ops@host:0", "ops@host:65536",
                        "-x@host", "ops@host/dir", "ssh -p 22 ops@host", "ops@[::1]extra"] {
            XCTAssertNil(SavedConnection.quickTarget(invalid), invalid)
        }
    }

    func testBracketedPasteTracksTerminalModeAndCannotCloseItsOwnBracket() {
        let tab = SessionTab()
        tab.screen.feed("\u{1b}[?2004h")
        XCTAssertTrue(tab.screen.bracketedPaste)
        let wrapped = TerminalKeyboard.pasteBytes("first\r\nsecond\u{1b}[201~", bracketed: tab.screen.bracketedPaste)
        XCTAssertEqual(wrapped, Array("\u{1b}[200~first\rsecond[201~\u{1b}[201~".utf8))
        tab.screen.feed("\u{1b}[?2004l")
        XCTAssertFalse(tab.screen.bracketedPaste)
        XCTAssertEqual(TerminalKeyboard.pasteBytes("first\nsecond", bracketed: false), Array("first\rsecond".utf8))
    }
}
