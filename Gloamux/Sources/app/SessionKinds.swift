import Foundation
import SwiftUI
import Terminal

enum NewConnectionType: String, CaseIterable {
    /// This Mac's own shell, opened with one click. Chosen last, it leaves every other section closed.
    case local, ssh, rdp, vnc, other

    /// The kind of saved session the form makes; nil for SSH, which has its own form, and for Local, which has none.
    var editorTool: ContainerSession.Tool? {
        switch self {
        case .local, .ssh: return nil
        case .rdp: return .rdp
        case .vnc: return .vnc
        case .other: return .serial
        }
    }

    private static let lastTypeKey = "newConnection.lastType"
    private static let lastOtherToolKey = "newConnection.lastOtherTool"

    /// The section a new connection opens on: the one used last.
    @MainActor static var last: NewConnectionType {
        get { WorkspaceCommand.preferences.string(forKey: lastTypeKey).flatMap(Self.init(rawValue:)) ?? .ssh }
        set { WorkspaceCommand.preferences.set(newValue.rawValue, forKey: lastTypeKey) }
    }

    /// The kind an Other connection starts as: the one chosen last, or a serial port.
    @MainActor static var lastOtherTool: ContainerSession.Tool {
        get {
            WorkspaceCommand.preferences.string(forKey: lastOtherToolKey).flatMap(ContainerSession.Tool.init(rawValue:))
                .flatMap { $0.opensDesktop ? nil : $0 } ?? .serial
        }
        set { if !newValue.opensDesktop { WorkspaceCommand.preferences.set(newValue.rawValue, forKey: lastOtherToolKey) } }
    }

    /// Whether a tab of this kind fills in the SSH form. A tab that is no longer a new connection (nil) connects as
    /// it is; Local and the saved-session kinds do not.
    static func usesSSHForm(_ type: NewConnectionType?) -> Bool { type == nil || type == .ssh }

    var title: String { self == .local ? "Local terminal" : editorTool?.title ?? "SSH" }
    var shortTitle: String {
        switch self {
        case .local: return "Local"
        case .other: return "Other connection"
        default: return rawValue.uppercased()
        }
    }
    /// What each one is for, beside its name in the new-connection list.
    var subtitle: String {
        switch self {
        case .local: return "localhost"
        case .ssh: return "Terminal and files on a server"
        case .rdp: return "Windows desktop"
        case .vnc: return "Mac or Linux desktop"
        case .other: return "Serial port, Telnet, Mosh, and containers"
        }
    }
}

/// An environment a saved session or folder belongs to. Sessions inherit it from their folders. Tabs, panes, and the
/// window show it, and risky commands ask before they run in the environments chosen in Settings.
public enum SessionEnvironment: String, Codable, CaseIterable, Identifiable, Sendable {
    case production, staging, test, development
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .production: return "Production"
        case .staging: return "Staging"
        case .test: return "Test"
        case .development: return "Development"
        }
    }

    var shortTitle: String {
        switch self {
        case .production: return "PROD"
        case .staging: return "STG"
        case .test: return "TEST"
        case .development: return "DEV"
        }
    }

    var color: Color {
        switch self {
        case .production: return Color(red: 0.86, green: 0.2, blue: 0.2)
        case .staging: return Color(red: 0.93, green: 0.55, blue: 0.1)
        case .test: return Color(red: 0.8, green: 0.7, blue: 0.1)
        case .development: return Color(red: 0.2, green: 0.65, blue: 0.35)
        }
    }

    /// Environments that confirm risky commands, from Settings. Production and staging by default.
    static var confirming: Set<SessionEnvironment> {
        get {
            guard let saved = UserDefaults.standard.array(forKey: confirmingKey) as? [String] else { return [.production, .staging] }
            return Set(saved.compactMap(SessionEnvironment.init(rawValue:)))
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: confirmingKey) }
    }
    static let confirmingKey = "Gloamux.confirmEnvironments"
}

/// Command patterns that ask before they run in a confirming environment. Each is a case-insensitive regular
/// expression matched against the command line about to run.
enum RiskyCommands {
    static let key = "Gloamux.riskyCommandPatterns"
    static let defaults = [
        #"\brm\s+(-[a-zA-Z]*[rRf][a-zA-Z]*\s+)+"#,
        #"\b(shutdown|reboot|halt|poweroff)\b"#,
        #"\bmkfs(\.\w+)?\b"#,
        #"\bdd\s+.*\bof="#,
        #"\b(drop|truncate)\s+(table|database|schema)\b"#,
        #"\bdelete\s+from\b(?!.*\bwhere\b)"#,
        #"\bkubectl\s+(delete|drain|replace\s+--force)\b"#,
        #"\bterraform\s+(destroy|apply)\b"#,
        #"\bgit\s+push\s+.*(--force|-f\b)"#,
        #"\bsystemctl\s+(stop|restart|disable|mask)\b"#,
        #"\b(chmod|chown)\s+-R\b"#,
        #":\(\)\s*\{"#,
        #">\s*/dev/(sd|nvme|disk)"#,
    ]

    static var patterns: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? defaults }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The pattern a command matches, if any. Invalid patterns are skipped.
    static func match(_ command: String, patterns: [String] = patterns) -> String? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for pattern in patterns where !pattern.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return pattern }
        }
        return nil
    }
}

/// A terminal session that is not SSH: a shell inside a container, a Kubernetes pod, or an EC2 instance through AWS
/// Systems Manager, Mosh, Telnet, or a serial port. RDP and VNC have a desktop view.
public struct ContainerSession: Codable, Equatable, Sendable {
    public enum Tool: String, Codable, CaseIterable, Identifiable, Sendable {
        case docker, kubectl, ssm, mosh, telnet, serial, rdp, vnc
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .docker: return "docker exec"
            case .kubectl: return "kubectl exec"
            case .ssm: return "AWS SSM"
            case .mosh: return "Mosh"
            case .telnet: return "Telnet"
            case .serial: return "Serial port"
            case .rdp: return "Windows Remote Desktop (RDP)"
            case .vnc: return "Remote Desktop (VNC)"
            }
        }
        var symbol: String {
            switch self {
            case .docker: return "shippingbox"
            case .kubectl: return "cube"
            case .ssm: return "cloud"
            case .mosh: return "antenna.radiowaves.left.and.right"
            case .telnet: return "network"
            case .serial: return "cable.connector"
            case .rdp: return "desktopcomputer"
            case .vnc: return "rectangle.on.rectangle"
            }
        }
        /// Runs a command through the login shell; Telnet and serial ports are opened by Gloamux itself.
        var runsCommand: Bool { self != .telnet && self != .serial && !opensDesktop }
        var opensDesktop: Bool { self == .rdp || self == .vnc }
        var usesHost: Bool { self == .mosh || self == .telnet || opensDesktop }
        var defaultPort: Int {
            switch self {
            case .telnet: return 23
            case .rdp: return 3389
            case .vnc: return 5900
            default: return 22
            }
        }
    }

    public var tool: Tool
    /// The container, pod, or instance ID.
    public var target: String
    /// The Docker or kubectl context, or the AWS profile.
    public var context: String?
    /// The Kubernetes namespace, or the AWS Region.
    public var namespace: String?
    /// The container in a pod.
    public var container: String?
    /// The shell to start; `/bin/sh` when empty. Not used for SSM.
    public var shell: String?
    /// The user inside a Docker container, or the SSH user for Mosh.
    public var user: String?
    /// The SSH port for Mosh, or the Telnet port; the default when nil.
    public var port: Int?
    /// Serial line speed, format such as `8N1`, and flow control.
    public var baud: Int?
    public var format: String?
    public var flow: String?
    /// The character encoding of a serial or Telnet terminal, when it is not UTF-8.
    public var encoding: TerminalEncoding?
    var rdpFingerprint: String?
    /// A saved SSH session that carries an RDP or VNC connection through an SSH tunnel: VNC traffic is then encrypted,
    /// and hosts only that server can reach are reachable.
    var gatewaySessionID: UUID?
    /// An RDP desktop's fixed size; nil follows the size of the view.
    var desktopResolution: DesktopResolution?
    /// An RDP desktop at twice the pixels and 200% scaling, sharp on a Retina display. Only with no fixed size.
    var desktopRetina: Bool?
    /// What an RDP desktop gives up for a slower network; nil is the best quality.
    var desktopQuality: DesktopQuality?
    /// Whether clipboard text goes between this Mac and the desktop; nil follows the app's setting.
    var sharesClipboard: Bool?

    public init(tool: Tool, target: String, context: String? = nil, namespace: String? = nil, container: String? = nil,
                shell: String? = nil, user: String? = nil, port: Int? = nil, baud: Int? = nil, format: String? = nil, flow: String? = nil) {
        self.tool = tool; self.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        self.context = context.nonEmpty; self.namespace = namespace.nonEmpty; self.container = container.nonEmpty
        self.shell = shell.nonEmpty; self.user = user.nonEmpty
        self.port = port == tool.defaultPort ? nil : port
        self.baud = baud; self.format = format.nonEmpty?.uppercased(); self.flow = flow.nonEmpty
    }

    var effectivePort: Int { port ?? tool.defaultPort }

    var serialSettings: SerialPort.Settings {
        SerialPort.Settings(baud: baud ?? 9600, format: format ?? "8N1", flow: flow.flatMap(SerialPort.Settings.Flow.init(rawValue:)) ?? .none)
    }

    /// Values start with a letter, digit, or one of `_./:@`, so none can be read as an option, and have no spaces or
    /// control characters.
    func validate() throws {
        func valid(_ value: String?, required: Bool = false) -> Bool {
            guard let value, !value.isEmpty else { return !required }
            guard value.count <= 253, let first = value.unicodeScalars.first, first != "-" else { return false }
            return !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
        }
        switch tool {
        case .serial:
            guard SerialPort.isDevicePath(target), serialSettings.isValid, flow == nil || SerialPort.Settings.Flow(rawValue: flow!) != nil else {
                throw WorkspaceError.invalid("Choose a serial device and valid line settings.")
            }
        case .mosh, .telnet:
            guard valid(target, required: true), valid(user), !target.contains("@"), (1...65535).contains(effectivePort) else {
                throw WorkspaceError.invalid("Enter a host and settings without spaces, and none that start with a hyphen.")
            }
        case .rdp, .vnc:
            _ = try RemoteDesktopAddress(self)
            if let rdpFingerprint, tool != .rdp || !RemoteDesktopSession.isFingerprint(rdpFingerprint) {
                throw WorkspaceError.invalid("Invalid RDP certificate fingerprint.")
            }
        default:
            guard valid(target, required: true), valid(context), valid(namespace), valid(container), valid(shell), valid(user) else {
                throw WorkspaceError.invalid("Enter a target and settings without spaces, and none that start with a hyphen.")
            }
        }
    }

    /// The command line, quoted for a POSIX shell.
    var commandLine: String {
        let q = ShellIntegration.quote
        var parts: [String]
        switch tool {
        case .docker:
            parts = ["docker"] + (context.map { ["--context", q($0)] } ?? []) + ["exec", "-it"]
            if let user { parts += ["-u", q(user)] }
            parts += [q(target), q(shell ?? "/bin/sh")]
        case .kubectl:
            parts = ["kubectl"] + (context.map { ["--context", q($0)] } ?? []) + (namespace.map { ["-n", q($0)] } ?? [])
            parts += ["exec", "-it", q(target)] + (container.map { ["-c", q($0)] } ?? []) + ["--", q(shell ?? "/bin/sh")]
        case .ssm:
            parts = ["aws"] + (context.map { ["--profile", q($0)] } ?? []) + (namespace.map { ["--region", q($0)] } ?? [])
            parts += ["ssm", "start-session", "--target", q(target)]
        case .mosh:
            // `exec` comes first in the login shell, so the check for mosh runs in its own sh.
            let script = #"command -v mosh >/dev/null 2>&1 || { echo "mosh is not installed. Install it with: brew install mosh"; exit 127; }; exec mosh "$@""#
            parts = ["sh", "-c", q(script), "mosh"] + (port.map { [q("--ssh=ssh -p \($0)")] } ?? [])
            parts += ["--", q((user.map { $0 + "@" } ?? "") + target)]
        case .telnet, .serial, .rdp, .vnc:
            parts = []
        }
        return parts.joined(separator: " ")
    }

    var summary: String {
        switch tool {
        case .docker: return target
        case .kubectl: return (namespace.map { $0 + "/" } ?? "") + target + (container.map { " (\($0))" } ?? "")
        case .ssm: return target + (namespace.map { " · \($0)" } ?? "")
        case .mosh: return (user.map { $0 + "@" } ?? "") + target + (port.map { ":\($0)" } ?? "")
        case .telnet: return target + ":\(effectivePort)"
        case .rdp, .vnc: return (try? RemoteDesktopAddress(self).authority) ?? target
        case .serial:
            let settings = serialSettings
            return (target as NSString).lastPathComponent + " · \(settings.baud) \(settings.format)"
        }
    }
}

extension Optional where Wrapped == String {
    /// Nil for an empty or blank string.
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// A command held back in a confirming environment until the user says to run it.
struct RiskyCommandPrompt: Identifiable, Equatable {
    let id = UUID()
    let command: String
    let bytes: [UInt8]
    let environment: SessionEnvironment
}

/// Saved sessions opened most recently, newest first, kept in the workspace folder.
@MainActor final class RecentSessions: ObservableObject {
    private let url: URL
    @Published private(set) var ids: [UUID] = []

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([UUID].self, from: data) { ids = saved }
    }

    func opened(_ id: UUID) {
        var updated = ids.filter { $0 != id }
        updated.insert(id, at: 0)
        ids = Array(updated.prefix(20))
        if let data = try? JSONEncoder().encode(ids) { try? writePrivate(data, to: url) }
    }
}

/// A fixed RDP desktop size, in pixels.
struct DesktopResolution: Codable, Hashable, Sendable {
    var width: Int
    var height: Int

    static let presets = [(1280, 720), (1280, 800), (1366, 768), (1440, 900), (1600, 900), (1680, 1050),
                          (1920, 1080), (1920, 1200), (2560, 1440), (2560, 1600)].map { DesktopResolution(width: $0.0, height: $0.1) }

    var title: String { "\(width) × \(height)" }

    /// `1920x1080`, as the CLI writes it.
    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              Self.presets.contains(DesktopResolution(width: width, height: height)) else { return nil }
        self.init(width: width, height: height)
    }

    init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// How much an RDP desktop draws: everything on a LAN, no wallpaper on broadband, and no visual effects on a slow link.
enum DesktopQuality: String, Codable, CaseIterable, Sendable {
    case lan, broadband, low

    var title: String {
        switch self {
        case .lan: return "Best quality (LAN)"
        case .broadband: return "Balanced (broadband)"
        case .low: return "Fastest (slow network)"
        }
    }
}
