import SwiftUI
import AppKit

/// The main window's scene ID, for the menu bar and Spotlight to bring it back after it was closed.
public enum WorkspaceWindowID {
    public static let main = "workspace"
}

/// One operation in the ⌘⇧P command palette.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var detail: String? = nil
    let symbol: String
    var section: String
    var shortcut: String? = nil
    let run: @MainActor () -> Void
}

enum PaletteSearch {
    /// How well `query` matches `text`: a prefix beats a word start, which beats a substring, which beats the
    /// letters in order. Nil when the letters are not all there in order.
    static func score(_ query: String, in text: String) -> Int? {
        let q = query.lowercased(), t = text.lowercased()
        guard !q.isEmpty else { return 0 }
        if t.hasPrefix(q) { return 1000 - t.count }
        if let range = t.range(of: q) {
            let start = range.lowerBound
            let wordStart = start == t.startIndex || !t[t.index(before: start)].isLetter
            return (wordStart ? 800 : 600) - t.count
        }
        var index = t.startIndex, gaps = 0, last: String.Index?
        for character in q where !character.isWhitespace {
            guard let found = t[index...].firstIndex(of: character) else { return nil }
            if let last, t.index(after: last) != found { gaps += 1 }
            last = found; index = t.index(after: found)
        }
        return max(1, 400 - gaps * 20 - t.count)
    }

    /// Commands matching every word of the query, best first; in their original order for an empty query.
    static func filter(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return commands }
        let scored: [(Int, Int, PaletteCommand)] = commands.enumerated().compactMap { offset, command in
            var total = 0
            for word in words {
                let best = [command.title, command.detail ?? "", command.section].compactMap { score(word, in: $0) }.max()
                guard let best else { return nil }
                total += best
            }
            return (total, offset, command)
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
    }
}

extension WorkspaceModel {
    /// Every operation the palette offers. `extra` adds the window's own commands, such as its side panels.
    func paletteCommands(openWindow: OpenWindowAction?, extra: [PaletteCommand] = []) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        let saved = sessionTree.nodes.filter { !$0.isFolder }
        let indexed = Dictionary(uniqueKeysWithValues: sessionTree.nodes.map { ($0.id, $0) })
        func folder(of node: SessionTreeNode) -> String {
            var names: [String] = [], current = node.parent
            while let parent = current.flatMap({ indexed[$0] }) { names.append(parent.name); current = parent.parent }
            return names.reversed().joined(separator: " / ")
        }
        func session(_ node: SessionTreeNode, section: String) -> PaletteCommand {
            let address = node.connection.map { "\($0.accountPrefix)\($0.host)" + ($0.port == 22 ? "" : ":\($0.port)") }
                ?? node.container.map { $0.tool.title + " " + $0.summary } ?? ""
            let place = folder(of: node)
            let environment = sessionTree.effectiveEnvironment(node.id).map { " · " + T($0.title) } ?? ""
            return PaletteCommand(id: section + node.id.uuidString, title: node.name,
                                  detail: (place.isEmpty ? address : address + " · " + place) + environment,
                                  symbol: node.container?.tool.symbol ?? "server.rack", section: section) { [weak self] in
                self?.openSaved(node)
            }
        }
        let recent = recents.ids.compactMap { id in saved.first { $0.id == id } }
        commands += recent.prefix(8).map { session($0, section: T("Recent")) }

        for tab in tabs {
            let title = UIStrings.text(tab.title, language: language)
            commands.append(PaletteCommand(id: "tab" + tab.id.uuidString, title: title,
                                           detail: tab.isLocal ? (tab.container?.summary ?? tab.screen.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }) : tab.host, symbol: tab.isLocal ? "terminal" : "network",
                                           section: T("Open tabs")) { [weak self] in self?.selectTab(tab.id) })
        }

        func add(_ id: String, _ title: String, _ symbol: String, _ section: String, shortcut: String? = nil, detail: String? = nil,
                 _ run: @escaping @MainActor () -> Void) {
            commands.append(PaletteCommand(id: id, title: T(title), detail: detail, symbol: symbol, section: T(section), shortcut: shortcut, run: run))
        }
        add("new.connection", "New connection", "network", "Session", shortcut: "⇧⌘N") { [weak self] in self?.newConnectionTab() }
        add("new.local", "Local terminal", "terminal", "Session", shortcut: "⌘T") { [weak self] in self?.addLocalTab() }
        add("new.rdp", ContainerSession.Tool.rdp.title, "desktopcomputer", "Session") { [weak self] in self?.newConnectionTab(.rdp, remember: true) }
        add("new.vnc", ContainerSession.Tool.vnc.title, "rectangle.on.rectangle", "Session") { [weak self] in self?.newConnectionTab(.vnc, remember: true) }
        add("new.other", "Other connection", "shippingbox", "Session") { [weak self] in self?.newConnectionTab(.other, remember: true) }
        add("agents.share", "Share with Agents", "sparkles", "Terminal") { [weak self] in
            guard let self, let tab = self.selected, tab.desktop == nil else { return }
            self.shareWithAgents(tab, selection: WorkspaceModel.terminalSelection())
        }
        add("discover", "Discover hosts…", "dot.radiowaves.left.and.right", "Session") { [weak self] in self?.openTool(.discovery) }
        if let tab = selected {
            if tab.connected || tab.busy {
                add("disconnect", "Disconnect and close this session", "xmark.circle", "Session") { [weak self] in
                    Task { await self?.disconnectAndClose(tab) }
                }
            } else if !tab.isLocal {
                add("connect", "Connect", "bolt.horizontal", "Session") { [weak self] in Task { await self?.connect(tab) } }
            }
        }

        if canSplit(selection) {
            add("split.side", "Split side by side", "rectangle.split.2x1", "Panes", shortcut: "⌘D") { [weak self] in self?.splitWorkspace(.sideBySide) }
            add("split.stacked", "Split top and bottom", "rectangle.split.1x2", "Panes", shortcut: "⇧⌘D") { [weak self] in self?.splitWorkspace(.stacked) }
        }
        if split != nil {
            add("split.close", "Close split view", "rectangle", "Panes") { [weak self] in self?.closeSplit() }
            add("split.broadcast", broadcastInput ? "Stop typing into all panes" : "Type into all panes", "dot.radiowaves.left.and.right",
                "Panes", shortcut: "⌥⌘I") { [weak self] in self?.toggleBroadcastInput() }
            add("split.maximize", maximizedPane == nil ? "Maximize pane" : "Restore pane", "arrow.up.left.and.arrow.down.right", "Panes",
                shortcut: "⇧⌘↩") { [weak self] in
                guard let self, let id = self.maximizedPane ?? self.selection else { return }
                self.toggleMaximizedPane(id)
            }
        }

        if let tab = selected, tab.terminalReady || recordings.isRecording(tab) {
            if hasShellIntegration(tab) {
                add("prompt.previous", "Previous prompt", "arrow.up.to.line", "Terminal", shortcut: "⌘↑") { [weak self] in self?.navigate(.previousPrompt) }
                add("prompt.next", "Next prompt", "arrow.down.to.line", "Terminal", shortcut: "⌘↓") { [weak self] in self?.navigate(.nextPrompt) }
                if tab.lastCommand != nil {
                    add("prompt.output", "Select output of last command", "text.badge.checkmark", "Terminal", shortcut: "⇧⌘A") { [weak self] in
                        self?.navigate(.selectLastOutput)
                    }
                }
            } else if tab.terminalReady {
                add("integration", "Enable shell integration", "wand.and.stars", "Terminal") { [weak self] in self?.installShellIntegration(tab) }
            }
            add("record", recordings.isRecording(tab) ? "Stop recording" : "Start recording", "record.circle", "Terminal",
                shortcut: "⌥⌘R") { [weak self] in self?.toggleRecording(tab) }
        }
        add("recordings", "Recordings…", "play.rectangle", "Terminal") { [weak self] in self?.showRecordings() }
        add("history", "Session Log", "clock.arrow.circlepath", "Session") { [weak self] in self?.showConnectionHistory() }
        add("sftp.command", "New session from sftp command", "arrow.up.arrow.down.circle", "Session") { [weak self] in self?.showSFTPCommand() }
        add("runbooks", "Runbooks…", "book.pages", "Terminal") { [weak self] in self?.showRunbooks() }
        for file in runbooks.files.prefix(30) {
            add("runbook." + file.lastPathComponent, file.deletingPathExtension().lastPathComponent, "book.pages", "Runbooks") { [weak self] in
                self?.runbooks.selected = file
                self?.showRunbooks()
            }
        }

        add("files", workspaceMode == .files ? "Terminal" : "File transfer", workspaceMode == .files ? "terminal" : "folder", "View") { [weak self] in
            guard let self else { return }
            if self.workspaceMode == .files { self.showTerminal() } else { self.openFileTransfer(for: nil) }
        }
        for layout in WorkspaceLayout.allCases where layout != self.layout {
            commands.append(PaletteCommand(id: "layout." + layout.rawValue, title: T("Layout") + ": " + layout.title,
                                           symbol: layout.symbol, section: T("View")) { [weak self] in
                withAnimation(.easeInOut(duration: 0.2)) {
                    do { try self?.selectLayout(layout) } catch { self?.error = error.localizedDescription }
                }
            })
        }
        for theme in themes where theme.id != themeID {
            commands.append(PaletteCommand(id: "theme." + theme.id, title: T("Color theme") + ": " + theme.title,
                                           symbol: "paintpalette", section: T("View")) { [weak self] in
                do { try self?.selectTheme(theme.id) } catch { self?.error = error.localizedDescription }
            })
        }
        commands += extra

        add("hostkeys", "Host key history", "key.horizontal", "Security") { [weak self] in self?.openTool(.hostKeyHistory) }
        if vaultState == "Unlocked" {
            add("vault.lock", "Lock vault", "lock", "Security") { [weak self] in Task { await self?.lockVault() } }
        }
        if let openWindow {
            add("settings", "Settings…", "gearshape", "Gloamux", shortcut: "⌘,") { openWindow(id: SettingsWindow.id) }
        }

        let seen = Set(recent.map(\.id))
        commands += saved.filter { !seen.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { session($0, section: T("Saved sessions")) }
        return commands
    }
}

/// The ⌘⇧P command palette: type to find a session, a tab, or any workspace operation, then press Return.
struct CommandPalette: View {
    @ObservedObject var model: WorkspaceModel
    let commands: [PaletteCommand]
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [PaletteCommand] {
        var matches = PaletteSearch.filter(commands, query: query)
        // "sftp command" is a search; a pasted command has an account, an option, or a URL.
        if SFTPCommand.looksLike(query), ["@", " -", "://"].contains(where: query.contains) {
            let text = query
            matches.insert(PaletteCommand(id: "sftp.pasted", title: T("New session from sftp command"), symbol: "arrow.up.arrow.down.circle",
                                          section: T("Session")) { [weak model] in model?.showSFTPCommand(text) }, at: 0)
        } else if let direct = SavedConnection.quickTarget(query) {
            let address = "\(direct.username)@\(direct.host)" + (direct.port == 22 ? "" : ":\(direct.port)")
            matches.insert(PaletteCommand(id: "direct", title: String(format: T("Connect directly to %@"), address),
                                          symbol: "arrow.up.right", section: T("Session")) { [weak model] in
                model?.openSaved(SessionTreeNode(name: address, connection: direct))
            }, at: 0)
        }
        return Array(matches.prefix(200))
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("Search sessions and commands, or enter user@host"), text: $query)
                    .textFieldStyle(.plain)
                    .appFont(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .accessibilityIdentifier("commandPaletteField")
            }
            .padding(.horizontal, 14).frame(height: 46)
            Divider()
            if items.isEmpty {
                Text(T("No matches")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(18)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection)
                                    .onTapGesture { selection = index; run(items) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selection) { _, index in
                        if items.indices.contains(index) { scroll.scrollTo(items[index].id) }
                    }
                }
            }
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ item: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(selected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).appFont(.caption).lineLimit(1).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut).appFont(.caption.monospaced()).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            Text(item.section).appFont(.caption).foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.8))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(count - 1, max(0, selection + delta))
    }

    private func run(_ items: [PaletteCommand]) {
        guard items.indices.contains(selection) else { return }
        let command = items[selection]
        close()
        command.run()
    }

    private func close() { model.commandPaletteShown = false }
}

/// Gloamux in the menu bar: find and open a saved session, reopen recent ones, start and stop saved tunnels,
/// and jump to tabs whose commands finished.
public struct MenuBarPanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var tree: SessionTreeStore
    @ObservedObject private var recents: RecentSessions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    public init(model: WorkspaceModel) {
        self.model = model; tree = model.sessionTree; recents = model.recents
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("Find a session or enter user@host"), text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(openFirst)
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                section(T("Results")) {
                    if let direct = SavedConnection.quickTarget(query) {
                        rowButton(String(format: T("Connect directly to %@"), "\(direct.username)@\(direct.host)"), symbol: "arrow.up.right") {
                            open(SessionTreeNode(name: "\(direct.username)@\(direct.host)", connection: direct))
                        }
                    }
                    ForEach(matches.prefix(8)) { node in sessionRow(node) }
                    if matches.isEmpty && SavedConnection.quickTarget(query) == nil {
                        Text(T("No matching sessions")).foregroundStyle(.secondary).appFont(.callout)
                    }
                }
            } else {
                let attention = model.tabs.filter(\.attention)
                if !attention.isEmpty {
                    section(T("Finished commands")) {
                        ForEach(attention) { tab in
                            rowButton(UIStrings.text(tab.title, language: model.language), symbol: "bell.badge",
                                      detail: tab.lastCommand?.command) { show(); model.reveal(tab: tab.id) }
                        }
                    }
                }
                let recent = recents.ids.compactMap { tree.node($0) }.filter { !$0.isFolder }.prefix(6)
                if !recent.isEmpty {
                    section(T("Recent")) { ForEach(Array(recent)) { node in sessionRow(node) } }
                }
                let tunnels = tree.nodes.filter { !($0.connection?.forwardingRules ?? []).isEmpty }
                if !tunnels.isEmpty {
                    section(T("Tunnels")) { ForEach(tunnels) { node in TunnelRow(model: model, node: node) } }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button { show(); model.addLocalTab() } label: { Label(T("Local terminal"), systemImage: "terminal") }
                Spacer()
                Button { show() } label: { Label(T("Open Gloamux"), systemImage: "macwindow") }
                Button { openWindow(id: SettingsWindow.id); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                    .help(T("Settings…"))
            }
            .buttonStyle(.borderless)
            .appFont(.callout)
        }
        .padding(12)
        .frame(width: 340)
    }

    private var matches: [SessionTreeNode] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return tree.nodes.filter { node in
            guard !node.isFolder else { return false }
            let address = node.connection.map { "\($0.accountPrefix)\($0.host):\($0.port)" } ?? node.container?.summary ?? ""
            return words.allSatisfy { word in node.name.localizedStandardContains(word) || address.localizedStandardContains(word) }
        }
    }

    private func openFirst() {
        if let direct = SavedConnection.quickTarget(query) {
            open(SessionTreeNode(name: "\(direct.username)@\(direct.host)", connection: direct))
        } else if let first = matches.first { open(first) }
    }

    private func open(_ node: SessionTreeNode) {
        show()
        model.openSaved(node)
        query = ""
    }

    private func show() {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix(WorkspaceWindowID.main) == true }) {
            openWindow(id: WorkspaceWindowID.main)
        }
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    private func sessionRow(_ node: SessionTreeNode) -> some View {
        let detail = node.connection.map { "\($0.accountPrefix)\($0.host)" } ?? node.container?.summary
        return rowButton(node.name, symbol: node.container?.tool.symbol ?? "server.rack", detail: detail,
                         environment: tree.effectiveEnvironment(node.id)) { open(node) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            content()
        }
    }

    private func rowButton(_ title: String, symbol: String, detail: String? = nil, environment: SessionEnvironment? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                if let environment { EnvironmentBadge(environment: environment) }
                Spacer(minLength: 6)
                if let detail { Text(detail).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

/// A saved session with forwarding rules: whether its tunnels are up, and a button to start or stop them.
private struct TunnelRow: View {
    @ObservedObject var model: WorkspaceModel
    let node: SessionTreeNode

    var body: some View {
        let tab = (model.tabs + model.sessionWindows.values.map(\.tab)).first { $0.savedSessionID == node.id && ($0.connected || $0.busy) }
        let rules = node.connection?.forwardingRules ?? []
        HStack(spacing: 8) {
            Circle().fill(color(tab)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                Text(rules.map { $0.address() }.joined(separator: ", ")).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let tab, !tab.forwardingErrors.isEmpty {
                    Text(tab.forwardingErrors.joined(separator: "; ")).appFont(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let tab {
                if tab.busy { ProgressView().controlSize(.mini) }
                Text("\(tab.forwards.count)/\(rules.count)").appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(T("Forwards running"))
                Button(T("Stop")) { Task { await model.disconnectAndClose(tab) } }.controlSize(.small)
            } else {
                Button(T("Start")) { model.openSaved(node) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
    }

    private func color(_ tab: SessionTab?) -> Color {
        guard let tab else { return Color.secondary.opacity(0.4) }
        if tab.busy { return .orange }
        let rules = node.connection?.forwardingRules?.count ?? 0
        return tab.forwards.count >= rules && tab.forwardingErrors.isEmpty ? .green : .orange
    }
}

public enum MenuBarSettings {
    public static let key = "Gloamux.menuBarExtra"
}
