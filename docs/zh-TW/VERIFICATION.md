# Gloamux 驗證紀錄

[English](../en/VERIFICATION.md) · [繁體中文](VERIFICATION.md) · [回到 README](../../README.zh-TW.md)

2026 年 11 月 24 日，依 `b1e4638` 之上、收錄於 Gloamux 1.2 (build 3) 的架構修改重新建置與驗證。本次測試套件位於 `build/Gloamux.app`。

## 1.2.2 (build 5) 的終端圖示修正

2026 年 11 月 24 日，基於 `1363ebf`（1.2.1 build 4）驗證。本機測試版為 `build/font-fix/Gloamux.app`；正式建置會重跑 Swift 全套與套件檢查。

- 原本的一般與粗體預設字型會把 Powerline／Nerd Font 私用區字元交給 LastResort；TextKit 使用的缺字符號前進寬度也與終端格寬不同。最初四項回歸案例在修正前均失敗；最終六項 `TerminalFontTests` 全數通過，涵蓋實際字型、13／20 pt 的位置、游標偏移、單格／雙格圖示、固定列高、指定 Menlo 字型及一般中文／emoji 後備。左右彩色提示原地重繪仍維持在同一列。
- Swift 全套：**476 項，468 通過、8 跳過、0 失敗**。略過項目仍為三項外部 SSH 和五項 Xshell 樣本檢查。測試版通過完整嚴格簽章驗證，功能契約自檢 **9/9**；資源套件含符號字型、MIT 授權及來源紀錄。
- 使用獨立 App 識別碼與臨時工作區，透過本機 zsh 載入真正的 Oh My Zsh Agnoster 和 Powerlevel10k（os_icon、dir、prompt_char、status、time）。以預設系統等寬字型目視確認 Powerline 分隔、Apple／首頁／時鐘圖示、一般與粗體圖示樣本、中文、emoji 及右側提示；沒有把字型安裝到使用者字型資料夾。另以程序內註冊的官方 MesloLGS NF Regular 確認，它標示為等寬，能通過現有字型選單篩選。尚未在回報問題的那台 Mac 或 Intel 硬體上測試。
- Release 終端基準測試以 120 × 40 執行五種各 2 MB 的負載。測試版重繪耗時 **0.54–1.72 ms**，已安裝基準版為 **0.47–1.60 ms**；增加最多為 0.23 ms。輸入回顯 p99 為 0.019 ms，基準版為 0.021 ms。這是本機單次量測，未重跑完整 App 壓力測試。

以下其餘章節保留先前的 1.2 架構與壓力測試紀錄。

## 功能與回歸測試

| 檢查 | 結果 |
|---|---|
| Swift 全套 | 469 項，461 通過、8 跳過、0 失敗 |
| Rust 遠端桌面引擎 | 18 項通過 |
| 封裝 App | 完整簽章驗證通過，功能契約自檢 9/9 |
| CLI 說明入口 | 22 組通過 |
| 封裝後分批功能腳本 | 81/81 通過，包含修正測試識別碼後重跑的退出錄影案例 |
| 語系檔 | 五份 `Localizable.strings` 均通過 plutil 檢查 |

Swift 涵蓋解析與匯入、主機信任、憑證、代理和跳板、MFA 回送測試、終端、分割與鎖定、SFTP／SCP／FTP／FTPS、轉發，以及新增的架構回歸測試。八項略過為三項外部 SSH 主機檢查和五項已安裝 Xshell 樣本檢查。

81 項封裝測試涵蓋安全覆寫、鎖定後拒絕操作、損壞資料保護、錄影儲存失敗、並行 CLI、共用連線服務、help 與補全、結束代碼、標準輸入密語、相對路徑，以及錄影達上限和退出時保存。測試使用臨時工作區，本機 SSH 測試使用當次產生的金鑰。

使用者回報已於打包測試版確認注音／拼音組字與 Return、分割窗格持續輸出時組字、滑鼠選取，以及輸入送到正確窗格。這項手動結果記錄於本機專案進度。

## 完整壓力測試

環境為 Apple silicon、10 核心、macOS 27.2.1。以完整負載執行，14/14 階段通過。

| 階段 | 結果 |
|---|---|
| 離線 CLI 目錄 | 通過 |
| 設定匯出與匯入 | 通過 |
| 本機 SSH 伺服器 | 通過 |
| SFTP 大檔 | 通過 |
| SCP 大檔 | 通過 |
| 遞迴資料夾傳輸 | 通過 |
| SSH 反覆連線 | 通過 |
| 終端基準測試 | 通過 |
| App 啟動 | 通過 |
| App 執行中的 CLI 目錄 | 通過 |
| 分頁與終端大量輸出 | 通過 |
| 連接埠轉發 | 通過 |
| MCP 代理 | 通過 |
| 負載後閒置 | 通過 |

| 指標 | 本次結果 |
|---|---|
| 大檔 | SFTP 與 SCP 各 512 MB 往返 |
| 資料夾 | 2,000 個檔案上傳、下載與移除 |
| 平行 SSH | 40 條，0 失敗 |
| 終端負載 | 20 個本機、10 個 SSH 分頁，各輸出 1,000,000 行 |
| 輸出速率 | 約 660,949 行／秒 |
| App 記憶體 | 峰值 711 MB，關閉負載分頁後約 153 MB |
| 轉發 | 200 次連線，256 MB 往返 |
| MCP | 5 個工具，300 次呼叫，p95 約 4 ms，執行提案維持等待審閱 |

數值為本機這次量測。傳輸端點為 loopback，測試記錄每秒取樣一次。

## 架構檢視結果與待辦

十項發現均有對應實作與測試，包括安全提交、目標工作區鎖定、過期結果淘汰、儲存錯誤、並行請求、有界程序、共用連線服務、背景保存、終端更新隔離和 CLI 目錄。

離線管理指令仍建立完整 WorkspaceModel，CLI handler 仍各自解析字串參數；這兩項延伸重構保留待辦。真實 VNC／螢幕共享、PAM 一次性驗證碼、XQuartz 顯示與輸入、較廣泛的 Vim／tmux 相容性、更新安裝和 Intel 建置測試也仍待驗證。功能契約自檢與測試通過的範圍以本頁各項說明為準。

## 測試腳本修正紀錄

退出錄影腳本原先硬編碼舊測試 App 識別碼，第一次重跑關閉了先前的測試實例，造成新實例退出與保存的兩項檢查失敗。修正臨時腳本為本次獨立識別碼後重跑，6/6 通過。產品程式碼無須為此調整。原始與重跑紀錄均保留在本機檢查資料中。

## 重跑與來源

```sh
swift test --package-path Gloamux
cargo test --offline --locked --manifest-path Gloamux/RDP/Cargo.toml
Gloamux/scripts/package-app.sh
codesign --verify --deep --strict build/Gloamux.app
python3 Gloamux/scripts/stress-test.py --out /tmp/gloamux-stress-verification
```

來源摘要 SHA-256 為 `7632fcf66a6a1b75b5cb4191dc4092d308109d132e70bb5a99700a1f1617f984`，涵蓋 Sources、Tests、RDP/src、Package.swift、Package.resolved、Cargo.toml 和 Cargo.lock，依路徑排序後以路徑、NUL、檔案內容、NUL 串接計算。本機原始紀錄保留於 `analysis/verification-20261124/`，該目錄由 Git 排除。
