import App
import Foundation

enum ManagementCommands {
    /// Commands this type runs: workspace operations, XQuartz, and completion. The definitions live in `CLICatalog`.
    static func handles(_ command: String) -> Bool {
        guard let runner = CLICatalog.command(command)?.runner else { return false }
        return [.workspace, .xserver, .completion].contains(runner)
    }

    @MainActor static func run(_ command: String, _ arguments: [String]) async throws {
        if command == "completion" {
            try completion(arguments)
            return
        }
        if CLICatalog.asksForHelp(arguments) || arguments.isEmpty {
            print("Usage: gloamux \(command) <operation> [arguments] [--workspace PATH]\n")
            print(CLICatalog.command(command)?.help ?? "")
            print("\nResults are emitted as JSON. Use -- before a literal argument that begins with --.")
            return
        }
        if command == "xserver" {
            try await xserver(arguments)
            return
        }
        let args = try CLIArguments(arguments, values: ["--workspace"], switches: ["--json"])
        // Paths are resolved here, since the running app has its own working directory.
        let request = CLICatalog.resolvingLocalPaths([command] + args.operands,
                                                     from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        let channel = try WorkspaceCommandChannel(workspace: args.workspace ?? WorkspaceModel.defaultStorage)
        if try !channel.claim(), let reply = try await channel.send(request) {
            switch reply.code {
            case 0: print(reply.text)
            case 2: throw CLIUsageError(reply.text)
            default: throw WorkspaceError.invalid(reply.text)
            }
            return
        }
        let model = try WorkspaceModel(storage: channel.workspace)
        print(String(decoding: try await WorkspaceCommand.run(request, model: model, live: false), as: UTF8.self))
    }

    /// XQuartz belongs to this Mac, not to a workspace, so this runs here without the app.
    private static func xserver(_ arguments: [String]) async throws {
        // XQuartz is per Mac, not per workspace; the shared options are accepted like every other group's.
        let args = try CLIArguments(arguments, values: ["--workspace"], switches: ["--json"])
        guard args.operands.count == 1, let action = args.operands.first,
              CLICatalog.command("xserver")?.operations.contains(action) == true else {
            throw CLIUsageError(CLICatalog.choice("xserver"))
        }
        if action == "start" { try await XQuartz.start() }
        try ProductCLI.json(["installed": XQuartz.installedURL != nil, "running": XQuartz.isRunning])
    }

    private static func completion(_ args: [String]) throws {
        let usage = CLICatalog.choice("completion")
        if CLICatalog.asksForHelp(args) { print(usage); return }
        guard args.count == 1, let shell = args.first, CLICatalog.command("completion")?.operations.contains(shell) == true else {
            throw CLIUsageError(usage)
        }
        // benchmark is offered by name only; it is handled before the other commands and takes no operation.
        let listed = CLICatalog.commands.filter { $0.runner != .benchmark }.sorted { $0.name < $1.name }
        let names = (listed.map(\.name) + ["benchmark", "help"]).joined(separator: " ")
        let cases = listed.map { command in
            "    \(command.name)) candidates='\(command.operations.joined(separator: " "))' ;;"
        }.joined(separator: "\n")
        if shell == "zsh" {
            print("""
            _gloamux() {
              local candidates
              if (( CURRENT == 2 )); then
                candidates='\(names)'
              else
                case "$words[2]" in
            \(cases)
                esac
              fi
              compadd ${=candidates}
            }
            compdef _gloamux gloamux gloam
            """)
        } else {
            print("""
            _gloamux() {
              local candidates
              if (( COMP_CWORD == 1 )); then
                candidates='\(names)'
              else
                case "${COMP_WORDS[1]}" in
            \(cases)
                esac
              fi
              COMPREPLY=( $(compgen -W "$candidates" -- "${COMP_WORDS[COMP_CWORD]}") )
            }
            complete -F _gloamux gloamux gloam
            """)
        }
    }
}
