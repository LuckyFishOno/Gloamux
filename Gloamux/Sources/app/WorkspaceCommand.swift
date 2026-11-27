import Foundation
import FileTransfer

/// The application operations shared by the command line and the running workspace.
public enum WorkspaceCommand {
    public struct Usage: LocalizedError {
        public let detail: String
        public init(_ detail: String) { self.detail = detail }
        public var errorDescription: String? { detail }
    }

    /// Runs one operation. `model` is the active window's workspace; `windows` lists every open workspace window when
    /// the app is running, so tab IDs from any window work.
    @MainActor public static func run(_ argv: [String], model: WorkspaceModel, live: Bool,
                                      windows: [WorkspaceModel] = []) async throws -> Data {
        guard argv.count >= 2 else { throw Usage("Choose an operation. Run gloamux <command> --help.") }
        let command = argv[0], action = argv[1], args = Array(argv.dropFirst(2))
        // Every public operation is listed in the catalog, so help, completion, and what runs here cannot drift apart.
        // Checked first, so an unknown operation is a usage error with or without the running app.
        if !CLICatalog.internalCommands.contains(command) {
            guard let entry = CLICatalog.command(command), entry.runner == .workspace else { throw Usage("Unknown workspace command.") }
            guard entry.operations.contains(action) else { throw Usage("Unknown \(command) operation.") }
        }
        let open = [model] + windows.filter { $0 !== model }
        let result: Any
        switch command {
        case "sessions": result = try await sessions(action, args, model, live: live)
        case "hosts":
            result = ["list", "history", "trust", "replace"].contains(action) ? try hosts(action, args, model)
                : try await hostTools(action, args, model)
        case "recordings": result = try recordings(action, args, model)
        case "videos": result = try await videos(action, args, model, live: live, open)
        case "history": result = try history(action, args, model)
        case "commands":
            if ["send", "run"].contains(action) {
                try requireLive(live, model)
                result = try commandToTab(action, args, model, open)
            } else {
                result = try commands(action, args, model)
            }
        case "appearance": result = try appearance(action, args, model)
        case "triggers": result = try triggers(action, args, model)
        case "runbooks":
            if action == "run" { try requireLive(live, model) }
            result = try runbooks(action, args, model, open)
        case "settings": result = try settings(action, args, model, live: live)
        case "layout": result = try layout(action, args, model, live: live)
        case "config": result = try config(action, args, model, live: live)
        case "agent":
            guard live else { throw WorkspaceError.invalid("Open Gloamux and turn on agent access in Settings › Agents.") }
            guard !model.workspaceLocked else { throw WorkspaceError.invalid("Gloamux is locked. Unlock it to continue.") }
            result = try agent([action] + args, model, windows)
        case "agents": result = try agents(action, args, model)
        case "vault", "signins", "workspace":
            if !(command == "vault" && action == "status") { try requireLive(live, model) }
            result = try await security(command, action, args, model)
        case "tabs":
            try requireLive(live, model)
            result = try await tabs(action, args, model, open)
        case "web":
            try requireLive(live, model)
            result = try await web(action, args, model)
        case "forwards":
            if ["live-list", "start", "stop"].contains(action) {
                guard live, !model.workspaceLocked else { throw WorkspaceError.invalid("Open and unlock Gloamux before controlling live forwards.") }
                if action == "live-list", args.isEmpty {
                    result = await tunnels(open)
                } else {
                    let owner = try tab(args.first ?? "", open).model
                    result = try await forwards(action, args, owner)
                }
            } else {
                result = try await forwards(action, args, model)
            }
        default: throw Usage("Unknown workspace command.")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed])
    }

    @MainActor public static func item(_ selector: String, in tree: SessionTreeStore) throws -> SessionTreeNode {
        if let id = UUID(uuidString: selector), let node = tree.node(id) { return node }
        let matches = tree.nodes.filter { $0.name == selector }
        guard let node = matches.first else { throw WorkspaceError.invalid("No saved item named \(selector).") }
        guard matches.count == 1 else { throw WorkspaceError.invalid("More than one item is named \(selector). Use its ID from gloamux sessions list.") }
        return node
    }

    /// Exports or restores the whole configuration. Restoring needs Gloamux closed, so nothing it has open is replaced.
    @MainActor private static func config(_ action: String, _ args: [String], _ model: WorkspaceModel, live: Bool) throws -> Any {
        try count(args, 1...1)
        let url = URL(fileURLWithPath: args[0]).standardizedFileURL
        switch action {
        case "export":
            let checksum = try ConfigBackup.export(storage: model.storage, to: url)
            return ["file": url.path, "sha256": checksum.path]
        case "import":
            guard !live else { throw WorkspaceError.invalid("Quit Gloamux before importing all settings, or import them from Settings in Gloamux.") }
            let backup = try ConfigBackup.read(url)
            let safety = try ConfigBackup.restore(backup, storage: model.storage)
            return ["restored": url.path, "verified": backup.verified, "previous": safety.path]
        default: throw Usage("Unknown config operation.")
        }
    }

    static func count(_ args: [String], _ range: ClosedRange<Int>) throws {
        guard range.contains(args.count) else { throw Usage("Wrong number of arguments. Run gloamux <command> --help.") }
    }

    @MainActor private static func sessions(_ action: String, _ args: [String], _ model: WorkspaceModel, live: Bool) async throws -> Any {
        let tree = model.sessionTree
        func describe(_ node: SessionTreeNode) -> [String: Any] {
            var info: [String: Any] = ["id": node.id.uuidString, "name": node.name, "kind": node.isFolder ? "folder" : "session"]
            if let parent = node.parent { info["parent"] = parent.uuidString }
            if let environment = node.environment { info["environment"] = environment.rawValue }
            if let config = node.connection {
                let transport = config.ftpSecurity.map { $0 == .none ? "ftp" : "ftps" }
                info["protocol"] = transport ?? config.fileProtocol?.rawValue ?? "ssh"
                info["host"] = config.host
                info["port"] = config.port
                info["username"] = config.username
                info.merge(describeOptions(config, tree)) { current, _ in current }
            } else if let other = node.container {
                info["protocol"] = other.tool.rawValue
                info["target"] = other.target
                if other.tool.usesHost { info["port"] = other.effectivePort }
                if other.tool.opensDesktop {
                    info["gateway"] = other.gatewaySessionID.map { tree.node($0)?.name ?? $0.uuidString } ?? "-"
                }
                info.merge(describeOther(other)) { current, _ in current }
            }
            return info
        }
        func folder(_ selector: String) throws -> UUID? {
            if selector == "-" { return nil }
            let node = try item(selector, in: tree)
            guard node.isFolder else { throw Usage("Choose a folder, or use - for the top level.") }
            return node.id
        }
        switch action {
        case "list":
            try count(args, 0...0)
            return tree.nodes.map(describe)
        case "show":
            try count(args, 1...1)
            return describe(try item(args[0], in: tree))
        case "mkdir":
            try count(args, 1...2)
            let parent = try args.dropFirst().first.flatMap(folder)
            return ["id": try tree.add(name: args[0], parent: parent).uuidString]
        case "add":
            try count(args, 4...6)
            let port = try args.dropFirst(4).first.map { try tcpPort($0) }
            let parent = try args.dropFirst(5).first.flatMap(folder)
            let name = args[0], scheme = args[1], host = args[2], user = args[3] == "-" ? "" : args[3]
            if let desktop = ContainerSession.Tool(rawValue: scheme), desktop.opensDesktop {
                let profile = ContainerSession(tool: desktop, target: host, user: user, port: port)
                return ["id": try tree.add(name: name, parent: parent, container: profile).uuidString]
            }
            let security: FTPSecurity?
            switch scheme {
            case "ssh", "sftp", "scp": security = nil
            case "ftp": security = FTPSecurity.none
            case "ftps": security = .explicitTLS
            case "ftps-implicit": security = .implicitTLS
            default: throw Usage("Choose ssh, sftp, scp, ftp, ftps, ftps-implicit, rdp, or vnc.")
            }
            var profile = SavedConnection(host: host, port: port ?? security?.defaultPort ?? 22, username: user)
            profile.fileProtocol = FileProtocolChoice(rawValue: scheme)
            profile.ftpSecurity = security
            return ["id": try tree.add(name: name, parent: parent, connection: profile).uuidString]
        case "from-sftp":
            try count(args, 2...3)
            let command = try SFTPCommand.parse(args[1])
            let asksKey = command.connection.identityPath == nil
                && (command.connection.username.isEmpty || SessionKey.looksLikeKey(command.connection.username))
            let id = try model.saveSFTPSession(command, name: args[0], parent: args.count > 2 ? folder(args[2]) : nil, asksKey: asksKey,
                                               localFolder: WorkspaceModel.copyFolder(command.localFolder), connects: false, copies: false, replaces: false)
            return ["id": id.uuidString, "auth": asksKey ? SignInMode.sessionKey.rawValue : command.connection.signIn?.rawValue ?? "password",
                    "ignored": command.ignored]
        case "options":
            return try await sessionOptions(args, model, live: live)
        case "add-other", "edit-other", "serial-ports":
            return try otherSessions(action, args, tree, folder: folder)
        case "rename":
            try count(args, 2...2)
            let id = try item(args[0], in: tree).id
            try tree.rename(id, to: args[1])
            return ["id": id.uuidString]
        case "edit":
            try count(args, 4...4)
            let node = try item(args[0], in: tree)
            let host = args[1], user = args[2] == "-" ? "" : args[2], port = try tcpPort(args[3])
            if var connection = node.connection {
                if connection.host != host || connection.port != port { connection.ftpFingerprint = nil }
                connection.host = host
                connection.username = user
                connection.port = port
                try tree.updateConnection(node.id, name: node.name, connection: connection)
            } else if var desktop = node.container, desktop.tool.opensDesktop {
                if desktop.target != host || desktop.effectivePort != port { desktop.rdpFingerprint = nil }
                desktop.target = host
                desktop.user = desktop.tool == .rdp ? Optional(user).nonEmpty : nil
                desktop.port = port == desktop.tool.defaultPort ? nil : port
                try tree.updateContainer(node.id, name: node.name, container: desktop, environment: node.environment)
            } else {
                throw Usage("Select a saved SSH, FTP, or remote desktop connection. Use edit-other for other connections.")
            }
            return ["id": node.id.uuidString]
        case "move":
            try count(args, 2...2)
            let id = try item(args[0], in: tree).id
            try tree.drop(id, on: try folder(args[1]), .into)
            return ["id": id.uuidString]
        case "env":
            try count(args, 2...2)
            let node = try item(args[0], in: tree)
            let environment = args[1] == "-" ? nil : SessionEnvironment(rawValue: args[1])
            guard args[1] == "-" || environment != nil else { throw Usage("Choose production, staging, test, development, or -.") }
            try tree.setEnvironment(node.id, environment)
            return ["id": node.id.uuidString, "environment": environment?.rawValue ?? NSNull()]
        case "remove":
            try count(args, 1...1)
            let node = try item(args[0], in: tree)
            guard tree.children(of: node.id).isEmpty else { throw WorkspaceError.invalid("The folder is not empty.") }
            try tree.remove(node.id)
            return ["id": node.id.uuidString]
        case "auth", "cert":
            try count(args, action == "auth" ? 2...3 : 2...2)
            let node = try item(args[0], in: tree)
            guard var connection = node.connection else { throw Usage("Select an SSH or FTPS profile.") }
            if action == "cert" {
                guard let security = connection.ftpSecurity, security != .none, FTPSettings.isFingerprint(args[1]) else {
                    throw Usage("Select an FTPS profile and enter its verified SHA-256 certificate fingerprint.")
                }
                connection.ftpFingerprint = args[1]
            } else {
                guard !connection.isFTP else { throw Usage("This authentication setting applies to SSH.") }
                guard args[1] == SignInMode.sessionKey.rawValue || !connection.username.isEmpty else {
                    throw Usage("Give the session a user name first, with sessions edit.")
                }
                connection.signIn = SignInMode(rawValue: args[1])
                switch args[1] {
                case "password", "agent":
                    try count(args, 2...2)
                    connection.identityPath = nil
                    connection.usesAgent = args[1] == "agent" ? true : nil
                    connection.agentSocket = nil
                case "key":
                    try count(args, 3...3)
                    guard args[2].hasPrefix("/") else { throw Usage("Use an absolute private key path.") }
                    connection.identityPath = args[2]
                    connection.usesAgent = nil
                    connection.agentSocket = nil
                case SignInMode.questions.rawValue, SignInMode.sessionKey.rawValue:
                    try count(args, 2...2)
                    connection.identityPath = nil; connection.usesAgent = nil; connection.agentSocket = nil
                    if connection.usesSessionKey { connection.username = "" }
                default: throw Usage("Choose password, agent, key PATH, questions, or session-key.")
                }
            }
            try tree.updateConnection(node.id, name: node.name, connection: connection)
            return ["id": node.id.uuidString]
        case "import":
            try count(args, 2...4)
            let types: [String: FolderImportRequest.Source] = ["openssh": .openSSHConfig, "xshell": .xshellFolder,
                "mobaxterm": .mobaXterm, "putty": .putty, "csv": .csv, "gloamux": .gloamux]
            guard let source = types[args[0]] else { throw Usage("Unknown session import format.") }
            let url = URL(fileURLWithPath: args[1])
            guard url.path == args[1] else { throw Usage("Use an absolute path for import.") }
            let draft = try await Task.detached { try source.scan(url) }.value
            var result: [String: Any] = ["name": draft.name, "count": draft.entries.count,
                "skipped": draft.skipped.map { ["path": $0.path, "reason": $0.reason] }]
            if args.count >= 3 {
                let parent = try args.dropFirst(3).first.flatMap(folder)
                result["id"] = try tree.importProfiles(draft, name: args[2], parent: parent).uuidString
            } else {
                result["preview"] = draft.entries.map { entry -> [String: Any] in
                    var item: [String: Any] = ["name": entry.name, "path": entry.path,
                                               "host": entry.connection?.host ?? entry.container?.target ?? ""]
                    if let container = entry.container { item["kind"] = container.tool.rawValue }
                    if !entry.notes.isEmpty { item["notes"] = entry.notes }
                    return item
                }
            }
            return result
        case "export":
            try count(args, 2...3)
            let types: [String: SessionExport.Format] = ["csv": .csv, "gloamux": .gloamux, "openssh": .openSSH]
            guard let format = types[args[0]], args[1].hasPrefix("/") else {
                throw Usage("Use csv, gloamux, or openssh and an absolute path.")
            }
            let id = try args.dropFirst(2).first.map { try item($0, in: tree).id }
            let url = URL(fileURLWithPath: args[1])
            try SessionExport.data(tree, root: id, format: format).write(to: url, options: .withoutOverwriting)
            return ["path": url.path]
        default: throw Usage("Unknown sessions operation.")
        }
    }

    static func tcpPort(_ raw: String, allowAutomatic: Bool = false) throws -> Int {
        guard let port = Int(raw), ((allowAutomatic ? 0 : 1)...65535).contains(port) else { throw Usage("Enter a valid TCP port.") }
        return port
    }

    @MainActor private static func hosts(_ action: String, _ args: [String], _ model: WorkspaceModel) throws -> Any {
        let store = model.knownHosts
        if action == "history" {
            try count(args, 0...0)
            let dates = ISO8601DateFormatter()
            return store.history.map { event -> [String: Any] in
                var info: [String: Any] = ["date": dates.string(from: event.date), "endpoint": event.endpoint,
                                           "action": event.action.rawValue, "fingerprint": event.fingerprint]
                if let previous = event.previousFingerprint { info["previousFingerprint"] = previous }
                return info
            }
        }
        if action == "list" {
            try count(args, 0...0)
            return try store.trusted.map { ["endpoint": $0.endpoint, "fingerprint": try KnownHosts.fingerprint($0.key)] }
        }
        guard ["trust", "replace"].contains(action) else { throw Usage("Unknown hosts operation.") }
        try count(args, action == "trust" ? 3...3 : 4...4)
        let endpoint = args[0]
        guard endpoint.hasPrefix("["), let split = endpoint.lastIndex(of: ":"), split > endpoint.startIndex,
              endpoint[endpoint.index(before: split)] == "]" else { throw Usage("Use [host]:port for the SSH endpoint.") }
        let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<endpoint.index(before: split)])
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { throw Usage("Invalid endpoint host.") }
        let normalized = KnownHosts.endpoint(host: host, port: try tcpPort(String(endpoint[endpoint.index(after: split)...])))
        let keyParts = args[1].split(whereSeparator: \.isWhitespace)
        guard keyParts.count == 2 else { throw Usage("Pass the SSH public key as one quoted argument without the comment.") }
        let key = keyParts.joined(separator: " ")
        let fingerprint = try KnownHosts.fingerprint(key)
        guard fingerprint == args[2] else { throw WorkspaceError.invalid("The supplied key does not match your verified fingerprint.") }
        if action == "trust" {
            if try !store.isTrusted(endpoint: normalized, key: key) { try store.trust(endpoint: normalized, key: key) }
        } else {
            guard let previous = store.trustedKey(for: normalized), try KnownHosts.fingerprint(previous) == args[3] else {
                throw WorkspaceError.invalid("The current host key does not match the prior fingerprint.")
            }
            try store.replace(endpoint: normalized, expectedKey: previous, with: key)
        }
        return ["endpoint": normalized, "fingerprint": fingerprint]
    }

    @MainActor private static func commands(_ action: String, _ args: [String], _ model: WorkspaceModel) throws -> Any {
        let store = model.quickCommands
        if let error = store.loadError { throw WorkspaceError.invalid(error) }
        switch action {
        case "list":
            try count(args, 0...0)
            return store.entries.map { ["id": $0.id.uuidString, "name": $0.name, "text": $0.text] }
        case "add", "edit":
            try count(args, action == "add" ? 2...2 : 3...3)
            let id = action == "add" ? UUID() : try quickID(args[0], store)
            let command = QuickCommand(id: id, name: args[args.count - 2], text: args[args.count - 1])
            try store.save(command)
            return ["id": id.uuidString]
        case "remove":
            try count(args, 1...1)
            let id = try quickID(args[0], store)
            try store.remove(id)
            return ["id": id.uuidString]
        default: throw Usage("Unknown commands operation.")
        }
    }

    @MainActor static func quickID(_ value: String, _ store: QuickCommandStore) throws -> UUID {
        guard let id = UUID(uuidString: value), store.entries.contains(where: { $0.id == id }) else {
            throw WorkspaceError.invalid("No saved quick command with that ID.")
        }
        return id
    }

    @MainActor private static func appearance(_ action: String, _ args: [String], _ model: WorkspaceModel) throws -> Any {
        switch action {
        case "list":
            try count(args, 0...0)
            return model.themes.map { ["id": $0.id, "title": $0.title, "appearance": $0.appearance] }
        case "get":
            try count(args, 0...0)
        case "set":
            try count(args, 1...1)
            try model.selectTheme(args[0])
        default: throw Usage("Unknown appearance operation.")
        }
        return ["theme": model.themeID]
    }

    @MainActor private static func liveForwards(_ tab: SessionTab) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        for forward in tab.forwards {
            items.append(["id": forward.id.uuidString, "rule": try json(forward.rule), "boundPort": forward.handle.port,
                          "connections": await forward.handle.connectionCount()])
        }
        return items
    }

    /// Every SSH tab of every window with its running forwards, as the Tunnels window shows them.
    @MainActor static func tunnels(_ windows: [WorkspaceModel]) async -> Any {
        var result: [[String: Any]] = []
        for (index, owner) in windows.enumerated() {
            for tab in owner.tunnelTabs {
                guard !owner.workspaceLocked else {
                    result.append(["id": tab.id.uuidString, "title": tab.title, "window": index + 1, "locked": true])
                    continue
                }
                result.append(["id": tab.id.uuidString, "title": tab.title, "window": index + 1, "locked": false,
                               "forwards": (try? await liveForwards(tab)) ?? []])
            }
        }
        return result
    }

    @MainActor private static func forwards(_ action: String, _ args: [String], _ model: WorkspaceModel) async throws -> Any {
        switch action {
        case "live-list":
            try count(args, 1...1)
            return try await liveForwards(tab(args[0], [model]).tab)
        case "start":
            try count(args, 3...5)
            let forward = try await model.startForward(tab(args[0], [model]).tab, rule: rule(Array(args.dropFirst())))
            return ["id": forward.id.uuidString, "boundPort": forward.handle.port]
        case "stop":
            try count(args, 2...2)
            let tab = try tab(args[0], [model]).tab
            guard let item = tab.forwards.first(where: { $0.id == UUID(uuidString: args[1]) }) else {
                throw WorkspaceError.invalid("No active forward with that ID.")
            }
            await model.stopForward(tab, item)
            return ["id": item.id.uuidString]
        case "list", "add", "remove":
            try count(args, action == "list" ? 1...1 : action == "add" ? 3...5 : 2...2)
            let node = try item(args[0], in: model.sessionTree)
            guard var connection = node.connection, !connection.isFTP else { throw Usage("Choose a saved SSH connection.") }
            var rules = connection.forwardingRules ?? []
            if action == "list" { return try json(rules) }
            let id: UUID
            if action == "add" {
                let rule = try rule(Array(args.dropFirst()))
                rules.append(rule)
                id = rule.id
            } else {
                guard let index = rules.firstIndex(where: { $0.id == UUID(uuidString: args[1]) }) else {
                    throw WorkspaceError.invalid("No saved forward with that ID.")
                }
                id = rules.remove(at: index).id
            }
            connection.forwardingRules = rules.isEmpty ? nil : rules
            try model.sessionTree.updateConnection(node.id, name: node.name, connection: connection)
            return ["id": id.uuidString]
        default: throw Usage("Unknown forwards operation.")
        }
    }

    private static func rule(_ args: [String]) throws -> ForwardingRule {
        guard let kind = ForwardingKind(rawValue: args[0]) else { throw Usage("Choose local, remote, or dynamic.") }
        try count(args, kind == .dynamic ? 2...2 : 4...4)
        let listen = try tcpPort(args[1], allowAutomatic: true)
        let rule = try kind == .dynamic ? ForwardingRule(kind: kind, listenPort: listen)
            : ForwardingRule(kind: kind, listenPort: listen, host: args[2], port: tcpPort(args[3]))
        try rule.validate()
        return rule
    }

    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
}
