# Gloamux user guide

[English](USER-GUIDE.md) · [繁體中文](../zh-TW/USER-GUIDE.md) · [Back to README](../../README.md)

The [verification record](VERIFICATION.md) includes the November 25, 2026 local serial/terminal checks and the November 24 full application stress baseline.

This guide covers everything Gloamux does, in the order you are likely to need it. Menu, button, and setting names follow the English interface. The last sections provide menu, keyboard shortcut, settings, and command-line references.

## Contents

1. [The window](#1-the-window)
2. [Connections and the session tree](#2-connections-and-the-session-tree)
3. [SSH](#3-ssh)
4. [Passwords, keys, and the vault](#4-passwords-keys-and-the-vault)
5. [Terminal](#5-terminal)
6. [Tabs, panes, and windows](#6-tabs-panes-and-windows)
7. [Files](#7-files)
8. [Remote desktop](#8-remote-desktop)
9. [Other connections](#9-other-connections)
10. [Automation](#10-automation)
11. [Safety](#11-safety)
12. [Import, export, and backup](#12-import-export-and-backup)
13. [Appearance and text](#13-appearance-and-text)
14. [Mac integration](#14-mac-integration)
15. [AI agents (MCP)](#15-ai-agents-mcp)
16. [Updates](#16-updates)
17. [Menu reference](#17-menu-reference)
18. [Keyboard shortcuts](#18-keyboard-shortcuts)
19. [Settings reference](#19-settings-reference)
20. [Command-line reference](#20-command-line-reference)

## 1. The window

### Layouts

Choose a layout from the **Layout** menu at the right end of the toolbar. It applies at once and is remembered. Every layout uses the same connections, themes, and tools.

| Layout | What it looks like |
|---|---|
| **Default** | A Mac toolbar, flat tabs, floating panes, the connection tree on the left, and the files sidebar on the right. |
| **Classic** | An icon toolbar, an address bar, the session manager on the left, boxed tabs, a compose bar, and a status bar. |
| **Workbench** | A ribbon of large buttons, numbered tabs, and a side rail that switches the left panel between Sessions, SFTP, and Macros. |

### Default layout toolbar

| Item | What it does |
|---|---|
| Sidebar button (⌃⌘S) | Shows or hides the connection tree. |
| Environment badge | Shows the focused session's environment tag, such as Production. |
| **File Transfer** / **Terminal** / **Session Log** | Switches the window between two-pane file transfer, the terminal, and the [session log](#session-log-page). Choosing a tab leaves the session log. |
| **New connection** menu | **New connection**, **Local terminal**, **Other connection**, **Discover hosts**, and **Import sessions**. |
| **Files** | Shows or hides the focused pane's files on the right. |
| **Quick commands** | Opens the quick commands sidebar. |
| **Color theme** | Opens the theme list in the sidebar. |
| **Layout** | Switches between Default, Classic, and Workbench. |

### Classic layout

- The address bar takes `ssh://user@host:port`, `user@host`, or a host name. Press Return to connect.
- The compose bar under the terminal sends one line to the **Current session** or to **All sessions**. Hide it with **Hide compose bar**.
- The toolbar also starts and stops a session's log, opens the **Session Log**, imports a highlight set, opens the output triggers in Settings, splits panes, and locks the workspace.
- The status bar shows the address, protocol, terminal size, cursor position (`Ln`, `Col`), selected lines, the number of sessions, data received and sent, and Caps Lock.

### Workbench layout

- The side rail switches the left panel between **Sessions** (with quick connect), **SFTP**, and **Macros** (quick commands).
- **MultiExec** types what you type into every terminal of the window at once, split or not, except read-only ones.
- **X server** starts XQuartz. **Saved passwords** opens the saved passwords after Touch ID or the Mac password. **Tunneling** lists every connected SSH session of the window with its running forwards.
- **Follow terminal folder**, under the SFTP browser, shows the folder the remote shell is in after each command. If the shell does not report its folder, Gloamux types a one-line prompt hook into it.
- **Session Log** in the ribbon opens the record of every connection in its own window.
- **Two-pane**, next to the SFTP panel title, opens the two-pane File Transfer window.
- A monitoring bar under the terminal shows CPU, memory, network, uptime, users, and disk use for this Mac or for a Linux server.

## 2. Connections and the session tree

### Open a new connection

1. Choose **File › New connection** (⇧⌘N), or **New connection** in the toolbar.
2. The new connection tab lists **Local**, **SSH**, **RDP**, **VNC**, and **Other connection** from top to bottom. **Local** opens this Mac's login shell in the current tab. The form remembers the last section and other connection kind you used. After choosing Local, the next form starts with the other sections collapsed.
3. Fill in the host, port, and username, and choose **Connect**.
4. After the connection works, choose **Save** to keep it in the tree. Gloamux asks for a name.

For a terminal on this Mac, choose **File › New local terminal** (⌘T). With **New tabs open a local terminal** on in **Settings › Terminal**, the **+** buttons open a local terminal at once instead of the form.

### SSH connection form

| Field | Use |
|---|---|
| **Name**, **Host**, **Port**, **Username** | Where to connect. |
| **Protocol** | SSH, or FTP, **FTPS (explicit, AUTH TLS)**, or **FTPS (implicit TLS)** for file-only connections. |
| Key picker | **Choose private key** opens a private key file. Its menu also offers **Generate new key file**. **Create public key** / **Show public key** manages the Gloamux Secure Enclave key. See [Keys](#keys). |
| **Confirm each connection with Touch ID** | Asks for Touch ID before each connection that uses a key or a remembered password. The first connection, before anything is saved, does not ask. |
| **SSH jump host** | Other saved sessions to connect through, in order, up to eight. **Add jump host** adds the next one and × removes it. Only the first one goes through its own jump host settings. Once connected, the pane header shows the route (A › B › D); click it for each host's address and host key, and **Check from each server** to see where each server received the connection from. Each one should name the host above it. Terminal, Remote files, and port forwards all use the same route. |
| **Proxy type**, **Proxy host**, **Proxy port** | SOCKS4, SOCKS4a, SOCKS5, or HTTP CONNECT. |
| **Forward SSH agent** | Lets the server use this Mac's SSH agent for this session. |
| **Forward X11** | Shows remote X11 programs on this Mac (needs XQuartz). |
| **Open in Remote files** | Opens the files sidebar when the session connects. |
| **Startup commands** | Lines typed into the shell after it opens. |
| **File transfer** | **SFTP, or SCP when SFTP is off**, **SFTP only**, or **SCP only**. |
| **Trusted certificate** | For FTPS, the server certificate's SHA-256 fingerprint you verified. |

### The session tree

- Click a folder to open or close it. Double-click a saved terminal connection to open it in a new tab.
- Drag an item above or below another to reorder it, onto a folder to move it inside, or onto **Root folder** to move it to the top level.
- The sort button next to **+** lists items in your custom order, **Name (ascending)**, or **Name (descending)**, with folders first. While sorted by name, dragging only moves an item into a folder, and the custom order is kept for when you switch back.
- **Search sessions** filters the tree. Searching for a folder lists everything inside it.
- A dot after each visible saved host shows whether its SSH port answers. See [Safety](#11-safety).

The **+** menu offers **New folder**, **Save current connection**, **Other connection**, **Discover hosts**, **Import**, **Export all sessions**, **Expand all**, **Collapse all**, and **Paste at root**.

Right-click a session for:

| Item | What it does |
|---|---|
| **Open in tab** / **Open in new window** | Opens the session. |
| **Session properties** | Edits the connection form. |
| **Rename**, **Copy**, **Cut**, **Paste**, **Delete** | Manages the item. Deleting removes only the saved item; open connections and remote files are unaffected. |
| **Environment** | Tags the session as Production, Staging, Test, or Development. |
| **Allow AI agents** | Lets agents use this session. See [AI agents](#15-ai-agents-mcp). |

Right-click a folder for **Open all in tabs**, **Save current connection here**, **New folder**, **Export folder**, **Environment** (sessions inside inherit it), and the same edit items.

### Discover hosts

**Discover hosts** finds SSH services on this network through Bonjour, Tailscale peers, and running EC2 instances through the AWS command-line tool with your own profile. Review the list, choose a username, and add the ones you want to a new folder. EC2 instances can be added as AWS Systems Manager (SSM) sessions. Nothing is added until you choose. Switching the source or closing the sheet stops the search in progress. The Tailscale and AWS tools must finish within their time limit and print at most 16 MB.

## 3. SSH

### Sign-in methods

- A password, an Ed25519, ECDSA, or RSA key, keys from `ssh-agent`, or the Gloamux key in this Mac's Secure Enclave.
- Servers that ask their own questions (keyboard-interactive), such as a verification code after the password, show them in a sheet. The session's password answers the first password question. Answers are never saved.
- **Sign-in** in a saved session's settings chooses **Password or key**, **Answer the server each time** (no saved password; every question is shown), or **Session key each time**.

### SFTP gateways and session keys

Some access gateways allow only `sftp` and give a new session key in place of the user name.

- Choose **New session from sftp command** in the session tree's **+** menu or the command palette, or paste the command into the palette. The command can span lines and include `lcd`, `cd`, `get`, and `put`.
- Gloamux reads the host, port, sign-in, and folders, and shows options it leaves out under **Not included**. A command whose options change the route or run programs, such as `-J` or `ProxyCommand`, is refused.
- **Save and connect** saves the session and copies the files in the command. **Replace existing files** is off unless you turn it on.
- Later, open that session and enter the new key. You can paste the key alone, `key@host`, or a whole new command; a command for another host or port is refused.
- The key stays in memory until Gloamux quits, the vault is locked, or the server refuses it. It is never saved. These sessions do not reconnect on their own and cannot be jump hosts.
- **Remote folder** and **Folder on this Mac** in the session's settings choose what File Transfer opens first.

### Host keys

- The first connection to a server shows its fingerprint. Compare it with the server's real fingerprint before you trust it.
- If a server's key changes, the connection stops. Verify the new fingerprint before you choose **Update key and reconnect**.
- **Settings › Safety › Host key history** lists every key you trusted, replaced, or declined, and changed keys that blocked a connection.

### Reconnecting

- Typing `exit` or `logout` closes the tab.
- If the connection drops, the tab stays open with **Reconnect**, and the tab shows a red mark.
- With **Reconnect automatically** on in **Settings › Terminal**, a saved session connects again after 2, 5, 10, 30, and 60 seconds. **Disconnect** or closing the tab stops it, even during an attempt. After the Mac wakes, every connection is checked at once.

### Port forwarding

1. In a connected SSH pane, choose the **Port forwarding** button (⇄) in the pane header.
2. Choose the **Forwarding type**: **Local port forwarding**, **Remote port forwarding**, or **Dynamic SOCKS proxy**. Then enter the port, and for local and remote forwards the **Destination host** and **Destination port**.
3. Choose **Start forwarding** to run it now, or **Save rule** to start it every time the session connects.

**Active forwards** lists what is running, with connection counts, and **Stop** ends one. Listeners use loopback by default. In the Workbench layout, **Tunneling** lists running forwards with their connection counts; stop one there, or choose **Manage** to edit the session's rules. The menu bar icon starts and stops sessions that have saved rules.

### X11 forwarding

1. Start XQuartz with the Workbench **X server** button or `gloamux xserver start`.
2. Turn on **Forward X11** in a trusted session's properties.
3. Remote X11 programs open on this Mac while that SSH shell is open.

## 4. Passwords, keys, and the vault

### Sign in once

After a password or key passphrase works, Gloamux keeps it on this Mac, sealed with a Secure Enclave key, so later connections need no typing. New connections start with **Confirm each connection with Touch ID** on; turn it off in the session's properties. A new session's first connection does not ask, because nothing is saved for it yet; type the password, and later connections ask before using it.

**Saved passwords** lists them after Touch ID or the Mac password, with the sessions that use each one, to show, copy, or delete. A copied password is cleared from the clipboard after 60 seconds.

### The password vault (optional)

The vault is a separate store sealed under a master password.

- Unlock it once after opening Gloamux. Until you lock it or quit, no connection asks for Touch ID or the Mac password.
- While it is locked, a session with **Confirm each connection with Touch ID** asks each time; other sessions connect with the password remembered on this Mac.
- When the vault section is collapsed and locked, its Touch ID button unlocks it.
- An account already in the vault shows **In vault** in the connection form. Open it to update the password with the one typed, or to remove it. **Add to vault** saves a password before it has signed in.
- **Lock vault** locks it at once. Passwords remembered before you created the vault stay on this Mac.

### Keys

- **Choose private key** uses an existing private key, such as an EC2 `.pem` file. Its menu includes **Choose key file** and **Generate new key file**. Generation writes an Ed25519 private key and its `.pub` file in `~/.ssh`, with an optional passphrase and comment. Keep the private key on your Mac and put the public key in the server's `~/.ssh/authorized_keys`.
- **Create public key** creates a P-256 key in this Mac's Secure Enclave. **Show public key** shows that Gloamux key's OpenSSH public key, independently of any private key file selected beside it. Choose **Use for this connection** to use the Secure Enclave key. **Regenerate** replaces it, so servers must receive the new public key.
- Removing a key with × asks first. The saved session stops using it, and while the vault is unlocked, the account's saved password and the key's passphrase are deleted too.
- An older Secure Enclave key that still asks for Touch ID shows **Needs Touch ID**. Switch to the Gloamux key to stop the prompt.

### Lock the workspace

**Window › Lock workspace** (⌃⌘L) covers every terminal until you unlock Gloamux with Touch ID or the Mac password. **Settings › General › Lock the workspace** locks it after a time without use.

Each window locks on its own. While a window is locked, `gloamux` commands and agents cannot read, type into, or change its tabs, even when they are sent through another window. `gloamux tabs list` shows only their names, and a runbook or a confirmed command does not continue there until you unlock it.

## 5. Terminal

### Basics

- The cursor follows the shell while the mouse selects text. Text rewraps when the width changes.
- Input methods compose over the cursor.
- ⌘-click a link to open it, both links that programs mark (OSC 8) and plain web addresses.
- vim, tmux, htop, and similar programs get mouse clicks, drags, and the wheel. Hold Option to select text instead.
- Pasting several lines shows them first, so you can check or edit them.
- The bell flashes the terminal or plays a sound, and marks a tab you are not looking at.
- **Terminal › Text encoding** switches a session to UTF-8, Big5, GB18030, Shift JIS, EUC-JP, EUC-KR, or ISO Latin 1. Saved sessions remember it.
- **Terminal › Read-only** stops your typing from reaching the session.

### Shell integration

Local zsh reports each prompt, command, exit status, and folder. For bash, zsh over SSH, or another local shell, choose **Terminal › Enable shell integration**, or turn on **SSH shell integration** in **Settings › Terminal**. Then:

- ⌘↑ and ⌘↓ jump between prompts. ⇧⌘A selects the last command's output.
- The pane header shows the last command's result and how long it ran. Click it for the **Command history**, where you can copy a command or its output.
- When a command that ran 10 seconds or longer (see **Notify after long commands**) finishes in a tab you are not looking at, the tab gets a dot and macOS shows a notification.
- ⌘T opens a new local terminal in the focused local terminal's folder.

### Find

⌘F searches the terminal and its scrollback as plain text or a regular expression and highlights every match. ⌘G and ⇧⌘G step through them.

### Session Log page

- Open it with **Session Log** in the Default toolbar, the Classic toolbar, or the Workbench ribbon, from the **Terminal** menu or the command palette, or by right-clicking a saved session, which shows only records that match its name.
- It lists every connection: when, where, through which jump hosts or proxy, and how it ended. Select one to see what happened in it, in order:
  - **Commands**: each command run in the terminal, however it was entered: typed, recalled, pasted, broadcast, or sent by a quick command, runbook, agent, or `gloamux tabs`.
  - **Files**: downloads, uploads, new folders, renames, deletions, and permission changes.
  - **Connection**: the jump hosts and proxy it went through, sign-in, port forwarding, and how it ended.
- Search finds commands, paths, hosts, and names. **Download log** saves one record as text, with its terminal log when there is one.
- A command is read from the line the terminal shows when you press Return, so a password the server does not show is never recorded, and likely secrets in a command are masked. Text typed into editors and other full-screen programs is left out. Inside tmux, screen, or Mosh a command is recorded when its prompt shows `user@host`. A terminal that opens on this Mac is not a connection and has no record.
- The options menu exports the list as CSV or JSON, clears it, or turns it or **Record commands** off. Right-click a record to delete it.
- Passwords, session keys, and command output are not part of it. A session key is shown as its first four characters. Records are kept for a year, up to 2,000.

### Session logs

- **Terminal › Start session log** (⌥⌘L) saves what a terminal shows to a file, as plain text or with escape sequences. Likely secrets are masked.
- **Settings › Terminal › Log every session** logs every terminal from when it opens.
- **Terminal › Show session logs** opens the folder in Finder.
- **Terminal › Save output** (⇧⌘S) saves what the terminal shows. **Open output in text editor** opens it in your text editor.

### Recordings

- **Terminal › Start recording** (⌥⌘R) records what a terminal shows, never what you type.
- Access keys, tokens, private keys, and password values are replaced with `[REDACTED]` when the recording is saved.
- **Terminal › Recordings** replays them at up to 4× speed and exports them as asciinema `.cast` files.
- Stopping a recording returns at once; Gloamux masks and writes the file in the background, so the window keeps working. Two recordings of the same tab stopped within one second get separate files.
- If a recording cannot be saved, **Recording not saved** appears at the bottom of the window. Gloamux keeps the recording until you choose **Try again** or **Discard**.
- Quitting stops running recordings and waits until they are written. If one cannot be saved, Gloamux asks before quitting: **Don’t Quit** keeps it for another try, **Quit Anyway** discards it.

### Colors

**Terminal › Import color scheme** applies an Xshell `.xcs` color scheme to the session, and **Import highlight set** applies an Xshell highlight set. **Use default colors** goes back to the workspace theme.

## 6. Tabs, panes, and windows

### Tabs

- Tabs shrink to fit the bar, down to an icon. A tab you are not looking at shows a ring when new output arrives.
- Right-click a tab for **Rename tab**, **Duplicate tab**, **Move tab to new window**, **Read-only**, **Move tab left**, **Move tab right**, and **Close**.
- ⌘1 to ⌘8 select a tab by position, and ⌘9 selects the last. ⇧⌘] and ⇧⌘[ show the next and previous tab.
- A tab moved to its own window keeps its connection. The button at the right of that window's title bar, or **Window › Move window to tab bar**, puts it back.

### Split panes

- Drag a tab onto the left, right, top, or bottom edge of a pane to split it on that side, or onto the middle of a pane to show it there.
- ⌘D splits the current pane side by side, and ⇧⌘D splits it top and bottom. Only connected sessions and local terminals split.
- A split shows as one **Workspace** tab whose tooltip lists its panes. Each pane has its own header; drag the header to another edge to move the pane, or onto the tab bar to make it a separate tab again. The × in a pane header disconnects and closes that session.
- Every pane can be split again, and the dividers can be dragged.
- ⇧⌘↩ maximizes or restores a pane. ⌥⌘I types into all panes of the split at once. **Close split view** turns the panes back into tabs.

### Windows

Use **File › New Window** (⌘N), or right-click the Dock icon and choose **New Window**. Each window has its own tabs and uses the same saved connections. Closing the last workspace window quits Gloamux.

## 7. Files

### Files sidebar

1. In the Default layout, choose **Files** in the toolbar.
2. The sidebar shows the focused pane's files: a server pane opens at its login folder, and a local terminal opens at your home folder. Click another pane and the tree switches to it.
3. Click the arrow to expand a folder, double-click to go into it, and use `..` or ⌘↑ to go back up.

- ⌘-click or ⇧-click selects several files to download at once.
- **Upload** in the sidebar title sends files to the selected folder. You can also drop Finder files on a folder.
- Right-click for **Open**, **Expand** or **Collapse**, **Quick Look**, **Download**, **Rename**, **Delete**, **New folder**, **Show in Finder**, and **Copy path**.
- **Follow terminal folder**, at the bottom, keeps the tree on the shell's current folder. It is off by default.
- Drag the sidebar's edge to resize it.

### Transfer progress

Each upload and download gets a row at the bottom of the files sidebar with the percent, time left, and size left. Up to five rows show at once. A finished row stays for 10 seconds.

### File Transfer (two panes)

This Mac is on the left, a connected server on the right, and the transfer queue below.

- Open it with **File Transfer** in the Default toolbar (the tab bar picks the server), the Classic **File Transfer** button, or **Two-pane** in the Workbench SFTP panel.
- Drag files between the panes or use the arrow buttons. Folders copy with everything inside them.
- When names are already taken, choose **Replace** or **Skip existing**.
- Transfers write to a temporary name first and then replace an existing file in one step, so a failed or cancelled transfer leaves the existing file intact. An SFTP server that cannot replace a file in one step refuses the overwrite and keeps its file. A broken connection is retried after 2, 5, and 10 seconds, and SFTP and FTP copies continue where they stopped. A failed transfer has **Try again** in the queue.
- Right-click a remote item for **Download**, **Edit on this Mac**, **Change permissions**, **Rename**, **Copy path**, **Quick Look**, **New remote folder**, and **Delete**. Right-click a local item for **Upload**, **Quick Look**, **Show in Finder**, **Rename**, **New folder**, and **Move to Trash**.
- Press Space for Quick Look. Drag a remote item to Finder to copy it there.

### Edit on this Mac

**Edit on this Mac** opens a remote file of up to 100 MB in its default Mac app, or TextEdit. After you save it there, the files sidebar and the File Transfer queue show **Upload**. Gloamux checks that nobody changed the server's copy since you opened it, asks before replacing it, and keeps the file's permissions.

### Quick Look

**Quick Look** previews remote files up to 100 MB. They are copied to a private temporary folder for the preview and deleted afterward.

### Protocols

SSH sessions use SFTP, legacy SCP, or SFTP with SCP fallback when the server has no SFTP subsystem. FTP and FTPS sessions use FTP, explicit FTPS, or implicit FTPS. FTPS encrypts commands and data. Plain FTP sends everything, the password included, unencrypted.

## 8. Remote desktop

1. Choose **New connection** and expand **RDP** (Windows Remote Desktop) or **VNC** (including macOS Screen Sharing).
2. Enter the host and account. **Remember password** keeps the password after the first successful sign-in.
3. To carry the whole connection over SSH, choose a saved SSH session under **Through SSH**. VNC desktop traffic is unencrypted, so an SSH tunnel protects it. Mac account sign-in encrypts the credentials. Classic VNC password authentication does not encrypt the desktop stream. The desktop opens only its own tunnel through that session, not the session's saved port forwards, and asks about the session's host key and sign-in questions in the desktop pane.

- RDP checks the server certificate and supports Network Level Authentication. VNC supports a classic VNC password, or a Mac account name and password for Screen Sharing.
- An RDP desktop follows the size of its pane. In the connection settings, **Resolution** can fix the remote size, with the image scaled to fit the pane. **Optimize for Retina displays** is available when fitting to the window. **Connection quality** ranges from Best quality (LAN) to Fastest (slow network).
- With **Share clipboard** on, text copied on either side can be pasted on the other, for RDP and VNC.
- The header has a full screen button. A dropped connection reconnects on its own when **Reconnect automatically** is on.
- Printers, smart cards, sound, microphones, cameras, and shared folders are not redirected.

## 9. Other connections

Open or save these from the **Other connection** section of the new connection tab:

| Kind | Settings |
|---|---|
| Serial port | The device (from the connected ones), speed from 300 to 921600, data bits, parity, stop bits, flow control (RTS/CTS, DTR/DSR, or XON/XOFF), and text encoding. |
| Telnet | Host, port, and text encoding. |
| Mosh | Host, user, and SSH port. Uses the `mosh` installed in your login shell. |
| Docker container | Container (the picker lists running ones), context, shell, and user. |
| Kubernetes pod | Pod, context, namespace, container, and shell. |
| AWS Systems Manager | Instance, profile, and region. |

The serial device menu loads when the form opens and refreshes every second while Serial port is selected. A new, blank form fills in the device and name when exactly one USB serial adapter is connected. With multiple adapters, choose one from the menu; existing saved devices and typed paths are kept. The menu also includes Bluetooth and system ports and has **Refresh** for an immediate scan. The command line lists the same available paths with `gloamux sessions serial-ports`.

## 10. Automation

### Quick commands

The **Quick commands** sidebar saves single-line commands.

- **Add command** saves one with a name. **Filter commands** searches them.
- **Insert** types the command into the selected terminal without pressing Return, so you can edit it.
- **Run** shows the command and destination first, then types it and presses Return.

### Output triggers

**Settings › Triggers** watches every terminal's output. **Add trigger**, then set a **Name**, a **Pattern** (text or regular expression, with **Match case**), and the **Action**: show a notification, play a sound, or mark the tab. Each rule fires at most once every 10 seconds per terminal. Triggers never type anything.

If `triggers.json` in the workspace folder cannot be read or is damaged, **Settings › Triggers** says so and Gloamux does not change the file. Repair or restore it, then choose **Try again**.

### Runbooks

**Terminal › Runbooks** keeps Markdown runbooks with `sh`, `bash`, `zsh`, or `console` code blocks.

1. Choose a session.
2. Run one block, or all of them, after confirming the commands and destination. A warning appears for tagged environments.
3. With shell integration, Gloamux waits for each block, stops at the first failure, and keeps each block's exit status and output.

### Typing into several terminals

- ⌥⌘I types into all panes of a split.
- **MultiExec** (Workbench) types into every terminal of the window, except read-only ones.
- The Classic compose bar sends one line to **All sessions**.

### Command palette

⇧⌘P finds a saved session, an open tab, or any workspace action, such as splits, layouts, themes, recordings, and runbooks. Type `user@host` to connect directly, or paste an `sftp` command to save it as a session.

## 11. Safety

### Environments

Tag a session or folder as Production, Staging, Test, or Development from its right-click **Environment** menu. Sessions inherit their folder's tag. The tag colors the tab, frames the pane, and shows in the toolbar and the session window's title.

### Risky commands

In the environments chosen under **Settings › Safety › Confirm risky commands in** (Production and Staging at first), a command that matches a pattern waits for you to confirm it. The patterns cover commands such as `rm -rf`, `shutdown`, `mkfs`, `dd of=`, `DROP TABLE`, `DELETE FROM` without `WHERE`, `kubectl delete`, `terraform destroy`, `git push --force`, `systemctl stop`, and `chmod -R`. Edit them under **Patterns**, one regular expression per line, or choose **Restore defaults**.

### Host reachability

**Show host reachability** opens and closes a TCP connection to each visible saved host's SSH port every few minutes, without signing in, and shows the result as a dot in the tree. Turn it off in **Settings › Safety**.

### Clipboard

Programs can copy to your clipboard with OSC 52 only after you turn on **Let programs copy to the clipboard**. They can never read it.

## 12. Import, export, and backup

### Import sessions

Choose **Import sessions** from the toolbar's **New connection** menu, or **Import** in the tree's **+** menu. Gloamux shows a preview first.

| Source | File |
|---|---|
| Xshell | A session file, a folder of sessions, or a supported `.xts` backup |
| OpenSSH | `~/.ssh/config` or another configuration file |
| MobaXterm | `.mxtsessions` or `MobaXterm.ini` |
| PuTTY and KiTTY | Sessions exported from the registry (`.reg`) |
| CSV | A file with a `host` column |
| Gloamux | A `.gloamuxsessions` file |

Gloamux keeps folders and reads users, ports, keys, proxies, and jump hosts. MobaXterm SSH gateways and PuTTY SSH proxies become jump host sessions, and PuTTY port forwards are kept. Passwords are never imported. The preview lists skipped entries and settings to review, such as key files that were on Windows.

### Export sessions

**Export all sessions** in the **+** menu, or **Export folder** from a folder's right-click menu, writes a Gloamux sessions file, a CSV file, or OpenSSH configuration. These exports contain connection details and key paths. Review them before sharing. Passwords and private key contents are excluded. Key paths in your home folder are written as `~/…`.

CSV columns: `host` (required), and optionally `folder` (for example `Team/Prod`), `name`, `port`, `username`, `protocol` (`ssh` or `sftp`), `identity file`, `proxy type`, `proxy host`, `proxy port`, and `jump` (another row's `folder/name`, or `user@host:port`).

### All settings in one file

**Settings › General › All settings › Export** saves sessions with their accounts, quick commands, triggers, runbooks, host keys, the theme, the layout, settings, and the password vault in one `.gloamuxconfig` file, with a `.sha256` file next to it.

- The vault stays sealed under its master password, which is not in the file. Passwords remembered on this Mac are not included.
- **Import** checks the file against its `.sha256`, replaces all of these, and restarts Gloamux. The previous ones are kept in the `Backups` folder of Gloamux's data folder first.
- A backup without a vault leaves the current vault alone.

## 13. Appearance and text

- **Color theme** in the toolbar, or **Settings › Appearance**, offers 73 workspace themes: Gloamux's own, Linux palettes such as Ubuntu, Kali, GNOME, KDE Breeze, Tango, and the Linux console, and popular Visual Studio Code themes such as GitHub, One Dark Pro, Dracula, Tokyo Night, Catppuccin, Nord, and Gruvbox. Search the list by name. Every terminal uses the selected theme.
- **Settings › Text** sets the session font and size, a block, underline, or bar cursor that can blink, and the background opacity over a blurred desktop.
- Powerline and Nerd Font prompt icons work with **System monospaced** and other session fonts. Gloamux includes a symbol fallback, so these icons need no separate font installation. To use a complete patched text face, install it and select it in **Settings › Text › Font**.
- ⌘+, ⌘−, and ⌘0 change the session font in a terminal. Outside a session, or with ⌥ added anywhere, they change the **Application font size** (8 to 28 pt), which sizes the rest of the interface, including buttons and menus.
- **Language** in **Settings › General** offers English, Traditional Chinese, Simplified Chinese, Japanese, and Spanish. By default Gloamux follows the Mac's language. Gloamux's own text changes at once, and the menus macOS draws change the next time Gloamux opens.

## 14. Mac integration

- **Menu bar** · The terminal icon in the menu bar finds and opens saved sessions, reopens recent ones, starts and stops sessions with saved forwarding rules (showing how many forwards are running), and lists tabs whose commands finished. Turn it off with **Show in menu bar** in **Settings › Terminal**.
- **Spotlight** · Saved sessions appear in Spotlight by name, user, and host, never passwords. Choosing one opens it in Gloamux. Turn it off with `gloamux settings set spotlight off`.
- **Shortcuts** · The Shortcuts app offers **Open Saved Session** and **New Local Terminal**.
- **Siri quit protection** · An open workspace stays running when Siri's task service sends its cleanup Quit request. You can still quit Gloamux with ⌘Q or the Dock.
- **Links** · `gloamux://open?id=SESSION_ID` opens a saved session, and `gloamux://new-terminal` opens a local terminal.
- **Dock** · Right-click the Dock icon for **New Window**.
- **Reopen tabs at launch** · In **Settings › General**, opens the sessions and local terminals that were open when Gloamux quit.

## 15. AI agents (MCP)

Agent access is off until you turn it on.

1. Open **Settings › Agents** and turn on **Allow AI agents**.
2. Copy the **MCP command** (`gloamux mcp`) into your agent's MCP settings. For Claude Code: `claude mcp add gloamux -- /Applications/Gloamux.app/Contents/Resources/bin/gloamux mcp`.
3. Under **Allowed sessions**, choose **Add**, or use **Allow AI agents** in a session's right-click menu.

What an agent can do:

- See the allowed sessions by name and destination. It never receives passwords or keys.
- Open an allowed session in Gloamux.
- Read text you share with **Terminal › Share with Agents**: the selection, the last command's output, or the screen. Recognized passwords, tokens, and private keys are replaced with `[REDACTED]` first. Check what you share, because a secret in another form can be missed.
- Propose a command. Gloamux brings the tab forward and shows the agent, session, destination, reason, and full command. It runs only when you choose **Run**, and only in the same live terminal.

**Activity** lists every request, including refused ones. **Revoke all access** turns agent access off, removes every allowed session, and stops commands waiting for review.

## 16. Updates

- **Gloamux › Check for Updates** looks for a newer release on GitHub, shows what changed, and installs it after checking its signature against the key built into Gloamux. Then Gloamux reopens.
- The second time Gloamux opens, it asks whether to check automatically once a day. **Check for updates automatically** in **Settings › General** changes that.
- Update checks request the feed from GitHub over HTTPS. The User-Agent includes the app and Sparkle versions. GitHub receives the network request and source IP. Gloamux leaves Sparkle system profiling disabled. See [Data protection](DATA-PROTECTION.md).
- Updates start with Gloamux 1.1. Gloamux 1.0 has no updater, so replace it once with the newer DMG.

## 17. Menu reference

| Menu | Item | Shortcut |
|---|---|---|
| **Gloamux** | **About Gloamux** | |
| | **Check for Updates** | |
| | **Settings** | ⌘, |
| **File** | **New Window** | ⌘N |
| | **New connection** | ⇧⌘N |
| | **New local terminal** | ⌘T |
| **Edit** | **Find** | ⌘F |
| | **Find next** | ⌘G |
| | **Find previous** | ⇧⌘G |
| **View** | **Bigger text** / **Smaller text** / **Actual size** | ⌘+ / ⌘− / ⌘0 |
| | **Bigger app text** / **Smaller app text** / **App text actual size** | ⌥⌘+ / ⌥⌘− / ⌥⌘0 |
| | **Split side by side** | ⌘D |
| | **Split top and bottom** | ⇧⌘D |
| | **Maximize pane** / **Restore pane** | ⇧⌘↩ |
| | **Type into all panes** | ⌥⌘I |
| | **Close split view** | |
| **Terminal** | **Command palette** | ⇧⌘P |
| | **Previous prompt** / **Next prompt** | ⌘↑ / ⌘↓ |
| | **Select output of last command** | ⇧⌘A |
| | **Share with Agents** | |
| | **Enable shell integration** | |
| | **Start recording** / **Stop recording** | ⌥⌘R |
| | **Recordings** | |
| | **Start session log** / **Stop session log** | ⌥⌘L |
| | **Session Log** | |
| | **Show session logs** | |
| | **Save output** | ⇧⌘S |
| | **Open output in text editor** | |
| | **Read-only** | |
| | **Import color scheme** / **Import highlight set** / **Use default colors** | |
| | **Text encoding** | |
| | **Runbooks** | |
| **Window** | **Show next tab** / **Show previous tab** | ⇧⌘] / ⇧⌘[ |
| | **Move tab left** / **Move tab right** | |
| | **Rename tab** / **Duplicate tab** | |
| | **Move tab to new window** / **Move window to tab bar** | |
| | **Tab 1** to **Tab 8** / **Last tab** | ⌘1 to ⌘8 / ⌘9 |
| | **Lock workspace** | ⌃⌘L |

## 18. Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New window |
| ⇧⌘N | New connection |
| ⌘T | New local terminal |
| ⌃⌘S | Show or hide the connection tree |
| ⌘, | Settings |
| ⇧⌘P | Command palette |
| ⌘F, ⌘G, ⇧⌘G | Find, find next, find previous |
| ⌘D, ⇧⌘D | Split side by side, split top and bottom |
| ⇧⌘↩ | Maximize or restore the pane |
| ⌥⌘I | Type into all panes |
| ⌘1 to ⌘8, ⌘9 | Select a tab, the last tab |
| ⇧⌘], ⇧⌘[ | Next tab, previous tab |
| ⌘↑, ⌘↓ | Previous prompt, next prompt (shell integration); in the files sidebar, ⌘↑ goes up a folder |
| ⇧⌘A | Select the last command's output |
| ⌥⌘R | Start or stop recording |
| ⌥⌘L | Start or stop the session log |
| ⇧⌘S | Save output |
| ⌘+, ⌘−, ⌘0 | Session text size |
| ⌥⌘+, ⌥⌘−, ⌥⌘0 | App text size |
| ⌃⌘L | Lock the workspace |
| ⌘-click | Open a link in the terminal |
| Option-drag | Select text while a program uses the mouse |
| Control-click | Show the terminal menu when right-click pastes |
| Space | Quick Look in File Transfer; play or pause in Recordings |

## 19. Settings reference

Open Settings with **Gloamux › Settings** (⌘,). Changes apply at once. Each setting has a **!** button with more detail. Most settings can also be read and changed with `gloamux settings`; the name is in parentheses.

### General

| Setting | What it does |
|---|---|
| **Language** (`language`) | The interface language, or the Mac's. |
| **Reopen tabs at launch** (`workspace.reopen-tabs`) | Opens the sessions and local terminals that were open when Gloamux quit. Each connects on its own. |
| **Lock the workspace** (`workspace.lock-after-minutes`) | Locks the workspace after this long without use, or **Never**. |
| **Check for updates automatically** | Checks GitHub for a new version once a day. |
| **All settings** · **Export** / **Import** | Saves or restores everything in one file. See [Backup](#all-settings-in-one-file). |

### Terminal

| Setting | What it does |
|---|---|
| **New tabs open a local terminal** (`terminal.new-tab-local`) | The **+** buttons open a local terminal at once instead of the New connection form. |
| **Local shell integration** (`shell-integration.local`) | zsh reports prompts, commands, exit status, and folders. |
| **SSH shell integration** (`shell-integration.ssh`) | Types a one-line hook into bash or zsh after an SSH terminal opens. |
| **Notify after long commands** (`notify-after-seconds`) | Notifies when a command that ran this long finishes in a tab you are not looking at, or **Off**. |
| **Show in menu bar** (`menu-bar-extra`) | The menu bar icon with quick connect, recent sessions, and tunnels. |
| **Check idle SSH connections** (`ssh.keepalive-seconds`) | After this long without output, asks the server for a reply, so routers keep the connection open and a dead one is noticed. |
| **Terminal type** (`terminal.type`) | The `TERM` value SSH sessions report. Change it only when a server lacks `xterm-256color`. |
| **Reconnect automatically** (`ssh.reconnect`) | Reconnects dropped saved sessions after 2, 5, 10, 30, and 60 seconds. |
| **Scrollback** (`terminal.scrollback`) | Lines kept above the screen in each terminal. |
| **Bell** (`terminal.bell`) | **Flash**, **Sound**, or **Off**. |
| **Confirm multiline paste** (`terminal.confirm-multiline-paste`) | Shows pasted text with line breaks before sending it. |
| **Send mouse to programs** (`terminal.mouse-reporting`) | vim, tmux, and htop get clicks, drags, and the wheel. |
| **Confirm before closing** (`terminal.confirm-close`) | Asks before closing a connected tab, or a local terminal running a command. |
| **Right-click pastes** (`terminal.right-click-paste`) | As in PuTTY. Control-click still shows the menu. |
| **Use Option as Meta** (`terminal.option-as-meta`) | Option and a key send Escape and the key, for word movement in shells and Emacs. |
| **Let programs copy to the clipboard** (`terminal.allow-clipboard-writes`) | Allows OSC 52 clipboard writes. Programs can never read the clipboard. |
| **Log every session** (`terminal.log-every-session`) | Logs every terminal from when it opens until it closes. |
| **Log format** (`terminal.log-format`) | **Plain text**, or **With escape sequences** to keep colors. |
| **Session logs** · **Show in Finder** | Opens the log folder. |
| **Keep connection history** (`history.enabled`) | Saves one record for each connection. On by default. |
| **Record commands** (`history.commands`) | Adds the commands run in a connection to its record. On by default. |

### Text

| Setting | What it does |
|---|---|
| **Application font size** (`app.font-size`) | Lists, forms, toolbars, and Settings, from 8 to 28 pt. |
| **Font** (`terminal.font`) | The session font, or **System monospaced**. |
| **Session font size** (`terminal.font-size`) | The terminal text size. |
| **Cursor** (`terminal.cursor`) | **Block**, **Underline**, or **Bar**. |
| **Blinking cursor** (`terminal.cursor-blinks`) | Programs such as vim can still change it while they run. |
| **Background opacity** (`terminal.opacity`) | Below 100%, what is behind the window shows through, blurred. |

### Triggers

**Output triggers**: **Add trigger**, **Edit**, or **Remove trigger**. See [Output triggers](#output-triggers).

### Safety

| Setting | What it does |
|---|---|
| **Confirm risky commands in** (`safety.confirm-environments`) | The environments where risky commands wait for confirmation. |
| **Patterns** (`safety.risky-patterns`) | One regular expression per line, ignoring case. **Restore defaults** resets them. |
| **Show host reachability** (`reachability`) | The reachability dots in the session tree. |
| **Host key history** · **Show** | Every host key decision. |

### Agents

**Allow AI agents**, **MCP command** with **Copy**, **Allowed sessions** with **Add** and **Remove**, **Activity** with **Clear**, and **Revoke all access**. See [AI agents](#15-ai-agents-mcp).

### Appearance

**Color theme**: the 73 workspace themes.

### Only from the command line

| Name | What it does |
|---|---|
| `spotlight` | Lists saved sessions in Spotlight. |
| `desktop.share-clipboard` | The clipboard sharing default for remote desktops that do not set their own. |

## 20. Command-line reference

`Gloamux.app` includes the `gloamux` command, and `gloam` as a short name for it. Add it to your path:

```sh
export PATH="/Applications/Gloamux.app/Contents/Resources/bin:$PATH"
```

Workspace commands take `--workspace PATH` to use a separate Gloamux workspace. Utility commands such as `--version` and `completion` do not use a workspace. Management commands print JSON. Exit codes are 0 for success, 1 for a failed operation, 2 for invalid usage, and 130 when Ctrl-C stops a command. Run `gloamux COMMAND --help` for details.

While Gloamux is open, workspace commands run in the app. A command that waits for Touch ID or a host search does not hold up other commands. If Gloamux does not pick a command up within 20 seconds, the command is withdrawn and did not run, so it is safe to retry. If Gloamux picked it up but has not answered after 5 minutes, or quits while running it, the command says so and is not retried; check whether it took effect first. A setting that waits for Touch ID is not saved if the session changed during the wait; run the command again.

| Command | Operations |
|---|---|
| `gloamux ssh SESSION` | Opens a saved SSH session's shell in this terminal and exits with the remote shell's status. Options: `--password-stdin`, `--vault-password-stdin`, `--host-key FINGERPRINT`, `--interactive`. |
| `gloamux files OP --session S` | `ls`, `pwd`, `stat`, `get`, `put`, `mkdir`, `mv`, `rm`, `rmdir`, `chmod`. Options: `--protocol sftp\|scp\|ftp\|ftps`, `--recursive`, `--overwrite`, `--resume`, `--allow-plain-ftp`, `--json`, and the sign-in options of `ssh`. Ctrl-C removes the partial file. |
| `gloamux sftp SESSION` | Signs in once and reads `sftp` commands (`ls`, `cd`, `get`, `put`, `mkdir`, `rename`, `rm`, `chmod`, and more) from the terminal or standard input. Also takes `sftp` options with a host, or a whole pasted command with `--command FILE\|-`. Options: `--password-stdin` (the password or session key), `--vault-password-stdin`, `--host-key FINGERPRINT`, `--overwrite`. |
| `gloamux history` | `list [COUNT [SEARCH]]`, `show`, `log ID PATH`, `export PATH.csv\|PATH.json`, `remove`, `clear`. |
| `gloamux sessions` | `list`, `show`, `mkdir`, `add`, `edit`, `options`, `add-other`, `edit-other`, `serial-ports`, `rename`, `move`, `remove`, `env`, `auth`, `cert`, `from-sftp`, `import`, `export`. |
| `gloamux hosts` | `list`, `history`, `clear-history`, `trust`, `replace`, `remove`, `export` (as `known_hosts`), `discover bonjour\|tailscale\|aws`. |
| `gloamux tabs` | `list`, `show`, `open`, `open-window`, `connect`, `local`, `select`, `rename`, `duplicate`, `close`, `disconnect`, `reconnect`, `split`, `unsplit`, `broadcast`, `multiexec`, `window`, `attach`, `read`, `send`, `run`, `readonly`, `log`, `record`, `encoding`, `integration`, `view`, `colors`, `highlights`. Needs the running app. |
| `gloamux forwards` | `list`, `add`, `remove` (saved rules); `live-list`, `start`, `stop` (running forwards). Kinds: `local`, `remote`, `dynamic`. |
| `gloamux commands` | `list`, `add`, `edit`, `remove`, `send`, `run` (quick commands). |
| `gloamux triggers` | `list`, `add`, `edit`, `enable`, `disable`, `remove`. Actions: `notify`, `sound`, `mark`. |
| `gloamux runbooks` | `list`, `show`, `create`, `import`, `delete`, `run`. |
| `gloamux recordings` | `list`, `export` (as `.cast`), `remove`. |
| `gloamux appearance` | `list`, `get`, `set THEME_ID`. |
| `gloamux settings` | `list`, `get`, `set`, `reset`. Names are in the [settings reference](#19-settings-reference). |
| `gloamux layout` | `get`, `set default\|classic\|workbench`. |
| `gloamux config` | `export PATH`, `import PATH` (quit Gloamux first). |
| `gloamux mcp` | Serves allowed sessions to an AI agent over MCP. |
| `gloamux agents` | `status`, `history`, `clear-history`, `revoke`, `off`. |
| `gloamux vault` | `status`, `lock`. |
| `gloamux signins` | `list`, `remove` (after Touch ID or the Mac password; passwords are never printed). |
| `gloamux workspace` | `lock`. |
| `gloamux xserver` | `status`, `start` (XQuartz). |
| `gloamux completion` | `zsh`, `bash`. |
| `gloamux benchmark` | Measures terminal throughput, redraw, and echo time. |
| `gloamux --version` | Prints the app version. |
| `gloamux --self-test` | Checks the nine bundled feature contracts. |

Examples:

```sh
gloamux sessions add "Work server" ssh server.example.com deploy
gloamux sessions options "Work server" jump=Bastion x11=on
gloamux sessions options "Work server" jump=Bastion,Inner   # through Bastion, then Inner
gloamux ssh "Work server"
gloamux files get --session "Work server" /var/log/app.log ./app.log
gloamux files put --session "Work server" ./build.tar.gz /srv/releases/ --overwrite
gloamux tabs list
gloamux tabs run TAB_ID "uptime"
gloamux forwards start TAB_ID local 8080 localhost 80
gloamux hosts discover bonjour
gloamux settings set terminal.font-size 14
```

For shell completion, run `source <(gloamux completion zsh)` in zsh (after `autoload -Uz compinit && compinit`), or save `gloamux completion bash` to a file and `source` it in bash.
