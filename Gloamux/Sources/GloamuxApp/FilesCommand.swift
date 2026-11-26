import App
import Darwin
import FileTransfer
import Foundation
import Ssh

enum FilesCommand {
    static var usage: String { CLICatalog.command("files")?.help ?? "" }

    @MainActor static func run(_ arguments: [String]) async throws {
        if CLICatalog.asksForHelp(arguments) { print(usage); return }
        let args = try CLIArguments(arguments, values: ["--session", "--workspace", "--protocol", "--host-key"],
                                    switches: ["--json", "--password-stdin", "--vault-password-stdin", "--interactive",
                                               "--allow-plain-ftp", "--overwrite", "--resume", "--recursive"], repeated: ["--host-key"])
        guard let selector = args.option("--session"), let op = args.operands.first else { throw CLIUsageError(usage) }
        let paths = Array(args.operands.dropFirst())
        guard let count = CLICatalog.filePaths[op], count.contains(paths.count) else { throw CLIUsageError("Invalid operation or path count. Run gloamux files --help.") }
        let overwrite = args.has("--overwrite"), resume = args.has("--resume")
        guard !(overwrite && resume), !(overwrite || resume) || ["get", "put"].contains(op) else {
            throw CLIUsageError("Use --overwrite or --resume with get or put.")
        }
        let recursive = args.has("--recursive")
        guard !recursive || ["get", "put", "rm"].contains(op) else { throw CLIUsageError("Use --recursive with get, put, or rm.") }
        let mode = op == "chmod" ? UInt32(paths[0], radix: 8) : nil
        if op == "chmod", mode.map({ $0 <= 0o7777 }) != true { throw CLIUsageError("Mode must be an octal number from 0000 to 7777.") }
        let requested = args.option("--protocol")
        if let requested, !["sftp", "scp", "ftp", "ftps"].contains(requested) { throw CLIUsageError("Unknown file protocol.") }
        let hostKeys = try verifiedHostKeys(args)

        // Read the catalog, saved sign-ins, and known hosts as local snapshots. The file-command
        // connection never saves credentials, accepts keys into the catalog, or updates recents. Only the connection
        // history is written, by appending.
        // Keep the app's writer lock independent of transfers, which may take a long time.
        let model = try WorkspaceModel(storage: args.workspace)
        let item = try WorkspaceCommand.item(selector, in: model.sessionTree)
        if args.has("--vault-password-stdin") { try await model.vault.unlock(password: try stdinSecret()) }
        let secret = args.has("--password-stdin") ? try stdinSecret() : nil
        let answer: SSHLoginAnswerer?
        if args.has("--interactive") { answer = { @Sendable challenge in try terminalAnswers(challenge) } }
        else { answer = nil }
        let result: [String: Any] = try await Interruption.run { try await model.withFileConnection(
            item, protocol: requested, secret: secret, allowPlainFTP: args.has("--allow-plain-ftp"),
            access: FileCommandAccess(hostKeys: hostKeys, answer: answer)
        ) { fs in
            var result: [String: Any] = ["protocol": fs.protocolName, "operation": op]
            switch op {
            case "ls":
                let listing = try await fs.readDirectory(paths.first ?? ".")
                result["path"] = listing.path
                result["entries"] = listing.entries.map(entryJSON)
            case "pwd": result["path"] = try await fs.resolve(".")
            case "stat":
                guard let entry = try await fs.entry(at: paths[0]) else { throw WorkspaceError.invalid("Remote item does not exist.") }
                result["entry"] = entryJSON(entry)
            case "get" where recursive:
                result["files"] = try await noting(model, download: true, paths[0]) {
                    try await getFolder(fs, paths[0], URL(fileURLWithPath: paths[1]), overwrite: overwrite, resume: resume)
                }
            case "put" where recursive:
                result["files"] = try await noting(model, download: false, paths[1]) {
                    try await putFolder(fs, URL(fileURLWithPath: paths[0]), paths[1], overwrite: overwrite, resume: resume)
                }
            case "rm" where recursive:
                guard let entry = try await fs.entry(at: paths[0]) else { throw WorkspaceError.invalid("Remote item does not exist.") }
                try await RemoteDelete.remove(paths[0], isDirectory: entry.isDirectory, with: fs)
                model.noteCommandChange("rm", paths)
            case "get":
                try await noting(model, download: true, paths[0]) {
                    try await get(fs, paths[0], URL(fileURLWithPath: paths[1]), overwrite: overwrite, resume: resume)
                }
            case "put":
                try await noting(model, download: false, paths[1]) {
                    try await put(fs, URL(fileURLWithPath: paths[0]), paths[1], overwrite: overwrite, resume: resume)
                }
            case "mkdir": try await fs.makeDirectory(paths[0]); model.noteCommandChange(op, paths)
            case "mv": try await fs.rename(from: paths[0], to: paths[1]); model.noteCommandChange(op, paths)
            case "rm": try await fs.removeFile(paths[0]); model.noteCommandChange(op, paths)
            case "rmdir": try await fs.removeDirectory(paths[0]); model.noteCommandChange(op, paths)
            case "chmod":
                if let mode {
                    try await fs.setPermissions(paths[1], mode: mode)
                    model.noteCommandChange(op, [paths[1]], mode: mode)
                }
            default: throw CLIUsageError("Unknown file operation.")
            }
            return result
        } }
        if args.has("--json") { try ProductCLI.json(result) }
        else if let entries = result["entries"] as? [[String: Any]] {
            for entry in entries { print(ProductCLI.safe(entry["name"] as? String ?? "")) }
        } else if let path = result["path"] as? String { print(ProductCLI.safe(path)) }
        else if let entry = result["entry"] { try ProductCLI.json(entry) }
    }

    /// Runs one copy and writes how it went to the connection history.
    @MainActor private static func noting<Result>(_ model: WorkspaceModel, download: Bool, _ path: String,
                                                  _ copy: () async throws -> Result) async throws -> Result {
        do {
            let result = try await copy()
            model.noteCommandCopy(download: download, path: path)
            return result
        } catch {
            model.noteCommandCopy(download: download, path: path, error: error.localizedDescription)
            throw error
        }
    }

    static func verifiedHostKeys(_ args: CLIArguments) throws -> Set<String> {
        let hostKeys = Set(args.all("--host-key"))
        guard hostKeys.allSatisfy({ $0.hasPrefix("SHA256:") && $0.count == 50 && Data(base64Encoded: String($0.dropFirst(7)) + "=")?.count == 32 }) else {
            throw CLIUsageError("Use an OpenSSH SHA256: fingerprint for --host-key.")
        }
        return hostKeys
    }

    static func stdinSecret() throws -> String {
        guard let line = readLine(), !line.isEmpty else { throw CLIUsageError("Expected a nonempty secret on standard input.") }
        return line
    }

    static func terminalAnswers(_ challenge: SSHLoginChallenge) throws -> [String] {
        if !challenge.name.isEmpty { ProductCLI.writeError(challenge.name) }
        if !challenge.instruction.isEmpty { ProductCLI.writeError(challenge.instruction) }
        return try challenge.prompts.map { prompt in
            var buffer = [CChar](repeating: 0, count: 4096)
            let flags = RPP_REQUIRE_TTY | (prompt.hidden ? RPP_ECHO_OFF : RPP_ECHO_ON)
            defer { _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            guard readpassphrase(ProductCLI.safe(prompt.text), &buffer, buffer.count, flags) != nil else {
                throw WorkspaceError.invalid("Cannot read SSH sign-in from the terminal.")
            }
            return String(cString: buffer)
        }
    }

    static func entryJSON(_ entry: RemoteEntry) -> [String: Any] {
        var object: [String: Any] = ["name": entry.name, "directory": entry.isDirectory]
        if let size = entry.size { object["size"] = size }
        if let permissions = entry.permissions { object["permissions"] = String(permissions & 0o7777, radix: 8) }
        if let modified = entry.modified { object["modified"] = ISO8601DateFormatter().string(from: modified) }
        return object
    }

    private static func localSize(_ url: URL) throws -> UInt64? {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        guard attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? NSNumber else {
            throw WorkspaceError.invalid("Expected a regular local file at \(url.path).")
        }
        return size.uint64Value
    }

    static func get(_ fs: any RemoteFileSystem, _ remote: String, _ local: URL, overwrite: Bool, resume: Bool) async throws {
        let existing = try localSize(local)
        if resume, let offset = existing, offset > 0 {
            guard await fs.canResume(), let size = try await fs.entry(at: remote)?.size, offset <= size else {
                throw WorkspaceError.invalid("Cannot resume this download.")
            }
            if offset < size { try await fs.resumeDownload(remotePath: remote, to: local, offset: offset, progress: nil) }
            return
        }
        guard existing == nil || overwrite || resume else { throw WorkspaceError.invalid("Local file exists. Use --overwrite or --resume.") }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".gloamux-\(UUID()).partial")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        Darwin.close(fd)
        Interruption.partial = temporary
        defer { try? FileManager.default.removeItem(at: temporary); Interruption.partial = nil }
        try await fs.download(remotePath: remote, to: temporary)
        let flags: UInt32 = overwrite || (resume && existing != nil) ? 0 : UInt32(RENAME_EXCL)
        guard renamex_np(temporary.path, local.path, flags) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func child(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// Downloads a remote folder to `local`, which becomes that folder. Each file goes through `get`, so
    /// `--overwrite` and `--resume` apply file by file. Returns the number of files.
    static func getFolder(_ fs: any RemoteFileSystem, _ remote: String, _ local: URL, overwrite: Bool, resume: Bool) async throws -> Int {
        guard try await fs.entry(at: remote)?.isDirectory == true else { throw WorkspaceError.invalid("Remote folder does not exist.") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw WorkspaceError.invalid("A file is at \(local.path).") }
            guard overwrite || resume else { throw WorkspaceError.invalid("Local folder exists. Use --overwrite or --resume.") }
        }
        var files = 0
        var pending = [(remote, local)]
        while let (folder, target) = pending.popLast() {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for entry in try await fs.listDirectory(folder) where ![".", ".."].contains(entry.name) {
                let source = child(folder, entry.name), destination = target.appendingPathComponent(entry.name)
                if entry.isDirectory { pending.append((source, destination)); continue }
                try await get(fs, source, destination, overwrite: overwrite, resume: resume)
                files += 1
            }
        }
        return files
    }

    /// Uploads a folder on this Mac to `remote`, which becomes that folder. Returns the number of files.
    static func putFolder(_ fs: any RemoteFileSystem, _ local: URL, _ remote: String, overwrite: Bool, resume: Bool) async throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.invalid("Local source folder does not exist.")
        }
        if let existing = try await fs.entry(at: remote) {
            guard existing.isDirectory else { throw WorkspaceError.invalid("Remote destination is a file.") }
            guard overwrite || resume else { throw WorkspaceError.invalid("Remote folder exists. Use --overwrite or --resume.") }
        } else {
            try await fs.makeDirectory(remote)
        }
        var files = 0
        for (url, relative, folder) in try localTree(local) {
            try Task.checkCancellation()
            let destination = child(remote, relative)
            if folder {
                if let entry = try await fs.entry(at: destination) {
                    guard entry.isDirectory else { throw WorkspaceError.invalid("\(destination) exists and is not a folder.") }
                } else {
                    try await fs.makeDirectory(destination)
                }
            } else {
                let exists = try await fs.entry(at: destination) != nil
                try await put(fs, url, destination, overwrite: overwrite && exists, resume: resume && exists)
                files += 1
            }
        }
        return files
    }

    /// Every folder and file under `root`, parents first, without following symbolic links.
    private static func localTree(_ root: URL) throws -> [(url: URL, relative: String, folder: Bool)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw WorkspaceError.invalid("Cannot read \(root.path).")
        }
        let base = root.standardizedFileURL.path
        var items: [(URL, String, Bool)] = []
        while let url = walker.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            items.append((url, String(url.standardizedFileURL.path.dropFirst(base.count + 1)), values.isDirectory == true))
        }
        return items
    }

    static func put(_ fs: any RemoteFileSystem, _ local: URL, _ remote: String, overwrite: Bool, resume: Bool) async throws {
        guard let size = try localSize(local) else { throw WorkspaceError.invalid("Local source file does not exist.") }
        guard !remote.hasSuffix("/"), !["", ".", ".."].contains((remote as NSString).lastPathComponent) else {
            throw CLIUsageError("Specify the destination file path.")
        }
        let existing = try await fs.entry(at: remote)
        guard existing?.isDirectory != true else { throw WorkspaceError.invalid("Remote destination is a directory.") }
        if resume, let existing {
            guard await fs.canResume(), let offset = existing.size, offset <= size else {
                throw WorkspaceError.invalid("Cannot resume this upload.")
            }
            if offset < size { try await fs.resumeUpload(localURL: local, to: remote, offset: offset, progress: nil) }
            return
        }
        guard existing == nil || overwrite else { throw WorkspaceError.invalid("Remote file exists. Use --overwrite or --resume.") }
        let directory = (remote as NSString).deletingLastPathComponent
        let partial = (directory as NSString).appendingPathComponent(".gloamux-\(UUID()).partial")
        do {
            try await fs.upload(localURL: local, to: partial)
            if !overwrite, try await fs.entry(at: remote) != nil {
                throw WorkspaceError.invalid("Remote file appeared during upload.")
            }
            let replacing = overwrite ? try await fs.entry(at: remote) != nil : false
            try await fs.commitUpload(partial, to: remote, replacing: replacing)
        } catch {
            try? await fs.removeFile(partial)
            throw error
        }
    }
}
