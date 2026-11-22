import XCTest
import Darwin
import Foundation
@testable import App

@MainActor
final class RemoteKindsTests: XCTestCase {
    func testMoshCommandLineChecksForMoshAndQuotesArguments() throws {
        let session = ContainerSession(tool: .mosh, target: "build.example", user: "deploy", port: 2222)
        XCTAssertNoThrow(try session.validate())
        XCTAssertEqual(session.summary, "deploy@build.example:2222")
        // A stand-in mosh prints its arguments, so the quoting is checked by a real shell.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-mosh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("mosh")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertEqual(try run("exec " + session.commandLine, path: folder.path + ":/usr/bin:/bin"),
                       "--ssh=ssh -p 2222\n--\ndeploy@build.example\n")
        let plain = ContainerSession(tool: .mosh, target: "host", port: 22)
        XCTAssertNil(plain.port, "the default port is not stored")
        XCTAssertEqual(try run("exec " + plain.commandLine, path: folder.path + ":/usr/bin:/bin"), "--\nhost\n")
        // Without mosh on the PATH it says how to install it instead of failing quietly.
        XCTAssertTrue(try run("exec " + plain.commandLine, path: "/usr/bin:/bin").contains("brew install mosh"))
        XCTAssertThrowsError(try ContainerSession(tool: .mosh, target: "-oProxyCommand=x").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .mosh, target: "a@b").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .telnet, target: "router", port: 70000).validate())
        XCTAssertEqual(ContainerSession(tool: .telnet, target: "router").summary, "router:23")
    }

    func testSerialSettingsAreValidated() {
        XCTAssertNoThrow(try ContainerSession(tool: .serial, target: "/dev/cu.usbserial-1", baud: 115200, format: "8n1").validate())
        XCTAssertEqual(ContainerSession(tool: .serial, target: "/dev/cu.usbserial-1", baud: 115200, format: "7e1").summary, "cu.usbserial-1 · 115200 7E1")
        XCTAssertThrowsError(try ContainerSession(tool: .serial, target: "/etc/passwd").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .serial, target: "/dev/cu.x/../disk0").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .serial, target: "/dev/cu.x", baud: 12345).validate())
        XCTAssertThrowsError(try ContainerSession(tool: .serial, target: "/dev/cu.x", format: "9N1").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .serial, target: "/dev/cu.x", flow: "magic").validate())
        XCTAssertNotNil(SerialPort.Settings.parse("8O2"))
        XCTAssertNil(SerialPort.Settings.parse("8X1"))
    }

    func testDesktopProfilesPersistAndOpenInGloamuxTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-desktop-profiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("sessions.json")
        let tree = try SessionTreeStore(url: catalog)
        let rdp = ContainerSession(tool: .rdp, target: "workstation.example")
        let vnc = ContainerSession(tool: .vnc, target: "2001:db8::1", port: 5901)
        let windowsID = try tree.add(name: "Windows", parent: nil, container: rdp)
        let screenID = try tree.add(name: "Screen", parent: nil, container: vnc)
        let reopened = try SessionTreeStore(url: catalog)
        XCTAssertEqual(reopened.node(windowsID)?.container, rdp)
        XCTAssertEqual(reopened.node(screenID)?.container, vnc)
        XCTAssertFalse(rdp.tool.runsCommand)
        XCTAssertFalse(vnc.tool.runsCommand)
        XCTAssertEqual(try RemoteDesktopAddress(rdp).authority, "workstation.example:3389")
        XCTAssertEqual(try RemoteDesktopAddress(vnc).authority, "[2001:db8::1]:5901")
        let model = try WorkspaceModel(storage: root)
        XCTAssertEqual(model.workspaceMode, .terminal)
        for (id, profile) in [(windowsID, rdp), (screenID, vnc)] {
            let tab = try XCTUnwrap(model.openSaved(try XCTUnwrap(model.sessionTree.node(id))))
            XCTAssertEqual(tab.desktop?.profile, profile)
            XCTAssertEqual(tab.desktop?.phase, .idle)
            XCTAssertNil(tab.localShell)
        }
        model.openFileTransfer(for: nil)
        XCTAssertEqual(model.workspaceMode, .files)
        let draft = model.newConnectionTab(.vnc)
        XCTAssertEqual(model.workspaceMode, .terminal)
        XCTAssertEqual(draft.newConnectionType, .vnc)
        let tabCount = model.tabs.count
        model.configureDesktop(draft, try XCTUnwrap(model.sessionTree.node(screenID)), vnc)
        XCTAssertNil(draft.newConnectionType)
        XCTAssertEqual(draft.desktop?.profile, vnc)
        XCTAssertEqual(draft.savedSessionID, screenID)
        XCTAssertEqual(model.tabs.count, tabCount, "opening the desktop form reuses the new connection tab")
        XCTAssertThrowsError(try ContainerSession(tool: .rdp, target: "pc\r\nusername:s:other").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .vnc, target: "name@other").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .vnc, target: "screen", port: 70000).validate())
    }

    func testDesktopThroughSSHKeepsItsGatewayAfterReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-desktop-gateway-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("sessions.json")
        let tree = try SessionTreeStore(url: catalog)
        let gatewayID = UUID()
        var vnc = ContainerSession(tool: .vnc, target: "127.0.0.1", port: 5900)
        let id = try tree.add(name: "Screen", parent: nil, container: vnc)
        XCTAssertNil(try SessionTreeStore(url: catalog).node(id)?.container?.gatewaySessionID)
        vnc.gatewaySessionID = gatewayID
        try tree.updateContainer(id, name: "Screen", container: vnc, environment: nil)
        XCTAssertEqual(try SessionTreeStore(url: catalog).node(id)?.container?.gatewaySessionID, gatewayID)
    }

    func testDesktopSizeAndClipboardLimits() {
        XCTAssertTrue(RemoteDesktopSession.pixels(.zero) == (0, 0))
        XCTAssertTrue(RemoteDesktopSession.pixels(CGSize(width: 1280.7, height: 800.2)) == (1280, 800))
        XCTAssertTrue(RemoteDesktopSession.pixels(CGSize(width: 20000, height: 9000)) == (8192, 8192))
        XCTAssertEqual(RemoteDesktopSession.clipped("short 中文"), "short 中文")
        let limit = RemoteDesktopSession.clipboardLimit
        let long = String(repeating: "a", count: limit - 1) + "中文"
        let cut = RemoteDesktopSession.clipped(long)
        XCTAssertLessThanOrEqual(cut.utf8.count, limit)
        XCTAssertEqual(cut, String(repeating: "a", count: limit - 1))
    }

    func testX11IsOptInAndPersistsInTheSavedSSHProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-x11-profiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("sessions.json")
        let tree = try SessionTreeStore(url: catalog)
        var ssh = SavedConnection(host: "server.example", username: "user")
        XCTAssertNil(ssh.forwardsX11)
        ssh.forwardsX11 = true
        let id = try tree.add(name: "X11", parent: nil, connection: ssh)
        XCTAssertEqual(try SessionTreeStore(url: catalog).node(id)?.connection?.forwardsX11, true)
    }

    /// A pseudo-terminal pair stands in for a USB serial cable.
    func testSerialPortExchangesBytesOverATerminalDevice() async throws {
        var controller: Int32 = -1, device: Int32 = -1
        XCTAssertEqual(openpty(&controller, &device, nil, nil, nil), 0)
        let path = String(cString: ptsname(controller))
        Darwin.close(device)
        defer { Darwin.close(controller) }
        let received = LockedBytes()
        let port = try SerialPort(path: path, settings: .init(baud: 115200, format: "8N1", flow: .none)) { received.append(Array($0)) }
        defer { port.close() }
        var options = termios(); tcgetattr(controller, &options); cfmakeraw(&options); tcsetattr(controller, TCSANOW, &options)
        _ = Array("hello\r\n".utf8).withUnsafeBytes { Darwin.write(controller, $0.baseAddress, $0.count) }
        for _ in 0..<200 where received.bytes.count < 7 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(received.bytes, Array("hello\r\n".utf8), "raw mode passes bytes through unchanged")
        port.send([0x41, 0x0D, 0xFF])
        var buffer = [UInt8](repeating: 0, count: 16), total: [UInt8] = []
        let flags = fcntl(controller, F_GETFL); _ = fcntl(controller, F_SETFL, flags | O_NONBLOCK)
        for _ in 0..<200 where total.count < 3 {
            let count = Darwin.read(controller, &buffer, buffer.count)
            if count > 0 { total += buffer.prefix(count) } else { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertEqual(total, [0x41, 0x0D, 0xFF])
        XCTAssertThrowsError(try SerialPort(path: "/dev/cu.gloamux-missing", settings: .init()) { _ in })
    }

    func testTelnetAndSerialTabsDoNotStartAShell() throws {
        let model = try WorkspaceModel(storage: FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-kinds-\(UUID().uuidString)"))
        let tab = model.addLocalTab(launch: nil, title: "Console", container: ContainerSession(tool: .serial, target: "/dev/cu.gloamux-missing"))
        XCTAssertNil(tab.localShell)
        XCTAssertFalse(tab.terminalReady)
        XCTAssertEqual(tab.status, "Connection failed")
        XCTAssertEqual(tab.host, "cu.gloamux-missing · 9600 8N1")
    }

    private func run(_ command: String, path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": path, "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

private final class LockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []
    var bytes: [UInt8] { lock.withLock { storage } }
    func append(_ new: [UInt8]) { lock.withLock { storage += new } }
}
