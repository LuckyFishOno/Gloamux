# Gloamux roadmap

[English](ROADMAP.md) · [繁體中文](../zh-TW/ROADMAP.md) · [Back to README](../../README.md)

The [verification record](VERIFICATION.md) includes the November 25, 2026 local serial/terminal checks and the November 24 full application stress baseline.

The [feature backlog](FEATURE-BACKLOG.md) tracks documented workflows from Xshell 8 and MobaXterm 26.6, including their macOS counterparts. Tabby and Termius inform workspace navigation and appearance.

Current release is **Gloamux 1.4.2 (build 11)**. The application and CLI ship together, and Sparkle updates are available from 1.1. The remaining CLI gap is remote desktop input.

Included in 1.4.2 (build 11): the **Session Log** records the commands run in each connection, the jump hosts and proxy it went through, port forwarding, and file changes.

Included in 1.4.1 (build 10): the connection history is a third view in the Default toolbar, **Session Log**, with buttons in Classic and Workbench.

Included in 1.4 (build 9): sessions saved from a pasted `sftp` command, sign-in with a session key, connection history, `gloamux sftp` and `gloamux history`, and a sign-in fix for names whose first address refuses the connection.

Included in 1.3.2 (build 8): the serial form discovers devices on opening and refreshes while visible, fills a blank new target for one USB adapter, and preserves saved or typed paths. Terminal resets now keep the current grid size after resizing, preventing an out-of-bounds redraw. See the [verification record](VERIFICATION.md).

## First milestones

1. Establish the shared application operations and product CLI with saved session listing and connection by profile.
2. Extend the CLI file commands with the remaining file workspace operations.
3. Extend the CLI with remaining GUI operations and live workspace controls.
4. Extend the same shared operations to the local MCP server and the next connection types.

## Command line and MCP

- [ ] **CLI parity.** Every GUI operation must have a supported `gloamux` command. Cover session and folder management, import, authentication and host-key review, terminal and tab control, file transfers, forwarding, saved commands, appearance, and workspace preferences. Apply the same requirement to each new connection type. Commands that display a window can ask the running app to open or arrange it. Covered so far: agent access status, history, and revocation (granting stays in the app), sessions, folders, other connections (serial ports, Telnet, Mosh, containers, pods, and SSM) and the serial devices list, every SSH connection option (`sessions options`), remote desktop tunnels and display options, host key removal, export, and history clearing, host discovery, recordings, tab recording, shell integration, and the terminal or file transfer view, environment tags, import and export, exporting and importing all settings, host keys and their history, `gloamux ssh`, quick connections, tabs and terminals across windows, splits, per-tab colors and highlights, file transfers, forwarding, quick commands, output triggers, runbooks, settings, layout, themes, and locking. Still GUI-only: remote desktop input. Creating, unlocking, or changing the vault and showing saved passwords stay in the app on purpose.
- [x] Share application operations, workspace data, and live session identifiers between the GUI and CLI. Start with session listing and connection by saved profile. Provide stable exit codes and structured output for automation where applicable. Verify each feature through both entry points before marking it complete.
- [x] **Local MCP server.** Expose selected application operations over [MCP stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports). Allow an agent to list approved sessions, open or locate an approved connection, read a user-shared excerpt of terminal output, and prepare a command for review in Gloamux. Done as `gloamux mcp`, which forwards each tool call to the running app.
- [x] Provide opt-in MCP access, per-session permissions, a visible activity history, and immediate revocation. Show the full command and destination before execution and require confirmation in Gloamux. Keep credentials inside Gloamux and bind approvals to a specific live session.

## File transfers

- [x] **SFTP GUI.** Browse, upload, download, rename, and delete files over an existing SSH connection. Saved profiles can open directly to the file browser.
- [x] **SFTP layout.** Show remote files beside the terminal in the Workbench side rail, optionally following the shell's folder.
- [x] **Remote file tree and File Transfer window.** The Default layout's right sidebar shows the focused pane's files as a folder tree: the server's login folder, or this Mac's home folder for the local terminal. A two-pane view (this Mac and a server, like WinSCP or FileZilla) takes the Default layout's main window and opens in its own window from the Classic and Workbench layouts. It provides Finder drag and drop, recursive folder transfers, a queue with cancellation, replace-or-skip conflict handling, and pipelined SFTP reads and writes.
- [x] **SFTP workspace and CLI.** Directory following, hidden files, multiple selection, multi-file upload and download from the file sidebar, per-transfer progress, Quick Look, removing folders with their contents, permissions, dragging to Finder, transfer resume, and remote editing with explicit upload and conflict handling are done. `gloamux files` provides the same file operations: listing, details, upload and download of files and whole folders with resume, folders, renaming, removal of files and folders with their contents, and permissions.
- [x] **SFTP gateways.** Paste an `sftp` command once to save it as a session that asks only for a session key, and keep a history of every connection.
- [x] **FTP and FTPS GUI.** Connect with saved profiles and use the file browser and queue. Passive FTP, explicit and implicit FTPS, certificate verification, and protected data connections have loopback tests.
- [x] **SCP GUI.** Upload and download using legacy SCP and the saved SSH authentication. Choose SCP, SFTP, or SCP fallback. The fallback and both transfer directions are tested against OpenSSH with SFTP disabled.
- [x] **File CLI across protocols.** Use saved profiles to list, inspect, upload, download, resume supported transfers, rename, create and remove directories, remove files, and set permissions through SFTP, SCP, FTP, and FTPS.
- [x] **Workspace CLI foundation.** Manage saved sessions and folders, import profiles, review SSH host keys, control tabs, manage SSH forwards and quick commands, and select a theme. Provide JSON output, exit codes, and Zsh and Bash completion.
- [x] **Transfers across protocols.** Progress, cancellation, overwrite handling, the queue, keeping existing files intact on failure, retries after a broken connection, and resume for SFTP and FTP are shared and tested on disposable fixtures.

## SSH and terminal

- [x] Three workspace layouts (Default, Classic, and Workbench) with a toolbar menu that applies at once, a persisted choice, and CLI get/set. The Classic toolbar and the Workbench ribbon reach the session log, highlight sets, triggers, the workspace lock, MultiExec, XQuartz, saved passwords, and the tunnel list.
- [x] Preview and import OpenSSH configuration with includes, wildcard defaults, agent settings, and jump routes. Support Ed25519, ECDSA, and RSA key files and agent keys, up to eight jump hosts, and SOCKS4/4a/5 and HTTP CONNECT proxies.
- [x] Start and stop local, reverse, and dynamic forwarding in the app. Save rules in a connection profile and start them after connect.
- [x] Use Touch ID to reopen the password vault during the same app launch. Create, show, and regenerate an app-managed Secure Enclave SSH key without per-connection Touch ID.
- [x] Save a password or key passphrase on this Mac after it first signs in, so it connects after a restart without unlocking. Optionally ask for Touch ID or the Mac password on every connection.
- [x] Keyboard-interactive authentication and multi-factor login, including multi-round prompts and public key plus verification code, through RFC 4256 support added to the vendored NIOSSH.
- [ ] Verify keyboard-interactive sign-in against a real OpenSSH server with PAM and a one-time code.
- [x] Per-session SSH agent forwarding and Ed25519 key file generation.
- [x] Connection recovery: a configurable keepalive, a check after the Mac wakes, and optional automatic reconnect for saved sessions.
- [x] Multi-pane workspace: split any pane side by side or stacked without a pane limit, drag dividers, maximize and restore a pane, and type into all panes at once.
- [x] Reopen the last launch's tabs, select tabs by number, reorder and rename tabs, confirm before closing, lock the workspace, and run startup commands per session.
- [x] Tab duplication, and moving a tab to its own window and back to the tab bar.
- [x] Saved quick commands with search, insertion, and confirmation before running.
- [x] Shell integration: OSC 133 prompt marks (jump between prompts, select output, exit status, notifications for long commands in hidden tabs), OSC 7 folders for new tabs and the file tree, and OSC 8 and detected links. Also the ⌘⇧P command palette, recordings with secret redaction and asciinema export, Markdown runbooks, environment tags with confirmation of risky commands, and `docker`, `kubectl`, and SSM sessions.
- [x] Terminal search with regular expressions, session logs, the bell, fonts and zoom, cursor shapes, background opacity, scrollback length, per-session encodings, input method composition, mouse and focus reporting, multiline paste preview, and opt-in OSC 52 clipboard writes.
- [x] Output triggers that notify, play a sound, or mark the tab when a line matches.
- [x] Output and disconnect indicators on tabs, besides a finished long command and the bell.
- [x] Rewrap text when the terminal width changes.
- [ ] Expand compatibility testing with Vim, tmux, and Chinese input methods.
- [x] Session import and export, including MobaXterm and CSV. Support sharing profiles with a team without including credentials. Imports also read PuTTY and KiTTY registry exports and Gloamux sessions files; exports write Gloamux sessions files, CSV, and OpenSSH configuration without passwords.

## Other connections

- [x] **Embedded RDP and VNC.** Save both protocols in the session tree. Sign in, view the desktop, and use the keyboard and pointer in a Gloamux tab. Local fixtures cover RDP certificate approval and NLA, and verify frame decoding and input for both protocols.
- [x] RDP resolution changes, full screen, and reconnection. VNC clipboard. RDP and VNC through an SSH tunnel.
- [x] RDP clipboard text.
- [x] Verify desktop workflows on a real Windows server.
- [ ] Verify desktop workflows on a real VNC server, such as macOS Screen Sharing.
- [x] Open built-in or USB serial devices with configurable baud rate, data bits, parity, stop bits, and flow control.
- [x] Forward X11 from a trusted SSH shell to XQuartz. The loopback test checks authorization replacement, rejected connections, and shell teardown.
- [x] Open Mosh sessions using the installed client and Telnet sessions with built-in negotiation for terminal type and window size.
- [ ] Verify X11 rendering and input with XQuartz.

## Utilities and team use

- [x] A menu bar item with quick connect, recent sessions, and saved tunnels; saved sessions in Spotlight and Shortcuts; Quick Look for remote files; host discovery through Bonjour, Tailscale, and AWS; reachability in the session tree; and a host key history.
