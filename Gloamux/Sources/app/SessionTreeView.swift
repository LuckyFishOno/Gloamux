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
    /// Where each visible row's header sits in the tree's own coordinate space, for finding the row under a drag.
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var dragging: TreeDragState?
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
            GeometryReader { bounds in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(store.children(of: nil).filter { store.matches($0.id) }) { item in row(item) }
                            if store.nodes.isEmpty {
                                Text(T("Save a connection or create a folder using +.")).appFont(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
                            } else if !store.children(of: nil).contains(where: { store.matches($0.id) }) {
                                Text(T("No matching sessions")).appFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 18)
                            .frame(maxWidth: .infinity)
                            .background(dragging?.spot == .root ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                            .onTapGesture { store.selection = nil }
                            .contextMenu { rootMenu }
                    }
                    // Fills the visible area so the space under the rows takes clicks and drops, but a pixel short of it:
                    // content exactly as tall as a fractional height (after the vault below opens or closes) makes
                    // the scroll view show a scroller that takes width and truncates names.
                    .frame(minHeight: max(0, bounds.size.height.rounded(.down) - 1), alignment: .topLeading)
                    .coordinateSpace(name: Self.space)
                    .onPreferenceChange(TreeRowFrames.self) { rowFrames = $0 }
                    .overlay(alignment: .topLeading) {
                        if let dragging, let node = store.node(dragging.id) {
                            Label(node.name, systemImage: node.isFolder ? "folder.fill" : "terminal").lineLimit(1)
                                .padding(.vertical, 4).padding(.horizontal, 8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .shadow(radius: 3, y: 1).fixedSize()
                                .offset(x: dragging.location.x + 10, y: dragging.location.y - 12)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }.frame(minHeight: 120, maxHeight: .infinity)
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

    private func row(_ item: SessionTreeNode) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if item.isFolder {
                    Image(systemName: "chevron.right").appFont(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(item.expanded || !store.query.isEmpty ? 90 : 0))
                        .frame(width: 14, height: 14)
                } else { Color.clear.frame(width: 14, height: 14) }
                Image(systemName: item.isFolder ? "folder.fill" : item.container?.tool.symbol ?? (item.connection?.isFTP == true ? "externaldrive.connected.to.line.below" : "terminal"))
                    .foregroundStyle(item.isFolder ? .orange : .secondary)
                Text(item.name).lineLimit(1)
                if let environment = item.environment { EnvironmentBadge(environment: environment, compact: true) }
                if reachabilityEnabled && !item.isFolder { ReachabilityDot(monitor: model.reachability, id: item.id) }
                Spacer(minLength: 0)
                if store.clipboard == item.id { Image(systemName: store.cutting ? "scissors" : "doc.on.doc").appFont(.caption) }
            }
            .padding(.vertical, 6).padding(.horizontal, 4).contentShape(Rectangle())
            .background(store.selection == item.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TreeRowFrames.self, value: [item.id: proxy.frame(in: .named(Self.space))])
            })
            .overlay { dropIndicator(for: item.id) }
            .opacity(dragging?.id == item.id ? 0.45 : 1)
            .modifier(SessionTreeRowInteraction(isFolder: item.isFolder, select: { store.selection = item.id }, toggle: {
                // A folder opens and closes with a single click anywhere on its row, like a Finder sidebar section.
                guard store.query.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.18)) { perform { try store.setExpanded(item.id, !item.expanded) } }
            }, activate: { model.openSaved(item) },
            drag: { location in dragging = TreeDragState(id: item.id, location: location, spot: spot(at: location, moving: item.id)) },
            drop: { location in finishDrag(item.id, at: location) }))
            .contextMenu {
                if item.isFolder {
                    Button(T("Open all in tabs")) { perform { try model.openSavedFolder(item.id) } }
                    newItems(parent: item.id)
                    Button(T("Save current connection here…")) { saveCurrent(parent: item.id) }.disabled(!canSaveCurrent)
                    Button(T("Paste")) { perform { try store.paste(into: item.id) } }.disabled(store.clipboard == nil)
                    exportMenu(T("Export folder"), root: item.id)
                } else {
                    Button(T("Open in new window")) { model.openSaved(item, inNewWindow: true) }
                    Button(T("Open in tab")) { model.openSaved(item) }
                    Button(T("Session properties…")) {
                        if item.container != nil { model.editContainer(item) }
                        else { connectionEditor = ConnectionEditRequest(item: item, parent: item.parent) }
                    }
                }
                environmentMenu(item)
                if !item.isFolder { AgentAccessToggle(agents: model.agents, item: item) }
                Divider()
                Button(T("Rename…")) { name = item.name; editor = TreeEditor(kind: .rename, item: item.id, parent: item.parent, tab: nil) }
                Button(T("Copy")) { store.prepareClipboard(item.id, cut: false) }
                Button(T("Cut")) { store.prepareClipboard(item.id, cut: true) }
                Button(T("Delete…"), role: .destructive) { deleting = item }
            }
            if item.isFolder && (item.expanded || !store.query.isEmpty) {
                ForEach(store.children(of: item.id).filter { store.matches($0.id) }) { child in
                    row(child).padding(.leading, 14).transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        })
    }
    /// Tags a session or folder as production, staging, test, or development. Sessions inherit their folder's tag.
    private func environmentMenu(_ item: SessionTreeNode) -> some View {
        Menu(T("Environment")) {
            Picker(T("Environment"), selection: Binding(get: { item.environment }, set: { environment in
                perform { try store.setEnvironment(item.id, environment) }
            })) {
                Text(T(item.parent.flatMap { store.effectiveEnvironment($0) }.map { _ in "Same as folder" } ?? "None")).tag(SessionEnvironment?.none)
                ForEach(SessionEnvironment.allCases) { environment in
                    Text(T(environment.title)).tag(Optional(environment))
                }
            }
            .pickerStyle(.inline)
        }
    }

    /// A blue line above or below the row, or a frame around a folder, where the dragged item would land.
    @ViewBuilder private func dropIndicator(for id: UUID) -> some View {
        if case let .row(target, placement)? = dragging?.spot, target == id {
            switch placement {
            case .into:
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5)).allowsHitTesting(false)
            case .before, .after:
                VStack(spacing: 0) {
                    if placement == .after { Spacer(minLength: 0) }
                    Capsule().fill(Color.accentColor).frame(height: 2).offset(y: placement == .before ? -2 : 2)
                    if placement == .before { Spacer(minLength: 0) }
                }.allowsHitTesting(false)
            }
        }
    }

    /// The row under `location`, and where on it the item would land; below the last row means the top level.
    /// While sorted by name there is no order to change, so a drop only moves the item into a folder: onto a folder
    /// means inside it, and onto a session means into that session's folder.
    private func spot(at location: CGPoint, moving id: UUID) -> TreeDropSpot? {
        if let (target, frame) = rowFrames.first(where: { $0.value.minY <= location.y && location.y < $0.value.maxY }),
           let node = store.node(target) {
            if store.sorting != .custom {
                guard let folder = node.isFolder ? target : node.parent else {
                    return store.canDrop(id, on: nil, .into) ? .root : nil
                }
                return store.canDrop(id, on: folder, .into) ? .row(folder, .into) : nil
            }
            let placement = SessionTreeDropPlacement.at(location.y - frame.minY, height: frame.height, isFolder: node.isFolder,
                                                        expanded: node.expanded || !store.query.isEmpty)
            return store.canDrop(id, on: target, placement) ? .row(target, placement) : nil
        }
        let bottom = rowFrames.values.map(\.maxY).max() ?? 0
        return location.y >= bottom && store.canDrop(id, on: nil, .into) ? .root : nil
    }

    private func finishDrag(_ id: UUID, at location: CGPoint) {
        let spot = spot(at: location, moving: id)
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragging = nil
            switch spot {
            case let .row(target, placement)?: perform { try store.drop(id, on: target, placement) }
            case .root?: perform { try store.drop(id, on: nil, .into) }
            case nil: break
            }
        }
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

struct SessionTreeRowInteraction: ViewModifier {
    var isFolder = false
    let select: () -> Void
    var toggle: () -> Void = {}
    let activate: () -> Void
    /// Called as a press moves at least a few points, with the pointer in the tree's coordinate space.
    var drag: (CGPoint) -> Void = { _ in }
    /// Called when that drag is released.
    var drop: (CGPoint) -> Void = { _ in }

    func body(content: Content) -> some View {
        taps(content).simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(SessionTreeView.space))
                .onChanged { drag($0.location) }.onEnded { drop($0.location) })
    }

    @ViewBuilder private func taps(_ content: Content) -> some View {
        if isFolder {
            // Folders have no double-click action, so a single click both selects and toggles at once.
            content.onTapGesture { select(); toggle() }
        } else {
            // Selection must not wait for the double-click recognizer to fail.
            content.onTapGesture(count: 2) { select(); activate() }
                .simultaneousGesture(TapGesture().onEnded { select() })
        }
    }
}

enum TreeDropSpot: Equatable {
    case row(UUID, SessionTreeDropPlacement)
    case root
}

struct TreeDragState: Equatable {
    let id: UUID
    var location: CGPoint
    var spot: TreeDropSpot?
}

private struct TreeRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
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
        VStack(alignment: .leading, spacing: 16) {
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
            HStack {
                Button(T("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(T("Save"), action: onSave).buttonStyle(.appProminent).disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct ConnectionEditRequest: Identifiable {
    let id = UUID()
    var item: SessionTreeNode?
    let parent: UUID?
}
