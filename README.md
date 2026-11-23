# Gloamux

[繁體中文](README.zh-TW.md)

Gloamux is a native macOS client for SSH, file transfer, and remote desktops. Keep your servers in one workspace: saved connections in folders, terminals side by side, and the server's files next to the shell.

## Highlights

- **Terminal** · Tabs and drag-to-split panes, local shell, shell integration, find, recordings, and 72 themes.
- **SSH** · Passwords, keys, `ssh-agent`, Secure Enclave keys, jump hosts, proxies, port forwarding, and X11.
- **Files** · A Finder-style file sidebar, a two-pane transfer view, and SFTP, SCP, FTP, and FTPS.
- **Remote desktop** · RDP and VNC in a Gloamux tab.
- **Sign in once** · Passwords stay on this Mac behind the Secure Enclave, with an optional password vault.
- **Safety** · Environment tags for production servers and confirmation before risky commands.
- **Bring your sessions** · Import from Xshell, MobaXterm, PuTTY, OpenSSH, or CSV, and export without passwords.
- **Three layouts** · Default, Classic, or Workbench. The interface is available in English, Traditional Chinese, Simplified Chinese, Japanese, and Spanish.

The [feature guide](FEATURES.md) explains every feature in detail.

## Build

Requires macOS 14 or later, Xcode, and Rust 1.94 or later.

```sh
git clone https://github.com/LuckyFishOno/Gloamux.git
cd Gloamux
./Gloamux/scripts/package-app.sh
open build/Gloamux.app
```

Run the tests with `swift test --package-path Gloamux`.

Gloamux was called Termac, and MShell before that. The first launch moves the data folder and settings from the newest earlier name, and `.termacconfig`, `.termacsessions`, `.mshellconfig`, and `.mshellsessions` exports still import. The command is now `gloamux`, and links use `gloamux://`.

## Command line

Add the packaged CLI to your shell path with `export PATH="$PWD/build/Gloamux.app/Contents/Resources/bin:$PATH"` from the repository root. To build the CLI by itself, run `swift build --package-path Gloamux --product gloamux`. The app also installs `gloam`, a short name for the same command.

```sh
gloamux sessions list
gloamux files ls --session "Work server" --json
gloamux files get --session "Work server" /remote/report.csv ./report.csv
gloamux files put --session "Work server" ./report.csv /remote/report.csv --overwrite
gloamux files get --session "Work server" /remote/logs ./logs --recursive
gloamux sessions add-other "Core switch" serial /dev/cu.usbserial-1 baud=115200 flow=rts-cts
gloamux ssh "Work server"
gloamux tabs list
gloamux tabs run TAB_ID "uptime"
gloamux tabs read TAB_ID 50
gloamux tabs multiexec TAB_ID on
gloamux forwards live-list
gloamux xserver start
gloamux settings set terminal.font-size 14
gloamux config export ~/Gloamux.gloamuxconfig
gloamux commands --help
```

`gloamux files` supports SFTP, SCP, FTP, and explicit and implicit FTPS. It uses the saved profile's authentication, proxy, jump hosts, and server trust. Use `--password-stdin` for a temporary password or key passphrase, `--vault-password-stdin` to unlock the vault for the command, and `--interactive` for additional SSH sign-in questions. The CLI leaves supplied credentials out of saved profiles. Plain FTP requires `--allow-plain-ftp`. SSH uses existing trusted host keys or a fingerprint you verify and pass with `--host-key`. Use `gloamux hosts --help` to manage saved trust.

`gloamux ssh` takes the same sign-in options and opens the session's shell in your terminal. `gloamux tabs` and `gloamux commands send|run` act on the running app; tab IDs from `gloamux tabs list` work in any window. `gloamux xserver` checks and starts XQuartz and does not need the app.

`gloamux mcp` lets an AI agent work with Gloamux over the [Model Context Protocol](https://modelcontextprotocol.io). Turn on **Settings › Agents**, allow the sessions an agent may use, and add the command shown there to the agent, for example `claude mcp add gloamux -- /Applications/Gloamux.app/Contents/Resources/bin/gloamux mcp`. The agent can list and open allowed sessions, read output you share, and propose commands that run only after you review them in Gloamux. `gloamux agents status|history|revoke|off` shows and revokes access.

Use `gloamux --help` for the command list, or `gloamux <command> --help` for syntax. Management commands return JSON. File commands support `--json`. Exit codes are 0 for success, 1 for a failed operation, 2 for invalid usage, and 130 when Ctrl-C stops a command. `gloamux ssh` exits with the remote shell's status.

In Zsh, run `autoload -Uz compinit && compinit` if completion is not initialized, then `source <(gloamux completion zsh)`. In Bash, save the script with `gloamux completion bash > ~/.gloamux-completion.bash` and load it with `source ~/.gloamux-completion.bash`. Loading from a file also works with the Bash bundled with macOS.

## More

- [Feature guide](FEATURES.md)
- [Development guide](DEVELOPMENT.md): source layout, tests, and third-party notices
- [Data protection](DATA-PROTECTION.md)
- [Roadmap](ROADMAP.md) and [feature backlog](FEATURE-BACKLOG.md)

Gloamux is an early release.
