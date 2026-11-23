import AppKit
import SwiftUI

/// "Allow AI agents" in a saved session's right-click menu.
struct AgentAccessToggle: View {
    @ObservedObject var agents: AgentAccess
    let item: SessionTreeNode

    var body: some View {
        Toggle(T("Allow AI agents"), isOn: Binding(get: { agents.allowedSessions.contains(item.id) }, set: { on in
            if on { agents.allow(item.id, name: item.name) } else { agents.revoke(item.id, name: item.name) }
        }))
    }
}

/// Shows a command an agent proposed for this tab, with where it would run, until the user runs or declines it.
struct AgentReview: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var agents: AgentAccess
    @ObservedObject var tab: SessionTab
    var visible = true

    init(model: WorkspaceModel, tab: SessionTab, visible: Bool = true) {
        self.model = model
        self.agents = model.agents
        self.tab = tab
        self.visible = visible
    }

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { visible ? agents.waiting(in: tab.id) : nil }, set: { _ in })) { proposal in
            let stale = proposal.terminalID != tab.terminalID || !tab.connected
            VStack(alignment: .leading, spacing: 14) {
                Label(T("Run this command from an AI agent?"), systemImage: "sparkles").appFont(.title2.bold())
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text(T("Agent")).foregroundStyle(.secondary); Text(proposal.client) }
                    GridRow { Text(T("Session")).foregroundStyle(.secondary); Text(proposal.session) }
                    GridRow { Text(T("Runs on")).foregroundStyle(.secondary); Text(proposal.destination).textSelection(.enabled) }
                    if let reason = proposal.reason {
                        GridRow { Text(T("Reason")).foregroundStyle(.secondary); Text(reason).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                ScrollView {
                    Text(proposal.command)
                        .appFont(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("agentCommand")
                if stale {
                    Label(T("This session reconnected or closed, so the command can no longer run."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button(T("Decline")) { model.answerAgentProposal(tab, run: false) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(T("Run")) { model.answerAgentProposal(tab, run: true) }
                        .buttonStyle(.appProminent)
                        .disabled(stale || tab.readOnly)
                        .accessibilityIdentifier("agentRunButton")
                }
            }
            .padding(24)
            .frame(width: 560)
        }
    }
}

/// Settings › Agents: whether agents may connect, which sessions they see, and what they did.
struct AgentSettings: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var agents: AgentAccess
    @State private var confirmingRevoke = false

    init(model: WorkspaceModel) {
        self.model = model
        self.agents = model.agents
    }

    /// The command an agent's MCP settings run.
    static var command: String {
        let bundle = Bundle.main.bundleURL
        let tool = bundle.pathExtension == "app" ? bundle.appendingPathComponent("Contents/Resources/bin/gloamux").path : "gloamux"
        return (tool.contains(" ") ? "\"\(tool)\"" : tool) + " mcp"
    }

    private var sessions: [SessionTreeNode] {
        model.sessionTree.nodes.filter { !$0.isFolder }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { agents.enabled }, set: { agents.setEnabled($0) })) {
                    HStack(spacing: 6) {
                        Text(T("Allow AI agents"))
                        InfoButton(T("Agents such as Claude Code or Codex connect by running the MCP command below. They see only the sessions allowed here and never receive passwords or keys. They can open those sessions, read what you share with Terminal › Share with Agents, and propose commands. A proposed command runs only after you review it in Gloamux. Turning this off stops all of it at once."))
                    }
                }
                .accessibilityIdentifier("agentsEnabled")
                LabeledContent(T("MCP command")) {
                    HStack(spacing: 6) {
                        Text(Self.command).appFont(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.command, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(T("Copy"))
                    }
                }
            }
            Section {
                HStack(spacing: 6) {
                    Text(T("Allowed sessions"))
                    InfoButton(T("You can also allow a session from its right-click menu in the session list."))
                    Spacer()
                    Menu(T("Add")) {
                        ForEach(sessions.filter { !agents.allowedSessions.contains($0.id) }) { node in
                            Button(node.name) { agents.allow(node.id, name: node.name) }
                        }
                    }
                    .fixedSize()
                    .disabled(sessions.allSatisfy { agents.allowedSessions.contains($0.id) })
                }
                if agents.allowedSessions.isEmpty {
                    Text(T("No sessions")).foregroundStyle(.secondary)
                }
                ForEach(agents.allowedSessions, id: \.self) { id in
                    if let node = model.sessionTree.node(id) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name)
                                Text(WorkspaceCommand.destination(node)).appFont(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(T("Remove")) { agents.revoke(id, name: node.name) }.controlSize(.small)
                        }
                    }
                }
            }
            Section {
                HStack {
                    Text(T("Activity"))
                    Spacer()
                    Button(T("Clear")) { agents.clearHistory() }.controlSize(.small).disabled(agents.history.isEmpty)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if agents.history.isEmpty { Text(T("Nothing yet")).foregroundStyle(.secondary) }
                        ForEach(agents.history.reversed()) { event in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(event.date, format: .dateTime.month().day().hour().minute().second())
                                        .foregroundStyle(.secondary)
                                    Text(event.client).bold()
                                    Text(T(event.action))
                                    if let session = event.session { Text("· " + session).foregroundStyle(.secondary) }
                                }
                                if let detail = event.detail {
                                    Text(detail).appFont(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                                }
                                Text(T(event.outcome)).appFont(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .appFont(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 150)
                HStack {
                    Spacer()
                    Button(T("Revoke all access"), role: .destructive) { confirmingRevoke = true }
                        .disabled(!agents.enabled && agents.allowedSessions.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(-8)
        .confirmationDialog(T("Revoke all agent access?"), isPresented: $confirmingRevoke) {
            Button(T("Revoke all access"), role: .destructive) { agents.revokeAll() }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(T("Agent access turns off, every allowed session is removed, and commands waiting for review can no longer run."))
        }
    }
}
