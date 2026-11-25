import Foundation
import Combine
import Ssh
import FileTransfer
import GloamuxNetwork
import Terminal
import Profiles
import Formats
import Highlight
import MasterPassword
import LocalAuthentication
import AppKit

public struct HostKeyPrompt: Identifiable {
    public let id = UUID()
    public let endpoint: String
    public let fingerprint: String
    let key: String
}

/// Questions the server asks while signing in, such as a verification code, waiting for the user's answers.
public struct LoginChallengePrompt: Identifiable {
    public let id = UUID()
    public let endpoint: String
    public let challenge: SSHLoginChallenge
    /// Gloamux asks for the session key before connecting; the server has not asked anything yet.
    var asksSessionKey = false
}

struct HostKeyChange: Identifiable {
    let id = UUID()
    let endpoint: String
    let savedFingerprint: String
    let receivedFingerprint: String
    let savedKey: String
    let receivedKey: String
}

@MainActor public final class SessionTab: ObservableObject, Identifiable {
    public let id = UUID()
    var opensAutomatically = false
    var savedSessionID: UUID?
    /// The jump hosts the form lists, first dialed first.
    @Published var jumpPath: [UUID] = []
    /// Passwords or key passphrases typed for listed jump hosts, cleared when a connection starts.
    @Published var jumpSecrets: [UUID: String] = [:]
    /// The hosts the open connection went through, ending with the destination; empty without jump hosts.
    @Published var route: [RouteStop] = []
    /// The jump host sessions of `route`, first hop first, for checking the route from each server.
    var routeSessions: [SSHSession] = []
    @Published var checkingRoute = false
    /// Where the tab's connection is. One value, so a tab is never both connected and lost.
    @Published private(set) var connectionState: ConnectionState = .disconnected
    /// The connection dropped without the user ending it; Reconnect, or the automatic reconnect, can bring it back.
    var transportLost: Bool {
        get { connectionState == .lost }
        set { if newValue { moveConnection(to: .lost) } else if connectionState == .lost { moveConnection(to: .disconnected) } }
    }
    /// "Follow terminal folder" for this tab. Off for every new tab, so the file tree only moves when asked.
    @Published var followsFolder = false
    var pendingJump: SSHSession?
    var disconnectWatcher: Task<Void, Never>?
    /// Checks the connection while it is idle, so a dead network is noticed and a NAT does not drop it.
    var keepAliveTask: Task<Void, Never>?
    var triggerMatcher: OutputTriggerMatcher?
    /// The shell that already ran this session's startup commands.
    var startupTerminal: UUID?
    /// Waits to reconnect after the connection was lost.
    var reconnectTask: Task<Void, Never>?
    var reconnectAttempts = 0
    @Published var forwards: [SessionForward] = []
    @Published var forwardingRules: [ForwardingRule] = []
    @Published var forwardingErrors: [String] = []
    var forwardStarts: Set<UUID> = []
    var savedConnectionTask: Task<Void, Never>?
    @Published public var title = "New connection"
    /// The user named this tab, so connecting keeps that name.
    @Published var renamed = false
    /// Typing and pasting are ignored; output still shows.
    @Published var readOnly = false
    /// Bytes received from and sent to the session since it opened, for the status bar.
    var bytesReceived = 0
    var bytesSent = 0
    /// Lines in the terminal's selection, for the status bar.
    @Published var selectedLines = 0
    @Published public var host = ""
    @Published public var port = "22"
    @Published public var username = ""
    @Published public var password = ""
    @Published var identityPath: String?
    @Published var useAgent = false
    /// Forward this Mac's SSH agent into the shell, from the saved session.
    var forwardsAgent = false
    var forwardsX11 = false
    var agentSocket: String?
    var confirmsEachConnection = true
    @Published var keyPassphrase = ""
    @Published var showsFiles = false
    @Published public internal(set) var filesLoaded = false
    @Published public var useProxy = false
    @Published public var proxyKind: ProxyKind = .socks5
    @Published public var proxyHost = "127.0.0.1"
    @Published public var proxyPort = "1080"
    @Published public var status = "Disconnected"
    @Published public var error: String?
    @Published public var busy = false
    /// Signed in: an SSH or FTP session, a local shell, or a desktop on screen.
    public var connected: Bool {
        get { connectionState == .connected }
        set { if newValue { moveConnection(to: .connected) } else if connectionState == .connected { moveConnection(to: .disconnected) } }
    }
    @Published public var command = ""
    @Published public var remotePath = "."
    @Published public var entries: [RemoteEntry] = []
    @Published public var progress: Double?
    /// Plain text of the scrollback and screen. Built on demand: rebuilding it after every chunk of
    /// output cost more than drawing the terminal.
    public var transcript: String { lines.joined(separator: "\n") }
    /// What the terminal shows changes with every chunk of output. Only views that draw it observe `output`, so the
    /// rest of the pane (header, sign-in form, sheets) is not evaluated again for each chunk.
    let output = TerminalOutput()
    public var screenRevision: Int {
        get { output.revision }
        set { output.revision = newValue }
    }
    @Published var terminalFocusRequest = 0
    @Published public var hostKeyPrompt: HostKeyPrompt?
    @Published public var loginChallenge: LoginChallengePrompt?
    var loginContinuation: CheckedContinuation<[String], Error>?
    /// The user cancelled a sign-in question, so a lost connection is not reopened on its own.
    var loginCancelled = false
    @Published var hostKeyChange: HostKeyChange?
    @Published public var colorScheme: Formats.ColorScheme?
    @Published public var highlights: HighlightSet?
    var epoch = UUID()
    var terminalID = UUID()
    var fileOperationID = UUID()
    @Published public var terminalReady = false
    @Published public var terminalStarting = false
    @Published public var isLocal = false
    /// The local shell, Telnet connection, or serial port of a local tab.
    var localShell: (any TerminalTransport)?
    var shell: SSHInteractiveShell?
    var shellOutput: Task<Void, Never>?
    var inputTask: Task<Void, Never>?
    var resizeTask: Task<Void, Never>?
    var pendingInput: [[UInt8]] = []
    var pendingInputBytes = 0
    var session: SSHSession?
    var transfer: (any RemoteFileSystem)?
    var transferOpening: Task<any RemoteFileSystem, Error>?
    /// Set for an FTP or FTPS session, which has files and no terminal.
    var ftpSecurity: FTPSecurity?
    var ftpFingerprint: String?
    /// SFTP only, SCP only, or SFTP with SCP when the server has no SFTP (nil).
    var fileProtocol: FileProtocolChoice?
    var signIn: SignInMode?
    /// Where this session's files open, from the saved session.
    var remoteFolder: String?
    var localFolder: String?
    /// The session key this tab signed in with, kept while it is open and never saved or shown.
    var sessionKey: String?
    /// Copies from a pasted sftp command, started once the tab is connected.
    var pendingCopies: SFTPCopies?
    /// This connection's record in the history.
    var historyID: UUID?
    /// Reads the commands run in this connection, for its record.
    var commands: CommandCapture?
    /// `user@host` as the interface shows it.
    var account: String { (username.isEmpty ? "" : SessionKey.masked(username) + "@") + host }
    /// Folders shown in the remote file sidebar for this session.
    let remoteTree = RemoteTreeState()
    /// The folder the file transfer view shows for this session.
    let remoteBrowser = RemoteBrowserState()
    var trustContinuation: CheckedContinuation<Void, Error>?
    var screen = TerminalPreferences.newScreen()
    /// The last command reported by shell integration, for the pane header.
    @Published var lastCommand: CommandMark?
    /// A long command finished while the tab was out of sight; the tab bar marks it until it is shown.
    @Published var attention = false
    /// Asks the terminal view to jump between prompts or select output.
    @Published var navigation: TerminalNavigationRequest?
    /// The terminal that already has the shell integration hook typed into it.
    var integratedTerminal: UUID?
    /// What a local tab runs, kept so it can be started again in the same place.
    var localLaunch: LocalLaunch?
    /// The saved session's environment, shown on the tab and pane.
    @Published var environment: SessionEnvironment?
    /// A container, pod, or SSM session this local tab runs.
    @Published var container: ContainerSession?
    var desktop: RemoteDesktopSession?
    @Published var newConnectionType: NewConnectionType?
    /// A risky command held until the user confirms it.
    @Published var riskyCommand: RiskyCommandPrompt?
    /// What has been typed on the current line, for terminals without shell integration.
    var typedLine = ""
    /// The find bar's search, or nil while it is closed.
    @Published var search: TerminalSearch?
    @Published var searchStatus = TerminalSearchStatus()
    @Published var findFocusRequest = 0
    var lastSearchQuery = ""
    /// Changes for each visual bell.
    @Published var bellFlash = 0
    /// The bell rang while the tab was out of sight; the tab bar shows it until the tab is shown.
    @Published var bellPending = false
    /// New output arrived while the tab was out of sight; the tab bar shows a dot until the tab is shown.
    @Published var outputPending = false
    var lastBell = Date.distantPast
    /// The title a program set with OSC 0 or 2, shown in the pane header.
    @Published var programTitle: String?
    /// The character encoding of the session's output and input.
    @Published var encoding = TerminalEncoding.utf8 { didSet { if encoding != oldValue { decoder = TerminalDecoder(encoding: encoding) } } }
    var decoder = TerminalDecoder(encoding: .utf8)
    /// The SSH settings this tab connects with, from its form.
    var sshTarget: SavedConnection {
        var target = SavedConnection(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 22,
                                     username: username, proxyHost: useProxy ? proxyHost : nil,
                                     proxyPort: useProxy ? Int(proxyPort) : nil, identityPath: identityPath,
                                     usesAgent: useAgent, agentSocket: agentSocket,
                                     proxyKind: proxyKind, confirmsEachConnection: confirmsEachConnection)
        target.setJumpPath(jumpPath)
        target.signIn = signIn
        if let sessionKey, target.usesSessionKey { target.username = sessionKey }
        return target
    }
    public var credentialID: String {
        ConnectionService.credentialID(username: username, host: host, port: Int(port) ?? 22, ftp: ftpSecurity != nil)
    }
    public var lines: [String] { screen.scrollback.map { String($0.filter { $0.width != 0 }.map(\.character)) } + screen.lines }
    public init() {
        feed(T("Connect to a server to use the terminal, or open Remote files for SFTP.") + "\n")
    }
    func feed(_ text: String) {
        screen.feed(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
        screenRevision += 1
    }

    /// Changes the connection state; a change to the same state announces nothing.
    func moveConnection(to state: ConnectionState) {
        assert(connectionState.canMove(to: state), "\(connectionState) cannot become \(state)")
        if connectionState != state { connectionState = state }
    }
}

/// The states of a tab's connection and the moves between them.
enum ConnectionState: Equatable {
    /// Never connected, or ended on purpose.
    case disconnected
    case connected
    /// Ended by the network or the server.
    case lost

    /// A connection is lost only while it was up, or while a reconnect after a loss failed again.
    func canMove(to next: ConnectionState) -> Bool {
        switch (self, next) {
        case (.disconnected, .lost): return false
        default: return true
        }
    }
}

/// Counts changes to what a terminal shows. Views that draw the terminal, or follow it, observe this instead of the tab.
@MainActor final class TerminalOutput: ObservableObject {
    @Published var revision = 0
}

@MainActor public final class WorkspaceModel: ObservableObject {
    /// The window arrangement: Default, Classic, or Workbench. It applies at once and is remembered.
    @Published public private(set) var layout: WorkspaceLayout
    let storage: URL
    public weak var workspaceWindow: NSWindow?
    let restoresWorkspaceTabs: Bool
    var idleMonitor: Any?
    var idleTimer: Timer?
    var terminationObserver: NSObjectProtocol?

    func selectLayout(_ layout: WorkspaceLayout) throws {
        try layout.save(to: storage)
        self.layout = layout
    }

    @Published public private(set) var themeID = WorkspaceTheme.native.id
    @Published public private(set) var themePreview: ThemePreviewState?
    private var themePreviewTask: Task<Void, Never>?
    private var themePreviewGeneration = UUID()
    public let themes: [WorkspaceTheme]
    private let themePreferencesURL: URL
    public var displayedThemeID: String { themePreview?.activeID ?? themeID }
    public var theme: WorkspaceTheme { themes.first { $0.id == displayedThemeID } ?? .native }
    public func beginThemePreview() {
        guard themePreview == nil else { return }
        themePreview = ThemePreviewState(current: themeID)
    }
    public func focusThemePreview(_ id: String, schedule: Bool = true) throws {
        guard var preview = themePreview else { throw ThemeError.previewNotOpen }
        guard themes.contains(where: { $0.id == id }) else { throw ThemeError.unknownTheme }
        themePreviewTask?.cancel(); themePreviewGeneration = UUID()
        preview.focus(id); themePreview = preview
        let generation = themePreviewGeneration
        if schedule {
            themePreviewTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self, self.themePreviewGeneration == generation else { return }
                self.advanceThemePreview(milliseconds: 200)
            }
        }
    }
    public func advanceThemePreview(milliseconds: Int) {
        guard (0...30_000).contains(milliseconds), var preview = themePreview else { return }
        preview.advance(milliseconds); themePreview = preview
    }
    public func applyThemePreview() throws {
        guard let preview = themePreview else { throw ThemeError.previewNotOpen }
        try selectTheme(preview.selectedID)
    }
    public func cancelThemePreview() {
        themePreviewTask?.cancel(); themePreviewTask = nil; themePreviewGeneration = UUID(); themePreview = nil
    }
    public func selectTheme(_ id: String) throws {
        guard themes.contains(where: { $0.id == id }) else { throw ThemeError.unknownTheme }
        let bytes = try JSONEncoder().encode(ThemePreference(selectedID: id))
        try writePrivate(bytes, to: themePreferencesURL)
        themeID = id
        cancelThemePreview()
    }
    @Published public var language = UIStrings.language {
        didSet { UIStrings.language = language; UIStrings.store(language) }
    }
    @Published public var tabs: [SessionTab] = [SessionTab()]
    @Published public private(set) var selection: UUID?
    /// Split layouts. Each group shows as one tab in the tab bar; tabs outside every group show alone.
    @Published private(set) var groups: [WorkspaceSplit] = [] {
        didSet {
            if !groups.contains(where: { $0.contains(maximizedPane) }) { maximizedPane = nil }
            if split == nil { broadcastInput = false }
        }
    }
    /// The split layout on screen: the group that holds the selected tab.
    var split: WorkspaceSplit? { groups.first { $0.contains(selection) } }
    func group(containing id: UUID?) -> WorkspaceSplit? { groups.first { $0.contains(id) } }
    /// Replaces the group holding `member` (or adds one) with `layout`; nil dissolves it.
    private func setGroup(containing member: UUID, to layout: WorkspaceSplit?) {
        var updated = groups
        if let index = updated.firstIndex(where: { $0.contains(member) }) {
            if let layout { updated[index] = layout } else { updated.remove(at: index) }
        } else if let layout { updated.append(layout) }
        groups = updated
    }
    /// The pane temporarily filling the session area, if any. Its siblings keep running.
    @Published private(set) var maximizedPane: UUID?
    /// When on, keyboard input in any pane is sent to every pane in the split layout.
    @Published private(set) var broadcastInput = false
    /// The Workbench layout's MultiExec: keyboard input in any terminal of this window goes to every ready terminal
    /// of the window, its tab bar and the tabs moved to their own windows, whether or not they share a split.
    @Published private(set) var multiExec = false
    @Published public var vaultState = "Not configured"
    @Published public var vaultBusy = false
    @Published var vaultHasTouchID = false
    /// Passwords are saved on this Mac without unlocking the vault (any Mac with a Secure Enclave).
    @Published var savesWithoutUnlock = false
    /// Accounts and key passphrases that have a copy in the vault, for the "In vault" mark in the form.
    @Published var vaultEntries: Set<String> = []
    /// Stands in for the vault's Touch ID unlock in tests, which cannot answer the system prompt.
    /// Confirms the Mac's owner before a session marked to ask every time. Tests replace it.
    var confirmOwner: (String) async throws -> Void = { reason in
        // Under XCTest no one can answer the system prompt; tests that check the prompt set their own closure.
        if NSClassFromString("XCTestCase") != nil { return }
        // The context is kept until the answer arrives: a context released early ends the prompt with an error.
        let context = LAContext()
        defer { withExtendedLifetime(context) {} }
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
    @Published public var error: String?
    public let sessionTree: SessionTreeStore
    let quickCommands: QuickCommandStore
    public let knownHosts: KnownHosts
    let triggers: OutputTriggerStore
    var triggerCache: (source: [OutputTrigger], compiled: [(OutputTrigger, NSRegularExpression)])?
    /// The workspace is covered and ignores typing until the owner unlocks it.
    @Published var workspaceLocked = false
    var lastActivity = Date()
    public let vault: CredentialVault
    var sessionWindows: [UUID: SavedSessionWindow] = [:]
    /// Uploads and downloads started from any file panel or window.
    lazy var transfers = TransferQueue(model: self)
    /// What the middle of the main window shows: the two-pane file transfer view, terminals, or the session log.
    @Published private(set) var workspaceMode: WorkspaceMode = .terminal
    /// A session in its own window whose files the transfer view shows instead of the selected tab's.
    @Published var pinnedTransferTab: UUID?
    /// The left-hand folder of the file transfer view, kept while switching tabs and modes.
    let localBrowser = LocalBrowserState()
    /// This Mac's folder tree in the Mac layout's file sidebar, shown while the local terminal is focused.
    let localTree = LocalTreeState()
    /// The Mac layout's file transfer view follows the selected tab.
    let mainTransferTarget = TransferTarget(followsSelection: true)
    /// The Classic and Workbench layouts' own file transfer window.
    var transferWindow: FileTransferWindow?
    /// Set when a saved session that opens to its files has connected, so the layout can show them.
    @Published var filesRequest: FilesRequest?
    @Published var sftpCommandRequest: SFTPCommandRequest?
    /// Saved sessions opened most recently, for the menu bar and the command palette.
    let recents: RecentSessions
    /// Called with each command a tab's shell reports as finished, for runbooks waiting on a result.
    var commandObservers: [UUID: (CommandMark) -> Void] = [:]
    /// The ⌘⇧P command palette is open.
    @Published var commandPaletteShown = false
    /// A recording that was just saved, for the banner that offers to show it.
    @Published var recordingSaved: URL?
    /// Recordings, runbooks, host discovery, and other tool windows, by kind.
    var toolWindows: [ToolWindowKind: ToolWindow] = [:]
    /// Markdown runbooks in the workspace folder.
    let runbooks: RunbookLibrary
    /// Saved sessions in Spotlight.
    let spotlight = SpotlightIndex()
    /// Whether saved hosts answer on their SSH port, for the dots in the connection tree.
    lazy var reachability = Reachability()
    /// Terminal recordings in progress and saved.
    lazy var recordings = TerminalRecordings(folder: storage.appendingPathComponent("recordings", isDirectory: true))
    let history: ConnectionHistory
    /// The record of a command's connection.
    var commandHistoryID: UUID?
    lazy var logs = TerminalLogs(folder: storage.appendingPathComponent("logs", isDirectory: true))
    /// What the menu bar's workspace commands show, so the menus rebuild only when that changes.
    lazy var commandState = WorkspaceCommandState(model: self)

    nonisolated public static var defaultStorage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Gloamux", isDirectory: true)
    }
    public init(storage: URL? = nil, sharing source: WorkspaceModel? = nil) throws {
        let storage = (source?.storage ?? storage ?? Self.defaultStorage).standardizedFileURL
        if storage == Self.defaultStorage.standardizedFileURL || AppSSHKey.directory == nil { AppSSHKey.directory = storage }
        self.storage = storage
        restoresWorkspaceTabs = source == nil
        workspaceLocked = source?.workspaceLocked ?? false
        let layout = source?.layout ?? (try? WorkspaceLayout.load(from: storage)) ?? .native
        self.layout = layout
        themes = try source?.themes ?? ThemeCatalog.bundled()
        themePreferencesURL = storage.appendingPathComponent("appearance.json")
        if let data = try? Data(contentsOf: themePreferencesURL), let preference = try? JSONDecoder().decode(ThemePreference.self, from: data), themes.contains(where: { $0.id == preference.selectedID }) {
            themeID = preference.selectedID
        }
        sessionTree = try source?.sessionTree ?? SessionTreeStore(url: storage.appendingPathComponent("sessions.json"))
        quickCommands = source?.quickCommands ?? QuickCommandStore(url: storage.appendingPathComponent("quick-commands.json"))
        knownHosts = try source?.knownHosts ?? KnownHosts(url: storage.appendingPathComponent("known-hosts.json"))
        triggers = source?.triggers ?? OutputTriggerStore(url: storage.appendingPathComponent("triggers.json"))
        vault = try source?.vault ?? CredentialVault(url: storage.appendingPathComponent("password-vault.json"),
                                                   deviceSecrets: storage.appendingPathComponent("saved-sign-ins.json"))
        history = source?.history ?? ConnectionHistory(url: storage.appendingPathComponent("connection-history.jsonl"))
        recents = source?.recents ?? RecentSessions(url: storage.appendingPathComponent("recent-sessions.json"))
        runbooks = source?.runbooks ?? RunbookLibrary(folder: storage.appendingPathComponent("runbooks", isDirectory: true))
        selection = tabs[0].id
        observeWake()
    }
    public var selected: SessionTab? { tabs.first { $0.id == selection } }
    func selectTab(_ id: UUID, focusTerminal: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.attention = false
        tab.bellPending = false
        tab.outputPending = false
        if maximizedPane != nil && !(split?.contains(id) ?? false) { maximizedPane = nil }
        selection = id; pinnedTransferTab = nil
        // The session log does not follow the tabs, so choosing one leaves it.
        if workspaceMode == .log { workspaceMode = .terminal }
        if focusTerminal { tab.terminalFocusRequest += 1 }
    }

    /// Splits the selected pane. The new pane shows the most recent tab that is not already visible,
    /// or a new local terminal. Focus stays on the pane that was split.
    func splitWorkspace(_ axis: WorkspaceSplitAxis) {
        guard let active = selected, canSplit(active.id) else { return }
        let grouped = Set(groups.flatMap(\.tabIDs)).union([active.id])
        let added = tabs.last(where: { !grouped.contains($0.id) && canSplit($0.id) }) ?? addLocalTab(select: false)
        setGroup(containing: active.id, to: split?.splitting(active.id, axis: axis, adding: added.id)
            ?? WorkspaceSplit(axis: axis, first: active.id, second: added.id))
        maximizedPane = nil
        selectTab(active.id)
    }

    /// Only connected sessions and local terminals share the screen; a tab still showing its sign-in form does not.
    func canSplit(_ id: UUID?) -> Bool {
        tabs.first { $0.id == id }.map { $0.connected || $0.isLocal } ?? false
    }

    /// Ungroups the split on screen; its panes become separate tabs again.
    func closeSplit() {
        guard let selection else { return }
        setGroup(containing: selection, to: nil)
        selectTab(selection)
    }

    /// Takes a pane out of its split group and shows it as its own tab.
    func detachPane(_ id: UUID) {
        guard let layout = group(containing: id) else { return }
        setGroup(containing: id, to: layout.removing(id))
        selectTab(id)
    }

    /// Places a dragged tab on a pane. An edge splits that pane toward the edge; the center shows the
    /// dragged tab in that pane, swapping places when both are already visible. Dragging a visible
    /// pane to another edge moves it.
    func placeTab(_ dragged: UUID, at edge: PaneDropEdge, of target: UUID) {
        guard dragged != target, canSplit(dragged), canSplit(target) else { return }
        var root = group(containing: target)?.root ?? .tab(target)
        if !root.contains(dragged), let source = group(containing: dragged) {
            // Leaving another group: that group keeps its other panes.
            setGroup(containing: dragged, to: source.removing(dragged))
        }
        if edge == .center {
            root = root.contains(dragged) ? root.swapping(dragged, target) : root.replacing(target, with: dragged)
        } else {
            if root.contains(dragged) {
                guard let remaining = root.removing(dragged) else { return }
                root = remaining
            }
            root = root.splitting(target, axis: edge.axis, adding: dragged, newFirst: edge.placesNewFirst)
        }
        setGroup(containing: target, to: nil)
        if let layout = WorkspaceSplit.make(root) { groups.append(layout) }
        maximizedPane = nil
        selectTab(dragged)
    }

    func toggleMaximizedPane(_ id: UUID) {
        guard split?.contains(id) == true else { return }
        maximizedPane = maximizedPane == id ? nil : id
        selectTab(id)
    }

    func toggleBroadcastInput() {
        broadcastInput = split != nil && !broadcastInput
    }

    func toggleMultiExec() {
        multiExec.toggle()
    }

    /// Connected SSH sessions of this window, in tabs or windows of their own, for the Tunnels window and
    /// `gloamux forwards live-list`. A tab that is not connected shows the new-connection form, so it is left out.
    var tunnelTabs: [SessionTab] {
        (tabs + sessionWindows.values.map(\.tab))
            .filter { $0.connected && !$0.isLocal && $0.desktop == nil && $0.ftpSecurity == nil && $0.container == nil }
    }

    /// Keyboard and paste input from a terminal view. Terminal replies and quick commands use
    /// `sendTerminal` and always stay with their own tab.
    func typeTerminal(_ tab: SessionTab, bytes: [UInt8]) {
        let targets: [SessionTab]
        let terminals = tabs + sessionWindows.values.map(\.tab)
        if multiExec, terminals.contains(where: { $0 === tab }) {
            targets = [tab] + terminals.filter { $0 !== tab && $0.desktop == nil && $0.terminalReady }
        } else if broadcastInput, let layout = split, layout.contains(tab.id) {
            targets = layout.tabIDs.compactMap { id in tabs.first { $0.id == id } }
        } else { targets = [tab] }
        guard !workspaceLocked else { return }
        if tab.readOnly { NSSound.beep() }
        for target in targets where !target.readOnly {
            // In a production session (or another environment set to confirm), a risky command waits for a yes.
            if let command = riskyCommand(in: target, typing: bytes) {
                target.riskyCommand = RiskyCommandPrompt(command: command, bytes: bytes, environment: target.environment ?? .production,
                                                         terminalID: target.terminalID)
                continue
            }
            if enqueueTerminalInput(target, bytes: bytes) { trackTyping(target, bytes) }
        }
    }

    /// Sends a held risky command after the user confirms it.
    func confirmRiskyCommand(_ tab: SessionTab, run: Bool) {
        guard let prompt = tab.riskyCommand else { return }
        // While the window is locked the question waits; it is answered once the owner unlocks.
        if run, workspaceLocked { return }
        tab.riskyCommand = nil
        guard run, tab.terminalID == prompt.terminalID else { return }
        if enqueueTerminalInput(tab, bytes: prompt.bytes) { trackTyping(tab, prompt.bytes) }
    }

    /// The command line that `bytes` would run in a confirming environment, when it matches a risky pattern.
    func riskyCommand(in tab: SessionTab, typing bytes: [UInt8]) -> String? {
        guard let environment = tab.environment, SessionEnvironment.confirming.contains(environment), bytes.contains(0x0D),
              !bytes.starts(with: Array("\u{1b}[200~".utf8)) else { return nil }
        // The line as the shell shows it, when shell integration marks where typing starts; otherwise what was typed.
        var current = tab.typedLine
        if let mark = tab.screen.commandMarks.last, mark.outputLine == nil, let input = mark.inputLine {
            let cursor = tab.screen.absoluteLine(ofRow: tab.screen.cursorRow)
            current = tab.screen.text(lines: input..<max(input + 1, cursor + 1), fromColumn: mark.inputColumn ?? 0)
        }
        let typed = String(decoding: bytes.filter { $0 == 0x0D || $0 >= 0x20 && $0 != 0x7F }, as: UTF8.self)
        let lines = (current + typed).split(separator: "\r", omittingEmptySubsequences: false).dropLast().map(String.init)
        return lines.first { RiskyCommands.match($0) != nil }
    }

    func trackTyping(_ tab: SessionTab, _ bytes: [UInt8]) {
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x03, 0x15: tab.typedLine = ""
            case 0x7F, 0x08: if !tab.typedLine.isEmpty { tab.typedLine.removeLast() }
            case 0x1B: return
            case 0x20...: if tab.typedLine.count < 4096 { tab.typedLine.unicodeScalars.append(scalar) }
            default: break
            }
        }
    }

    @discardableResult public func addTab(select: Bool = true) -> SessionTab {
        let tab = SessionTab()
        tabs.append(tab)
        if select { selectTab(tab.id) }
        return tab
    }
    /// A new-connection form, open on `type`, or on the kind used last. `remember` makes `type` the next one's
    /// kind too, for a kind the user chose.
    @discardableResult func newConnectionTab(_ type: NewConnectionType? = nil, remember: Bool = false) -> SessionTab {
        if remember, let type { NewConnectionType.last = type }
        let tab = addTab(select: false)
        tab.newConnectionType = type ?? NewConnectionType.last
        workspaceMode = .terminal
        selectTab(tab.id)
        return tab
    }
    /// The + buttons: the New connection form, or a local terminal for those who set new tabs to open one.
    /// New connection itself (⇧⌘N) always opens the form.
    @discardableResult func newTab() -> SessionTab {
        TerminalPreferences.newTabOpensLocal ? addLocalTab() : newConnectionTab()
    }
    @discardableResult public func addLocalTab(select: Bool = true) -> SessionTab {
        addLocalTab(select: select, launch: nil)
    }

    /// A local terminal. Without a launch it is the login shell, in the folder of the focused local terminal when
    /// shell integration reports one, so ⌘T opens where you are working.
    @discardableResult func addLocalTab(select: Bool = true, launch: LocalLaunch?, title: String = "Local terminal",
                                        container: ContainerSession? = nil) -> SessionTab {
        let folder = selected.flatMap { $0.isLocal && $0.localLaunch?.arguments.contains("-c") != true ? $0.screen.workingDirectory : nil }
        let tab = addTab(select: false)
        startLocal(tab, launch: launch ?? .loginShell(directory: folder, integration: ShellIntegration.local), title: title, container: container)
        if select { selectTab(tab.id) }
        return tab
    }

    /// Turns a new-connection tab into a terminal on this Mac, in place, from the Local row at the top of the form.
    func openLocalTerminal(in tab: SessionTab) {
        guard !tab.isLocal, !tab.connected, !tab.busy, tab.desktop == nil, tab.savedSessionID == nil else { return }
        tab.newConnectionType = nil
        tab.error = nil
        startLocal(tab, launch: .loginShell(directory: nil, integration: ShellIntegration.local), title: "Local terminal", container: nil)
        if selection == tab.id {
            // The file sidebar observes the workspace, so an in-place change of the selected tab's kind must redraw it.
            objectWillChange.send()
            tab.terminalFocusRequest += 1
        }
    }

    private func startLocal(_ tab: SessionTab, launch: LocalLaunch, title: String, container: ContainerSession?) {
        tab.isLocal = true; tab.title = title
        tab.host = container?.summary ?? "127.0.0.1"; tab.username = NSUserName(); tab.container = container
        tab.encoding = container?.encoding ?? .utf8
        tab.screen = TerminalPreferences.newScreen(); tab.screenRevision += 1
        tab.localLaunch = launch
        startLocalTerminal(tab)
    }
    public func startLocalTerminal(_ tab: SessionTab) {
        guard tab.isLocal, tab.localShell == nil else { return }
        let epoch = UUID(); tab.epoch = epoch
        let pump = TerminalOutputPump { [weak self, weak tab] bytes, ended in
            guard let tab, tab.epoch == epoch else { return }
            if !bytes.isEmpty { self?.terminalReceived(tab, bytes: bytes) }
            if ended {
                tab.localShell?.close(); tab.localShell = nil
                tab.terminalReady = false; tab.connected = false
                tab.status = tab.container?.tool.runsCommand == false ? "Connection closed" : "Shell closed"
                self?.recordings.stop(tab)
                self?.logs.stop(tab)
                self?.endHistory(tab, .closed)
            }
        }
        let output: @Sendable ([UInt8]) -> Void = { bytes in pump.push(bytes) }
        switch tab.container?.tool {
        case .telnet?:
            guard let container = tab.container else { return }
            tab.connected = false; tab.terminalReady = false; tab.status = "Connecting…"; tab.error = nil
            let rows = tab.screen.rows, columns = tab.screen.cols
            beginHistory(tab)
            Task { @MainActor [weak self, weak tab] in
                do {
                    let connection = try await TelnetConnection.connect(host: container.target, port: container.effectivePort,
                                                                         terminalType: TerminalPreferences.terminalType,
                                                                         rows: rows, columns: columns, output: output)
                    guard let tab, tab.epoch == epoch else { connection.close(); return }
                    tab.localShell = connection
                    self?.localTerminalStarted(tab)
                } catch {
                    guard let tab, tab.epoch == epoch else { return }
                    tab.status = "Connection failed"; tab.error = message(for: error)
                    self?.endHistory(tab, .failed, detail: tab.error)
                }
            }
        case .serial?:
            guard let container = tab.container else { return }
            beginHistory(tab)
            do {
                tab.localShell = try SerialPort(path: container.target, settings: container.serialSettings) { output(Array($0)) }
                localTerminalStarted(tab)
            } catch {
                tab.status = "Connection failed"; tab.error = message(for: error)
                endHistory(tab, .failed, detail: tab.error)
            }
        default:
            let launch = tab.localLaunch ?? .loginShell(integration: ShellIntegration.local)
            tab.localLaunch = launch
            do {
                let shell = try LocalShell(rows: tab.screen.rows, columns: tab.screen.cols, launch: launch) { output(Array($0)) }
                pump.attach(shell)
                tab.localShell = shell
                localTerminalStarted(tab)
            } catch { tab.error = error.localizedDescription }
        }
    }

    private func localTerminalStarted(_ tab: SessionTab) {
        tab.terminalID = UUID()
        tab.connected = true; tab.terminalReady = true; tab.status = "Connected"; tab.error = nil
        if tab.container != nil {
            if tab.historyID == nil { beginHistory(tab) }
            noteHistory(tab, .connected)
        }
        startAutomaticLog(tab)
    }
    public func closeTab(_ tab: SessionTab) async {
        await disconnect(tab)
        removeFromTabBar(tab)
    }
    /// Takes a tab out of the tab bar and its split, and shows a neighbor. The last tab gives way to a local terminal.
    func removeFromTabBar(_ tab: SessionTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if let layout = group(containing: tab.id) {
            let remaining = layout.tabIDs.filter { $0 != tab.id }
            setGroup(containing: tab.id, to: layout.removing(tab.id))
            if selection == tab.id, let next = remaining.first { selectTab(next) }
        } else if tabs.isEmpty {
            _ = addLocalTab()
        } else if selection == tab.id {
            selectTab(tabs[min(index, tabs.count - 1)].id)
        }
    }
    /// Disconnects and closes the tab, or its own window when it was opened in one.
    public func disconnectAndClose(_ tab: SessionTab) async {
        if let window = sessionWindows[tab.id]?.window { window.close(); return }
        await closeTab(tab)
    }
    public func disconnect(_ tab: SessionTab) async {
        await endConnection(tab, lost: false)
    }

    private func endConnection(_ tab: SessionTab, lost: Bool) async {
        tab.savedConnectionTask?.cancel(); tab.savedConnectionTask = nil
        tab.desktop?.disconnect()
        tab.epoch = UUID()
        tab.localShell?.close(); tab.localShell = nil
        answerHostKey(tab, approve: false)
        answerLogin(tab, answers: nil)
        tab.hostKeyChange = nil
        let ssh = tab.session, transfer = tab.transfer, shell = tab.shell, jump = tab.pendingJump
        tab.pendingJump = nil
        tab.route = []; tab.routeSessions = []; tab.checkingRoute = false
        tab.disconnectWatcher?.cancel()
        tab.disconnectWatcher = nil
        tab.keepAliveTask?.cancel(); tab.keepAliveTask = nil
        if !lost { tab.reconnectTask?.cancel(); tab.reconnectTask = nil; tab.reconnectAttempts = 0 }
        endHistory(tab, lost ? .lost : .closed)
        tab.sessionKey = nil
        tab.pendingCopies = nil
        let forwards = tab.forwards
        tab.forwards = []
        tab.forwardStarts.removeAll()
        tab.forwardingErrors = []
        tab.resizeTask?.cancel(); tab.resizeTask = nil
        tab.shellOutput?.cancel(); tab.inputTask?.cancel(); tab.shellOutput = nil; tab.inputTask = nil
        tab.shell = nil; tab.terminalReady = false; tab.terminalStarting = false; tab.pendingInput = []; tab.pendingInputBytes = 0
        tab.transferOpening = nil; tab.remoteTree.reset(); tab.remoteBrowser.clear()
        recordings.stop(tab)
        logs.stop(tab)
        tab.session = nil; tab.transfer = nil; tab.busy = false; tab.progress = nil; tab.status = "Disconnected"
        tab.password = ""; tab.keyPassphrase = ""; tab.jumpSecrets = [:]; tab.filesLoaded = false; tab.entries = []
        // Straight to the end state: a lost connection was up until now.
        tab.moveConnection(to: lost ? .lost : .disconnected)
        if lost {
            tab.status = "Connection lost"
            tab.error = nil
            tab.feed("\u{1b}[?1049l\u{1b}[?2004l\n" + T("Connection lost") + "\n")
        }
        for forward in forwards { await forward.handle.close() }
        await shell?.close()
        try? await transfer?.close()
        try? await ssh?.close()
        try? await jump?.close()
    }
    public func closeWorkspaceTabs(lockingVault: Bool = true) async {
        saveOpenTabs()
        stopWorkspaceObservers()
        for tab in tabs { await disconnect(tab) }
        if lockingVault, sessionWindows.isEmpty { await lockVault() }
    }

    public func closeWorkspaceWindow(lockingVault: Bool) async {
        saveOpenTabs()
        stopWorkspaceObservers()
        for window in Array(toolWindows.values) { window.close() }
        transferWindow?.close()
        transferWindow = nil
        await closeAll(lockingVault: lockingVault)
    }
    public func closeAll(lockingVault: Bool = true) async {
        let windows = Array(sessionWindows.values)
        for controller in windows { controller.close(); await disconnect(controller.tab) }
        for tab in tabs { await disconnect(tab) }
        if lockingVault { await lockVault() }
    }

    public func connect(_ tab: SessionTab) async {
        guard tab.desktop == nil, NewConnectionType.usesSSHForm(tab.newConnectionType) else { return }
        if tab.isLocal { startLocalTerminal(tab); return }
        guard !tab.busy, !tab.connected else { return }
        tab.error = nil
        tab.hostKeyChange = nil
        tab.loginCancelled = false
        tab.forwardingErrors = []
        if let id = tab.savedSessionID {
            tab.forwardingRules = sessionTree.node(id)?.connection?.forwardingRules ?? []
        }
        let host = tab.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let security = tab.ftpSecurity {
            guard let port = Int(tab.port), (1...65535).contains(port), !host.isEmpty else { tab.error = "Enter a host and valid TCP ports."; return }
            await connectFTP(tab, host: host, port: port, security: security)
            return
        }
        guard Int(tab.port).map({ (1...65535).contains($0) }) == true, !host.isEmpty, !tab.username.isEmpty || tab.signIn == .sessionKey,
              !tab.useProxy || (!tab.proxyHost.isEmpty && Int(tab.proxyPort).map { (1...65535).contains($0) } == true) else {
            tab.error = "Enter a host, username and valid TCP ports."
            return
        }
        tab.host = host
        let epoch = UUID()
        tab.epoch = epoch
        if tab.signIn == .sessionKey {
            guard await askSessionKey(tab, epoch: epoch) else { return }
        }
        let target = tab.sshTarget
        let service = connections
        let hops: [SavedConnection]
        do { hops = try service.jumpHosts(for: target, excluding: tab.savedSessionID) } catch {
            tab.error = message(for: error)
            return
        }

        if !tab.opensAutomatically && !tab.renamed { tab.title = tab.account }
        tab.busy = true
        tab.status = "Connecting…"
        let secret = tab.identityPath == nil ? (tab.useAgent ? "" : tab.password) : tab.keyPassphrase
        // The listed hops are the last ones of the chain; hops before them come from the first one's own settings.
        let hopNames = sessionTree.jumpRoute(for: target, excluding: tab.savedSessionID)?.map(\.name) ?? []
        let listed = tab.jumpPath.map { tab.jumpSecrets[$0] ?? "" }
        let jumpSecrets = Array(repeating: "", count: max(0, hops.count - listed.count)) + listed.suffix(hops.count)
        tab.password = ""; tab.keyPassphrase = ""; tab.jumpSecrets = [:]
        defer { if tab.epoch == epoch { tab.busy = false } }
        beginHistory(tab, key: tab.signIn == .sessionKey ? tab.sessionKey : nil)
        history.addRoute(to: tab.historyID, target: target, hops: hops, names: hopNames)
        do {
            let signIn = TabSignIn(model: self, tab: tab, epoch: epoch)
            let ssh = try await service.openSSH(target, hops: hops, secret: secret, jumpSecrets: jumpSecrets, handler: signIn) { server in
                if tab.epoch == epoch { tab.pendingJump = server; tab.routeSessions.append(server) }
            }
            tab.pendingJump = nil
            tab.session = ssh
            tab.route = hops.isEmpty ? [] : hops.enumerated().map { index, hop in
                routeStop(index < hopNames.count ? hopNames[index] : hop.host, hop)
            } + [routeStop(tab.title, target)]
            tab.connected = true
            tab.transportLost = false
            tab.status = "Connected"
            noteHistory(tab, .connected)
            if let id = tab.savedSessionID, let key = tab.sessionKey { sessionTree.sessionKeys[id] = key }
            tab.feed(T("Connected to") + " \(KnownHosts.endpoint(host: target.host, port: target.port))\n")
            tab.disconnectWatcher = Task { @MainActor [weak self, weak tab] in
                await ssh.waitForDisconnect()
                guard !Task.isCancelled, let self, let tab, tab.epoch == epoch else { return }
                await self.endConnection(tab, lost: true)
                self.scheduleReconnect(tab)
            }
            tab.reconnectAttempts = 0
            startKeepAlive(tab, session: ssh, epoch: epoch)
            await startSavedForwards(tab, epoch: epoch)
        } catch {
            guard tab.epoch == epoch else { return }
            let server = tab.pendingJump
            tab.pendingJump = nil
            tab.routeSessions = []
            answerHostKey(tab, approve: false)
            answerLogin(tab, answers: nil)
            tab.status = "Connection failed"
            tab.error = ConnectionService.failureText(error, reported: tab.error)
            endHistory(tab, .failed, detail: tab.error)
            // A key that did not work is asked for again next time.
            if let id = tab.savedSessionID, tab.signIn == .sessionKey { sessionTree.sessionKeys[id] = nil }
            tab.sessionKey = nil
            try? await server?.close()
        }
    }

    /// The vault entry that holds a private key's passphrase.
    static func passphraseID(_ path: String) -> String { "passphrase:" + path }

    func confirmKey(_ tab: SessionTab, endpoint: String, key: String, epoch: UUID) async throws {
        guard tab.epoch == epoch else { throw WorkspaceError.rejectedHostKey }
        do { if try knownHosts.isTrusted(endpoint: endpoint, key: key) { return } }
        catch WorkspaceError.changedHostKey {
            guard let savedKey = knownHosts.trustedKey(for: endpoint) else { throw WorkspaceError.rejectedHostKey }
            tab.hostKeyChange = try HostKeyChange(endpoint: endpoint, savedFingerprint: KnownHosts.fingerprint(savedKey),
                                                  receivedFingerprint: KnownHosts.fingerprint(key), savedKey: savedKey, receivedKey: key)
            knownHosts.record(.blocked, endpoint: endpoint, key: key, previous: savedKey)
            tab.error = "The server host key has changed. Review its fingerprint before reconnecting."
            throw WorkspaceError.changedHostKey(endpoint)
        } catch { tab.error = message(for: error); throw error }
        guard tab.trustContinuation == nil else { throw WorkspaceError.rejectedHostKey }
        let prompt = HostKeyPrompt(endpoint: endpoint, fingerprint: try KnownHosts.fingerprint(key), key: key)
        try await withCheckedThrowingContinuation { continuation in tab.trustContinuation = continuation; tab.hostKeyPrompt = prompt }
        guard tab.epoch == epoch else { throw WorkspaceError.rejectedHostKey }
    }
    func askLogin(_ tab: SessionTab, endpoint: String, challenge: SSHLoginChallenge, epoch: UUID, asksSessionKey: Bool = false) async throws -> [String] {
        guard tab.epoch == epoch, tab.loginContinuation == nil else { throw SSHError.signInCancelled }
        let prompt = LoginChallengePrompt(endpoint: endpoint, challenge: challenge, asksSessionKey: asksSessionKey)
        let answers = try await withCheckedThrowingContinuation { continuation in
            tab.loginContinuation = continuation
            tab.loginChallenge = prompt
        }
        guard tab.epoch == epoch else { throw SSHError.signInCancelled }
        return answers
    }

    /// Sends the answers to the server's sign-in questions, or cancels the sign-in with nil.
    public func answerLogin(_ tab: SessionTab, answers: [String]?) {
        guard let continuation = tab.loginContinuation else { return }
        tab.loginContinuation = nil
        tab.loginChallenge = nil
        if let answers { continuation.resume(returning: answers) }
        else {
            tab.loginCancelled = true
            continuation.resume(throwing: SSHError.signInCancelled)
        }
    }

    public func answerHostKey(_ tab: SessionTab, approve: Bool) {
        guard let continuation = tab.trustContinuation else { return }
        let prompt = tab.hostKeyPrompt
        tab.trustContinuation = nil; tab.hostKeyPrompt = nil
        do {
            try Self.settleHostKey(prompt, approve: approve, knownHosts: knownHosts)
            continuation.resume()
        } catch { continuation.resume(throwing: error) }
    }

    private func routeStop(_ name: String, _ connection: SavedConnection) -> RouteStop {
        let endpoint = KnownHosts.endpoint(host: connection.host, port: connection.port)
        return RouteStop(name: name, endpoint: endpoint,
                         fingerprint: knownHosts.trustedKey(for: endpoint).flatMap { try? KnownHosts.fingerprint($0) })
    }

    /// Asks every server on the route where it sees the connection coming from (`$SSH_CONNECTION`), so the user can
    /// see that each one was reached from the host before it. Runs only when asked: a server with a forced command
    /// runs that command instead.
    func checkRoute(_ tab: SessionTab) async {
        guard let destination = tab.session, !tab.checkingRoute, tab.route.count == tab.routeSessions.count + 1 else { return }
        let epoch = tab.epoch
        tab.checkingRoute = true
        defer { if tab.epoch == epoch { tab.checkingRoute = false } }
        for (index, session) in (tab.routeSessions + [destination]).enumerated() {
            let reply = try? await session.runCommand("printf '%s' \"$SSH_CONNECTION\"", maxResponseBytes: 512, timeoutSeconds: 20)
            guard tab.epoch == epoch, index < tab.route.count else { return }
            tab.route[index].seen = RouteStop.Seen(sshConnection: reply)
        }
    }

    func updateHostKeyAndReconnect(_ tab: SessionTab, change: HostKeyChange) async {
        guard !tab.busy, !tab.connected, tab.hostKeyChange?.id == change.id else { return }
        let host = tab.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = Int(tab.port).map { KnownHosts.endpoint(host: host, port: $0) }
        var probe = SavedConnection(host: host, port: Int(tab.port) ?? 22, username: tab.username)
        probe.setJumpPath(tab.jumpPath)
        let jumps = (sessionTree.jumpChain(for: probe, excluding: tab.savedSessionID) ?? [])
            .map { KnownHosts.endpoint(host: $0.host, port: $0.port) }
        guard change.endpoint == target || jumps.contains(change.endpoint) else {
            tab.hostKeyChange = nil
            tab.error = "Connection settings changed. Connect again to review the host key."
            return
        }
        do { try knownHosts.replace(endpoint: change.endpoint, expectedKey: change.savedKey, with: change.receivedKey) }
        catch {
            tab.hostKeyChange = nil
            tab.error = message(for: error)
            return
        }
        await connect(tab)
    }
    public func startTerminal(_ tab: SessionTab) async {
        guard tab.connected, let ssh = tab.session, tab.shell == nil, !tab.terminalStarting else { return }
        let epoch = tab.epoch; tab.terminalStarting = true
        defer { if tab.epoch == epoch { tab.terminalStarting = false } }
        do {
            let agent = tab.forwardsAgent ? (tab.agentSocket ?? SSHAgentClient.environment()?.socketPath) : nil
            var x11: SSHX11Configuration?
            if tab.forwardsX11 {
                x11 = try await Task.detached(priority: .userInitiated) { try SSHX11Configuration.localDisplay() }.value
                guard tab.epoch == epoch else { return }
            }
            let shell = try await ssh.openShell(rows: tab.screen.rows, columns: tab.screen.cols,
                                                term: TerminalPreferences.terminalType, agentSocket: agent, x11: x11)
            guard tab.epoch == epoch else { await shell.close(); return }
            try await shell.resize(rows: tab.screen.rows, columns: tab.screen.cols)
            guard tab.epoch == epoch else { await shell.close(); return }
            tab.terminalID = UUID()
            tab.shell = shell; tab.terminalReady = true; tab.error = nil
            startAutomaticLog(tab)
            if ShellIntegration.remote { installShellIntegration(tab) }
            runStartupCommands(tab)
            tab.shellOutput = Task { @MainActor [weak self, weak tab] in
                do {
                    for try await bytes in shell.output {
                        guard let tab, tab.epoch == epoch, !Task.isCancelled else { return }
                        self?.terminalReceived(tab, bytes: bytes)
                    }
                } catch { if let tab, tab.epoch == epoch, !Task.isCancelled { tab.error = message(for: error) } }
                if let tab, tab.epoch == epoch {
                    tab.inputTask?.cancel(); tab.inputTask = nil
                    tab.pendingInput.removeAll(); tab.pendingInputBytes = 0
                    tab.terminalReady = false; tab.shell = nil; tab.status = "Shell closed"
                    // `exit` or `logout` ends the session like a terminal app: the tab goes away. A shell that
                    // stops without an exit status (the connection dropped) keeps the tab for Reconnect.
                    if shell.exitStatus != nil, tab.error == nil, !Task.isCancelled {
                        tab.shellOutput = nil
                        await self?.disconnectAndClose(tab)
                    }
                }
            }
        } catch { if tab.epoch == epoch { tab.error = message(for: error) } }
    }
    public func sendTerminal(_ tab: SessionTab, bytes: [UInt8]) {
        enqueueTerminalInput(tab, bytes: bytes, records: false)
    }

    /// Output from a shell: draws it, answers terminal queries, records it, and notes finished commands.
    func terminalReceived(_ tab: SessionTab, bytes raw: [UInt8]) {
        let bytes = tab.decoder.decode(raw)
        tab.bytesReceived += raw.count
        if !tab.outputPending, tab.id != selection, !isVisible(tab) { tab.outputPending = true }
        let scrollback = TerminalPreferences.scrollback
        if tab.screen.options.scrollbackSize != scrollback { tab.screen.setScrollbackSize(scrollback) }
        if let commands = tab.commands { commands.feed(bytes, to: tab.screen) } else { tab.screen.feed(bytes) }
        tab.screenRevision += 1
        recordings.output(tab, bytes: bytes)
        logs.output(tab, bytes: bytes)
        runTriggers(tab, bytes: bytes)
        for event in tab.screen.takeEvents() {
            switch event {
            case .reply(let reply): sendTerminal(tab, bytes: reply)
            case .commandFinished(let mark): commandFinished(tab, mark)
            case .bell: ringBell(tab)
            case .title(let title):
                let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                // Shells set the title at every prompt; an unchanged one would redraw every view of the tab.
                let programTitle = trimmed.isEmpty ? nil : trimmed
                if tab.programTitle != programTitle { tab.programTitle = programTitle }
            case .clipboard(let text):
                // OSC 52 lets a program on the server write the Mac's clipboard, so it is off unless turned on.
                if TerminalPreferences.allowsClipboardWrites {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }

    /// The bell: a flash or the system sound, at most four times a second. Out of sight, the tab shows a bell.
    private func ringBell(_ tab: SessionTab) {
        let now = Date()
        guard now.timeIntervalSince(tab.lastBell) >= 0.25 else { return }
        tab.lastBell = now
        if !isVisible(tab) && tab.id != selection { tab.bellPending = true }
        switch TerminalPreferences.bell {
        case .flash: tab.bellFlash += 1
        case .sound: NSSound.beep()
        case .off: break
        }
    }

    /// Starts or stops the session log for a tab.
    func toggleLogging(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        if logs.isLogging(tab) { logs.stop(tab) } else { startLog(tab) }
    }

    /// Starts a log for a terminal that just opened, when Settings logs every session.
    func startAutomaticLog(_ tab: SessionTab) {
        if TerminalPreferences.logsEverySession { startLog(tab) }
    }

    private func startLog(_ tab: SessionTab) {
        if let url = logs.start(tab) { noteHistory(tab, .log, detail: url.path) }
    }

    /// Changes a tab's encoding, and the saved session's, so it opens the same way next time.
    func setEncoding(_ encoding: TerminalEncoding, for tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        tab.encoding = encoding
        guard let id = tab.savedSessionID, let node = sessionTree.nodes.first(where: { $0.id == id }) else { return }
        if var container = node.container, !container.tool.opensDesktop {
            container.encoding = encoding == .utf8 ? nil : encoding
            try? sessionTree.updateContainer(id, name: node.name, container: container, environment: node.environment)
            return
        }
        guard var connection = node.connection else { return }
        connection.encoding = encoding == .utf8 ? nil : encoding
        try? sessionTree.updateConnection(id, name: node.name, connection: connection)
    }

    /// Whether a tab is on screen: the selected tab, a pane of the split on screen, or a session in its own window.
    func isVisible(_ tab: SessionTab) -> Bool {
        // NSApp is nil when no app is running, as in tests; nothing is on screen then.
        (NSApp?.isActive ?? false) && (tab.id == selection || split?.contains(tab.id) == true || sessionWindows[tab.id]?.window?.isKeyWindow == true)
    }

    private func commandFinished(_ tab: SessionTab, _ mark: CommandMark) {
        tab.lastCommand = mark
        commandObservers[tab.id]?(mark)
        let threshold = ShellIntegration.notifyAfter
        guard threshold > 0, let duration = mark.duration, duration >= threshold, !isVisible(tab) else { return }
        if tab.id != selection { tab.attention = true }
        let command = mark.command.map { String($0.prefix(80)) } ?? T("Command")
        let result = mark.exitCode.map { $0 == 0 ? T("Succeeded") : String(format: T("Exit code %d"), $0) } ?? T("Finished")
        CommandNotifier.shared.model = self
        CommandNotifier.shared.notify(title: command, body: "\(result) · \(formatDuration(duration)) · \(UIStrings.text(tab.title, language: language))", tab: tab.id)
    }

    /// Shows a tab from a notification or the menu bar: selects it, or brings its own window forward.
    func reveal(tab id: UUID) {
        if let window = sessionWindows[id]?.window { window.makeKeyAndOrderFront(nil); return }
        guard tabs.contains(where: { $0.id == id }) else { return }
        workspaceMode = .terminal
        selectTab(id)
        bringForward()
    }

    /// Types the shell integration hook into a remote or non-zsh local shell, once per terminal.
    func installShellIntegration(_ tab: SessionTab) {
        guard tab.terminalReady, tab.integratedTerminal != tab.terminalID else { return }
        tab.integratedTerminal = tab.terminalID
        enqueueTerminalInput(tab, bytes: Array(ShellIntegration.hook.utf8) + [0x0D], records: false)
    }

    /// Whether the shell in a tab reports its prompts.
    func hasShellIntegration(_ tab: SessionTab) -> Bool { !tab.screen.commandMarks.isEmpty }

    func navigate(_ action: TerminalNavigation, in tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        tab.navigation = TerminalNavigationRequest(action: action)
    }

    /// `records` is false for what a user or command did not type, such as a terminal's replies.
    @discardableResult func enqueueTerminalInput(_ tab: SessionTab, bytes utf8: [UInt8], records: Bool = true) -> Bool {
        let bytes = tab.encoding.encode(utf8)
        guard tab.terminalReady, !bytes.isEmpty, bytes.count <= 262144 else { return false }
        tab.bytesSent += bytes.count
        if tab.isLocal {
            guard let shell = tab.localShell else { return false }
            if records { captureCommands(tab, utf8) }
            shell.send(bytes)
            return true
        }
        guard let shell = tab.shell else { return false }
        guard tab.pendingInputBytes + bytes.count <= 262144 else { tab.error = "Terminal input queue exceeds 256 KiB."; return false }
        if records { captureCommands(tab, utf8) }
        tab.pendingInput.append(bytes); tab.pendingInputBytes += bytes.count
        guard tab.inputTask == nil else { return true }
        let epoch = tab.epoch
        let terminalID = tab.terminalID
        tab.inputTask = Task { @MainActor [weak tab] in
            guard let tab else { return }
            defer { if tab.epoch == epoch, tab.shell === shell { tab.inputTask = nil } }
            while !tab.pendingInput.isEmpty, tab.epoch == epoch, tab.terminalID == terminalID, !Task.isCancelled {
                let bytes = tab.pendingInput.removeFirst(); tab.pendingInputBytes -= bytes.count
                do { try await shell.send(bytes) }
                catch {
                    if tab.epoch == epoch, tab.shell === shell, !Task.isCancelled {
                        tab.pendingInput.removeAll(); tab.pendingInputBytes = 0
                        tab.error = message(for: error)
                    }
                    return
                }
            }
        }
        return true
    }
    public func resizeTerminal(_ tab: SessionTab, rows: Int, columns: Int) {
        let rows = min(200, max(5, rows)), columns = min(400, max(20, columns))
        guard rows != tab.screen.rows || columns != tab.screen.cols else { return }
        tab.screen.resize(rows: rows, cols: columns); tab.screenRevision += 1
        recordings.resize(tab, rows: rows, columns: columns)
        tab.localShell?.resize(rows: rows, columns: columns)
        tab.resizeTask?.cancel()
        if let shell = tab.shell {
            tab.resizeTask = Task {
                do { try await Task.sleep(nanoseconds: 80_000_000); try Task.checkCancellation(); try await shell.resize(rows: rows, columns: columns) } catch {}
            }
        }
    }
    public func execute(_ tab: SessionTab) async {
        guard !tab.busy, let ssh = tab.session, !tab.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let command = tab.command, epoch = tab.epoch
        tab.command = ""; tab.busy = true; tab.error = nil; tab.status = "Running command…"; tab.feed("$ \(command)\n")
        defer { if tab.epoch == epoch { tab.busy = false; tab.status = tab.connected ? "Connected" : "Disconnected" } }
        do {
            let output = try await ssh.runCommand(command, includeStandardError: true)
            if tab.epoch == epoch { tab.feed(output + (output.hasSuffix("\n") ? "" : "\n")) }
        } catch { if tab.epoch == epoch { tab.error = message(for: error) } }
    }
    private func fileSession(_ tab: SessionTab) async throws -> any RemoteFileSystem {
        if let transfer = tab.transfer { return transfer }
        // Panels that ask at the same moment share one SFTP channel instead of each opening their own.
        if let opening = tab.transferOpening { return try await opening.value }
        guard let ssh = tab.session else { throw WorkspaceError.disconnected }
        let epoch = tab.epoch
        let choice = tab.fileProtocol
        let opening = Task { try await ConnectionService.openFiles(ssh, choice: choice) }
        tab.transferOpening = opening
        let transfer: any RemoteFileSystem
        do { transfer = try await opening.value } catch {
            if epoch == tab.epoch { tab.transferOpening = nil }
            throw error
        }
        guard epoch == tab.epoch else { try? await transfer.close(); throw WorkspaceError.disconnected }
        tab.transferOpening = nil
        tab.transfer = transfer; return transfer
    }

    /// The file session of a connected tab: SFTP or SCP over SSH, opened on first use, or the FTP connection.
    /// A file connection that broke is opened again: a new SFTP or SCP channel over SSH, or a new FTP sign-in.
    func sftp(for tab: SessionTab) async throws -> any RemoteFileSystem {
        guard tab.connected, !tab.isLocal else { throw WorkspaceError.disconnected }
        if let security = tab.ftpSecurity {
            if let transfer = tab.transfer, !transfer.isOpen, !tab.busy, let port = Int(tab.port) {
                tab.transfer = nil; tab.connected = false
                await connectFTP(tab, host: tab.host, port: port, security: security)
            }
            guard tab.connected, let transfer = tab.transfer, transfer.isOpen else { throw WorkspaceError.disconnected }
            return transfer
        }
        if let transfer = tab.transfer, !transfer.isOpen { tab.transfer = nil }
        return try await fileSession(tab)
    }

    /// Connected SSH sessions, in the main window and in their own windows.
    var remoteTabs: [SessionTab] {
        (tabs + sessionWindows.values.map(\.tab)).filter { $0.connected && !$0.isLocal && $0.desktop == nil }
    }

    /// The session whose server the file transfer view shows.
    var transferTab: SessionTab? {
        if let id = pinnedTransferTab, let tab = sessionWindows[id]?.tab { return tab.desktop == nil ? tab : nil }
        return selected.flatMap { $0.desktop == nil ? $0 : nil }
    }

    /// Shows the two-pane file transfer view, on `tab` when given. The Mac layout switches its main window over to it;
    /// the Classic and Workbench layouts open it in its own window.
    func openFileTransfer(for tab: SessionTab?) {
        if layout != .native {
            if transferWindow == nil { transferWindow = FileTransferWindow(model: self) }
            transferWindow?.select(tab ?? selected.flatMap { $0.connected && !$0.isLocal ? $0 : nil })
            transferWindow?.showWindow(nil)
            transferWindow?.window?.makeKeyAndOrderFront(nil)
            return
        }
        if let tab, !tabs.contains(where: { $0.id == tab.id }) {
            // A session in its own window: show its server here and bring the main window forward.
            pinnedTransferTab = tab.id
            bringForward()
        } else {
            pinnedTransferTab = nil
            if let tab, tab.id != selection { selectTab(tab.id, focusTerminal: false) }
        }
        workspaceMode = .files
    }

    /// The Default layout shows the session log in the main window; the others open its own window.
    /// `search` narrows the list, for example to one session's name.
    func showConnectionHistory(search: String = "") {
        history.reload()
        history.search = search
        guard layout == .native else { openTool(.connectionHistory); return }
        workspaceMode = .log
        // Opened from Settings or a session's own window, the log is in the window behind it.
        workspaceWindow?.makeKeyAndOrderFront(nil)
    }

    func showTerminal() {
        workspaceMode = .terminal
        pinnedTransferTab = nil
        if let selected, selected.desktop == nil && selected.newConnectionType?.editorTool == nil {
            selected.terminalFocusRequest += 1
        }
    }

    public func refreshFiles(_ tab: SessionTab, navigateTo path: String? = nil) async {
        guard !tab.busy, tab.connected else { return }
        let epoch = tab.epoch
        let requested = path ?? tab.remotePath
        tab.busy = true; tab.error = nil; tab.status = "Reading remote directory…"
        defer { if tab.epoch == epoch { tab.busy = false; tab.status = "Connected" } }
        do {
            let transfer = try await fileSession(tab)
            let directory = try await transfer.readDirectory(requested)
            guard tab.epoch == epoch else { return }
            tab.remotePath = directory.path
            tab.entries = directory.entries
            tab.filesLoaded = true
        } catch {
            if tab.epoch == epoch { tab.error = message(for: error) }
        }
    }
    public func remoteFile(_ name: String, in tab: SessionTab) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw WorkspaceError.invalid("Use a single file name.") }
        return (tab.remotePath as NSString).appendingPathComponent(name)
    }
    public func upload(_ tab: SessionTab, local: URL, overwrite: Bool = false) async {
        let epoch = tab.epoch
        await fileOperation(tab, title: "Uploading…") { transfer in
            let operation = tab.fileOperationID
            let name = local.lastPathComponent
            let path = try self.remoteFile(name, in: tab)
            if !overwrite, try await transfer.listDirectory(tab.remotePath).contains(where: { $0.name == name }) { throw WorkspaceError.alreadyExists(name) }
            try await transfer.upload(localURL: local, to: path) { progress in Task { @MainActor in if tab.busy && tab.epoch == epoch && tab.fileOperationID == operation { tab.progress = progress.fraction } } }
        }
    }
    public func download(_ tab: SessionTab, name: String, local: URL) async {
        let epoch = tab.epoch
        await fileOperation(tab, title: "Downloading…") { transfer in
            let operation = tab.fileOperationID
            let path = try self.remoteFile(name, in: tab)
            let partial = local.deletingLastPathComponent().appendingPathComponent(".gloamux-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            try await transfer.download(remotePath: path, to: partial) { progress in Task { @MainActor in if tab.busy && tab.epoch == epoch && tab.fileOperationID == operation { tab.progress = progress.fraction } } }
            if FileManager.default.fileExists(atPath: local.path) { _ = try FileManager.default.replaceItemAt(local, withItemAt: partial) }
            else { try FileManager.default.moveItem(at: partial, to: local) }
            self.noteHistory(tab, .downloaded, detail: path)
        }
    }
    public func rename(_ tab: SessionTab, from: String, to: String) async {
        await fileOperation(tab, title: "Renaming…") { transfer in
            let destination = try self.remoteFile(to, in: tab)
            if try await transfer.listDirectory(tab.remotePath).contains(where: { $0.name == to }) { throw WorkspaceError.alreadyExists(to) }
            let path = try self.remoteFile(from, in: tab)
            try await transfer.rename(from: path, to: destination)
            self.noteHistory(tab, .renamed, detail: path + " → " + destination)
        }
    }
    public func remove(_ tab: SessionTab, name: String) async {
        await fileOperation(tab, title: "Deleting…") { transfer in
            let path = try self.remoteFile(name, in: tab)
            try await transfer.removeFile(path)
            self.noteHistory(tab, .deleted, detail: path)
        }
    }
    private func fileOperation(_ tab: SessionTab, title: String, _ action: (any RemoteFileSystem) async throws -> Void) async {
        guard !tab.busy, tab.connected else { return }
        let epoch = tab.epoch; tab.fileOperationID = UUID(); tab.busy = true; tab.error = nil; tab.status = title; tab.progress = nil
        do { try await action(fileSession(tab)) }
        catch { if tab.epoch == epoch { tab.error = message(for: error) } }
        guard tab.epoch == epoch else { return }
        tab.fileOperationID = UUID(); tab.busy = false; tab.progress = nil; tab.status = "Connected"
        if tab.error == nil { await refreshFiles(tab) }
    }
    @discardableResult public func openSaved(_ item: SessionTreeNode, inNewWindow: Bool = false) -> SessionTab? {
        if sessionTree.node(item.id) != nil { recents.opened(item.id) }
        if let container = item.container {
            if container.tool.opensDesktop {
                return openDesktop(item, container, inNewWindow: inNewWindow)
            }
            return openContainer(item, container, inNewWindow: inNewWindow)
        }
        guard let settings = item.connection else { return nil }
        let tab = inNewWindow ? SessionTab() : addTab()
        configureSaved(tab, item, settings)
        if inNewWindow {
            let controller = SavedSessionWindow(model: self, tab: tab)
            sessionWindows[tab.id] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        tab.savedConnectionTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab, !Task.isCancelled else { return }
            await self.connect(tab)
            guard !Task.isCancelled else { return }
            if tab.connected {
                // A session saved to open its files (an Xftp profile, say) browses without asking for a terminal.
                if tab.showsFiles {
                    // Copies start before the folder is listed: some gateways allow copying but not listing.
                    if let copies = tab.pendingCopies { tab.pendingCopies = nil; await self.startCopies(copies, via: tab) }
                    await self.refreshFiles(tab)
                    if inNewWindow || tab.signIn != nil || tab.localFolder != nil { self.openFileTransfer(for: tab) } else { self.filesRequest = FilesRequest(tab: tab.id) }
                } else { await self.startTerminal(tab) }
            }
            tab.savedConnectionTask = nil
        }
        return tab
    }

    /// Copies a saved SSH connection's settings into a tab.
    func configureSaved(_ tab: SessionTab, _ item: SessionTreeNode, _ settings: SavedConnection) {
        tab.environment = sessionTree.effectiveEnvironment(item.id)
        tab.opensAutomatically = true
        tab.savedSessionID = item.id
        tab.jumpPath = settings.jumpPath
        tab.title = item.name; tab.host = settings.host; tab.port = String(settings.port); tab.username = settings.username
        tab.encoding = settings.encoding ?? .utf8
        tab.forwardsAgent = settings.forwardsAgent == true
        tab.forwardsX11 = settings.forwardsX11 == true
        tab.useProxy = settings.proxyHost != nil; tab.proxyKind = settings.proxyKind ?? .socks5; tab.proxyHost = settings.proxyHost ?? "127.0.0.1"; tab.proxyPort = String(settings.proxyPort ?? 1080)
        tab.identityPath = settings.identityPath
        tab.useAgent = settings.usesAgent == true
        tab.agentSocket = settings.agentSocket
        tab.confirmsEachConnection = settings.asksEachConnection
        tab.showsFiles = settings.opensFiles == true
        tab.forwardingRules = settings.forwardingRules ?? []
        tab.fileProtocol = settings.fileProtocol
        tab.signIn = settings.signIn
        tab.remoteFolder = settings.remoteFolder; tab.localFolder = settings.localFolder
        if let folder = settings.remoteFolder { tab.remotePath = folder }
        tab.ftpSecurity = settings.ftpSecurity; tab.ftpFingerprint = settings.ftpFingerprint
        if settings.isFTP { tab.showsFiles = true }
    }

    /// A container, pod, or SSM shell: a local terminal that runs `docker`, `kubectl`, or `aws`.
    private func openContainer(_ item: SessionTreeNode, _ container: ContainerSession, inNewWindow: Bool) -> SessionTab {
        let launch = container.tool.runsCommand ? LocalLaunch.command(container.commandLine) : nil
        let tab: SessionTab
        if inNewWindow {
            tab = SessionTab(); tab.isLocal = true; tab.title = item.name; tab.username = NSUserName()
            tab.screen = TerminalPreferences.newScreen(); tab.localLaunch = launch
            tab.container = container; tab.host = container.summary; tab.encoding = container.encoding ?? .utf8
        } else {
            tab = addLocalTab(launch: launch, title: item.name, container: container)
        }
        tab.savedSessionID = item.id
        tab.environment = sessionTree.effectiveEnvironment(item.id)
        if inNewWindow {
            startLocalTerminal(tab)
            let controller = SavedSessionWindow(model: self, tab: tab)
            sessionWindows[tab.id] = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
        return tab
    }

    func openDesktop(_ item: SessionTreeNode, _ profile: ContainerSession, inNewWindow: Bool = false) -> SessionTab {
        let tab = inNewWindow ? SessionTab() : addTab(select: false)
        configureDesktop(tab, item, profile)
        if inNewWindow {
            let controller = SavedSessionWindow(model: self, tab: tab)
            sessionWindows[tab.id] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            workspaceMode = .terminal
            selectTab(tab.id, focusTerminal: false)
        }
        return tab
    }

    func configureDesktop(_ tab: SessionTab, _ item: SessionTreeNode, _ profile: ContainerSession) {
        tab.newConnectionType = nil
        tab.password = ""
        tab.title = item.name
        tab.host = profile.target
        tab.port = String(profile.effectivePort)
        let desktop = RemoteDesktopSession(profile: profile, tab: tab)
        desktop.openTunnel = { [weak self, weak desktop] gateway, host, port in
            guard let self, let desktop else { throw CancellationError() }
            return try await self.openDesktopTunnel(desktop, gateway: gateway, host: host, port: port)
        }
        tab.desktop = desktop
        tab.container = profile
        desktop.historyEvent = { [weak self, weak tab] event, detail in
            guard let self, let tab else { return }
            switch event {
            case .opened: self.beginHistory(tab)
            case .failed, .closed, .lost: self.endHistory(tab, event, detail: detail)
            default: self.noteHistory(tab, event, detail: detail)
            }
        }
        tab.savedSessionID = sessionTree.node(item.id)?.id
        tab.environment = sessionTree.effectiveEnvironment(item.id) ?? item.environment
    }

    public func openSavedFolder(_ id: UUID) throws {
        let items = sessionTree.connections(in: id)
        guard items.count <= 50 else { throw WorkspaceError.invalid("Open at most 50 saved sessions at once. Select a smaller folder.") }
        for item in items { openSaved(item) }
    }
    public func saveConnection(_ tab: SessionTab, name: String, parent: UUID?) throws {
        if let desktop = tab.desktop {
            let profile = desktop.profile
            try profile.validate()
            let id = try sessionTree.add(name: name, parent: parent, container: profile)
            if tab.savedSessionID == nil { tab.savedSessionID = id }
            return
        }
        guard tab.newConnectionType?.editorTool == nil else { throw WorkspaceError.invalid("Use Save in the remote desktop form.") }
        guard let port = Int(tab.port) else { throw WorkspaceError.invalid("Enter a valid port.") }
        var settings = SavedConnection(host: tab.host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, username: tab.username,
            proxyHost: tab.useProxy ? tab.proxyHost : nil, proxyPort: tab.useProxy ? Int(tab.proxyPort) : nil, identityPath: tab.identityPath, opensFiles: tab.showsFiles,
            usesAgent: tab.useAgent, agentSocket: tab.agentSocket, proxyKind: tab.proxyKind,
            confirmsEachConnection: tab.confirmsEachConnection)
        settings.setJumpPath(tab.jumpPath)
        settings.forwardingRules = tab.forwardingRules.isEmpty ? nil : tab.forwardingRules
        settings.forwardsX11 = tab.forwardsX11 ? true : nil
        settings.fileProtocol = tab.fileProtocol
        settings.signIn = tab.signIn
        settings.remoteFolder = tab.remoteFolder; settings.localFolder = tab.localFolder
        try settings.validate()
        let id = try sessionTree.add(name: name, parent: parent, connection: settings)
        if tab.savedSessionID == nil { tab.savedSessionID = id }
    }
    public func importColors(_ url: URL, tab: SessionTab) throws { tab.colorScheme = try Formats.ColorScheme(data: limitedData(url), name: url.deletingPathExtension().lastPathComponent); tab.screenRevision += 1 }
    public func importHighlights(_ url: URL, tab: SessionTab) throws { tab.highlights = try HighlightSet(data: limitedData(url), name: url.deletingPathExtension().lastPathComponent); tab.screenRevision += 1 }
    private func limitedData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw WorkspaceError.invalid("Settings file exceeds 1 MiB.") }; return data
    }
    public func refreshVault() async {
        vaultState = await vault.state
        vaultHasTouchID = await vault.touchIDEnrolled
        savesWithoutUnlock = await vault.savesWithoutUnlock
        vaultEntries = await vault.vaultIdentifiers
    }
    public func configureVault(password: String, create: Bool) async {
        guard !vaultBusy else { return }; vaultBusy = true; error = nil
        do {
            if create { try await vault.create(password: password) } else { try await vault.unlock(password: password) }
            await vault.persistSessionSecrets()
            try await vault.enableTouchIDAfterPasswordUnlock()
        }
        catch { self.error = message(for: error) }
        await refreshVault(); vaultBusy = false
    }
    func unlockVaultWithTouchID() async {
        guard !vaultBusy else { return }
        vaultBusy = true
        error = nil
        do {
            try await vault.unlockWithTouchID(reason: T("Unlock the Gloamux password vault"))
            await vault.persistSessionSecrets()
        }
        catch { self.error = message(for: error) }
        await refreshVault()
        vaultBusy = false
    }
    public func lockVault() async { sessionTree.sessionKeys = [:]; await vault.lock(); await refreshVault() }
    /// Stops using the tab's key: the saved session forgets it, and so does the saved passphrase unless another
    /// saved session still uses the same key. The key file stays.
    func removeKey(from tab: SessionTab) async {
        guard let path = tab.identityPath else { return }
        tab.identityPath = nil
        do {
            if let id = tab.savedSessionID, let node = sessionTree.node(id), var connection = node.connection,
               connection.identityPath == path {
                connection.identityPath = nil
                try sessionTree.updateConnection(id, name: node.name, connection: connection)
            }
            try await forgetSignIn(account: tab.credentialID, keyPath: path)
        } catch {
            tab.error = message(for: error)
        }
    }

    /// Withdraws what let an account connect without typing, after its key is removed: the account's remembered
    /// password is deleted, so the next connection, also from the session tree, needs the password typed again (or
    /// the vault unlocked, if a copy was put there). The key's passphrase goes too unless another saved session
    /// still uses that key.
    func forgetSignIn(account: String, keyPath: String) async throws {
        try await vault.forgetRemembered(id: account)
        if !sessionTree.nodes.contains(where: { $0.connection?.identityPath == keyPath }) {
            try await vault.forgetRemembered(id: Self.passphraseID(keyPath))
        }
        await refreshVault()
    }

    // MARK: Saved sign-ins list

    /// Asks for Touch ID or the Mac password before the saved sign-ins are listed. Returns false when cancelled.
    /// Changing whether a saved session asks on every connection needs the master password when a vault exists
    /// (`verifyMasterPassword`), and Touch ID or the Mac password otherwise.
    func verifyMasterPassword(_ password: String) async -> Bool { await vault.verifyMasterPassword(password) }
    func authorizeAskChange() async -> Bool {
        do { try await confirmOwner(T("change whether this session asks on every connection")); return true }
        catch { return false }
    }

    func authorizeSavedSignIns() async -> Bool {
        do { try await confirmOwner(T("view saved passwords")); return true }
        catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) { return false }
        catch { self.error = "Touch ID or the Mac password is required to view saved passwords."; return false }
    }

    func savedSignIns() async -> [SavedSignIn] {
        let connections = sessionTree.nodes.compactMap { node in node.connection.map { (node.name, $0) } }
        return await vault.savedEntries().map { entry, place in
            if entry.hasPrefix("passphrase:") {
                let path = String(entry.dropFirst("passphrase:".count))
                let names = connections.filter { $0.1.identityPath == path }.map(\.0)
                return SavedSignIn(entry: entry, place: place, isPassphrase: true,
                                   account: URL(fileURLWithPath: path).lastPathComponent, detail: path, sessions: names)
            }
            let names = connections.filter { "\($0.1.username)@\(KnownHosts.endpoint(host: $0.1.host, port: $0.1.port))" == entry }.map(\.0)
            return SavedSignIn(entry: entry, place: place, isPassphrase: false, account: entry, detail: nil, sessions: names)
        }
    }

    func revealSignIn(_ item: SavedSignIn) async throws -> String { try await vault.revealSaved(id: item.entry, in: item.place) }

    func removeSignIn(_ item: SavedSignIn) async throws {
        try await vault.removeSaved(id: item.entry, from: item.place)
        await refreshVault()
    }

    /// Deletes the account's password from the vault and from this launch's memory, so the next connection asks.
    func removeFromVault(_ tab: SessionTab) async {
        let id = tab.credentialID
        do {
            try await vault.removeSaved(id: id, from: .vault)
            await vault.forgetForSession(id: id)
        } catch VaultError.locked {
            tab.error = "Unlock the password vault to delete its entries."
        } catch {
            tab.error = message(for: error)
        }
        await refreshVault()
    }

    /// Puts the account's password in the master-password vault: the one typed in the form, or the one remembered.
    /// It is a copy the user keeps on purpose; signing in remembers passwords on this Mac without it.
    public func savePassword(_ tab: SessionTab) async {
        guard tab.identityPath == nil, !tab.useAgent else { return }
        do {
            let secret = tab.password.isEmpty ? try await vault.password(id: tab.credentialID) : tab.password
            try await vault.addToVault(id: tab.credentialID, secret: secret)
            await refreshVault()
        }
        catch { tab.error = message(for: error) }
    }
}

/// One entry in the saved sign-ins list: an account password or a key passphrase.
struct SavedSignIn: Identifiable, Equatable {
    /// The vault entry ID: `user@[host]:port` or `passphrase:<key path>`.
    let entry: String
    /// Remembered on this Mac, or kept in the master-password vault.
    let place: CredentialVault.Place
    var id: String { (place == .vault ? "vault:" : "mac:") + entry }
    let isPassphrase: Bool
    let account: String
    let detail: String?
    /// Saved sessions that use it.
    let sessions: [String]
}

func message(for error: Error) -> String {
    if let error = error as? VaultError {
        switch error {
        case .locked: return "Enter a connection password or unlock the password vault."
        case .wrongPassword: return "The master password is incorrect."
        case .notFound: return "No password is saved for this account. Enter a connection password."
        case .passwordLength: return "The master password must contain 6–50 characters."
        default: return "The vault could not be read or updated: \(error)"
        }
    }
    if let error = error as? SSHError {
        switch error {
        case .authenticationFailed: return "SSH authentication failed. Check the username and password."
        case .signInCancelled: return "Sign-in was cancelled."
        case .connectFailed(let detail): return "Connection failed: \(detail)"
        case .commandFailed(let detail): return "Command failed: \(detail)"
        case .invalidSettings(let detail): return "Invalid connection settings: \(detail)"
        case .notConnected: return "The session is disconnected."
        }
    }
    return error.localizedDescription
}

/// Asks the window to show the files of a session that has just connected.
struct FilesRequest: Equatable {
    let tab: UUID
    let nonce = UUID()
}
