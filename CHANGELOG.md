# Changelog

## [Unreleased]

## [42.20.4-0.26.0] - 2026-09-03

### 新增

- **動物名稱**：動物分類新增「顯示動物名稱」開關（預設關）——圖標下方標出種類（如「小牛」；有取名的顯示自訂名）並附公／母；「動物名稱顯示距離」滑條（0＝不限）只在距離內標名，圖標本身不受影響

> 技術要點：名稱於 0.5 秒取樣輪一併取（`getCustomName` 優先，否則 `IGUI_AnimalType_<getAnimalType()>`；`isFemale`，譯文 `IGUI_Animal_Female|Male`），入點池 `d.name`；`wantNames` 進取樣 cache key（mask bit 8）。距離為純客戶端 `AnimalNameDistance`（無沙盒 cap——名稱不比圖標多揭露位置），缺玩家時 fail closed 不標名。格式鍵 `UI_MinidoracatMiniMap_AnimalNameFmt`。

### 變更

- **全新圖標**：安全屋、殭屍、動物（雞／牛／豬／羊／鹿／兔／浣熊／鼠／火雞）、載具的地圖圖標換成一組新繪的實心剪影，辨識度比原版地圖符號高很多；地圖顯示設定的導覽列每個分類現在都有圖示（安全屋／殭屍／動物／載具與圖層／資源點等同一排風格）。圖標由 UI 框架（MinidoracatUIFor42）統一提供，框架未更新時自動退回原版符號
- **設定視窗的物種小圖跟著「動物圖標風格」走**：切到「彩色物品圖標」時，動物分類的物種清單立刻改顯示彩圖，切回符號即恢復——地圖上長怎樣設定窗就長怎樣。彩色物品圖標在小地圖與設定窗都不再墊深色方塊，直接透明去背顯示

> 技術要點：依賴框架 API rev 4（`Icons` 新增 13 個 art key）；`Skin.iconTexture(key)` adapter，`_Dots.lua` 的 `adotsSymTexture／adotsStyleTexture／adotsVehTexture` 為地圖與設定視窗的單一貼圖來源（框架 art → `ADOTS_ART.sym` 原版 → 腳印備援；第三方相容包物種只有 `sym` 照走）。安全屋圖標 `house`、導覽分類 `icon=`＋`iconTex=` 原版退回。`AnimalIconStyle` 下拉改值即 `unifiedRebuild`。

## [42.20.4-0.25.0] - 2026-09-03

### 新增

- **安全屋獨立分類**：地圖顯示設定新增「安全屋」分類，範圍框開關從「圖層顯示」搬入，並新增「顯示安全屋圖標」（範圍中心的房屋圖標）與「顯示安全屋名稱」兩顆開關；顏色一致——自己所屬綠、同陣營屋主青、其他玩家紅。安全屋範圍與名稱的顯示距離兩條滑條也在此分類（原「顯示距離」區的安全屋滑條搬過來），名稱距離獨立可調。伺服器以沙盒關閉時，對應開關會反灰並提示
- **沙盒：安全屋名稱獨立政策**：新增「安全屋名稱顯示」（關閉／僅自己的／全部／自己與陣營）與「安全屋名稱顯示距離」，與範圍顯示分開設定；「安全屋範圍顯示」多一檔「自己與陣營」（屋主為同陣營成員即顯示）。新檔追加在尾端，舊伺服器存的「全部」值不變
- **沙盒分頁**：Minidoracat 小地圖的沙盒選項拆成五個分頁——一般（全域距離上限、陣營分享、管理員旁路）／圖標（殭屍、動物、載具）／區域（資源點、自訂區域）／安全屋／匯出，選項名稱不變，既有伺服器設定無需調整

> 技術要點：安全屋圖層整段自主檔拆至 `MinidoracatMiniMap_Safehouse.lua`（主檔 prerender 改 `pcall(Core.drawSafehouses)`＋log-once；`_Dots.lua` 新匯出 `Core.adotsDrawGlyph`）。模式判定純函式 `safehouseModeAllows(mode, mine, ally)`，陣營以 `Faction.getPlayerFaction(username)`→`isOwner/isMember(sh:getOwner())` 判定（Faction.java:123/150/154），名稱取 `sh:getTitle()`（SafeHouse.java:727）。Policy SCHEMA 19→21 鍵、`PRIVACY_KEYS` 加 `SafehouseNameDistance`、新 `safehouseNameMode(pn)`，兩模式值域 1-4（隱私旁路回 3）。沙盒 `page` 只是 UI 分頁字串（翻譯鍵 `Sandbox_<page>`），選項名前綴 `MinidoracatMiniMap.` 不變，`SandboxVars` 讀寫不受影響。離線回歸：`test_livestock_visibility`（改讀 `_Safehouse.lua`；模式 4／圖標／名稱／獨立距離案例）、`test_admin_policy`（21 鍵對齊、名稱模式）、`test_settings_studio`（safehouse 分類＋cap dirty）。

## [42.20.4-0.24.0] - 2026-09-03

### 修正

- 修正導航路線「起點距離」在沿路行駛一段之後失真的問題：先前這個數字量的是「玩家到路線第一個點」的距離，只有路線剛算好那一刻才等於真正要越野接線的長度；沿路開了一段再查詢會變成離起點幾十甚至上百公尺。使用自動駕駛 addon 時的症狀是：導航中停車、再啟動被拒絕並提示「路線起點離車太遠」，即使車就在路上。現在改量「玩家到路線最近點」的距離；給自動駕駛 addon 用的導航介面版本升為 v5（自動駕駛 0.3.0 起依賴本版）

- 修正在車上時導航路線寧可「橫越田野／樹林」也不走正規道路的問題：先前選路只把兩端的越野接線算成三倍距離，適合走路抄捷徑，但開車過不了樹林——例如目的地就在支路旁 3 格、離大路 64 格時，路線會停在大路上要你自己穿 64 格樹林。現在人在車上時越野接線改算十二倍，會乖乖沿大路繞到路口再轉進支路；徒步導航不變。上下車會立刻重算路線

> 技術要點：`route.snapDist` 沿用快取時改刷新為投影距離（＝偏航判定用的 d），首算值不變；`MinidoracatMiniMapAPI.navApiVersion` 4→5，欄位與簽名皆不變。自動駕駛 addon 0.3.0 起只在 v5 以上啟用「起點太遠」門檻。`NavCore.findRoute` 新增第 9 參 `approachWeight`（缺省 3）；`ensureRoute` 新增第 5 參 `weight`，由三個呼叫端（繪製、`requestRoute`、`requestDetour`）依手上 `playerObj:getVehicle()` 選 3／12 傳入並記在快取，權重改變＝立即重算（不吃 3 秒冷卻）。

- **Hog Wallow Road（豬窪路）北端與 KY-60 之間缺一段路網**（玩家回報「小段沒鏈接」，約 x4490 y10650）：官方街道資料把這條路畫到 (4483,10744) 就停了，但實際鋪面還往北 94 格、切角轉東 81 格接上 KY-60。少了這 183 格，導航線在這裡斷頭，從豬窪路要上 KY-60 得沿路南下繞 4500 格。道路修補層現在把這段補進路網，路線與自動駕駛直接走這條接上 KY-60。

> 技術要點：`manualRoads` 追加 `m:muldraugh-hog-wallow-ky60-link`（add、paved、width 8，四點折線 (4483,10744)→(4483,10653)→(4490.5,10645.5)→(4571.5,10646)），起點與官方北端節點重合、尾點落 KY-60 兩段共用頂點；鋪面依 `road-surfaces-full-v2` 逐格實證（中線 185 格全 paved）。稽核 row-span 未列此候選：KY-60 實際路帶比 xml 寬 1-2 格，未覆蓋的路肩細條把缺段接進全圖大分量。離線回歸：`test_nav_route.lua` 鎖 addCount=3＋(4483,10800)→(4540,10583) 路線經切角頂點、長 309（修前 4501）。

### 變更

- 小地圖主程式檔重整：區域圖層繪製、導航目標（旗標／右鍵選單／陣營分享）、邊緣拖曳縮放與快捷鍵三段程式碼各自搬進獨立模組檔，畫面與功能不變；為之後更多 addon 的擴充預留空間

> 技術要點：三刀各自 commit、行為逐位元不變（唯一例外 `RESIZE_MIN`→`Core.RESIZE_MIN`，因它是主檔兩處依字級抬高的可變值）。主檔主 chunk local 175→151→134→111（Kahlua 200 上限、verify 警戒 190）；主檔 4443→2753 行。
> - `MinidoracatMiniMap_Zones.lua`：`test:zone-render` 切片（fill／lines／icons 三 pass＋ZC 候選快取）；主檔留 `Core.drawZonePass(inner, pass, flagKey)` 入口，模組缺席依 flagKey log-once；新匯出 `Core.drawClippedEdge`。
> - `MinidoracatMiniMap_Nav.lua`：導航狀態／分享／nav gate API（`navApiVersion`／`registerNavGate`／`getNavTarget`）／旗標繪製／抵達／座標列／管理員檢視標記／右鍵選單／OnServerCommand；`navTargets` 表留主檔（InitPlayer 載回 modData）經 `Core.navTargets` 共享；prerender 四個呼叫點改 `pcall(Core.*)`。字母序在 `_NavRoute`／`_Search`／`_Settings`／`_WorldMapNav` 之前，其 `Core.nav*` 閉包載入期即就緒；先載入的 `_Dots`／`_FloatIcon`／`_Ghost`／`_Migrate`／POI 經審計皆呼叫時查。
> - `MinidoracatMiniMap_Resize.lua`：拖曳縮放狀態機、外框調色、outer prerender／render wrap、標題列鎖定、自訂鍵位；`debugWarn` 留主檔（`_FloatIcon` 載入期取別名且先載入）；主檔 InitPlayer 補掛與實例 prerender 改呼叫時查 `Core.installResizeHooks`／`Core.chromeTintBorder`＋nil 防呆，三個前置宣告與 `RESIZE_EDGE` 移除，新匯出 `Core.resizeMax`。
> - 拆法：`luac -l` 列該段 GETGLOBAL＝需別名的主檔 local，缺的補 `Core` 匯出；搬後再審計主檔零洩漏、新檔自由名稱只剩 PZ 全域。離線測試改讀新檔：`test_zone_render`（arg[3]）、`test_livestock_visibility`（arg[4]/[5]）、`test_nav_gate`／`test_admin_view_marker`／`test_server_nav_share`／`test_nav_api` 改指 `_Nav.lua`。新增 `docs/addon-api.md` 為 addon API 契約單一來源；addon 守衛規範改為版本欄位 `>=` 比較（Zones addon 同步）。

## [42.20.4-0.23.0] - 2026-09-02

### 新增

- 地圖顯示設定 addon API v2：分類可在勾選／下拉之後註冊最多 16 個動作按鈕
  （`label`／`tooltip`／`run` 必填，`enabled` 可選；`run(playerNum)`）；超過上限或任一動作無效時整次註冊失敗，不會部分更新。
  未傳 `actions` 的既有 ticks／combos spec 完全相容。
- **道路資料稽核與修補層**：新增可重現的全圖 `streets.xml`／地板材質稽核流程，
  以記憶體有界的 row-span 分析辨識缺路候選，並將人工裁決與來源雜湊烘焙成
  可重現的修補資料檔。42.20.4 全圖 6 筆最終候選均確認為停車區、
  私有服務巷或建物間土徑，因此沒有臆測新增道路；已知道路仍取得逐段
  `paved`／`gravel`／`dirt`／`unknown` metadata。
- **管理員檢視旁路（雙層政策，預設全關）**：沙盒新增「允許管理員戰術檢視旁路」與
  「允許管理員隱私檢視旁路」兩個選項。旁路要**三把鑰匙**同時成立才生效——伺服器主人
  開放該沙盒選項、該玩家的 Role 具備「看見全部」（`CanSeeAll`）、以及管理員自己在
  設定視窗勾選；少任何一把都不旁路。權限採 B42 的 Role＋Capability 判定，不再
  依賴舊版的管理員等級判定，自訂 Role 一樣適用。
  - **戰術層與隱私層分開兩把鑰匙**：戰術層（殭屍點位、殭屍熱度圖、動物圖標、載具圖標，
    以及殭屍／動物／載具／資源點／自訂區域的顯示距離與全域距離上限）是「看敵情」，
    不涉及他人隱私；隱私層（安全屋範圍顯示與其距離、牲畜圖標可見性）會看到其他玩家
    刻意藏起來的東西，故需要第二個沙盒選項＋第二個勾選，且**依賴**戰術層——關掉戰術
    檢視會連帶把隱私檢視一併關掉。
  - 地圖顯示設定新增「管理員檢視」分類，**只有同時具備 `CanSeeAll` 與伺服器戰術權限
    的玩家才看得到**；權限或沙盒政策在視窗開著時變動會讓分類即時長出／消失，勾選被
    伺服器拒絕時也會立刻彈回實際值。該分類的「重設此分類」只清自己的本機旗標，
    不會改動任何沙盒值。
  - 旁路生效期間，小地圖與世界地圖左上角常駐「管理員檢視」（英文介面 `ADMIN VIEW`）
    標記，避免管理員忘記自己開著看穿模式。
  - 勾選狀態只存在本機私有狀態，逐分割畫面 slot 獨立，不寫
    角色 modData、不同步伺服器；建立玩家、離線／重連時回到關閉（fail-closed）。
  - **顯示距離滑條仍然只能收緊**：旁路解除的是伺服器上限，玩家自己在「顯示距離」區
    設的值照樣生效。
  - 導航轉送（允許陣營目標分享）與玩家座標匯出**永遠不旁路**——那是通訊與 I/O 政策，
    不是檢視政策。整組旁路只改變「這台客戶端畫什麼」，**不是防作弊機制**。

### 變更

- **道路修補層在翻譯 MOD 環境生效**：RoadPatch 套用改為對「未知來源（fail-open）
  街道容器」逐條指紋匹配——LangFor42 以自有 rel 承載官方 Muldraugh 幾何中文版的
  全量替換容器（runtime 唯一容器、無官方 src 身分）現在可正常命中；集合外街道
  （其他地圖）跳過不受影響，1089 條官方幾何仍須全數命中才套用（缺一條整包拒套），
  具名第三方 map MOD 容器行為不變。
- **六筆稽核候選經使用者裁決翻案入網（2026-09-01）**：42.20.4 稽核的 6 筆最終
  候選（停車區表面帶×4、私人土徑×1、庭院鋪面×1）原判「非公共道路」拒絕，現以
  遊戲內導航涵蓋需求翻案為 bridge 操作入路網（原判定的事實描述保留於核准理由）；
  不進街名搜尋（searchable=false）。烘焙器對 add/bridge 幾何新增 Douglas-Peucker
  簡化（ε=0.25，同 CUT_MERGE 量級）——稽核骨架的逐格點（169 格＝169 點）直接
  入圖會讓建圖切割爆限；證據雜湊仍綁原始點，僅 operation 輸出簡化。
- **dirt-edge 訊號：隱形土路自動偵測**：與周圍曠野同 dirt 材質的土路，其可靠
  身分在路帶兩側連續的 dirt→grass 過渡邊 tile（`blends_natural_01_{64..71}`，
  逐格 lotpack 實證）——MapRendering 分類表新增 `dirt-edge` class（surfaces
  schema classes 第 6 項），稽核端以「edge 獨輪」收集（與 dirt-candidate 同輪
  連通會把 edge 帶融進曠野大面被 gate 拒；primary 輪維持全集保 v1 連通形狀）。
  edge 輪被 gate 拒者只計數不入報告（全圖裸泥塊邊緣圈上萬）；bbox 對角
  < GATE_LENGTH 預過濾；MAX_COMPONENTS 50000→500000（edge 碎片實測量級）。
  全圖重稽核抓出 8 筆 edge 候選，人工高倍裁決後 2 筆暫收——**經使用者遊戲內
  實測全數否決**（646 格帶實為西北鐵路路基：dirt-edge 訊號已知盲點，鐵路路基
  同為 dirt/gravel 邊帶；另筆保守一併撤回）。最終 edge 候選 0 收 8 拒，訊號
  管線保留供日後升版稽核，候選一律需遊戲內實測後才核准。斷頭土徑（單端接
  路網，如湖畔小屋徑）仍由 manualRoads 人工描線。
- **人工描線道路入口（manualRoads）**：表面 class 與周圍地形同質的路（如穿越
  曠野的土徑，與整片 dirt 同類、row-span 稽核無訊號可用）可由人工提供折線入
  路網——approvals 新增 `manualRoads` 區段（`m:` 前綴 id 與稽核證據空間分離，
  寬度限稽核同值域 2..8、searchable 強制 false、同套幾何驗證與 DP 簡化），
  runtime 零改動。首筆：湖畔小屋（約 10050,8250）聯外土徑，自基底 pyramid
  影像描線並經路帶疊圖驗證，東端接河畔路縱段（10781,8255）、西端止於小屋
  私人駛道（懸空端屬預期）。
- 移除已退役的小地圖齒輪面板 MOD 開關注入區塊：齒輪鈕改開統一設定視窗後，
  該注入在有 PZAPI 時到不了（面板不開）、無 PZAPI 時自行早退（值無處持久化），
  兩種情況皆為死路。無 PZAPI 環境維持原版行為（齒輪開原版圖層面板）不變；
  原版面板的 PlaceNames→Symbols 連帶與 ESC 頁同步 wrap 保留。
- 內部整理（行為不變）：統一設定視窗六處雙欄勾選網格與三處「全選／全不選」
  按鈕列收斂為共用 helper；MapBounds 顏色／透明度下拉的翻譯鍵改 ESC 頁與統一
  視窗共用同一份表；移除死碼與單一呼叫端的轉發層（合計約 -220 行）。

- 全服沙盒政策讀取收斂到單一共用入口：真相源改為引擎的沙盒設定本體，Lua 端的
  鏡像表只當備援（該鏡像任何 MOD 都能改寫，權限判定不能建立在它上面），並以 250ms 快照攤平逐幀逐鍵查表成本。舊伺服器
  缺鍵時退回與 `sandbox-options.txt` 逐鍵對齊的預設值，兩個管理員選項缺鍵即 `false`。
- 導航介接升級為 API v4：路線新增與 `pts` 嚴格對齊的 `segSurface`／`segWidth`，
  並分開回報幾何長度、路面成本與避讓懲罰。A* 以保守有界倍率偏好鋪裝替代路，
  只有碎石／土路時仍保持可達。`requestRoute`／`requestDetour` 參數與既有 route
  欄位維持相容；`getNavGraph` 尾端另回 RoadPatch／搜尋資料狀態。
- 導航路線的自動重算門檻由偏離約 28 格收緊為約 12 格（一個路幅），並新增
  `snapDist` 欄位（出發點到路線起點要越野的格數）供導航 addon 判斷路線可用性。

### 修正

- **自動駕駛會被導向 19 格外的舊路線起點、第一段斜穿房屋與柵欄**（AutoDrive
  實測回報，車在 (10716,9756) 目標 (10744.8,9717.5)）：路線起點是「上次重算當下」
  的道路投影點，只要偏離沒超過舊的 28 格門檻就一直沿用舊線。小地圖畫線時會依
  目前進度裁掉走過的段落而看不出來，但透過導航 API 取路線的 addon 拿到的是
  未裁切的整條線——等於被要求先越野 19 格回到舊起點。現在偏離超過約一個路幅
  就重算，路線起點永遠貼著自己。

  > 根因在 `_NavRoute.lua` 的 `ensureRoute` 快取沿用條件，不在 snap：以 42.20.4
  > vanilla `streets.xml`＋RoadPatch＋cell gate 離線重現，該座標的最近邊投影距離
  > 實測 1.5 格，重算後路線起點即回到 1.5 格內（修復前 19.0）。

- **原地不動時導航路線每 3 秒無謂重算一次**：路線起點本來就遠（深野外目標）時，
  偏離判定永遠成立，冷卻一到就重跑一次尋路，得到的是幾何完全相同的新路線。
  現在玩家位移不足時直接沿用既有路線，消費端拿到的路線物件也不再無故換新。

- **Muldraugh 銀行路（Bank Road，約 10662,9696）導航線在路面偏移處斜穿住家院子角**
  （AutoDrive 實測回報）：官方街道資料把該處 6 格的斜向路面偏移畫成一個直角，
  轉角頂點落在真實路面之外約 2 格，導航線與自動駕駛都會被帶進院子角落並在
  三個短彎全程爬行。道路修補層現以貼合真實路面的斜線取代該段，路線沿路面
  平順通過；街道搜尋仍找得到銀行路。

  > 資料依據 `worldmap.xml` 該路段的路面多邊形（y 9686→9698 西緣自 x 10660 斜移至
  > 10666）；稽核亦早已把 L 角東向短段判為 surface=unknown。實作為 approvals
  > `remove` 官方段 0-2＋`manualRoads` 三點折線（`m:muldraugh-bank-road-north`），
  > 尾點與保留的官方段 3 起點重合併節點；離線以官方 geometry 建圖驗證南北向路線
  > 走斜段、不再經舊頂點，AutoDrive follower 該段最低速 12→52 km/h、三 fallback 角歸零。

## [42.20.4-0.22.0] - 2026-08-30

### 新增

- 地圖顯示設定現在支援 addon 自行註冊獨立分類、勾選與下拉選項；安裝支援版本的 AutoDrive 後，齒輪視窗會出現「自動駕駛」分類，與 AutoDrive 的 MOD Options 共用同一份軌跡顯示設定
- 導航介接新增封路避讓重算能力；新版 AutoDrive 遇到道路完全堵死時，可請小地圖重新規劃繞開堵點的替代路線

### 變更

- 小地圖齒輪設定改為現代化「地圖顯示設定」：分類導覽與目前分類的檢查器分離，
  並加入不搶走遊戲按鍵焦點的跨分類搜尋；分割畫面與大字型自動切換單 pane，
  不再以全部展開的雙欄長表一次塞滿畫面。
- 地圖顯示設定預設尺寸放大；各設定分類右下新增「重設此分類」，採單次 apply/save
  批次恢復該分類預設值。效能說明加入項目分隔與更寬行長，降低密集文字閱讀負擔。
- 滑條保留原生拖曳、步進、伺服器上限與存檔行為，只換成琥珀填色細軌＋圓形旋鈕。
  地圖顯示設定標題列改用較大字型並連動放大按鈕；鎖定／解除鎖定分別使用閉鎖／開鎖輪廓，
  同時保留琥珀／灰色狀態差異，左上關閉鈕使用程序化生成的現代 X 圖示。
- 小地圖底欄的定位玩家與複製座標按鈕由 `C`／`XY` 改為 UI framework 程序化
  locate／clipboard-coordinate 圖示；自由查看時定位圖示同步轉琥珀，框架或資產缺席
  仍退回原文字標籤，九個功能、順序與間距不變。
- 資源與動物分類的導覽列新增一鍵主開關；所有分類移除數量摘要，保留更清楚的
  分類名稱與主要狀態。
- 自訂區域新增「顯示自訂區域名稱」（預設開）；關閉後只隱藏外部自訂區域的
  文字名稱，色塊、框線與圖標維持，內建資源點名稱不受影響。

## [42.20.3-0.21.0] - 2026-08-26

### 新增

- **MOD 地圖街名多語化載入層**：遊戲語言為繁體中文／簡體中文／日文時，若地圖包提供了
  該地圖的街名翻譯檔，就改用翻譯版取代地圖作者的英文 `streets.xml`；其他語言或找不到
  翻譯檔時維持原本的英文街名。小地圖與世界地圖同步生效。
  - 起因：玩家回報「雛菊郡的道路顯示英文」（2026-08-25）。查證後確認**引擎沒有街名翻譯
    機制**（`WorldMapStreetsXML.parseStreet` 直接把 `streets.xml` 的 `name` 原樣繪製，
    整個 streets 子系統零 `Translator` 呼叫），唯一安全做法是整份替換。
  - 實作為獨立檔 `MinidoracatMiniMap_StreetI18n.lua`，包裝
    `MapUtils.initDirectoryStreetData`（目錄層），與翻譯 MOD 包裝迴圈層
    `initDefaultStreetData` 正交、可共存。**全程只 `addStreetData`、絕不 `clearStreetData`**
    （清除會留下不清空間索引的幽靈街名）。
  - `registerMaps` 新增選配欄位 `streetI18n`（資料集 ID，需同時指定 `mapDir`）。舊版地圖包
    沒有此欄位＝維持英文；新版地圖包搭配舊版主 MOD 也只是忽略，不會出錯。
  - 同一地圖目錄有多個互斥變體時（如渡鴉溪本體與 Kardinal 移植版），依實際啟用的地圖 MOD
    挑選對應翻譯；無法唯一判定時退回英文，不猜。
  - 需要地圖包 **MinidoracatMiniMapModMapsFor42 0.7.0** 或更新版本提供翻譯資料。

## [42.20.3-0.20.0] - 2026-08-25

### 變更

- **新增必要依賴：Minidoracat UI 函式庫**：本版起小地圖的視窗外觀改由家族
  共用的介面函式庫提供，**必須一併訂閱**（Workshop 頁面已列為 Required
  Item）。只更新本 MOD 卻沒訂閱該函式庫的話，本 MOD 會無法載入。
- **視窗外觀與家族其他 MOD 統一**：面板圓角、配色與浮動按鈕行為改用共用
  實作，與公告欄等家族 MOD 一致；外觀細節日後由函式庫統一改進，本 MOD
  自動受益。

> 技術要點：`_Skin`／`_FloatIcon` 改為框架 thin wrapper，經
> `MinidoracatUI.v1` 的 `CAPABILITIES` 逐項探測後委派，函式庫缺席或能力
> 未就緒時退回原本的直角／內建浮鈕路徑；`mod.info` 掛
> `require=MinidoracatUIFor42`。兩邊 `versionMin` 皆 42.20.1——require 會讓
> 引擎過濾掉 build 範圍外的依賴而導致整包拒載，故本 MOD 的 versionMin
> 永不得低於函式庫的。

## [42.20.3-0.19.0] - 2026-08-22

### 新增

- **自訂區域顯示距離**（裝 Zones 等區域 addon 時出現）：統一設定視窗「顯示距離」
  區第 6 條滑條＋ESC 選項頁同組滑條（0＝不限，預設行為不變），只顯示距自己
  N 格內的自訂區域（色塊、框線、名稱、圖標一併顯隱；三個繪製 pass 與視窗候選
  快取一體生效，區域很多的伺服器可藉此讓地圖清爽並降低繪製成本）。伺服器另有
  沙盒選項「自訂區域顯示距離（格）」設全體上限——與玩家滑條取較小生效，
  【全域】全部資訊顯示距離上限亦適用。資源點（POI）與地圖包範圍框線不受影響、
  各走原有距離閘。順修（distRects 邊界加固，三模型 review 抓出）：lodRect
  快排僅對 internal provider 的 distRects 保留——POI 建構保證 distRects 含於
  整棟框，外部 addon 無此保證、快排會把實際距離內的區域錯誤隱藏；空表／
  非 table／全殘缺的 distRects 視為未提供回退 rects（原空表會整個繞過距離
  閘），殘缺元素跳過、不再讓整層區域圖層當幀消失（離線回歸鎖 A8-7e～7i）。
- **「效能說明」獨立區塊**：統一設定視窗新增第九個收合區塊（跨雙欄全寬、排在兩欄之下——長文字塞單欄會把該欄撐高留白，實測回饋）——逐項
  「名稱＋彩色等級」標題列（極低綠／低黃／中橘，Okabe-Ito 色盲友善向）＋縮排
  描述行的懸掛版式，列出各圖層／圖標的效能成因與對策（如殭屍點位隨上限檔位與
  周遭數量增加、自訂區域可用顯示距離收窄、世界地圖開啟期間成本較高），收尾
  行動建議提亮突出；附 2026-08-19 GameProfiler 實測錨點（本 MOD＋常駐小地圖
  預設設定約 0.6ms/幀＝60fps 幀預算約 4％），讓玩家自行取捨要開什麼。等級為
  機制推導——無逐項 profiler 數據，不標逐項百分比。「即時殭屍點位」與
  「自訂區域圖層」tooltip 同步補上成本說明。
- **區域開關收斂為單一開關**（搭配 Zones addon 0.5.0）：Zones addon 不再註冊
  「顯示伺服器區域」per-provider 母開關——它與「顯示自訂區域圖層」總開關作用
  完全重疊（家族唯一 zone provider，兩顆相鄰的等效開關令人困惑；實測回饋）。
  區域顯示由總開關單獨控制；per-provider 開關機制保留給未來第三方區域 addon，
  總開關 tooltip 補充與 addon 自帶開關的 AND 關係說明。先前關過「顯示伺服器
  區域」的玩家升級 Zones 後區域會重新出現（舊值失效屬預期），用總開關關回即可。
  統一視窗「伺服器區域」區塊同步改名「**自訂區域**」（四語；區塊涵蓋所有
  區域 addon 提供的區域、非僅伺服器來源，相關 tooltip 用語一併統一）。

## [42.20.3-0.18.0] - 2026-08-20

- **統一設定視窗 UX 現代化**（與搜尋視窗同一套家族皮膚語彙）：區段標題列改
  圓角淡底＋懸停亮階（原生灰框方鈕退場，展開/收合點擊區不變）；工具鈕
  （全部展開/收合、全選/全不選、恢復預設尺寸等）統一改淡框淡底、懸停走引擎
  原生漸變亮階；區段間距微調（6→8px）。皮膚貼圖缺失時照舊退回直角樣式，
  功能與佈局邏輯零變動。
- **小地圖整框現代化**：外框改圓角卡片式粗邊（2→8px，圓角與搜尋/設定視窗
  同款皮膚；不透明度滑條與穿透模式照常作用於新外框），頂部標題列改圓角
  淡填色；底部 9 顆按鈕（M／−／＋／視角／C／XY／搜尋／⚙／X，原版 5＋本
  MOD 4）統一淡框淡底＋懸停漸變亮階。同尺寸下地圖可視區各邊縮 6px（讓位
  給圓角）；皮膚貼圖缺失時整組退回原版直角樣式。順修：按鈕列排版迴圈與
  皮膚套用改顯式計數／逐鈕呼叫，除去對 Kahlua sparse-table `#` 的僥倖依賴
  （視角鈕材質降級時清單中間出現 nil，`#` 回值屬未定義行為——現值恰巧
  正確，先除雷防未來重排靜默截斷）。

## [42.20.3-0.17.0] - 2026-08-20

### 新增

- **導航目標升級「沿道路路線」**：右鍵設定導航目標後，自動沿實際道路計算路線，
  以青色路線畫在小地圖與世界地圖上（目標旗標之下）；偏離路線約 28 格會自動重新
  規劃，抵達即清除。走路開車皆可用、完全本地計算（單機／多人／專用伺服器通用，
  不需伺服器支援）。統一設定視窗與 ESC 選項頁新增「導航路線（沿道路）」開關
  （預設開）；關閉或附近無道路資料時維持原本的直線旗標指示。資料來源為各地圖
  內建的官方街道資料——有提供街道資料的地圖 MOD 自動支援；鐵路不納入路網。
  目標旗標現在**不分視野內外都顯示距離公尺**（原本只有視野外的邊緣箭頭有讀數）；
  **深野外目標也有路線**：目標離路網很遠時（軍事基地、湖心島營地等），
  自動導到「離目標最近的道路點」，最後一段越野以直線接到目標；完全無街道
  資料的極端情況也至少畫一條玩家→目標的直線方向線，不再只剩旗標。
  **修復拖動/縮放時路線片段消失**：視窗外的路段剔除先前以「抽樣點」為單位
  誤砍——前一節在畫面外、下一節橫貫畫面時，橫貫段一起被砍掉（症狀＝拖動
  地圖到某些位置，長直路段整段不見）；改以「線段」為單位判定，只有真正
  完全在畫面外的線段才跳過。
  **陣營分享的目標也有路線**——接收方以較淡的青色細線顯示通往每個分享點的
  道路路線（各自本地計算、不增加網路流量），與自己的主路線可辨。

- **地圖搜尋**：小地圖按鈕列與**世界地圖按鈕列**（爪印鈕左側）新增放大鏡鈕，
  小地圖與世界地圖右鍵選單另有「搜尋地圖…」。輸入自動判別——純數字＋分隔符
  ＝座標（支援 `12895,3499`、`12895 - 3499 - 0`、`10980,9679,0`，全形逗號也認），
  其餘＝關鍵字，同時比對街道名與設施類別（藥局、槍店等 20 類，命中即列出該類
  全部設施、依距離排序）。**街道名中英雙語可搜**：翻譯後街名（裝中文包搜
  「威廉街」）與官方英文原名（搜 "will" 出 Williams St——原名隨 MOD 內建
  對照表，翻譯包整份取代街道資料後遊戲裡已無英文名可查）都認。結果可
  「在大地圖顯示」（帶座標開圖置中＋落點金色脈動標記 12 秒，大小地圖同步
  顯示）或直接「設為導航目標」（沿路線導航接手）。
- **UI 現代化**：搜尋視窗與統一設定視窗改用家族圓角深色皮膚（與公告板 MOD
  同一套 9-slice 資產與色票）；搜尋結果列有懸停/選中高亮、類型色點與右對齊
  距離欄。皮膚貼圖缺失時自動退回原生直角樣式，不影響功能。
- **分享目標的隊友名字改用其專屬色**（與旗、路線同色一眼對應）。
- **地下室資源點標注**（玩家回報「普通民宅有官方資源圖示」的解答）：B42 新增
  的地下室設施（民宅地下酒吧、地下軍火庫、槍店倉庫等 62 筆）先前與地上圖示
  無法區分——地上看到的是民宅、圖示標的是地下 loot。現在這類條目的圖標右下
  帶「↓」角標、搜尋結果加「（地下室）」後綴；伺服器匯出 `poi_blocks.json`
  同步加選配欄 `"u":1`（additive，重置工具照舊忽略）。

- **匯出目錄說明檔**（`Zomboid/Lua/MinidoracatMiniMap/_README_*.txt`）：新增
  **日文版**（_README_JP.txt）；三語內容新增 `poi_blocks.json` **完整欄位解釋**
  （v／modversion／count／categories 與條目 b／r／u，含 b 可缺席與 u 僅地下輸出
  的語義）。說明檔是「不存在才寫、絕不覆寫」（保護管理員自己加的註記）——
  **想拿到新版請刪掉舊檔**，下次啟動自動補回。

- **修復沙盒「開始時全部已知」（MapAllKnown）在多人下失效**：42.20.3 引擎把
  多人 visited 同步後的全圖已知處理移除了（單機不受影響），伺服器沙盒開著
  也會看到未探索迷霧。本 MOD 現在在該沙盒選項開啟時自動把兩張地圖的未探索
  遮罩關掉，恢復全圖顯示；沙盒關閉時行為照舊。

- **世界地圖也能看座標、設導航目標**：大地圖（M）底部置中顯示自己的 x, y, z
  （與小地圖共用同一個「顯示玩家座標」開關）；右鍵大地圖即可設定／清除導航目標、
  分享給陣營、複製指向處座標，金旗與邊緣方向箭頭在大小兩張地圖同步顯示。
  目標照舊隨角色存檔保留——這次另修好「伺服器關閉小地圖功能時，目標讀不回來、
  或沿用到上一位角色的目標」的情況。
- **小地圖新增視角切換鈕**：按鈕列多一顆菱形鈕，一鍵在等軸測（斜角）與俯視之間
  切換，和設定視窗的「等軸測」勾選即時互相同步（原本只能從設定視窗切）。
  按鈕變 8 顆後，原本設得極小的小地圖會自動略微加寬，以免最右邊的關閉鈕被擠出邊界。

### 修正

- **穿透模式的半透明失效**：穿透開著時地圖整片維持不透明、圖片化地圖看起來像整層
  消失了。現在改成每一幀自我校正——漏套的下一幀就補上，中途失敗則自動重試
  （最遲約 1 秒內補正），透明度、拖動滑條、退出還原都不再卡住。萬一日後真的再壞，
  遊戲日誌會留下明確的失敗記錄可回報（先前這類失敗完全無聲）。
- **穿透模式的未探索區域現在會跟著變暗**：先前未探索的霧區永遠是不透明的亮奶油色，
  和已探索區的半透明格格不入、整塊很搶眼；現在霧區亮度會跟著不透明度滑條一起降低。
  受遊戲本身的繪製方式限制，霧區無法做到真正透明（夜間場景下視覺上等同透明，
  白天則是暗霧）。

> 技術要點：
> - 導航路線引擎（`_NavRoute.lua`，零第三方依賴；經三 lane review-plus＋codex
>   對抗審查逐項修正定版）：資料源＝42.20.0 官方街道 API（global `getStreets`＋
>   `WorldMapStreet` 自身讀點方法）；抽取＝byRel 主路徑（lot dirs，來源即查詢鍵）
>   ＋byIndex 兜底全容器（street 級首末點簽名去重；未知來源 src=nil——翻譯
>   MOD 的全量容器如 LangFor42 `Riverside, KY` rel，MP 不在 lot dirs、SP 其 dir
>   無 lotheader，一律 fail-open 收入不裁）；對實例全程唯讀（clearStreetData
>   的 combinedStreets 幽靈坑見 AGENTS.md，主檔小地圖補載同步加 count==0 gate）。
>   lotheader cell 勝出閘門（cell=256、段沿 cell 邊界切分、優先序取
>   `getLoadedMapDirs`、拿不到或未知來源 fail-open）擋重疊地圖敗者幽靈路。
>   連接規則＝端點量化 join（0.5 格）＋端點吸附（epMove 單向合流小 key 根、
>   世界距離判端點/段內；容差＝兩路半寬和＋4.5 路口間隙——streets.xml 是道路
>   中心線，寬路支路端點停在路緣（距幹道中心線＝半寬 3-4 格＝MP 實測「無路線」
>   根因），分隔帶公路更畫成兩條平行線（中央帶 10 格、支路只畫到近側線＝MP
>   實測「繞行 800 格」根因，離線 repro ratio 8.94→1.15）＋中段 X 交叉切割
>   （交點存 pair-time 世界座標、兩段
>   共享同一節點——移動後幾何重插 t 會令交點分裂，codex 執行反例修正）；
>   Railroad 剔除＝英文子串 ∪ vanilla 9 條鐵路首點幾何簽名（翻譯免疫、
>   「鐵路街」類真街道零誤殺）。抽取與建圖全 OnTick 分幀（48 街/tick＋
>   STEP_BUDGET=900 硬上限：pairs 桶內游標可中斷續跑）——惰性啟動、無
>   Navigator 式啟動卡頓；OnGameStart 重置引擎（client Lua 跨存檔不重載，
>   不重置＝舊世界 graph 帶進新世界）。A*＝整數節點＋SoA 鄰接＋generation
>   stamp＋二元堆；起/終各 2 snap 候選（跨圈蒐集）、代價含 approach×3 加權
>   （防穿荒地退化路線）、終點臨時注入 pcall 保護＋無條件回滾、同段直達特例。
>   每幀行進投影（±12 段窗）供裁切繪製（route 從進度點畫起、approach 連投影
>   點——否則畫回頭線）；偏航 >28 格 3s 冷卻重算、無路位移 64 格重試。繪製＝
>   單輪投影雙 pass 共用＋世界視窗 bbox 段剔除＋ppu 兩軸抽樣（≈3px/點）＋主檔
>   零配置 clipSegment（經 Core 掛出，單一實作）。離線測試
>   scripts/test_nav_route.lua 15 組（幾何／十字／T 字吸附／互吸合流／長段近端
>   T／cell gate 多來源＋src=nil fail-open（含 mutation check 實證會抓）／兩島
>   nil／複合吸附交點一致／跨桶 T／budget=1 硬上限／連續尋路回滾／終點次近
>   候選／Railroad 謂詞／負座標）。
> - 穿透壓暗改「收斂式」：`ghostFrameTick` 每幀維護（無快照自癒補壓／重壓底紙 quad
>   與未探索遮罩／滑條重壓／退場還原）；逐層先快照後寫入、`alphaUsed` 延後寫入
>   （中途拋錯必重試）、還原失敗保留快照、失敗重試 1s 節流、全失敗路徑 log-once。
>   原症狀的確切觸發路徑未實證定位（console 乾淨），故不依賴根因假說——四條候選
>   路徑都會被每幀收斂補正。
> - 未探索遮罩 alpha 是引擎 shader 硬編（`worldMapVisited.frag:13` 未探索區
>   alpha＝texel 積、頂點 `col.a` 不參與）＝`setUnvisitedRGBA` 的 alpha 恆為 no-op，
>   改以 rgb×滑條暗化近似；**勿關 `HideUnvisited` 求透明**——`UIWorldMap.java:183-186`
>   會 `setVisited(null)`，未探索區的 pyramid 影像全裸（洩漏）。
> - 深野外導航＝`nearestSnap` fallback（`findRoute` snap ring 全空時全段線性掃
>   最近投影點，O(segCount) 僅 rebuild 時跑）：實測案例 Muldraugh(12895,3498)→
>   軍事基地(5783,12484) 終點離路網 >160 格（SNAP_RING 上限）整條 noroad——
>   修後導到路網最近點、越野末段走既有 approach 直線；graph 空/建置中另有
>   drawOneRoute 直線 fallback（玩家→目標，同 approach 樣式）。回歸鎖
>   test_nav_route 案例十八＋離線重現 scripts/repro_nav.lua（吃 vanilla
>   streets.xml 全量，預設即該實測座標）。
> - 雙線公路 Z 字＝已知行為（斷口橋接做過又撤回，2026-08-20）：vanilla 幾何
>   實證 x=12513——S 1st St 止 y=3442、Dixie Highway 起 y=3458、KY-1394 雙線帶
>   （3445/3455）之間無縱向連接，A* 借最近貫穿點橫移成 Z＝合法繞行。曾以
>   「端點對齊（≤6）＋軸向間距 4~24」合成短街補斷口，但 vanilla 實測生成
>   +347 節點——遠超雙線斷口量級，大多是排屋後巷/圍籬/河岸誤接（導錯路實害
>   大於視覺瑕疵），發布前撤回（codex review 裁決）。嚴謹重做需「兩端切線同軸
>   ＋縫隙內確有橫穿道路」驗證；test_nav_route 案例十九鎖「不橋接」拓撲。
> - 路線剔除改段級（`drawRoutePolyline`，2026-08-20 拖動消失實測）：舊實作
>   點級哨兵——AABB 只驗「該抽樣點的前一節」，false 卻同時砍以該點為端的
>   前後兩條線，「前節離屏、後節穿窗」被誤砍。改抽樣（純 Lua 收世界座標）
>   與投影分離：段 AABB（相鄰抽樣點對＝實際畫的直線）判交、命中才 lazy 投影
>   （端點共享），離屏路段照舊零跨界呼叫。回歸鎖 test_nav_route 案例二十
>   （stub 恆等投影：穿窗段必畫＋全離屏零繪製）。
> - 街名雙語搜尋＝生成期烘焙（`scripts/gen_street_names.py` →
>   `shared/MinidoracatMiniMapStreetNames.lua`，1098 條英文原名＋首點）：
>   翻譯 MOD（LangFor42）是「整份取代」官方 streets.xml——runtime 只剩譯名
>   （`WorldMapStreet` 僅 `translatedText` 一欄），讀遊戲目錄原檔的
>   `getGameFilesTextInput` 非 debug 回 null，故走 POIData 同款烘焙。搜尋端
>   雙來源互補（譯名查引擎索引、英文查烘焙表），首點精確鍵去重（引擎項優先，
>   無翻譯 MOD 環境兩邊命中同條不重複列）。**PZ 更新後重跑生成器**
>   （EXPECTED_MIN 1000 擋來源異常）。
> - **點雲段拆新模組 `_Dots.lua`（主 chunk locvar 上限實爆對策，2026-08-20）**：
>   主檔加一個頂層 `local function drawSearchPing` 就觸發
>   `LexState.new_localvar Index 200 out of bounds`——Kahlua 每 FuncState 的
>   locvars 累計上限 200（`actvar[200]` 固定陣列），且 `-debug` 下 `actvarline`
>   以「累計宣告數」索引＝**非 debug 不炸、-debug 才炸**；`luac -p` 抓不到
>   （PUC 檢查同時活躍數）。殭屍/動物/載具點雲「取樣＋繪製」整段（27 個主 chunk
>   local）遷出，主檔 200→171；註冊表與公開 API（`registerAnimalGroup`／
>   `ADOTS_ART`／`adotsTexture`／篩選 UI 表）留主檔，`deriveAffine`／
>   `visibleWorldAABB`／`unifiedCsvSet` 為 zone/POI 跨段共用同樣留主檔補
>   `Core` 曝露；搜尋 ping 繪製移 `_Search.lua` 掛 `Core.drawSearchPing`。
>   `verify_mod.py` 新增守衛：全 Lua 檔 main chunk locals ≤190（`luac -l`
>   標頭與 Kahlua nlocvars 同義）。
> - 世界地圖側拆新模組 `_WorldMapNav.lua`（主檔 Kahlua 200 locvar 上限對策）：導航動作
>   抽 `Core` 閉包與小地圖共用；右鍵 wrap 保留原版 symbolsUI 工具取消與 debug/admin
>   選單（handled 時追加 player-0 單例、一般玩家自建 `ISContextMenu.get(playerNum)`
>   ——分割畫面歸屬正確）；目標載回改掛 `OnCreatePlayer`（`InitPlayer` 受沙盒
>   `AllowMiniMap` 閘門，關閉時整條載回／清槽都不跑）。
> - 視角鈕與統一視窗同源＝小地圖 `mapAPI` 的 `Isometric` 布林：按鈕每幀值變才
>   `setImage`、toggle 後重建開著的設定視窗；`RESIZE_MIN` 公式抬到 8 顆——高字級
>   字型資產下原版「小」檔寬度裝不下 8 鈕（差 6–30px），首建尺寸決策統一走覆寫
>   路徑夾下限（原版寬足夠時逐位同原版）。
> - 回歸守衛：新增 `test_worldmap_nav`（R1-R9：工具透傳／選單雙路／分割畫面歸屬／
>   選項閘／加繪順序／log-once）、`test_minimap_size`（S1-S7）；`test_ghost_gate`
>   擴至 A15（自癒／重掛失效／寫入與還原失敗／分類失敗／節流）、`test_layer_tail`
>   補 rebuilt 回傳斷言。

## [42.20.3-0.16.0] - 2026-08-19

### 修正

- **大幅降低小地圖的效能開銷**：開著角落小地圖遊玩時的整體幀成本大幅下降——
  「裝 MOD＋開小地圖」相對「不裝 MOD（該存檔無小地圖）」的完整體驗差從每幀
  +2.75ms 降到 +0.56ms（-80%；此為含小地圖功能本身的整體差值，非純 MOD 邊際
  成本；小地圖單次繪製 6.5ms → 0.85ms）。未鎖幀環境下幀率從 174 回到 239，與
  不裝 MOD 的 237 相同水準；世界地圖開啟時的繪製成本同步下降（約 10.4ms → 5.3ms）。
  根因是資源點／區域圖層每一個 UI 影格都對全部區塊（約 1700 筆）重複掃描；現在
  改為快取「視野內的候選區塊」，只在視野移動、縮放或資料變更時重新掃描（並每秒
  自動刷新一次兜底）。第三方區域 addon 資料不變時畫面與先前逐像素相同（原地改動
  資料的 addon 最多 1 秒內同步），所有圖層開關、類別篩選、顯示距離的行為
  都不變。60fps 的玩家先前多半無感（幀預算充足）；高更新率螢幕與低階機器
  受益最大。（量測註記：上述數字量自本優化主體完成時的建置；發布版另含其後
  的快取鍵嚴格化與邊界防護修訂——同樣位於每幀路徑，精確值未以最終建置重測。
  最終建置以全部回歸守衛、遊戲內冒煙與視覺驗收確認行為正確。）

> 技術要點：GameProfiler 六組 A/B 差分歸因（量測與分段工具
> `scripts/analyze_client_profile.py` 隨 repo，回歸守衛
> `scripts/tests/test_analyze_client_profile.py`）——熱點是 Kahlua 每 UI 幀
> 3 pass × 全量 zone 的篩選迴圈本身，不是 draw call、不是 pyramid 圖層、也不是
> 引擎圖標／地名。修正＝三 pass 共用視窗候選快取（`zcCandidates`）：鍵含 zones
> 表引用／篩選集／距離閘參數／zoom，視窗外擴（64 格＋halo 世界尺寸）、溢出即
> 重建，TTL 1s 兜第三方 addon 原地 mutate（時鐘回撥視為到期）、stale index 由
> sentinel 跳過不中止 pass；pass 內全部精確條件保留（候選為超集），provider
> snapshot 不變時繪製逐像素不變（同表原地 mutate 依 TTL 最多 1 秒同步）。
> 回歸守衛 `test_zone_render.lua` A14（命中證據／TTL／換表／溢出／
> stale-remove／iconRect 聯集／時鐘回撥／距離閘與移動鍵／disCats，含變異驗證）。

## [42.20.2-0.15.0] - 2026-08-17

### 新增

- **玩家座標匯出（伺服器管理用，預設關閉）**：沙盒開啟後，伺服器（單機也適用）
  每 N 秒把「在線玩家的即時座標」與「離線玩家最後一次被觀測到的座標」寫成
  `Zomboid/Lua/MinidoracatMiniMap/players_存檔名.json`，與 `poi_blocks.json`
  同一目錄。用途是讓地圖區塊重置工具（pz-rewild）在清除一塊地之前知道
  「那裡現在有沒有人、有沒有人在裡面登出」，必要時先把人踢下線再動手——
  離線玩家的角色下次上線仍站在原地，重置到他身上會直接影響玩家。**在線清單是
  完整的（引擎權威）、離線清單只是本 MOD 觀測到的子集**——檔案裡帶
  `offlineSince`／`offlineIncluded`／`offlineTruncated` 三個欄位讓外部工具判斷
  可信度，契約明訂離線清單只能當「這裡有人」的正向證據，不能反證「這裡沒人」。
  三個沙盒選項：匯出開關（預設關）、匯出週期 1–300 秒（預設 5）、是否一併
  匯出離線玩家（預設開）。管理員面板改動即時生效，把週期改小也立刻生效。
  一般玩家不需要開；開啟後玩家座標會落地成檔案。
- **匯出檔帶 Steam64（`steamId`）**：每筆玩家帶 17 位 Steam64 字串，取不到時是空字串。
  這個欄位是**客戶端回報、伺服器做過一致性檢查**的值，不是伺服器權威值——引擎沒給
  伺服器端取得精確 Steam64 的路（見技術要點）。可用於對照、稽核、跨改名追蹤，
  **不可用於授權、封鎖、所有權判定**；要權威值請在停機後讀存檔 `players.db` 的
  `networkPlayers.steamid`。非 Steam 伺服器／客戶端一律是空字串。
- **`Lua/MinidoracatMiniMap/` 下自動放一份目錄說明**（`_README_CH.txt` /
  `_README_EN.txt`，分語系各一檔）：欄位表、兩份清單的證明力差異、`steamId` 的信任
  等級、外部工具義務摘要，讓看到那堆 JSON 的人不必翻 MOD 原始碼。只在檔案不存在時
  產生，之後不覆寫（可以在上面加自己的註記），刪掉下次啟動會補回。

> 技術要點：這件事引擎沒有替代路徑（42.20.2 反編譯核對）。Lua 讀不到
> `players.db`——`ServerPlayerDB`/`PlayerDB`/`PlayerDBHelper` 都沒 `setExposed`
> （LuaManager.java:1687-2712），且 `ServerPlayerDB` 只有依 username/steamid
> ＋playerIndex 的單筆 load/update、沒有列舉 API（ServerPlayerDB.java:216-227）；
> 唯一 Lua 入口 `getSaveInfo`（LuaManager.java:8068-8071 →
> PlayerDBHelper.java:134-165）只查 `localPlayers` 的 id/name/isDead，無座標。
> 也沒有「玩家斷線」事件（全 snapshot 無 `OnPlayerDisconnect`；`OnDisconnect`
> 只在客戶端且無玩家參數，LuaEventManager.java:653、GameClient.java:354-355），
> `GameServer.disconnect` 只寫 DB 不 triggerEvent（GameServer.java:2976-3034）
> ——所以「離線」只能由在線名單（`getOnlinePlayers()`，LuaManager.java:4454-4464
> → GameServer.java:3522-3541；單機退回 `getNumActivePlayers`/`getSpecificPlayer`，
> 分支慣例同原版 XpUpdate.lua:300-303）逐輪做差集推導。這個推導模型天生不完整
> （本 MOD 開始記錄前登出的角色永遠不在清單裡），所以檔案格式必須把不完整性寫
> 出來讓消費端 fail-closed，而不是假裝完整——三家獨立 review lane 都指向這一點。
> 唯一鍵是 `(name, idx)` 而非 name：`idx`＝`getPlayerNum()`
> （IsoPlayer.java:966-974，`@UsedFromLua`，原版 server 用例 ISPickDungCursor.lua:8），
> 伺服器端由 GameServer.java:2785 指派、與 `players.db` 的 `playerIndex` 同一身分；
> 同一帳號同機分屏可有多個角色分處兩地，只用 name 當鍵會把其中一個直接丟掉
> （對「保護玩家」是漏報，最危險的方向）。
> 節流掛 `OnTickEvenPaused`（LuaEventManager.java:594）不掛 `OnTick`：專用伺服器
> 在 `pauseEmpty`＋空服時 `paused` 為真（IngameState.java:1485-1486），`OnTick`
> 被 pause 閘門擋掉（:1489 判斷、:1532 呼叫、:1623 才 triggerEvent），而
> `OnTickEvenPaused` 在 :1316、pause 判斷之前——空服也必須繼續推進檔內時間戳，
> 否則工具無法區分「現在沒人」與「匯出已停擺」。專用伺服器觸發鏈
> GameServer.java:824 `IngameState statex` → :1001 `statex.update()`，主迴圈
> `LockFPS(10)`（:823）。真實時間用 `getTimestampMs()`（LuaManager.java:9267-9274）。
> 節流刻意存「上次寫檔時刻」而非「絕對到期時刻」，否則把週期從 300 秒改成 5 秒要等
> 舊間隔跑完才生效（離線測試 S4 釘住）；時鐘被往回調時視為到期，不會卡死。
> 檔名帶存檔名（`getWorld():getWorld()`＝`Core.gameSaveWorld`，
> IsoWorld.java:3192-3194，專用伺服器上是 serverName，:1792-1793）：`Zomboid/Lua`
> 是全域目錄、不隨存檔，同機輪流跑兩個世界時共用單一檔名會互相覆寫，也讓工具端
> 指錯檔時直接「檔案不存在」而不是讀進別的存檔的座標；檔名 token 只留 `%w - _`
> （點也轉底線——含 `..` 的路徑會被 `getFileWriter` 的 `hasRelativePath` 整個拒絕，
> LuaManager.java:6730、:8519-8522）。username 一律**無損** JSON 轉義（`\` `"` 依
> JSON 規則、控制字元寫成 `\u00xx`，對照表用 `string.char` 建、實機確認 33 筆）：
> 引擎允許的 username 字元集比直覺寬——primary 只擋 `" \ / . ' ? ; @ $ ,` 與 NUL、
> 長度 2-20（ServerWorldDatabase.java:763-785），**控制字元是合法的**，coop 分屏的
> secondary 更寬（只擋空字串與全服重名，ConnectCoopPacket.java:73-80）。所以絕不能
> 消毒或截斷：那會讓 `ab\nc` 與 `abc` 撞成同一個 registry 鍵、或讓名字轉換後變空而
> 被略過——少一個在線玩家就直接推翻「online 清單完整、可反證此處無人」這條核心
> 保證（第三條 review lane 抓出）。任何一個在線玩家無法無損寫出、或出現重複
> `(name, idx)` 時，本輪**整份拒寫**（讓舊檔因 ts 過期被工具擋下），不是略過那個人。
> 讀回時另用 JSON 字串文法驗證（含 `\uXXXX`）擋下裸引號，並用位數＋值域守衛擋下
> 「400 位數經 tonumber 變 inf、再被寫成 `"x":inf`」這種非法 JSON。排序用自備的迭代
> merge sort：家規禁 `table.sort`（Kahlua 是遞迴 quicksort、coroutine 堆疊上限 3000，
> **已排序輸入退化 O(n) 深度、數百筆即溢位**，見 scripts/verify_mod.py 檔頭）——而
> 本功能的輸入正好幾乎總是已排序（registry 讀回自按名稱排序的檔案）、上限 2000 筆，
> 用 table.sort 必炸；`table.concat` 一律傳 first/last，否則 Kahlua 會走 `table.len()`
> （TableLib.java:129-138）這個家規要避開的隱性長度依賴。沙盒關閉時檔案原地凍結、
> 不寫空文件：空清單會讓工具誤判「到處都沒人」而放行刪除，比陳舊檔案更危險——
> 新鮮度改由工具端比對檔內 `ts`／`interval`（含上界，防未來時間戳讓陳舊檔永遠
> 看起來新鮮），完整契約與外部工具義務寫在 `MinidoracatMiniMapPlayerExport.lua`
> 檔頭。週期不做每輪寫後讀回驗證（I/O 加倍且下輪就覆寫），改為每 5 分鐘**整份**讀回
> 重新解析並比對 ts/count/online——`LuaFileWriter` 走 `PrintWriter`
> （LuaManager.java:12751-12770），磁碟滿／唯讀時完全靜默、`pcall` 接不到；只驗第一行
> 不夠（header 落地、後續條目被截斷的 partial write 會被誤判成功）。
> 目錄說明檔是 `42/media/exportdoc/_README_<LANG>.txt` 靜態 UTF-8 檔，啟動時原封
> 不動複製出去，**不寫在 Lua 字面量裡**：Lua 原始檔由 `IndieFileLoader.getStreamReader`
> 載入，主路徑是 UTF-8（IndieFileLoader.java:22-24），但 fallback 到
> `Core.getMyDocumentFolder()/mods` 時用的是平台預設編碼（:25-27）——本機 linked-mod
> 走的就是 fallback，第一版把中文寫在 Lua 字串裡，實機寫出來整段是 U+FFFD 亂碼
> （`getFileWriter` 本身是 UTF-8，LuaManager.java:6753-6754，壞的是載入端）。改走
> 靜態檔後全程 UTF-8：`getModFileReader` 明確 `StandardCharsets.UTF_8`
> （LuaManager.java:6005，先找 versionDir 再找 commonDir）→ `getFileWriter` 寫出，
> 實機驗證與來源 byte-identical、管理員自己加的註記在重啟後完整保留（exists-only，
> 第二次啟動連來源檔都不讀）。守衛 `python scripts/tests/test_export_doc_assets.py`：
> 檢查 Lua 宣告的來源檔都存在、說明檔是合法 UTF-8／無 BOM／無 CRLF，以及
> **ExportReadme.lua 的非註解行不得含非 ASCII**（防有人又把中文塞回 Lua 字面量）。
> Steam64 只能由客戶端回報：`IsoPlayer.getSteamID()` 回 Java long
> （IsoPlayer.java:6412-6414），經 Kahlua 的 `NumberToLuaConverter` 一律轉成 Double
> （KahluaNumberConverter.java:141-142）——Steam64 約 7.66e16，該量級 double 的 ULP
> 是 16，末一兩位被靜默捨去，`tostring` 還會給科學記號；而引擎會把 SteamID 字串化的
> Lua 入口全都擋在客戶端（`getCurrentUserSteamID()` 條件含 `!GameServer.server`，
> LuaManager.java:9366-9372；`getSteamIDFromUsername()` 條件含 `GameClient.client`，
> :9470-9479；`SteamUtils` 未 setExposed；字串化的值只出現在
> ScoreboardUpdatePacket.steamIdsString，而那個 triggerEvent 也只在客戶端）。所以
> 客戶端用 `getCurrentUserSteamID()` 取精確字串、經 `sendClientCommand` 回報，伺服器
> 驗格式（17 位、≥ individual 區段起點）＋一致性（把回報字串 `tonumber` 後與自己的
> `getSteamID()` 比對，兩邊都是同一個 long 的 double 投影）。亂填會被擋下，但同一個
> double bucket 有 15-16 個相鄰 Steam64（實測任取一個 7.66e16 量級的值，其 bucket
> 涵蓋 15 個連續整數）且多半也是真帳號，所以只能標 client-reported,
> consistency-checked。回報協議：**只有驗證通過才回 ack**（失敗也 ack 會讓客戶端誤
> 以為完成而停手），ack 帶 slot、客戶端逐 slot 記帳（分屏時每個 slot 是獨立的
> (username, playerIndex) 身分）；客戶端掛 OnTick 輪詢而非 OnGameStart——後者在
> MP 連線就緒前（IngameState.java:761 vs :764-767、UpdateStuff():563）
> `sendClientCommand` 可能是 no-op。輪詢的每一條「未就緒」路徑（Steam 尚未初始化、
> IsoPlayer 還沒建立、onlineID 還是 -1）都只能等下一輪，**不能放棄**，否則功能會
> 靜默失效、而且在非 Steam 環境下與「本來就沒有 Steam ID」無法區分；真的放棄一定
> log。離線測試 `lua scripts/test_steamid_report.lua`（21 檢查，專門釘住這些窗口）。
> 主開關關掉再開時 `offlineSince` 會重設成當下：停用期間完全不觀測，那段時間登出的
> 角色不會進 registry，沿用舊起點等於宣稱空窗期的人也在清單裡。
> 離線測試 `lua scripts/test_player_export.lua`（198 檢查：黃金字串／無損轉義與文法
> 驗證邊界／數字位數與值域守衛／路徑消毒／讀回嚴格解析與拒絕（含重複鍵）／同名分屏
> 不塌縮並跨重啟保座標／排序正確性與穩定性含 2000 筆已排序輸入／節流與時鐘回跳／
> 離線差集／死亡剔除／writer 缺席／截斷檔／靜默寫入失敗與 partial write 抽驗／
> 不可表示名稱與重複鍵的整輪 abort）。真機驗證：隔離 `-cachedir` 的專用伺服器在
> `PauseEmpty=true`＋空服下 `ts` 每 ~5.05 秒前進、跨重啟讀回 registry（含負座標、
> 同名分屏與 `\u000a` 名稱的無損 round-trip）、輸出 `(name, idx)` 升序正確、
> 撕裂／裸引號檔被拒絕且 `offlineSince` 重設為當下。

### 修正

- **沙盒選項說明裡的輸出路徑被吃掉**：新加的說明裡用了角括號包住存檔名，tooltip 實際
  顯示成「輸出 .json（存檔名＝…」——整段輸出路徑憑空消失。原因是 tooltip 由 rich
  text 面板渲染，角括號會被當成標記，**而且同一個 token 裡角括號之前的文字會一起被
  丟棄**；中日文沒有空格，整句連成一個 token，所以殺傷範圍是整句而不只是那對角
  括號。現在移除說明裡所有角括號寫法（`players_存檔名.json`），並把四語說明的換行
  統一成實體換行、順手精簡過長段落。**翻譯改動要重啟遊戲才生效。**

> 技術要點：tooltip 由 ISToolTip 的 ISRichTextPanel 畫。`:459-486` 的 tokenizer 以
> 空格切，遇到同時含 `<` 與 `>` 的 token 就只取 `<...>` 內的標記字串丟給
> `processCommand`，其餘部分完全不寫進 `self.lines`——原版沙盒 tooltip 自己也在用
> rich text 標記（`<BHC>`、`<RGB:1,1,1>`），所以這是設計行為、不是 bug，寫文案時
> 就得避開角括號。單獨的 `>`（英文 `N > 0`）安全，因為條件要求 `<` 與 `>` 同時出現。
> 換行方面兩條沙盒 UI 路徑（新遊戲頁 SandboxOptions.lua:665-666、伺服器設定頁
> ServerSettingsScreen.lua:2522-2525）都會在交給控制項前做
> `tooltip:gsub("\\n", "\n")`，所以**字面 `\n` 本來就會正常換行**，既有 13 條與原版
> 那 35 條都沒問題；本次改用實體換行是因為它在兩條路徑都成立（gsub 找不到字面
> `\\n` 即 no-op，接著 ISRichTextPanel:445 把實體 LF 換成兩側帶空格的 `<LINE>`），
> 一個檔案裡只留一種寫法比較好維護。新增守衛
> `python scripts/tests/test_sandbox_tooltip_richtext.py`：把該 tokenizer 逐句移植
> 過來跑四語 160 個翻譯值，「含 `<`」「會被吞掉的文字」「連續換行」任一出現即 fail
> （negative test 能復現 `players_` 整段消失的現象）；字面 `\n` 也一併擋掉，理由是
> 寫法一致，不是它會壞。

- **兩張 MOD 地圖重疊時，小地圖影像顯示錯的那一張**（玩家回報：同時啟用
  Grapeseed 與 Greenleaf 時，Grapeseed 北緣兩個區塊在小地圖上「消失」、
  變成空草地，但遊戲世界與原版小地圖都是正確的城區）：兩張地圖真的共用
  3 格 cell（(24,42)(25,42)(26,42)，squares 6144,10752–6912,11008），引擎
  遇到這種衝突時以「地圖優先序最前者」勝出，而本 MOD 的影像疊層先前是照
  註冊清單字母序堆疊，跟引擎的勝出者無關——恰好把 Greenleaf 那片空草地
  疊在 Grapeseed 城區上面。現在影像疊層改為跟隨引擎的地圖優先序，
  地圖包登記的影像層一律顯示「遊戲實際載入」的那張地圖（第三方地圖 MOD 自附的
  約定檔名影像共用同一個檔名、在引擎裡是同一層，上下規則與此相反，維持原本的
  最上層位置、不納入這項一致性保證）。受影響的不只這一對：以本機安裝的
  69 個地圖 MOD（90 個地圖目錄）逐格比對 lotheader，共 82 對真的共用 cell
  （Kingsmouth North×Megurigaoka 12 格、Atlanta×BlackpineCounty 10 格、
  Grapeseed×Hartburg 6 格……），這些組合同時啟用時先前都可能顯示錯的那張。
  註：重疊 cell 本身是地圖 MOD 之間的衝突（遊戲選 MOD 畫面也會警告），
  兩張地圖不可能同時完整顯示；本修正保證的是「小地圖與你腳下的世界一致」，
  想換成另一張請用遊戲的地圖排序調整優先序

> 技術要點：引擎 `IsoMetaGrid.CreateStep1` 對 MapFiles 反序 `putAll`
> （IsoMetaGrid.java:1424-1428），故 `getLotDirectories()`／`getWorld():getMap()`
> 分號串的 index 0 最優先（原版註解 ISMapDefinitions.lua:25-28
> "highest priority (mods) to lowest priority (vanilla)"）；順序由
> MapGroups.setPriority／setOrder(ActiveMods.getMapOrder()) 決定。
> `getLoadedMapDirs` 原本把該串解析成集合（值 true）、順序被丟棄，現改存
> 1-based 優先序 index，mapDir 閘門改判 `~= nil`。新增純函式
> `orderByMapPriority`：只重排「對得上已載入目錄」的條目、並就地填回它們
> 原本的位置，pri 遞減（層間繪製正序、後建在上 ⇒ 最高優先最後建、畫最上；
> WorldMapRenderer.renderCellFeatures:933-938）。identity 解析鏈＝registry 的
> `mapDir` → zip basename → `getMapFoldersForMod(modID)` 反查
> （LuaManager.java:5390-5445）。反查是必要的：地圖包 91 筆有 3 筆 zip 名 ≠ 資料夾名
> （Atlanta - Safe Zone 目錄帶社群後綴、EchoCreek 目錄夾中文、Kardinal Raven Creek
> 的目錄其實叫 Raven Creek B42），其中 Atlanta 與 EdsAutoSalvageB42 真的共用 3 格
> cell，光靠 zip 名會讓它排不進優先序、繼續被壓在下面（codex review 抓出的正式
> 資料反例）。反查只在「該 mod 總共只提供一張地圖、且那張已載入」時成立：mod ID →
> 資料夾是多對一，引擎沒有 zip→資料夾的關聯，多張時拿「當下只載入一張」當識別會把
> 別張的 zip 標成它的 identity（codex review 第二輪抓出），一律放棄不猜、由 registry
> 明寫 `mapDir`；有 mod ID 卻仍解析不到的條目會 log 一行（正式資料應為 0 筆），基底與
> legacy 不進這條路徑、不會每次開圖刷屏。基底全圖與 legacy 兩者都以顯式
> `sortable = false` 固定位置（基底恆在最底、legacy 恆在最上），不靠「沒有 mapMod」
> 或「zip 名對不上目錄」的巧合——PZ 不禁止把地圖資料夾命名成 Muldraugh_KY 或
> minidoracat_minimap，隱含隔離在撞名時會破功（code review 抓出）；
> legacy 之所以要完全排除：全體共用同一檔名、去重後只有一層，層「內」同名多 zip
> 是反序迭代（先註冊者在上，WorldMapPyramidStyleLayer.java:46-51），與層間規則相反，
> 硬套會讓低優先者反而蓋住高優先者（codex review 抓出）。連帶把 canonical 檔名
> 定為 `registerMaps` 的保留名並拒收：同名兩份條目（一份來自 registerMaps、一份來自
> 自動掃描）會互搶同一圖層，前者被排序搬走、後者又被 layerId 去重丟掉，canonical
> 層可能落到其他地圖層下面（codex review 第四輪以 probe 重現）。
> 已知邊界（刻意不處理）：這套排序只管層間順序。同一個 zip 檔名的多個條目會被去重成
> 一層、層內是反序繪製（先掛在上），與層間規則相反——若同名條目來自不同路徑，層間
> 排序反而會讓低優先者畫在上面（codex review 第五輪以 probe 指出）。不修的理由：唯一
> 真實存在的同名多路徑情境是第三方自附影像那條 lane（多個 addon 共用約定檔名、各自
> bounds 對位，是刻意設計），而它已 `sortable = false`、順序等同本次修改前；兩個地圖
> 包提供同名 zip 時，兩份影像可能都合法且不重疊，「誰該在上」本來就沒有定義，去重會
> 直接弄丟一張圖。真要支援得按檔名分組反轉該組註冊序，等實際生態出現再做。
> 排序用插入排序（家規：Kahlua 遞迴 quicksort 會堆疊溢位，見 verify_mod.py）、
> 嚴格 `<` 才位移＝相等保留原序，n＝已啟用地圖數；只在掛載流程跑（開世界
> 地圖／小地圖 init／樣式重掛），不在每幀路徑上。`getWorld():getMap()` 拋例外時留下診斷
> （每次呼叫一行；框線重建與影像蒐集各呼叫一次，故一次 apply 會看到兩行。
> DEFAULT／空串是世界未 init 的正常路徑，維持靜默）。離線測試
> scripts/test_mapdir_gate.lua 補上回歸案例：雙向 map order、3 筆完整排序、同優先序
> 穩定性、重複目錄首見優先、明示 mapDir 不得 fallback、unknown 原位、反查含糊／
> 未載入／mod 不存在、log 靜默契約、正式 MAPS 的 sortable 契約、基底與 legacy 的
> 檔名撞名、registerMaps 拒收保留名，以及 collectPyramids 的整合案例（不手動塞
> mapDir，走完蒐集→identity 補齊→排序，含 Atlanta×Eds 雙向優先序、含糊時提示補
> mapDir、地圖包圖層關閉）。十個變異注入（升序、`<=`、寫回 1..n、忽略 sortable、
> 忘記傳旗標、忽略保留名、多地圖亂猜、丟失優先序 index…）全部被測試攔下

## [42.20.1-0.14.2] - 2026-08-14

### 變更

- **「資源點區塊用整棟範圍」改為預設開啟**（含既有玩家一次性套用）：
  0.14.0 引入時預設關（逐房間矩形），實際使用回饋是整棟範圍在導航上更
  直觀——一眼看出建築物邊界，搭配 0.14.1 的地標全縮放可見與描邊，區塊
  模式開箱即用。已在 0.14.0/0.14.1 存過選項的玩家也會在更新後首次進主
  選單時一次性套用新預設；之後偏好逐房間的玩家取消勾選即可、不再干預。
  其餘行為（圖標位置、顯示距離）不受影響
- **console／log 訊息全面改為英文**：遊戲 console 輸出走系統編碼（非
  UTF-8），中文 log 在 console.txt 與 DebugLog 裡是亂碼——排障時讀不了、
  玩家貼 log 回報也失去意義。既有診斷訊息全數改為英文（本版新增的訊息
  亦為英文）；遊戲內 UI 的多語翻譯不受影響

> 技術要點：預設值四點同步翻轉（addTickBox 註冊、POI provider 讀取與
> 簽章 fallback、統一視窗初始值）＋四語 tooltip 的「預設」標記換邊；
> 渲染測試補預設值契約案例（選項未設時帶 b 條目須畫整棟框）。一次性
> 遷移必要性：PZAPI save() 整檔全寫——玩家改過任何選項就把沒碰過的
> false 一併落檔、load 時存值優先於預設，只改註冊預設救不了既有安裝；
> 存檔的 false 幾乎全是「沒動過」而非刻意選擇（選項上線僅一天），比照
> MapImagery 0.10.1 前例翻轉＋marker 冪等（測試 W1-W6 六案例）。順序刻意
> 與前例相反：先寫 marker、以「存在性」讀回驗證落地，通過才翻值——marker
> 沒落地時翻值會在下次啟動重翻、覆蓋玩家事後的刻意關閉（codex review
> 反例；PrintWriter 吞 IO 例外，pcall 接不到，讀回是唯一證據）。寧可漏翻
> （fail closed 下次重試），不可重複干預。marker 自本次起集中放
> Lua/MinidoracatMiniMap/ 子資料夾（與 poi_blocks.json 同處）；既有兩個
> 根目錄 marker 屬歷史產物、原地不動。

## [42.20.1-0.14.1] - 2026-08-14

### 修正

- **一般民宅被標成超市／醫療／餐飲等資源點**（玩家回報 (6724,5447)、
  (10091,8257)）：官方地圖在住家裡放小型設施房間——客廳角落 2 格的雜貨儲藏
  櫃、二樓的家庭診間、廚房旁的肉品處理間——是為了讓那個角落刷出對應物資，
  先前把它當成整棟建築的身分，地圖上看到超市圖標、跑過去卻是民宅。現在住家
  裡佔比過小的設施房不再定義整棟身分，**23 棟民宅退場**；其中 (6065–6753,
  5321–5473) 一帶 6 棟假超市與 Louisville (13288–13610) 一帶 5 棟假服飾店
  是同批建築範本的群聚，在那兩區會連續踩到。另有 2 棟的主身分被小房間搶走
  的錯誤一併翻正（182 格的雜貨行原本標成服飾店、181 格的服飾店原本標成
  五金行）。真設施不受影響——軍事基地、療養院、醫院大樓、商場與公寓一樓的
  小型藥局／店面判定皆不變。資源點 1692→1669 筆
- **大型地標拉遠時從區塊模式消失**（實測回饋：March Ridge 地下軍事基地拉遠
  看不到、拉近又看不進整棟）：縮放 LOD 的「拉遠隱藏」檔位原是為了把已縮成
  色點的普通建築收掉，但 177 格寬的地堡在最遠縮放仍是明顯色塊、卻被一視
  同仁藏掉；且名稱要拉得很近才顯示，屆時整棟已塞不進視窗——大型地標從來
  沒有「整棟＋名稱」同框的縮放檔位。現比照伺服器區域的既有規則（最長邊
  超過 100 格不參與縮放 LOD）：20 筆地標級資源點（軍事基地、警局園區、
  商場等）改為任何縮放皆可見（含名稱），其餘資源點的縮放行為與效能結構
  不變。同場實測的第二發現：軍事的橄欖綠染色疊在地堡迷彩地形上幾乎看不
  出來、而暗色描邊原本只在拉最近時畫——「有染色卻看不出區域」；此類地標
  區塊的暗色描邊改為所有縮放皆畫，中距整棟同框時就有清楚邊界

> 技術要點：住宅門檻＝建物房間總面積 ≤800 格且臥室佔比 ≥10% 時，撤銷商店型
> 觸發房的免面積門檻豁免（觸發房佔比 <10% 則落給下一候選，與 accessory gate
> 同水位）。三條件缺一不可，逐項以全圖 9254 棟 counterfactual 定案：缺總面積
> 條件誤殺 14 棟機構型建物（臥室是宿舍不是民宅——地下軍事地堡、療養院、醫院
> 大樓）、缺臥室條件誤殺 7 棟店住混合真店面、缺佔比條件誤殺小坪數真店面。
> 800 格斷點取自實測落點（761 格民宅與 815 格真書店之間自然分離），非猜測。
> poi_blocks.json 隨之 count 1692→1669、2 筆條目的 cat 與 r 變動（b 不變）
> ——外部工具依契約驗 modversion 即可辨識，故本次必須 bump 版本號。

## [42.20.1-0.14.0] - 2026-08-14

### 新功能

- **資源點區塊「整棟範圍」模式**：新選項「資源點區塊用整棟範圍」（預設關）
  ——勾選後區塊改畫整棟建築外框（同棟跨樓層紀錄取聯集），不勾維持逐房間
  矩形；圖標錨點與顯示距離判定不受影響。ESC 選項頁的資源點選項同步獨立成
  「資源點（POI）」群組
- **伺服器區域獨立設定區**（裝 Zones addon 才出現）：統一視窗新增「伺服器
  區域」區——伺服器 zones.json 各區域可帶 `category` 欄位，視窗依實際資料
  動態生成逐類勾選（含全選／全不選；含逗號等不可逆編碼的類別名自動排除
  於 UI）；「區域名稱不受縮放限制」開關（預設開，拉遠也能找到區域位置）；
  範本生成的語言下拉與按鈕移入此區。**視窗開著時區域資料到貨自動刷新**
  ——按下生成或管理員 /reloadzones 後類別勾選即時長出來，不必重開視窗
- **區域縮放三檔 LOD**（provider schema 擴充 `lodRect`）：拉遠到中距只畫
  聯集外框色塊、再遠整組隱藏，拉近才畫逐矩形細節與名稱——大量建物尺度
  區域在全圖視野下的繪製成本大減；`haloAlpha`（暗色描邊）、`iconRect`
  （圖標錨點覆寫）、`distRects`（距離判定覆寫）一併開放。Zones addon
  0.4.0 起自動附掛 lodRect，舊 addon 傳統欄位照常運作
- **poi_blocks.json 匯出（外部工具契約）**：啟動時（單機進世界／伺服器啟動）
  自動把 1692 筆資源點（20 類、含整棟外框）寫到
  `Zomboid/Lua/MinidoracatMiniMap/poi_blocks.json`，供外部程式（如建築重置
  工具）讀取「地圖上實際顯示的資源點區塊」——與 Zones addon 的 zones.json
  同根目錄。payload 帶 modversion 新鮮度標記；寫後逐行讀回驗證，通過才記
  成功；工具端義務（整檔嚴格解析／count 對數／版本驗證／容忍不存在）
  文件化於檔頭與 README

### 變更

- **資源點區塊視覺改版：框線退場、暗色描邊上場**：區塊不再畫邊線，改為
  區塊底下墊一層外擴 2px 的暗色底（halo）——邊界對比不輸框線，每矩形的
  繪製呼叫從 4 次邊線＋1 次填色降為 2 次填色（實測回饋定案：純無框線
  難辨識，halo 是清晰度與效能的折衷）
- **全面效能優化**（實測 244 FPS 場景整輪驗證）：區域渲染對沒有填色／
  框線／圖標的資料整段跳過不空跑；殭屍／動物點位的座標轉換改用投影快取，
  大量圖標同時顯示時每幀成本大減；小地圖隱藏時整條渲染流程提早結束
  （導航抵達判定照常執行）；座標列顯示與資源點設定讀取加上快取與節流
- **需要遊戲 Build 42.20.1 以上**：poi_blocks.json 需要 `.json` 寫入
  （42.20.1 白名單解禁，同 Zones addon 0.3.0 的版本門檻），`versionMin`
  同步升起，避免 42.20.0 上功能靜默失效

### 修正

- **同一棟建築出現多重外框／多重圖標**：警察局等建築的地下室與地面層在
  原始地圖資料是兩筆獨立紀錄（外框差幾格），先前各自成點——疊框、雙圖標，
  跨類別時同棟還會掛兩個類別。改以「同名房間共享同座標矩形」判定同棟合併
  （全圖 27 組、1704→1692 筆），一棟恰好一個外框＋一個主身分
- **統一視窗長提示句溢出欄寬**：提示文字改逐 UTF-8 碼點貪婪斷行（拉丁字
  在空白處回退斷行），大字型與長句不再破版
- **區域類別篩選收口**：類別名含逗號或保留字時 CSV 停用清單無法可逆表示
  ——此類類別排除於勾選 UI（照常顯示區域）；provider 取類別失敗由靜默
  改為逐 owner log-once

> 技術要點：效能輪的機制——zone 三 pass 空跑閘為 hasFill/hasLine/hasIcon
> 表級旗標；熱路徑比較鏈取代 math.min/max（math.* 是 JavaFunction 跨界呼叫）；
> 仿射投影快取每幀 6 次 Java 取樣建 2×3 係數、其餘純 Lua 乘加；POI 重建簽章
> 15-tick 節流＋選項快取。同棟合併是兩段式分組——先精確 bbox 相等、再以 union-find 合併
> 「共享同名同座標房間矩形」的紀錄（rect 是世界座標實體地面，同名同座標
> ⟹ 同棟垂直堆疊；全 corpus 17 組全數為跨樓層對、60 對相鄰同層建築零誤併，
> 逐組不變式測試鎖住）。仿射投影快取每幀取樣 6 次建立 2×3 仿射係數，錨點
> 取視窗中心附近整數格壓 float32 精度誤差；LOD 門檻 scale<1.5 隱藏、<6 聯集
> 色塊、≥6 全細節。poi_blocks 匯出經四 lane review（Claude base／
> silent-failure／tests＋codex）：LuaFileWriter 走 PrintWriter 吞 IO 例外
> ——pcall 接不到磁碟錯誤，讀回驗證是唯一可靠完整性證據；離線測試 27 例
> （黃金字串＋真實資料煙霧＋整檔 stub 六情境 boundary）。

## [42.20.0-0.13.0] - 2026-08-07

### 新功能

- **資源點（POI）顯示距離**：新增沙盒選項，建築的資源點需其「顯示中的分類
  房間」最近點距玩家 N 格內才顯示（區塊／框線／名稱／圖標整棟一致顯隱）。
  建議 300＝約一個街區群，保留探索感；僅影響內建資源點，地圖包範圍框線
  不受影響
- **全域距離上限（沙盒）**：一鍵管住殭屍點位／動物／載具／安全屋／資源點
  五類距離，最優先生效——個別距離選項只能設得更嚴（兩者取較小），不能放寬
- **玩家自訂顯示距離**：統一設定視窗新增「顯示距離」區（ESC 選項頁有同組
  滑條），五類各一條、0＝不限。伺服器有設限時數值標直接顯示「你的設定／
  伺服器上限」（如 `200/300`），不必從滑條可拉範圍反推；兩值取較小生效——
  玩家只能收緊自己的視野，不能放寬伺服器限制

### 變更

- **沙盒選項重排**：同類相鄰——全域上限置頂並加【全域】標記、資源點移入
  顯示類別群、陣營分享等功能權限墊底。沙盒頁沒有標題或分隔線機制，整頁是
  依定義順序渲染的扁平清單，排序本身就是唯一的分組手段；值以選項名存取，
  重排不影響既有存檔（既有 MP 伺服器的 SandboxVars.lua 下次存檔會依新順序
  重寫，讀寫兩向皆安全）

### 修正

- **大字型下設定視窗滑條破版**：PZ 字型大小 26px 以上時，欄寬上限（不隨
  字型縮放的硬常數）會讓滑條軌道寬歸零甚至倒轉，而該值被當除數——0 會得
  nan 並經 setCurrentValue 寫進設定檔。軌道寬補下限；英文「資源點距離」
  標籤縮短——它原本是全視窗最寬標籤，而欄寬是共用值、會連坐壓縮八個區塊
  的每一列（日文在 33px/38px 的既有破版一併被下限擋住）

> 技術要點：距離合成收口於 sandboxDist／displayDist 兩層（伺服器個別值×
> 全域上限×玩家自訂取最小正值），五個消費端（殭屍取樣／動物／載具／安全屋
> ／POI）統一改走 displayDist。POI 距離逐 rects 判距，lodRect（分類房間
> 聯集 AABB、非建築 bbox——codex review 以實資料證明兩者可差數十格）僅作
> 下界快速排除；閘門置於螢幕裁切之前，故啟用距離閘反而比不啟用更省。滑條
> step=1：沙盒上限是任意整數，step>1 會讓存值被 ISSliderPanel 先進位再夾限，
> UI／存值／實效三方漂移。守衛測試新增 31 例（全域上限取小 7、displayDist
> 合成 9、滑條上限讓位 8、數值標格式 7）＋zone 距離閘 A8 六組，另有三道
> 原始碼層守衛（Client\* 命名四方對齊、unifiedSliderText cap 傳參、軌道寬
> 下限）——後兩者正是雙邊 review 抓到、helper 單測抓不到的缺口類型。

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
