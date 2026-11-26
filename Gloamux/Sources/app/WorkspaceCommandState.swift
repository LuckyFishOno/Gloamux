import AppKit
import Combine
import SwiftUI
import Terminal

/// What the menu bar's workspace commands show: which items are enabled and the titles that change.
///
/// The commands read this instead of observing the whole workspace. Every change to the workspace would otherwise
/// rebuild the Terminal, View, Edit, File, and Window menus, which costs the main thread a frame or two each time and
/// makes animations elsewhere in the app, such as an explanation popover opening, stutter. The snapshot is worked out
/// again after a change and published only when something the menus show is different.
@MainActor final class WorkspaceCommandState: ObservableObject {
    struct Snapshot: Equatable {
        var hasSelection = false
        var workspaceLocked = false
        // Tab menu
        var canDuplicate = false
        var hasKeySessionWindow = false
        // Split commands
        var canSplit = false
        var maximized = false
        var broadcastInput = false
        var hasSplit = false
        // Terminal menu, for the focused tab
        var terminalReady = false
        var hasShellIntegration = false
        var hasLastCommand = false
        var isDesktop = false
        var agentsEnabled = false
        var recording = false
        var logging = false
        var readOnly = false
        var showsTimestamps = false
        var copyMode = false
        var hasCustomColors = false
        var encoding = TerminalEncoding.utf8

        @MainActor init() {}

        @MainActor init(_ model: WorkspaceModel) {
            let tab = model.selected
            hasSelection = tab != nil
            workspaceLocked = model.workspaceLocked
            canDuplicate = tab.map(model.canDuplicate) == true
            hasKeySessionWindow = model.keySessionWindowTab != nil
            canSplit = model.canSplit(model.selection)
            maximized = model.maximizedPane != nil
            broadcastInput = model.broadcastInput
            hasSplit = model.split != nil
            guard let tab else { return }
            terminalReady = tab.terminalReady
            hasShellIntegration = model.hasShellIntegration(tab)
            hasLastCommand = tab.lastCommand != nil
            isDesktop = tab.desktop != nil
            agentsEnabled = model.agents.enabled
            recording = model.recordings.isRecording(tab)
            logging = model.logs.isLogging(tab)
            readOnly = tab.readOnly
            showsTimestamps = tab.showsTimestamps
            copyMode = tab.copyMode
            hasCustomColors = tab.colorScheme != nil || tab.highlights != nil
            encoding = tab.encoding
        }
    }

    @Published private(set) var snapshot = Snapshot()
    private weak var model: WorkspaceModel?
    private var subscriptions: Set<AnyCancellable> = []
    private var tabSubscription: AnyCancellable?
    private weak var watchedTab: SessionTab?
    private var scheduled = false

    init(model: WorkspaceModel) {
        self.model = model
        snapshot = Snapshot(model)
        // `objectWillChange` comes before the change, so the snapshot is taken on the next turn of the run loop.
        model.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        // The Window menu's "Move window to tab bar" depends on which window is in front.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        watchSelectedTab()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        scheduled = false
        guard let model else { return }
        watchSelectedTab()
        let next = Snapshot(model)
        if next != snapshot { snapshot = next }
    }

    /// The focused tab's own changes (a shell becoming ready, a recording starting) also change the Terminal menu.
    private func watchSelectedTab() {
        let tab = model?.selected
        guard tab !== watchedTab else { return }
        watchedTab = tab
        tabSubscription = tab?.objectWillChange.sink { [weak self] _ in self?.schedule() }
    }
}
