# Gloamux 開發指南

[English](DEVELOPMENT.md) · [繁體中文](DEVELOPMENT.zh-TW.md)

## 原始碼結構

Swift 套件位於 [Gloamux](Gloamux)。`GloamuxApp` 執行檔會啟動原生 macOS 介面，也同時是 `gloamux` 命令列。`GloamuxShared` 放著每個模組都要實作的功能約定。`Sources/app` 管理連線樹、視窗、分頁、偏好設定和憑證密碼庫。介面文字放在 `Sources/app/Resources/<語言>.lproj/Localizable.strings`，以英文原文為鍵。目錄有 `en`、`zh-Hant`、`zh-Hans`、`ja` 和 `es`。新的 `T("…")` 字串要加進每個目錄，`TerminalInputTests` 會檢查各目錄的鍵是否一致。語言選擇存成 App 的 `AppleLanguages` 偏好設定，與系統設定中每個 App 的語言是同一個值；`package-app.sh` 在 `CFBundleLocalizations` 中宣告內附的語言。`terminal` 和 `LocalPTY` target 處理終端狀態和本機登入 shell。`ssh`、`network`（模組名為 `GloamuxNetwork`，以免遮住 `AppIntents` 等系統模組使用的 Apple `Network` 框架）和 `file-transfer` target 實作遠端工作階段和 SFTP。`Sources/intents`（模組 `ShellIntents`）放捷徑用的 App Intents，不依賴套件中其他任何部分。

打包腳本預設會建置最佳化的正式版 App 套件 `build/Gloamux.app`。除錯版解析和繪製終端輸出會慢好幾倍，所以判斷反應速度請用打包好的 App。若要用不同的建置快取或輸出位置，把它們當作 `package-app.sh` 的第一和第二個參數傳入。

介面說明放在 `InfoButton`（「!」彈出視窗，是 AppKit 的 `NSPopover`，打開時不會重繪周圍的 SwiftUI 畫面）後面，不要寫成說明段落。標籤要短；翻譯較長時，用 `.fixedSize(horizontal: false, vertical: true)` 讓標籤換行，不要截斷。

編輯繁體中文介面和 `.zh-TW.md` 文件時使用 [Humanizer-zh](https://github.com/op7418/Humanizer-zh/blob/main/SKILL.md)。同一個動作用同一個詞，並保留原本的條件、格式佔位符和指令範例。每份英文文件都有一份繁體中文版，兩者要一起更新。

SwiftPM 目前會警告 `swift-nio-ssh` 和 `swift-nio-ssl` 的套件身分衝突。Gloamux 使用[內附的 swift-nio-ssh](Gloamux/Vendor/swift-nio-ssh/VENDORED.md) 處理 agent 和 X11 轉發，使用[內附的 swift-nio-ssl](Gloamux/Vendor/swift-nio-ssl/VENDORED.md) 處理 FTPS 的 TLS 工作階段重用。Citadel 和 swift-nio-extras 透過上游網址宣告了相同的套件身分。SwiftPM 這次建置會使用本機副本，所以這個身分警告是預期中的，在目前的工具鏈下可以忽略。升級 SwiftPM 時請重新檢查解析結果，因為未來版本可能會把這個衝突當成錯誤。

## 本機資料

Gloamux 的工作檔案放在 `~/Library/Application Support/Gloamux`。所有地方都用 Gloamux 這個名稱：GitHub 儲存庫、App（`Gloamux.app`，bundle ID `local.gloamux.desktop`）、資料夾、`gloamux` 指令、`gloamux://` 連結和介面文字。App 套件也把 `gloam` 連到同一個執行檔作為簡短指令名稱；`main.swift` 把兩個名稱都當成 CLI。Gloamux 曾名為 Termac，更早叫 MShell：除非傳入 `--workspace`，否則在 Gloamux 資料夾還不存在時，`LegacyName.migrate` 會把最近一個舊資料夾（先找 `Termac`，再找 `MShell`）搬過來；`local.gloamux.desktop` 沒有設定時，會複製最近一個舊設定（先找 `local.termac.desktop`，再找 `local.mshell.desktop`）。舊 App 正在執行時不會做任何事。使用舊副檔名和格式名稱的匯出檔仍可匯入。連線目錄儲存連線設定和金鑰檔路徑。主機指紋、已存登入資訊（`saved-sign-ins.json`）和可選的加密密碼庫各有獨立的資料檔。快速指令以純文字存在 `quick-commands.json`，請不要把機密放進已存指令。做介面檢查時，對 App 執行檔傳入 `--workspace /path/to/test-workspace`，把這些檔案和平常的工作區隔開。

工具列的版面選單和 `gloamux layout` 指令都會設定 `layout.json` 偏好。選單會立即套用版面；App 開著時 CLI 的變更也一樣，否則下次啟動才套用。`layout set` 接受 `default`、`classic` 和 `workbench`，分別存成 `macos`、`terminal` 和 `transfer`；`xshell`、`mobaxterm` 等舊名稱仍然可用。在 layout 指令最後加上 `--workspace PATH` 可以指定隔離的工作區。經典和工作台的外框程式碼在 `ClassicLayouts.swift`，其模型支援（網址列、輸入列、跟隨資料夾、主機監控）在 `ClassicWorkspace.swift`。

使用者拖曳排列後，`sessions.json` 的每個項目可能帶有 `order`。`SessionTreeStore.children(of:)` 先列出有排序的項目，再列出沒排序的項目（資料夾優先、依名稱），所以舊目錄能保持原本的順序。`drop(_:on:_:)` 套用拖曳，即使連線樹依名稱排序，也會依自訂順序重新編號該資料夾。目錄中可選的 `sorting` 欄位（`nameAscending` 或 `nameDescending`；沒有就是自訂）決定 `children(of:)` 如何列出項目。檔案傳輸都經過 `TransferQueue`，由 `WorkspaceModel.transfers` 在檔案側欄（`RemoteFileSidebar`，本機終端時顯示 `LocalTreeState`）、雙欄的 `FileTransferView` 和所有版面之間共用。預設版面在 `workspaceMode` 為 `.files` 時於主視窗顯示 `FileTransferView`，並跟著選取的分頁。經典和工作台版面則在附伺服器選單的 `FileTransferWindow` 中顯示它。它在分頁的 SFTP 通道上一次執行一個項目。上傳會先寫入暫存的 `.name.gloamux-….partial` 檔，再改名就位。下載會在目的地旁寫入隱藏的暫存檔。`SFTPTransfer` 同時保持 16 個 32 KiB 的讀取或寫入，並在工作取消時停止。已存的轉發規則與連線一起存在 `sessions.json`。本機和動態轉發在這台 Mac 的回送介面上監聽。反向轉發會請伺服器在它的回送介面上監聽。可以輸入固定的監聽連接埠，或留空讓系統自動分配。

密碼庫把 Touch ID 解鎖用的資料以 Secure Enclave 保護放在記憶體中。新的 App 程序需要主密碼。Gloamux 的 Secure Enclave SSH 金鑰以 `ssh-key-secure-enclave` 存在資料夾中（見 `AppSSHKey`），內容是只有這台 Mac 能用的加密表示。新金鑰簽章時不需要 Touch ID。需要 Touch ID 的舊金鑰會在每次啟動、載入金鑰時（SSH 交握之前）詢問一次，所以連線事件迴圈上的簽章不會等待使用者。能登入的密碼存到哪裡，取決於有沒有密碼庫。沒有密碼庫時，能登入的密碼和金鑰密語由 `CredentialVault.rememberWorking` 存進 `DeviceSecrets`：AES-GCM 項目，以項目 ID 為關聯資料，金鑰由不需要 Touch ID 的 Secure Enclave 金鑰協商重建。重新開機後不需主密碼也能用。密語使用 `passphrase:<金鑰路徑>` 作為項目 ID。沒有 Secure Enclave 時，機密照舊存進主密碼密碼庫。建立密碼庫後 `DeviceSecrets` 仍然保留，所以密碼庫鎖定不會讓連線無法連上。密碼庫解鎖時，`connect` 會略過每個連線的 `confirmsEachConnection` 檢查；鎖定時則會執行。當需要的機密只存在已鎖定的密碼庫（`CredentialVault.lockedVaultIDs`），且本次啟動已設定好 Touch ID 時，`readWithTouchID` 會在不解鎖密碼庫的情況下把那些項目讀進 `sessionPasswords`，這次提示也代替了每個連線的檢查。測試用 `enableTouchIDForTesting` 取代提示。新連線預設開啟這項檢查。**加入密碼庫**（`CredentialVault.addToVault`）會在密碼登入前就先儲存。`SavedSignInsView` 列出兩個存放處（`CredentialVault.Place`），並在 `WorkspaceModel.authorizeSavedSignIns` 之後顯示、複製或刪除其中一份。移除金鑰會呼叫 `forgetRemembered`，刪除這台 Mac 上的副本，密碼庫解鎖時也會刪除密碼庫中的副本。開啟 `confirmsEachConnection` 的連線在使用已存機密前，會呼叫 `WorkspaceModel.confirmOwner`（Touch ID 或 Mac 密碼）。

## Shell 整合與終端工具

`TerminalScreen`（在 `Sources/terminal`）把 OSC 133 標記記錄成帶絕對行號的 `CommandMark`（`trimmedLines` 加上回捲索引，讓標記在修剪後仍然有效），並發出 `TerminalEvent.commandFinished`。OSC 8 連結放進連結表，每個 `CellStyle` 保留一個不會被 SGR 0 清除的連結索引。OSC 7 設定 `workingDirectory`。本機 zsh 透過指向使用者暫存資料夾中產生的 `.zshenv` 的 `ZDOTDIR` 載入標記（`ShellIntegration.zshDirectory()`）；它會還原使用者的 `ZDOTDIR`，並在第一個提示字元時把自己的 hook 加在使用者的 hook 之後。其他 shell 和 SSH 工作階段則取得單行的 `ShellIntegration.hook`，依要求輸入，或在 **設定 › 終端** 如此設定時自動為 SSH 輸入。本機程序透過 `LocalPTY.c` 中的 `gloamux_spawn_command` 啟動，它接受參數陣列和額外的環境變數；容器工作階段透過登入 shell 執行 `docker`、`kubectl` 或 `aws ssm start-session`（`LocalLaunch.command`）。

每個終端的輸出都經過 `WorkspaceModel.terminalReceived`，再送給畫面、錄影器和指令觀察者。在看不到的分頁中，執行時間至少達到通知門檻的指令完成時，會在該分頁設定 `attention`，並在 Gloamux 以 App 套件執行時送出通知。操作手冊（`Runbooks.swift`，工作區資料夾中 `runbooks/` 的 Markdown）一次以括號貼上送出一個區塊，等待它的 `commandFinished`，遇到第一個失敗就停止，並把結果存在 `runbooks/.results/`。錄影（`TerminalRecording.swift`）只保留輸出，儲存時經過 `SecretRedaction`（也能找出被切成多段的機密），並以 0600 權限把 asciicast v2 檔寫到 `recordings/`。

環境標籤存在 `SessionTreeNode.environment`；連線會從資料夾繼承（`effectiveEnvironment`）。在 **設定 › 安全** 中選擇的環境裡，`typeTerminal` 會攔住符合 `RiskyCommands.patterns` 的那一行，直到窗格的警示被回應。shell 有回報 OSC 133 B 標記時，這一行取自標記之後的畫面，否則取自輸入的內容。

選單列項目、指令面板（`CommandPalette.swift`）、Spotlight（`SpotlightIndex`，只有名稱和位址）、`gloamux://open?id=` 和 `gloamux://new-terminal` 連結，以及捷徑動作，都呼叫同一組 `WorkspaceModel` 操作。`package-app.sh` 會對 SwiftPM 為 `ShellIntents` 產生的常數值執行 `appintentsmetadataprocessor`，寫出 `Metadata.appintents`；少了它 App 仍能運作，但捷徑裡不會列出 Gloamux 的動作。連線能否連上的圓點來自對每個可見已存主機 SSH 連接埠的非阻塞 TCP 連線，一次最多六個，每 90 秒一次；透過代理、跳板或容器的連線不會檢查。主機金鑰的決定會附加到 `host-key-history.json`（最多 2,000 筆）。

遠端快速查看會把一個最多 100 MB 的檔案複製到私有暫存資料夾，並在下一次預覽和結束時刪除。

## 終端畫面

`TerminalDisplay` 把回捲和畫面以帶屬性的行繪製在 `NSTextView`（`TerminalTextView`）中，只替換有變動的行。預設背景上的儲存格不帶背景色，所以畫面本身的顏色（可以在 `TerminalBackdrop` 這個視窗後方的 `NSVisualEffectView` 上半透明）會透出來。游標是蓋在儲存格上的獨立 `TerminalCursorView`：改變形狀、焦點或閃爍都不會重繪任何一行，閃爍是 Core Animation 的關鍵影格動畫。輸入法組字保留在畫面中並繪製在游標上；它從不進入文字儲存，組字期間每個按鍵都交給輸入法。搜尋列搜尋文字儲存，並用 layout manager 的暫時屬性標示符合項目；搜尋列開著時，新的輸出會在 0.2 秒後重新搜尋。

`TerminalScreen` 追蹤程式設定的滑鼠模式（1000、1002、1003，以及 1006 的 SGR 座標）、焦點回報（1004）、DECSCUSR 游標形狀和 OSC 52 剪貼簿寫入；`terminalReceived` 只在 **設定 › 終端** 允許時才套用剪貼簿寫入。其他編碼的工作階段會在解析前由 `TerminalDecoder` 轉成 UTF-8，輸入則在 `enqueueTerminalInput` 中轉回去；編碼存在連線上（`SavedConnection.encoding`）。終端設定使用 `TerminalPreferences` 中的 `Gloamux.terminal.*` 鍵。記錄檔（`TerminalLogs`）以 0600 權限寫到工作區資料夾的 `logs/`，並逐行以 `SecretRedaction` 遮蔽。

## 效能

`gloamux benchmark [--megabytes N] [--columns N] [--rows N] [--json]` 以每次 4 KB 的讀取，把純文字、彩色記錄、中日韓文字、全螢幕重繪和 OSC 133 提示字元送進 `TerminalScreen`，量測用 `TerminalLineRenderer` 完整重繪可見行的時間，以及一次按鍵回顯的時間。請從打包好的正式版 App 執行。在 Apple 晶片的 Mac 上以 160×48 執行（2026 年 11 月 22 日）：純文字約 100 MB/s、彩色記錄 36 MB/s、中日韓文字 20 MB/s、全螢幕重繪 25 MB/s、OSC 133 提示字元 10 MB/s；完整重繪需 0.4–0.7 毫秒；按鍵回顯約 0.01 毫秒。

**壓力測試。** `python3 Gloamux/scripts/stress-test.py` 在高負載下透過 `gloamux` 和 `gloamux mcp` 操作打包好的 App，並記錄 Mac 付出的成本。它只需要 Python 3 標準函式庫和 macOS 的 OpenSSH，所以 Codex 或 Claude Code 這類代理可以在 `Gloamux/scripts/package-app.sh` 之後無人看管地執行。它會建立一個拋棄式工作區，以及一個只在 127.0.0.1 上、只接受為這次執行產生的金鑰的拋棄式 `sshd`。它不會打開你的工作區、不會用密碼登入，也不會連到其他主機。它啟動的 App 是獨立的程序，結束時會關閉。只在那個工作區中，它會為測試連線開啟代理存取，就像使用者在 設定 › AI 代理 中做的一樣。

涵蓋以下範圍：

- App 關閉和開啟時的連線目錄
- 設定匯出和匯入，包括必須被拒絕的損壞備份
- 大型檔案的 SFTP 和 SCP 傳輸，以及遞迴資料夾傳輸
- 依序和平行的 SSH 連線反覆建立
- `gloamux benchmark`
- 20 個本機分頁和 10 個 SSH 分頁，各印出一百萬行
- 以 TCP 回聲伺服器檢查的連接埠轉發
- 每個 MCP 工具，包括代理只能看到允許的連線，以及提議的指令會等待審閱

每個階段都有通過或失敗、自己的數據、App 的 CPU 時間和記憶體峰值，以及它執行的 CLI 程序所用的 CPU。

選項：`--quick` 執行約五分之一的負載，`--no-app` 略過需要 App 的階段，`--out DIR` 選擇報告資料夾，`--keep` 保留拋棄式檔案。報告寫成 `report.md` 和 `report.json`，每秒的取樣在 `samples.csv`。所有階段都通過時結束狀態為 0，有任何失敗為 1，設定問題為 2。

記憶體數據是活動監視器顯示的實體記憶體用量。RSS 也有記錄，但記憶體釋放後仍會維持在高點。在 Apple 晶片的 Mac（10 核心，2026 年 11 月 22 日）上完整執行的結果：

- App 閒置時 93 MB，30 個忙碌分頁時峰值約 1 GB。一個 160 欄、回捲滿 5,000 行的分頁約佔 33 MB。
- 所有分頁合計每秒印出約 560,000 行。
- 代理和 CLI 對執行中 App 的請求分別需要 4 毫秒和 13 毫秒。
- SFTP 上傳約 1 GB/s、下載 730 MB/s，轉發的連接埠約 800 MB/s。
- 分頁關閉後，堆積中仍有 36 MB 在使用。實體記憶體用量停在約 390 MB，因為配置器會保留釋放的頁面以便重用。

SwiftUI 會保留上次繪製的值直到再次繪製，所以關閉的分頁會在視窗下次更新時才釋放。

終端輸出有流量控制：

- **SSH shell。** 未讀的區塊超過 64 個時，SSH shell 會停止讀取通道，SSH 視窗隨之填滿，伺服器就會等待。
- **本機 shell。** 輸出依序、分批經過 `TerminalOutputPump` 到達畫面。等待中的資料超過 1 MB 時，PTY 讀取來源會暫停，直到畫面跟上。

**Metal。** 建立所有可見行不到 1 毫秒，之後 AppKit 只繪製有變動的行，所以 Metal 繪製器目前不會帶來使用者感受得到的差異。瓶頸在解析器。連續的可列印 ASCII 現在一次寫入一整列，UTF-8 解碼不再為每個字元建立 `String`，CSI 參數也逐位元組解析。中日韓文字仍一次一個字元查詢寬度，所以在考慮字形圖集的 Metal 繪製器之前，下一個要加速的就是這裡。

**內嵌圖片。** iTerm2 的 `OSC 1337 File=` 和 kitty 圖形協定傳送的是 `NSImage` 和 `CGImage` 能直接解碼的 PNG 或原始像素，所以可以當作錨定在儲存格上的附件放進目前的文字畫面；sixel 則需要自己的解碼器。若要加入：先做 iTerm2，再做 kitty 的直接傳輸（不含檔案或共用記憶體模式），最後是 sixel；每張圖片編碼後上限 10 MB、4096×4096 像素，每個分頁最多保留 64 MB 的解碼圖片，在其所在行離開回捲時丟棄。來自遠端主機的圖片絕不能讀取本機檔案。

## 檔案協定與顯示連線

`RemoteFileSystem` 由瀏覽器、佇列、預覽和 CLI 共用。SSH 預設用 SFTP，子系統被拒絕後改用 SCP。設定檔可以強制使用其中一種。FTP 使用被動式資料連線。明確和隱含 FTPS 會加密兩條連線，在資料連線上重用控制連線的 TLS 工作階段，並使用系統信任或已驗證的憑證釘選。CLI 上傳會先把內容放在遠端的暫存名稱，再改名。OpenSSH SFTP 的取代使用伺服器宣告的 `posix-rename@openssh.com` 擴充。

`gloamux` 產品與 App 共用執行檔。`WorkspaceCommand` 分派管理操作。`gloamux xserver` 是例外：它在 CLI 程序中透過 `XQuartz` 檢查並啟動 XQuartz，因為 XQuartz 屬於這台 Mac 而不是某個工作區。`WorkspaceCommandChannel` 讓工作區的寫入依序進行，並透過同一使用者的私有通道把請求轉給作用中的 App 視窗。檔案指令開啟自己的已驗證傳輸，並把提供的密碼和一次性主機指紋只留在記憶體。較新的 CLI 正在編輯某個工作區時，請對同一個工作區使用目前打包的 App。

可選的 X11 設定只套用在 SSH shell。`SSHX11Configuration` 從 `DISPLAY` 或 launchd 取得本機顯示，並用 XQuartz 的 `xauth` 讀取其 MIT-MAGIC-COOKIE-1 授權。Gloamux 在 SSH 請求中送出隨機產生的替代值，在開啟本機連線前驗證 X11 設定，並在記憶體中替換回來。只允許本機 socket 或回送端點。關閉 shell 會關閉它的 X11 通道。測試使用回送 SSH 伺服器和假的顯示，不需要 XQuartz 也能執行。

RDP 和 VNC 會開在 Gloamux 的遠端桌面分頁。`RemoteDesktopPane` 繪製最新的畫面、縮放到窗格大小，並轉換鍵盤和指標事件。打包腳本會建置 `Gloamux/RDP` 中鎖定版本的 Rust 專案，並簽署 `Contents/Helpers` 中的輔助程式。打包 App 需要 Rust 1.94 以上和 Cargo。內附的輔助程式為一個連線執行，透過私有管道與 Swift 交換登入資料、輸入和畫面。關閉分頁就會結束程序。

預設版面的工具列可以在檔案傳輸和終端之間切換。新連線分頁可以從 SSH、RDP 或 VNC 開始。選擇桌面協定會取代該分頁中的終端連線表單。連線樹會打開精簡的編輯器，已存的桌面設定檔可以在 RDP 和 VNC 之間切換。憑證釘選只會保留給同一個 RDP 端點。

MultiExec（`WorkspaceModel.multiExec`）屬於單一視窗：`typeTerminal` 會把輸入送到該視窗中每個就緒的終端，包括移到獨立視窗的分頁，並略過唯讀終端和遠端桌面；每個目標仍會套用高風險指令檢查。通道視窗和 `gloamux forwards live-list` 共用 `WorkspaceModel.tunnelTabs`，它只列出已連線的 SSH 分頁，因為沒連線的分頁顯示的是新連線表單。

工作區視窗各有獨立的模型和分頁，共用已存的連線目錄、密碼庫、已知主機、快速指令、最近使用和操作手冊。新視窗以本機終端開始。第一個視窗擁有已存分頁的快照。關閉工作區會清理它的工作階段和工具視窗，關閉最後一個工作區會結束 App。

RDP 使用 IronRDP 進行搭配 NTLM 和 TLS 的 NLA。伺服器憑證必須通過系統驗證，或符合為該已存設定檔明確核可的 SHA-256 指紋。核可前請把顯示的指紋與伺服器的憑證比對。VNC 支援 RFB 3.3、3.7 和 3.8，對 macOS（3.889）這類較新的伺服器以 3.8 回應。它會請求 ZRLE、CopyRect 和原始矩形，以及伺服器調整大小的訊息，並依 ZRLE 的要求在整個連線中維持同一個 zlib 串流。登入方式有不驗證、傳統 VNC 密碼，或在輸入使用者名稱時使用 Apple Remote Desktop（安全類型 30）。類型 30 是 macOS 螢幕共享用於 Mac 帳號的方式：以 Diffie-Hellman 交換產生 AES-128 金鑰來加密帳號名稱和密碼。只有憑證會加密，其餘 VNC 流量不加密。RDP 預設跟著窗格大小。連線也可以改用固定解析度（`DesktopResolution` 預設值，最大 2560 × 1600）、要求 Retina（以 200% 桌面縮放送出兩倍像素），以及選擇畫質，由 `rdp.rs` 的 `quality()` 對應到連線類型和效能旗標。剪貼簿共用依連線設定；連線沒有設定時，使用 `desktop.share-clipboard` 預設值。RDP 閘道，以及重新導向磁碟機、印表機、智慧卡、音訊和攝影機，都不在目前的桌面實作範圍內；要連到伺服器後方的桌面，支援的方式是 SSH 通道（透過 SSH）。

## 測試

在儲存庫根目錄執行 `swift test --package-path Gloamux`。`ReflowTests` 涵蓋調整大小時的重新換行、在任意位元組切分輸出，以及 CSI 參數解析。`TerminalModesTests` 涵蓋滑鼠和焦點回報、游標形狀、OSC 52、回捲大小和舊式編碼。`TerminalViewBehaviorTests` 在真實視窗中涵蓋輸入法組字、搜尋、滑鼠回報和游標。`TerminalFeaturesTests` 涵蓋遮蔽、asciicast 檔、操作手冊解析、高風險指令、環境、容器指令列、探索解析器、主機金鑰紀錄、指令面板搜尋、URL scheme、連線檢查和基準測試工作負載。SSH 和轉發整合測試使用回送測試環境。SFTP 測試也使用 macOS 的 `sftp-server`。測試涵蓋目的地和跳板主機各自的主機金鑰核可、傳輸往返、傳輸中斷後重連，以及獨立的本機終端。

可選的格式相容性測試會從 `XSHELL_DIR` 指定的資料夾讀取。原始的 Xshell 安裝和測試檔是外部測試輸入。

`RemoteKindsTests` 檢查已存的桌面設定檔會開啟專用分頁並保留其協定。執行 `cargo test --offline --manifest-path Gloamux/RDP/Cargo.toml` 跑輔助程式的單元測試：ZRLE 區塊與共用 zlib 串流、CopyRect、矩形邊界、版本與安全協商、VNC DES 回應，以及 Apple 登入區塊。本機協定測試環境也驗證過 RDP 憑證核可、CredSSP 登入、像素與鍵盤和指標事件，以及透過 RFB 的 VNC 畫面緩衝和輸入。

做 SSH 互通性檢查時，把 `GLOAMUX_REMOTE_HOSTS` 設為以逗號分隔的 `user@host[:port]` 目標清單，`GLOAMUX_REMOTE_KEYS` 設為放有測試私鑰和含已驗證伺服器金鑰之 `known_hosts` 檔的資料夾。執行 `swift test --package-path Gloamux --filter RemoteHostTests`。第二個目標也會以第一個作為跳板來測試。把 `GLOAMUX_REMOTE_LOGIN_ONLY` 設為以逗號分隔的主機清單，這些主機的受限 shell 只能檢查是否成功登入。

## 第三方授權聲明

遠端桌面引擎使用 [IronRDP](https://github.com/Devolutions/IronRDP)，其 [MIT](Gloamux/RDP/licenses/ironrdp-MIT.txt) 和 [Apache 2.0](Gloamux/RDP/licenses/ironrdp-Apache-2.0.txt) 授權聲明隨 App 一起發布。[Cargo.lock](Gloamux/RDP/Cargo.lock) 記錄解析後的 Rust 相依套件。

SwiftPM 使用 [Package.resolved](Gloamux/Package.resolved) 解析相依套件。內附的 Visual Studio Code 主題顏色資料隨其 [MIT 聲明](Gloamux/Sources/app/Resources/vscode-themes-license.txt)發布。來自 MIT 授權 Marketplace 主題的工作台顏色隨其[授權聲明](Gloamux/Sources/app/Resources/vscode-community-themes-licenses.txt)發布。要變更內附主題，請編輯 [build-vscode-themes.py](Gloamux/scripts/build-vscode-themes.py) 中的選擇，並以本機的 Visual Studio Code App 和下載的 `.vsix` 套件執行。Linux 發行版配色定義在 `ThemeGallery.swift`；[THEME-INVENTORY.zh-TW.md](THEME-INVENTORY.zh-TW.md) 記錄了它們的來源。Gloamux 的工作區版面和主題選擇器都是原生實作。Xshell 連線匯入支援相容設定檔中的部分欄位。MobaXterm 讀取器（`SessionImports.swift` 中的 `MobaXtermImport`）依照 MobaXterm 連線匯出的欄位位置讀取，Mobatek 並未公開這份格式；它讀取 SSH（類型 0）和 SFTP（類型 7）連線，也能容忍舊版較短的欄位清單。匯入檔有標記或內容有效時以 UTF-16 或 UTF-8 解碼，否則依序嘗試 Big5（CP950）、GB 18030 和 Windows-1252。`SessionExport` 寫出 `.gloamuxsessions` JSON（`SessionsFile`）和 CSV；兩者都不含密碼，並把家目錄下的路徑改寫成 `~/…`。
