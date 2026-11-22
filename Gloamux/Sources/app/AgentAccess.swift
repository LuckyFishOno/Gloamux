import AppKit

/// What AI agents may do through `gloamux mcp`, for one workspace folder. Nothing is allowed until the user turns
/// agent access on in Settings › Agents and allows a saved session. Agents see allowed sessions by name and
/// destination, open them in Gloamux, read only what the user shares, and propose commands that run only after the
/// user reviews them in Gloamux. Passwords and keys never leave Gloamux.
@MainActor public final class AgentAccess: ObservableObject {
    struct Settings: Codable, Equatable {
        var enabled = false
        var sessions: [UUID] = []
    }

    /// One thing an agent asked for, and what happened.
    public struct Event: Codable, Identifiable, Equatable {
        public var id = UUID()
        public let date: Date
        public let client: String
        public let action: String
        public var session: String?
        public var detail: String?
        public let outcome: String
    }

    /// Terminal text the user chose to show agents.
    public struct Excerpt: Identifiable, Equatable {
        public let id: UUID
        public let date: Date
        public let session: String
        public let text: String
    }

    /// A command an agent wants to run, held until the user answers in Gloamux. It belongs to one live terminal:
    /// once that terminal reconnects or closes, the proposal can no longer run.
    public struct Proposal: Identifiable, Equatable {
        public enum Status: String { case waiting, sent, declined, expired, revoked }
        public let id: UUID
        public let date: Date
        public let client: String
        public let tabID: UUID
        let terminalID: UUID
        public let sessionID: UUID
        public let session: String
        public let destination: String
        public let command: String
        public let reason: String?
        public var status: Status
    }

    static let historyLimit = 500
    static let excerptLimit = 20
    static let proposalLimit = 50

    @Published private(set) var settings = Settings()
    @Published public private(set) var history: [Event] = []
    @Published public private(set) var excerpts: [Excerpt] = []
    @Published public private(set) var proposals: [Proposal] = []

    private let settingsURL: URL
    private let historyURL: URL
    private static var shared: [URL: AgentAccess] = [:]

    /// The one store for a workspace folder, so every window of it sees the same permissions and requests.
    static func store(for storage: URL) -> AgentAccess {
        let key = storage.standardizedFileURL
        if let existing = shared[key] { return existing }
        let store = AgentAccess(storage: key)
        shared[key] = store
        return store
    }

    private init(storage: URL) {
        settingsURL = storage.appendingPathComponent("agent-access.json")
        historyURL = storage.appendingPathComponent("agent-activity.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: settingsURL), let value = try? decoder.decode(Settings.self, from: data) { settings = value }
        if let data = try? Data(contentsOf: historyURL), let value = try? decoder.decode([Event].self, from: data) { history = value }
    }

    public var enabled: Bool { settings.enabled }
    public var allowedSessions: [UUID] { settings.sessions }
    public func allows(_ session: UUID) -> Bool { settings.enabled && settings.sessions.contains(session) }

    // MARK: Permissions

    public func setEnabled(_ on: Bool) {
        settings.enabled = on
        save()
        if !on { revokeProposals { _ in true } }
        record(client: "Gloamux", action: on ? "Agent access turned on" : "Agent access turned off", outcome: "done")
    }

    public func allow(_ session: UUID, name: String) {
        guard !settings.sessions.contains(session) else { return }
        settings.sessions.append(session)
        save()
        record(client: "Gloamux", action: "Session allowed", session: name, outcome: "done")
    }

    public func revoke(_ session: UUID, name: String) {
        settings.sessions.removeAll { $0 == session }
        save()
        revokeProposals { $0.sessionID == session }
        record(client: "Gloamux", action: "Session access removed", session: name, outcome: "done")
    }

    /// Turns access off and forgets every allowed session; waiting proposals can no longer run.
    public func revokeAll() {
        settings = Settings()
        save()
        excerpts = []
        revokeProposals { _ in true }
        record(client: "Gloamux", action: "All agent access revoked", outcome: "done")
    }

    /// Drops sessions that no longer exist in the tree.
    func prune(existing: Set<UUID>) {
        let kept = settings.sessions.filter(existing.contains)
        if kept != settings.sessions { settings.sessions = kept; save() }
    }

    private func revokeProposals(_ matching: (Proposal) -> Bool) {
        for index in proposals.indices where proposals[index].status == .waiting && matching(proposals[index]) {
            proposals[index].status = .revoked
        }
    }

    // MARK: Shared text and proposals

    @discardableResult func share(_ text: String, session: String) -> Excerpt? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        let excerpt = Excerpt(id: UUID(), date: Date(), session: session, text: String(trimmed.utf8.suffix(65536)) ?? trimmed)
        excerpts.append(excerpt)
        if excerpts.count > Self.excerptLimit { excerpts.removeFirst(excerpts.count - Self.excerptLimit) }
        record(client: "Gloamux", action: "Output shared with agents", session: session, outcome: "done")
        return excerpt
    }

    public func clearExcerpts() { excerpts = [] }

    func propose(_ proposal: Proposal) {
        proposals.append(proposal)
        if proposals.count > Self.proposalLimit { proposals.removeFirst(proposals.count - Self.proposalLimit) }
    }

    func proposal(_ id: UUID) -> Proposal? { proposals.first { $0.id == id } }

    /// The proposal waiting in a tab, oldest first.
    public func waiting(in tab: UUID) -> Proposal? { proposals.first { $0.tabID == tab && $0.status == .waiting } }

    func setStatus(_ id: UUID, _ status: Proposal.Status) {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[index].status = status
    }

    // MARK: History

    func record(client: String, action: String, session: String? = nil, detail: String? = nil, outcome: String) {
        history.append(Event(date: Date(), client: client, action: action, session: session, detail: detail, outcome: outcome))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(history) { try? writePrivate(data, to: historyURL) }
    }

    public func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: historyURL)
    }

    private func save() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) { try? writePrivate(data, to: settingsURL) }
    }
}

extension WorkspaceModel {
    public var agents: AgentAccess { AgentAccess.store(for: storage) }

    /// The text selected in the focused terminal, if any.
    static func terminalSelection() -> String? {
        guard let view = NSApp?.keyWindow?.firstResponder as? NSTextView, view.selectedRange().length > 0 else { return nil }
        return (view.string as NSString).substring(with: view.selectedRange())
    }

    /// Shares a terminal's selection, or else the output of its last command, or else the screen, with agents.
    func shareWithAgents(_ tab: SessionTab, selection: String? = nil) {
        let screen = tab.screen
        var text = selection ?? ""
        if text.isEmpty, let mark = screen.commandMarks.last(where: { $0.outputLine != nil && $0.endLine != nil }),
           let output = mark.outputLine, let end = mark.endLine, end > output {
            text = (mark.command.map { "$ " + $0 + "\n" } ?? "") + screen.text(lines: output..<end)
        }
        if text.isEmpty {
            let top = screen.absoluteLine(ofRow: 0)
            text = screen.text(lines: top..<(top + screen.rows))
        }
        agents.share(text, session: tab.title)
    }

    /// Runs or declines the command an agent proposed in this tab, after the user has read it.
    func answerAgentProposal(_ tab: SessionTab, run: Bool) {
        guard let proposal = agents.waiting(in: tab.id) else { return }
        guard run else {
            agents.setStatus(proposal.id, .declined)
            agents.record(client: proposal.client, action: "Command declined", session: proposal.session, detail: proposal.command, outcome: "declined")
            return
        }
        guard agents.allows(proposal.sessionID), tab.terminalID == proposal.terminalID, tab.connected, tab.terminalReady, !tab.readOnly,
              let bytes = TerminalKeyboard.pasteBytes(proposal.command, bracketed: tab.screen.bracketedPaste),
              enqueueTerminalInput(tab, bytes: bytes + [0x0D]) else {
            agents.setStatus(proposal.id, .expired)
            agents.record(client: proposal.client, action: "Command not sent", session: proposal.session, detail: proposal.command,
                          outcome: "the session changed")
            return
        }
        trackTyping(tab, bytes + [0x0D])
        agents.setStatus(proposal.id, .sent)
        agents.record(client: proposal.client, action: "Command run after review", session: proposal.session, detail: proposal.command, outcome: "sent")
    }
}
