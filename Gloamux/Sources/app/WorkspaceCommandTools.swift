import Foundation

/// The rest of the tool windows on the command line: host key review, host discovery, recordings, and the agent
/// history's Clear button.
extension WorkspaceCommand {
    /// `hosts remove|export|clear-history|discover`, beside `list`, `history`, `trust`, and `replace`.
    @MainActor static func hostTools(_ action: String, _ args: [String], _ model: WorkspaceModel) async throws -> Any {
        let store = model.knownHosts
        switch action {
        case "remove":
            try count(args, 1...1)
            guard store.trustedKey(for: args[0]) != nil else { throw WorkspaceError.invalid("No trusted key for \(args[0]). Run gloamux hosts list.") }
            try store.remove(endpoint: args[0])
            return ["removed": args[0]]
        case "export":
            try count(args, 1...1)
            guard args[0].hasPrefix("/") else { throw Usage("Use an absolute path for the known_hosts file.") }
            let url = URL(fileURLWithPath: args[0])
            try Data(store.knownHostsText().utf8).write(to: url, options: .atomic)
            return ["path": url.path, "count": store.trusted.count]
        case "clear-history":
            try count(args, 0...0)
            store.clearHistory()
            return ["history": 0]
        case "discover":
            return try await discover(args, model)
        default: throw Usage("Unknown hosts operation.")
        }
    }

    /// `hosts discover bonjour|tailscale|aws [profile=P] [region=R] [add=all|ID,... user=NAME ssm=on]`, as Discover hosts.
    @MainActor private static func discover(_ args: [String], _ model: WorkspaceModel) async throws -> Any {
        guard let first = args.first, let source = DiscoveredHost.Source(rawValue: first) else {
            throw Usage("Choose bonjour, tailscale, or aws.")
        }
        let discovery = HostDiscoveryModel()
        discovery.source = source
        var add: String?, user: String?
        for (key, value) in try pairs(args.dropFirst()) {
            switch key {
            case "profile" where source == .aws: discovery.awsProfile = value
            case "region" where source == .aws: discovery.awsRegion = value
            case "ssm" where source == .aws: discovery.useSSM = try switchValue(value)
            case "add": add = value
            case "user": user = value
            default: throw Usage("Use add=, user=, and for aws also profile=, region=, and ssm=.")
            }
        }
        discovery.scan()
        // Bonjour answers for four seconds; the other sources finish when their command does.
        for _ in 0..<300 where discovery.busy { try await Task.sleep(nanoseconds: 100_000_000) }
        discovery.stop()
        if let error = discovery.error { throw WorkspaceError.invalid(error) }
        let hosts = discovery.hosts.map { host -> [String: Any] in
            var info: [String: Any] = ["id": host.id, "name": host.name, "host": host.host, "port": host.port, "online": host.online]
            if !host.detail.isEmpty { info["detail"] = host.detail }
            if let instance = host.instanceID { info["instance"] = instance }
            if let region = host.region { info["region"] = region }
            return info
        }
        guard let add else { return hosts }
        let ids = add == "all" ? Set(discovery.hosts.map(\.id)) : Set(add.split(separator: ",").map(String.init))
        guard ids.isSubset(of: Set(discovery.hosts.map(\.id))), !ids.isEmpty else {
            throw WorkspaceError.invalid("Choose IDs from the list this command prints without add=.")
        }
        discovery.chosen = ids
        if let user { discovery.username = user }
        let sessions = discovery.sessions()
        guard !sessions.isEmpty else { throw Usage("Enter a username with user=.") }
        let folder = try model.sessionTree.addFolder(named: T("Discovered") + " · " + T(source.title), parent: nil, sessions: sessions)
        return ["folder": folder.uuidString, "added": sessions.count]
    }

    /// `recordings list|export FILE PATH|remove FILE`: the Recordings window. Start and stop one with gloamux tabs record.
    @MainActor static func recordings(_ action: String, _ args: [String], _ model: WorkspaceModel) throws -> Any {
        let store = model.recordings
        store.reload()
        func recording(_ name: String) throws -> TerminalRecordings.Recording {
            guard let found = store.saved.first(where: { $0.url.lastPathComponent == name || $0.url.path == name }) else {
                throw WorkspaceError.invalid("No recording named \(name). Run gloamux recordings list.")
            }
            return found
        }
        switch action {
        case "list":
            try count(args, 0...0)
            let dates = ISO8601DateFormatter()
            return store.saved.map { ["file": $0.url.lastPathComponent, "title": $0.title, "date": dates.string(from: $0.date),
                                      "seconds": ($0.duration * 1000).rounded() / 1000, "bytes": $0.size] as [String: Any] }
        case "export":
            try count(args, 2...2)
            let source = try recording(args[0])
            guard args[1].hasPrefix("/") else { throw Usage("Use an absolute path for the .cast file.") }
            let url = URL(fileURLWithPath: args[1])
            guard !FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.invalid("\(url.path) already exists.") }
            try FileManager.default.copyItem(at: source.url, to: url)
            return ["path": url.path]
        case "remove":
            try count(args, 1...1)
            let found = try recording(args[0])
            try store.delete(found)
            return ["removed": found.url.lastPathComponent]
        default: throw Usage("Unknown recordings operation.")
        }
    }

    /// `history list [COUNT [SEARCH]]|show ID|log ID PATH|export PATH|remove ID|clear`: the Session Log.
    @MainActor static func history(_ action: String, _ args: [String], _ model: WorkspaceModel) throws -> Any {
        let history = model.history
        history.reload()
        func record(_ text: String) throws -> ConnectionRecord {
            guard let id = UUID(uuidString: text), let found = history.records.first(where: { $0.id == id }) else {
                throw WorkspaceError.invalid("No connection with that ID. Run gloamux history list.")
            }
            return found
        }
        func newFile(_ path: String) throws -> URL {
            guard path.hasPrefix("/") else { throw Usage("Use an absolute path.") }
            guard !FileManager.default.fileExists(atPath: path) else { throw WorkspaceError.invalid("\(path) already exists.") }
            return URL(fileURLWithPath: path)
        }
        switch action {
        case "list":
            try count(args, 0...2)
            guard let limit = args.first.map({ Int($0) }) ?? 50, limit > 0 else { throw Usage("Enter how many connections to list.") }
            return history.matching(args.count > 1 ? args[1] : "").prefix(limit).map { history.json($0) }
        case "show":
            try count(args, 1...1)
            return history.json(try record(args[0]), events: true)
        case "log":
            try count(args, 2...2)
            let url = try newFile(args[1])
            try writePrivate(Data(history.report(record(args[0])).utf8), to: url)
            return ["path": url.path]
        case "export":
            try count(args, 1...1)
            let url = try newFile(args[0])
            guard ["csv", "json"].contains(url.pathExtension.lowercased()) else { throw Usage("Use a path that ends in .csv or .json.") }
            try writePrivate(url.pathExtension.lowercased() == "csv" ? Data(history.csv(history.records).utf8) : history.exportJSON(history.records), to: url)
            return ["path": url.path, "count": history.records.count]
        case "remove":
            try count(args, 1...1)
            let found = try record(args[0])
            guard !history.open.contains(found.id) else { throw WorkspaceError.invalid("This connection is open.") }
            try history.remove([found.id])
            return ["removed": found.id.uuidString]
        case "clear":
            try count(args, 0...0)
            try history.clear()
            return ["remaining": history.records.count]
        default: throw Usage("Unknown history operation.")
        }
    }
}
