import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FileTransfer
import Ssh

public struct DesktopView: View {
    @StateObject var model: WorkspaceModel
    @State var masterPassword = ""
    @State var vaultExpanded = false
    @State var showingSignIns = false
    @AppStorage("showsConnectionTree") var showsTree = true
    @AppStorage("showsComposeBar") var showsCompose = true
    @AppStorage(TerminalPreferences.newTabLocalKey) var newTabOpensLocal = false
    @AppStorage("sideRailPanel") var railPanel = SideRailPanel.sessions
    /// The Mac layout's remote file tree on the right, which follows the focused pane.
    @AppStorage("showsRemoteFilesSidebar") var showsFilesSidebar = true
    @State var sidebar: WorkspaceSidebar?
    @State var importRequest: FolderImportRequest?
    @State var stripTargeted = false
    @State var splitRatios: [String: CGFloat] = [:]
    @Environment(\.openWindow) private var openWindow
    public init(model: WorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            switch model.layout {
            case .native: nativeLayout
            case .terminal: classicLayout
            case .transfer: workbenchLayout
            }
        }
        .background(WorkspaceToolbarHost(state: toolbarState) { workspaceToolbar }.equatable())
        // ThemeTitlebar paints the toolbar in the theme's header color without taking its clicks. A SwiftUI
        // toolbar background would cover the title bar and catch its double-clicks, so the window would no longer fill
        // the screen or zoom as System Settings says. The content background stops below the toolbar for the same reason.
        .frame(minWidth: model.layout == .transfer ? 1110 : 1040, minHeight: 700)
        .background(model.theme.background.color, ignoresSafeAreaEdges: [])
        .foregroundStyle(model.theme.foreground.color)
        .tint(model.theme.accent.color)
        .background(ThemeTitlebar(theme: model.theme))
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .sheet(item: $importRequest) { request in
            ProfileImportView(store: model.sessionTree, source: request.url, parent: request.parent, kind: request.source)
        }
        .overlay(alignment: .top) {
            if model.commandPaletteShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { model.commandPaletteShown = false }
                    CommandPalette(model: model, commands: model.paletteCommands(openWindow: openWindow, extra: paletteExtras))
                        .padding(.top, 60)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                UnsavedRecordingBanner(recordings: model.recordings) { model.recordingSaved = $0 }
                recordingBanner
            }
        }
        .overlay { WorkspaceLockCover(model: model) }
        .sheet(item: $model.sftpCommandRequest) { SFTPCommandSheet(model: model, text: $0.text).tint(model.theme.accent.color) }
        .animation(.easeOut(duration: 0.15), value: model.workspaceLocked)
        .animation(.easeOut(duration: 0.12), value: model.commandPaletteShown)
        .task {
            await model.refreshVault()
            // A locked vault is the first thing to open after launch: show its unlock field.
            if model.vaultState == "Locked" { vaultExpanded = true }
        }
        .onChange(of: model.filesRequest) { _, request in
            guard let request, let tab = model.tabs.first(where: { $0.id == request.tab }) else { return }
            switch model.layout {
            case .native: setFilesSidebar(true)
            case .terminal: model.openFileTransfer(for: tab)
            case .transfer: withAnimation(.easeOut(duration: 0.18)) { railPanel = .files; showsTree = true }
            }
        }
    }

    /// The Mac layout: connection tree, flat tabs over floating panes, and optional right-hand panels.
    private var nativeLayout: some View {
        VStack(spacing: 0) {
            workspaceColumns {
                connectionSidebar.padding(13)
            } center: {
                VStack(spacing: 0) {
                    tabStrip()
                    sessionArea
                }
            }
            errorBanner
        }
    }

    /// The saved-connection tree with the password vault under it.
    var connectionSidebar: some View {
        VStack(alignment: .leading, spacing: 13) {
            SessionTreeView(store: model.sessionTree, model: model, importFrom: chooseImport)
            Divider().opacity(0.5)
            vaultSection
            if model.savesWithoutUnlock { savedPasswordsSection }
        }
        .sheet(isPresented: $showingSignIns) { SavedSignInsView(model: model) }
    }

    private var savedPasswordsButton: some View {
        Button {
            Task { if await model.authorizeSavedSignIns() { showingSignIns = true } }
        } label: {
            Label(T("Saved passwords…"), systemImage: "key.viewfinder").lineLimit(1).truncationMode(.tail)
        }
        .help(T("Asks for Touch ID or the Mac password"))
        .accessibilityIdentifier("savedPasswordsButton")
    }

    /// With a Secure Enclave, a password that signs in is remembered on this Mac and connects again without asking.
    private var savedPasswordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                savedPasswordsButton.buttonStyle(.plain).appFont(.system(size: 12))
                InfoButton(T("Passwords that sign in are remembered on this Mac and connect again without asking, also after a restart."))
            }
        }
    }

    private func submitMasterPassword() {
        guard !model.vaultBusy, !masterPassword.isEmpty else { return }
        let password = masterPassword; masterPassword = ""
        Task { await model.configureVault(password: password, create: model.vaultState == "Not configured") }
    }

    private var masterPasswordUnlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Return in the field does what the button does.
            SecureField(T("Master password"), text: $masterPassword)
                .onSubmit(submitMasterPassword)
            Button(T(model.vaultState == "Not configured" ? "Create vault" : "Unlock vault"), action: submitMasterPassword)
                .disabled(model.vaultBusy || masterPassword.isEmpty)
            if model.vaultHasTouchID {
                Button { Task { await model.unlockVaultWithTouchID() } } label: {
                    Label(T("Unlock with Touch ID"), systemImage: "touchid")
                }.disabled(model.vaultBusy)
            }
        }
    }

    /// The master-password vault: copies the user keeps on purpose with **Add to vault**. On a Mac without a Secure
    /// Enclave it is also where passwords that sign in are kept.
    private var vaultSection: some View {
        DisclosureGroup(isExpanded: $vaultExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if model.vaultState != "Unlocked" {
                    masterPasswordUnlock
                } else { Button(T("Lock vault")) { Task { await model.lockVault() } } }
                if !model.savesWithoutUnlock { savedPasswordsButton }
            }
            // Fills the row so the buttons sit at its left edge, under the section title, rather than centered.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                // The name keeps its width; a narrow sidebar shortens the state beside it instead.
                Label(T("Password vault"), systemImage: "lock.shield").lineLimit(1).truncationMode(.tail).layoutPriority(1)
                InfoButton(T(!model.savesWithoutUnlock
                             ? "Unlock once after opening Gloamux. Passwords that sign in are saved here, and every connection fills them in without asking again until you lock the vault or quit."
                             : model.vaultState == "Not configured"
                             ? "Create a vault to keep passwords under a master password. While it is unlocked, connections stop asking for Touch ID one by one."
                             : "Unlock once after opening Gloamux, and connections stop asking for Touch ID one by one. While it is locked, sessions set to ask on every connection ask; the others connect with the password remembered on this Mac."))
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    Text(T(model.vaultState)).lineLimit(1).fixedSize()
                    Image(systemName: Self.vaultStateSymbol(model.vaultState))
                        .help(T(model.vaultState)).accessibilityLabel(T(model.vaultState))
                }
                .foregroundStyle(.secondary)
                // Collapsed and locked: unlock with Touch ID without opening the section.
                if !vaultExpanded, model.vaultState == "Locked", model.vaultHasTouchID {
                    Button { Task { await model.unlockVaultWithTouchID() } } label: {
                        Image(systemName: "touchid").foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.vaultBusy)
                    .help(T("Unlock with Touch ID"))
                    .accessibilityLabel(T("Unlock with Touch ID"))
                }
            }.appFont(.system(size: 12))
        }
    }

    /// The vault state as a symbol, for a sidebar too narrow to spell it out.
    static func vaultStateSymbol(_ state: String) -> String {
        switch state {
        case "Unlocked": return "lock.open"
        case "Locked": return "lock"
        default: return "minus.circle"
        }
    }

    /// In the Mac layout, files, themes, and commands share the same trailing width and resize handle.
    func workspaceColumns<Leading: View, Center: View>(@ViewBuilder leading: () -> Leading,
                                                         @ViewBuilder center: () -> Center) -> some View {
        let trailing = model.layout == .native ? TrailingSidebarSizing.resizable :
            .fixed(sidebar == .themes ? 236 : 260)
        return WorkspaceSidebarLayout(showsLeading: showsTree, trailing: showsTrailingSidebar ? trailing : nil,
                                      sidebarColor: model.theme.sidebar.color,
                                      dividerColor: model.theme.border?.color ?? model.theme.foreground.color.opacity(0.16),
                                      leadingContent: leading(), centerContent: center(), trailingContent: trailingSidebarContent)
    }

    private var showsTrailingSidebar: Bool {
        switch sidebar {
        case .themes: return true
        case .commands: return model.selected != nil
        case .collapsed: return false
        case nil: return filesSidebarOpen
        }
    }

    private var canShowFilesSidebar: Bool {
        // Choosing RDP or VNC in the form keeps the panel available until a remote desktop opens.
        model.layout == .native && model.workspaceMode == .terminal && model.selected?.desktop == nil
    }

    private var filesSidebarOpen: Bool {
        canShowFilesSidebar && sidebar == nil && showsFilesSidebar
    }

    @ViewBuilder private var trailingSidebarContent: some View {
        switch sidebar {
        case .themes:
            themeSidebar
        case .commands:
            if let tab = model.selected {
                QuickCommandPanel(model: model, store: model.quickCommands, tab: tab) { setSidebar(.collapsed) }
            }
        case .collapsed:
            EmptyView()
        case nil:
            RemoteFileSidebar(model: model) { setFilesSidebar(false) }
        }
    }

    /// The window's own palette commands: its side panels.
    private var paletteExtras: [PaletteCommand] {
        var extras = [
            PaletteCommand(id: "view.tree", title: T(showsTree ? "Hide connection tree" : "Show connection tree"), symbol: "sidebar.left",
                           section: T("View"), shortcut: "⌃⌘S") { withAnimation(.easeOut(duration: 0.18)) { showsTree.toggle() } },
            PaletteCommand(id: "view.commands", title: T("Quick commands"), symbol: "command", section: T("View")) { toggleSidebar(.commands) },
            PaletteCommand(id: "view.themes", title: T("Color theme"), symbol: "paintpalette", section: T("View")) { toggleSidebar(.themes) },
            PaletteCommand(id: "import.ssh", title: T("Import sessions") + ": " + T(FolderImportRequest.Source.openSSHConfig.menuTitle),
                           symbol: "square.and.arrow.down", section: T("Session")) { chooseImport(.openSSHConfig) },
            PaletteCommand(id: "settings.export", title: T("Export all settings"), symbol: "square.and.arrow.up",
                           section: T("Settings")) { model.exportConfiguration() },
            PaletteCommand(id: "settings.import", title: T("Import all settings"), symbol: "square.and.arrow.down.on.square",
                           section: T("Settings")) { model.importConfiguration() },
        ]
        if canShowFilesSidebar {
            extras.append(PaletteCommand(id: "view.files", title: T("Show or hide the focused pane's files on the right"), symbol: "folder",
                                         section: T("View")) {
                setFilesSidebar(!filesSidebarOpen)
            })
        }
        return extras
    }

    /// Shown for a few seconds after a recording is saved.
    @ViewBuilder private var recordingBanner: some View {
        if let url = model.recordingSaved {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(T("Recording saved")).fontWeight(.medium)
                Text(url.deletingPathExtension().lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button(T("Show")) { model.recordingSaved = nil; model.showRecordings() }
                Button { model.recordingSaved = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .appFont(.callout)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: url) {
                try? await Task.sleep(for: .seconds(6))
                if model.recordingSaved == url { withAnimation { model.recordingSaved = nil } }
            }
        }
    }

    @ViewBuilder var errorBanner: some View {
        if let error = model.error {
            HStack { Image(systemName: "exclamationmark.triangle"); Text(T(error)); Spacer(); Button(T("Dismiss")) { model.error = nil } }
                .foregroundStyle(.red).padding(10)
        }
    }

    func toggleSidebar(_ panel: WorkspaceSidebar) {
        setSidebar(sidebar == panel ? .collapsed : panel)
    }

    private func setSidebar(_ panel: WorkspaceSidebar) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { sidebar = panel }
    }

    private func setFilesSidebar(_ open: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            showsFilesSidebar = open
            sidebar = nil
        }
    }

    /// Tab bar entries in tab order. A split group is one entry, placed where its first pane's tab was.
    var stripItems: [StripItem] {
        var seen = Set<Int>()
        return model.tabs.compactMap { tab in
            guard let index = model.groups.firstIndex(where: { $0.contains(tab.id) }) else { return .tab(tab) }
            return seen.insert(index).inserted ? .group(model.groups[index]) : nil
        }
    }

    func tabStrip(_ chrome: TabChrome = .flat) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let items = stripItems
                let addWidth: CGFloat = 40
                // Tabs share the bar evenly and shrink down to an icon instead of scrolling out of view.
                let width = max(StripTab.minimumWidth, min(StripTab.maximumWidth, (proxy.size.width - addWidth) / CGFloat(max(items.count, 1))))
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        stripTab(item, width: width, chrome: chrome, number: index + 1)
                            .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                    Button { model.newTab() } label: {
                        Image(systemName: "plus").appFont(.system(size: 12, weight: .medium)).frame(width: 28, height: min(28, chrome.height)).contentShape(Rectangle())
                    }
                    .buttonStyle(StripPlusStyle())
                    .help(T(newTabOpensLocal ? "New local terminal" : "New connection"))
                    .frame(width: addWidth)
                    Spacer(minLength: 0)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: items.map(\.id))
            }
            .frame(height: chrome.height)
            .padding(.top, chrome == .flat ? 0 : 4)
            .padding(.horizontal, chrome == .flat ? 0 : 4)
            .background(model.theme.tabs.color)
            .overlay {
                if stripTargeted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(model.theme.accent.color, lineWidth: 2)
                        .background(model.theme.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .padding(2).allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: stripTargeted)
            // Dropping a pane on the tab bar takes it out of its split and makes it a tab again.
            .onDrop(of: [.plainText], isTargeted: Binding(get: { stripTargeted }, set: { targeted in
                stripTargeted = targeted && model.group(containing: PaneDrag.current) != nil
            })) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, let id = PaneDrag.tabID(from: text) else { return }
                    DispatchQueue.main.async {
                        PaneDrag.current = nil
                        model.detachPane(id)
                    }
                }
                return true
            }
            Rectangle().fill(model.theme.foreground.color.opacity(0.08)).frame(height: 1)
        }
    }

    @ViewBuilder private func stripTab(_ item: StripItem, width: CGFloat, chrome: TabChrome, number: Int) -> some View {
        switch item {
        case .tab(let tab):
            TabObserver(tab: tab) { tab in
                StripTab(title: chrome.title(UIStrings.text(tab.title, language: model.language), number: number), chrome: chrome,
                         symbol: tab.container?.tool.symbol ?? (tab.isLocal ? "terminal" : "network"),
                         connected: tab.connected, width: width, selected: tab.id == model.selection, theme: model.theme,
                         environment: tab.environment, attention: tab.attention, bell: tab.bellPending,
                         activity: tab.outputPending, lost: tab.transportLost,
                         select: { model.selectTab(tab.id) },
                         close: { model.requestClose(tab) })
            }
            .onDrag { PaneDrag.provider(for: tab.id) }
            .contextMenu {
                Button(T("Rename tab…")) { model.renameTab(tab) }
                Button(T("Duplicate tab")) { model.duplicateTab(tab) }.disabled(!model.canDuplicate(tab))
                Button(T("Move tab to new window")) { model.moveTabToWindow(tab) }
                Toggle(T("Read-only"), isOn: Binding(get: { tab.readOnly }, set: { _ in model.toggleReadOnly(tab) }))
                Divider()
                Button(T("Move tab left")) { model.moveTab(tab.id, by: -1) }
                Button(T("Move tab right")) { model.moveTab(tab.id, by: 1) }
                Divider()
                Button(T("Close")) { model.requestClose(tab) }
            }
            .help(T("Drag onto a pane to split it"))
        case .group(let layout):
            let members = layout.tabIDs.compactMap { id in model.tabs.first { $0.id == id } }
            // Like Termius, a split is a "Workspace"; further splits are numbered. The tooltip lists its panes.
            let workspaceNumber = (model.groups.firstIndex(of: layout) ?? 0) + 1
            StripTab(title: chrome.title(T("Workspace") + (workspaceNumber > 1 ? " \(workspaceNumber)" : ""), number: number), chrome: chrome,
                     detail: members.map { UIStrings.text($0.title, language: model.language) }.joined(separator: "\n"),
                     symbol: "rectangle.split.2x1", connected: members.contains(where: \.connected), width: width,
                     selected: layout.contains(model.selection), theme: model.theme,
                     select: { if !layout.contains(model.selection), let first = layout.tabIDs.first { model.selectTab(first) } },
                     close: { Task { for tab in members { await model.closeTab(tab) } } })
        }
    }

    /// Everything `workspaceToolbar` reads, so it is rebuilt only when one of these changes.
    private var toolbarState: WorkspaceToolbarState {
        WorkspaceToolbarState(showsTree: showsTree, selection: model.selected?.id, layout: model.layout, mode: model.workspaceMode,
                              themeID: model.displayedThemeID, language: model.language, filesSidebarOpen: filesSidebarOpen,
                              canShowFilesSidebar: canShowFilesSidebar, sidebar: sidebar)
    }

    /// Native window toolbar. The Default layout keeps its actions here; the Classic and Workbench layouts
    /// draw their own toolbars in the window, so only the sidebar button and the layout menu stay.
    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { withAnimation(.easeOut(duration: 0.18)) { showsTree.toggle() } } label: {
                Label(T(showsTree ? "Hide connection tree" : "Show connection tree"), systemImage: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help(T(showsTree ? "Hide connection tree" : "Show connection tree"))
            .accessibilityIdentifier("connectionTreeToggle")
        }
        // The focused session's environment, so a production session is marked in the window as well as its tab.
        if let tab = model.selected {
            ToolbarItem(placement: .navigation) {
                TabObserver(tab: tab) { tab in
                    if let environment = tab.environment { EnvironmentBadge(environment: environment) }
                }
            }
        }
        if model.layout == .native { ToolbarItem(placement: .principal) { workspaceModePicker } }
        // A flexible space pushes the session actions to the trailing edge, like Finder and Terminal.
        ToolbarItem(placement: .automatic) { Spacer() }
        if model.layout == .native {
            ToolbarItem(placement: .automatic) {
                newConnectionMenu
            }
            ToolbarItem(placement: .automatic) {
                sidebarPicker
            }
        }
        ToolbarItem(placement: .automatic) { layoutMenu }
    }

    private var sidebarPicker: some View {
        HStack(spacing: 5) {
            Toggle(isOn: Binding(get: { filesSidebarOpen }, set: setFilesSidebar)) {
                Label(T("Files"), systemImage: "folder")
            }
            .disabled(!canShowFilesSidebar)
            .help(T("Show or hide the focused pane's files on the right"))
            .accessibilityIdentifier("remoteFilesToggle")
            Toggle(isOn: Binding(get: { sidebar == .commands }, set: { setSidebar($0 ? .commands : .collapsed) })) {
                Label(T("Quick commands"), systemImage: "command")
            }
            .help(T("Quick commands"))
            .accessibilityIdentifier("quickCommandsToggle")
            Toggle(isOn: Binding(get: { sidebar == .themes }, set: { setSidebar($0 ? .themes : .collapsed) })) {
                Label(T("Color theme"), systemImage: "paintpalette")
            }
            .help(T("Color theme"))
            .accessibilityIdentifier("workspaceThemeToggle")
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .padding(.horizontal, 5)
    }

    var workspaceModePicker: some View {
        WorkspaceModeSwitch(mode: model.workspaceMode, theme: model.theme) { mode in
            switch mode {
            case .terminal: model.showTerminal()
            case .files: model.openFileTransfer(for: nil)
            case .log: model.showConnectionHistory()
            }
        }
        .help(T("Switch between file transfer, the terminal, and the session log"))
        .accessibilityIdentifier("workspaceModePicker")
    }

    var newConnectionMenu: some View {
        Menu {
            newConnectionItems
        } label: {
            Label(T("New connection"), systemImage: "plus")
        } primaryAction: { model.newTab() }
        .help(T("New connection"))
        .accessibilityIdentifier("newConnectionMenu")
    }

    @ViewBuilder var newConnectionItems: some View {
        Button { model.newConnectionTab() } label: { Label(T("New connection"), systemImage: "network") }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Button { model.addLocalTab() } label: { Label(T("Local terminal"), systemImage: "terminal") }
            .keyboardShortcut("t", modifiers: .command)
        Button { model.newConnectionTab(.rdp, remember: true) } label: { Label(T(ContainerSession.Tool.rdp.title), systemImage: ContainerSession.Tool.rdp.symbol) }
        if model.layout != .terminal {
            Button { model.newConnectionTab(.vnc, remember: true) } label: { Label(T(ContainerSession.Tool.vnc.title), systemImage: ContainerSession.Tool.vnc.symbol) }
        }
        Button { model.newConnectionTab(.other, remember: true) } label: { Label(T("Other connection"), systemImage: "shippingbox") }
        Button { model.openTool(.discovery) } label: { Label(T("Discover hosts…"), systemImage: "dot.radiowaves.left.and.right") }
        Divider()
        Menu(T("Import sessions")) {
            ForEach(FolderImportRequest.Source.allCases, id: \.self) { source in
                Button(T(source.menuTitle)) { chooseImport(source) }
            }
        }
    }

    /// Switches between the Default, Classic, and Workbench arrangements. The choice applies at once.
    private var layoutMenu: some View {
        Menu {
            Picker(T("Layout"), selection: Binding(get: { model.layout }, set: { layout in
                withAnimation(.easeInOut(duration: 0.2)) {
                    do { try model.selectLayout(layout) } catch { model.error = error.localizedDescription }
                }
            })) {
                ForEach(WorkspaceLayout.allCases) { layout in
                    Label { Text(layout.title); Text(layout.detail) } icon: { Image(systemName: layout.symbol) }.tag(layout)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(T("Layout"), systemImage: model.layout.symbol)
        }
        .help(T("Layout") + ": " + model.layout.title)
        .accessibilityIdentifier("layoutMenu")
    }

    /// Panes float as cards over a slightly darker well. Pane frames change without animation: animating
    /// them would resize and redraw every terminal on each frame.
    var sessionArea: some View {
        ZStack {
            if model.layout == .native && model.workspaceMode == .files {
                FileTransferView(model: model, local: model.localBrowser, queue: model.transfers, target: model.mainTransferTarget)
            } else if model.layout == .native && model.workspaceMode == .log {
                ConnectionHistoryView(model: model, history: model.history)
                    .background(model.theme.background.color)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let split = model.split {
                if let id = model.maximizedPane, let tab = model.tabs.first(where: { $0.id == id }) {
                    pane(tab, card: true)
                } else {
                    paneTree(split.root)
                }
            } else if let tab = model.selected {
                pane(tab, card: false)
            }
        }
        .padding(model.layout == .native ? 5 : 0)
        .background(model.theme.tabs.color)
    }

    private func paneDropTarget(_ target: UUID) -> PaneDropTarget {
        PaneDropTarget(target: target, accent: model.theme.accent.color,
                       accepts: { [model] dragged in model.canSplit(dragged) && model.canSplit(target) }) { dragged, edge in
            model.placeTab(dragged, at: edge, of: target)
        }
    }

    /// Draws a split layout recursively; every divider can be dragged, and a double-click evens it out.
    private func paneTree(_ node: WorkspacePane) -> AnyView {
        switch node {
        case .tab(let id):
            guard let tab = model.tabs.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
            return AnyView(pane(tab, card: true))
        case .split(let axis, let first, let second):
            // Ratios are kept per pair of panes, so moving one divider leaves the others where they were.
            let key = "\(first.tabIDs[0])|\(second.tabIDs[0])"
            let ratio = Binding(get: { splitRatios[key] ?? 0.5 }, set: { splitRatios[key] = $0 })
            return AnyView(PaneSplitView(axis: axis, ratio: ratio, first: paneTree(first), second: paneTree(second),
                                         dividerColor: model.theme.accent.color))
        }
    }

    /// One session as a floating card. In a split, the focused card gets an accent ring and a deeper shadow.
    private func pane(_ tab: SessionTab, card inSplit: Bool) -> some View {
        let focused = inSplit && model.selection == tab.id
        let classic = model.layout != .native
        // Classic and Workbench draw square, edge-to-edge panes; the Default layout floats rounded cards.
        let shape = RoundedRectangle(cornerRadius: classic ? 0 : 10, style: .continuous)
        return SessionPane(model: model, tab: tab, compact: inSplit, dockedFiles: model.layout == .transfer,
                           flat: classic, showsHeader: !classic || inSplit)
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.theme.background.color)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(focused ? model.theme.accent.color.opacity(0.75) : model.theme.foreground.color.opacity(0.08),
                                   lineWidth: focused ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if model.broadcastInput && inSplit {
                    shape.strokeBorder(Color.orange.opacity(0.85), lineWidth: 2).allowsHitTesting(false)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { model.selectTab(tab.id, focusTerminal: false) })
            .modifier(paneDropTarget(tab.id))
    }

    var workspaceDivider: some View {
        Rectangle().fill(model.theme.border?.color ?? model.theme.foreground.color.opacity(0.16)).frame(width: 1)
    }

    var themeSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(T("Color theme"), systemImage: "paintpalette").appFont(.headline)
                Spacer()
                Button { setSidebar(.collapsed) } label: {
                    Image(systemName: "xmark").appFont(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(T("Close theme panel"))
            }
            ThemeGallery(themes: model.themes, selectedID: model.displayedThemeID) { id in
                do { try model.selectTheme(id) }
                catch { model.error = error.localizedDescription }
            }
        }
        .padding(13)
        .background(model.theme.sidebar.color)
    }

    func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // Session files, a folder of them, or an Xshell backup (.xts) from File > Export.
        panel.allowedContentTypes = ["xsh", "xfp", "xts"].compactMap { UTType(filenameExtension: $0) }
        panel.canCreateDirectories = false
        panel.prompt = T("Review profiles")
        if panel.runModal() == .OK, let url = panel.url {
            importRequest = FolderImportRequest(url: url, parent: model.sessionTree.destination)
        }
    }

    /// Asks for the folder or file to import from, then shows what it holds before saving anything.
    func chooseImport(_ source: FolderImportRequest.Source) {
        switch source {
        case .xshellFolder: chooseImportFolder()
        case .openSSHConfig: chooseOpenSSHConfig()
        default:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowedContentTypes = source.fileExtensions.compactMap { UTType(filenameExtension: $0) }
            panel.prompt = T("Review profiles")
            if panel.runModal() == .OK, let url = panel.url {
                importRequest = FolderImportRequest(url: url, parent: model.sessionTree.destination, source: source)
            }
        }
    }

    /// Opens `~/.ssh/config` for review, or asks for another file when it does not exist.
    func chooseOpenSSHConfig() {
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        var url: URL? = FileManager.default.isReadableFile(atPath: standard.path) ? standard : nil
        if url == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.showsHiddenFiles = true
            panel.directoryURL = standard.deletingLastPathComponent()
            panel.prompt = T("Review hosts")
            if panel.runModal() == .OK { url = panel.url }
        }
        if let url {
            importRequest = FolderImportRequest(url: url, parent: model.sessionTree.destination, source: .openSSHConfig)
        }
    }

}

enum WorkspaceSidebar {
    // A collapsed panel overrides the default file sidebar for the current window.
    case commands, themes, collapsed
}

struct FolderImportRequest: Identifiable {
    /// Where saved sessions come from, in menu order. Each is read into the same preview before anything is saved.
    enum Source: CaseIterable {
        case gloamux, xshellFolder, mobaXterm, putty, openSSHConfig, csv

        /// The import menu's item.
        var menuTitle: String {
            switch self {
            case .xshellFolder: return "Xshell config…"
            case .openSSHConfig: return "OpenSSH config…"
            case .mobaXterm: return "MobaXterm config…"
            case .putty: return "PuTTY config…"
            case .csv: return "CSV file…"
            case .gloamux: return "Gloamux config…"
            }
        }

        /// The preview sheet's title.
        var title: String {
            switch self {
            case .xshellFolder: return "Import Xshell config"
            case .openSSHConfig: return "Import OpenSSH config"
            case .mobaXterm: return "Import MobaXterm config"
            case .putty: return "Import PuTTY config"
            case .csv: return "Import CSV file"
            case .gloamux: return "Import Gloamux config"
            }
        }

        var symbol: String { self == .xshellFolder ? "folder.badge.plus" : self == .csv ? "tablecells" : "doc.text" }

        /// File name extensions offered in the open panel.
        var fileExtensions: [String] {
            switch self {
            case .xshellFolder, .openSSHConfig: return []
            case .mobaXterm: return ["mxtsessions", "ini"]
            case .putty: return ["reg"]
            case .csv: return ["csv", "txt", "tsv"]
            case .gloamux: return [SessionsFile.fileExtension] + LegacyName.sessionsExtensions + ["json"]
            }
        }

        func scan(_ url: URL) throws -> ProfileImport {
            switch self {
            case .xshellFolder: return try ProfileImport.scan(url)
            case .openSSHConfig: return try OpenSSHConfigImport.scan(url)
            case .mobaXterm: return try MobaXtermImport.scan(url)
            case .putty: return try PuTTYImport.scan(url)
            case .csv: return try CSVSessionImport.scan(url)
            case .gloamux: return try SessionsFile.scan(url)
            }
        }
    }
    let id = UUID()
    let url: URL
    let parent: UUID?
    var source: Source = .xshellFolder
}

/// Drag payload for a tab chip. The prefix keeps ordinary dragged text from being read as a tab.
enum PaneDrag {
    static let prefix = "gloamux-tab:"
    /// The tab being dragged, so a pane does not offer to split around itself.
    @MainActor static var current: UUID?

    @MainActor static func provider(for id: UUID) -> NSItemProvider {
        current = id
        return NSItemProvider(object: (prefix + id.uuidString) as NSString)
    }

    static func tabID(from text: String) -> UUID? {
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }
}

/// Lets a tab chip be dropped on a pane: near an edge splits toward that edge, the middle replaces the pane.
private struct PaneDropTarget: ViewModifier {
    let target: UUID
    let accent: Color
    /// Whether the tab being dragged may join this pane. Only connected sessions can be split.
    let accepts: (UUID?) -> Bool
    let place: (UUID, PaneDropEdge) -> Void
    @State private var size = CGSize.zero
    @State private var hover: PaneDropEdge?

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear.onAppear { size = proxy.size }.onChange(of: proxy.size) { _, new in size = new }
            })
            .overlay { if let hover { PaneDropHighlight(edge: hover, accent: accent).transition(.opacity) } }
            .animation(.easeOut(duration: 0.12), value: hover)
            .onDrop(of: [.plainText], delegate: PaneDropDelegate(target: target, size: size, hover: $hover, accepts: accepts, place: place))
    }
}

private struct PaneDropDelegate: DropDelegate {
    let target: UUID
    let size: CGSize
    @Binding var hover: PaneDropEdge?
    let accepts: (UUID?) -> Bool
    let place: (UUID, PaneDropEdge) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let dragged = MainActor.assumeIsolated { PaneDrag.current }
        guard dragged != target, MainActor.assumeIsolated({ accepts(dragged) }) else {
            hover = nil
            return DropProposal(operation: .forbidden)
        }
        hover = PaneDropEdge.at(info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { hover = nil }

    func performDrop(info: DropInfo) -> Bool {
        let edge = PaneDropEdge.at(info.location, in: size)
        hover = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = PaneDrag.tabID(from: text) else { return }
            DispatchQueue.main.async { PaneDrag.current = nil; place(id, edge) }
        }
        return true
    }
}

/// Shows where a dropped tab will go: the half of the pane at that edge, or the whole pane.
private struct PaneDropHighlight: View {
    let edge: PaneDropEdge
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let area = region(in: proxy.size)
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(accent, lineWidth: 2))
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
                .animation(.easeOut(duration: 0.12), value: edge)
        }
        .padding(4)
        .allowsHitTesting(false)
    }

    private func region(in size: CGSize) -> CGRect {
        let halfWidth = size.width / 2, halfHeight = size.height / 2
        switch edge {
        case .left: return CGRect(x: 0, y: 0, width: halfWidth, height: size.height)
        case .right: return CGRect(x: halfWidth, y: 0, width: halfWidth, height: size.height)
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: halfHeight)
        case .bottom: return CGRect(x: 0, y: halfHeight, width: size.width, height: halfHeight)
        case .center: return CGRect(origin: .zero, size: size)
        }
    }
}

enum StripItem: Identifiable {
    case tab(SessionTab)
    case group(WorkspaceSplit)
    var id: UUID {
        switch self {
        case .tab(let tab): return tab.id
        case .group(let layout): return layout.tabIDs[0]
        }
    }
}

private struct StripPlusStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A flat tab: the selected tab takes the content background. Narrow tabs drop the title, then the
/// status dot, and finally show only the icon. The close button lights up only under the pointer.
/// How tabs are drawn: flat Mac tabs, Classic boxed tabs, or Workbench rounded, numbered tabs.
enum TabChrome: Equatable {
    case flat, boxed, rounded
    var height: CGFloat { self == .flat ? 34 : 28 }
    func title(_ title: String, number: Int) -> String { self == .rounded ? "\(number). \(title)" : title }
}

struct StripTab: View {
    static let minimumWidth: CGFloat = 38
    static let maximumWidth: CGFloat = 200
    let title: String
    var chrome: TabChrome = .flat
    var detail: String? = nil
    let symbol: String
    let connected: Bool
    let width: CGFloat
    let selected: Bool
    let theme: WorkspaceTheme
    var environment: SessionEnvironment? = nil
    /// A command finished in this tab while it was not shown.
    var attention = false
    /// The bell rang in this tab while it was not shown.
    var bell = false
    /// New output arrived in this tab while it was not shown.
    var activity = false
    /// The connection dropped; the tab stays open with Reconnect.
    var lost = false
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        let wide = width >= 64, showsTitle = width >= 70, showsDot = width >= 110
        // Workbench keeps a close button on every wide tab; the other styles show it under the pointer.
        let fixedClose = chrome == .rounded && showsTitle
        // A tap gesture rather than a Button: a Button keeps the mouse and stops the tab from being dragged.
        HStack(spacing: 6) {
            // The close button takes the icon's place under the pointer, so it costs no width.
            ZStack {
                icon.opacity(hovering && !fixedClose ? 0 : 1)
                if hovering && !fixedClose { closeButton.transition(.opacity) }
            }
            .frame(width: 16, height: 16)
            if showsTitle {
                Text(title).appFont(.system(size: chrome == .flat ? 12 : 11.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if let environment, width >= 130 { EnvironmentBadge(environment: environment, compact: true) }
                if lost {
                    Image(systemName: "bolt.horizontal.circle.fill").appFont(.system(size: 10)).foregroundStyle(.red)
                        .help(T("Connection lost"))
                } else if bell && !attention {
                    Image(systemName: "bell.fill").appFont(.system(size: 9)).foregroundStyle(theme.accent.color).help(T("The bell rang"))
                } else if attention {
                    Circle().fill(theme.accent.color).frame(width: 7, height: 7).help(T("A command finished"))
                } else if activity {
                    Circle().stroke(theme.accent.color, lineWidth: 1.5).frame(width: 7, height: 7).help(T("New output"))
                } else if showsDot && chrome != .rounded {
                    Circle().fill(connected ? Color.green.opacity(0.85) : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                }
                if fixedClose { closeButton }
            }
        }
        .padding(.horizontal, wide ? 8 : 0)
        .frame(width: chrome == .flat ? width : max(width - 2, 30), height: chrome.height, alignment: showsTitle ? .leading : .center)
        .background { tabBackground }
        .overlay(alignment: .top) {
            if let environment { Rectangle().fill(environment.color).frame(height: selected ? 3 : 2) }
            else if selected && chrome != .rounded { Rectangle().fill(theme.accent.color).frame(height: 2) }
        }
        .overlay(alignment: .trailing) {
            if !selected && chrome == .flat { Rectangle().fill(theme.foreground.color.opacity(0.1)).frame(width: 1, height: 16) }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: selected)
        .help(detail ?? title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    @ViewBuilder private var tabBackground: some View {
        switch chrome {
        case .flat:
            if selected { theme.background.color.shadow(color: .black.opacity(0.18), radius: 3, y: -1) }
            else if hovering { Color.primary.opacity(0.05) }
        case .boxed, .rounded:
            let radius: CGFloat = chrome == .boxed ? 3 : 7
            let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
            shape.fill(selected ? theme.background.color : hovering ? theme.header.color.opacity(0.9) : theme.header.color.opacity(0.55))
                .overlay(shape.stroke(theme.foreground.color.opacity(selected ? 0.18 : 0.1), lineWidth: 1))
                // The selected tab joins the pane below it.
                .overlay(alignment: .bottom) { if selected { theme.background.color.frame(height: 1.5).padding(.horizontal, 1) } }
        }
    }

    private var icon: some View {
        Group {
            if lost {
                // Narrow tabs have no room for the badge, so the icon itself turns red.
                Image(systemName: symbol).foregroundStyle(.red)
            } else if chrome == .flat {
                Image(systemName: symbol).foregroundStyle(selected ? theme.accent.color : .secondary)
            } else {
                // Classic tabs color the icon by state: green when connected, gray otherwise.
                Image(systemName: symbol).foregroundStyle(connected ? Color.green : Color.secondary)
            }
        }
        .appFont(.system(size: 11))
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").appFont(.system(size: 8, weight: .bold))
                .foregroundStyle(hoveringClose ? Color.primary : Color.secondary)
                .frame(width: 16, height: 16)
                .background(Color.primary.opacity(hoveringClose ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringClose = $0 }
        .help(T("Close connection"))
    }
}

struct PaneIconButton: View {
    let symbol: String
    var active = false
    var activeColor: Color = .accentColor
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).appFont(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? activeColor : hovering ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(T(help))
        .accessibilityLabel(T(help))
    }
}

/// A remote desktop's part of the pane header: a spinner while it signs in, then a disconnect button.
private struct DesktopHeaderControls: View {
    @ObservedObject var connection: RemoteDesktopSession
    @State private var fullScreen = NSApp?.keyWindow?.styleMask.contains(.fullScreen) == true

    var body: some View {
        Group { controls }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
    }

    @ViewBuilder private var controls: some View {
        if connection.phase == .connecting { ProgressView().controlSize(.mini).padding(.horizontal, 4) }
        if connection.phase == .connected {
            // The desktop follows the view's size, so full screen gives it the whole display.
            PaneIconButton(symbol: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           help: fullScreen ? "Exit full screen" : "Full screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .accessibilityIdentifier("desktopFullScreenButton")
        }
        if connection.phase != .idle {
            PaneIconButton(symbol: "bolt.horizontal.circle", help: "Disconnect") { connection.disconnect() }
                .accessibilityIdentifier("desktopDisconnectButton")
        }
    }
}

struct SessionPane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    let compact: Bool
    let dockedFiles: Bool
    /// Square, edge-to-edge drawing for the Classic and Workbench layouts.
    let flat: Bool
    /// Classic layouts drop the pane header for a lone connected pane: the tab and status bar say the same.
    let showsHeader: Bool
    /// A session in its own window has no file sidebar, so its header opens the transfer window instead.
    var transferButton = false
    @State private var forwarding = false
    @AppStorage(TerminalPreferences.opacityKey) private var terminalOpacity = 1.0
    @State private var reviewedHostKey: HostKeyChange?
    @State private var confirmingVaultRemoval = false
    @State private var namingConnection = false
    @State private var connectionName = ""
    @State private var keyNeedsPassphrase = true
    /// Whether each listed jump host's key file is encrypted, by key path.
    @State private var jumpKeysNeedingPassphrase: Set<String> = []
    /// The Local row was clicked: it shows so at once, and the terminal replaces the form on the next frame.
    @State private var openingLocal = false
    /// The SSH form's width, which decides how its option rows wrap.
    @State private var sshFormWidth: CGFloat = 1000
    @Environment(\.appTextScale) private var textScale
    init(model: WorkspaceModel, tab: SessionTab, compact: Bool = false, dockedFiles: Bool = false, flat: Bool = false, showsHeader: Bool = true,
         transferButton: Bool = false) {
        self.model = model; self.tab = tab; self.compact = compact
        self.dockedFiles = dockedFiles; self.flat = flat; self.showsHeader = showsHeader; self.transferButton = transferButton
    }
    private var live: Bool { tab.connected || tab.isLocal }
    var body: some View {
        let _ = ViewEvaluations.note("SessionPane")
        if let desktop = tab.desktop {
            // The same slim header as a terminal, so every kind of session reads alike.
            VStack(spacing: 0) {
                if showsHeader || !live { header }
                RemoteDesktopPane(model: model, tab: tab, connection: desktop)
            }
        } else {
            terminalPane
        }
    }

    private var terminalPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader || !live || tab.busy { header }
            VStack(alignment: .leading, spacing: 10) {
                if live {
                    status
                } else {
                    // A split pane can be short and narrow: the sign-in form scrolls rather than being cut off, and
                    // the terminal below only appears when it still holds output from before the connection dropped.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            connectionForm
                            status
                        }
                        .padding(1)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: tab.transportLost ? 260 : .infinity, alignment: .top)
                    .layoutPriority(1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if live || tab.transportLost { content }
            }
            .padding(flat ? (live ? 0 : 10) : compact ? 6 : 10)
        }
        .animation(.easeOut(duration: 0.2), value: tab.connected)
        .overlay {
            // A tagged environment frames the pane in its color, so production stands out in a split.
            if let environment = tab.environment {
                RoundedRectangle(cornerRadius: flat ? 0 : 10, style: .continuous)
                    .strokeBorder(environment.color.opacity(environment == .production ? 0.85 : 0.6), lineWidth: environment == .production ? 2 : 1.5)
                    .allowsHitTesting(false)
            }
        }
        .modifier(AgentReview(model: model, tab: tab, visible: model.split?.contains(tab.id) != true || model.selection == tab.id))
        .alert(T("Run this command?"), isPresented: Binding(get: { tab.riskyCommand != nil }, set: { _ in }), presenting: tab.riskyCommand) { _ in
            Button(T("Cancel"), role: .cancel) { model.confirmRiskyCommand(tab, run: false) }
            Button(T("Run"), role: .destructive) { model.confirmRiskyCommand(tab, run: true) }
        } message: { prompt in
            Text(String(format: T("This session is tagged %@, and the command matches a pattern in Settings > Safety.\n\n%@"),
                        T(prompt.environment.title), prompt.command))
        }
        .textFieldStyle(.roundedBorder)
        .loginChallengeSheet(model: model, tab: tab, visible: model.split?.contains(tab.id) != true || model.selection == tab.id)
        .sheet(item: visibleHostKey, onDismiss: { model.answerHostKey(tab, approve: false) }) { prompt in
            VStack(alignment: .leading, spacing: 18) {
                Label(T("Verify this server"), systemImage: "key.horizontal").appFont(.title2.bold())
                Text(prompt.endpoint).appFont(.headline)
                Text(T("Compare this fingerprint with the server administrator before trusting this connection."))
                Text(prompt.fingerprint).appFont(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("hostFingerprint")
                HStack { Button(T("Cancel")) { model.answerHostKey(tab, approve: false) }; Spacer(); Button(T("Trust and connect")) { model.answerHostKey(tab, approve: true) }.buttonStyle(.appProminent).accessibilityIdentifier("trustHostButton") }
            }.padding(24).frame(width: 530)
        }
        .sheet(item: $reviewedHostKey) { change in
            VStack(alignment: .leading, spacing: 14) {
                Label(T("Host key changed"), systemImage: "exclamationmark.shield").appFont(.title2.bold())
                Text(change.endpoint).appFont(.headline).textSelection(.enabled)
                Text(T("Confirm the new fingerprint from the server console or with your administrator before updating the saved key."))
                    .fixedSize(horizontal: false, vertical: true)
                fingerprint(T("Saved fingerprint"), value: change.savedFingerprint)
                fingerprint(T("New fingerprint"), value: change.receivedFingerprint)
                HStack {
                    Spacer()
                    Button(T("Cancel")) { reviewedHostKey = nil }.keyboardShortcut(.cancelAction)
                    Button(T("Update key and reconnect"), role: .destructive) {
                        reviewedHostKey = nil
                        Task { await model.updateHostKeyAndReconnect(tab, change: change) }
                    }
                    .accessibilityIdentifier("updateHostKeyButton")
                }
            }
            .padding(24).frame(width: 555)
        }
        .sheet(isPresented: $forwarding) { PortForwardingView(model: model, tab: tab) }
        .sheet(isPresented: $namingConnection) {
            SessionNameSheet(title: T("Save connection"), name: $connectionName, showsConnectionInfo: true) {
                namingConnection = false
            } onSave: {
                do {
                    try model.saveConnection(tab, name: connectionName, parent: model.sessionTree.destination)
                } catch {
                    tab.error = error.localizedDescription
                }
                namingConnection = false
            }
        }
        .task { if CommandLine.arguments.contains("--capture-files") { tab.showsFiles = true } }
        .task(id: tab.connected) { if tab.connected { await showSelectedPanel() } }
        .onChange(of: tab.identityPath) { _, _ in tab.password = ""; tab.keyPassphrase = ""; tab.error = nil }
        .task(id: tab.identityPath) { keyNeedsPassphrase = await Self.needsPassphrase(tab.identityPath) }
        .task(id: jumpKeyPaths) {
            var encrypted: Set<String> = []
            for path in jumpKeyPaths where await Self.needsPassphrase(path) { encrypted.insert(path) }
            jumpKeysNeedingPassphrase = encrypted
        }
        .onChange(of: tab.useAgent) { _, _ in tab.password = "" }
        .onChange(of: tab.jumpPath) { _, path in
            // A secret typed for a hop that is no longer listed is dropped.
            tab.jumpSecrets = tab.jumpSecrets.filter { path.contains($0.key) }
            if !path.isEmpty { tab.useProxy = false }
        }
    }

    /// Connection progress and the last error, shown above the terminal or under the sign-in form.
    @ViewBuilder private var status: some View {
        if let progress = tab.progress { ProgressView(value: progress).tint(model.theme.accent.color) }
        if let error = tab.error {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(T(error)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let change = tab.hostKeyChange, !tab.busy {
                    Button(T("Review host key…")) { reviewedHostKey = change }
                        .foregroundStyle(model.theme.foreground.color)
                        .accessibilityIdentifier("reviewHostKeyButton")
                }
                Button { tab.error = nil; tab.hostKeyChange = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.appFont(.callout).foregroundStyle(.red).padding(8).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Remote files live in the file sidebar, the SFTP rail, or the transfer window, so a pane always shows its terminal.
    @ViewBuilder private var content: some View {
        if tab.connected && !tab.terminalReady && !tab.terminalStarting && tab.ftpSecurity == nil {
            Button(T("Open terminal")) { Task { await model.startTerminal(tab) } }
        }
        TerminalDisplay(tab: tab, model: model)
            .background { if terminalOpacity < 1 { TerminalBackdrop() } }
            .overlay(alignment: .topTrailing) { TerminalFindBar(model: model, tab: tab) }
            .clipShape(RoundedRectangle(cornerRadius: flat ? 0 : 8)).accessibilityIdentifier("terminalOutput")
    }

    private static func needsPassphrase(_ path: String?) async -> Bool {
        guard let path else { return false }
        return await Task.detached { SSHPrivateKeyFile.needsPassphrase(at: URL(fileURLWithPath: path)) }.value
    }

    /// A thin Termius-style bar: what the pane is, and a few icon actions. Drag it to move the pane.
    private var header: some View {
        ViewEvaluations.note("SessionPane.header")
        return HStack(spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(tab.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Image(systemName: tab.container?.tool.symbol ?? (tab.isLocal ? "apple.logo" : "network")).appFont(.system(size: 11)).foregroundStyle(.secondary)
                Text(tab.container != nil ? tab.host : tab.isLocal ? "127.0.0.1" : tab.host.isEmpty ? T("New connection") : tab.host)
                    .appFont(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                Text(subtitle).appFont(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                if let title = tab.programTitle {
                    Text(title).appFont(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(title)
                }
                if tab.busy || tab.terminalStarting { ProgressView().controlSize(.mini) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onDrag { PaneDrag.provider(for: tab.id) }
            .help(T("Drag onto a pane to split it"))
            if tab.connected && tab.route.count > 1 { RouteHeaderButton(model: model, tab: tab) }

            if let environment = tab.environment { EnvironmentBadge(environment: environment) }
            RecordingIndicator(model: model, tab: tab)
            LogIndicator(model: model, tab: tab, logs: model.logs)
            if tab.readOnly {
                PaneIconButton(symbol: "lock.fill", active: true, activeColor: .orange, help: "Read-only: click to allow typing") {
                    model.toggleReadOnly(tab)
                }
                .accessibilityIdentifier("readOnlyButton")
            }
            if let desktop = tab.desktop { DesktopHeaderControls(connection: desktop) }
            else { CommandStatusButton(model: model, tab: tab) }
            if transferButton && tab.connected && !tab.isLocal {
                PaneIconButton(symbol: "folder", help: "Show this server's files in the main window") { model.openFileTransfer(for: tab) }
                    .accessibilityIdentifier("fileTransferButton")
            }
            if !tab.isLocal && tab.desktop == nil {
                PaneIconButton(symbol: "arrow.left.arrow.right", help: "Port forwarding") { forwarding = true }
                    .accessibilityIdentifier("portForwardingButton")
            }
            if model.split?.contains(tab.id) == true {
                PaneIconButton(symbol: "dot.radiowaves.left.and.right", active: model.broadcastInput, activeColor: .orange,
                               help: model.broadcastInput ? "Stop typing into all panes" : "Type into all panes") { model.toggleBroadcastInput() }
                    .accessibilityIdentifier("broadcastInputButton")
                let maximized = model.maximizedPane == tab.id
                PaneIconButton(symbol: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: maximized ? "Restore pane" : "Maximize pane") {
                    model.toggleMaximizedPane(tab.id)
                }
                .accessibilityIdentifier("maximizePaneButton")
            }
            PaneIconButton(symbol: "xmark", help: tab.connected || tab.busy ? "Disconnect and close this session" : "Close connection") {
                model.requestClose(tab)
            }
            .accessibilityIdentifier("disconnectButton")
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 30)
        .background(model.theme.header.color.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(model.theme.foreground.color.opacity(0.07)).frame(height: 1) }
    }

    private var subtitle: String {
        // "rdp, alice" like "ssh, alice".
        if let desktop = tab.desktop {
            return ([desktop.profile.tool.rawValue] + [desktop.profile.user].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: ", ")
        }
        if !tab.connected && !tab.busy { return T(tab.status) }
        if let container = tab.container { return container.tool.title }
        if tab.isLocal { return "local, \(tab.username)" }
        return "ssh, \(SessionKey.masked(tab.username))"
    }

    private var isNewConnection: Bool { tab.newConnectionType != nil && tab.savedSessionID == nil && !tab.transportLost }

    @ViewBuilder private var connectionForm: some View {
        if isNewConnection { newConnectionSections } else { sshForm.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10)) }
    }

    /// A new connection lists Local, SSH, RDP, VNC, and other connections from top to bottom; the chosen one is open
    /// for filling in. Local has nothing to fill in: one click opens this Mac's shell in the tab.
    private var newConnectionSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            localConnectionRow
            ForEach(NewConnectionType.allCases.filter { $0 != .local }, id: \.self) { type in
                let open = (tab.newConnectionType ?? .ssh) == type
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        NewConnectionType.last = type   // The next new connection opens here.
                        withAnimation(.easeOut(duration: 0.15)) { tab.newConnectionType = type }
                    } label: {
                        connectionRowLabel(type, open: open)
                    }
                    .buttonStyle(.plain)
                    .disabled(tab.busy)
                    .accessibilityIdentifier("newConnection-" + type.rawValue)
                    .accessibilityLabel(T(type.shortTitle))
                    .accessibilityHint(T(type.subtitle))
                    if open { sectionForm(type) }
                }
                .background(.quaternary.opacity(open ? 0.4 : 0.2), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionForm(_ type: NewConnectionType) -> some View {
        Group {
            if let tool = type.editorTool {
                ContainerSessionEditor(model: model, editing: nil, tool: tool.opensDesktop ? tool : NewConnectionType.lastOtherTool,
                                       draftTab: tab).id(tool)
            } else {
                sshForm
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    /// Green, unlike the other four, with no chevron since it has nothing to expand: it reads as a button, not a form.
    private var localConnectionRow: some View {
        let type = NewConnectionType.local
        return Button {
            guard !openingLocal else { return }
            NewConnectionType.last = type   // The next new connection leaves every section closed.
            // Show the click first; building the terminal takes a moment, which held the click up with no sign of it.
            openingLocal = true
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                model.openLocalTerminal(in: tab)
                openingLocal = false
            }
        } label: {
            connectionRowLabel(type, open: false, working: openingLocal)
            .background(Color.green.opacity(openingLocal ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.4), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(tab.busy)
        .accessibilityIdentifier("newConnection-" + type.rawValue)
        .accessibilityLabel(T(type.title))
        .accessibilityHint(T(type.subtitle))
    }

    private func connectionRowLabel(_ type: NewConnectionType, open: Bool, working: Bool = false) -> some View {
        let local = type == .local
        return HStack(spacing: 12) {
            Image(systemName: local ? "laptopcomputer" : type.editorTool?.symbol ?? "terminal")
                .appFont(.system(size: 16))
                .foregroundStyle(local ? Color.green : open ? .accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(T(type.shortTitle)).appFont(.body.weight(.semibold))
                Text(T(type.subtitle)).appFont(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: local ? "arrow.right" : "chevron.right")
                    .appFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(local ? Color.green : .secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var sshForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            let credentialLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) :
                AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            credentialLayout {
                HStack(alignment: .top, spacing: 10) {
                    field("Host") { TextField("server.example.com", text: $tab.host).accessibilityIdentifier("hostField") }
                        .frame(maxWidth: 340)
                    field("Port") { TextField("22", text: $tab.port).accessibilityIdentifier("portField") }.frame(width: 76)
                }
                HStack(alignment: .top, spacing: 10) {
                    field("Username") { TextField(T("Username"), text: $tab.username).accessibilityIdentifier("usernameField") }
                        .frame(maxWidth: 184)
                    if tab.identityPath == nil && tab.useAgent {
                        field("Authentication") {
                            Label(T("Keys from the SSH agent"), systemImage: "key.horizontal").foregroundStyle(.secondary)
                        }
                    } else if tab.identityPath == nil {
                        field("Password or vault entry") { SecureField(T("Password or vault entry"), text: $tab.password).accessibilityIdentifier("passwordField") }
                            .frame(maxWidth: 230)
                    } else if keyNeedsPassphrase {
                        // Only an encrypted key file has a passphrase; the Gloamux key and unencrypted keys do not.
                        field("Key passphrase") { SecureField(T("Key passphrase"), text: $tab.keyPassphrase) }
                            .frame(maxWidth: 230)
                    }
                }
            }.onSubmit { Task { await model.connect(tab) } }
            // One row when the pane is wide enough; in a narrow split pane, the proxy settings move to a second row.
            // Chosen from the measured width: ViewThatFits built every arrangement to try it, which slowed opening.
            let oneRow = (tab.useProxy && tab.jumpPath.isEmpty ? 940 : 660) * textScale
            if sshFormWidth >= oneRow {
                HStack {
                    keyOptions
                    if tab.jumpPath.isEmpty {
                        Divider().frame(height: 16)
                        proxyOptions(hostWidth: 170)
                    }
                    Spacer(minLength: 8)
                    savePasswordButton
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if sshFormWidth >= 480 * textScale {
                        HStack { keyOptions; Spacer(minLength: 8); savePasswordButton }
                    } else {
                        VStack(alignment: .leading, spacing: 8) { keyOptions; savePasswordButton }
                    }
                    if tab.jumpPath.isEmpty {
                        HStack { proxyOptions(hostWidth: nil) }
                    }
                }
            }
            if !tab.jumpPath.isEmpty { jumpHostCards }
            HStack {
                addJumpHostButton
                // The main button sits where filling in ends, as in a macOS dialog; Return does the same.
                Spacer(minLength: 8)
                if !tab.busy {
                    if isNewConnection {
                        Button(T("Save")) {
                            connectionName = tab.host.trimmingCharacters(in: .whitespacesAndNewlines)
                            namingConnection = true
                        }
                        .disabled(tab.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  tab.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.appTinted).tint(model.theme.accent.color)
                        .accessibilityIdentifier("saveConnectionButton")
                    }
                    Button(T(tab.transportLost ? "Reconnect" : "Connect")) { Task { await model.connect(tab) } }
                        .buttonStyle(.appProminent).tint(model.theme.accent.color)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("connectButton")
                }
            }
        }
        .controlSize(.large)
        // Fills the pane to its right edge, as the New connection form does, after a failed connection too.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sshFormWidth = $0 }
        .disabled(tab.busy)
    }

    /// Key files of the listed jump hosts, to learn which ones need a passphrase.
    private var jumpKeyPaths: [String] {
        tab.jumpPath.compactMap { model.sessionTree.node($0)?.connection?.identityPath }
    }

    /// One card per listed jump host, in the order Gloamux connects through them; the destination comes after the last.
    private var jumpHostCards: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(T("SSH jump hosts")).appFont(.callout.weight(.semibold)).foregroundStyle(.secondary)
                InfoButton(T("Gloamux connects to these in order, from the top, and reaches this server from the last one. A password typed here is used for this connection only; after it works, it is remembered like any other."))
            }
            ForEach(Array(tab.jumpPath.enumerated()), id: \.element) { index, id in
                jumpHostCard(index: index, id: id)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func jumpHostCard(index: Int, id: UUID) -> some View {
        let others = Set(tab.jumpPath).subtracting([id])
        let selection = Binding<UUID?>(
            get: { id },
            set: { new in
                guard let new, let position = tab.jumpPath.firstIndex(of: id) else { return }
                tab.jumpPath[position] = new
            })
        return HStack(spacing: 8) {
            Text(verbatim: "\(index + 1)").appFont(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary).frame(minWidth: 16)
            JumpHostPicker(store: model.sessionTree, excluding: tab.savedSessionID, selection: selection,
                           fills: true, hidden: others, allowsNone: false)
                .frame(maxWidth: 300)
            if let jump = model.sessionTree.node(id)?.connection,
               jump.identityPath.map({ jumpKeysNeedingPassphrase.contains($0) }) ?? (jump.usesAgent != true) {
                let title = jump.identityPath == nil ? "Jump host password" : "Jump host key passphrase"
                SecureField(T(title), text: Binding(get: { tab.jumpSecrets[id] ?? "" }, set: { tab.jumpSecrets[id] = $0 }))
                    .frame(maxWidth: 220)
            }
            Spacer(minLength: 0)
            Button {
                tab.jumpPath.removeAll { $0 == id }
            } label: {
                Image(systemName: "xmark").appFont(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(T("Remove this jump host"))
            .accessibilityLabel(T("Remove this jump host"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: T("Jump host %d"), index + 1))
    }

    /// Adds the next jump host after the listed ones: the first saved session that is not listed yet.
    private var addJumpHostButton: some View {
        let candidates = model.sessionTree.jumpCandidates(excluding: tab.savedSessionID).filter { !tab.jumpPath.contains($0.id) }
        return Button {
            if let next = candidates.first { tab.jumpPath.append(next.id) }
        } label: {
            Label(T("Add jump host"), systemImage: "plus")
        }
        .disabled(candidates.isEmpty || tab.jumpPath.count >= SessionTreeStore.maximumJumpHops)
        .help(T(candidates.isEmpty && tab.jumpPath.isEmpty ? "Save another SSH session first to use it as a jump host." : "Connect through another saved SSH session"))
        .accessibilityIdentifier("addJumpHostButton")
    }

    @ViewBuilder private var keyOptions: some View {
        IdentityFilePicker(path: $tab.identityPath) { Task { await model.removeKey(from: tab) } }
        Toggle(T("SSH agent"), isOn: $tab.useAgent).toggleStyle(.checkbox).fixedSize()
            .help(T("Offer the SSH agent's keys before the key file"))
    }

    @ViewBuilder private func proxyOptions(hostWidth: CGFloat?) -> some View {
        Toggle(T("Proxy"), isOn: $tab.useProxy).toggleStyle(.checkbox).fixedSize()
        if tab.useProxy {
            ProxyKindPicker(kind: $tab.proxyKind).frame(width: 92)
            TextField(T("Proxy host"), text: $tab.proxyHost).frame(width: hostWidth).frame(minWidth: 90)
            TextField(T("Port"), text: $tab.proxyPort).frame(width: 65)
        }
    }

    @ViewBuilder private var savePasswordButton: some View {
        // Without a vault there is nothing to add to: passwords that sign in are remembered on this Mac.
        if tab.identityPath == nil && !tab.useAgent && model.vaultState != "Not configured" {
            let stored = model.vaultEntries.contains(tab.credentialID)
            if stored {
                // Already in the vault: a mark that opens update and remove.
                let unlocked = model.vaultState == "Unlocked"
                Menu {
                    Button(T("Update vault")) { Task { await model.savePassword(tab) } }
                        .disabled(!unlocked || tab.password.isEmpty)
                    Button(T("Remove from vault…"), role: .destructive) { confirmingVaultRemoval = true }
                        .disabled(!unlocked)
                    if !unlocked { Text(T("Unlock the password vault to change it.")) }
                } label: {
                    Label(T("In vault"), systemImage: "checkmark.shield.fill")
                }
                .menuStyle(.button).fixedSize()
                .tint(.green).foregroundStyle(.green)
                .help(T("This account's password is saved in the password vault."))
                .accessibilityIdentifier("inVaultMark")
                .confirmationDialog(T("Remove this password from the vault?"), isPresented: $confirmingVaultRemoval) {
                    Button(T("Remove"), role: .destructive) { Task { await model.removeFromVault(tab) } }
                    Button(T("Cancel"), role: .cancel) {}
                } message: {
                    Text(T("The next connection to this account asks for the password."))
                }
            } else {
                // Not "save password": signing in already saves it while the vault is unlocked.
                Button {
                    Task { await model.savePassword(tab) }
                } label: {
                    Label(T("Add to vault"), systemImage: "lock.shield")
                }
                .disabled(model.vaultState != "Unlocked")
                .help(T(model.vaultState != "Unlocked"
                        ? "Unlock the password vault to keep a copy of this password there."
                        : "Keeps a copy of this password in the master-password vault. Passwords that sign in are remembered on this Mac without it."))
                .accessibilityIdentifier("addToVaultButton")
            }
        }
    }

    private var visibleHostKey: Binding<HostKeyPrompt?> {
        Binding(get: {
            let inSplit = model.split?.contains(tab.id) == true
            return !inSplit || model.selection == tab.id ? tab.hostKeyPrompt : nil
        }, set: { _ in })
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(T(title)).appFont(.callout.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
    private func fingerprint(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).appFont(.caption).foregroundStyle(.secondary)
            Text(value).appFont(.body.monospaced()).textSelection(.enabled)
        }
    }
    private func showSelectedPanel() async {
        guard tab.connected else { return }
        // A session that opened to its files waits for Open terminal instead of asking for one.
        if (!tab.showsFiles || dockedFiles) && !tab.terminalReady { await model.startTerminal(tab) }
    }
}


/// What the window toolbar shows. The toolbar is rebuilt only when one of these changes.
struct WorkspaceToolbarState: Equatable {
    var showsTree: Bool
    var selection: UUID?
    var layout: WorkspaceLayout
    var mode: WorkspaceMode
    var themeID: String
    var language: AppLanguage
    var filesSidebarOpen: Bool
    var canShowFilesSidebar: Bool
    var sidebar: WorkspaceSidebar?
}

/// Holds the window toolbar apart from the rest of the window. The window redraws on every workspace change; if the
/// toolbar were rebuilt with it, AppKit would also rebuild each item's overflow menu and its symbol images, a frame or
/// two of main-thread work each time that makes animations elsewhere, such as an explanation popover, stutter.
/// Compared by `state` alone: the content's actions reach the workspace and the window's settings through references
/// that stay the same.
struct WorkspaceToolbarHost<Content: ToolbarContent>: View, Equatable {
    let state: WorkspaceToolbarState
    @ToolbarContentBuilder let content: () -> Content

    var body: some View {
        // The toolbar keeps macOS's own toolbar buttons rather than the app's button style around it.
        Color.clear.frame(width: 0, height: 0).toolbar(content: content).buttonStyle(.automatic)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }
}

/// Redraws its content when the tab changes, for views drawn by a parent that observes only the workspace.
struct TabObserver<Content: View>: View {
    @ObservedObject var tab: SessionTab
    @ViewBuilder let content: (SessionTab) -> Content
    var body: some View { content(tab) }
}
