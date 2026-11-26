# Gloamux verification record

[English](VERIFICATION.md) · [繁體中文](../zh-TW/VERIFICATION.md) · [Back to README](../../README.md)

This record lists the checks behind each release, newest first. The original November 24, 2026 architecture and stress-test baseline used the changes on top of `b1e4638` that ship in Gloamux 1.2 (build 3), packaged as `build/Gloamux.app`.

## Gloamux 1.5 (build 16): terminal tools, ZMODEM, inline images, and Compatible SSH key exchanges (November 26, 2026)

Built on `395ad71` (1.4.6 build 15).

- **Unit tests.** New: `ZmodemTests`, `InlineImageTests`, `KeyExchangeTests` (each Compatible key exchange signs in to a local OpenSSH server that offers only it, with two cipher families, and Modern is refused), and `ShellEnvironmentTests` (the locale variables and terminal modes a shell receives). Added to: `TerminalInputTests` (xterm keys, bright bold colors, italic and faint text, spacing, ligatures and minimum contrast, copying wrapped rows, copy on select and middle-click paste, word characters and ambiguous width, paste trimming and joining, copy mode, double-click on paths), `TerminalViewBehaviorTests` (following output, accessibility input), `KeyFormatTests` (EC keys with a short scalar, in SEC1 and PKCS#8), `WorkspaceCommandTests` (the new settings, ZMODEM through a local shell including cancelling `sz` mid-transfer, the dropdown hotkey, paste history, and timestamps from the CLI), and `TerminalOutputViewTests` (a click while output arrives).
- **Swift suite.** 560 tests, 8 skipped (remote host and Xshell sample checks that need external inputs), 0 failures, before the release run. The Swift and Rust suites run again in `release.sh build` on the release commit.
- **ZMODEM against real lrzsz.** Over SSH to a test server with lrzsz 0.12.21rc: `sz` of a 20 MB file, an empty file, a name with spaces, and a name with shell characters, and `rz` of an 8 MB file, a Chinese name, and an empty file. Every SHA-256 matched. A second download of the same name got a numbered name. A cancelled download removed its partial file; before the fix the data `sz` had already sent appeared on screen, and after it only the prompt did.
- **Following output.** A report that a long `sudo apt install` did not stay at the bottom led to reading the position before each update. In a packaged copy, a script that redraws an apt-style progress line in a scroll region kept the bottom in view with text selected, and kept the view still when scrolled up.
- **A click while output arrives.** Found during the demo: with **Copy on select** on, a click while output arrived selected a line and replaced the clipboard. The new test reproduced it (162 characters selected) before the fix and passes after it.
- **On the Mac.** In a renamed test copy with an isolated workspace and test preferences: minimum contrast, 1.4× line spacing, 1.2× character spacing, wide ambiguous-width characters, double-clicking a path, copy on select, middle-click paste, paste trimming and joining, timestamps, copy mode, paste history in the sheet and the CLI, a session set to **Compatible** connecting, the dropdown window shown and hidden with `gloamux layout dropdown`, sixel and iTerm2 images, and `sz` and `rz` with the bar.
- **Packaged app and stress.** `package-app.sh`, deep strict signature verification, the 9-feature self-test, and a full `stress-test.py` run: all 14 phases passed, including 30 tabs printing 1,000,000 lines each (about 605,000 lines/s, 931 MB at the peak and 242 MB after closing them).
- Not checked: the hotkey pressed on a real keyboard (the demo used the CLI), ligatures with a ligature font (none installed), the Dock bounce, and installing the update through **Check for Updates**. The kitty graphics protocol is not supported.

## Gloamux 1.4.6 (build 15): what new tabs open, a steady terminal screen, and pickers (November 26, 2026)

Built on `1b57fc3` (1.4.5 build 14).

- **New tabs.** **Settings › Terminal › New tabs open** chooses what the **+** buttons open: **Default (127.0.0.1)**, a terminal on this Mac; the **New connection form**; or a saved session. The CLI setting `terminal.new-tab` replaces `terminal.new-tab-local`. Tests cover the default, the form, a saved session, a deleted session and a folder falling back to the default, and the CLI taking an ID or a name used by only one session.
- **Settings › Terminal** is grouped under five headings and scrolls. **Show in menu bar** moved to **Settings › General**.
- **Pickers.** On macOS 15 and later a picker opens its menu when the click is released, so a click on its name no longer opens and closes the menu at once. A test clicks the name and the arrows and checks that the menu stays open and that choosing an item sets the value.
- **Terminal screen.** The view keeps the whole screen in sight instead of only the cursor's row, so running `top` again, or a prompt after `clear`, no longer shows scrollback lines above it with its last rows cut off. Typing, Return included, scrolls back down from the scrollback even with text selected. The viewport is a whole number of rows tall, and its padding lies outside the scrolling area. A test checks the screen's first and last rows at the edges, a short screen staying whole at the top, and Return from the scrollback.
- **Tests.** Swift: 527 tests, 8 skipped, 0 failures, before the release run. The Swift and Rust suites run again in `release.sh build` on the release commit.
- **On the Mac.** In a packaged copy, the Settings window showed the grouped Terminal pane and the picker as one button, and a fresh terminal showed its first line whole under the top padding. The user ran `top` twice by hand on an earlier build of this change, before the padding was moved to the top. Not checked: the opened picker menu, which needs a full-screen capture.

## Gloamux 1.4.5 (build 14): daily update checks on by default (November 26, 2026)

Built on `39970bc` (1.4.4 build 13). The app's `Info.plist` now sets `SUEnableAutomaticChecks`, so Gloamux checks GitHub for a new version once a day without first asking. A user who turned **Check for updates automatically** off keeps that choice, because Sparkle reads the saved setting before the bundle default.

- **Package.** A packaged copy carries `SUEnableAutomaticChecks` as `true`, and `plutil -lint` passed. `release.sh build` now refuses a bundle without it.
- The Swift and Rust suites run in `release.sh build` on the release commit.
- Not checked live: a fresh install skipping Sparkle's question and checking on its own, and an installed copy updating through **Check for Updates**.

## Gloamux 1.4.4 (build 13): session tree drag and drop, and dialog buttons (November 26, 2026)

Built on `d2acdb0` (1.4.3 build 12). The session tree is now an AppKit outline view. Scrolling during a drag used to cancel the drag and leave its image stuck in the tree; the system drag session now scrolls at the edges and follows the scroll wheel. Folders can change places, also in a tree sorted by name, and every dialog ends with the same Cancel and main-action buttons.

- **Unit tests.** `SessionTreeInteractionTests` covers drops between rows, onto folders and their edges, onto sessions, below the last row, into a folder's own subfolder (refused), and in a name-sorted tree, and keeps the shown order when it turns custom. A hosted outline in a key window takes queued real clicks: a folder click opens it and saves that, a click selects a session, and a double click opens it.
- **App.** A renamed copy of the packaged app with an isolated workspace of 6 folders and 37 items: an item dragged from the bottom to the top edge scrolled the tree and landed in the right place on disk, search showed and restored folders, the selection showed in light and dark themes, and the rename dialog showed the new buttons.
- `swift test`: **300 app tests passed** before the release commit. `release.sh build` reruns the suites on it.
- Not checked by hand: the right-click menu, scrolling with the wheel during a drag, and every dialog other than rename.

## Gloamux 1.4.3 (build 12): how each `ssh` run in a terminal went (November 25, 2026)

Built on `5421375` (1.4.2 build 11). After an `ssh` run in a connection's terminal, the Session Log records **SSH connected** or **SSH connection failed** with the reason `ssh` showed. `TypedSSH` reads the command and its messages; `CommandCapture` decides when a prompt waits below it, or when the next command runs.

- **Unit tests.** `CommandCaptureTests` covers a new host key, a refused and then accepted password, refused ports, refused keys, unknown hosts, Ctrl-C, prompts without a user or host, unknown prompts, cleared, wrapped, long, and tmux-style screens, and which commands count.
- **Packaged CLI.** `gloamux ssh` signed in to a throwaway loopback `sshd` with a run-only key, then the system's `ssh` went on to a second one: one connection after answering `yes` to a new host key, a refused port, a refused key, and an unknown name. Each result was recorded under its command and `yes` was not a command.
- **App.** A renamed copy of the packaged app with an isolated workspace showed both results in the Session Log.
- `swift test` passed before the release commit. `release.sh build` reruns the suites on it.
- Not checked live: Windows and network-equipment servers, and tmux outside the unit tests. The result comes from what the terminal shows, so an `ssh` that hides its errors or runs from an alias or script has none.

## Gloamux 1.4.2 (build 11): commands, routes, and file changes in the Session Log (November 25, 2026)

Built on `7e91e50` (1.4.1 build 10). A record of the Session Log now holds the commands run in the connection, the jump hosts and proxy it went through, port forwarding, and file changes. Commands come from `CommandCapture`, which reads the line the terminal shows when Return is sent.

- **Unit tests.** `CommandCaptureTests` covers typed, recalled, completed, pasted, typed-ahead, wrapped, and continuation lines, right and changing prompts, shell integration, tmux-style screens, and passwords that are not echoed, are masked, or have no line end of their own. `ConnectionHistoryTests` covers routes, search, exports, and masking of secrets in arguments.
- **Real server.** The packaged CLI signed in to an Ubuntu 24.04 OpenSSH server with a key from `ssh-agent`, through a jump host, on a pseudo-terminal. The record held the jump host and every command, including history recall, Tab completion, Ctrl-R, a `for` loop on two lines, and a command typed while another ran. Text given to `read -s` was not in the file, and `-p` of `mysql` was masked.
- **Local zsh.** The same reader on a login zsh, with and without shell integration, returned every command.
- **App.** A renamed copy of the packaged app with an isolated workspace, against loopback demo servers: commands and downloads appeared in the Session Log, the filters and the jump-host route were shown, and turning `history.commands` off left a command out.
- `swift test`: **521 cases, 513 passed, 8 skipped, 0 failed** before the last fixes to `CommandCapture`, whose tests passed after them. `release.sh build` reruns the suites on the release commit.
- Not checked: Mosh, serial devices, network equipment, fish, a desktop through an SSH gateway, and a real proxy. A terminal whose size differs from the one the server was told, so that the shell draws over its own line, can lose a command.

## Gloamux 1.4.1 (build 10): Session Log in the window (November 25, 2026)

Built on `8bef52f` (1.4 build 9). The Default toolbar has a third segment, **Session Log**; the Classic toolbar and Workbench ribbon open it in its own window. **Connection history** is now named **Session Log** in English; the stored file is unchanged.

- A renamed copy of the packaged app with an isolated workspace: the segment shows the records, choosing a tab returns to the terminal, `gloamux tabs view TAB_ID session-log` switches to it, the Workbench button opens its window, and the Classic button is in the toolbar. `gloamux history list COUNT SEARCH` returned the matching record.
- `swift test`: **515 cases, 507 passed, 8 skipped, 0 failed** before the release commit; only documents and the version number changed after it. `release.sh build` reruns the suites on that commit.
- Not clicked: the Classic button and the session's right-click item.

## Gloamux 1.4 (build 9): SFTP gateways, connection history, and sign-in fixes (November 25, 2026)

Checked on the working tree on top of `f04169a` (1.3.2 build 8) before the release commit. `release.sh build` reruns the Swift and Rust suites on the release commit; the release notes carry those counts.

- **Full suite.** `swift test`: **514 cases, 506 passed, 8 skipped, 0 failed**. Only Traditional Chinese texts, documents, and the version number changed after it. The skips are three external SSH and five Xshell sample checks.
- **Package.** `package-app.sh` succeeded, the deep strict signature check passed, and the self-test reported 9/9. No Rust source changed.
- **App.** A renamed copy of the packaged app with an isolated workspace was driven against loopback demo servers: a pasted `sftp` command, its question, the saved folders, the copy, the history window, splits, themes, and a two-pane download. Driving it found four faults, all fixed: File Transfer ignored the saved remote folder, the sheet lacked the theme color, palette rows kept old contents after typing, and the one below.
- **Addresses.** A name with an IPv6 and an IPv4 address failed to sign in when the IPv6 address refused the connection, because the refused attempt ended the sign-in. `testNameWithOneUnreachableAddress` covers it. The HTTP and SOCKS4 proxy handshake had the same fault and the same fix, without its own test.
- **Real server.** The packaged CLI signed in to an Ubuntu 24.04 OpenSSH 9.6 server with a key from `ssh-agent`: `gloamux sftp` (`pwd`, `get`), `gloamux files ls`, and two history records.
- **Limits.** That server has keyboard-interactive sign-in turned off, so PAM questions and a real session-key gateway are still unchecked. The README recordings use demo servers on this Mac; their terminals relay a real Linux server.

## Gloamux 1.3.2 (build 8): shared-text redaction, serial discovery, and terminal reset

Gloamux 1.3.2 (build 8) ships the changes below on top of `8bbc564` (1.3.1 build 7). At the owner's request it was published before the suites were rerun on the release commit. The test counts below come from the working tree before the release commit, which then changed only version numbers and documentation.

### Shared-text redaction (November 25, 2026)

Text shared with agents is redacted with the recording rules before it is kept or shortened. Before, it was only shortened. Three `AgentAccessTests` use synthetic secrets: a token and a password, a private key longer than an excerpt, a token wrapped across rows, a key that starts above the screen, and partly selected tokens. Two of the three were also run with their fixes removed and failed. A selection outside a terminal, such as in a password field, is no longer shared; that has no test of its own. Sharing was not exercised by hand in a packaged app.

### Serial discovery and terminal reset (November 25, 2026)

Verified on the working tree based on `8bbc564` (1.3.1 build 7). The local candidate is `build/serial-reset-fix/Gloamux.app`; its version metadata remains 1.3.1 build 7. These fixes ship in 1.3.2. The tree also retains the pre-existing shared-terminal redaction changes and their three additional `AgentAccessTests`, included in this run.

- **Crash reproduction and fix.** The supplied 1.2.2 build 5 report traps on the main thread in `TerminalScreen.cell(row:col:)`, called by `TerminalDisplay.redraw`. Four initial regressions failed before the fix: after a resize, RIS (`ESC c`) or DECSTR (`CSI ! p`) recreated the initial-size buffers while `rows` and `cols` still described the resized screen. Reset now builds both buffers at the current dimensions. The screenshot does not establish which byte sequence triggered the original user's crash; it establishes the crash location, and the size mismatch is independently reproduced.
- **Terminal checks.** All six `TerminalResetTests` pass, covering growth, shrinkage, height-only changes, alternate screens, and 500 resize/reset/screen-switch cycles with cell-content and dimension checks. A `TerminalOutputViewTests` regression feeds reset output through `WorkspaceModel` and the actual SwiftUI/AppKit redraw at four sizes; it passes.
- **Serial discovery.** The form scans on opening and every second while Serial port is selected, with task cancellation on leaving the form/type and an immediate Refresh action. IOKit USB ancestry identifies adapters independently of their driver names. Only a new blank target with one USB adapter is filled; multiple adapters, saved devices, and typed paths retain user choice. Discovery does not open the port. Three `SerialDeviceTests`, the PTY byte-exchange test, and the line-settings test pass. The packaged `sessions serial-ports --json` lists the same available paths.
- **Live package check.** An isolated identifier (`local.gloamux.serialreset20261125`) and throwaway workspace showed the USB device and name filled without opening the device menu, alongside Bluetooth and system ports. The owner connected the physical adapter; the app reported the serial tab connected and displayed the device's login prompt. The owner reported that it looked correct. This proves discovery, opening, and receiving output; live unplug/replug, multiple physical adapters, and authenticated device operations were not exercised. The test instance was left open because the owner was using the connection.
- **Full validation.** `swift test`: **498 cases, 490 passed, 8 skipped, 0 failed**. The skips remain three external SSH and five Xshell sample checks. `package-app.sh` succeeded; deep strict signature verification and feature-contract self-test **9/9** passed. `git diff --check` passed. No Rust source changed; the Rust helper was built by packaging, and its test suite was not rerun separately.
- **Documentation.** Both READMEs and all eight en/zh-TW document pairs were checked for the affected behavior, release status, local links, heading structure, and command examples. The guides, development notes, roadmap, backlog, data inventory, release procedure, verification records, and local checkpoint were synchronized. No version or release tag was changed. Raw logs and the source digest are under `analysis/serial-reset-fix-20261125/` (ignored).
- **Limits.** This is a targeted terminal stability run, not a repeat of the November 24 full application stress test. Intel hardware and the original reporter's Mac have not been retested.

## Gloamux 1.3.1 (build 7): Session properties layout

Verified on November 24, 2026, on top of `b4256a0` (1.3 build 6). In Session properties, a jump host menu now fills its row and truncates a long name instead of growing past the sheet, its row label stays on one line, and the sheet is 540 points wide instead of 460. A packaged copy with an isolated workspace was checked in Traditional Chinese and English with a long jump host name and two hops: every label, field, and info button stayed inside the sheet and the jump host menus lined up with the other fields. The sheet without jump hosts was not captured after the change. `OpenSSHConfigImportTests` and `WorkspaceCommandTests` passed; the release build reruns the full suites.

## Gloamux 1.3 (build 6): Siri quit protection, multiple jump hosts, and connection route

Gloamux 1.3 (build 6) ships the changes reviewed below on top of `6bbace3` (1.2.2 build 5). The release build reruns the Swift suite, the Rust remote desktop tests, and the package checks; the release notes give its counts.

### Siri quit protection review (November 24, 2026)

- Source review confirmed that `GloamuxApplicationDelegate.applicationShouldTerminate` checks `QuitRequest` before closing connections or saving recordings. A Quit Apple event from `linkd` is refused while a workspace is open. With no workspace, an unknown sender, or another sender, the existing quit path remains in use.
- The six `QuitRequestTests` were independently rerun and passed. They cover the `linkd` decision, other senders, no workspace, another event type, no current Apple event, and process-name lookup.
- The full Swift suite on this working tree was independently rerun: **485 cases, 477 passed, 8 skipped, 0 failed**. This includes the pending owner-confirmation, multi-hop, and route-display regressions; the eight skips remain three external SSH and five Xshell sample checks.
- Claude's recorded packaged simulation used an isolated workspace: a helper executable named `linkd` sent Quit, received cancellation (-128), and the app stayed open; another sender and a normal scripted Quit ended the app. This is a sender simulation, not a real Siri end-to-end check.
- **Still pending:** an actual Ask Siri request against the 1.3 build, then waiting beyond the observed 30-second grace period with a workspace open. No new full application stress run was performed in this review.

### Jump hosts and owner confirmation (November 24, 2026)

- A new session's first connection, with nothing saved yet, or one with the password typed now, no longer asks for Touch ID; `DeviceSecretsTests` and `ConnectionServiceTests` cover it.
- One session lists several jump hosts in order. `TunnelWorkspaceTests` connects through two listed hops with a password typed for each, checks the route's names, endpoints, and fingerprints, runs the route check, lists an SFTP folder on the destination, and checks that the route clears when the tab closes. `OpenSSHConfigImportTests`, `SessionExchangeTests`, and `WorkspaceCommandTests` cover OpenSSH `ProxyJump` lists, export and import, and `jump=A,B` in the CLI.
- A packaged copy with an isolated workspace connected through three loopback OpenSSH servers (A, then B, then D, with a temporary key). The route popover showed each server reached from the one before it. `lsof` showed Gloamux connected only to A, with B's incoming connection owned by A's `sshd-session` and D's by B's.

## Terminal symbol fix in 1.2.2 (build 5)

Verified on November 24, 2026, on top of `1363ebf` (1.2.1 build 4). The local candidate was `build/font-fix/Gloamux.app`; the release build repeats the Swift suite and package checks.

- The default regular and bold fonts previously resolved Powerline/Nerd Font private-use characters to LastResort. TextKit also laid out those missing glyphs at a different advance from the terminal cell grid. The four initial regression cases failed before the fix; all six final `TerminalFontTests` pass, covering actual glyph faces, 13/20 pt positions, cursor offsets, single/double-width icons, fixed row height, a selected Menlo face, and ordinary CJK/emoji fallback. An in-place colored left/right prompt redraw stays on one screen row.
- Full Swift suite: **476 cases, 468 passed, 8 skipped, 0 failed**. The skips are the same three external SSH and five Xshell sample checks. The candidate passes deep strict code-signature verification and feature-contract self-test **9/9**; the bundled font, its MIT license, and provenance are present in its resource bundle.
- A separate bundle identifier and throwaway workspace loaded real Oh My Zsh Agnoster and Powerlevel10k (os_icon, dir, prompt_char, status, time) through local zsh. Visual checks with the default system monospaced font confirmed Powerline segments, Apple/home/clock icons, regular/bold symbol samples, Chinese, emoji, and the right prompt. No font was installed in the user's font folders. A process-only probe of the official MesloLGS NF Regular confirmed it is fixed-pitch and accepted by the existing picker. Intel hardware has not been tested.
- **User confirmation, November 24, 2026:** the user reported testing and confirmed that the prompt-symbol issue is fixed. The test machine and installation method were not specified.
- The release terminal benchmark ran five 2 MB workloads at 120 × 40. Candidate redraws measured **0.54–1.72 ms**, against **0.47–1.60 ms** in the installed baseline; the largest added time was 0.23 ms. Echo p99 was 0.019 ms versus 0.021 ms. These are single-run local measurements, not a new full application stress run.

The remaining sections preserve the earlier 1.2 architecture and stress-test record.

## Functional and regression checks

| Check | Result |
|---|---|
| Full Swift suite | 469 cases, 461 passed, 8 skipped, 0 failed |
| Rust remote desktop engine | 18 passed |
| Packaged app | Deep strict signature verification passed, feature-contract self-test 9/9 |
| CLI help entry points | 22 groups passed |
| Packaged batch verification scripts | 81/81 passed, including the quit-recording case rerun with the corrected test identifier |
| Localization files | All five Localizable.strings catalogs passed plutil validation |

Swift coverage includes parsing and imports, host trust, credentials, proxies and jumps, loopback MFA, terminal behavior, splits and locks, SFTP/SCP/FTP/FTPS, forwarding, and the new architecture regressions. The eight skips are three external SSH checks and five installed Xshell sample checks.

The 81 packaged checks cover safe overwrites, lock refusal, damaged-store protection, recording save failures, concurrent CLI requests, shared connection services, help and completion, exit codes, stdin passphrases, relative paths, and recording saves at the size limit and on quit. Checks use throwaway workspaces and the loopback SSH tests use keys generated for the run.

The user reported successful manual checks on the packaged test build for Zhuyin/Pinyin composition and Return, composition while another split pane continuously prints output, mouse selection, and input reaching the focused pane. This manual result is recorded in the local project status.

## Full stress test

The run used Apple silicon, 10 cores, and macOS 27.2.1. All 14 phases passed in full mode (14/14).

| Phase | Result |
|---|---|
| CLI catalog (offline) | Passed |
| Config export and import | Passed |
| Test SSH server | Passed |
| SFTP large file | Passed |
| SCP large file | Passed |
| Folder transfer (recursive) | Passed |
| SSH connection churn | Passed |
| Terminal benchmark | Passed |
| App launch | Passed |
| CLI catalog (app running) | Passed |
| Tabs and terminal output | Passed |
| Port forwarding | Passed |
| MCP agents | Passed |
| App idle after load | Passed |

| Measurement | Result |
|---|---|
| Large files | 512 MB round trips over each of SFTP and SCP |
| Folder tree | 2,000 files uploaded, downloaded, and removed |
| Parallel SSH | 40 connections, 0 failures |
| Terminal load | 20 local and 10 SSH tabs, each printing 1,000,000 lines |
| Aggregate output | About 660,949 lines/s |
| App memory | 711 MB peak, about 153 MB after closing the loaded tabs |
| Forwarding | 200 connections, 256 MB round trip |
| MCP | 5 tools, 300 calls, about 4 ms p95, command proposal remained awaiting review |

These are measurements from this Mac and run. Transfer endpoints are loopback and resource sampling is once per second.

## Architecture status and remaining checks

All ten findings have corresponding implementation and tests, covering upload commits, target-workspace locks, stale results, storage failures, concurrent requests, bounded processes, shared connection services, background saves, isolated terminal updates, and the command catalog.

Offline management commands still create a full WorkspaceModel and CLI handlers still parse string operands. These remain follow-up refactors. Real VNC/Screen Sharing, PAM one-time-code sign-in, XQuartz rendering and input, broader Vim/tmux compatibility, update installation, and Intel builds also need verification. Feature-contract self-checks and other checks establish the coverage described in this record.

## Test harness correction

The quit-recording script initially hard-coded the older test app identifier. Its first rerun closed the previous test instance and failed the new instance's quit and save checks. After correcting the temporary script to this run's isolated identifier, all 6 checks passed. This required a test-script correction. Both the initial and corrected logs are retained in the local evidence.

## Reproduction and source

```sh
swift test --package-path Gloamux
cargo test --offline --locked --manifest-path Gloamux/RDP/Cargo.toml
Gloamux/scripts/package-app.sh
codesign --verify --deep --strict build/Gloamux.app
python3 Gloamux/scripts/stress-test.py --out /tmp/gloamux-stress-verification
```

Source digest SHA-256 is `7632fcf66a6a1b75b5cb4191dc4092d308109d132e70bb5a99700a1f1617f984`. It covers Sources, Tests, RDP/src, Package.swift, Package.resolved, Cargo.toml, and Cargo.lock, sorted by path and hashed as path, NUL, file bytes, NUL. Raw local evidence is in `analysis/verification-20261124/`, excluded by Git.
