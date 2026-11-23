# Xshell and MobaXterm feature backlog

[English](FEATURE-BACKLOG.md) · [繁體中文](FEATURE-BACKLOG.zh-TW.md)

Baseline reviewed on November 20, 2026. The backlog covers documented product features, settings, and integration workflows in Xshell 8 and MobaXterm 26.6, including the Professional Customizer and the November 11 Xshell update. Windows-specific workflows have macOS counterparts below. Each checkbox is a Gloamux development item. An open item can include capabilities already present in the app. Optional items that Gloamux does not plan to build were removed on November 22, 2026.

- **Xshell** · [Features and specifications](https://www.netsarang.com/en/xshell-all-features/) · [Version 8 manual](https://www.netsarang.com/docs/Xshell8_manual.pdf) · [What's new](https://www.xshell.com/en/whats-new/) · [Update history](https://www.xshell.com/en/xshell-update-history/)
- **MobaXterm** · [Features](https://mobaxterm.mobatek.net/features.html) · [User guide](https://mobaxterm.mobatek.net/documentation.html) · [Release history](https://mobaxterm.mobatek.net/download-home-edition.html) · [Plugin catalog](https://mobaxterm.mobatek.net/plugins.html) · [Home and Professional editions](https://mobaxterm.mobatek.net/download.html)

## Sessions and workspace

- [x] Start with a local terminal tab. Keep saved sessions in a searchable folder tree with add, edit, rename, duplicate through copy/paste, move, and remove operations.
- [x] Open saved sessions in tabs and in their own windows. Preview Xshell folder imports and keep the imported folder hierarchy.
- [x] Show two independent terminals in side-by-side or stacked layouts.
- [x] Offer Default, Classic, and Workbench layout presets from the top bar and CLI. Apply the saved layout on the next app launch.
- [x] Connect to `user@host` from the command palette, open saved sessions and tabs from the palette, the menu bar, Spotlight, Shortcuts, and `gloamux://` links.
- [x] Connect from the Classic layout's address bar with `ssh://user@host:port`, `user@host`, or a host.
- [x] Reopen the last launch's saved sessions and local terminals as tabs (Settings › General). A failed startup connection leaves the other tabs open.
- [x] Drag tabs onto panes to split them, split without a pane limit, and take a pane out of its split as its own tab.
- [x] Select tabs by number, move through them with shortcuts, reorder them, and rename them.
- [x] Duplicate a tab next to the original, move a tab to its own window, and move that window back to the tab bar without disconnecting.
- [x] Enter full screen from the Classic and Workbench layouts' toolbars, as well as from the window.
- [x] Start the session log, import a highlight set, open the triggers, and lock the workspace from the Classic layout's toolbar.
- [x] From the Workbench layout's ribbon, type into every terminal of the window (MultiExec), start XQuartz, open the saved passwords, and list every connected SSH session's tunnels with their connection counts. The CLI does the same with `gloamux tabs multiexec`, `gloamux xserver`, `gloamux signins`, and `gloamux forwards live-list`.
- [x] Import Xshell folders, MobaXterm exports, OpenSSH config, CSV, PuTTY and KiTTY registry exports, and Gloamux sessions files with a preview. Export Gloamux sessions files and CSV.
- [x] Export profiles for a team without passwords. Keep storage separate for each macOS account.

## SSH, trust, and networking

- [x] Support SSH password and OpenSSH Ed25519 key-file login, host-key review and pinning, and an optional encrypted password vault.
- [x] Support up to eight SSH jump hosts, SOCKS4, SOCKS4a, SOCKS5, and HTTP CONNECT proxies, local, reverse, and dynamic forwarding, and manual reconnect.
- [x] Add keyboard-interactive authentication and multi-factor prompts, including multiple rounds and a public key plus a verification code.
- [x] Sign in with OpenSSH agent keys and with Ed25519, ECDSA, and RSA key files.
- [x] Forward the SSH agent per session, chosen in the connection editor. Generate an Ed25519 key file in the OpenSSH format, optionally encrypted with a passphrase.
- [x] Send a configurable keepalive while idle, check sessions after the Mac wakes, and optionally reconnect a lost saved session (after 2, 5, 10, 30, then 60 seconds).
- [x] Save local, reverse, and dynamic tunnels in a profile and start them after connect. Start, stop, and save rules during an active connection, and from the menu bar. Local listeners use loopback.

## Terminal, appearance, and logging

- [x] Render UTF-8, Unicode line drawing, ANSI attributes, 256 colors, and RGB colors in the terminal. Offer whole-workspace color presets and language settings.
- [x] Show a steady block at the terminal cursor position. Support mouse text selection independently and honor terminal cursor visibility.
- [x] Choose the terminal font and size, zoom with ⌘+ and ⌘− and reset with ⌘0, pick a block, underline, or bar cursor that can blink (programs can change it with DECSCUSR), and lower the background's opacity over a blurred desktop.
- [x] Choose a session's encoding (UTF-8, Big5, GB18030, Shift JIS, EUC-JP, EUC-KR, ISO Latin 1), set the scrollback length, compose with input methods over the cursor, and report mouse clicks, drags, motion, the wheel (X10 and SGR), and focus to programs. Option-drag still selects text.
- [x] Rewrap the main screen and scrollback when the width changes, keeping the cursor and shell integration marks with their text.
- [ ] Add repeatable compatibility checks with tmux, Vim, and full-screen console apps.
- [x] Double-click a word or triple-click a line to select it. Search the terminal and its scrollback with ⌘F, as text or a regular expression, with or without case, with every match highlighted and ⌘G and ⇧⌘G to step through them.
- [x] Preview and edit a multiline paste before it is sent, and let programs write the clipboard with OSC 52 when the user turns it on. Clipboard reads are never answered.
- [x] Import Xshell highlight sets and color matching keywords in a terminal.
- [x] Mark an inactive tab and send a macOS notification when a long command finishes there (with shell integration).
- [x] Ring the bell as a flash or the system sound, or not at all, and mark an inactive tab where it rang. Show the title a program sets in the pane header.
- [x] Confirm before closing a tab that would end something, make a terminal read-only, and lock the workspace manually or after an idle time, unlocking with Touch ID or the Mac password.
- [x] Mark new output on a tab you are not looking at, and a dropped connection on any tab.
- [x] Save session logs as plain text or with escape sequences, for every session or one terminal at a time, with likely secrets masked.
- [x] Save what a terminal shows to a text file or open it in the default text editor.

## Commands, macros, and automation

- [x] Save, search, edit and delete single-line quick commands. Insert them into the selected terminal or confirm before running them.
- [x] Type into every pane of a split group at once, with a toggle to stop.
- [x] Send a line from the Classic layout's compose bar to the current session or to every open session.
- [x] Type a saved session's startup commands into each new shell.
- [x] Add output triggers with literal or regex patterns that notify, play a sound, or mark the tab. Settings › Triggers lists, edits, and disables rules, and each rule fires at most once every 10 seconds per terminal.
- [ ] Release a supported CLI with operation parity across the GUI. Use the same application operations and workspace, stable session IDs, terminal mode, machine-readable output, cancellation, exit codes, and shell completion. Document installation and test both entry points for each GUI feature.
- [x] Ship the `gloamux` executable product with file commands across SFTP, SCP, FTP, and FTPS, session and folder management, import and export, SSH trust review, active-window tab control, saved and live forwarding, quick commands, themes, JSON, exit codes, and Bash and Zsh completion.
- [x] Ship a local MCP server for approved sessions. Provide short shared terminal excerpts, proposed commands, visible activity, per-session permissions, review before a command runs, and revocation. File transfer actions for agents are not built. Leave credential material under Gloamux control.

## File transfer and remote editing

- [x] Browse directories and upload, download, rename, and delete files from an SSH/SFTP session in the GUI. Preserve local files on failed downloads.
- [x] Show the remote file list alongside the terminal in the Workbench layout.
- [x] Show a local file list beside the remote one, follow the shell's current folder, sort columns, and open a saved SSH profile directly in the file browser.
- [x] Show or hide hidden files on both sides of File Transfer.
- [x] Create folders, show permissions and modification times, drag files in from Finder, and upload and download folders recursively with progress.
- [x] Select several files at once in File Transfer, and remove remote folders with their contents.
- [x] Browse the file sidebar like Finder: expand with the arrow, double-click to open, select several files to download, and upload several files at once. Each transfer shows its own row with percent, time left, and size left.
- [x] Change permissions on remote files, and drag remote files and folders out to Finder.
- [x] Queue transfers, cancel one or all, and choose to replace or skip existing files.
- [x] Retry transfers after a broken connection, continue SFTP and FTP copies where they stopped, and keep local and remote files intact after an interruption. SCP copies start over.
- [x] Passive FTP and explicit and implicit FTPS profiles, with certificate verification, protected FTPS data connections, and GUI file operations.
- [x] FTPS data connections resume the control connection's TLS session, so servers that require session reuse, such as vsftpd with `require_ssl_reuse`, can connect.
- [x] Legacy SCP upload and download using SSH trust and authentication. Saved choices include SFTP, SCP, and SCP fallback. The loopback fixture disables SFTP to exercise fallback.
- [x] Preview local and remote files with Quick Look.
- [x] Edit a remote file in a local editor: download, edit, and upload with a conflict check that keeps the file's permissions.

## Desktop and alternate connection types

- [x] **Embedded RDP** · Open saved profiles in Gloamux tabs with TLS, NLA/CredSSP, pane scaling, and keyboard and pointer input.
- [x] **RDP resolution, full screen, and reconnection** · The desktop follows the pane size through Display Control, the header has a full screen button, and a dropped connection reconnects with the terminal reconnect setting.
- [x] **RDP clipboard** · Text is shared both ways over CLIPRDR, with Windows line ends converted.
- [x] **Embedded VNC** · Open saved profiles in Gloamux tabs with classic password or Mac account sign-in, ZRLE, CopyRect, and raw frame updates, server resolution changes, and keyboard and pointer input.
- [x] **VNC clipboard and SSH tunnel** · Text is shared both ways when **Share clipboard** is on. RDP and VNC profiles can connect **Through SSH** with a saved SSH session.
- [x] **Checked on Windows** · RDP sign-in, resizing, full screen, clipboard, reconnection, and the SSH tunnel work against a real Windows server.
- [ ] Check VNC sign-in, clipboard, and the SSH tunnel against a real macOS Screen Sharing server.
- [x] **X11** · Forward from an enabled SSH shell to the local XQuartz display. Test the connection and authorization with a simulated display.
- [ ] **X11 display verification** · Verify app rendering, input, clipboard, and keyboard layouts with XQuartz.
- [x] **Serial** · Select macOS serial and USB devices and configure baud rate, data bits, stop bits, parity, and flow control.
- [x] **Mosh and Telnet** · Open saved or ad hoc Mosh sessions through the installed client and Telnet sessions through Gloamux's connection handler.

## Utilities and distribution

- [x] Show CPU, memory, network, uptime, users, and disk use for this Mac or a Linux server in the Workbench layout's monitoring bar.

## Beyond the Xshell and MobaXterm baseline

These items come from a November 20, 2026 brainstorm. They cover macOS-native, modern terminal, fleet, and quality work that the reference products do not define.

### macOS integration

- [x] Generate a non-exportable SSH key in the Secure Enclave and show the public key for copying to servers.
- [x] Unlock the password vault with Touch ID during the same app launch, and optionally confirm each connection with Touch ID.
- [x] Add a menu bar extra for quick connect, recent sessions, and starting, stopping, and checking saved tunnels.
- [x] Expose saved sessions and common operations through App Intents for Shortcuts and index saved hosts in Spotlight. Use the same shared operations as the CLI.
- [x] Preview remote files with Quick Look.

### Modern terminal features

- [x] Add shell integration with OSC 133 prompt marks: jump between prompts, select a command's output, show exit status, and notify when a long-running command finishes in an inactive tab.
- [x] Track the remote working directory through OSC 7 and use it for the file pane's directory following and for opening new tabs in the same location.
- [x] Support OSC 8 hyperlinks and detected URLs. Evaluate inline images through the sixel, kitty, and iTerm2 protocols with size limits (see the development guide).
- [x] Measure terminal throughput and input latency with repeatable benchmarks. Evaluate Metal rendering against the current renderer.
- [x] Raise parser throughput: write runs of printable ASCII in bulk, decode UTF-8 without a `String` per character, and parse CSI parameters byte by byte (plain text from 22 to about 100 MB/s, colored logs from 17 to 36 MB/s).
- [x] Add a ⌘⇧P command palette that lists every operation through the shared application operations.

### Fleet and environment workflows

- [x] Discover hosts from Bonjour `_ssh._tcp` services, Tailscale peers, and AWS EC2 or SSM inventories. Preview discovered hosts before adding them to the session tree.
- [x] Add `docker exec` and `kubectl exec` session types with saved context, namespace, container, and shell settings.
- [x] Tag sessions as production or another environment. Show the tag on tabs, panes, and the window, and require extra confirmation for configurable destructive command patterns in tagged sessions.
- [x] Show reachability in the session tree and keep a local audit history of host-key changes and approvals.

### Runbooks, recordings, and assistance

- [x] Add Markdown runbooks with executable blocks bound to a selected session. Show each command and destination before it runs and record the results.
- [x] Record terminal sessions with secret redaction, replay them in the app, and export to the asciinema format.

### Quality and distribution

- [ ] Add GitHub Actions CI on a macOS runner for build and Swift tests. Run AppKit interaction tests in a separate job that has an active window session.
- [ ] Add automated terminal compatibility tests based on vttest, and fuzz the escape-sequence parser.
- [ ] Sign and notarize releases, add Sparkle updates, and publish a Homebrew cask.
