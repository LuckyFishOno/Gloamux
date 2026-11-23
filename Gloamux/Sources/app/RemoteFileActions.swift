import AppKit
import FileTransfer
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dragging remote files to Finder

extension RemoteFileDrag {
    /// Where files dragged out of a server are copied before Finder takes them.
    static var dragFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Gloamux-Drag", isDirectory: true) }

    /// A drag of a remote file or folder. Gloamux's own panes read the path; Finder and other apps get a file that is
    /// copied from the server when the drop lands.
    @MainActor static func provider(path: String, isDirectory: Bool, payload: String, tab: SessionTab, model: WorkspaceModel) -> NSItemProvider {
        let provider = NSItemProvider(object: payload as NSString)
        let name = (path as NSString).lastPathComponent
        provider.suggestedName = name
        let type = isDirectory ? UTType.folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak tab, weak model] done in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                guard let tab, let model else { done(nil, false, WorkspaceError.disconnected); return }
                do {
                    let copy = try await fetch(path, isDirectory: isDirectory, tab: tab, model: model)
                    progress.completedUnitCount = 1
                    done(copy, false, nil)
                } catch {
                    model.error = message(for: error)
                    done(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    /// Copies a remote file or folder into a new private folder and returns the copy.
    @MainActor static func fetch(_ path: String, isDirectory: Bool, tab: SessionTab, model: WorkspaceModel) async throws -> URL {
        let folder = dragFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let transfer = try await model.sftp(for: tab)
        let name = (path as NSString).lastPathComponent
        let target = folder.appendingPathComponent(name.isEmpty ? "file" : name, isDirectory: isDirectory)
        try await copy(path, isDirectory: isDirectory, to: target, transfer, depth: 0)
        return target
    }

    private static func copy(_ path: String, isDirectory: Bool, to target: URL, _ transfer: any RemoteFileSystem, depth: Int) async throws {
        guard isDirectory else { try await transfer.download(remotePath: path, to: target); return }
        guard depth < 32 else { throw WorkspaceError.invalid("The folder is nested too deeply to copy.") }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for entry in try await transfer.listDirectory(path) {
            try Task.checkCancellation()
            try await copy(RemoteTreeState.child(path, entry.name), isDirectory: entry.isDirectory,
                           to: target.appendingPathComponent(entry.name, isDirectory: entry.isDirectory), transfer, depth: depth + 1)
        }
    }

    /// A file Gloamux itself copied for a drag. Dropping it back on a server pane would only copy it in a circle.
    static func isOwnCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(dragFolder.standardizedFileURL.path + "/")
    }

    nonisolated static func removeAll() { try? FileManager.default.removeItem(at: dragFolder) }
}

// MARK: - Permissions

struct PermissionsRequest: Identifiable {
    let id = UUID()
    let paths: [String]
    /// The current mode of the first item, including the file type bits.
    let mode: UInt32
}

/// Read, write, and execute for the owner, the group, and everyone else, with the octal value beside them.
struct PermissionsSheet: View {
    let request: PermissionsRequest
    let apply: (UInt32) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bits: UInt32
    @State private var octal: String

    init(request: PermissionsRequest, apply: @escaping (UInt32) -> Void) {
        self.request = request; self.apply = apply
        let bits = request.mode & 0o777
        _bits = State(initialValue: bits)
        _octal = State(initialValue: String(format: "%03o", bits))
    }

    private static let classes: [(String, UInt32)] = [("Owner", 6), ("Group", 3), ("Everyone", 0)]
    private static let rights: [(String, UInt32)] = [("Read", 4), ("Write", 2), ("Execute", 1)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T("Permissions")).appFont(.headline)
            Text(request.paths.count == 1 ? request.paths[0] : String(format: T("%d items"), request.paths.count))
                .appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(Self.rights, id: \.0) { right in Text(T(right.0)).appFont(.caption).foregroundStyle(.secondary) }
                }
                ForEach(Self.classes, id: \.0) { owner in
                    GridRow {
                        Text(T(owner.0))
                        ForEach(Self.rights, id: \.0) { right in
                            Toggle("", isOn: binding(right.1 << owner.1)).toggleStyle(.checkbox).labelsHidden()
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text(T("Octal"))
                TextField("", text: $octal).appFont(.system(.body, design: .monospaced)).frame(width: 60)
                    .onChange(of: octal) { _, text in if let value = UInt32(text, radix: 8), value <= 0o777, text.count == 3 { bits = value } }
                Text(PermissionsSheet.symbolic(bits)).appFont(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Button(T("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(T("Apply")) { apply(bits); dismiss() }.buttonStyle(.appProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 340)
    }

    private func binding(_ bit: UInt32) -> Binding<Bool> {
        Binding(get: { bits & bit != 0 }, set: { on in
            bits = on ? bits | bit : bits & ~bit
            octal = String(format: "%03o", bits)
        })
    }

    /// `rwxr-x---` for the nine permission bits.
    static func symbolic(_ bits: UInt32) -> String {
        let marks = Array("rwxrwxrwx")
        return String((0..<9).map { bits & (1 << (8 - $0)) != 0 ? marks[$0] : "-" })
    }

    /// The mode to set: the chosen bits, keeping the setuid, setgid, and sticky bits the item already has.
    static func mode(_ chosen: UInt32, keeping current: UInt32?) -> UInt32 { (current ?? 0) & 0o7000 | chosen & 0o777 }
}

extension WorkspaceModel {
    /// Sets the permission bits of remote items; each keeps its own special bits.
    func setPermissions(_ items: [(path: String, mode: UInt32?)], to bits: UInt32, in tab: SessionTab) async throws {
        let transfer = try await sftp(for: tab)
        for item in items {
            try await transfer.setPermissions(item.path, mode: PermissionsSheet.mode(bits, keeping: item.mode))
        }
    }
}

// MARK: - Editing remote files

/// A remote file opened in a Mac app. Saving it there marks it changed; Gloamux uploads it only when asked, after
/// checking that nobody changed the server's copy in the meantime.
@MainActor final class RemoteEdit: ObservableObject, Identifiable {
    let id = UUID()
    let remotePath: String
    let localURL: URL
    weak var tab: SessionTab?
    let host: String
    /// The server's copy as last downloaded or uploaded, to notice changes made by someone else.
    var remoteSize: UInt64?
    var remoteModified: Date?
    var permissions: UInt32?
    /// The Mac copy's modification time when it last matched the server.
    var syncedAt: Date?
    @Published var changed = false
    @Published var uploading = false
    @Published var error: String?

    init(remotePath: String, localURL: URL, tab: SessionTab, entry: RemoteEntry?) {
        self.remotePath = remotePath; self.localURL = localURL; self.tab = tab; host = tab.host
        remoteSize = entry?.size; remoteModified = entry?.modified; permissions = entry?.permissions
        syncedAt = Self.modified(localURL)
    }

    var name: String { localURL.lastPathComponent }

    nonisolated static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Whether the server's copy differs from the one this edit started from.
    func serverChanged(_ entry: RemoteEntry?) -> Bool {
        guard let entry else { return true }
        return entry.size != remoteSize || entry.modified != remoteModified
    }
}

@MainActor final class RemoteEditor: ObservableObject {
    static let shared = RemoteEditor()
    @Published private(set) var edits: [RemoteEdit] = []
    private var watcher: Timer?

    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Gloamux-Edit", isDirectory: true) }
    /// Larger files are not opened for editing.
    static let limit: UInt64 = 100 * 1024 * 1024

    /// Downloads a remote file and opens it in the Mac's default app for its type, or TextEdit when there is none.
    func open(_ path: String, size: UInt64?, in tab: SessionTab, model: WorkspaceModel, launches: Bool = true) async {
        if let edit = edits.first(where: { $0.remotePath == path && $0.tab === tab }) {
            if launches { NSWorkspace.shared.open(edit.localURL) }
            return
        }
        if let size, size > Self.limit { model.error = "Files up to 100 MB can be edited. Download larger files instead."; return }
        do {
            let transfer = try await model.sftp(for: tab)
            let entry = try await transfer.entry(at: path)
            if let size = entry?.size, size > Self.limit { throw WorkspaceError.invalid("Files up to 100 MB can be edited. Download larger files instead.") }
            let folder = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = (path as NSString).lastPathComponent
            let local = folder.appendingPathComponent(name.isEmpty ? "file" : name)
            try await transfer.download(remotePath: path, to: local)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
            let edit = RemoteEdit(remotePath: path, localURL: local, tab: tab, entry: entry)
            edits.append(edit)
            watch()
            if launches { Self.launch(local) }
        } catch { model.error = message(for: error) }
    }

    private static func launch(_ url: URL) {
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil { NSWorkspace.shared.open(url); return }
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Notices saves in the other app. A timer rather than a file watch, as many editors save by replacing the file.
    private func watch() {
        guard watcher == nil else { return }
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { RemoteEditor.shared.check() }
        }
    }

    func check() {
        for edit in edits where !edit.uploading {
            let now = RemoteEdit.modified(edit.localURL)
            if now != nil, now != edit.syncedAt, !edit.changed { edit.changed = true }
        }
        if edits.isEmpty { watcher?.invalidate(); watcher = nil }
    }

    /// Uploads the edited copy. When the server's file changed since it was opened, `confirm` decides whether to
    /// replace it anyway.
    func upload(_ edit: RemoteEdit, model: WorkspaceModel, confirm: @MainActor (RemoteEdit) async -> Bool) async {
        guard let tab = edit.tab, !edit.uploading else { return }
        edit.uploading = true; edit.error = nil
        defer { edit.uploading = false }
        do {
            let transfer = try await model.sftp(for: tab)
            let current = try await transfer.entry(at: edit.remotePath)
            if edit.serverChanged(current) {
                guard await confirm(edit) else { return }
            }
            let stamp = RemoteEdit.modified(edit.localURL)
            let folder = (edit.remotePath as NSString).deletingLastPathComponent
            let partial = RemoteTreeState.child(folder.isEmpty ? "/" : folder, ".\(edit.name).gloamux-edit-\(edit.id.uuidString.prefix(8).lowercased()).partial")
            do {
                try await transfer.upload(localURL: edit.localURL, to: partial)
                // The new copy keeps the permissions of the file it replaces, such as a script's execute bit.
                if let mode = current?.permissions ?? edit.permissions { try? await transfer.setPermissions(partial, mode: mode) }
                try await transfer.commitUpload(partial, to: edit.remotePath, replacing: current != nil)
            } catch {
                try? await transfer.removeFile(partial)
                throw error
            }
            let after = try? await transfer.entry(at: edit.remotePath)
            edit.remoteSize = after?.size; edit.remoteModified = after?.modified; edit.permissions = after?.permissions ?? edit.permissions
            edit.syncedAt = stamp
            edit.changed = RemoteEdit.modified(edit.localURL) != stamp
            model.transfers.noteChange()
        } catch { edit.error = message(for: error) }
    }

    /// Stops tracking an edit and deletes the Mac copy.
    func close(_ edit: RemoteEdit) {
        edits.removeAll { $0.id == edit.id }
        try? FileManager.default.removeItem(at: edit.localURL.deletingLastPathComponent())
        check()
    }

    /// Removes the Mac copies that have nothing left to upload, at quit.
    func removeSynced() {
        for edit in edits where !edit.changed { try? FileManager.default.removeItem(at: edit.localURL.deletingLastPathComponent()) }
    }
}

/// Remote files open in Mac apps, with an upload button once they are saved there.
struct RemoteEditsList: View {
    @ObservedObject var editor = RemoteEditor.shared
    @ObservedObject var model: WorkspaceModel
    /// Only the edits of this session, or all of them.
    var tab: SessionTab?
    var inset: CGFloat = 0

    var body: some View {
        let shown = editor.edits.filter { tab == nil || $0.tab === tab }
        if !shown.isEmpty {
            VStack(spacing: 6) {
                ForEach(shown) { edit in RemoteEditRow(edit: edit, model: model) }
            }
            .padding(inset)
        }
    }
}

private struct RemoteEditRow: View {
    @ObservedObject var edit: RemoteEdit
    @ObservedObject var model: WorkspaceModel
    @State private var discarding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: edit.changed ? "pencil.circle.fill" : "pencil.circle").foregroundStyle(edit.changed ? Color.orange : .secondary)
                Text(edit.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if edit.uploading { ProgressView().controlSize(.mini) }
                else if edit.changed {
                    Button(T("Upload")) { upload() }.controlSize(.small)
                }
                Button { NSWorkspace.shared.open(edit.localURL) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help(T("Open in editor"))
                Button { if edit.changed { discarding = true } else { RemoteEditor.shared.close(edit) } } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help(T("Stop editing"))
            }
            .appFont(.system(size: 11))
            Text(edit.error.map { T($0) } ?? T(edit.changed ? "Saved on this Mac, not uploaded" : "Same as on the server"))
                .appFont(.system(size: 10)).foregroundStyle(edit.error == nil ? Color.secondary : .red).lineLimit(2)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .help(edit.remotePath)
        .alert(T("Discard changes?"), isPresented: $discarding) {
            Button(T("Cancel"), role: .cancel) {}
            Button(T("Discard"), role: .destructive) { RemoteEditor.shared.close(edit) }
        } message: { Text(String(format: T("The changes to %@ have not been uploaded."), edit.name)) }
    }

    private func upload() {
        Task {
            await RemoteEditor.shared.upload(edit, model: model) { edit in
                let alert = NSAlert()
                alert.messageText = T("The file changed on the server")
                alert.informativeText = String(format: T("%@ changed on the server after you opened it. Uploading replaces those changes."), edit.remotePath)
                alert.addButton(withTitle: T("Replace"))
                alert.addButton(withTitle: T("Cancel"))
                return alert.runModal() == .alertFirstButtonReturn
            }
        }
    }
}
