# Gloamux development guide

[English](DEVELOPMENT.md) · [繁體中文](../zh-TW/DEVELOPMENT.md) · [Back to README](../../README.md)

Functional and stress results for the November 24, 2026 working tree are in the [verification record](VERIFICATION.md).

## Contents

1. [Source layout](#source-layout)
2. [Building](#building)
3. [Conventions](#conventions)
4. [Local data](#local-data)
5. [Session tree, layouts, and windows](#session-tree-layouts-and-windows)
6. [Credentials and the vault](#credentials-and-the-vault)
7. [Terminal](#terminal)
8. [Safety and Mac integration](#safety-and-mac-integration)
9. [Files and protocols](#files-and-protocols)
10. [Command line](#command-line)
11. [X11](#x11)
12. [Remote desktop](#remote-desktop)
13. [Updates](#updates)
14. [Performance](#performance)
15. [Tests](#tests)
16. [Third-party notices](#third-party-notices)

## Source layout

The Swift package lives in [Gloamux](../../Gloamux).

| Path or target | What it holds |
|---|---|
| `GloamuxApp` | The executable. It launches the macOS interface and also runs as the `gloamux` command line. |
| `GloamuxShared` | The feature contract every module implements. |
| `Sources/app` | The session tree, windows, tabs, settings, and credential vault. |
| `Sources/app/Resources/<language>.lproj` | Interface text (`Localizable.strings`), keyed by the English source string. |
| `terminal`, `LocalPTY` | Terminal state and the local login shell. |
| `ssh`, `network`, `file-transfer` | Remote sessions and SFTP. `network` is the module `GloamuxNetwork`, so it does not hide Apple's `Network` framework from `AppIntents` and other system modules. |
| `Sources/intents` | The App Intents for Shortcuts (module `ShellIntents`). It depends on nothing else in the package. |
| `RDP` | The Rust remote desktop helper. |
| `scripts` | Packaging, releasing, themes, and the stress test. |

## Building

- `Gloamux/scripts/package-app.sh` builds an optimized release app, `build/Gloamux.app`. Pass a different build cache and destination as the first and second arguments.
- Debug builds parse and draw terminal output several times slower, so judge responsiveness with the packaged app.
- Packaging needs Rust 1.94 or later and Cargo, for the remote desktop helper.
- `GLOAMUX_VERSION` and `GLOAMUX_BUILD` override the version for one build. `GLOAMUX_FEED_URL` points a test build at another update feed. See [Releasing](RELEASING.md).
- SwiftPM warns about conflicting `swift-nio-ssh` and `swift-nio-ssl` package identities. Gloamux uses the [vendored swift-nio-ssh](../../Gloamux/Vendor/swift-nio-ssh/VENDORED.md) for agent and X11 forwarding and the [vendored swift-nio-ssl](../../Gloamux/Vendor/swift-nio-ssl/VENDORED.md) for FTPS TLS session reuse. Citadel and swift-nio-extras declare the same identities through their upstream URLs. SwiftPM uses the local checkout, so the warning is expected with the current toolchain. Recheck resolution when upgrading SwiftPM, because future versions may make this conflict an error.

## Conventions

### Interface text

- Explanations go behind an `InfoButton` (the "!" popover, an AppKit `NSPopover`, so it opens without redrawing the SwiftUI views around it), not in caption paragraphs.
- Keep labels short. Where a translation is longer, let the label wrap with `.fixedSize(horizontal: false, vertical: true)` instead of truncating it.
- No interface text, in any language, ends with "…" or "...".
- The catalogs are `en`, `zh-Hant`, `zh-Hans`, `ja`, and `es`. Add every new `T("…")` string to all five; `TerminalInputTests` checks that they have the same keys.
- The language choice is stored as the app's `AppleLanguages` preference, the same value as the per-app language in System Settings. `package-app.sh` declares the shipped languages in `CFBundleLocalizations`.

### Documents

- Documents are in English in `docs/en`, with a Traditional Chinese copy of the same name in `docs/zh-TW`. The READMEs are `README.md` and `README.zh-TW.md`. Update both languages together.
- Use [Humanizer-zh](https://github.com/op7418/Humanizer-zh/blob/main/SKILL.md) when editing Traditional Chinese text. Use the same term for the same action, and keep the original conditions, format placeholders, and command examples.

## Local data

Gloamux stores its working files under `~/Library/Application Support/Gloamux`. For interface checks, pass `--workspace /path/to/test-workspace` to the app executable to keep these files apart from your regular workspace.

| File | Contents |
|---|---|
| `sessions.json` | The session catalog: connection settings, key-file paths, forwarding rules, custom order, and sorting. |
| `saved-sign-ins.json` | Passwords and key passphrases remembered on this Mac. |
| `password-vault.json` | The optional vault, sealed under the master password. |
| `known-hosts.json`, `host-key-history.json` | Trusted host keys, and every host key decision (2,000 entries at most). |
| `quick-commands.json` | Quick commands, as plain text. Keep secrets out of saved commands. |
| `layout.json`, `appearance.json`, `settings.json` | The workspace layout, the theme, and workspace settings. |
| `triggers.json` | Output triggers. |
| `open-tabs.json`, `recent-sessions.json` | Tabs to reopen at launch, and recently opened sessions. |
| `agent-access.json`, `agent-activity.json` | Agent access, allowed sessions, and the activity history. |
| `ssh-key-secure-enclave` | The Gloamux Secure Enclave SSH key (see `AppSSHKey`). |
| `runbooks/`, `recordings/`, `logs/` | Runbooks and their results, recordings, and session logs (mode 0600). |

Naming:

- Everything uses the name Gloamux: the GitHub repository, the app (`Gloamux.app`, bundle ID `local.gloamux.desktop`), the data folder, the `gloamux` command, `gloamux://` links, and the interface text. The app also links `gloam` to the same executable; `main.swift` treats both names as the CLI.
- Gloamux was called Termac, and MShell before that. Unless `--workspace` is passed, `LegacyName.migrate` moves the newest earlier folder (`Termac`, then `MShell`) to the Gloamux folder when that does not exist yet, and copies the newest earlier settings (`local.termac.desktop`, then `local.mshell.desktop`) when `local.gloamux.desktop` has none. It does nothing while an earlier app is running. Exports with the earlier extensions and format names still import.

## Session tree, layouts, and windows

### Session tree

- An item in `sessions.json` may carry an `order` once the user drags items into place. `SessionTreeStore.children(of:)` lists ordered items first, then unordered ones, folders first and by name, so older catalogs keep their order.
- `drop(_:on:_:)` applies a drag and renumbers that folder by the custom order, even while the tree is sorted by name.
- The catalog's optional `sorting` field (`nameAscending` or `nameDescending`; absent means custom) picks how `children(of:)` lists items.

### Layouts

- The toolbar's layout menu and `gloamux layout` both set `layout.json`. The menu applies the layout at once, and so does a CLI change while the app is open; otherwise the next launch uses it.
- `layout set` takes `default`, `classic`, and `workbench`, stored as `macos`, `terminal`, and `transfer`. Earlier names such as `xshell` and `mobaxterm` still work.
- The Classic and Workbench chrome is in `ClassicLayouts.swift`. Its model support (address bar, compose bar, folder following, host monitoring) is in `ClassicWorkspace.swift`.
- The Default layout's toolbar switches between File Transfer and Terminal. A new connection tab lists Local, SSH, RDP, VNC, and Other connection. Local starts the login shell in place. Choosing another protocol opens its form in that tab.
- `ThemeTitlebar` colors the title bar with the window background and a fill under the toolbar that lets clicks through. It leaves `titlebarAppearsTransparent` off, as SwiftUI sets it: a transparent title bar passes clicks to the window content, so double-clicking it would no longer fill or zoom the window. Switching layouts replaces the view, which removes its fill as it leaves the window.

### Windows and MultiExec

- Workspace windows have independent models and tabs. They share the session catalog, vault, known hosts, quick commands, recents, and runbooks.
- A new window starts with a local terminal. The first window owns the saved-tab snapshot. Closing a workspace cleans up its sessions and tool windows, and closing the last one quits the app.
- MultiExec (`WorkspaceModel.multiExec`) belongs to one window. `typeTerminal` sends input to every ready terminal of that window, including tabs moved to their own windows, and skips read-only terminals and remote desktops. Risky-command checks still apply to each target.
- The Tunnels window and `gloamux forwards live-list` share `WorkspaceModel.tunnelTabs`, which lists only connected SSH tabs, because a tab that is not connected shows the new connection form.

### Ownership

- **Shared by every window:** the session catalog, known hosts, the vault, quick commands, triggers, recents, and runbooks, created once and passed to each new `WorkspaceModel` (`sharing:`).
- **One window:** its tabs, selection, splits, layout state, tool windows, MultiExec, and lock.
- **One connection:** a `SessionTab` owns its SSH session, pending jump host, file channel, shell, forwards, keep-alive and reconnect tasks, and `epoch`. `disconnect` closes all of them and changes `epoch`, so work started for the old connection ends or is ignored. It also cancels `reconnectTask`; a reconnect attempt that was cancelled does not schedule another. Moving a tab to its own window (`moveTabToWindow`) and back keeps the same connection; closing that window disconnects it, and closing the workspace window closes those windows too.
- `ConnectionService` (`model.connections`) opens SSH and FTP connections from the shared data only: owner confirmation, the Touch ID vault read, jump hosts, sign-in, credential saving, and the file channel (`openFiles`). Each attempt brings a `SignInHandler`. `TabSignIn` shows host keys and sign-in questions in its tab, saves what worked, and stops when the tab's `epoch` changes; `CommandSignIn` accepts only trusted or `--host-key` keys, answers with `--interactive`, and saves nothing. The caller owns what it returns.
- `SessionTab.connectionState` is `disconnected`, `connected`, or `lost`, and `moveConnection(to:)` refuses an illegal move (a tab that never connected cannot be lost). `connected` and `transportLost` read from it.
- A remote desktop reached through SSH owns a `DesktopGateway`: the SSH connection and the local forward only, with no hidden terminal tab. `GatewaySignIn` shows its host key and sign-in questions in the desktop pane. `WorkspaceModel.settleHostKey` is the one place that trusts or replaces a key, for tabs and gateways alike.

### Main actor and redraws

- Large work runs off the main actor. `TerminalRecordings.stop` removes the recorder at once and returns a task; a `RecordingSnapshot` masks and writes the file in a detached task, one save at a time, in stop order. A file name already taken gets " 2", " 3", and so on. A save that fails stays in `unsaved` until **Try again**. Quitting awaits `finishRecordingsBeforeQuit` and asks before dropping a recording that was not saved.
- `LocalBrowserState.load` lists a folder off the main actor. A newer load wins over an older, slower one, and `loading` shows a spinner until the first listing arrives.
- Terminal output bumps `TerminalOutput.revision`, which only the terminal view and the small views that follow output (cursor or byte count, the side file list) observe. `SessionTab.screenRevision` reads and writes it, so a burst of output no longer redraws the session pane, its header, or the tab bar. `ViewEvaluations` counts view evaluations in debug builds so tests can check this; it does nothing in release.
- `CLICatalog.localPaths` names the arguments that are paths on this Mac, and the command line resolves them against its working folder before a request reaches the app.

## Credentials and the vault

### Where passwords go

- Without a vault, passwords and key passphrases that sign in are saved by `CredentialVault.rememberWorking` to `DeviceSecrets`: AES-GCM entries, with the entry ID as associated data, under a key rebuilt from a Secure Enclave key agreement that needs no Touch ID. They work after a restart without the master password. Passphrases use the entry ID `passphrase:<key path>`.
- Without a Secure Enclave, secrets go to the master-password vault.
- `DeviceSecrets` stays on after the vault is created, so a locked vault does not stop sessions from connecting.
- **Add to vault** (`CredentialVault.addToVault`) saves a password before it signs in.
- `SavedSignInsView` lists both places (`CredentialVault.Place`) and reveals, copies, or deletes one copy after `WorkspaceModel.authorizeSavedSignIns`.
- Removing a key calls `forgetRemembered`, which deletes the copy on this Mac and, while the vault is unlocked, the vault copy.

### Unlocking and confirmation

- The vault keeps its Touch ID unlock material in memory with Secure Enclave protection. A new app process needs the master password.
- While the vault is unlocked, `connect` skips the per-session `confirmsEachConnection` check; while it is locked, the check runs and calls `WorkspaceModel.confirmOwner` (Touch ID or the Mac password) before a saved secret is used. New sessions start with the check on.
- When only the locked vault holds a needed secret (`CredentialVault.lockedVaultIDs`) and Touch ID is set up for this launch, `readWithTouchID` reads those entries into `sessionPasswords` without unlocking the vault, and that prompt stands in for the per-session check. Tests replace the prompt with `enableTouchIDForTesting`.

### Secure Enclave SSH key

- `ssh-key-secure-enclave` holds a sealed representation that only this Mac can use.
- New keys sign without Touch ID. Older keys that require it ask once per launch while the key loads, before the SSH handshake, so signing on the connection's event loop never waits for the user.

## Terminal

### Screen and shell integration

- `TerminalScreen` (in `Sources/terminal`) records OSC 133 marks as `CommandMark`s with absolute line numbers (`trimmedLines` plus the scrollback index, so marks survive trimming) and raises `TerminalEvent.commandFinished`.
- OSC 8 links go into a link table, and each `CellStyle` keeps a link index that SGR 0 does not clear. OSC 7 sets `workingDirectory`.
- Local zsh loads the marks through `ZDOTDIR`, pointed at a generated `.zshenv` in the user's temporary folder (`ShellIntegration.zshDirectory()`). It restores the user's `ZDOTDIR` and adds its hooks after the user's own on the first prompt.
- Other shells and SSH sessions get the one-line `ShellIntegration.hook`, typed on request, or automatically for SSH when **Settings › Terminal** says so.
- `TerminalScreen` also tracks mouse modes (1000, 1002, 1003, with SGR coordinates for 1006), focus reports (1004), DECSCUSR cursor shapes, and OSC 52 clipboard writes, which `terminalReceived` applies only when **Settings › Terminal** allows them.
- A session in another encoding is converted to UTF-8 by `TerminalDecoder` before parsing, and input is converted back in `enqueueTerminalInput`. The encoding is saved on the session (`SavedConnection.encoding`).
- Terminal settings use the `Gloamux.terminal.*` keys in `TerminalPreferences`.

### Local processes

- Local processes start through `gloamux_spawn_command` in `LocalPTY.c`, which takes an argument vector and extra environment.
- Container sessions run `docker`, `kubectl`, or `aws ssm start-session` through the login shell (`LocalLaunch.command`).
- An app opened from Finder has no locale variables, so `LocalShell` adds `LANG` from `LocalLaunch.localeEnvironment` (the Mac's language and region with UTF-8, or `en_US.UTF-8`) unless `LANG`, `LC_ALL`, or `LC_CTYPE` is already set, as Terminal does. Without it, `ls` printed non-ASCII names as `?`, and zsh themes other than Powerlevel10k garbled them.

### Output pipeline

- Every terminal's output goes through `WorkspaceModel.terminalReceived`, which feeds the screen, the recorder, and command observers.
- A finished command that ran at least the notification threshold in a tab that is not visible sets `attention` on it and posts a notification when Gloamux runs as an app bundle.
- Runbooks (`Runbooks.swift`, Markdown in `runbooks/`) send one block at a time as a bracketed paste, wait for its `commandFinished`, stop at the first failure, and save results in `runbooks/.results/`.
- Recordings (`TerminalRecording.swift`) keep output only, pass it through `SecretRedaction` (which also finds secrets split across chunks) when saving, and write asciicast v2 files to `recordings/`.
- Session logs (`TerminalLogs`) go to `logs/`, masked line by line with `SecretRedaction`.

### Terminal view

- `TerminalDisplay` draws the scrollback and screen as attributed lines in an `NSTextView` (`TerminalTextView`) and replaces only the lines that changed.
- Cells on the default background carry no background color, so the view's own color, which can be translucent over `TerminalBackdrop` (a behind-window `NSVisualEffectView`), shows through.
- The cursor is a separate `TerminalCursorView` over its cell. Changing its shape, focus, or blink never redraws a line, and blinking is a Core Animation keyframe animation.
- Input method composition is kept in the view and drawn over the cursor. It never enters the text storage, and while it is active every key goes to the input method.
- The find bar searches the text storage and marks matches with layout-manager temporary attributes. While it is open, new output is searched again after 0.2 s.

## Safety and Mac integration

- Environment tags live on `SessionTreeNode.environment`; sessions inherit them from folders (`effectiveEnvironment`).
- In the environments chosen in **Settings › Safety**, `typeTerminal` holds a line that matches `RiskyCommands.patterns` until the pane's alert is answered. The line comes from the screen after the OSC 133 B mark when the shell reports one, otherwise from what was typed.
- Reachability dots come from a non-blocking TCP connect to each visible saved host's SSH port, at most six at a time, every 90 seconds. Sessions through a proxy, a jump host, or a container are not checked.
- The menu bar item, the command palette (`CommandPalette.swift`), Spotlight (`SpotlightIndex`, names and addresses only), the `gloamux://open?id=` and `gloamux://new-terminal` links, and the Shortcuts actions all call the same `WorkspaceModel` operations.
- `package-app.sh` runs `appintentsmetadataprocessor` on the constant values SwiftPM emits for `ShellIntents` to write `Metadata.appintents`. Without it the app works, but Shortcuts lists no Gloamux actions.

## Files and protocols

- `RemoteFileSystem` is shared by the browser, queue, previews, and CLI.
- SSH defaults to SFTP and falls back to SCP after a subsystem refusal. Profiles can force either protocol. OpenSSH SFTP replacement uses the advertised `posix-rename@openssh.com` extension.
- FTP uses passive data connections. Explicit and implicit FTPS encrypt both connections, reuse the control connection's TLS session on the data connection, and use system trust or a verified certificate pin.
- File transfers go through `TransferQueue`, which `WorkspaceModel.transfers` shares between the file sidebar (`RemoteFileSidebar`, which shows `LocalTreeState` for a local terminal), the two-pane `FileTransferView`, and every layout. The Default layout shows `FileTransferView` in the main window when `workspaceMode` is `.files`, following the selected tab. Classic and Workbench show it in `FileTransferWindow` with a server menu.
- The queue runs one item at a time on the tab's SFTP channel. Uploads write a temporary `.name.gloamux-….partial` file and move it into place with `RemoteFileSystem.commitUpload`, which uses `replace` over an existing file and never deletes it first; downloads write a hidden partial file beside the destination. CLI uploads and **Edit on this Mac** stage content at a temporary remote name and commit it the same way.
- `SFTPTransfer` keeps 16 reads or writes of 32 KiB in flight and stops at task cancellation.
- Remote Quick Look copies one file of at most 100 MB into a private temporary folder and deletes it with the next preview and at quit.
- Saved forwarding rules are stored with the connection in `sessions.json`. Local and dynamic forwards listen on this Mac's loopback interface; reverse forwards ask the server to listen on its loopback interface. A blank listening port is assigned automatically.

## Command line

- The `gloamux` product shares the app executable. `WorkspaceCommand` dispatches management operations.
- `CLICatalog` lists every public command and operation once. `gloamux --help`, each command's `--help`, shell completion, and the `files` path counts come from it, and `WorkspaceCommand.run` rejects an operation it does not list before anything runs, with or without the app. Add a new command or operation there first; `CLICatalogTests` checks that each listed operation reaches its handler and appears in its help.
- `WorkspaceCommandChannel` serializes workspace writers and routes requests to the active app window over a private same-user channel. The app answers each request in its own main-actor task, so a request waiting for Touch ID does not block others. Taking `ID.request` picks it up and the app writes `ID.accepted`; a client withdraws a request not picked up within `pickupTimeout` (it never runs) and reports a picked-up request without an answer after `answerTimeout` as still running. A command that awaits the owner re-reads its target afterwards and refuses to save over a newer change.
- `BoundedCommand` runs external tools in their own process group with stdin from `/dev/null`, output limits applied while reading, a deadline, and cancellation that stops the whole group.
- `gloamux files` and `gloamux ssh` call `ConnectionService` with a `CommandSignIn` and no tab, close what they opened when the operation ends or fails, and keep supplied passwords and one-time host fingerprints in memory only.
- `gloamux xserver` checks and starts XQuartz in the CLI process through `XQuartz`, since XQuartz belongs to the Mac rather than a workspace.
- While a newer CLI is editing a workspace, use the current packaged app for that same workspace.

## X11

- The X11 setting applies only to the SSH shell.
- `SSHX11Configuration` gets the local display from `DISPLAY` or launchd and reads its MIT-MAGIC-COOKIE-1 authorization with XQuartz's `xauth`.
- Gloamux sends a randomly generated substitute in the SSH request, validates the X11 setup before opening a local connection, and replaces the substitute in memory. Only a local socket or loopback endpoint is allowed.
- Closing the shell closes its X11 channels. The tests use a loopback SSH server and a fake display, so they run without XQuartz.

## Remote desktop

- RDP and VNC open in remote desktop tabs. `RemoteDesktopPane` draws the latest frame, scales it to the pane, and translates keyboard and pointer events.
- The packaging script builds the locked Rust project in `Gloamux/RDP` and signs the helper in `Contents/Helpers`. The helper runs for one connection and exchanges sign-in data, input, and frames with Swift through private pipes. Closing the tab ends the process.
- The connection tree opens a compact editor where a saved desktop profile can switch between RDP and VNC. A certificate pin is kept only for the same RDP endpoint.
- **RDP** uses IronRDP for NLA with NTLM and TLS. A server certificate must pass system verification or match the SHA-256 fingerprint approved for that saved profile.
  - RDP follows the pane size by default. A connection can instead fix a resolution (`DesktopResolution` presets, at most 2560 × 1600), ask for Retina (twice the pixels with a 200% desktop scale), and pick a quality, which `quality()` in `rdp.rs` maps to the connection type and performance flags.
  - RDP gateways and redirected drives, printers, smart cards, audio, and cameras are not implemented. An SSH tunnel (**Through SSH**) is the supported way to reach a desktop behind a server.
- **VNC** supports RFB 3.3, 3.7, and 3.8, and answers newer servers such as macOS (3.889) as 3.8. It requests ZRLE, CopyRect, raw rectangles, and server resize messages, and keeps one zlib stream for the connection as ZRLE requires.
  - Sign-in uses no authentication, the classic VNC password, or Apple Remote Desktop (security type 30) when a user name is entered. Type 30 is what macOS Screen Sharing uses for a Mac account: a Diffie-Hellman exchange keys AES-128 for the account name and password. Only the credentials are encrypted.
- Clipboard sharing follows the connection, or the `desktop.share-clipboard` default when the connection leaves it unset.

## Updates

- `AppUpdates` (in the `App` module) is what the menu and Settings see: **Gloamux › Check for Updates** (`CheckForUpdatesCommand`) and **Check for updates automatically** in **Settings › General**.
- Only the `GloamuxApp` executable links [Sparkle](https://sparkle-project.org) 2. `SparkleUpdates` starts `SPUStandardUpdaterController` in `applicationDidFinishLaunching`, after the command-line paths have exited, and only when the bundle's Info.plist has `SUFeedURL` and `SUPublicEDKey`. `swift run`, tests, and the CLI never check for updates, and the menu item and setting stay hidden there.
- `package-app.sh` copies `Sparkle.framework` into `Contents/Frameworks` without its XPC services (Gloamux is not sandboxed), adds the `@executable_path/../Frameworks` rpath, signs Sparkle's helpers before the app, and writes the feed URL (`releases/latest/download/appcast.xml`) and the public key.
- `appcast.sh` signs a DMG with the private key in the login Keychain (account `Gloamux`) and writes that signature into the feed. `release.sh publish` uploads it next to the DMG. The current configuration authenticates the update archive through EdDSA. The appcast and release-note content are fetched over HTTPS. Sparkle's signed-feed option is unset. See [Sparkle customization](https://sparkle-project.org/documentation/customization/).

To test an update locally:

1. Package one build with `GLOAMUX_FEED_URL=http://127.0.0.1:8765/appcast.xml`, and a second one with a higher build number.
2. Put the newer DMG and its feed (from `appcast.sh`) in a folder, and serve it with `python3 -m http.server 8765 --bind 127.0.0.1`.
3. Open the older copy and choose **Check for Updates**.

## Performance

### Benchmark

`gloamux benchmark [--megabytes N] [--columns N] [--rows N] [--json]` feeds plain text, colored logs, CJK text, full-screen redraws, and OSC 133 prompts through `TerminalScreen` in 4 KB reads, times a full redraw of the visible lines with `TerminalLineRenderer`, and times one keystroke's echo. Run it from the packaged release app.

On an Apple silicon Mac at 160×48 (November 22, 2026):

| Workload | Result |
|---|---|
| Plain text | about 100 MB/s |
| Colored logs | 36 MB/s |
| CJK text | 20 MB/s |
| Full-screen redraws | 25 MB/s |
| OSC 133 prompts | 10 MB/s |
| Full redraw | 0.4–0.7 ms |
| Keystroke echo | about 0.01 ms |

### Stress test

`python3 Gloamux/scripts/stress-test.py` drives the packaged app through `gloamux` and `gloamux mcp` under load and records what it costs the Mac.

- It needs only the Python 3 standard library and macOS's OpenSSH, so an agent can run it unattended after `package-app.sh`.
- It creates a throwaway workspace and a throwaway `sshd` on 127.0.0.1 that accepts only a key made for the run. It never opens your workspace, never signs in with a password, and never connects to another host. In that workspace only, it turns on agent access for the test session.
- Options: `--quick` runs about a fifth of the load, `--no-app` skips the phases that need the app, `--out DIR` chooses the report folder, and `--keep` keeps the throwaway files.
- It writes `report.md`, `report.json`, and once-a-second samples in `samples.csv`. The exit status is 0 when every phase passed, 1 when any failed, and 2 for a setup problem.

It covers:

- the session catalog with the app closed and open
- configuration export and import, including a damaged backup that must be refused
- SFTP and SCP transfers of large files, and recursive folder transfers
- SSH connection churn, sequential and parallel
- `gloamux benchmark`
- 20 local and 10 SSH tabs, each printing a million lines
- port forwarding, checked with a TCP echo server
- every MCP tool, including that an agent sees only allowed sessions and that a proposed command waits for review

Each phase gets a pass or fail, its own figures, the app's CPU time and peak memory, and the CPU used by the CLI processes it ran. Memory figures are the physical footprint shown in Activity Monitor; RSS is also recorded, but it stays high after memory is freed.

A full run on an Apple silicon Mac (10 cores, November 22, 2026):

- The app was idle at 93 MB and peaked at about 1 GB with the 30 busy tabs. A tab with a full 5,000-line scrollback at 160 columns holds about 33 MB.
- The tabs printed about 560,000 lines a second in total.
- Agent and CLI requests to the running app took 4 ms and 13 ms.
- SFTP moved about 1 GB/s up and 730 MB/s down, and a forwarded port carried about 800 MB/s.
- After the tabs closed, 36 MB was still in use in the heap. The footprint stayed near 390 MB because the allocator keeps freed pages for reuse. SwiftUI holds the values it last drew until it draws again, so closed tabs are released at the window's next update.

### Flow control

- **SSH shells.** Above 64 unread chunks, an SSH shell stops reading its channel. The SSH window then fills and the server waits.
- **Local shells.** Output reaches the screen through `TerminalOutputPump` in order, in batches. Above 1 MB waiting, the PTY read source is suspended until the screen catches up.

### Future work

- **Metal.** Building every visible line takes under 1 ms, and AppKit then draws only the lines that changed, so a Metal renderer would not change what users notice today. The parser is the limit. Runs of printable ASCII are written a row at a time, UTF-8 is decoded without a `String` per character, and CSI parameters are parsed byte by byte. CJK text still goes through the width lookup one character at a time, so that is the next place to speed up.
- **Inline images.** iTerm2's `OSC 1337 File=` and the kitty graphics protocol carry PNG or raw pixels that `NSImage` and `CGImage` decode directly, so they fit the current text view as attachments anchored to cells; sixel needs its own decoder. If added: iTerm2 first, then kitty's direct transmission (not its file or shared-memory modes), then sixel. Cap each image at 10 MB encoded and 4096×4096 pixels, keep at most 64 MB of decoded images per tab, dropped as their lines leave the scrollback, and never let images from a remote host read local files.

## Tests

Run from the repository root:

```sh
swift test --package-path Gloamux
cargo test --offline --manifest-path Gloamux/RDP/Cargo.toml
```

| Suite | Covers |
|---|---|
| `ReflowTests` | Rewrapping on resize, splitting output at any byte, and CSI parameter parsing. |
| `TerminalModesTests` | Mouse and focus reports, cursor shapes, OSC 52, scrollback size, and legacy encodings. |
| `TerminalViewBehaviorTests` | Input method composition, find, mouse reports, and the cursor in a real window. |
| `TerminalFeaturesTests` | Redaction, asciicast files, runbook parsing, risky commands, environments, container command lines, discovery parsers, host key history, palette search, the URL scheme, reachability probes, and the benchmark workloads. |
| `RemoteKindsTests` | Saved desktop profiles open dedicated tabs and keep their protocol. |
| `LocalLocaleTests` | Local shell locale selection, preserving configured locales, and non-ASCII file names through a real PTY. |
| SSH, forwarding, and SFTP tests | Loopback fixtures and macOS's `sftp-server`: separate host-key approvals for the destination and jump host, transfer round trips, reconnect after transport loss, and independent local terminals. |
| Rust helper (`cargo test`) | ZRLE tiles and the shared zlib stream, CopyRect, rectangle bounds, version and security negotiation, the VNC DES response, and the Apple sign-in block. |

Local protocol fixtures have also verified RDP certificate approval, CredSSP sign-in, pixels, and keyboard and pointer events, plus the VNC framebuffer and input over RFB.

Optional inputs:

- **Xshell formats.** Compatibility tests read from the folder in `XSHELL_DIR`. The Xshell installation and fixtures are external.
- **Remote SSH hosts.** Set `GLOAMUX_REMOTE_HOSTS` to a comma-separated list of `user@host[:port]` targets, and `GLOAMUX_REMOTE_KEYS` to a folder with test private keys and a `known_hosts` file with the verified server keys. Run `swift test --package-path Gloamux --filter RemoteHostTests`. The second target is also tested through the first as a jump host. `GLOAMUX_REMOTE_LOGIN_ONLY` lists hosts whose restricted shells can only be checked for a successful login.

Without these inputs the related tests are skipped.

Verification on November 24, 2026 of the uncommitted architecture changes passed 461 of 469 Swift cases with 8 skips and 0 failures, all 18 Rust tests, 9/9 package self-checks, 14/14 full stress phases, and 81/81 packaged batch checks. See the [verification record](VERIFICATION.md) for coverage and remaining checks.

## Third-party notices

| Component | Notice |
|---|---|
| [IronRDP](https://github.com/Devolutions/IronRDP) (remote desktop engine) | [MIT](../../Gloamux/RDP/licenses/ironrdp-MIT.txt) and [Apache 2.0](../../Gloamux/RDP/licenses/ironrdp-Apache-2.0.txt), shipped with the app. [Cargo.lock](../../Gloamux/RDP/Cargo.lock) records the Rust dependencies. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (in-app updates) | MIT-style license, shipped in the app as `Sparkle-LICENSE.txt`. |
| Visual Studio Code theme colors | [MIT notice](../../Gloamux/Sources/app/Resources/vscode-themes-license.txt). |
| Marketplace theme colors | [License notices](../../Gloamux/Sources/app/Resources/vscode-community-themes-licenses.txt) of the MIT-licensed themes. |
| Swift packages | Resolved in [Package.resolved](../../Gloamux/Package.resolved). |

Themes and imports:

- To change the bundled Visual Studio Code themes, edit the selection in [build-vscode-themes.py](../../Gloamux/scripts/build-vscode-themes.py) and run it with a local Visual Studio Code app and the downloaded `.vsix` packages.
- Linux distribution palettes are defined in `ThemeGallery.swift`; the [theme inventory](THEME-INVENTORY.md) records their sources. The workspace layouts and theme picker are native implementations.
- Xshell import supports selected fields from compatible profiles.
- The MobaXterm reader (`MobaXtermImport` in `SessionImports.swift`) follows the field positions of MobaXterm's session export, which Mobatek does not document. It reads SSH (type 0), SFTP (type 7), and serial (type 8) sessions and tolerates short field lists from older versions.
- Import files are decoded as UTF-16 or UTF-8 when marked or valid, then as Big5 (CP950), GB 18030, and Windows-1252.
- `SessionExport` writes `.gloamuxsessions` JSON (`SessionsFile`), CSV, and OpenSSH configuration. Exports leave out passwords and private key contents, and rewrite key paths under the home folder as `~/…`. OpenSSH output represents SSH settings supported by that format.
