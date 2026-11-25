# 發布 Gloamux

[English](../en/RELEASING.md) · [繁體中文](RELEASING.md) · [回到 README](../../README.zh-TW.md)

[驗證紀錄](VERIFICATION.md)包含 2026 年 11 月 25 日的本機序列埠／終端檢查，以及 11 月 24 日的全 App 壓力測試基準。

這是更新文件、push `main`、建置 DMG 和發布 GitHub release 的標準流程，寫成人或程式代理都能從頭照做到尾。建置、檢查和發布由 `Gloamux/scripts/release.sh` 負責，其餘步驟由你完成。

## 版本號

| Release | Tag | App 版本（`CFBundleShortVersionString`） | Build（`CFBundleVersion`） |
|---|---|---|---|
| Gloamux 1.0 (build 1) | `v1.0` | `1.0` | `1` |
| Gloamux 1.1 (build 2) | `v1.1` | `1.1` | `2` |
| Gloamux 1.2 (build 3) | `v1.2` | `1.2` | `3` |
| Gloamux 1.2.1 (build 4) | `v1.2.1` | `1.2.1` | `4` |
| Gloamux 1.2.2 (build 5) | `v1.2.2` | `1.2.2` | `5` |
| Gloamux 1.3 (build 6) | `v1.3` | `1.3` | `6` |
| Gloamux 1.3.1 (build 7) | `v1.3.1` | `1.3.1` | `7` |
| Gloamux 1.3.2 (build 8) | `v1.3.2` | `1.3.2` | `8` |
| Gloamux 1.4 (build 9) | `v1.4` | `1.4` | `9` |
| **下一個一般版本範例：Gloamux 1.5 (build 10)** | `v1.5` | `1.5` | `10` |

- 版本是使用者看到的號碼。一般發布提高第二個數字（1.1、1.2），重大改版提高第一個數字（2.0）。第三個數字只用在已發布版本的純修正版（1.1.1）。
- Build 號碼每發布一次就加一，不論版本為何，且絕不重複使用。Tag 也不重複使用，所以替換壞掉的 DMG 時，要發一個修正版並用下一個 build 號碼，例如 1.5.1 (build 11)。
- Release 標題固定是 `Gloamux 版本 (build 號碼)`，tag 固定是 `v版本`。
- 本機建置使用和最新 release 相同的版號，也就是 `Gloamux/scripts/package-app.sh` 裡的預設值（目前是 `version=${GLOAMUX_VERSION:-1.4}` 和 `build_number=${GLOAMUX_BUILD:-9}`）。發布的 commit 要把它們調成新版號，否則 `release.sh` 不會建置。

## 開始之前

- 執行 macOS 14 以上的 Apple 晶片 Mac、Xcode，以及 Rust 1.94 以上。
- GitHub CLI 已登入，且能存取 `LuckyFishOno/Gloamux`：`gh auth status`。
- 有 push `main` 的權限。如果 `git push origin main` 要求 HTTPS 帳密，改用 SSH push：`git push git@github.com:LuckyFishOno/Gloamux.git main`。
- 登入鑰匙圈裡有更新簽署金鑰。先執行一次 `swift build --package-path Gloamux`，再用 `Gloamux/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account Gloamux -p` 檢查；它印出的必須是 `package-app.sh` 裡的 `update_key`。只有擁有者有這把金鑰。在別台 Mac 上，用 `generate_keys --account Gloamux -f 備份檔` 匯入擁有者的備份，匯入後刪除備份檔。

### 更新簽署金鑰

只有用 EdDSA 私鑰簽署的 DMG，Gloamux 才會安裝；對應的公鑰就是 `package-app.sh` 裡的 `update_key`（App 的 `SUPublicEDKey`）。私鑰放在擁有者的登入鑰匙圈，帳號是 `Gloamux`。請用 `generate_keys --account Gloamux -x 備份檔` 備份一次，並把檔案存進密碼管理器，絕不放進 repository。金鑰遺失時，已安裝的版本就無法自行更新，只能在一個所有使用者都手動安裝的版本裡換上新金鑰。除此之外絕不更換 `update_key`。

每個步驟都適用的規則：

- 文件以英文撰寫，`docs/en` 的每份文件在 `docs/zh-TW` 都有同名的繁體中文版（README 則是 `README.md` 和 `README.zh-TW.md`），兩者要在同一個 commit 中修改。
- 截圖和文件絕不出現真實的主機名稱、使用者名稱、IP 位址或金鑰。用 `--workspace` 搭配可拋棄的資料夾，主機用 `server.example.com` 這類範例。
- 任何語言的介面文字都不能以「…」或「...」結尾。
- 絕不 commit 機密、`.env`、金鑰，或 `build/`、`web/`、`/analysis/`、`.agent-memory/` 底下的任何東西。
- 絕不 force-push `main`；未經擁有者同意，絕不刪除或取代已發布的 release 或 tag。

## 1. 從最新的 main 開始

```sh
git switch main
git pull --ff-only
git status --short          # 必須沒有任何輸出
gh release list -R LuckyFishOno/Gloamux --limit 5
```

清單中最新的 release 就是上一個 build 號碼，新的 build 是它加一。

## 2. 更新文件

每次發布都要逐項檢查，兩種語言都要改：

- [ ] `Gloamux/scripts/package-app.sh`：把預設值改成新版號，例如 `version=${GLOAMUX_VERSION:-1.5}` 和 `build_number=${GLOAMUX_BUILD:-10}`，本機建置就會和發布版顯示相同版本。
- [ ] `README.md` 和 `README.zh-TW.md`：`Current release: **Gloamux 版本 (build 號碼)**.` 這一行（中文是 `目前版本：**Gloamux 版本 (build 號碼)**。`）。兩份都寫上新版之前，`release.sh publish` 不會執行。
- [ ] `docs/*/USER-GUIDE.md`：上次發布以來所有使用者看得到的改變，寫進對應的章節，以及選單、快捷鍵、設定和命令列一覽，名稱要和 App 顯示的完全一致（中文手冊使用 App 的繁體中文名稱）。
- [ ] `README` 的功能清單和「為什麼用它」表格：有新增或移除主打功能時才改。
- [ ] `docs/*/ROADMAP.md` 和 `docs/*/FEATURE-BACKLOG.md`：勾選完成的項目；App 裡沒有的不要標成完成。
- [ ] `docs/*/DATA-PROTECTION.md`：新增的儲存資料、機密或輸出管道，以及「審閱日期」那一行。
- [ ] `docs/*/DEVELOPMENT.md`：新的架構、設定鍵或測試說明。
- [ ] `docs/assets/*.png`：只有介面明顯改變時才重拍，並遵守上面的截圖規則。
- [ ] 文件搬移或改名後，檢查兩種語言的相對連結與章節錨點，並以封裝後 CLI 的說明核對文件指令。
- [ ] 更新本機 `.agent-memory/status.md` 的發布 commit、安裝路徑、完成的檢查和待驗證項目。這份檔案保留在本機。網站維護筆記放在同樣不納入公開提交的 `web/`。

接著檢查要 commit 的內容：

```sh
git diff --stat
git grep -nIi -e "$(id -un)" -e "$(hostname -s)" -- . ':!*.lproj' || echo "no personal names"
```

## 3. Commit

把這次發布的程式和文件 commit 起來。標題用簡短的祈使句（72 字元以內），內文列出使用者看得到的改變：

```sh
git add -A
git status --short          # 檢查：沒有機密，沒有產生出來的檔案
git commit -m "Release Gloamux 1.5 (build 10)" -m "- Short list of the user-facing changes"
```

## 4. 建置並檢查 DMG

```sh
Gloamux/scripts/release.sh build 1.5 10
```

工作目錄必須是乾淨的，因為 DMG 是從已 commit 的原始碼建置。之後若再提交原始碼或文件，發布前請重新建置，讓封裝對應 release 記載的 commit。腳本會：

1. 不在 `main`、有未 commit 的變更、`package-app.sh` 的版號和這次發布不符、tag 已存在，或 build 號碼沒有大於上一個已發布的號碼時，拒絕執行。
2. 執行 Swift 測試和 Rust 遠端桌面測試。`--skip-tests` 會略過它們；只有兩組測試都已在這個 commit 上通過時才用。
3. 用發布版號把 `Gloamux.app` 打包到 `build/release/版本-號碼/`。
4. 檢查版本、build 號碼、更新清單網址、更新金鑰、內含的 Sparkle framework、簽章、arm64 架構、9 項功能的 self-test，以及 `gloamux --version`。鑰匙圈裡沒有更新簽署金鑰時，也會在一開始就停下。
5. 製作含 App 和 Applications 捷徑的 `Gloamux.dmg`，掛載後檢查內容、捷徑、簽章和校驗碼。
6. 寫出 `Gloamux.dmg.sha256`，並印出路徑、大小、SHA-256 和 commit。

Swift 測試在沒有設定遠端主機和 Xshell 範例檔時，會略過相關檢查，這是正常的。任何失敗都會讓腳本停下；請在新的 commit 修正原因後再執行一次。

## 5. Push main

```sh
git push origin main
```

## 6. 撰寫 release 說明

用英文把說明寫到 `build/release/版本-號碼/notes.md`（`build/` 資料夾不會被 commit）。不要自己加建置資訊段落，`release.sh` 會自動附上。範本：

```markdown
**Gloamux 1.5 (build 10)** adds … and fixes ….

## Highlights
- **Feature name.** What it does for the user, in one sentence.

## Fixes
- What was wrong, and what happens now.

## Installation
1. Download and open **Gloamux.dmg**.
2. Quit Gloamux if it is running, then drag **Gloamux.app** onto **Applications** and replace the old copy.
3. Open Gloamux from Applications. Your connections and settings stay as they are.

Already on Gloamux 1.1 or later? Choose **Gloamux › Check for Updates** instead.

Requires macOS 14 or later and an Apple silicon Mac (M1 or newer). The app is ad hoc signed and is not notarized. If macOS shows "Gloamux" Not Opened, use System Settings → Privacy & Security → Open Anyway, as documented in the README.

## Validation
- Swift suite: N tests, N passed and N skipped (remote host and Xshell sample checks that need external inputs), 0 failed.
- Rust remote desktop engine: N tests passed.
- Packaged app self-test passed for all 9 features.
- Apple silicon release build, deep signature verification, and DMG checksum verification passed.
```

測試數量取自第 4 步的輸出。只寫使用者看得到的改變，不要列內部重構。

## 7. 發布

```sh
Gloamux/scripts/release.sh publish 1.5 10 build/release/1.5-10/notes.md
```

腳本會再次確認工作目錄乾淨、DMG 仍符合校驗碼、兩份 README 都寫上這個版本，以及 GitHub 上的 `main` 就是你建置的 commit。它會把說明轉成 HTML（透過 GitHub 的 Markdown API），並寫出 `appcast.xml`，也就是已安裝的版本會讀取的更新清單：版本、build 號碼、說明，以及 DMG 的 EdDSA 簽章（`Gloamux/scripts/appcast.sh`）。接著建立 tag 和標題為 `Gloamux 1.5 (build 10)` 的最新 release，附上 `Gloamux.dmg` 和 `appcast.xml`、加上建置資訊，並確認 README 的下載連結（`releases/latest/download/Gloamux.dmg`）可以下載，以及 `releases/latest/download/appcast.xml` 提供的是新的 build。從這一刻起，Gloamux 1.1 以後的版本會透過 **Gloamux › 檢查更新** 和每日檢查提供這次更新。

Gloamux 1.0 沒有更新功能，使用者需要手動安裝新版一次；1.1 的說明已寫明這點。

## 8. 發布之後

- 打開 release 頁面，以使用者的角度讀一遍。
- 確認 README 的 **下載 Gloamux** 連結下載的是新的 DMG。
- 在裝有上一版的 Mac 上（1.1 以後），選 **Gloamux › 檢查更新**，確認它會提供、安裝並重新開啟新版本。記錄這項檢查是否執行；單元測試和功能自檢通過，仍需另行驗證更新安裝。
- 向擁有者回報 release 網址、DMG 的 SHA-256 和 commit。

## 出問題時

| 問題 | 處理方式 |
|---|---|
| `tag vX.Y already exists` | 這個版本發布過了。改用下一個版本，或先問過擁有者再動既有的 release。 |
| `build N is not above the published build M` | 改用 build M + 1。 |
| `set version=... and build_number=... in Gloamux/scripts/package-app.sh` | 把兩個預設值調成新版號，commit 後再執行一次。 |
| `README.md does not name ...` | 更新兩份 README 的目前版本那一行，commit、push，再重新建置，讓 DMG 對應這個 commit。 |
| `GitHub main is ..., not ...` | push `main`；如果別人 push 過就先 pull，再從新的 commit 重新建置。 |
| `the DMG changed after it was built` | 重新執行 `release.sh build`。 |
| `hdiutil: ... Resource busy` | 退出已掛載的 Gloamux 磁碟（`hdiutil info` 後 `hdiutil detach`），再執行一次。 |
| `the Gloamux update signing key is not in the login Keychain` | 匯入擁有者的備份（見[更新簽署金鑰](#更新簽署金鑰)），或請擁有者發布。絕不為了發布產生新金鑰。 |
| `the Keychain's update key does not match update_key` | 鑰匙圈裡是另一把金鑰。匯入擁有者的備份，不要改 `update_key`。 |
| `the update feed at ... does not offer build N` | GitHub 可能要一分鐘才會提供新的附檔，稍候再開一次網址。如果 release 裡沒有 `appcast.xml`，用 `gh release upload v版本 檔案 -R LuckyFishOno/Gloamux` 上傳 `build/release/版本-號碼/appcast.xml`。 |
| `gh` 要求登入 | 執行 `gh auth login` 並選 GitHub.com。 |
| `release.sh build` 時某個測試失敗 | 單獨執行那個測試，例如 `swift test --package-path Gloamux --filter SshTests.KeyFormatTests/testPEMAndPKCS8KeysSignIn`。少數會啟動程序或伺服器的測試，在整套同時執行時可能失敗、單獨執行則通過；單獨通過的話，重新執行 `release.sh build`。單獨也失敗就是真的 bug，請在新的 commit 修正。 |
| 已發布的 DMG 有問題 | 不要替換附檔或移動 tag。修正後發一個修正版並用下一個 build 號碼，例如 1.5.1 (build 11)，並在說明中註明它取代哪個 build。 |
