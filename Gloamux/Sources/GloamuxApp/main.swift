import Foundation
import SwiftUI
import AppKit
import App
import CoreSpotlight
import ShellIntents

let arguments = Array(CommandLine.arguments.dropFirst())
// Data saved under the old name moves over before anything opens the default workspace.
if !arguments.contains("--workspace") { LegacyName.migrate() }
if arguments.first == "benchmark" { exit(TerminalBenchmark.run(arguments)) }
if arguments.first.map({ CLICatalog.command($0) != nil || ["help", "--help", "-h", "--version"].contains($0) }) == true {
    exit(await ProductCLI.run(arguments))
}
if arguments.contains("--theme-flow-trace") { ThemeFlowProbe.start() }
if arguments.contains("--verify-ssh") { SSHProbe.start(arguments) }
if FeatureCheckCommand.handles(arguments) { exit(FeatureCheckCommand.run(arguments)) }
// `gloam` is a short name for the same command.
if ["gloamux", "gloam"].contains(URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent) {
    exit(await ProductCLI.run(arguments))
}
GloamuxApplication.main()

struct GloamuxApplication: SwiftUI.App {
    @NSApplicationDelegateAdaptor(GloamuxApplicationDelegate.self) private var applicationDelegate
    @StateObject private var store = ApplicationWorkspace()
    @AppStorage(MenuBarSettings.key) private var showsMenuBarExtra = true
    /// Shortcuts finds the app's actions through this provider; naming it keeps it from being stripped.
    private let shortcuts = GloamuxShortcuts.self
    var body: some Scene {
        WindowGroup("Gloamux", id: WorkspaceWindowID.main) {
            WorkspaceWindow(store: store, applicationDelegate: applicationDelegate).appTextSize()
        }
            .defaultSize(width: 1320, height: 840)
            .windowToolbarStyle(.unified(showsTitle: false))
            .commands {
                // Always present, so the app menu has exactly one Settings item from launch on.
                CommandGroup(replacing: .appSettings) { SettingsCommand(store: store) }
                CommandGroup(after: .appInfo) { CheckForUpdatesCommand() }
                CommandGroup(replacing: .newItem) { NewWorkspaceWindowCommand() }
                if let workspace = store.workspace {
                    WorkspaceSplitCommands(model: workspace)
                    TerminalCommands(model: workspace)
                }
            }
            .handlesExternalEvents(matching: ["*"])
        // The menu bar item reports its visibility back on every update; writing an unchanged value to UserDefaults would
        // redraw every view that reads a setting, which updates the item again, without end.
        MenuBarExtra(isInserted: Binding(get: { showsMenuBarExtra },
                                         set: { if $0 != showsMenuBarExtra { showsMenuBarExtra = $0 } })) {
            if let workspace = store.workspace { MenuBarPanel(model: workspace).appTextSize() }
            else { ProgressView().padding().task { await store.load() } }
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)
        // A plain window rather than a `Settings` scene: the system would add its own untranslated Settings… item.
        Window(UIStrings.text("Settings"), id: SettingsWindow.id) {
            if let workspace = store.workspace { PreferencesView(model: workspace).appTextSize() }
            else { ProgressView(UIStrings.text("Opening workspace")).padding().task { await store.load() } }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Settings opens from the app menu with Command-comma; it is not a document window for the Window menu.
        .commandsRemoved()
    }
}

@MainActor final class GloamuxApplicationDelegate: NSObject, NSApplicationDelegate {
    var newWindow: (() -> Void)?
    /// The open workspace windows, once the workspace has loaded.
    var workspaces: (() -> [WorkspaceModel])?
    private var quitting = false
    private var repliedToQuit = false
    /// Counts Quit requests, so the work of one that was cancelled cannot finish a later one.
    private var quitRound = 0

    /// Quitting ends every connection the way closing its tab does: each SSH server is told the session is over, so it
    /// ends the login at once instead of finding it dropped. Open tabs are saved first, so they still reopen at launch.
    /// The app quits when that is done, or after five seconds with a server that does not answer, once every recording
    /// is written.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second Quit while connections are closing waits for the first.
        guard !quitting else { return .terminateCancel }
        let models = workspaces?() ?? []
        // The system quits an app it thinks Siri opened once the intent is done; the open window stays.
        if QuitRequest.refusesCurrentEvent(workspaceIsOpen: !models.isEmpty) { return .terminateCancel }
        guard !models.isEmpty else { return .terminateNow }
        quitting = true
        quitRound += 1
        let round = quitRound
        Task { @MainActor in
            for model in models { await model.closeWorkspaceWindow(lockingVault: true) }
            await finishQuitting(sender, models, round: round)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            await finishQuitting(sender, models, round: round)
        }
        return .terminateLater
    }

    /// Quits once every recording is written. A recording that could not be written is not dropped without asking.
    private func finishQuitting(_ sender: NSApplication, _ models: [WorkspaceModel], round: Int) async {
        guard round == quitRound, !repliedToQuit else { return }
        repliedToQuit = true
        var saved = true
        for model in models {
            if await !model.finishRecordingsBeforeQuit() { saved = false }
        }
        if !saved {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = UIStrings.text("Recording not saved")
            alert.informativeText = UIStrings.text("Couldn’t save the recording. Gloamux keeps it until you try again or discard it.")
            alert.addButton(withTitle: UIStrings.text("Don’t Quit"))
            alert.addButton(withTitle: UIStrings.text("Quit Anyway"))
            if alert.runModal() == .alertFirstButtonReturn {
                quitting = false
                repliedToQuit = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
        }
        sender.reply(toApplicationShouldTerminate: true)
    }

    /// Gloamux draws its own tab bar. The system's window tabs would add a second set of tab commands to the View and
    /// Window menus (Show Tab Bar, Merge All Windows) that do something different from the app's.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Starts Sparkle in a packaged app, after the command-line paths above have already exited.
    func applicationDidFinishLaunching(_ notification: Notification) {
        SparkleUpdates.start()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: UIStrings.text("New Window"),
                              action: #selector(openWorkspaceWindow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openWorkspaceWindow() { newWindow?() }
}

private struct NewWorkspaceWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(UIStrings.text("New Window")) { openWindow(id: WorkspaceWindowID.main) }
            .keyboardShortcut("n", modifiers: .command)
    }
}

struct SettingsCommand: View {
    @ObservedObject var store: ApplicationWorkspace
    var body: some View { PreferencesMenuLink(model: store.workspace) }
}

@MainActor final class ApplicationWorkspace: ObservableObject {
    @Published var failure: String?
    @Published var workspace: WorkspaceModel?
    private var primary: WorkspaceModel?
    private var commandChannel: WorkspaceCommandChannel?
    private var loading: Task<Void, Never>?
    private var windows: [ObjectIdentifier: WorkspaceModel] = [:]
    /// Workspace windows in the order they opened, for tab IDs from `gloamux tabs`.
    private var windowOrder: [ObjectIdentifier] = []
    var openWindows: [WorkspaceModel] { windowOrder.compactMap { windows[$0] } }
    private var openedPrimary = false
    private var closing = 0
    /// Links and Spotlight results that arrived before the workspace finished loading.
    var pendingURLs: [URL] = []
    var pendingActivities: [NSUserActivity] = []

    func open(_ url: URL) {
        if let workspace { workspace.open(url: url) } else { pendingURLs.append(url) }
    }

    func continueActivity(_ activity: NSUserActivity) {
        if let workspace { workspace.continueActivity(activity) } else { pendingActivities.append(activity) }
    }

    func load() async {
        if let loading {
            await loading.value
            return
        }
        guard primary == nil, failure == nil else { return }
        let task = Task { await loadWorkspace() }
        loading = task
        await task.value
    }

    private func loadWorkspace() async {
        defer { loading = nil }
        do {
            let storage: URL
            if let index = arguments.firstIndex(of: "--workspace"), index + 1 < arguments.count {
                storage = URL(fileURLWithPath: arguments[index + 1])
            } else {
                storage = WorkspaceModel.defaultStorage
            }
            let channel = try WorkspaceCommandChannel(workspace: storage)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while try !channel.claim() {
                guard clock.now < deadline else {
                    throw WorkspaceError.invalid("This workspace is already open or being updated by gloamux.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let model = try WorkspaceModel(storage: storage)
            try channel.serve(activeWorkspace: { [weak self] in self?.workspace },
                              windows: { [weak self] in self?.openWindows ?? [] })
            commandChannel = channel
            primary = model
            workspace = model
            model.startSystemIntegration { [weak self] in self?.workspace }
            model.openInitialTabs()
            for url in pendingURLs { model.open(url: url) }
            for activity in pendingActivities { model.continueActivity(activity) }
            pendingURLs = []
            pendingActivities = []
            if let index = arguments.firstIndex(of: "--theme"), index + 1 < arguments.count {
                do { try model.selectTheme(arguments[index + 1]) }
                catch { failure = error.localizedDescription; model.error = error.localizedDescription }
            }
        } catch {
            failure = error.localizedDescription
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func attach(_ window: NSWindow) -> WorkspaceModel? {
        let id = ObjectIdentifier(window)
        if let model = windows[id] { return model }
        guard let primary else { return nil }
        do {
            let model: WorkspaceModel
            if openedPrimary {
                model = try WorkspaceModel(sharing: workspace ?? primary)
                model.openInitialTabs()
            } else {
                model = primary
                openedPrimary = true
            }
            model.workspaceWindow = window
            windows[id] = model
            windowOrder.append(id)
            if window.isKeyWindow { workspace = model }
            return model
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    func focus(_ window: NSWindow) {
        if let model = windows[ObjectIdentifier(window)] { workspace = model }
    }

    func close(_ window: NSWindow) {
        windowOrder.removeAll { $0 == ObjectIdentifier(window) }
        guard let model = windows.removeValue(forKey: ObjectIdentifier(window)) else {
            if windows.isEmpty { NSApp.terminate(nil) }
            return
        }
        if workspace === model { workspace = windows.values.first }
        closing += 1
        Task {
            await model.closeWorkspaceWindow(lockingVault: windows.isEmpty)
            closing -= 1
            if windows.isEmpty, closing == 0 { NSApp.terminate(nil) }
        }
    }
}

struct WorkspaceWindow: View {
    @ObservedObject var store: ApplicationWorkspace
    let applicationDelegate: GloamuxApplicationDelegate
    @State private var workspace: WorkspaceModel?
    @State private var window: NSWindow?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if let workspace { DesktopView(model: workspace) }
            else if let failure = store.failure {
                ContentUnavailableView(UIStrings.text("Workspace could not be opened"), systemImage: "exclamationmark.triangle",
                                       description: Text(UIStrings.text(failure))).frame(width: 600, height: 300)
            } else { ProgressView(UIStrings.text("Opening workspace")).frame(width: 600, height: 300) }
        }
        .background(WorkspaceWindowAttachment { attached in
            guard window !== attached else { return }
            window = attached
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window, notification.object as? NSWindow === window {
                store.focus(window)
                applicationDelegate.newWindow = { openWindow(id: WorkspaceWindowID.main) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window, notification.object as? NSWindow === window else { return }
            store.close(window)
            self.window = nil
            workspace = nil
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { store.open($0) }
        .onContinueUserActivity(CSSearchableItemActionType) { store.continueActivity($0) }
        .task(id: window) {
            guard let attached = window else { return }
            await store.load()
            guard !Task.isCancelled, window === attached else { return }
            workspace = store.attach(attached)
            applicationDelegate.newWindow = { openWindow(id: WorkspaceWindowID.main) }
            applicationDelegate.workspaces = { [weak store] in store?.openWindows ?? [] }
            if arguments.contains("--show-preferences") { openWindow(id: SettingsWindow.id) }
            if arguments.contains("--show-command-palette") { store.workspace?.showCommandPalette() }
            if let index = arguments.firstIndex(of: "--preview-theme"), index + 1 < arguments.count, let model = store.workspace {
                model.beginThemePreview()
                do { try model.focusThemePreview(arguments[index + 1]) } catch { model.error = error.localizedDescription }
            }
            PopoverProbe.scheduleIfRequested(touch: { store.workspace?.objectWillChange.send() },
                                            changes: { store.workspace?.objectWillChange.map { _ in () }.eraseToAnyPublisher() })
            SmokeCapture.scheduleIfRequested {
                guard let model = store.workspace else { return [:] }
                return ["savedTheme": model.themeID, "displayedTheme": model.displayedThemeID, "previewOpen": model.themePreview != nil,
                        "localTerminalReady": model.selected?.terminalReady ?? false, "language": model.language.rawValue]
            }
        }
    }
}

private struct WorkspaceWindowAttachment: NSViewRepresentable {
    let attached: (NSWindow) -> Void

    func makeNSView(context: Context) -> View {
        let view = View()
        view.attached = attached
        return view
    }

    func updateNSView(_ view: View, context: Context) { view.attached = attached }

    final class View: NSView {
        var attached: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                if let window, self?.window === window { self?.attached?(window) }
            }
        }
    }
}
