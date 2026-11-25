import AppKit
import SwiftUI

// The Classic and Workbench window arrangements. They follow where familiar Windows terminal apps place their
// toolbars, panels, tabs, and bars, and draw everything with Gloamux's own symbols and workspace theme.

/// The panels behind the Workbench layout's vertical side rail.
enum SideRailPanel: String {
    case sessions, files, commands
}

extension DesktopView {
    /// Classic: icon toolbar, address bar, session manager on the left, boxed tabs, compose bar, and status bar.
    var classicLayout: some View {
        VStack(spacing: 0) {
            ClassicToolbar(model: model, showsTree: $showsTree, showsCompose: $showsCompose, sidebar: sidebar,
                          toggleSidebar: toggleSidebar, newConnectionItems: { newConnectionItems })
            AddressField(model: model, theme: model.theme, prominent: true)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(model.theme.header.color)
            classicRule
            workspaceColumns {
                connectionSidebar.padding(10)
            } center: {
                VStack(spacing: 0) {
                    tabStrip(.boxed)
                    sessionArea
                }
            }
            if showsCompose {
                classicRule
                ComposeBar(model: model, close: { withAnimation(.easeOut(duration: 0.15)) { showsCompose = false } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            errorBanner
            classicRule
            ClassicStatusBar(model: model)
        }
    }

    /// Workbench: large-button ribbon, a vertical rail that switches the left panel between sessions, SFTP,
    /// and macros, numbered rounded tabs, and a host monitoring bar under the terminal.
    var workbenchLayout: some View {
        VStack(spacing: 0) {
            MobaRibbon(model: model, sidebar: sidebar, toggleSidebar: toggleSidebar, showPanel: showRailPanel,
                       newConnectionItems: { newConnectionItems })
            classicRule
            HStack(spacing: 0) {
                SideRail(selection: showsTree ? railPanel : nil, theme: model.theme) { panel in
                    withAnimation(.easeOut(duration: 0.18)) {
                        if showsTree && railPanel == panel { showsTree = false } else { railPanel = panel; showsTree = true }
                    }
                }
                workspaceDivider
                workspaceColumns {
                    railContent
                } center: {
                    VStack(spacing: 0) {
                        tabStrip(.rounded)
                        sessionArea
                        classicRule
                        MonitorBar(model: model)
                    }
                }
            }
            errorBanner
        }
    }

    func showRailPanel(_ panel: SideRailPanel) {
        withAnimation(.easeOut(duration: 0.18)) { railPanel = panel; showsTree = true }
    }

    @ViewBuilder private var railContent: some View {
        switch railPanel {
        case .sessions:
            VStack(alignment: .leading, spacing: 10) {
                AddressField(model: model, theme: model.theme, prominent: false)
                connectionSidebar
            }
            .padding(10)
        case .files:
            if let tab = model.selected {
                SideRailFiles(model: model, tab: tab).padding(10)
            }
        case .commands:
            if let tab = model.selected {
                QuickCommandPanel(model: model, store: model.quickCommands, tab: tab) {
                    withAnimation(.easeOut(duration: 0.18)) { showsTree = false }
                }
                .frame(width: 260)
            }
        }
    }

    private var classicRule: some View {
        Rectangle().fill(model.theme.border?.color ?? model.theme.foreground.color.opacity(0.14)).frame(height: 1)
    }
}

// MARK: - Shared controls

/// A small toolbar icon that lights up under the pointer, like the buttons on a classic Windows toolbar.
private struct ToolIcon: View {
    let symbol: String
    let help: String
    var color: Color = .secondary
    var active = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .appFont(.system(size: 14))
                .foregroundStyle(enabled ? color : Color.secondary.opacity(0.5))
                .frame(width: 28, height: 26)
                .background(Color.primary.opacity(active ? 0.14 : hovering && enabled ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .helpTag(T(help))
    }
}

/// A toolbar icon with a small arrow that opens a menu.
private struct ToolMenu<Items: View>: View {
    let symbol: String
    let help: String
    var color: Color = .secondary
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            HStack(spacing: 2) {
                Image(systemName: symbol).symbolRenderingMode(.hierarchical).appFont(.system(size: 14)).foregroundStyle(color)
                Image(systemName: "chevron.down").appFont(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        // The button menu style with a plain button keeps a custom label intact; the borderless style flattens it.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: 26)
        .padding(.horizontal, 4)
        .helpTag(T(help))
    }
}

private struct ToolSeparator: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 4) }
}

/// The address bar (Classic) and quick connect field (Workbench): `ssh://user@host:port`, `user@host`, or a host.
struct AddressField: View {
    @ObservedObject var model: WorkspaceModel
    let theme: WorkspaceTheme
    let prominent: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: prominent ? "link" : "bolt.horizontal.fill")
                .appFont(.system(size: 11)).foregroundStyle(prominent ? Color.secondary : Color.yellow)
            TextField(T(prominent ? "Host, IP address, or ssh://user@host:port" : "Quick connect…"), text: $text)
                .textFieldStyle(.plain)
                .appFont(.system(size: 12))
                .focused($focused)
                .onSubmit(open)
                .accessibilityIdentifier(prominent ? "addressBar" : "quickConnectField")
            if !text.isEmpty {
                Button(action: open) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
                .help(T("Connect"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: prominent ? 26 : 28)
        .background(theme.background.color.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(focused ? theme.accent.color.opacity(0.8) : theme.foreground.color.opacity(0.14)))
    }

    private func open() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if model.openAddress(text) == nil {
            model.error = "Enter a host, user@host, or ssh://user@host:port."
        } else { text = "" }
    }
}

// MARK: - Classic

private struct ClassicToolbar<NewItems: View>: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var showsTree: Bool
    @Binding var showsCompose: Bool
    let sidebar: WorkspaceSidebar?
    let toggleSidebar: (WorkspaceSidebar) -> Void
    @ViewBuilder let newConnectionItems: () -> NewItems
    @Environment(\.openWindow) private var openWindow
    @State private var forwarding: SessionTab?

    var body: some View {
        let tab = model.selected
        let remote = tab.map { !$0.isLocal } ?? false
        HStack(spacing: 1) {
            ToolMenu(symbol: "plus.rectangle.on.folder", help: "New connection", color: .green) { newConnectionItems() }
            ToolIcon(symbol: "folder", help: showsTree ? "Hide connection tree" : "Show connection tree", color: .yellow, active: showsTree) {
                withAnimation(.easeOut(duration: 0.18)) { showsTree.toggle() }
            }
            ToolSeparator()
            ToolIcon(symbol: "arrow.clockwise.circle", help: "Reconnect", color: .green,
                     enabled: remote && tab?.connected == false && tab?.busy == false && tab?.host.isEmpty == false) {
                if let tab { Task { await model.connect(tab) } }
            }
            ToolIcon(symbol: "stop.circle", help: "Disconnect", color: .red, enabled: remote && (tab?.connected == true || tab?.busy == true)) {
                if let tab { Task { await model.disconnect(tab) } }
            }
            ToolSeparator()
            ToolIcon(symbol: "doc.on.doc", help: "Copy", color: .blue) { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
            ToolIcon(symbol: "doc.on.clipboard", help: "Paste", color: .blue) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
            ToolSeparator()
            // The New File Transfer button opens Gloamux's two-pane transfer window in its own window.
            ToolIcon(symbol: "arrow.up.arrow.down.square", help: "File Transfer", color: .orange) { model.openFileTransfer(for: tab) }
            ToolIcon(symbol: "arrow.left.arrow.right", help: "Port forwarding", color: .purple, enabled: remote) {
                forwarding = tab
            }
            ToolSeparator()
            ToolMenu(symbol: "rectangle.split.2x1", help: "Split", color: .teal) { SplitItems(model: model) }
            ToolIcon(symbol: "dot.radiowaves.left.and.right", help: model.broadcastInput ? "Stop typing into all panes" : "Type into all panes",
                     color: .orange, active: model.broadcastInput, enabled: model.split != nil) { model.toggleBroadcastInput() }
            ToolIcon(symbol: "keyboard", help: showsCompose ? "Hide compose bar" : "Show compose bar", color: .indigo, active: showsCompose) {
                withAnimation(.easeOut(duration: 0.15)) { showsCompose.toggle() }
            }
            ToolSeparator()
            SessionLogIcon(model: model, logs: model.logs)
            ToolIcon(symbol: "clock.arrow.circlepath", help: "Session Log", color: .brown) { model.showConnectionHistory() }
            ToolIcon(symbol: "highlighter", help: "Import highlight set", color: .yellow, enabled: tab.map { $0.desktop == nil } ?? false) {
                model.chooseHighlightSet()
            }
            ToolIcon(symbol: "bolt.badge.clock", help: "Triggers", color: .orange) {
                SettingsWindow.request("triggers")
                openWindow(id: SettingsWindow.id)
            }
            ToolSeparator()
            ToolIcon(symbol: "command", help: "Quick commands", color: .cyan, active: sidebar == .commands) { toggleSidebar(.commands) }
            ToolIcon(symbol: "paintpalette", help: "Color theme", color: .pink, active: sidebar == .themes) { toggleSidebar(.themes) }
            ToolIcon(symbol: "arrow.up.left.and.arrow.down.right", help: "Full screen", color: .secondary) { NSApp.keyWindow?.toggleFullScreen(nil) }
            ToolSeparator()
            ToolIcon(symbol: "lock", help: "Lock workspace", color: .secondary) { model.lockWorkspace() }
            ToolIcon(symbol: "gearshape", help: "Settings", color: .secondary) { openWindow(id: SettingsWindow.id) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(model.theme.header.color)
        .sheet(item: $forwarding) { tab in PortForwardingView(model: model, tab: tab) }
    }
}

/// Starts or stops the selected terminal's session log; lit while it records.
private struct SessionLogIcon: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var logs: TerminalLogs

    var body: some View {
        let tab = model.selected
        let logging = tab.map(logs.isLogging) ?? false
        ToolIcon(symbol: "doc.text", help: logging ? "Stop session log" : "Start session log", color: .brown, active: logging,
                 enabled: tab.map { $0.desktop == nil } ?? false) { model.toggleLogging() }
    }
}

private struct SplitItems: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        Button(T("Split side by side")) { model.splitWorkspace(.sideBySide) }.disabled(!model.canSplit(model.selection))
        Button(T("Split top and bottom")) { model.splitWorkspace(.stacked) }.disabled(!model.canSplit(model.selection))
        Divider()
        Button(T("Close split view")) { model.closeSplit() }.disabled(model.split == nil)
    }
}

/// The Classic layout's compose bar: type a line, then send it to the selected session or to every open session.
private struct ComposeBar: View {
    @ObservedObject var model: WorkspaceModel
    let close: () -> Void
    @AppStorage("composeSendsToAll") private var toAll = false
    @State private var draft = ""
    @State private var flash = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker(T("Send to"), selection: $toAll) {
                    Text(T("Current session")).tag(false)
                    Text(T("All sessions")).tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Label(T(toAll ? "All sessions" : "Current session"), systemImage: toAll ? "rectangle.stack" : "rectangle")
                    .appFont(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(T("Send to"))
            TextField(T("Type text to send, then press Return"), text: $draft)
                .textFieldStyle(.plain)
                .appFont(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit(send)
                .accessibilityIdentifier("composeBar")
            Button(action: send) { Image(systemName: "paperplane.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(draft.isEmpty ? Color.secondary : model.theme.accent.color)
                .disabled(draft.isEmpty)
                .help(T("Send"))
            Button(action: close) { Image(systemName: "xmark").appFont(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(T("Hide compose bar"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(flash ? model.theme.accent.color.opacity(0.12) : model.theme.header.color)
        .animation(.easeOut(duration: 0.25), value: flash)
    }

    private func send() {
        guard !draft.isEmpty else { return }
        if model.sendCompose(draft, toAll: toAll) > 0 {
            draft = ""
            flash = true
            Task { try? await Task.sleep(nanoseconds: 250_000_000); flash = false }
        } else {
            model.error = "Open a terminal before sending text."
        }
        focused = true
    }
}

/// The Classic layout's status bar: address, protocol, terminal type, size, cursor, session count, and Caps Lock.
private struct ClassicStatusBar: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var keys = KeyLockState()

    var body: some View {
        HStack(spacing: 0) {
            if let tab = model.selected { TabStatus(tab: tab) } else { Spacer() }
            StatusCell(text: String(format: T("%d sessions"), model.tabs.count))
            StatusCell(text: "CAP", dim: !keys.capsLock)
        }
        .appFont(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(model.theme.header.color)
    }

    /// The cells that change with output: the cursor position, or the bytes received and sent.
    private struct OutputStatus: View {
        let tab: SessionTab
        @ObservedObject var output: TerminalOutput
        let cursor: Bool
        var body: some View {
            if cursor {
                StatusCell(text: String(format: T("Ln %d, Col %d"), tab.screen.cursorRow + 1, tab.screen.cursorCol + 1))
            } else {
                StatusCell(text: "↓ " + Self.bytes(tab.bytesReceived) + "  ↑ " + Self.bytes(tab.bytesSent))
                    .help(T("Received and sent in this session"))
            }
        }
        private static func bytes(_ count: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
        }
    }

    private struct TabStatus: View {
        @ObservedObject var tab: SessionTab
        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: tab.isLocal ? "terminal" : tab.connected ? "lock.fill" : "lock.open")
                    .appFont(.system(size: 9)).foregroundStyle(tab.connected || tab.isLocal ? Color.green : Color.secondary)
                Text(address).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if tab.connected || tab.isLocal {
                StatusCell(text: tab.isLocal ? T("Local") : "SSH2")
                StatusCell(text: tab.isLocal ? "xterm-256color" : TerminalPreferences.terminalType)
                StatusCell(text: "⇲ \(tab.screen.cols)×\(tab.screen.rows)")
                OutputStatus(tab: tab, output: tab.output, cursor: true)
                if tab.selectedLines > 0 { StatusCell(text: String(format: T("%d lines selected"), tab.selectedLines)) }
                OutputStatus(tab: tab, output: tab.output, cursor: false)
            }
        }
        private var address: String {
            if tab.isLocal { return T("Local shell") + "  \(tab.username)" }
            guard !tab.host.isEmpty else { return T("Not connected.") }
            let endpoint = "ssh://\(tab.account):\(tab.port)"
            return tab.connected ? endpoint : endpoint + "  ·  " + T(tab.status)
        }
    }
}

private struct StatusCell: View {
    let text: String
    var dim = false
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 12).padding(.trailing, 8)
            Text(text).opacity(dim ? 0.35 : 1).lineLimit(1)
        }
        .padding(.leading, 8)
    }
}

// MARK: - Workbench

/// A big ribbon button: icon over a short label.
private struct RibbonButton: View {
    let symbol: String
    let title: String
    let color: Color
    var active = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { RibbonLabel(symbol: symbol, title: title, color: enabled ? color : .secondary, active: active, hovering: hovering && enabled) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(T(title))
    }
}

private struct RibbonLabel: View {
    let symbol: String
    let title: String
    let color: Color
    var active = false
    var hovering = false
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical).appFont(.system(size: 19)).foregroundStyle(color)
                .frame(height: 22)
            Text(T(title)).appFont(.system(size: 10.5)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 7)
        .frame(minWidth: 52, minHeight: 50)
        .background(Color.primary.opacity(active ? 0.13 : hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

private struct RibbonMenu<Items: View>: View {
    let symbol: String
    let title: String
    let color: Color
    @ViewBuilder let items: () -> Items
    var body: some View {
        Menu(content: items) { RibbonLabel(symbol: symbol, title: title, color: color) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(T(title))
    }
}

private struct MobaRibbon<NewItems: View>: View {
    @ObservedObject var model: WorkspaceModel
    let sidebar: WorkspaceSidebar?
    let toggleSidebar: (WorkspaceSidebar) -> Void
    let showPanel: (SideRailPanel) -> Void
    @ViewBuilder let newConnectionItems: () -> NewItems
    @Environment(\.openWindow) private var openWindow
    @State private var showingTunnels = false
    @State private var showingSignIns = false
    @State private var xServerRunning = XQuartz.isRunning

    var body: some View {
        let tab = model.selected
        let remoteConnected = tab.map { !$0.isLocal && $0.connected } ?? false
        HStack(spacing: 2) {
            RibbonMenu(symbol: "display", title: "Session", color: .blue) { newConnectionItems() }
            RibbonButton(symbol: "terminal.fill", title: "Local terminal", color: .green) { model.addLocalTab() }
            RibbonButton(symbol: "folder.fill", title: "SFTP", color: .orange) { showPanel(.files) }
            ToolSeparator().frame(height: 40)
            RibbonMenu(symbol: "rectangle.split.2x2", title: "Split", color: .teal) { SplitItems(model: model) }
            RibbonButton(symbol: "dot.radiowaves.left.and.right", title: "MultiExec", color: .orange, active: model.multiExec) {
                model.toggleMultiExec()
            }
            RibbonButton(symbol: "point.3.connected.trianglepath.dotted", title: "Tunneling", color: .purple) { showingTunnels = true }
            RibbonButton(symbol: "keyboard.fill", title: "Macros", color: .cyan) { showPanel(.commands) }
            RibbonButton(symbol: "x.square.fill", title: "X server", color: .indigo, active: xServerRunning) {
                if let problem = XQuartz.open() { model.error = problem }
            }
            RibbonButton(symbol: "clock.arrow.circlepath", title: "Session Log", color: .brown) { model.showConnectionHistory() }
            RibbonButton(symbol: "key.fill", title: "Saved passwords", color: .yellow) {
                Task { if await model.authorizeSavedSignIns() { showingSignIns = true } }
            }
            ToolSeparator().frame(height: 40)
            RibbonButton(symbol: "paintpalette.fill", title: "Theme", color: .pink, active: sidebar == .themes) { toggleSidebar(.themes) }
            RibbonButton(symbol: "arrow.up.left.and.arrow.down.right", title: "Full screen", color: .secondary) { NSApp.keyWindow?.toggleFullScreen(nil) }
            RibbonButton(symbol: "gearshape.fill", title: "Settings", color: .gray) { openWindow(id: SettingsWindow.id) }
            Spacer(minLength: 0)
            RibbonButton(symbol: "xmark.octagon.fill", title: "Disconnect", color: .red,
                         enabled: tab.map { !$0.isLocal && ($0.connected || $0.busy) } ?? false) {
                if let tab { Task { await model.disconnect(tab) } }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(model.theme.header.color)
        .sheet(isPresented: $showingTunnels) { TunnelManagerView(model: model) }
        .sheet(isPresented: $showingSignIns) { SavedSignInsView(model: model) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            xServerRunning = XQuartz.isRunning
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            xServerRunning = XQuartz.isRunning
        }
    }
}

/// XQuartz, the X server that X11 forwarding displays on.
public enum XQuartz {
    static let bundleIDs = ["org.xquartz.X11", "org.macosforge.xquartz.X11"]
    public static let missing = "XQuartz is not installed. Get it from xquartz.org to show remote X11 programs on this Mac."

    public static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier.map(bundleIDs.contains) == true }
    }

    public static var installedURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Starts XQuartz, or brings it forward when it runs. Returns a message key when it is not installed.
    @MainActor static func open() -> String? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier.map(bundleIDs.contains) == true }) {
            running.activate()
            return nil
        }
        guard let url = installedURL else { return missing }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }

    /// For `gloamux xserver start`: waits until XQuartz has launched, so the command can exit right after.
    public static func start() async throws {
        if isRunning { return }
        guard let url = installedURL else { throw WorkspaceError.invalid(missing) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

/// The Workbench layout's vertical tab strip: rotated labels that pick the left panel. Clicking the open one hides it.
private struct SideRail: View {
    let selection: SideRailPanel?
    let theme: WorkspaceTheme
    let select: (SideRailPanel) -> Void

    var body: some View {
        VStack(spacing: 2) {
            item(.sessions, symbol: "star.fill", title: "Sessions", color: .yellow)
            item(.files, symbol: "folder.fill", title: "SFTP", color: .orange)
            item(.commands, symbol: "keyboard.fill", title: "Macros", color: .cyan)
            Spacer()
        }
        .padding(.top, 6)
        .frame(width: 28)
        .background(theme.header.color)
    }

    private func item(_ panel: SideRailPanel, symbol: String, title: String, color: Color) -> some View {
        let label = T(title)
        let length = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        let selected = selection == panel
        return Button { select(panel) } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).appFont(.system(size: 11)).foregroundStyle(color)
                Text(label).appFont(.system(size: 11, weight: selected ? .semibold : .regular)).fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 16, height: length)
            }
            .padding(.vertical, 8)
            .frame(width: 26)
            .background(selected ? theme.sidebar.color : Color.clear, in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5))
            .overlay(alignment: .leading) { if selected { Rectangle().fill(theme.accent.color).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The SFTP panel for the selected SSH tab, with "Follow terminal folder".
private struct SideRailFiles: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @State private var followed: String?
    @State private var hooked: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.orange)
                Text(tab.isLocal || tab.host.isEmpty ? "SFTP" : "SFTP · \(tab.host)").appFont(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if !tab.isLocal && tab.connected {
                    Button { tab.followsFolder.toggle() } label: {
                        Image(systemName: tab.followsFolder ? "location.fill" : "location")
                            .foregroundStyle(tab.followsFolder ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help(T(tab.followsFolder ? "Stop following the terminal folder" : "Follow terminal folder") + "\n" + T("Show the folder the remote shell is in after each command"))
                    .accessibilityLabel(T("Follow terminal folder"))
                    .accessibilityAddTraits(tab.followsFolder ? .isSelected : [])
                    Button { model.openFileTransfer(for: tab) } label: {
                        Label(T("Two-pane"), systemImage: "arrow.left.arrow.right").labelStyle(.titleAndIcon).appFont(.system(size: 11))
                    }
                    .buttonStyle(.app).controlSize(.small)
                    .help(T("Open these files in the two-pane File Transfer view"))
                }
            }
            .accessibilityIdentifier("transferSidebar")
            if !tab.isLocal && tab.connected {
                RemoteFilesPane(model: model, tab: tab, compact: true).id(tab.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.wifi").appFont(.system(size: 26)).foregroundStyle(.secondary)
                    Text(T("Open an SSH tab to browse remote files.")).appFont(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: tab.followsFolder) { _, on in if on { hookIfNeeded(); followed = nil; follow() } }
        .onChange(of: tab.terminalReady) { _, ready in if ready && tab.followsFolder { hookIfNeeded() } }
        .onReceive(tab.output.$revision.dropFirst()) { _ in follow() }
        .onAppear { if tab.followsFolder { hookIfNeeded() }; follow() }
    }

    /// Without a folder report from the shell, installs a prompt hook once per terminal.
    private func hookIfNeeded() {
        guard !tab.isLocal, tab.terminalReady, tab.screen.workingDirectory == nil,
              TerminalFolder.fromTitle(tab.screen.title) == nil, !hooked.contains(tab.terminalID) else { return }
        hooked.insert(tab.terminalID)
        model.reportTerminalFolder(tab)
    }

    private func follow() {
        guard tab.followsFolder, !tab.isLocal, tab.connected, !tab.busy,
              let folder = TerminalFolder.current(screenDirectory: tab.screen.workingDirectory, title: tab.screen.title),
              folder != followed else { return }
        followed = folder
        Task { await model.refreshFiles(tab, navigateTo: folder) }
    }
}

/// The Workbench layout's remote monitoring bar: CPU, memory, network, uptime, users, and disk for the selected host.
private struct MonitorBar: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var monitor = HostMonitor()

    var body: some View {
        Group {
            if let tab = model.selected { MonitorContent(tab: tab, monitor: monitor, theme: model.theme) }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(model.theme.header.color)
        .onDisappear { monitor.stop() }
    }

    private struct MonitorContent: View {
        @ObservedObject var tab: SessionTab
        @ObservedObject var monitor: HostMonitor
        let theme: WorkspaceTheme

        var body: some View {
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: tab.isLocal ? "laptopcomputer" : "server.rack").foregroundStyle(theme.accent.color)
                    Text(tab.isLocal ? T("This Mac") : tab.host.isEmpty ? T("Not connected.") : tab.host).fontWeight(.medium)
                }
                if let stats = monitor.stats, !stats.isEmpty {
                    metric("cpu", .green, stats.cpu.map { String(format: "%.0f%%", $0) })
                    metric("memorychip", .blue, stats.memoryUsed.flatMap { used in
                        stats.memoryTotal.map { "\(HostStats.bytes(Double(used))) / \(HostStats.bytes(Double($0)))" }
                    })
                    metric("arrow.up", .orange, stats.sendRate.map { HostStats.bytes($0) + "/s" })
                    metric("arrow.down", .teal, stats.receiveRate.map { HostStats.bytes($0) + "/s" })
                    metric("clock", .purple, stats.uptime.map(HostStats.duration))
                    metric("person.2", .pink, stats.users.map(String.init))
                    metric("internaldrive", .yellow, stats.diskUsed.flatMap { used in
                        stats.diskSize.map { $0 > 0 ? "/ " + String(format: "%.0f%%", Double(used) / Double($0) * 100) : "/" }
                    })
                } else if monitor.unavailable {
                    Text(T("Monitoring needs a Linux server")).foregroundStyle(.secondary)
                } else if tab.connected || tab.isLocal {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(T("Connect to see host usage")).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .appFont(.system(size: 11).monospacedDigit())
            .padding(.horizontal, 10)
            .task(id: "\(tab.id)-\(tab.connected)") { monitor.watch(tab) }
        }

        @ViewBuilder private func metric(_ symbol: String, _ color: Color, _ value: String?) -> some View {
            if let value {
                HStack(spacing: 4) {
                    Image(systemName: symbol).appFont(.system(size: 10)).foregroundStyle(color)
                    Text(value)
                }
            }
        }
    }
}
