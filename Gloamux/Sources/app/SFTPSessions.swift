import AppKit
import FileTransfer
import Ssh
import SwiftUI

/// Copies from an sftp command, waiting for its connection.
struct SFTPCopies: Equatable {
    var steps: [SFTPCommand.Step]
    /// Where downloads without their own place go.
    var localFolder: String
    var replaces: Bool
}

extension WorkspaceModel {
    /// What the session key sheet returns as its answer is read here: the key, or the whole command it came in.
    static let sessionKeyQuestion = SSHLoginChallenge(name: "", instruction: "", prompts: [.init(text: "Session key", hidden: true)])

    /// Uses the key typed earlier, or asks for it. Returns false when the user cancelled or the key could not be read.
    func askSessionKey(_ tab: SessionTab, epoch: UUID) async -> Bool {
        if tab.sessionKey != nil { return true }
        if let id = tab.savedSessionID, let key = sessionTree.sessionKeys[id] { tab.sessionKey = key; return true }
        guard let port = Int(tab.port) else { return false }
        tab.busy = true
        tab.status = "Waiting for the session key"
        defer { if tab.epoch == epoch { tab.busy = false } }
        do {
            let endpoint = KnownHosts.endpoint(host: tab.host, port: port)
            let answers = try await askLogin(tab, endpoint: endpoint, challenge: Self.sessionKeyQuestion, epoch: epoch, asksSessionKey: true)
            let read = try SessionKey.read(answers.first ?? "", host: tab.host, port: port)
            tab.sessionKey = read.key
            if let command = read.command, !command.transfers.isEmpty {
                tab.pendingCopies = SFTPCopies(steps: command.steps, localFolder: Self.copyFolder(command.localFolder ?? tab.localFolder), replaces: false)
            }
            return true
        } catch {
            guard tab.epoch == epoch else { return false }
            tab.status = "Disconnected"
            if !(error is CancellationError), (error as? SSHError) != .signInCancelled { tab.error = message(for: error) }
            return false
        }
    }

    /// `path` when that folder is on this Mac, and otherwise Downloads: a pasted command may name another Mac's folder.
    static func copyFolder(_ path: String?) -> String {
        if let path {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue { return expanded }
        }
        return (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser).path
    }

    /// Queues the copies of an sftp command in its order, following its `cd` and `lcd` lines.
    func startCopies(_ copies: SFTPCopies, via tab: SessionTab) async {
        do {
            let files = try await sftp(for: tab)
            var local = copies.localFolder
            var remote: String?
            func remotePath(_ path: String) async throws -> String {
                if path.hasPrefix("/") { return path }
                if remote == nil { remote = try await files.resolve(".") }
                return ((remote ?? "/") as NSString).appendingPathComponent(path)
            }
            func localPath(_ path: String) -> String {
                let expanded = (path as NSString).expandingTildeInPath
                return expanded.hasPrefix("/") ? expanded : (local as NSString).appendingPathComponent(expanded)
            }
            let policy: TransferConflictPolicy = copies.replaces ? .replace : .skip
            for step in copies.steps {
                switch step {
                case .localFolder(let path): local = Self.copyFolder(localPath(path))
                case .remoteFolder(let path): remote = try await remotePath(path)
                case .get(let path, let target, let recursive):
                    let source = try await remotePath(path)
                    var folder = local, newName: String?
                    if let target {
                        let place = localPath(target)
                        var isDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: place, isDirectory: &isDirectory), isDirectory.boolValue { folder = place }
                        else { folder = (place as NSString).deletingLastPathComponent; newName = (place as NSString).lastPathComponent }
                    }
                    let isFolder = recursive ? (try? await files.entry(at: source))?.isDirectory == true : false
                    transfers.add(TransferItem(direction: .download, name: (source as NSString).lastPathComponent, source: source,
                                               destinationFolder: folder, isFolder: isFolder, tab: tab, policy: policy, newName: newName))
                case .put(let path, let target, _):
                    let source = localPath(path)
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory)
                    guard exists else { throw WorkspaceError.invalid("\(source) was not found on this Mac.") }
                    var folder = try await remotePath("."), newName: String?
                    if folder.hasSuffix("/.") { folder = String(folder.dropLast(2)); if folder.isEmpty { folder = "/" } }
                    if let target {
                        let place = try await remotePath(target)
                        let isDirectory = target.hasSuffix("/") ? true : (try? await files.entry(at: place))?.isDirectory == true
                        if isDirectory { folder = place }
                        else { folder = (place as NSString).deletingLastPathComponent; newName = (place as NSString).lastPathComponent }
                    }
                    transfers.add(TransferItem(direction: .upload, name: (source as NSString).lastPathComponent, source: source,
                                               destinationFolder: folder, isFolder: isDirectory.boolValue, tab: tab, policy: policy, newName: newName))
                }
            }
        } catch { tab.error = message(for: error) }
    }

    /// The session a pasted command describes. With `asksKey`, its user name is a key for this connection only and is not saved.
    static func sessionSettings(for command: SFTPCommand, asksKey: Bool, localFolder: String?) -> SavedConnection {
        var settings = command.connection
        if asksKey { settings.signIn = .sessionKey; settings.username = "" }
        settings.opensFiles = true
        settings.remoteFolder = command.startFolder
        settings.localFolder = localFolder
        return settings
    }

    /// Saves the session a pasted command describes, and connects with the command's own key and copies when asked to.
    @discardableResult func saveSFTPSession(_ command: SFTPCommand, name: String, parent: UUID?, asksKey: Bool, localFolder: String,
                                            connects: Bool, copies: Bool, replaces: Bool) throws -> UUID {
        let settings = Self.sessionSettings(for: command, asksKey: asksKey, localFolder: localFolder)
        try settings.validate()
        let id = try sessionTree.add(name: name, parent: parent, connection: settings)
        guard connects, let node = sessionTree.node(id) else { return id }
        if asksKey, !command.connection.username.isEmpty { sessionTree.sessionKeys[id] = command.connection.username }
        let tab = openSaved(node)
        if copies, !command.transfers.isEmpty {
            tab?.pendingCopies = SFTPCopies(steps: command.steps, localFolder: localFolder, replaces: replaces)
        }
        return id
    }

    func showSFTPCommand(_ text: String = "") { sftpCommandRequest = SFTPCommandRequest(text: text) }
}

struct SFTPCommandRequest: Identifiable {
    let id = UUID()
    let text: String
}

/// Turns an sftp command, pasted once, into a saved session, after showing what it will do.
struct SFTPCommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    @State private var text: String
    @State private var name = ""
    @State private var named = false
    @State private var asksKey = true
    @State private var folder = ""
    @State private var copies = true
    @State private var replaces = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(model: WorkspaceModel, text: String) {
        self.model = model
        _text = State(initialValue: text)
    }

    private var command: SFTPCommand? { try? SFTPCommand.parse(text) }

    private var problem: String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try SFTPCommand.parse(text); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        let command = command
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Label(T("New session from sftp command"), systemImage: "arrow.up.arrow.down.circle").appFont(.title2.weight(.semibold))
                InfoButton(T("Paste the sftp command once. Gloamux saves the host, port, sign-in, and folders as a session. Later, open that session and enter only the new session key."))
            }
            TextEditor(text: $text)
                .appFont(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .focused($focused)
                .accessibilityLabel(T("sftp command"))
                .accessibilityIdentifier("sftpCommandField")
            if let command { summary(command) }
            if let shown = error ?? problem {
                Label(T(shown), systemImage: "exclamationmark.circle").foregroundStyle(.red).appFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DialogActions(cancel: { dismiss() }, title: T("Save and connect"), enabled: command != nil, identifier: "saveSFTPSession",
                          confirm: { save(connects: true) }) {
                Button(T("Save")) { save(connects: false) }.disabled(command == nil)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { focused = true; read() }
        .onChange(of: text) { _, _ in error = nil; read() }
    }

    @ViewBuilder private func summary(_ command: SFTPCommand) -> some View {
        Form {
            TextField(T("Name"), text: Binding(get: { name }, set: { name = $0; named = true }))
            LabeledContent(T("Server")) {
                Text(verbatim: KnownHosts.endpoint(host: command.connection.host, port: command.connection.port)).textSelection(.enabled)
            }
            if !command.connection.username.isEmpty {
                HStack(spacing: 6) {
                    Toggle(String(format: T("%@ is a session key"), SessionKey.masked(command.connection.username)), isOn: $asksKey)
                        .disabled(command.connection.identityPath != nil)
                    InfoButton(T("Gloamux asks for the session key each time instead of saving it. Turn this off when it is an ordinary user name."))
                }
            }
            LabeledContent(T("Download to")) {
                HStack(spacing: 6) {
                    Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(folder)
                    Button(T("Choose"), action: chooseFolder)
                }
            }
            if !command.transfers.isEmpty {
                Toggle(T("Copy these files after connecting"), isOn: $copies)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(command.transfers.prefix(6).enumerated()), id: \.offset) { _, step in row(step) }
                    if command.transfers.count > 6 { Text(String(format: T("%d more"), command.transfers.count - 6)) }
                }
                .appFont(.caption.monospaced()).foregroundStyle(.secondary)
                if copies { Toggle(T("Replace existing files"), isOn: $replaces) }
            }
            if !command.ignored.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label(T("Not included"), systemImage: "exclamationmark.triangle")
                    ForEach(Array(command.ignored.prefix(4).enumerated()), id: \.offset) { _, line in
                        Text(verbatim: String(line.prefix(120))).appFont(.caption.monospaced()).lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func row(_ step: SFTPCommand.Step) -> some View {
        switch step {
        case .get(let remote, _, _): Label { Text(verbatim: remote).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "arrow.down") }
        case .put(let local, _, _): Label { Text(verbatim: local).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "arrow.up") }
        default: EmptyView()
        }
    }

    private func read() {
        guard let command else { return }
        if !named { name = command.connection.host }
        asksKey = command.connection.identityPath == nil
            && (command.connection.username.isEmpty || SessionKey.looksLikeKey(command.connection.username))
        folder = WorkspaceModel.copyFolder(command.localFolder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func save(connects: Bool) {
        guard let command else { return }
        do {
            try model.saveSFTPSession(command, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                      parent: model.sessionTree.destination, asksKey: asksKey, localFolder: folder,
                                      connects: connects, copies: copies, replaces: replaces)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
