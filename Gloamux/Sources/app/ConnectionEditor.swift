import SwiftUI
import GloamuxNetwork
import Ssh
import FileTransfer

/// A saved entry is edited independently of any live connection.
struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: SessionTreeStore
    let item: SessionTreeNode?
    let parent: UUID?
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var identityPath: String?
    @State private var usesAgent: Bool
    @State private var confirmsEachConnection: Bool
    private let vaultOverrideNote = "If you have set up a password vault and it is unlocked, this setting does not apply: connections use the vault without asking."
    @State private var opensFiles: Bool
    /// Jump hosts, first dialed first.
    @State private var jumpPath: [UUID]
    @State private var usesProxy: Bool
    @State private var proxyHost: String
    @State private var proxyPort: String
    @State private var proxyKind: ProxyKind
    @State private var error: String?
    @State private var startupCommands: String
    @State private var forwardsAgent: Bool
    @State private var forwardsX11: Bool
    /// nil for SSH; otherwise the session is an FTP or FTPS server.
    @State private var ftpSecurity: FTPSecurity?
    @State private var ftpFingerprint: String
    @State private var fileProtocol: FileProtocolChoice?
    /// Saved value of the ask setting. Changing it needs the master password (or the owner without a vault).
    private let savedAsks: Bool?
    @State private var askChangeAuthorized = false
    @State private var enteringMasterPassword = false
    @State private var masterPassword = ""
    @State private var masterPasswordError: String?
    @State private var verifying = false

    /// Deletes saved sign-ins when the key is removed on save.
    var model: WorkspaceModel?

    init(store: SessionTreeStore, item: SessionTreeNode? = nil, parent: UUID?, model: WorkspaceModel? = nil) {
        self.store = store
        self.model = model
        self.item = item
        self.parent = parent
        let settings = item?.connection
        _name = State(initialValue: item?.name ?? "")
        _host = State(initialValue: settings?.host ?? "")
        _port = State(initialValue: String(settings?.port ?? 22))
        _username = State(initialValue: settings?.username ?? "")
        _identityPath = State(initialValue: settings?.identityPath)
        _usesAgent = State(initialValue: settings?.usesAgent == true)
        _confirmsEachConnection = State(initialValue: item == nil ? true : settings?.asksEachConnection == true)
        savedAsks = item == nil ? nil : settings?.asksEachConnection == true
        _opensFiles = State(initialValue: settings?.opensFiles == true)
        _jumpPath = State(initialValue: settings?.jumpPath ?? [])
        _usesProxy = State(initialValue: settings?.proxyHost != nil)
        _proxyHost = State(initialValue: settings?.proxyHost ?? "")
        _proxyPort = State(initialValue: String(settings?.proxyPort ?? 1080))
        _proxyKind = State(initialValue: settings?.proxyKind ?? .socks5)
        _startupCommands = State(initialValue: settings?.startupCommands ?? "")
        _forwardsAgent = State(initialValue: settings?.forwardsAgent == true)
        _forwardsX11 = State(initialValue: settings?.forwardsX11 == true)
        _ftpSecurity = State(initialValue: settings?.ftpSecurity)
        _ftpFingerprint = State(initialValue: settings?.ftpFingerprint ?? "")
        _fileProtocol = State(initialValue: settings?.fileProtocol)
    }

    private static func defaultPort(_ security: FTPSecurity?) -> Int { security?.defaultPort ?? 22 }

    private var protocolTitle: String {
        switch ftpSecurity {
        case nil: return "SSH"
        case .explicitTLS?: return T("FTPS (explicit, AUTH TLS)")
        case .implicitTLS?: return T("FTPS (implicit TLS)")
        case .some(.none): return T("FTP (not encrypted)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(T(item == nil ? "New saved session" : "Session properties"), systemImage: "server.rack")
                .appFont(.title2.weight(.semibold))
            Form {
                TextField(T("Name"), text: $name)
                HStack(spacing: 6) {
                    AppPicker(T("Protocol"), selection: $ftpSecurity, current: protocolTitle) {
                        Text("SSH").tag(FTPSecurity?.none)
                        Text(T("FTPS (explicit, AUTH TLS)")).tag(Optional(FTPSecurity.explicitTLS))
                        Text(T("FTPS (implicit TLS)")).tag(Optional(FTPSecurity.implicitTLS))
                        Text(T("FTP (not encrypted)")).tag(Optional(FTPSecurity.none))
                    }
                    .onChange(of: ftpSecurity) { old, new in
                        if Int(port) == Self.defaultPort(old) { port = String(Self.defaultPort(new)) }
                    }
                    InfoButton(T("FTPS encrypts the password and the files. Explicit FTPS starts on port 21 and switches to TLS; implicit FTPS uses TLS from the start, usually on port 990. Plain FTP sends the password and the files unencrypted, so use it only on a network you trust."))
                }
                TextField(T("Host"), text: $host)
                TextField(T("Port"), text: $port)
                if ftpSecurity != nil {
                    TextField(T("Username"), text: $username, prompt: Text("anonymous"))
                    if ftpSecurity != FTPSecurity.none {
                        HStack(spacing: 6) {
                            TextField(T("Trusted certificate"), text: $ftpFingerprint, prompt: Text(T("SHA-256 fingerprint")))
                                .appFont(.system(size: 11, design: .monospaced))
                            InfoButton(T("Leave this empty for servers with a certificate this Mac trusts. For a self-signed certificate, connect once: the error shows the server's fingerprint. Check it with the server's administrator, then paste it here."))
                        }
                    }
                    HStack(spacing: 6) {
                        Toggle(isOn: $confirmsEachConnection) {
                            Text(T("Confirm each connection with Touch ID")).fixedSize(horizontal: false, vertical: true)
                        }
                        InfoButton(T(confirmsEachConnection
                                     ? "The saved password or key is used only after Touch ID or the Mac password. While the password vault is unlocked, it does not ask."
                                     : "After the first successful sign-in, this session connects without asking again.")
                                   + "\n\n" + T(vaultOverrideNote))
                    }
                } else {
                    sshFields
                }
            }
            if let error {
                Label(T(error), systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .appFont(.callout).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(T("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(T("Save"), action: save).buttonStyle(.appProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .sheet(isPresented: $enteringMasterPassword, onDismiss: { masterPassword = ""; masterPasswordError = nil }) {
            masterPasswordSheet
        }
    }

    /// One row per jump host, first dialed first, each with its own remove button, then a button that adds one.
    @ViewBuilder private var jumpHostRows: some View {
        ForEach(Array(jumpPath.enumerated()), id: \.element) { index, id in
            let selection = Binding<UUID?>(
                get: { id },
                set: { new in
                    guard let new, let position = jumpPath.firstIndex(of: id) else { return }
                    jumpPath[position] = new
                })
            // The menu fills the row and truncates a long name; at its natural width it grew past the sheet, pushed the
            // form's labels off the left edge, and squeezed this label into an empty column.
            LabeledContent {
                HStack(spacing: 6) {
                    JumpHostPicker(store: store, excluding: item?.id, selection: selection, fills: true,
                                   hidden: Set(jumpPath).subtracting([id]), allowsNone: false)
                        .labelsHidden()
                    Button { jumpPath.removeAll { $0 == id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help(T("Remove this jump host"))
                        .accessibilityLabel(T("Remove this jump host"))
                }
            } label: {
                Text(String(format: T("Jump host %d"), index + 1)).lineLimit(1).fixedSize()
            }
        }
        let candidates = store.jumpCandidates(excluding: item?.id).filter { !jumpPath.contains($0.id) }
        LabeledContent(jumpPath.isEmpty ? T("SSH jump host") : "") {
            HStack(spacing: 6) {
                Button { if let next = candidates.first { jumpPath.append(next.id) } } label: {
                    Label(T("Add jump host"), systemImage: "plus")
                }
                .disabled(candidates.isEmpty || jumpPath.count >= SessionTreeStore.maximumJumpHops)
                InfoButton(T("Gloamux connects to the jump hosts in order, from the first, and reaches this server from the last one. Only the first one uses its own jump host settings."))
            }
        }
    }

    @ViewBuilder private var sshFields: some View {
                TextField(T("Username"), text: $username)
                IdentityFilePicker(path: $identityPath)
                // One row with fixed spacing: the form spaces a checkbox next to a button differently from a plain one.
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(T("SSH agent"), isOn: $usesAgent)
                    HStack(spacing: 6) {
                        Toggle(T("Forward SSH agent"), isOn: $forwardsAgent)
                        InfoButton(T("Programs on the server can then sign in elsewhere with the keys in this Mac's SSH agent, as with ssh -A. Anyone with root on the server can use them while you are connected, so turn this on only for servers you trust."))
                    }
                    HStack(spacing: 6) {
                        Toggle(T("Forward X11"), isOn: $forwardsX11)
                        InfoButton(T("Lets programs on this server use your local XQuartz display. Enable only for servers you trust."))
                    }
                    Toggle(T("Open in Remote files"), isOn: $opensFiles)
                    HStack(spacing: 6) {
                        Toggle(isOn: $confirmsEachConnection) {
                            Text(T("Confirm each connection with Touch ID")).fixedSize(horizontal: false, vertical: true)
                        }
                        InfoButton(T(confirmsEachConnection
                                     ? "The saved password or key is used only after Touch ID or the Mac password. While the password vault is unlocked, it does not ask."
                                     : "After the first successful sign-in, this session connects without asking again.")
                                   + "\n\n" + T(vaultOverrideNote))
                    }
                }
                if usesAgent, let socket = item?.connection?.agentSocket {
                    LabeledContent(T("Agent socket")) {
                        Text(verbatim: socket).appFont(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(socket)
                    }
                }
                jumpHostRows
                if jumpPath.isEmpty {
                    Toggle(T("Proxy"), isOn: $usesProxy)
                    if usesProxy {
                        ProxyKindPicker(kind: $proxyKind, labeled: true)
                        TextField(T("Proxy host"), text: $proxyHost)
                        TextField(T("Proxy port"), text: $proxyPort)
                    }
                }
                LabeledContent {
                    TextEditor(text: $startupCommands)
                        .appFont(.system(size: 11, design: .monospaced))
                        .frame(height: 54)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("startupCommands")
                } label: {
                    HStack(spacing: 6) {
                        Text(T("Startup commands"))
                        InfoButton(T("Typed into the shell each time this session opens a terminal, one command per line, up to 20 lines. Do not put passwords here: these lines are saved as plain text and shown in the terminal."))
                    }
                }
                HStack(spacing: 6) {
                    AppPicker(T("File transfer"), selection: $fileProtocol,
                              current: T(fileProtocol == .sftp ? "SFTP only" : fileProtocol == .scp ? "SCP only" : "SFTP, or SCP when SFTP is off")) {
                        Text(T("SFTP, or SCP when SFTP is off")).tag(FileProtocolChoice?.none)
                        Text(T("SFTP only")).tag(Optional(FileProtocolChoice.sftp))
                        Text(T("SCP only")).tag(Optional(FileProtocolChoice.scp))
                    }
                    InfoButton(T("Remote files use SFTP. Some servers turn SFTP off and keep only scp: Gloamux then copies with scp and lists, renames, and deletes with shell commands, which needs a POSIX shell on the server."))
                }
    }

    private var masterPasswordSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(T("Enter the master password"), systemImage: "lock.shield").appFont(.title3.weight(.semibold))
            Text(T("Changing whether this session asks on every connection needs the password vault's master password."))
                .fixedSize(horizontal: false, vertical: true)
            SecureField(T("Master password"), text: $masterPassword).onSubmit(checkMasterPassword)
            if let masterPasswordError {
                Label(T(masterPasswordError), systemImage: "exclamationmark.circle").foregroundStyle(.red).appFont(.callout)
            }
            HStack {
                Spacer()
                Button(T("Cancel")) { enteringMasterPassword = false }.keyboardShortcut(.cancelAction)
                Button(T("Save"), action: checkMasterPassword).buttonStyle(.appProminent).keyboardShortcut(.defaultAction)
                    .disabled(masterPassword.isEmpty || verifying)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func checkMasterPassword() {
        guard let model, !masterPassword.isEmpty, !verifying else { return }
        let password = masterPassword
        verifying = true
        Task {
            let valid = await model.verifyMasterPassword(password)
            verifying = false
            guard valid else { masterPasswordError = "The master password is incorrect."; return }
            enteringMasterPassword = false
            askChangeAuthorized = true
            save()
        }
    }

    /// The ask setting of a saved session changed: confirm the owner before saving.
    private func authorizeAskChange() -> Bool {
        guard let model, let savedAsks, savedAsks != confirmsEachConnection, !askChangeAuthorized else { return true }
        if model.vaultState != "Not configured" {
            enteringMasterPassword = true
        } else {
            Task {
                if await model.authorizeAskChange() { askChangeAuthorized = true; save() }
                else { error = "Touch ID or the Mac password is required to change this setting." }
            }
        }
        return false
    }

    private func save() {
        guard authorizeAskChange() else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ftpSecurity {
            guard let port = Int(port) else { error = "Enter a valid port."; return }
            let fingerprint = ftpFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fingerprint.isEmpty || FTPSettings.isFingerprint(fingerprint) else {
                error = "Paste the certificate's SHA-256 fingerprint: 64 hexadecimal digits."; return
            }
            var connection = SavedConnection(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                                             username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                             confirmsEachConnection: confirmsEachConnection)
            connection.ftpSecurity = ftpSecurity
            connection.ftpFingerprint = fingerprint.isEmpty || ftpSecurity == FTPSecurity.none ? nil : fingerprint
            do {
                if let item { try store.updateConnection(item.id, name: name, connection: connection) }
                else { try store.add(name: name, parent: parent, connection: connection) }
                dismiss()
            } catch { self.error = error.localizedDescription }
            return
        }
        let proxy = usesProxy && jumpPath.isEmpty
        guard let port = Int(port), !proxy || Int(proxyPort) != nil else {
            error = "Enter a valid port."
            return
        }
        var connection = SavedConnection(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            proxyHost: proxy ? proxyHost.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            proxyPort: proxy ? Int(proxyPort) : nil, identityPath: identityPath, opensFiles: opensFiles,
            usesAgent: usesAgent, agentSocket: item?.connection?.agentSocket, proxyKind: proxyKind,
            confirmsEachConnection: confirmsEachConnection
        )
        connection.setJumpPath(jumpPath)
        let startup = startupCommands.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.startupCommands = startup.isEmpty ? nil : String(startup.prefix(8000))
        connection.forwardsAgent = forwardsAgent ? true : nil
        connection.forwardsX11 = forwardsX11 ? true : nil
        connection.fileProtocol = fileProtocol
        do {
            if let item {
                let previous = store.node(item.id)?.connection
                connection.forwardingRules = previous?.forwardingRules
                connection.encoding = previous?.encoding
                try store.updateConnection(item.id, name: name, connection: connection)
                // The key was removed: the account must sign in with a typed password again.
                if let previous, let removedKey = previous.identityPath, connection.identityPath == nil, let model {
                    let account = "\(previous.username)@\(KnownHosts.endpoint(host: previous.host, port: previous.port))"
                    Task { try? await model.forgetSignIn(account: account, keyPath: removedKey) }
                }
            } else {
                try store.add(name: name, parent: parent, connection: connection)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}


/// Gloamux's own Secure Enclave key, kept in the app's data folder. Saved connections refer to it by path.
@MainActor enum AppSSHKey {
    /// Set by the workspace to its storage folder.
    static var directory: URL?
    static var url: URL? { directory?.appendingPathComponent("ssh-key-secure-enclave") }
    static var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    static func isAppKey(_ path: String?) -> Bool { path != nil && path == url?.path }

    static func publicKey() async throws -> String {
        guard let url else { throw SSHKeyFileError.invalid }
        return try await Task.detached(priority: .userInitiated) {
            try SecureEnclaveSSHIdentity.publicKey(of: Data(contentsOf: url))
        }.value
    }

    /// Posted after the key is created or replaced, so every key picker updates its button.
    static let changed = Notification.Name("GloamuxAppSSHKeyChanged")

    /// Creates a new key, replacing any earlier one. Servers that trusted the old public key need the new one.
    static func create() async throws -> String {
        guard let url else { throw SSHKeyFileError.invalid }
        let identity = try await Task.detached(priority: .userInitiated) { try SecureEnclaveSSHIdentity.create() }.value
        try writePrivate(identity.fileContents, to: url)
        NotificationCenter.default.post(name: changed, object: nil)
        return identity.publicKey
    }
}

struct IdentityFilePicker: View {
    @Binding var path: String?
    /// Runs after the user confirms removing the key; without it the key is only cleared from the form.
    var onRemove: (() -> Void)? = nil
    @State private var confirmingRemove = false
    @State private var busy = false
    @State private var shownPublicKey: String?
    @State private var keyError: String?
    @State private var confirmingRegenerate = false
    @State private var copied = false
    @State private var needsTouchID = false
    @State private var explainingTouchID = false
    /// Whether the Gloamux key exists: "Create public key" until it does, then "Show public key".
    @State private var hasAppKey = AppSSHKey.exists
    @State private var generating = false

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK { path = panel.url?.path }
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button(T("Choose key file…"), action: chooseKey)
                Button(T("Generate new key file…")) { generating = true }
            } label: {
                Text(T(path == nil ? "Choose private key…" : "Change key…"))
            } primaryAction: { chooseKey() }
            .fixedSize()
            if let path {
                Text(AppSSHKey.isAppKey(path) ? T("Gloamux key (Secure Enclave)") : URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).help(path).foregroundStyle(.secondary)
                Button { confirmingRemove = true } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).accessibilityLabel(T("Remove key reference")).help(T("Remove key reference"))
                    .accessibilityIdentifier("removeKeyButton")
                if needsTouchID {
                    Button { explainingTouchID = true } label: {
                        Label(T("Needs Touch ID"), systemImage: "touchid").foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain).fixedSize()
                    .help(T("This older key asks for Touch ID. Switch to the Gloamux key to stop the prompt."))
                }
            }
            if SecureEnclaveSSHIdentity.isAvailable && AppSSHKey.directory != nil {
                Button(T(hasAppKey ? "Show public key" : "Create public key"), action: hasAppKey ? showKey : createKey)
                    .help(T("A key kept in this Mac's Secure Enclave. Add its public key to the server."))
                    .disabled(busy)
            }
        }
        .onAppear { hasAppKey = AppSSHKey.exists }
        .onReceive(NotificationCenter.default.publisher(for: AppSSHKey.changed)) { _ in hasAppKey = AppSSHKey.exists }
        .confirmationDialog(T("Stop using this key?"), isPresented: $confirmingRemove) {
            Button(T("Remove"), role: .destructive) {
                if let onRemove { onRemove() } else { path = nil }
            }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(T(onRemove == nil
                   ? "When you save, this session stops using the key and its saved password is deleted, so the next connection asks for the password. The key itself is not deleted."
                   : "The saved session stops using the key and its saved password and passphrase are deleted, so the next connection asks for the password. The key itself is not deleted."))
        }
        .task(id: path) {
            needsTouchID = false
            guard let path, !AppSSHKey.isAppKey(path) else { return }
            needsTouchID = await Task.detached {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
                return SecureEnclaveSSHIdentity.needsTouchID(data)
            }.value
        }
        .alert(T("This key asks for Touch ID"), isPresented: $explainingTouchID) {
            Button(T(hasAppKey ? "Show Gloamux key" : "Create Gloamux key"), action: hasAppKey ? showKey : createKey)
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(T("It was created by an earlier Gloamux build that bound it to Touch ID, and that cannot be changed. Create the Gloamux key, add its public key to the server's ~/.ssh/authorized_keys, and use it for this connection. It signs without Touch ID."))
        }
        .sheet(isPresented: Binding(get: { shownPublicKey != nil }, set: { if !$0 { shownPublicKey = nil } })) {
            publicKeySheet
        }
        .sheet(isPresented: $generating) { KeyGeneratorSheet { url in path = url.path } }
        .alert(T("Could not use the Secure Enclave key."), isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
            Button(T("Done")) { keyError = nil }
        } message: { Text(keyError ?? "") }
    }

    private var publicKeySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Label(T("Gloamux public key"), systemImage: "key.horizontal").appFont(.headline)
                InfoButton(T("Add this line to ~/.ssh/authorized_keys on the server. The private key stays in this Mac's Secure Enclave."))
            }
            Text(verbatim: shownPublicKey ?? "").appFont(.callout.monospaced()).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(T("Regenerate…"), role: .destructive) { confirmingRegenerate = true }.disabled(busy)
                Spacer()
                if !AppSSHKey.isAppKey(path) {
                    Button(T("Use for this connection")) { path = AppSSHKey.url?.path; shownPublicKey = nil }
                }
                Button(T(copied ? "Copied" : "Copy")) {
                    guard let shownPublicKey else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shownPublicKey, forType: .string)
                    copied = true
                }
                Button(T("Done")) { shownPublicKey = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 560)
        .onDisappear { copied = false }
        .confirmationDialog(T("Regenerate the Gloamux key?"), isPresented: $confirmingRegenerate) {
            Button(T("Regenerate"), role: .destructive) {
                perform { copied = false; shownPublicKey = try await AppSSHKey.create() }
            }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(T("Servers that trust the current public key will stop accepting it. Add the new public key to them."))
        }
    }

    /// Creates the key only. A connection without a key starts using it; viewing it is a separate button.
    private func createKey() {
        perform {
            _ = try await AppSSHKey.create()
            hasAppKey = true
            if path == nil { path = AppSSHKey.url?.path }
        }
    }

    /// Shows the existing key without changing which key this connection uses.
    private func showKey() {
        perform {
            copied = false
            shownPublicKey = try await AppSSHKey.publicKey()
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { keyError = T(message(for: error)) }
        }
    }
}


struct JumpHostPicker: View {
    @ObservedObject var store: SessionTreeStore
    let excluding: UUID?
    @Binding var selection: UUID?
    /// Takes the width it is given and truncates a long name, as in the connect form's button row; a fixed-size menu there
    /// grew past its frame and over the fields beside it, and squeezed its label into a tall column.
    var fills = false
    /// Sessions already listed as other hops, left out of the menu.
    var hidden: Set<UUID> = []
    /// Offers None. A hop in a list is removed with its own button instead.
    var allowsNone = true

    var body: some View {
        let candidates = store.jumpCandidates(excluding: excluding).filter { !hidden.contains($0.id) }
        let current = selection.map { id in
            candidates.first { $0.id == id }.map { $0.name + " · " + ($0.connection?.host ?? "") } ?? T("Unavailable jump host")
        } ?? T("None")
        AppPicker(title: T("SSH jump host"), selection: $selection, current: current, fills: fills) {
            if allowsNone { Text(T("None")).tag(UUID?.none) }
            if let selection, !candidates.contains(where: { $0.id == selection }) {
                Text(T("Unavailable jump host")).tag(Optional(selection))
            }
            ForEach(candidates) { item in
                Text(item.name + " · " + (item.connection?.host ?? "")).tag(Optional(item.id))
            }
        } label: {
            if allowsNone { Text(T("SSH jump host")).lineLimit(1).fixedSize() }
        }
    }
}


/// SOCKS5, SOCKS4 (4a for host names), or HTTP CONNECT.
struct ProxyKindPicker: View {
    @Binding var kind: ProxyKind
    var labeled = false

    var body: some View {
        AppPicker(T("Proxy type"), selection: $kind, current: kind.title) {
            ForEach([ProxyKind.socks5, .socks4, .http], id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        .labelsHidden(!labeled)
    }
}

private extension View {
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// Creates an Ed25519 key file in ~/.ssh, as `ssh-keygen -t ed25519` does, optionally protected by a passphrase, then
/// shows the public key to add to the server.
struct KeyGeneratorSheet: View {
    let created: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = KeyGeneratorSheet.freeName()
    @State private var comment = "\(NSUserName())@\(Host.current().localizedName ?? "mac")"
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var publicKey: String?
    @State private var error: String?
    @State private var copied = false
    @State private var working = false

    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true) }

    /// `id_ed25519`, or the first `id_ed25519_N` with no key or .pub file yet.
    static func freeName(in folder: URL = folder) -> String {
        var name = "id_ed25519", number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".pub").path) {
            name = "id_ed25519_\(number)"; number += 1
        }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Label(T("Generate key file"), systemImage: "key.horizontal").appFont(.headline)
                InfoButton(T("Creates an Ed25519 key in ~/.ssh, the same file ssh-keygen makes, so ssh and other apps can use it too. Add the public key to ~/.ssh/authorized_keys on the server."))
            }
            if let publicKey {
                Text(verbatim: publicKey).appFont(.callout.monospaced()).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button(T(copied ? "Copied" : "Copy")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(publicKey, forType: .string); copied = true
                    }
                    Button(T("Done")) { dismiss() }.buttonStyle(.appProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    LabeledContent(T("File")) {
                        HStack(spacing: 2) {
                            Text("~/.ssh/").foregroundStyle(.secondary).appFont(.body.monospaced())
                            TextField("", text: $name).appFont(.body.monospaced()).labelsHidden()
                        }
                    }
                    TextField(T("Comment"), text: $comment)
                    SecureField(T("Passphrase (optional)"), text: $passphrase)
                    SecureField(T("Confirm passphrase"), text: $confirmation).disabled(passphrase.isEmpty)
                }
                if let error { Text(T(error)).foregroundStyle(.red).appFont(.callout) }
                HStack {
                    Button(T("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button(T("Generate"), action: generate).buttonStyle(.appProminent).keyboardShortcut(.defaultAction)
                        .disabled(working || name.isEmpty || passphrase != confirmation)
                }
            }
        }
        .padding(24).frame(width: 520)
    }

    private func generate() {
        let file = name.trimmingCharacters(in: .whitespaces)
        guard !file.isEmpty, !file.contains("/"), !file.hasPrefix(".") else { error = "Enter a file name without slashes."; return }
        let url = Self.folder.appendingPathComponent(file)
        working = true; error = nil
        let comment = comment, passphrase = passphrase
        Task {
            do {
                let key = try await Task.detached { try GeneratedSSHKey.ed25519(comment: comment, passphrase: passphrase) }.value
                try key.write(to: url)
                self.passphrase = ""; confirmation = ""
                publicKey = key.publicKeyLine
                created(url)
            } catch CocoaError.fileWriteFileExists {
                error = "A key with this name already exists. Choose another name."
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
