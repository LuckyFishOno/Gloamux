import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SessionTreeView: View {
    @ObservedObject var store: SessionTreeStore
    @ObservedObject var model: WorkspaceModel
    @State private var editor: TreeEditor?
    @State private var name = ""
    @State private var deleting: SessionTreeNode?
    @State private var connectionEditor: ConnectionEditRequest?
    static let space = "sessionTree"
    var importFrom: (FolderImportRequest.Source) -> Void = { _ in }
    @AppStorage(Reachability.key) private var reachabilityEnabled = true

    /// Saved hosts whose rows are on screen: at the top level or inside expanded folders.
    private var visibleSessions: [SessionTreeNode] {
        let indexed = Dictionary(uniqueKeysWithValues: store.nodes.map { ($0.id, $0) })
        return store.nodes.filter { node in
            guard node.connection != nil else { return false }
            var parent = node.parent
            while let id = parent {
                guard let folder = indexed[id], folder.expanded else { return false }
                parent = folder.parent
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // One line: the full title, a shorter one, or only the icon when the sidebar is narrow, never a cut word.
                ViewThatFits(in: .horizontal) {
                    Label(T("Session Manager"), systemImage: "folder").fixedSize()
                    Label(T("Sessions"), systemImage: "folder").fixedSize()
                    Label(T("Session Manager"), systemImage: "folder").labelStyle(.iconOnly)
                }
                .appFont(.system(size: 13, weight: .semibold))
                .accessibilityElement(children: .ignore).accessibilityLabel(T("Session Manager")).accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu { rootMenu }
                Menu {
                    Picker(T("Sort"), selection: Binding(get: { store.sorting }, set: { sorting in perform { try store.setSorting(sorting) } })) {
                        Text(T("Custom")).tag(SessionTreeSorting.custom)
                        Text(T("Name (ascending)")).tag(SessionTreeSorting.nameAscending)
                        Text(T("Name (descending)")).tag(SessionTreeSorting.nameDescending)
                    }.pickerStyle(.inline)
                } label: { Image(systemName: "arrow.up.arrow.down").iconHitArea() }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(T("Sort")).accessibilityLabel(T("Sort"))
                Menu {
                    newItems(parent: store.destination)
                    Button(T("Save current connection…")) { saveCurrent() }.disabled(!canSaveCurrent)
                    Button(T("Other connection…")) { model.openTool(.containers) }
                    Button(T("Discover hosts…")) { model.openTool(.discovery) }
                    Divider()
                    Menu(T("Import")) {
                        ForEach(FolderImportRequest.Source.allCases, id: \.self) { source in
                            Button(T(source.menuTitle)) { importFrom(source) }
                        }
                    }
                    exportMenu(T("Export all sessions"), root: nil).disabled(store.nodes.isEmpty)
                    Divider()
                    Button(T("Expand all")) { perform { try store.expandAll(true) } }
                    Button(T("Collapse all")) { perform { try store.expandAll(false) } }
                    Button(T("Paste at root")) { perform { try store.paste(into: nil) } }.disabled(store.clipboard == nil)
                } label: { Image(systemName: "plus.circle").iconHitArea() }.menuStyle(.borderlessButton).fixedSize()
                    .help(T("Add")).accessibilityLabel(T("Add"))
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("Search sessions"), text: $store.query).textFieldStyle(.plain)
                    .accessibilityIdentifier("sessionSearch")
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(T("Clear search"))
                }
            }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            SessionOutline(store: store, reachability: reachabilityEnabled ? model.reachability : nil,
                           activate: { model.openSaved($0) }, menu: { contextMenu(for: $0) },
                           delete: { deleting = $0 }, failed: { model.error = $0.localizedDescription })
                .overlay(alignment: .topLeading) {
                    Group {
                        if store.nodes.isEmpty {
                            Text(T("Save a connection or create a folder using +.")).padding(.vertical, 10)
                        } else if !store.children(of: nil).contains(where: { store.matches($0.id) }) {
                            Text(T("No matching sessions")).padding(.vertical, 4)
                        }
                    }
                    .appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).allowsHitTesting(false)
                }
                .frame(minHeight: 120, maxHeight: .infinity)
        }
        // Checks the SSH port of visible saved hosts now and then; the dots after their names show the result.
        .task(id: reachabilityEnabled) {
            while !Task.isCancelled && reachabilityEnabled {
                await model.reachability.refresh(visibleSessions)
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .sheet(item: $connectionEditor) { request in
            ConnectionEditor(store: store, item: request.item, parent: request.parent, model: model)
        }
        .sheet(item: $editor) { current in
            SessionNameSheet(title: current.title, name: $name, showsConnectionInfo: current.kind == .save) {
                editor = nil
            } onSave: {
                submit(current)
            }
        }
        .alert(T("Delete saved item?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(T("Cancel"), role: .cancel) { deleting = nil }
            Button(T("Delete"), role: .destructive) { if let item = deleting { perform { try store.remove(item.id) } }; deleting = nil }
        } message: { Text(String(format: T("%@ and its saved descendants will be removed. Open connections and remote files are unaffected."), deleting?.name ?? "")) }
    }

    private var canSaveCurrent: Bool {
        guard let tab = model.selected else { return false }
        return !tab.isLocal && NewConnectionType.usesSSHForm(tab.newConnectionType)
    }

    @ViewBuilder private func newItems(parent: UUID?) -> some View {
        Button(T("New folder…")) { edit(.folder, parent: parent) }
        Button(T("New saved session…")) { connectionEditor = ConnectionEditRequest(parent: parent) }
        Button(T("New session from sftp command")) { model.showSFTPCommand() }
        Button(T(ContainerSession.Tool.rdp.title)) { model.openTool(.rdp, parent: parent) }
        Button(T(ContainerSession.Tool.vnc.title)) { model.openTool(.vnc, parent: parent) }
    }

    @ViewBuilder private var rootMenu: some View {
        newItems(parent: nil)
        Divider()
        Button(T("Paste")) { perform { try store.paste(into: nil) } }.disabled(store.clipboard == nil)
        exportMenu(T("Export all sessions"), root: nil).disabled(store.nodes.isEmpty)
        Button(T("Expand all")) { perform { try store.expandAll(true) } }
        Button(T("Collapse all")) { perform { try store.expandAll(false) } }
    }

    /// The right-click menu of a row, or of the empty space under the rows when `item` is nil.
    private func contextMenu(for item: SessionTreeNode?) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, to menu: NSMenu = menu, enabled: Bool = true, on: Bool = false, _ run: @escaping () -> Void) {
            menu.addItem(MenuAction(title, enabled: enabled, on: on, run))
        }
        func addNewItems(parent: UUID?) {
            add(T("New folder…")) { edit(.folder, parent: parent) }
            add(T("New saved session…")) { connectionEditor = ConnectionEditRequest(parent: parent) }
            add(T("New session from sftp command")) { model.showSFTPCommand() }
            add(T(ContainerSession.Tool.rdp.title)) { model.openTool(.rdp, parent: parent) }
            add(T(ContainerSession.Tool.vnc.title)) { model.openTool(.vnc, parent: parent) }
        }
        func addExport(_ title: String, root: UUID?, enabled: Bool = true) {
            let formats = NSMenu()
            add(T("Gloamux sessions file (for teammates, no passwords)…"), to: formats) { export(root, .gloamux) }
            add(T("CSV file (for spreadsheets)…"), to: formats) { export(root, .csv) }
            add(T("OpenSSH config (for ssh in any terminal)…"), to: formats) { export(root, .openSSH) }
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.submenu = formats; entry.isEnabled = enabled
            menu.addItem(entry)
        }
        guard let item else {
            addNewItems(parent: nil)
            menu.addItem(.separator())
            add(T("Paste"), enabled: store.clipboard != nil) { perform { try store.paste(into: nil) } }
            addExport(T("Export all sessions"), root: nil, enabled: !store.nodes.isEmpty)
            add(T("Expand all")) { perform { try store.expandAll(true) } }
            add(T("Collapse all")) { perform { try store.expandAll(false) } }
            return menu
        }
        if item.isFolder {
            add(T("Open all in tabs")) { perform { try model.openSavedFolder(item.id) } }
            addNewItems(parent: item.id)
            add(T("Save current connection here…"), enabled: canSaveCurrent) { saveCurrent(parent: item.id) }
            add(T("Paste"), enabled: store.clipboard != nil) { perform { try store.paste(into: item.id) } }
            addExport(T("Export folder"), root: item.id)
        } else {
            add(T("Open in new window")) { model.openSaved(item, inNewWindow: true) }
            add(T("Open in tab")) { model.openSaved(item) }
            add(T("Session properties…")) {
                if item.container != nil { model.editContainer(item) }
                else { connectionEditor = ConnectionEditRequest(item: item, parent: item.parent) }
            }
            add(T("Session Log")) { model.showConnectionHistory(search: item.name) }
        }
        // Sessions inherit their folder's tag, so "none" reads "Same as folder" under a tagged folder.
        let environments = NSMenu()
        add(T(item.parent.flatMap { store.effectiveEnvironment($0) }.map { _ in "Same as folder" } ?? "None"), to: environments,
            on: item.environment == nil) { perform { try store.setEnvironment(item.id, nil) } }
        environments.addItem(.separator())
        for environment in SessionEnvironment.allCases {
            add(T(environment.title), to: environments, on: item.environment == environment) { perform { try store.setEnvironment(item.id, environment) } }
        }
        let environmentItem = NSMenuItem(title: T("Environment"), action: nil, keyEquivalent: ""); environmentItem.submenu = environments
        menu.addItem(environmentItem)
        if !item.isFolder {
            let allowed = model.agents.allowedSessions.contains(item.id)
            add(T("Allow AI agents"), on: allowed) {
                if allowed { model.agents.revoke(item.id, name: item.name) } else { model.agents.allow(item.id, name: item.name) }
            }
        }
        menu.addItem(.separator())
        add(T("Rename…")) { name = item.name; editor = TreeEditor(kind: .rename, item: item.id, parent: item.parent, tab: nil) }
        add(T("Copy")) { store.prepareClipboard(item.id, cut: false) }
        add(T("Cut")) { store.prepareClipboard(item.id, cut: true) }
        add(T("Delete…")) { deleting = item }
        return menu
    }
    private func edit(_ kind: TreeEditor.Kind, parent: UUID?) {
        name = ""; editor = TreeEditor(kind: kind, item: nil, parent: parent, tab: nil)
    }
    private func saveCurrent(parent: UUID? = nil) {
        guard let tab = model.selected, !tab.isLocal else { return }
        name = tab.host.isEmpty ? "" : tab.title == "New connection" ? tab.host : tab.title
        editor = TreeEditor(kind: .save, item: nil, parent: parent ?? store.destination, tab: tab.id)
    }
    private func submit(_ current: TreeEditor) {
        do {
            switch current.kind {
            case .folder: try store.add(name: name, parent: current.parent)
            case .rename: if let id = current.item { try store.rename(id, to: name) }
            case .save:
                guard let tab = model.tabs.first(where: { $0.id == current.tab }) else { throw WorkspaceError.invalid("The connection tab was closed.") }
                try model.saveConnection(tab, name: name, parent: current.parent)
            }
            editor = nil
        } catch { model.error = error.localizedDescription; editor = nil }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { model.error = error.localizedDescription } }

    /// Export as a Gloamux sessions file (every setting, for Gloamux) or CSV (for spreadsheets). Neither holds passwords.
    private func exportMenu(_ title: String, root: UUID?) -> some View {
        Menu(title) {
            Button(T("Gloamux sessions file (for teammates, no passwords)…")) { export(root, .gloamux) }
            Button(T("CSV file (for spreadsheets)…")) { export(root, .csv) }
            Button(T("OpenSSH config (for ssh in any terminal)…")) { export(root, .openSSH) }
        }
    }

    private func export(_ root: UUID?, _ format: SessionExport.Format) {
        perform {
            let data = try SessionExport.data(store, root: root, format: format)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (root.flatMap(store.node)?.name ?? T("Gloamux sessions")) + "." + format.fileExtension
            panel.allowedContentTypes = [format == .openSSH ? .plainText : UTType(filenameExtension: format.fileExtension) ?? .data]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        }
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, enabled: Bool, on: Bool, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(choose), keyEquivalent: "")
        target = self; isEnabled = enabled; state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choose() { run() }
}

private struct TreeEditor: Identifiable {
    enum Kind { case folder, rename, save }
    let id = UUID()
    let kind: Kind
    let item: UUID?
    let parent: UUID?
    let tab: UUID?
    var title: String { switch kind { case .folder: return T("New folder"); case .rename: return T("Rename saved item"); case .save: return T("Save connection") } }
}

struct SessionNameSheet: View {
    let title: String
    @Binding var name: String
    let showsConnectionInfo: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Text(title).appFont(.headline)
                if showsConnectionInfo { InfoButton(T("Host, account and proxy settings only. Passwords are excluded.")) }
            }
            // A label that stays once the field is filled in: a Save suggests the host as the name, and without it the
            // field read as the host rather than the name the item gets in the session tree.
            VStack(alignment: .leading, spacing: 6) {
                Text(T("Name")).appFont(.callout.weight(.medium)).foregroundStyle(.secondary)
                TextField(T("Name"), text: $name).textFieldStyle(.roundedBorder)
                    .onSubmit { if canSave { onSave() } }
                    .accessibilityLabel(T("Name"))
            }
            DialogActions(cancel: onCancel, title: T("Save"), enabled: canSave, confirm: onSave)
        }
        .padding(20)
        .frame(width: 360)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct ConnectionEditRequest: Identifiable {
    let id = UUID()
    var item: SessionTreeNode?
    let parent: UUID?
}
