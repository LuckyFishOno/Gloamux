import Foundation
import Terminal
import SwiftUI

/// Runs a command line through the user's login shell, so `docker`, `kubectl`, `aws`, and `tailscale` are found
/// where Terminal finds them, and returns its output. It is stopped after `timeout` seconds.
enum LoginShellCommand {
    /// Output collected on reader threads and the one-time result, behind a lock.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        var output = Data(), errors = Data()
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if finished { return false }; finished = true; return true }
        func set(output: Data? = nil, errors: Data? = nil) {
            lock.lock(); defer { lock.unlock() }
            if let output { self.output = output }
            if let errors { self.errors = errors }
        }
        func read() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (output, errors) }
    }

    static func run(_ command: String, timeout: TimeInterval = 20) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: LocalLaunch.userShell)
            process.arguments = ["-l", "-c", command]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
            let state = State()
            let finish: @Sendable (Result<String, Error>) -> Void = { result in
                if state.claim() { continuation.resume(with: result) }
            }
            // Read while the process runs so a large output cannot fill the pipe and stall it.
            let group = DispatchGroup()
            group.enter(); DispatchQueue.global().async { state.set(output: output.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            group.enter(); DispatchQueue.global().async { state.set(errors: errors.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            process.terminationHandler = { process in
                group.wait()
                let (data, errorData) = state.read()
                if process.terminationStatus == 0 {
                    finish(.success(String(decoding: data.prefix(16 * 1024 * 1024), as: UTF8.self)))
                } else {
                    let message = String(decoding: errorData.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(.failure(WorkspaceError.invalid(message.isEmpty ? "The command failed with exit code \(process.terminationStatus)." : message)))
                }
            }
            do { try process.run() } catch { finish(.failure(error)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate(); finish(.failure(WorkspaceError.invalid("The command took too long and was stopped."))) }
            }
        }
    }
}

/// A host found on the network, in Tailscale, or in AWS, before it is added to the session tree.
struct DiscoveredHost: Identifiable, Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case bonjour, tailscale, aws
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bonjour: return "This network (Bonjour)"
            case .tailscale: return "Tailscale"
            case .aws: return "AWS EC2"
            }
        }
        var symbol: String {
            switch self {
            case .bonjour: return "bonjour"
            case .tailscale: return "point.3.connected.trianglepath.dotted"
            case .aws: return "cloud"
            }
        }
    }

    var id: String { source.rawValue + ":" + identifier }
    let source: Source
    /// A stable ID within the source: the service name, node ID, or instance ID.
    let identifier: String
    var name: String
    var host: String
    var port = 22
    /// What else is known: the OS, the instance type, or whether the peer is online.
    var detail: String = ""
    var online = true
    /// AWS instances can also be reached through Systems Manager.
    var instanceID: String?
    var region: String?
}

enum HostDiscoveryParser {
    /// `tailscale status --json`: every peer, online first. DNS names are preferred over addresses.
    static func tailscale(_ json: Data) throws -> [DiscoveredHost] {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw WorkspaceError.invalid("Tailscale returned an unexpected answer.") }
        let peers = (root["Peer"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        return peers.compactMap { peer -> DiscoveredHost? in
            let dns = (peer["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let address = (peer["TailscaleIPs"] as? [String])?.first
            guard let host = dns.isEmpty ? address : dns else { return nil }
            let name = peer["HostName"] as? String ?? host
            let id = peer["ID"] as? String ?? peer["PublicKey"] as? String ?? host
            let online = peer["Online"] as? Bool ?? false
            let os = peer["OS"] as? String ?? ""
            return DiscoveredHost(source: .tailscale, identifier: id, name: name, host: host, detail: os, online: online)
        }
        .sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
    }

    /// `aws ec2 describe-instances --output json`: running instances, named by their Name tag.
    static func ec2(_ json: Data, region: String?) throws -> [DiscoveredHost] {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw WorkspaceError.invalid("AWS returned an unexpected answer.") }
        let reservations = root["Reservations"] as? [[String: Any]] ?? []
        return reservations.flatMap { $0["Instances"] as? [[String: Any]] ?? [] }.compactMap { instance -> DiscoveredHost? in
            guard let id = instance["InstanceId"] as? String else { return nil }
            let state = (instance["State"] as? [String: Any])?["Name"] as? String ?? ""
            let tags = instance["Tags"] as? [[String: Any]] ?? []
            let name = tags.first { $0["Key"] as? String == "Name" }?["Value"] as? String ?? id
            let publicName = (instance["PublicDnsName"] as? String).nonEmpty
            let host = publicName ?? (instance["PublicIpAddress"] as? String).nonEmpty ?? (instance["PrivateIpAddress"] as? String).nonEmpty ?? ""
            let type = instance["InstanceType"] as? String ?? ""
            let platform = instance["PlatformDetails"] as? String ?? instance["Platform"] as? String ?? ""
            return DiscoveredHost(source: .aws, identifier: id, name: name, host: host,
                                  detail: [type, platform, state].filter { !$0.isEmpty }.joined(separator: " · "),
                                  online: state == "running", instanceID: id, region: region)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Finds `_ssh._tcp` services on the local network.
@MainActor final class BonjourSSHBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var found: [String: DiscoveredHost] = [:]
    private var update: (([DiscoveredHost]) -> Void)?

    func start(_ update: @escaping ([DiscoveredHost]) -> Void) {
        self.update = update
        browser.delegate = self
        browser.searchForServices(ofType: "_ssh._tcp.", inDomain: "local.")
    }

    func stop() { browser.stop(); services.forEach { $0.stop() }; services = [] }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            services.append(service)
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return }
            found[sender.name] = DiscoveredHost(source: .bonjour, identifier: sender.name, name: sender.name, host: host,
                                                port: sender.port > 0 ? sender.port : 22, detail: "_ssh._tcp")
            update?(found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }
}

@MainActor final class HostDiscoveryModel: ObservableObject {
    @Published var source: DiscoveredHost.Source = .bonjour
    @Published var hosts: [DiscoveredHost] = []
    @Published var chosen: Set<String> = []
    @Published var busy = false
    @Published var error: String?
    @Published var username = NSUserName()
    @Published var awsProfile = ""
    @Published var awsRegion = ""
    /// AWS instances can be added as SSH sessions or as SSM sessions.
    @Published var useSSM = false
    private let bonjour = BonjourSSHBrowser()

    func scan() {
        error = nil; hosts = []; chosen = []
        bonjour.stop()
        switch source {
        case .bonjour:
            busy = true
            bonjour.start { [weak self] hosts in self?.hosts = hosts }
            Task { try? await Task.sleep(nanoseconds: 4_000_000_000); busy = false }
        case .tailscale:
            run("(command -v tailscale >/dev/null && tailscale status --json) || /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json") {
                try HostDiscoveryParser.tailscale(Data($0.utf8))
            }
        case .aws:
            if username == NSUserName() { username = "ec2-user" }
            let q = ShellIntegration.quote
            var command = "aws ec2 describe-instances --output json --filters Name=instance-state-name,Values=running"
            if let profile = Optional(awsProfile).nonEmpty { command += " --profile " + q(profile) }
            if let region = Optional(awsRegion).nonEmpty { command += " --region " + q(region) }
            let region = Optional(awsRegion).nonEmpty
            run(command) { try HostDiscoveryParser.ec2(Data($0.utf8), region: region) }
        }
    }

    private func run(_ command: String, parse: @escaping (String) throws -> [DiscoveredHost]) {
        busy = true
        Task {
            do { hosts = try parse(try await LoginShellCommand.run(command)) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func stop() { bonjour.stop() }

    /// The sessions to add: SSH for every host, or SSM for AWS instances when chosen.
    func sessions() -> [(String, SavedConnection?, ContainerSession?)] {
        hosts.filter { chosen.contains($0.id) }.compactMap { host in
            if host.source == .aws, useSSM, let id = host.instanceID {
                return (host.name, nil, ContainerSession(tool: .ssm, target: id, context: awsProfile, namespace: host.region))
            }
            guard !host.host.isEmpty, !username.isEmpty else { return nil }
            return (host.name, SavedConnection(host: host.host, port: host.port, username: username, confirmsEachConnection: true), nil)
        }
    }
}

struct HostDiscoveryView: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var discovery = HostDiscoveryModel()
    @State private var added: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker(T("Source"), selection: $discovery.source) {
                    ForEach(DiscoveredHost.Source.allCases) { source in Label(T(source.title), systemImage: source.symbol).tag(source) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 440)
                InfoButton(T("Gloamux asks Bonjour on this network, the Tailscale app, or the AWS command-line tool with your own profile. Nothing is added until you choose hosts and add them."))
                Spacer()
                if discovery.busy { ProgressView().controlSize(.small) }
                Button(T("Search")) { discovery.scan() }.keyboardShortcut(.defaultAction)
            }
            if discovery.source == .aws {
                HStack {
                    TextField(T("AWS profile"), text: $discovery.awsProfile).frame(width: 180)
                    TextField(T("Region"), text: $discovery.awsRegion).frame(width: 140)
                    Toggle(T("Connect through SSM"), isOn: $discovery.useSSM).toggleStyle(.checkbox)
                }
            }
            if let error = discovery.error {
                Label(T(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).appFont(.callout).textSelection(.enabled)
            }
            Table(discovery.hosts) {
                TableColumn("") { host in
                    Toggle("", isOn: Binding(get: { discovery.chosen.contains(host.id) }, set: { on in
                        if on { discovery.chosen.insert(host.id) } else { discovery.chosen.remove(host.id) }
                    })).labelsHidden()
                }.width(24)
                TableColumn(T("Name")) { host in
                    HStack(spacing: 6) {
                        Circle().fill(host.online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                        Text(host.name)
                    }
                }
                TableColumn(T("Address")) { host in Text(host.port == 22 ? host.host : "\(host.host):\(host.port)").appFont(.system(.body, design: .monospaced)) }
                TableColumn(T("Details")) { host in Text(host.detail).foregroundStyle(.secondary) }
            }
            .overlay {
                if discovery.hosts.isEmpty && !discovery.busy {
                    ContentUnavailableView(T("No hosts yet"), systemImage: "magnifyingglass", description: Text(T("Choose a source and search.")))
                }
            }
            HStack {
                Button(T(discovery.chosen.count == discovery.hosts.count && !discovery.hosts.isEmpty ? "Select none" : "Select all")) {
                    discovery.chosen = discovery.chosen.count == discovery.hosts.count ? [] : Set(discovery.hosts.map(\.id))
                }
                .disabled(discovery.hosts.isEmpty)
                if !(discovery.source == .aws && discovery.useSSM) {
                    TextField(T("Username"), text: $discovery.username).frame(width: 160)
                }
                Spacer()
                if let added { Text(added).foregroundStyle(.secondary).appFont(.callout) }
                Button(String(format: T("Add %d sessions"), discovery.chosen.count)) { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(discovery.chosen.isEmpty)
            }
        }
        .padding(16)
        .onChange(of: discovery.source) { _, _ in discovery.hosts = []; discovery.chosen = []; discovery.error = nil }
        .onDisappear { discovery.stop() }
    }

    private func add() {
        let sessions = discovery.sessions()
        guard !sessions.isEmpty else { discovery.error = "Enter a username."; return }
        do {
            try model.sessionTree.addFolder(named: T("Discovered") + " · " + T(discovery.source.title), parent: nil, sessions: sessions)
            added = String(format: T("Added %d sessions to the session tree."), sessions.count)
            discovery.chosen = []
        } catch { discovery.error = message(for: error) }
    }
}

/// Trusted host keys, which can be removed or exported as `known_hosts`, and every host key trusted, replaced,
/// declined, blocked, or removed, newest first.
struct HostKeyHistoryView: View {
    enum Page: Hashable { case trusted, history }

    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var hosts: KnownHosts
    @State private var page = Page.trusted
    @State private var query = ""
    @State private var confirmingClear = false
    @State private var removing: String?
    @State private var error: String?

    init(model: WorkspaceModel) { self.model = model; hosts = model.knownHosts }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $page) {
                    Text(T("Trusted keys")).tag(Page.trusted)
                    Text(T("History")).tag(Page.history)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField(T("Search hosts or fingerprints"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                InfoButton(T(page == .trusted
                             ? "Hosts Gloamux has trusted, with the key each one showed. Remove a host to be asked again on the next connection, after the server's key changed on purpose."
                             : "Gloamux keeps this history on this Mac. It lists keys you trusted, replaced, or declined, and changed keys that blocked a connection."))
                Spacer()
                if page == .trusted {
                    Button(T("Export known_hosts…"), action: exportKnownHosts).disabled(hosts.trusted.isEmpty)
                } else {
                    Button(T("Clear history…")) { confirmingClear = true }.disabled(hosts.history.isEmpty)
                }
            }
            if let error { Text(T(error)).foregroundStyle(.red).appFont(.callout) }
            if page == .trusted { trustedTable } else { historyTable }
        }
        .padding(16)
        .confirmationDialog(T("Clear the host key history?"), isPresented: $confirmingClear) {
            Button(T("Clear history"), role: .destructive) { hosts.clearHistory() }
            Button(T("Cancel"), role: .cancel) {}
        } message: { Text(T("Trusted host keys stay. Only the history is removed.")) }
        .confirmationDialog(String(format: T("Remove the trusted key for %@?"), removing ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(T("Remove"), role: .destructive) {
                if let removing { do { try hosts.remove(endpoint: removing) } catch { self.error = error.localizedDescription } }
                removing = nil
            }
            Button(T("Cancel"), role: .cancel) { removing = nil }
        } message: { Text(T("The next connection to this host asks you to check its key again.")) }
    }

    private struct TrustedRow: Identifiable {
        let endpoint: String
        let type: String
        let fingerprint: String
        var id: String { endpoint }
    }

    private var trustedTable: some View {
        let rows = hosts.trusted.map { entry in
            TrustedRow(endpoint: entry.endpoint, type: String(entry.key.split(separator: " ").first ?? ""),
                       fingerprint: (try? KnownHosts.fingerprint(entry.key)) ?? "")
        }.filter { query.isEmpty || $0.endpoint.localizedCaseInsensitiveContains(query) || $0.fingerprint.contains(query) }
        return Table(rows) {
            TableColumn(T("Host")) { row in Text(row.endpoint).appFont(.system(.body, design: .monospaced)) }
            TableColumn(T("Type")) { row in Text(row.type).appFont(.system(size: 11, design: .monospaced)) }.width(min: 90, ideal: 120)
            TableColumn(T("Fingerprint")) { row in
                Text(row.fingerprint).appFont(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
            TableColumn("") { row in
                Button(T("Remove")) { removing = row.endpoint }.buttonStyle(.borderless)
            }.width(70)
        }
        .overlay { if rows.isEmpty { ContentUnavailableView(T("No trusted host keys"), systemImage: "key.horizontal") } }
    }

    private var historyTable: some View {
        let events = hosts.history.reversed().filter { query.isEmpty || $0.endpoint.localizedCaseInsensitiveContains(query) || $0.fingerprint.contains(query) }
        return Table(Array(events)) {
            TableColumn(T("Date")) { event in Text(event.date, format: .dateTime.year().month().day().hour().minute()) }.width(min: 120, ideal: 140)
            TableColumn(T("Host")) { event in Text(event.endpoint).appFont(.system(.body, design: .monospaced)) }
            TableColumn(T("Action")) { event in
                Label(T(title(event.action)), systemImage: symbol(event.action)).foregroundStyle(color(event.action))
            }.width(min: 90, ideal: 110)
            TableColumn(T("Fingerprint")) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.fingerprint).appFont(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if let previous = event.previousFingerprint {
                        Text(T("Before:") + " " + previous).appFont(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        .overlay { if events.isEmpty { ContentUnavailableView(T("No host key changes yet"), systemImage: "key.horizontal") } }
    }

    private func exportKnownHosts() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "known_hosts"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(hosts.knownHostsText().utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }

    private func title(_ action: HostKeyEvent.Action) -> String {
        switch action { case .trusted: return "Trusted"; case .replaced: return "Replaced"; case .declined: return "Declined"; case .blocked: return "Changed key blocked"; case .removed: return "Removed" }
    }
    private func symbol(_ action: HostKeyEvent.Action) -> String {
        switch action { case .trusted: return "checkmark.shield"; case .replaced: return "arrow.triangle.2.circlepath"; case .declined: return "xmark.shield"; case .blocked: return "exclamationmark.shield"; case .removed: return "trash" }
    }
    private func color(_ action: HostKeyEvent.Action) -> Color {
        switch action { case .trusted: return .green; case .replaced: return .orange; case .declined, .removed: return .secondary; case .blocked: return .red }
    }
}

/// Creates or edits a session that uses a desktop, a terminal protocol, or a local command.
struct ContainerSessionEditor: View {
    @ObservedObject var model: WorkspaceModel
    let editing: SessionTreeNode?
    private let availableTools: [ContainerSession.Tool]
    private let draftTab: SessionTab?
    private let parent: UUID?
    private let onClose: () -> Void
    @State private var name = ""
    @State private var tool: ContainerSession.Tool
    @State private var target = ""
    @State private var context = ""
    @State private var namespace = ""
    @State private var container = ""
    @State private var shell = ""
    @State private var user = ""
    @State private var port = ""
    @State private var baud = 9600
    @State private var format = "8N1"
    @State private var flow = SerialPort.Settings.Flow.none
    @State private var encoding = TerminalEncoding.utf8
    @State private var environment: SessionEnvironment?
    @State private var gateway: UUID?
    @State private var choices: [String] = []
    @State private var listing = false
    @State private var error: String?

    init(model: WorkspaceModel, editing: SessionTreeNode?, tool: ContainerSession.Tool = .docker,
         draftTab: SessionTab? = nil, parent: UUID? = nil, onClose: @escaping () -> Void = {}) {
        self.model = model
        self.editing = editing
        self.draftTab = draftTab
        self.parent = parent
        self.onClose = onClose
        let initial = editing?.container?.tool ?? tool
        self._tool = State(initialValue: initial)
        self._target = State(initialValue: draftTab?.host ?? "")
        self._user = State(initialValue: draftTab?.username ?? "")
        availableTools = ContainerSession.Tool.allCases.filter { $0.opensDesktop == initial.opensDesktop }
    }

    var body: some View {
        EditorContainer(inline: draftTab != nil) {
            if draftTab == nil || !tool.opensDesktop {
                sizedRow("Type", width: 240) {
                    Picker(T("Type"), selection: $tool) {
                        ForEach(availableTools) { tool in Label(T(tool.title), systemImage: tool.symbol).tag(tool) }
                    }
                    .disabled(editing != nil && !tool.opensDesktop)
                }
            }
            sizedRow(targetLabel) {
                HStack {
                    TextField(T(targetLabel), text: $target)
                    if !tool.usesHost {
                        Menu {
                            if choices.isEmpty { Text(T(listing ? "Loading…" : "Nothing found")) }
                            ForEach(choices, id: \.self) { choice in Button(choice) { target = choice; if name.isEmpty { name = (choice as NSString).lastPathComponent } } }
                        } label: { Image(systemName: "list.bullet") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help(T(tool == .serial ? "Choose a connected device" : "Choose a running one"))
                        .simultaneousGesture(TapGesture().onEnded { list() })
                    }
                }
            }
            switch tool {
            case .mosh, .telnet, .rdp, .vnc:
                if tool == .mosh || tool == .rdp {
                    sizedRow("User", width: 240) {
                        TextField(T("User"), text: $user, prompt: tool == .mosh ? Text(NSUserName()) : nil)
                    }
                }
                let portLabel = tool == .mosh ? "SSH port" : "Port"
                sizedRow(portLabel, width: 104) {
                    TextField(T(portLabel), text: $port, prompt: Text(String(tool.defaultPort)))
                }
                if tool.opensDesktop {
                    sizedRow("Through SSH", width: 270) {
                        HStack(spacing: 8) {
                            Picker(T("Through SSH"), selection: $gateway) {
                                Text(T("Direct")).tag(UUID?.none)
                                ForEach(sshSessions) { node in Text(node.name).tag(Optional(node.id)) }
                            }
                            InfoButton(T("Connects to the desktop through an SSH tunnel from this saved session. The SSH connection encrypts the traffic, which plain VNC does not, and reaches desktops only that server can reach. Enter the desktop's address as that server sees it."))
                        }
                    }
                }
            case .serial:
                sizedRow("Speed", width: 140) {
                    Picker(T("Speed"), selection: $baud) {
                        ForEach(SerialPort.Settings.speeds, id: \.self) { Text(String($0)).tag($0) }
                    }
                }
                sizedRow("Data bits", width: 200) {
                    Picker(T("Data bits"), selection: formatPart(0)) {
                        ForEach(["8", "7", "6", "5"], id: \.self) { Text($0).tag(Character($0)) }
                    }
                    .pickerStyle(.segmented)
                }
                sizedRow("Parity", width: 224) {
                    Picker(T("Parity"), selection: formatPart(1)) {
                        Text(T("None")).tag(Character("N"))
                        Text(T("Odd")).tag(Character("O"))
                        Text(T("Even")).tag(Character("E"))
                    }
                    .pickerStyle(.segmented)
                }
                sizedRow("Stop bits", width: 124) {
                    Picker(T("Stop bits"), selection: formatPart(2)) {
                        Text("1").tag(Character("1"))
                        Text("2").tag(Character("2"))
                    }
                    .pickerStyle(.segmented)
                }
                sizedRow("Flow control", width: 320) {
                    Picker(T("Flow control"), selection: $flow) {
                        Text(T("None")).tag(SerialPort.Settings.Flow.none)
                        Text("RTS/CTS").tag(SerialPort.Settings.Flow.hardware)
                        Text("DTR/DSR").tag(SerialPort.Settings.Flow.dtrDsr)
                        Text("XON/XOFF").tag(SerialPort.Settings.Flow.software)
                    }
                    .pickerStyle(.segmented)
                }
                sizedRow("Text encoding", width: 180) {
                    Picker(T("Text encoding"), selection: $encoding) {
                        ForEach(TerminalEncoding.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            default:
                let contextLabel = tool == .ssm ? "AWS profile" : "Context"
                sizedRow(contextLabel) { TextField(T(contextLabel), text: $context) }
                if tool != .docker {
                    let namespaceLabel = tool == .ssm ? "Region" : "Namespace"
                    sizedRow(namespaceLabel) { TextField(T(namespaceLabel), text: $namespace) }
                }
                if tool == .kubectl { sizedRow("Container in the pod") { TextField(T("Container in the pod"), text: $container) } }
                if tool != .ssm { sizedRow("Shell") { TextField(T("Shell"), text: $shell, prompt: Text("/bin/sh")) } }
                if tool == .docker { sizedRow("User") { TextField(T("User"), text: $user) } }
            }
            sizedRow("Name") { TextField(T("Name"), text: $name) }
            if draftTab == nil { environmentPicker }
            if let session = draft, session.tool.runsCommand { LabeledContent(T("Command")) { Text(session.commandLine).appFont(.system(size: 11, design: .monospaced)).textSelection(.enabled) } }
            if let error { Text(T(error)).foregroundStyle(.red).appFont(.callout) }
            if draftTab != nil {
                LabeledContent(T("Environment")) {
                    // One row: the picker gives up width before the buttons do. ViewThatFits measured both arrangements.
                    HStack {
                        environmentPicker.labelsHidden().frame(minWidth: 120, maxWidth: 200)
                        Spacer(minLength: 12)
                        inlineActions
                    }
                    .padding(.vertical, 2)
                }
            } else {
                HStack {
                    Button(T("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(T("Open")) { open() }.disabled(draft == nil)
                    Button(T(editing == nil ? "Save" : "Save changes")) { save() }.buttonStyle(.borderedProminent).disabled(draft == nil || Optional(name).nonEmpty == nil)
                }
            }
        }
        .modifier(EditorFormStyle(inline: draftTab != nil))
        .onAppear(perform: load)
        .onChange(of: target) { _, value in draftTab?.host = value }
        .onChange(of: user) { _, value in draftTab?.username = value }
        .onChange(of: tool) { previous, current in
            if draftTab != nil { NewConnectionType.lastOtherTool = current }
            choices = []
            if previous.opensDesktop, Int(port) == previous.defaultPort { port = "" }
        }
    }

    private var environmentPicker: some View {
        Picker(T("Environment"), selection: $environment) {
            Text(T("None")).tag(SessionEnvironment?.none)
            ForEach(SessionEnvironment.allCases) { Text(T($0.title)).tag(Optional($0)) }
        }
    }

    private var inlineActions: some View {
        HStack {
            Button(T("Save")) { save() }.disabled(draft == nil || Optional(name).nonEmpty == nil)
            Button(T("Connect")) { open() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(draft == nil)
        }
        .fixedSize()
    }

    @ViewBuilder private func sizedRow<Content: View>(_ title: String, width: CGFloat = 400,
                                                      @ViewBuilder content: () -> Content) -> some View {
        if draftTab != nil {
            LabeledContent(T(title)) {
                content()
                    .labelsHidden()
                    .padding(.vertical, 2)
                    .frame(maxWidth: width)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            content()
        }
    }

    private var draft: ContainerSession? {
        let remote = tool.usesHost, serial = tool == .serial
        let portNumber = port.trimmingCharacters(in: .whitespaces)
        if remote, !portNumber.isEmpty, Int(portNumber) == nil { return nil }
        var session = ContainerSession(tool: tool, target: target, context: remote || serial ? nil : context,
                                       namespace: remote || serial ? nil : namespace, container: tool == .kubectl ? container : nil,
                                       shell: remote || serial || tool == .ssm ? nil : shell, user: tool == .docker || tool == .mosh || tool == .rdp ? user : nil,
                                       port: remote ? Int(portNumber) : nil, baud: serial ? baud : nil, format: serial ? format : nil,
                                       flow: serial && flow != .none ? flow.rawValue : nil)
        if serial, encoding != .utf8 { session.encoding = encoding }
        if session.tool.opensDesktop { session.gatewaySessionID = gateway }
        if session.tool == .rdp, let previous = editing?.container, previous.tool == .rdp,
           previous.target == session.target, previous.effectivePort == session.effectivePort {
            session.rdpFingerprint = previous.rdpFingerprint
        }
        return (try? session.validate()) == nil ? nil : session
    }

    /// Saved SSH sessions a desktop can tunnel through, by name.
    private var sshSessions: [SessionTreeNode] {
        model.sessionTree.nodes.filter { $0.connection.map { !$0.isFTP } ?? false }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One character of the line format, such as the parity in `8N1`.
    private func formatPart(_ index: Int) -> Binding<Character> {
        Binding(get: {
            let characters = Array(SerialPort.Settings.parse(format) == nil ? "8N1" : format)
            return characters[index]
        }, set: { value in
            var characters = Array(SerialPort.Settings.parse(format) == nil ? "8N1" : format)
            characters[index] = value
            format = String(characters)
        })
    }

    private var targetLabel: String {
        switch tool {
        case .docker: return "Container"
        case .kubectl: return "Pod"
        case .ssm: return "Instance ID"
        case .mosh, .telnet, .rdp, .vnc: return "Host"
        case .serial: return "Device"
        }
    }

    private func load() {
        guard let editing, let session = editing.container else { return }
        name = editing.name; tool = session.tool; target = session.target; context = session.context ?? ""
        namespace = session.namespace ?? ""; container = session.container ?? ""; shell = session.shell ?? ""; user = session.user ?? ""
        port = session.port.map(String.init) ?? ""
        let settings = session.serialSettings
        baud = settings.baud; format = settings.format; flow = settings.flow
        encoding = session.encoding ?? .utf8
        environment = editing.environment
        gateway = session.gatewaySessionID
    }

    /// Lists running containers, pods, or managed instances for the menu.
    private func list() {
        guard !listing else { return }
        if tool == .serial { choices = SerialPort.devices(); return }
        guard tool.runsCommand, tool != .mosh else { return }
        listing = true
        let q = ShellIntegration.quote
        let command: String
        switch tool {
        case .docker: command = "docker" + (Optional(context).nonEmpty.map { " --context " + q($0) } ?? "") + " ps --format '{{.Names}}'"
        case .kubectl: command = "kubectl" + (Optional(context).nonEmpty.map { " --context " + q($0) } ?? "") + (Optional(namespace).nonEmpty.map { " -n " + q($0) } ?? "") + " get pods -o name"
        case .ssm: command = "aws" + (Optional(context).nonEmpty.map { " --profile " + q($0) } ?? "") + (Optional(namespace).nonEmpty.map { " --region " + q($0) } ?? "") + " ssm describe-instance-information --query 'InstanceInformationList[].InstanceId' --output text"
        case .mosh, .telnet, .serial, .rdp, .vnc: return
        }
        Task {
            do {
                let output = try await LoginShellCommand.run(command)
                choices = output.split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == " " })
                    .map { String($0).replacingOccurrences(of: "pod/", with: "") }.filter { !$0.isEmpty }.prefix(200).map { $0 }
                error = nil
            } catch { self.error = error.localizedDescription }
            listing = false
        }
    }

    private func open() {
        guard let session = draft else { return }
        let node = SessionTreeNode(name: Optional(name).nonEmpty ?? session.summary, environment: environment, container: session)
        if let draftTab { model.openDraft(draftTab, node, session) }
        else { model.openTransient(node); onClose() }
    }

    private func cancel() {
        if let draftTab { Task { await model.disconnectAndClose(draftTab) } }
        else { onClose() }
    }

    private func save() {
        guard let session = draft else { return }
        do {
            if let editing {
                try model.sessionTree.updateContainer(editing.id, name: name, container: session, environment: environment)
            } else {
                let destination = draftTab == nil ? parent : model.sessionTree.destination
                let id = try model.sessionTree.add(name: name, parent: destination, container: session, environment: environment)
                if let draftTab, let node = model.sessionTree.node(id) {
                    model.openDraft(draftTab, node, session)
                }
            }
            onClose()
        } catch { self.error = message(for: error) }
    }
}

/// A grouped, scrolling form in a sheet; a plain one that sizes to its fields inside the new-connection list.
private struct EditorFormStyle: ViewModifier {
    let inline: Bool

    func body(content: Content) -> some View {
        if inline { content.formStyle(.columns).controlSize(.large) }
        else { content.formStyle(.grouped).scrollContentBackground(.hidden) }
    }
}

/// The editor's fields: a plain column of labeled rows in the new-connection form, a grouped form elsewhere.
/// A SwiftUI form measures every row again for its label column, which held up opening a new-connection section.
private struct EditorContainer<Content: View>: View {
    let inline: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if inline {
            VStack(alignment: .leading, spacing: 8) { content }
                .labeledContentStyle(InlineRowStyle())
        } else {
            Form { content }
        }
    }
}

/// A label in a fixed column at the leading side, ending at its field, as in a columns form.
private struct InlineRowStyle: LabeledContentStyle {
    @Environment(\.appTextScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.label
                .multilineTextAlignment(.trailing)
                .frame(width: (130 * scale).rounded(), alignment: .trailing)
            configuration.content
        }
    }
}

extension WorkspaceModel {
    /// Opens a container session that is not saved in the tree.
    func openTransient(_ node: SessionTreeNode) {
        guard let container = node.container else { return }
        if container.tool.opensDesktop {
            reveal(tab: openDesktop(node, container).id)
            return
        }
        let tab = addLocalTab(launch: container.tool.runsCommand ? .command(container.commandLine) : nil, title: node.name, container: container)
        tab.environment = node.environment
        reveal(tab: tab.id)
    }

    /// Opens what the new-connection form describes: a desktop in the form's own tab, or a serial line in a terminal
    /// tab that takes the form's place.
    func openDraft(_ draft: SessionTab, _ node: SessionTreeNode, _ session: ContainerSession) {
        if session.tool.opensDesktop { configureDesktop(draft, node, session); return }
        if sessionTree.node(node.id) != nil { openSaved(node) } else { openTransient(node) }
        Task { await closeTab(draft) }
    }

    func editContainer(_ node: SessionTreeNode) {
        let kind: ToolWindowKind = node.container?.tool.opensDesktop == true ? .desktopEditor : .containers
        toolWindows[kind]?.close()
        let content = ContainerSessionEditor(model: self, editing: node) { [weak self] in self?.toolWindows[kind]?.close() }
        let window = ToolWindow(model: self, kind: kind, content: AnyView(content))
        toolWindows[kind] = window
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
    }
}
