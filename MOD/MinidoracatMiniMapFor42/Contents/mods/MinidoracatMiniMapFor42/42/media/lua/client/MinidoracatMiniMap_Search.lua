-- MinidoracatMiniMap_Search.lua
-- 本檔範圍：地圖搜尋／收藏／行程／道路視窗（0.17.0 搜尋；v6 多停靠點行程頁；收藏頁、道路頁見下）——單一視窗四頁，
-- 共用放大鏡入口、標題列與 owner-transfer。
--
-- 【搜尋頁】輸入自動判別「座標 or 關鍵字」：
--   - 座標：整串只含數字與分隔符（, - 空白 . 與全形逗號）且抓得到 ≥2 個數字
--     ＝座標（支援 "12895,3499"、"12895 - 3499 - 0"、"10980,9679,0"；z 容忍
--     但忽略——地圖是 2D。負號當分隔符：世界座標恆正，同主檔 XY 鈕註記的
--     原版 teleport UI 慣例）
--   - 關鍵字：比對街道名（NavRoute 引擎抽取的翻譯後街名——LangFor42 中文街名
--     直接可搜；"KY-841" 含字母走關鍵字不會誤判座標）＋POI 類別名（20 類翻譯
--     名，命中即展開該類設施、依距玩家有界最近-N 選擇）＋收藏名稱（排在最前面，座標查詢不比對）
-- 結果動作：在大地圖顯示（ShowWorldMap 帶座標開圖，ISWorldMap.lua:1500，並落
-- Core.searchPing 由雙表面畫脈動標記）／加到行程最後（Core.navPromptTarget
-- op=append，主要動作）／插在指定停靠點之前（原生子選單列出待前往站，選項建立時
-- 就捕捉 owner＋revision＋錨點 id，延遲點擊不得插到別的位置；長站名只放有界短標籤，
-- 全文走既有可捲確認面板讀完再套用——原生選單寬度＝最長選項全文寬，不封頂會出畫面）
-- ／先去這裡（op=priority：插在第一個待前往站之前並明確開始導航，不啟自駕）／取代整趟
-- （op=replace，次要動作；會丟待前往站時先確認）。選不到結果時（空字串／載入中／查無命中的
-- 說明列）這些動作一律停用——不留按了沒反應的按鈕。
-- 未輸入時列出收藏（家第一，權威在 _Places.lua，本檔只現查唯讀狀態）；收藏列的設為家／改名／移除
-- 直接列在「動作…」與清單右鍵。行程頁另有永遠可按的「回家」。
--
-- 【收藏頁】（2026-10-21 設計稿 minimap-places-entry-1021 作答）不看搜尋框，一律列出家與收藏；
-- 沿用搜尋頁的清單、底部按鈕與右鍵，只是沒有搜尋框、清單接在分頁列下面。右鍵「收藏」子選單的
-- 「管理收藏...」開這一頁（_Places.lua）。
--
-- 【行程頁】行程權威完全在 _Itinerary.lua：本檔每次刷新用 Core.navItineraryState
-- 現查唯讀狀態，**不留第二份 stops／revision**，所有變更一律經
-- Core.navEditItinerary（帶 expectedRevision 的單筆原子編輯）／navPauseItinerary／
-- navGuideItinerary／API.startNavItinerary。取代與清空走共用確認面板，
-- 對話框捕捉 owner（角色物件本體）＋revision＋資料損壞旗標，三者任一不符即
-- 拒絕——舊對話框不得覆蓋新行程（契約 docs/addon-api.md §6.5）。
-- 行程頁頂部是接續模式的兩顆明確選擇鈕（自動接續／逐點停等），走
-- API.setNavContinuation(pn, expectedRevision, enabled)：只改這份行程的設定，
-- 不發車、不煞車、不換目標；舊版 Core（navApiVersion<7 或缺 setter）一律當不支援，
-- 在清單裡說明並停用，不做假操作。逐站「停等」標記走 edit op pause(stopId, bool)，
-- 只動待前往站的旗標，自動接續模式同樣尊重它。
--
-- UI：ISPanel 自組＋家族圓角皮膚（Core.Skin，移植自 NoticeBoard 的 NBSkin；
-- moveWithMouse＝ISPanel 內建拖曳，ISPanel.lua:26-113）。載入序註記：本檔
-- 字母序在 _Skin.lua 之前——Core.Skin 一律於事件期（開窗/繪製）動態取用，
-- 缺席（貼圖壞/測試環境）時 Skin 自身退回直角、本檔另有 nil 防呆。
-- 效能紀律（review 定案）：doSearch 只在輸入/引擎狀態變化時跑（雙欄位 cache
-- key，零每幀配置）；行程頁以 revision/phase/reason/預覽狀態/玩家 8 格位置桶
-- 組成純純量 cache key，站著不動時零重建。兩份清單的右欄文字/寬度/徽章全在
-- 刷新時一次性預格式化，doDrawItem 每幀零配置、視窗外列早退。
-- 版面：尺寸與換列一律按 getFontHeight／MeasureStringX 實測字寬算（大字級／
-- 窄 viewport 自適應），主要動作固定在清單之外的底部按鈕區、永不隨清單捲失；
-- 名稱放不下時整列改兩行（完整名稱優先於同行顯示座標）。
-- 輸入可達性：鍵盤 TAB 進入焦點環（琥珀框）、方向鍵移動／改選、Enter 觸發、
-- ESC 先解焦再關窗（關窗必 unfocus，否則不可見輸入框續攔遊戲鍵）；輸入框聚焦
-- 期改走原版 onOtherKey／onPressUp／onPressDown／onCommandEntered 鉤子，不與
-- 遊戲移動鍵搶事件。手把走原生 joypad focus（setJoypadFocus＋A/B/X＋方向鍵，
-- 文字輸入交原版 OnScreenKeyboard）。
-- 分割畫面（codex review）：視窗單例採 owner-transfer（同 _Settings 慣例）——
-- 他人開窗時轉移擁有者並重刷，不誤關；searchPing 帶 pn，僅擁有者的表面繪製；
-- 行程一律以擁有者 pn 現查，不跨槽位帶資料。
-- 拆檔緣由：同 _Settings/_NavRoute（主檔 Kahlua 主 chunk locvar 上限）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

local MAX_STREET_RESULTS = 40
local MAX_POI_RESULTS = 30
local PING_MS = 12000
local MSG_MS = 6000

--------------------------------------------------------------------------------
-- 解析與搜尋（純函式）
--------------------------------------------------------------------------------
-- 座標判別：全串僅由數字/小數點/分隔符組成才視為座標（"1394號公路" 含中文、
-- "KY-841" 含字母→關鍵字）。回 x, y（floor 後整數）或 nil。
-- 全形逗號（U+FF0C）以碼位 65292 比對：Lua 字面量禁非 ASCII（AGENTS.md——
-- linked-mod fallback 讀檔走平台編碼，非 ASCII 字面量會炸成 U+FFFD）；
-- Kahlua 字串為 Java String（UTF-16 unit），string.byte 回 charAt 碼值，
-- BMP 內全形逗號恰為單 unit。string.byte 家規需 pcall 降級（原版無用例）
local SEP_CODES = { [9] = true, [32] = true, [44] = true, [45] = true, [46] = true, [65292] = true }

local COORD_MAX = 1e9 -- 世界座標合理上限（PZ 地圖座標 <10^5 量級；防 Infinity）

local function extractNums(text)
    local nums = {}
    for n in text:gmatch("%d+%.?%d*") do
        -- floor：家規慣例 %d 只餵整數（Kahlua %d 對真小數行為未實測；座標本為整數格）。
        -- 有限值檢查（codex review blocking）：超長數字串經 Double.parseDouble 會回
        -- Infinity，floor 不除——不擋會寫進持久 modData／分享封包並讓座標轉換出 NaN；
        -- v~=v 防 NaN、>=COORD_MAX 防 Infinity 與離譜值，命中即整串當關鍵字（回 nil）
        local v = math.floor(tonumber(n))
        if v ~= v or v >= COORD_MAX then return nil end
        nums[#nums + 1] = v
        if #nums >= 3 then break end
    end
    if #nums < 2 then return nil end
    return nums[1], nums[2]
end

local function parseCoords(text)
    if text:match("^[%d%s,%.%-]+$") then return extractNums(text) end -- ASCII 快路徑
    local ok, pass = pcall(function() -- 非純 ASCII：逐碼位驗證（數字 48-57 或分隔符白名單）
        for i = 1, #text do
            local b = string.byte(text, i)
            if not ((b >= 48 and b <= 57) or SEP_CODES[b]) then return false end
        end
        return true
    end)
    if not ok or not pass then return nil end
    return extractNums(text)
end

local function dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end

local function fmtDist(d)
    if d >= 1000 then return string.format("%.1fkm", d / 1000) end
    return string.format("%dm", math.floor(d + 0.5))
end

local function kindTag(kind)
    if kind == "coord" then return getText("UI_MinidoracatMiniMap_SearchKindCoord") end
    if kind == "street" then return getText("UI_MinidoracatMiniMap_SearchKindStreet") end
    if kind == "place" then return getText("UI_MinidoracatMiniMap_SearchKindPlace") end
    return getText("UI_MinidoracatMiniMap_SearchKindPoi")
end

-- 有界最近-N 插入：維持 arr 依 d 升冪、長度 ≤ cap；比末位遠直接丟（剪枝）。
-- review 定案：先全配置再 O(n²) 全排序在大命中集（單字母命中多類、上千筆）
-- 會同步卡 UI 執行緒數十 ms；此法每筆 O(cap) 上限、無多餘配置
local function boundedInsert(arr, cap, entry)
    local n = #arr
    if n >= cap and entry.d >= arr[n].d then return end
    local i = n
    while i >= 1 and arr[i].d > entry.d do i = i - 1 end
    local last = n + 1
    if last > cap then last = cap end
    for j = last, i + 2, -1 do arr[j] = arr[j - 1] end
    if i + 1 <= cap then arr[i + 1] = entry end
end

local streetMapSources
local function streetSourceHint(dir)
    if type(dir) ~= "string" then return nil end
    if not streetMapSources then
        local active, sources = {}, {}
        local mods = getActivatedMods()
        for i = 0, mods:size() - 1 do active[mods:get(i)] = true end
        for _, pack in ipairs(Core.registeredPacks or {}) do
            for _, entry in ipairs(pack.entries or {}) do
                if type(entry.mapDir) == "string" and entry.mapDir ~= ""
                    and type(entry.mapMod) == "string" and active[entry.mapMod] then
                    local key = entry.mapDir:lower()
                    local previous = sources[key]
                    if previous == nil then
                        sources[key] = { mapMod = entry.mapMod, mapDir = entry.mapDir, nameKey = entry.nameKey }
                    elseif previous then
                        if previous.mapMod ~= entry.mapMod then
                            sources[key] = false
                        elseif previous.nameKey ~= entry.nameKey then
                            previous.nameKey = nil
                        end
                    end
                end
            end
        end
        streetMapSources = sources
    end
    local source = streetMapSources[dir:lower()]
    if not source then return nil end
    local name = source.mapDir
    if type(source.nameKey) == "string" then
        local ok, localized = pcall(getTextOrNull, source.nameKey)
        if ok and type(localized) == "string" and localized ~= "" and localized ~= source.nameKey then
            name = localized
        end
    end
    return getText("UI_MinidoracatMiniMap_SearchModMapSource", name)
end

-- 結果列最終化：座標取整＋右欄文字/寬度/類型標籤一次性預格式化
-- （listDrawItem 每幀直用，零配置）。labelW 供加入清單時判定是否需換兩行
local function finalizeItem(it)
    it.x = math.floor(it.x)
    it.y = math.floor(it.y)
    it.tag = it.home and getText("UI_MinidoracatMiniMap_PlaceHome") or kindTag(it.kind)
    it.right = string.format("(%d, %d)  %s", it.x, it.y, fmtDist(it.d))
    local tm = getTextManager()
    it.tagW = tm:MeasureStringX(UIFont.Small, it.tag)
    it.rightW = tm:MeasureStringX(UIFont.Small, it.right)
    it.labelW = tm:MeasureStringX(UIFont.Small, it.label)
    if it.kind == "street" then it.sourceHint = streetSourceHint(it.sourceDir) end
    return it
end

-- 結果收集：回陣列 { { kind="coord|street|poi", label=, x=, y=, d=, tag=, right=, ... } }
local function doSearch(text, px, py)
    local results = {}
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" then return results end
    local cx, cy = parseCoords(text)
    if cx then
        results[1] = finalizeItem({ kind = "coord",
            label = string.format("%d, %d", cx, cy),
            x = cx, y = cy, d = math.sqrt(dist2(px, py, cx, cy)) })
        return results
    end
    local q = text:lower()
    -- 街道名：有界最近-N（review：同名街跨城大量重複——抽取序截斷會把「離玩家
    -- 最近的那段」擠出清單，且介面右欄顯示距離、必須按距離組織）。
    -- 譯名與原名共用即時道路錨點；小寫索引建圖時一次計算。
    local streets = Core.navStreetIndex and Core.navStreetIndex() or nil
    if streets then
        local hits = {}
        local seen = nil -- 首點精確鍵（引擎命中的街，烘焙英文項去重用；lazy 建）
        -- 即時索引已有的官方原名（小寫）：烘焙表同名項不再追加。純文字翻譯取 originalLow；
        -- 名稱沒翻譯（英文客戶端或字典缺這條）時顯示名就是原名、originalLow＝nil，取 low。
        -- 不能只靠首點精確鍵：RoadPatch 移除首段或整條換成同名人工線後，即時錨點落在第一個
        -- 保留段／人工線起點，離官方首點 2–2222 格（Fiddler's Trail 2、Walker Road 87、KY-841
        -- 2212），舊首點會變成第二列。同名的每條官方街都有自己的即時項目，所以按名擋掉烘焙項
        -- 不會漏街；即時索引不收的鐵路仍由烘焙表提供。
        local liveOriginals
        for i = 1, #streets do
            local st = streets[i]
            if (st.low ~= "" and st.low:find(q, 1, true))
                or (st.originalLow and st.originalLow:find(q, 1, true)) then
                if st.sourceDir and st.sourceDir:lower() == "muldraugh, ky" then
                    local original = st.originalLow or (st.low ~= "" and st.low or nil)
                    if original then
                        liveOriginals = liveOriginals or {}
                        liveOriginals[original] = true
                    end
                end
                local d = math.sqrt(dist2(px, py, st.x, st.y))
                -- 剪枝早退：滿載且比末位遠→不配置 entry table（與 POI 分支對稱）
                if #hits < MAX_STREET_RESULTS or d < hits[#hits].d then
                    boundedInsert(hits, MAX_STREET_RESULTS, { kind = "street",
                        label = st.name, x = st.x, y = st.y, d = d, sourceDir = st.sourceDir })
                    seen = seen or {}
                    seen[math.floor(st.x) * 100000 + math.floor(st.y)] = true
                end
            end
        end
        -- 英文原名補充（2026-08-20 使用者回報搜 "will" 無結果）：LangFor42 等
        -- 翻譯 MOD 整份取代官方 streets.xml → 引擎索引只剩譯名；官方英文原名
        -- 由 gen_street_names.py 烘焙進 MinidoracatMiniMapStreetNames（shared
        -- 資料檔，首點與引擎索引同源）。譯名/原名天然互補（中文查引擎、英文查
        -- 本表）；即時索引已有同一官方原名→liveOriginals 擋掉（見上），首點精確鍵
        -- 只剩非官方來源同首點的保底。表缺席（生成器沒跑）＝純引擎行為
        local en = MinidoracatMiniMapStreetNames
        if type(en) == "table" then
            for i = 1, #en do
                local e = en[i]
                if e.l:find(q, 1, true)
                    and not (liveOriginals and liveOriginals[e.l])
                    and not (seen and seen[e.x * 100000 + e.y]) then
                    local d = math.sqrt(dist2(px, py, e.x, e.y))
                    if #hits < MAX_STREET_RESULTS or d < hits[#hits].d then
                        boundedInsert(hits, MAX_STREET_RESULTS, { kind = "street",
                            label = e.n, x = e.x, y = e.y, d = d })
                    end
                end
            end
        end
        for i = 1, #hits do
            results[#results + 1] = finalizeItem(hits[i])
        end
    end
    -- POI 類別名：命中類別→有界最近-N 展開該類設施。錨點＝r[1] 矩形中心
    -- （小地圖資源版的消費契約：r 按面積排序、r[1] 為圖標錨點；清單含地圖包註冊的地圖）
    local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    local Res = MinidoracatMiniMapResources
    local data = Res and Res.minimapEntries() or nil
    if type(cats) == "table" and type(data) == "table" then
        local allNames = {} -- 全類別譯名（地下關鍵字命中時查名用）
        local hitCats = {}
        local anyCat = false
        for key, def in pairs(cats) do
            local nm = def.nameKey and getText(def.nameKey) or key
            allNames[key] = nm
            if nm:lower():find(q, 1, true) then
                hitCats[key] = nm
                anyCat = true
            end
        end
        -- 「地下」關鍵字（2026-08-20 實測需求：搜「地下」應列出全部地下室設施）：
        -- 比對走**專用匹配鍵**（SearchBasementKey＝無標點核心詞「地下室」/
        -- "basement"）的**前綴語義**＋最小長度 2 unit——初版拿顯示後綴
        -- 「（地下室）」做反向子串，EN 搜街名的常見前綴 "st"/"b" 必誤觸灑出
        -- 62 筆地下設施（三 lane review 一致抓出）；前綴匹配「地下」「bas」
        -- 命中、"st"/"as"/單字元/括號全擋
        local baseCore = getText("UI_MinidoracatMiniMap_SearchBasementKey"):lower()
        local baseHit = #q >= 2 and baseCore:sub(1, #q) == q
        if anyCat or baseHit then
            local hits = {}
            local function addHit(nm, ex, ey, basement)
                local d = math.sqrt(dist2(px, py, ex, ey))
                -- 剪枝早退：滿載且比末位遠→不配置 entry table 直接丟
                if #hits < MAX_POI_RESULTS or d < hits[#hits].d then
                    -- 地下條目後綴（資料 u=1＝B42 basement）：地上是別的建築，
                    -- 不標會被當標錯（同圖標「↓」角標語義）
                    local label = basement
                        and (nm .. getText("UI_MinidoracatMiniMap_SearchBasement")) or nm
                    boundedInsert(hits, MAX_POI_RESULTS,
                        { kind = "poi", label = label, x = ex, y = ey, d = d })
                end
            end
            -- 房間資料版：地圖上畫的同一份建築清單（MinidoracatMiniMapPOI.lua），落點＝該類最大的房間；
            -- 一筆有多個類別時各自是一個結果。還沒掃完時清單是空的
            if Core.poiSource and Core.poiSource() == "rooms" then
                local list, n = nil, 0
                if Core.poiRoomBuildings then list, n = Core.poiRoomBuildings() end
                for i = 1, list and n or 0 do
                    local b = list[i]
                    for cat in pairs(b.cats) do
                        local a = b.anchors[cat]
                        local nm = hitCats[cat] or (baseHit and a.basement and allNames[cat] or nil)
                        if nm then addHit(nm, a.x + a.w / 2, a.y + a.h / 2, a.basement) end
                    end
                end
            else
                for i = 1, #data do
                    local e = data[i]
                    local nm = hitCats[e.cat]
                        or (baseHit and e.u == 1 and allNames[e.cat] or nil)
                    if nm and e.rn and e.rn >= 1 then
                        local r1 = e.r[1]
                        addHit(nm, r1.x + r1.w / 2, r1.y + r1.h / 2, e.u == 1)
                    end
                end
            end
            for i = 1, #hits do
                results[#results + 1] = finalizeItem(hits[i])
            end
        end
    end
    -- 停車場：查詢字是「停車場」譯名的子字串→有界最近-N 列出停車場。一座停車場只有 i == 1 那一區
    -- 有圖標，搜尋也只列那一區，落點＝它的範圍框 b 的中心（同圖標）。不看 ParkingLayer（同 POI 搜尋不看 PoiIcons）
    local parking = Res and Res.parkingEntries() or nil
    local parkingName = getText("UI_MinidoracatMiniMap_Parking")
    if type(parking) == "table" and parkingName:lower():find(q, 1, true) then
        local hits = {}
        for i = 1, parking.count or 0 do
            local e = parking[i]
            local b = e.i == 1 and e.b or nil
            if b then
                local ex, ey = b.x + b.w / 2, b.y + b.h / 2
                local d = math.sqrt(dist2(px, py, ex, ey))
                if #hits < MAX_POI_RESULTS or d < hits[#hits].d then
                    boundedInsert(hits, MAX_POI_RESULTS, { kind = "poi", label = parkingName, x = ex, y = ey, d = d })
                end
            end
        end
        for i = 1, #hits do
            results[#results + 1] = finalizeItem(hits[i])
        end
    end
    return results
end

--------------------------------------------------------------------------------
-- 搜尋／行程視窗（單例＋owner-transfer；ISPanel 自組＋圓角皮膚）
--------------------------------------------------------------------------------
local searchWin = nil

local HEAD_LINES = 2 -- 狀態列與預覽列各自預留的行數（版面先留位，文字按實寬換行）
local MSG_LINES = 2

local KIND_COLORS = {
    coord = { r = 1, g = 0.85, b = 0.4 },     -- 琥珀（同皮膚 ACCENT）
    street = { r = 0.05, g = 0.86, b = 1.0 }, -- 青（同路線色語）
    poi = { r = 0.3, g = 0.95, b = 0.4 },     -- 綠
    place = { r = 1, g = 0.55, b = 0.8 },     -- 粉：收藏（家另有文字標籤，不靠顏色區分）
    road = { r = 0.95, g = 0.92, b = 0.82 },  -- 米白：自訂道路（同地圖上的虛線）
    draft = { r = 1, g = 0.85, b = 0.4 },     -- 琥珀：未存的道路
}
local ROAD_OFF_COLOR = { r = 0.45, g = 0.45, b = 0.45 } -- 不用於導航／路網容量已滿的路：圓點變灰

-- 站點編號徽章色（與 _Nav 地圖上的編號標記同語義，跨 lane 對齊）
local STOP_COLORS = {
    active = { r = 1, g = 0.85, b = 0.4 },     -- 琥珀：目前／下一個要去的站
    pending = { r = 0.05, g = 0.86, b = 1.0 }, -- 青：待處理
    arrived = { r = 0.3, g = 0.95, b = 0.4 },  -- 綠：已抵達
    skipped = { r = 0.5, g = 0.5, b = 0.5 },   -- 灰：已略過（不是抵達）
}
-- phase 文字色。paused 是「玩家明確停止導航」的正常狀態＝中性灰，
-- 只有 reason 為 noroad／failed 與資料損壞才用警告色（避免把正常停止當錯誤）
local PHASE_COLORS = {
    draft = { r = 1, g = 1, b = 1 },
    navigating = { r = 0.05, g = 0.86, b = 1.0 },
    approach = { r = 1, g = 0.85, b = 0.4 },
    waiting = { r = 1, g = 0.85, b = 0.4 },
    paused = { r = 0.7, g = 0.7, b = 0.7 },
    completed = { r = 0.3, g = 0.95, b = 0.4 },
}
local WARN_COLOR = { r = 1, g = 0.45, b = 0.3 }
local GOOD_COLOR = { r = 0.3, g = 0.95, b = 0.4 }
local MUTED_COLOR = { r = 0.62, g = 0.62, b = 0.62 }

-- 選中項防呆（review blocking：list:clear() 會把 selected 重設 1，而「載入中/
-- 無結果」info 列正好落在索引 1——不擋會把 nil 座標寫進 searchPing/navSetTarget，
-- 前者讓 drawSearchPing 每幀丟錯 12 秒、後者讓導航層靜默壞到手動清除）
local function winSelectedItem(win)
    local sel = win.list.selected
    local row = win.list.items and win.list.items[sel]
    local it = row and row.item or nil
    if not it or it.kind == "info" then return nil end
    if type(it.x) ~= "number" or type(it.y) ~= "number" then return nil end
    return it
end

--------------------------------------------------------------------------------
-- 文字換行（按實測字寬，不截字）
--------------------------------------------------------------------------------
local function measureSmall(text)
    return getTextManager():MeasureStringX(UIFont.Small, text)
end

-- 可放進 maxW 的最長前綴長度（至少 1）。Kahlua 字串是 Java String，string.sub
-- 以 UTF-16 unit 切——BMP 內的 CJK 字元恰為單 unit，不會切出半個字；二分搜尋
-- 讓一行只量 log2(n) 次，不逐字元量
local function fitPrefix(text, maxW)
    local lo, hi = 1, #text
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if measureSmall(text:sub(1, mid)) <= maxW then lo = mid else hi = mid - 1 end
    end
    return lo
end

-- 按實測字寬換行：有空白的語言優先在空白處斷，CJK 直接按 unit 斷。
-- maxLines 省略＝不限行數（站名／說明列一律完整可讀，寧可列變高）；
-- 有給＝版面已預留固定行數（狀態列／訊息列），最後一行補 "..." 並標 truncated
-- 不限行數時框架有 UI.Text.wrap（rev 16 CAPABILITIES.textWrap）就交給它：中日韓斷點與行首／行尾禁則
-- （「。」「、」不起行）只維護一份（家族 pitfalls「判斷能不能逐字斷行要看中日韓碼位範圍」）
local function wrapLines(text, maxW, maxLines)
    local lines = {}
    if type(text) ~= "string" or text == "" then return lines end
    if maxW < 16 then -- 版面異常窄：不硬切成一堆單字元，交給繪製端自然裁切
        lines[1] = text
        return lines
    end
    local UI = not maxLines and MinidoracatUI and MinidoracatUI.v1
    if UI and UI.CAPABILITIES and UI.CAPABILITIES.textWrap and UI.Text and UI.Text.wrap then
        local ok, wrapped = pcall(UI.Text.wrap, text, maxW, UIFont.Small)
        if ok and type(wrapped) == "table" and wrapped[1] ~= nil then return wrapped end
    end
    local rest = text
    while rest ~= "" do
        if measureSmall(rest) <= maxW then
            lines[#lines + 1] = rest
            return lines
        end
        if maxLines and #lines + 1 >= maxLines then
            local room = maxW - measureSmall("...")
            lines[#lines + 1] = rest:sub(1, room > 0 and fitPrefix(rest, room) or 1) .. "..."
            lines.truncated = true
            return lines
        end
        local cut = fitPrefix(rest, maxW)
        for i = cut, 2, -1 do
            if rest:sub(i, i) == " " then
                cut = i - 1
                break
            end
        end
        lines[#lines + 1] = rest:sub(1, cut)
        rest = rest:sub(cut + 1):match("^%s*(.*)$")
    end
    return lines
end

local function widestLine(lines)
    local w = 0
    for i = 1, #lines do
        local lw = measureSmall(lines[i])
        if lw > w then w = lw end
    end
    return w
end

--------------------------------------------------------------------------------
-- 行程狀態轉接（權威在 _Itinerary.lua，本檔只現查唯讀狀態）
--------------------------------------------------------------------------------
-- nil 檢查的唯一理由：本檔可被離線測試整檔抽載（_Itinerary.lua 未載入）。
-- 遊戲內載入序保證 _Itinerary（'I'）先於 _Search（'S'）。
local function tripState(pn)
    local read = Core.navItineraryState
    return read and read(pn) or nil
end

local function tripRevision(st)
    return st and st.revision or 0
end

-- 認領狀態（自駕正握著目前段）只存在於**公開快照**：Core.navItineraryState 回的是
-- 私有 raw trip，claimed 只在 API.getNavItinerary 的複本上補入（_Itinerary.lua
-- getItinerary:294-296），直接讀 st.claimed 在真 Core 下永遠是 nil——UI 的鎖定
-- 顯示會完全失效（review UI-2）。getNavItinerary 會複製整份行程，所以只在
-- 認領狀態「可能已變」時取一次、只留一個布林：claim／release／report 全都推進
-- revision（_Itinerary.lua claim:358、release:410、commit:173），所以同一份 trip
-- ＋同一個 revision 內認領狀態不可能改變；每幀刷新與每 8 格移動的距離重算都不再
-- 複製整份行程；trip 物件本體另守角色／行程生命週期切換。
local claimCache = { pn = nil, trip = nil, revision = nil, claimed = false }
local function tripClaimed(pn, st)
    local revision = tripRevision(st)
    if claimCache.pn ~= pn or claimCache.trip ~= st or claimCache.revision ~= revision then
        local api = MinidoracatMiniMapAPI
        local read = type(api) == "table" and api.getNavItinerary or nil
        local snapshot = type(read) == "function" and read(pn) or nil
        claimCache.pn, claimCache.trip, claimCache.revision = pn, st, revision
        claimCache.claimed = type(snapshot) == "table" and snapshot.claimed == true
    end
    return claimCache.claimed
end

local function tripErrorReason(pn)
    local read = Core.navItineraryError
    return read and read(pn) or nil
end

-- 錯誤文字一律由 Main 的 Core.navErrorText 決定（blocked 優先 detailKey）；
-- 單獨抽載時退回本檔擁有的 generic 鍵，不得讓提示路徑自己丟錯
local function tripErrorText(reason, detailKey)
    local translate = Core.navErrorText
    if translate then return translate(reason, detailKey) end
    return getText("UI_MinidoracatMiniMap_TripError_failed")
end

-- 視窗內訊息列（開窗時的操作回饋必須看得見；視窗不在／已收合＝退原版 halo，
-- 同 navSetTarget 既有通道——右鍵地圖直接編輯行程時不能靜默失敗）。
-- 自己的世界地圖開著時 halo 畫在被全螢幕地圖蓋住的角色頭上：改走 UI 框架 Toast
-- （置頂；寫法同 _Settings.lua studioNeedFramework），框架缺 toast 能力才退 halo。
-- good＝成功回饋（綠字／addGoodText），其餘一律當失敗（警告色／addBadText）
local function winMessage(pn, text, good)
    local win = searchWin
    if win and win:isVisible() and not win.collapsed and (win.playerNum or 0) == pn then
        win.msgLines = wrapLines(text, win.width - 20, win.msgMaxLines or MSG_LINES)
        win.msgUntil = getTimestampMs() + MSG_MS
        win.msgGood = good == true
        -- 訊息列只預留固定行數：放不下就把完整文字併進可捲清單（錯誤原因不得只剩
        -- 「...」）；兩頁的刷新 cache 一併作廢，那一列才會長出來／收回去
        win.msgFull = win.msgLines.truncated and text or nil
        win._tRev, win._lastText, win._rRev = nil, nil, nil
        return
    end
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    local wm = ISWorldMap_instance
    if wm and wm:isVisible() and (wm.playerNum or 0) == pn then
        local UI = MinidoracatUI and MinidoracatUI.v1
        if UI and UI.CAPABILITIES and UI.CAPABILITIES.toast and UI.Toast
                and pcall(UI.Toast.show, { message = text, maxLines = 4 }) then
            return
        end
    end
    if good then
        HaloTextHelper.addGoodText(playerObj, text)
    else
        HaloTextHelper.addBadText(playerObj, text)
    end
end

-- 收藏（_Places.lua）共用的訊息通道：契約 places-contract「Search.lua 需提供」
Core.navMessage = function(pn, text, good)
    winMessage(pn or 0, text, good)
end

local function winError(pn, reason, detailKey)
    winMessage(pn, tripErrorText(reason, detailKey))
end

-- 收藏轉接（權威在 _Places.lua）。字母序 P 先於 S，但離線測試會單獨抽載本檔：
-- Core.places* 一律事件期現查，缺席時不列收藏、動作回 generic 錯誤，不得丟錯
local function placesRead(pn)
    local read = Core.placesState
    return read and read(pn) or nil
end

local function placesErrorText(reason)
    local translate = Core.placesErrorText
    if translate then return translate(reason) end
    return tripErrorText(reason)
end

local function placeById(pn, id)
    local ps = placesRead(pn)
    for i = 1, (ps and ps.count or 0) do
        if ps.places[i].id == id then return ps.places[i] end
    end
    return nil
end

local function placeName(pn, place)
    local label = Core.placeLabel
    if label then return label(pn, place) end
    return place.label or string.format("%d, %d", place.x, place.y)
end

-- 自訂道路轉接（資料權威在 _Roads.lua，工具在 _RoadTool／_RoadRecord／_RoadShare）。遊戲內字母序 _Road* 先於
-- 本檔，但離線測試會單獨抽載本檔、對方檔也可能載入失敗：Core.roads* 一律
-- 事件期現查，缺席＝通用錯誤，不丟錯。失敗原因由 Core.roadsErrorText 決定
local function roadReport(pn, ok, reason, okKey)
    if ok then
        if okKey then winMessage(pn, getText(okKey), true) end
        return
    end
    local text = Core.roadsErrorText and Core.roadsErrorText(reason)
    winMessage(pn, text or getText("UI_MinidoracatMiniMap_RoadError"))
end

-- 改資料的道路操作（回 ok, reason；複製回新 id）：結果一律說出來
local function roadEdit(pn, okKey, name, a, b)
    local fn = Core[name]
    local ok, reason = false, "failed"
    if fn then ok, reason = fn(pn, a, b) end
    roadReport(pn, ok, reason, okKey)
end

-- 開工具／表單的道路操作（對方自己回饋）：只有對方檔缺席時才由這裡說
local function roadOpen(pn, name, a, b)
    local fn = Core[name]
    if fn then return fn(pn, a, b) end
    roadReport(pn, false, "failed")
end

-- 單筆原子編輯統一入口：失敗必顯示原因（不得靜默）。
-- d＝insert 的錨點 stopId／pause 的布林（契約 navEditItinerary(pn, rev, op, a, b, c, d)）
local function tripEdit(pn, expectedRevision, operation, a, b, c, d)
    local edit = Core.navEditItinerary
    if not edit then return false end
    local ok, reason, detailKey = edit(pn, expectedRevision, operation, a, b, c, d)
    if not ok then winError(pn, reason, detailKey) end
    return ok
end

-- 第一個 pending 站（開始／繼續導航會選它）
local function tripFirstPending(st)
    if not st then return nil end
    for i = 1, (st.count or 0) do
        local stop = st.stops[i]
        if stop.status == "pending" then return stop.id end
    end
    return nil
end

-- 可略過的站＝**目前站且仍 pending**。與 _Itinerary.lua 的 skip 守衛逐條一致
-- （a ~= currentStopId 或該站非 pending 即回 state）：draft 沒有 currentStopId、
-- waiting 的 currentStopId 指向剛完成的站，兩者都不可略過，按鈕不得假亮
local function tripSkippable(st)
    if not st or not st.currentStopId then return nil end
    for i = 1, (st.count or 0) do
        local stop = st.stops[i]
        if stop.id == st.currentStopId then
            return stop.status == "pending" and stop.id or nil
        end
    end
    return nil
end

-- 站點查表（插入錨點驗證與選取列的旗標判定共用）
local function tripStopById(st, id)
    if not st or type(id) ~= "number" then return nil end
    for i = 1, (st.count or 0) do
        if st.stops[i].id == id then return st.stops[i] end
    end
    return nil
end

-- 站名：契約缺省顯示座標（不解讀標記）
local function stopName(stop)
    if not stop then return nil end
    return stop.label or string.format("%d, %d", stop.x, stop.y)
end

-- 接續模式 API 守衛（同 addon 守衛規範：版本欄位 >= 與函式存在都要查，不足即當
-- 不支援）。舊版 Core 沒有 autoContinue／pause／setNavContinuation，UI 必須說明並
-- 停用，不能讓玩家以為自己切了模式
local NAV_API_CONTINUATION = 7
local function continuationApi()
    local api = MinidoracatMiniMapAPI
    if type(api) ~= "table" then return nil end
    if type(api.navApiVersion) ~= "number" or api.navApiVersion < NAV_API_CONTINUATION then
        return nil
    end
    if type(api.setNavContinuation) ~= "function" then return nil end
    return api.setNavContinuation
end

-- 接續模式切換：兩顆鈕各送明確布林（不是 toggle——顯示晚一幀時 toggle 會反向
-- 操作）。只改目前這份行程的設定，不發車、不煞車、不換目標
local function setContinuation(win, enabled)
    local pn = win.playerNum or 0
    local setter = continuationApi()
    if not setter then
        winMessage(pn, getText("UI_MinidoracatMiniMap_TripModeUnsupported"))
        return
    end
    local ok, reason, detailKey = setter(pn, tripRevision(tripState(pn)), enabled)
    if not ok then winError(pn, reason, detailKey) end
end

-- 行程清單選中站防呆（同 winSelectedItem：空行程／載入錯誤的提示列不是站點）
local function tripSelectedStop(win)
    local list = win.tripList
    if not list then return nil end
    local row = list.items and list.items[list.selected]
    local it = row and row.item or nil
    if not it or it.kind ~= "trip" then return nil end
    if type(it.stopId) ~= "number" or type(it.x) ~= "number" or type(it.y) ~= "number" then
        return nil
    end
    return it
end

--------------------------------------------------------------------------------
-- 焦點環（鍵盤與手把共用同一套；可見焦點＝琥珀外框）
--------------------------------------------------------------------------------
local function focusEntries(win)
    if win.page == "itinerary" then return win.tripFocus end
    if win.page == "roads" then return win.roadsFocus end
    return win.page == "places" and win.placesFocus or win.searchFocus
end

local function focusUsable(entry)
    local el = entry.el
    return el:isVisible() and el.enable ~= false
end

local function focusMove(win, delta)
    local list = focusEntries(win)
    local n = list and #list or 0
    if n == 0 then return end
    local i = win.focus or (delta > 0 and 0 or n + 1)
    for _ = 1, n do
        i = i + delta
        if i > n then i = 1 elseif i < 1 then i = n end
        if focusUsable(list[i]) then
            win.focus = i
            return
        end
    end
    win.focus = nil
end

local function listStep(list, delta)
    local n = list.items and #list.items or 0
    if n == 0 then return end
    local sel = (list.selected or 1) + delta
    if sel < 1 then sel = 1 elseif sel > n then sel = n end
    list.selected = sel
    list:ensureVisible(sel)
end

-- 方向鍵／手把方向：焦點在清單上＝改選，否則移動焦點
local function focusStep(win, delta)
    local list = focusEntries(win)
    local entry = win.focus and list and list[win.focus] or nil
    if entry and entry.isList then
        listStep(entry.el, delta)
        return
    end
    focusMove(win, delta)
end

local function focusActivate(win)
    local list = focusEntries(win)
    local entry = win.focus and list and list[win.focus] or nil
    if not (entry and focusUsable(entry)) then return end
    entry.action(win)
end

--------------------------------------------------------------------------------
-- 頁面／收合／次要動作折疊
--------------------------------------------------------------------------------
local relayoutWindow -- 前向宣告（setPage／收合／折疊都要重排版面）
local claimJoypad

-- 原版 setJoypadFocus 會推入 prev/prevprev；關閉時還原開窗前狀態，不能再推入死視窗。
local function releaseJoypad(control)
    local pn = control.joyOwner
    local data = pn ~= nil and JoypadState and JoypadState.players and JoypadState.players[pn + 1]
    if data and data.focus == control then
        data.focus, data.prevfocus, data.prevprevfocus =
            control.joyPrevious, control.joyPrevious2, control.joyPrevious3
    end
    control.joyOwner = nil
end

-- 本視窗開著的原生選單（次要動作折疊與插入位置選擇共用同一個插槽：鍵盤／手把
-- 路由與關窗清理都只認這一份）
local function activeNativeMenu(win)
    local menu = win.nativeMenu
    return menu and menu.origin == win and menu:isVisible() and menu or nil
end

local function styleButton(btn)
    btn.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
    btn.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.12 }
    btn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
end

local function styleTab(btn, on)
    btn.backgroundColor = on and { r = 1, g = 0.85, b = 0.4, a = 0.22 }
        or { r = 0, g = 0, b = 0, a = 0.5 }
    btn.borderColor = on and { r = 1, g = 0.85, b = 0.4, a = 1 }
        or { r = 0.4, g = 0.4, b = 0.4, a = 1 }
end

-- 各頁標題：{ 標題, 放不下時的短標題 }。收藏頁沿用設定視窗的「家與收藏點」與分頁名「收藏」。
-- 鍵＝合法頁名（setPage 與 toggleSearchWindow 的白名單）
local PAGE_TITLES = {
    search = { "UI_MinidoracatMiniMap_SearchTitle", "UI_MinidoracatMiniMap_SearchTabSearch" },
    places = { "UI_MinidoracatMiniMap_RowPlaces", "UI_MinidoracatMiniMap_PlaceMenu" },
    itinerary = { "UI_MinidoracatMiniMap_TripTitle", "UI_MinidoracatMiniMap_TripManage" },
    roads = { "UI_MinidoracatMiniMap_RoadTitle", "UI_MinidoracatMiniMap_RoadTab" },
}

-- 各頁的底部按鈕與「動作…」鈕：收藏頁與搜尋頁共用一份，行程頁、道路頁各一份
local function pageButtons(win)
    if win.page == "itinerary" then return win.tripBtns, win.tripMoreBtn end
    if win.page == "roads" then return win.roadBtns, win.roadMoreBtn end
    return win.searchBtns, win.searchMoreBtn
end

-- 依「目前頁 × 是否收合 × 次要動作是否展開」決定每顆按鈕可見性。
-- 收合時只留標題列兩顆鈕：其餘元件不可見、輸入框解焦，完全不吃鍵盤。
-- 收藏頁與搜尋頁共用同一份清單與底部按鈕：差在收藏頁沒有搜尋框、清單接在分頁列下面
local function applyPage(win)
    local trip = win.page == "itinerary"
    local shown = not win.collapsed
    win.entry:setVisible(shown and win.page == "search")
    win.list:setVisible(shown and not trip)
    local at = win.listAt and win.listAt[win.page]
    if at then
        win.list:setY(at.y)
        win.list:setHeight(at.h)
    end
    win.tripList:setVisible(shown and trip)
    for i = 1, #win.modeBtns do
        win.modeBtns[i].btn:setVisible(shown and trip)
    end
    for i = 1, #win.tabs do
        win.tabs[i].btn:setVisible(shown)
        styleTab(win.tabs[i].btn, win.tabs[i].page == win.page)
    end
    local pageDefs = pageButtons(win)
    for _, defs in ipairs({ win.searchBtns, win.tripBtns, win.roadBtns }) do
        local onPage = shown and defs == pageDefs
        for i = 1, #defs do
            local d = defs[i]
            d.btn:setVisible(onPage and d.group ~= "more" and not d.hide)
        end
    end
    win.g = win.geom[win.page]
    local titles = PAGE_TITLES[win.page]
    win.titleText = getText(titles[1])
    win.titleW = getTextManager():MeasureStringX(UIFont.Medium, win.titleText)
    if win.titleW > win.collapseBtn.x - 20 then
        win.titleText = getText(titles[2])
        win.titleW = getTextManager():MeasureStringX(UIFont.Medium, win.titleText)
    end
    -- 依整個視窗置中；只有會碰到右上角按鈕時才往左讓
    win.titleX = math.max(10, math.min(math.floor((win.width - win.titleW) / 2),
        win.collapseBtn.x - 8 - win.titleW))
    win.collapseBtn:setTitle(win.collapsed and "+" or "-")
    win.collapseBtn.tooltip = getText(win.collapsed and "UI_MinidoracatMiniMap_TripExpand"
        or "UI_MinidoracatMiniMap_TripCollapse")
    if win.collapsed then
        if win.entry.unfocus then win.entry:unfocus() end
        win.focus = nil
    elseif win.focus then
        -- 已在鍵盤／手把模式：焦點移到新頁的分頁鈕，讓左右鍵可以連續換頁
        for i = 1, #win.tabs do
            if win.tabs[i].page == win.page then win.focus = i end
        end
    end
    -- 各頁的刷新 cache 一律作廢：切頁／重排版後清單寬度可能已變，
    -- 換行判定與預格式化的右欄寬都要按新版面重算
    win._lastText = nil
    win._lastState = nil
    win._tRev = nil
    win._tripSel = nil
    win._searchSel = nil
    win._rRev = nil
    win._roadSel = nil
end

local function setPage(win, page)
    if not (page and PAGE_TITLES[page]) then page = "search" end
    if win.page == page then return end
    -- 離開搜尋頁必解焦：不可見的輸入框仍會攔截遊戲鍵盤
    -- （UITextBox2.java:652 只有 unfocus() 清 currentTextEntryBox）
    if page ~= "search" and win.entry and win.entry.unfocus then win.entry:unfocus() end
    win.roadLost = nil -- 錄製中斷的警告只在道路頁顯示一次：離開就收掉
    win.page = page
    applyPage(win)
end

-- 分頁順序＝分頁列由左到右。wrap＝手把 X 到最後一頁再回第一頁；方向鍵停在兩端
local PAGES = { "search", "places", "itinerary", "roads" }
local function stepPage(win, delta, wrap)
    local at = 1
    for i = 1, #PAGES do
        if PAGES[i] == win.page then at = i end
    end
    local to = at + delta
    if wrap then to = (to - 1) % #PAGES + 1 end
    if PAGES[to] then setPage(win, PAGES[to]) end
end

local function toggleCollapsed(win)
    win.collapsed = not win.collapsed
    relayoutWindow(win, win.playerNum or 0)
end

-- 原生選單（可捲動、走原版鍵盤／手把路由）：次要動作折疊不下與插入位置選擇共用。
-- 開選單前解焦輸入框，否則底層輸入框會吃掉方向鍵與 Enter
local function openNativeMenu(win, button, fill)
    local pn = win.playerNum or 0
    win.entry:unfocus()
    local anchorX = win:getAbsoluteX() + button.x
    local anchorY = win:getAbsoluteY() + button.y
    local below = anchorY + button.height
    local menu = ISContextMenu.get(pn, anchorX, below)
    menu.origin, menu.mouseOver = win, 1
    fill(menu)
    local left, top = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local width, height = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    -- 原版 calcHeight 以整個螢幕為界；分割畫面改用同一套可捲列尺寸。
    if menu.height > height then
        local chrome = menu.padTopBottom * 2 + menu.scrollIndicatorHgt * 2
        local rows = math.max(1, math.floor((height - chrome) / menu.itemHgt))
        menu.scrollAreaHeight = rows * menu.itemHgt
        menu:setHeight(menu.scrollAreaHeight + chrome)
    end
    local x = math.max(left, math.min(anchorX, left + width - menu.width))
    local y = below
    if y + menu.height > top + height then y = anchorY - menu.height end
    y = math.max(top, math.min(y, top + height - menu.height))
    menu.requestX, menu.requestY = x, y
    menu:setSlideGoalX(x, x)
    menu:setSlideGoalY(y, y)
    win.nativeMenu = menu
    if JoypadState and JoypadState.players and JoypadState.players[pn + 1] then
        claimJoypad(win, pn)
        setJoypadFocus(pn, menu)
    end
    return menu
end

-- 選單選項的說明（原版 ISToolTip，同 _Nav.lua navMenuLock 寫法）：選單裡只有這裡看得到說明或停用原因
local function optionTip(option, text)
    local tip = ISToolTip:new()
    tip:initialise()
    tip:setVisible(false)
    tip.description = text
    option.toolTip = tip
end

-- 「動作…」鈕與清單右鍵共用同一份原生選單（可捲動、走原版鍵盤／手把路由）。
-- 按鈕只列次要動作（主要動作已在底部）；右鍵列出該頁全部動作。d.shown(win) 回 false 的項
-- 整項不列（不是灰掉）；有 d.fill 的項自己往選單加（收藏：依選中項列出那幾項）。anchor＝相對視窗的
-- 定位框，後續二層選單（插入位置）沿用同一處
-- 按鈕的 tooltip 只有滑鼠看得到，收進選單後跟著搬到選項上（介面審查 #4）
local function openActions(win, anchor, all)
    local defs, moreBtn = pageButtons(win)
    win.actionAnchor = anchor or moreBtn
    openNativeMenu(win, win.actionAnchor, function(menu)
        for i = 1, #defs do
            local d = defs[i]
            if d.btn ~= moreBtn and (all or d.group == "more") and not d.hide
                    and (not d.shown or d.shown(win)) then
                if d.fill then
                    d.fill(menu, win)
                else
                    local intent = d.field == "manualBtn"
                        and { phase = win._tPhase, revision = win._tRev } or nil
                    local option = menu:addOption(d.btn.title, win, d.action, intent)
                    option.notAvailable = d.btn.enable == false
                    if d.btn.tooltip then optionTip(option, d.btn.tooltip) end
                end
            end
        end
    end)
end

-- 關窗統一走這裡（codex review blocking：只 hide/remove 不 unfocus 會讓
-- Core.currentTextEntryBox 殘留——UITextBox2.java:652 只有 unfocus() 清它、
-- UIManager.RemoveElement 不清——關窗後不可見輸入框仍攔截遊戲鍵盤）。
-- 手把焦點同樣要交還，否則焦點卡在已移除的 UI 會鎖死手把導航
local function closeWindow(win)
    if win.entry and win.entry.unfocus then win.entry:unfocus() end
    win.focus = nil
    win.roadLost = nil
    local menu = activeNativeMenu(win)
    if menu then menu:closeAll() end
    if win.confirm then
        releaseJoypad(win.confirm)
        win.confirm:removeFromUIManager()
        win.confirm = nil
    end
    releaseJoypad(win)
    win:setVisible(false)
    win:removeFromUIManager()
end

--------------------------------------------------------------------------------
-- 搜尋頁動作
--------------------------------------------------------------------------------
-- 帶座標開大地圖（原版簽名 ShowWorldMap(playerNum, centerX, centerY, zoom)，
-- ISWorldMap.lua:1500）；zoom 16＝街區級視野。落 ping＝雙表面脈動標記
-- （繪製在主檔 drawNavTargets 尾，12 秒自動消失；pn＝僅擁有者表面畫）。
-- 決策註記：直呼 ShowWorldMap 繞過原版 ToggleWorldMap 的 tooDarkToRead
-- 閘門（ISWorldMap.lua:1585-1596）——刻意：搜尋跳圖屬 UI 導航動作，與本
-- MOD XY 鈕/世界地圖入口同性質，不受黑暗閱讀判定限制
local function pingAndShow(pn, x, y)
    Core.searchPing = { pn = pn, x = x, y = y, untilMs = getTimestampMs() + PING_MS }
    ISWorldMap.ShowWorldMap(pn, x, y, 16)
end

local function winGoto(win)
    local it = winSelectedItem(win)
    if not it then return end
    pingAndShow(win.playerNum or 0, it.x, it.y)
end

local function winSetTarget(win)
    local it = winSelectedItem(win)
    if not it then return end
    if Core.navPromptTarget then
        Core.navPromptTarget(win.playerNum or 0, it.x, it.y, it.label, "replace")
    end
end

local function winAddStop(win)
    local it = winSelectedItem(win)
    if not it then return end
    if Core.navPromptTarget then
        Core.navPromptTarget(win.playerNum or 0, it.x, it.y, it.label, "append")
    end
end

-- 先去這裡：插在第一個待前往站之前並明確開始導航（不啟自駕；碰到目前站時車上須
-- 停妥且無 claim，不合時 Core 回原因）
local function winPriorityStop(win)
    local it = winSelectedItem(win)
    if not it then return end
    if Core.navPromptTarget then
        Core.navPromptTarget(win.playerNum or 0, it.x, it.y, it.label, "priority")
    end
end

-- 插在指定停靠點之前：原生選單列出待前往站＋加到最後（鍵盤／手把同一份路由）。
-- 沒有待前往站可當錨點時直接加尾，不開一張只有一個選項的選單
local function winInsertStop(win)
    local it = winSelectedItem(win)
    if not it then return end
    local pn = win.playerNum or 0
    if Core.navInsertAnchors(pn) == 0 then
        Core.navPromptTarget(pn, it.x, it.y, it.label, "append")
        return
    end
    local button = win.actionAnchor or win.searchMoreBtn
    openNativeMenu(win, button, function(menu)
        Core.navInsertOptions(menu, win, pn, it.x, it.y, it.label)
    end)
end

-- 收藏選單的點擊：建立選項時捕捉 owner（角色物件本體）與 placeId，延遲點擊先驗
-- owner（換角色＝不碰新角色），收藏是否仍在由 Core 以 stale 回報。缺函式＝generic
-- 錯誤；失敗一律經 navMessage 顯示，不得靜默
local function placeMenuApply(_, payload)
    if type(payload) ~= "table" then return end
    local pn = payload.pn
    local playerObj = getSpecificPlayer(pn)
    if playerObj == nil or playerObj ~= payload.owner then return end
    local op = payload.op
    local fn = op == "home" and Core.placesSetHome or op == "rename" and Core.placesPromptRename
        or op == "remove" and Core.navPromptPlaceRemove or op == "add" and Core.placesPromptAdd
    if not fn then
        winMessage(pn, placesErrorText("failed"))
        return
    end
    if op == "add" then
        fn(pn, payload.x, payload.y, payload.label)
    elseif op == "home" then
        local ok, reason = fn(pn, payload.placeId)
        if ok then
            winMessage(pn, getText("UI_MinidoracatMiniMap_HomeSet"), true)
        else
            winMessage(pn, placesErrorText(reason))
        end
    else
        fn(pn, payload.placeId)
    end
end

-- 收藏的動作直接放進「動作…」與清單右鍵（openActions 的 fill，不另開第二張選單；2026-10-18 設計稿
-- minimap-places-remove-1018 作答）：收藏列＝設為家（已是家不列）／改名／從收藏移除（會刪資料的排最後）；
-- 其他結果＝加入收藏...（直接開命名框）；沒選到地點或缺 _Places＝灰字的加入收藏...（同其他目標動作）。
-- 座標結果不帶預設名稱：無名收藏顯示即時座標、無名的家顯示「家」，寫死座標字串會蓋掉這兩種顯示
local function placeOptions(menu, win)
    local it = winSelectedItem(win)
    local pn = win.playerNum or 0
    local owner = getSpecificPlayer(pn)
    if not (it and owner and Core.placesState) then
        local none = menu:addOption(getText("UI_MinidoracatMiniMap_PlaceAdd"))
        none.notAvailable = true
        return
    end
    local function add(key, payload)
        payload.pn, payload.owner = pn, owner
        menu:addOption(getText(key), win, placeMenuApply, payload)
    end
    if it.kind ~= "place" then
        add("UI_MinidoracatMiniMap_PlaceAdd", { op = "add", x = it.x, y = it.y,
            label = it.kind ~= "coord" and it.label or nil })
        return
    end
    if not it.home then add("UI_MinidoracatMiniMap_PlaceMenuSetHome", { op = "home", placeId = it.placeId }) end
    add("UI_MinidoracatMiniMap_PlaceRename", { op = "rename", placeId = it.placeId })
    add("UI_MinidoracatMiniMap_PlaceRemove", { op = "remove", placeId = it.placeId })
end

--------------------------------------------------------------------------------
-- 確認面板（取代／清空）
-- 自組而非用 ISModalDialog：需要「明確動詞按鈕」「預設焦點在取消」「文字按實寬
-- 換行」「尺寸不超出 viewport」四件事，原版 UI_Yes/UI_No＋CalcSize 自動撐寬做不到，
-- 而且原版 Enter 沒有防誤觸概念。鍵盤 Enter 觸發「目前焦點」（預設取消），
-- 手把 A 同樣只觸發目前焦點、B 恆為取消——破壞性動作永遠要先把焦點移過去。
-- 綁定：owner 角色物件本體＋revision＋資料損壞旗標，三者任一在按下時已變即整筆拒絕
--------------------------------------------------------------------------------
local function confirmClose(panel)
    local win = searchWin
    panel:setVisible(false)
    panel:removeFromUIManager()
    if win and win.confirm == panel then win.confirm = nil end
    releaseJoypad(panel)
end

local function confirmApply(panel)
    local payload = panel.payload
    local pn = payload.pn
    confirmClose(panel)
    local playerObj = getSpecificPlayer(pn)
    if playerObj == nil or playerObj ~= payload.owner then return end -- 換角色＝不碰新角色
    if payload.op == "placeRemove" then
        -- 收藏與行程無關：不驗行程 revision（自駕推進行程不該讓移除收藏失效），
        -- 只驗收藏仍在；移除本身由 Core 做原子寫入
        if not placeById(pn, payload.placeId) then
            winMessage(pn, placesErrorText("stale"))
            return
        end
        local remove = Core.placesRemove
        local ok, reason = false, "failed"
        if remove then ok, reason = remove(pn, payload.placeId) end
        if ok then
            winMessage(pn, getText("UI_MinidoracatMiniMap_PlaceRemoved"), true) -- 同「已加入收藏」的通道
        else
            winMessage(pn, placesErrorText(reason))
        end
        return
    end
    if payload.op == "roadDraftDrop" then
        -- 確認期間草稿可能已存檔或換成新的：只捨棄當初看到的那一份，新草稿不碰
        if not (Core.roadsDraft and Core.roadsDraft(pn) == payload.draft) then
            roadReport(pn, false, "notfound")
            return
        end
        roadOpen(pn, "roadsClearDraft")
        return
    end
    if payload.op == "roadDelete" then
        -- 道路與行程無關：同收藏只驗那條路還在（確認期間可能已在別處刪掉）
        if not (Core.roadsGet and Core.roadsGet(pn, payload.roadId)) then
            roadReport(pn, false, "notfound")
            return
        end
        roadEdit(pn, "UI_MinidoracatMiniMap_RoadDeleted", "roadsDelete", payload.roadId)
        return
    end
    local st = tripState(pn)
    if tripRevision(st) ~= payload.revision or tripErrorReason(pn) ~= payload.error then
        winError(pn, "stale")
        return
    end
    if payload.op == "clear" then
        tripEdit(pn, payload.revision, "clear")
        return
    end
    if payload.op == "insert" then
        -- 錨點身份到真正 commit 前再驗一次：stopId 是穩定身份，確認期間那站可能
        -- 已被走完或略過，不得把新點插到別人算好的位置上（同選單那道防線）
        local anchor = tripStopById(st, payload.before)
        if not anchor or anchor.status ~= "pending" then
            winError(pn, "stale")
            return
        end
        tripEdit(pn, payload.revision, "insert",
            payload.x, payload.y, payload.label, payload.before)
        return
    end
    -- 取代＝Core.navSetTarget：建立單站行程並**立即開始導航**（不是只建 draft）
    local ok, reason, detailKey = Core.navSetTarget(pn, payload.x, payload.y, payload.label)
    if not ok then winError(pn, reason, detailKey) end
end

local function confirmFocusToggle(panel)
    panel.onConfirm = not panel.onConfirm
end

local function createConfirmPanel(pn, messageText, actionKey, payload)
    local tm = getTextManager()
    local fhS = tm:getFontHeight(UIFont.Small)
    local btnH = math.max(28, fhS + 10)
    local lineH = fhS + 4
    local pad = 12
    local sw = getPlayerScreenWidth(pn) or getCore():getScreenWidth()
    local sh = getPlayerScreenHeight(pn) or getCore():getScreenHeight()
    local actionText = getText(actionKey)
    local cancelText = getText("UI_MinidoracatMiniMap_TripCancel")
    local actionW = measureSmall(actionText) + 24
    local cancelW = measureSmall(cancelText) + 24
    local w = math.min(math.max(280, 20 * fhS), sw - 20)
    local stacked = actionW + cancelW + pad * 3 > w
    if stacked then actionW, cancelW = w - pad * 2, w - pad * 2 end
    local lines = wrapLines(messageText, w - pad * 3)
    local actionsH = stacked and (btnH * 2 + 6) or btnH
    local h = math.min(pad + #lines * lineH + pad + actionsH + pad, sh - 20)
    local actionsY = h - pad - actionsH
    local panel = ISPanel:new(0, 0, w, h)
    panel:initialise()
    panel:instantiate()
    panel.background = false
    panel.moveWithMouse = true
    panel.payload = payload
    panel.lines = lines
    panel.lineH = lineH
    panel.onConfirm = false -- 預設焦點在取消：破壞性動作不接受「順手按 Enter」
    panel.actionBtn = ISButton:new(w - pad - actionW, stacked and (actionsY + btnH + 6) or actionsY, actionW, btnH,
        actionText, panel, function(target) confirmApply(target) end)
    panel.actionBtn:initialise()
    styleButton(panel.actionBtn)
    panel.actionBtn.backgroundColor = { r = 0.45, g = 0.12, b = 0.08, a = 0.7 }
    panel:addChild(panel.actionBtn)
    panel.cancelBtn = ISButton:new(pad, actionsY, cancelW, btnH,
        cancelText, panel, function(target) confirmClose(target) end)
    panel.cancelBtn:initialise()
    styleButton(panel.cancelBtn)
    panel:addChild(panel.cancelBtn)
    panel.messageList = ISScrollingListBox:new(pad, pad, w - pad * 2, math.max(0, actionsY - pad * 2))
    panel.messageList:initialise()
    panel.messageList:instantiate()
    panel.messageList.itemheight = lineH
    panel.messageList.font = UIFont.Small
    panel.messageList.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    panel.messageList.doDrawItem = function(list, y, item)
        list:drawText(item.text, 0, y, 1, 1, 1, 1, UIFont.Small)
        return y + list.itemheight
    end
    for i = 1, #lines do panel.messageList:addItem(lines[i], {}) end
    panel:addChild(panel.messageList)
    panel.prerender = function(self)
        local Skin = Core.Skin
        if Skin then
            Skin.fill(self, 0, 0, self.width, self.height, Skin.COLORS.BG_PANEL)
            Skin.border(self, 0, 0, self.width, self.height, Skin.COLORS.BORDER)
        else
            self:drawRect(0, 0, self.width, self.height, 0.9, 0, 0, 0)
            self:drawRectBorder(0, 0, self.width, self.height, 1, 0.4, 0.4, 0.4)
        end
        local el = self.onConfirm and self.actionBtn or self.cancelBtn
        self:drawRectBorder(el.x - 3, el.y - 3, el.width + 6, el.height + 6, 0.95, 1, 0.85, 0.4)
    end
    panel:setWantKeyEvents(true)
    panel.isKeyConsumed = function(self, k)
        if self.consumedKey == k then self.consumedKey = nil; return true end
        if not self:isVisible() then return false end
        return k == Keyboard.KEY_ESCAPE or k == Keyboard.KEY_RETURN or k == Keyboard.KEY_TAB
            or k == Keyboard.KEY_LEFT or k == Keyboard.KEY_RIGHT
            or k == Keyboard.KEY_UP or k == Keyboard.KEY_DOWN
    end
    panel.onKeyRelease = function(self, k)
        if not self:isVisible() then return end
        self.consumedKey = k -- UIElement 先派發 onKeyRelease，再詢問 isKeyConsumed。
        if k == Keyboard.KEY_ESCAPE then
            confirmClose(self)
        elseif k == Keyboard.KEY_UP or k == Keyboard.KEY_DOWN then
            listStep(self.messageList, k == Keyboard.KEY_UP and -1 or 1)
        elseif k == Keyboard.KEY_TAB or k == Keyboard.KEY_LEFT or k == Keyboard.KEY_RIGHT then
            confirmFocusToggle(self)
        elseif k == Keyboard.KEY_RETURN then
            if self.onConfirm then confirmApply(self) else confirmClose(self) end
        end
    end
    panel.onJoypadDown = function(self, button)
        if button == Joypad.AButton then
            if self.onConfirm then confirmApply(self) else confirmClose(self) end
        elseif button == Joypad.BButton then
            confirmClose(self)
        end
    end
    panel.onJoypadDirLeft = function(self) confirmFocusToggle(self) end
    panel.onJoypadDirRight = function(self) confirmFocusToggle(self) end
    panel.onJoypadDirUp = function(self) listStep(self.messageList, -1) end
    panel.onJoypadDirDown = function(self) listStep(self.messageList, 1) end
    panel:setX(math.max(0, (getPlayerScreenLeft(pn) or 0) + math.floor((sw - w) / 2)))
    panel:setY(math.max(0, (getPlayerScreenTop(pn) or 0) + math.floor((sh - h) / 2)))
    return panel
end

local function tripPrompt(pn, textKey, arg, actionKey, payload)
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    payload.pn = pn
    payload.owner = playerObj
    payload.revision = tripRevision(tripState(pn))
    payload.error = tripErrorReason(pn)
    local win = searchWin
    if win and win:isVisible() then
        -- 開確認面板前先解焦：輸入框還聚焦時底層會吃掉 Enter/ESC
        if win.entry and win.entry.unfocus then win.entry:unfocus() end
        win.focus = nil
        if win.confirm then confirmClose(win.confirm) end
    end
    local panel = createConfirmPanel(pn, getText(textKey, arg), actionKey, payload)
    if win and win:isVisible() then win.confirm = panel end
    panel:addToUIManager()
    panel:bringToTop()
    if JoypadState and JoypadState.players and JoypadState.players[pn + 1] then
        claimJoypad(panel, pn)
    end
end

-- 雙地圖右鍵與搜尋頁共用的目標入口。op 一律明確傳入：
-- replace＝Core.navSetTarget，取代整份行程成單站並**立即開始導航**，所以會丟掉待前往
-- 站或壞資料時一律先確認（走完的行程沒有東西可丟，直接取代）；append 只加到清單最後、
-- 不出發；priority 插在第一個待前往站之前並明確開始導航（不啟自駕），取代舊的 next——
-- 沒有別名、沒有舊語意入口。
-- 舊 next 與任何未知 op（含 nil）一律回報 badargs 並停止：把未知操作「落回
-- replace」會把一次編輯升格成取代整趟，空行程時更直接建立單站行程發車
-- （review UI-1）——那是這支函式最破壞性的一條路，不能靠猜。
local PROMPT_OPS = { replace = true, append = true, priority = true }
Core.navPromptTarget = function(pn, x, y, label, op)
    pn = pn or 0
    if type(x) ~= "number" or type(y) ~= "number" then return end
    if type(op) ~= "string" or not PROMPT_OPS[op] then
        winError(pn, "badargs")
        return
    end
    local st = tripState(pn)
    if op ~= "replace" then
        tripEdit(pn, tripRevision(st), op, x, y, label)
        return
    end
    -- 壞資料時 snapshot 可能是 nil，但取代同樣要確認（不偷偷抹掉待診斷資料）；
    -- 待前往站數＝插入錨點數（Core.navInsertAnchors，本檔下方）
    if Core.navInsertAnchors(pn) > 0 or tripErrorReason(pn) then
        tripPrompt(pn, "UI_MinidoracatMiniMap_TripConfirmReplace",
            label or string.format("%d, %d", math.floor(x), math.floor(y)),
            "UI_MinidoracatMiniMap_TripReplaceAction",
            { op = "replace", x = x, y = y, label = label })
        return
    end
    local ok, reason, detailKey = Core.navSetTarget(pn, x, y, label)
    if not ok then winError(pn, reason, detailKey) end
end

-- 清空：有站點要確認；沒有站點但存檔資料損壞時也要能清（那正是重建的出口，
-- 成功的 commit 會一併清掉 slot.error），只有兩者皆無才回報沒有行程
Core.navPromptClear = function(pn)
    pn = pn or 0
    local st = tripState(pn)
    local count = st and st.count or 0
    local err = tripErrorReason(pn)
    if count == 0 and not err then
        winError(pn, "noitinerary")
        return
    end
    tripPrompt(pn, count > 0 and "UI_MinidoracatMiniMap_TripConfirmClear"
        or "UI_MinidoracatMiniMap_TripConfirmClearBroken", tostring(count),
        "UI_MinidoracatMiniMap_TripClear", { op = "clear" })
end

-- 移除收藏：共用確認面板（op=placeRemove；confirmApply 只驗 owner 與收藏仍在）
Core.navPromptPlaceRemove = function(pn, id)
    pn = pn or 0
    local place = placeById(pn, id)
    if not place then
        winMessage(pn, placesErrorText("stale"))
        return
    end
    local label = placeName(pn, place)
    tripPrompt(pn, "UI_MinidoracatMiniMap_PlaceConfirmRemove", label,
        "UI_MinidoracatMiniMap_PlaceRemove", { op = "placeRemove", placeId = id, label = label })
end

--------------------------------------------------------------------------------
-- 插入位置（雙地圖右鍵子選單與搜尋頁共用同一份組裝與防線）
--------------------------------------------------------------------------------
-- 可當錨點的待前往站數：雙地圖用它決定要不要掛子選單，搜尋頁用它決定要不要開
-- 選單（零錨點時插入等於加尾，不開只有一個選項的選單）
Core.navInsertAnchors = function(pn)
    local st = tripState(pn or 0)
    local n = 0
    for i = 1, (st and st.count or 0) do
        if st.stops[i].status == "pending" then n = n + 1 end
    end
    return n
end

-- 組裝「插在 N. 站名 之前」各項＋「加到行程最後」。每個選項在**建立時**就捕捉
-- owner（角色物件本體）＋revision＋錨點 stopId：選單開著的期間行程可能被自駕推進
-- 或別的入口改動，延遲點擊不得插到別的位置（同確認面板的防線，契約
-- docs/addon-api.md §6.5）。回可插入的錨點數
--
-- 選項文字有界（review UI-4）：原生 calcWidth 以最長選項的全文寬度算寬，render
-- 每幀還會改回全文寬（ISContextMenu.lua:616-627／574-578），128 單位長站名在窄
-- viewport／大字級會把單行選單撐出畫面；子選單放不下時原生還會改掛到父選單左側、
-- 連編號都可能落在負 X（render:583-590）。所以選項只放「第幾站＋放得下的站名
-- 前綴」，被截短的項目點下去先開既有可捲確認面板把全文讀完再套用——鍵盤／手把
-- 與滑鼠同一條路徑，不是只有滑鼠 hover 才看得到的 tooltip
local INSERT_MENU_RATIO = 0.4 -- 選項文字寬上限佔該玩家 viewport 寬的比例
local function insertOptionText(pn, index, stop)
    local name = stopName(stop)
    local full = getText("UI_MinidoracatMiniMap_TripInsertBefore", tostring(index), name)
    local sw = getPlayerScreenWidth(pn) or getCore():getScreenWidth()
    local maxW = math.floor(sw * INSERT_MENU_RATIO)
    if measureSmall(full) <= maxW then return full, nil end
    -- 樣板（第幾站＋前後綴）一律保留：截短後玩家至少仍看得出是哪一站
    local room = maxW - (measureSmall(full) - measureSmall(name)) - measureSmall("...")
    local short = room > 0 and (name:sub(1, fitPrefix(name, room)) .. "...") or "..."
    local label = getText("UI_MinidoracatMiniMap_TripInsertBefore", tostring(index), short)
    if measureSmall(label) > maxW then label = tostring(index) end
    return label, full
end

Core.navInsertOptions = function(menu, target, pn, x, y, label)
    pn = pn or 0
    local st = tripState(pn)
    local playerObj = getSpecificPlayer(pn)
    if not (st and playerObj) then return 0 end
    local revision = tripRevision(st)
    local n = 0
    for i = 1, (st.count or 0) do
        local stop = st.stops[i]
        if stop.status == "pending" then
            -- clipped＝被截短時的完整描述（nil＝選項本身就是全文，直接套用）
            local text, clipped = insertOptionText(pn, i, stop)
            menu:addOption(text, target, Core.navApplyInsert,
                { pn = pn, x = x, y = y, label = label, before = stop.id,
                    revision = revision, owner = playerObj, clipped = clipped })
            n = n + 1
        end
    end
    if n > 0 then
        menu:addOption(getText("UI_MinidoracatMiniMap_TripAdd"), target, Core.navApplyInsert,
            { pn = pn, x = x, y = y, label = label, revision = revision, owner = playerObj })
    end
    return n
end

-- 選單點擊：owner、revision、載入錯誤旗標、錨點是否仍在且仍待前往，任一不符即
-- 整筆拒絕並說明——延遲點擊不得插到別人算好的位置上
Core.navApplyInsert = function(_, payload)
    if type(payload) ~= "table" then return end
    local pn = payload.pn or 0
    local playerObj = getSpecificPlayer(pn)
    if playerObj == nil or playerObj ~= payload.owner then return end
    local st = tripState(pn)
    if tripRevision(st) ~= payload.revision or tripErrorReason(pn) then
        winError(pn, "stale")
        return
    end
    if payload.before == nil then
        tripEdit(pn, payload.revision, "append", payload.x, payload.y, payload.label)
        return
    end
    local anchor = tripStopById(st, payload.before)
    if not anchor or anchor.status ~= "pending" then
        winError(pn, "stale")
        return
    end
    if payload.clipped then
        -- 選單只看得到截短的站名：先用既有可捲確認面板讀完整錨點描述再套用。
        -- owner／revision／穩定 stopId 一路帶到 confirmApply 再驗一次才 commit
        tripPrompt(pn, "UI_MinidoracatMiniMap_TripConfirmInsert", payload.clipped,
            "UI_MinidoracatMiniMap_TripInsertAction",
            { op = "insert", x = payload.x, y = payload.y, label = payload.label,
                before = payload.before })
        return
    end
    tripEdit(pn, payload.revision, "insert", payload.x, payload.y, payload.label, payload.before)
end

-- 雙地圖右鍵用（Core.mapMenuFill 第二項）：掛「加入行程」子選單——先去這裡、插在第 N 站之前與
-- 加到行程最後（Core.navInsertOptions，同搜尋頁）。沒有待前往站可當錨點時整項不加：插入等於加尾，
-- 呼叫端改放平的「加到行程最後」；不能掛子選單（Core.mapSubMenu 回 nil）時同樣交給呼叫端。
-- blocked＝Core.navMenuBlocked 的原因文字：只加紅色父項＋說明、不掛子選單（停用父項的子選單照樣
-- 點得到）。回 true＝已加這一項
Core.navInsertSubMenu = function(context, target, pn, x, y, label, blocked)
    if Core.navInsertAnchors(pn) == 0 then return end
    if blocked then
        Core.navMenuLock(context:addOption(getText("UI_MinidoracatMiniMap_TripAddMenu")), blocked)
        return true
    end
    local sub = Core.mapSubMenu(context, "UI_MinidoracatMiniMap_TripAddMenu")
    if not sub then return end
    sub:addOption(getText("UI_MinidoracatMiniMap_TripPriority"), target,
        target.onMinidoracatPriorityStop, x, y)
    Core.navInsertOptions(sub, target, pn, x, y, label)
    return true
end

--------------------------------------------------------------------------------
-- 行程頁動作（全部走共享 Core 契約；本檔不保留任何行程副本）
--------------------------------------------------------------------------------
local function tripStart(win)
    local pn = win.playerNum or 0
    local token, reason, detailKey =
        MinidoracatMiniMapAPI.startNavItinerary(pn, tripRevision(tripState(pn)))
    if not token then winError(pn, reason, detailKey) end
end

local function tripPause(win)
    local pn = win.playerNum or 0
    local ok, reason = Core.navPauseItinerary(pn, "manual")
    if not ok then winError(pn, reason) end
end

-- 以畫面上顯示的模式／版本切換；不先 pause 再 start，避免第二步失敗丟掉原指引。
local function tripManual(win, intent)
    local pn = win.playerNum or 0
    local phase, revision = win._tPhase, win._tRev
    if intent then phase, revision = intent.phase, intent.revision end
    local mode = phase == "approach" and "navigating" or "approach"
    local ok, reason, detailKey = Core.navGuideItinerary(pn, revision, mode)
    if not ok then winError(pn, reason, detailKey) end
end

local function tripPreview(win)
    local pn = win.playerNum or 0
    Core.navSetPreview(pn, Core.navPreviewState(pn) == "off")
end

local function tripShowOnMap(win)
    local it = tripSelectedStop(win)
    if not it then return end
    pingAndShow(win.playerNum or 0, it.x, it.y)
end

local function tripMoveUp(win)
    local it = tripSelectedStop(win)
    if not it or not it.canUp then return end
    local pn = win.playerNum or 0
    tripEdit(pn, tripRevision(tripState(pn)), "move", it.stopId, -1)
end

local function tripMoveDown(win)
    local it = tripSelectedStop(win)
    if not it or not it.canDown then return end
    local pn = win.playerNum or 0
    tripEdit(pn, tripRevision(tripState(pn)), "move", it.stopId, 1)
end

local function tripRemove(win)
    local it = tripSelectedStop(win)
    if not it then return end
    local pn = win.playerNum or 0
    tripEdit(pn, tripRevision(tripState(pn)), "remove", it.stopId)
end

-- 逐站停等標記：只改「待前往」站的 pause 旗標（契約 pause(stopId, bool) 不動目前
-- token）。已抵達／已略過的站不可改；自動接續模式同樣會在標了停等的站停下來
local function tripTogglePause(win)
    local it = tripSelectedStop(win)
    if not it or it.status ~= "pending" then return end
    local pn = win.playerNum or 0
    tripEdit(pn, tripRevision(tripState(pn)), "pause", it.stopId, not it.pause)
end

local function tripSkip(win)
    local pn = win.playerNum or 0
    local st = tripState(pn)
    local id = tripSkippable(st)
    if not id then
        winError(pn, "state")
        return
    end
    tripEdit(pn, tripRevision(st), "skip", id)
end

local function tripUndo(win)
    local pn = win.playerNum or 0
    tripEdit(pn, tripRevision(tripState(pn)), "undo")
end

local function tripClear(win)
    Core.navPromptClear(win.playerNum or 0)
end

-- 回家：永遠可按（未設家／已在家由 Core.placesGoHome 自己說明）；缺函式＝generic 錯誤
local function tripGoHome(win)
    local pn = win.playerNum or 0
    local go = Core.placesGoHome
    if not go then
        winMessage(pn, placesErrorText("failed"))
        return
    end
    go(pn)
end

-- 找不到道路時「畫自訂道路」（介面審查 #2；設計稿 1.5）：地圖開在離這站最近的道路點，從那裡畫過來；
-- 路網沒好或附近沒有道路＝開在這站本身
local function tripDrawRoad(win)
    local pn = win.playerNum or 0
    local st = tripState(pn)
    local stop = tripStopById(st, st and st.currentStopId) or tripStopById(st, tripFirstPending(st))
    if not stop then return end
    -- ponytail: 固定 2000 格搜尋半徑；要依地圖大小調再改
    local road = Core.navNearestRoad and Core.navNearestRoad(pn, stop.x, stop.y, 2000)
    roadOpen(pn, "roadToolStart", { mode = "draw",
        near = road and { x = road.x, y = road.y } or { x = stop.x, y = stop.y } })
end

--------------------------------------------------------------------------------
-- 道路頁動作（2026-10-23 設計稿 minimap-custom-roads-1023 主張 3）：資料與工具都在別的檔，
-- 本檔只把選中列轉成契約呼叫
--------------------------------------------------------------------------------
-- 道路頁選中列（草稿或道路）；群組標題與說明列是 info，不算
local function roadSelected(win)
    local row = win.list.items and win.list.items[win.list.selected]
    local it = row and row.item or nil
    if it and (it.kind == "road" or it.kind == "draft") then return it end
    return nil
end

-- 刪除自訂道路：共用確認面板（按鈕寫明動作、預設焦點在取消；confirmApply 只驗 owner 與道路仍在）。
-- 分享出去的路（有 sid）刪除時 _Roads.lua 會一併收回分享，確認文要先講。地圖右鍵的道路子選單也呼叫這裡
Core.roadsPromptDelete = function(pn, id)
    pn = pn or 0
    local road = Core.roadsGet and Core.roadsGet(pn, id)
    if not road then
        roadReport(pn, false, "notfound")
        return
    end
    tripPrompt(pn, road.sid and "UI_MinidoracatMiniMap_RoadConfirmDeleteShared"
            or "UI_MinidoracatMiniMap_RoadConfirmDelete", road.name,
        "UI_MinidoracatMiniMap_RoadDeleteAction", { op = "roadDelete", roadId = id })
end

-- 捨棄草稿：草稿只在記憶體，誤按就沒了，要確認（按鈕寫「捨棄」、預設焦點在取消）；0–1 點沒什麼可丟，直接捨棄
local function roadDiscard(pn, draft)
    if #(draft.pts or {}) <= 2 then
        roadOpen(pn, "roadsClearDraft")
        return
    end
    tripPrompt(pn, "UI_MinidoracatMiniMap_RoadConfirmDiscard", nil,
        "UI_MinidoracatMiniMap_RoadDraftDiscard", { op = "roadDraftDrop", draft = draft })
end

-- 改名：原版 ISTextBox（同 _Places.lua promptName；ISTextBox.lua:178 以 maxChars 擋 OK）。
-- 按下時角色已換＝不寫入新角色。地圖右鍵的道路子選單也呼叫這裡
Core.roadsPromptRename = function(pn, id)
    pn = pn or 0
    local player = getSpecificPlayer(pn)
    local road = player and Core.roadsGet and Core.roadsGet(pn, id)
    if not road then
        roadReport(pn, false, "notfound")
        return
    end
    local modal = ISTextBox:new(0, 0, 280, 180, getText("UI_MinidoracatMiniMap_RoadNameTitle"),
        road.name or "", nil, function(_, button)
            if button.internal ~= "OK" or getSpecificPlayer(pn) ~= player then return end
            roadEdit(pn, "UI_MinidoracatMiniMap_RoadRenamed", "roadsRename", id, button.parent.entry:getText())
        end, pn)
    modal:initialise()
    modal:addToUIManager()
    local codec = MinidoracatMiniMapRoadCodec
    modal.maxChars = codec and codec.MAX_NAME or 128
    if getJoypadData(pn) then
        modal:centerOnScreen(pn)
        modal.prevFocus = getJoypadFocus(pn)
        setJoypadFocus(pn, modal)
    end
end

local function roadDrawNew(win)
    local pn = win.playerNum or 0
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    roadOpen(pn, "roadToolStart", { mode = "draw", near = { x = playerObj:getX(), y = playerObj:getY() } })
end

local function roadRecordToggle(win)
    local pn = win.playerNum or 0
    local recording = Core.roadRecordState and Core.roadRecordState(pn) ~= nil
    roadOpen(pn, recording and "roadRecordStop" or "roadRecordStart")
end

-- 在世界地圖顯示；草稿＝回到地圖接著畫或確認（草稿只活在工具裡，顯示它就是打開工具）
local function roadShow(win)
    local it = roadSelected(win)
    if not it then return end
    local pn = win.playerNum or 0
    if it.kind == "draft" then
        roadOpen(pn, "roadToolStart", { mode = "review", draft = it.draft })
    elseif it.own then
        roadOpen(pn, "roadsShowOnMap", "own", it.id)
    else
        roadOpen(pn, "roadsShowOnMap", "received", it.sid)
    end
end

-- 選單點擊：建立選項時捕捉 owner 與目標（同 placeMenuApply），延遲點擊先驗 owner；道路是否仍在由 Core 回報
local function roadMenuApply(_, p)
    local pn, op = p.pn, p.op
    if getSpecificPlayer(pn) ~= p.owner then return end
    if op == "continue" then
        roadOpen(pn, "roadToolStart", { mode = "review", draft = p.draft })
    elseif op == "discard" then
        roadDiscard(pn, p.draft)
    elseif op == "edit" then
        roadOpen(pn, "roadToolStart", { mode = "edit", roadId = p.id })
    elseif op == "rename" then
        Core.roadsPromptRename(pn, p.id)
    elseif op == "share" then
        roadOpen(pn, "roadsOpenShare", p.id)
    elseif op == "enable" then
        roadEdit(pn, nil, "roadsSetEnabled", p.id, p.on)
    elseif op == "delete" then
        Core.roadsPromptDelete(pn, p.id)
    elseif op == "off" then
        roadEdit(pn, nil, "roadsSetReceivedOff", p.sid, p.on)
    elseif op == "copy" then
        roadEdit(pn, "UI_MinidoracatMiniMap_RoadCopied", "roadsCopyReceived", p.sid)
    end
end

-- 「動作…」與清單右鍵的道路項（依選中列）：草稿＝繼續／捨棄；我的路＝編輯形狀、改名、分享、
-- 用於／不用於導航、刪除（會刪資料的排最後）；收到的路只能停用或複製一份
local function roadOptions(menu, win)
    local it = roadSelected(win)
    local pn = win.playerNum or 0
    local owner = getSpecificPlayer(pn)
    if not (it and owner) then
        menu:addOption(getText("UI_MinidoracatMiniMap_RoadEditShape")).notAvailable = true
        return
    end
    local function add(key, payload)
        payload.pn, payload.owner = pn, owner
        return menu:addOption(getText(key), win, roadMenuApply, payload)
    end
    if it.kind == "draft" then
        add("UI_MinidoracatMiniMap_RoadDraftContinue", { op = "continue", draft = it.draft })
        add("UI_MinidoracatMiniMap_RoadDraftDiscard", { op = "discard", draft = it.draft })
    elseif it.own then
        add("UI_MinidoracatMiniMap_RoadEditShape", { op = "edit", id = it.id })
        add("UI_MinidoracatMiniMap_RoadRename", { op = "rename", id = it.id })
        -- 分享：單機不列；多人時不能分享（沙盒關、沒有陣營也沒有安全屋）照原版慣例紅字＋原因，
        -- RoadShare 缺席時當不可用、不寫原因
        if isClient() then
            local share = add("UI_MinidoracatMiniMap_RoadShare", { op = "share", id = it.id })
            local ok, reasonKey = false, nil
            if Core.roadShareAvailable then ok, reasonKey = Core.roadShareAvailable(pn) end
            if not ok then
                share.notAvailable = true
                if reasonKey then optionTip(share, getText(reasonKey)) end
            end
        end
        add(it.enabled and "UI_MinidoracatMiniMap_RoadNavOff" or "UI_MinidoracatMiniMap_RoadNavOn",
            { op = "enable", id = it.id, on = not it.enabled })
        add("UI_MinidoracatMiniMap_RoadDelete", { op = "delete", id = it.id })
    else
        add(it.off and "UI_MinidoracatMiniMap_RoadNavOn" or "UI_MinidoracatMiniMap_RoadNavOff",
            { op = "off", sid = it.sid, on = not it.off })
        add("UI_MinidoracatMiniMap_RoadCopy", { op = "copy", sid = it.sid })
    end
end

--------------------------------------------------------------------------------
-- 刷新
--------------------------------------------------------------------------------
-- 列的排版：名稱按實測字寬換行（不截字）；名稱與右欄同行放不下時，右欄／狀態
-- 改到名稱之後的獨立一行，名稱獨佔整行寬度。右欄自己也擠不進一行時（窄視窗／
-- 大字級），狀態與座標各自分列並同樣按實寬換行——寧可列再高，也不讓兩段文字
-- 落在同一個起點疊字。版面未指派（list.width 為 nil）時不做判定——沒有實際
-- 寬度就談不上換行
local function prepareRow(list, row, item, nameX, metaW, extraLine)
    local width = list.width
    if not width then return end
    local full = width - nameX - 14
    item.nameX = nameX
    item.badgeLines, item.rightLines = nil, nil
    if metaW > 0 and measureSmall(item.label) <= full - metaW - 10 then
        item.lines = { item.label }
        item.metaOwn = false
    else
        item.lines = wrapLines(item.label, full)
        item.metaOwn = metaW > 0
    end
    local metaRows = 0
    if item.metaOwn then
        metaRows = 1
        if metaW > full then -- 狀態＋座標同列也放不下：各自成列，過寬再自己換行
            if item.badge then
                item.badgeLines = wrapLines(item.badge, full)
                metaRows = #item.badgeLines
            else
                metaRows = 0
            end
            item.rightLines = wrapLines(item.right, full)
            metaRows = metaRows + #item.rightLines
        end
    end
    local extra = #item.lines - 1 + metaRows + (extraLine and 1 or 0)
    if extra > 0 then row.height = list.itemheight + extra * list._minidoracatLineH end
end

-- 說明／全文列：按實寬換行後**一行一列**加入清單（沿用確認面板 messageList 的
-- 一行一列模式）。不得塞成單一超高列——原生 ISScrollingListBox 的 ensureVisible
-- 只把該列頂端或底端對齊可視範圍（ISScrollingListBox.lua:623-639），列高大於清單
-- 高時方向鍵／手把只看得到一端，中段永遠捲不到（review UI-3）。拆出來的每一行
-- 仍是 kind=info：它們不是站點也不是地點，既有防呆照舊擋掉
local function addInfoLine(list, text)
    local item = { kind = "info", label = text }
    local row = list:addItem(text, item)
    prepareRow(list, row, item, 12, 0)
    return row
end

local function addInfoRow(list, text)
    if not list.width then return addInfoLine(list, text) end
    local lines = wrapLines(text, list.width - 12 - 14) -- 同 prepareRow 的可用寬
    if #lines <= 1 then return addInfoLine(list, text) end
    local first
    for i = 1, #lines do
        local row = addInfoLine(list, lines[i])
        if not first then first = row end
    end
    return first
end

-- 收藏列（收藏頁，與搜尋頁未輸入時）：家第一，其餘照收藏順序；以 placeId 保留選取。
-- unsupported（較新 schema，拒絕寫入）接在清單後說明；invalid 依契約當空清單
local function addPlaceRows(win, pn, ps, err, px, py, keepId)
    local list = win.list
    local count = ps and ps.count or 0
    if count == 0 then addInfoRow(list, getText("UI_MinidoracatMiniMap_PlacesEmpty")) end
    for pass = 1, 2 do
        for i = 1, count do
            local place = ps.places[i]
            local home = place.id == ps.homeId
            if home == (pass == 1) then
                local item = finalizeItem({ kind = "place", placeId = place.id, home = home,
                    x = place.x, y = place.y, label = placeName(pn, place),
                    d = math.sqrt(dist2(px, py, place.x, place.y)) })
                local row = list:addItem(item.label, item)
                prepareRow(list, row, item, 24 + item.tagW + 10, item.rightW)
                if keepId == place.id then list.selected = row.itemindex end
            end
        end
    end
    if err == "unsupported" then addInfoRow(list, placesErrorText(err)) end
end

-- 搜尋框也比對收藏名稱（2026-10-21 設計稿 minimap-places-entry-1021 作答）：名稱含查詢字就列出，
-- 排在街道與設施前面；家第一，其餘照收藏順序（同 addPlaceRows）。比對的是顯示名稱（Core.placeLabel：
-- 沒有名字的家＝「家」、沒有名字的收藏＝座標）。座標查詢不比對：打座標要的是那個座標本身
local function matchPlaces(pn, ps, text, px, py)
    local out = {}
    local q = text:match("^%s*(.-)%s*$")
    if not ps or q == "" or parseCoords(q) then return out end
    q = q:lower()
    for pass = 1, 2 do
        for i = 1, ps.count or 0 do
            local place = ps.places[i]
            local home = place.id == ps.homeId
            if home == (pass == 1) then
                local name = placeName(pn, place)
                if name:lower():find(q, 1, true) then
                    out[#out + 1] = finalizeItem({ kind = "place", placeId = place.id, home = home,
                        x = place.x, y = place.y, label = name,
                        d = math.sqrt(dist2(px, py, place.x, place.y)) })
                end
            end
        end
    end
    return out
end

local function winRefresh(win, force)
    -- 選取相依的動作（滑鼠改選不會動 cache key）先處理，成本只是純量比較：
    -- 空字串／載入中／查無命中的說明列不是地點，五個目標動作一律停用——按鈕亮著
    -- 卻按了沒反應是 review blocking
    if win.list.selected ~= win._searchSel then
        win._searchSel = win.list.selected
        local has = winSelectedItem(win) ~= nil
        win.gotoBtn:setEnable(has)
        win.addBtn:setEnable(has)
        win.insertBtn:setEnable(has)
        win.priorityBtn:setEnable(has)
        win.replaceBtn:setEnable(has)
    end
    -- 引擎冷啟動／nodata 重試泵（每幀，prerender 呼叫）：沒設導航目標時 drawNavRoute
    -- 在 kick 前就 return，搜尋是唯一入口（codex review）。實際泵送（小地圖 live inner
    -- ＋世界地圖單例、非 idle O(1) 早退、nodata per-inner 節流）收斂在 _NavRoute 的
    -- Core.navKickAvailable，本檔不再各自取表面
    local pn = win.playerNum or 0
    if Core.navKickAvailable then Core.navKickAvailable(pn) end
    -- 收藏頁不看搜尋框：搜尋框留著上次的字，收藏頁照樣列出全部收藏
    local onPlaces = win.page == "places"
    local text = onPlaces and "" or (win.entry:getInternalText() or "")
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end -- 不寫 key：玩家回來後同 key 仍要能刷（review）
    local px, py = playerObj:getX(), playerObj:getY()
    -- cache key＝頁＋文字＋引擎狀態（review：索引屬非同步建置，只鍵文字會在
    -- ready 後永遠停在「載入中」；欄位比較零每幀字串配置）＋收藏 revision／錯誤（搜尋結果也列收藏，
    -- 改名或刪除後要重算）。未輸入時另鍵玩家 8 格位置桶（同行程頁：站著不動零重建）
    local st = Core.navEngineState and Core.navEngineState() or "unknown"
    local ps = placesRead(pn)
    local pRev = ps and ps.revision or nil
    local pErr = Core.placesError and Core.placesError(pn) or nil
    local bx, by = nil, nil
    if text == "" then
        bx, by = math.floor(px / 8), math.floor(py / 8)
    end
    if not force and win.page == win._lastPage and text == win._lastText and st == win._lastState
        and pRev == win._pRev and pErr == win._pErr and bx == win._pBx and by == win._pBy then
        return
    end
    win._lastPage = win.page
    win._lastText = text
    win._lastState = st
    win._pRev, win._pErr, win._pBx, win._pBy = pRev, pErr, bx, by
    local keep = winSelectedItem(win)
    local keepId = keep and keep.kind == "place" and keep.placeId or nil
    win.list:clear()
    win._searchSel = nil -- 清單重建：下個 prerender 依新的選取重算動作可用性
    if onPlaces then
        -- 收藏頁：只有家與收藏（缺 _Places 時不列）
        if Core.placesState then addPlaceRows(win, pn, ps, pErr, px, py, keepId) end
        if win.msgFull then addInfoRow(win.list, win.msgFull) end
        return
    end
    local results = matchPlaces(pn, ps, text, px, py)
    local found = doSearch(text, px, py)
    for i = 1, #found do results[#results + 1] = found[i] end
    if #results == 0 then
        if text == "" then
            -- 還沒輸入：先列收藏（缺 _Places 時不列），再明說要輸入什麼才有動作
            if Core.placesState then addPlaceRows(win, pn, ps, pErr, px, py, keepId) end
            addInfoRow(win.list, getText("UI_MinidoracatMiniMap_SearchEmptyHint"))
        else
            -- 街名索引與路網可分別就緒；建圖失敗不能誤報已可用的街名索引失敗。
            -- 提示分成短列，沿用 info 防呆與捲動，不把恢復說明擠成一行。
            local titleKey = "UI_MinidoracatMiniMap_SearchNoResult"
            local hintKey = "UI_MinidoracatMiniMap_SearchTryAnother"
            local retryKey
            local count = 2
            if not (Core.navStreetIndex and Core.navStreetIndex()) then
                if st == "failed" then
                    titleKey = "UI_MinidoracatMiniMap_SearchStreetFailed"
                    hintKey = "UI_MinidoracatMiniMap_SearchTryCoordinates"
                    retryKey = "UI_MinidoracatMiniMap_SearchReenterWorld"
                    count = 3
                elseif st == "idle" or st == "extracting" or st == "building" then
                    titleKey = "UI_MinidoracatMiniMap_SearchLoading"
                    count = 1
                else
                    titleKey = "UI_MinidoracatMiniMap_SearchStreetUnavailable"
                    hintKey = "UI_MinidoracatMiniMap_SearchTryCoordinates"
                end
            end
            local keys = { titleKey, hintKey, retryKey }
            for i = 1, count do
                addInfoRow(win.list, getText(keys[i]))
            end
        end
    else
        for i = 1, #results do
            local result = results[i]
            local row = win.list:addItem(result.label, result, result.sourceHint)
            prepareRow(win.list, row, result, 24 + result.tagW + 10, result.rightW,
                result.sourceHint ~= nil)
            if keepId and result.placeId == keepId then win.list.selected = row.itemindex end
        end
    end
    -- 訊息列收不住的完整文字接在結果之後：選取索引 1 仍是第一個可用地點
    if win.msgFull then addInfoRow(win.list, win.msgFull) end
end

-- 行程頁刷新。cache key 全為純量（revision／phase／reason／接續模式／載入錯誤／
-- 預覽四值／玩家 8 格位置桶）——站著不動且行程沒變時零重建、零配置。
-- 重建時以 stopId 保留選取：距離刷新不得把玩家的選取彈回第一站
local function tripRefresh(win, force)
    local pn = win.playerNum or 0
    -- 選取相依的按鈕（滑鼠改選不會動 cache key）先處理，成本只是純量比較。
    -- 自駕已認領（公開快照的 claimed，見 tripClaimed——私有 raw trip 沒有這個欄位）
    -- 期間的目前站不可重排／刪除：Core 會擋，按鈕就不該假亮（契約不另設保留權）。
    -- 停等標記仍可改——那只決定到站後
    -- 要不要等，不碰目前 token
    if win.tripList.selected ~= win._tripSel then
        win._tripSel = win.tripList.selected
        local sel = tripSelectedStop(win)
        win.upBtn:setEnable(sel ~= nil and sel.canUp == true)
        win.downBtn:setEnable(sel ~= nil and sel.canDown == true)
        win.removeBtn:setEnable(sel ~= nil and not sel.locked)
        win.mapBtn:setEnable(sel ~= nil)
        win.pauseStopBtn:setEnable(sel ~= nil and sel.status == "pending"
            and continuationApi() ~= nil)
        win.pauseStopBtn:setTitle(getText(sel and sel.pause
            and "UI_MinidoracatMiniMap_TripUnmarkPause"
            or "UI_MinidoracatMiniMap_TripMarkPause"))
    end
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    local px, py = playerObj:getX(), playerObj:getY()
    local st = tripState(pn)
    local err = tripErrorReason(pn)
    local pstate, pdone, ptotal, pdist = Core.navPreviewState(pn)
    -- 預覽 idle 混了「沒有待前往站」「路網還沒好」「路網好了、下個 tick 才排」三種情況，要分開說
    -- （介面審查 #3）；路網狀態進 cache key，路網一好就換字
    local graph = Core.navGraphState and Core.navGraphState()
        or (Core.navEngineState and Core.navEngineState()) or nil
    local bucketX, bucketY = math.floor(px / 8), math.floor(py / 8)
    local rev = tripRevision(st)
    local phase = st and st.phase or nil
    local reason = st and st.reason or nil
    local count = st and st.count or 0
    local current = st and st.currentStopId or nil
    local auto = st ~= nil and st.autoContinue == true
    if not force and rev == win._tRev and phase == win._tPhase and reason == win._tReason
        and count == win._tCount and current == win._tCur and err == win._tErr
        and auto == win._tAuto and graph == win._tGraph
        and pstate == win._tPs and pdone == win._tPd and ptotal == win._tPt
        and pdist == win._tPdist and bucketX == win._tBx and bucketY == win._tBy then
        return
    end
    -- 目前這站找不到道路（介面審查 #2；設計稿 1.5）：亮出「畫自訂道路」。按鈕出現或收起要重排底部
    -- 按鈕，先重排再建清單（重排會作廢 cache，下面馬上寫回），清單才照新寬度排
    local noroad = phase == "paused" and reason == "noroad"
    if win.roadDrawDef.hide == noroad then
        win.roadDrawDef.hide = not noroad
        relayoutWindow(win, pn)
    end
    win._tRev, win._tPhase, win._tReason = rev, phase, reason
    win._tCount, win._tCur, win._tErr, win._tAuto = count, current, err, auto
    win._tPs, win._tPd, win._tPt, win._tPdist = pstate, pdone, ptotal, pdist
    win._tBx, win._tBy, win._tGraph = bucketX, bucketY, graph
    local tm = getTextManager()
    local textW = win.width - 20
    -- 狀態列：phase＋目標名＋後續站數＋計數＋接續模式。無路／規劃失敗／設備不可用
    -- 都不是「玩家自己停的」＝一律警告色（被動接續被 gate 擋下時 reason 會是
    -- unavailable，狀態必須說出原因，不能假裝是刻意停靠）
    local warn = reason == "noroad" or reason == "failed" or reason == "unavailable"
        or err ~= nil
    -- 已抵達與已略過分開數：把略過算進「已完成」等於謊報去過那裡
    local arrived, skipped, pending = 0, 0, 0
    for i = 1, count do
        local status = st.stops[i].status
        if status == "arrived" then
            arrived = arrived + 1
        elseif status == "skipped" then
            skipped = skipped + 1
        else
            pending = pending + 1
        end
    end
    local firstPending = tripFirstPending(st)
    local skippable = tripSkippable(st)
    local currentStop = tripStopById(st, current)
    local nextStop = tripStopById(st, firstPending)
    -- 正在前往的站＝活動相位的目前站。waiting 的 currentStopId 指向剛完成的那站，
    -- 它不是下一步；編號只是順序，不得拿舊的「1/3」當下一個目標
    local goingId = nil
    if (phase == "navigating" or phase == "approach")
        and currentStop and currentStop.status == "pending" then
        goingId = currentStop.id
    end
    local phaseText = phase and getText("UI_MinidoracatMiniMap_TripPhase_" .. phase)
        or getText("UI_MinidoracatMiniMap_TripPhase_none")
    if reason and (phase == "paused" or phase == "waiting") then
        -- waiting 也可能帶 reason（被動接續遇 gate 失敗）：原因跟著相位一起顯示
        phaseText = phaseText .. getText("UI_MinidoracatMiniMap_TripReason_" .. reason)
    end
    local head = phaseText
    if phase == "waiting" and currentStop then
        -- 已停靠／已略過＋下一目標：waiting 也可能由略過產生，略過的站不得說成
        -- 抵達或停靠；兩個名字都要出現，玩家才知道「等你繼續」要去哪
        local skippedNow = currentStop.status == "skipped"
        head = head .. (nextStop
            and getText(skippedNow and "UI_MinidoracatMiniMap_TripHeadSkipped"
                    or "UI_MinidoracatMiniMap_TripHeadStopped",
                stopName(currentStop), stopName(nextStop))
            or getText(skippedNow and "UI_MinidoracatMiniMap_TripHeadSkippedEnd"
                or "UI_MinidoracatMiniMap_TripHeadStoppedEnd", stopName(currentStop)))
    else
        local aim = goingId and currentStop or nextStop
        if aim then
            local rest = pending - 1
            head = head .. (rest > 0
                and getText("UI_MinidoracatMiniMap_TripHeadTarget", stopName(aim), tostring(rest))
                or getText("UI_MinidoracatMiniMap_TripHeadTargetLast", stopName(aim)))
        end
    end
    if count > 0 then
        head = head .. getText("UI_MinidoracatMiniMap_TripHeadCounts",
            tostring(count), tostring(arrived), tostring(skipped))
    end
    local modeApi = continuationApi() ~= nil
    local modeUsable = modeApi and count > 0 and err == nil
    if modeUsable then
        head = head .. getText(auto and "UI_MinidoracatMiniMap_TripModeNow_auto"
            or "UI_MinidoracatMiniMap_TripModeNow_stop")
    end
    win.headColor = warn and WARN_COLOR or (PHASE_COLORS[phase] or MUTED_COLOR)
    -- 預覽列：state 是權威。**只有 state=="ok" 且 done==total** 才報全程距離，
    -- 且它含兩端越野接線＝估計值不是精確門到門里程；其餘一律標「已算出部分」。
    -- 行程剛編輯完的 ("pending",0,0,0) 是刻意的重排空窗，distance 0 不得當總長
    local previewOn = pstate ~= "off" and pstate ~= "disabled"
    local sub
    if pstate == "idle" and pending == 0 then
        sub = getText("UI_MinidoracatMiniMap_RoadPreviewNoStops") -- 空行程或走完：沒有東西要算，不是在等道路資料
    elseif pstate == "idle" and graph == "ready" then
        sub = getText("UI_MinidoracatMiniMap_TripPreview_pending")
    else
        sub = getText("UI_MinidoracatMiniMap_TripPreview_" .. tostring(pstate or "off"))
    end
    if pstate == "pending" then
        sub = sub .. getText("UI_MinidoracatMiniMap_TripPreviewProgress",
            tostring(pdone or 0), tostring(ptotal or 0))
    end
    if type(pdist) == "number" and pdist > 0 then
        local whole = pstate == "ok" and pdone == ptotal
        sub = sub .. getText(whole and "UI_MinidoracatMiniMap_TripPreviewDist"
            or "UI_MinidoracatMiniMap_TripPreviewPartial", fmtDist(pdist))
    end
    -- 狀態列與預覽列共用版面預留的 HEAD_LINES*2 行：預覽列先取它要的行數（通常
    -- 一行），剩下的全給狀態列。狀態列比預覽長得多（相位＋目標名＋站數＋模式），
    -- 硬切成固定兩行會在真實 CH 文案下天天截斷，反而讓全文出口變常態
    if win.scrollInfo then
        win.headLines, win.subLines = nil, nil
    else
        win.subLines = wrapLines(sub, textW, HEAD_LINES)
        win.headLines = wrapLines(head, textW,
            math.max(1, HEAD_LINES * 2 - #win.subLines))
    end
    -- 全文出口：預留行數收不住時（窄視窗／大字級／長站名）把完整狀態與預覽也放進
    -- 可捲清單。關鍵狀態不得只剩「...」，更不能只藏在 tooltip 裡（review blocking）
    local spill = win.scrollInfo
        or (win.headLines ~= nil and win.headLines.truncated == true)
        or (win.subLines ~= nil and win.subLines.truncated == true)
    -- 清單（重建前記住選取的 stopId）
    local list = win.tripList
    local keepSelected = tripSelectedStop(win)
    local keepId = keepSelected and keepSelected.stopId or nil
    list:clear()
    if spill then
        addInfoRow(list, head)
        addInfoRow(list, sub)
    end
    -- 找不到道路：狀態列下面寫出兩條出路
    if noroad then addInfoRow(list, getText("UI_MinidoracatMiniMap_RoadNoRoadHint")) end
    if win.msgFull then addInfoRow(list, win.msgFull) end
    if err then
        addInfoRow(list, tripErrorText(err))
        addInfoRow(list, getText("UI_MinidoracatMiniMap_TripDataErrorHint"))
    end
    if not modeApi then
        -- 舊版 Core：接續模式整組不存在。說清楚比留兩顆按不動的鈕誠實
        addInfoRow(list, getText("UI_MinidoracatMiniMap_TripModeUnsupported"))
    end
    if count == 0 then
        if not err then
            addInfoRow(list, getText("UI_MinidoracatMiniMap_TripEmpty"))
            addInfoRow(list, getText("UI_MinidoracatMiniMap_TripEmptyHint"))
            if modeApi then
                addInfoRow(list, getText("UI_MinidoracatMiniMap_TripModeNeedTrip"))
            end
        end
    else
        local claimed = tripClaimed(pn, st)
        for i = 1, count do
            local stop = st.stops[i]
            local going = stop.id == goingId
            local item = {
                kind = "trip", stopId = stop.id, x = stop.x, y = stop.y,
                status = stop.status,
                pause = stop.pause == true,
                locked = claimed and stop.id == current,
                active = going,
            }
            local before, after = st.stops[i - 1], st.stops[i + 1]
            local movable = stop.status == "pending" and not item.locked
            item.canUp = movable and before ~= nil and before.status == "pending"
                and (not claimed or before.id ~= current)
            item.canDown = movable and after ~= nil and after.status == "pending"
                and (not claimed or after.id ~= current)
            item.label = stopName(stop)
            item.tag = tostring(i)
            -- 狀態文字：正在前往的那站說「前往中」，已抵達／已略過各說自己的。
            -- 目前選取只由左緣選中條表示，兩件事不混進同一段文字
            item.badge = going and getText("UI_MinidoracatMiniMap_TripStatus_going")
                or getText("UI_MinidoracatMiniMap_TripStatus_" .. stop.status)
            if item.pause then
                item.badge = item.badge .. getText("UI_MinidoracatMiniMap_TripPauseMark")
            end
            if i == count and stop.status == "pending" then
                -- 最後一站標「最後目標」＝純文字標記，不新建終點站
                item.badge = item.badge .. getText("UI_MinidoracatMiniMap_TripLastMark")
            end
            item.right = string.format("(%d, %d)  %s", stop.x, stop.y,
                fmtDist(math.sqrt(dist2(px, py, stop.x, stop.y))))
            item.tagW = tm:MeasureStringX(UIFont.Small, item.tag)
            item.badgeW = tm:MeasureStringX(UIFont.Small, item.badge)
            item.rightW = tm:MeasureStringX(UIFont.Small, item.right)
            local row = list:addItem(item.label, item)
            prepareRow(list, row, item, 10 + item.tagW + 10 + 8, item.badgeW + 10 + item.rightW)
            if keepId == stop.id then list.selected = row.itemindex end
        end
    end
    win._tripSel = nil -- 下個 prerender 依還原後的選取重算按鈕可用性
    -- 動作可用性。逐條對齊 _Itinerary.lua 的守衛，不做假亮：
    -- start 只吃 draft/paused/waiting 且要有 pending；guide 只吃
    -- paused/navigating/approach；skip 只吃「目前站且仍 pending」
    win.startBtn:setTitle(getText(phase == "waiting" and "UI_MinidoracatMiniMap_TripContinue"
        or "UI_MinidoracatMiniMap_TripStart"))
    win.startBtn:setEnable(firstPending ~= nil
        and (phase == "draft" or phase == "paused" or phase == "waiting"))
    win.pauseBtn:setEnable(phase == "navigating" or phase == "approach")
    win.manualBtn:setEnable(phase == "paused" or phase == "navigating" or phase == "approach")
    local direct = phase == "approach"
    win.manualBtn:setTitle(getText(direct and "UI_MinidoracatMiniMap_TripRoads"
        or "UI_MinidoracatMiniMap_TripManual"))
    win.manualBtn.tooltip = getText(direct and "UI_MinidoracatMiniMap_TripRoadsHint"
        or "UI_MinidoracatMiniMap_TripManualHint")
    win.previewBtn:setTitle(getText(previewOn and "UI_MinidoracatMiniMap_TripPreviewOff"
        or "UI_MinidoracatMiniMap_TripPreviewOn"))
    win.previewBtn:setEnable(count > 0 and pstate ~= "disabled")
    win.skipBtn:setEnable(skippable ~= nil)
    win.undoBtn:setEnable(Core.navCanUndo(pn) == true)
    win.clearBtn:setEnable(count > 0 or err ~= nil)
    -- 接續模式：空行程／壞資料／舊版 API 一律不可操作，理由就在清單第一列
    win.autoBtn:setEnable(modeUsable)
    win.stopModeBtn:setEnable(modeUsable)
    styleTab(win.autoBtn, modeUsable and auto)
    styleTab(win.stopModeBtn, modeUsable and not auto)
end

-- 道路列右欄（設計稿 3 mock）：收到的路先寫作者，再寫停用／容量已滿，接著路面與路寬、長度，最後是分享旗。
-- 錄的路逐段量，路面取段數最多的、路寬寫範圍；草稿可能還沒有路寬路面，只寫長度
local function roadMeta(road, off)
    local parts, n = {}, 0
    local function put(text)
        n = n + 1
        parts[n] = text
    end
    if road.author then put(road.author) end
    if off then put(getText("UI_MinidoracatMiniMap_RoadNavOffMark")) end
    if road.overBudget then put(getText("UI_MinidoracatMiniMap_RoadOverBudget")) end
    local pts = road.pts or {}
    local widths, surfaces = road.segWidth, road.segSurface
    local wmin, wmax, len = nil, nil, 0
    local tally, best, bestN = {}, "unknown", 0
    for i = 1, math.floor(#pts / 2) - 1 do
        local w = widths and widths[i]
        if type(w) == "number" then
            wmin, wmax = math.min(wmin or w, w), math.max(wmax or w, w)
        end
        local s = surfaces and surfaces[i] or "unknown"
        tally[s] = (tally[s] or 0) + 1
        if tally[s] > bestN then best, bestN = s, tally[s] end
        local j = i * 2 - 1
        len = len + math.sqrt(dist2(pts[j], pts[j + 1], pts[j + 2], pts[j + 3]))
    end
    if wmin then
        put(getText("UI_MinidoracatMiniMap_RoadSurface_" .. best) .. " " .. (wmin == wmax
            and getText("UI_MinidoracatMiniMap_RoadWidth", tostring(wmin))
            or getText("UI_MinidoracatMiniMap_RoadWidthRange", tostring(wmin), tostring(wmax))))
    end
    put(fmtDist(len))
    local share = road.share
    if not off and share then
        if share.faction then put(getText("UI_MinidoracatMiniMap_RoadShareFactionMark")) end
        if share.safehouse then put(getText("UI_MinidoracatMiniMap_RoadShareSafehouseMark")) end
    end
    return table.concat(parts, getText("UI_MinidoracatMiniMap_RoadSep"), 1, n)
end

-- 群組標題與警告：照說明列換行，每一行都上色
local function addNoteRows(list, text, color)
    local from = #list.items + 1
    addInfoRow(list, text)
    for i = from, #list.items do list.items[i].item.color = color end
end

-- 道路列沿用搜尋列的畫法（圓點＋名稱＋右欄），沒有類型字。回這一列（保留選取用）
local function addRoadRow(list, item)
    item.tag, item.tagW = "", 0
    item.rightW = measureSmall(item.right)
    local row = list:addItem(item.label, item)
    prepareRow(list, row, item, 34, item.rightW)
    return row
end

-- 道路頁刷新：清單只在 Core.roadsRevision() 變了（含草稿變動）或版面／訊息作廢時重建；每幀只做
-- 純量比較——錄製狀態決定按鈕字、選取決定按鈕可用性、錄製中斷旗（讀了就清）出現時強制重建
local function roadsRefresh(win, force)
    local pn = win.playerNum or 0
    local recording = Core.roadRecordState ~= nil and Core.roadRecordState(pn) ~= nil
    if recording ~= win._rRec then
        win._rRec = recording
        win.roadRecordBtn:setTitle(getText(recording and "UI_MinidoracatMiniMap_RoadRecordStop"
            or "UI_MinidoracatMiniMap_RoadRecordStart"))
    end
    if Core.roadRecordLastLost and Core.roadRecordLastLost(pn) then
        win.roadLost = true -- 頂端警告留到離開這一頁（setPage／關窗清掉）
        force = true
    end
    if win.list.selected ~= win._roadSel then
        win._roadSel = win.list.selected
        win.roadShowBtn:setEnable(roadSelected(win) ~= nil)
    end
    local rev = Core.roadsRevision and Core.roadsRevision() or 0
    if not force and rev == win._rRev then return end
    win._rRev = rev
    local keep = roadSelected(win)
    local keepKey = keep and keep.key or nil
    local list = win.list
    list:clear()
    win._roadSel = nil -- 下個 prerender 依新的選取重算按鈕可用性
    local first, kept
    local function add(item)
        local row = addRoadRow(list, item)
        first = first or row.itemindex
        if item.key == keepKey then kept = row.itemindex end
    end
    if win.roadLost then
        addNoteRows(list, getText("UI_MinidoracatMiniMap_RoadRecordLost"), WARN_COLOR)
    end
    local draft = Core.roadsDraft and Core.roadsDraft(pn) or nil
    if draft then
        addNoteRows(list, getText("UI_MinidoracatMiniMap_RoadGroupDraft"), MUTED_COLOR)
        add({ kind = "draft", key = "draft", draft = draft, right = roadMeta(draft),
            label = getText(draft.source == "record" and "UI_MinidoracatMiniMap_RoadDraft_record"
                or "UI_MinidoracatMiniMap_RoadDraft_draw") })
    end
    local own, readOnly = nil, nil
    if Core.roadsList then own, readOnly = Core.roadsList(pn) end
    own = own or {}
    addNoteRows(list, getText("UI_MinidoracatMiniMap_RoadGroupOwn", tostring(#own)), MUTED_COLOR)
    if #own == 0 then addInfoRow(list, getText("UI_MinidoracatMiniMap_RoadEmpty")) end
    for i = 1, #own do
        local road = own[i]
        local off = road.enabled == false
        add({ kind = "road", own = true, key = "o" .. tostring(road.id), id = road.id,
            enabled = not off, label = road.name or "", right = roadMeta(road, off),
            dot = (off or road.overBudget) and ROAD_OFF_COLOR or nil })
    end
    if readOnly then addInfoRow(list, getText("UI_MinidoracatMiniMap_RoadReadOnly_" .. tostring(readOnly))) end
    local got = Core.roadsReceived and Core.roadsReceived(pn) or {}
    if #got > 0 then
        addNoteRows(list, getText("UI_MinidoracatMiniMap_RoadGroupShared", tostring(#got)), MUTED_COLOR)
        for i = 1, #got do
            local road = got[i]
            local off = road.off == true
            add({ kind = "road", own = false, key = "s" .. tostring(road.sid), sid = road.sid,
                off = off, label = road.name or "", right = roadMeta(road, off),
                dot = (off or road.overBudget) and ROAD_OFF_COLOR or nil })
        end
    end
    if win.msgFull then addInfoRow(list, win.msgFull) end
    -- 沒有可保留的選取時選第一條路：清單第一列是群組標題，停在那裡「動作…」會整片灰掉
    if kept or first then list.selected = kept or first end
end

local function pageRefresh(win, force)
    if win.page == "itinerary" then
        tripRefresh(win, force)
    elseif win.page == "roads" then
        roadsRefresh(win, force)
    else
        winRefresh(win, force)
    end
end

--------------------------------------------------------------------------------
-- 清單自繪（每幀熱路徑：文字/寬度全用刷新時預格式化欄位，零配置；視窗外列早退）
--------------------------------------------------------------------------------
local function drawRowBackground(self, y, item, hgt)
    local Skin = Core.Skin
    -- hover 判定補原版兩道保護（ISScrollingListBox.lua:316——mouseoverselected
    -- 滑到捲軸/失焦時殘留，原版靠 isMouseOver 消殘影）
    local hovered = self.mouseoverselected == item.index and self:isMouseOver()
        and not self:isMouseOverScrollBar()
    local selected = self.selected == item.index
    if Skin then
        if selected then
            Skin.fill(self, 2, y + 1, self.width - 4, hgt - 2, Skin.COLORS.ROW_SELECTED)
        elseif hovered then
            Skin.fill(self, 2, y + 1, self.width - 4, hgt - 2, Skin.COLORS.ROW_HOVER)
        end
        if selected then -- 左緣琥珀選中條
            self:drawRect(2, y + 3, 3, hgt - 6, 0.9, 1, 0.85, 0.4)
        end
    elseif selected then
        self:drawRect(0, y, self.width, hgt, 0.15, 1, 1, 1)
    end
end

-- 畫一段已換行的文字，回下一個可用的文字 y
local function drawLines(self, lines, x, ty, r, g, b)
    local lineH = self._minidoracatLineH
    for i = 1, #lines do
        self:drawText(lines[i], x, ty + (i - 1) * lineH, r, g, b, 1, UIFont.Small)
    end
    return ty + #lines * lineH
end

-- 畫名稱各行，回下一個可用的文字 y（meta 行用）。it.color＝上色的說明列（道路頁的群組標題與警告）
local function drawNameLines(self, it, ty)
    local c = it.color
    local r, g, b = c and c.r or 1, c and c.g or 1, c and c.b or 1
    local lines = it.lines
    if not lines then
        self:drawText(it.label, it.nameX or 12, ty, r, g, b, 1, UIFont.Small)
        return ty + self._minidoracatLineH
    end
    return drawLines(self, lines, it.nameX, ty, r, g, b)
end

-- 畫右欄（狀態徽章＋座標與距離）。放得下就右對齊貼在名稱那一列，狀態再貼在
-- 座標左側（prepareRow 已保證兩邊各留 10px 空隙）；名稱佔滿整列時右欄自成一
-- 列；連一列都放不下時狀態與座標各自分列。c＝狀態色，搜尋列沒有狀態徽章給
-- nil。回下一個可用的文字 y（說明列接在其後）
local function drawMeta(self, it, ty, nextY, c)
    local rightX = self.width - it.rightW - 14
    if not it.metaOwn then
        if c then
            self:drawText(it.badge, rightX - 10 - it.badgeW, ty, c.r, c.g, c.b, 1, UIFont.Small)
        end
        self:drawText(it.right, rightX, ty, 0.62, 0.62, 0.62, 1, UIFont.Small)
        return nextY
    end
    local y = nextY
    if it.badgeLines then y = drawLines(self, it.badgeLines, it.nameX, y, c.r, c.g, c.b) end
    if it.rightLines then
        return drawLines(self, it.rightLines, it.nameX, y, 0.62, 0.62, 0.62)
    end
    if c then self:drawText(it.badge, it.nameX, y, c.r, c.g, c.b, 1, UIFont.Small) end
    self:drawText(it.right, rightX, y, 0.62, 0.62, 0.62, 1, UIFont.Small)
    return y + self._minidoracatLineH
end

-- 搜尋結果列：hover/選中圓角填色＋kind 徽章色點＋名稱＋座標與距離
local function listDrawItem(self, y, item, alt)
    local hgt = item.height or self.itemheight
    -- 可見性早退（stencil 之外自己也省：捲出視窗的列不畫不量）
    local ys = self:getYScroll()
    if y + hgt < -ys or y > self.height - ys then return y + hgt end
    local it = item.item
    drawRowBackground(self, y, item, hgt)
    local ty = y + self._minidoracatTextY
    if it and it.kind and it.kind ~= "info" then
        local kc = it.dot or KIND_COLORS[it.kind] or KIND_COLORS.coord
        self:drawRect(12, y + math.floor(self.itemheight / 2) - 3, 6, 6, 1, kc.r, kc.g, kc.b)
        self:drawText(it.tag, 24, ty, kc.r, kc.g, kc.b, 1, UIFont.Small)
        local hintY = drawMeta(self, it, ty, drawNameLines(self, it, ty), nil)
        if it.sourceHint then
            self:drawText(it.sourceHint, it.nameX, hintY, 0.62, 0.62, 0.62, 1, UIFont.Small)
        end
    else
        drawNameLines(self, it or { label = item.text, nameX = 12 }, ty)
    end
    return y + hgt
end

-- 行程列：編號徽章（深底＋狀態色框＋白字）＋站名＋狀態＋座標與距離
local function tripDrawItem(self, y, item, alt)
    local hgt = item.height or self.itemheight
    local ys = self:getYScroll()
    if y + hgt < -ys or y > self.height - ys then return y + hgt end
    local it = item.item
    drawRowBackground(self, y, item, hgt)
    local ty = y + self._minidoracatTextY
    if it and it.kind == "trip" then
        local c = it.active and STOP_COLORS.active
            or STOP_COLORS[it.status] or STOP_COLORS.pending
        local badgeW = it.tagW + 10
        local rowH = self.itemheight
        -- 編號＝深底＋狀態色框＋白字（同地圖上的編號標記 _Nav.lua drawTripTargets）：
        -- 略過站的灰字疊在灰底上根本讀不出來（review blocking），顏色只進框線
        self:drawRect(10, y + 3, badgeW, rowH - 6, 0.62, 0, 0, 0)
        self:drawRectBorder(10, y + 3, badgeW, rowH - 6, 0.95, c.r, c.g, c.b)
        self:drawText(it.tag, 10 + math.floor((badgeW - it.tagW) / 2), ty,
            1, 1, 1, 1, UIFont.Small)
        drawMeta(self, it, ty, drawNameLines(self, it, ty), c)
    else
        drawNameLines(self, it or { label = item.text, nameX = 12 }, ty)
    end
    return y + hgt
end

--------------------------------------------------------------------------------
-- 版面
--------------------------------------------------------------------------------
-- 按實際字寬貪婪換列：放不進本列就換下一列，單顆超寬就獨佔整列（不截字）。
-- 次要動作（group=="more"）不排在底部，改由「動作…」選單提供；d.hide 的主要動作（只在特定狀態出現，
-- 例如找不到道路時的「畫自訂道路」）不留位，狀態一變由刷新端重排。回總高
local function layoutButtons(defs, x, y, availW, btnH, gap)
    local tm = getTextManager()
    local cx, cy, rows = x, y, 1
    for i = 1, #defs do
        local d = defs[i]
        if d.group ~= "more" and not d.hide then
            local bw = tm:MeasureStringX(UIFont.Small, d.btn.title or d.text) + 24
            if d.altKey then bw = math.max(bw, tm:MeasureStringX(UIFont.Small, d.text) + 24) end
            if bw > availW then bw = availW end
            if cx > x and cx + bw > x + availW then
                cx, cy, rows = x, cy + btnH + gap, rows + 1
            end
            d.btn:setX(cx)
            d.btn:setY(cy)
            d.btn:setWidth(bw)
            d.btn:setHeight(btnH)
            cx = cx + bw + gap
        end
    end
    return rows * (btnH + gap) - gap
end

local function makeButtons(win, defs)
    for i = 1, #defs do
        local d = defs[i]
        d.text = getText(d.key)
        if d.altKey then -- 動態標題：版面按較寬者留位，切換時不會擠掉字
            local alt = getText(d.altKey)
            if measureSmall(alt) > measureSmall(d.text) then d.text = alt end
        end
        local btn = ISButton:new(0, 0, 10, 10, d.text, win, function(target)
            d.action(target)
        end)
        btn:initialise()
        styleButton(btn)
        win:addChild(btn)
        d.btn = btn
        if d.field then win[d.field] = btn end
    end
end

-- 焦點環順序＝版面上下順序：分頁列→（行程頁）模式列→輸入框→清單→動作鈕。
-- topDefs＝畫在清單之上的那一排（模式選擇），鍵盤與手把都必須走得到
local function focusListFor(win, listEl, defs, entryEl, topDefs)
    local out = {}
    for i = 1, #win.tabs do
        local tab = win.tabs[i]
        out[#out + 1] = { el = tab.btn, action = function(w) setPage(w, tab.page) end }
    end
    for i = 1, (topDefs and #topDefs or 0) do
        local d = topDefs[i]
        out[#out + 1] = { el = d.btn, action = d.action }
    end
    if entryEl then
        out[#out + 1] = { el = entryEl, action = function(w)
            local joypadData = w.joyOwner ~= nil and JoypadState.players[w.joyOwner + 1] or nil
            if joypadData then
                -- 手把文字輸入走原版 OnScreenKeyboard（ISTextEntryBox.lua:293）
                w.entry:onJoypadDown(Joypad.AButton, joypadData)
            else
                w.entry:focus()
            end
        end }
    end
    out[#out + 1] = { el = listEl, isList = true, action = function(w)
        if w.page == "itinerary" then
            tripShowOnMap(w)
        elseif w.page == "roads" then
            roadShow(w)
        else
            winGoto(w)
        end
    end }
    for i = 1, #defs do
        local d = defs[i]
        out[#out + 1] = { el = d.btn, action = d.action }
    end
    return out
end

-- 依目前 viewport 與 UI 字級重算整份版面（開窗／owner-transfer／收合／折疊每次
-- 呼叫）。硬規則：**視窗絕不大於 viewport**。空間不足時縮的是清單，再不足就自動
-- 折疊次要動作；主要動作與分頁列固定在清單之外，永遠留在視窗內可達
relayoutWindow = function(win, pn)
    local tm = getTextManager()
    local fhS = tm:getFontHeight(UIFont.Small)
    local fhM = tm:getFontHeight(UIFont.Medium)
    local titleH = math.max(30, fhM + 10)
    local entryH = math.max(24, fhS + 8)
    local rowH = math.max(24, fhS + 8)
    local btnH = math.max(28, fhS + 10)
    local lineH = fhS + 2
    local pad, gap = 10, 6
    local msgH = MSG_LINES * lineH + 6
    local sw = getPlayerScreenWidth(pn) or getCore():getScreenWidth()
    local sh = getPlayerScreenHeight(pn) or getCore():getScreenHeight()
    local maxH = sh - 20
    local w = math.min(math.max(420, 24 * fhS), sw - 20)
    local availW = w - pad * 2
    win:setWidth(w)
    win._titleH = titleH
    local chromeW = titleH - 10
    win.closeBtn:setX(w - pad - chromeW)
    win.closeBtn:setY(5)
    win.closeBtn:setWidth(chromeW)
    win.closeBtn:setHeight(chromeW)
    win.collapseBtn:setX(w - pad - chromeW * 2 - 4)
    win.collapseBtn:setY(5)
    win.collapseBtn:setWidth(chromeW)
    win.collapseBtn:setHeight(chromeW)
    if win.collapsed then
        -- 收合：只留標題列。其餘元件由 applyPage 設為不可見，鍵盤完全不攔
        win:setHeight(titleH)
        win.geom = { search = { headY = 0, msgY = 0 }, places = { headY = 0, msgY = 0 },
            itinerary = { headY = 0, msgY = 0 }, roads = { headY = 0, msgY = 0 } }
        applyPage(win)
        return
    end
    local tabsY = titleH + pad
    local tabsH = layoutButtons(win.tabs, pad, tabsY, availW, btnH, gap)
    local bodyY = tabsY + tabsH + 8
    -- 模式列固定在行程頁頂部（清單之外）：接續模式是整趟行程的前提，
    -- 不能跟著清單捲走，也不能被次要動作折疊
    local modeH = layoutButtons(win.modeBtns, pad, 0, availW, btnH, gap)
    local modeTop = bodyY + modeH + 6
    local listY = {
        search = bodyY + entryH + 8,
        itinerary = modeTop + HEAD_LINES * lineH * 2 + 8,
    }
    local baseY = math.max(listY.search, listY.itinerary)
    -- 視窗高照按鈕最多列的那一頁（換頁不變高）；每頁的按鈕各自貼齊底邊，列數較少的頁把多出的高度給清單，
    -- 不在按鈕下面留白（EN 道路頁四顆鈕換成兩列時，其他頁原本多一條空白）
    local blocks = {
        search = layoutButtons(win.searchBtns, pad, 0, availW, btnH, gap),
        itinerary = layoutButtons(win.tripBtns, pad, 0, availW, btnH, gap),
        roads = layoutButtons(win.roadBtns, pad, 0, availW, btnH, gap),
    }
    local block = math.max(blocks.search, blocks.itinerary, blocks.roads)
    local function heightFor(rows)
        return baseY + block + rowH * rows + msgH + pad + 8
    end
    -- 極窄／大字時連主要動作都擠不下：狀態與預覽改隨清單捲動，資訊不刪不截。
    win.scrollInfo = heightFor(1) > maxH
    if win.scrollInfo then
        listY.itinerary = modeTop
        baseY = math.max(listY.search, listY.itinerary)
    end
    local h = math.min(heightFor(8), maxH)
    win:setHeight(h)
    local btnTop = h - pad - blocks.itinerary
    -- 窄版大字時分頁列可能換到兩三列（四個分頁）：行程清單連一列都放不下時，訊息列只留一行，
    -- 放不下的全文照舊接進可捲清單（winMessage 的 msgFull），清單至少留一列可選
    win.msgMaxLines = MSG_LINES
    if btnTop - msgH - 4 - listY.itinerary < rowH then
        win.msgMaxLines = 1
        msgH = lineH + 6
    end
    local msgY = {
        search = h - pad - blocks.search - msgH,
        itinerary = btnTop - msgH,
        roads = h - pad - blocks.roads - msgH,
    }
    layoutButtons(win.searchBtns, pad, h - pad - blocks.search, availW, btnH, gap)
    layoutButtons(win.tripBtns, pad, btnTop, availW, btnH, gap)
    layoutButtons(win.roadBtns, pad, h - pad - blocks.roads, availW, btnH, gap)
    layoutButtons(win.modeBtns, pad, bodyY, availW, btnH, gap)
    local function fitList(listEl, y, bottom)
        listEl:setX(pad)
        listEl:setY(y)
        listEl:setWidth(availW)
        listEl:setHeight(math.max(0, bottom - 4 - y))
        listEl.itemheight = rowH
        listEl._minidoracatTextY = math.floor((rowH - fhS) / 2)
        listEl._minidoracatLineH = lineH
    end
    fitList(win.list, listY.search, msgY.search)
    fitList(win.tripList, listY.itinerary, msgY.itinerary)
    -- 收藏頁、道路頁與搜尋頁共用 win.list：這兩頁沒有搜尋框，清單往上接到分頁列下面（applyPage 依頁套用）
    win.listAt = {
        search = { y = listY.search, h = math.max(0, msgY.search - 4 - listY.search) },
        places = { y = bodyY, h = math.max(0, msgY.search - 4 - bodyY) },
        roads = { y = bodyY, h = math.max(0, msgY.roads - 4 - bodyY) },
    }
    win.entry:setX(pad)
    win.entry:setY(bodyY)
    win.entry:setWidth(availW)
    win.entry:setHeight(entryH)
    win.geom = {
        search = { msgY = msgY.search, headY = bodyY },
        places = { msgY = msgY.search, headY = bodyY },
        itinerary = { msgY = msgY.itinerary, headY = modeTop },
        roads = { msgY = msgY.roads, headY = bodyY },
    }
    win.searchFocus = focusListFor(win, win.list, win.searchBtns, win.entry, nil)
    win.placesFocus = focusListFor(win, win.list, win.searchBtns, nil, nil)
    win.tripFocus = focusListFor(win, win.tripList, win.tripBtns, nil, win.modeBtns)
    win.roadsFocus = focusListFor(win, win.list, win.roadBtns, nil, nil)
    applyPage(win)
end

--------------------------------------------------------------------------------
-- 鍵盤與手把
--------------------------------------------------------------------------------
-- 輸入框聚焦期：方向鍵/Enter/其他鍵由原版 UITextBox2 鉤子轉進來
-- （onOtherKey 慣例同 ISMPEditServer.lua:245），不與遊戲移動鍵搶事件
local function entryOtherKey(win, key)
    if key == Keyboard.KEY_ESCAPE then
        win.entry:unfocus()
    elseif key == Keyboard.KEY_TAB then
        win.entry:unfocus()
        focusMove(win, 1)
    end
end

-- 視窗鍵盤導航。TAB 之前不建立焦點環＝方向鍵/Enter 完全不攔（玩家只是開著視窗
-- 在玩）；建立焦點環後才接手，ESC 逐級退出
local function winKeyNav(win, key)
    if key == Keyboard.KEY_TAB then
        focusMove(win, isShiftKeyDown() and -1 or 1)
        return
    end
    if not win.focus then return end
    if key == Keyboard.KEY_DOWN then
        focusStep(win, 1)
    elseif key == Keyboard.KEY_UP then
        focusStep(win, -1)
    elseif key == Keyboard.KEY_LEFT then
        stepPage(win, -1)
    elseif key == Keyboard.KEY_RIGHT then
        stepPage(win, 1)
    elseif key == Keyboard.KEY_RETURN then
        focusActivate(win)
    end
end

-- 鍵盤政策的單一判定點：收合中／確認面板開著時本視窗完全不處理鍵盤
local function winKeysInert(win)
    return not win:isVisible() or win.collapsed
        or (win.confirm and win.confirm:isVisible())
end

local function installInput(win)
    win:setWantKeyEvents(true)
    -- 只宣告「本視窗真的處理」的鍵；WASD 等遊戲鍵一律不吞，關窗／收合後亦不吞
    win.isKeyConsumed = function(self, key)
        if self.consumedKey == key then self.consumedKey = nil; return true end
        if winKeysInert(self) then return false end
        if activeNativeMenu(self) then
            return key == Keyboard.KEY_ESCAPE or key == Keyboard.KEY_RETURN
                or key == Keyboard.KEY_UP or key == Keyboard.KEY_DOWN
        end
        if key == Keyboard.KEY_ESCAPE then return true end
        if self.entry:isFocused() then return false end
        if key == Keyboard.KEY_TAB then return true end
        if not self.focus then return false end
        return key == Keyboard.KEY_UP or key == Keyboard.KEY_DOWN
            or key == Keyboard.KEY_LEFT or key == Keyboard.KEY_RIGHT
            or key == Keyboard.KEY_RETURN
    end
    win.onKeyRelease = function(self, key)
        if winKeysInert(self) then return end
        if self:isKeyConsumed(key) then self.consumedKey = key end
        local menu = activeNativeMenu(self)
        if menu then
            if key == Keyboard.KEY_UP then menu:onJoypadDirUp()
            elseif key == Keyboard.KEY_DOWN then menu:onJoypadDirDown()
            elseif key == Keyboard.KEY_RETURN then menu:onJoypadDown(Joypad.AButton)
            elseif key == Keyboard.KEY_ESCAPE then menu:closeAll() end
            return
        end
        if key == Keyboard.KEY_ESCAPE then
            if self.entry:isFocused() then
                self.entry:unfocus()
            elseif self.focus then
                self.focus = nil
            else
                closeWindow(self)
            end
            return
        end
        if self.entry:isFocused() then return end
        winKeyNav(self, key)
    end
    win.entry.onOtherKey = function(_, key) entryOtherKey(win, key) end
    win.entry.onCommandEntered = function() winGoto(win) end
    win.entry.onPressDown = function() listStep(win.list, 1) end
    win.entry.onPressUp = function() listStep(win.list, -1) end
    -- 手把：原生 joypad focus 模式（A 觸發／B 關窗／X 依序換頁／左右換到隔壁頁／方向鍵移動）
    win.onGainJoypadFocus = function(self, joypadData)
        ISPanel.onGainJoypadFocus(self, joypadData)
        if not self.collapsed and not self.focus then focusMove(self, 1) end
    end
    win.onJoypadDown = function(self, button)
        if button == Joypad.AButton then
            if self.collapsed then toggleCollapsed(self) else focusActivate(self) end
        elseif button == Joypad.BButton then
            closeWindow(self)
        elseif button == Joypad.XButton then
            stepPage(self, 1, true)
        elseif button == Joypad.YButton then
            toggleCollapsed(self)
        end
    end
    win.onJoypadDirUp = function(self) focusStep(self, -1) end
    win.onJoypadDirDown = function(self) focusStep(self, 1) end
    win.onJoypadDirLeft = function(self) stepPage(self, -1) end
    win.onJoypadDirRight = function(self) stepPage(self, 1) end
end

claimJoypad = function(win, pn)
    if not (JoypadState and JoypadState.players and JoypadState.players[pn + 1]) then
        win.joyOwner = nil
        return
    end
    local data = JoypadState.players[pn + 1]
    if data.focus ~= win then
        win.joyPrevious, win.joyPrevious2, win.joyPrevious3 = data.focus, data.prevfocus, data.prevprevfocus
    end
    win.joyOwner = pn
    setJoypadFocus(pn, win)
end

--------------------------------------------------------------------------------
-- 建構與開關
--------------------------------------------------------------------------------
local function createSearchWindow(pn)
    -- 尺寸隨 UI 字級（codex review：固定 px 在 1440p Auto 字級（2x 字型，
    -- Small/Medium 行高 26/33）必裁切；getFontHeight 同主檔 BUTTON_HGT 先例）；
    -- 實際幾何全由 relayoutWindow 依當下 viewport 指派
    local win = ISPanel:new(0, 0, 420, 430)
    win:initialise()
    win:instantiate()
    win.background = false   -- 背板由皮膚 prerender 自畫（圓角）
    win.moveWithMouse = true -- ISPanel 內建拖曳（ISPanel.lua:26-113）
    win.playerNum = pn
    win.page = "search"
    win.collapsed = false
    -- 清單右鍵：先選中滑鼠下的列（同原版 onMouseDown 的 rowAt），再在滑鼠處開動作選單
    local function rowMenu(list, x, y)
        local row = list:rowAt(x, y)
        if row < 1 then return true end
        list.selected = row
        pageRefresh(win, false)
        openActions(win, { x = list.x + x, y = list.y + y + list:getYScroll(), height = 0 }, true)
        return true
    end
    -- 標題列：收合／關閉
    win.collapseBtn = ISButton:new(0, 0, 10, 10, "-", win, toggleCollapsed)
    win.collapseBtn:initialise()
    styleButton(win.collapseBtn)
    win:addChild(win.collapseBtn)
    win.closeBtn = ISButton:new(0, 0, 10, 10, "X", win, closeWindow)
    win.closeBtn:initialise()
    styleButton(win.closeBtn)
    win.closeBtn.tooltip = getText("UI_MinidoracatMiniMap_StudioClose")
    win:addChild(win.closeBtn)
    -- 分頁鈕（鍵盤／手把可達的收藏頁、行程頁與道路頁入口；滑鼠、TAB、左右鍵、X 鈕四路等價）。
    -- 由左到右的順序同 PAGES：搜尋、收藏、行程、道路
    win.tabs = {
        { key = "UI_MinidoracatMiniMap_SearchTabSearch", page = "search" },
        { key = "UI_MinidoracatMiniMap_PlaceMenu", page = "places" },
        { key = "UI_MinidoracatMiniMap_TripManage", page = "itinerary" },
        { key = "UI_MinidoracatMiniMap_RoadTab", page = "roads" },
    }
    for i = 1, #win.tabs do
        local tab = win.tabs[i]
        tab.action = function(target) setPage(target, tab.page) end
    end
    makeButtons(win, win.tabs)
    -- 輸入框（原版 ISTextEntryBox；setClearButton/getInternalText 原版用例
    -- ObjectViewer.lua:254/571；placeholder 走官方 API（ISTextEntryBox.lua:121-127，
    -- javaObject 未建時暫存、instantiate 後套用）——比自畫穩：不與元件自繪底板疊層）
    win.entry = ISTextEntryBox:new("", 0, 0, 10, 10)
    win.entry:initialise()
    win.entry:instantiate()
    if win.entry.setClearButton then win.entry:setClearButton(true) end
    if win.entry.setPlaceholderText then
        win.entry:setPlaceholderText(getText("UI_MinidoracatMiniMap_SearchHint"))
    end
    win.entry.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
    win.entry.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    win:addChild(win.entry)
    -- 兩份清單（一次只顯示一份；分開比在同一份裡分支乾淨，繪製也各自零配置）
    win.list = ISScrollingListBox:new(0, 0, 10, 10)
    win.list:initialise()
    win.list:instantiate()
    win.list.font = UIFont.Small
    win.list.drawBorder = false
    win.list.backgroundColor = { r = 0, g = 0, b = 0, a = 0.25 }
    win.list.doDrawItem = listDrawItem
    win:addChild(win.list)
    win.list.onRightMouseUp = rowMenu
    win.list:setOnMouseDoubleClick(win, function(target)
        if target.page == "roads" then roadShow(target) else winGoto(target) end
    end)
    win.tripList = ISScrollingListBox:new(0, 0, 10, 10)
    win.tripList:initialise()
    win.tripList:instantiate()
    win.tripList.font = UIFont.Small
    win.tripList.drawBorder = false
    win.tripList.backgroundColor = { r = 0, g = 0, b = 0, a = 0.25 }
    win.tripList.doDrawItem = tripDrawItem
    win:addChild(win.tripList)
    win.tripList.onRightMouseUp = rowMenu
    win.tripList:setOnMouseDoubleClick(win, function(target)
        tripShowOnMap(target)
    end)
    -- 捲軸每幀對齊清單高度（照原版 ISComboBoxPopup:prerender）：引擎只把一幀內最後一次 setHeight
    -- 的高度差套到錨定的捲軸（UIElement.setHeight 每次覆寫 lastheight），relayoutWindow 的 fitList
    -- 與 applyPage 同一幀各設一次時，捲軸會停在建立時的 10px，內容沒滿也畫出半截捲軸
    local function listPrerender(self)
        self.vscroll:setHeight(self.height)
        ISScrollingListBox.prerender(self)
    end
    win.list.prerender = listPrerender
    win.tripList.prerender = listPrerender
    -- 搜尋頁：主要＝加到行程最後／在地圖顯示；次要＝插在指定站之前／先去這裡／
    -- 取代整趟（取代會立刻出發，放次要；會丟待前往站時先確認）／收藏動作（placeOptions 依選中項直接列出）
    win.searchBtns = {
        { key = "UI_MinidoracatMiniMap_TripAdd", action = winAddStop, field = "addBtn" },
        { key = "UI_MinidoracatMiniMap_SearchGoto", action = winGoto, field = "gotoBtn" },
        { key = "UI_MinidoracatMiniMap_TripMoreShow", action = openActions, field = "searchMoreBtn" },
        { key = "UI_MinidoracatMiniMap_TripInsert", action = winInsertStop,
            field = "insertBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripPriority", action = winPriorityStop,
            field = "priorityBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_SearchSetTarget", action = winSetTarget,
            field = "replaceBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_PlaceMenu", fill = placeOptions,
            field = "placeBtn", group = "more" },
    }
    makeButtons(win, win.searchBtns)
    -- 行程頁頂部：接續模式兩顆明確選擇鈕（不是 toggle）。切換只改這份行程的設定，
    -- 不發車、不煞車、不換目標；滑鼠、TAB／方向鍵、手把三路等價
    win.modeBtns = {
        { key = "UI_MinidoracatMiniMap_TripModeAuto", field = "autoBtn",
            action = function(target) setContinuation(target, true) end },
        { key = "UI_MinidoracatMiniMap_TripModeStop", field = "stopModeBtn",
            action = function(target) setContinuation(target, false) end },
    }
    makeButtons(win, win.modeBtns)
    -- 行程頁：主要＝開始/繼續、停止、回家（永遠可按）；次要＝手動前往、檢視、分享與清單編輯。
    -- 「畫自訂道路」只在目前這站找不到道路時出現（tripRefresh 切 hide 並重排）
    win.roadDrawDef = { key = "UI_MinidoracatMiniMap_RoadDrawHere", action = tripDrawRoad,
        field = "roadDrawBtn", hide = true }
    win.tripBtns = {
        { key = "UI_MinidoracatMiniMap_TripStart", altKey = "UI_MinidoracatMiniMap_TripContinue",
            action = tripStart, field = "startBtn" },
        win.roadDrawDef,
        { key = "UI_MinidoracatMiniMap_TripPause", action = tripPause, field = "pauseBtn" },
        { key = "UI_MinidoracatMiniMap_GoHome", action = tripGoHome, field = "homeBtn" },
        { key = "UI_MinidoracatMiniMap_TripMoreShow", action = openActions, field = "tripMoreBtn" },
        { key = "UI_MinidoracatMiniMap_TripManual", altKey = "UI_MinidoracatMiniMap_TripRoads",
            action = tripManual, field = "manualBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripShowOnMap", action = tripShowOnMap,
            field = "mapBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripPreviewOn", altKey = "UI_MinidoracatMiniMap_TripPreviewOff",
            action = tripPreview, field = "previewBtn", group = "more" },
        -- 分享目標給陣營：鍵盤與手把開不了地圖右鍵，這裡是它們的入口。列不列和地圖右鍵同一個
        -- 判定（Core.navShareOk）；單機、沒有陣營或沒在導航時整項不出現
        { key = "UI_MinidoracatMiniMap_ShareTarget", field = "shareBtn", group = "more",
            action = function(w) Core.navShareTarget(w.playerNum or 0) end,
            shown = function(w)
                local pn = w.playerNum or 0
                return Core.navShareOk(pn, getSpecificPlayer(pn))
            end },
        { key = "UI_MinidoracatMiniMap_TripMoveUp", action = tripMoveUp,
            field = "upBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripMoveDown", action = tripMoveDown,
            field = "downBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripSkip", action = tripSkip,
            field = "skipBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripMarkPause", altKey = "UI_MinidoracatMiniMap_TripUnmarkPause",
            action = tripTogglePause, field = "pauseStopBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripRemove", action = tripRemove,
            field = "removeBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripUndo", action = tripUndo,
            field = "undoBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripClear", action = tripClear,
            field = "clearBtn", group = "more" },
    }
    makeButtons(win, win.tripBtns)
    -- 道路頁（設計稿 3）：主要＝畫新道路、錄製道路（錄製中換「停止錄製」）、在世界地圖顯示；
    -- 次要＝依選中列的道路動作（roadOptions），清單右鍵開同一份
    win.roadBtns = {
        { key = "UI_MinidoracatMiniMap_RoadDrawNew", action = roadDrawNew, field = "roadNewBtn" },
        { key = "UI_MinidoracatMiniMap_RoadRecordStart", altKey = "UI_MinidoracatMiniMap_RoadRecordStop",
            action = roadRecordToggle, field = "roadRecordBtn" },
        { key = "UI_MinidoracatMiniMap_RoadShowOnMap", action = roadShow, field = "roadShowBtn" },
        { key = "UI_MinidoracatMiniMap_TripMoreShow", action = openActions, field = "roadMoreBtn" },
        { key = "UI_MinidoracatMiniMap_TripMoreShow", fill = roadOptions, field = "roadActBtn", group = "more" },
    }
    makeButtons(win, win.roadBtns)
    win.roadRecordBtn.tooltip = getText("UI_MinidoracatMiniMap_RoadRecordHint")
    installInput(win)
    -- 皮膚 prerender：圓角底板＋邊框＋上圓角標題列＋標題字＋狀態列＋焦點環
    win.prerender = function(self)
        local Skin = Core.Skin
        if Skin then
            Skin.fill(self, 0, 0, self.width, self.height, Skin.COLORS.BG_PANEL)
            Skin.fill(self, 0, 0, self.width, self._titleH, Skin.COLORS.TITLEBAR_FILL, true)
            Skin.border(self, 0, 0, self.width, self.height, Skin.COLORS.BORDER)
        else
            self:drawRect(0, 0, self.width, self.height, 0.8, 0, 0, 0)
            self:drawRectBorder(0, 0, self.width, self.height, 1, 0.4, 0.4, 0.4)
        end
        self:drawText(self.titleText, self.titleX, 6,
            1, 1, 1, 1, UIFont.Medium)
        if self.collapsed then return end -- 收合＝只有標題列，不刷新也不繪製內容
        pageRefresh(self, false)
        local g = self.g
        local lineH = self.list._minidoracatLineH
        if self.page == "itinerary" and self.headLines then
            -- 預覽列緊接在狀態列實際用掉的行數之後（兩者共用固定預留行數，
            -- 所以狀態列長一行時預覽往下讓一行，永不互疊也不壓到清單）
            local c = self.headColor
            local y = g.headY
            for i = 1, #self.headLines do
                self:drawText(self.headLines[i], 10, y, c.r, c.g, c.b, 1, UIFont.Small)
                y = y + lineH
            end
            for i = 1, #self.subLines do
                self:drawText(self.subLines[i], 10, y + (i - 1) * lineH,
                    0.62, 0.62, 0.62, 1, UIFont.Small)
            end
        end
        if self.msgUntil then
            if getTimestampMs() >= self.msgUntil then
                self.msgUntil = nil
                if self.msgFull then
                    -- 訊息退場：清單裡的全文列跟著收回去（兩頁的 cache 一併作廢）
                    self.msgFull = nil
                    self._tRev, self._lastText, self._rRev = nil, nil, nil
                end
            else
                local c = self.msgGood and GOOD_COLOR or WARN_COLOR
                for i = 1, #self.msgLines do
                    self:drawText(self.msgLines[i], 10, g.msgY + (i - 1) * lineH,
                        c.r, c.g, c.b, 1, UIFont.Small)
                end
            end
        end
        local entries = focusEntries(self)
        local focused = self.focus and entries and entries[self.focus] or nil
        if focused and focused.el:isVisible() then
            local el = focused.el
            self:drawRectBorder(el.x - 3, el.y - 3, el.width + 6, el.height + 6,
                0.95, 1, 0.85, 0.4)
        end
    end
    return win
end

-- 置中到該玩家的 viewport（分割畫面各半邊；單人＝全螢幕。API 出處：
-- getPlayerScreenLeft/Top/Width/Height 原版用例 ISMiniMap.lua:701-702、
-- 本 repo _Settings.lua:1266-1267 同慣例）
local function centerToPlayer(win, pn)
    local sx = getPlayerScreenLeft(pn) or 0
    local sy = getPlayerScreenTop(pn) or 0
    local sw = getPlayerScreenWidth(pn) or getCore():getScreenWidth()
    local sh = getPlayerScreenHeight(pn) or getCore():getScreenHeight()
    win:setX(sx + math.max(0, math.floor((sw - win.width) / 2)))
    win:setY(sy + math.max(0, math.floor((sh - win.height) / 2)))
end

-- 視窗開著卻被同一位玩家的世界地圖（全螢幕）整片蓋住＝玩家看不見它：開關鈕此時該叫到前面而不是關掉
-- （從小地圖開窗後再開世界地圖，世界地圖經 addToUIManager 排到最上層，UIManager.java:112-117）。
-- UIManager.getUI() 由下而上，從尾端往前先遇到誰誰就在上面；分割畫面只看同一位玩家的世界地圖
-- （ShowWorldMap 設 playerNum，別人的只蓋別人的 viewport）。_Settings 的開關共用這個判斷
Core.isBehindWorldMap = function(win, pn)
    local wm = ISWorldMap_instance
    if not (win and win.javaObject and wm and wm.javaObject and wm:isVisible()
            and (wm.playerNum or 0) == (pn or 0)) then
        return false
    end
    local uis = UIManager.getUI()
    for i = uis:size() - 1, 0, -1 do
        local el = uis:get(i)
        if el == wm.javaObject then return true end
        if el == win.javaObject then return false end
    end
    return false
end

-- 開關搜尋／收藏／行程視窗（按鈕/右鍵選單/快捷鍵入口共用）。引擎冷啟動由 winRefresh 的
-- Core.navKickAvailable 負責（開窗後首個 prerender 即泵）。
-- page＝"search"／"places"／"itinerary"／"roads" 時語意是「開啟或切到該頁」，**絕不關窗**——
-- 右鍵「搜尋、收藏與行程...」「管理收藏...」「行程規劃...」按兩次不該把視窗關掉；不帶 page
-- （按鈕列放大鏡、快捷鍵）保留原本的 toggle。
-- 收合狀態下再按等於展開，不用先展開再按一次；被世界地圖蓋住時再按＝叫到前面（看不見的窗不關）。
-- 分割畫面：同人再按＝關；他人按＝owner-transfer 重刷（同 _Settings 慣例），
-- 不誤關別人的視窗
Core.toggleSearchWindow = function(pn, page)
    pn = pn or 0
    if not (page and PAGE_TITLES[page]) then page = nil end -- nil 鍵查表在 Kahlua 不保證安全，先擋
    if searchWin and searchWin:isVisible() then
        if (searchWin.playerNum or 0) == pn then
            if searchWin.collapsed then
                searchWin.collapsed = false
                if page then searchWin.page = page end
                relayoutWindow(searchWin, pn)
                searchWin:bringToTop()
                return
            end
            if page then
                setPage(searchWin, page)
                searchWin:bringToTop()
                return
            end
            if Core.isBehindWorldMap(searchWin, pn) then
                searchWin:bringToTop()
                if searchWin.page == "search" and searchWin.entry and searchWin.entry.focus then
                    searchWin.entry:focus() -- 同開窗路徑：叫回來就能直接打字
                end
                return
            end
            closeWindow(searchWin)
            return
        end
        -- 轉移擁有者（grok review：只換 pn 不重定位會停在原主半邊，新主
        -- 看似沒反應）：距離/結果按新主重算＋依新主 viewport 重排版面＋置頂。
        -- 行程一律以新的 pn 現查，不把前一位玩家的行程搬過來
        local menu = activeNativeMenu(searchWin)
        if menu then menu:closeAll() end
        if searchWin.confirm then confirmClose(searchWin.confirm) end
        releaseJoypad(searchWin)
        searchWin.playerNum = pn
        searchWin.page = page or searchWin.page
        searchWin.msgUntil = nil -- 前一位玩家的操作結果不留給新擁有者看
        searchWin.msgFull = nil
        relayoutWindow(searchWin, pn)
        centerToPlayer(searchWin, pn)
        searchWin:bringToTop()
        claimJoypad(searchWin, pn)
        if searchWin.page == "search" and searchWin.entry and searchWin.entry.focus then
            searchWin.entry:focus() -- 轉移即聚焦（同開窗路徑；點鈕時引擎已 unfocus）
        end
        return
    end
    if not searchWin then
        searchWin = createSearchWindow(pn)
    end
    searchWin.playerNum = pn
    searchWin.page = page or "search"
    searchWin.collapsed = false
    searchWin.msgUntil = nil
    searchWin.msgFull = nil
    relayoutWindow(searchWin, pn) -- 重開必重算：字級/解析度/半邊都可能已變
    centerToPlayer(searchWin, pn) -- 每次開窗回到該玩家 viewport 中央
    searchWin:addToUIManager()
    searchWin:setVisible(true)
    claimJoypad(searchWin, pn)
    -- 只有搜尋頁自動聚焦輸入框：行程頁沒有要打字，聚焦只會白攔遊戲鍵盤
    if searchWin.page == "search" and searchWin.entry and searchWin.entry.focus then
        searchWin.entry:focus()
    end
end

-- 鍵盤開窗入口（選項 → 按鍵綁定 → [MinidoracatMiniMap] 可重綁；群組標題由
-- _Resize.lua 於同一 OnGameBoot 先插入，載入序 'R' < 'S' 保證順序）。
-- 預設 ;（SEMICOLON）：與本 MOD 既有兩鍵同一排鄰位（小地圖 /、穿透 '、本窗 ;）。
-- 已驗證範圍——原版 shared/keyBinding.lua 全綁定零命中 KEY_SEMICOLON，
-- vanilla client/shared lua 全樹零使用，本 MOD 自身兩鍵不衝突；
-- 未能在此驗證的是第三方 Workshop MOD 與玩家 keysB42.ini（本機無此檔），
-- 衝突時玩家直接重綁即可。文字輸入期引擎以 isDoingTextEntry 抑制派送，
-- 在搜尋框打分號不會誤觸。只處理 player 0（同 _Resize togglePlayerMiniMap 慣例，
-- 分割畫面由滑鼠入口的 owner-transfer 處理）
Events.OnGameBoot.Add(function()
    table.insert(keyBinding, { value = "MinidoracatMiniMap_Search", key = Keyboard.KEY_SEMICOLON })
end)

Events.OnKeyPressed.Add(function(key)
    if key == 0 or key ~= getCore():getKey("MinidoracatMiniMap_Search") then return end
    if not getSpecificPlayer(0) then return end -- 主選單等無玩家情境
    Core.toggleSearchWindow(0)
end)

-- 搜尋 ping 繪製（主檔 drawNavTargets 內動態呼叫——ping 落點與繪製同住本檔：
-- 主檔主 chunk locvar 已頂 Kahlua 200 上限（LexState actvar[200] 固定陣列、
-- 頂層 local 永不出 scope），不得再增頂層 local，遊戲內實爆記錄 2026-08-20）。
-- 雙相位擴散菱形＋中心準星，12 秒自動失效；菱形（4 線）代圓：引擎無圓弧 API；
-- 金色同自己目標旗。小地圖與世界地圖（Core.drawNavTargets 共用）雙表面同畫
Core.drawSearchPing = function(inner, mapAPI)
    local ping = Core.searchPing
    if not ping then return end
    -- 載荷防呆（review：info 列誤選曾可寫入 nil 座標——來源已擋，此為第二道；
    -- 壞載荷直接清除免每幀重驗）
    if type(ping.x) ~= "number" or type(ping.y) ~= "number"
        or type(ping.untilMs) ~= "number" then
        Core.searchPing = nil
        return
    end
    -- 分割畫面：僅擁有者（發起搜尋的 pn）的小地圖/世界地圖畫（codex review：
    -- 全域單載荷不過濾會畫到別人表面）
    if (ping.pn or 0) ~= (inner.playerNum or 0) then return end
    local now = getTimestampMs()
    if now >= ping.untilMs then
        Core.searchPing = nil
        return
    end
    local ux = mapAPI:worldToUIX(ping.x, ping.y)
    local uy = mapAPI:worldToUIY(ping.x, ping.y)
    -- 幾何跟「標記大小」（px／16，預設 1＝原尺寸：菱形半徑 6～28、準星臂長 9）
    local k = Core.markerIconSize() / 16
    -- 視野外整組跳過（菱形半徑上限 28，留 40px 緩衝，同比例放大）
    local pad = 40 * k
    if ux < -pad or uy < -pad or ux > inner.width + pad or uy > inner.height + pad then return end
    local lw = 2 * k
    for ph = 0, 1 do
        local phase = ((now / 1100) + ph * 0.5) % 1
        local rad = (6 + phase * 22) * k
        local a = 0.85 * (1 - phase)
        inner:drawLine(nil, ux - rad, uy, ux, uy - rad, lw, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux, uy - rad, ux + rad, uy, lw, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux + rad, uy, ux, uy + rad, lw, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux, uy + rad, ux - rad, uy, lw, a, 1, 0.85, 0.2)
    end
    inner:drawRect(ux - 2 * k, uy - 2 * k, 4 * k, 4 * k, 1, 1, 0.85, 0.2)
    local a1, a2 = 4 * k, 9 * k
    inner:drawLine(nil, ux - a2, uy, ux - a1, uy, lw, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux + a1, uy, ux + a2, uy, lw, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux, uy - a2, ux, uy - a1, lw, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux, uy + a1, ux, uy + a2, lw, 0.9, 1, 0.85, 0.2)
end

Events.OnGameStart.Add(function()
    -- PZ 同程序回主選單再進另一存檔 client Lua 不重載（同 _NavRoute 引擎重置
    -- 慣例）：舊 searchWin 掛在已清空的 UIManager 上、isVisible 殘 true，會讓
    -- 新世界首次 toggle 走關閉分支（按鈕看似壞掉）；直接棄置由 GC 收、再開重建。
    -- searchPing 一併清（12 秒牆鐘雖會自然過期，跨檔殘留座標無意義）
    -- 棄置前先解焦（codex/claude review：entry 若仍聚焦，Core.currentTextEntryBox
    -- 指向死輸入框、跨存檔攔鍵盤——UITextBox2.java:652 只有 unfocus() 清它）；
    -- 不走 closeWindow：對已清空的 UIManager 呼 removeFromUIManager 風險較高
    if searchWin and searchWin.entry and searchWin.entry.unfocus then
        pcall(function() searchWin.entry:unfocus() end)
    end
    searchWin = nil
    streetMapSources = nil
    Core.searchPing = nil
end)
