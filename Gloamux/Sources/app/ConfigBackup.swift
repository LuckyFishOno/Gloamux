import CryptoKit
import Foundation
import MasterPassword

/// One file that holds all of Gloamux's configuration, for moving it to another Mac or keeping a copy. It carries
/// sessions with their accounts, quick commands, triggers, runbooks, host keys, the theme, the layout, settings,
/// and the password vault as it is stored: sealed under its master password, which is not in the file and is needed
/// to open the vault again. Passwords remembered on this Mac and this Mac's key stay here; they are sealed with this
/// Mac's Secure Enclave and would not open anywhere else.
/// A `.sha256` file is written next to it, and restoring checks it when it is there.
public enum ConfigBackup {
    public static let fileExtension = "gloamuxconfig"
    static let format = "gloamux/config@1"
    /// The workspace files a backup replaces, as they are named in the workspace folder.
    static let files = ["sessions.json", "quick-commands.json", "triggers.json", "known-hosts.json",
                        "host-key-history.json", "appearance.json", "layout.json"]
    static let runbookFolder = "runbooks"
    /// Kept apart from `files`: a backup without a vault leaves the current vault alone instead of removing it.
    static let vaultFile = "password-vault.json"
    static let limit = 32 * 1024 * 1024

    public struct Backup {
        let files: [String: Data]
        let runbooks: [String: Data]
        let settings: [String: Any]
        /// The sealed vault file, when the backup has one.
        let vault: Data?
        public let created: String
        /// True when a `.sha256` file next to the backup matched it; false when there was none.
        public let verified: Bool
    }

    /// The suggested file name for a backup made now.
    public static func defaultName(_ date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Gloamux-\(format.string(from: date)).\(fileExtension)"
    }

    // MARK: Export

    /// Writes the backup to `url` and its checksum to `url` + `.sha256`, in the `shasum -a 256` format.
    @discardableResult @MainActor
    public static func export(storage: URL, to url: URL, preferences: UserDefaults? = nil) throws -> URL {
        let preferences = preferences ?? WorkspaceCommand.preferences
        var files: [String: Any] = [:]
        for name in Self.files {
            let source = storage.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            files[name] = try JSONSerialization.jsonObject(with: Data(contentsOf: source), options: [.fragmentsAllowed])
        }
        var runbooks: [String: String] = [:]
        let folder = storage.appendingPathComponent(runbookFolder, isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where isRunbookName(file.lastPathComponent) {
            runbooks[file.lastPathComponent] = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        }
        var settings: [String: Any] = [:]
        for setting in WorkspaceCommand.settingsTable {
            if let value = preferences.object(forKey: setting.key) { settings[setting.name] = value }
        }
        let dates = ISO8601DateFormatter()
        var document: [String: Any] = ["format": format, "created": dates.string(from: Date()),
                                       "files": files, "runbooks": runbooks, "settings": settings]
        let vault = storage.appendingPathComponent(vaultFile)
        if FileManager.default.fileExists(atPath: vault.path) {
            document["vault"] = try JSONSerialization.jsonObject(with: Data(contentsOf: vault))
        }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try writePrivate(data, to: url)
        let checksum = checksumURL(url)
        try writePrivate(Data("\(sha256(data))  \(url.lastPathComponent)\n".utf8), to: checksum)
        return checksum
    }

    public static func checksumURL(_ url: URL) -> URL { url.appendingPathExtension("sha256") }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func isRunbookName(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.contains("/") && ["md", "markdown"].contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: Read

    /// Reads and checks a backup without changing anything. A `.sha256` file next to it must match.
    @MainActor public static func read(_ url: URL) throws -> Backup {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw WorkspaceError.invalid("This Gloamux backup is larger than 32 MB.") }
        var verified = false
        let checksum = checksumURL(url)
        if FileManager.default.fileExists(atPath: checksum.path) {
            let expected = String(decoding: try Data(contentsOf: checksum).prefix(4096), as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
            guard expected == sha256(data) else {
                throw WorkspaceError.invalid("This backup does not match its .sha256 file. It may be damaged or changed.")
            }
            verified = true
        }
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ([format] + LegacyName.configFormats).contains(document["format"] as? String ?? "") else { throw WorkspaceError.invalid("This is not a Gloamux backup.") }
        var files: [String: Data] = [:]
        for (name, value) in document["files"] as? [String: Any] ?? [:] {
            guard Self.files.contains(name) else { throw WorkspaceError.invalid("This Gloamux backup has an unexpected file: \(name).") }
            files[name] = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys])
        }
        var runbooks: [String: Data] = [:]
        for (name, value) in document["runbooks"] as? [String: Any] ?? [:] {
            guard isRunbookName(name), let text = value as? String else { throw WorkspaceError.invalid("This Gloamux backup has an invalid runbook: \(name).") }
            runbooks[name] = Data(text.utf8)
        }
        let settings = document["settings"] as? [String: Any] ?? [:]
        for name in settings.keys where !WorkspaceCommand.settingsTable.contains(where: { $0.name == name }) {
            throw WorkspaceError.invalid("This Gloamux backup has an unknown setting: \(name).")
        }
        var vault: Data?
        if let value = document["vault"] {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  (try? MasterVault.load(data)) != nil else { throw WorkspaceError.invalid("The password vault in this Gloamux backup is damaged.") }
            vault = data
        }
        let backup = Backup(files: files, runbooks: runbooks, settings: settings, vault: vault,
                            created: document["created"] as? String ?? "", verified: verified)
        try validate(backup)
        return backup
    }

    /// Opens the backup's files the way Gloamux opens a workspace, in a scratch folder, so a damaged backup is refused
    /// before anything is replaced.
    @MainActor static func validate(_ backup: Backup) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (name, data) in backup.files { try writePrivate(data, to: scratch.appendingPathComponent(name)) }
        do {
            let model = try WorkspaceModel(storage: scratch)
            if let error = model.quickCommands.loadError { throw WorkspaceError.invalid(error) }
            if let error = model.triggers.loadError { throw WorkspaceError.invalid(error) }
            if let data = backup.files["appearance.json"] {
                let id = try JSONDecoder().decode(ThemePreference.self, from: data).selectedID
                guard model.themes.contains(where: { $0.id == id }) else { throw WorkspaceError.invalid("Unknown theme.") }
            }
            _ = try WorkspaceLayout.load(from: scratch)
            if let data = backup.files["host-key-history.json"] {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                _ = try decoder.decode([HostKeyEvent].self, from: data)
            }
        } catch {
            throw WorkspaceError.invalid("This Gloamux backup could not be read: \(error.localizedDescription)")
        }
    }

    // MARK: Restore

    /// Replaces the workspace's configuration with the backup. The current files and settings are first copied to
    /// `Backups/Before restore <date>` in the workspace folder, which is returned. The vault is replaced only when the
    /// backup has one; passwords remembered on this Mac and this Mac's key are left as they are. Reopen the workspace
    /// afterward to load the restored files.
    @discardableResult @MainActor
    public static func restore(_ backup: Backup, storage: URL, preferences: UserDefaults? = nil) throws -> URL {
        let preferences = preferences ?? WorkspaceCommand.preferences
        let manager = FileManager.default
        let safety = storage.appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("Before restore \(defaultName().dropFirst("Gloamux-".count).dropLast(fileExtension.count + 1))", isDirectory: true)
        try manager.createDirectory(at: safety, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in files {
            let current = storage.appendingPathComponent(name)
            if manager.fileExists(atPath: current.path) { try manager.copyItem(at: current, to: safety.appendingPathComponent(name)) }
        }
        let runbooks = storage.appendingPathComponent(runbookFolder, isDirectory: true)
        if manager.fileExists(atPath: runbooks.path) { try manager.copyItem(at: runbooks, to: safety.appendingPathComponent(runbookFolder)) }
        let vault = storage.appendingPathComponent(vaultFile)
        if backup.vault != nil, manager.fileExists(atPath: vault.path) { try manager.copyItem(at: vault, to: safety.appendingPathComponent(vaultFile)) }
        var previous: [String: Any] = [:]
        for setting in WorkspaceCommand.settingsTable {
            if let value = preferences.object(forKey: setting.key) { previous[setting.name] = value }
        }
        try writePrivate(JSONSerialization.data(withJSONObject: previous, options: [.prettyPrinted, .sortedKeys]),
                         to: safety.appendingPathComponent("settings.json"))

        for name in files {
            let target = storage.appendingPathComponent(name)
            if let data = backup.files[name] { try writePrivate(data, to: target) }
            else if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        }
        if manager.fileExists(atPath: runbooks.path) { try manager.removeItem(at: runbooks) }
        for (name, data) in backup.runbooks { try writePrivate(data, to: runbooks.appendingPathComponent(name)) }
        if let data = backup.vault { try writePrivate(data, to: vault) }
        for setting in WorkspaceCommand.settingsTable {
            if let value = backup.settings[setting.name] { preferences.set(value, forKey: setting.key) }
            else { preferences.removeObject(forKey: setting.key) }
        }
        return safety
    }
}
