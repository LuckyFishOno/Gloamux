import Foundation
import Profiles
import Ssh

struct ProfileImport: Sendable {
    struct Entry: Sendable {
        let components: [String]
        let name: String
        /// An SSH session, or nil for an entry that is another kind of session.
        var connection: SavedConnection?
        /// A serial port or other non-SSH session, in place of `connection`.
        var container: ContainerSession? = nil
        var notes: [String]
        /// The components of another entry in the same import that this one reaches through as its jump host.
        var jump: [String]? = nil
        var path: String { components.joined(separator: " / ") }
    }

    struct Skipped: Sendable {
        let path: String
        let reason: String
    }

    let name: String
    let folders: [[String]]
    let entries: [Entry]
    let skipped: [Skipped]

    /// Reads an Xshell session file, a folder of them, or an Xshell backup (`.xts`). A session without a user name
    /// takes `localUser`, as Xshell asks for the name when it connects.
    static func scan(_ root: URL, localUser: String = NSUserName()) throws -> Self {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        let fileExtension = root.pathExtension.lowercased()
        let single = rootValues.isRegularFile == true && ["xsh", "xfp"].contains(fileExtension)
        if rootValues.isRegularFile == true, rootValues.isSymbolicLink != true, fileExtension == "xts" {
            return try scanBackup(root, localUser: localUser)
        }
        guard rootValues.isDirectory == true || single, rootValues.isSymbolicLink != true else {
            throw WorkspaceError.invalid("Select an Xshell session file, folder, or backup.")
        }
        // One session file imports as one entry, with nothing around it.
        if single {
            let name = root.deletingPathExtension().lastPathComponent
            do {
                return Self(name: name, folders: [], entries: [try entry(root, components: [root.lastPathComponent], localUser: localUser)], skipped: [])
            } catch let error as WorkspaceError {
                return Self(name: name, folders: [], entries: [], skipped: [Skipped(path: root.lastPathComponent, reason: error.localizedDescription)])
            }
        }
        var folders: [[String]] = []
        var entries: [Entry] = []
        var skipped: [Skipped] = []
        var inspected = 0

        func walk(_ directory: URL, path: [String]) throws {
            try Task.checkCancellation()
            guard path.count < 63 else { throw WorkspaceError.invalid("The import contains too many nested folders.") }
            let children = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            inspected += children.count
            guard inspected <= 5000 else { throw WorkspaceError.invalid("Select a smaller folder. The import limit is 5,000 items.") }

            for child in children {
                try Task.checkCancellation()
                let components = path + [child.lastPathComponent]
                let values = try child.resourceValues(forKeys: keys)
                let isProfile = ["xsh", "xfp"].contains(child.pathExtension.lowercased())
                if values.isSymbolicLink == true {
                    if values.isDirectory == true || isProfile {
                        skipped.append(Skipped(path: components.joined(separator: " / "), reason: "Symbolic links are skipped."))
                    }
                } else if values.isDirectory == true {
                    folders.append(components)
                    try walk(child, path: components)
                } else if values.isRegularFile == true, isProfile {
                    do {
                        entries.append(try entry(child, components: components, localUser: localUser))
                    } catch let error as WorkspaceError {
                        skipped.append(Skipped(path: components.joined(separator: " / "), reason: error.localizedDescription))
                    } catch {
                        skipped.append(Skipped(path: components.joined(separator: " / "), reason: "The SSH/SFTP profile could not be read."))
                    }
                }
            }
        }

        try walk(root, path: [])
        return Self(name: root.lastPathComponent, folders: folders, entries: entries, skipped: skipped)
    }

    /// Xshell's backup (File > Export) is a zip of its data folder. Sessions are in `Xshell/` and `Xftp/`, or in
    /// `xsl/Sessions/` and `xfp/Sessions/` in older versions; only those folders are taken out, into a temporary folder
    /// that is removed afterwards. Key files, scripts, and color schemes in the backup are not read.
    private static func scanBackup(_ archive: URL, localUser: String) throws -> Self {
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 << 20 else { throw WorkspaceError.invalid("The Xshell backup could not be read.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-xts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let roots = ["Xshell", "Xftp", "xsl/Sessions", "xfp/Sessions"]
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // unzip leaves out absolute paths and `..` in the archive's names, so nothing lands outside the folder.
        unzip.arguments = ["-qq", "-o", archive.path] + roots.map { $0 + "/*" } + ["-d", temporary.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        // 11 means some of the folders are not in this backup.
        guard [0, 11].contains(unzip.terminationStatus) else { throw WorkspaceError.invalid("The Xshell backup could not be read.") }
        var folders: [[String]] = [], entries: [Entry] = [], skipped: [Skipped] = []
        for root in roots {
            let url = temporary.appendingPathComponent(root, isDirectory: true)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let part = try scan(url, localUser: localUser)
            folders += part.folders.filter { !folders.contains($0) }
            entries += part.entries
            skipped += part.skipped
        }
        guard !entries.isEmpty || !skipped.isEmpty else { throw WorkspaceError.invalid("No Xshell sessions were found in this backup.") }
        return Self(name: archive.deletingPathExtension().lastPathComponent, folders: folders, entries: entries, skipped: skipped)
    }

    private static func entry(_ url: URL, components: [String], localUser: String) throws -> Entry {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw WorkspaceError.invalid("Settings file exceeds 1 MiB.") }
        let profile = try SessionProfile(data: data, name: url.deletingPathExtension().lastPathComponent)
        guard [.ssh, .sftp].contains(profile.resolvedProtocol) else {
            throw WorkspaceError.invalid("Only SSH and SFTP profiles can be imported.")
        }
        let settings = try SSHConnectionSettings(profile: profile)
        if let rawPort = profile.sections.lazy.compactMap({ $0.value("Port") }).first,
           Int(rawPort).map({ (1...65535).contains($0) }) != true {
            throw WorkspaceError.invalid("Enter a valid port.")
        }
        guard profile.connection.proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError.invalid("This profile uses a proxy. Add the host with its proxy settings in Gloamux.")
        }
        var notes = profile.connection.authMethod.isEmpty || profile.connection.authMethod.lowercased() == "password"
            ? [] : ["Review the authentication settings before connecting."]
        var username = settings.username
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            username = localUser
            notes.append("Xshell asks for the user name when this session connects. Check the user name.")
        }
        let connection = SavedConnection(host: settings.host, port: settings.port, username: username,
                                         opensFiles: profile.resolvedProtocol == .sftp)
        try connection.validate()
        return Entry(components: components, name: profile.name, connection: connection, notes: notes)
    }
}
