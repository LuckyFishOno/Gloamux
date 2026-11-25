import UniformTypeIdentifiers
import AppKit
import SwiftUI
import FileTransfer

/// What the main window shows in the macOS layout.
enum WorkspaceMode: String, CaseIterable {
    case files, terminal, log

    var title: String {
        switch self {
        case .terminal: return T("Terminal")
        case .files: return T("File Transfer")
        case .log: return T("Session Log")
        }
    }
}

struct WorkspaceModeSwitch: View {
    let mode: WorkspaceMode
    let theme: WorkspaceTheme
    let choose: (WorkspaceMode) -> Void

    var body: some View {
        // Every segment takes the wider title's width, so the switch is symmetric in every language.
        EqualWidthRow(spacing: 2) {
            ForEach(WorkspaceMode.allCases, id: \.self) { segment($0) }
        }
        .padding(2)
        .background(theme.foreground.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }

    private func segment(_ value: WorkspaceMode) -> some View {
        let selected = mode == value
        return Button { if !selected { choose(value) } } label: {
            // The bold title is laid out hidden underneath, so choosing one doesn't change its width.
            ZStack {
                Text(value.title).appFont(.system(size: 12, weight: .semibold)).hidden()
                Text(value.title)
                    .appFont(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(theme.foreground.color.opacity(selected ? 1 : 0.6))
            }
                .lineLimit(1)
                .frame(minWidth: 32)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 5).fill(theme.background.color)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row whose items all take the widest item's ideal width, centered in each slot.
struct EqualWidthRow: Layout {
    var spacing: CGFloat = 0

    private func cell(_ subviews: Subviews) -> CGSize {
        subviews.reduce(.zero) { size, view in
            let ideal = view.sizeThatFits(.unspecified)
            return CGSize(width: max(size.width, ideal.width), height: max(size.height, ideal.height))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cell = cell(subviews)
        let count = CGFloat(subviews.count)
        return CGSize(width: cell.width * count + spacing * max(count - 1, 0), height: cell.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cell(subviews)
        for (index, view) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (cell.width + spacing)
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(cell))
        }
    }
}

/// Which server the two-pane view shows. In the Default layout's main window it follows the selected tab; in the Classic
/// and Workbench layouts' own window it is picked from a menu.
@MainActor final class TransferTarget: ObservableObject {
    let followsSelection: Bool
    @Published var tabID: UUID?
    init(followsSelection: Bool) { self.followsSelection = followsSelection }
}

/// The Classic and Workbench layouts open file transfer in its own window.
@MainActor final class FileTransferWindow: NSWindowController {
    let target = TransferTarget(followsSelection: false)
    let local = LocalBrowserState()

    init(model: WorkspaceModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = T("File Transfer")
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: FileTransferWindowContent(model: model, local: local, target: target).appTextSize())
        if !window.setFrameUsingName("GloamuxFileTransfer") { window.center() }
        window.setFrameAutosaveName("GloamuxFileTransfer")
    }
    required init?(coder: NSCoder) { fatalError("The transfer window requires a workspace.") }

    func select(_ tab: SessionTab?) {
        if let tab { target.tabID = tab.id }
    }
}

private struct FileTransferWindowContent: View {
    @ObservedObject var model: WorkspaceModel
    let local: LocalBrowserState
    let target: TransferTarget
    var body: some View {
        FileTransferView(model: model, local: local, queue: model.transfers, target: target)
            .foregroundStyle(model.theme.foreground.color)
            .tint(model.theme.accent.color)
            .background(ThemeTitlebar(theme: model.theme))
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
    }
}

// MARK: - Browser state

struct LocalItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date
    /// An app or other package, read with the listing so drawing a row does not ask the disk again.
    var isPackage = false
    var id: String { url.path }
    /// The `..` row at the top of a file list.
    var isParent: Bool { name == ".." }
}

@MainActor final class LocalBrowserState: ObservableObject {
    @Published var folder = FileManager.default.homeDirectoryForCurrentUser
    @Published var items: [LocalItem] = []
    @Published var showsHidden = false
    @Published private(set) var loading = false
    @Published var error: String?

    /// Counts navigations, so only the latest one may show its folder, its error, or end the loading state.
    private var generation = 0

    /// Lists the folder away from the main actor: a large folder or a network volume can take a long time to read.
    @discardableResult func load(_ url: URL? = nil) -> Task<Void, Never> {
        let target = (url ?? folder).standardizedFileURL
        let hidden = showsHidden
        generation += 1
        let mine = generation
        loading = true
        return Task { @MainActor [weak self] in
            let listed = await Task.detached(priority: .userInitiated) { Result { try Self.list(target, showsHidden: hidden) } }.value
            guard let self, self.generation == mine else { return }
            self.loading = false
            switch listed {
            case .success(let items): self.items = items; self.folder = target; self.error = nil
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    nonisolated static func list(_ folder: URL, showsHidden: Bool) throws -> [LocalItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                options: showsHidden ? [] : [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return LocalItem(url: url, name: url.lastPathComponent, isDirectory: values.isDirectory == true,
                             size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }
}

struct RemoteItem: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date
    let permissions: UInt32?
    var id: String { path }
    /// The `..` row at the top of a file list.
    var isParent: Bool { name == ".." }
}

@MainActor final class RemoteBrowserState: ObservableObject {
    @Published var folder: String?
    @Published var items: [RemoteItem] = []
    @Published var showsHidden = false
    @Published var loading = false
    @Published var error: String?

    /// Counts navigations, so only the latest one may show its folder, its error, or end the loading state.
    private var generation = 0

    func load(_ path: String?, model: WorkspaceModel, tab: SessionTab) async {
        generation += 1
        let mine = generation
        loading = true
        defer { if generation == mine { loading = false } }
        do {
            let transfer = try await model.sftp(for: tab)
            // A reply from a connection that has since ended or been replaced is dropped, even after it arrives.
            let epoch = tab.epoch
            let directory = try await transfer.readDirectory(path ?? folder ?? tab.remoteFolder ?? ".")
            guard generation == mine, tab.epoch == epoch else { return }
            items = directory.entries.map {
                RemoteItem(path: RemoteTreeState.child(directory.path, $0.name), name: $0.name, isDirectory: $0.isDirectory,
                           size: $0.size ?? 0, modified: $0.modified ?? .distantPast, permissions: $0.permissions)
            }
            folder = directory.path; error = nil
        } catch {
            guard generation == mine else { return }
            self.error = message(for: error)
        }
    }

    /// Forgets the folder and makes every request still under way stale.
    func clear() { generation += 1; folder = nil; items = []; error = nil; loading = false }
}

// MARK: - Two-pane view

/// This Mac on the left and the selected session's server on the right, like WinSCP or FileZilla, with the transfer
/// queue below. It takes the main window's middle area in every layout; the tab bar above picks the server.
struct FileTransferView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var local: LocalBrowserState
    @ObservedObject var queue: TransferQueue
    @ObservedObject var target: TransferTarget
    @State private var localSelection = Set<String>()
    @State private var remoteSelection = Set<String>()
    @State private var pending: PendingTransfer?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                // In the main window the toolbar's switch and the tab bar already say what this is and which server.
                if !target.followsSelection {
                    titleBar
                    Divider()
                }
                HStack(spacing: 0) {
                    LocalFilePane(local: local, selection: $localSelection, upload: { urls in upload(urls) },
                                  download: { paths in download(paths) })
                    transferButtons
                    remotePane
                }
            }
            .frame(minHeight: 260)
            VStack(spacing: 0) {
                RemoteEditsList(model: model, inset: 8)
                TransferQueueView(queue: queue)
            }
            .frame(minHeight: 100, idealHeight: 150)
        }
        .background(model.theme.background.color)
        .onAppear {
            if !openSessionFolder(), local.items.isEmpty { local.load() }
            if !target.followsSelection, target.tabID == nil {
                target.tabID = (model.selected.flatMap { $0.connected && !$0.isLocal ? $0 : nil } ?? model.remoteTabs.first)?.id
            }
        }
        .onChange(of: currentTab?.id) { _, _ in openSessionFolder() }
        .onChange(of: queue.revision) { _, _ in
            local.load()
            if let tab = currentTab { Task { await tab.remoteBrowser.load(nil, model: model, tab: tab) } }
        }
        .alert(T("Replace existing files?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(T("Replace"), role: .destructive) { pending?.start(.replace); pending = nil }
            Button(T("Skip existing")) { pending?.start(.skip); pending = nil }
            Button(T("Cancel"), role: .cancel) { pending = nil }
        } message: { Text(pending.map { $0.conflicts.joined(separator: "\n") } ?? "") }
    }

    /// The server on the right: the selected tab, or a session from its own window that asked to show its files.
    private var currentTab: SessionTab? {
        let tab = target.followsSelection ? model.transferTab : model.remoteTabs.first { $0.id == target.tabID }
        return tab.flatMap { $0.connected && !$0.isLocal ? $0 : nil }
    }

    /// Shows the folder on this Mac that the session was saved with. Returns false when it has none.
    @discardableResult private func openSessionFolder() -> Bool {
        guard let path = currentTab?.localFolder else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        local.load(URL(fileURLWithPath: path, isDirectory: true))
        return true
    }

    /// The transfer window's top row. That window has no tab bar, so the server is chosen here.
    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(model.theme.accent.color)
            Text(T("File Transfer")).appFont(.system(size: 13, weight: .semibold))
            AppPicker(T("Server"), selection: Binding(get: { target.tabID }, set: { target.tabID = $0 }),
                      current: currentTab.map(\.account) ?? T("No connected server")) {
                if currentTab == nil { Text(T("No connected server")).tag(UUID?.none) }
                ForEach(model.remoteTabs, id: \.id) { tab in
                    Text(tab.account + (tab.title != tab.host && tab.title != "New connection" ? "  ·  \(tab.title)" : ""))
                        .tag(Optional(tab.id))
                }
            }
            .labelsHidden().frame(maxWidth: 340)
            Spacer()
            if queue.isActive { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ViewBuilder private var remotePane: some View {
        if let tab = currentTab {
            RemoteFilePane(model: model, tab: tab, remote: tab.remoteBrowser, selection: $remoteSelection,
                           upload: { urls in upload(urls) }, download: { paths in download(paths) })
                .id(tab.id)
        } else {
            ContentUnavailableView(T("No connected server"), systemImage: "network",
                                   description: Text(T(target.followsSelection ? "Select a tab connected over SSH to show its server here."
                                                       : "Connect to a server over SSH, then choose it above.")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transferButtons: some View {
        VStack(spacing: 10) {
            Spacer()
            Button { upload(local.items.filter { localSelection.contains($0.id) }.map(\.url)) } label: {
                Image(systemName: "arrow.right").frame(width: 22, height: 18)
            }
            .help(T("Upload the selected files to the server"))
            .disabled(localSelection.isEmpty || currentTab?.remoteBrowser.folder == nil)
            Button { download((currentTab?.remoteBrowser.items ?? []).filter { remoteSelection.contains($0.id) }.map { ($0.path, $0.isDirectory) }) } label: {
                Image(systemName: "arrow.left").frame(width: 22, height: 18)
            }
            .help(T("Download the selected files to this Mac"))
            .disabled(remoteSelection.isEmpty || currentTab == nil)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(model.theme.sidebar.color.opacity(0.5))
    }

    private func upload(_ urls: [URL]) {
        let urls = urls.filter { !RemoteFileDrag.isOwnCopy($0) }
        guard let tab = currentTab, let folder = tab.remoteBrowser.folder, !urls.isEmpty else { return }
        Task {
            let conflicts = await queue.remoteConflicts(urls.map(\.lastPathComponent), in: folder, via: tab)
            let start: (TransferConflictPolicy) -> Void = { policy in queue.upload(urls, to: folder, via: tab, policy: policy) }
            if conflicts.isEmpty { start(.replace) } else { pending = PendingTransfer(conflicts: conflicts, start: start) }
        }
    }

    private func download(_ paths: [(path: String, isDirectory: Bool)]) {
        guard let tab = currentTab, !paths.isEmpty else { return }
        let folder = local.folder
        let conflicts = TransferQueue.localConflicts(paths.map { ($0.path as NSString).lastPathComponent }, in: folder)
        let start: (TransferConflictPolicy) -> Void = { policy in queue.download(paths, to: folder, via: tab, policy: policy) }
        if conflicts.isEmpty { start(.replace) } else { pending = PendingTransfer(conflicts: conflicts, start: start) }
    }
}

// MARK: - Panes

/// Drag payload for remote rows dropped on the local pane.
enum RemoteFileDrag {
    static let prefix = "gloamux-remote-file:"
    static func payload(_ item: RemoteItem) -> String { prefix + (item.isDirectory ? "d:" : "f:") + item.path }
    static func parse(_ text: String) -> (path: String, isDirectory: Bool)? {
        guard text.hasPrefix(prefix) else { return nil }
        let body = text.dropFirst(prefix.count)
        guard body.count > 2 else { return nil }
        return (String(body.dropFirst(2)), body.hasPrefix("d:"))
    }
}

/// Rows of This Mac dragged onto the server pane. The path travels inside this app only; Finder and other apps
/// still receive the file itself.
enum LocalFileDrag {
    static let prefix = "gloamux-local-file:"
    static func payload(_ url: URL) -> String { prefix + url.path }
    static func parse(_ text: String) -> URL? {
        guard text.hasPrefix(prefix), text.count > prefix.count else { return nil }
        return URL(fileURLWithPath: String(text.dropFirst(prefix.count)))
    }
    static func provider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        provider.registerObject(payload(url) as NSString, visibility: .ownProcess)
        return provider
    }

    /// The local file a drop carries: a row from This Mac, or a file from Finder.
    @MainActor static func files(in providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self),
               let text = await load(NSString.self, from: provider) as? String, let url = parse(text) {
                urls.append(url)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await load(NSURL.self, from: provider) as? URL, url.isFileURL {
                urls.append(url)
            }
        }
        return urls
    }

    private static func load<T: NSItemProviderReading>(_ type: T.Type, from provider: NSItemProvider) async -> Any? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { object, _ in continuation.resume(returning: object) }
        }
    }
}

private struct PaneTitle: View {
    let symbol: String
    let title: String
    var body: some View {
        Label(title, systemImage: symbol).appFont(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
}

private struct LocalFilePane: View {
    @ObservedObject var local: LocalBrowserState
    @Binding var selection: Set<String>
    let upload: ([URL]) -> Void
    let download: ([(path: String, isDirectory: Bool)]) -> Void
    @State private var sortOrder = [KeyPathComparator(\LocalItem.name, comparator: .localizedStandard)]
    @State private var pathDraft = ""
    @State private var naming: LocalNaming?
    @State private var nameDraft = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PaneTitle(symbol: "laptopcomputer", title: T("This Mac"))
                Spacer()
                Toggle(T("Hidden files"), isOn: $local.showsHidden).toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: local.showsHidden) { _, _ in local.load() }
            }
            HStack(spacing: 4) {
                Button { local.load(local.folder.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }
                    .help(T("Parent folder")).disabled(local.folder.path == "/")
                Button { local.load(FileManager.default.homeDirectoryForCurrentUser) } label: { Image(systemName: "house") }
                    .help(T("Home folder"))
                TextField(T("Local folder"), text: $pathDraft).textFieldStyle(.roundedBorder)
                    .onSubmit { local.load(URL(fileURLWithPath: (pathDraft as NSString).expandingTildeInPath)) }
                Button { local.load() } label: { Image(systemName: "arrow.clockwise") }.help(T("Refresh"))
                Button { nameDraft = ""; naming = LocalNaming(rename: nil) } label: { Image(systemName: "folder.badge.plus") }
                    .help(T("New folder…"))
            }
            .buttonStyle(.borderless)
            if let error = local.error { Text(error).appFont(.caption).foregroundStyle(.red).lineLimit(2) }
            Table(of: LocalItem.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(T("Name"), value: \.name, comparator: .localizedStandard) { item in
                    Label { Text(item.name).lineLimit(1) } icon: {
                        // `..` shows a plain folder, like the folders below it.
                        Image(nsImage: item.isParent ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable().frame(width: 16, height: 16)
                    }
                }.width(min: 160, ideal: 260)
                TableColumn(T("Size"), value: \.size) { item in
                    Text(item.isParent ? "" : item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                }.width(min: 60, ideal: 80)
                TableColumn(T("Modified"), value: \.modified) { item in
                    Text(item.isParent ? "" : item.modified.formatted(.dateTime.year().month().day().hour().minute())).foregroundStyle(.secondary)
                }.width(min: 100, ideal: 140)
            } rows: {
                ForEach(sorted) { item in
                    TableRow(item).itemProvider { item.isParent ? nil : LocalFileDrag.provider(item.url) }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let chosen = local.items.filter { ids.contains($0.id) }
                Button(T("Upload")) { upload(chosen.map(\.url)) }.disabled(chosen.isEmpty)
                Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.url)) }.disabled(chosen.isEmpty)
                Button(T("Quick Look")) { QuickLookPreview.shared.show(chosen.filter { !$0.isDirectory }.map(\.url)) }
                    .disabled(!chosen.contains { !$0.isDirectory })
                Divider()
                Button(T("Rename…")) {
                    if let item = chosen.first { nameDraft = item.name; naming = LocalNaming(rename: item) }
                }.disabled(chosen.count != 1)
                Button(T("Move to Trash"), role: .destructive) {
                    for item in chosen { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
                    local.load()
                }.disabled(chosen.isEmpty)
            } primaryAction: { ids in
                guard let item = sorted.first(where: { ids.contains($0.id) }) else { return }
                if item.isDirectory { local.load(item.url) } else { upload([item.url]) }
            }
            .onKeyPress(.space) {
                let files = local.items.filter { selection.contains($0.id) && !$0.isDirectory }.map(\.url)
                guard !files.isEmpty else { return .ignored }
                QuickLookPreview.shared.show(files); return .handled
            }
            .dropDestination(for: String.self) { texts, _ in
                // Remote rows dropped here download into this folder.
                let paths = texts.compactMap(RemoteFileDrag.parse)
                guard !paths.isEmpty else { return false }
                download(paths); return true
            } isTargeted: { dropTargeted = $0 }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
            .overlay { if local.loading && local.items.isEmpty { ProgressView() } }
        }
        .padding(10)
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pathDraft = local.folder.path }
        .onChange(of: local.folder) { _, folder in pathDraft = folder.path; selection = [] }
        .sheet(item: $naming) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text(request.rename == nil ? T("New folder") : T("Rename")).appFont(.headline)
                TextField(T("Name"), text: $nameDraft).onSubmit { finish(request) }
                HStack {
                    Button(T("Cancel")) { naming = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(request.rename == nil ? T("Create") : T("Rename")) { finish(request) }.buttonStyle(.appProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 340)
        }
    }

    /// Folders first in the chosen order, under a `..` row that opens the parent folder, as in WinSCP and FileZilla.
    private var sorted: [LocalItem] {
        let items = local.items.sorted(using: sortOrder).sorted { $0.isDirectory && !$1.isDirectory }
        guard local.folder.path != "/" else { return items }
        let parent = local.folder.deletingLastPathComponent()
        return [LocalItem(url: parent, name: "..", isDirectory: true, size: 0, modified: .distantPast)] + items
    }

    private func finish(_ request: LocalNaming) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        naming = nil
        do {
            if let item = request.rename {
                try FileManager.default.moveItem(at: item.url, to: item.url.deletingLastPathComponent().appendingPathComponent(name))
            } else {
                try FileManager.default.createDirectory(at: local.folder.appendingPathComponent(name), withIntermediateDirectories: false)
            }
        } catch { local.error = error.localizedDescription }
        local.load()
    }
}

private struct LocalNaming: Identifiable {
    let id = UUID()
    let rename: LocalItem?
}

private struct RemoteFilePane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @ObservedObject var remote: RemoteBrowserState
    @Binding var selection: Set<String>
    let upload: ([URL]) -> Void
    let download: ([(path: String, isDirectory: Bool)]) -> Void
    @State private var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)]
    @State private var pathDraft = ""
    @State private var naming: RemoteNaming?
    @State private var nameDraft = ""
    @State private var deleting: [RemoteItem] = []
    @State private var dropTargeted = false
    @State private var permissions: PermissionsRequest?
    @State private var permissionTargets: [(path: String, mode: UInt32?)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PaneTitle(symbol: "server.rack", title: tab.account)
                Spacer()
                Toggle(T("Hidden files"), isOn: $remote.showsHidden).toggleStyle(.checkbox).controlSize(.small)
            }
            HStack(spacing: 4) {
                Button { go((remote.folder.map { ($0 as NSString).deletingLastPathComponent }) ?? "/") } label: { Image(systemName: "arrow.up") }
                    .help(T("Parent folder")).disabled(remote.folder == nil || remote.folder == "/")
                Button { go(".") } label: { Image(systemName: "house") }.help(T("Home folder"))
                TextField(T("Remote directory"), text: $pathDraft).textFieldStyle(.roundedBorder).onSubmit { go(pathDraft) }
                Button { go(nil) } label: { Image(systemName: "arrow.clockwise") }.help(T("Refresh"))
                Button { nameDraft = ""; naming = RemoteNaming(rename: nil) } label: { Image(systemName: "folder.badge.plus") }
                    .help(T("New folder…")).disabled(remote.folder == nil)
            }
            .buttonStyle(.borderless)
            if let error = remote.error { Text(T(error)).appFont(.caption).foregroundStyle(.red).lineLimit(2) }
            Table(of: RemoteItem.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(T("Name"), value: \.name, comparator: .localizedStandard) { item in
                    Label(item.name, systemImage: item.isDirectory || item.isParent ? "folder.fill" : "doc").lineLimit(1)
                }.width(min: 160, ideal: 260)
                TableColumn(T("Size"), value: \.size) { item in
                    Text(item.isParent ? "" : item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                }.width(min: 60, ideal: 80)
                TableColumn(T("Modified"), value: \.modified) { item in
                    Text(item.modified == .distantPast ? "" : item.modified.formatted(.dateTime.year().month().day().hour().minute()))
                        .foregroundStyle(.secondary)
                }.width(min: 100, ideal: 140)
                TableColumn(T("Permissions")) { item in
                    Text(item.permissions.map(Self.mode) ?? "").appFont(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.width(min: 80, ideal: 90)
            } rows: {
                ForEach(sorted) { item in
                    TableRow(item).itemProvider {
                        item.isParent ? nil : RemoteFileDrag.provider(path: item.path, isDirectory: item.isDirectory,
                                                                      payload: RemoteFileDrag.payload(item), tab: tab, model: model)
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let chosen = remote.items.filter { ids.contains($0.id) }
                Button(T("Download")) { download(chosen.map { ($0.path, $0.isDirectory) }) }.disabled(chosen.isEmpty)
                Button(T("Quick Look")) { quickLook(chosen) }.disabled(chosen.count != 1 || chosen.first?.isDirectory != false)
                Button(T("Edit on this Mac")) {
                    if let item = chosen.first { Task { await RemoteEditor.shared.open(item.path, size: item.size, in: tab, model: model) } }
                }.disabled(chosen.count != 1 || chosen.first?.isDirectory != false)
                Divider()
                Button(T("Rename…")) {
                    if let item = chosen.first { nameDraft = item.name; naming = RemoteNaming(rename: item) }
                }.disabled(chosen.count != 1)
                Button(T("Change permissions…")) {
                    permissionTargets = chosen.map { ($0.path, $0.permissions) }
                    permissions = PermissionsRequest(paths: chosen.map(\.path), mode: chosen.first?.permissions ?? 0o644)
                }.disabled(chosen.isEmpty)
                Button(T("Copy path")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(chosen.map(\.path).joined(separator: "\n"), forType: .string)
                }.disabled(chosen.isEmpty)
                Divider()
                Button(T("Delete…"), role: .destructive) { deleting = chosen }.disabled(chosen.isEmpty)
            } primaryAction: { ids in
                guard let item = sorted.first(where: { ids.contains($0.id) }) else { return }
                if item.isDirectory { go(item.path) } else { download([(item.path, false)]) }
            }
            .onKeyPress(.space) {
                let chosen = remote.items.filter { selection.contains($0.id) }
                guard chosen.count == 1, chosen.first?.isDirectory == false else { return .ignored }
                quickLook(chosen); return .handled
            }
            // Files from This Mac or from Finder upload into this folder.
            .onDrop(of: [.plainText, .fileURL], isTargeted: $dropTargeted) { providers in
                Task {
                    let files = await LocalFileDrag.files(in: providers)
                    if !files.isEmpty { upload(files) }
                }
                return true
            }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
            .overlay { if remote.loading && remote.items.isEmpty { ProgressView() } }
        }
        .padding(10)
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: tab.connected) {
            if tab.connected, remote.folder == nil { await remote.load(nil, model: model, tab: tab) }
        }
        .onChange(of: remote.folder) { _, folder in pathDraft = folder ?? ""; selection = [] }
        .onAppear { pathDraft = remote.folder ?? "" }
        .alert(T("Delete from the server?"), isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button(T("Cancel"), role: .cancel) { deleting = [] }
            Button(T("Delete"), role: .destructive) { delete(deleting); deleting = [] }
        } message: { Text(deleting.map(\.path).joined(separator: "\n")) }
        .sheet(item: $permissions) { request in
            PermissionsSheet(request: request) { bits in
                let targets = permissionTargets
                Task {
                    do { try await model.setPermissions(targets, to: bits, in: tab) } catch { remote.error = message(for: error) }
                    await remote.load(nil, model: model, tab: tab)
                }
            }
        }
        .sheet(item: $naming) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text(request.rename == nil ? T("New remote folder") : T("Rename remote item")).appFont(.headline)
                TextField(T("Name"), text: $nameDraft).onSubmit { finish(request) }
                HStack {
                    Button(T("Cancel")) { naming = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(request.rename == nil ? T("Create") : T("Rename")) { finish(request) }.buttonStyle(.appProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 340)
        }
    }

    /// Folders first in the chosen order, under a `..` row that opens the parent folder, as in WinSCP and FileZilla.
    private var sorted: [RemoteItem] {
        let items = remote.items.filter { remote.showsHidden || !$0.name.hasPrefix(".") }
            .sorted(using: sortOrder).sorted { $0.isDirectory && !$1.isDirectory }
        guard let folder = remote.folder, folder != "/" else { return items }
        let parent = (folder as NSString).deletingLastPathComponent
        return [RemoteItem(path: parent.isEmpty ? "/" : parent, name: "..", isDirectory: true, size: 0, modified: .distantPast,
                           permissions: nil)] + items
    }

    /// `rwxr-xr-x` from a POSIX mode.
    static func mode(_ permissions: UInt32) -> String {
        let marks = Array("rwxrwxrwx")
        return (permissions & 0o170000 == 0o040000 ? "d" : "-") + String((0..<9).map { permissions & (1 << (8 - $0)) != 0 ? marks[$0] : "-" })
    }

    private func quickLook(_ items: [RemoteItem]) {
        guard let item = items.first, !item.isDirectory else { return }
        Task { await QuickLookPreview.shared.show(remote: item.path, size: item.size, in: tab, model: model) }
    }

    private func go(_ path: String?) {
        Task { await remote.load(path?.isEmpty == true ? nil : path, model: model, tab: tab) }
    }

    private func delete(_ items: [RemoteItem]) {
        Task {
            do {
                let transfer = try await model.sftp(for: tab)
                for item in items {
                    try await RemoteDelete.remove(item.path, isDirectory: item.isDirectory, with: transfer)
                    model.noteHistory(tab, .deleted, detail: item.path)
                }
            } catch { remote.error = message(for: error) }
            await remote.load(nil, model: model, tab: tab)
        }
    }

    private func finish(_ request: RemoteNaming) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), let folder = remote.folder else { return }
        naming = nil
        Task {
            do {
                let transfer = try await model.sftp(for: tab)
                if let item = request.rename {
                    guard let chosen = FileNameCheck.confirm(original: item.name, chosen: name) else { return }
                    let destination = RemoteTreeState.child(folder, chosen)
                    if try await transfer.entry(at: destination) != nil { throw WorkspaceError.alreadyExists(chosen) }
                    try await transfer.rename(from: item.path, to: destination)
                    model.noteHistory(tab, .renamed, detail: item.path + " → " + destination)
                } else {
                    try await transfer.makeDirectory(RemoteTreeState.child(folder, name))
                    model.noteHistory(tab, .folderCreated, detail: RemoteTreeState.child(folder, name))
                }
            } catch { remote.error = message(for: error) }
            await remote.load(nil, model: model, tab: tab)
        }
    }
}

private struct RemoteNaming: Identifiable {
    let id = UUID()
    let rename: RemoteItem?
}

// MARK: - Queue

struct TransferQueueView: View {
    @ObservedObject var queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(T("Transfers"), systemImage: "arrow.up.arrow.down").appFont(.system(size: 12, weight: .semibold))
                Spacer()
                Button(T("Cancel all")) { queue.cancelAll() }.disabled(!queue.isActive)
                Button(T("Clear finished")) { queue.clearFinished() }.disabled(!queue.items.contains { $0.state.isFinished })
            }
            .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if queue.items.isEmpty {
                Text(T("Drag files between the panes, or use the arrows, to transfer them."))
                    .appFont(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(queue.items.reversed()) { item in TransferRow(item: item, cancel: { queue.cancel(item) }, retry: { queue.retry(item) }) }
                    .listStyle(.plain)
            }
        }
    }
}

private struct TransferRow: View {
    @ObservedObject var item: TransferItem
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(item.direction == .upload ? Color.accentColor : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.isFolder ? "folder" : "doc").foregroundStyle(.secondary).appFont(.caption)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Text(item.direction == .upload ? "→ \(item.host):\(item.destinationFolder)" : "← \(item.host)")
                        .appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if item.state == .running {
                    ProgressView(value: item.fraction ?? 0).controlSize(.small)
                }
            }
            Spacer(minLength: 8)
            // A fixed column keeps the progress bar the same length while the byte counts change.
            Text(detail).appFont(.caption.monospacedDigit()).foregroundStyle(stateColor).lineLimit(1).truncationMode(.middle)
                .frame(width: 190, alignment: .trailing)
                .help(detail)
            if case .failed = item.state {
                Button(action: retry) { Image(systemName: "arrow.clockwise.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(T("Try again"))
            }
            if !item.state.isFinished {
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(T("Cancel"))
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let size = item.total.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }
        switch item.state {
        case .waiting: return T("Waiting")
        case .running:
            let moved = ByteCountFormatter.string(fromByteCount: Int64(clamping: item.bytes), countStyle: .file)
            let files = item.isFolder ? String(format: T("%d of %d files"), item.filesDone, item.fileCount) + " · " : ""
            return files + (size.map { "\(moved) / \($0)" } ?? moved)
        case .done: return T("Done")
        case .skipped: return T("Skipped, already there")
        case .cancelled: return T("Cancelled")
        case .retrying(let seconds): return String(format: T("Connection lost. Trying again in %d s"), seconds)
        case .failed(let reason): return T(reason)
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}
