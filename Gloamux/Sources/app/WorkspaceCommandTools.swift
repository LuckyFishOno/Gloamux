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
}
