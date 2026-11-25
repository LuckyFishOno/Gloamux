import App
import Darwin
import FileTransfer
import Foundation
import Ssh

/// `gloamux sftp`: one SFTP connection, signed in to once, with the commands people know from sftp.
enum SFTPShell {
    static let usage = """
    Usage: gloamux sftp SESSION [options]
           gloamux sftp [sftp options] [user@]host[:path]
           gloamux sftp --command FILE

    Signs in once, then reads sftp commands: from the terminal, or from standard input, where the first error ends it.
    A saved session keeps its host, port, sign-in, and folders; one that uses a session key asks only for that key.
    --command reads a whole sftp command, with the lcd, get, and put lines after it, from FILE, or from standard input
    with -. Run gloamux sessions from-sftp to save such a command as a session.

    Options:
      --workspace PATH             Use a separate Gloamux workspace
      --session NAME_OR_ID         Choose the saved session by option
      --password-stdin             Read the password, or the session key, as one line
      --vault-password-stdin       Unlock the vault for this command (first line if both are set)
      --host-key FINGERPRINT       Permit a verified new SSH host key for this run (repeatable)
      --overwrite                  Replace existing files

    sftp options: -P PORT, -i KEY, -o OPTION=VALUE. Options that Gloamux does not need are accepted and not used.

    Commands:
      ls [PATH]  cd PATH  pwd  lls [PATH]  lcd PATH  lpwd
      get [-r] [-f] REMOTE [LOCAL]   put [-r] [-f] LOCAL [REMOTE]   -f replaces an existing file
      mkdir PATH  rename FROM TO  rm PATH  rmdir PATH  chmod MODE PATH  stat PATH
      help  bye
    """

    @MainActor static func run(_ arguments: [String]) async throws -> Int32 {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] { print(usage); return arguments.isEmpty ? 2 : 0 }
        let args = try CLIArguments(arguments, values: ["--session", "--workspace", "--host-key", "--command"],
                                    switches: ["--password-stdin", "--vault-password-stdin", "--overwrite"], repeated: ["--host-key"])
        let hostKeys = try FilesCommand.verifiedHostKeys(args)
        let model = try WorkspaceModel(storage: args.workspace)
        var steps: [SFTPCommand.Step] = []
        var item: SessionTreeNode
        var start: String?
        if let file = args.option("--command") {
            guard args.option("--session") == nil, args.operands.isEmpty else { throw CLIUsageError(usage) }
            let command = try SFTPCommand.parse(try commandText(file))
            for line in command.ignored { ProductCLI.writeError("Not used: \(line)") }
            steps = command.steps
            start = command.remotePath
            item = SessionTreeNode(name: command.connection.host, connection: command.connection)
        } else if let selector = args.option("--session") {
            guard args.operands.isEmpty else { throw CLIUsageError(usage) }
            item = try WorkspaceCommand.item(selector, in: model.sessionTree)
        } else if args.operands.count == 1, let saved = try? WorkspaceCommand.item(args.operands[0], in: model.sessionTree) {
            item = saved
        } else {
            let command = try SFTPCommand.parse(arguments: args.operands)
            start = command.remotePath
            item = SessionTreeNode(name: command.connection.host, connection: command.connection)
        }
        guard var settings = item.connection, !settings.isFileServer else { throw CLIUsageError("Choose an SSH session.") }
        if settings.username.isEmpty, settings.signIn != .sessionKey { settings.username = NSUserName(); item.connection = settings }
        if args.has("--vault-password-stdin") { try await model.vault.unlock(password: try FilesCommand.stdinSecret()) }
        let secret = args.has("--password-stdin") ? try FilesCommand.stdinSecret() : nil
        let access = FileCommandAccess(hostKeys: hostKeys, answer: { challenge in try FilesCommand.terminalAnswers(challenge) },
                                       confirmHostKey: { endpoint, fingerprint in try confirm(endpoint, fingerprint) })
        let interactive = isatty(STDIN_FILENO) == 1 && args.option("--command") == nil
        let readsInput = args.option("--command") == nil
        let overwrite = args.has("--overwrite")
        return try await Interruption.run {
            try await model.withFileConnection(item, protocol: "sftp", secret: secret, allowPlainFTP: false, access: access) { fs in
                let shell = Session(fs: fs, model: model, overwrite: overwrite)
                try await shell.open(remote: start ?? settings.remoteFolder, local: settings.localFolder)
                for step in steps { try await shell.run(step) }
                if readsInput { return try await shell.readCommands(interactive: interactive) }
                return 0
            }
        }
    }

    private static func commandText(_ file: String) throws -> String {
        let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: file))
        return String(decoding: data.prefix(64 * 1024), as: UTF8.self)
    }

    /// Asks on the terminal about a host key seen for the first time. It is accepted for this run only.
    private static func confirm(_ endpoint: String, _ fingerprint: String) throws -> Bool {
        ProductCLI.writeError("New SSH host key for \(endpoint): \(fingerprint)")
        var buffer = [CChar](repeating: 0, count: 16)
        guard readpassphrase("Is this the server's key? Type yes to continue: ", &buffer, buffer.count, RPP_REQUIRE_TTY | RPP_ECHO_ON) != nil else {
            return false
        }
        return String(cString: buffer).lowercased() == "yes"
    }

    @MainActor private final class Session {
        let fs: any RemoteFileSystem
        let model: WorkspaceModel
        let overwrite: Bool
        var remote = "/"
        var local = FileManager.default.currentDirectoryPath

        init(fs: any RemoteFileSystem, model: WorkspaceModel, overwrite: Bool) {
            self.fs = fs; self.model = model; self.overwrite = overwrite
        }

        func open(remote path: String?, local folder: String?) async throws {
            remote = (try? await fs.resolve(path ?? ".")) ?? path ?? "/"
            if let folder, isFolder(folder) { local = folder }
        }

        func readCommands(interactive: Bool) async throws -> Int32 {
            while true {
                try Task.checkCancellation()
                if interactive { FileHandle.standardOutput.write(Data("sftp> ".utf8)) }
                guard let line = await Self.line() else { if interactive { print("") }; return 0 }
                do { if try await run(line) == false { return 0 } } catch is CancellationError { throw CancellationError() } catch {
                    ProductCLI.writeError(error.localizedDescription)
                    if !interactive { return 1 }
                }
            }
        }

        /// Reads a line away from the main actor, so the connection stays alive while nothing is typed.
        private static func line() async -> String? {
            await withCheckedContinuation { continuation in
                let thread = Thread { continuation.resume(returning: readLine()) }
                thread.start()
            }
        }

        /// Runs one line. Returns false for bye.
        private func run(_ line: String) async throws -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return true }
            let words = try SFTPCommand.tokens(trimmed)
            guard let name = words.first?.lowercased() else { return true }
            var flags: Set<Character> = []
            var paths: [String] = []
            for word in words.dropFirst() {
                if word.hasPrefix("-"), word.count > 1, paths.isEmpty { flags.formUnion(word.dropFirst()) } else { paths.append(word) }
            }
            func count(_ range: ClosedRange<Int>) throws {
                guard range.contains(paths.count) else { throw CLIUsageError("Wrong number of arguments. Type help.") }
            }
            let recursive = flags.contains("r") || flags.contains("R"), replaces = overwrite || flags.contains("f")
            switch name {
            case "ls", "dir":
                try count(0...1)
                for entry in try await fs.readDirectory(absolute(paths.first ?? ".")).entries where ![".", ".."].contains(entry.name) {
                    let size = entry.isDirectory ? "-" : entry.size.map(String.init) ?? "?"
                    print(String(repeating: " ", count: max(0, 14 - size.count)) + size + "  " + ProductCLI.safe(entry.name) + (entry.isDirectory ? "/" : ""))
                }
            case "cd":
                try count(1...1)
                let target = absolute(paths[0])
                remote = try await fs.readDirectory(target).path
            case "pwd": print(ProductCLI.safe(remote))
            case "lpwd": print(local)
            case "lcd": try count(1...1); try changeLocal(paths[0])
            case "lls":
                try count(0...1)
                for item in try FileManager.default.contentsOfDirectory(atPath: localPath(paths.first ?? ".")).sorted() { print(ProductCLI.safe(item)) }
            case "get": try count(1...2); try await get(paths[0], paths.count > 1 ? paths[1] : nil, recursive: recursive, replaces: replaces)
            case "put": try count(1...2); try await put(paths[0], paths.count > 1 ? paths[1] : nil, recursive: recursive, replaces: replaces)
            case "mkdir": try count(1...1); try await fs.makeDirectory(absolute(paths[0]))
            case "rename", "mv": try count(2...2); try await fs.rename(from: absolute(paths[0]), to: absolute(paths[1]))
            case "rm": try count(1...1); try await fs.removeFile(absolute(paths[0]))
            case "rmdir": try count(1...1); try await fs.removeDirectory(absolute(paths[0]))
            case "chmod":
                try count(2...2)
                guard let mode = UInt32(paths[0], radix: 8), mode <= 0o7777 else { throw CLIUsageError("Mode must be an octal number from 0000 to 7777.") }
                try await fs.setPermissions(absolute(paths[1]), mode: mode)
            case "stat":
                try count(1...1)
                guard let entry = try await fs.entry(at: absolute(paths[0])) else { throw WorkspaceError.invalid("Remote item does not exist.") }
                try ProductCLI.json(FilesCommand.entryJSON(entry))
            case "help", "?": print(String(SFTPShell.usage[SFTPShell.usage.range(of: "Commands:")!.lowerBound...]))
            case "bye", "exit", "quit": return false
            default: throw CLIUsageError("Unknown command \(ProductCLI.safe(name)). Type help.")
            }
            return true
        }

        func run(_ step: SFTPCommand.Step) async throws {
            switch step {
            case .localFolder(let path): try changeLocal(path)
            case .remoteFolder(let path): remote = try await fs.resolve(absolute(path))
            case .get(let source, let target, let recursive): try await get(source, target, recursive: recursive, replaces: overwrite)
            case .put(let source, let target, let recursive): try await put(source, target, recursive: recursive, replaces: overwrite)
            }
        }

        private func absolute(_ path: String) -> String {
            if path.hasPrefix("/") { return path }
            if path == "." { return remote }
            return remote.hasSuffix("/") ? remote + path : remote + "/" + path
        }

        private func localPath(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: local, isDirectory: true)).standardizedFileURL.path
        }

        private func isFolder(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        private func changeLocal(_ path: String) throws {
            let target = localPath(path)
            guard isFolder(target) else { throw WorkspaceError.invalid("\(target) is not a folder on this Mac.") }
            local = target
        }

        private func get(_ source: String, _ target: String?, recursive: Bool, replaces: Bool) async throws {
            let path = absolute(source), name = (path as NSString).lastPathComponent
            var destination = localPath(target ?? name)
            if target != nil, isFolder(destination) { destination = (destination as NSString).appendingPathComponent(name) }
            let url = URL(fileURLWithPath: destination)
            do {
                if recursive, try await fs.entry(at: path)?.isDirectory == true {
                    _ = try await FilesCommand.getFolder(fs, path, url, overwrite: replaces, resume: false)
                } else {
                    try await FilesCommand.get(fs, path, url, overwrite: replaces, resume: false)
                }
            } catch { model.noteCommandCopy(download: true, path: path, error: error.localizedDescription); throw error }
            let size = (try? FileManager.default.attributesOfItem(atPath: destination)[.size] as? NSNumber)?.uint64Value
            model.noteCommandCopy(download: true, path: path, bytes: isFolder(destination) ? nil : size)
            print("Downloaded \(ProductCLI.safe(path)) to \(ProductCLI.safe(destination))")
        }

        private func put(_ source: String, _ target: String?, recursive: Bool, replaces: Bool) async throws {
            let file = localPath(source), name = (file as NSString).lastPathComponent
            var destination = absolute(target ?? name)
            if let target, target.hasSuffix("/") { destination = absolute(target + name) }
            else if target != nil, try await fs.entry(at: destination)?.isDirectory == true { destination += "/" + name }
            let url = URL(fileURLWithPath: file)
            do {
                if recursive, isFolder(file) { _ = try await FilesCommand.putFolder(fs, url, destination, overwrite: replaces, resume: false) }
                else { try await FilesCommand.put(fs, url, destination, overwrite: replaces, resume: false) }
            } catch { model.noteCommandCopy(download: false, path: destination, error: error.localizedDescription); throw error }
            let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.uint64Value
            model.noteCommandCopy(download: false, path: destination, bytes: isFolder(file) ? nil : size)
            print("Uploaded \(ProductCLI.safe(file)) to \(ProductCLI.safe(destination))")
        }
    }
}
