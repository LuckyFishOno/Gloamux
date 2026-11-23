# 配色清單

[English](../en/THEME-INVENTORY.md) · [繁體中文](THEME-INVENTORY.md) · [回到 README](../../README.zh-TW.md)

2026 年 11 月 24 日工作目錄的功能與壓力測試結果見[驗證紀錄](VERIFICATION.md)。

2026 年 11 月 20 日調查，2026 年 11 月 23 日依 Gloamux 1.1 (build 2) 重新核對內附清單。Marketplace 排名仍保留 11 月 20 日的快照。本清單列出來自 Linux 發行版終端和安裝數最多的 Visual Studio Code 主題的候選配色，記錄每組配色的來源和數值的可靠程度。

**目前已內附：** `ThemeGallery.swift`（`linuxPresets`）中有七組 Linux 預設：Ubuntu、Kali Dark、GNOME Dark、GNOME Light、Breeze、Tango 和 Linux Console。Kali-Dark 已與另一份獨立的 colorscheme 檔交叉核對，Linux Console 與核心 `drivers/tty/vt/vt.c` 的預設配色一致。視窗外框顏色是衍生出來的。每種外框和選取顏色上的文字對比都至少 4.5:1。

**Visual Studio Code 主題：** `vscode-themes.json` 另外內附 48 組主題，Visual Studio Code 主題共 58 組。加上八組 Gloamux 預設和七組 Linux 預設，App 共提供 73 組配色。其中九組來自 Visual Studio Code 1.144.1 的內建主題擴充（Abyss、Kimbie Dark、Monokai、Monokai Dimmed、Quiet Light、Red、Solarized Dark、Solarized Light、Tomorrow Night Blue），三十九組來自下方排名中 19 個 MIT 授權的 Marketplace 擴充。Bearded Theme 因為是 GPL 授權而排除，Monokai Pro 因為是商業主題而排除。只差在斜體或邊框的變體略過。`scripts/build-vscode-themes.py` 會從本機的 Visual Studio Code App 和下載的 `.vsix` 套件重新產生藍圖、其校驗碼和 `vscode-community-themes-licenses.txt`。只使用工作台顏色，不內附語法標記顏色。App 中的主題清單是一個附搜尋欄的單一清單。原本的 Gloamux 主題已移除。取自 App 圖示（深靛藍配紫色強調色）的 Gloam 是預設配色；Midnight 仍可使用。

## 目前狀態

`vscode-themes.json` 一開始內含 Visual Studio Code `theme-defaults` 擴充的 10 組內建主題，現在也包含上面列出的 48 組：Light 2026、Dark 2026、Dark+、Dark Modern、Light+、Light Modern、Dark (Visual Studio)、Light (Visual Studio)、Dark High Contrast 和 Light High Contrast。載入器會檢查 SHA-256 校驗碼，最多接受 64 個 `color-palette` 資產，並讀取 Visual Studio Code 的顏色鍵。終端顏色來自 `terminal.ansi*` 鍵，主題沒有提供時使用後備配色。

發行版配色只定義終端：前景、背景、游標和 16 個 ANSI 顏色。要把它當成完整的工作區預設，Gloamux 必須衍生出工具列、側欄、分頁和強調色。

## Linux 發行版終端配色

**已驗證** 表示數值取自終端本身的原始碼，或註明來源且有人維護的收藏。**移植** 表示第三方轉換，尚未與上游檔案比對。

| 發行版 | 預設終端與配色 | 背景／前景 | ANSI 0–15 | 狀態 |
|---|---|---|---|---|
| **Ubuntu**（至 25.04） | GNOME Terminal，Ubuntu 設定檔：茄紫底上的 Tango 顏色 | `#300A24` / `#EEEEEC` | `#2E3436 #CC0000 #4E9A06 #C4A000 #3465A4 #75507B #06989A #D3D7CF` · `#555753 #EF2929 #8AE234 #FCE94F #729FCF #AD7FA8 #34E2E2 #EEEEEC` | 已驗證 · [iTerm2-Color-Schemes "Ubuntu"](https://github.com/mbadolato/iTerm2-Color-Schemes) · [Gogh "Clone Of Ubuntu"](https://github.com/Gogh-Co/Gogh) |
| **Ubuntu**（25.10 起） | Ptyxis 取代 GNOME Terminal | 未確認 | 未確認 | 檢查 Ubuntu 的 Ptyxis 套件是否有 Ubuntu 配色。上游 Ptyxis 沒有名為 Ubuntu 的配色。[Phoronix](https://phoronix.com/news/Ubuntu-Ptyxis-Recommended) |
| **Kali Linux** | QTerminal，Kali-Dark | `#23252E` / `#FFFFFF`，游標 `#B4D5FF` | `#1F2229 #D41919 #5EBDAD #FEA44C #367BF0 #9755B3 #49AEE6 #E6E6E6` · `#198388 #EC0101 #47D4B9 #FF8A18 #277FFF #962AC3 #05A1F7 #FFFFFF` | 已交叉核對 · [Alacritty gist](https://gist.github.com/scmanjarrez/3a069c3db3af2411118ad162cfb88e88) 與 [toxicwebdev/toxicblue](https://github.com/toxicwebdev/toxicblue) 中另一份 `Kali-Dark.colorscheme` 一致。Kali GitLab 上的 qtermwidget 擋下了自動存取。 |
| **Fedora Workstation**、GNOME 桌面 | Ptyxis，GNOME 配色深色版 | `#1C1C1F` / `#FFFFFF` | `#241F31 #C01C28 #2EC27E #F5C211 #1E78E4 #9841BB #0AB9DC #C0BFBC` · `#5E5C64 #ED333B #57E389 #F8E45C #51A1FF #C061CB #4FD2FD #F6F5F4` | 已驗證 · [Ptyxis `gnome.palette`](https://gitlab.gnome.org/chergert/ptyxis/-/tree/main/src/palettes) |
| 同上，淺色版 | Ptyxis，GNOME 配色淺色版 | `#FFFFFF` / `#1D1D20` | `#1D1D20 #C01C28 #26A269 #A2734C #12488B #A347BA #2AA1B3 #CFCFCF` · `#5D5D5D #F66151 #33D17A #E9AD0C #2A7BDE #C061CB #33C7DE #FFFFFF` | 已驗證 · 同一來源 |
| **RHEL、CentOS Stream、Rocky、AlmaLinux** | GNOME 桌面。終端依版本而定（GNOME Terminal 或 Ptyxis）。 | 使用上面的 GNOME 配色 | — | 找不到發行版專屬配色。需確認 RHEL 9 和 10 的預設終端。 |
| **較舊的 GNOME 發行版**（CentOS 7、Debian、舊版 Fedora） | GNOME Terminal，Tango | 黑色或系統顏色 | ANSI 值與 Ubuntu 那列相同 | 已驗證 · Gogh "Builtin Tango Dark" 和 "Builtin Tango Light" |
| **KDE 發行版**（Kubuntu、Fedora KDE、openSUSE、Manjaro KDE） | Konsole，Breeze | `#232627` / `#FCFCFC` | `#232627 #ED1515 #11D116 #F67400 #1D99F3 #9B59B6 #1ABC9C #FCFCFC` · `#7F8C8D #C0392B #1CDC9A #FDBC4B #3DAEE9 #8E44AD #16A085 #FFFFFF` | 已驗證 · Ptyxis `Breeze.palette`，由 Gogh 產生 |
| **Linux 主控台**（所有發行版、沒有桌面的伺服器） | VGA 文字模式配色 | `#000000` / `#AAAAAA` | `#000000 #AA0000 #00AA00 #AA5500 #0000AA #AA00AA #00AAAA #AAAAAA` · `#555555 #FF5555 #55FF55 #FFFF55 #5555FF #FF55FF #55FFFF #FFFFFF` | 標準 VGA 值 · Gogh "Linux Vt" |
| **elementary OS**、**Pop!_OS**、**Peppermint** | 各自的終端預設 | 見來源 | 見來源 | 可用 Gogh 的 "Elementary"、"Pop" 和 "Peppermint"。未與發行版目前版本比對。 |

### 以品牌為靈感的主題

Debian、Red Hat、CentOS、Arch 和大多數伺服器發行版沒有自己的終端配色。以它們命名的主題會是根據品牌色重新設計。彙整網站上的品牌色常常互相矛盾，設計前請從各專案自己的品牌頁面取值。

| 品牌 | 找到的顏色 | 可靠程度 |
|---|---|---|
| Ubuntu | 橘色 `#E95420`、茄紫 `#300A24`（終端） | 終端值已驗證。橘色請對照 [Ubuntu 的品牌更新](https://ubuntu.com/blog/ubuntu-orange-update)。 |
| CentOS | 綠 `#9CCD2A`、橘 `#EFA724`、藍 `#262577`、紫 `#A14F8C` | 取自[已封存的 CentOS wiki](https://wiki.centos.org/ArtWork(2f)Brand(2f)Logo.html)。這個標誌已由 CentOS Stream 取代。 |
| Arch Linux | 藍 `#1793D1`、灰 `#333333` | 第三方來源（[designpieces](https://www.designpieces.com/palette/arch-linux-color-palette-hex-and-rgb/)）。 |
| Kali Linux | 藍 `#367BF0` | 取自 Kali-Dark 的 ANSI 藍色。 |
| Red Hat、Fedora、Debian | 數值互相矛盾 | 未驗證。請以 [AlmaLinux 品牌頁](https://almalinux.org/branding/)這類官方頁面為範本，逐一查證。 |

## 安裝數最多的 Visual Studio Code 主題

2026 年 11 月 20 日從 Visual Studio Marketplace API 查詢 Themes 分類，依安裝數排序。安裝數為累計值。已排除圖示主題、擴充包和已停用的項目。

| 排名 | 主題 | 擴充 ID | 安裝數 | 評分 |
|---|---|---|---|---|
| 1 | GitHub Theme | `GitHub.github-vscode-theme` | 20.7M | 4.6 |
| 2 | One Dark Pro | `zhuangtongfa.Material-theme` | 12.9M | 4.7 |
| 3 | Dracula Theme Official | `dracula-theme.theme-dracula` | 11.2M | 4.8 |
| 4 | Atom One Dark | `akamud.vscode-theme-onedark` | 7.4M | 4.8 |
| 5 | Ayu | `teabyii.ayu` | 4.3M | 4.8 |
| 6 | Monokai Pro | `monokai.theme-monokai-pro-vscode` | 4.2M | 3.6 |
| 7 | Winter is Coming | `johnpapa.winteriscoming` | 3.8M | 4.6 |
| 8 | Night Owl | `sdras.night-owl` | 3.6M | 4.9 |
| 9 | Tokyo Night | `enkia.tokyo-night` | 3.0M | 5.0 |
| 10 | One Monokai | `azemoh.one-monokai` | 3.0M | 4.9 |
| 11 | Palenight | `whizkydee.material-palenight-theme` | 2.7M | 4.9 |
| 12 | SynthWave '84 | `RobbOwen.synthwave-vscode` | 2.6M | 4.8 |
| 13 | Shades of Purple | `ahmadawais.shades-of-purple` | 2.4M | 4.9 |
| 14 | Cobalt2 | `wesbos.theme-cobalt2` | 1.9M | 4.8 |
| 15 | Andromeda | `EliverLara.andromeda` | 1.7M | 5.0 |
| 16 | Bearded Theme | `BeardedBear.beardedtheme` | 1.5M | 4.9 |
| 17 | Catppuccin | `Catppuccin.catppuccin-vsc` | 1.5M | 5.0 |
| 18 | Atom One Light | `akamud.vscode-theme-onelight` | 1.5M | 4.9 |
| 19 | Noctis | `liviuschera.noctis` | 1.4M | 4.9 |
| 20 | Nord | `arcticicestudio.nord-visual-studio-code` | 1.3M | 4.9 |
| 21 | Panda | `tinkertrain.theme-panda` | 1.3M | 4.7 |
| 22 | Gruvbox | `jdinhlife.gruvbox` | 1.1M | 5.0 |
| 23 | Omni | `rocketseat.theme-omni` | 1.0M | 4.9 |
| 24 | Darcula | `rokoroku.vscode-theme-darcula` | 0.9M | 4.8 |
| 25 | Eva | `fisheva.eva-theme` | 0.8M | 4.9 |
| 26 | Linux Themes for VS Code | `SolarLiner.linux-themes` | 0.8M | 4.8 |
| 27 | Doki Theme | `unthrottled.doki-theme` | 0.7M | 4.9 |
| 28 | Min Theme | `miguelsolorio.min-theme` | 0.6M | 4.9 |
| 29 | Aura | `DaltonMenezes.aura-theme` | 0.6M | 5.0 |

備註：

- Microsoft 的 C/C++ Themes（`ms-vscode.cpptools-themes`，61.8M）安裝數最多，但大多是隨 C/C++ 擴充自動安裝，不代表使用者的選擇。
- Monokai Pro 是商業主題，沒有授權不得內附。
- Linux Themes for VS Code 改編自 Linux 桌面風格，可當作上面發行版預設的參考來源。
- Visual Studio Code 也內附其他與 `theme-defaults` 同樣是 MIT 授權的內建主題擴充：Abyss、Kimbie Dark、Monokai、Monokai Dimmed、Quiet Light、Red、Solarized Dark、Solarized Light 和 Tomorrow Night Blue。可用現有的轉接器加入。

## 建議的第一批

| 分組 | 主題 |
|---|---|
| 發行版終端 | Ubuntu（經典茄紫）、Kali Dark、GNOME 深色和淺色（Fedora、RHEL）、Breeze（KDE）、Tango、Linux 主控台 |
| Visual Studio Code 內建 | Solarized Dark、Solarized Light、Monokai、Abyss、Quiet Light、Tomorrow Night Blue |
| 熱門社群主題 | GitHub Dark 和 Light、One Dark Pro、Dracula、Tokyo Night、Night Owl、Catppuccin、Nord、Gruvbox、Ayu |

載入器最多接受 64 個資產。這一批是在只內附 10 組預設時寫的，現在已包含在上面的 58 組 Visual Studio Code 主題中。

## 內附之前

- 檢查每個主題的授權，並把授權聲明放在 `vscode-themes-license.txt` 旁邊。
- 把每個來源固定到某個版本或 commit，並在內附清單中記錄其 SHA-256。
- 對照上游檔案驗證 Kali-Dark 的移植。確認 Ubuntu 25.10 以後以及 RHEL 9 和 10 的預設終端。
- 只有終端配色的主題，需定義衍生的工作區顏色，並檢查工具列、側欄和分頁中的文字對比。
