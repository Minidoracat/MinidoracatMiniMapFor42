# Minidoracat MiniMap for B42

**By Minidoracat**

Project Zomboid Build 42 遊戲內世界地圖圖片化 MOD。
使用 B42 引擎原生的 **ImagePyramid**（pyramid.zip）在世界地圖上疊加預渲染地圖圖片；
內建基底全圖，**地圖 MOD 的圖走「地圖包 addon」**
（[MinidoracatMiniMapModMapsFor42](../MinidoracatMiniMapModMapsFor42)，`require=` 本 MOD，
經 `registerMaps` API 註冊、依啟用的地圖 MOD 自動掛載），
並保留第三方 addon 同名約定——addon 零 Lua 即可被載入。

設計決策詳見 [MinidoracatMapRendering/docs/minimap-mod-design.md](../MinidoracatMapRendering/docs/minimap-mod-design.md)
（該文件描述初版「同名檔案」架構，現為第三方相容路徑；現行架構見下方架構節）。

## 功能

- **世界地圖 / 角落小地圖圖片化**：ImagePyramid 疊加層，自動掛載基底與 addon 地圖 zip；
  「圖片化地圖」總開關可切回原版向量樣式（圖標等其他功能照常）
- **小地圖快捷鍵**：預設 `/`（斜線，M 鍵右方）開關小地圖（選項 → 按鍵綁定可改），
  沙盒未開 AllowMiniMap 也能自建；舊預設 HOME 首次進遊戲自動遷移為 `/`
- **浮動開關圖標**：常駐小圖標點擊開關小地圖（免快捷鍵）；可拖曳擺放、
  位置自動記憶，設定可關
- **小地圖尺寸設定**：小（原版）/ 中（1.5 倍，預設）/ 大（2 倍）/ 特大（2.5 倍）
- **邊緣拖曳縮放**：滑鼠移到小地圖邊緣／角落（8px 熱區，有角落括號與亮條提示）
  按住拖曳即可縮放（單邊＝單軸自由縮放、角落＝等比縮放；180px ～ 螢幕短邊 85%）；
  放開後以新尺寸重建並自動存檔，自訂尺寸優先於尺寸下拉、改動下拉即重置
- **按鈕列顯示模式**：預設「永遠顯示」標題列與按鈕列，小地圖高度恆定、
  滑鼠移上去地圖核心不再位移；可改回原版「滑鼠懸停時」展開
- **精準殭屍點位**：小地圖上以亮橘點（黑描邊）顯示已載入區域的殭屍即時位置（與紅色玩家點區分）
  （預設關；每 0.3 秒取樣、視窗內上限可調 100～800 隻，關閉時零成本）
- **動物圖標**（預設關）：即時顯示附近動物——野生／畜養獨立開關、9 個內建物種篩選
  （牛/羊/豬/鹿/雞/火雞/兔/浣熊/鼠類；相容包可追加）；地圖符號或彩色物品圖兩種風格，大小、
  透明度、顏色可調（色盲友善 8 色）；內建物種使用遊戲內建素材，相容包可提供自己的圖標。MP 伺服器可依動物目前所在的
  安全屋設定四檔牲畜可見性，預設隱藏其他安全屋內的牲畜
- **載具圖標**（預設關）：方向盤圖標顯示附近載具；一般／重型／性能／特勤（警燈車）
  類別篩選，大小、透明度、顏色可調
- **內建資源點（POI，0.8.0+）**：原版地圖 636 筆資源點、14 類（軍事／警察／槍店／醫療／
  藥局／消防／圖書／學校／超市／加油站／五金／戶外／監獄／倉儲，各配可辨識色），
  裝本體即見；預設圖標模式（染色剪影，可切全彩），另有半透明區塊模式；統一視窗
  「資源點」小節逐類勾選（列首帶類別小圖）＋全選／全不選，齒輪面板快速開關
- **世界地圖圖標**（預設關）：殭屍點位／野生動物／畜養動物／載具四個獨立開關，
  在世界地圖（M）顯示同款圖標；風格、顏色與篩選跟隨小地圖設定；世界地圖按鈕列
  新增爪印按鈕直開設定視窗
- **統一設定視窗**（齒輪鈕）：雙欄七區塊（圖層顯示／資源點／殭屍點位／動物圖標／
  載具圖標／世界地圖圖標／外觀與行為）可收合、全部展開／收合、收合時標題列顯示現況摘要；各語系實測字寬
  自適應版面、內容捲動不超出螢幕；引擎原生「等軸測／符號／遠端符號」整併於此，
  勾選即存、與 ESC 選項頁雙向同步
- **玩家座標顯示與一鍵複製**：小地圖底部置中顯示自己座標 x, y, z（可關）；
  按鈕列 XY 鈕一鍵複製 `x,y,z` 到剪貼簿、右鍵選單「複製此處座標」複製指向位置
  （`x,y,0`），貼上即用於 `/teleportto` 等指令；複製成功顯示 1.5 秒「已複製！」
- **按鈕列**：M（世界地圖）、-／+（縮放）、C（回到玩家）、XY（複製座標）、
  齒輪（統一設定視窗）、X（關閉）；按鈕動態間距，最小尺寸也裝得下
- **HUD 微調**：滑鼠懸停時小地圖邊框微亮（0.4→0.55），縮放熱區顯示 HUD 角落括號

## 截圖

| | |
|---|---|
| ![統一設定視窗](docs/screenshots/settings-window.png) | ![導航選單與回中提示](docs/screenshots/nav-menu-recenter-hint.png) |
| ![設定導航目標](docs/screenshots/nav-set-target.png) | ![陣營目標分享](docs/screenshots/nav-share-faction.png) |
| ![導航邊緣指示](docs/screenshots/nav-edge-indicator.png) | ![管理員沙盒選項](docs/screenshots/admin-sandbox-options.png) |
| ![內建資源點（POI）](docs/screenshots/poi-resource-points.png) | |

（設定視窗／沙盒選項／回中提示另有英日文版截圖：`*-en.png`、`*-jp.png`）

## 設定

主選單或遊戲內 **選項 → 模組 → Minidoracat 小地圖**：

| 選項 | 預設 | 說明 |
|------|------|------|
| 小地圖尺寸 | 中（1.5 倍） | 變更後按「接受」即重建小地圖套用；改動時同時清除自訂尺寸 |
| 顯示按鈕列 | 永遠顯示 | 標題列＋按鈕列顯示模式：「永遠顯示」高度恆定、地圖核心不位移；「滑鼠懸停時」為原版展開/收合行為 |
| 自訂尺寸（寬x高） | 空 | 拖曳小地圖邊緣縮放時自動寫入（例 `300x240`），優先於尺寸下拉；清空即還原 |
| 顯示自己圖標 | 開 | 小地圖上自己的位置圖標 |
| 顯示隊友圖標 | 開 | 其他玩家圖標＋名字，**僅多人有效**；另受伺服器 `MapRemotePlayerVisibility` 限制（1=隱藏 2=同陣營 3=陣營+視線內 4=所有人） |
| 顯示殭屍熱度 | 關 | 殭屍**族群熱度圖**（密度分布，非即時點位） |
| 顯示即時殭屍點位 | 關 | 亮橘點（黑描邊）顯示**小地圖可視範圍內**的殭屍即時位置（與紅色玩家點區分）（0.3 秒取樣、視窗內上限可調），輕微效能成本；圖層選單亦有同步開關 |
| 殭屍點顏色／大小／透明度／上限 | 橘／3px／100%／200 | 五色、大小與透明度滑條（1-16px／10-100%）、上限 100～800 隻（可視範圍內，超過上限優先顯示離自己較近者），存檔即生效 |
| 顯示野生／畜養動物圖標 | 關／關 | 即時顯示附近動物（0.5 秒取樣、可視範圍內）；統一視窗可再按 9 個內建物種＋相容包追加項目篩選。MP 牲畜可見性由伺服器四檔沙盒選項控制 |
| 動物圖標風格／大小／透明度 | 地圖符號／16px／100% | 風格：原版地圖符號（可染色）或彩色物品圖；大小與透明度滑條（8-48px／10-100%）；載具另有獨立大小/透明度滑條 |
| 野生動物顏色／畜養動物顏色／載具圖標顏色 | 綠／白／天藍 | 色盲友善 8 色（白/綠/橘/天藍/黃/紫紅/藍/硃紅） |
| 顯示載具圖標 | 關 | 方向盤圖標顯示可視範圍內載具；統一視窗可按一般/重型/性能/特勤（警燈車）類別篩選 |
| 世界地圖：殭屍點位／野生動物／畜養動物／載具 | 關 ×4 | 世界地圖（M）的圖標開關（設定視窗「世界地圖圖標」區段）；風格、顏色與篩選跟隨小地圖設定 |
| 隱藏物種清單／隱藏載具類別（進階） | 空 | 由統一設定視窗的篩選勾選自動寫入（CSV 停用清單），一般不需手動編輯 |
| 顯示街名 | 開 | 沿道路顯示街名——原版小地圖**從不載入街道資料**（只有世界地圖有），本 MOD 補載；中文街名翻譯 MOD 同步生效 |
| 顯示安全屋範圍 | 開 | 自己所屬安全屋＝綠框、其他玩家＝紅框（等軸測下正確描邊），辨識禁入區；齒輪面板亦有同步開關 |
| 外框不透明度 | 原版 | 外框與按鈕列底色透明度三檔（地圖本體為 GPU 直繪，無法整體半透明） |
| 鎖定小地圖 | 關 | 鎖定後標題列拖曳移動與邊緣拖曳縮放皆停用，防止誤觸 |
| 拖曳自由查看 | 開 | 拖動小地圖後**停留在該處**（原版放開即回中），點一下小地圖回到玩家；拖離期間地圖底部顯示「點擊地圖回到玩家」提示、C 鈕高亮 |
| 顯示玩家座標 | 開 | 小地圖底部置中顯示自己 x, y, z；XY 鈕與右鍵「複製此處座標」**不受此開關影響**，複製成功顯示 1.5 秒琥珀提示 |
| 顯示地名 | 開 | 城鎮與區域名稱（開啟時自動連帶開啟「符號」）；**角落小地圖預設看不到文字**——需同時開啟下方「文字註記」實驗選項，世界地圖（M）則不受限 |
| 小地圖文字註記（實驗性） | 關 | 原版小地圖固定精簡符號模式、文字註記一律不畫；開啟改用完整模式讓地名等文字可顯示，玩家自畫標記會以完整大小呈現 |
| 點擊小地圖開啟世界地圖 | 關 | 原版點一下小地圖會開世界地圖；預設關閉保留點擊給未來互動，M 鍵／M 鈕不受影響 |

**導航目標**：右鍵小地圖 → 「設定導航目標」。目標在視窗內顯示金旗、超出視窗時
沿邊緣顯示方向箭頭與直線距離；走到目標 5 格內自動抵達清除；目標隨角色存檔保留。
加入陣營（faction）後右鍵選單多「分享目標給陣營」——同陣營成員的小地圖會以
青旗＋名字顯示你的目標（由伺服器過濾轉送，非同陣營玩家收不到）。
右鍵選單另有「複製此處座標：x, y, 0」，即看即複製指向位置到剪貼簿。

以上設定**遊戲內按小地圖齒輪鈕（統一設定視窗）即可直接調整**，改動即時生效並存檔；
ESC 選項頁按「接受」亦同步。設定存於 `%UserProfile%\Zomboid\Lua\ModOptions.ini`（引擎管理）。

**語言支援**：繁體中文（CH）、简体中文（CN）、English（EN）、日本語（JP），
四語鍵完全同步；其他語言回退英文。

## 伺服器管理（沙盒選項）

沙盒設定新增「Minidoracat 小地圖」頁（伺服器建立時設定，或管理員面板 →
沙盒設定即時調整，**客戶端每幀讀值、改動即時生效**）：

| 沙盒選項 | 預設 | 說明 |
|----------|------|------|
| 允許即時殭屍點位 | 開 | 關閉＝所有玩家的殭屍點位失效（避免情報優勢） |
| 殭屍點位顯示距離（格） | 0＝不限制 | N＞0＝僅顯示距玩家 N 格（約 1 公尺/格）內的項目；二維直線距離（不含樓層），管理員套用後即時生效 |
| 允許殭屍熱度圖 | 開 | 關閉＝強制隱藏熱度圖 |
| 允許動物圖標 | 開 | 關閉＝所有玩家的動物圖標失效 |
| 動物圖標顯示距離（格） | 0＝不限制 | N＞0＝僅顯示距玩家 N 格（約 1 公尺/格）內的項目；二維直線距離（不含樓層），管理員套用後即時生效 |
| 牲畜圖標可見性 | 隱藏其他安全屋內的牲畜 | 全部顯示／隱藏其他安全屋內的牲畜（安全屋外仍顯示）／僅顯示我方安全屋內的牲畜（安全屋外也隱藏）／全部隱藏；野生動物不受影響 |
| 允許載具圖標 | 開 | 關閉＝所有玩家的載具圖標失效 |
| 載具圖標顯示距離（格） | 0＝不限制 | N＞0＝僅顯示距玩家 N 格（約 1 公尺/格）內的項目；二維直線距離（不含樓層），管理員套用後即時生效 |
| 安全屋範圍顯示 | 全部 | 關閉／僅自己的／全部——PVP 伺服器可設「僅自己的」防基地位置洩漏 |
| 安全屋範圍顯示距離（格） | 0＝不限制 | N＞0＝僅顯示距玩家 N 格（約 1 公尺/格）內的範圍框線；二維最近點距離（不含樓層），不影響牲畜歸屬/隱私判定，管理員套用後即時生效 |
| 允許陣營目標分享 | 開 | 關閉＝伺服器直接拒收分享請求（客戶端選單同步隱藏） |

未設定時沿用表中預設值；單機中牲畜可見性的前 3 檔皆為全部顯示，第 4 檔仍會全部隱藏。
動物沒有持久化的玩家主人資料；「我方安全屋」是指玩家為屋主或受邀成員，並依動物目前位置判定。
可見性與距離閘門僅提供誠實客戶端的顯示政策；已同步到客戶端的實體資料不會因此消失，並非防作弊機制。

## 架構：主 MOD + 地圖包 addon + 第三方相容路徑

主 MOD 只帶基底全圖與所有邏輯；**地圖 MOD 的圖資由「地圖包 addon」提供**——
獨立 MOD（`require=` 本 MOD）在自己的 `media/minimap/` 放 pyramid zip
（**檔名＝地圖原名**，pzmap Studio 預設輸出名，渲染完免改名），client lua 呼叫
`MinidoracatMiniMapAPI.registerMaps(自身 mod ID, 條目清單)` 註冊——基底永遠掛載，
地圖 MOD 的圖僅該 MOD 啟用時掛載（沒裝該地圖，畫它的圖＝錯）；一 mod 多地圖
（SecretZ 12 據點類）的條目可另指定 `mapDir`，MP 伺服器 `Map=` 未載入該目錄就不畫
（拿不到清單時 fail-open 回退 mod ID 閘門）：

```
主 MOD                          地圖包 addon（官方包/任何人可做）    第三方地圖 MOD（零 Lua 相容路徑）
MinidoracatMiniMapFor42/        MinidoracatMiniMapModMapsFor42/    SomeMapMod/
└── media/                      ├── mod.info（require=主 MOD）      └── media/minimap/
    ├── lua/client/             └── media/                             └── minidoracat_minimap.pyramid.zip
    │   └── MinidoracatMiniMap.lua  ├── lua/client/<註冊呼叫>.lua          （約定同名 zip，自動掃描掛載）
    │       （registerMaps API）    └── minimap/<地圖名>.pyramid.zip × N
    └── minimap/
        └── Muldraugh_KY.pyramid.zip（基底，永遠掛載）

                    ┌──────────────────────────────────────────────┐
 世界地圖開啟時      │ hook ISWorldMap:initDataAndStyle（初建）      │
 （＋樣式重建後）    │ ＋ ShowWorldMap／MapUtils.overlayPaper 補掛   │
                    └────────────────┬─────────────────────────────┘
                                     │ (1)  基底 MAPS
                                     │ (1b) 已註冊地圖包：已啟用地圖 MOD 的 zip
                                     │      （「顯示 MOD 地圖區塊」選項可關）
                                     │ (2)  相容路徑：掃描 getActivatedMods() 的約定同名 zip
                                     ▼
                    mapAPI:addImagePyramid(絕對路徑) × N
                                     │
                                     ▼
                    每個「檔名」一個 Pyramid 樣式層（fileName 尾綴匹配；
                    多層並存是引擎原生支援，原版即有 forest.pyramid.zip 獨立樣式層）
                    疊在原版樣式之上；addon 層後建，畫在基底之上
                    （引擎對層列「正序」繪製、新層 append 到尾——後建的層在上）
```

- **一個樣式層只綁一個檔名**：引擎以 `endsWith(File.separator + fileName)` 匹配已掛載 zip，
  loader 對每個檔名動態建一層；同名多 zip（相容路徑的多個 addon）由同一層全數匹配。
- **每顆 zip 自帶 bounds**（`pyramid.txt` 內世界 square 座標），引擎自動對位，無需檔名編碼座標。
- **地圖包專屬功能**（裝了地圖包才出現選項）：MOD 地圖範圍框線＋名稱（四語翻譯、
  五色可選、三檔透明度）、MOD 地圖區塊顯示開關。
- **發佈準則**：常用地圖進官方地圖包；大型地圖（pyramid zip 動輒數百 MB）建議獨立
  地圖包或第三方相容路徑分開發佈，避免只玩部分地圖的玩家被迫下載全部。
- 效能由引擎處理：LRU 紋理快取、多層級 LOD、非同步載入（相對 B41 per-cell 紋理方案）。

## 第三方動物相容 API

獨立相容包可在 client Lua 載入時登記已確認的 `IsoAnimal` group：

```lua
MinidoracatMiniMapAPI.registerAnimalGroup(
    "相容包自身 mod ID",
    "dog",
    "UI_相容包的翻譯鍵",
    "media/ui/相容包/map_dog.png",       -- 可省略；符號風格，預設原版爪印
    "media/textures/Item_相容包_Dog.png" -- 可省略；彩色圖風格
)
```

- 呼叫端 `mod.info` 必須 `require=MinidoracatMiniMapFor42`，確保 API 已載入。
- API 只追加物種篩選資料與可選素材路徑；未提供符號時使用遊戲原版爪印，未提供或無法載入彩圖時回退符號。
- 自訂圖檔應由相容包自行提供；API 不接受 callback、不讀第三方私有狀態，也不要求重包上游 MOD 素材。
- `group` 必須是非空單一 token，不可含逗號，也不可覆蓋內建或其他相容包已註冊的 group。
- 包含素材路徑在內完全相同的重複註冊是冪等成功；衝突與非法輸入回傳 `false` 並留下 log。
- 官方第三方相容項目集中在
  [MinidoracatMiniMapCompatFor42](../MinidoracatMiniMapCompatFor42)，避免主 MOD 綁定各家 MOD。

## MOD 資訊

| 項目 | 值 |
|------|-----|
| **Mod ID** | `MinidoracatMiniMapFor42` |
| **支援版本** | Build 42.20.0+ |

## 專案結構

```
MinidoracatMiniMapFor42/
├── link_workshop.bat              # Workshop 符號連結管理（雙擊啟動）
├── PZ_Test.bat                    # PZ 本地測試啟動器（雙擊啟動）
├── scripts/
│   ├── build_pyramids.ps1      # 產生基底 pyramid zip（呼叫 pzmap render-minimap）
│   ├── link_workshop.ps1       # 符號連結管理腳本（PowerShell）
│   └── PZ_Test.ps1             # 遊戲測試啟動器（PowerShell）
├── STEAM_DESCRIPTION.md           # Steam 商店頁描述（中文）——改動時必同步 _EN / _JP 版
└── MOD/MinidoracatMiniMapFor42/   # Workshop 上傳根目錄
    └── Contents/mods/MinidoracatMiniMapFor42/42/  ← PZ 模組根目錄
        ├── mod.info
        └── media/
            ├── lua/client/MinidoracatMiniMap.lua
            └── minimap/           # pyramid zip 集合目錄（產物不進版控）
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

支援新地圖（進地圖包 addon）：pzmap Studio（GUI）選該地圖 →「遊戲內小地圖」模式輸出
`<地圖名>.pyramid.zip`（預設輸出名，免改名）放進
[MinidoracatMiniMapModMapsFor42](../MinidoracatMiniMapModMapsFor42) 的 `media/minimap/`，
並在其註冊清單（`MinidoracatMiniMapModMaps.lua`）加一行對應該地圖 mod ID。
第三方 MOD 自帶支援（不進地圖包）：輸出改名為約定檔名 `minidoracat_minimap.pyramid.zip`
放進**該 MOD 自己的** `media/minimap/`，零 Lua。

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
[MinidoracatMiniMap] 圖層就緒（新增 X／共 N 個 pyramid zip）
```

> 只在真正新增圖層時輸出——後續開圖／樣式重建的冪等補掛不刷 log。

### 卸載

`link_workshop.bat` → **[2] 卸載**（只移除連結，不刪原始檔案）。

## 授權

程式碼以 [MIT License](LICENSE) 釋出。地圖渲染產物（pyramid.zip）不進版控；
其內容衍生自 Project Zomboid 遊戲資產與各地圖 MOD，僅於 Steam Workshop 依
The Indie Stone 政策發佈。

## 問題回報 & 交流

- [Discord 伺服器](https://discord.gg/Gur2V67)
- [Twitch 直播頻道](https://www.twitch.tv/minidoracat)
