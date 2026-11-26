import Foundation
import GloamuxNetwork
import Terminal
import Ssh

/// `gloamux sessions options`: the rest of the SSH and FTP connection form, beyond `edit` and `auth`.
extension WorkspaceCommand {
    static let sshOptions = ["jump", "proxy", "proxy-host", "proxy-port", "startup", "forward-agent", "x11", "open-files",
                             "files", "algorithms", "encoding", "confirm", "remote-folder", "local-folder"]

    @MainActor static func sessionOptions(_ args: [String], _ model: WorkspaceModel, live: Bool) async throws -> Any {
        guard args.count >= 2 else { throw Usage("Wrong number of arguments. Run gloamux sessions --help.") }
        let tree = model.sessionTree
        let node = try item(args[0], in: tree)
        guard var connection = node.connection else {
            throw Usage("Select a saved SSH or FTP connection. Use edit-other for other connections.")
        }
        let settings = try pairs(args.dropFirst())
        let allowed = connection.isFTP ? ["confirm"] : sshOptions
        for (key, _) in settings where !allowed.contains(key) {
            throw Usage("\(connection.isFTP ? "FTP connections take" : "SSH connections take") \(allowed.map { $0 + "=" }.joined(separator: ", ")).")
        }
        var asks = connection.asksEachConnection
        for (key, value) in settings {
            let clear = value == "-"
            switch key {
            case "jump":
                if clear { connection.setJumpPath([]); continue }
                // One item, or several separated by commas, first dialed first. A name with a comma still works alone.
                let hops: [SessionTreeNode]
                if let single = try? item(value, in: tree) { hops = [single] }
                else { hops = try value.split(separator: ",").map { try item(String($0).trimmingCharacters(in: .whitespaces), in: tree) } }
                let candidates = Set(tree.jumpCandidates(excluding: node.id).map(\.id))
                guard !hops.isEmpty, hops.allSatisfy({ candidates.contains($0.id) }), Set(hops.map(\.id)).count == hops.count,
                      hops.count <= SessionTreeStore.maximumJumpHops else {
                    throw Usage("Choose a saved SSH connection that does not lead back to this one, within \(SessionTreeStore.maximumJumpHops) hops.")
                }
                connection.setJumpPath(hops.map(\.id))
                // The proxy belongs on the jump host, as the form hides it once a jump host is chosen.
                connection.proxyHost = nil; connection.proxyPort = nil
            case "proxy":
                if clear || value == "none" { connection.proxyHost = nil; connection.proxyPort = nil; connection.proxyKind = nil; continue }
                guard let kind = ProxyKind(rawValue: value), kind != .none else { throw Usage("Choose socks5, socks4, http, or -.") }
                connection.proxyKind = kind
            case "proxy-host":
                let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
                connection.proxyHost = clear || host.isEmpty ? nil : host
                connection.proxyPort = connection.proxyHost == nil ? nil : connection.proxyPort ?? 1080
            case "proxy-port":
                connection.proxyPort = clear ? (connection.proxyHost == nil ? nil : 1080) : try tcpPort(value)
            case "startup":
                // \n separates lines, so a whole block fits in one argument.
                let text = clear ? "" : value.replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.split(separator: "\n", omittingEmptySubsequences: false).count <= 20 else {
                    throw Usage("Use up to 20 lines of startup commands.")
                }
                connection.startupCommands = text.isEmpty ? nil : String(text.prefix(8000))
            case "forward-agent": connection.forwardsAgent = try clear ? nil : switchValue(value) ? true : nil
            case "x11": connection.forwardsX11 = try clear ? nil : switchValue(value) ? true : nil
            case "open-files": connection.opensFiles = try clear ? nil : switchValue(value) ? true : nil
            case "files":
                guard clear || ["auto", "sftp", "scp"].contains(value) else { throw Usage("Choose auto, sftp, or scp.") }
                connection.fileProtocol = clear ? nil : FileProtocolChoice(rawValue: value)
            case "algorithms":
                guard clear || SSHAlgorithmSet(rawValue: value) != nil else { throw Usage("Choose modern or compatible.") }
                connection.sshAlgorithms = clear || value == "modern" ? nil : .compatible
            case "encoding":
                guard clear || TerminalEncoding(rawValue: value) != nil else {
                    throw Usage("Choose \(TerminalEncoding.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                let encoding = clear ? nil : TerminalEncoding(rawValue: value)
                connection.encoding = encoding == .utf8 ? nil : encoding
            case "remote-folder": connection.remoteFolder = clear ? nil : value
            case "local-folder":
                let path = (value as NSString).expandingTildeInPath
                guard clear || path.hasPrefix("/") else { throw Usage("Use an absolute path for local-folder.") }
                connection.localFolder = clear ? nil : path
            case "confirm": asks = try clear ? false : switchValue(value)
            default: break
            }
        }
        if connection.proxyHost != nil, connection.proxyKind == nil { connection.proxyKind = .socks5 }
        if connection.proxyHost == nil { connection.proxyPort = nil }
        try connection.validate()
        if asks != connection.asksEachConnection {
            // As in the form, changing whether a session asks on every connection needs the owner, in Gloamux.
            guard live else { throw WorkspaceError.invalid("Open Gloamux to change confirm: it asks for Touch ID or the Mac password.") }
            let before = node
            guard await model.authorizeAskChange() else { throw WorkspaceError.invalid("Touch ID or the Mac password is required to change this setting.") }
            // The session may have changed while Gloamux waited; saving the copy made before the wait would undo that.
            guard let now = tree.node(node.id), now == before else {
                throw WorkspaceError.invalid("The session changed while Gloamux waited for confirmation. Nothing was saved; run the command again.")
            }
            connection.confirmsEachConnection = asks
        }
        try tree.updateConnection(node.id, name: node.name, connection: connection)
        return ["id": node.id.uuidString]
    }

    /// What `sessions show` prints for these settings.
    @MainActor static func describeOptions(_ connection: SavedConnection, _ tree: SessionTreeStore) -> [String: Any] {
        var info: [String: Any] = ["confirm": connection.asksEachConnection]
        guard !connection.isFTP else { return info }
        info["auth"] = connection.signIn?.rawValue ?? (connection.identityPath != nil ? "key" : connection.usesAgent == true ? "agent" : "password")
        if let folder = connection.remoteFolder { info["remote-folder"] = folder }
        if let folder = connection.localFolder { info["local-folder"] = folder }
        if let key = connection.identityPath { info["key"] = key }
        if !connection.jumpPath.isEmpty {
            info["jump"] = connection.jumpPath.map { tree.node($0)?.name ?? $0.uuidString }.joined(separator: ",")
        }
        if let host = connection.proxyHost, let port = connection.proxyPort {
            info["proxy"] = (connection.proxyKind ?? .socks5).rawValue
            info["proxy-host"] = host
            info["proxy-port"] = port
        }
        if let startup = connection.startupCommands { info["startup"] = startup }
        info["forward-agent"] = connection.forwardsAgent == true
        info["x11"] = connection.forwardsX11 == true
        info["open-files"] = connection.opensFiles == true
        info["files"] = connection.fileProtocol?.rawValue ?? "auto"
        info["algorithms"] = (connection.sshAlgorithms ?? .modern).rawValue
        info["encoding"] = (connection.encoding ?? .utf8).rawValue
        return info
    }
}
