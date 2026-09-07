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

> **必要前置 MOD（0.20.0 起）**：本 MOD 的視窗外觀改由家族共用介面函式庫提供，
> 需一併訂閱 [Minidoracat UI Library for B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701)
> （`require=MinidoracatUIFor42`）。只更新本 MOD 而未訂閱該函式庫會導致本 MOD 不載入。

## 功能

- **世界地圖 / 角落小地圖圖片化**：ImagePyramid 疊加層，自動掛載基底與 addon 地圖 zip；
  「圖片化地圖」總開關可切回原版向量樣式（圖標等其他功能照常）
- **保留探索迷霧**：開啟沙盒「開始時全部已知」後，未到訪區域仍有薄霧、走過之處正常顯示；
  單機沿用原版，多人另補正全圖已知與探索資料晚到的情況，不清除已到訪紀錄
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
- **內建資源點（POI，0.8.0+）**：原版地圖 1669 筆資源點、20 類（軍事／警察／槍店／醫療／
  藥局／消防／圖書／學校／超市／加油站／五金／戶外／監獄／倉儲／電器行／教堂／
  農場／工業／零售／餐飲，各配可辨識色），
  裝本體即見；預設圖標模式（染色剪影，可切全彩），另有半透明區塊模式（暗色描邊
  取代框線；預設「整棟範圍」畫整棟建築外框，可切逐房間）；統一視窗
  「資源點」小節逐類勾選（列首帶類別小圖）＋全選／全不選，齒輪面板快速開關；
  ESC 選項頁獨立「資源點（POI）」群組；地下室設施（B42 basement，如民宅地下
  酒吧、地下軍火庫）圖標帶「↓」角標、搜尋結果標「（地下室）」——地上建築可能是別的
- **世界地圖圖標**（預設關）：殭屍點位／野生動物／畜養動物／載具四個獨立開關，
  在世界地圖（M）顯示同款圖標；風格、顏色與篩選跟隨小地圖設定；世界地圖按鈕列
  新增爪印按鈕直開設定視窗
- **導航目標＋沿道路路線**：右鍵雙地圖設目標——自動沿實際道路計算青色路線
  （偏離約 12 格自動重算；深野外目標導到最近道路、末段直線；完全無路資料至少
  畫直線方向線），金旗＋邊緣箭頭＋距離讀數，抵達自動清除；陣營分享後隊友端
  也各自算路顯示（詳見下方「導航目標」段）
  路網會套用 42.20.4 全圖稽核後的逐段路面資料：有合理替代時小幅偏好鋪裝道路，
  只有碎石路／土路時仍照常可達；離線候選未經人工確認不會自動加入導航。
- **地圖搜尋**：小地圖與世界地圖按鈕列放大鏡鈕、雙地圖右鍵「搜尋地圖…」——
  輸入自動判別座標（`12895,3499` 等格式）／街道名（**中英雙語可搜**，英文原名
  隨 MOD 內建對照表）／設施類別（20 類），結果依距離排序；可跳大地圖（金色
  脈動標記 12 秒）或直接設為導航目標
- **地圖顯示設定視窗**（齒輪鈕）：左側依地圖內容分類導覽，右側只顯示目前分類的設定；
  可直接搜尋跨分類選項，空白搜尋仍能完整瀏覽。預設視窗比舊版寬高更充足，寬螢幕使用
  導覽＋檢查器雙 pane，分割畫面或大字型自動降為單 pane；搜尋框不會搶走 WASD 焦點。
  標題列採較大字型並連動放大閉鎖／開鎖與關閉圖示，鎖定狀態仍保留琥珀／灰色差異；開關、
  滑條亦採共用 UI framework 的現代化 painter。資源與動物
  分類導覽列提供主開關，所有分類皆不顯示數量摘要。每個可設定分類右下皆可一鍵恢復該分類
  預設值。支援 addon 動態註冊，例如 [AutoDrive](https://steamcommunity.com/sharedfiles/filedetails/?id=3792675881) 的「自動駕駛」
  與其 MOD Options 共用設定；Zones addon 另有依 zones.json 動態生成的「自訂區域」
  分類，可獨立關閉文字名稱而保留色塊／框線／圖標。所有設定即時套用並存檔，
  與 ESC 選項頁雙向同步。
- **穿透模式（Ghost Mode）**：點擊、滾輪、右鍵點擊全部穿透小地圖直達遊戲世界，
  地圖本體與外框自動變半透明＋琥珀邊框提示——把地圖拉大當常駐畫面也不擋操作、不擋視線。
  快捷鍵 `'`（可改）、浮動圖標右鍵、或設定面皆可切換，狀態跨重啟保留；
  分割畫面下對所有玩家生效
- **玩家座標顯示與一鍵複製**：小地圖與世界地圖（M）底部置中顯示自己座標 x, y, z
  （可關，同一開關管兩面）；按鈕列複製圖示一鍵複製 `x,y,z` 到剪貼簿、小地圖與世界地圖
  右鍵選單「複製此處座標」複製指向位置（`x,y,0`），貼上即用於 `/teleportto` 等指令；
  複製成功顯示 1.5 秒「已複製！」
- **按鈕列**：M（世界地圖）、-／+（縮放）、◇（視角切換：等軸測／俯視，與地圖顯示
  設定的「等軸測」勾選即時同步）、定位玩家圖示、複製座標圖示、放大鏡（地圖搜尋）、
  齒輪（地圖顯示設定）、X（關閉）；定位與複製採共用 UI framework 程序化 icon，
  框架缺席時退回 C／XY，功能不受影響；按鈕動態間距，最小尺寸也裝得下；
  世界地圖按鈕列另有放大鏡＋爪印（地圖顯示設定）
- **HUD 微調**：滑鼠懸停時小地圖邊框微亮（0.4→0.55），縮放熱區顯示 HUD 角落括號
- **玩家座標匯出**（伺服器管理用，預設關閉）：沙盒開啟後伺服器每 N 秒把在線玩家
  即時座標與離線玩家最後座標寫成 `players_<存檔名>.json`，供地圖區塊重置工具在
  清除區域前判斷該處有無玩家（見下方「外部工具介接」）
- **家族圓角深色 UI**：搜尋視窗、統一設定視窗與小地圖整框（卡片式外框＋標題列
  ＋底部按鈕列）同一套圓角皮膚語彙（與公告板 MOD 同源）；皮膚貼圖缺失時
  自動退回原版直角樣式，功能不受影響

## 截圖

### 繁體中文

| | |
|---|---|
| ![統一設定視窗（圓角皮膚）](docs/screenshots/zh/01-settings-window.png) | ![小地圖圓角卡片外框](docs/screenshots/zh/02-minimap-frame.png) |
| ![小地圖右鍵選單（導航／複製座標／搜尋／陣營分享）](docs/screenshots/zh/03-nav-menu.png) | ![沿道路導航路線（大地圖）](docs/screenshots/zh/04-nav-route-worldmap.png) |
| ![沿道路導航路線（小地圖）](docs/screenshots/zh/05-nav-route-minimap.png) | ![分享目標的隊友路線](docs/screenshots/zh/06-nav-route-shared.png) |
| ![地圖搜尋：中文街名](docs/screenshots/zh/07-search-street.png) | ![地圖搜尋：地下室條目](docs/screenshots/zh/08-search-basement.png) |
| ![管理員沙盒選項](docs/screenshots/zh/09-admin-sandbox-options.png) | |

### English

| | |
|---|---|
| ![Settings: Layers](docs/screenshots/en/01-settings-layers.png) | ![Settings: Animal icons](docs/screenshots/en/02-settings-animal-icons.png) |
| ![Mini-map context menu](docs/screenshots/en/03-nav-menu.png) | ![World map key & symbols](docs/screenshots/en/04-worldmap-key-symbols.png) |
| ![Map search: street names](docs/screenshots/en/05-search-street.png) | ![Admin sandbox options](docs/screenshots/en/06-admin-sandbox-options.png) |

Steam Workshop 用 JPG（≤2MB）在 `docs/screenshots/steam/{zh,en}/`，編號與上表一致。

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
| 顯示動物名稱／名稱顯示距離 | 關／不限 | 圖標下方標「種類（公／母）」（自訂名優先）；距離 0＝不限，N＞0 只在 N 格內標名 |
| 動物圖標風格／大小／透明度 | 地圖符號／16px／100% | 風格：原版地圖符號（可染色）或彩色物品圖；大小與透明度滑條（8-48px／10-100%）；載具另有獨立大小/透明度滑條 |
| 野生動物顏色／畜養動物顏色／載具圖標顏色 | 綠／白／天藍 | 色盲友善 8 色（白/綠/橘/天藍/黃/紫紅/藍/硃紅） |
| 顯示載具圖標 | 關 | 方向盤圖標顯示可視範圍內載具；統一視窗可按一般/重型/性能/特勤（警燈車）類別篩選 |
| 世界地圖：殭屍點位／野生動物／畜養動物／載具 | 關 ×4 | 世界地圖（M）的圖標開關（設定視窗「世界地圖圖標」區段）；風格、顏色與篩選跟隨小地圖設定 |
| 隱藏物種清單／隱藏載具類別（進階） | 空 | 由統一設定視窗的篩選勾選自動寫入（CSV 停用清單），一般不需手動編輯 |
| 顯示街名 | 開 | 沿道路顯示街名——原版小地圖**從不載入街道資料**（只有世界地圖有），本 MOD 補載；中文街名翻譯 MOD 同步生效 |
| 導航路線（沿道路） | 開 | 右鍵設定導航目標後自動沿道路計算路線畫在雙地圖；關閉退回純旗標／直線指示（詳見下方「導航目標與路線」段） |
| 顯示安全屋範圍／圖標／名稱 | 開／開／開 | 獨立「安全屋」分類：範圍框（等軸測下正確描邊）、範圍中心房屋圖標、安全屋名稱（掛圖標下方）。自己所屬＝綠、同陣營屋主＝青、其他玩家＝紅；範圍框與圖標共用伺服器「安全屋範圍顯示」模式與距離，名稱走獨立「安全屋名稱顯示」模式與距離，分類內另有兩條距離滑條 |
| 外框不透明度 | 原版 | 外框與按鈕列底色透明度三檔（地圖本體為 GPU 直繪，無法整體半透明） |
| 鎖定小地圖 | 關 | 鎖定後標題列拖曳移動與邊緣拖曳縮放皆停用，防止誤觸 |
| 拖曳自由查看 | 開 | 拖動小地圖後**停留在該處**（原版放開即回中），點一下小地圖回到玩家；拖離期間地圖底部顯示「點擊地圖回到玩家」提示、定位玩家圖示轉琥珀 |
| 顯示玩家座標 | 開 | 小地圖與世界地圖（M）底部置中顯示自己 x, y, z；複製座標圖示與右鍵「複製此處座標」**不受此開關影響**，複製成功顯示 1.5 秒琥珀提示 |
| 穿透模式 | 關 | 點擊/滾輪/右鍵點擊穿透到遊戲世界＋地圖半透明＋外框變淡＋琥珀邊框；未探索霧區同步依滑條暗化（引擎著色器不支援霧區真透明，暗景視覺等效）；快捷鍵 `'` 或浮動圖標右鍵亦可切換；穿透中小地圖按鈕列收合，退出走熱鍵/浮動圖標右鍵/ESC 選項頁（三層防鎖死） |
| 顯示地名 | 開 | 城鎮與區域名稱（開啟時自動連帶開啟「符號」）；**角落小地圖預設看不到文字**——需同時開啟下方「文字註記」實驗選項，世界地圖（M）則不受限 |
| 小地圖文字註記（實驗性） | 關 | 原版小地圖固定精簡符號模式、文字註記一律不畫；開啟改用完整模式讓地名等文字可顯示，玩家自畫標記會以完整大小呈現 |
| 點擊小地圖開啟世界地圖 | 關 | 原版點一下小地圖會開世界地圖；預設關閉保留點擊給未來互動，M 鍵／M 鈕不受影響 |

**導航目標與路線**：右鍵小地圖或世界地圖（M）→ 「設定導航目標」。設定後自動
沿實際道路計算路線，以青色線畫在雙地圖上（目標旗標之下）：偏離路線約 12 格
自動重新規劃；目標離路網很遠（軍事基地等深野外）時導到最近道路點、末段以直線
接目標；完全無街道資料時至少畫玩家→目標直線方向線。目標在視窗內顯示金旗、
超出視窗時沿邊緣顯示方向箭頭與直線距離；走到目標 5 格內自動抵達清除；目標隨
角色存檔保留。「導航路線（沿道路）」開關預設開，關閉退回純旗標指示。
路線內部同時保留逐段道路寬度與 `paved`／`gravel`／`dirt`／`unknown` 路面分類；
路面分類供導航成本使用，寬度則作為相容 addon 的逐段 metadata。route 另帶
`snapDist`（出發點到路線起點需越野的格數），供導航 addon 判斷路線可用性。
舊版 route 欄位與查詢方式維持相容。
自 0.26.1 起，街道資料尚未就緒不會讓導航永久失敗：設有導航目標或開著搜尋視窗時，
會以每份地圖每秒一次的頻率重試取得街道資料；世界地圖每次開啟亦會檢查是否需要補載。
已有街道資料不重載。搜尋會使用重建後的現行地圖，資料可用後自動更新結果；
沒有道路資料的地圖仍只能提供直線方向指示。
裝了第三方「統一中文漢化（B42Trans_CN）」的多人伺服器：該漢化的街道載入方式在多人客戶端
會載到零條（0.26.2 起本 MOD 自動補上——繁中／簡中介面載它的中文街名，其他介面語言載官方
英文街名），不需要改裝本作者的翻譯包；console 會留一行 `carrier fallback` 供支援判讀。
加入陣營（faction）後右鍵選單多「分享目標給陣營」——同陣營成員的雙地圖會以
青旗＋名字（作者專屬色）顯示你的目標並各自本地算路（由伺服器過濾轉送，
非同陣營玩家收不到）。右鍵選單另有「複製此處座標」與「搜尋地圖…」。

以上設定**遊戲內按小地圖齒輪鈕（統一設定視窗）即可直接調整**，改動即時生效並存檔；
ESC 選項頁按「接受」亦同步。設定存於 `%UserProfile%\Zomboid\Lua\ModOptions.ini`（引擎管理）。

**語言支援**：繁體中文（CH）、简体中文（CN）、English（EN）、日本語（JP），
四語鍵完全同步；其他語言回退英文。

## 伺服器管理（沙盒選項）

沙盒設定新增「Minidoracat 小地圖」五個分頁（一般／圖標／區域／安全屋／匯出；伺服器建立時設定，
或管理員面板 → 沙盒設定即時調整，**客戶端每幀讀值、改動即時生效**）：

| 沙盒選項 | 預設 | 說明 |
|----------|------|------|
| 一般：【全域】全部資訊顯示距離上限（格） | 0＝不限制 | 最優先生效：殭屍/動物/載具/安全屋/資源點/自訂區域六類距離的全域上限；個別距離選項只能設得更嚴（兩者取較小），不能放寬 |
| 一般：允許陣營目標分享 | 開 | 關閉＝伺服器直接拒收分享請求（客戶端選單同步隱藏） |
| 一般：允許管理員戰術檢視旁路 | 關 | 開啟後，具備「看見全部」（CanSeeAll）權限的管理員可自行開啟「戰術檢視」，暫時忽略殭屍點位／熱度圖／動物／載具四個開關，以及殭屍／動物／載具／資源點／自訂區域的顯示距離與全域距離上限 |
| 一般：允許管理員隱私檢視旁路 | 關 | 需與上一項同時開啟才有作用。開啟後管理員可在戰術檢視之上再加開「隱私檢視」，暫時忽略安全屋範圍／名稱顯示與其距離限制、牲畜圖標可見性 |
| 圖標：允許即時殭屍點位 | 開 | 關閉＝所有玩家的殭屍點位失效（避免情報優勢） |
| 圖標：殭屍點位顯示距離（格） | 0＝不限制 | N＞0＝僅顯示距玩家 N 格（約 1 公尺/格）內的項目；二維直線距離（不含樓層），管理員套用後即時生效 |
| 圖標：允許殭屍熱度圖 | 開 | 關閉＝強制隱藏熱度圖 |
| 圖標：允許動物圖標 | 開 | 關閉＝所有玩家的動物圖標失效 |
| 圖標：動物圖標顯示距離（格） | 0＝不限制 | N＞0＝僅顯示距玩家 N 格（約 1 公尺/格）內的項目；二維直線距離（不含樓層），管理員套用後即時生效 |
| 圖標：牲畜圖標可見性 | 隱藏其他安全屋內的牲畜 | 全部顯示／隱藏其他安全屋內的牲畜（安全屋外仍顯示）／僅顯示我方安全屋內的牲畜（安全屋外也隱藏）／全部隱藏；野生動物不受影響 |
| 圖標：允許載具圖標 | 開 | 關閉＝所有玩家的載具圖標失效 |
| 圖標：載具圖標顯示距離（格） | 0＝不限制 | N＞0＝僅顯示距玩家 N 格（約 1 公尺/格）內的項目；二維直線距離（不含樓層），管理員套用後即時生效 |
| 區域：資源點（POI）顯示距離（格） | 0＝不限制 | N＞0＝資源點區域（顯示中的分類房間）最近點距玩家 N 格內才顯示（區塊、名稱、圖標一併隱藏）；建議 300＝約一個街區群，保留探索感；僅影響內建資源點，地圖包範圍框線不受影響 |
| 區域：自訂區域顯示距離（格） | 0＝不限制 | N＞0＝自訂區域（zone 圖層 addon，如伺服器推送的區域）最近點距玩家 N 格內才顯示（色塊、框線、名稱、圖標一併隱藏）；僅影響自訂區域圖層，資源點與地圖包範圍框線不受影響 |
| 安全屋：安全屋範圍顯示 | 全部 | 關閉／僅自己的／全部／自己與陣營（屋主為同陣營成員）——控制範圍框與圖標；PVP 伺服器可設「僅自己的」或「自己與陣營」防基地位置洩漏。「自己與陣營」為後加第 4 檔，舊存檔的「全部」值不變 |
| 安全屋：安全屋範圍顯示距離（格） | 0＝不限制 | N＞0＝僅顯示距玩家 N 格（約 1 公尺/格）內的範圍框與圖標；二維最近點距離（不含樓層），不影響牲畜歸屬/隱私判定，管理員套用後即時生效 |
| 安全屋：安全屋名稱顯示 | 全部 | 關閉／僅自己的／全部／自己與陣營——控制安全屋名稱（安全屋標題），與範圍顯示獨立 |
| 安全屋：安全屋名稱顯示距離（格） | 0＝不限制 | N＞0＝安全屋最近點距玩家 N 格內才顯示名稱；與範圍顯示距離獨立 |
| 匯出：匯出玩家座標檔（外部工具） | 關 | 開啟＝伺服器每 N 秒把玩家座標寫成 `players_<存檔名>.json`（見下方「外部工具介接」）；一般伺服器不需要，開啟後玩家座標會落地成檔案 |
| 匯出：玩家座標匯出週期（秒） | 5 | 1–300 秒；僅在上一項開啟時有作用，改小也立即生效 |
| 匯出：一併匯出離線玩家最後座標 | 開 | 關閉＝只匯出在線玩家。離線座標用於避開「有玩家在裡面登出」的區域——那些角色下次上線仍在原地 |

表列順序＝沙盒各分頁實際顯示順序。沙盒選項的共通版面／分組 metadata 只有 `page` 與
`translation` 兩項（`CustomSandboxOption.parseCommon`；型別自有的 `min`/`max`/
`default`/`numValues` 由各子類解析）：`page` 只是分頁字串（翻譯鍵 `Sandbox_<page>`），
同一分頁內沒有標題或分隔線可用，是依定義順序渲染的扁平清單——因此
`sandbox-options.txt` 的分頁歸屬＋排列就是全部分組手段（分頁依首個選項出現順序排列，
ServerSettingsScreen.lua:5134-5142）。調整分頁或順序不影響既有存檔：沙盒值以選項名存取
（`SandboxVars.lua` 為巢狀名稱表、`SandboxOptions.lua` 走 `option:getName()`），
enum 值域只由各自的 `numValues` 決定，`VERSION` 是 parser 格式版本、不因重排而變動。

未設定時沿用表中預設值；單機中牲畜可見性的前 3 檔皆為全部顯示，第 4 檔仍會全部隱藏。
動物沒有持久化的玩家主人資料；「我方安全屋」是指玩家為屋主或受邀成員，並依動物目前位置判定。
可見性與距離閘門僅提供誠實客戶端的顯示政策；已同步到客戶端的實體資料不會因此消失，並非防作弊機制。

玩家端另有統一設定視窗「顯示距離」區：四類距離各一滑條（0＝不限；裝 Zones 等
區域 addon 時另有「自訂區域顯示距離」，共五條；安全屋範圍／名稱兩條在「安全屋」分類）；各功能的效能等級與對策見
地圖顯示設定的「效能說明」分類（含 GameProfiler 實測錨點）。**伺服器有設限時
數值標顯示「你的設定／伺服器上限」**（例：`200/300`；自己設 0 則顯示 `不限/300`），
玩家不必從滑條軌道長度反推就知道還能拉到多少；兩值取較小者生效——只能收緊自己的
視野、不能放寬伺服器限制。滑條可拉上限＝伺服器允許範圍與 2000 取小，但既有存值超過
上限時滑條讓位顯示存值、不截斷偏好；管理員在視窗開啟期間調整沙盒 gate／距離上限時，
地圖顯示設定會偵測有效值變化並即時重建數值標與軌道。ESC 選項頁有同一組滑條
（獨立「顯示距離」群組、恆為全值域 0–2000），兩處寫同一設定值。

### 管理員檢視旁路（三把鑰匙）

兩個管理員選項都**預設關閉**，且旁路要三個條件同時成立才生效（少任何一把都不旁路）：

1. **伺服器主人開放**：對應的沙盒選項為開；
2. **引擎權限**：該玩家的 Role 具備 `CanSeeAll`——採 B42 的 Role＋Capability 判定，
   不看已 deprecated 的 `isAdmin()`／`getAccessLevel()`，自訂 Role 一樣適用；
3. **管理員自己打開**：在地圖顯示設定的「管理員檢視」分類勾選。該分類**只有同時具備
   `CanSeeAll` 與伺服器戰術權限的玩家才看得到**，其他玩家連分類都不會出現。

勾選狀態只存在 Policy facade 的本機私有 slot table，逐分割畫面 slot 獨立，不寫角色
modData、不同步伺服器；建立玩家、離線或重連時回到關閉（fail-closed）。伺服器收回權限
或關掉沙盒選項時，開著的設定視窗會即時
把分類收掉、勾選彈回實際值。

**戰術層與隱私層是分開的兩把鑰匙。** 戰術層（殭屍點位、殭屍熱度圖、動物圖標、載具圖標，
以及殭屍／動物／載具／資源點／自訂區域的顯示距離與全域距離上限）是「看敵情」，不涉及
他人隱私；隱私層（安全屋範圍顯示與其距離限制、牲畜圖標可見性）會看到其他玩家刻意藏起來
的東西，故需要第二個沙盒選項＋第二個勾選，且**依賴**戰術層——關掉戰術檢視會連帶把隱私
檢視一併關掉。「允許陣營目標分享」與玩家座標匯出**永遠不旁路**：那是通訊與 I/O 政策，
不是檢視政策。

旁路生效期間，小地圖與世界地圖左上角常駐「管理員檢視」（英文介面 `ADMIN VIEW`）標記，
避免管理員忘記自己開著看穿模式。**顯示距離滑條仍然只能收緊**：旁路解除的是伺服器上限，
玩家自己在「顯示距離」區設的值照樣生效。

旁路只改變「這台客戶端畫什麼」，不會改動任何全服沙盒值，**也不是防作弊機制**；伺服器端
真正需要權威的兩件事（導航轉送、座標匯出）讀的是未旁路的全服政策。

## 外部工具介接

### poi_blocks.json（資源點區塊，啟動時寫一次）

啟動時（單機進世界／伺服器啟動）自動把內建資源點資料匯出成
`Zomboid/Lua/MinidoracatMiniMap/poi_blocks.json`（需遊戲 42.20.1+，`.json` 寫入白名單
解禁版本；`versionMin` 已同步），供外部程式（如建築重置工具）讀取
「地圖上實際顯示的資源點區塊」——與 Zones addon 的
`Zomboid/Lua/MinidoracatMiniMapZones/zones.json` 同根，工具端一個根目錄讀兩份。

格式 v1：`{"v":1,"modversion":"…","count":N,"categories":{"<分類>":[{"b":[x,y,w,h],"u":1,"r":[[x,y,w,h],…]},…]}}`
——世界 square 座標（x/y 左上、w/h 尺寸，涵蓋 tiles `[x, x+w-1]`）；`b`＝整棟建築外框、
`u`＝1 時為地下條目（B42 basement，主分類房的主樓層在地下；選配欄、僅地下時輸出，
additive 擴充——工具端忽略未知鍵即可）、`r`＝該分類觸發房矩形（面積大→小，`r[1]` 為
圖標錨點）；`modversion`＝寫檔當下的 MOD 版本（新鮮度標記）。每次啟動整檔覆寫，
內容隨 MOD 版本自動同步；MP 純客戶端不寫。

**工具端義務**（座標會被拿去刪存檔 chunk，讀壞資料＝刪錯區域）：整檔嚴格 JSON 解析
（失敗＝視同不存在，勿逐行流式取用）；各分類條目總數須等於 `count`；破壞性操作前驗
`modversion` 等於實際安裝版本（寫檔失敗時舊檔會殘留）；容忍檔案不存在。完整契約見
`shared/MinidoracatMiniMapPOIExport.lua` 檔頭，離線測試 `scripts/test_poi_export.lua`。

### `players_<存檔名>.json`（玩家座標，沙盒開啟才寫）

沙盒「匯出玩家座標檔」開啟後，伺服器（含單機）每 N 秒（預設 5）覆寫
`Zomboid/Lua/MinidoracatMiniMap/players_<存檔名>.json`（存檔名＝多人的伺服器名／
單機的存檔資料夾名——`Zomboid/Lua` 是全域目錄不隨存檔，檔名綁存檔名才不會兩個
世界互相覆寫）。用途：地圖區塊重置工具在清除一塊地之前判斷「那裡現在有沒有人、
有沒有人在裡面登出」，必要時先把人踢下線。

**兩份清單的證明力完全不同**，這是本檔最重要的契約：

- **`"online":true` 的筆＝完整**（來源 `getOnlinePlayers()` 是引擎權威在線清單，
  掃遍所有連線的所有分割畫面 slot）。**可以**用它證明「此刻沒有在線玩家在這塊地」。
  這條保證由「無損轉義 ＋ 不可表示就整輪拒寫」維持：任何一個在線玩家無法被無損
  寫出（或出現重複 `(name, idx)`）時，本 MOD **完全不寫檔**，讓舊檔因 `ts` 過期被
  你擋下，絕不靜默略過那個人。
- **`"online":false` 的筆＝本 MOD 觀測到的子集，永遠不完整**。缺席來源至少四種：
  本 MOD 開始記錄前就登出的角色（見 `offlineSince`）、沙盒關閉離線匯出時全部缺席
  （`offlineIncluded:false`）、超過上限被裁掉的（`offlineTruncated:true`）、以及在
  最後一次觀測後才移動並登出的（誤差最多一個 `interval`）。
  **絕不可用它證明「這塊地沒有離線角色」**——只能當正向證據（清單裡有人＝真的有人）。
- 要在停機後證明某區域「沒有任何角色」，唯一權威來源是存檔的 `players.db`
  `networkPlayers` 表（斷線時由引擎寫入當下 x/y/z）。那是 SQLite、Lua 讀不到，
  只有停機中的外部工具能讀。本檔的定位是**伺服器運行中的即時資訊**（現在誰在哪、
  要踢誰），不是停機後的完整清冊。

格式 v1：

```json
{"v":1,"modversion":"…","save":"…","ts":1755400000000,"interval":5,
 "offlineAuthority":"observed-subset","offlineIncluded":true,
 "offlineSince":1755300000000,"offlineTruncated":false,
 "online":1,"count":2,"players":[
{"name":"alice","idx":0,"steamId":"76561198012345678","online":true,"x":10700,"y":9800,"z":0,"seen":1755400000000}
,{"name":"bob","idx":1,"steamId":"","online":false,"x":-5,"y":12,"z":-1,"seen":1755399000000}
]}
```

`steamId`＝Steam64（17 位字串），取不到時是空字串。**它是客戶端回報、伺服器做過
一致性檢查的值，不是伺服器權威值**：引擎沒給伺服器端取得精確 Steam64 的路
（`getSteamID()` 回 Java long，經 Kahlua 一律轉 double，該量級精度 16、末位會被
捨去；會字串化 SteamID 的引擎函式全都限定客戶端）。伺服器驗格式（17 位、≥ 個人
帳號區段起點）並把回報值與自己那個 double 比對，亂填會被擋下，但同一個 double
對應約 15-16 個相鄰 Steam64、多半也是真帳號，所以惡意客戶端仍可挑一個通過。
可用於對照／稽核／跨改名追蹤，**不可用於授權、封鎖、所有權判定**；要權威值請在
停機後讀 `players.db` 的 `networkPlayers.steamid`。

`x`/`y`＝世界 square 整數（chunk 換算 `floor(x/8)`）、`z`＝樓層；`seen`＝該座標的
觀測時刻；`name`＝username（踢人用），**無損** JSON 轉義（`\` `"` 依 JSON 規則，
控制字元寫成 `\u00xx`——引擎允許的 username 字元集比直覺寬，primary 只擋
`" \ / . ' ? ; @ $ ,` 與 NUL、長度 2-20，控制字元是合法的；coop 分屏的 secondary
更寬）；`idx`＝分割畫面 slot（0-3）。**去重鍵是 `(name, idx)`**——同一帳號同機
分屏可有多個角色分處兩地，只按 `name` 去重會直接丟掉一個真實玩家座標；出現重複的
`(name, idx)` 代表檔案不可信，請中止整份文件而不是靜默去重。注意 `(name, idx)`
**不等於** `players.db` 的持久身分（username 是各 slot 自報的 alias，DB 用主連線
username／SteamID＋world＋playerIndex），玩家改名或別人重用同一 alias 可能讓
離線觀測值張冠李戴——這由「離線只作正向證據」的契約承接。死亡玩家不列入。
`offlineAuthority` 固定 `"observed-subset"`（schema 層面宣告離線清單沒有反證力，
讀到未知值＝語意版本不同，請中止）。`offlineSince`＝離線歷史起點（早於此時刻登出
的角色不在清單中；跨重啟繼承，讀回失敗或該檔本身沒有離線筆時重設為當下）。
排序：`name` 升序、同名再 `idx` 升序，同輸入輸出逐 byte 相同。

**工具端義務**（這份資料決定「能不能刪這塊地」，比 poi_blocks 更嚴）：整檔嚴格
JSON 解析（失敗＝視同不存在）；`players` 筆數須等於 `count`、其中在線筆數須等於
`online`，去重一律用 `(name, idx)`、重複即中止；`offlineAuthority` 必須是
`"observed-subset"`；**新鮮度 fail-closed**——`now - ts` 超過 `interval` 的數倍
（建議 3×）即視為匯出已停擺（沙盒被關／MOD 被移除／伺服器已停／本 MOD 因無法完整
寫出在線清單而拒寫），此時 `online` 只代表伺服器最後一刻的狀態、不可當即時；
**上界也要驗**，`ts` 大於 `now` 加小幅時鐘偏差（建議 60 秒）＝來源時鐘異常，同樣
中止；`interval` 不在 1–300 內＝檔案不可信；`save` 須等於要操作的存檔目錄名；
離線清單不可反證（見上）；容忍檔案不存在。沙盒關閉後檔案原地凍結、**不寫空文件**
——空清單會讓工具誤判「到處都沒人」而放行刪除，比陳舊檔案更危險。完整契約見
`server/MinidoracatMiniMapPlayerExport.lua` 檔頭，離線測試
`scripts/test_player_export.lua`（198 檢查）。

MOD 也會在同一個目錄放 `_README_CH.txt` / `_README_EN.txt`（只在檔案不存在時產生，
之後不覆寫，可以在上面加自己的註記），內容是上述欄位與義務的摘要——這樣看到那堆
JSON 的人不必翻 MOD 原始碼。

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

## 第三方 client 設定分類 API

需要把 addon 的玩家端設定整合進小地圖齒輪視窗時，可在 client Lua 註冊：

```lua
local api = MinidoracatMiniMapAPI
if api and type(api.settingsApiVersion) == "number"
        and api.settingsApiVersion >= 1
        and type(api.registerSettingsSection) == "function" then
    local spec = {
        label = "UI_Addon_Settings",
        ticks = {
            { label = "UI_Addon_Show", get = getShow, set = setShow },
        },
        combos = {
            { label = "UI_Addon_Width", items = {
                "UI_Addon_Thin", "UI_Addon_Normal", "UI_Addon_Thick",
            }, default = 2, get = getWidth, set = setWidth },
        },
    }
    if api.settingsApiVersion >= 2 then
        spec.actions = {
            { label = "UI_Addon_Copy", tooltip = "UI_Addon_Copy_tip",
                run = function(playerNum) copyLatest(playerNum) end,
                enabled = function(playerNum) return hasLatest() end },
        }
    end
    api.registerSettingsSection("AddonModId", spec)
end
```

- 第一參數必須是 addon 自身 mod ID；同 ID 重複註冊會更新原分類，不會新增重複項目。
- 分類位置由 MiniMap 的響應式版面決定；addon 不指定欄位或 pane。
- `get`／`set` 是 addon callback；MiniMap 只提供 UI，不保存第二份設定。
- 導覽列只顯示分類名稱與主開關；API 不讀取、保存或計算 `summary`／數量 callback。
- 壞 spec 會在註冊期回傳 `false`，不得影響 MiniMap 其他設定。
- **v2 `actions`**（最多 16）：每項 `label`／`tooltip`／`run` 必填，`enabled` 可選。
  `run(playerNum)` 與 `enabled(playerNum)` 收到設定窗擁有者；`enabled` 回 `false` 時按鈕停用。
  執行錯誤以 pcall 隔離。超過 16 項或任一項無效時，整次註冊回傳 `false`，ticks／combos 也不更新；未傳 `actions` 的 v1 spec 完全相容。
- `enabled` 只控制按鈕可用狀態，拋錯時會 fail closed；它不是權限邊界。addon 與 MiniMap 共用 Lua VM，`run` 涉及權限或可變狀態時仍須在 callback 內重驗。

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
| **支援版本** | Build 42.20.1+ |

## 專案結構

```
MinidoracatMiniMapFor42/
├── link_workshop.bat              # Workshop 符號連結管理（雙擊啟動）
├── PZ_Test.bat                    # PZ 本地測試啟動器（雙擊啟動）
├── Publish_Workshop.bat           # Steam Workshop 發布（雙擊選單；見「發布到 Workshop」）
├── scripts/
│   ├── build_pyramids.ps1      # 產生基底 pyramid zip（呼叫 pzmap render-minimap）
│   ├── link_workshop.ps1       # 符號連結管理腳本（PowerShell）
│   ├── PZ_Test.ps1             # 遊戲測試啟動器（PowerShell）
│   ├── publish_workshop.py     # Workshop 發布工具（原生 Steamworks；內容／GIF 封面／四語簡介）
│   └── workshop_publish.json   # 發布設定（Workshop ID、擁有者、各語言簡介來源）
├── STEAM_DESCRIPTION.md           # Steam 商店頁描述（中文）——改動時必同步 _EN / _JP 版
└── MOD/MinidoracatMiniMapFor42/   # Workshop 上傳根目錄
    ├── preview.png                # 遊戲內上傳器用（APNG，256／512 正方形）
    ├── workshop/preview.gif       # Workshop 網頁動態封面（發布工具上傳；不在 Contents，不會下載給玩家）
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

### 發布到 Workshop

雙擊 `Publish_Workshop.bat`：先檢查 Steam 用戶端是否以作者帳號登入（未登入會喚起 Steam
並等你登入後重試），再選擇要更新的項目：

| 選項 | 上傳內容 | 前置檢查 |
|------|---------|---------|
| 只更新 MOD 內容 | `Contents/` ＋ `STEAM_CHANGELOG.md` 作為更新說明 | `verify_mod.py` 全數通過；更新說明版本＝`mod.info` |
| 只更新 GIF 封面 | `MOD/…/workshop/preview.gif` | GIF、≤1,024,000 bytes |
| 只更新簡介 | 英／繁／簡／日四個語言槽（來源見 `scripts/workshop_publish.json`） | 每份 ≤8000 bytes |
| 全部更新 | 以上全部（內容／封面／更新說明隨英文槽提交） | 以上全部 |

提交後會回查 Steam：內容看 `time_updated`、封面確認仍是 GIF、簡介逐語言用 ISteamUGC 取回比對，
任一不符即以非零碼結束。自動化／AI 呼叫：

```
uv run --no-project python -B scripts/publish_workshop.py --mode all --yes       # 或 content / preview / description
uv run --no-project python -B scripts/publish_workshop.py --mode all --dry-run   # 只檢查、顯示計畫
```

退出碼：`0` 成功／`2` 參數或取消／`3` 未登入、帳號不是擁有者／`4` 前置檢查失敗／`5` 提交失敗／`6` 已提交但回查不符。
非互動模式下未登入直接以 exit 3 結束，不會停在密碼提示；`--dry-run` 一樣會先做登入檢查。
簡中槽目前沿用繁中檔（`workshop_publish.json` 的 `descriptions`）。`steam_api64.dll` 預設取 PZ 安裝目錄，
可用環境變數 `PUBLISH_STEAM_API_DLL` 覆寫。

不再使用 SteamCMD：它只能寫英文簡介槽，且遊戲內上傳器每次會把網頁封面覆回靜態 `preview.png`；
改用本工具即可保留 GIF 封面。

## 授權

程式碼以 [MIT License](LICENSE) 釋出。地圖渲染產物（pyramid.zip）不進版控；
其內容衍生自 Project Zomboid 遊戲資產與各地圖 MOD，僅於 Steam Workshop 依
The Indie Stone 政策發佈。

## 問題回報 & 交流

- [Discord 伺服器](https://discord.gg/Gur2V67)
- [Twitch 直播頻道](https://www.twitch.tv/minidoracat)
