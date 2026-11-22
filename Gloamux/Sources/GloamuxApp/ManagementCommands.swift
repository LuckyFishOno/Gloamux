import App
import Foundation

enum ManagementCommands {
    static let operations: [String: [String]] = [
        "sessions": ["list", "show", "mkdir", "add", "add-other", "edit", "edit-other", "serial-ports", "rename", "move", "remove", "env", "auth", "cert", "import", "export"],
        "hosts": ["list", "history", "trust", "replace"],
        "tabs": ["list", "show", "open", "open-window", "connect", "local", "select", "rename", "duplicate", "close", "disconnect", "reconnect",
                 "split", "unsplit", "broadcast", "multiexec", "window", "attach", "read", "send", "run", "readonly", "log", "encoding", "colors", "highlights"],
        "forwards": ["list", "add", "remove", "live-list", "start", "stop"],
        "commands": ["list", "add", "edit", "remove", "send", "run"],
        "triggers": ["list", "add", "edit", "enable", "disable", "remove"],
        "runbooks": ["list", "show", "create", "import", "delete", "run"],
        "appearance": ["list", "get", "set"],
        "settings": ["list", "get", "set", "reset"],
        "layout": ["get", "set"],
        "config": ["export", "import"],
        "agents": ["status", "history", "revoke", "off"],
        "mcp": [],
        "vault": ["status", "lock"],
        "signins": ["list", "remove"],
        "workspace": ["lock"],
        "xserver": ["status", "start"],
        "files": ["ls", "pwd", "stat", "get", "put", "mkdir", "mv", "rm", "rmdir", "chmod"],
        "ssh": [],
        "completion": ["zsh", "bash"]
    ]

    static let help: [String: String] = [
        "sessions": """
            list | show ITEM
            mkdir NAME [FOLDER]
            add NAME PROTOCOL HOST USER [PORT [FOLDER]]
            edit ITEM HOST USER PORT
            add-other NAME KIND TARGET [SETTING=VALUE ...] | edit-other ITEM SETTING=VALUE ...
            serial-ports
            rename ITEM NAME | move ITEM FOLDER | remove ITEM
            env ITEM production|staging|test|development|-
            auth ITEM password|agent|key [ABSOLUTE_KEY_PATH]
            cert ITEM VERIFIED_FTPS_SHA256
            import FORMAT PATH [IMPORT_NAME [FOLDER]]
            export FORMAT PATH [ITEM]

            Use an item UUID or its unique name. Use - for the top level or an empty username.
            Protocols: ssh, sftp, scp, ftp, ftps, ftps-implicit, rdp, vnc.
            Formats: openssh, xshell, mobaxterm, putty, csv, gloamux. Omit IMPORT_NAME for a preview.

            Other connections, with TARGET and their settings (folder=FOLDER works for all; - resets a setting):
              serial  DEVICE    baud=9600 data-bits=8|7|6|5 parity=none|odd|even stop-bits=1|2
                                flow=none|rts-cts|dtr-dsr|xon-xoff encoding=utf8
              telnet  HOST      port=23 encoding=utf8
              mosh    HOST      user=USER port=22 (the SSH port)
              docker  CONTAINER context=CONTEXT shell=/bin/sh user=USER
              kubectl POD       context=CONTEXT namespace=NAMESPACE container=CONTAINER shell=/bin/sh
              ssm     INSTANCE  profile=AWS_PROFILE region=REGION
            serial-ports lists the serial devices connected to this Mac. edit-other also takes target=TARGET.
            Open a saved session with gloamux tabs open ITEM.
            """,
        "hosts": """
            list | history
            trust '[HOST]:PORT' 'TYPE PUBLIC_KEY' VERIFIED_SHA256
            replace '[HOST]:PORT' 'TYPE PUBLIC_KEY' VERIFIED_SHA256 PREVIOUS_SHA256
            """,
        "tabs": """
            list | show TAB_ID
            open SESSION | open-window SESSION | connect USER@HOST[:PORT] | local
            select TAB_ID | rename TAB_ID NAME | duplicate TAB_ID | close TAB_ID
            disconnect TAB_ID | reconnect TAB_ID
            split TAB_ID left|right|top|bottom OTHER_TAB_ID | unsplit TAB_ID | broadcast TAB_ID on|off
            multiexec TAB_ID on|off
            window TAB_ID | attach TAB_ID
            read TAB_ID [LINES] | send TAB_ID TEXT | run TAB_ID COMMAND_LINE
            readonly TAB_ID on|off | log TAB_ID on|off | encoding TAB_ID ENCODING
            colors TAB_ID XCS_PATH | highlights TAB_ID HIGHLIGHT_PATH

            Tab IDs come from gloamux tabs list and stay the same while the tab is open, in any window.
            broadcast types into the panes of a split. multiexec types into every terminal of the tab's window.
            read prints the visible screen, or the last LINES lines with scrollback. run presses Return after the text.
            A risky command in a confirming environment waits for your answer in Gloamux.
            Encodings: utf8, big5, gb18030, shiftJIS, eucJP, eucKR, latin1. Needs the running app.
            """,
        "forwards": """
            list SESSION | remove SESSION RULE_ID
            add SESSION KIND LISTEN_PORT [HOST DESTINATION_PORT]
            live-list [TAB_ID] | stop TAB_ID FORWARD_ID
            start TAB_ID KIND LISTEN_PORT [HOST DESTINATION_PORT]

            Kinds: local, remote, dynamic. Use 0 for an automatic listening port.
            live-list without TAB_ID lists every open SSH tab in every window with its running forwards.
            """,
        "commands": """
            list | add NAME TEXT | edit COMMAND_ID NAME TEXT | remove COMMAND_ID
            send COMMAND_ID TAB_ID | run COMMAND_ID TAB_ID

            send types the command into the tab; run also presses Return. Both need the running app.
            """,
        "triggers": """
            list | enable TRIGGER_ID | disable TRIGGER_ID | remove TRIGGER_ID
            add NAME PATTERN [ACTION [MATCH [CASE]]]
            edit TRIGGER_ID NAME PATTERN [ACTION [MATCH [CASE]]]

            Actions: notify, sound, mark. Match: text or regex. Case: ignore-case or match-case.
            """,
        "runbooks": """
            list | show NAME | create NAME | import MARKDOWN_PATH | delete NAME
            run NAME TAB_ID [BLOCK]

            run starts the shell blocks in the tab and stops at the first failure; show prints the latest results.
            Sessions tagged with a confirming environment run runbooks from Gloamux, after review. delete moves the file to the Trash.
            """,
        "settings": """
            list | get NAME | set NAME VALUE | reset NAME

            Use on or off for switches. safety.confirm-environments takes a comma-separated list or -.
            safety.risky-patterns takes a JSON array of regular expressions. language needs the running app.
            """,
        "layout": "get | set default|classic|workbench",
        "agents": """
            status | history [COUNT] | revoke [SESSION] | off

            Agents reach Gloamux through gloamux mcp. Turn agent access on and allow sessions in Gloamux, in Settings › Agents.
            revoke removes one session, or with no SESSION turns access off and removes every session. Proposals waiting
            for review can no longer run once access is revoked.
            """,
        "config": """
            export PATH | import PATH

            export saves sessions with their accounts, quick commands, triggers, runbooks, host keys, the theme, the layout,
            and settings in one file, and writes PATH.sha256 next to it. No passwords are included.
            import replaces all of these. Quit Gloamux first. The current ones are kept in the Backups folder of the workspace.
            When PATH.sha256 is there, the backup must match it.
            """,
        "vault": "status | lock\nUnlock the vault in Gloamux, or pass --vault-password-stdin to gloamux files or gloamux ssh.",
        "signins": "list | remove ID\nGloamux asks for Touch ID or the Mac password first. Saved passwords are never printed.",
        "workspace": "lock\nCovers every terminal until you unlock Gloamux with Touch ID or the Mac password.",
        "xserver": "status | start\nstart opens XQuartz, the X server that shows remote X11 programs on this Mac. Gloamux does not need to be open.",
        "appearance": "list | get | set THEME_ID"
    ]

    @MainActor static func run(_ command: String, _ arguments: [String]) async throws {
        if command == "completion" {
            try completion(arguments)
            return
        }
        if arguments == ["--help"] || arguments == ["-h"] || arguments.isEmpty {
            print("Usage: gloamux \(command) <operation> [arguments] [--workspace PATH]\n")
            print(help[command] ?? "")
            print("\nResults are emitted as JSON. Use -- before a literal argument that begins with --.")
            return
        }
        if command == "xserver" {
            try await xserver(arguments)
            return
        }
        let args = try CLIArguments(arguments, values: ["--workspace"], switches: ["--json"])
        var request = [command] + args.operands
        if command == "sessions", request.count >= 4, request[1] == "import" {
            request[3] = URL(fileURLWithPath: request[3]).standardizedFileURL.path
        }
        if command == "sessions", request.count >= 4, request[1] == "export" {
            request[3] = URL(fileURLWithPath: request[3]).standardizedFileURL.path
        }
        // Paths are resolved here, since the running app has its own working directory.
        if command == "runbooks", request.count == 3, request[1] == "import" {
            request[2] = URL(fileURLWithPath: request[2]).standardizedFileURL.path
        }
        if command == "config", request.count == 3 {
            request[2] = URL(fileURLWithPath: request[2]).standardizedFileURL.path
        }
        if command == "tabs", request.count == 4, ["colors", "highlights"].contains(request[1]) {
            request[3] = URL(fileURLWithPath: request[3]).standardizedFileURL.path
        }
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
        let args = try CLIArguments(arguments)
        guard args.operands.count == 1, let action = args.operands.first, ["status", "start"].contains(action) else {
            throw CLIUsageError("Usage: gloamux xserver status|start")
        }
        if action == "start" { try await XQuartz.start() }
        try ProductCLI.json(["installed": XQuartz.installedURL != nil, "running": XQuartz.isRunning])
    }

    private static func completion(_ args: [String]) throws {
        if args == ["--help"] || args == ["-h"] { print("Usage: gloamux completion zsh|bash"); return }
        guard args.count == 1, let shell = args.first, ["zsh", "bash"].contains(shell) else {
            throw CLIUsageError("Usage: gloamux completion zsh|bash")
        }
        let names = operations.keys.sorted().joined(separator: " ") + " benchmark help"
        let cases = operations.keys.sorted().map { key in
            "    \(key)) candidates='\(operations[key, default: []].joined(separator: " "))' ;;"
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
