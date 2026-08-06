# Changelog

## [42.20.0-0.12.1] - 2026-08-06

### 修正

- **公寓誤標倉儲根治（POI 房間級重做）**：玩家回報 (10078,12631) 公寓大樓
  因 64 格住戶儲物間（佔房間面積 0.8%）被標倉儲。資料管線升級為逐房間
  幾何（pzmap poi v2 重擷 .lotheader 逐房座標），「附屬型」觸發房（倉儲／
  監獄／學校儲存家族、體育器材室等）面積佔比 <10% 不得冒充建築身分——
  對 0.12.0 基準 23 棟歸屬變更：14 棟噪音退場（7 公寓倉儲、5 場館戶外、
  監獄外圍場地棟等）、9 棟改判真實身分（Louisville 商場→藥局、保齡球館→
  餐飲、3 棟高中拿回學校圖標——school 並補 secondaryclassroom 等 3 鍵）。
  1720→1704 筆；同棟地下室/地面層雙紀錄先合併再分類，不再產生跨樓層雙圖標。

### 新功能

- **圖標錨定實際房間**：圖標從整棟外框中心移到主身分房間位置（商場藥局
  釘在場內藥局、公寓一樓店面釘在店面，約 1/3 條目受益）；區塊模式顯示
  主樓層房間平面（相鄰房間合併成塊、跨樓層不再疊色）
- **區塊縮放 LOD 三檔**：拉遠只留圖標、中距每棟一個純填色聯集框、拉近
  逐房間平面圖＋框線＋名稱——中/遠距的名稱洗版與框線雜訊即此治

### 效能

- 區塊全開曾在 Louisville 市中心掉到 8 FPS，三刀修復後中距檔實測 244：
  三 pass 世界座標視野預裁、仿射投影快取（每矩形 8 次 Kahlua→Java 投影
  歸零，只在視野中心採樣 3 點）、圖標同格去重疊（拉遠時互疊圖標只畫
  可見的那顆，繪製數砍 6~8 成；孤立圖標永不消失、拉近自動全部展開）
- POI 快取重建逐類預取類別勾選（~5k 次 ModOptions 查找→20 次）

> 技術要點：poi_raw.json v2（9254 棟 85,585 房間實例，與 v1 房名/外框
> 零差異）；POIData v3 格式 {cat, rn, r}（1704 筆 4764 矩形，256KB）；
> zone 契約新增 iconOnce/lodRect 選配欄（Zones addon 零波及）。守衛測試
> python 27 個＋zone render harness 全面擴充（兩層裁切分離驗證、LOD 檔位
> 邊界、去重疊三向、poi-convert 消費端契約、900 例隨機不變式）。雙邊
> （Claude＋codex）review 六輪，Blocking 全數修復；逐棟證據見
> MinidoracatMiniMapPOICategories.lua 檔頭查核區。

## [42.20.0-0.12.0] - 2026-08-06

### 新功能

- **資源點（POI）14 類→20 類、636→1720 筆**：新增電器行(52)／教堂(31)／
  農場(378)／工業(163)／零售(126)／餐飲(325) 六類，各配可辨識色＋單色/全彩
  圖標；既有類別補鍵——medical +8 鍵（+9 棟淨新增、2 棟含牙醫的複合樓自
  超市歸屬修正）、軍警 +19 鍵（現圖冪等防未來缺口）、戶外補 fishingstorage
  （+10 棟）；storage −10 主身分修正（咖啡店／工廠／郵局街區原掛倉儲圖標）。
  全部依 poi_raw.json 9254 棟逐鍵實算：否決會誤傷的 baggagesearch（Louisville
  商場變軍事）／killbox（豬屠宰場變監獄）／shed（99 棟中 83 棟是後院工具棚），
  armory 改歸警察（警局軍械室非軍事基地）。

### 效能

- **POI 圖標渲染視野預裁**：1720 筆逐幀投影前先以世界座標 AABB 早退——
  小地圖典型視野省 >99% 的 Kahlua→Java 投影呼叫、全圖拉遠最差僅 +0.2%；
  畫面逐位元不變（外接框超集形式證明＋差分/隨機/mutation 測試 0 誤殺）。
- POI 快取重建時逐類預取類別勾選（~5k 次 ModOptions 查找→20 次）。

> 技術要點：CATEGORY_PRIORITY 尾端順序逐棟實測定案（church<food 保自助餐教堂、
> electronics<retail 保百貨、industry<retail 工廠直售店 6:1、retail<food 餐飲
> 寄生 41 棟、storage 墊底）；四語翻譯新增 8 鍵並修 tooltip stale「15 類」；
> 三語 Steam 描述同步（6555/6965/7777 bytes 皆 <8000）。守衛測試 8→14
> （ORDER parity／圖標存在性／烘焙 byte-compare／優先級尾端鎖定／rooms 兩兩
> 互斥／鍵數快照）＋ test_zone_render.lua A5 視野預裁區塊（900 例隨機不變式）。
> 逐鍵查核與取捨依據見 MinidoracatMiniMapPOICategories.lua 檔頭；
> 雙邊（Claude＋codex）review-plus 三輪、發現全數落地。

## [42.20.0-0.11.0] - 2026-08-04

### 新功能

- **玩家座標顯示＋一鍵複製**：小地圖底部置中顯示目前 x, y, z（開關預設開，
  複製功能不受開關影響）；按鈕列新增 XY 鈕一鍵複製 `x,y,z` 到剪貼簿、右鍵
  選單「複製此處座標」複製指向位置（`x,y,0`）——格式與 `/teleportto` 直接
  相容，複製成功顯示 1.5 秒琥珀提示。
- **穿透模式（Ghost Mode）**：點擊／滾輪／右鍵點擊全部穿透小地圖直達遊戲
  世界、地圖本體半透明（不透明度滑條 10–90%，預設 40%、穿透中拉動即時生效）
  ＋外框變淡＋琥珀邊框——把地圖拉大當常駐畫面不擋操作、不擋視線（Discord
  玩家需求）。快捷鍵 `'`（引擎硬編碼／275 個 Workshop MOD／keysB42.ini／
  vanilla 四關空閒驗證）、浮動圖標右鍵（tooltip 標示左右鍵雙用途＋動態鍵名）
  或三處設定面切換，狀態跨重啟保留；分割畫面對所有玩家生效；防鎖死鏈三層
  （熱鍵→浮動圖標右鍵→ESC 選項頁）。
- **統一設定視窗預設全部收合**（原本每次開窗自動展開「圖層顯示」）。

> 技術要點：穿透＝事件 gate 明確 return false（右鍵 Java 收尾 nil 即消費）＋
> consume 旗標全組快照還原（防 stale picker：外框吃 mouse-move 會讓世界指向
> 不更新）；半透明＝分層壓暗（內容層×滑條值、被蓋住層歸零防疊層累積）＋底紙
> quad 歸零（mapAPI:setBackgroundRGBA，實測第一死點）＋未探索遮罩每幀重壓
> （WorldMapVisited singleton 與大地圖共用、退出還原）。三邊 review 修正
> 9 項。離線測試：`scripts/test_ghost_gate.lua`（G1-G6＋A1-A8）、
> `scripts/tests/test_translate_json.py`（四語 JSON 守衛）。

## [42.20.0-0.10.4] - 2026-08-03

### 加固

- **圖層自癒**：地圖影像圖層被其他 MOD 的樣式層壓下、或處於缺層／亂序
  狀態時，開圖即自動偵測並重掛回最上層；自癒時在 console.txt 寫入診斷行
  （含當時的最上層 id），「影像被藍色水體等向量圖形遮蓋」類回報可直接
  定位來源（源自地圖包許願串 #4 的 AnruisiTown 倉庫區回報）。
- **stale 圖層清掃**：MapPackLayers 關閉、或 MP 伺服器 Map= 收緊後，
  世界地圖不重建也會移除已不該顯示的舊圖層（既有缺口）。
- 建層中途失敗改為全拆重試、不留半掛狀態；同 zip 變體（Chinatown 兩版、
  legacy 約定名）圖層 id 顯式去重。

> Note：原版 42.20 樣式重建全是 clear() 起手（全有全無），純原版環境走不到
> 「壓下」狀態——本版屬防禦性加固＋診斷儀器，AnruisiTown 回報的實際成因待
> 玩家 console.txt 的自癒診斷行佐證。產品契約：本 MOD 圖層恆佔樣式最上層，
> 第三方晚掛的 style layer 會在覆蓋範圍內被壓下。
> 離線測試：`scripts/test_layer_tail.lua`（11 組決策矩陣＋5 組整合案例）。

## [42.20.0-0.10.3] - 2026-07-30

### 更新

- **內建資源點（POI）分類補洞：606→636 筆**：42.20 相容性稽核發現分類表涵蓋
  不一致——police/fire/gas/grocery/sport/army 的 storage 變體都收了，唯
  medical/pharmacy/school/prison/outdoor 系缺漏，約 30 棟高價值建築在地圖上
  隱形。補齊 15 個 room key：medicalstorage/hospitalstorage/pharmacystorage/
  campingstorage/schoolstorage/schoolgymstorage/policelocker/policearchive/
  prisonstorage/prisonlaundry/gymstorage/universitystorage（Distributions
  頂層 loot key）＋gunstorage/bookstorage/universityclassroom（非 loot key，
  依 bunker「位置存在」前例收錄，含大學園區三棟大樓）。部分建築主身分隨之
  修正（如藥局倉庫建築 grocery→pharmacy、大學園區 medical→school），屬
  語意修正非資料遺失。ranger 護林站（42.20 新圖 1 棟）維持併入 medical 顯示
  （全圖僅 1 棟，獨立類別不划算，查核註記已記錄）。
- 雙邊 review-plus（Claude／codex 獨立 lane）皆 COMMENT 無 blocking；
  gen 決定性重跑一致、離線測試全綠。

## [42.20.0-0.10.2] - 2026-07-29

### 更新

- **遊戲 42.20 基底全圖重渲**：42.20 更新主世界 950 個 cell（Muldraugh／
  Rosewood／Riverside／West Point 城區）並新增 JUMBOXL/JUMBOXXL 巨樹
  （JumboTreesBigs2x.pack）；以完成 42.20 修正（巨樹 pack 補載＋anchor 分層＋
  畫布邊界）的 MapRendering 重渲 `Muldraugh_KY.pyramid.zip`（bounds 不變
  0 0 19968 16128，Lua 掛載鏈零改動）。
- **POI 資料 42.20 重生**：`pzmap poi` 重擷 poi_raw.json（建築 8541→9254 棟）
  → `gen_poi_data.py` 重生 POIData（499→606 筆，14 類全數有值，luac -p 通過）。
- **Lua 相容性查證（42.19→42.20 反編譯逐檔 diff）**：掛載鏈依賴的
  WorldMap／ImagePyramid／WorldMapImages／MapDefinitions／UIWorldMapV1-V3
  位元組相同；被 hook 的原版 `ISWorldMap`／`ISMiniMap` 等 Maps/ Lua 42.20
  未更動——功能面免改，僅版本元資料 bump（modversion=42.20.0-0.10.2、
  versionMin=42.20.0、三語描述 42.20.0+、workshop.txt 重生成）。

## [42.19.0-0.10.1] - 2026-07-21

### 修正

- **緊急修復：0.10.0 圖片化地圖全面失效（退回原版向量樣式）**：mapDir 逐圖閘門的
  `getLoadedMapDirs` 使用了 PZ Kahlua 未註冊的全域 `next()`，只要
  `getWorld():getMap()` 回傳有效清單（MP 必定、單機多數）即拋
  「Object tried to call nil」，pyramid 掛載鏈中斷、全部退回原版地圖
  （Steam 玩家 gwinnblayd 與自營伺服器實測回報）。42.19.0 反編譯查證：
  Kahlua BaseLib 僅註冊 18 個全域，`next`/`assert` 皆不存在。兩處 `next()`
  （`getLoadedMapDirs` 與 `navShareGateTick` 的隱性地雷——伺服器關閉
  AllowNavShare 時會每 tick 炸）改為 `pairs` 探測空表，語意等價、
  fail-open 路徑不變。
- **一次性重新開啟「圖片化地圖」總開關**：故障期間部分玩家排查時可能把總開關
  關掉，修復後仍看原版樣式且不知要開回。比照快捷鍵遷移：主選單一次性強制設回
  預設 true＋寫 marker（Zomboid/Lua/MinidoracatMiniMap_imageryForcedV1.txt）；
  之後玩家再關閉即屬刻意選擇，永不再干預。離線測試 V1-V5。

### 內部

- **Kahlua 缺失全域守衛測試**：新增 `scripts/tests/test_kahlua_globals.py`，掃描
  全 MOD 執行期 Lua 的 `next(`/`assert(` 裸呼叫——這類「實機才炸、離線測試
  （標準 Lua）全綠」的雷改由靜態守衛在離線階段攔下。

## [42.19.0-0.10.0] - 2026-07-20

### 修正

- **一 mod 多地圖的逐圖閘門（`mapDir`）**：registerMaps 條目新增選配 `mapDir`
  （地圖目錄名）。指定時除 mod ID 啟用外，還須該目錄實際載入世界才掛圖/畫框——
  修 MP 伺服器只在 `Map=` 挑部分 SecretZ 據點時，未載入據點仍被畫出的誤顯示
  （玩家 baker 回報）。判定源＝`getWorld():getMap()`（Java `Core.gameMap`）：
  單機＝MapGroups 串起的全部啟用 MOD 目錄（行為不變）、MP 客戶端＝伺服器
  `Map=` 清單（世界 init 時 IsoMetaGrid.getLotDirectories 回填；42.19 反編譯查證）。
  拿不到清單＝fail-open 回退純 mod ID 閘門；空字串 mapDir 視同未指定（單點中和，
  不整條目拒收）。離線回歸測試 `scripts/test_mapdir_gate.lua`（串列解析/修剪/
  單目錄/fail-open 矩陣＋rebuildMapOverlays 整合過濾案例）。

## [42.19.0-0.9.0] - 2026-07-20

### 新增

- **浮動開關圖標**：常駐畫面的小圖標（預設開），點擊直接開關小地圖——純滑鼠玩家
  不再依賴快捷鍵。可拖曳擺放（4px 位移門檻區分點擊/拖曳），位置自動記憶
  （ModOptions FloatIconPos "x,y"，同 CustomSize 先例可手動清空還原）；獨立於
  小地圖視窗、關圖後仍在；hover 顯示提示「開關小地圖（快捷鍵：X）」——動態讀
  當前綁定（含修飾鍵前綴），改鍵即時反映；統一設定視窗「外觀」區與 ESC 選項頁皆可開關；
  材質（media/ui/minimap_toggle.png，64x64）缺漏時 nil-safe 以「M」字替代；
  回主選單自動隱藏、進遊戲自動恢復。
- **快捷鍵自動遷移**：首次進遊戲時若綁定仍是舊預設「無修飾鍵的 HOME」則自動改為
  /（斜線）並寫回 keysB42.ini（走 MainOptions.keyText → saveKeys 正規路徑；帶修飾鍵或
  已改鍵＝玩家刻意設定，不動）。marker 檔 Zomboid/Lua/
  MinidoracatMiniMap_keyMigratedV1.txt 記錄已處理，玩家事後刻意改回 HOME 不再干預。
- **圖片化地圖總開關**（統一視窗「圖層顯示」首列＋ESC 選項頁＋世界地圖（M）
  選項面板，三面同源，預設開）：關閉後
  不掛任何 pyramid 圖層，小地圖與世界地圖回到原版向量樣式，圖標/資源點/殭屍點位
  等其他功能全部照常。切換即時生效：世界地圖逐 id 卸載/補掛本 MOD 樣式圖層
  （外科手術式——不走 Reapply Style，避免 styleAPI:clear 誤刪其他 MOD 的圖層）、
  小地圖 Recreate 重建；applyMiniMapPyramids 為所有掛載路徑唯一入口＝單點閘門，
  框線資料重建置於閘門之前（關閉圖片化時 MOD 地圖框線照常）。無小地圖
  （沙盒 AllowMiniMap 關閉）時仍可切換世界地圖；apply 決策抽為純函式
  computeApplyPlan＋離線矩陣測試 P1-P9。
- **-debug 渲染除錯警告**：debug 模式下偵測到「世界渲染已被切至舊管線
  （PerformanceSettings.fboRenderChunk=false，多半是誤按 HOME）」或「開關綁定
  仍是 HOME」時，小地圖頂部顯示橘色警告條（前者優先、提示再按 HOME 復原）；
  浮動圖標 tooltip 同步附警告行，並常態多顯示一行「目前渲染管線：chunk-FBO（新版）
  ／舊版逐 tile」讓 debug 使用者隨時可查。非 debug 環境一個布林判斷即返回、零成本。
  fboRenderChunk 為 exposed class 的 public static 欄位（同 Keyboard.KEY_* 讀法），
  以 pcall 防未來版本移除。Steam 描述同步把 -debug/HOME 注意事項獨立成醒目區塊。

- **圖標大小/透明度全面滑條化**：殭屍點、動物圖標、載具圖標、資源點圖標四類
  各自獨立「大小(px)」與「透明度(%)」滑條，統一設定視窗（內嵌 ISSliderPanel）與
  ESC 選項頁（PZAPI 原生 addSlider）雙面可調；拖動即時預覽（繪製端每幀讀值）、
  放開滑鼠才落盤（避免拖曳中高頻檔案 IO）。動物與載具大小自此拆分（原共用一顆
  三檔下拉）；資源點圖標大小（原固定 18px，作用於所有 zone 圖標）與四類透明度
  （原寫死常數）首次開放。舊三檔下拉存值於主選單一次性自動換算為對應像素
  （動物依當時風格選映射表、載具以舊共用值播種；離線測試 M1-M5 覆蓋）。
  世界地圖（M）圖標沿用共用設定、自動跟隨。

### 變更

- **統一設定視窗區塊標題一致化**：「殭屍點位」→「殭屍圖標」、「資源點」→
  「資源點圖標」，與既有「動物圖標／載具圖標／世界地圖圖標」命名對齊（四語系
  同步；Steam 描述引用的小節名一併更新）。
- **小地圖預設快捷鍵 HOME → /（斜線）**：HOME 在 -debug 模式下是引擎隱藏熱鍵
  （IsoCell.render 按鍵切換 PerformanceSettings.fboRenderChunk，整個世界渲染
  退回舊版逐 tile 路徑——本機實測 FPS 約減半 244→124、地面積雪外觀隨渲染路徑
  改變），與小地圖開關同鍵齊發，讓 debug 環境的使用者誤以為小地圖吃 FPS。
  /（斜線，M 鍵右方——大地圖 M、小地圖 /）於原版 keyBinding.lua 未綁定（含裸數字
  鍵碼掃描）、引擎 Java 層無硬編碼、無文字框編輯副作用（文字輸入期間引擎本就不
  派送綁定）、本機 213 個 Workshop MOD 與 keysB42.ini 全 56 綁定掃描空閒、實體
  位置跨鍵盤佈局穩定、顯示名稱「/」無歧義。選鍵否決紀錄：K 撞原版「Display FPS」
  （keyBinding.lua:199 以裸數字 37 註冊，掃 KEY_* 常數抓不到）；0 的顯示字元在
  UI 字型下似字母 o；F7/F8/F9 是 debug 裸鍵編輯器（載具/世界地圖/接縫，
  IngameState.java:1398/1424/1431）、F12 撞 Steam 截圖；9 被 Bandits Week One
  事件鍵使用；N 撞 StartVehicleEngine。注意：綁定會持久化寫入 keysB42.ini、
  既存值蓋過新預設
  （MainOptions.loadKeys 於 ini 讀入後覆寫）——存量安裝由上方「快捷鍵自動遷移」接手。

## [42.19.0-0.8.0] - 2026-07-18

### 新增

- **內建資源點（POI）**：主 MOD 內建原版地圖的 499 筆資源點、14 類（軍事、警察、槍店、
  醫療、藥局、消防、圖書／書店、學校、超市、加油站、五金／修車、戶外／打獵、監獄、
  倉儲，各配可辨識色），裝本體即見。以內部 zone provider 註冊，預設「圖標模式」
  （每點於中心畫染色剪影圖標、不鋪標籤），可勾「彩色資源點圖標」改用全彩圖；另有
  「顯示資源點區塊」選配（半透明色塊＋名稱）。統一設定視窗新增「資源點」收合小節：
  母開關＋彩色切換＋14 類 3 欄勾選格（列首帶類別小圖）＋全選／全不選；齒輪面板同步
  提供「顯示資源點」快速開關。同建物含多類別房間時以主類別去重（如警局內含牢房不再
  疊監獄圖標）；分類收錄原版 room 別名（medclinic／elementaryhall，
  SuburbsDistributions.lua:162/:177）。圖標素材缺漏時 nil-safe 跳過，不影響區塊模式。
  四語翻譯齊備。
- **zone schema `icon` 欄位與 per-provider 開關**：zone 可帶 `icon = { tex, r, g, b }`
  （每 rect 中心投影畫染色圖標，與框線同層）；`registerZoneProvider` 新增選配第三參
  `optionLabelKey`，給了就由本 MOD 於統一視窗動態追加一顆 per-provider 母開關
  （關＝渲染時整個跳過該 provider）。
- **registerZoneAction API**：addon 可註冊設定頁動作列（`[下拉選單]+[按鈕]` 一列，
  spec 帶 labelKey／tooltipKey／options／onTrigger），渲染於圖層區伺服器區域開關之後
  ——Zones addon 的「生成區域範本」按鈕即以此實作。無註冊時零列（dormant）。

### 修復

- **統一設定視窗捲動與排版**（三項疊加根因，實機探針逐一驗證）：
  1. `setScrollChildren(true)` 在 panel 的 javaObject 尚未建立時為靜默 no-op
     （ISUIElement.lua:1647 直接 return），子元件渲染從不吃捲動位移——改為先
     `instantiate()` 再設定；
  2. 自畫標題／圖標的手動 `+getYScroll` 移除——java 端 DrawText／DrawTexture 已自加
     yScroll（UIElement.java:190-194），再加一次＝雙倍速錯位；
  3. vanilla `keepOnScreen` 螢幕夾制誤傷內容座標子元件：`addOption→setHeight`
     （ISTickBox.lua:234）會把尚無 parent 的 tickbox y 夾到「螢幕高−元件高」
     （ISUIElement.lua:245-251；getKeepOnScreen 預設 `not self.parent`），全展開時
     超過一屏的勾選全疊在同一列——建構前顯式關閉 keepOnScreen。
  修畢後全展開內容可完整捲動到底、逐列可點、文字不重疊。

### 變更

- 統一設定視窗所有開關／下拉即時套用並持久化（等同 ESC MOD 選項頁儲存，無需另開選單）。

## [42.19.0-0.7.0] - 2026-07-17

### 新增

- **Zone 渲染 API**：新增 `MinidoracatMiniMapAPI.registerZoneProvider(ownerModId, providerFn)`
  與 `MinidoracatMiniMapAPI.zoneApiVersion = 1`，讓區域圖層 addon（家族第四個 MOD
  MinidoracatMiniMapZonesFor42）把矩形區域資料交給本 MOD 渲染。本 MOD 每幀呼叫 provider
  取回已翻譯、已正規化的 zone 陣列，在小地圖與世界地圖以半透明色塊填色、框線描邊並置中標名。
  provider 每幀回傳快取表、繪製端只讀不改；provider 拋錯以 pcall 攔截並首次記 log，
  不影響地圖其餘繪製。
- **「顯示區域圖層」總開關**：偵測到有 zone provider 註冊時，於 ESC 選項頁、統一設定視窗
  圖層區、齒輪面板三處動態追加開關（預設開）。關閉即整層不繪製，且不觸發 provider 重建。
- **MOD 地圖框線透明度（MapBoundsAlpha）**：新下拉三檔（不透明／半透明／隱約，
  沿用小地圖不透明度的翻譯鍵與倍率 1.0/0.5/0.15），同時作用於框線與名稱標籤；
  預設不透明＝與先前外觀完全相同。ESC 選項頁與統一設定視窗外觀區同步提供，
  隨地圖包安裝動態出現（同 MapBoundsColor）。
  未安裝區域圖層 addon 時整條管線休眠、零成本。四語翻譯（繁中／簡中／英／日）齊備。

### 變更

- 更正 `MinidoracatMiniMapServer.lua` 開頭「SP 下 OnClientCommand 不觸發」的舊註解：
  B42 單機走 spnetwork loopback，`OnClientCommand` 在單機同樣觸發。

## [42.19.0-0.6.0] - 2026-07-15

### 新增

- 新增 `MinidoracatMiniMapAPI.registerAnimalGroup(ownerModId, group, labelKey, symbolPath, itemPath)`，
  讓獨立相容包把第三方 `IsoAnimal` 群組加入既有物種篩選，並可選擇提供自己的符號與彩圖；
  未提供素材時使用原版爪印安全備援，不接受 callback，也不接管上游 MOD 自己的地圖標記。

## [42.19.0-0.5.0] - 2026-07-15

### 新增

- **伺服器顯示距離限制**：殭屍點位、動物圖標、載具圖標與安全屋框線可分別設定
  顯示距離；`0` 代表不限制，正數代表只顯示玩家 N 格內的項目。採二維距離、不計
  樓層，管理員按「套用」後立即生效。

### 變更

- **牲畜圖標可見性改為四檔**：全部顯示／隱藏其他安全屋內的牲畜（預設）／僅顯示
  我方安全屋內的牲畜／全部隱藏。安全屋歸屬包含屋主與受邀成員，依動物目前位置判定；
  野生動物不受影響。這是誠實客戶端的顯示政策，不是動物所有權或防作弊機制。
- **升級注意**：舊版「顯示其他玩家的牲畜」開啟值不會自動遷移；更新後預設為
  「隱藏其他安全屋內的牲畜」。原本要全部顯示的伺服器管理員需手動改選「全部顯示」。

### 修復

- **陣營分享關閉後仍殘留既有目標**：管理員停用陣營分享時，已收到的共享目標現在
  立即隱藏並清除；停用期間延遲抵達的舊封包不會在重新開啟後復活。
- **PVP 距離閘門殘留舊點**：距離值或玩家物件狀態改變時立即淘汰取樣快取；距離
  限制啟用但暫時無法取得玩家時採 fail-closed，不保留舊殭屍、動物或載具點位。
- **統一設定視窗摘要不同步**：收合標題改為即時計算；世界地圖圖標區顯示已開啟的
  類別數量，不必重新收合或開啟視窗才更新。
- **多語沙盒提示過長**：繁中、簡中、英文與日文 tooltip 加入語意換行，避免橫跨
  大半個畫面。

## [42.19.0-0.4.0] - 2026-07-14

### 新增

- **世界地圖圖標**：殭屍點位／野生動物／畜養動物／載具圖標登上世界地圖（M）——
  四個獨立開關（統一設定視窗新增「世界地圖圖標」區段，與原版世界地圖選項分開
  不混淆），風格、顏色、大小與物種／類別篩選跟隨小地圖設定；受同組沙盒管理
  選項控管。
- **世界地圖爪印入口**：世界地圖右上按鈕列新增爪印按鈕，直接開啟統一設定視窗
  （不必先開小地圖）。

### 修復

- **世界地圖 MOD 地圖圖像會中途消失且不復原**：原版三條路徑（色盲圖案設定
  同步偵測、debug「Reapply Style」、地形圖片切回）會重建世界地圖樣式，把本 MOD
  的圖像圖層洗掉——世界地圖是單例、原掛載點只在建立時跑一次，洗掉後不重啟
  遊戲不會恢復。現在開圖時與樣式重建後都自動補掛（冪等），玩家零操作。

## [42.19.0-0.3.0] - 2026-07-14

### 新增

- **動物圖標（預設關）**：小地圖即時顯示附近動物——野生／畜養獨立開關；9 物種
  個別篩選（牛/羊/豬/鹿/雞/火雞/兔/浣熊/鼠類）；兩種圖標風格（原版地圖符號染色／
  物品彩圖）；大小三檔；野生・畜養顏色可自訂（色盲友善 8 色，Okabe-Ito 為底）。
  全部使用遊戲內建素材，零自帶圖檔。
- **載具圖標（預設關）**：方向盤符號顯示可視範圍內載具（內建無車形地圖圖示，
  方向盤為最接近的原版符號）；一般／重型／性能（mechanicType 1/2/3）＋特勤
  （警燈車）類別篩選；顏色可自訂。
- **統一設定視窗**：齒輪鈕改開新視窗，整併原設定視窗與圖層面板注入項——
  雙欄五區塊（圖層顯示／殭屍點位／動物圖標／載具圖標／外觀與行為）可收合、
  標題列現況摘要、全部展開／收合、各語系實測字寬自適應版面、內容捲動
  （高度不超出螢幕）、沙盒停用標示。引擎原生三項（等軸測／符號／遠端符號）
  移入圖層區；「=」圖層面板鈕退役（按鈕列 6 顆）。
- **沙盒管理選項 ×3**：允許動物圖標（預設開）、顯示其他玩家的牲畜（他人安全屋
  內的牲畜可見性，預設關——基地隱私）、允許載具圖標（預設開）。
- **自由查看回中提示**（導航軟體同款模式）：拖離玩家後，小地圖底部浮出
  「點擊地圖回到玩家」琥珀提示、C 鈕同步高亮——回中即消失。

### 修復

- **圖層面板勾選被設定套用蓋回**（玩家回報）：殭屍熱度等引擎選項的面板勾選
  現會回寫 MOD 選項——任何設定調整不再把勾選強制改回；MP 沙盒壓制解除時
  也改恢復成玩家自己的偏好。
- **改尺寸／重建不再丟失**等軸測、符號、遠端符號設定（重建前快照回寫）。
- **分割畫面**：設定視窗記住開啟它的玩家，引擎選項讀寫與視窗夾位不再固定 player 0。
- 安全屋邊界判定照原版半開區間（東／南界外一格的牲畜不再被誤隱藏）；
  空篩選欄位經 PZAPI 存讀變 "nil" 髒字串（改用 sentinel）；
  材質快取不再把暫時載入失敗變成整場消失。

## [42.19.0-0.2.0] - 2026-07-13

### 新增

- **地圖包註冊 API**：`MinidoracatMiniMapAPI.registerMaps(ownerModId, entries)`——
  地圖包 addon（如 MinidoracatMiniMapModMapsFor42，`require=` 本 MOD）向本 MOD 註冊
  地圖清單（zip/mapMod/bounds/nameKey），zip 放地圖包自己的 `media/minimap/`，
  依對應地圖 MOD 啟用狀態自動掛載。首批三張地圖已移往地圖包 addon 專案。
- **MOD 地圖框線＋名稱顯示（MapBounds）**：對已註冊且啟用的地圖 MOD，在角落
  小地圖與世界地圖（M）以框線標出範圍、中心顯示地圖名稱（走 UI.json 翻譯，
  缺譯退 mod ID）。
- **地圖包專屬選項（裝了地圖包才出現，OnGameBoot 依註冊狀態動態追加）**：
  「顯示 MOD 地圖區塊」（掛不掛地圖包圖像，改動即重建小地圖）、「顯示 MOD 地圖
  框線」、「MOD 地圖框線顏色」（預設綠，另有青/黃/紫/白）——ESC 選項頁、齒輪面板、
  設定視窗三處同步。

### 變更

- **pyramid 架構改為 manifest 驅動集合包**：本 MOD `media/minimap/` 集中放各地圖 zip
  （檔名＝地圖原名，pzmap Studio 預設輸出名免改名），`MAPS` manifest 宣告對應的地圖
  mod ID——基底圖（`Muldraugh_KY.pyramid.zip`）永遠掛載，地圖 MOD 的圖僅該 MOD 啟用
  才掛載；每個檔名動態建一個 Pyramid 樣式層。第三方 addon 的
  `minidoracat_minimap.pyramid.zip` 同名約定保留為相容路徑（零 Lua 不變）。

## [42.19.0-0.1.0] - 2026-07-11

### 新增

- 專案初始版本（v1 最小可用）。
- `MinidoracatMiniMap.lua`：hook `ISWorldMap:initDataAndStyle`，掃描啟用 MOD 的
  `media/minimap/minidoracat_minimap.pyramid.zip` 並以 `addImagePyramid` 掛載，
  疊加單一 Pyramid 樣式層（不清空原版樣式），全程 pcall 防禦。
- `scripts/build_pyramids.ps1`：呼叫 pzmap `render-minimap` 產生基底 zip。
- `link_workshop.bat` / `PZ_Test.bat`：本地 no-steam 測試流程（沿用 MinidoracatLangFor42 腳本架構）。
