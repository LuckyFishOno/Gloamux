import SwiftUI

struct QuickCommandPanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var store: QuickCommandStore
    @ObservedObject var tab: SessionTab
    let close: () -> Void

    @State private var query = ""
    @State private var draft: QuickCommand?
    @State private var confirmation: QuickCommandRequest?
    @State private var approvedRun: QuickCommandRequest?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(T("Quick commands")).appFont(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").appFont(.caption.weight(.semibold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(T("Close quick commands"))
            }

            HStack(spacing: 7) {
                TextField(T("Filter commands"), text: $query)
                    .accessibilityIdentifier("quickCommandSearch")
                Button {
                    draft = QuickCommand(name: "", text: "")
                } label: {
                    Image(systemName: "plus")
                }
                .help(T("Add command"))
                .accessibilityLabel(T("Add command"))
                .accessibilityIdentifier("quickCommandAdd")
                .disabled(store.loadError != nil)
            }

            Label {
                Text(tab.canReceiveQuickCommands(in: model.layout) ? model.quickCommandDestination(for: tab) : T("Select an open terminal to use a command."))
                    .lineLimit(2)
            } icon: {
                Image(systemName: "terminal")
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)

            if let message = store.loadError ?? error {
                Text(T(message)).appFont(.caption).foregroundStyle(.red)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let commands = store.matching(query)
                    if commands.isEmpty, store.loadError == nil {
                        Text(T(store.entries.isEmpty ? "Add commands you use often." : "No matching commands."))
                            .appFont(.callout).foregroundStyle(.secondary).padding(.vertical, 7)
                    }
                    ForEach(commands) { command in
                        commandRow(command)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(13)
        .background(model.theme.sidebar.color)
        .sheet(item: $draft) { command in
            QuickCommandEditor(store: store, command: command)
        }
        .sheet(item: $confirmation, onDismiss: runApprovedCommand) { request in
            confirmationSheet(request)
        }
    }

    private func commandRow(_ command: QuickCommand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(command.name).appFont(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { draft = command } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .help(T("Edit command"))
                    .accessibilityLabel(T("Edit command"))
            }
            Text(command.text).appFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                .help(command.text)
            HStack(spacing: 6) {
                Button(T("Insert")) {
                    if let request = model.prepareQuickCommand(command, for: tab) { send(request, run: false) }
                }
                .help(T("Insert the command without pressing Return."))
                .accessibilityIdentifier("quickCommandInsert")
                Button(T("Run…")) { confirmation = model.prepareQuickCommand(command, for: tab) }
                    .accessibilityIdentifier("quickCommandRun")
            }
            .controlSize(.small)
            .buttonStyle(.app)
            .disabled(!tab.canReceiveQuickCommands(in: model.layout))
        }
        .padding(9)
        .background(model.theme.foreground.color.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
    }

    private func confirmationSheet(_ request: QuickCommandRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(T("Run saved command?")).appFont(.headline)
                InfoButton(T("Gloamux inserts the command and presses Return. Any text already entered stays on the line."))
            }
            Label(request.destination, systemImage: "terminal").appFont(.subheadline)
            ScrollView {
                Text(request.command.text).appFont(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 56, idealHeight: 76, maxHeight: 120)
            DialogActions(cancel: { confirmation = nil }, title: T("Run command"), returnConfirms: false, identifier: "quickCommandConfirmRun") {
                approvedRun = request
                confirmation = nil
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func runApprovedCommand() {
        guard let request = approvedRun else { return }
        approvedRun = nil
        send(request, run: true)
    }

    private func send(_ request: QuickCommandRequest, run: Bool) {
        error = model.sendQuickCommand(request, run: run) ? nil : "Couldn’t send the command to this terminal."
    }
}

private struct QuickCommandEditor: View {
    @ObservedObject var store: QuickCommandStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var text: String
    @State private var error: String?
    @State private var confirmsDeletion = false
    private let id: UUID

    init(store: QuickCommandStore, command: QuickCommand) {
        self.store = store
        id = command.id
        _name = State(initialValue: command.name)
        _text = State(initialValue: command.text)
    }

    var body: some View {
        let editing = store.entries.contains { $0.id == id }
        VStack(alignment: .leading, spacing: 12) {
            Text(T(editing ? "Edit command" : "Add command")).appFont(.headline)
            TextField(T("Command name"), text: $name)
                .accessibilityIdentifier("quickCommandName")
            TextField(T("Command text"), text: $text, axis: .vertical)
                .appFont(.body.monospaced())
                .lineLimit(3...6)
                .accessibilityIdentifier("quickCommandText")
            Text(T(error ?? "Use one line. Saved commands are stored locally as plain text."))
                .appFont(.callout).foregroundStyle(error == nil ? Color.secondary : .red)
            DialogActions(cancel: { dismiss() }, title: T("Save"), returnConfirms: false, identifier: "quickCommandSave",
                          confirm: { commit { try store.save(QuickCommand(id: id, name: name, text: text)) } }) {
                if editing {
                    Button(T("Delete"), role: .destructive) { confirmsDeletion = true }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 420)
        .alert(T("Delete saved command?"), isPresented: $confirmsDeletion) {
            Button(T("Cancel"), role: .cancel) { }
            Button(T("Delete"), role: .destructive) { commit { try store.remove(id) } }
        } message: {
            Text(name)
        }
    }

    private func commit(_ action: () throws -> Void) {
        do { try action(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
