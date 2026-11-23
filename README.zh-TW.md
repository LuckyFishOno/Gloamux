# Gloamux

[English](README.md)

Gloamux 是 macOS 原生的 SSH、檔案傳輸和遠端桌面工具。用資料夾整理連線，終端可以並排，伺服器的檔案就在 shell 旁邊。

## 重點功能

- **終端** · 分頁、拖曳分割窗格、本機 shell、Shell 整合、搜尋、錄影和 72 組配色。
- **SSH** · 密碼、金鑰、`ssh-agent`、Secure Enclave 金鑰、跳板、代理、連接埠轉發和 X11。
- **檔案** · 像 Finder 的檔案側欄、雙欄傳輸畫面，支援 SFTP、SCP、FTP 和 FTPS。
- **遠端桌面** · 在 Gloamux 分頁裡使用 RDP 和 VNC。
- **登入一次就好** · 密碼由 Secure Enclave 保護、只存在這台 Mac，也可另用密碼庫。
- **安全** · 為正式環境加上標籤，高風險指令執行前先確認。
- **帶著連線過來** · 可從 Xshell、MobaXterm、PuTTY、OpenSSH 或 CSV 匯入，匯出時不含密碼。
- **三種版面** · 預設、經典或工作台，介面提供英文、繁體中文、簡體中文、日文和西班牙文。

每項功能的細節請見[功能說明](FEATURES.zh-TW.md)。

## 建置

需要 macOS 14 以上、Xcode，以及 Rust 1.94 以上。

```sh
git clone https://github.com/LuckyFishOno/Gloamux.git
cd Gloamux
./Gloamux/scripts/package-app.sh
open build/Gloamux.app
```

執行測試：`swift test --package-path Gloamux`。

Gloamux 曾名為 Termac，更早叫 MShell。第一次啟動會把最近一個舊名稱的資料夾和設定搬過來，`.termacconfig`、`.termacsessions`、`.mshellconfig` 和 `.mshellsessions` 匯出檔也能照常匯入。指令改成 `gloamux`，連結改用 `gloamux://`。

## 命令列

在專案根目錄執行 `export PATH="$PWD/build/Gloamux.app/Contents/Resources/bin:$PATH"`，就能使用打包好的 `gloamux`。若要單獨建置命令列工具，可執行 `swift build --package-path Gloamux --product gloamux`。App 也附有 `gloam`，是同一個指令的簡寫。

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

檔案傳輸支援 SFTP、SCP、FTP 和兩種 FTPS，並沿用已儲存的連線設定。用 `--password-stdin` 輸入臨時密碼或私鑰密語，或用 `--vault-password-stdin` 解鎖這次指令使用的密碼庫。需要回答 SSH 額外登入問題時使用 `--interactive`。使用明文 FTP 須加上 `--allow-plain-ftp`。

SSH 會檢查已信任的主機金鑰。首次連線時，可用 `--host-key` 傳入已核對的 SHA-256 指紋，供這次連線使用。執行 `gloamux hosts --help` 可查看如何管理已儲存的主機金鑰。

`gloamux ssh` 使用相同的登入選項，在目前的終端機開啟連線的 shell。`gloamux tabs` 和 `gloamux commands send|run` 操作執行中的 App，`gloamux tabs list` 取得的分頁 ID 在任何視窗都能使用。`gloamux xserver` 檢查和啟動 XQuartz，不需要開著 App。

`gloamux mcp` 讓 AI 代理透過 [Model Context Protocol](https://modelcontextprotocol.io) 使用 Gloamux。在「設定 › AI 代理」開啟存取、允許代理可用的連線，再把那裡顯示的指令加到代理，例如 `claude mcp add gloamux -- /Applications/Gloamux.app/Contents/Resources/bin/gloamux mcp`。代理可以列出及開啟允許的連線、讀取你分享的輸出，並提出指令；指令要等你在 Gloamux 檢查後才會執行。`gloamux agents status|history|revoke|off` 可查看及撤銷存取。

用 `gloamux --help` 查看指令，或用 `gloamux <command> --help` 查看個別用法。管理指令輸出 JSON，檔案操作加上 `--json` 即可取得 JSON。結束碼 0 表示成功，1 表示操作失敗，2 表示用法錯誤，按 Ctrl-C 停止則為 130。`gloamux ssh` 會回傳遠端 shell 的結束碼。

Zsh 若尚未啟用補全，可先執行 `autoload -Uz compinit && compinit`，再執行 `source <(gloamux completion zsh)`。Bash 可用 `gloamux completion bash > ~/.gloamux-completion.bash` 儲存腳本，再用 `source ~/.gloamux-completion.bash` 載入。這個方式也適用於 macOS 內建的 Bash。

## 更多文件

- [功能說明](FEATURES.zh-TW.md)
- [開發指南](DEVELOPMENT.md)（英文）：程式目錄、測試和第三方授權
- [資料保護](DATA-PROTECTION.md)（英文）
- [路線圖](ROADMAP.md)和[功能清單](FEATURE-BACKLOG.md)（英文）

Gloamux 目前仍是初版。
