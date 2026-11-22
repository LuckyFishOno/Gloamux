import AppKit
import Foundation
import SwiftUI

/// Startup commands, reopening last session's tabs, and locking the workspace.
extension WorkspaceModel {
    // MARK: Startup commands

    /// Types a saved session's startup commands once into each new shell, one line at a time.
    func runStartupCommands(_ tab: SessionTab) {
        guard let id = tab.savedSessionID, tab.startupTerminal != tab.terminalID,
              let text = sessionTree.node(id)?.connection?.startupCommands else { return }
        tab.startupTerminal = tab.terminalID
        for line in Self.startupLines(text) { enqueueTerminalInput(tab, bytes: Array(line.utf8) + [0x0D]) }
    }

    /// Non-empty lines, at most 20, each at most 1,024 characters.
    static func startupLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(20)
            .map { String($0.prefix(1024)) }
    }

    // MARK: Reopening tabs

    struct OpenTabs: Codable, Equatable {
        enum Entry: Codable, Equatable { case saved(UUID), local }
        var entries: [Entry]
        var selected: Int?
    }

    static let restoreTabsKey = "Gloamux.workspace.reopenTabs"
    private var openTabsURL: URL { storage.appendingPathComponent("open-tabs.json") }

    /// Saved sessions and plain local terminals, in tab order. Containers and unsaved connections are left out.
    func currentOpenTabs() -> OpenTabs {
        var entries: [OpenTabs.Entry] = []
        var selected: Int?
        for tab in tabs {
            if let id = tab.savedSessionID, sessionTree.node(id) != nil { entries.append(.saved(id)) }
            else if tab.isLocal, tab.container == nil, tab.localLaunch?.arguments.contains("-c") != true { entries.append(.local) }
            else { continue }
            if tab.id == selection { selected = entries.count - 1 }
        }
        return OpenTabs(entries: entries, selected: selected)
    }

    func saveOpenTabs() {
        guard restoresWorkspaceTabs, UserDefaults.standard.bool(forKey: Self.restoreTabsKey) else { return }
        if let data = try? JSONEncoder().encode(currentOpenTabs()) { try? writePrivate(data, to: openTabsURL) }
    }

    /// At launch: last session's tabs when that is turned on, otherwise one local terminal. Each saved session
    /// connects on its own, so one that fails leaves the others open.
    public func openInitialTabs() {
        tabs.removeAll()
        if restoresWorkspaceTabs, UserDefaults.standard.bool(forKey: Self.restoreTabsKey), let data = try? Data(contentsOf: openTabsURL),
           let saved = try? JSONDecoder().decode(OpenTabs.self, from: data) {
            var opened: [SessionTab] = []
            for entry in saved.entries.prefix(50) {
                switch entry {
                case .saved(let id):
                    if let node = sessionTree.node(id), !node.isFolder, let tab = openSaved(node) { opened.append(tab) }
                case .local:
                    opened.append(addLocalTab(select: false))
                }
            }
            if let index = saved.selected, opened.indices.contains(index) { selectTab(opened[index].id) }
            else if let first = opened.first { selectTab(first.id) }
        }
        if tabs.isEmpty { addLocalTab() }
        if restoresWorkspaceTabs {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveOpenTabs() }
            }
        }
        startIdleLock()
    }

    // MARK: Lock

    static let lockIdleKey = "Gloamux.workspace.lockAfterMinutes"

    /// Covers every terminal and ignores typing until the owner unlocks with Touch ID or the Mac password.
    func lockWorkspace() {
        guard !workspaceLocked else { return }
        workspaceLocked = true
        for window in NSApp?.windows ?? [] where window.isVisible { window.makeFirstResponder(nil) }
    }

    func unlockWorkspace() async {
        guard workspaceLocked else { return }
        do {
            try await confirmOwner(T("unlock the Gloamux workspace"))
            workspaceLocked = false
            lastActivity = Date()
            selected?.terminalFocusRequest += 1
        } catch {}
    }

    /// Locks after the set number of minutes without a key press or mouse use in Gloamux.
    func startIdleLock() {
        idleMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.lastActivity = Date() }
            return event
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.workspaceLocked else { return }
                let minutes = UserDefaults.standard.integer(forKey: Self.lockIdleKey)
                if minutes > 0, Date().timeIntervalSince(self.lastActivity) >= Double(minutes) * 60 { self.lockWorkspace() }
            }
        }
    }

    func stopWorkspaceObservers() {
        if let idleMonitor { NSEvent.removeMonitor(idleMonitor) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        idleMonitor = nil
        terminationObserver = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }
}

/// What a locked workspace shows in place of its terminals.
struct WorkspaceLockCover: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        if model.workspaceLocked {
            ZStack {
                Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(T("Gloamux is locked")).font(.title3.weight(.semibold))
                    Button(T("Unlock")) { Task { await model.unlockWorkspace() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {}
            .transition(.opacity)
            .accessibilityIdentifier("workspaceLock")
        }
    }
}
