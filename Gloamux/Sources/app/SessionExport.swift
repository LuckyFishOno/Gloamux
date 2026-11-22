import Foundation

/// Writes saved sessions for a backup, a teammate, or a spreadsheet.
///
/// The catalog holds no passwords, and none are written: passwords stay in this Mac's keychain and the vault. Key
/// files are referred to by path only, and paths under the home folder are written as `~/…` so the file names no
/// user's own folder.
@MainActor enum SessionExport {
    enum Format: CaseIterable {
        /// Every setting, folders and jump hosts included, for importing into Gloamux.
        case gloamux
        /// One row per session, for spreadsheets and other tools.
        case csv
        /// `Host` blocks for `~/.ssh/config`, so the same sessions work with `ssh` in any terminal.
        case openSSH

        var fileExtension: String {
            switch self {
            case .gloamux: return SessionsFile.fileExtension
            case .csv: return "csv"
            case .openSSH: return "conf"
            }
        }
    }

    struct Collected {
        var name: String
        var folders: [[String]] = []
        var sessions: [(folder: [String], node: SessionTreeNode)] = []
    }

    /// Everything under `root` (the whole tree when nil), with paths relative to it.
    static func collect(_ store: SessionTreeStore, root: UUID?) -> Collected {
        let top = root.flatMap(store.node)
        var collected = Collected(name: top?.name ?? "Gloamux sessions")
        func walk(_ parent: UUID?, path: [String]) {
            for child in store.children(of: parent) {
                if child.isFolder {
                    collected.folders.append(path + [child.name])
                    walk(child.id, path: path + [child.name])
                } else {
                    collected.sessions.append((path, child))
                }
            }
        }
        if let top, !top.isFolder { collected.sessions = [([], top)] } else { walk(root, path: []) }
        return collected
    }

    static func data(_ store: SessionTreeStore, root: UUID?, format: Format, now: Date = Date()) throws -> Data {
        let collected = collect(store, root: root)
        guard !collected.sessions.isEmpty || !collected.folders.isEmpty else {
            throw WorkspaceError.invalid("There are no sessions to export.")
        }
        var paths: [UUID: [String]] = [:]
        for session in collected.sessions { paths[session.node.id] = session.folder + [session.node.name] }
        func jump(_ connection: SavedConnection) -> (path: [String]?, address: String?) {
            guard let id = connection.jumpSessionID else { return (nil, nil) }
            if let path = paths[id] { return (path, nil) }
            guard let target = store.node(id)?.connection else { return (nil, nil) }
            return (nil, "\(target.username)@\(target.host)" + (target.port == 22 ? "" : ":\(target.port)"))
        }

        switch format {
        case .gloamux:
            let items = collected.sessions.compactMap { session -> SessionsFile.Item? in
                guard var connection = session.node.connection else { return nil }
                let (path, address) = jump(connection)
                connection.jumpSessionID = nil
                connection.identityPath = shareable(connection.identityPath)
                connection.agentSocket = shareable(connection.agentSocket)
                return SessionsFile.Item(folder: session.folder, name: session.node.name, connection: connection,
                                         jump: path, jumpAddress: address)
            }
            let file = SessionsFile(name: collected.name, exported: now, folders: collected.folders, items: items)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(file)
        case .csv:
            var lines = [CSVSessionImport.columns.map(field).joined(separator: ",")]
            for session in collected.sessions {
                guard let connection = session.node.connection else { continue }
                let (path, address) = jump(connection)
                let proxyKind = connection.proxyHost == nil ? "" : (connection.proxyKind ?? .socks5).rawValue
                let row = [session.folder.joined(separator: "/"), session.node.name, connection.host, String(connection.port),
                           connection.username, connection.opensFiles == true ? "sftp" : "ssh",
                           shareable(connection.identityPath) ?? "", proxyKind, connection.proxyHost ?? "",
                           connection.proxyPort.map(String.init) ?? "", path?.joined(separator: "/") ?? address ?? ""]
                lines.append(row.map(field).joined(separator: ","))
            }
            // A byte order mark lets Excel open names in Chinese and other scripts correctly.
            return Data("\u{FEFF}".utf8) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        case .openSSH:
            return Data(openSSHConfig(collected, store: store, now: now).utf8)
        }
    }

    /// One `Host` block per session. The alias is the folder path and name joined with dashes, made unique, so
    /// `ssh work-web-1` connects. Jump hosts become `ProxyJump`, proxies a `ProxyCommand` through `nc`, and saved
    /// forwarding rules `LocalForward`, `RemoteForward`, and `DynamicForward`.
    static func openSSHConfig(_ collected: Collected, store: SessionTreeStore, now: Date) -> String {
        var used = Set<String>()
        var aliases: [UUID: String] = [:]
        for session in collected.sessions {
            var alias = alias(session.folder + [session.node.name])
            if used.contains(alias) {
                var number = 2
                while used.contains("\(alias)-\(number)") { number += 1 }
                alias += "-\(number)"
            }
            used.insert(alias)
            aliases[session.node.id] = alias
        }
        let formatter = ISO8601DateFormatter()
        var out = "# Gloamux sessions · \(collected.name.replacingOccurrences(of: "\n", with: " ")) · \(formatter.string(from: now))\n"
        out += "# No passwords are included. Add these blocks to ~/.ssh/config, or Include this file from it.\n"
        for session in collected.sessions {
            // FTP servers have no place in an SSH config.
            guard let connection = session.node.connection, !connection.isFTP, let alias = aliases[session.node.id] else { continue }
            out += "\n# \((session.folder + [session.node.name]).joined(separator: " / ").replacingOccurrences(of: "\n", with: " "))\n"
            out += "Host \(alias)\n"
            out += "    HostName \(configValue(connection.host))\n"
            if connection.port != 22 { out += "    Port \(connection.port)\n" }
            if !connection.username.isEmpty { out += "    User \(configValue(connection.username))\n" }
            if let identity = shareable(connection.identityPath) {
                out += "    IdentityFile \(configValue(identity))\n    IdentitiesOnly yes\n"
            }
            if let socket = shareable(connection.agentSocket) { out += "    IdentityAgent \(configValue(socket))\n" }
            if connection.forwardsAgent == true { out += "    ForwardAgent yes\n" }
            if let id = connection.jumpSessionID {
                if let jump = aliases[id] { out += "    ProxyJump \(jump)\n" }
                else if let target = store.node(id)?.connection {
                    out += "    ProxyJump \(target.username.isEmpty ? "" : target.username + "@")\(target.host)\(target.port == 22 ? "" : ":\(target.port)")\n"
                }
            } else if let host = connection.proxyHost, let port = connection.proxyPort {
                let kind = connection.proxyKind ?? .socks5
                let flag = kind == .http ? "connect" : kind == .socks4 ? "4" : "5"
                if kind != .none { out += "    ProxyCommand nc -X \(flag) -x \(host):\(port) %h %p\n" }
            }
            for rule in connection.forwardingRules ?? [] {
                switch rule.kind {
                case .local:
                    if let host = rule.host, let port = rule.port { out += "    LocalForward \(rule.listenPort) \(bracketed(host)):\(port)\n" }
                case .remote:
                    if let host = rule.host, let port = rule.port { out += "    RemoteForward \(rule.listenPort) \(bracketed(host)):\(port)\n" }
                case .dynamic:
                    out += "    DynamicForward \(rule.listenPort)\n"
                }
            }
        }
        return out
    }

    /// A `Host` alias: letters, digits, dots, and dashes only.
    static func alias(_ path: [String]) -> String {
        let joined = path.joined(separator: "-").lowercased()
        var alias = String(joined.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-" ? Character(scalar) : "-"
        })
        while alias.contains("--") { alias = alias.replacingOccurrences(of: "--", with: "-") }
        alias = alias.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return alias.isEmpty ? "session" : alias
    }

    /// Quotes a value with spaces, as ssh_config allows.
    static func configValue(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\"", with: "")
        return clean.contains(" ") ? "\"\(clean)\"" : clean
    }

    private static func bracketed(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }

    /// `~/…` for a path in the home folder.
    static func shareable(_ path: String?, home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) -> String? {
        guard let path else { return nil }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A CSV field, quoted when needed. Text a spreadsheet would run as a formula gets a leading apostrophe.
    static func field(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+@".contains(first) { value = "'" + value }
        // Scalars: "\r\n" is a single Character and would not match "\n" or "\r".
        guard value.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
