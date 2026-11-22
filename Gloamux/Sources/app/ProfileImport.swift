import Foundation
import Profiles
import Ssh

struct ProfileImport: Sendable {
    struct Entry: Sendable {
        let components: [String]
        let name: String
        let connection: SavedConnection
        let notes: [String]
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

    static func scan(_ root: URL) throws -> Self {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        let single = rootValues.isRegularFile == true && ["xsh", "xfp"].contains(root.pathExtension.lowercased())
        guard rootValues.isDirectory == true || single, rootValues.isSymbolicLink != true else {
            throw WorkspaceError.invalid("Select an Xshell session file or folder.")
        }
        // One session file imports as one entry, with nothing around it.
        if single {
            let name = root.deletingPathExtension().lastPathComponent
            do {
                return Self(name: name, folders: [], entries: [try entry(root, components: [root.lastPathComponent])], skipped: [])
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
                        entries.append(try entry(child, components: components))
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

    private static func entry(_ url: URL, components: [String]) throws -> Entry {
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
        let connection = SavedConnection(host: settings.host, port: settings.port, username: settings.username,
                                         opensFiles: profile.resolvedProtocol == .sftp)
        try connection.validate()
        let notes = profile.connection.authMethod.isEmpty || profile.connection.authMethod.lowercased() == "password"
            ? [] : ["Review the authentication settings before connecting."]
        return Entry(components: components, name: profile.name, connection: connection, notes: notes)
    }
}
