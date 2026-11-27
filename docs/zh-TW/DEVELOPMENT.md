# Gloamux 開發指南

[English](../en/DEVELOPMENT.md) · [繁體中文](DEVELOPMENT.md) · [回到 README](../../README.zh-TW.md)

[驗證紀錄](VERIFICATION.md)包含 2026 年 11 月 25 日的本機序列埠／終端檢查，以及 11 月 24 日的全 App 壓力測試基準。

## 目錄

1. [原始碼結構](#原始碼結構)
2. [建置](#建置)
3. [撰寫慣例](#撰寫慣例)
4. [本機資料](#本機資料)
5. [連線樹、版面與視窗](#連線樹版面與視窗)
6. [憑證與密碼庫](#憑證與密碼庫)
7. [終端](#終端)
8. [安全與 Mac 整合](#安全與-mac-整合)
9. [檔案與通訊協定](#檔案與通訊協定)
10. [命令列](#命令列)
11. [X11](#x11)
12. [遠端桌面](#遠端桌面)
13. [更新](#更新)
14. [效能](#效能)
15. [測試](#測試)
16. [第三方授權聲明](#第三方授權聲明)

## 原始碼結構

Swift 套件位於 [Gloamux](../../Gloamux)。

| 路徑或 target | 內容 |
|---|---|
| `GloamuxApp` | 執行檔。啟動 macOS 介面，也同時是 `gloamux` 命令列。 |
| `GloamuxShared` | 每個模組都要實作的功能約定。 |
| `Sources/app` | 連線樹、視窗、分頁、設定和憑證密碼庫。 |
| `Sources/app/Resources/<語言>.lproj` | 介面文字（`Localizable.strings`），以英文原文為鍵。 |
| `terminal`、`LocalPTY` | 終端狀態和本機登入 shell。 |
| `ssh`、`network`、`file-transfer` | 遠端工作階段和 SFTP。`network` 的模組名為 `GloamuxNetwork`，以免遮住 `AppIntents` 等系統模組使用的 Apple `Network` 框架。 |
| `Sources/intents` | 捷徑用的 App Intents（模組 `ShellIntents`），不依賴套件中其他任何部分。 |
| `RDP` | Rust 寫的遠端桌面輔助程式。 |
| `scripts` | 打包、發布、主題和壓力測試。 |

## 建置

- `Gloamux/scripts/package-app.sh` 會建置最佳化的正式版 App `build/Gloamux.app`。可以把不同的建置快取和輸出位置當作第一和第二個參數傳入。
- 除錯版解析和繪製終端輸出會慢好幾倍，判斷反應速度請用打包好的 App。
- 打包需要 Rust 1.94 以上和 Cargo，用來建置遠端桌面輔助程式。
- `GLOAMUX_VERSION` 和 `GLOAMUX_BUILD` 可以覆寫單次建置的版號。`GLOAMUX_FEED_URL` 讓測試版本改用其他更新清單。見[發布流程](RELEASING.md)。
- SwiftPM 會警告 `swift-nio-ssh` 和 `swift-nio-ssl` 的套件身分衝突。Gloamux 使用[內附的 swift-nio-ssh](../../Gloamux/Vendor/swift-nio-ssh/VENDORED.md) 處理 agent 和 X11 轉發，使用[內附的 swift-nio-ssl](../../Gloamux/Vendor/swift-nio-ssl/VENDORED.md) 處理 FTPS 的 TLS 工作階段重用。Citadel 和 swift-nio-extras 透過上游網址宣告了相同的套件身分。SwiftPM 會使用本機副本，所以在目前的工具鏈下這個警告是預期中的。升級 SwiftPM 時請重新檢查解析結果，未來版本可能會把這個衝突當成錯誤。

## 撰寫慣例

### 介面文字

- 說明放在 `InfoButton`（「!」彈出視窗，是 AppKit 的 `NSPopover`，打開時不會重繪周圍的 SwiftUI 畫面）後面，不寫成說明段落。
- 標籤要短。翻譯較長時，用 `.fixedSize(horizontal: false, vertical: true)` 讓標籤換行，不要截斷。
- 任何語言的介面文字都不能以「…」或「...」結尾。
- 文字目錄有 `en`、`zh-Hant`、`zh-Hans`、`ja` 和 `es`。每個新的 `T("…")` 字串都要加進五個目錄，`TerminalInputTests` 會檢查各目錄的鍵是否一致。
- 語言選擇存成 App 的 `AppleLanguages` 偏好設定，與系統設定中每個 App 的語言是同一個值。`package-app.sh` 在 `CFBundleLocalizations` 中宣告內附的語言。

### 文件

- 文件以英文撰寫，放在 `docs/en`，同名的繁體中文版放在 `docs/zh-TW`。README 則是 `README.md` 和 `README.zh-TW.md`。兩種語言要一起更新。
- 編輯繁體中文時使用 [Humanizer-zh](https://github.com/op7418/Humanizer-zh/blob/main/SKILL.md)。同一個動作用同一個詞，並保留原本的條件、格式佔位符和指令範例。

## 本機資料

Gloamux 的工作檔案放在 `~/Library/Application Support/Gloamux`。做介面檢查時，對 App 執行檔傳入 `--workspace /path/to/test-workspace`，把這些檔案和平常的工作區隔開。

| 檔案 | 內容 |
|---|---|
| `sessions.json` | 連線目錄：連線設定、金鑰檔路徑、轉發規則、自訂順序和排序方式。 |
| `saved-sign-ins.json` | 這台 Mac 記住的密碼和金鑰密語。 |
| `password-vault.json` | 可選的密碼庫，以主密碼加密。 |
| `known-hosts.json`、`host-key-history.json` | 信任的主機金鑰，以及每次主機金鑰的決定（最多 2,000 筆）。 |
| `quick-commands.json` | 常用指令，以純文字儲存。請不要把機密放進已存指令。 |
| `layout.json`、`appearance.json`、`settings.json` | 工作區版面、主題和工作區設定。 |
| `triggers.json` | 輸出觸發規則。 |
| `connection-history.jsonl` | 每次連線的事件，一行一個（見 `ConnectionHistory`；指令來自 `CommandCapture`）。 |
| `open-tabs.json`、`recent-sessions.json` | 啟動時要重新打開的分頁，以及最近開啟的連線。 |
| `agent-access.json`、`agent-activity.json` | AI 代理存取、允許的連線和活動紀錄。 |
| `ssh-key-secure-enclave` | Gloamux 的 Secure Enclave SSH 金鑰（見 `AppSSHKey`）。 |
| `runbooks/`、`recordings/`、`logs/` | Runbook 和執行結果、錄影，以及連線紀錄（權限 0600）。 |
| `videos.json` | Gloamux 存過的視窗錄影（在下載項目或 `video.folder`）和錄製中檔案的路徑，讓中斷的錄影在下次啟動時取好檔名（權限 0600）。 |
| `videos/` | 改存下載項目之前的視窗錄影（權限 0600），仍會列出。錄製中的檔案是隱藏的 `.NAME.recording.mp4` 或 `.mov`。 |

命名：

- 所有地方都用 Gloamux 這個名稱：GitHub 儲存庫、App（`Gloamux.app`，bundle ID `local.gloamux.desktop`）、資料夾、`gloamux` 指令、`gloamux://` 連結和介面文字。App 也把 `gloam` 連到同一個執行檔；`main.swift` 把兩個名稱都當成 CLI。
- Gloamux 曾名為 Termac，更早叫 MShell。除非傳入 `--workspace`，否則在 Gloamux 資料夾還不存在時，`LegacyName.migrate` 會把最近一個舊資料夾（先找 `Termac`，再找 `MShell`）搬過來；`local.gloamux.desktop` 沒有設定時，會複製最近一個舊設定（先找 `local.termac.desktop`，再找 `local.mshell.desktop`）。舊 App 正在執行時不會做任何事。使用舊副檔名和格式名稱的匯出檔仍可匯入。

## 連線樹、版面與視窗

### 連線樹

- 連線樹是 AppKit 的 `NSOutlineView`（`SessionOutline`），拖曳使用系統的拖曳工作階段：拖到邊緣會捲動，也會跟著滾輪。`SessionOutlineDrop.resolve` 把大綱提出的位置轉成上層資料夾與要排在前面的項目；依名稱排序時放在兩列之間，會先呼叫 `SessionTreeStore.keepShownOrder()`。右鍵選單由 `SessionTreeView.contextMenu(for:)` 用 AppKit 建立，對話框底部統一使用 `DialogActions` 按鈕列。
- 使用者拖曳排列後，`sessions.json` 的項目可能帶有 `order`。`SessionTreeStore.children(of:)` 先列出有排序的項目，再列出沒排序的項目（資料夾優先、依名稱），所以舊目錄能保持原本的順序。
- `drop(_:on:_:)` 套用拖曳，即使連線樹依名稱排序，也會依自訂順序重新編號該資料夾。
- 目錄中可選的 `sorting` 欄位（`nameAscending` 或 `nameDescending`；沒有就是自訂）決定 `children(of:)` 如何列出項目。

### 版面

- 工具列的版面選單和 `gloamux layout` 都會設定 `layout.json`。選單會立即套用；App 開著時 CLI 的變更也一樣，否則下次啟動才套用。
- `layout set` 接受 `default`、`classic` 和 `workbench`，分別存成 `macos`、`terminal` 和 `transfer`。`xshell`、`mobaxterm` 等舊名稱仍然可用。
- 經典和工作台的外框程式碼在 `ClassicLayouts.swift`，模型支援（網址列、輸入列、跟隨資料夾、主機監控）在 `ClassicWorkspace.swift`。
- 預設版面的工具列可以在檔案傳輸和終端之間切換。新連線分頁列出本機、SSH、RDP、VNC 和其他連線。本機會在原分頁啟動登入 shell；其他通訊協定會開啟各自的表單。
- `ThemeTitlebar` 用視窗背景色和工具列下方一層不攔截點擊的底色替標題列上色。它不開啟 `titlebarAppearsTransparent`，維持 SwiftUI 的設定：透明的標題列會把點擊交給視窗內容，雙擊就不再填滿或縮放視窗。切換版面會替換這個畫面，它離開視窗時會一併移除自己的底色。

### 視窗與多重執行

- 工作區視窗各有獨立的模型和分頁，共用連線目錄、密碼庫、已知主機、常用指令、最近使用和 runbook。
- 新視窗以本機終端開始。第一個視窗擁有已存分頁的快照。關閉工作區會清理它的工作階段和工具視窗，關閉最後一個會結束 App。
- 多重執行（`WorkspaceModel.multiExec`）屬於單一視窗。`typeTerminal` 會把輸入送到該視窗中每個就緒的終端，包括移到獨立視窗的分頁，並略過唯讀終端和遠端桌面。每個目標仍會套用高風險指令檢查。
- 通道視窗和 `gloamux forwards live-list` 共用 `WorkspaceModel.tunnelTabs`，它只列出已連線的 SSH 分頁，因為沒連線的分頁顯示的是新連線表單。
- 下拉視窗（`DropdownWindow.swift`）用 Carbon 的 `RegisterEventHotKey` 註冊快速鍵，不需要輔助使用權限；它接手下一個開啟的工作區視窗，並讓它浮在每個桌面空間上。`gloamux layout dropdown` 可顯示或隱藏它。

### 所有權

- **所有視窗共用：** 連線目錄、已知主機、密碼庫、常用指令、觸發器、最近使用和 runbook，只建立一次，再傳給每個新的 `WorkspaceModel`（`sharing:`）。
- **單一視窗：** 它的分頁、選取、分割、版面狀態、工具視窗、多重執行和鎖定。
- **單一連線：** `SessionTab` 擁有它的 SSH 工作階段、尚在建立的跳板主機、檔案通道、shell、轉送、保持連線與重新連線的工作，以及 `epoch`。`disconnect` 會關閉這些並更換 `epoch`，為舊連線開始的工作會結束或被忽略。它也會取消 `reconnectTask`；被取消的重新連線嘗試不會再排下一次。把分頁移到自己的視窗（`moveTabToWindow`）再移回來，連線保持不變；關閉那個視窗會中斷連線，關閉工作區視窗也會一併關閉這些視窗。
- `ConnectionService`（`model.connections`）只用共用資料開啟 SSH 與 FTP 連線：擁有者確認、以 Touch ID 讀取密碼庫、跳板主機、登入、保存憑證，以及檔案通道（`openFiles`）。每次連線都帶一個 `SignInHandler`。`TabSignIn` 在分頁中顯示主機金鑰與登入問題、保存成功的憑證，分頁的 `epoch` 一變就停止；`CommandSignIn` 只接受已信任或 `--host-key` 指定的金鑰、用 `--interactive` 回答，且不保存任何東西。回傳的連線由呼叫端擁有。
- 連線在 `SavedConnection.jumpPath` 列出它的跳板：`jumpSessionID` 是最後一台（舊版目錄也有的欄位），`earlierJumpSessionIDs` 是它之前的幾台。`SessionTreeStore.jumpChain` 會把第一台自己的跳板鏈放在清單前面，和 OpenSSH 的 `ProxyJump` 一樣，所以只有一台跳板時串接方式不變。`openSSH` 依 `hops` 的順序接收每一層輸入的機密（`jumpSecrets`）。匯出時寫入 `earlierJumps`（Gloamux 格式）或以逗號分隔的 `ProxyJump`（OpenSSH）；CSV 只保留最後一台跳板。
- 經由跳板連上後，`SessionTab.route` 列出每個 `RouteStop`（名稱、端點、已信任的主機金鑰指紋），`routeSessions` 保留各層跳板的工作階段。`checkRoute` 只在使用者要求時才在每一台執行 `printf '%s' "$SSH_CONNECTION"`，因為設有強制指令的伺服器會改跑那個指令；`RouteStop.Seen` 只接受四個欄位且為 IP 位址的回覆。
- `SessionTab.connectionState` 是 `disconnected`、`connected` 或 `lost`，`moveConnection(to:)` 會拒絕不合法的變化（從未連上的分頁不會變成連線中斷）。`connected` 與 `transportLost` 都由它讀出。
- 經 SSH 連到的遠端桌面擁有一個 `DesktopGateway`：只有 SSH 連線和本機轉送，沒有隱藏的終端機分頁。`GatewaySignIn` 在桌面窗格中顯示主機金鑰與登入問題。`WorkspaceModel.settleHostKey` 是信任或取代金鑰的唯一位置，分頁和閘道共用。

### 主執行緒與重繪

- 大量工作不在主執行緒上執行。`TerminalRecordings.stop` 會立刻移除錄製器並回傳一個 task；`RecordingSnapshot` 在分離的 task 中遮蔽並寫入檔案，一次存一個，依停止的順序。檔名已被使用時會加上「 2」、「 3」等。存檔失敗的錄製會留在 `unsaved`，直到按**重試**。結束 App 時會等待 `finishRecordingsBeforeQuit`，要捨棄未存的錄製前會先詢問。
- `LocalBrowserState.load` 在主執行緒之外列出資料夾。較新的載入會勝過較舊、較慢的載入，第一次列表出現前 `loading` 會顯示轉圈。
- 終端機輸出只會增加 `TerminalOutput.revision`，只有終端機畫面和跟著輸出的小畫面（游標或位元組數、側邊檔案列表）會觀察它。`SessionTab.screenRevision` 讀寫的就是它，所以大量輸出不再重繪工作階段窗格、它的標題列或分頁列。`ViewEvaluations` 在除錯版本中計算畫面的求值次數，讓測試能檢查這點；正式版本中它不做任何事。
- `CLICatalog.localPaths` 標出哪些參數是本機路徑，命令列會先依自己的工作資料夾解析它們，再把請求送到 App。

## 憑證與密碼庫

### 密碼存放位置

- 沒有密碼庫時，能登入的密碼和金鑰密語由 `CredentialVault.rememberWorking` 存進 `DeviceSecrets`：AES-GCM 項目，以項目 ID 為關聯資料，金鑰由不需要 Touch ID 的 Secure Enclave 金鑰協商重建。重新開機後不需主密碼也能用。密語使用 `passphrase:<金鑰路徑>` 作為項目 ID。
- 沒有 Secure Enclave 時，機密存進主密碼密碼庫。
- 建立密碼庫後 `DeviceSecrets` 仍然保留，所以密碼庫鎖定不會讓連線無法連上。
- **存入密碼庫**（`CredentialVault.addToVault`）會在密碼登入前就先儲存。
- `SavedSignInsView` 列出兩個存放處（`CredentialVault.Place`），並在 `WorkspaceModel.authorizeSavedSignIns` 之後顯示、拷貝或刪除其中一份。
- 移除金鑰會呼叫 `forgetRemembered`，刪除這台 Mac 上的副本；密碼庫解鎖時也會刪除密碼庫中的副本。

### 解鎖與確認

- 密碼庫把 Touch ID 解鎖用的資料以 Secure Enclave 保護放在記憶體中。新的 App 程序需要主密碼。
- 密碼庫解鎖時，`connect` 會略過每個連線的 `confirmsEachConnection` 檢查；鎖定時則會執行，在使用已存機密前呼叫 `WorkspaceModel.confirmOwner`（Touch ID 或 Mac 密碼）。新連線預設開啟這項檢查。檢查只保護金鑰，或為該帳號記住的密碼與密語（`CredentialVault.hasRemembered`，不讀取機密），所以尚未保存任何東西的第一次連線、這次輸入的密碼，以及匿名 FTP 都不會詢問。
- 需要的機密只存在已鎖定的密碼庫（`CredentialVault.lockedVaultIDs`），且本次啟動已設定好 Touch ID 時，`readWithTouchID` 會在不解鎖密碼庫的情況下把那些項目讀進 `sessionPasswords`，這次提示也代替了每個連線的檢查。測試用 `enableTouchIDForTesting` 取代提示。

### Secure Enclave SSH 金鑰

- `ssh-key-secure-enclave` 存的是只有這台 Mac 能用的加密表示。
- 新金鑰簽章時不需要 Touch ID。需要 Touch ID 的舊金鑰會在每次啟動、載入金鑰時（SSH 交握之前）詢問一次，所以連線事件迴圈上的簽章不會等待使用者。

## 終端

### 畫面與 Shell 整合

- RIS（`ESC c`）與目前的 DECSTR（`CSI ! p`）實作會以當下的 `rows`、`cols` 重建兩個畫面緩衝區，不使用初始 `TerminalOptions` 尺寸。任何傳輸來源都可能在縮放後送出重設；緩衝區與公開尺寸必須一致，避免 `TerminalDisplay` 讀取越界。`TerminalResetTests` 涵蓋放大、縮小、替代畫面與反覆縮放／重設；`TerminalOutputViewTests` 驗證實際重繪流程。
- `SerialDevice.connected()` 保留 `sessions serial-ports` 使用的 `/dev/cu.*` 清單，透過 IOKit 上層裝置辨識 USB 轉接器。`ContainerSessionEditor` 以隨畫面取消的 task 立即搜尋、每秒更新。只有新表單的空白裝置欄且僅一個 USB 轉接器時才自動帶入；已儲存和手動輸入的路徑會保留。搜尋過程不開啟連接埠。

- `TerminalScreen`（在 `Sources/terminal`）把 OSC 133 標記記錄成帶絕對行號的 `CommandMark`（`trimmedLines` 加上回捲索引，讓標記在修剪後仍然有效），並發出 `TerminalEvent.commandFinished`。
- OSC 8 連結放進連結表，每個 `CellStyle` 保留一個不會被 SGR 0 清除的連結索引。OSC 7 設定 `workingDirectory`。
- 本機 zsh 透過 `ZDOTDIR` 載入標記，`ZDOTDIR` 指向使用者暫存資料夾中產生的 `.zshenv`（`ShellIntegration.zshDirectory()`）。它會還原使用者的 `ZDOTDIR`，並在第一個提示字元時把自己的 hook 加在使用者的 hook 之後。
- 其他 shell 和 SSH 工作階段取得單行的 `ShellIntegration.hook`，依要求輸入，或在 **設定 › 終端** 如此設定時自動為 SSH 輸入。
- `TerminalScreen` 也追蹤滑鼠模式（1000、1002、1003，以及 1006 的 SGR 座標）、焦點回報（1004）、DECSCUSR 游標形狀和 OSC 52 剪貼簿寫入；`terminalReceived` 只在 **設定 › 終端** 允許時才套用剪貼簿寫入。
- 其他編碼的工作階段會在解析前由 `TerminalDecoder` 轉成 UTF-8，輸入則在 `enqueueTerminalInput` 中轉回去。編碼存在連線上（`SavedConnection.encoding`）。
- 終端設定使用 `TerminalPreferences` 中的 `Gloamux.terminal.*` 鍵。
- `TerminalFonts` 選好文字字型後，會在一般與粗體的 cascade list 加入內附的 Symbols Nerd Font Mono v3.5.1。否則 macOS 對 Powerline／Nerd Font 的私用區字元會使用 LastResort，即使其他已安裝字型恰好涵蓋相同碼位。符號字型只註冊於 App 程序，不會安裝到使用者的字型資料夾；未修改的上游檔案、MIT 授權、來源網址和 SHA-256 放在 `Resources/TerminalFonts`。只有圖示的字型不會出現於文字字型選單。`TerminalLineRenderer` 依此 cascade 解析私用區圖示，把圖示前進寬度校正成解析器的格寬，並固定段落列高。ASCII 仍依樣式合併，其他 Unicode 字型後備維持可用。`TerminalFontTests` 檢查實際 TextKit 字型、位置、游標偏移和列高。

### 本機程序

- 本機程序透過 `LocalPTY.c` 中的 `gloamux_spawn_command` 啟動，它接受參數陣列和額外的環境變數。
- 容器工作階段透過登入 shell 執行 `docker`、`kubectl` 或 `aws ssm start-session`（`LocalLaunch.command`）。
- 從 Finder 開啟的 App 沒有 locale 環境變數，所以除非已設定 `LANG`、`LC_ALL` 或 `LC_CTYPE`，`LocalShell` 會像 Terminal 一樣，從 `LocalLaunch.localeEnvironment` 補上 `LANG`（這台 Mac 的語言和地區加 UTF-8，否則用 `en_US.UTF-8`）。少了它，`ls` 會把非 ASCII 檔名印成 `?`，Powerlevel10k 以外的 zsh 主題也會顯示成亂碼。

### 輸出流程

- 每個終端的輸出都經過 `WorkspaceModel.terminalReceived`，再送給畫面、錄影器和指令觀察者。
- 在看不到的分頁中，執行時間達到通知門檻的指令完成時，會在該分頁設定 `attention`，並在 Gloamux 以 App 套件執行時送出通知。
- Runbook（`Runbooks.swift`，`runbooks/` 中的 Markdown）一次以括號貼上送出一個區塊，等待它的 `commandFinished`，遇到第一個失敗就停止，並把結果存在 `runbooks/.results/`。
- 錄影（`TerminalRecording.swift`）只保留輸出，儲存時經過 `SecretRedaction`（也能找出被切成多段的機密），並把 asciicast v2 檔寫到 `recordings/`。
- 連線紀錄（`TerminalLogs`）寫到 `logs/`，並逐行以 `SecretRedaction` 遮蔽。
- 視窗錄影（`VideoRecording.swift`）用 ScreenCaptureKit 擷取工作區的 `NSWindow`（`SCContentFilter(desktopIndependentWindow:)`，縮放到開始時的大小），再以 `AVAssetWriter` 每兩秒一段寫入 H.264。`VideoTimeline` 依主機時鐘的擷取時間放置每一格，並剪掉因 `NSWindow` 工作表和縮到 Dock 通知而暫停的時段。`VideoRules` 放上限和檔名規則；`CaptureWriter.append` 是測試在沒有螢幕時驅動的路徑。`VideoRecordings` 每個工作區視窗一個，寫入 `VideoSettings.folder`（沒設 `video.folder` 時是下載項目），以 `videos.json` 記錄自己的影片和錄製中的檔案（同一工作區的視窗共用，所以每次變更都重新讀取），每次啟動把殘留的錄製中檔案改回正式名稱一次，並在 `closeWorkspaceWindow` 和 `finishRecordingsBeforeQuit` 完成檔案。`VideoRecordingUI.swift` 有工具列按鈕、一次性的同意說明和權限工作表；`WorkspaceCommandVideos.swift` 是 `gloamux videos`。

### 終端畫面

- `TerminalDisplay` 把回捲和畫面以帶屬性的行繪製在 `NSTextView`（`TerminalTextView`）中，只替換有變動的行。
- 預設背景上的儲存格不帶背景色，所以畫面本身的顏色（可以在 `TerminalBackdrop` 這個視窗後方的 `NSVisualEffectView` 上半透明）會透出來。
- 游標是蓋在儲存格上的獨立 `TerminalCursorView`。改變形狀、焦點或閃爍都不會重繪任何一行，閃爍是 Core Animation 的關鍵影格動畫。
- 輸入法組字保留在畫面中並繪製在游標上。它從不進入文字儲存，組字期間每個按鍵都交給輸入法。
- 搜尋列搜尋文字儲存，並用 layout manager 的暫時屬性標示符合項目。搜尋列開著時，新的輸出會在 0.2 秒後重新搜尋。
- 更新前畫面離底部在一行半以內、且沒有顯示搜尋結果時，新輸出會捲到底部（`showsScreenBottom`，在新行讓畫面變高之前讀取），即使選取了文字也一樣。打字一律捲回底部。
- 按住左鍵選取時（`selectingWithMouse`），`TerminalDisplay` 只把最新一次更新存在 `heldUpdate`，等 `mouseDown` 返回後連同游標一起執行。AppKit 追蹤滑鼠時用字元位置記住按下的位置，並以游標底下的位置當選取終點，所以點擊期間輸出改變或捲動文字，原本會選取一整行。`TerminalOutputViewTests` 用 run loop 計時器驅動追蹤迴圈，因為迴圈裡不會執行 main queue 的區塊。
- **終端 › 拷貝模式**（`TerminalCopyMode.swift`）在文字儲存上移動鍵盤游標，並和滑鼠走同一條 `copy` 路徑拷貝。`PasteHistory` 在記憶體保留 20 筆，跳過 `SecretRedaction` 會改動的文字。`LineTimes` 在每次輸出時，標記舊游標行到新游標行之間的絕對行號。
- 透過輔助使用設定選取文字或內容值的輔助 App（例如「語音控制」和聽寫），會把文字打進終端，而不是修改畫面內容。
- ZMODEM：`Zmodem.detect` 在分頁輸出中找 `**` ZDLE `B00`（`sz` 要傳檔）或 `B01`（`rz` 在等檔案），之後由 `Zmodem`（在 `Sources/terminal`）處理該分頁的位元組。`ZmodemTransfer` 把收到的檔案直接寫進資料夾（`ZmodemDownload`：只取路徑最後一段、同名加編號、不完整的檔案會刪除）並顯示進度列。Gloamux 中止下載後，`sz` 仍會送出已排入的資料，所以會丟棄輸出，直到線路安靜 0.3 秒（最多 5 秒），並只顯示最後一個 ZDLE 之後的文字。已用 lrzsz 0.12.21rc 驗證。

## 安全與 Mac 整合

- 環境標籤存在 `SessionTreeNode.environment`；連線會從資料夾繼承（`effectiveEnvironment`）。
- 在 **設定 › 安全** 選擇的環境中，`typeTerminal` 會攔住符合 `RiskyCommands.patterns` 的那一行，直到窗格的警示被回應。shell 有回報 OSC 133 B 標記時，這一行取自標記之後的畫面，否則取自輸入的內容。
- 能否連線的圓點來自對每個可見已存主機 SSH 連接埠的非阻塞 TCP 連線，一次最多六個，每 90 秒一次。透過代理、跳板或容器的連線不會檢查。
- 選單列項目、指令面板（`CommandPalette.swift`）、Spotlight（`SpotlightIndex`，只有名稱和位址）、`gloamux://open?id=` 和 `gloamux://new-terminal` 連結，以及捷徑動作，都呼叫同一組 `WorkspaceModel` 操作。
- `package-app.sh` 會對 SwiftPM 為 `ShellIntents` 產生的常數值執行 `appintentsmetadataprocessor`，寫出 `Metadata.appintents`。少了它 App 仍能運作，但捷徑裡不會列出 Gloamux 的動作。
- 1.2.2 的這次 Siri 事件中，`linkd` 登記 ad hoc 簽章 App 的執行中程序失敗（缺少 Team ID），把原本的 App 當成冷啟動，並在 30 秒閒置寬限期後送出 Quit Apple 事件。1.3 (build 6) 起的保護會在工作區視窗開著時，於 `applicationShouldTerminate` 拒絕這個 Quit（`QuitRequest` 從 `keySenderPIDAttr` 取得寄件者 PID，再由 `proc_pidpath` 查執行檔名稱）。沒有工作區、無法識別寄件者或其他寄件者時，仍走原有退出流程；⌘Q、Dock、登出與重新開機保留原有處理。六項 `QuitRequestTests` 檢查判斷條件與程序名稱查詢，封裝版的寄件者模擬測試見 VERIFICATION；修正版的真實 Siri 請求仍待驗證。

## 檔案與通訊協定

- `RemoteFileSystem` 由瀏覽器、佇列、預覽和 CLI 共用。
- SSH 預設用 SFTP，子系統被拒絕後改用 SCP。設定檔可以強制使用其中一種。OpenSSH SFTP 的取代使用伺服器宣告的 `posix-rename@openssh.com` 擴充。
- FTP 使用被動式資料連線。明確和隱含 FTPS 會加密兩條連線，在資料連線上重用控制連線的 TLS 工作階段，並使用系統信任或已驗證的憑證釘選。
- 檔案傳輸都經過 `TransferQueue`，由 `WorkspaceModel.transfers` 在檔案側欄（`RemoteFileSidebar`，本機終端時顯示 `LocalTreeState`）、雙欄的 `FileTransferView` 和所有版面之間共用。預設版面在 `workspaceMode` 為 `.files` 時於主視窗顯示 `FileTransferView`，並跟著選取的分頁；經典和工作台則在附伺服器選單的 `FileTransferWindow` 中顯示。`.log` 時顯示 `ConnectionHistoryView`，`selectTab` 會離開；其他版面以工具視窗打開。
- 佇列在分頁的 SFTP 通道上一次執行一個項目。上傳會先寫入暫存的 `.name.gloamux-….partial` 檔，再用 `RemoteFileSystem.commitUpload` 放到定位；已有檔案時使用 `replace`，不會先刪除舊檔。下載會在目的地旁寫入隱藏的暫存檔。CLI 上傳和 **在這台 Mac 編輯** 也會先放在遠端的暫存名稱，再用同樣方式提交。
- `SFTPTransfer` 同時保持 16 個 32 KiB 的讀取或寫入，並在工作取消時停止。
- SSH 金鑰交換預設為「新式」（只有橢圓曲線），連線選「相容」時才加入 `FiniteFieldKeyExchange`：建立在 BigInt 套件上的 `diffie-hellman-group16-sha512` 與 `diffie-hellman-group14-sha256`（RFC 8268，RFC 3526 群組），不提供 SHA-1 群組。每個 shell 請求都會像 `SendEnv` 一樣，提供 `LocalLaunch.sshEnvironment` 的 `LANG` 與 `LC_*`。
- `SFTPCommand` 解析貼上的 `sftp` 指令，並拒絕會改變連線路徑或執行程式的選項。`SavedConnection.signIn` 是 `questions` 或 `session-key`；session key 只存在 `SessionTreeStore.sessionKeys`。
- `AuthWatcher` 只跟隨真正連上的 channel。一個名稱有多個位址時，每個位址各有一個 channel，被拒絕的位址不能讓登入失敗。
- 遠端快速查看會把一個最多 100 MB 的檔案複製到私有暫存資料夾，並在下一次預覽和結束時刪除。
- 已存的轉發規則與連線一起存在 `sessions.json`。本機和動態轉發在這台 Mac 的回送介面上監聽；反向轉發會請伺服器在它的回送介面上監聽。監聽連接埠留空會自動分配。

## 命令列

- `gloamux` 產品與 App 共用執行檔。`WorkspaceCommand` 分派管理操作。
- `CLICatalog` 是所有公開指令與操作的唯一清單。`gloamux --help`、各指令的 `--help`、shell 補全，以及 `files` 的路徑數量都由它產生；不論 App 有沒有開，`WorkspaceCommand.run` 都會先拒絕清單上沒有的操作，什麼都不執行。新增指令或操作時先加在這裡；`CLICatalogTests` 會檢查每個列出的操作都能送到處理程式，也都寫在說明裡。
- `WorkspaceCommandChannel` 讓工作區的寫入依序進行，並透過同一使用者的私有通道把請求轉給作用中的 App 視窗。App 為每個請求開一個 main actor 任務，等待 Touch ID 的請求不會擋住其他請求。App 取走 `ID.request` 即代表接手，並寫入 `ID.accepted`；客戶端會撤回超過 `pickupTimeout` 仍未被接手的請求（不會執行），已接手但超過 `answerTimeout` 仍未回覆的則回報為仍在執行。等待使用者確認的指令會在等待後重新讀取目標，不會蓋掉較新的修改。
- `BoundedCommand` 讓外部工具在自己的程序群組執行，stdin 接 `/dev/null`，讀取時就套用輸出上限，並有期限；取消時會停止整個群組。
- `gloamux files` 和 `gloamux ssh` 以 `CommandSignIn` 呼叫 `ConnectionService`，不建立分頁；操作結束或失敗時關閉自己開啟的連線，提供的密碼和一次性主機指紋只留在記憶體。
- `gloamux xserver` 在 CLI 程序中透過 `XQuartz` 檢查並啟動 XQuartz，因為 XQuartz 屬於這台 Mac 而不是某個工作區。
- 較新的 CLI 正在編輯某個工作區時，請對同一個工作區使用目前打包的 App。

## X11

- X11 設定只套用在 SSH shell。
- `SSHX11Configuration` 從 `DISPLAY` 或 launchd 取得本機顯示，並用 XQuartz 的 `xauth` 讀取其 MIT-MAGIC-COOKIE-1 授權。
- Gloamux 在 SSH 請求中送出隨機產生的替代值，在開啟本機連線前驗證 X11 設定，並在記憶體中替換回來。只允許本機 socket 或回送端點。
- 關閉 shell 會關閉它的 X11 通道。測試使用回送 SSH 伺服器和假的顯示，不需要 XQuartz 也能執行。

## 遠端桌面

- RDP 和 VNC 開在遠端桌面分頁。`RemoteDesktopPane` 繪製最新的畫面、縮放到窗格大小，並轉換鍵盤和指標事件。
- 打包腳本會建置 `Gloamux/RDP` 中鎖定版本的 Rust 專案，並簽署 `Contents/Helpers` 中的輔助程式。輔助程式為一個連線執行，透過私有管道與 Swift 交換登入資料、輸入和畫面。關閉分頁就會結束程序。
- 連線樹會打開精簡的編輯器，已存的桌面設定檔可以在 RDP 和 VNC 之間切換。憑證釘選只保留給同一個 RDP 端點。
- **RDP** 使用 IronRDP 進行搭配 NTLM 和 TLS 的 NLA。伺服器憑證必須通過系統驗證，或符合為該已存設定檔核可的 SHA-256 指紋。
  - RDP 預設跟著窗格大小。連線也可以改用固定解析度（`DesktopResolution` 預設值，最大 2560 × 1600）、要求 Retina（以 200% 桌面縮放送出兩倍像素），以及選擇畫質，由 `rdp.rs` 的 `quality()` 對應到連線類型和效能旗標。
  - 尚未實作 RDP 閘道，以及重新導向磁碟機、印表機、智慧卡、音訊和攝影機。要連到伺服器後方的桌面，支援的方式是 SSH 通道（**透過 SSH**）。
- **VNC** 支援 RFB 3.3、3.7 和 3.8，對 macOS（3.889）這類較新的伺服器以 3.8 回應。它會請求 ZRLE、CopyRect、原始矩形和伺服器調整大小的訊息，並依 ZRLE 的要求在整個連線中維持同一個 zlib 串流。
  - 登入方式有不驗證、傳統 VNC 密碼，或在輸入使用者名稱時使用 Apple Remote Desktop（安全類型 30）。類型 30 是 macOS 螢幕共享用於 Mac 帳號的方式：以 Diffie-Hellman 交換產生 AES-128 金鑰來加密帳號名稱和密碼。只有登入資訊會加密。
- 剪貼簿共用依連線設定；連線沒有設定時，使用 `desktop.share-clipboard` 預設值。

### 瀏覽器面板

- `BrowserPanel`（`WebPage.swift`）屬於視窗的 `WorkspaceModel`，最多保留 20 個 `WebPageSession` 網頁，以分頁顯示在面板標題列。它們共用一個 `WKWebsiteDataStore.nonPersistent()` 和一個 `WebCertificates`，所以 Cookie 和信任的憑證保留到 Gloamux 結束。WebKit 會在資料存在期間一直保留回答過的 HTTP 登入，`removeData(ofTypes:)` 清不掉它，所以 `clearWebsiteData()` 會把每一頁換到新的資料（`WebPageSession.restart(with:)`）並重新開啟；`BrowserPanelPageTests` 檢查網站會再要求登入。隱藏面板時會呼叫 `pauseMedia()`。網頁第一次載入時才建立 `WKWebView`（`GloamuxWebView`）。
- `WebAddress.url(from:)` 用和 Safari 相同的方式補齊輸入的位址（IP 位址、`localhost` 和沒有點的名稱用 `http`），並拒絕其他通訊協定和網址裡的帳號密碼。網址欄和 `gloamux web` 使用的 `WebAddress.destination(from:)` 會把一般字詞、沒有點的單一字詞和其他不是網址的文字改成 Google 搜尋。
- User-Agent 會加上 `/Applications/Safari.app` 的 `Version/… Safari/…`，因為 Google 等網站沒有它時會送出簡易版網頁。
- 沒通過 `SecTrustEvaluateWithError` 的憑證會連同指紋顯示（`WebCertificateCard`），且只在那個端點信任。登入要求、JavaScript 對話框、上傳、下載和當掉的網頁內容程序在 delegate extension 處理。
- `WebPageViews.swift` 繪製面板（`WorkspaceSidebar.browser`）：網頁分頁、工具列和網頁。右側每個面板（瀏覽器、檔案、常用指令和配色）共用一個寬度 `filesSidebarWidth`（`SidebarWidth.right`），在每種版面都能從 240 點拖曳到只留給視窗其他部分 340 點。`gloamux web`（`WorkspaceCommandWeb.swift`）控制面板和它的網頁，需要 App 正在執行。
- `WebPageTests` 涵蓋位址、網頁、下載、縮放、憑證和 CLI。`BrowserPanelPageTests` 從本機伺服器載入網頁，檢查標題、上一頁下一頁和 User-Agent。

## 更新

- 選單和設定看到的是 `App` 模組裡的 `AppUpdates`：**Gloamux › 檢查更新**（`CheckForUpdatesCommand`）和 **設定 › 一般** 的 **自動檢查更新**。
- 只有 `GloamuxApp` 執行檔連結 [Sparkle](https://sparkle-project.org) 2。`SparkleUpdates` 在 `applicationDidFinishLaunching` 啟動 `SPUStandardUpdaterController`，這時命令列的路徑都已結束，而且只在 bundle 的 Info.plist 有 `SUFeedURL` 和 `SUPublicEDKey` 時才啟動。`swift run`、測試和 CLI 都不會檢查更新，選單項目和設定也會隱藏。
- `package-app.sh` 把 `Sparkle.framework` 複製到 `Contents/Frameworks`，不含 XPC 服務（Gloamux 沒有沙盒），加入 `@executable_path/../Frameworks` rpath，先簽 Sparkle 的輔助程式再簽 App，並寫入更新清單網址（`releases/latest/download/appcast.xml`）和公鑰。
- `appcast.sh` 用登入鑰匙圈裡的私鑰（帳號 `Gloamux`）簽署 DMG，並把簽章寫入更新清單。`release.sh publish` 會把它和 DMG 一起上傳。目前以 EdDSA 驗證更新封裝，更新清單與版本說明透過 HTTPS 取得。Sparkle 的更新清單簽署選項維持未設定。見 [Sparkle 設定文件](https://sparkle-project.org/documentation/customization/)。

在本機測試更新：

1. 用 `GLOAMUX_FEED_URL=http://127.0.0.1:8765/appcast.xml` 打包一個版本，再打包一個 build 號碼較大的版本。
2. 把較新的 DMG 和它的更新清單（由 `appcast.sh` 產生）放進一個資料夾，用 `python3 -m http.server 8765 --bind 127.0.0.1` 提供。
3. 打開較舊的那份，選 **檢查更新**。

## 效能

### 基準測試

`gloamux benchmark [--megabytes N] [--columns N] [--rows N] [--json]` 以每次 4 KB 的讀取，把純文字、彩色記錄、中日韓文字、全螢幕重繪和 OSC 133 提示字元送進 `TerminalScreen`，量測用 `TerminalLineRenderer` 完整重繪可見行的時間，以及一次按鍵回顯的時間。請從打包好的正式版 App 執行。

在 Apple 晶片的 Mac 上以 160×48、用打包好的版本執行（2026 年 11 月 26 日，中日韓文字加速之後；11 月 22 日的數字是中日韓文字 20 MB/s、全螢幕重繪 25 MB/s）：

| 工作負載 | 結果 |
|---|---|
| 純文字 | 約 117 MB/s |
| 彩色記錄 | 35 MB/s |
| 中日韓文字 | 68 MB/s |
| 全螢幕重繪 | 50 MB/s |
| OSC 133 提示字元 | 10 MB/s |
| 完整重繪 | 0.4–1.0 毫秒 |
| 按鍵回顯 | 約 0.01 毫秒 |

### 壓力測試

`python3 Gloamux/scripts/stress-test.py` 在高負載下透過 `gloamux` 和 `gloamux mcp` 操作打包好的 App，並記錄 Mac 付出的成本。

- 只需要 Python 3 標準函式庫和 macOS 的 OpenSSH，所以代理可以在 `package-app.sh` 之後無人看管地執行。
- 它會建立拋棄式工作區，以及只在 127.0.0.1 上、只接受為這次執行產生的金鑰的拋棄式 `sshd`。它不會打開你的工作區、不會用密碼登入，也不會連到其他主機。只在那個工作區中，它會為測試連線開啟 AI 代理存取。
- 選項：`--quick` 執行約五分之一的負載，`--no-app` 略過需要 App 的階段，`--app PATH` 執行另一份副本（例如改名的測試副本），`--out DIR` 選擇報告資料夾，`--keep` 保留拋棄式檔案。
- App 和它的 `gloamux` 會寫入 App 自己的偏好設定網域。若是已安裝 App 的識別碼 `local.gloamux.desktop`，這次執行會略過設定匯入，讓你的設定維持原樣。
- 它會寫出 `report.md`、`report.json`，以及每秒取樣的 `samples.csv`。所有階段都通過時結束狀態為 0，有任何失敗為 1，設定問題為 2。

涵蓋範圍：

- App 關閉和開啟時的連線目錄
- 設定匯出和匯入，包括必須被拒絕的損壞備份
- 大型檔案的 SFTP 和 SCP 傳輸，以及遞迴資料夾傳輸
- 依序和平行的 SSH 連線反覆建立
- `gloamux benchmark`
- 20 個本機分頁和 10 個 SSH 分頁，各印出一百萬行
- 以 TCP 回聲伺服器檢查的連接埠轉發
- 每個 MCP 工具，包括代理只能看到允許的連線，以及提議的指令會等待審閱
- 寬字元文字和內嵌圖片：在本機分頁中印出 CJK 文字行和 kitty graphics 圖片
- 瀏覽器面板，對本機網頁伺服器：超過 20 頁上限的頁面、反覆導覽、被「清除網站資料」移除的 cookie，以及關閉頁面後剩下的 WebKit 程序和記憶體

每個階段都有通過或失敗、自己的數據、App 的 CPU 時間和記憶體峰值，以及它執行的 CLI 程序所用的 CPU。記憶體數據是活動監視器顯示的實體記憶體用量；RSS 也有記錄，但記憶體釋放後仍會維持在高點。

### 功能檢查

`python3 Gloamux/scripts/feature-check.py` 對打包好的 App 檢查每一組 `gloamux` 指令的一項實際操作，使用和壓力測試相同的拋棄式工作區、`sshd` 和本機網頁伺服器。

- 不需要 App：版本、自我測試、說明、自動完成、連線、主機、透過 SFTP 和 SCP 的檔案、從標準輸入讀取的 `sftp` 和 `ssh`、轉發、快速指令、觸發器、Runbook、歷史紀錄、外觀、版面、設定、設定備份、代理、密碼庫、X 伺服器、錄製、視窗錄影清單和效能測試。
- 需要 App：分頁（執行、讀取、開關、檢視、分割、視窗、重新連線、錄製）、視窗錄影狀態（開始錄影需要螢幕錄製權限，要由人授予）、在分頁中執行快速指令和 Runbook、執行中的轉發、瀏覽器面板（導覽、縮放、信任和拒絕不受信任的 HTTPS 憑證、清除網站資料、關閉頁面）、`gloamux mcp`、下拉視窗，以及鎖定工作區。
- 選項：`--app PATH`、`--no-app`、`--out DIR` 和 `--keep`，和壓力測試相同。用改名的副本時，它也會變更並重設一項設定，以及匯入備份；用已安裝 App 的識別碼時會略過這些。
- 它不執行需要人操作的步驟：已存密碼的 Touch ID、解鎖工作區，以及核准代理提議的指令。它從不執行 `runbooks delete`、`recordings remove` 或 `web external`，這些會把檔案移到垃圾桶或打開你的瀏覽器。
- 它會寫出 `report.md` 和 `report.json`。所有檢查都通過時結束狀態為 0，有任何失敗為 1，設定問題為 2。

在 Apple 晶片的 Mac（10 核心，2026 年 11 月 22 日）上完整執行的結果：

- App 閒置時 93 MB，30 個忙碌分頁時峰值約 1 GB。一個 160 欄、回捲滿 5,000 行的分頁約佔 33 MB。
- 所有分頁合計每秒印出約 560,000 行。
- AI 代理和 CLI 對執行中 App 的請求分別需要 4 毫秒和 13 毫秒。
- SFTP 上傳約 1 GB/s、下載 730 MB/s，轉發的連接埠約 800 MB/s。
- 分頁關閉後，堆積中仍有 36 MB 在使用。實體記憶體用量停在約 390 MB，因為配置器會保留釋放的頁面以便重用。SwiftUI 會保留上次繪製的值直到再次繪製，所以關閉的分頁會在視窗下次更新時才釋放。

### 流量控制

- **SSH shell。** 未讀的區塊超過 64 個時，SSH shell 會停止讀取通道，SSH 視窗隨之填滿，伺服器就會等待。
- **本機 shell。** 輸出依序、分批經過 `TerminalOutputPump` 到達畫面。等待中的資料超過 1 MB 時，PTY 讀取來源會暫停，直到畫面跟上。

### 未來工作

- **Metal。** 建立所有可見行不到 1 毫秒，之後 AppKit 只繪製有變動的行，所以 Metal 繪製器目前不會帶來使用者感受得到的差異。瓶頸在解析器。連續的可列印 ASCII 一次寫入一整列，UTF-8 解碼不再為每個字元建立 `String` 或陣列，CSI 參數也逐位元組解析。U+20000 以下的字元寬度改為查表，這張表在終端第一次顯示 U+0300 以上的字元時建立；連續的完整非 ASCII 字元（中日韓文字、框線字元、表情符號）也像 ASCII 一樣一次寫入一整列。遇到組合字元、控制位元組，或無效、被一次讀取的結尾切斷的 UTF-8 序列，就改走逐字元的路徑。`WideTextTests` 檢查兩條路徑得到相同的畫面。現在最慢的是 SGR 與 OSC 133 的解析。
- **內嵌圖片。** iTerm2 的 `OSC 1337 File=`（含 `MultipartFile=`）與 sixel 已實作於 `Sources/terminal/InlineImages.swift`：畫面為每張圖片記下其最上一行的絕對行號與涵蓋的儲存格，文字畫面再把圖片畫在這些儲存格上。每個檔案上限 10 MB、4096×4096 像素，sixel 每邊上限 4096 像素，每個分頁最多保留 64 張、以解碼後像素計 64 MB；圖片在其所在行離開回捲、清除畫面或回捲，或程式離開替代畫面時丟棄。沒有標記 `inline=1` 的檔案（下載）會被忽略，遠端主機送來的內容絕不能讀取本機檔案。
- **kitty 圖片。** `Sources/terminal/KittyGraphics.swift` 解碼 `ESC _ G` 指令，`TerminalScreen` 保存並放置圖片，和另外兩種協定一樣以 `TerminalImage` 表示。支援：傳送（`a=t`）、傳送並顯示（`a=T`）、以放置 ID 顯示（`a=p`）、查詢（`a=q`），以及刪除（`a=d`，搭配 `a`、`i`、`n`、`c`、`p`、`x`、`y`，大小寫皆可）；格式 `f=24`、`f=32`、`f=100`（PNG）；zlib 壓縮（`o=z`）；分段傳送（`m=1`）；來源矩形（`x`、`y`、`w`、`h`）；儲存格大小（`c`、`r`）；`C=1`；以及 `q=1` 與 `q=2`。只接受直接傳送（`t=d`）；指定檔案、暫存檔或共用記憶體的傳送會以 `EINVAL` 拒絕，所以遠端主機送來的內容絕不能讀取本機檔案。不支援動畫、Unicode 佔位字元（`U=1`）、z-index，以及儲存格內的像素位移。保存的圖片同樣計入 64 張與 64 MB 的上限，從最舊的開始丟棄。一個指令的上限是 10 MB 檔案的 base64 長度。關閉 **顯示內嵌圖片** 時，kitty 指令不會得到回應。
- **像素大小。** `CSI 14 t`、`CSI 16 t`、`CSI 18 t` 回報文字區域與一個儲存格的像素大小（一點一像素），以及文字區域的儲存格數。本機 shell 會在 PTY 設定 `ws_xpixel` 與 `ws_ypixel`，SSH 連線會在視窗大小變更要求中送出像素大小。只換字型、列數與欄數不變時，也會重新送出像素大小。

## 測試

在儲存庫根目錄執行：

```sh
swift test --package-path Gloamux
cargo test --offline --manifest-path Gloamux/RDP/Cargo.toml
```

| 測試 | 涵蓋 |
|---|---|
| `ReflowTests` | 調整大小時的重新換行、在任意位元組切分輸出，以及 CSI 參數解析。 |
| `TerminalModesTests` | 滑鼠和焦點回報、游標形狀、OSC 52、回捲大小和舊式編碼。 |
| `TerminalViewBehaviorTests` | 在真實視窗中的輸入法組字、搜尋、滑鼠回報和游標。 |
| `TerminalFeaturesTests` | 遮蔽、asciicast 檔、runbook 解析、高風險指令、環境、容器指令列、探索解析器、主機金鑰紀錄、指令面板搜尋、URL scheme、連線檢查和基準測試工作負載。 |
| `RemoteKindsTests` | 已存的桌面設定檔會開啟專用分頁並保留其協定。 |
| `LocalLocaleTests` | 本機 shell 語系選擇、保留既有語系，以及透過真實 PTY 顯示非 ASCII 檔名。 |
| SSH、轉發和 SFTP 測試 | 回送測試環境和 macOS 的 `sftp-server`：目的地和跳板主機各自的主機金鑰核可、傳輸往返、傳輸中斷後重連，以及獨立的本機終端。 |
| Rust 輔助程式（`cargo test`） | ZRLE 區塊與共用 zlib 串流、CopyRect、矩形邊界、版本與安全協商、VNC DES 回應，以及 Apple 登入區塊。 |

本機協定測試環境也驗證過 RDP 憑證核可、CredSSP 登入、像素與鍵盤和指標事件，以及透過 RFB 的 VNC 畫面緩衝和輸入。

選用的測試輸入：

- **Xshell 格式。** 相容性測試會從 `XSHELL_DIR` 指定的資料夾讀取。Xshell 安裝和測試檔是外部輸入。
- **遠端 SSH 主機。** 把 `GLOAMUX_REMOTE_HOSTS` 設為以逗號分隔的 `user@host[:port]` 清單，`GLOAMUX_REMOTE_KEYS` 設為放有測試私鑰和含已驗證伺服器金鑰之 `known_hosts` 檔的資料夾，再執行 `swift test --package-path Gloamux --filter RemoteHostTests`。第二個目標也會以第一個作為跳板來測試。`GLOAMUX_REMOTE_LOGIN_ONLY` 列出受限 shell 只能檢查是否成功登入的主機。

沒有這些輸入時，相關測試會略過。

2026 年 11 月 24 日依未提交的架構修改驗證，Swift 469 項中 461 通過、8 跳過、0 失敗，Rust 18 項通過，封裝 App 自檢 9/9，完整壓力測試 14/14，分批功能腳本 81/81。範圍與待辦見[驗證紀錄](VERIFICATION.md)。

## 第三方授權聲明

| 元件 | 授權聲明 |
|---|---|
| [IronRDP](https://github.com/Devolutions/IronRDP)（遠端桌面引擎） | [MIT](../../Gloamux/RDP/licenses/ironrdp-MIT.txt) 和 [Apache 2.0](../../Gloamux/RDP/licenses/ironrdp-Apache-2.0.txt)，隨 App 發布。[Cargo.lock](../../Gloamux/RDP/Cargo.lock) 記錄 Rust 相依套件。 |
| [Sparkle](https://github.com/sparkle-project/Sparkle)（App 內更新） | MIT 類型授權，以 `Sparkle-LICENSE.txt` 隨 App 發布。 |
| [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) Symbols Nerd Font Mono v3.5.1（終端提示圖示） | [MIT](../../Gloamux/Sources/app/Resources/TerminalFonts/NerdFontsSymbols-LICENSE.txt)，連同[來源紀錄](../../Gloamux/Sources/app/Resources/TerminalFonts/PROVENANCE.txt)放在 App 的資源套件中。其收錄的各圖示集保留各自的授權，列於 Nerd Fonts 的[授權稽核](https://github.com/ryanoasis/nerd-fonts/blob/v3.5.1/license-audit.md)。 |
| Visual Studio Code 主題顏色 | [MIT 聲明](../../Gloamux/Sources/app/Resources/vscode-themes-license.txt)。 |
| Marketplace 主題顏色 | MIT 授權主題的[授權聲明](../../Gloamux/Sources/app/Resources/vscode-community-themes-licenses.txt)。 |
| Swift 套件，包含 [BigInt](https://github.com/attaswift/BigInt)（MIT，用於「相容」SSH 金鑰交換） | 解析結果記錄在 [Package.resolved](../../Gloamux/Package.resolved)。 |

主題與匯入：

- 要變更內附的 Visual Studio Code 主題，請編輯 [build-vscode-themes.py](../../Gloamux/scripts/build-vscode-themes.py) 中的選擇，並以本機的 Visual Studio Code App 和下載的 `.vsix` 套件執行。
- Linux 發行版配色定義在 `ThemeGallery.swift`；[配色清單](THEME-INVENTORY.md)記錄了它們的來源。工作區版面和主題選擇器都是原生實作。
- Xshell 匯入支援相容設定檔中的部分欄位。
- MobaXterm 讀取器（`SessionImports.swift` 中的 `MobaXtermImport`）依照 MobaXterm 連線匯出的欄位位置讀取，Mobatek 並未公開這份格式。它讀取 SSH（類型 0）、SFTP（類型 7）和序列埠（類型 8）連線，也能容忍舊版較短的欄位清單。
- 匯入檔有標記或內容有效時以 UTF-16 或 UTF-8 解碼，否則依序嘗試 Big5（CP950）、GB 18030 和 Windows-1252。
- `SessionExport` 寫出 `.gloamuxsessions` JSON（`SessionsFile`）、CSV 和 OpenSSH 設定。匯出不含密碼或私鑰內容，家目錄下的金鑰路徑會改寫成 `~/…`。OpenSSH 輸出限於該格式能表示的 SSH 設定。
