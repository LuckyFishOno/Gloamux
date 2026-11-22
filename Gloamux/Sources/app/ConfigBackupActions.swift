import AppKit
import UniformTypeIdentifiers

/// Export and Import in Settings › General and the command palette.
extension WorkspaceModel {
    /// Saves every setting to one file the user picks, with its `.sha256` next to it, and shows both in Finder.
    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ConfigBackup.defaultName()
        panel.allowedContentTypes = [UTType(filenameExtension: ConfigBackup.fileExtension) ?? .json]
        panel.prompt = T("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let checksum = try ConfigBackup.export(storage: storage, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url, checksum])
        } catch {
            Self.showProblem(T("The settings could not be exported."), error)
        }
    }

    /// Replaces every setting with a backup the user picks, after a confirmation, then restarts Gloamux.
    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ([ConfigBackup.fileExtension] + LegacyName.configExtensions).map { UTType(filenameExtension: $0) ?? .json }
        panel.prompt = T("Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let backup: ConfigBackup.Backup
        do { backup = try ConfigBackup.read(url) } catch {
            Self.showProblem(T("This backup cannot be imported."), error)
            return
        }
        let alert = NSAlert()
        alert.messageText = T("Replace all Gloamux settings with this backup?")
        var detail = T("Sessions, quick commands, triggers, runbooks, host keys, and settings are replaced. Saved passwords stay on this Mac. Open tabs close and Gloamux restarts.")
        if !backup.verified { detail += "\n\n" + T("No .sha256 file was found next to the backup, so it could not be checked.") }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: T("Replace and restart"))
        alert.addButton(withTitle: T("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let storage = storage
        Task {
            await closeAll(lockingVault: true)
            do {
                try ConfigBackup.restore(backup, storage: storage)
            } catch {
                Self.showProblem(T("The backup could not be restored."), error)
                return
            }
            Self.relaunch(storage: storage)
        }
    }

    private static func showProblem(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = T(error.localizedDescription)
        alert.runModal()
    }

    /// Quits and opens Gloamux again once this process has exited, so the restored files load from the start.
    private static func relaunch(storage: URL) {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            var arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -n \"$0\" --args \"$@\"", bundle.path]
            if storage.standardizedFileURL != WorkspaceModel.defaultStorage.standardizedFileURL {
                arguments += ["--workspace", storage.path]
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = arguments
            try? process.run()
        }
        NSApp.terminate(nil)
    }
}
