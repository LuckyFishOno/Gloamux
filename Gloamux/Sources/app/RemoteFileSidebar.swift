import AppKit
import SwiftUI
import FileTransfer

/// The folders of one session's remote file tree: which are open and what each one holds.
@MainActor final class RemoteTreeState: ObservableObject {
    @Published var root: String?
    @Published var children: [String: [RemoteEntry]] = [:]
    @Published var expanded: Set<String> = []
    @Published var loading: Set<String> = []
    @Published var selection: String?
    /// Every selected row, for ⌘-click and ⇧-click; `selection` is the last one clicked.
    @Published var picked: Set<String> = []
    @Published var error: String?

    /// Counts tree openings and resets; a reply from an earlier one is dropped.
    private var generation = 0
    /// The latest request for each folder, so an older reply for the same folder cannot replace a newer one.
    private var requests: [String: Int] = [:]
    private var requestCount = 0

    func reset() {
        generation += 1; requests = [:]
        root = nil; children = [:]; expanded = []; loading = []; selection = nil; picked = []; error = nil
    }

    /// Selects one row, or adds to the selection as Finder does: ⌘ toggles a row, ⇧ selects the rows in between.
    func pick(_ path: String, in rows: [String], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if picked.isEmpty, let selection { picked = [selection] }
            if picked.contains(path) { picked.remove(path) } else { picked.insert(path) }
            selection = path
        } else if modifiers.contains(.shift), let anchor = selection, let from = rows.firstIndex(of: anchor),
                  let to = rows.firstIndex(of: path) {
            picked = Set(rows[min(from, to)...max(from, to)])
        } else {
            selection = path; picked = [path]
        }
    }

    func isPicked(_ path: String) -> Bool { picked.isEmpty ? selection == path : picked.contains(path) }

    static func child(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : (folder as NSString).appendingPathComponent(name)
    }

    /// Opens `path` (the login folder when nil) as the top of the tree.
    func open(_ path: String?, model: WorkspaceModel, tab: SessionTab) async {
        generation += 1
        let mine = generation
        do {
            let transfer = try await model.sftp(for: tab)
            let epoch = tab.epoch
            let resolved = try await transfer.resolve(path ?? ".")
            guard generation == mine, tab.epoch == epoch else { return }
            root = resolved; expanded = []; children = [:]; requests = [:]; loading = []; selection = nil; picked = []; error = nil
            await load(resolved, model: model, tab: tab)
        } catch {
            guard generation == mine else { return }
            self.error = message(for: error)
        }
    }

    /// Lists one folder. Several folders can load at once; each keeps only its latest reply, and replies from before
    /// the tree was opened again, reset, or reconnected are dropped.
    func load(_ folder: String, model: WorkspaceModel, tab: SessionTab) async {
        let tree = generation
        requestCount += 1
        let mine = requestCount
        requests[folder] = mine
        func current() -> Bool { generation == tree && requests[folder] == mine }
        loading.insert(folder)
        defer { if current() { loading.remove(folder); requests[folder] = nil } }
        do {
            let transfer = try await model.sftp(for: tab)
            let epoch = tab.epoch
            let entries = try await transfer.listDirectory(folder)
            guard current(), tab.epoch == epoch else { return }
            children[folder] = entries.sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            error = nil
        } catch {
            guard current() else { return }
            self.error = message(for: error)
        }
    }

    func toggle(_ folder: String, model: WorkspaceModel, tab: SessionTab) async {
        if expanded.contains(folder) { expanded.remove(folder); return }
        expanded.insert(folder)
        if children[folder] == nil { await load(folder, model: model, tab: tab) }
    }

    /// Where the Upload button sends files: the selected folder, the folder of the selected file, or the top folder.
    var uploadFolder: String? {
        guard let root else { return nil }
        guard let selection, selection != root else { return root }
        let parent = (selection as NSString).deletingLastPathComponent
        let name = (selection as NSString).lastPathComponent
        let isFolder = children[parent]?.first { $0.name == name }?.isDirectory ?? false
        return isFolder ? selection : parent
    }

    /// Reloads the top folder and every open folder, dropping ones that no longer exist.
    func refresh(model: WorkspaceModel, tab: SessionTab) async {
        guard let root else { return await open(nil, model: model, tab: tab) }
        for folder in [root] + expanded.sorted() where folder == root || children[folder] != nil || expanded.contains(folder) {
            await load(folder, model: model, tab: tab)
        }
    }
}

/// Removes remote files and folders, emptying folders first.
@MainActor public enum RemoteDelete {
    public static func remove(_ path: String, isDirectory: Bool, with transfer: any RemoteFileSystem) async throws {
        if isDirectory {
            for entry in try await transfer.listDirectory(path) {
                try await remove(RemoteTreeState.child(path, entry.name), isDirectory: entry.isDirectory, with: transfer)
            }
            try await transfer.removeDirectory(path)
        } else {
            try await transfer.removeFile(path)
        }
    }
}

/// Files waiting for the user to choose whether to replace ones with the same name.
struct PendingTransfer: Identifiable {
    let id = UUID()
    let conflicts: [String]
    let start: (TransferConflictPolicy) -> Void
}

/// The Mac layout's right-hand panel: the files of the focused pane as a folder tree. A server pane shows the server's
/// files from its login folder; the local terminal shows this Mac's home folder.
struct RemoteFileSidebar: View {
    @ObservedObject var model: WorkspaceModel
    let close: () -> Void
    /// Bumped by the Upload button; the remote tree answers by asking which files to send.
    @State private var uploadRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                // One line, cut short when the panel is narrow, rather than wrapping.
                Label(T(focusedTab?.isLocal == true ? "Local files" : "Remote files"), systemImage: "folder").appFont(.headline)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                if let tab = focusedTab, !tab.isLocal {
                    SidebarUploadButton(tab: tab, tree: tab.remoteTree) { uploadRequest += 1 }
                }
                Button(action: close) { Image(systemName: "xmark").appFont(.caption.weight(.semibold)).iconHitArea() }
                    .buttonStyle(.plain).help(T("Hide files")).accessibilityLabel(T("Hide files"))
            }
            if let tab = focusedTab {
                if tab.isLocal {
                    LocalTreePanel(model: model, tab: tab, tree: model.localTree, queue: model.transfers)
                } else {
                    RemoteTreePanel(model: model, tab: tab, tree: tab.remoteTree, queue: model.transfers, uploadRequest: uploadRequest)
                        .id(tab.id)
                }
            } else {
                SidebarMessage(title: T("No remote session"), symbol: "network",
                               detail: T("Select a pane connected over SSH to browse its files."))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(model.theme.sidebar.color)
    }

    private var focusedTab: SessionTab? { model.selected }
}

/// "Follow terminal folder" as a button in the sidebar's path bar. While it is on, the tree moves to the folder the
/// focused shell reports after each command; turning it on goes there at once. Remote shells need shell integration,
/// which is turned on for that terminal the first time.
private struct FollowFolderButton: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @State private var followed: String?

    var body: some View {
        Button { tab.followsFolder.toggle() } label: {
            Image(systemName: tab.followsFolder ? "location.fill" : "location")
                .foregroundStyle(tab.followsFolder ? Color.accentColor : Color.primary)
        }
        .help(T(tab.followsFolder ? "Stop following the terminal folder" : "Follow terminal folder") + "\n"
              + T("The file tree moves to the folder the shell is in after each command. Remote shells need shell integration, which Gloamux turns on for this terminal when you check this."))
        .accessibilityLabel(T("Follow terminal folder"))
        .accessibilityAddTraits(tab.followsFolder ? .isSelected : [])
        .accessibilityIdentifier("followTerminalFolderButton")
        .onChange(of: tab.followsFolder) { _, on in if on { hook(); follow(force: true) } }
        .onChange(of: tab.terminalReady) { _, ready in if ready && tab.followsFolder { hook() } }
        .onReceive(tab.output.$revision.dropFirst()) { _ in follow(force: false) }
        .onAppear { if tab.followsFolder { hook(); follow(force: false) } }
    }

    private func hook() {
        guard !tab.isLocal, tab.terminalReady, tab.screen.workingDirectory == nil,
              TerminalFolder.fromTitle(tab.screen.title) == nil else { return }
        model.installShellIntegration(tab)
    }

    /// Moves the tree when the shell has changed folder since the last move. `force` goes there even if it has not,
    /// after the user browsed somewhere else.
    private func follow(force: Bool) {
        guard tab.followsFolder, tab.connected, !tab.busy,
              let folder = TerminalFolder.current(screenDirectory: tab.screen.workingDirectory, title: tab.isLocal ? "" : tab.screen.title),
              force || folder != followed else { return }
        followed = folder
        if tab.isLocal {
            if model.localTree.root != folder { model.localTree.open(folder) }
        } else if tab.remoteTree.root != folder {
            Task { await tab.remoteTree.open(folder, model: model, tab: tab) }
        }
    }
}

/// The labeled Upload button in the file sidebar's title, usable once the server's files are showing.
private struct SidebarUploadButton: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var tree: RemoteTreeState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(T("Upload"), systemImage: "arrow.up.doc").labelStyle(.titleAndIcon).appFont(.system(size: 11)).lineLimit(1)
        }
        .buttonStyle(.app).controlSize(.small)
        .disabled(!tab.connected || tree.root == nil)
        .help(T("Upload files to the selected folder"))
        .accessibilityIdentifier("sidebarUploadButton")
    }
}

private struct RemoteTreePanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @ObservedObject var tree: RemoteTreeState
    @ObservedObject var queue: TransferQueue
    let uploadRequest: Int
    @State private var pathDraft = ""
    @State private var pending: PendingTransfer?
    @State private var naming: NamingRequest?
    @State private var permissions: PermissionsRequest?
    @State private var permissionTargets: [(path: String, mode: UInt32?)] = []
    @State private var nameDraft = ""
    @State private var deleting: RemoteRow?
    @State private var dropTarget: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tab.connected {
                if tab.busy {
                    SidebarLoading(title: T("Connecting…"))
                } else {
                    SidebarMessage(title: T("Connect to browse files"), symbol: "network")
                }
            } else if tree.root == nil, tree.error == nil {
                // The first listing: centered rather than an empty list, which read as a blank panel.
                SidebarLoading(title: T("Loading…"))
            } else {
                header
                treeList
                RemoteEditsList(model: model, tab: tab)
                TransferStatusStrip(queue: queue) { model.openFileTransfer(for: tab) }
            }
        }
        .task(id: tab.connected) {
            if tab.connected, !tab.isLocal, tree.root == nil { await tree.open(nil, model: model, tab: tab) }
        }
        .onChange(of: tree.root) { _, root in pathDraft = root ?? "" }
        .onAppear { pathDraft = tree.root ?? "" }
        .onChange(of: queue.revision) { _, _ in Task { await tree.refresh(model: model, tab: tab) } }
        .onChange(of: uploadRequest) { _, _ in
            guard let folder = tree.uploadFolder else { return }
            DispatchQueue.main.async { chooseUpload(to: folder) }
        }
        .alert(T("Replace existing files?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(T("Replace"), role: .destructive) { pending?.start(.replace); pending = nil }
            Button(T("Skip existing")) { pending?.start(.skip); pending = nil }
            Button(T("Cancel"), role: .cancel) { pending = nil }
        } message: { Text(pending.map { $0.conflicts.joined(separator: "\n") } ?? "") }
        .alert(T("Delete from the server?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(T("Cancel"), role: .cancel) { deleting = nil }
            Button(T("Delete"), role: .destructive) { if let row = deleting { delete(row) }; deleting = nil }
        } message: {
            Text(deleting.map { $0.entry.isDirectory ? String(format: T("%@ and everything in it will be deleted."), $0.path) : $0.path } ?? "")
        }
        .sheet(item: $permissions) { request in
            PermissionsSheet(request: request) { bits in
                let targets = permissionTargets
                Task {
                    do { try await model.setPermissions(targets, to: bits, in: tab) } catch { tree.error = message(for: error) }
                    await tree.refresh(model: model, tab: tab)
                }
            }
        }
        .sheet(item: $naming) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text(request.title).appFont(.headline)
                TextField(T("Name"), text: $nameDraft).onSubmit { finish(request) }
                DialogActions(cancel: { naming = nil }, title: request.confirm, enabled: Self.validName(nameDraft)) { finish(request) }
            }.padding(22).frame(width: 340)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tab.account).appFont(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                Button { openParent() } label: { Image(systemName: "arrow.up").iconHitArea() }
                    .help(T("Parent folder")).disabled(tree.root == nil || tree.root == "/")
                Button { open(nil) } label: { Image(systemName: "house").iconHitArea() }.help(T("Home folder"))
                TextField(T("Remote directory"), text: $pathDraft).textFieldStyle(.roundedBorder).appFont(.system(size: 11))
                    .onSubmit { open(pathDraft) }
                Button { Task { await tree.refresh(model: model, tab: tab) } } label: { Image(systemName: "arrow.clockwise").iconHitArea() }
                    .help(T("Refresh"))
                FollowFolderButton(model: model, tab: tab)
            }
            .buttonStyle(.borderless).controlSize(.small)
            if let error = tree.error {
                Label(T(error), systemImage: "exclamationmark.triangle.fill").appFont(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private var visibleRows: [RemoteRow] { tree.root.map { rows(in: $0, depth: 0) } ?? [] }

    private var treeList: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let root = tree.root {
                        if root != "/" { TreeParentRow { openParent() } }
                        ForEach(visibleRows) { row in rowView(row) }
                        if tree.children[root]?.isEmpty == true {
                            Text(T("This folder is empty")).appFont(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)
            }
            .onChange(of: tree.selection) { _, path in if let path { scroller.scrollTo(path) } }
        }
        .frame(maxHeight: .infinity)
        .focusable().focusEffectDisabled().focused($listFocused)
        .onKeyPress(keys: TreeKeys.keys) { press in
            let keys = TreeKeys(rows: visibleRows.map { ($0.path, $0.entry.isDirectory) }, selection: tree.selection,
                                isExpanded: { tree.expanded.contains($0) })
            guard let action = keys.action(for: press) else { return .ignored }
            perform(action)
            return .handled
        }
        // Only while files are dragged over the list; with no folder open yet both are nil, which tinted it all.
        .background(dropTarget != nil && dropTarget == tree.root ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        // Files dropped from Finder on empty space go to the top folder.
        .dropDestination(for: URL.self) { urls, _ in
            guard let root = tree.root else { return false }
            upload(urls, to: root); return true
        } isTargeted: { dropTarget = $0 ? tree.root : (dropTarget == tree.root ? nil : dropTarget) }
    }

    /// The visible rows under `folder`: each entry, followed by its contents when it is an open folder.
    private func rows(in folder: String, depth: Int) -> [RemoteRow] {
        (tree.children[folder] ?? []).flatMap { entry -> [RemoteRow] in
            let path = RemoteTreeState.child(folder, entry.name)
            let row = RemoteRow(path: path, entry: entry, depth: depth)
            guard entry.isDirectory, tree.expanded.contains(path), depth < 32 else { return [row] }
            return [row] + rows(in: path, depth: depth + 1)
        }
    }

    private func rowView(_ row: RemoteRow) -> some View {
        HStack(spacing: 4) {
            TreeDisclosure(isDirectory: row.entry.isDirectory, expanded: tree.expanded.contains(row.path)) {
                tree.selection = row.path; tree.picked = [row.path]; listFocused = true
                Task { await tree.toggle(row.path, model: model, tab: tab) }
            }
            Image(systemName: row.entry.isDirectory ? "folder.fill" : "doc").appFont(.system(size: 11))
                .foregroundStyle(row.entry.isDirectory ? Color.accentColor : .secondary)
            Text(row.entry.name).appFont(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if tree.loading.contains(row.path) { ProgressView().controlSize(.mini) }
            else if !row.entry.isDirectory, let size = row.entry.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                    .appFont(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12 + 2).padding(.vertical, 3).padding(.trailing, 4)
        .contentShape(Rectangle())
        .background(background(for: row), in: RoundedRectangle(cornerRadius: 4))
        // As in Finder's list view: a click selects, a double-click opens, and the arrow expands in place.
        .onTapGesture(count: 2) { activate(row) }
        .simultaneousGesture(TapGesture().onEnded {
            tree.pick(row.path, in: visibleRows.map(\.path), modifiers: NSEvent.modifierFlags); listFocused = true
        })
        .contextMenu { menu(for: row) }
        .onDrag {
            RemoteFileDrag.provider(path: row.path, isDirectory: row.entry.isDirectory,
                                    payload: RemoteFileDrag.prefix + (row.entry.isDirectory ? "d:" : "f:") + row.path, tab: tab, model: model)
        }
        .modifier(FolderDrop(enabled: row.entry.isDirectory, path: row.path, target: $dropTarget) { urls in upload(urls, to: row.path) })
        .help(row.path)
    }

    private func background(for row: RemoteRow) -> Color {
        if dropTarget == row.path { return Color.accentColor.opacity(0.22) }
        return tree.isPicked(row.path) ? Color.accentColor.opacity(0.14) : .clear
    }

    @ViewBuilder private func menu(for row: RemoteRow) -> some View {
        let folder = row.entry.isDirectory ? row.path : (row.path as NSString).deletingLastPathComponent
        if row.entry.isDirectory {
            Button(T("Open")) { open(row.path) }
            Button(T(tree.expanded.contains(row.path) ? "Collapse" : "Expand")) {
                Task { await tree.toggle(row.path, model: model, tab: tab) }
            }
            Button(T("Upload files here…")) { chooseUpload(to: row.path) }
        }
        if !row.entry.isDirectory {
            Button(T("Quick Look")) { Task { await QuickLookPreview.shared.show(remote: row.path, size: row.entry.size, in: tab, model: model) } }
            Button(T("Edit on this Mac")) { Task { await RemoteEditor.shared.open(row.path, size: row.entry.size, in: tab, model: model) } }
        }
        // A right-click on one of several selected rows acts on all of them, as in Finder.
        let group = tree.picked.count > 1 && tree.picked.contains(row.path) ? visibleRows.filter { tree.picked.contains($0.path) } : [row]
        Button(group.count > 1 ? String(format: T("Download %d items…"), group.count) : T("Download…")) { chooseDownload(group) }
        Divider()
        Button(T("New folder…")) { nameDraft = ""; naming = NamingRequest(kind: .folder(in: folder)) }
        Button(T("Rename…")) { nameDraft = row.entry.name; naming = NamingRequest(kind: .rename(row.path)) }
        Button(T("Change permissions…")) {
            permissions = PermissionsRequest(paths: group.map(\.path), mode: row.entry.permissions ?? 0o644)
            permissionTargets = group.map { ($0.path, $0.entry.permissions) }
        }
        Button(T("Copy path")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.path, forType: .string)
        }
        Divider()
        Button(T("Delete…"), role: .destructive) { deleting = row }
    }

    private func activate(_ row: RemoteRow) {
        if row.entry.isDirectory { open(row.path) } else { tree.selection = row.path; tree.picked = [row.path]; chooseDownload([row]) }
    }

    private func open(_ path: String?) {
        Task { await tree.open(path?.isEmpty == true ? nil : path, model: model, tab: tab) }
    }

    /// Goes up a level with the folder just left selected, so the way back is one double-click.
    private func openParent() {
        guard let root = tree.root, root != "/" else { return }
        Task {
            await tree.open((root as NSString).deletingLastPathComponent, model: model, tab: tab)
            tree.selection = root
        }
    }

    private func perform(_ action: TreeKeys.Action) {
        let rows = visibleRows
        switch action {
        case .select(let path): tree.selection = path; tree.picked = [path]
        case .toggle(let path): Task { await tree.toggle(path, model: model, tab: tab) }
        case .parent: openParent()
        case .open(let path):
            if let row = rows.first(where: { $0.path == path }) { activate(row) }
        case .preview(let path):
            if let row = rows.first(where: { $0.path == path }), !row.entry.isDirectory {
                Task { await QuickLookPreview.shared.show(remote: row.path, size: row.entry.size, in: tab, model: model) }
            }
        }
    }

    /// Asks which Mac files and folders to send; several can be chosen at once.
    private func chooseUpload(to folder: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = T("Upload")
        panel.message = String(format: T("Upload to %@"), folder)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { upload(panel.urls, to: folder) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    /// Asks for a Mac folder, then queues every chosen file and folder into it.
    private func chooseDownload(_ rows: [RemoteRow]) {
        guard !rows.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = T("Download here")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            let conflicts = TransferQueue.localConflicts(rows.map(\.entry.name), in: folder)
            var sizes: [String: UInt64] = [:]
            for row in rows where !row.entry.isDirectory { sizes[row.path] = row.entry.size }
            let start: (TransferConflictPolicy) -> Void = { policy in
                queue.download(rows.map { ($0.path, $0.entry.isDirectory) }, to: folder, via: tab, policy: policy, sizes: sizes)
            }
            if conflicts.isEmpty { start(.replace) } else { pending = PendingTransfer(conflicts: conflicts, start: start) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    private func upload(_ urls: [URL], to folder: String) {
        let files = urls.filter { $0.isFileURL && !RemoteFileDrag.isOwnCopy($0) }
        guard !files.isEmpty else { return }
        Task {
            let conflicts = await queue.remoteConflicts(files.map(\.lastPathComponent), in: folder, via: tab)
            let start: (TransferConflictPolicy) -> Void = { policy in queue.upload(files, to: folder, via: tab, policy: policy) }
            if conflicts.isEmpty { start(.replace) } else { pending = PendingTransfer(conflicts: conflicts, start: start) }
            if !tree.expanded.contains(folder), folder != tree.root { tree.expanded.insert(folder) }
        }
    }

    private func delete(_ row: RemoteRow) {
        Task {
            do {
                try await RemoteDelete.remove(row.path, isDirectory: row.entry.isDirectory, with: model.sftp(for: tab))
                model.noteHistory(tab, .deleted, detail: row.path)
                if tree.selection == row.path { tree.selection = nil }
                tree.expanded.remove(row.path)
            } catch { tree.error = message(for: error) }
            await tree.refresh(model: model, tab: tab)
        }
    }

    private func finish(_ request: NamingRequest) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { return }
        naming = nil
        Task {
            do {
                let transfer = try await model.sftp(for: tab)
                switch request.kind {
                case .folder(let parent):
                    try await transfer.makeDirectory(RemoteTreeState.child(parent, name))
                    model.noteHistory(tab, .folderCreated, detail: RemoteTreeState.child(parent, name))
                    if parent != tree.root { tree.expanded.insert(parent) }
                case .rename(let path):
                    guard let chosen = FileNameCheck.confirm(original: (path as NSString).lastPathComponent, chosen: name) else { return }
                    let destination = RemoteTreeState.child((path as NSString).deletingLastPathComponent, chosen)
                    if try await transfer.entry(at: destination) != nil { throw WorkspaceError.alreadyExists(chosen) }
                    try await transfer.rename(from: path, to: destination)
                    model.noteHistory(tab, .renamed, detail: path + " → " + destination)
                }
            } catch { tree.error = message(for: error) }
            await tree.refresh(model: model, tab: tab)
        }
    }

    static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/") && !trimmed.contains("\0")
    }
}

private struct RemoteRow: Identifiable {
    let path: String
    let entry: RemoteEntry
    let depth: Int
    var id: String { path }
}

private struct NamingRequest: Identifiable {
    enum Kind { case folder(in: String), rename(String) }
    let id = UUID()
    let kind: Kind
    var title: String {
        switch kind { case .folder: return T("New remote folder"); case .rename: return T("Rename remote item") }
    }
    var confirm: String {
        switch kind { case .folder: return T("Create"); case .rename: return T("Rename") }
    }
}

/// Lets Finder files be dropped on a folder row, which highlights while they hover.
private struct FolderDrop: ViewModifier {
    let enabled: Bool
    let path: String
    @Binding var target: String?
    let drop: ([URL]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in drop(urls); return true } isTargeted: { hovering in
                if hovering { target = path } else if target == path { target = nil }
            }
        } else { content }
    }
}

/// Each transfer on its own row, newest at the top and oldest at the bottom: rows slide in from the top, and a
/// finished row stays a few seconds, without a progress bar, before it slides out at the bottom. A click opens the
/// transfer window.
struct TransferStatusStrip: View {
    @ObservedObject var queue: TransferQueue
    let openQueue: () -> Void
    /// How long a finished row stays.
    static let linger: TimeInterval = 10
    /// Rows shown at once. A sixth row pushes the oldest out at the bottom; the queue window still lists it.
    static let limit = 5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let shown = Self.shown(Self.visible(queue.items, at: context.date))
            VStack(spacing: 6) {
                ForEach(shown) { item in
                    TransferRow(item: item, now: context.date, openQueue: openQueue)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .move(edge: .bottom).combined(with: .opacity)))
                }
            }
            // Not clipped: a row leaving slides down out of the list instead of being cut off as the list shrinks.
            .animation(.easeInOut(duration: 0.3), value: shown.map(\.id))
        }
    }

    /// The newest `limit` rows, newest first, so they enter at the top and the oldest leaves at the bottom.
    static func shown(_ visible: [TransferItem]) -> [TransferItem] {
        Array(visible.suffix(limit).reversed())
    }

    /// Unfinished items and ones that ended under `linger` seconds ago, oldest first.
    static func visible(_ items: [TransferItem], at now: Date) -> [TransferItem] {
        items.filter { item in
            guard item.state.isFinished else { return true }
            guard let finished = item.finished else { return false }
            return now.timeIntervalSince(finished) < linger
        }
    }
}

private struct TransferRow: View {
    @ObservedObject var item: TransferItem
    let now: Date
    let openQueue: () -> Void

    var body: some View {
        Button(action: openQueue) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).foregroundStyle(tint)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.appFont(.system(size: 11))
                // Only a running transfer has a bar, so a finished one never looks stuck near the end.
                if item.state == .running {
                    let total = item.size ?? 0
                    ProgressView(value: total > 0 ? min(1, Double(item.bytes) / Double(total)) : 0).controlSize(.small)
                }
                Text(detail).appFont(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(T("Show transfers"))
    }

    private var symbol: String {
        switch item.state {
        case .waiting: return "clock"
        case .running: return item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .retrying: return "arrow.clockwise.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var detail: String {
        switch item.state {
        case .waiting: return T("Waiting")
        case .running:
            return TransferFigures.line(done: item.bytes, total: item.size ?? item.bytes,
                                        elapsed: now.timeIntervalSince(item.started ?? now), unknown: item.size == nil)
        case .done: return TransferFigures.finished
        case .failed(let reason): return T(reason)
        case .retrying(let seconds): return String(format: T("Connection lost. Trying again in %d s"), seconds)
        case .skipped: return T("Skipped: already there")
        case .cancelled: return T("Cancelled")
        }
    }
}

/// "45% · 1 min 20 s left · 12 MB of 40 MB left" for the transfer strip.
enum TransferFigures {
    static func line(done: UInt64, total: UInt64, elapsed: TimeInterval, unknown: Bool) -> String {
        guard total > 0 else { return T("Preparing…") }
        let percent = Int((Double(min(done, total)) / Double(total) * 100).rounded(.down))
        let left = total - min(done, total)
        var parts = [unknown ? "\(percent)%+" : "\(percent)%"]
        // The average speed so far; the first two seconds are too short to say.
        if elapsed >= 2, done > 0, !unknown {
            parts.append(String(format: T("%@ left"), duration(Double(left) / (Double(done) / elapsed))))
        }
        parts.append(String(format: T("%@ of %@ left"), bytes(left), bytes(total)))
        return parts.joined(separator: " · ")
    }

    /// "Done" once a transfer has ended.
    static let finished = T("Done")

    static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        if value < 60 { return String(format: T("%d s"), value) }
        if value < 3600 { return String(format: T("%d min %d s"), value / 60, value % 60) }
        return String(format: T("%d h %d min"), value / 3600, value % 3600 / 60)
    }

    static func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file) }
}

/// This Mac's files for the sidebar, opened at the home folder like a server opens at its login folder.
@MainActor final class LocalTreeState: ObservableObject {
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    @Published var children: [String: [LocalItem]] = [:]
    @Published var expanded: Set<String> = []
    @Published var selection: String?
    @Published var error: String?

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path }

    static func child(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : (folder as NSString).appendingPathComponent(name)
    }

    func open(_ path: String) {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = String(format: T("%@ is not a folder."), target); return
        }
        root = target; children = [:]; expanded = []; selection = nil
        load(target)
    }

    func load(_ folder: String) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])
            children[folder] = urls.compactMap { url -> LocalItem? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                // Apps and other packages open like files; a link to a folder opens like the folder.
                var isFolder = values.isDirectory == true && values.isPackage != true
                if values.isSymbolicLink == true, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
                    isFolder = target.isDirectory == true && target.isPackage != true
                }
                return LocalItem(url: url, name: url.lastPathComponent, isDirectory: isFolder,
                                 size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast,
                                 isPackage: values.isPackage == true)
            }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func toggle(_ folder: String) {
        if expanded.contains(folder) { expanded.remove(folder); return }
        expanded.insert(folder)
        if children[folder] == nil { load(folder) }
    }

    func refresh() {
        for folder in [root] + expanded.sorted() where folder == root || children[folder] != nil { load(folder) }
    }
}

/// The local terminal's view of the sidebar: this Mac's folders, starting at home.
private struct LocalTreePanel: View {
    /// Only for actions; the panel redraws when its tab, folders, or transfers change, not with every workspace change.
    let model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @ObservedObject var tree: LocalTreeState
    @ObservedObject var queue: TransferQueue
    @State private var pathDraft = ""
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if tree.root != "/" { TreeParentRow { openParent() } }
                        ForEach(visibleRows) { row in rowView(row) }
                        if tree.children[tree.root]?.isEmpty == true {
                            Text(T("This folder is empty")).appFont(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
                }
                .onChange(of: tree.selection) { _, path in if let path { scroller.scrollTo(path) } }
            }
            .frame(maxHeight: .infinity)
            .focusable().focusEffectDisabled().focused($listFocused)
            .onKeyPress(keys: TreeKeys.keys) { press in
                let keys = TreeKeys(rows: visibleRows.map { ($0.path, $0.item.isDirectory) }, selection: tree.selection,
                                    isExpanded: { tree.expanded.contains($0) })
                guard let action = keys.action(for: press) else { return .ignored }
                perform(action)
                return .handled
            }
            TransferStatusStrip(queue: queue) { model.openFileTransfer(for: nil) }
        }
        .onAppear {
            if tree.children[tree.root] == nil { tree.load(tree.root) }
            pathDraft = Self.display(tree.root)
        }
        .onChange(of: tree.root) { _, root in pathDraft = Self.display(root) }
        // Downloads land on this Mac, so a finished transfer can change what these folders hold.
        .onChange(of: queue.revision) { _, _ in tree.refresh() }
    }

    private static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { openParent() } label: { Image(systemName: "arrow.up").iconHitArea() }
                    .help(T("Parent folder")).disabled(tree.root == "/")
                Button { tree.open(LocalTreeState.home) } label: { Image(systemName: "house").iconHitArea() }.help(T("Home folder"))
                TextField(T("Local folder"), text: $pathDraft).textFieldStyle(.roundedBorder).appFont(.system(size: 11))
                    .onSubmit { tree.open(pathDraft.isEmpty ? LocalTreeState.home : pathDraft) }
                Button { tree.refresh() } label: { Image(systemName: "arrow.clockwise").iconHitArea() }.help(T("Refresh"))
                FollowFolderButton(model: model, tab: tab)
            }
            .buttonStyle(.borderless).controlSize(.small)
            if let error = tree.error {
                Label(T(error), systemImage: "exclamationmark.triangle.fill").appFont(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private var visibleRows: [LocalRow] { rows(in: tree.root, depth: 0) }

    /// Goes up a level with the folder just left selected, so the way back is one double-click.
    private func openParent() {
        let root = tree.root
        guard root != "/" else { return }
        tree.open((root as NSString).deletingLastPathComponent)
        tree.selection = root
    }

    private func activate(_ row: LocalRow) {
        if row.item.isDirectory { tree.open(row.path) } else { NSWorkspace.shared.open(URL(fileURLWithPath: row.path)) }
    }

    private func perform(_ action: TreeKeys.Action) {
        switch action {
        case .select(let path): tree.selection = path
        case .toggle(let path): tree.toggle(path)
        case .parent: openParent()
        case .open(let path):
            if let row = visibleRows.first(where: { $0.path == path }) { activate(row) }
        case .preview(let path):
            if visibleRows.first(where: { $0.path == path })?.item.isDirectory == false {
                QuickLookPreview.shared.show([URL(fileURLWithPath: path)])
            }
        }
    }

    private func rows(in folder: String, depth: Int) -> [LocalRow] {
        (tree.children[folder] ?? []).flatMap { item -> [LocalRow] in
            let row = LocalRow(path: LocalTreeState.child(folder, item.name), item: item, depth: depth)
            guard item.isDirectory, tree.expanded.contains(row.path), depth < 32 else { return [row] }
            return [row] + rows(in: row.path, depth: depth + 1)
        }
    }

    private func rowView(_ row: LocalRow) -> some View {
        HStack(spacing: 4) {
            TreeDisclosure(isDirectory: row.item.isDirectory, expanded: tree.expanded.contains(row.path)) {
                tree.selection = row.path; listFocused = true
                tree.toggle(row.path)
            }
            let isPackage = !row.item.isDirectory && row.item.isPackage
            // Apps and other packages show their own icon, as in Finder.
            if isPackage {
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.path)).resizable().frame(width: 14, height: 14)
            } else {
                Image(systemName: row.item.isDirectory ? "folder.fill" : "doc").appFont(.system(size: 11))
                    .foregroundStyle(row.item.isDirectory ? Color.accentColor : .secondary)
            }
            Text(row.item.name).appFont(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            // Packages have no single size to show, as in Finder.
            if !row.item.isDirectory, !isPackage {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: row.item.size), countStyle: .file))
                    .appFont(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12 + 2).padding(.vertical, 3).padding(.trailing, 4)
        .contentShape(Rectangle())
        .background(tree.selection == row.path ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
        // As in Finder's list view: a click selects, a double-click opens, and the arrow expands in place.
        .onTapGesture(count: 2) { activate(row) }
        .simultaneousGesture(TapGesture().onEnded { tree.selection = row.path; listFocused = true })
        // Dragging a file out hands Finder, other apps, or a terminal pane the file itself.
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: row.path)) ?? NSItemProvider() }
        .contextMenu {
            if row.item.isDirectory {
                Button(T("Open")) { tree.open(row.path) }
                Button(T(tree.expanded.contains(row.path) ? "Collapse" : "Expand")) { tree.toggle(row.path) }
            } else {
                Button(T("Open")) { NSWorkspace.shared.open(URL(fileURLWithPath: row.path)) }
                Button(T("Quick Look")) { QuickLookPreview.shared.show([URL(fileURLWithPath: row.path)]) }
            }
            Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
            Button(T("Copy path")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.path, forType: .string)
            }
        }
        .help(row.path)
    }
}

private struct LocalRow: Identifiable {
    let path: String
    let item: LocalItem
    let depth: Int
    var id: String { path }
}

/// A folder's expand arrow, clicked on its own so the rest of the row can select and open.
private struct TreeDisclosure: View {
    let isDirectory: Bool
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        if isDirectory {
            Image(systemName: "chevron.right").appFont(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0)).animation(.easeOut(duration: 0.12), value: expanded)
                .frame(width: 16, height: 18).contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .help(T(expanded ? "Collapse" : "Expand"))
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(T(expanded ? "Collapse" : "Expand"))
        } else { Color.clear.frame(width: 16, height: 1) }
    }
}

/// Finder's list-view keys for a sidebar tree: ↑ and ↓ move, → expands, ← collapses or moves to the enclosing folder,
/// Return or ⌘↓ opens, ⌘↑ goes to the parent folder, and Space previews a file.
struct TreeKeys {
    enum Action: Equatable { case select(String), toggle(String), open(String), parent, preview(String) }

    static let keys: Set<KeyEquivalent> = [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space]

    let rows: [(path: String, isDirectory: Bool)]
    let selection: String?
    let isExpanded: (String) -> Bool

    func action(for press: KeyPress) -> Action? { action(for: press.key, command: press.modifiers.contains(.command)) }

    func action(for key: KeyEquivalent, command: Bool) -> Action? {
        let index = rows.firstIndex { $0.path == selection }
        let current = index.map { rows[$0] }
        switch key {
        case .upArrow where command: return .parent
        case .downArrow where command, .return: return current.map { .open($0.path) }
        case .upArrow:
            guard !rows.isEmpty else { return nil }
            return .select(rows[max((index ?? rows.count) - 1, 0)].path)
        case .downArrow:
            guard !rows.isEmpty else { return nil }
            return .select(rows[index.map { min($0 + 1, rows.count - 1) } ?? 0].path)
        case .rightArrow:
            guard let current, let index, current.isDirectory else { return nil }
            if !isExpanded(current.path) { return .toggle(current.path) }
            let next = index + 1
            return next < rows.count && rows[next].path.hasPrefix(current.path + "/") ? .select(rows[next].path) : nil
        case .leftArrow:
            guard let current else { return nil }
            if current.isDirectory, isExpanded(current.path) { return .toggle(current.path) }
            let parent = (current.path as NSString).deletingLastPathComponent
            return rows.contains { $0.path == parent } ? .select(parent) : nil
        case .space: return current.flatMap { $0.isDirectory ? nil : .preview($0.path) }
        default: return nil
        }
    }
}

/// The `..` row at the top of a sidebar tree: a double-click opens the parent folder, like any other folder.
private struct TreeParentRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 16, height: 1)
            Image(systemName: "folder.fill").appFont(.system(size: 11)).foregroundStyle(Color.accentColor)
            Text("..").appFont(.system(size: 12))
            Spacer(minLength: 4)
        }
        .padding(.leading, 2).padding(.vertical, 3).padding(.trailing, 4)
        .contentShape(Rectangle())
        .background(hovering ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: action)
        .help(T("Parent folder"))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(T("Parent folder"))
    }
}

/// A spinner and a word, centered in the files panel while a session connects or its first folder loads.
/// A message in the middle of the file sidebar, both ways. `ContentUnavailableView` kept its own width inside the
/// sidebar's leading stack, so it sat left of center, and its insets pushed it below the middle.
private struct SidebarMessage: View {
    let title: String
    let symbol: String
    var detail: String?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).appFont(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).appFont(.headline).multilineTextAlignment(.center)
            if let detail {
                Text(detail).appFont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarLoading: View {
    let title: String
    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).appFont(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
