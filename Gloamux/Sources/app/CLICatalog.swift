import Foundation

/// One `gloamux` command as the command line, its help, and shell completion describe it.
public struct CLICommand: Sendable {
    /// Which part of the program carries out the command.
    public enum Runner: Sendable {
        /// Operations on a workspace, run by the running app or, without it, here (`WorkspaceCommand.run`).
        case workspace
        case ssh, sftp, files, mcp, xserver, completion, benchmark
    }

    public let name: String
    /// The line in `gloamux --help`.
    public let summary: String
    public let runner: Runner
    /// Every operation the command accepts, in the order help and completion list them.
    public let operations: [String]
    /// What `gloamux NAME --help` explains. ssh, mcp, and benchmark print their own.
    public let help: String?
    /// For each operation, the positions of its arguments (after the operation) that name a file on this Mac. The
    /// command line makes them absolute, since the running app has its own working directory.
    public let localPaths: [String: [Int]]

    init(_ name: String, summary: String, runner: Runner, operations: [String] = [], localPaths: [String: [Int]] = [:],
         help: String? = nil) {
        self.name = name
        self.summary = summary
        self.runner = runner
        self.operations = operations
        self.localPaths = localPaths
        self.help = help
    }
}

/// The public `gloamux` commands and their operations. The top-level usage, each command's help, shell completion,
/// and the check on every workspace request come from this list, so a new operation is added here once.
public enum CLICatalog {
    /// In the order `gloamux --help` lists them.
    public static let commands: [CLICommand] = [
        CLICommand("ssh",
                   summary: "Open a saved SSH session in this terminal",
                   runner: .ssh),
        CLICommand("files",
                   summary: "Browse, transfer, and manage files over SFTP, SCP, FTP, or FTPS",
                   runner: .files,
                   operations: ["ls", "pwd", "stat", "get", "put", "mkdir", "mv", "rm", "rmdir", "chmod"],
                   help: """
            Usage: gloamux files <operation> --session <name-or-id> [options] [paths]
              ls [REMOTE]                  List a directory (default: .)
              pwd                          Print the remote working directory
              stat REMOTE                  Show file attributes
              get REMOTE LOCAL             Download a file, or a folder with --recursive
              put LOCAL REMOTE             Upload a file, or a folder with --recursive
              mkdir REMOTE                 Create a directory
              mv FROM TO                   Rename or move a remote item
              rm REMOTE                    Remove a file, or a folder and its contents with --recursive
              rmdir REMOTE                 Remove an empty directory
              chmod MODE REMOTE            Set octal permissions (for example, 0644)

            Options:
              --workspace PATH             Use a separate Gloamux workspace
              --protocol sftp|scp|ftp|ftps Override SFTP/SCP or require the saved profile's protocol
              --password-stdin             Read the password or key passphrase as one line
              --vault-password-stdin       Unlock the vault for this command (first line if both are set)
              --host-key FINGERPRINT       Permit a verified new SSH host key for this run (repeatable)
              --interactive                Answer SSH keyboard-interactive prompts on the terminal
              --allow-plain-ftp            Allow cleartext FTP from a saved FTP profile
              --overwrite                  Replace an existing download or upload
              --resume                     Continue a partial download or upload by its current size
              --recursive                  Copy or remove a folder with everything in it; LOCAL or REMOTE
                                           names the folder itself. Symbolic links on this Mac are skipped.
              --json                       Print a JSON result
              --                           Treat remaining arguments as paths
            """),
        CLICommand("sftp",
                   summary: "Copy files over one SFTP connection, like sftp",
                   runner: .sftp),
        CLICommand("sessions",
                   summary: "List and manage saved sessions and folders",
                   runner: .workspace,
                   operations: ["list", "show", "mkdir", "add", "add-other", "edit", "options", "edit-other", "serial-ports", "rename", "move", "remove", "env", "auth", "cert", "from-sftp", "import", "export"],
                   localPaths: ["import": [1], "export": [1]],
                   help: """
            list | show ITEM
            mkdir NAME [FOLDER]
            add NAME PROTOCOL HOST USER [PORT [FOLDER]]
            edit ITEM HOST USER PORT
            options ITEM SETTING=VALUE ...
            add-other NAME KIND TARGET [SETTING=VALUE ...] | edit-other ITEM SETTING=VALUE ...
            serial-ports
            rename ITEM NAME | move ITEM FOLDER | remove ITEM
            env ITEM production|staging|test|development|-
            auth ITEM password|agent|key|questions|session-key [ABSOLUTE_KEY_PATH]
            cert ITEM VERIFIED_FTPS_SHA256
            from-sftp NAME 'SFTP COMMAND' [FOLDER]
            import FORMAT PATH [IMPORT_NAME [FOLDER]]
            export FORMAT PATH [ITEM]

            Use an item UUID or its unique name. Use - for the top level or an empty username.
            Protocols: ssh, sftp, scp, ftp, ftps, ftps-implicit, rdp, vnc.
            Import formats: openssh, xshell, mobaxterm, putty, csv, gloamux. Omit IMPORT_NAME for a preview.
            Export formats: openssh, csv, gloamux.

            Other connections, with TARGET and their settings (folder=FOLDER works for all; - resets a setting):
              serial  DEVICE    baud=9600 data-bits=8|7|6|5 parity=none|odd|even stop-bits=1|2
                                flow=none|rts-cts|dtr-dsr|xon-xoff encoding=utf8
              telnet  HOST      port=23 encoding=utf8
              mosh    HOST      user=USER port=22 (the SSH port)
              docker  CONTAINER context=CONTEXT shell=/bin/sh user=USER
              kubectl POD       context=CONTEXT namespace=NAMESPACE container=CONTAINER shell=/bin/sh
              ssm     INSTANCE  profile=AWS_PROFILE region=REGION
            SSH connections take these with options (- resets a setting):
              jump=ITEM[,ITEM...] proxy=socks5|socks4|http proxy-host=HOST proxy-port=1080
              startup='COMMAND\\nCOMMAND' forward-agent=on|off x11=on|off open-files=on|off
              files=auto|sftp|scp algorithms=modern|compatible encoding=utf8 confirm=on|off
              remote-folder=PATH local-folder=PATH
            FTP connections take confirm=on|off. Changing confirm asks for Touch ID or the Mac password in Gloamux.
            Remote desktops saved with add take these with edit-other:
              rdp       gateway=SSH_ITEM resolution=fit|1920x1080 retina=on|off quality=lan|broadband|low clipboard=on|off
              vnc       gateway=SSH_ITEM clipboard=on|off
            auth takes password, agent, key PATH, questions (answer the server each time), or session-key (enter a key in
            place of the user name each time). from-sftp saves the session an sftp command describes; a key in it is not saved.
            serial-ports lists the serial devices connected to this Mac. edit-other also takes target=TARGET.
            Open a saved session with gloamux tabs open ITEM.
            """),
        CLICommand("hosts",
                   summary: "List and review saved SSH host keys",
                   runner: .workspace,
                   operations: ["list", "history", "trust", "replace", "remove", "export", "clear-history", "discover"],
                   help: """
            list | history | clear-history
            trust '[HOST]:PORT' 'TYPE PUBLIC_KEY' VERIFIED_SHA256
            replace '[HOST]:PORT' 'TYPE PUBLIC_KEY' VERIFIED_SHA256 PREVIOUS_SHA256
            remove '[HOST]:PORT' | export ABSOLUTE_KNOWN_HOSTS_PATH
            discover bonjour|tailscale|aws [profile=AWS_PROFILE region=REGION] [add=all|ID,ID user=NAME [ssm=on]]
            remove forgets a trusted key, so the next connection asks again. clear-history keeps the trusted keys.
            discover lists SSH hosts on this network, Tailscale peers, or running EC2 instances; add= saves the chosen ones
            in a new folder. AWS instances become SSM sessions with ssm=on.
            """),
        CLICommand("tabs",
                   summary: "Control tabs and terminals in the running app",
                   runner: .workspace,
                   operations: ["list", "show", "open", "open-window", "connect", "local", "select", "rename", "duplicate", "close", "disconnect", "reconnect", "split", "unsplit", "broadcast", "multiexec", "window", "attach", "read", "send", "run", "paste-history", "readonly", "timestamps", "copy-mode", "zmodem", "log", "encoding", "colors", "highlights", "record", "integration", "view"],
                   localPaths: ["colors": [1], "highlights": [1], "zmodem": Array(2..<34)],
                   help: """
            list | show TAB_ID
            open SESSION | open-window SESSION | connect USER@HOST[:PORT] | local
            select TAB_ID | rename TAB_ID NAME | duplicate TAB_ID | close TAB_ID
            disconnect TAB_ID | reconnect TAB_ID
            split TAB_ID left|right|top|bottom OTHER_TAB_ID | unsplit TAB_ID | broadcast TAB_ID on|off
            multiexec TAB_ID on|off
            window TAB_ID | attach TAB_ID
            read TAB_ID [LINES] | send TAB_ID TEXT | run TAB_ID COMMAND_LINE
            paste-history [TAB_ID ENTRY]
            readonly TAB_ID on|off | timestamps TAB_ID on|off | copy-mode TAB_ID on|off
            zmodem TAB_ID [status | send PATH... | cancel]
            log TAB_ID on|off | record TAB_ID on|off | encoding TAB_ID ENCODING
            integration TAB_ID | view TAB_ID terminal|files|session-log
            colors TAB_ID XCS_PATH | highlights TAB_ID HIGHLIGHT_PATH

            Tab IDs come from gloamux tabs list and stay the same while the tab is open, in any window.
            record saves what the terminal shows, with secrets masked; list them with gloamux recordings.
            integration types the shell integration hook into the terminal. view switches the window to the terminal, to
            two-pane file transfer for the tab, or to the session log.
            broadcast types into the panes of a split. multiexec types into every terminal of the tab's window.
            read prints the visible screen, or the last LINES lines with scrollback. run presses Return after the text.
            timestamps shows beside each line when it last changed. copy-mode shows the tab and lets the keyboard select
            its text, as Terminal > Copy mode does.
            zmodem reports the tab's ZMODEM transfer. Running sz on the server saves its files in the
            terminal.zmodem-folder setting (Downloads by default); running rz waits for files, which send answers with up
            to 32 paths, as the file panel in Gloamux does. cancel stops a transfer.
            paste-history lists text copied from or pasted into terminals since the app opened, newest first, or pastes
            entry ENTRY into a tab. Text with a recognized secret is never kept.
            A risky command in a confirming environment waits for your answer in Gloamux.
            Encodings: utf8, big5, gb18030, shiftJIS, eucJP, eucKR, latin1. Needs the running app.
            """),
        CLICommand("web",
                   summary: "Open web pages in the browser panel of the running app",
                   runner: .workspace,
                   operations: ["show", "hide", "list", "open", "select", "close", "status", "go", "back", "forward", "reload", "stop", "zoom", "external", "trust", "refuse", "clear-data"],
                   help: """
            show [URL] | hide | list | open URL | select PAGE | close PAGE
            status PAGE | go PAGE URL | back PAGE | forward PAGE | reload PAGE | stop PAGE
            zoom PAGE PERCENT | external PAGE
            trust PAGE VERIFIED_SHA256 | refuse PAGE
            clear-data

            The browser panel at the right of the active window shows web pages as tabs. PAGE is a page's ID from
            list, or current for the page the panel shows.
            show and hide open and close the panel; show URL also opens the address in the page it shows. open opens
            an address in a new page. An address without http:// or https:// gets one as a browser adds it, and
            text that is not an address, such as words or a single word without a dot, is searched on Google.
            status prints the address, title, zoom, and any certificate question, sign-in, error, or download.
            external opens the page in the default browser.
            trust trusts the certificate a page is asking about until Gloamux quits, after you compare its SHA-256
            fingerprint from status. refuse leaves the page closed. Sign-ins a page asks for are answered in Gloamux.
            Pages keep cookies and sign-ins in memory only; clear-data deletes them and the trusted certificates and
            opens each page again, as Clear website data in the app does.
            Downloads go to the Downloads folder. Needs the running app.
            """),
        CLICommand("forwards",
                   summary: "Manage SSH forwarding rules",
                   runner: .workspace,
                   operations: ["list", "add", "remove", "live-list", "start", "stop"],
                   help: """
            list SESSION | remove SESSION RULE_ID
            add SESSION KIND LISTEN_PORT [HOST DESTINATION_PORT]
            live-list [TAB_ID] | stop TAB_ID FORWARD_ID
            start TAB_ID KIND LISTEN_PORT [HOST DESTINATION_PORT]

            Kinds: local, remote, dynamic. Use 0 for an automatic listening port.
            live-list without TAB_ID lists every open SSH tab in every window with its running forwards.
            """),
        CLICommand("commands",
                   summary: "Manage saved quick commands and type them into tabs",
                   runner: .workspace,
                   operations: ["list", "add", "edit", "remove", "send", "run"],
                   help: """
            list | add NAME TEXT | edit COMMAND_ID NAME TEXT | remove COMMAND_ID
            send COMMAND_ID TAB_ID | run COMMAND_ID TAB_ID

            send types the command into the tab; run also presses Return. Both need the running app.
            """),
        CLICommand("triggers",
                   summary: "Manage output triggers",
                   runner: .workspace,
                   operations: ["list", "add", "edit", "enable", "disable", "remove"],
                   help: """
            list | enable TRIGGER_ID | disable TRIGGER_ID | remove TRIGGER_ID
            add NAME PATTERN [ACTION [MATCH [CASE]]]
            edit TRIGGER_ID NAME PATTERN [ACTION [MATCH [CASE]]]

            Actions: notify, sound, mark. Match: text or regex. Case: ignore-case or match-case.
            """),
        CLICommand("runbooks",
                   summary: "Manage and run Markdown runbooks",
                   runner: .workspace,
                   operations: ["list", "show", "create", "import", "delete", "run"],
                   localPaths: ["import": [0]],
                   help: """
            list | show NAME | create NAME | import MARKDOWN_PATH | delete NAME
            run NAME TAB_ID [BLOCK]

            run starts the shell blocks in the tab and stops at the first failure; show prints the latest results.
            Sessions tagged with a confirming environment run runbooks from Gloamux, after review. delete moves the file to the Trash.
            """),
        CLICommand("recordings",
                   summary: "List, export, or remove terminal recordings",
                   runner: .workspace,
                   operations: ["list", "export", "remove"],
                   help: """
            list | export FILE ABSOLUTE_CAST_PATH | remove FILE
            Recordings are asciinema .cast files with secrets masked. Start and stop one with gloamux tabs record.
            remove moves the file to the Trash.
            """),
        CLICommand("history",
                   summary: "List or export the connection history",
                   runner: .workspace,
                   operations: ["list", "show", "log", "export", "remove", "clear"],
                   localPaths: ["log": [1], "export": [0]],
                   help: """
            list [COUNT [SEARCH]] | show ID | log ID PATH | export PATH.csv|PATH.json | remove ID | clear

            Each connection is one record: when, where, through which jump hosts or proxy, how it ended, the commands run in
            it, and the files copied or changed and ports forwarded. log writes one record as text, with its terminal log
            when there is one. Turn history off with gloamux settings set history.enabled off, or only the commands with
            gloamux settings set history.commands off.
            """),
        CLICommand("appearance",
                   summary: "Manage the workspace theme",
                   runner: .workspace,
                   operations: ["list", "get", "set"],
                   help: "list | get | set THEME_ID"),
        CLICommand("settings",
                   summary: "Get or change settings",
                   runner: .workspace,
                   operations: ["list", "get", "set", "reset"],
                   help: """
            list | get NAME | set NAME VALUE | reset NAME

            Use on or off for switches. safety.confirm-environments takes a comma-separated list or -.
            safety.risky-patterns takes a JSON array of regular expressions. language needs the running app.
            """),
        CLICommand("layout",
                   summary: "Get or set the workspace layout, or show the dropdown window",
                   runner: .workspace,
                   operations: ["get", "set", "dropdown"],
                   help: """
            get | set default|classic|workbench | dropdown

            dropdown shows or hides the dropdown window, as its hotkey does. Choose the key with
            settings set dropdown-hotkey off|control-grave|option-grave|option-space|f12.
            """),
        CLICommand("config",
                   summary: "Export or import all settings in one file",
                   runner: .workspace,
                   operations: ["export", "import"],
                   localPaths: ["export": [0], "import": [0]],
                   help: """
            export PATH | import PATH

            export saves sessions with their accounts, quick commands, triggers, runbooks, host keys, the theme, the layout,
            settings, and the password vault in one file, and writes PATH.sha256 next to it. The vault stays sealed under
            its master password, which is not in the file. Passwords remembered on this Mac are not included.
            import replaces all of these; the vault only when the backup has one. Quit Gloamux first. The current ones are
            kept in the Backups folder of the workspace.
            When PATH.sha256 is there, the backup must match it.
            """),
        CLICommand("mcp",
                   summary: "Serve allowed sessions to an AI agent over MCP",
                   runner: .mcp),
        CLICommand("agents",
                   summary: "Show agent access and its history, or revoke it",
                   runner: .workspace,
                   operations: ["status", "history", "clear-history", "revoke", "off"],
                   help: """
            status | history [COUNT] | clear-history | revoke [SESSION] | off

            Agents reach Gloamux through gloamux mcp. Turn agent access on and allow sessions in Gloamux, in Settings › Agents.
            revoke removes one session, or with no SESSION turns access off and removes every session. Proposals waiting
            for review can no longer run once access is revoked.
            """),
        CLICommand("vault",
                   summary: "Show or lock the password vault",
                   runner: .workspace,
                   operations: ["status", "lock"],
                   help: """
            status | lock
            Unlock the vault in Gloamux, or pass --vault-password-stdin to gloamux files or gloamux ssh.
            """),
        CLICommand("signins",
                   summary: "List or remove saved passwords",
                   runner: .workspace,
                   operations: ["list", "remove"],
                   help: """
            list | remove ID
            Gloamux asks for Touch ID or the Mac password first. Saved passwords are never printed.
            """),
        CLICommand("workspace",
                   summary: "Lock the workspace",
                   runner: .workspace,
                   operations: ["lock"],
                   help: """
            lock
            Covers every terminal until you unlock Gloamux with Touch ID or the Mac password.
            """),
        CLICommand("xserver",
                   summary: "Check or start XQuartz for remote X11 programs",
                   runner: .xserver,
                   operations: ["status", "start"],
                   help: """
            status | start
            start opens XQuartz, the X server that shows remote X11 programs on this Mac. Gloamux does not need to be open.
            """),
        CLICommand("completion",
                   summary: "Print shell completion setup",
                   runner: .completion,
                   operations: ["zsh", "bash"]),
        CLICommand("benchmark",
                   summary: "Benchmark the terminal",
                   runner: .benchmark)
    ]

    /// Requests that Gloamux itself sends through the command channel; they are not typed at the command line.
    /// `agent` carries the tools of `gloamux mcp`.
    public static let internalCommands: Set<String> = ["agent"]

    public static func command(_ name: String) -> CLICommand? { commands.first { $0.name == name } }

    /// Whether a command's arguments ask only for its help: `--help` or `-h`, also next to `--workspace PATH`, which
    /// every command accepts, so `gloamux web --help --workspace PATH` prints help and does not refuse `--help`.
    public static func asksForHelp(_ arguments: [String]) -> Bool {
        var rest: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "--workspace" { _ = iterator.next() } else { rest.append(argument) }
        }
        return rest == ["--help"] || rest == ["-h"]
    }

    /// The text of `gloamux --help`.
    public static var usage: String {
        let width = 13
        let lines = commands.map { ($0.name, $0.summary) } + [("--version", "Print the app version"), ("--self-test", "Check bundled features")]
        return """
        Usage: gloamux <command> [options]

        \(lines.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n"))

        Run gloamux <command> --help for details.
        """
    }

    /// The usage error of a command whose only argument is one of its operations.
    public static func choice(_ name: String) -> String {
        "Usage: gloamux \(name) " + (command(name)?.operations.joined(separator: "|") ?? "")
    }

    /// A workspace request with each local path argument made absolute against `directory`.
    public static func resolvingLocalPaths(_ request: [String], from directory: URL) -> [String] {
        guard request.count > 2, let command = command(request[0]), let positions = command.localPaths[request[1]] else { return request }
        var resolved = request
        for position in positions where position + 2 < resolved.count {
            resolved[position + 2] = URL(fileURLWithPath: resolved[position + 2], relativeTo: directory).standardizedFileURL.path
        }
        return resolved
    }

    /// The remote path count each `gloamux files` operation takes.
    public static let filePaths: [String: ClosedRange<Int>] = [
        "ls": 0...1, "pwd": 0...0, "stat": 1...1, "get": 2...2, "put": 2...2,
        "mkdir": 1...1, "mv": 2...2, "rm": 1...1, "rmdir": 1...1, "chmod": 2...2,
    ]
}
