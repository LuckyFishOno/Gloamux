import Foundation

/// The operations behind `gloamux mcp` (`agent TOOL ARGUMENTS_JSON CLIENT`) and `gloamux agents`. Every agent request
/// is checked against Settings › Agents and written to the activity history, whether it is allowed or not.
extension WorkspaceCommand {
    struct AgentRefusal: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    @MainActor static func agent(_ args: [String], _ model: WorkspaceModel, _ windows: [WorkspaceModel]) throws -> Any {
        try count(args, 3...3)
        let tool = args[0], client = String(args[2].prefix(80)).nonEmptyOr("Agent")
        guard let data = args[1].data(using: .utf8), let input = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Usage("Agent arguments must be a JSON object.")
        }
        let access = model.agents
        func refuse(_ text: String, session: String? = nil, detail: String? = nil) -> AgentRefusal {
            access.record(client: client, action: tool, session: session, detail: detail, outcome: "refused: " + text)
            return AgentRefusal(text)
        }
        guard access.enabled else { throw refuse("Agent access is off. Turn it on in Gloamux, in Settings › Agents.") }
        let open = [model] + windows.filter { $0 !== model }
        access.prune(existing: Set(model.sessionTree.nodes.map(\.id)))
        let allowed = model.sessionTree.nodes.filter { !$0.isFolder && access.allows($0.id) }

        func session(_ key: String = "session") throws -> SessionTreeNode {
            guard let selector = input[key] as? String, !selector.isEmpty else { throw refuse("Name a session from list_sessions.") }
            let node = allowed.first { $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame }
                ?? allowed.first { $0.name == selector }
            guard let node else { throw refuse("That session is not allowed for agents. Allow it in Gloamux, in Settings › Agents.") }
            return node
        }
        func liveTabs(of node: SessionTreeNode) -> [(WorkspaceModel, SessionTab)] {
            open.flatMap { owner in
                (owner.tabs + owner.sessionWindows.values.map(\.tab)).filter { $0.savedSessionID == node.id }.map { (owner, $0) }
            }
        }
        func tabInfo(_ tab: SessionTab) -> [String: Any] {
            ["tab": tab.id.uuidString, "connected": tab.connected, "ready": tab.terminalReady && tab.desktop == nil]
        }

        switch tool {
        case "list_sessions":
            access.record(client: client, action: "Listed sessions", outcome: "\(allowed.count) shown")
            return allowed.map { node -> [String: Any] in
                var info: [String: Any] = ["id": node.id.uuidString, "name": node.name, "destination": destination(node),
                                           "tabs": liveTabs(of: node).map { tabInfo($0.1) }]
                if let environment = model.sessionTree.effectiveEnvironment(node.id) { info["environment"] = environment.rawValue }
                return info
            }
        case "open_session":
            let node = try session()
            if let (owner, tab) = liveTabs(of: node).first(where: { $0.1.connected || $0.1.busy }) ?? liveTabs(of: node).first {
                owner.reveal(tab: tab.id)
                access.record(client: client, action: "Found open session", session: node.name, outcome: "shown")
                return tabInfo(tab).merging(["status": "already open"]) { $1 }
            }
            guard let tab = model.openSaved(node) else { throw refuse("This session cannot be opened.", session: node.name) }
            model.reveal(tab: tab.id)
            access.record(client: client, action: "Opened session", session: node.name, outcome: "opened")
            return tabInfo(tab).merging(["status": "opening; sign-in happens in Gloamux"]) { $1 }
        case "read_shared_output":
            let after = (input["after"] as? String).flatMap(UUID.init(uuidString:))
            var excerpts = access.excerpts
            if let after, let index = excerpts.firstIndex(where: { $0.id == after }) { excerpts = Array(excerpts[(index + 1)...]) }
            access.record(client: client, action: "Read shared output", outcome: "\(excerpts.count) excerpts")
            let dates = ISO8601DateFormatter()
            return ["excerpts": excerpts.map { ["id": $0.id.uuidString, "date": dates.string(from: $0.date), "session": $0.session, "text": $0.text] },
                    "note": excerpts.isEmpty ? "Nothing shared yet. Ask the user to choose Share with Agents in Gloamux's Terminal menu." : ""]
        case "propose_command":
            let node = try session()
            guard let command = input["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  command.count <= 4096, !command.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" || $0.value == 0x7F }) else {
                throw refuse("Give a command of up to 4096 characters without control characters.", session: node.name)
            }
            let requested = (input["tab"] as? String).flatMap(UUID.init(uuidString:))
            let candidates = liveTabs(of: node).filter { $0.1.connected && $0.1.terminalReady && $0.1.desktop == nil }
            guard let (owner, tab) = candidates.first(where: { requested == nil || $0.1.id == requested }) else {
                throw refuse("Open the session first with open_session, and wait until it is connected.", session: node.name, detail: command)
            }
            guard !tab.readOnly else { throw refuse("That terminal is read-only.", session: node.name, detail: command) }
            let reason = (input["reason"] as? String).map { String($0.prefix(500)) }.flatMap { Optional($0).nonEmpty }
            let proposal = AgentAccess.Proposal(id: UUID(), date: Date(), client: client, tabID: tab.id, terminalID: tab.terminalID,
                                                sessionID: node.id, session: node.name, destination: destination(node),
                                                command: command, reason: reason, status: .waiting)
            access.propose(proposal)
            owner.reveal(tab: tab.id)
            access.record(client: client, action: "Proposed a command", session: node.name, detail: command, outcome: "waiting for review")
            return ["proposal": proposal.id.uuidString, "status": "waiting for review in Gloamux", "tab": tab.id.uuidString]
        case "get_proposal":
            guard let id = (input["proposal"] as? String).flatMap(UUID.init(uuidString:)), let proposal = access.proposal(id),
                  proposal.client == client else { throw refuse("No proposal with that ID.") }
            return ["proposal": proposal.id.uuidString, "status": proposal.status.rawValue, "session": proposal.session, "command": proposal.command]
        default:
            throw refuse("Unknown tool.")
        }
    }

    /// Where a session connects, without anything secret: user@host:port, or the other kind's target.
    @MainActor static func destination(_ node: SessionTreeNode) -> String {
        if let connection = node.connection {
            return (connection.username.isEmpty ? "" : connection.username + "@") + connection.host + ":\(connection.port)"
        }
        if let other = node.container { return other.tool.rawValue + " " + other.summary }
        return node.name
    }

    /// `gloamux agents status|history|revoke [SESSION]|off`. Granting access stays in Gloamux.
    @MainActor static func agents(_ action: String, _ args: [String], _ model: WorkspaceModel) throws -> Any {
        let access = model.agents
        let names = Dictionary(uniqueKeysWithValues: model.sessionTree.nodes.map { ($0.id, $0.name) })
        switch action {
        case "status":
            try count(args, 0...0)
            return ["enabled": access.enabled,
                    "sessions": access.allowedSessions.map { ["id": $0.uuidString, "name": names[$0] ?? "?"] },
                    "waiting": access.proposals.filter { $0.status == .waiting }.count]
        case "history":
            try count(args, 0...1)
            let limit = try args.first.map { value -> Int in
                guard let number = Int(value), number > 0 else { throw Usage("Enter a positive number of events.") }
                return number
            } ?? 50
            let dates = ISO8601DateFormatter()
            return access.history.suffix(limit).map { event -> [String: Any] in
                var info: [String: Any] = ["date": dates.string(from: event.date), "client": event.client, "action": event.action, "outcome": event.outcome]
                if let session = event.session { info["session"] = session }
                if let detail = event.detail { info["detail"] = detail }
                return info
            }
        case "revoke":
            try count(args, 0...1)
            if let selector = args.first {
                let node = try item(selector, in: model.sessionTree)
                access.revoke(node.id, name: node.name)
                return ["revoked": node.id.uuidString]
            }
            access.revokeAll()
            return ["revoked": "all"]
        case "off":
            try count(args, 0...0)
            access.setEnabled(false)
            return ["enabled": false]
        default: throw Usage("Unknown agents operation.")
        }
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
