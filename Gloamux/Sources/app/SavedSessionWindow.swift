import AppKit
import SwiftUI

@MainActor final class SavedSessionWindow: NSWindowController, NSWindowDelegate {
    let tab: SessionTab
    private weak var model: WorkspaceModel?
    /// Set when the session moves back to the tab bar, so closing this window leaves it connected.
    var keepsSession = false
    init(model: WorkspaceModel, tab: SessionTab) {
        self.model = model; self.tab = tab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = (tab.environment.map { "[\($0.shortTitle)] " } ?? "") + tab.title
        window.minSize = NSSize(width: 880, height: 580)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SavedSessionContent(model: model, tab: tab))
        super.init(window: window)
        window.delegate = self
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        let button = NSHostingView(rootView: MoveToTabsButton { [weak self] in
            guard let self, let model = self.model else { return }
            model.moveWindowToTabs(self.tab)
        })
        button.frame = NSRect(x: 0, y: 0, width: 34, height: 28)
        accessory.view = button
        window.addTitlebarAccessoryViewController(accessory)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Saved session windows require a workspace.") }
    func windowWillClose(_ notification: Notification) {
        guard let model, !keepsSession else { return }
        // Cancel before yielding so an unstarted auto-connect cannot reopen this session.
        tab.savedConnectionTask?.cancel()
        model.sessionWindows.removeValue(forKey: tab.id)
        Task { await model.disconnect(tab) }
    }
}

/// The titlebar button that puts this session back in the main window's tab bar.
private struct MoveToTabsButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "macwindow.badge.plus") }
            .buttonStyle(.borderless)
            .help(T("Move window to tab bar"))
            .padding(.trailing, 8)
    }
}

private struct SavedSessionContent: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    var body: some View {
        SessionPane(model: model, tab: tab, transferButton: true)
            .overlay { WorkspaceLockCover(model: model) }
            .background(model.theme.background.color)
            .foregroundStyle(model.theme.foreground.color)
            .tint(model.theme.accent.color)
            .background(ThemeTitlebar(theme: model.theme))
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
            .task { await model.refreshVault() }
    }
}
