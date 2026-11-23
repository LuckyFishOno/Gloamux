import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

struct DesktopInput: Encodable, Sendable {
    let kind: String
    var scan: UInt16? = nil
    var keysym: UInt32? = nil
    var pressed: Bool? = nil
    var x: UInt16? = nil
    var y: UInt16? = nil
    var mask: UInt8? = nil
    var delta: Int16? = nil
    var width: UInt16? = nil
    var height: UInt16? = nil
    var text: String? = nil
}

private struct DesktopLogin: Encodable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let fingerprint: String?
    let protocolName: String
    let width: UInt16
    let height: UInt16
    /// A port on 127.0.0.1 that tunnels to the desktop; the host is still used for certificate and sign-in names.
    let viaPort: Int?
    /// RDP display scaling in percent: 200 for a Retina desktop, otherwise 100.
    let scale: Int
    /// `lan`, `broadband`, or `low`.
    let quality: String

    enum CodingKeys: String, CodingKey {
        case host, port, username, password, fingerprint, width, height, scale, quality
        case viaPort = "via_port"
        case protocolName = "protocol"
    }
}

private enum DesktopMessage: Sendable {
    case connected, frame(CGImage), certificate(String), failed(String), closed
    /// Text the remote desktop put on its clipboard.
    case clipboard(String)
    /// The connection broke after sign-in, so connecting again may work.
    case lost(String)

    static func read(_ handle: FileHandle) throws -> Self {
        guard let header = try Self.read(5, from: handle) else { return .closed }
        let count = header.dropFirst().enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        // The engine's largest image, a 6K screen, with its size in front.
        let limit = header[0] == 2 ? 6144 * 3456 * 4 + 4 : header[0] == 6 ? RemoteDesktopSession.clipboardLimit : 1024
        guard count <= limit, let data = try read(count, from: handle) else { throw Self.invalid }
        switch header[0] {
        case 1 where data.isEmpty: return .connected
        case 2:
            guard data.count >= 4 else { throw Self.invalid }
            let width = Int(data[0]) | Int(data[1]) << 8
            let height = Int(data[2]) | Int(data[3]) << 8
            guard width > 0, height > 0, width * height * 4 + 4 == data.count,
                  let provider = CGDataProvider(data: Data(data.dropFirst(4)) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Self.invalid }
            return .frame(image)
        case 3:
            guard let value = String(data: data, encoding: .ascii), Self.isFingerprint(value) else { throw Self.invalid }
            return .certificate(value)
        case 4:
            return .failed(String(data: data, encoding: .utf8) ?? "The remote desktop engine stopped.")
        case 5 where data.isEmpty: return .closed
        case 6: return .clipboard(String(decoding: data, as: UTF8.self))
        case 7: return .lost(String(data: data, encoding: .utf8) ?? "The remote desktop connection was lost.")
        default: throw Self.invalid
        }
    }

    static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func read(_ count: Int, from handle: FileHandle) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else { return nil }
            data.append(part)
        }
        return data
    }

    private static var invalid: WorkspaceError { .invalid("The remote desktop engine returned invalid data.") }
}

private final class DesktopWorker: @unchecked Sendable {
    let process = Process()
    let output: FileHandle
    private let input: FileHandle
    private let writes = DispatchQueue(label: "Gloamux.remote-desktop.input")

    init(executable: URL) {
        let commands = Pipe(), messages = Pipe()
        input = commands.fileHandleForWriting
        output = messages.fileHandleForReading
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = executable
        process.standardInput = commands
        process.standardOutput = messages
        process.standardError = FileHandle.nullDevice
    }

    func send<T: Encodable>(_ value: T) {
        // The engine reads lines of up to twice the clipboard limit, as JSON escapes can double the text.
        guard var data = try? JSONEncoder().encode(value), data.count < RemoteDesktopSession.clipboardLimit * 2 else { return }
        data.append(10)
        let packet = data
        writes.async { [input] in try? input.write(contentsOf: packet) }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        writes.async { [input] in try? input.close() }
    }
}

@MainActor final class RemoteDesktopSession: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var phase: Phase = .idle {
        didSet { tab?.connected = phase == .connected }
    }
    @Published private(set) var error: String?
    @Published private(set) var pendingFingerprint: String?
    private(set) var profile: ContainerSession
    /// The sign-in under way, kept here rather than in the view so it survives the view being rebuilt, and handled
    /// once the desktop accepts or refuses it.
    var signIn: (id: String, secret: String, generation: UUID, remember: Bool, user: String)?
    private var worker: DesktopWorker?
    private var id = UUID()
    private weak var tab: SessionTab?
    /// The view's size in points: the desktop size an RDP server is asked for.
    private var viewSize: CGSize = .zero
    private var resizeTask: Task<Void, Never>?
    /// The sign-in that worked, kept in memory while the tab is open so a broken connection can sign in again.
    private var lastSignIn: (username: String, password: String)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    /// The pasteboard change count last sent to or received from the remote desktop, so neither side echoes.
    private var clipboardChange = -1
    /// Opens the SSH tunnel for a desktop with a gateway: the gateway session, the desktop host and port. Returns
    /// the local port to connect to. Set by the workspace.
    var openTunnel: ((UUID, String, Int) async throws -> Int)?
    /// Closes the tunnel and its gateway connection. Set when a tunnel opens.
    var closeTunnel: (() -> Void)?
    /// The hidden SSH connection a tunnel goes through, so the pane can show its host key prompt.
    @Published var gatewayTab: SessionTab?

    /// Clipboard text passed either way is cut at this many bytes.
    nonisolated static let clipboardLimit = 256 * 1024
    /// Settings key: share text on the clipboard with VNC desktops. On by default.
    nonisolated static let clipboardKey = "Gloamux.desktop.sharesClipboard"
    nonisolated static var sharesClipboard: Bool { UserDefaults.standard.object(forKey: clipboardKey) as? Bool ?? true }
    /// This desktop's clipboard choice, or the app's setting.
    var clipboardShared: Bool { profile.sharesClipboard ?? Self.sharesClipboard }
    /// The desktop asks for twice the view's pixels: Retina is on and the size follows the view.
    var retina: Bool { profile.tool == .rdp && profile.desktopRetina == true && profile.desktopResolution == nil }
    static let reconnectDelays = [2, 5, 10, 30, 60]

    enum Phase { case idle, connecting, connected }

    init(profile: ContainerSession, tab: SessionTab) { self.profile = profile; self.tab = tab }

    nonisolated static func isFingerprint(_ value: String) -> Bool { DesktopMessage.isFingerprint(value) }

    func connect(username: String, password: String) {
        guard phase == .idle, worker == nil, pendingFingerprint == nil else { return }
        error = nil
        reconnectTask?.cancel(); reconnectTask = nil
        lastSignIn = (username, password)
        let runID = id
        phase = .connecting
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let address = try RemoteDesktopAddress(self.profile)
                var viaPort: Int?
                if let gateway = self.profile.gatewaySessionID {
                    guard let openTunnel = self.openTunnel else { throw WorkspaceError.invalid("Cannot open the SSH tunnel.") }
                    viaPort = try await openTunnel(gateway, address.host, self.profile.effectivePort)
                    // Disconnected while the tunnel opened.
                    guard self.id == runID, self.phase == .connecting else { self.closeGateway(); return }
                }
                try self.start(address: address, viaPort: viaPort, username: username, password: password)
            } catch {
                guard self.id == runID else { return }
                self.stop()
                self.error = message(for: error)
                self.lastSignIn = nil
            }
        }
    }

    /// Starts the engine and reads what it reports until the session ends.
    private func start(address: RemoteDesktopAddress, viaPort: Int?, username: String, password: String) throws {
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gloamux-rdp")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw WorkspaceError.invalid("The built-in remote desktop engine is missing. Rebuild Gloamux.")
            }
            let worker = DesktopWorker(executable: helper)
            try worker.process.run()
            self.worker = worker
            let runID = id
            let size: (width: UInt16, height: UInt16)
            if profile.tool == .rdp, let fixed = profile.desktopResolution {
                size = (UInt16(fixed.width), UInt16(fixed.height))
            } else {
                size = Self.pixels(viewSize, scale: retina ? 2 : 1)
            }
            worker.send(DesktopLogin(host: address.host, port: profile.effectivePort, username: username,
                                     password: password, fingerprint: profile.rdpFingerprint, protocolName: profile.tool.rawValue,
                                     width: size.width, height: size.height, viaPort: viaPort, scale: retina ? 200 : 100,
                                     quality: (profile.desktopQuality ?? .lan).rawValue))
            Task.detached { [weak self, worker] in
                defer { try? worker.output.close() }
                while !Task.isCancelled {
                    let message: DesktopMessage
                    do { message = try DesktopMessage.read(worker.output) }
                    catch { message = .failed(error.localizedDescription) }
                    guard await self?.receive(message, id: runID) == true else { return }
                }
            }
        }
    }

    func send(_ input: DesktopInput) {
        if phase == .connected { worker?.send(input) }
    }

    /// The view changed size. Sign-in uses the latest size; a connected RDP desktop is asked to match it once
    /// the size has settled, since each change makes the server redraw the whole desktop.
    func viewResized(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewSize else { return }
        viewSize = size
        // A fixed size stays as it is and is scaled to fit the view.
        guard profile.tool == .rdp, profile.desktopResolution == nil, phase == .connected else { return }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.phase == .connected else { return }
            let pixels = Self.pixels(self.viewSize, scale: self.retina ? 2 : 1)
            self.send(DesktopInput(kind: "resize", width: pixels.width, height: pixels.height))
        }
    }

    /// A size in points as whole pixels for the engine, which keeps it within what RDP allows.
    nonisolated static func pixels(_ size: CGSize, scale: CGFloat = 1) -> (width: UInt16, height: UInt16) {
        guard size.width >= 1, size.height >= 1 else { return (0, 0) }
        return (UInt16(min((size.width * scale).rounded(.down), 8192)), UInt16(min((size.height * scale).rounded(.down), 8192)))
    }

    /// The desktop view took focus: the Mac clipboard's text goes to the remote desktop when it changed since it was
    /// last shared, so text copied on the Mac can be pasted there.
    func shareClipboard() {
        guard phase == .connected, clipboardShared else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChange else { return }
        clipboardChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        send(DesktopInput(kind: "clipboard", text: Self.clipped(text)))
    }

    /// Text cut to `clipboardLimit` UTF-8 bytes, at a character boundary.
    nonisolated static func clipped(_ text: String) -> String {
        guard text.utf8.count > clipboardLimit else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: clipboardLimit)
        while end > text.startIndex, end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }

    private func receiveClipboard(_ text: String) {
        guard clipboardShared, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == text { clipboardChange = pasteboard.changeCount; return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        clipboardChange = pasteboard.changeCount
    }

    func confirmFingerprint() {
        guard let pendingFingerprint else { return }
        profile.rdpFingerprint = pendingFingerprint
        self.pendingFingerprint = nil
    }

    func dismissFingerprint() { pendingFingerprint = nil }

    /// The account that signed in, so the header and the next sign-in show it.
    func useUser(_ user: String) { profile.user = user.isEmpty ? nil : user }

    /// Ends the session at the user's request: no reconnecting, and the kept sign-in is forgotten.
    func disconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempts = 0
        lastSignIn = nil
        stop()
    }

    private func stop() {
        id = UUID()
        closeGateway()
        resizeTask?.cancel(); resizeTask = nil
        worker?.stop()
        worker = nil
        image = nil
        phase = .idle
    }

    private func closeGateway() {
        closeTunnel?(); closeTunnel = nil
        gatewayTab = nil
    }

    /// After a broken connection, signs in again with the sign-in that worked, after 2, 5, 10, then 30 seconds.
    private func scheduleReconnect(_ reason: String) {
        guard TerminalPreferences.reconnects, let signIn = lastSignIn, reconnectAttempts < Self.reconnectDelays.count else {
            error = reason
            lastSignIn = nil
            reconnectAttempts = 0
            return
        }
        let delay = Self.reconnectDelays[reconnectAttempts]
        reconnectAttempts += 1
        error = T(reason) + " " + String(format: T("Reconnecting in %d seconds…"), delay)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.phase == .idle else { return }
            let attempts = self.reconnectAttempts
            self.connect(username: signIn.username, password: signIn.password)
            self.reconnectAttempts = attempts
        }
    }

    private func receive(_ message: DesktopMessage, id: UUID) -> Bool {
        guard self.id == id else { return false }
        switch message {
        case .connected:
            phase = .connected
            reconnectAttempts = 0
        case .frame(let frame): image = frame
        case .clipboard(let text): receiveClipboard(text)
        case .lost(let reason):
            // Only a session that was signed in reconnects; a failure while connecting is reported.
            let wasConnected = phase == .connected || reconnectAttempts > 0
            stop()
            if wasConnected { scheduleReconnect(reason) } else { self.error = reason; lastSignIn = nil }
            return false
        case .certificate(let fingerprint):
            pendingFingerprint = fingerprint
            disconnect()
            return false
        case .failed(let error):
            // A reconnect that is refused (a changed password, say) stops trying.
            disconnect()
            self.error = error
            return false
        case .closed:
            disconnect()
            error = "The remote desktop connection ended."
            return false
        }
        return true
    }
}
