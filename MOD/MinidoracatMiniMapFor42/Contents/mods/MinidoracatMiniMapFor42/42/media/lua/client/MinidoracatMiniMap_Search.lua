-- MinidoracatMiniMap_Search.lua
-- 本檔範圍：地圖搜尋／行程視窗（0.17.0 搜尋；v6 多停靠點行程頁）——單一視窗兩頁，
-- 共用放大鏡入口、標題列與 owner-transfer。
--
-- 【搜尋頁】輸入自動判別「座標 or 關鍵字」：
--   - 座標：整串只含數字與分隔符（, - 空白 . 與全形逗號）且抓得到 ≥2 個數字
--     ＝座標（支援 "12895,3499"、"12895 - 3499 - 0"、"10980,9679,0"；z 容忍
--     但忽略——地圖是 2D。負號當分隔符：世界座標恆正，同主檔 XY 鈕註記的
--     原版 teleport UI 慣例）
--   - 關鍵字：比對街道名（NavRoute 引擎抽取的翻譯後街名——LangFor42 中文街名
--     直接可搜；"KY-841" 含字母走關鍵字不會誤判座標）＋POI 類別名（20 類翻譯
--     名，命中即展開該類設施、依距玩家有界最近-N 選擇）
-- 結果動作：在大地圖顯示（ShowWorldMap 帶座標開圖，ISWorldMap.lua:1500，並落
-- Core.searchPing 由雙表面畫脈動標記）／加到行程最後（Core.navPromptTarget
-- op=append，主要動作）／插在指定停靠點之前（原生子選單列出待前往站，選項建立時
-- 就捕捉 owner＋revision＋錨點 id，延遲點擊不得插到別的位置；長站名只放有界短標籤，
-- 全文走既有可捲確認面板讀完再套用——原生選單寬度＝最長選項全文寬，不封頂會出畫面）
-- ／先去這裡（op=priority：插在第一個待前往站之前並明確開始導航，不啟自駕）／取代整趟
-- （op=replace，次要動作且一律先確認）。選不到結果時（空字串／載入中／查無命中的
-- 說明列）這些動作一律停用——不留按了沒反應的按鈕。
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
    it.tag = kindTag(it.kind)
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
        local liveOriginals -- 純文字翻譯已有即時原名錨點，不再追加烘焙舊座標。
        for i = 1, #streets do
            local st = streets[i]
            if (st.low ~= "" and st.low:find(q, 1, true))
                or (st.originalLow and st.originalLow:find(q, 1, true)) then
                if st.originalLow and st.sourceDir and st.sourceDir:lower() == "muldraugh, ky" then
                    liveOriginals = liveOriginals or {}
                    liveOriginals[st.originalLow] = true
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
        -- 本表）；無翻譯 MOD 環境兩邊同時命中同一條→首點精確鍵去重，引擎項
        -- 優先。表缺席（生成器沒跑）＝純引擎行為
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
    -- （MinidoracatMiniMapPOIData 消費契約：r 按面積排序、r[1] 為圖標錨點）
    local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    local data = MinidoracatMiniMapPOIData
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
            for i = 1, #data do
                local e = data[i]
                local nm = hitCats[e.cat]
                    or (baseHit and e.u == 1 and allNames[e.cat] or nil)
                if nm and e.rn and e.rn >= 1 then
                    local r1 = e.r[1]
                    local ex, ey = r1.x + r1.w / 2, r1.y + r1.h / 2
                    local d = math.sqrt(dist2(px, py, ex, ey))
                    -- 剪枝早退：滿載且比末位遠→不配置 entry table 直接丟
                    if #hits < MAX_POI_RESULTS or d < hits[#hits].d then
                        -- 地下條目後綴（資料 u=1＝B42 basement）：地上是別的建築，
                        -- 不標會被當標錯（同圖標「↓」角標語義）
                        local label = (e.u == 1)
                            and (nm .. getText("UI_MinidoracatMiniMap_SearchBasement")) or nm
                        boundedInsert(hits, MAX_POI_RESULTS,
                            { kind = "poi", label = label, x = ex, y = ey, d = d })
                    end
                end
            end
            for i = 1, #hits do
                results[#results + 1] = finalizeItem(hits[i])
            end
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
}

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
local function wrapLines(text, maxW, maxLines)
    local lines = {}
    if type(text) ~= "string" or text == "" then return lines end
    if maxW < 16 then -- 版面異常窄：不硬切成一堆單字元，交給繪製端自然裁切
        lines[1] = text
        return lines
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

-- 視窗內訊息列（開窗時的操作回饋必須看得見；視窗不在／已收合＝退原版 halo
-- 壞訊息，同 navSetTarget 既有通道——右鍵地圖直接編輯行程時不能靜默失敗）
local function winMessage(pn, text)
    local win = searchWin
    if win and win:isVisible() and not win.collapsed and (win.playerNum or 0) == pn then
        win.msgLines = wrapLines(text, win.width - 20, MSG_LINES)
        win.msgUntil = getTimestampMs() + MSG_MS
        -- 訊息列只預留固定行數：放不下就把完整文字併進可捲清單（錯誤原因不得只剩
        -- 「...」）；兩頁的刷新 cache 一併作廢，那一列才會長出來／收回去
        win.msgFull = win.msgLines.truncated and text or nil
        win._tRev, win._lastText = nil, nil
        return
    end
    local playerObj = getSpecificPlayer(pn)
    if playerObj then HaloTextHelper.addBadText(playerObj, text) end
end

local function winError(pn, reason, detailKey)
    winMessage(pn, tripErrorText(reason, detailKey))
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
    return win.page == "itinerary" and win.tripFocus or win.searchFocus
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

-- 依「目前頁 × 是否收合 × 次要動作是否展開」決定每顆按鈕可見性。
-- 收合時只留標題列兩顆鈕：其餘元件不可見、輸入框解焦，完全不吃鍵盤
local function applyPage(win)
    local trip = win.page == "itinerary"
    local shown = not win.collapsed
    win.entry:setVisible(shown and not trip)
    win.list:setVisible(shown and not trip)
    win.tripList:setVisible(shown and trip)
    for i = 1, #win.modeBtns do
        win.modeBtns[i].btn:setVisible(shown and trip)
    end
    for i = 1, #win.tabs do
        win.tabs[i].btn:setVisible(shown)
        styleTab(win.tabs[i].btn, win.tabs[i].page == win.page)
    end
    for _, defs in ipairs({ win.searchBtns, win.tripBtns }) do
        local onPage = shown and ((defs == win.tripBtns) == trip)
        for i = 1, #defs do
            local d = defs[i]
            d.btn:setVisible(onPage and (d.group ~= "more" or win.expanded))
        end
    end
    win.g = win.geom[win.page]
    win.titleText = getText(trip and "UI_MinidoracatMiniMap_TripTitle"
        or "UI_MinidoracatMiniMap_SearchTitle")
    win.titleW = getTextManager():MeasureStringX(UIFont.Medium, win.titleText)
    if win.titleW > win.collapseBtn.x - 20 then
        win.titleText = getText(trip and "UI_MinidoracatMiniMap_TripManage"
            or "UI_MinidoracatMiniMap_SearchTabSearch")
        win.titleW = getTextManager():MeasureStringX(UIFont.Medium, win.titleText)
    end
    win.titleX = math.max(10, math.floor((win.collapseBtn.x - win.titleW) / 2))
    win.collapseBtn:setTitle(win.collapsed and "+" or "-")
    win.collapseBtn.tooltip = getText(win.collapsed and "UI_MinidoracatMiniMap_TripExpand"
        or "UI_MinidoracatMiniMap_TripCollapse")
    local moreText = getText(win.expanded and "UI_MinidoracatMiniMap_TripMoreHide"
        or "UI_MinidoracatMiniMap_TripMoreShow")
    win.searchMoreBtn:setTitle(moreText)
    win.tripMoreBtn:setTitle(moreText)
    if win.collapsed then
        if win.entry.unfocus then win.entry:unfocus() end
        win.focus = nil
    elseif win.focus then
        -- 已在鍵盤／手把模式：焦點移到新頁的分頁鈕，讓左右鍵可以連續換頁
        for i = 1, #win.tabs do
            if win.tabs[i].page == win.page then win.focus = i end
        end
    end
    -- 兩頁的刷新 cache 一律作廢：切頁／重排版後清單寬度可能已變，
    -- 換行判定與預格式化的右欄寬都要按新版面重算
    win._lastText = nil
    win._lastState = nil
    win._tRev = nil
    win._tripSel = nil
    win._searchSel = nil
end

local function setPage(win, page)
    if page ~= "itinerary" then page = "search" end
    if win.page == page then return end
    -- 離開搜尋頁必解焦：不可見的輸入框仍會攔截遊戲鍵盤
    -- （UITextBox2.java:652 只有 unfocus() 清 currentTextEntryBox）
    if page == "itinerary" and win.entry and win.entry.unfocus then win.entry:unfocus() end
    win.page = page
    applyPage(win)
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

-- 次要動作放不下時改用原生可捲動選單，不能把行程清單壓到零高度。
local function toggleMore(win)
    if not win.expanded and not win.moreFits then
        local defs = win.page == "itinerary" and win.tripBtns or win.searchBtns
        openNativeMenu(win, win.page == "itinerary" and win.tripMoreBtn or win.searchMoreBtn, function(menu)
            for i = 1, #defs do
                local d = defs[i]
                if d.group == "more" then
                    local intent = d.field == "manualBtn"
                        and { phase = win._tPhase, revision = win._tRev } or nil
                    local option = menu:addOption(d.btn.title, win, d.action, intent)
                    option.notAvailable = d.btn.enable == false
                end
            end
        end)
        return
    end
    win.moreMode = win.expanded and "off" or "on"
    relayoutWindow(win, win.playerNum or 0)
end

-- 關窗統一走這裡（codex review blocking：只 hide/remove 不 unfocus 會讓
-- Core.currentTextEntryBox 殘留——UITextBox2.java:652 只有 unfocus() 清它、
-- UIManager.RemoveElement 不清——關窗後不可見輸入框仍攔截遊戲鍵盤）。
-- 手把焦點同樣要交還，否則焦點卡在已移除的 UI 會鎖死手把導航
local function closeWindow(win)
    if win.entry and win.entry.unfocus then win.entry:unfocus() end
    win.focus = nil
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
    local button = win.insertBtn:isVisible() and win.insertBtn or win.searchMoreBtn
    openNativeMenu(win, button, function(menu)
        Core.navInsertOptions(menu, win, pn, it.x, it.y, it.label)
    end)
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
-- replace＝Core.navSetTarget，取代整份行程成單站並**立即開始導航**，所以有舊行程
-- 或壞資料時一律先確認；append 只加到清單最後、不出發；priority 插在第一個待前往
-- 站之前並明確開始導航（不啟自駕），取代舊的 next——沒有別名、沒有舊語意入口。
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
    -- 壞資料時 snapshot 可能是 nil，但取代同樣要確認（不偷偷抹掉待診斷資料）
    if (st and (st.count or 0) > 0) or tripErrorReason(pn) then
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

-- 雙地圖右鍵用：掛「插在指定停靠點之前」子選單（原版 getNew／addSubMenu 出處
-- ISContextMenu.lua:1199／1075；getNew 走 player 單例的 subMenuPool，前手一定先
-- 呼叫過 ISContextMenu.get 才有那張池子）。沒有待前往站可當錨點時整項不加——
-- 插入等於加尾，不留一條死路；第三方選單缺方法或不是 player 單例時安靜略過，
-- 不得讓別人的選單連坐壞掉
Core.navInsertSubMenu = function(context, target, pn, x, y, label)
    if type(context.addSubMenu) ~= "function" or type(context.player) ~= "number" then return end
    if type(context.subMenuPool) ~= "table" then return end
    if not (ISContextMenu and ISContextMenu.getNew) then return end
    if Core.navInsertAnchors(pn) == 0 then return end
    local sub = ISContextMenu:getNew(context)
    if Core.navInsertOptions(sub, target, pn, x, y, label) == 0 then return end
    context:addSubMenu(context:addOption(getText("UI_MinidoracatMiniMap_TripInsert")), sub)
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
    if Core.navKickAvailable then Core.navKickAvailable(win.playerNum or 0) end
    local text = win.entry:getInternalText() or ""
    -- cache key＝文字＋引擎狀態雙欄位（review：索引屬非同步建置，只鍵文字會在
    -- ready 後永遠停在「載入中」；欄位比較零每幀字串配置）
    local st = Core.navEngineState and Core.navEngineState() or "unknown"
    if not force and text == win._lastText and st == win._lastState then return end
    local playerObj = getSpecificPlayer(win.playerNum or 0)
    if not playerObj then return end -- 不寫 key：玩家回來後同 key 仍要能刷（review）
    win._lastText = text
    win._lastState = st
    win.list:clear()
    win._searchSel = nil -- 清單重建：下個 prerender 依新的選取重算動作可用性
    local results = doSearch(text, playerObj:getX(), playerObj:getY())
    if #results == 0 then
        if text == "" then
            -- 還沒輸入：空清單＋灰按鈕自己不會講話，明說要輸入什麼才有動作
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
    local bucketX, bucketY = math.floor(px / 8), math.floor(py / 8)
    local rev = tripRevision(st)
    local phase = st and st.phase or nil
    local reason = st and st.reason or nil
    local count = st and st.count or 0
    local current = st and st.currentStopId or nil
    local auto = st ~= nil and st.autoContinue == true
    if not force and rev == win._tRev and phase == win._tPhase and reason == win._tReason
        and count == win._tCount and current == win._tCur and err == win._tErr
        and auto == win._tAuto
        and pstate == win._tPs and pdone == win._tPd and ptotal == win._tPt
        and pdist == win._tPdist and bucketX == win._tBx and bucketY == win._tBy then
        return
    end
    win._tRev, win._tPhase, win._tReason = rev, phase, reason
    win._tCount, win._tCur, win._tErr, win._tAuto = count, current, err, auto
    win._tPs, win._tPd, win._tPt, win._tPdist = pstate, pdone, ptotal, pdist
    win._tBx, win._tBy = bucketX, bucketY
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
    local sub = getText("UI_MinidoracatMiniMap_TripPreview_" .. tostring(pstate or "off"))
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

local function pageRefresh(win, force)
    if win.page == "itinerary" then
        tripRefresh(win, force)
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

-- 畫名稱各行，回下一個可用的文字 y（meta 行用）
local function drawNameLines(self, it, ty)
    local lines = it.lines
    if not lines then
        self:drawText(it.label, it.nameX or 12, ty, 1, 1, 1, 1, UIFont.Small)
        return ty + self._minidoracatLineH
    end
    return drawLines(self, lines, it.nameX, ty, 1, 1, 1)
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
        local kc = KIND_COLORS[it.kind] or KIND_COLORS.coord
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
-- newRow＝強制換列（保持動作分組：主要動作永遠是第一批）。
-- expanded=false 時跳過 group=="more" 的次要動作（窄畫面／大字級折疊）。回總高
local function layoutButtons(defs, x, y, availW, btnH, gap, expanded)
    local tm = getTextManager()
    local cx, cy, rows = x, y, 1
    for i = 1, #defs do
        local d = defs[i]
        if expanded or d.group ~= "more" then
            local bw = tm:MeasureStringX(UIFont.Small, d.btn.title or d.text) + 24
            if d.altKey then bw = math.max(bw, tm:MeasureStringX(UIFont.Small, d.text) + 24) end
            if bw > availW then bw = availW end
            if cx > x and ((d.newRow and true) or cx + bw > x + availW) then
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
        if w.page == "itinerary" then tripShowOnMap(w) else winGoto(w) end
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
        win.geom = { search = { headY = 0, msgY = 0 }, itinerary = { headY = 0, msgY = 0 } }
        applyPage(win)
        return
    end
    local tabsY = titleH + pad
    local tabsH = layoutButtons(win.tabs, pad, tabsY, availW, btnH, gap, true)
    local bodyY = tabsY + tabsH + 8
    -- 模式列固定在行程頁頂部（清單之外）：接續模式是整趟行程的前提，
    -- 不能跟著清單捲走，也不能被次要動作折疊
    local modeH = layoutButtons(win.modeBtns, pad, 0, availW, btnH, gap, true)
    local modeTop = bodyY + modeH + 6
    local listY = {
        search = bodyY + entryH + 8,
        itinerary = modeTop + HEAD_LINES * lineH * 2 + 8,
    }
    local baseY = math.max(listY.search, listY.itinerary)
    local function blockH(expanded)
        return math.max(
            layoutButtons(win.searchBtns, pad, 0, availW, btnH, gap, expanded),
            layoutButtons(win.tripBtns, pad, 0, availW, btnH, gap, expanded))
    end
    local fullBlock, leanBlock = blockH(true), blockH(false)
    local function heightFor(block, rows)
        return baseY + block + rowH * rows + msgH + pad + 8
    end
    -- 極窄／大字時連主要動作都擠不下：狀態與預覽改隨清單捲動，資訊不刪不截。
    win.scrollInfo = heightFor(leanBlock, 1) > maxH
    if win.scrollInfo then
        listY.itinerary = modeTop
        baseY = math.max(listY.search, listY.itinerary)
    end
    -- 至少保留一列；更多動作若放不下，按鈕改開原生選單而非重疊主清單。
    win.moreFits = heightFor(fullBlock, 1) <= maxH
    local expanded = win.moreMode ~= "off" and win.moreFits
    win.expanded = expanded
    local block = expanded and fullBlock or leanBlock
    local h = math.min(heightFor(block, 8), maxH)
    win:setHeight(h)
    local btnTop = h - pad - block
    local msgY = btnTop - msgH
    layoutButtons(win.searchBtns, pad, btnTop, availW, btnH, gap, expanded)
    layoutButtons(win.tripBtns, pad, btnTop, availW, btnH, gap, expanded)
    layoutButtons(win.modeBtns, pad, bodyY, availW, btnH, gap, true)
    local function fitList(listEl, y)
        listEl:setX(pad)
        listEl:setY(y)
        listEl:setWidth(availW)
        listEl:setHeight(math.max(0, msgY - 4 - y))
        listEl.itemheight = rowH
        listEl._minidoracatTextY = math.floor((rowH - fhS) / 2)
        listEl._minidoracatLineH = lineH
    end
    fitList(win.list, listY.search)
    fitList(win.tripList, listY.itinerary)
    win.entry:setX(pad)
    win.entry:setY(bodyY)
    win.entry:setWidth(availW)
    win.entry:setHeight(entryH)
    win.geom = {
        search = { msgY = msgY, headY = bodyY },
        itinerary = { msgY = msgY, headY = modeTop },
    }
    win.searchFocus = focusListFor(win, win.list, win.searchBtns, win.entry, nil)
    win.tripFocus = focusListFor(win, win.tripList, win.tripBtns, nil, win.modeBtns)
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
        setPage(win, "search")
    elseif key == Keyboard.KEY_RIGHT then
        setPage(win, "itinerary")
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
    -- 手把：原生 joypad focus 模式（A 觸發／B 關窗／X 換頁／方向鍵移動）
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
            setPage(self, self.page == "search" and "itinerary" or "search")
        elseif button == Joypad.YButton then
            toggleCollapsed(self)
        end
    end
    win.onJoypadDirUp = function(self) focusStep(self, -1) end
    win.onJoypadDirDown = function(self) focusStep(self, 1) end
    win.onJoypadDirLeft = function(self) setPage(self, "search") end
    win.onJoypadDirRight = function(self) setPage(self, "itinerary") end
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
    win.moreMode = "auto"
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
    -- 分頁鈕（鍵盤／手把可達的行程頁入口；滑鼠、TAB、左右鍵、X 鈕四路等價）
    win.tabs = {
        { key = "UI_MinidoracatMiniMap_SearchTabSearch", page = "search" },
        { key = "UI_MinidoracatMiniMap_TripManage", page = "itinerary" },
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
    win.list:setOnMouseDoubleClick(win, function(target)
        winGoto(target)
    end)
    win.tripList = ISScrollingListBox:new(0, 0, 10, 10)
    win.tripList:initialise()
    win.tripList:instantiate()
    win.tripList.font = UIFont.Small
    win.tripList.drawBorder = false
    win.tripList.backgroundColor = { r = 0, g = 0, b = 0, a = 0.25 }
    win.tripList.doDrawItem = tripDrawItem
    win:addChild(win.tripList)
    win.tripList:setOnMouseDoubleClick(win, function(target)
        tripShowOnMap(target)
    end)
    -- 搜尋頁：主要＝加到行程最後／在地圖顯示；次要＝插在指定站之前／先去這裡／
    -- 取代整趟（取代會立刻出發，放次要且一律先確認）
    win.searchBtns = {
        { key = "UI_MinidoracatMiniMap_TripAdd", action = winAddStop, field = "addBtn" },
        { key = "UI_MinidoracatMiniMap_SearchGoto", action = winGoto, field = "gotoBtn" },
        { key = "UI_MinidoracatMiniMap_TripMoreShow", altKey = "UI_MinidoracatMiniMap_TripMoreHide",
            action = toggleMore, field = "searchMoreBtn" },
        { key = "UI_MinidoracatMiniMap_TripInsert", action = winInsertStop,
            field = "insertBtn", group = "more", newRow = true },
        { key = "UI_MinidoracatMiniMap_TripPriority", action = winPriorityStop,
            field = "priorityBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_SearchSetTarget", action = winSetTarget,
            field = "replaceBtn", group = "more" },
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
    -- 行程頁：主要＝開始/繼續、停止；次要＝手動前往、檢視與清單編輯
    win.tripBtns = {
        { key = "UI_MinidoracatMiniMap_TripStart", altKey = "UI_MinidoracatMiniMap_TripContinue",
            action = tripStart, field = "startBtn" },
        { key = "UI_MinidoracatMiniMap_TripPause", action = tripPause, field = "pauseBtn" },
        { key = "UI_MinidoracatMiniMap_TripManual", altKey = "UI_MinidoracatMiniMap_TripRoads",
            action = tripManual, field = "manualBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripMoreShow", altKey = "UI_MinidoracatMiniMap_TripMoreHide",
            action = toggleMore, field = "tripMoreBtn" },
        { key = "UI_MinidoracatMiniMap_TripShowOnMap", action = tripShowOnMap,
            field = "mapBtn", group = "more", newRow = true },
        { key = "UI_MinidoracatMiniMap_TripPreviewOn", altKey = "UI_MinidoracatMiniMap_TripPreviewOff",
            action = tripPreview, field = "previewBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripMoveUp", action = tripMoveUp,
            field = "upBtn", group = "more", newRow = true },
        { key = "UI_MinidoracatMiniMap_TripMoveDown", action = tripMoveDown,
            field = "downBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripSkip", action = tripSkip,
            field = "skipBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripMarkPause", altKey = "UI_MinidoracatMiniMap_TripUnmarkPause",
            action = tripTogglePause, field = "pauseStopBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripRemove", action = tripRemove,
            field = "removeBtn", group = "more" },
        { key = "UI_MinidoracatMiniMap_TripUndo", action = tripUndo,
            field = "undoBtn", group = "more", newRow = true },
        { key = "UI_MinidoracatMiniMap_TripClear", action = tripClear,
            field = "clearBtn", group = "more" },
    }
    makeButtons(win, win.tripBtns)
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
                    self._tRev, self._lastText = nil, nil
                end
            else
                for i = 1, #self.msgLines do
                    self:drawText(self.msgLines[i], 10, g.msgY + (i - 1) * lineH,
                        WARN_COLOR.r, WARN_COLOR.g, WARN_COLOR.b, 1, UIFont.Small)
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

-- 開關搜尋／行程視窗（按鈕/右鍵選單/快捷鍵入口共用）。引擎冷啟動由 winRefresh 的
-- Core.navKickAvailable 負責（開窗後首個 prerender 即泵）。
-- page＝"search"／"itinerary" 時語意是「開啟或切到該頁」，**絕不關窗**——
-- 右鍵「行程管理」按兩次不該把視窗關掉；不帶 page 保留原本的 toggle。
-- 收合狀態下再按等於展開，不用先展開再按一次。
-- 分割畫面：同人再按＝關；他人按＝owner-transfer 重刷（同 _Settings 慣例），
-- 不誤關別人的視窗
Core.toggleSearchWindow = function(pn, page)
    pn = pn or 0
    if page ~= "search" and page ~= "itinerary" then page = nil end
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
    -- 視野外整組跳過（菱形半徑上限 28，留 40px 緩衝）
    if ux < -40 or uy < -40 or ux > inner.width + 40 or uy > inner.height + 40 then return end
    for k = 0, 1 do
        local phase = ((now / 1100) + k * 0.5) % 1
        local rad = 6 + phase * 22
        local a = 0.85 * (1 - phase)
        inner:drawLine(nil, ux - rad, uy, ux, uy - rad, 2, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux, uy - rad, ux + rad, uy, 2, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux + rad, uy, ux, uy + rad, 2, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux, uy + rad, ux - rad, uy, 2, a, 1, 0.85, 0.2)
    end
    inner:drawRect(ux - 2, uy - 2, 4, 4, 1, 1, 0.85, 0.2)
    inner:drawLine(nil, ux - 9, uy, ux - 4, uy, 2, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux + 4, uy, ux + 9, uy, 2, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux, uy - 9, ux, uy - 4, 2, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux, uy + 4, ux, uy + 9, 2, 0.9, 1, 0.85, 0.2)
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
