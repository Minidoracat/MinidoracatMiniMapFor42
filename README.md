# Minidoracat MiniMap for B42

**By Minidoracat**

Project Zomboid Build 42 遊戲內世界地圖圖片化基底 MOD。
使用 B42 引擎原生的 **ImagePyramid**（pyramid.zip）在世界地圖上疊加預渲染地圖圖片，
並自動掃描啟用中的地圖 addon MOD——addon 零 Lua 即可被載入。

設計決策詳見 [MinidoracatMapRendering/docs/minimap-mod-design.md](../MinidoracatMapRendering/docs/minimap-mod-design.md)。

## 架構：基底 + addon 同檔名匹配

所有 zip 使用同一個約定檔名 `minidoracat_minimap.pyramid.zip`，
放在各自 MOD 的 `media/minimap/` 下：

```
基底 MOD（本專案）                          地圖 addon MOD（第三方，零 Lua）
MinidoracatMiniMapFor42/                   SomeMapMod/
└── media/                                 └── media/
    ├── lua/client/                            └── minimap/
    │   └── MinidoracatMiniMap.lua                 └── minidoracat_minimap.pyramid.zip
    └── minimap/                                       （該地圖 bbox 的渲染圖，
        └── minidoracat_minimap.pyramid.zip             bounds 自帶自動對位）
            （Muldraugh 基底全圖）

                    ┌──────────────────────────────────┐
 世界地圖開啟時      │ hook ISWorldMap:initDataAndStyle │
                    └────────────────┬─────────────────┘
                                     │ 掃描 getActivatedMods()
                                     │ 每個 MOD 檢查 media/minimap/<約定檔名>
                                     ▼
                    mapAPI:addImagePyramid(絕對路徑) × N（含本 MOD 自己，不特判）
                                     │
                                     ▼
                    單一 Pyramid 樣式層（fileName 尾綴匹配全部 zip）
                    疊在原版樣式之上；addon 後註冊，畫在基底之上
```

- **檔名即匹配鍵**：引擎樣式層以 `endsWith(File.separator + fileName)` 匹配已掛載 zip，
  所以基底與 addon 必須同檔名。
- **每顆 zip 自帶 bounds**（`pyramid.txt` 內世界 square 座標），引擎自動對位，無需檔名編碼座標。
- 效能由引擎處理：LRU 紋理快取、多層級 LOD、非同步載入（相對 B41 per-cell 紋理方案）。

## MOD 資訊

| 項目 | 值 |
|------|-----|
| **Mod ID** | `MinidoracatMiniMapFor42` |
| **支援版本** | Build 42.19.0+ |

## 專案結構

```
MinidoracatMiniMapFor42/
├── link_workshop.bat              # Workshop 符號連結管理（雙擊啟動）
├── PZ_Test.bat                    # PZ 本地測試啟動器（雙擊啟動）
├── scripts/
│   ├── build_pyramids.ps1      # 產生基底 pyramid zip（呼叫 pzmap render-minimap）
│   ├── link_workshop.ps1       # 符號連結管理腳本（PowerShell）
│   └── PZ_Test.ps1             # 遊戲測試啟動器（PowerShell）
├── STEAM_DESCRIPTION.md           # Steam 商店頁面描述草稿
└── MOD/MinidoracatMiniMapFor42/   # Workshop 上傳根目錄
    └── Contents/mods/MinidoracatMiniMapFor42/42/  ← PZ 模組根目錄
        ├── mod.info
        └── media/
            ├── lua/client/MinidoracatMiniMap.lua
            └── minimap/           # pyramid zip 約定目錄（產物不進版控）
```

## 本地開發

### 前置需求

- Windows 10/11、Project Zomboid Build 42（Steam 版）
- 產 zip 需要 [MinidoracatMapRendering](../MinidoracatMapRendering) 的 `pzmap.exe`
  （`cargo build --release`）

### 1. 產生基底 pyramid zip

```powershell
pwsh -NoProfile -File scripts/build_pyramids.ps1
# 或指定路徑/地圖：
pwsh -NoProfile -File scripts/build_pyramids.ps1 -GamePath "D:\SteamLibrary\steamapps\common\ProjectZomboid" -MapName "Muldraugh, KY"
```

addon 的 zip 用 pzmap Studio（GUI）選該地圖 MOD →「遊戲內小地圖」模式輸出同名 zip。

### 2. 掛載到遊戲目錄

雙擊 `link_workshop.bat`，選擇 **[1] 掛載**。建立兩個符號連結：

```
%UserProfile%\Zomboid\Workshop\MinidoracatMiniMapFor42 → <專案>\MOD\MinidoracatMiniMapFor42
%UserProfile%\Zomboid\mods\MinidoracatMiniMapFor42     → <專案>\MOD\...\Contents\mods\MinidoracatMiniMapFor42
```

> 權限不足會自動彈 UAC；或啟用 Windows 開發人員模式免提示。

### 3. 啟動遊戲測試（no-steam）

雙擊 `PZ_Test.bat` 選啟動模式（客戶端 / Debug / 專用伺服器 / Host 雙開）。
進遊戲啟用 MOD 後開世界地圖（M），console.txt 應出現：

```
[MinidoracatMiniMap] 已掛載 pyramid: ...
[MinidoracatMiniMap] 圖層就緒（N 個 pyramid zip）
```

### 卸載

`link_workshop.bat` → **[2] 卸載**（只移除連結，不刪原始檔案）。

## 問題回報 & 交流

- [Discord 伺服器](https://discord.gg/Gur2V67)
- [Twitch 直播頻道](https://www.twitch.tv/minidoracat)
