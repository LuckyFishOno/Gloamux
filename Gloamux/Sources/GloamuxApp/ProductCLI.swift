import App
import Foundation

struct CLIUsageError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

struct CLIArguments {
    let operands: [String]
    private let options: [String: [String]]
    private let flags: Set<String>

    init(_ arguments: [String], values: Set<String> = [], switches: Set<String> = [], repeated: Set<String> = []) throws {
        var rest = arguments.makeIterator()
        var operands: [String] = []
        var options: [String: [String]] = [:]
        var flags: Set<String> = []
        while let arg = rest.next() {
            if arg == "--" {
                while let value = rest.next() { operands.append(value) }
            } else if values.contains(arg) {
                guard let value = rest.next(), !value.isEmpty, !value.hasPrefix("--") else { throw CLIUsageError("Missing value for \(arg).") }
                guard options[arg] == nil || repeated.contains(arg) else { throw CLIUsageError("Specify \(arg) once.") }
                options[arg, default: []].append(value)
            } else if switches.contains(arg) {
                flags.insert(arg)
            } else if arg.hasPrefix("--") {
                throw CLIUsageError("Unknown option \(arg).")
            } else {
                operands.append(arg)
            }
        }
        self.operands = operands
        self.options = options
        self.flags = flags
    }

    func option(_ key: String) -> String? { options[key]?.first }
    func all(_ key: String) -> [String] { options[key] ?? [] }
    func has(_ key: String) -> Bool { flags.contains(key) }
    var workspace: URL? { option("--workspace").map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

enum ProductCLI {
    static var usage: String { CLICatalog.usage }

    static func writeError(_ text: String) {
        FileHandle.standardError.write(Data((safe(text) + "\n").utf8))
    }

    static func safe(_ text: String) -> String {
        text.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
    }

    static func json(_ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        print(String(decoding: data, as: UTF8.self))
    }

    @MainActor static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else {
                print(usage)
                return 0
            }
            let rest = Array(arguments.dropFirst())
            switch command {
            case "--version":
                guard rest.isEmpty else { throw CLIUsageError("Usage: gloamux --version") }
                print(version)
            case "files": try await FilesCommand.run(rest)
            case "sftp": return try await SFTPShell.run(rest)
            case "ssh": return try await SSHCommand.run(rest)
            case "mcp": try await MCPServer.run(rest)
            case _ where ManagementCommands.handles(command): try await ManagementCommands.run(command, rest)
            default: throw CLIUsageError("Unknown command \(command). Run gloamux --help.")
            }
            return 0
        } catch is CancellationError {
            writeError("Cancelled.")
            return 130
        } catch let error as CLIUsageError {
            writeError(error.localizedDescription)
            return 2
        } catch let error as WorkspaceCommand.Usage {
            // Offline workspace commands report usage errors directly, not through the running app's reply code.
            writeError(error.localizedDescription)
            return 2
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static var version: String {
        let key = "CFBundleShortVersionString"
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String { return value }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let enclosingApp = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: enclosingApp)?.object(forInfoDictionaryKey: key) as? String ?? "development"
    }
}
