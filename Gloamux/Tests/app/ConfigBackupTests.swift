import XCTest
import AppKit
import Darwin
import MasterPassword
@testable import App

/// Export and Import of all settings, and the serial line settings of the Other connection form.
@MainActor final class ConfigBackupTests: XCTestCase {
    private var saved: UserDefaults!

    override func setUp() async throws {
        _ = NSApplication.shared
        saved = WorkspaceCommand.preferences
        let name = "gloamux-test-\(UUID().uuidString)"
        WorkspaceCommand.preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    }

    override func tearDown() async throws { WorkspaceCommand.preferences = saved }

    private func folder() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-backup-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A workspace with a session, a runbook, a setting, a vault that travels sealed, and a saved sign-in that stays.
    private func source() throws -> URL { try sourceWorkspace().storage }

    private func sourceWorkspace() throws -> WorkspaceModel {
        let root = folder()
        let model = try WorkspaceModel(storage: root)
        try model.sessionTree.add(name: "Build server", parent: nil, connection: SavedConnection(host: "build.test", username: "alice"))
        let runbooks = root.appendingPathComponent("runbooks", isDirectory: true)
        try FileManager.default.createDirectory(at: runbooks, withIntermediateDirectories: true)
        try Data("# Deploy\n".utf8).write(to: runbooks.appendingPathComponent("Deploy.md"))
        let vault = try MasterVault.create(password: "master-secret", iterations: 100)
            .storing(id: "alice@[build.test]:22", secret: "TOPSECRET-VAULT")
        try vault.serialized().write(to: root.appendingPathComponent("password-vault.json"))
        try Data(#"{"secret":"TOPSECRET-SIGNIN"}"#.utf8).write(to: root.appendingPathComponent("saved-sign-ins.json"))
        WorkspaceCommand.preferences.set(15.0, forKey: TerminalPreferences.fontSizeKey)
        return model
    }

    func testExportWritesAChecksumAndLeavesPasswordsOut() throws {
        let file = folder().appendingPathComponent("all.gloamuxconfig")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let checksum = try ConfigBackup.export(storage: try source(), to: file)
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("build.test") && text.contains("alice"), "accounts are included")
        XCTAssertTrue(text.contains("# Deploy"))
        XCTAssertFalse(text.contains("TOPSECRET"), "no password in the clear, and no password remembered on this Mac")
        XCTAssertFalse(text.contains("master-secret"), "the master password is never written")
        XCTAssertEqual(try String(contentsOf: checksum, encoding: .utf8), "\(ConfigBackup.sha256(data))  all.gloamuxconfig\n")
        let backup = try ConfigBackup.read(file)
        XCTAssertTrue(backup.verified)
        let vault = try MasterVault.load(try XCTUnwrap(backup.vault, "the sealed vault is included"))
        XCTAssertThrowsError(try vault.unlocked(password: "wrong"))
        XCTAssertEqual(try vault.unlocked(password: "master-secret").retrieve(id: "alice@[build.test]:22"), "TOPSECRET-VAULT")
    }

    func testABackupWithoutAVaultKeepsTheCurrentOneAndADamagedVaultIsRefused() throws {
        let file = folder().appendingPathComponent("all.gloamuxconfig")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = try source()
        try FileManager.default.removeItem(at: source.appendingPathComponent("password-vault.json"))
        try ConfigBackup.export(storage: source, to: file)
        let backup = try ConfigBackup.read(file)
        XCTAssertNil(backup.vault)

        let target = folder()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let current = try MasterVault.create(password: "other-master", iterations: 100).serialized()
        try current.write(to: target.appendingPathComponent("password-vault.json"))
        try ConfigBackup.restore(backup, storage: target)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("password-vault.json")), current,
                       "An older backup without a vault does not remove the vault.")

        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        document["vault"] = ["version": "not a vault"]
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        try FileManager.default.removeItem(at: ConfigBackup.checksumURL(file))
        XCTAssertThrowsError(try ConfigBackup.read(file)) {
            XCTAssertEqual($0.localizedDescription, "The password vault in this Gloamux backup is damaged.")
        }
    }

    func testChangedBackupIsRefusedAndMissingChecksumIsReported() throws {
        let file = folder().appendingPathComponent("all.gloamuxconfig")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let checksum = try ConfigBackup.export(storage: try source(), to: file)
        var data = try Data(contentsOf: file)
        data.append(contentsOf: Array(" ".utf8))
        try data.write(to: file)
        XCTAssertThrowsError(try ConfigBackup.read(file))
        try FileManager.default.removeItem(at: checksum)
        XCTAssertFalse(try ConfigBackup.read(file).verified)
    }

    func testImportReplacesEverythingAndKeepsTheOldCopy() throws {
        let file = folder().appendingPathComponent("all.gloamuxconfig")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigBackup.export(storage: try source(), to: file)

        let target = folder()
        let before = try WorkspaceModel(storage: target)
        try before.sessionTree.add(name: "Old server", parent: nil, connection: SavedConnection(host: "old.test", username: "bob"))
        try Data(#"{"secret":"KEEP"}"#.utf8).write(to: target.appendingPathComponent("saved-sign-ins.json"))
        let oldVault = try MasterVault.create(password: "old-master", iterations: 100).serialized()
        try oldVault.write(to: target.appendingPathComponent("password-vault.json"))
        WorkspaceCommand.preferences.set(11.0, forKey: TerminalPreferences.fontSizeKey)
        WorkspaceCommand.preferences.removeObject(forKey: TerminalPreferences.scrollbackKey)
        WorkspaceCommand.preferences.set(5000, forKey: TerminalPreferences.scrollbackKey)

        let safety = try ConfigBackup.restore(try ConfigBackup.read(file), storage: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("saved-sign-ins.json"), encoding: .utf8), #"{"secret":"KEEP"}"#)
        try FileManager.default.removeItem(at: target.appendingPathComponent("saved-sign-ins.json"))
        let after = try WorkspaceModel(storage: target)
        XCTAssertEqual(after.sessionTree.nodes.map(\.name), ["Build server"])
        XCTAssertEqual(WorkspaceCommand.preferences.double(forKey: TerminalPreferences.fontSizeKey), 15)
        XCTAssertNil(WorkspaceCommand.preferences.object(forKey: TerminalPreferences.scrollbackKey), "a setting the backup lacks returns to its default")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("runbooks/Deploy.md").path))
        let old = try String(contentsOf: safety.appendingPathComponent("sessions.json"), encoding: .utf8)
        XCTAssertTrue(old.contains("old.test"))
        let restored = try MasterVault.load(Data(contentsOf: target.appendingPathComponent("password-vault.json")))
        XCTAssertEqual(try restored.unlocked(password: "master-secret").retrieve(id: "alice@[build.test]:22"), "TOPSECRET-VAULT",
                       "The vault comes back and opens with the master password it was made with.")
        XCTAssertEqual(try Data(contentsOf: safety.appendingPathComponent("password-vault.json")), oldVault,
                       "The replaced vault is kept with the other previous files.")
    }

    func testCommandLineImportNeedsGloamuxClosed() async throws {
        let file = folder().appendingPathComponent("all.gloamuxconfig")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let model = try sourceWorkspace()
        _ = try await WorkspaceCommand.run(["config", "export", file.path], model: model, live: true)
        do {
            _ = try await WorkspaceCommand.run(["config", "import", file.path], model: model, live: true)
            XCTFail("import ran inside the open app")
        } catch {}
        let offline = try WorkspaceModel(storage: folder())
        let reply = try await WorkspaceCommand.run(["config", "import", file.path], model: offline, live: false)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(result["verified"] as? Bool, true)
    }

    // MARK: Serial line

    func testSerialLineSettingsReachTheDevice() throws {
        var main: Int32 = 0, side: Int32 = 0
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&main, &side, &name, nil, nil), 0)
        defer { Darwin.close(main); Darwin.close(side) }
        let path = String(cString: name)
        let port = try SerialPort(path: path, settings: .init(baud: 19200, format: "7E2", flow: .dtrDsr)) { _ in }
        defer { port.close() }
        var options = termios()
        XCTAssertEqual(tcgetattr(side, &options), 0)
        XCTAssertEqual(options.c_cflag & tcflag_t(CSIZE), tcflag_t(CS7))
        XCTAssertNotEqual(options.c_cflag & tcflag_t(PARENB), 0)
        XCTAssertEqual(options.c_cflag & tcflag_t(PARODD), 0)
        XCTAssertNotEqual(options.c_cflag & tcflag_t(CSTOPB), 0)
        XCTAssertNotEqual(options.c_cflag & tcflag_t(CDTR_IFLOW | CDSR_OFLOW), 0)
        XCTAssertEqual(options.c_cflag & tcflag_t(CRTS_IFLOW | CCTS_OFLOW), 0)
        XCTAssertEqual(cfgetospeed(&options), speed_t(19200))
    }

    func testOtherConnectionKeepsItsEncodingAndFlow() throws {
        var session = ContainerSession(tool: .serial, target: "/dev/cu.usbserial-1", baud: 115200, format: "8n1", flow: "dtr-dsr")
        session.encoding = .big5
        XCTAssertNoThrow(try session.validate())
        let decoded = try JSONDecoder().decode(ContainerSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.encoding, .big5)
        XCTAssertEqual(decoded.serialSettings.flow, .dtrDsr)
        XCTAssertEqual(NewConnectionType.other.editorTool, .serial)
    }
}

extension ConfigBackupTests {
    func testNewConnectionOpensOnTheKindUsedLast() throws {
        let root = folder()
        let model = try WorkspaceModel(storage: root)
        XCTAssertEqual(model.newConnectionTab().newConnectionType, .ssh)
        NewConnectionType.last = .other
        XCTAssertEqual(model.newConnectionTab().newConnectionType, .other)
        XCTAssertEqual(NewConnectionType.lastOtherTool, .serial)
        NewConnectionType.lastOtherTool = .telnet
        NewConnectionType.lastOtherTool = .rdp
        XCTAssertEqual(NewConnectionType.lastOtherTool, .telnet, "a desktop kind belongs to its own section")
    }

    func testTheLocalRowOpensThisMacsShellInPlaceAndLeavesTheNextFormClosed() async throws {
        let model = try WorkspaceModel(storage: folder())
        XCTAssertEqual(NewConnectionType.allCases.first, .local, "Local is the first row")
        XCTAssertNil(NewConnectionType.local.editorTool)
        let draft = model.newConnectionTab()
        let count = model.tabs.count
        NewConnectionType.last = .local
        model.openLocalTerminal(in: draft)
        defer { draft.localShell?.close() }
        XCTAssertEqual(model.tabs.count, count, "the form's own tab becomes the terminal")
        XCTAssertEqual(model.selected?.id, draft.id)
        XCTAssertTrue(draft.isLocal)
        XCTAssertNil(draft.newConnectionType)
        XCTAssertEqual(draft.host, "127.0.0.1")
        XCTAssertEqual(draft.username, NSUserName())
        XCTAssertEqual(draft.title, "Local terminal")
        XCTAssertNotNil(draft.localShell)

        // A second click, or one on a tab already in use, does nothing.
        let shell = draft.localShell
        model.openLocalTerminal(in: draft)
        XCTAssertTrue(draft.localShell === shell)

        // Chosen last, Local leaves every section of the next form closed, and that form neither connects nor saves.
        let next = model.newConnectionTab()
        XCTAssertEqual(next.newConnectionType, .local)
        XCTAssertFalse(NewConnectionType.usesSSHForm(next.newConnectionType))
        await model.connect(next)
        XCTAssertFalse(next.busy || next.connected || next.isLocal)
        XCTAssertTrue(NewConnectionType.usesSSHForm(.ssh) && NewConnectionType.usesSSHForm(nil))
    }
}
