# Gloamux verification record

[English](VERIFICATION.md) · [繁體中文](../zh-TW/VERIFICATION.md) · [Back to README](../../README.md)

This record lists the checks behind each release, newest first. The original November 24, 2026 architecture and stress-test baseline used the changes on top of `b1e4638` that ship in Gloamux 1.2 (build 3), packaged as `build/Gloamux.app`.

## Gloamux 1.8.2 (build 21): the empty Recordings and Runbooks windows (November 27, 2026)

- **What changed.** With nothing listed, the **Recordings** and **Runbooks** windows drew their header and empty message in the lower part of the window and left the top blank. No child of the split view could grow taller, so the split view shrank to its content, and AppKit placed it at the bottom of the window. The list column and the empty message now fill the window's height.
- **Unit tests.** `ToolWindowLayoutTests` (3) hosts each window at its default size and checks that the split view fills the window and the header sits at the top: empty Recordings, empty Runbooks, and Runbooks with one file. Before the fix the two empty cases failed.
- **Packaged app, renamed copy, isolated workspace.** The empty Recordings and Runbooks windows showed the header at the top and the message centered; the released 1.8.1 copy still showed them at the bottom. After **New runbook**, the list and the runbook filled the window.
- **Not checked.** Recordings with a video listed was not opened in the packaged app; a filled list already took the full height before this change. **New runbook** lists the new file but does not select it, in 1.8.1 too; this is not changed here.

## Gloamux 1.8.1 (build 20): Saved passwords stays responsive under accessibility clients (November 27, 2026)

- **What changed.** With no saved passwords, the **Saved passwords** sheet showed `ContentUnavailableView` once its list loaded. Inserted into a sheet that was already open, that view sent SwiftUI's accessibility update into an attribute-graph cycle without end as soon as VoiceOver, a window manager, or an automation tool read the window: the main thread stayed at full CPU and `gloamux` requests to the app got no answer. The sheet's empty state is now a plain symbol, title, and detail with the same text. The bug was present from 1.6 (build 17).
- **How it was found and narrowed.** In a diagnostic build that opened the sheet without Touch ID and read it with an `AXUIElement` client: the same view present from the sheet's first frame, a plain text, or a hand-built symbol and text inserted later did not hang; `ContentUnavailableView` inserted later did, in a stack and in a `ZStack`. The same view in the main window's Session Log did not hang. A view hosted in an `NSWindow` in a unit test never showed the cycle, so the regression test `SavedSignInsViewTests` keeps the view out of the sheet's source.
- **Other sheets under the same client.** Session properties, Rename, Paste history, and the Settings window: no cycle. No other sheet uses `ContentUnavailableView`.
- **Windows with `ContentUnavailableView`, released 1.8.1, empty workspace.** Recordings, Runbooks, Discover hosts, Host keys (both tabs, the History one switched while open), and the Classic layout's Session Log window each showed their empty view; the client read the whole app twice after each, with no cycle and no hang.
- **Packaged app, renamed copy, isolated workspace.** With **Saved passwords** open after Touch ID, three reads of the whole accessibility tree finished in under 0.05 seconds each, AttributeGraph reported no cycle, the app used about 5 % CPU, and `gloamux tabs list` answered at once. Before the fix the same steps hung the 1.6 and 1.7 copies.

## Gloamux 1.8 (build 19): the window video history (November 27, 2026)

- **What changed.** `videos.json` is a history: a listed video whose file is gone stays on the list with `exists` false until **Remove from List**, **Move to Trash** (which then only drops the entry), `gloamux videos forget`, or **Clear History** / `gloamux videos clear`, which keep the files. The list checks again when Gloamux becomes active. The old workspace `videos` folder is added to the list once. Rows show a first-frame thumbnail, the name without the start time, and the start time on the caption line; the player bar shows the folder.
- **Unit tests.** `VideoRecordingTests` (18): the earlier 16, a missing file kept and marked, removed without an error, forgotten and cleared with the files kept, the old folder listed only once, and names shown without the start time; the command-line test covers `exists`, `forget`, `clear`, and export refusing a missing file.
- **Packaged app, renamed copy, isolated workspace.** The Recordings window listed two demo videos and one deleted one; the deleted one showed **File not found** with its path and **Remove from List**; moving a file to the Trash in the Finder and reloading marked it; thumbnails, names, dates, and the folder path showed; `gloamux videos list` reported `exists`.
- **Not checked.** **Clear History** and **Remove from List** were not clicked in the packaged app; they are covered by the unit tests.

## Gloamux 1.7 (build 18): window video (November 27, 2026)

- **What it does.** Records the whole workspace window as H.264 MP4 or MOV without sound (ScreenCaptureKit and `AVAssetWriter`), from the toolbar, **Terminal › Record window video** (⇧⌘R), the command palette, or `gloamux videos start`. Videos are saved in Downloads by default (`video.folder`), listed in **Terminal › Recordings** through `videos.json`, and mode 0600.
- **Unit tests.** `VideoRecordingTests` (16): the pause timeline, limits and names, settings including the save folder, the writer for both formats (a pause cut out, 2.5 s, no audio track, 0600), an empty recording leaving no file, crash recovery in the workspace folder and in another folder, the list ignoring other files and dropping removed ones, the Recordings window building its player, and `gloamux videos` (agreement, `--yes`, `--window`, export, remove, settings).
- **Packaged app, renamed copy, isolated workspace, Screen Recording granted.** A sheet paused the clock (0:56 held); minimizing paused; resizing kept recording; a force-quit left a partial file that was named at the next launch as a 56.0 s MP4 with the pause cut out; MOV at 60 fps (11.46 s, 668 frames, Rec.709) shows the terminal text; stopping from the toolbar showed **Recording saved**, and **Show** opened the Recordings window, which plays the videos; closing the window saved the running video; during an app-modal alert the clock kept counting (11 to 16 s), and that 24.7 s video decodes.
- **Found and fixed during the checks.** SwiftUI `VideoPlayer` stopped the packaged release app when the Recordings window showed a video (a debug test build does not show it), so the player is AppKit's `AVPlayerView`. The clock's timer stopped during app-modal alerts; it now runs in the common run loop modes. Fragmented files with irregular frame times failed to write (-11800/-16341) until frame reordering was turned off.
- **Not checked.** Saving to Downloads in the packaged app needs Screen Recording granted again after re-signing; it is covered by the unit tests. A real accessibility client reading the window while **Saved passwords** is open hangs the app; this happens in 1.6 too and is not fixed in 1.7.

## Gloamux 1.7 (build 18): toolbar tooltips and the File Transfer and Session Log layout (November 27, 2026)

Made on top of `9670fcc` (1.6 build 17) and released in 1.7 (build 18).

- **User report.** In the Default layout, the Browser, Files, Quick commands, and Color theme buttons shared one toolbar item. AppKit shows one tooltip per item, so pointing at any of them showed "Browser", and moving between them kept that tooltip up instead of fading it and showing the next one. Each button is now its own toolbar item.
- **Unit test.** `WorkspaceToolbarTests.testEachSidebarButtonHasItsOwnToolbarItemAndTooltip` hosts the workspace in a titled window and checks that each button's tooltip belongs to one item that shows no other tooltip. With the four buttons put back in one item, it failed for Files, Quick commands, and Color theme.
- **User report: File Transfer and the Session Log ran under the panels.** The right panel could take all but 340 points, the terminal's minimum, but the two file panes needed about 700 and the log's list and details about 700, so they spilled over the session tree and under the browser. The center now keeps the room its mode needs (`DesktopView.centerMinimum`): 340 for the terminal, 734 for the two file panes and the arrows, 520 for the log; the right panel gives way, and the session tree keeps its 200-point minimum. The center is clipped, so nothing draws over the sidebars. The file panes always share the width equally, so the arrows stay in the middle (`CenteredColumns`). The log's list can shrink to 180 points, its details to 320; narrower, the log shows the list and a connection one at a time, and a connection's title row wraps its status and **Download log** under the name and turns the filter into a menu.
- **Unit tests.** `SidebarLayoutTests.testTheCenterKeepsRoomForItsColumnsInEveryMode` (each mode's room in a 1,268-point window with a 640-point right panel, and the session tree's minimum in a 1,040-point window) and `testTheTransferArrowsStayCentered` (equal panes and centered arrows at four widths).

## Gloamux 1.6 (build 17): the browser panel, test scripts, and the settings a renamed copy writes (November 27, 2026)

Built on `f72a8d5` (1.5 build 16), together with the kitty graphics work in the next section.

- **Design changes during the work.** A saved **Web page** connection type, with **Through SSH**, was built and checked first, then removed at the owner's request, so pages open only in the browser panel. The panel's pages became tabs in its header, drawn like the session tabs, and every panel on the right now shares one width that can be dragged as wide as the window less 340 points. The session tree's **New session from sftp command** menu items were removed; the command palette and pasting the command still work.
- **Unit tests.** `WebPageTests` (8: typed addresses and Google searches, refused schemes and credentials, download names, zoom limits, pages as tabs with the 20-page limit, the certificate limit, the User-Agent, that web is not a connection kind, and every `gloamux web` operation with bad inputs) and `BrowserPanelPageTests` (2: a page from a local server loads with Safari's User-Agent, then a second page, back, and forward; an HTTP Basic sign-in is reused on the same site and asked for again after **Clear website data**). `SidebarLayoutTests` checks the shared right width.
- **A sign-in kept after clearing, found in review.** **Clear website data** emptied the store with `removeData(ofTypes:)`, but WebKit still answered the site with the earlier HTTP sign-in; the new test failed that way before the fix. The panel now moves its pages to new website data and opens each again, from the menu and from `gloamux web clear-data`. Hiding the panel now pauses sound and video.
- **Swift suite.** 592 tests: 584 passed, 8 skipped (remote host and Xshell sample checks that need external inputs), 0 failures. The Rust remote desktop engine: 18 tests passed. Both suites run again in `release.sh build` on the release commit.
- **Settings written by a renamed copy.** With the app closed, `gloamux settings set` and `gloamux config import` from a renamed test copy wrote the installed app's domain, `local.gloamux.desktop`, because the command-line tool did not know which app it came from. It now writes the domain of the app it is inside, so `settings set terminal.scrollback 50000` from the copy changed only `local.gloamux.uitest`, and the installed app's settings stayed byte for byte the same through every run below.
- **Help next to `--workspace`.** `gloamux web --help --workspace PATH` refused `--help` as an unknown option, found by the new feature check. Every command now prints its help there too. New test: `CLICatalogTests.testHelpIsRecognizedNextToAWorkspace`. Commands that need the running app now say so without naming tabs, for example for `gloamux web`.
- **Feature check.** The new `feature-check.py` runs one working operation of every `gloamux` command group against the renamed copy, a throwaway workspace, a throwaway key-only `sshd` on 127.0.0.1, and local web servers. The first run passed 47 of 50; the three failures were the script's own: `tabs run` with empty text, a dropdown window with no hotkey setting, and a certificate made with macOS's LibreSSL whose EC key made the TLS handshake fail before the page could ask. Rerun alone, the app asked about an RSA certificate, refused a wrong fingerprint, opened the page with the right one, and refused another. After fixing the script: 50 of 50.
- **Stress test.** A full `stress-test.py --app` run against the renamed copy passed all 16 phases. 20 local and 10 SSH tabs printed 1,000,000 lines each at about 691,000 lines/s, with 712 MB at the peak and 157 MB after closing them. The new wide-text phase printed 200,000 CJK lines and 500 kitty images in 1.2 s. The browser panel kept 20 of 41 pages, loaded them in 2.7 s, made 70 navigations in 3.8 s, used 20 WebKit processes with 532 MB, and left no WebKit process after its pages were closed. The terminal benchmark showed CJK text at 71.4 MB/s.
- **Packaged app.** `package-app.sh` and `codesign --verify --deep --strict` passed. In a renamed test copy (`local.gloamux.uitest`) with its own workspace, driven through `gloamux web`: `show` and `open` loaded pages from a local `http.server` in the panel and no tab was added; a page reported `Version/27.2 Safari/605.1.15` from `navigator.userAgent`; `go`, `back`, `select`, `zoom 150`, `close`, `hide`, and `clear-data` worked; `open "gloamux terminal"` loaded Google's results; `ftp://` and `file://` addresses and unknown page IDs were refused with exit code 2; `sessions add-other ... web` was refused. The owner looked at the page tabs in the test copy and found them right. A page playing audio reported `pause` when `hide` closed the panel, and a page that sets a cookie found it after a reload but not after `clear-data`, which reopened the page by itself.
- Not checked: certificate approval and sign-in sheets against a real device, downloads by clicking, and installing the update through **Check for Updates**.

## Gloamux 1.6 (build 17): kitty graphics, pixel sizes, faster CJK text, the reconnected screen, and edited desktop sessions (November 26, 2026)

Working tree on top of `f72a8d5` (1.5 build 16), released in 1.6 with the browser panel above.

- **Unit tests.** New: `KittyGraphicsTests` (11: raw RGB and RGBA, chunked PNG, zlib, transmit then place, crop, placement ids, image numbers, delete with and without freeing, refused transfers that name a file, quiet modes, queries, the setting turned off, reset, and the `CSI 14 t`, `16 t`, and `18 t` replies), `WideTextTests` (6: runs of CJK, emoji, combining marks, ambiguous-width, invalid, and cut-off UTF-8 written in one read give the same screen as one byte at a time, plus 200 random texts and the width table), and `EndProgramTests` (4: a dropped shell, a dropped full-screen program, a half-read sequence, and clearing into the scrollback).
- **A hang found by the new tests.** In a terminal one column wide, a wide character never fit, so the row-at-a-time writer looped forever, and the per-character path would have indexed past the row. A wide character now takes the one cell there. The app keeps terminals at least 20 columns wide, so users could not reach it.
- **Swift suite.** 581 tests: 573 passed, 8 skipped (remote host and Xshell sample checks that need external inputs), 0 failures.
- **Benchmark.** `gloamux benchmark --megabytes 32` from the packaged build: CJK text 18.7 MB/s before and 67.5 MB/s after; full-screen redraws 25.8 and 50.0 MB/s; plain text, colored logs, and OSC 133 prompts did not get slower.
- **Packaged app.** `package-app.sh` and `codesign --verify --deep --strict` passed. In a renamed test copy (`local.gloamux.uitest`) with its own workspace:
  - In a local shell, a Python script showed a PNG sent in two chunks, a zlib-compressed RGB picture stretched to 12×3 cells, and a cropped second placement. The kitty query was answered `OK`, `CSI 14 t` reported 739×656, and the PTY reported the same pixel size (`ws_xpixel`, `ws_ypixel`).
  - Against a throwaway `sshd` on 127.0.0.1 that accepted only a key made for the run: after the connection was dropped at a shell prompt, **Connection lost** appeared under the last prompt, the automatic reconnect started on a cleared screen, and the earlier text stayed whole in the scrollback. Before the fix, `ESC [?1049l` moved the cursor to the top left, so the message and the new connection wrote over the earlier lines. Dropped inside a program that had turned on the alternate screen, a scroll region, red text, and mouse reporting, the reconnected shell scrolled the whole screen in the default color.
- **Edited desktop sessions (user report).** A VNC tab opened from a saved session kept the host and port it opened with, so after the port was changed from 5900 to 5901 in the form, **Connect** still tried 5900 and showed **Cannot connect to the remote desktop host**. Open desktop tabs that are not connected now take the saved session's new settings when it changes, from the form or `gloamux sessions edit` and `edit-other`. New test: `RemoteKindsTests.testAnOpenDesktopTabUsesTheEditedPortOnTheNextConnect`, which failed without the fix. Full Swift suite after it: 582 tests, 574 passed, 8 skipped, 0 failures. In a packaged `local.gloamux.uitest` copy, a tab opened on 127.0.0.1:5900 and then edited through the CLI to another port reached a stand-in RFB server on the new port when **Connect** was clicked.
- Not checked: `kitten icat`, `chafa`, and other real kitty clients (none installed), and pixel sizes over a real SSH server. The full `stress-test.py` run is in the section above.

## Gloamux 1.5 (build 16): terminal tools, ZMODEM, inline images, and Compatible SSH key exchanges (November 26, 2026)

Built on `395ad71` (1.4.6 build 15).

- **Unit tests.** New: `ZmodemTests`, `InlineImageTests`, `KeyExchangeTests` (each Compatible key exchange signs in to a local OpenSSH server that offers only it, with two cipher families, and Modern is refused), and `ShellEnvironmentTests` (the locale variables and terminal modes a shell receives). Added to: `TerminalInputTests` (xterm keys, bright bold colors, italic and faint text, spacing, ligatures and minimum contrast, copying wrapped rows, copy on select and middle-click paste, word characters and ambiguous width, paste trimming and joining, copy mode, double-click on paths), `TerminalViewBehaviorTests` (following output, accessibility input), `KeyFormatTests` (EC keys with a short scalar, in SEC1 and PKCS#8), `WorkspaceCommandTests` (the new settings, ZMODEM through a local shell including cancelling `sz` mid-transfer, the dropdown hotkey, paste history, and timestamps from the CLI), and `TerminalOutputViewTests` (a click while output arrives).
- **Swift suite.** 560 tests, 8 skipped (remote host and Xshell sample checks that need external inputs), 0 failures, before the release run. The Swift and Rust suites run again in `release.sh build` on the release commit.
- **A test that failed now and then.** In the first `release.sh build`, `MenuTintTests` failed because its menu never opened: run alone it failed once in three runs. A test process in the background sometimes gets no menu tracking, so `popUp` returned at once. The test now tries again when the menu did not open and checks the theme the same way once it does; it then passed 8 runs in a row.
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
