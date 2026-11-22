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
if arguments.first.map({ ManagementCommands.operations[$0] != nil || ["help", "--help", "-h", "--version"].contains($0) }) == true {
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
            WorkspaceWindow(store: store, applicationDelegate: applicationDelegate)
        }
            .defaultSize(width: 1320, height: 840)
            .windowToolbarStyle(.unified(showsTitle: false))
            .commands {
                // Always present, so the app menu has exactly one Settings item from launch on.
                CommandGroup(replacing: .appSettings) { SettingsCommand(store: store) }
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
            if let workspace = store.workspace { MenuBarPanel(model: workspace) }
            else { ProgressView().padding().task { await store.load() } }
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)
        // A plain window rather than a `Settings` scene: the system would add its own untranslated Settings… item.
        Window("Settings", id: SettingsWindow.id) {
            if let workspace = store.workspace { PreferencesView(model: workspace) }
            else { ProgressView("Opening workspace").padding().task { await store.load() } }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@MainActor final class GloamuxApplicationDelegate: NSObject, NSApplicationDelegate {
    var newWindow: (() -> Void)?

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
            else if let failure = store.failure { ContentUnavailableView("Workspace could not be opened", systemImage: "exclamationmark.triangle", description: Text(failure)).frame(width: 600, height: 300) }
            else { ProgressView("Opening workspace").frame(width: 600, height: 300) }
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
            if arguments.contains("--show-preferences") { openWindow(id: SettingsWindow.id) }
            if arguments.contains("--show-command-palette") { store.workspace?.showCommandPalette() }
            if let index = arguments.firstIndex(of: "--preview-theme"), index + 1 < arguments.count, let model = store.workspace {
                model.beginThemePreview()
                do { try model.focusThemePreview(arguments[index + 1]) } catch { model.error = error.localizedDescription }
            }
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
