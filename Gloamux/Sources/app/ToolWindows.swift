import AppKit
import SwiftUI

/// Windows for tools that sit beside the terminals: recordings, runbooks, host discovery, host key history, and connection history.
enum ToolWindowKind: String, CaseIterable {
    case recordings, runbooks, discovery, hostKeyHistory, connectionHistory, containers, rdp, vnc, desktopEditor

    var title: String {
        switch self {
        case .recordings: return "Recordings"
        case .runbooks: return "Runbooks"
        case .discovery: return "Discover hosts"
        case .hostKeyHistory: return "Host keys"
        case .connectionHistory: return "Connection history"
        case .containers: return "Other session"
        case .rdp, .vnc, .desktopEditor: return "Remote desktop"
        }
    }

    var size: NSSize {
        switch self {
        case .recordings: return NSSize(width: 980, height: 640)
        case .runbooks: return NSSize(width: 860, height: 720)
        case .discovery: return NSSize(width: 820, height: 600)
        case .hostKeyHistory: return NSSize(width: 760, height: 480)
        case .connectionHistory: return NSSize(width: 940, height: 600)
        case .containers: return NSSize(width: 560, height: 430)
        case .rdp, .vnc, .desktopEditor: return NSSize(width: 480, height: 330)
        }
    }
}

@MainActor final class ToolWindow: NSWindowController, NSWindowDelegate {
    let kind: ToolWindowKind
    private weak var model: WorkspaceModel?

    init(model: WorkspaceModel, kind: ToolWindowKind, content: AnyView) {
        self.kind = kind; self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: kind.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = T(kind.title)
        window.contentMinSize = NSSize(width: min(460, kind.size.width), height: min(320, kind.size.height))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ToolWindowContent(model: model, content: content).appTextSize())
        let name = "GloamuxTool-" + kind.rawValue
        if !window.setFrameUsingName(name) { window.center() }
        if [.rdp, .vnc, .desktopEditor].contains(kind) { window.setContentSize(kind.size) }
        window.setFrameAutosaveName(name)
    }
    required init?(coder: NSCoder) { fatalError("Tool windows require a workspace.") }

    func windowWillClose(_ notification: Notification) {
        model?.toolWindows.removeValue(forKey: kind)
    }
}

private struct ToolWindowContent: View {
    @ObservedObject var model: WorkspaceModel
    let content: AnyView
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.theme.background.color)
            .foregroundStyle(model.theme.foreground.color)
            .tint(model.theme.accent.color)
            .background(ThemeTitlebar(theme: model.theme))
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
    }
}

extension WorkspaceModel {
    func openTool(_ kind: ToolWindowKind, parent: UUID? = nil) {
        if let existing = toolWindows[kind] {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        let content: AnyView
        switch kind {
        case .recordings: content = AnyView(RecordingsView(model: self, store: recordings))
        case .runbooks: content = AnyView(RunbooksView(model: self, library: runbooks))
        case .discovery: content = AnyView(HostDiscoveryView(model: self))
        case .hostKeyHistory: content = AnyView(HostKeyHistoryView(model: self))
        case .connectionHistory: content = AnyView(ConnectionHistoryView(model: self, history: history))
        case .containers, .rdp, .vnc, .desktopEditor:
            let tool: ContainerSession.Tool = kind == .containers ? .docker : kind == .vnc ? .vnc : .rdp
            let destination = kind == .containers ? sessionTree.destination : parent
            content = AnyView(ContainerSessionEditor(model: self, editing: nil, tool: tool, parent: destination) { [weak self] in
                self?.toolWindows[kind]?.close()
            })
        }
        let window = ToolWindow(model: self, kind: kind, content: content)
        toolWindows[kind] = window
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
    }

    func showRecordings() { openTool(.recordings) }
    func showConnectionHistory() { history.reload(); openTool(.connectionHistory) }
    func showRunbooks() { openTool(.runbooks) }
    public func showCommandPalette() { commandPaletteShown = true }
}
