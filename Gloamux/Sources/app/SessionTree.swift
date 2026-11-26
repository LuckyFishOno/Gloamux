import Foundation
import Terminal
import Combine
import GloamuxNetwork
import FileTransfer

/// How a saved SSH session reaches its files.
enum FileProtocolChoice: String, Codable, CaseIterable, Sendable {
    case sftp, scp
}

/// Native, credential-free catalog. This format is not an original profile-folder format.
/// How an SSH session signs in when it uses neither a saved password nor a key.
public enum SignInMode: String, Codable, Sendable, CaseIterable {
    /// The server asks, such as for a code, and nothing is saved.
    case questions
    /// Like `questions`, with a key asked for on connecting that takes the place of the user name.
    case sessionKey = "session-key"
}

public struct SavedConnection: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var proxyHost: String?
    public var proxyPort: Int?
    /// SOCKS4, SOCKS5, or HTTP CONNECT. Saved catalogs from before this field mean SOCKS5.
    public var proxyKind: ProxyKind?
    public var identityPath: String?
    var opensFiles: Bool?
    /// The jump host this connection is reached from: the last one in `jumpPath`.
    public var jumpSessionID: UUID?
    /// Jump hosts dialed before `jumpSessionID`, first one first, when this session lists more than one. Only the first
    /// host of the list goes through its own jump host, as with OpenSSH's ProxyJump; the others' own settings are not used.
    var earlierJumpSessionIDs: [UUID]?
    /// The jump hosts this session lists, first dialed first; empty without one.
    var jumpPath: [UUID] { jumpSessionID.map { (earlierJumpSessionIDs ?? []) + [$0] } ?? [] }
    mutating func setJumpPath(_ path: [UUID]) {
        jumpSessionID = path.last
        earlierJumpSessionIDs = path.count > 1 ? Array(path.dropLast()) : nil
    }
    /// Offers the SSH agent's keys before the identity file.
    public var usesAgent: Bool?
    /// An agent socket other than `SSH_AUTH_SOCK`, such as one named by `IdentityAgent` in an OpenSSH config.
    public var agentSocket: String?
    var forwardingRules: [ForwardingRule]?
    /// Asks for Touch ID or the Mac password before every connection that uses a saved password or key, unless the
    /// password vault is unlocked. A new session starts with it on; sessions saved before it existed keep it off.
    public var confirmsEachConnection: Bool?
    /// The character encoding of the terminal, when it is not UTF-8.
    public var encoding: TerminalEncoding?
    /// Lines typed into the shell after it opens, one command per line.
    var startupCommands: String?
    /// Lets the server use this Mac's SSH agent (`ssh -A`).
    var forwardsAgent: Bool?
    /// Permits programs on this SSH server to use this Mac's XQuartz display.
    var forwardsX11: Bool?
    /// How files are reached over SSH: SFTP only or SCP only; nil tries SFTP and falls back to SCP.
    var fileProtocol: FileProtocolChoice?
    /// Set for an FTP or FTPS server, which this entry then is instead of an SSH one.
    var ftpSecurity: FTPSecurity?
    /// The SHA-256 fingerprint of a self-signed FTPS certificate the user checked.
    var ftpFingerprint: String?
    /// Set when the user answers the server each time instead of using a saved password or key.
    public var signIn: SignInMode?
    /// Where Remote files and the file transfer view open: a folder on the server, and one on this Mac.
    public var remoteFolder: String?
    public var localFolder: String?
    /// An FTP or FTPS server rather than an SSH one.
    public var isFileServer: Bool { isFTP }
    var usesSessionKey: Bool { signIn == .sessionKey }
    /// `user@`, or nothing for a session without a saved user name.
    var accountPrefix: String { username.isEmpty ? "" : SessionKey.masked(username) + "@" }
    var asksEachConnection: Bool { confirmsEachConnection == true }
    var isFTP: Bool { ftpSecurity != nil }
    public init(host: String, port: Int = 22, username: String, proxyHost: String? = nil, proxyPort: Int? = nil, identityPath: String? = nil, opensFiles: Bool = false, jumpSessionID: UUID? = nil,
                usesAgent: Bool = false, agentSocket: String? = nil, proxyKind: ProxyKind = .socks5,
                confirmsEachConnection: Bool = false) {
        self.host = host; self.port = port; self.username = username
        self.proxyHost = proxyHost; self.proxyPort = proxyPort; self.identityPath = identityPath
        self.opensFiles = opensFiles ? true : nil
        self.jumpSessionID = jumpSessionID
        self.usesAgent = usesAgent ? true : nil
        self.agentSocket = usesAgent ? agentSocket : nil
        self.proxyKind = proxyHost == nil || proxyKind == .socks5 || proxyKind == .none ? nil : proxyKind
        self.confirmsEachConnection = confirmsEachConnection ? true : nil
    }
    /// The proxy this connection dials, or `.direct`.
    var proxy: ProxyConfiguration {
        guard let proxyHost, let proxyPort else { return .direct }
        return ProxyConfiguration(kind: proxyKind ?? .socks5, host: proxyHost, port: proxyPort)
    }
    /// Signs in with keys only: an identity file, the SSH agent, or both.
    var usesKeys: Bool { identityPath != nil || usesAgent == true }
    func validate() throws {
        if isFTP {
            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...65535).contains(port), identityPath == nil,
                  usesAgent == nil, forwardsX11 != true, jumpSessionID == nil, earlierJumpSessionIDs == nil, proxyHost == nil, forwardingRules?.isEmpty ?? true,
                  ftpFingerprint.map({ FTPSettings.isFingerprint($0) }) ?? true else {
                throw WorkspaceError.invalid("Invalid saved connection settings.")
            }
            return
        }
        if let forwardingRules { try ForwardingRule.validateSaved(forwardingRules) }
        if jumpSessionID != nil && proxyHost != nil {
            throw WorkspaceError.invalid("Set the proxy on the jump host rather than on the destination.")
        }
        if let earlier = earlierJumpSessionIDs {
            guard jumpSessionID != nil, !earlier.isEmpty, Set(jumpPath).count == jumpPath.count,
                  jumpPath.count <= SessionTreeStore.maximumJumpHops else {
                throw WorkspaceError.invalid("Jump hosts must not loop and can chain at most 8 hosts.")
            }
        }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !username.isEmpty || usesSessionKey,
              (1...65535).contains(port), (proxyHost == nil) == (proxyPort == nil),
              proxyPort.map({ (1...65535).contains($0) }) ?? true,
              proxyHost.map({ !$0.isEmpty }) ?? true,
              identityPath.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true,
              agentSocket.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true,
              signIn == nil || !usesKeys, localFolder.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true,
              remoteFolder.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true else { throw WorkspaceError.invalid("Invalid saved connection settings.") }
    }
}

public struct SessionTreeNode: Codable, Identifiable, Equatable {
    public let id: UUID
    public var parent: UUID?
    public var name: String
    public var connection: SavedConnection?
    public var expanded: Bool
    /// Position among its siblings once the user has dragged items into place. Unordered items follow ordered ones,
    /// folders first and then by name, so catalogs saved before manual ordering keep their look.
    public var order: Int?
    /// Production, staging, test, or development. Sessions without one take their folder's.
    public var environment: SessionEnvironment?
    /// A shell in a container, pod, or SSM instance instead of an SSH connection.
    public var container: ContainerSession?
    public var isFolder: Bool { connection == nil && container == nil }
    public init(id: UUID = UUID(), parent: UUID? = nil, name: String, connection: SavedConnection? = nil, expanded: Bool = true, order: Int? = nil,
                environment: SessionEnvironment? = nil, container: ContainerSession? = nil) {
        self.id = id; self.parent = parent; self.name = name; self.connection = connection; self.expanded = expanded; self.order = order
        self.environment = environment; self.container = container
    }
}

/// Where a dragged item lands relative to the row it is dropped on.
public enum SessionTreeDropPlacement: Equatable, Sendable {
    case before, into, after

    /// Rows split by height: a session's top half means before and bottom half after. A folder's middle means into;
    /// its top quarter means before, and its bottom quarter means after unless it is open, where that edge sits
    /// directly above its own children.
    static func at(_ y: CGFloat, height: CGFloat, isFolder: Bool, expanded: Bool) -> SessionTreeDropPlacement {
        let fraction = height > 0 ? y / height : 0.5
        guard isFolder else { return fraction < 0.5 ? .before : .after }
        if fraction < 0.25 { return .before }
        return fraction > 0.75 && !expanded ? .after : .into
    }
}

/// How the tree lists items in each folder. Folders stay above sessions when sorting by name.
public enum SessionTreeSorting: String, Codable, CaseIterable, Sendable {
    /// The order the user dragged items into.
    case custom
    case nameAscending
    case nameDescending
}

@MainActor public final class SessionTreeStore: ObservableObject {
    /// Session keys typed since Gloamux opened, by saved session. Kept in memory only.
    var sessionKeys: [UUID: String] = [:]

    private struct Document: Codable {
        var version = 1
        var nodes: [SessionTreeNode]
        /// Absent means custom, so catalogs written before sorting options read the same.
        var sorting: SessionTreeSorting?
    }
    @Published public private(set) var nodes: [SessionTreeNode]
    @Published public private(set) var sorting: SessionTreeSorting = .custom
    @Published public var selection: UUID?
    @Published public var query = ""
    @Published public private(set) var clipboard: UUID?
    @Published public private(set) var cutting = false
    private let url: URL
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
            let bytes = try h.read(upToCount: 4_194_305) ?? Data()
            guard bytes.count <= 4_194_304 else { throw WorkspaceError.invalid("Session catalog exceeds 4 MiB.") }
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1 else { throw WorkspaceError.invalid("Unsupported session catalog version.") }
            try Self.validate(document.nodes); nodes = document.nodes; sorting = document.sorting ?? .custom
        } else { nodes = [] }
    }
    public func node(_ id: UUID?) -> SessionTreeNode? { nodes.first { $0.id == id } }
    /// The longest jump chain a session may use: up to this many hosts before the destination.
    nonisolated static let maximumJumpHops = 8

    /// Saved sessions that can serve as a jump host for `id`: anything whose own chain is valid and never passes
    /// back through `id`.
    func jumpCandidates(excluding id: UUID?) -> [SessionTreeNode] {
        let indexed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return nodes.filter { node in
            guard node.id != id, let connection = node.connection, !connection.usesSessionKey, let chain = Self.jumpChain(from: node.id, in: indexed) else { return false }
            return !chain.contains { $0.id == id } && chain.count < Self.maximumJumpHops
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The jump hosts a connection passes through, first hop (the one Gloamux dials) first.
    /// Returns nil when a link is missing, loops, or exceeds the limit.
    func jumpChain(for connection: SavedConnection, excluding id: UUID?) -> [SavedConnection]? {
        jumpRoute(for: connection, excluding: id)?.compactMap(\.connection)
    }

    /// The saved sessions of `jumpChain`, with their names, first hop first.
    func jumpRoute(for connection: SavedConnection, excluding id: UUID?) -> [SessionTreeNode]? {
        var indexed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let start = id ?? UUID()
        indexed[start] = SessionTreeNode(id: start, name: "_", connection: connection)
        return Self.jumpChain(from: start, in: indexed)
    }

    /// Hosts reached before `id`, ordered from the first hop to the last. The node itself is not included.
    /// A session's listed jump hosts come in order; the first of them is reached through its own jump hosts, if any.
    static func jumpChain(from id: UUID, in indexed: [UUID: SessionTreeNode]) -> [SessionTreeNode]? {
        var chain: [SessionTreeNode] = []   // From the destination backward.
        var seen: Set<UUID> = [id]
        var path = indexed[id]?.connection?.jumpPath ?? []
        while let first = path.first {
            for hop in path.reversed() {
                guard seen.insert(hop).inserted, chain.count < maximumJumpHops,
                      let node = indexed[hop], node.connection != nil else { return nil }
                chain.append(node)
            }
            path = indexed[first]?.connection?.jumpPath ?? []
        }
        return chain.reversed()
    }

    /// Items directly inside `parent`, in the order the tree shows them.
    public func children(of parent: UUID?) -> [SessionTreeNode] { children(of: parent, sortedBy: sorting) }

    func children(of parent: UUID?, sortedBy sorting: SessionTreeSorting) -> [SessionTreeNode] {
        nodes.filter { $0.parent == parent }.sorted {
            if sorting == .custom {
                switch ($0.order, $1.order) {
                case let (left?, right?) where left != right: return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            let order = $0.name.localizedStandardCompare($1.name)
            if order == .orderedSame { return $0.id.uuidString < $1.id.uuidString }
            return sorting == .nameDescending ? order == .orderedDescending : order == .orderedAscending
        }
    }

    public func setSorting(_ sorting: SessionTreeSorting) throws {
        guard sorting != self.sorting else { return }
        try write(nodes, sorting: sorting); self.sorting = sorting
    }
    /// Keeps the order on screen as the custom order and switches to it, so a drag can rearrange a tree sorted by name.
    public func keepShownOrder() throws {
        guard sorting != .custom else { return }
        var position: [UUID: Int] = [:]
        func walk(_ parent: UUID?) {
            for (index, item) in children(of: parent).enumerated() {
                position[item.id] = index
                if item.isFolder { walk(item.id) }
            }
        }
        walk(nil)
        let updated = nodes.map { item -> SessionTreeNode in var item = item; item.order = position[item.id] ?? item.order; return item }
        try write(updated, sorting: .custom); nodes = updated; sorting = .custom
    }
    public var destination: UUID? {
        guard let current = node(selection) else { return nil }
        return current.isFolder ? current.id : current.parent
    }
    /// Whether a row shows while searching: it matches itself, something inside it matches, or it sits inside a
    /// matching folder, so finding a folder lists everything under it.
    public func matches(_ id: UUID) -> Bool {
        guard let current = node(id) else { return false }
        if query.isEmpty || matchesItself(current) { return true }
        var parent = current.parent, depth = 0
        while let ancestor = node(parent), depth < 65 {
            if matchesItself(ancestor) { return true }
            parent = ancestor.parent; depth += 1
        }
        return containsMatch(id)
    }
    private func matchesItself(_ item: SessionTreeNode) -> Bool {
        item.name.localizedCaseInsensitiveContains(query) || item.connection?.host.localizedCaseInsensitiveContains(query) == true
    }
    private func containsMatch(_ id: UUID) -> Bool {
        children(of: id).contains { matchesItself($0) || containsMatch($0.id) }
    }
    private func commit(_ updated: [SessionTreeNode]) throws {
        try Self.validate(updated)
        try write(updated, sorting: sorting); nodes = updated
    }
    private func write(_ nodes: [SessionTreeNode], sorting: SessionTreeSorting) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(nodes: nodes, sorting: sorting == .custom ? nil : sorting))
        guard data.count <= 4_194_304 else { throw WorkspaceError.invalid("Session catalog exceeds 4 MiB.") }
        try writePrivate(data, to: url)
    }
    private static func validate(_ nodes: [SessionTreeNode]) throws {
        guard nodes.count <= 5000, Set(nodes.map(\.id)).count == nodes.count else { throw WorkspaceError.invalid("Invalid or oversized session tree.") }
        let indexed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var names = Set<String>()
        for node in nodes {
            let name = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 160, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), name == node.name else {
                throw WorkspaceError.invalid("Use a name of 1–160 characters without path separators or control characters.")
            }
            let key = (node.parent?.uuidString ?? "root") + "/" + nameKey(name)
            guard names.insert(key).inserted else { throw WorkspaceError.invalid("An item with that name already exists here.") }
            try node.connection?.validate()
            try node.container?.validate()
            if node.connection != nil && node.container != nil { throw WorkspaceError.invalid("Invalid saved connection settings.") }
            if node.connection?.jumpPath.isEmpty == false {
                guard jumpChain(from: node.id, in: indexed) != nil else {
                    throw WorkspaceError.invalid("Jump hosts must not loop and can chain at most 8 hosts.")
                }
            }
            var parent = node.parent, visited: Set<UUID> = [node.id]
            while let id = parent {
                guard visited.count < 65, visited.insert(id).inserted, let folder = indexed[id], folder.isFolder else {
                    throw WorkspaceError.invalid("Invalid parent, cycle or folder depth exceeds 64.")
                }
                parent = folder.parent
            }
        }
    }
    @discardableResult public func add(name: String, parent: UUID?, connection: SavedConnection? = nil,
                                       container: ContainerSession? = nil, environment: SessionEnvironment? = nil) throws -> UUID {
        let item = SessionTreeNode(parent: parent, name: name, connection: connection, environment: environment, container: container)
        var updated = nodes
        if let index = updated.firstIndex(where: { $0.id == parent && $0.isFolder }) { updated[index].expanded = true }
        try commit(updated + [item]); selection = item.id; return item.id
    }
    public func rename(_ id: UUID, to name: String) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.invalid("Item no longer exists.") }
        var updated = nodes; updated[index].name = name; try commit(updated)
    }
    func updateConnection(_ id: UUID, name: String, connection: SavedConnection) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id && !$0.isFolder }) else {
            throw WorkspaceError.invalid("Item no longer exists.")
        }
        var updated = nodes
        updated[index].name = name
        updated[index].connection = connection
        try commit(updated)
    }

    func updateContainer(_ id: UUID, name: String, container: ContainerSession, environment: SessionEnvironment?) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id && $0.container != nil }) else {
            throw WorkspaceError.invalid("Item no longer exists.")
        }
        var updated = nodes
        updated[index].name = name
        updated[index].container = container
        updated[index].environment = environment
        try commit(updated)
    }

    public func setEnvironment(_ id: UUID, _ environment: SessionEnvironment?) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        var updated = nodes; updated[index].environment = environment; try commit(updated)
    }

    /// The node's own environment, or the nearest folder's above it.
    func effectiveEnvironment(_ id: UUID?) -> SessionEnvironment? {
        var current = node(id), depth = 0
        while let item = current, depth < 66 {
            if let environment = item.environment { return environment }
            current = node(item.parent); depth += 1
        }
        return nil
    }

    /// Adds several sessions at once in a new folder, for discovered hosts.
    @discardableResult func addFolder(named name: String, parent: UUID?, sessions: [(String, SavedConnection?, ContainerSession?)]) throws -> UUID {
        let folder = SessionTreeNode(parent: parent, name: availableImportName(name, parent: parent))
        var updated = nodes + [folder]
        var names = Set<String>()
        for (name, connection, container) in sessions {
            var candidate = Self.importName(name), index = 2
            while !names.insert(Self.nameKey(candidate)).inserted { candidate = Self.importName(name) + " (\(index))"; index += 1 }
            updated.append(SessionTreeNode(parent: folder.id, name: candidate, connection: connection, container: container))
        }
        try commit(updated)
        selection = folder.id
        return folder.id
    }

    @discardableResult func importProfiles(_ draft: ProfileImport, name: String, parent: UUID?) throws -> UUID {
        guard !draft.entries.isEmpty else { throw WorkspaceError.invalid("No compatible profiles were found.") }
        let root = SessionTreeNode(parent: parent, name: name)
        var updated = nodes
        if let index = updated.firstIndex(where: { $0.id == parent && $0.isFolder }) {
            updated[index].expanded = true
        }
        updated.append(root)
        var folders: [[String]: UUID] = [:]
        var names: [UUID: Set<String>] = [:]
        var imported: [[String]: UUID] = [:]
        @discardableResult func append(_ name: String, to parent: UUID, connection: SavedConnection? = nil,
                                       container: ContainerSession? = nil) -> UUID {
            let safeName = Self.importName(name)
            var candidate = safeName
            var index = 2
            while !names[parent, default: []].insert(Self.nameKey(candidate)).inserted {
                let suffix = " (\(index))"
                candidate = String(safeName.prefix(160 - suffix.count)) + suffix
                index += 1
            }
            let item = SessionTreeNode(parent: parent, name: candidate, connection: connection, container: container)
            updated.append(item)
            return item.id
        }
        for path in draft.folders {
            let parentPath = Array(path.dropLast())
            let parentID = folders[parentPath] ?? root.id
            if let folderName = path.last { folders[path] = append(folderName, to: parentID) }
        }
        for entry in draft.entries {
            let folder = folders[Array(entry.components.dropLast())] ?? root.id
            imported[entry.components] = append(entry.name, to: folder, connection: entry.connection, container: entry.container)
        }
        for entry in draft.entries {
            guard let jump = entry.jump, let target = imported[jump], let id = imported[entry.components],
                  let index = updated.firstIndex(where: { $0.id == id }) else { continue }
            updated[index].connection?.jumpSessionID = target
            // Listed hops come along only when every one of them was imported and the chain stays valid.
            let earlier = (entry.earlierJumps ?? []).compactMap { imported[$0] }
            guard let listed = entry.earlierJumps, !listed.isEmpty, earlier.count == listed.count else { continue }
            updated[index].connection?.setJumpPath(earlier + [target])
            let indexed = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
            if (try? updated[index].connection?.validate()) == nil || Self.jumpChain(from: id, in: indexed) == nil {
                updated[index].connection?.setJumpPath([target])
            }
        }
        try commit(updated)
        selection = root.id
        query = ""
        return root.id
    }

    func availableImportName(_ base: String, parent: UUID?) -> String {
        let siblings = Set(nodes.filter { $0.parent == parent }.map { Self.nameKey($0.name) })
        let base = Self.importName(base)
        var candidate = base
        var index = 2
        while siblings.contains(Self.nameKey(candidate)) {
            let suffix = " (\(index))"
            candidate = String(base.prefix(160 - suffix.count)) + suffix
            index += 1
        }
        return candidate
    }

    private static func importName(_ name: String) -> String {
        let safe = name.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" ? "_" : String(scalar)
        }.joined()
        let trimmed = String(safe.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", ".", ".."].contains(trimmed) ? "_" : trimmed
    }

    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public func setExpanded(_ id: UUID, _ expanded: Bool) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }), nodes[index].isFolder else { return }
        var updated = nodes; updated[index].expanded = expanded; try commit(updated)
    }
    public func expandAll(_ expanded: Bool) throws {
        try commit(nodes.map { var item = $0; if item.isFolder { item.expanded = expanded }; return item })
    }
    private func subtree(_ id: UUID) -> [SessionTreeNode] {
        guard let item = node(id) else { return [] }
        return [item] + children(of: id).flatMap { subtree($0.id) }
    }
    public func connections(in id: UUID?) -> [SessionTreeNode] {
        if let id { return subtree(id).filter { !$0.isFolder } }
        return children(of: nil).flatMap { subtree($0.id) }.filter { !$0.isFolder }
    }
    public func remove(_ id: UUID) throws {
        let ids = Set(subtree(id).map(\.id)); try commit(nodes.filter { !ids.contains($0.id) })
        if let selected = selection, ids.contains(selected) { selection = nil }
        if let copied = clipboard, ids.contains(copied) { clipboard = nil }
    }
    public func prepareClipboard(_ id: UUID, cut: Bool) { clipboard = id; cutting = cut }
    public func paste(into parent: UUID?) throws {
        guard let source = clipboard, node(source) != nil else { throw WorkspaceError.invalid("Copy or cut an item first.") }
        try relocate(source, into: parent, copy: !cutting)
        if cutting { clipboard = nil }
    }
    public func relocate(_ id: UUID, into parent: UUID?, copy: Bool) throws {
        let branch = subtree(id); guard let root = branch.first else { throw WorkspaceError.invalid("Item no longer exists.") }
        guard !branch.contains(where: { $0.id == parent }) else { throw WorkspaceError.invalid("A folder cannot be placed inside itself.") }
        if !copy && root.parent == parent { return }
        var updated = nodes
        if copy {
            let ids = Dictionary(uniqueKeysWithValues: branch.map { ($0.id, UUID()) })
            for item in branch {
                updated.append(SessionTreeNode(id: ids[item.id]!, parent: item.id == id ? parent : item.parent.flatMap { ids[$0] }, name: item.name, connection: item.connection, expanded: item.expanded,
                                               environment: item.environment, container: item.container))
            }
        } else {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
            updated[index].parent = parent; updated[index].order = nil
        }
        try commit(updated)
    }

    /// Whether `id` may be dropped on `target` (nil is the root folder): never onto or inside itself, and only into folders.
    public func canDrop(_ id: UUID?, on target: UUID?, _ placement: SessionTreeDropPlacement) -> Bool {
        guard let id, node(id) != nil else { return false }
        let branch = Set(subtree(id).map(\.id))
        guard let target else { return true }
        guard let destination = node(target), !branch.contains(target) else { return false }
        return placement != .into || destination.isFolder
    }

    /// Applies a drop of `id` on `target` (nil is the root folder, where the item goes last).
    public func drop(_ id: UUID, on target: UUID?, _ placement: SessionTreeDropPlacement) throws {
        guard canDrop(id, on: target, placement) else { throw WorkspaceError.invalid("A folder cannot be placed inside itself.") }
        guard let target, let destination = node(target) else { return try move(id, into: nil) }
        switch placement {
        case .into: try move(id, into: target)
        case .before: try move(id, into: destination.parent, before: target)
        case .after:
            let siblings = children(of: destination.parent, sortedBy: .custom).map(\.id).filter { $0 != id }
            let next = siblings.firstIndex(of: target).flatMap { siblings.indices.contains($0 + 1) ? siblings[$0 + 1] : nil }
            try move(id, into: destination.parent, before: next)
        }
    }

    /// Moves an item to `parent`, just before `sibling` (or last when nil), and fixes the order of everything there.
    public func move(_ id: UUID, into parent: UUID?, before sibling: UUID? = nil) throws {
        let branch = subtree(id); guard !branch.isEmpty else { throw WorkspaceError.invalid("Item no longer exists.") }
        guard !branch.contains(where: { $0.id == parent }) else { throw WorkspaceError.invalid("A folder cannot be placed inside itself.") }
        guard parent == nil || node(parent)?.isFolder == true else { throw WorkspaceError.invalid("Items can only be placed in a folder.") }
        if sibling == id { return }
        // Positions always follow the custom order, so moving while sorted by name keeps the dragged order intact.
        var placed = children(of: parent, sortedBy: .custom).map(\.id).filter { $0 != id }
        if let sibling, let index = placed.firstIndex(of: sibling) { placed.insert(id, at: index) } else { placed.append(id) }
        let position = Dictionary(uniqueKeysWithValues: placed.enumerated().map { ($1, $0) })
        let updated = nodes.map { item -> SessionTreeNode in
            var item = item
            if item.id == id { item.parent = parent }
            if let order = position[item.id] { item.order = order }
            return item
        }
        guard updated != nodes else { return }
        try commit(updated)
    }
}
