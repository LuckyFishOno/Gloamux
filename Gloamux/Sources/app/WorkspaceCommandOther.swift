import Foundation
import Terminal

/// `gloamux sessions add-other`, `edit-other`, and `serial-ports`: the Other connection form on the command line.
extension WorkspaceCommand {
    /// The settings each kind takes, as `NAME=VALUE`, in the order help lists them.
    static let otherSettings: [ContainerSession.Tool: [String]] = [
        .serial: ["baud", "data-bits", "parity", "stop-bits", "flow", "encoding"],
        .telnet: ["port", "encoding"],
        .mosh: ["user", "port"],
        .docker: ["context", "shell", "user"],
        .kubectl: ["context", "namespace", "container", "shell"],
        .ssm: ["profile", "region"],
        .rdp: ["gateway", "resolution", "retina", "quality", "clipboard"],
        .vnc: ["gateway", "clipboard"],
    ]

    static let otherKinds: [ContainerSession.Tool] = [.serial, .telnet, .mosh, .docker, .kubectl, .ssm]

    @MainActor static func otherSessions(_ action: String, _ args: [String], _ tree: SessionTreeStore,
                                         folder: (String) throws -> UUID?) throws -> Any {
        switch action {
        case "serial-ports":
            try count(args, 0...0)
            return SerialPort.devices()
        case "add-other":
            guard args.count >= 3 else { throw Usage("Wrong number of arguments. Run gloamux sessions --help.") }
            guard let tool = ContainerSession.Tool(rawValue: args[1]), otherKinds.contains(tool) else {
                throw Usage("Choose \(otherKinds.map(\.rawValue).joined(separator: ", ")).")
            }
            var session = ContainerSession(tool: tool, target: args[2])
            var parent: UUID?
            for (key, value) in try pairs(args.dropFirst(3)) {
                if key == "folder" { parent = try folder(value); continue }
                try apply(key, value, to: &session)
            }
            try session.validate()
            return ["id": try tree.add(name: args[0], parent: parent, container: session).uuidString]
        case "edit-other":
            guard args.count >= 2 else { throw Usage("Wrong number of arguments. Run gloamux sessions --help.") }
            let node = try item(args[0], in: tree)
            guard var session = node.container, otherKinds.contains(session.tool) || session.tool.opensDesktop else {
                throw Usage("Select a serial, Telnet, Mosh, container, pod, SSM, RDP, or VNC session.")
            }
            for (key, value) in try pairs(args.dropFirst()) {
                if key == "gateway", session.tool.opensDesktop {
                    // Through SSH: a saved SSH connection, as the form's menu lists.
                    if value == "-" { session.gatewaySessionID = nil; continue }
                    let gateway = try item(value, in: tree)
                    guard let connection = gateway.connection, !connection.isFTP else { throw Usage("Choose a saved SSH connection, or -.") }
                    session.gatewaySessionID = gateway.id
                } else if key == "target" {
                    let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if target != session.target { session.rdpFingerprint = nil }
                    session.target = target
                } else { try apply(key, value, to: &session) }
            }
            try session.validate()
            try tree.updateContainer(node.id, name: node.name, container: session, environment: node.environment)
            return ["id": node.id.uuidString]
        default: throw Usage("Unknown sessions operation.")
        }
    }

    static func pairs(_ args: ArraySlice<String>) throws -> [(String, String)] {
        try args.map { argument in
            guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else {
                throw Usage("Give settings as NAME=VALUE, such as baud=115200. Run gloamux sessions --help.")
            }
            return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
        }
    }

    /// Sets one setting; `-` clears it back to its default.
    private static func apply(_ key: String, _ value: String, to session: inout ContainerSession) throws {
        let allowed = otherSettings[session.tool] ?? []
        guard allowed.contains(key) else {
            throw Usage("\(session.tool.rawValue) takes \((["folder"] + allowed).map { $0 + "=" }.joined(separator: ", ")).")
        }
        let clear = value == "-"
        let text: String? = clear ? nil : value
        func formatPart(_ index: Int, _ character: Character) {
            var characters = Array(session.serialSettings.format)
            characters[index] = character
            session.format = String(characters)
        }
        switch key {
        case "user": session.user = text.nonEmpty
        case "port": session.port = try text.map { try tcpPort($0) }.flatMap { $0 == session.tool.defaultPort ? nil : $0 }
        case "context", "profile": session.context = text.nonEmpty
        case "namespace", "region": session.namespace = text.nonEmpty
        case "container": session.container = text.nonEmpty
        case "shell": session.shell = text.nonEmpty
        case "baud":
            guard let text else { session.baud = nil; return }
            guard let baud = Int(text), SerialPort.Settings.speeds.contains(baud) else {
                throw Usage("Choose a speed: \(SerialPort.Settings.speeds.map(String.init).joined(separator: ", ")).")
            }
            session.baud = baud
        case "data-bits":
            let bits = clear ? "8" : value
            guard ["5", "6", "7", "8"].contains(bits) else { throw Usage("Choose 5, 6, 7, or 8 data bits.") }
            formatPart(0, Character(bits))
        case "parity":
            let parity: [String: Character] = ["none": "N", "odd": "O", "even": "E"]
            guard let mark = parity[clear ? "none" : value] else { throw Usage("Choose none, odd, or even parity.") }
            formatPart(1, mark)
        case "stop-bits":
            let bits = clear ? "1" : value
            guard ["1", "2"].contains(bits) else { throw Usage("Choose 1 or 2 stop bits.") }
            formatPart(2, Character(bits))
        case "flow":
            let flows: [String: SerialPort.Settings.Flow] = ["none": .none, "rts-cts": .hardware, "dtr-dsr": .dtrDsr, "xon-xoff": .software]
            guard let flow = flows[clear ? "none" : value] else { throw Usage("Choose none, rts-cts, dtr-dsr, or xon-xoff flow control.") }
            session.flow = flow == .none ? nil : flow.rawValue
        case "resolution":
            if clear || value == "fit" { session.desktopResolution = nil; return }
            guard let resolution = DesktopResolution(value) else {
                throw Usage("Choose fit or \(DesktopResolution.presets.map { "\($0.width)x\($0.height)" }.joined(separator: ", ")).")
            }
            session.desktopResolution = resolution
        case "retina":
            session.desktopRetina = try switchValue(clear ? "off" : value) ? true : nil
        case "quality":
            guard clear || DesktopQuality(rawValue: value) != nil else { throw Usage("Choose lan, broadband, or low.") }
            session.desktopQuality = clear ? nil : DesktopQuality(rawValue: value).flatMap { $0 == .lan ? nil : $0 }
        case "gateway": throw Usage("Set gateway with edit-other.")
        case "clipboard":
            session.sharesClipboard = clear ? nil : try switchValue(value)
        case "encoding":
            guard clear || TerminalEncoding(rawValue: value) != nil else {
                throw Usage("Choose \(TerminalEncoding.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let encoding = clear ? nil : TerminalEncoding(rawValue: value)
            session.encoding = encoding == .utf8 ? nil : encoding
        default: break
        }
    }

    static func switchValue(_ value: String) throws -> Bool {
        switch value {
        case "on", "true", "yes": return true
        case "off", "false", "no": return false
        default: throw Usage("Use on or off.")
        }
    }

    /// What `sessions show` prints for an Other connection.
    @MainActor static func describeOther(_ session: ContainerSession) -> [String: Any] {
        var info: [String: Any] = [:]
        switch session.tool {
        case .serial:
            let settings = session.serialSettings
            let characters = Array(settings.format)
            info["baud"] = settings.baud
            info["data-bits"] = Int(String(characters[0])) ?? 8
            info["parity"] = ["N": "none", "O": "odd", "E": "even"][String(characters[1])] ?? "none"
            info["stop-bits"] = Int(String(characters[2])) ?? 1
            info["flow"] = ["none": "none", "hardware": "rts-cts", "dtr-dsr": "dtr-dsr", "software": "xon-xoff"][settings.flow.rawValue]
        case .docker, .kubectl, .ssm:
            let names: [String: String?] = [
                session.tool == .ssm ? "profile" : "context": session.context,
                "region": session.tool == .ssm ? session.namespace : nil,
                "namespace": session.tool == .kubectl ? session.namespace : nil,
                "container": session.container, "shell": session.shell, "user": session.user,
            ]
            for (key, value) in names { if let value { info[key] = value } }
        case .mosh: if let user = session.user { info["user"] = user }
        case .rdp:
            info["resolution"] = session.desktopResolution.map { "\($0.width)x\($0.height)" } ?? "fit"
            info["retina"] = session.desktopRetina == true && session.desktopResolution == nil
            info["quality"] = (session.desktopQuality ?? .lan).rawValue
        default: break
        }
        if session.tool.opensDesktop {
            let global = preferences.object(forKey: RemoteDesktopSession.clipboardKey) as? Bool ?? true
            info["clipboard"] = session.sharesClipboard ?? global
        }
        if session.tool == .serial || session.tool == .telnet { info["encoding"] = (session.encoding ?? .utf8).rawValue }
        return info
    }
}
