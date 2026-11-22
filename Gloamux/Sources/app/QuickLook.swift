import AppKit
import Quartz

/// Quick Look for local files and for remote files, which are copied to a private temporary folder first. The copy
/// is deleted when the next preview opens and when Gloamux quits.
@MainActor final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()
    /// Larger remote files are not copied just to preview them.
    static let remoteLimit: UInt64 = 100 * 1024 * 1024
    private var urls: [URL] = []
    private var folder: URL?
    @Published private(set) var loading: String?

    func show(_ urls: [URL]) {
        self.urls = urls.filter(\.isFileURL)
        guard !self.urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    /// Copies a remote file to a temporary folder and previews it.
    func show(remote path: String, size: UInt64?, in tab: SessionTab, model: WorkspaceModel) async {
        if let size, size > Self.remoteLimit {
            model.error = "Quick Look previews remote files up to 100 MB. Download larger files instead."
            return
        }
        clean()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Gloamux-QuickLook", isDirectory: true)
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            self.folder = folder
            let name = (path as NSString).lastPathComponent
            let destination = folder.appendingPathComponent(name.isEmpty ? "file" : name)
            loading = name
            defer { loading = nil }
            let transfer = try await model.sftp(for: tab)
            try await transfer.download(remotePath: path, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            show([destination])
        } catch {
            model.error = message(for: error)
            clean()
        }
    }

    /// Removes the previous remote copy.
    func clean() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    /// Removes every remote copy, at quit and at launch in case Gloamux did not quit normally.
    nonisolated static func removeAll() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Gloamux-QuickLook"))
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}

extension QuickLookPreview: ObservableObject {}
