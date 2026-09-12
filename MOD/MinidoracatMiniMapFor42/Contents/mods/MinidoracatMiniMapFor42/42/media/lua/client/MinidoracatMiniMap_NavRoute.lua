-- MinidoracatMiniMap_NavRoute.lua
-- 本檔範圍：導航目標的「沿道路路線」引擎（0.17.0）——自官方街道資料建路網圖、
-- A* 尋路、偏航追蹤、雙表面（小地圖/世界地圖）路線繪製。完全自製，不依賴任何
-- 第三方 MOD；資料源只用引擎已載入的 streets.xml（42.20.0 官方 Lua API）。
-- 與主檔分工：行程權威狀態全在 _Itinerary（站點、順序、目前站、進度、持久化），
-- Core.navGetTarget 提供「目前活動站」投影；本檔不讀寫行程權威，只把「玩家→
-- 目標」的直線升級為路線多段線，畫在旗標之下（主檔 drawNavTargets 開頭呼叫
-- Core.drawNavRoute），另算剩餘行程的分段預覽（多站行程預設自動啟用，
-- navSetPreview 可手動開關，navPreviewState 讀狀態；
-- 自有快取不碰活動段）。ensureRoute 每幀比對 target 座標與
-- route 錨點；活動站更換或取消另由 navInvalidateRoute 立即清快取。
-- 狀態變更只走非繪製路徑：活動段確定無路／引擎失敗由 OnTick 的維護（或 addon
-- 查詢面）以 Core.navRouteResult 通知一次，繪製幀永不通知；預覽自身的失敗
-- 只標預覽狀態，不動行程。
-- 拆檔緣由：主檔 Kahlua 主 chunk locvar 貼 200 上限（同 _Settings/_WorldMapNav）；
-- 載入序＝同目錄字母序，本檔在主檔後（'.' < '_'）、_Settings/_WorldMapNav 前，
-- 只讀主檔一次性賦值的穩定引用。
--
-- ## API 出處（42.20.3 snapshot；家規：每個 PZ 呼叫都要有出處）
-- - mapAPI:getStreetsAPI()：UIWorldMapV3.java:111；原版用例 ISMapDefinitions.lua:33-49
-- - streetsAPI:getStreetDataByRelativeFileName(rel)：WorldMapStreetsV1.java:39-41
--   （曝露 UIWorldMap.java:539；rel 與加入字串同構，equalsIgnoreCase 比對
--   WorldMap.java:230-236）；getStreetDataCount/getStreetDataByIndex：
--   WorldMapStreetsV1.java:31-37（byIndex 兜底遍歷未知來源容器）
-- - 不呼叫 addStreetData/clearStreetData：小地圖（InitPlayer）與世界地圖（每次
--   ShowWorldMap）的街道皆由主檔 ensureStreetData 補載（count>0 跳過）；
--   clearStreetData 會走 combinedStreets.clear()——
--   WorldMapStreets.clear 不清 StreetLookup 空間索引、42.20.3 起 ObjectPool
--   上限 1024 < 官方 1098 條（WorldMap.java:241-248、WorldMapStreets.java:433-437；
--   LangFor42 AGENTS.md 實證幽靈殘留），本檔對任何實例全程唯讀
-- - global getStreets(data) → List<WorldMapStreet>：LuaManager.java:12542-12548
--   （42.20.0 新增；42.19 無此 API，versionMin=42.20.1 已守住下限）
-- - WorldMapStreet 曝露：LuaManager.java:2426（42.20.0 新增）；本檔只用其自身
--   宣告方法 getNumPoints/getPointX/getPointY/getTranslatedText（WorldMapStreet.java）
--   ——不碰 getPoints()：StreetPoints 繼承的 TFloatArrayList 未曝露，繼承方法
--   在 Lua 不保證可用（claude review）
-- - getStreets 回每檔未裁切的原始街道；引擎另以 initObscuredCells →
--   clipToObscuredCells 裁成 splitStreets，combine 才複製到繪圖容器
--   （WorldMapStreets.java:155-175/419-431、WorldMapStreet.java:565-621）。
--   本檔只裁自己的路網，覆蓋判定對齊 MapFiles.hasCell300（見 makeWinnerOf）。
-- - fileExists：LuaManager.java:5553-5560；getTimestampMs：LuaManager.java:9267-9274
-- - worldToUIX/worldToUIY/drawLine 參數序：沿主檔已驗證用法（drawNavIndicator）
--
-- ## 演算法與效能（使用者要求：注意占用與效率）
-- - 全程惰性：不設導航目標＝零成本（不抽取、不建圖、OnTick O(1) 早退）。
-- - 抽取（一次性，OnTick 分幀 48 街/tick）：~1100 街 4539 點的跨界呼叫 ~15k 次
--   同步做＝數十 ms > 16.7ms 幀預算會掉幀（codex review），分幀後 ~23 tick
--   （<0.5s）完成；kickEngine 同步部分只做容器蒐集（輕）。
-- - 建圖（一次性，OnTick 分幀）：cell gate 預切 → 段對交點/T 字投影（64 格
--   spatial bucket，桶內配對、桶內游標＝budget 硬上限）→ 吸附鏈共同根解析
--   → 切割成節點/邊（座標量化 join）。每 tick 固定操作預算（STEP_BUDGET），60fps 下 1~3 秒
--   完成，不卡渲染幀（對比：Navigator 在 OnGameStart 同步全算，是其負評
--   「黑屏/卡頓」主因）。
-- - 尋路（設目標/偏航重算時）：A* 二元堆＋generation stamp 陣列（免每次清表）；
--   節點以整數索引、鄰接用扁平陣列（SoA）——避開 Kahlua 字串 key/巢狀表開銷。
--   ~4k 節點毫秒級。起/終各 2 snap 候選（至多 4 次 A*），總代價含 approach×3
--   加權（off-road 一格計三格，防「穿荒地到孤島短段」退化路線）。
-- - 每幀：行進進度增量投影（±12 段窗，O(25) 投影）；繪製單輪投影供雙 pass
--   共用＋世界視窗 bbox 段剔除＋ppu 抽樣（~3px 一點）＋主檔零配置 clipSegment。
--
-- ## 連接規則（vanilla 資料實測定案：61 端點 join / 39 T 字 / 153 中段 X 交叉）
-- - Railroad 街整條剔除：英文子串 ∪ vanilla 9 條鐵路首點幾何簽名（街名翻譯
--   MOD 下譯名無 "Railroad"、而中文另有「鐵路街」類真街道不可比詞——幾何
--   簽名兩者皆解）。不做鐵路導航，同時消滅鐵路×道路的立體交叉錯連。
-- - 端點量化 join（0.5 格）＋端點吸附（T 字 1.5 格/端點合流 1 格，單向往小
--   key 根）＋中段 X 交叉切割全連（交點用 pair-time 世界座標，兩段共享同一
--   節點）：Muldraugh 棋盤市區的連通主力是 X 交叉，不連＝市區癱瘓。
-- - 已知限制：streets.xml 無 Z 資料，真高架跨越（PZ 地圖罕見）會錯連平面
--   路口；非英文命名的地圖 MOD 自帶鐵路會漏剔。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

local getBoolOption = Core.getBoolOption

local STEP_BUDGET = 900       -- 每 tick 建圖操作預算（實測校準點，見檔頭效能節）
-- 偏航距（格）：超過即重算。舊值 28 是純視覺容差，對 nav API 消費者（AutoDrive）
-- 是實害——route 首點是「重算當下」的 snap 投影點，快取沿用期間玩家可以離首點
-- 28 格還拿到舊線；小地圖靠 progressIdx/progX/progY 裁切藏住，addon 拿到的是
-- 未裁切本體，等於被要求先越野 28 格回到舊錨（2026-09-01 實測：車在
-- (10716,9756)、舊線首點 (10716,9737)，第一段直接斜穿房屋柵欄）。12＝最寬車道
-- 半寬 4＋路肩/人行道 ATTACH_SLACK 4.5 再留餘裕，越野接線壓在一個路幅內
local DEVIATION_DIST = 12
local REBUILD_COOLDOWN_MS = 3000
local REBUILD_MOVE_DIST = 8   -- 偏航重算的最小位移（格）：原地重算必得同一條線
                              -- （snap 只看座標），只是白燒 A* 又換掉 table
                              -- identity。冷卻到期就重跑會讓深野外（首點必遠、
                              -- 偏航恆成立）每 3s 產一條幾何相同的新表
local NOROAD_RETRY_DIST = 64  -- 無路狀態下玩家位移超過此距才重試

--------------------------------------------------------------------------------
-- 純演算法核心（離線可測區段：scripts/test_nav_route.lua 抽取本區＋stub 跑）。
-- 區內只用標準 Lua——無任何 PZ API，winnerOf 由外部注入。
--------------------------------------------------------------------------------
-- test:navroute-core:start
local NavCore = {}

local floor, sqrt, huge = math.floor, math.sqrt, math.huge

-- 核心常數（置於 test 區段內＝離線測試與遊戲共用同一份，零漂移）
local STREET_CELL = 300       -- 街道覆蓋格：WorldMapStreet.java:593-598
local LOT_CELL = 256          -- 實體地塊格；轉換契約 MapFiles.java:120-134
local BUCKET = 64             -- 空間索引桶邊長（世界格）
local JOIN_INV = 2            -- 節點量化倒數（1/2＝0.5 格精度）
local DEFAULT_HALFW = 2.5     -- width 缺值時的半寬（vanilla 常見 width=5）
local ATTACH_SLACK = 4.5      -- 半寬和之外的路口間隙容差（格）：涵蓋人行道與
                              -- 雙線公路中央分隔帶——vanilla 分隔帶公路畫成兩條
                              -- 平行 polyline（實測 KY-841/KY-1394 走廊雙線中心
                              -- 距 10 格），支路端點只畫到近側線，0.5 格餘裕會讓
                              -- 兩線互不通、A* 繞行 800 格到西端迴轉頭折返（MP
                              -- 實測繞遠根因之二，離線 repro ratio 8.94）。誤連
                              -- 幾何下限：兩街中心距 < 半寬和+4.5 時路緣間隙
                              -- < 4.5 格，塞不下建築，「可通行」語義成立
local CUT_MERGE = 0.25        -- 同段切割點合併距（格）
local ATTACH_END = 1.0        -- 投影點併入彼段端點的世界距（格）——同路口語義
local SNAP_RING = { 16, 48, 96, 160 } -- snap 擴圈搜尋半徑（格）
local PROGRESS_WINDOW = 12    -- 偏航增量投影的段窗口（±）
local MAX_POINTS_PER_STREET = 4096
local MAX_SEGMENT_LENGTH = 16384
local MAX_STREETS = 65536
local MAX_WIDTH = 64
local MIN_WORLD_COORD = -32768
local MAX_WORLD_COORD = 32767.5
local MAX_GATE_SEGMENTS = 65535
local EP_PAIR_BASE = (MAX_GATE_SEGMENTS + 1) * 2 -- 每段至多兩個端點，無向pair key不碰撞
local MAX_GRAPH_NODES = 99999
local MAX_PAIR_WORK = 100000 -- official security-pass=8059；>12x headroom
local MAX_PAIR_SCAN_WORK = 125000 -- official=30320；>4x headroom
local MAX_CUT_RECORDS = 10000 -- official=1917；>5x headroom
local MAX_CUTS_PER_SEGMENT = 128 -- official max=22；>5x headroom
local MAX_EP_MOVES = 10000    -- official=1779；>5x headroom
local MAX_BUCKET_REFERENCES = 100000 -- official=22453；>4x headroom
local MAX_STREET_CONTAINERS = 1024
local MAX_PROCESSED_STREETS = 65536
local MAX_STREET_NAME_LENGTH = 1024
local MAX_SEARCH_NAME_CHARS = 1000000
local MAX_RAW_SEGMENTS = 16384
local MAX_EXTRACT_POINTS = MAX_RAW_SEGMENTS * 8 -- 包含認證時讀取、最後被去重的點
local MAX_QUERY_WORK = 250000

local function dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end

-- 點到線段投影：回 (距離平方, t, 投影點 x, y)
local function projPointSeg(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = 0
    if l2 > 1e-12 then
        t = ((px - ax) * dx + (py - ay) * dy) / l2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local qx, qy = ax + t * dx, ay + t * dy
    return dist2(px, py, qx, qy), t, qx, qy
end

-- 線段交點（t,u ∈ [0,1]，平行含共線＝nil：共線重複段不產交點，重複邊由建圖
-- 去重吸收）。端點觸碰也回切點：t≈0/1 的切割由 stepCut 的 CUT_MERGE 門檻自然
-- 併入端點節點——不用比例邊距（比例對長段是 10 格級盲區：500 格段的 2%＝10
-- 格，近端真交叉會被漏切，codex review）
local function segCross(ax, ay, bx, by, cx, cy, dx2, dy2)
    local rx, ry = bx - ax, by - ay
    local sx, sy = dx2 - cx, dy2 - cy
    local den = rx * sy - ry * sx
    if den > -1e-9 and den < 1e-9 then return nil end
    local qpx, qpy = cx - ax, cy - ay
    local t = (qpx * sy - qpy * sx) / den
    local u = (qpx * ry - qpy * rx) / den
    if t >= -1e-9 and t <= 1 + 1e-9 and u >= -1e-9 and u <= 1 + 1e-9 then
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        if u < 0 then u = 0 elseif u > 1 then u = 1 end
        return t, u
    end
    return nil
end

local BKOFF = 8192 -- bucket 座標偏移：負世界座標地圖包合法（grok review），偏移後恆正無碰撞
local function bucketKey(bx, by)
    return (bx + BKOFF) * 100000 + (by + BKOFF) -- max ~1.6e9 < 2^53 精度
end

-- 段 bbox 的 bucket 範圍（pad＝外擴格數）。回傳範圍由呼叫端內聯迴圈——
-- 不用回呼閉包：建圖期每段一個閉包物件是萬級無謂配置（claude review）
local function bucketRange(x1, y1, x2, y2, pad)
    local lox, hix = x1, x2
    if lox > hix then lox, hix = hix, lox end
    local loy, hiy = y1, y2
    if loy > hiy then loy, hiy = hiy, loy end
    return floor((lox - pad) / BUCKET), floor((hix + pad) / BUCKET),
        floor((loy - pad) / BUCKET), floor((hiy + pad) / BUCKET)
end

-- 收集線段跨 300 格街道覆蓋邊界的 t 值（升冪、含 0/1 端），供 gate 預切
local function cellBoundaryTs(x1, y1, x2, y2, out)
    local n = 0
    out[1] = 0
    n = 1
    local dx, dy = x2 - x1, y2 - y1
    if dx > 1e-9 or dx < -1e-9 then
        local lo, hi = x1, x2
        if lo > hi then lo, hi = hi, lo end
        for k = floor(lo / STREET_CELL) + 1, floor(hi / STREET_CELL) do
            n = n + 1
            out[n] = (k * STREET_CELL - x1) / dx
        end
    end
    if dy > 1e-9 or dy < -1e-9 then
        local lo, hi = y1, y2
        if lo > hi then lo, hi = hi, lo end
        for k = floor(lo / STREET_CELL) + 1, floor(hi / STREET_CELL) do
            n = n + 1
            out[n] = (k * STREET_CELL - y1) / dy
        end
    end
    n = n + 1
    out[n] = 1
    -- 小陣列插入排序（cell 邊界切點通常 0~3 個）
    for i = 2, n do
        local v = out[i]
        local j = i - 1
        while j >= 1 and out[j] > v do
            out[j + 1] = out[j]
            j = j - 1
        end
        out[j + 1] = v
    end
    return n
end

-- 原版補丁身分以完整 q2 幾何與路寬認證，不依賴街名或翻譯包 ID。
-- 純載體在抽取去重前逐容器認證；canonicalSrc 只決定補丁／實體覆蓋，
-- src 仍保留原始載入來源。未認證的 nil 來源不能湊聯集套用官方補丁。
local function validWidth(value)
    return type(value) == "number" and value == value and value >= 1
        and value <= MAX_WIDTH
end

local function validSurface(value)
    return value == "paved" or value == "gravel" or value == "dirt"
        or value == "unknown"
end

local function validStreetPoints(pts)
    if type(pts) ~= "table" or #pts < 4 or #pts % 2 ~= 0
        or #pts / 2 > MAX_POINTS_PER_STREET
    then
        return false
    end
    local limit2 = MAX_SEGMENT_LENGTH * MAX_SEGMENT_LENGTH
    for i = 1, #pts do
        local value = pts[i]
        if type(value) ~= "number" or value ~= value or value <= -huge or value >= huge
            or value < MIN_WORLD_COORD or value > MAX_WORLD_COORD
        then
            return false
        end
    end
    for i = 1, #pts - 2, 2 do
        if dist2(pts[i], pts[i + 1], pts[i + 2], pts[i + 3]) > limit2 then
            return false
        end
    end
    return true
end

local function geometryKey(pts)
    if not validStreetPoints(pts) then return nil end
    local parts = { floor(#pts / 2) }
    for i = 1, #pts do
        parts[i + 1] = floor(pts[i] * 2 + 0.5)
    end
    return table.concat(parts, ":", 1, #pts + 1)
end

local function fingerprintOf(pts, width)
    if not validWidth(width) then return nil end
    local geometry = geometryKey(pts)
    if not geometry then return nil end
    return geometry .. "|w:" .. floor(width * 2 + 0.5)
end

local function fingerprintKey(street)
    return fingerprintOf(street.pts, street.width)
end

local function segmentId(compact, segIndex)
    if type(compact) ~= "string" or compact == "" then return nil end
    return compact .. ":" .. segIndex
end

local function cloneStreet(street)
    local pts = street.pts
    if not validStreetPoints(pts) then return nil, "bad street geometry" end
    local baseWidth = validWidth(street.width) and street.width or DEFAULT_HALFW * 2
    local copy = {
        name = type(street.name) == "string" and street.name or "",
        originalName = street.originalName,
        src = street.src, width = street.width, pts = pts,
        canonicalSrc = street.canonicalSrc,
        searchable = street.searchable,
        segRemoved = {}, segWidth = {}, segSurface = {},
    }
    local segRemoved, segWidth, segSurface =
        street.segRemoved, street.segWidth, street.segSurface
    for i = 1, #pts / 2 - 1 do
        local width = segWidth and segWidth[i] or baseWidth
        local surface = segSurface and segSurface[i] or "unknown"
        copy.segRemoved[i] = (segRemoved and segRemoved[i]) == true
        copy.segWidth[i] = validWidth(width) and width or DEFAULT_HALFW * 2
        copy.segSurface[i] = validSurface(surface) and surface or "unknown"
    end
    return copy
end

local function registerSegments(street, compact, lookup)
    for i = 1, #street.pts / 2 - 1 do
        local id = segmentId(compact, i - 1)
        if lookup[id] then return false, "duplicate segment identity" end
        lookup[id] = { street = street, index = i }
    end
    return true
end

local function validCount(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function exactArray(values, count)
    if type(values) ~= "table" then return false end
    local seen = 0
    for key in pairs(values) do
        if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
            return false
        end
        seen = seen + 1
    end
    if seen ~= count then return false end
    for i = 1, count do
        if values[i] == nil then return false end
    end
    return true
end

local function stagePatchStreet(staged, lookup, op, operationIds, targetLow, officialDir)
    if type(op) ~= "table" or type(op.id) ~= "string" or op.id == ""
        or operationIds[op.id]
    then
        return false, "duplicate or invalid add/bridge id"
    end
    operationIds[op.id] = true
    local geometry = geometryKey(op.pts)
    if not geometry or type(op.src) ~= "string" or op.src == ""
        or not validWidth(op.width) or not validSurface(op.surface)
    then
        return false, "invalid add/bridge evidence"
    end
    local searchable = op.searchable
    if type(searchable) ~= "boolean" then return false, "invalid add/bridge searchable" end
    if op.name ~= nil and (type(op.name) ~= "string" or #op.name > MAX_STREET_NAME_LENGTH) then
        return false, "invalid add/bridge name"
    end
    local street = {
        name = type(op.name) == "string" and op.name or "",
        src = op.src, width = op.width, pts = op.pts, searchable = searchable,
        canonicalSrc = op.src:lower() == targetLow and officialDir or nil,
        segRemoved = {}, segWidth = {}, segSurface = {},
    }
    for i = 1, #op.pts / 2 - 1 do
        street.segRemoved[i] = false
        street.segWidth[i] = op.width
        street.segSurface[i] = op.surface
    end
    local ok, err = registerSegments(street, "add:" .. op.id, lookup)
    if not ok then return false, err end
    staged[#staged + 1] = street
    return true
end

-- 完整 preflight 後才替換 streets 的數字槽：fingerprint、所有 operation 引用、
-- remove→width/surface overrides→add→bridge；任一衝突時原 ex.out 一格都不動。
-- 相同 tag 重入直接成功且不重複 append；不同 patch 疊套 fail closed。
function NavCore.applyRoadPatches(streets, patch, officialDir)
    if type(streets) ~= "table" or type(patch) ~= "table"
        or patch.schemaVersion ~= 1 or type(patch.tag) ~= "string"
        or type(patch.targetSrc) ~= "string" or type(patch.geometrySet) ~= "table"
        or not validCount(patch.geometryCount)
    then
        return false, "invalid patch header"
    end
    local targetLow = patch.targetSrc:lower()
    officialDir = officialDir or patch.targetSrc
    if type(officialDir) ~= "string" or officialDir:lower() ~= targetLow then
        return false, "invalid canonical source"
    end
    if streets._roadPatchTag then
        if streets._roadPatchTag == patch.tag then return true, "already" end
        return false, "different patch already applied"
    end
    local expectedCount, compactSeen = 0, {}
    for fingerprint, compact in pairs(patch.geometrySet) do
        if type(fingerprint) ~= "string" or type(compact) ~= "string" or compact == ""
            or compactSeen[compact]
        then
            return false, "invalid geometry set"
        end
        compactSeen[compact] = true
        expectedCount = expectedCount + 1
    end
    if expectedCount ~= patch.geometryCount or #streets > MAX_STREETS then
        return false, "invalid geometry set"
    end
    local staged, lookup, targetSeen = {}, {}, {}
    local targetCount = 0
    for i = 1, #streets do
        local original = streets[i]
        if (original.canonicalSrc or original.src) == officialDir then
            local fingerprint = fingerprintKey(original)
            local compact = fingerprint and patch.geometrySet[fingerprint] or nil
            if compact and not targetSeen[fingerprint] then
                local copy, cloneErr = cloneStreet(original)
                if not copy then return false, cloneErr end
                targetSeen[fingerprint] = true
                targetCount = targetCount + 1
                local ok, err = registerSegments(copy, compact, lookup)
                if not ok then return false, err end
                staged[i] = copy
            else
                return false, "fingerprint mismatch"
            end
        else
            staged[i] = original -- 非 target 不配置 metadata/ID；builder 自行驗 raw
        end
    end
    if targetCount == 0 and patch.geometryCount > 0 then return false, "no certified vanilla source" end
    if targetCount ~= patch.geometryCount then return false, "fingerprint mismatch" end

    local removeCount = patch.removeCount or 0
    local addCount = patch.addCount or 0
    local bridgeCount = patch.bridgeCount or 0
    local widthCount = patch.widthCount or 0
    local surfaceCount = patch.surfaceCount or 0
    if not validCount(removeCount) or not validCount(addCount)
        or not validCount(bridgeCount) or not validCount(widthCount)
        or not validCount(surfaceCount)
    then
        return false, "invalid patch counts"
    end
    if not exactArray(patch.remove, removeCount)
        or not exactArray(patch.width, widthCount)
        or not exactArray(patch.surface, surfaceCount)
        or not exactArray(patch.add, addCount)
        or not exactArray(patch.bridge, bridgeCount)
    then
        return false, "patch count/array mismatch"
    end
    -- 上面的 exactArray 已保證五個陣列都是 dense table（count 為 0 也必須給 {}），
    -- 以下取用不必再 `patch.x and` 兜底。
    local touchedRemove = {}
    for i = 1, removeCount do
        local id = patch.remove[i]
        local hit = type(id) == "string" and lookup[id] or nil
        if not hit or touchedRemove[id] then return false, "remove conflict" end
        touchedRemove[id] = true
        hit.street.segRemoved[hit.index] = true
    end
    local touchedWidth = {}
    for i = 1, widthCount do
        local op = patch.width[i]
        local id = type(op) == "table" and op.id or nil
        local hit = id and lookup[id] or nil
        if not hit or touchedWidth[id] or not validWidth(op.value) then
            return false, "width conflict"
        end
        touchedWidth[id] = true
        hit.street.segWidth[hit.index] = op.value
    end
    local touchedSurface = {}
    for i = 1, surfaceCount do
        local op = patch.surface[i]
        local id = type(op) == "table" and op.id or nil
        local hit = id and lookup[id] or nil
        if not hit or touchedSurface[id] or not validSurface(op.value) then
            return false, "surface conflict"
        end
        touchedSurface[id] = true
        hit.street.segSurface[hit.index] = op.value
    end
    local operationIds = {}
    for i = 1, addCount do
        local ok, err = stagePatchStreet(staged, lookup, patch.add[i], operationIds, targetLow, officialDir)
        if not ok then return false, err end
    end
    for i = 1, bridgeCount do
        local ok, err = stagePatchStreet(staged, lookup, patch.bridge[i], operationIds, targetLow, officialDir)
        if not ok then return false, err end
    end

    local oldN = #streets
    for i = 1, #staged do streets[i] = staged[i] end
    for i = #staged + 1, oldN do streets[i] = nil end
    streets._roadPatchTag = patch.tag
    return true, "applied"
end

function NavCore.streetSearchable(street)
    if not street or street.searchable == false then return false end
    local pts = street.pts
    if type(pts) ~= "table" then return false end
    local segRemoved = street.segRemoved
    for i = 1, #pts / 2 - 1 do
        if not segRemoved or segRemoved[i] ~= true then return true end
    end
    return false
end


function NavCore.streetIndexAnchor(street, winnerOf, tsBuf)
    if not NavCore.streetSearchable(street) then return nil end
    local pts, removed = street.pts, street.segRemoved
    local source = street.canonicalSrc or street.src
    for i = 1, #pts / 2 - 1 do
        if not removed or removed[i] ~= true then
            local x1, y1 = pts[i * 2 - 1], pts[i * 2]
            local x2, y2 = pts[i * 2 + 1], pts[i * 2 + 2]
            if not winnerOf or source == nil then return x1, y1 end
            local nts = cellBoundaryTs(x1, y1, x2, y2, tsBuf)
            for k = 1, nts - 1 do
                local t0, t1 = tsBuf[k], tsBuf[k + 1]
                if t1 - t0 > 1e-9 then
                    local tm = (t0 + t1) * 0.5
                    local mx, my = x1 + (x2 - x1) * tm, y1 + (y2 - y1) * tm
                    local winner = winnerOf(floor(mx / STREET_CELL), floor(my / STREET_CELL), source)
                    if winner == nil or winner == source then
                        return x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0
                    end
                end
            end
        end
    end
    return nil
end
-- 建圖狀態機：NavCore.newBuild(streets, winnerOf) → builder；
-- NavCore.step(builder, budget) 推進，回傳 true＝完成（builder.graph 就緒）。
-- streets[i] = { name=街名, src=來源地圖目錄, pts={x1,y1,x2,y2,...} 扁平 }
-- winnerOf(cx,cy)→dir|nil：cell 勝出地圖目錄；整個參數為 nil＝fail-open 不裁段。
function NavCore.newBuild(streets, winnerOf)
    -- （斷口橋接已撤回 2026-08-20：曾以「端點對齊＋距離」合成短街修雙線公路
    -- Z 字，但 vanilla 實測生成 +347 節點——遠超雙線斷口量級，大多是排屋後巷/
    -- 圍籬/河岸的誤接，導錯路實害 > Z 字視覺瑕疵（Z 字路徑合法，只是在公路帶
    -- 內借最近貫穿點多繞幾格）。嚴謹版需驗證「兩端切線同軸＋縫隙內確有橫穿
    -- 道路」才可重做——codex review 裁決）
    -- padTol＝最大「兩路半寬和＋餘裕」：streets.xml 是道路「中心線」，寬路
    -- （vanilla width 5-8）的支路端點停在路緣、距幹道中心線＝半寬（3-4 格）
    -- ——固定 1.5 格容差接不上（MP 實測：白鴿街 w8 端點距麻雀街 w6 中心線
    -- 3 格，整個住宅區懸空 noroad，codex 定位）。吸附容差改 per-pair 半寬和，
    -- 配對 bucket 外擴用全域最大值
    if type(streets) ~= "table" or #streets > MAX_STREETS then
        error("street count limit exceeded")
    end
    local rawSegments = 0
    for i = 1, #streets do
        local street = streets[i]
        if not validStreetPoints(street.pts)
            or (street.width ~= nil and not validWidth(street.width))
        then
            error("invalid street geometry/width")
        end
        rawSegments = rawSegments + #street.pts / 2 - 1
        if rawSegments > MAX_RAW_SEGMENTS then error("raw segment limit exceeded") end
        if street.segWidth then
            for si = 1, #street.pts / 2 - 1 do
                if street.segWidth[si] ~= nil and not validWidth(street.segWidth[si]) then
                    error("invalid segment width")
                end
            end
        end
    end
    local maxHalf = DEFAULT_HALFW
    for i = 1, #streets do
        local street = streets[i]
        local segRemoved, segWidth = street.segRemoved, street.segWidth
        for si = 1, #street.pts / 2 - 1 do
            if not segRemoved or segRemoved[si] ~= true then
                local wd = segWidth and segWidth[si] or street.width
                if validWidth(wd) then
                    local half = wd * 0.5
                    if half > maxHalf then maxHalf = half end
                end
            end
        end
    end
    return {
        streets = streets, winnerOf = winnerOf,
        padTol = maxHalf * 2 + ATTACH_SLACK,
        phase = "gate", si = 1, pi = 1,
        gx1 = {}, gy1 = {}, gx2 = {}, gy2 = {}, gsid = {},
        gwidth = {}, gsurface = {}, gn = 0,
        buck = {}, bkeys = {}, bn = 0, peakBucket = 0, bucketReferenceCount = 0,
        cuts = {},
        seenPair = {}, pairWork = 0, pairScanWork = 0, cutRecords = 0,
        maxCutsPerSegment = 0,
        epMove = {}, epMoveCount = 0, epStreet = {}, junction = {},
        epOrd = {}, epOrdCount = 0, epLink = {},
        epKeys = {}, rpath = {}, ri = 1, rn = 0, rid = 0,
        bi = 1, ci = 1, pii = nil, pjj = nil,
        tsBuf = {}, graph = nil,
    }
end

local QOFF = 65536 -- 量化座標偏移：同 BKOFF，負世界座標防碰撞
local function quantKey(x, y)
    return (floor(x * JOIN_INV + 0.5) + QOFF) * 200000 + (floor(y * JOIN_INV + 0.5) + QOFF)
end

local function gateEmit(b, x1, y1, x2, y2, sid, width, surface)
    if dist2(x1, y1, x2, y2) < 1e-6 then return end
    local n = b.gn + 1
    if n > MAX_GATE_SEGMENTS then error("gate segment key-space limit exceeded") end
    b.gn = n
    -- 跨街共用端點有合流優先權，避免既有路口被附近單一路段頂點拖走。
    local k1, k2 = quantKey(x1, y1), quantKey(x2, y2)
    local s1, s2 = b.epStreet[k1], b.epStreet[k2]
    if s1 == nil then b.epStreet[k1] = sid elseif s1 ~= sid then b.junction[k1] = true end
    if s2 == nil then b.epStreet[k2] = sid elseif s2 ~= sid then b.junction[k2] = true end
    -- 既有路段的兩端不得再合流成一點；序號讓無向連邊可用精確整數key。
    local o1 = b.epOrd[k1]
    if not o1 then
        o1 = b.epOrdCount + 1
        b.epOrdCount, b.epOrd[k1] = o1, o1
    end
    local o2 = b.epOrd[k2]
    if not o2 then
        o2 = b.epOrdCount + 1
        b.epOrdCount, b.epOrd[k2] = o2, o2
    end
    if o1 > o2 then o1, o2 = o2, o1 end
    b.epLink[o1 * EP_PAIR_BASE + o2] = true
    b.gx1[n], b.gy1[n], b.gx2[n], b.gy2[n], b.gsid[n] = x1, y1, x2, y2, sid
    b.gwidth[n], b.gsurface[n] = width, surface
    -- 配對 bucket 登記外擴 padTol（最大半寬和＋餘裕）：吸附容差跨桶（主線
    -- y=-1、支路端 y=0 分居 64 格桶界）時不擴張就永遠配不到對（codex 反例）
    local bx1, bx2, by1, by2 = bucketRange(x1, y1, x2, y2, b.padTol)
    for bx = bx1, bx2 do
        for by = by1, by2 do
            local key = bucketKey(bx, by)
            local list = b.buck[key]
            if not list then
                list = {}
                b.buck[key] = list
                b.bn = b.bn + 1
                b.bkeys[b.bn] = key
            end
            b.bucketReferenceCount = b.bucketReferenceCount + 1
            if b.bucketReferenceCount > MAX_BUCKET_REFERENCES then
                error("bucket reference limit exceeded")
            end
            list[#list + 1] = n
            if #list > b.peakBucket then b.peakBucket = #list end
        end
    end
end

-- 階段一：依引擎的 300 格街道覆蓋邊界預切，再按子段中點的勝出來源過濾。
-- 沒有覆蓋者、來源未佔該街道格或純資料載體時保留；不可把邊緣的整個
-- 256 格 lotheader 都當成道路覆蓋，否則會裁斷 MOD 道路與原版幹道的接線。
local function stepGate(b, budget)
    local ops = 0
    while ops < budget do
        local street = b.streets[b.si]
        if not street then
            b.phase = "pairs"
            return ops
        end
        local pts = street.pts
        local np = #pts / 2
        if b.pi >= np then
            b.si, b.pi = b.si + 1, 1
        else
            local i = b.pi
            local width = street.segWidth and street.segWidth[i] or street.width
            if not validWidth(width) then width = DEFAULT_HALFW * 2 end
            local surface = street.segSurface and street.segSurface[i] or "unknown"
            if not validSurface(surface) then surface = "unknown" end
            local removed = street.segRemoved and street.segRemoved[i] == true
            local x1, y1 = pts[i * 2 - 1], pts[i * 2]
            local x2, y2 = pts[i * 2 + 1], pts[i * 2 + 2]
            if removed then
                ops = ops + 1
            elseif not b.winnerOf then
                gateEmit(b, x1, y1, x2, y2, b.si, width, surface)
                ops = ops + 2
            else
                local source = street.canonicalSrc or street.src
                local nts = cellBoundaryTs(x1, y1, x2, y2, b.tsBuf)
                for k = 1, nts - 1 do
                    local t0, t1 = b.tsBuf[k], b.tsBuf[k + 1]
                    if t1 - t0 > 1e-9 then
                        local tm = (t0 + t1) * 0.5
                        local mx = x1 + (x2 - x1) * tm
                        local my = y1 + (y2 - y1) * tm
                        local w = b.winnerOf(floor(mx / STREET_CELL), floor(my / STREET_CELL), source)
                        if w == nil or source == nil or w == source then
                            gateEmit(b, x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0,
                                x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1,
                                b.si, width, surface)
                        end
                        ops = ops + 3
                    end
                end
            end
            b.pi = i + 1
        end
    end
    return ops
end

-- 記切點：t＝沿原始段的排序鍵；(x,y)＝pair-time 世界交點座標。切割一律用
-- 世界座標建節點——兩段共享同一 (x,y) → 同量化節點。絕不可在端點吸附移動
-- 後的幾何上重插 t：同一交點會在兩段算出不同座標（codex 執行反例
-- (50,9.3) vs (50,10)；官方 42.20.3 資料掃描 28/160 交點量化 key 分裂）
local function addCut(b, segIdx, t, x, y)
    b.cutRecords = b.cutRecords + 1
    if b.cutRecords > MAX_CUT_RECORDS then error("cut record limit exceeded") end
    local list = b.cuts[segIdx]
    if not list then
        list = {}
        b.cuts[segIdx] = list
    end
    if #list >= MAX_CUTS_PER_SEGMENT then error("per-segment cut limit exceeded") end
    list[#list + 1] = { t = t, x = x, y = y }
    if #list > b.maxCutsPerSegment then b.maxCutsPerSegment = #list end
end

-- 段對處理：X 內部交叉互記切點；端點靠近彼段（≤兩路半寬和＋餘裕）者記「端點
-- 吸附」——投影落段內＝T 字（彼段記切點＋端點移往投影點）、投影 clamp 到彼段
-- 端點＝跨街近端點（吸附成同一路口）。吸附是 T 字連通的關鍵：投影切點與支路
-- 端點可差半寬（3-4 格）> 0.5 格量化合併距，只切不移則切了也不連（codex
-- review）；同 d2 競爭取小者，同量化 key 的共享端點一起移動
local function mapTo(b, fx, fy, tx2, ty2, d2)
    local key = quantKey(fx, fy)
    local cur = b.epMove[key]
    if not cur then
        b.epMoveCount = b.epMoveCount + 1
        if b.epMoveCount > MAX_EP_MOVES then error("endpoint move limit exceeded") end
        b.epKeys[b.epMoveCount] = key
    end
    if not cur or d2 < cur.d2 then
        b.epMove[key] = { x = tx2, y = ty2, d2 = d2 }
    end
end

local function tryAttach(b, ex, ey, ax, ay, bx2, by2, cutSeg, tol)
    local d2, t, qx, qy = projPointSeg(ex, ey, ax, ay, bx2, by2)
    if d2 > tol * tol then return end
    -- 端點 vs 段內判定用世界距離（比例 t 對長段失真，codex review）：投影點落
    -- 彼段端點 1 格內＝端點對端點合流；否則＝真 T 字，切段＋端點吸往投影點
    local da2 = dist2(qx, qy, ax, ay)
    local db2 = dist2(qx, qy, bx2, by2)
    local endTol = ATTACH_END * ATTACH_END
    if da2 <= endTol or db2 <= endTol then
        local px2, py2 = ax, ay
        if db2 < da2 then px2, py2 = bx2, by2 end
        -- 未宣告端點接入既有路口；同等身分才用小 key 決勝。T字投影仍走下方分支。
        local ka, kb = quantKey(ex, ey), quantKey(px2, py2)
        if ka ~= kb then
            local oa, ob = b.epOrd[ka], b.epOrd[kb]
            if oa > ob then oa, ob = ob, oa end
            if b.epLink[oa * EP_PAIR_BASE + ob] then return end
            local ja, jb = b.junction[ka], b.junction[kb]
            if jb and not ja then
                mapTo(b, ex, ey, px2, py2, d2)
            elseif ja and not jb then
                mapTo(b, px2, py2, ex, ey, d2)
            elseif ka < kb then
                mapTo(b, px2, py2, ex, ey, d2)
            else
                mapTo(b, ex, ey, px2, py2, d2)
            end
        end
    else
        addCut(b, cutSeg, t, qx, qy)
        mapTo(b, ex, ey, qx, qy, d2)
    end
end

local function processPair(b, i, j)
    local x1, y1, x2, y2 = b.gx1[i], b.gy1[i], b.gx2[i], b.gy2[i]
    local x3, y3, x4, y4 = b.gx1[j], b.gy1[j], b.gx2[j], b.gy2[j]
    local t, u = segCross(x1, y1, x2, y2, x3, y3, x4, y4)
    if t then
        -- 交點世界座標以 i 段原始幾何算一次、兩段共用同一 (ix,iy)——
        -- 各自插值有浮點差，量化邊界上可能分裂成兩節點
        local ix, iy = x1 + t * (x2 - x1), y1 + t * (y2 - y1)
        addCut(b, i, t, ix, iy)
        addCut(b, j, u, ix, iy)
    end
    -- 吸附容差＝兩路半寬和＋路口間隙（street 中心線語義：支路端點停在寬路
    -- 路緣、雙線公路停在近側線）
    local tol = b.gwidth[i] * 0.5 + b.gwidth[j] * 0.5 + ATTACH_SLACK
    tryAttach(b, x1, y1, x3, y3, x4, y4, j, tol)
    tryAttach(b, x2, y2, x3, y3, x4, y4, j, tol)
    tryAttach(b, x3, y3, x1, y1, x2, y2, i, tol)
    tryAttach(b, x4, y4, x1, y1, x2, y2, i, tol)
end

-- 階段 2.5：先把吸附鏈解析到共同代表，再建圖；不能按固定跳數截斷成不同節點。
-- 走鏈、環內選根與路徑壓縮各處理一筆就計一次 budget，長鏈也能跨 tick 續跑。
-- T 字可能形成環，環內取最小 key 的座標；壓縮後 done 節點不再改根。
local function stepResolve(b, budget)
    local ops = 0
    local keys, moves = b.epKeys, b.epMove
    while ops < budget do
        if b.rCycle then
            local i = b.rCycleI
            local pk = b.rpath[i]
            local mv = moves[pk]
            local nk = quantKey(mv.x, mv.y)
            if nk < b.rRootKey then
                b.rRootKey, b.rRootX, b.rRootY = nk, mv.x, mv.y
            end
            if pk == b.rCycle then
                b.rCycle, b.rCycleI = nil, nil
                b.rCompress = b.rn
            else
                b.rCycleI = i - 1
            end
        elseif b.rCompress then
            local i = b.rCompress
            local mv = moves[b.rpath[i]]
            mv.x, mv.y, mv.done = b.rRootX, b.rRootY, true
            b.rpath[i] = nil
            if i == 1 then
                b.rk, b.rn, b.rCompress = nil, 0, nil
                b.rRootKey, b.rRootX, b.rRootY = nil, nil, nil
            else
                b.rCompress = i - 1
            end
        elseif not b.rk then
            local idx = b.ri
            local start = keys[idx]
            if not start then
                b.phase, b.rpath = "cut", nil
                return ops
            end
            b.ri = idx + 1
            local mv = moves[start]
            if not mv.done then
                b.rn, b.rpath[1], b.rid, b.rk = 1, start, idx, start
                mv.walk = idx
            end
        else
            local mv = moves[b.rk]
            local tx, ty = mv.x, mv.y
            local nk = quantKey(tx, ty)
            local nextMove = moves[nk]
            local rootX, rootY
            if not nextMove or (nextMove.x == tx and nextMove.y == ty) then
                rootX, rootY = tx, ty
            elseif nextMove.done then
                rootX, rootY = nextMove.x, nextMove.y
            elseif nextMove.walk == b.rid then
                b.rCycle, b.rCycleI = nk, b.rn
                b.rRootKey, b.rRootX, b.rRootY = nk, tx, ty
            else
                local n = b.rn + 1
                b.rn, b.rpath[n], b.rk = n, nk, nk
                nextMove.walk = b.rid
            end
            if rootX ~= nil then
                b.rRootX, b.rRootY, b.rCompress = rootX, rootY, b.rn
            end
        end
        ops = ops + 1
    end
    return ops
end

-- resolve 期已壓成根座標，cut 期只需單查。
local function resolveMoved(b, x, y)
    local mv = b.epMove[quantKey(x, y)]
    if mv then return mv.x, mv.y end
    return x, y
end

-- 階段二：逐 bucket 桶內配對。budget 是硬上限：桶內 (ii,jj) 游標入 builder
-- state，超額即中斷、下 tick 續跑（codex 反例：100 段同桶時舊版 step(b,1)
-- 一次做完 4950 對——密集第三方地圖單 tick 尖峰）。同對跨桶以 seenPair 去重
-- （段數 <65536，i*65536+j 數字 key 在 2^53 精度內安全）
local function stepPairs(b, budget)
    local ops = 0
    while ops < budget do
        local key = b.bkeys[b.bi]
        if not key then
            b.phase = "resolve"
            return ops
        end
        local list = b.buck[key]
        local n = #list
        local ii = b.pii or 1
        local jj = b.pjj or (ii + 1)
        while ii <= n - 1 do
            local i = list[ii]
            while jj <= n do
                if ops >= budget then
                    b.pii, b.pjj = ii, jj -- 中斷點：下 tick 從同對續跑
                    return ops
                end
                b.pairScanWork = b.pairScanWork + 1
                if b.pairScanWork > MAX_PAIR_SCAN_WORK then
                    error("pair scan work limit exceeded")
                end
                local j = list[jj]
                if b.gsid[i] ~= b.gsid[j] then -- 同街段對跳過（含自交，vanilla 無自交街）
                    local a, c = i, j
                    if a > c then a, c = c, a end
                    local pk = a * 65536 + c
                    if not b.seenPair[pk] then
                        b.pairWork = b.pairWork + 1
                        if b.pairWork > MAX_PAIR_WORK then
                            error("pair work limit exceeded")
                        end
                        b.seenPair[pk] = true
                        processPair(b, a, c)
                    end
                end
                ops = ops + 1
                jj = jj + 1
            end
            ii = ii + 1
            jj = ii + 1
        end
        b.pii, b.pjj = nil, nil
        b.bi = b.bi + 1
        ops = ops + 1
    end
    return ops
end

local function graphNode(g, x, y)
    -- 量化 join：0.5 格內端點視為同一路口（vanilla 端點 join 61 處實證此精度）
    local key = quantKey(x, y)
    local idx = g.nodeByKey[key]
    if idx then return idx end
    idx = g.nodeCount + 1
    if idx > MAX_GRAPH_NODES then error("graph node key-space limit exceeded") end
    g.nodeCount = idx
    g.nodeByKey[key] = idx
    g.nx[idx], g.ny[idx] = x, y
    g.adjHead[idx] = 0
    return idx
end

local function conservativeMetadata(oldSurface, oldWidth, surface, width)
    local mergedSurface = oldSurface
    if oldSurface ~= surface then mergedSurface = "unknown" end
    local mergedWidth = oldWidth
    if width < oldWidth then mergedWidth = width end
    return mergedSurface, mergedWidth
end

local function graphEdge(g, a, b, len, surface, width)
    if a == b then return end
    local lo, hi = a, b
    if lo > hi then lo, hi = hi, lo end
    local ek = lo * 100000 + hi -- 節點 <100000，數字 key 無碰撞
    -- edgeSeen 存正向槽；反向恆為它 +1（下方成對配置），metadata 兩向同步
    local edge = g.edgeSeen[ek]
    if edge then
        local mergedSurface, mergedWidth = conservativeMetadata(
            g.adjSurface[edge], g.adjWidth[edge], surface, width)
        g.adjSurface[edge], g.adjSurface[edge + 1] = mergedSurface, mergedSurface
        g.adjWidth[edge], g.adjWidth[edge + 1] = mergedWidth, mergedWidth
        return
    end
    local e = g.edgeCount + 1
    g.edgeSeen[ek] = e
    g.adjTo[e], g.adjLen[e], g.adjNext[e] = b, len, g.adjHead[a]
    g.adjSurface[e], g.adjWidth[e] = surface, width
    g.adjHead[a] = e
    local e2 = e + 1
    g.adjTo[e2], g.adjLen[e2], g.adjNext[e2] = a, len, g.adjHead[b]
    g.adjSurface[e2], g.adjWidth[e2] = surface, width
    g.adjHead[b] = e2
    g.edgeCount = e2
end

local function graphSnapSeg(g, x1, y1, x2, y2, a, b2, surface, width)
    if a == b2 then return end
    local lo, hi = a, b2
    if lo > hi then lo, hi = hi, lo end
    local ek = lo * 100000 + hi
    local seg = g.snapSeen[ek]
    if seg then
        g.sSurface[seg], g.sWidth[seg] = conservativeMetadata(
            g.sSurface[seg], g.sWidth[seg], surface, width)
        return
    end
    local s = g.segCount + 1
    g.segCount = s
    g.snapSeen[ek] = s
    g.sx1[s], g.sy1[s], g.sx2[s], g.sy2[s], g.sA[s], g.sB[s] = x1, y1, x2, y2, a, b2
    g.sSurface[s], g.sWidth[s] = surface, width
    local bx1, bx2, by1, by2 = bucketRange(x1, y1, x2, y2, 0) -- snap 有擴圈查詢，不需 pad
    for bx = bx1, bx2 do
        for by = by1, by2 do
            local key = bucketKey(bx, by)
            local list = g.sbuck[key]
            if not list then
                list = {}
                g.sbuck[key] = list
            end
            list[#list + 1] = s
        end
    end
end

-- 階段三：依切點切割段 → 節點/邊/snap 索引
local function stepCut(b, budget)
    local g = b.graph
    if not g then
        g = {
            nodeCount = 0, edgeCount = 0, segCount = 0,
            nx = {}, ny = {}, nodeByKey = {},
            adjHead = {}, adjNext = {}, adjTo = {}, adjLen = {},
            adjSurface = {}, adjWidth = {}, edgeSeen = {},
            sx1 = {}, sy1 = {}, sx2 = {}, sy2 = {}, sA = {}, sB = {},
            sSurface = {}, sWidth = {}, sbuck = {}, snapSeen = {},
            -- A* generation stamp 工作區（findRoute 重用，免每次清表）
            gen = 0, gScore = {}, fromN = {}, fromEdge = {}, stamp = {}, closed = {},
        }
        b.graph = g
    end
    local ops = 0
    while ops < budget do
        local i = b.ci
        if i > b.gn then
            b.phase = "done"
            -- 建圖完成即釋放中間產物（bucket/切點/去重表佔記憶體大頭）
            b.buck, b.bkeys, b.cuts, b.seenPair = nil, nil, nil, nil
            b.epMove, b.epStreet, b.junction, b.epKeys = nil, nil, nil, nil
            b.epOrd, b.epLink = nil, nil
            b.gx1, b.gy1, b.gx2, b.gy2, b.gsid = nil, nil, nil, nil, nil
            b.gwidth, b.gsurface = nil, nil
            return ops
        end
        local x1, y1 = resolveMoved(b, b.gx1[i], b.gy1[i])
        local x2, y2 = resolveMoved(b, b.gx2[i], b.gy2[i])
        local ts = b.cuts[i]
        if not ts then
            local a = graphNode(g, x1, y1)
            local c = graphNode(g, x2, y2)
            local len = sqrt(dist2(x1, y1, x2, y2))
            graphEdge(g, a, c, len, b.gsurface[i], b.gwidth[i])
            graphSnapSeg(g, x1, y1, x2, y2, a, c, b.gsurface[i], b.gwidth[i])
            ops = ops + 3
        else
            -- 依 t 插排（家規禁 table.sort——Kahlua 遞迴 quicksort 已排序輸入
            -- 退化、coroutine 堆疊 3000 上限，verify_mod.py 守衛）
            for si2 = 2, #ts do
                local v = ts[si2]
                local sj = si2 - 1
                while sj >= 1 and ts[sj].t > v.t do
                    ts[sj + 1] = ts[sj]
                    sj = sj - 1
                end
                ts[sj + 1] = v
            end
            -- 節點鏈：moved 起點 → 各切點（pair-time 世界座標）→ moved 終點。
            -- 與前節點距 < CUT_MERGE 的切點跳過（近重合併）；終點節點必建
            -- （端點是 join 身分，其他段共享）——量化撞前節點時 graphEdge 自跳
            local mergeD2 = CUT_MERGE * CUT_MERGE
            local px, py = x1, y1
            local pn = graphNode(g, x1, y1)
            for k = 1, #ts do
                local cut = ts[k]
                if dist2(px, py, cut.x, cut.y) >= mergeD2 then
                    local qn = graphNode(g, cut.x, cut.y)
                    if qn ~= pn then
                        graphEdge(g, pn, qn, sqrt(dist2(px, py, cut.x, cut.y)),
                            b.gsurface[i], b.gwidth[i])
                        graphSnapSeg(g, px, py, cut.x, cut.y, pn, qn,
                            b.gsurface[i], b.gwidth[i])
                        px, py, pn = cut.x, cut.y, qn
                        ops = ops + 3
                    end
                end
            end
            local en = graphNode(g, x2, y2)
            if en ~= pn then
                graphEdge(g, pn, en, sqrt(dist2(px, py, x2, y2)),
                    b.gsurface[i], b.gwidth[i])
                graphSnapSeg(g, px, py, x2, y2, pn, en,
                    b.gsurface[i], b.gwidth[i])
                ops = ops + 3
            end
        end
        b.ci = i + 1
    end
    return ops
end

function NavCore.step(b, budget)
    local spent = 0
    while spent < budget do
        if b.phase == "gate" then
            spent = spent + stepGate(b, budget - spent)
        elseif b.phase == "pairs" then
            spent = spent + stepPairs(b, budget - spent)
        elseif b.phase == "resolve" then
            spent = spent + stepResolve(b, budget - spent)
        elseif b.phase == "cut" then
            spent = spent + stepCut(b, budget - spent)
        else
            return true
        end
    end
    return b.phase == "done"
end

local function queryStep(query, amount)
    query.n = query.n + (amount or 1)
    if query.n > MAX_QUERY_WORK then error("route query work limit exceeded") end
end

-- snap：擴圈搜 bucket，回最多 maxN 個「不同節點對」候選 {segIdx, d2, t, qx, qy}
local function snapCandidates(g, x, y, maxN, query)
    local found = {}
    local nFound = 0
    for r = 1, #SNAP_RING do
        local radius = SNAP_RING[r]
        local bx1, bx2 = floor((x - radius) / BUCKET), floor((x + radius) / BUCKET)
        local by1, by2 = floor((y - radius) / BUCKET), floor((y + radius) / BUCKET)
        for bx = bx1, bx2 do
            for by = by1, by2 do
                local list = g.sbuck[bucketKey(bx, by)]
                if list then
                    for li = 1, #list do
                        queryStep(query, 1)
                        local s = list[li]
                        local d2, t, qx, qy = projPointSeg(x, y,
                            g.sx1[s], g.sy1[s], g.sx2[s], g.sy2[s])
                        if d2 <= radius * radius then
                            -- 插入排序保持 d2 升冪、同節點對去重
                            local dup = false
                            for fi = 1, nFound do
                                local f = found[fi]
                                if (g.sA[f.seg] == g.sA[s] and g.sB[f.seg] == g.sB[s]) then
                                    if d2 < f.d2 then
                                        f.seg, f.d2, f.t, f.qx, f.qy = s, d2, t, qx, qy
                                    end
                                    dup = true
                                    break
                                end
                            end
                            if not dup then
                                nFound = nFound + 1
                                found[nFound] = { seg = s, d2 = d2, t = t, qx = qx, qy = qy }
                            end
                        end
                    end
                end
            end
        end
        -- 湊滿 maxN 才止：首圈命中即停會漏掉「最近段是孤島、次近段在外圈」的
        -- 可達候選（終點候選測試抓到——目標距孤島 5 格在首圈、距主網 25 格在
        -- 次圈，A* 對唯一孤島候選必然 nil）。找不到時照舊掃盡全部圈
        if nFound >= maxN then break end
    end
    -- 插入排序（候選小量；家規禁 table.sort，同上）
    for fi2 = 2, nFound do
        local v = found[fi2]
        local fj = fi2 - 1
        while fj >= 1 and found[fj].d2 > v.d2 do
            found[fj + 1] = found[fj]
            fj = fj - 1
        end
        found[fj + 1] = v
    end
    while #found > maxN do found[#found] = nil end
    return found
end

-- snap ring 全空的 fallback：全段線性掃最近投影，回單一候選（同 snapCandidates
-- 候選結構，直接餵 runAStar）。動機（2026-08-20 實測回報）：軍事基地等深野外
-- 目標離路網超過 SNAP_RING 上限 160 格→整條 noroad 連直線都沒有；改為導到
-- 路網最近點，越野末段由繪製端既有 approach 直線蓋住。O(segCount) 只在
-- rebuild 時跑（6k 段＝微秒級；ring 命中的正常情境不進來）
local function nearestSnap(g, x, y, query)
    local bestD2, bqx, bqy, bt, bseg = huge, nil, nil, nil, nil
    for s = 1, g.segCount do
        queryStep(query, 1)
        local d2v, t, qx, qy = projPointSeg(x, y, g.sx1[s], g.sy1[s], g.sx2[s], g.sy2[s])
        if d2v < bestD2 then
            bestD2, bqx, bqy, bt, bseg = d2v, qx, qy, t, s
        end
    end
    if not bseg then return nil end
    return { seg = bseg, d2 = bestD2, t = bt, qx = bqx, qy = bqy }
end

local function heapPush(hI, hF, idx, f, query)
    queryStep(query, 1)
    local n = #hI + 1
    hI[n], hF[n] = idx, f
    while n > 1 do
        local p = floor(n / 2)
        if hF[p] <= hF[n] then break end
        hI[p], hI[n], hF[p], hF[n] = hI[n], hI[p], hF[n], hF[p]
        n = p
    end
end

local function heapPop(hI, hF, query)
    queryStep(query, 1)
    local size = #hI
    if size == 0 then return nil end
    local topI = hI[1]
    hI[1], hF[1] = hI[size], hF[size]
    hI[size], hF[size] = nil, nil
    size = size - 1
    local n = 1
    while true do
        local l, r = n * 2, n * 2 + 1
        local m = n
        if l <= size and hF[l] < hF[m] then m = l end
        if r <= size and hF[r] < hF[m] then m = r end
        if m == n then break end
        hI[m], hI[n], hF[m], hF[n] = hI[n], hI[m], hF[n], hF[m]
        n = m
    end
    return topI
end

-- 避讓軟封鎖（nav API v3 detour）：邊對堵點圈的線段距離判定。懲罰不是硬移除
-- ——目標貼著堵點時 A* 仍要給路（吃罰照走），有替代路徑時罰額保證繞開。
local AVOID_PENALTY = 100000 -- 十萬米：任何真實繞路都比它便宜
local function segAvoidHit(x1, y1, x2, y2, ax, ay, ar2)
    local dx, dy = x2 - x1, y2 - y1
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 1e-9 then
        t = ((ax - x1) * dx + (ay - y1) * dy) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local qx, qy = x1 + dx * t, y1 + dy * t
    local ddx, ddy = ax - qx, ay - qy
    return ddx * ddx + ddy * ddy <= ar2
end

-- A* objective 與幾何長分離：adjLen/route.len 永遠是實際世界距離；surface
-- 只進 route.cost。未有實機數據前採保守有界倍率 paved/unknown=1、
-- gravel=1.05、dirt=1.10；width 僅暴露 metadata，MiniMap 不知道消費者車型，
-- 不得代替 AutoDrive 決定窄路代價。倍率皆 >=1，heuristic 仍 admissible。
local function edgeTravelCost(len, surface, _width)
    local multiplier = 1.0
    if surface == "gravel" then
        multiplier = 1.05
    elseif surface == "dirt" then
        multiplier = 1.10
    end
    return len * multiplier
end

local function segmentAvoidPenalty(len, x1, y1, x2, y2, avoidX, avoidY, avoidR2)
    if len > 1e-6 and avoidR2
        and segAvoidHit(x1, y1, x2, y2, avoidX, avoidY, avoidR2)
    then
        return AVOID_PENALTY
    end
    return 0
end

-- A*（雙源起點＝snap 段兩端；終點＝臨時節點注入 snap 段兩端後回滾）。
-- 回 route：len＝路網 pts 的幾何長；cost＝只套 surface 倍率的路網段成本；
-- avoidPenalty 另列。三者皆不污染 adjLen，且都不含兩端 approach。
local function runAStar(g, startCand, endCand, tx, ty, avoidX, avoidY, avoidR2, query)
    if type(g.nx) ~= "table" or type(g.ny) ~= "table" or type(g.adjHead) ~= "table"
        or type(g.adjTo) ~= "table" or type(g.adjLen) ~= "table"
        or type(g.adjNext) ~= "table" or type(g.adjSurface) ~= "table"
        or type(g.adjWidth) ~= "table" or type(g.gScore) ~= "table"
        or type(g.fromN) ~= "table" or type(g.fromEdge) ~= "table"
        or type(g.stamp) ~= "table" or type(g.closed) ~= "table"
        or type(g.sA) ~= "table" or type(g.sB) ~= "table"
        or type(g.sSurface) ~= "table" or type(g.sWidth) ~= "table"
        or type(g.gen) ~= "number" or type(g.nodeCount) ~= "number"
        or type(g.edgeCount) ~= "number"
    then
        return nil, "invalid graph SoA"
    end
    local Q = g.nodeCount + 1
    local eBase = g.edgeCount
    local c, d = g.sA[endCand.seg], g.sB[endCand.seg]
    local a, b2 = g.sA[startCand.seg], g.sB[startCand.seg]
    if not c or not d or not a or not b2
        or type(g.nx[c]) ~= "number" or type(g.ny[c]) ~= "number"
        or type(g.nx[d]) ~= "number" or type(g.ny[d]) ~= "number"
        or type(g.nx[a]) ~= "number" or type(g.ny[a]) ~= "number"
        or type(g.nx[b2]) ~= "number" or type(g.ny[b2]) ~= "number"
    then
        return nil, "invalid snap metadata"
    end
    local endSurface, endWidth = g.sSurface[endCand.seg], g.sWidth[endCand.seg]
    local startSurface, startWidth = g.sSurface[startCand.seg], g.sWidth[startCand.seg]
    if not validSurface(endSurface) or not validWidth(endWidth)
        or not validSurface(startSurface) or not validWidth(startWidth)
    then
        return nil, "invalid snap metadata"
    end
    local savedC, savedD = g.adjHead[c], g.adjHead[d]
    local lenQC = sqrt(dist2(endCand.qx, endCand.qy, g.nx[c], g.ny[c]))
    local lenQD = sqrt(dist2(endCand.qx, endCand.qy, g.nx[d], g.ny[d]))
    local gen = g.gen + 1
    local gS, fromN, fromEdge = g.gScore, g.fromN, g.fromEdge
    local stamp, closed = g.stamp, g.closed
    local hI, hF = {}, {}
    local px, py = startCand.qx, startCand.qy
    local lenA = sqrt(dist2(px, py, g.nx[a], g.ny[a]))
    local lenB = sqrt(dist2(px, py, g.nx[b2], g.ny[b2]))
    local gA = edgeTravelCost(lenA, startSurface, startWidth)
        + segmentAvoidPenalty(lenA, px, py, g.nx[a], g.ny[a], avoidX, avoidY, avoidR2)
    local gB = edgeTravelCost(lenB, startSurface, startWidth)
        + segmentAvoidPenalty(lenB, px, py, g.nx[b2], g.ny[b2], avoidX, avoidY, avoidR2)
    local reached = false
    local okSearch, searchErr = pcall(function()
        g.nx[Q], g.ny[Q], g.adjHead[Q] = endCand.qx, endCand.qy, 0
        g.adjTo[eBase + 1], g.adjLen[eBase + 1], g.adjNext[eBase + 1] = Q, lenQC, savedC
        g.adjSurface[eBase + 1], g.adjWidth[eBase + 1] = endSurface, endWidth
        g.adjHead[c] = eBase + 1
        g.adjTo[eBase + 2], g.adjLen[eBase + 2], g.adjNext[eBase + 2] = Q, lenQD, savedD
        g.adjSurface[eBase + 2], g.adjWidth[eBase + 2] = endSurface, endWidth
        g.adjHead[d] = eBase + 2
        g.gen = gen
        stamp[a], gS[a], fromN[a], fromEdge[a], closed[a] = gen, gA, 0, 0, false
        stamp[b2], gS[b2], fromN[b2], fromEdge[b2], closed[b2] = gen, gB, 0, 0, false
        heapPush(hI, hF, a,
            gA + sqrt(dist2(g.nx[a], g.ny[a], endCand.qx, endCand.qy)), query)
        heapPush(hI, hF, b2,
            gB + sqrt(dist2(g.nx[b2], g.ny[b2], endCand.qx, endCand.qy)), query)
        while true do
            local n = heapPop(hI, hF, query)
            if not n then break end
            if not (stamp[n] == gen and closed[n]) then
                if n == Q then
                    reached = true
                    break
                end
                closed[n] = true
                local e = g.adjHead[n]
                local gn = gS[n]
                while e ~= 0 do
                    queryStep(query, 1)
                    local to = g.adjTo[e]
                    local edgeLen = g.adjLen[e]
                    local ng = gn + edgeTravelCost(edgeLen, g.adjSurface[e], g.adjWidth[e])
                        + segmentAvoidPenalty(edgeLen, g.nx[n], g.ny[n], g.nx[to], g.ny[to],
                            avoidX, avoidY, avoidR2)
                    if stamp[to] ~= gen or ng < gS[to] then
                        stamp[to], gS[to], fromN[to], fromEdge[to], closed[to] =
                            gen, ng, n, e, false
                        heapPush(hI, hF, to,
                            ng + sqrt(dist2(g.nx[to], g.ny[to], endCand.qx, endCand.qy)),
                            query)
                    end
                    e = g.adjNext[e]
                end
            end
        end
    end)

    -- 回滾臨時注入（先回滾再組路徑，任何 return 路徑都乾淨）
    g.adjHead[c], g.adjHead[d] = savedC, savedD
    g.adjTo[eBase + 1], g.adjTo[eBase + 2] = nil, nil
    g.adjLen[eBase + 1], g.adjLen[eBase + 2] = nil, nil
    g.adjNext[eBase + 1], g.adjNext[eBase + 2] = nil, nil
    g.adjSurface[eBase + 1], g.adjSurface[eBase + 2] = nil, nil
    g.adjWidth[eBase + 1], g.adjWidth[eBase + 2] = nil, nil
    g.nx[Q], g.ny[Q], g.adjHead[Q] = nil, nil, nil

    if not okSearch then return nil, searchErr end
    if not reached then return nil end
    -- 回溯（節點鏈反向）——fromEdge 保存每一段的 surface/width 身分。
    local chain = {}
    local cn = 0
    local n = Q
    while n ~= 0 do
        cn = cn + 1
        chain[cn] = n
        n = fromN[n]
    end
    local pts, segSurface, segWidth = {}, {}, {}
    local np, routeLen, routeCost, avoidPenalty = 2, 0, 0, 0
    pts[1], pts[2] = px, py -- 起錨（玩家 snap 投影點）
    for i = cn, 1, -1 do
        local node = chain[i]
        local x, y
        if node == Q then
            x, y = endCand.qx, endCand.qy
        else
            x, y = g.nx[node], g.ny[node]
        end
        -- 與前一點重合（起錨=首節點）時跳過，metadata 也不可多一格。
        local prevX, prevY = pts[np - 1], pts[np]
        local edgeLen = sqrt(dist2(prevX, prevY, x, y))
        if edgeLen > 1e-6 then
            local surface, width
            if fromN[node] == 0 then          -- 起點種子：走的是 startCand snap 段
                surface, width = startSurface, startWidth
            elseif node == Q then             -- 注入邊已回滾，改用 endCand snap 段
                surface, width = endSurface, endWidth
            else
                local edge = fromEdge[node]
                surface, width = g.adjSurface[edge], g.adjWidth[edge]
            end
            np = np + 2
            pts[np - 1], pts[np] = x, y
            local segmentIndex = np / 2 - 1
            segSurface[segmentIndex], segWidth[segmentIndex] = surface, width
            routeLen = routeLen + edgeLen
            routeCost = routeCost + edgeTravelCost(edgeLen, surface, width)
            avoidPenalty = avoidPenalty
                + segmentAvoidPenalty(edgeLen, prevX, prevY, x, y, avoidX, avoidY, avoidR2)
        end
    end
    return {
        pts = pts, len = routeLen, cost = routeCost, avoidPenalty = avoidPenalty,
        segSurface = segSurface, segWidth = segWidth, approachSurface = "unknown",
        sx = px, sy = py, ex = endCand.qx, ey = endCand.qy,
        tx = tx, ty = ty,
    }
end

-- 對外：找路。起、終點各取 2 候選（不同節點對）——起點防「玩家在兩路之間先走
-- 反方向」，終點防「最近段是斷連孤島、次近段可達卻回 nil」（codex review）。
-- 總代價含兩端 approach 距離（×approachWeight，缺省 3＝徒步；車上由呼叫端給 12），
-- 取最短。第二回傳＝A* 內部例外（呼叫端 log）
local function findRouteInner(g, sx, sy, tx, ty, avoidX, avoidY, avoidR, approachWeight)
    approachWeight = approachWeight or 3
    if not g or g.nodeCount == 0 then return nil end
    local avoidR2 = nil
    if type(avoidR) == "number" and avoidR > 0
        and type(avoidX) == "number" and type(avoidY) == "number" then
        avoidR2 = avoidR * avoidR
    end
    local query = { n = 0 }
    local starts = snapCandidates(g, sx, sy, 2, query)
    if #starts == 0 then starts[1] = nearestSnap(g, sx, sy, query) end
    if not starts[1] then return nil end
    local ends = snapCandidates(g, tx, ty, 2, query)
    if #ends == 0 then ends[1] = nearestSnap(g, tx, ty, query) end
    if not ends[1] then return nil end
    local best = nil
    for i = 1, #starts do
        for ei = 1, #ends do
            local sc, ec = starts[i], ends[ei]
            local r, err
            if sc.seg == ec.seg then
                -- 起終 snap 同一路段：段內直達（A* 圖上無段中點間的邊，會繞經
                -- 段端折返成 U 形——測試「gate 勝者段」抓到的路徑膨脹）
                local dlen = sqrt(dist2(sc.qx, sc.qy, ec.qx, ec.qy))
                local surface, width = g.sSurface[sc.seg], g.sWidth[sc.seg]
                local avoidPenalty = segmentAvoidPenalty(dlen, sc.qx, sc.qy, ec.qx, ec.qy,
                    avoidX, avoidY, avoidR2)
                r = {
                    pts = { sc.qx, sc.qy, ec.qx, ec.qy },
                    len = dlen, cost = edgeTravelCost(dlen, surface, width),
                    avoidPenalty = avoidPenalty,
                    segSurface = { surface }, segWidth = { width },
                    approachSurface = "unknown",
                    sx = sc.qx, sy = sc.qy, ex = ec.qx, ey = ec.qy,
                    tx = tx, ty = ty,
                }
                if avoidPenalty > 0 then
                    local alternate, alternateErr =
                        runAStar(g, sc, ec, tx, ty, avoidX, avoidY, avoidR2, query)
                    if alternateErr then return nil, alternateErr end
                    if alternate and alternate.cost + alternate.avoidPenalty
                        < r.cost + r.avoidPenalty
                    then
                        r = alternate
                    end
                end
            else
                r, err = runAStar(g, sc, ec, tx, ty, avoidX, avoidY, avoidR2, query)
                if err then return nil, err end
            end
            if r then
                -- 候選 objective＝surface cost＋獨立 avoid penalty＋兩端 approach×權重；
                -- route.len 保持純幾何長，供既有 v1-v3 消費者沿用。
                local cost = r.cost + r.avoidPenalty
                    + approachWeight * (sqrt(dist2(sx, sy, r.sx, r.sy))
                    + sqrt(dist2(tx, ty, r.ex, r.ey)))
                if not best or cost < best._cost then
                    r._cost = cost
                    best = r
                end
            end
        end
    end
    -- snapDist（nav API v4 additive）＝查詢起點到路線首點（起點 snap 投影點）的
    -- 直線距離，即消費者必須越野走完的接線長度；路線品質的單一數字判準。
    -- 純新增欄位，不改任何既有欄位語意（len/cost 照舊不含兩端 approach）
    if best then best.snapDist = sqrt(dist2(sx, sy, best.sx, best.sy)) end
    return best
end

function NavCore.findRoute(g, sx, sy, tx, ty, avoidX, avoidY, avoidR, approachWeight)
    local ok, route, err = pcall(findRouteInner, g, sx, sy, tx, ty, avoidX, avoidY, avoidR, approachWeight)
    if not ok then return nil, route end
    return route, err
end

-- 偏航增量投影：從 fromIdx（點序，1-based）±窗口找玩家到路線的最近投影。
-- 回 (距離, 最佳點序, 投影點 x, y)——窗口外的更近段刻意不找：語意是「離開
-- 目前走廊」。投影點供繪製端做行進裁切（route 從玩家目前進度畫起，approach
-- 連到投影點——不裁切會畫一條從玩家拉回出發錨的回頭直線，codex/claude review）
function NavCore.distToRoute(route, x, y, fromIdx)
    local pts = route.pts
    local np = #pts / 2
    if np < 2 then return huge, 1, pts[1] or 0, pts[2] or 0 end
    local i1 = fromIdx - PROGRESS_WINDOW
    if i1 < 1 then i1 = 1 end
    local i2 = fromIdx + PROGRESS_WINDOW
    if i2 > np - 1 then i2 = np - 1 end
    local bestD2, bestI, bestX, bestY = huge, fromIdx, pts[1], pts[2]
    for i = i1, i2 do
        local d2, _, qx, qy = projPointSeg(x, y,
            pts[i * 2 - 1], pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2])
        if d2 < bestD2 then bestD2, bestI, bestX, bestY = d2, i, qx, qy end
    end
    return sqrt(bestD2), bestI, bestX, bestY
end

-- Railroad 剔除謂詞：英文子串（vanilla 命名「... Railroad (A - B)」與 Railway
-- St 等真街名可區分）∪ vanilla 9 條鐵路的首點幾何簽名——街名翻譯 MOD 把
-- getTranslatedText 換成譯名時（它是官方唯一名稱欄，無原始名可取；codex/grok
-- review）幾何簽名仍命中；且不可改比中文詞：中文資料另有「鐵路街」類真街道
-- 會被誤殺（codex review）。簽名生成自 42.20.3 vanilla streets.xml（round(x*2)
-- ":"round(y*2) 首點量化；再生方法見 scripts/test_nav_route.lua 對應測試）。
-- 已知限制：地圖 MOD 自帶鐵路且非英文 Railroad 命名者漏剔（原設計即如此）
local RAILROAD_SIGS = {
    ["25396:5323"] = true,   -- Louisville Railroad (Doe Valley - Louisville)
    ["25329:8953"] = true,   -- Northern Railroad (Muldraugh - Doe Valley)
    ["23472:20392"] = true,  -- Southern Railroad (Muldraugh - Fort Knox)
    ["22371:27600"] = true,  -- Southern Railroad (Muldraugh - Fort Knox) 南段
    ["20284:28261"] = true,  -- Southwestern Railroad (Fort Knox - Irvington)
    ["1641:23707"] = true,   -- Western Railroad (Ekron - Brandenburg)
    ["5223:28161"] = true,   -- Western Railroad (Irvington - Ekron)
    ["4061:13391"] = true,   -- Indiana Railroad (Brandenburg - Indiana)
    ["4476:13391"] = true,   -- Northwestern Railroad (Muldraugh - Brandenburg)
}
function NavCore.isRailroadStreet(name, x0, y0)
    if type(name) == "string" and name:find("Railroad", 1, true) then return true end
    if type(x0) == "number" and type(y0) == "number" then
        local sig = floor(x0 * 2 + 0.5) .. ":" .. floor(y0 * 2 + 0.5)
        if RAILROAD_SIGS[sig] then return true end
    end
    return false
end

NavCore.projPointSeg = projPointSeg       -- 測試面
NavCore.segCross = segCross
NavCore.cellBoundaryTs = cellBoundaryTs
NavCore.snapCandidates = snapCandidates
NavCore.geometryKey = geometryKey
NavCore.fingerprintKey = fingerprintKey
NavCore.segmentId = segmentId
NavCore.edgeTravelCost = edgeTravelCost
NavCore.graphNode = graphNode
NavCore.addCut = addCut
NavCore.mapTo = mapTo
NavCore.stepResolve = stepResolve
NavCore.gateEmit = gateEmit
NavCore.queryStep = queryStep
-- test:navroute-core:end

Core.validStreetPoints = validStreetPoints
Core.validStreetWidth = validWidth

--------------------------------------------------------------------------------
-- 遊戲整合：抽取器 / winnerOf / OnTick 編譯泵 / ensureRoute / 繪製
--------------------------------------------------------------------------------
local logOnce = {}
local function logf(key, msg)
    if logOnce[key] then return end
    logOnce[key] = true
    print("[MinidoracatMiniMap] NavRoute: " .. msg)
end

-- 引擎狀態機：idle → extracting → building → ready | failed（failed＝本場次
-- 不再重試，直線行為照舊）。idle＋engine.nodata＝上次探測到的容器是空的、
-- per-inner 每秒重試中（見 kickEngine）——idle 不再保證「首個繪製幀必推進」。
-- OnGameStart 重置：客戶端 Lua 進存檔不重載（本 repo 以 OnCreatePlayer/InitPlayer
-- 處理 per-world 狀態的既有慣例即為此），換檔不重置會把上一世界的 graph／failed
-- 帶進新世界（codex/grok review）
local engine = {
    state = "idle", extract = nil, builder = nil, graph = nil,
    patchState = "raw",
    searchState = "ok",
}
local navRoutes = {} -- [pn] = { state="ok|noroad", route=, tx=, ty=, progressIdx=,
                     --          progX=, progY=, lastBuildMs=, buildX=, buildY=,
                     --          failX=, failY= }
                     -- buildX/buildY＝上次 A* 的起點；偏航重算的位移閘門用
-- 行程全程預覽的獨立快取（v6）：宣告在這裡＝與 navRoutes 同受 OnGameStart 世界
-- 重置管轄，但兩張表永不互相讀寫（活動段 identity／進度只屬 navRoutes）。
-- [pn] = { state=, revision=, graph=, weight=, segs=, total=, done=, dist= }
local navPreview = {}

-- 街道覆蓋查詢：dir 優先序取自主檔 getLoadedMapDirs（index 1＝最高）。
-- 鏡像 MapFiles.postLoad/hasCell300（42.20.4 MapFiles.java:120-134）：
-- 街道格原點換算成 256 格 lot，原點與對角 (+1,+1) 兩個 lot 都存在才算覆蓋。
-- WorldMapStreets.initObscuredCells（:155-175）只裁來源自身也佔用的街道格；
-- 來源邊緣未佔用或未知來源維持 fail-open；已認證載體由呼叫端傳 canonicalSrc。
-- 全域 map priority 缺失/拋錯/形狀錯誤仍不可建 ready graph。
-- test:nav-winner:start
local function makeWinnerOf()
    if type(Core.getLoadedMapDirs) ~= "function" then
        return nil, "getLoadedMapDirs missing"
    end
    local ok, dirsMap = pcall(Core.getLoadedMapDirs)
    if not ok then return nil, "getLoadedMapDirs failed: " .. tostring(dirsMap) end
    if type(dirsMap) ~= "table" then return nil, "map priority is not a table" end
    local ordered, seenIndex = {}, {}
    local maxIdx, count = 0, 0
    for dir, idx in pairs(dirsMap) do
        if type(dir) ~= "string" or dir == "" or type(idx) ~= "number"
            or idx < 1 or idx > 1024 or idx % 1 ~= 0 or seenIndex[idx]
        then
            return nil, "map priority shape invalid"
        end
        seenIndex[idx], ordered[idx] = true, dir
        if idx > maxIdx then maxIdx = idx end
        count = count + 1
    end
    if count == 0 then return nil, "map priority empty" end
    local cacheWin, cacheDir = {}, {}
    local function hasStreetCell(dir, cx, cy, key)
        local dk = dir .. ":" .. key
        local has = cacheDir[dk]
        if has == nil then
            local lx = floor(cx * STREET_CELL / LOT_CELL)
            local ly = floor(cy * STREET_CELL / LOT_CELL)
            has = fileExists("media/maps/" .. dir .. "/" .. lx .. "_" .. ly .. ".lotheader")
                and fileExists("media/maps/" .. dir .. "/" .. (lx + 1) .. "_" .. (ly + 1) .. ".lotheader")
            cacheDir[dk] = has
        end
        return has
    end
    return function(cx, cy, src)
        local key = cx * 100000 + cy
        if src and not hasStreetCell(src, cx, cy, key) then return nil end
        local winner = cacheWin[key]
        if winner ~= nil then return winner or nil end
        for i = 1, maxIdx do
            local dir = ordered[i]
            if dir and hasStreetCell(dir, cx, cy, key) then
                cacheWin[key] = dir
                return dir
            end
        end
        cacheWin[key] = false
        return nil
    end
end
Core.makeStreetWinner = makeWinnerOf
-- test:nav-winner:end

-- 先按地圖目錄、再按 byIndex 讀取來源，保留原先去重與每 tick 計數。
-- 每個實體容器只認證一次；來源的完整幾何集合不能由不同容器拼湊。
-- src 保留資源來源，認證成功才另記 canonicalSrc，讓載體路網也受官方實體格覆蓋。
-- 不對玩家地圖 add/clearStreetData；載入由 ensureStreetData 與原版 loader 負責。
-- test:nav-extract:start（scripts/test_nav_kick.lua 抽本區段；依賴 getStreets/getLotDirectories/logf/MAX_STREET_CONTAINERS 由 prelude 注入）
local function beginExtract(mapAPI)
    local streetsAPI = mapAPI:getStreetsAPI()
    if not streetsAPI then return nil end
    if type(getStreets) ~= "function" then
        logf("api", "getStreets global missing (needs PZ 42.20+)")
        return nil
    end
    local total = streetsAPI:getStreetDataCount()
    if total == 0 then
        -- 「這個實例現在沒街道」≠「這個世界沒街道」：小地圖與世界地圖是兩個
        -- 獨立 WorldMap 容器（兩側皆由主檔 ensureStreetData 補載：小地圖 InitPlayer
        -- 、世界地圖每次 ShowWorldMap），任一側空都不得讓引擎進 failed 終態——
        -- 2026-09-05 MP 回報：空側先冷啟動（設目標當幀哪一側先繪製不可控）＝
        -- 該世界導航永久退直線，即使另一側容器是滿的。回 retry 讓另一側／
        -- 稍後重試（節流在 kickEngine）
        logf("nodata", "no street data on this map instance; will retry")
        return nil, true
    end
    if total > MAX_STREET_CONTAINERS then error("street container limit exceeded") end
    local patch = MinidoracatMiniMapRoadPatches
    if type(patch) ~= "table" or patch.schemaVersion ~= 1 or type(patch.tag) ~= "string"
        or type(patch.targetSrc) ~= "string" or patch.targetSrc == ""
        or type(patch.geometrySet) ~= "table" or type(patch.geometryCount) ~= "number"
        or patch.geometryCount < 1 or patch.geometryCount % 1 ~= 0
    then
        patch = nil
    end
    if patch then
        local count = 0
        for fingerprint, compact in pairs(patch.geometrySet) do
            if type(fingerprint) ~= "string" or type(compact) ~= "string" or compact == "" then
                patch = nil
                break
            end
            count = count + 1
        end
        if patch and count ~= patch.geometryCount then patch = nil end
    end
    local officialDir
    local targetLow = patch and patch.targetSrc:lower()
    local list = {}
    local seenRel, seenData = {}, {}
    local dirs = getLotDirectories()
    for i = 1, dirs:size() do
        local dir = dirs:get(i - 1)
        if targetLow and dir:lower() == targetLow and not officialDir then officialDir = dir end
        local rel = "media/maps/" .. dir .. "/streets.xml"
        local relKey = rel:lower()
        if not seenRel[relKey] then
            seenRel[relKey] = true
            local data = streetsAPI:getStreetDataByRelativeFileName(rel)
            if data then
                if #list >= MAX_STREET_CONTAINERS then error("street container limit exceeded") end
                list[#list + 1] = { data = data, src = dir, repeated = seenData[data] }
                seenData[data] = true
            end
        end
    end
    local knownN = #list
    for i = 0, total - 1 do
        if #list >= MAX_STREET_CONTAINERS then error("street container limit exceeded") end
        local data = streetsAPI:getStreetDataByIndex(i)
        list[#list + 1] = { data = data, src = nil, repeated = seenData[data] }
        if data then seenData[data] = true end
    end
    if #list > knownN + knownN then
        logf("unknown", string.format(
            "street containers: %d known by dir, %d total (by-index fallback)",
            knownN, total))
    end
    return {
        list = list, li = 1, si = 0, seenSig = {}, out = {}, outN = 0,
        processedStreetCount = 0, totalSegments = 0, searchNameChars = 0,
        omittedSearchNames = 0,
        patch = patch, officialDir = officialDir, tsBuf = {}, pointReads = 0,
    }
end
-- test:nav-extract:end

-- 抽取分幀：每 tick 有限跨界呼叫（getTranslatedText/getNumPoints/getPointX/Y
-- 全是 Java bridge；同步全抽 ~15k 次 ≈ 數十 ms > 16.7ms 幀預算，會在設目標
-- 當幀掉幀——codex review）。回 true＝抽取完成
local EXTRACT_STREETS_PER_TICK = 48
local function sourceOwnsRoadCells(ex, source, pts)
    for i = 1, #pts - 2, 2 do
        local x1, y1, x2, y2 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        local n = cellBoundaryTs(x1, y1, x2, y2, ex.tsBuf)
        for j = 1, n - 1 do
            local t = (ex.tsBuf[j] + ex.tsBuf[j + 1]) * 0.5
            if ex.wof(floor((x1 + (x2 - x1) * t) / STREET_CELL),
                floor((y1 + (y2 - y1) * t) / STREET_CELL), source) ~= nil then
                return true
            end
        end
    end
    return false
end

local function stepExtract(ex)
    local done = 0
    while done < EXTRACT_STREETS_PER_TICK do
        local entry = ex.list[ex.li]
        if not entry then return true end
        local streets = entry.streets
        if not streets then
            streets = getStreets(entry.data)
            entry.streets, entry.n, entry.outStart = streets, streets:size(), ex.outN
            entry.cert = ex.patch and ex.officialDir and not entry.repeated and entry.src ~= ex.officialDir
            entry.hits, entry.hitSet = 0, entry.cert and {} or nil
        end
        if ex.si >= entry.n then
            if entry.cert and entry.hits == ex.patch.geometryCount then
                for i = entry.outStart + 1, ex.outN do ex.out[i].canonicalSrc = ex.officialDir end
            end
            entry.streets, entry.data, entry.hitSet = nil, nil, nil
            ex.li, ex.si = ex.li + 1, 0
        else
            local st = streets:get(ex.si)
            ex.si, done = ex.si + 1, done + 1
            ex.processedStreetCount = ex.processedStreetCount + 1
            if ex.processedStreetCount > MAX_PROCESSED_STREETS then
                error("processed street limit exceeded")
            end
            local n = st:getNumPoints()
            if n > MAX_POINTS_PER_STREET then error("street point limit/geometry invalid") end
            if n < 2 then
                entry.cert, entry.hitSet = false, nil
                if not logOnce.shortstreet then
                    logf("shortstreet", string.format(
                        "ignoring streets with fewer than 2 points (first source=%s, index=%d, points=%d)",
                        entry.src or "unknown", ex.si - 1, n))
                end
            else
                local originalName = st:getTranslatedText() or ""
                local name = Core.streetDisplayName and Core.streetDisplayName(originalName, entry.src) or originalName
                local repair = Core.streetRepair and Core.streetRepair(st, entry.src, ex.si - 1)
                local replacement = repair and repair.replacementPoints
                local pointCount = replacement and #replacement / 2 or n
                local rawX0, rawY0 = st:getPointX(0), st:getPointY(0)
                local rawXL, rawYL = st:getPointX(n - 1), st:getPointY(n - 1)
                local rawSig = n .. ":" .. floor(rawX0 * 2 + 0.5) .. ":" .. floor(rawY0 * 2 + 0.5)
                    .. ":" .. floor(rawXL * 2 + 0.5) .. ":" .. floor(rawYL * 2 + 0.5)
                local x0 = replacement and replacement[1] or rawX0
                local y0 = replacement and replacement[2] or rawY0
                local xl = replacement and replacement[#replacement - 1] or rawXL
                local yl = replacement and replacement[#replacement] or rawYL
                local sig = pointCount .. ":" .. floor(x0 * 2 + 0.5) .. ":" .. floor(y0 * 2 + 0.5)
                    .. ":" .. floor(xl * 2 + 0.5) .. ":" .. floor(yl * 2 + 0.5)
                if replacement and ex.seenSig[sig] then ex.seenSig[rawSig] = true end
                local duplicate = ex.seenSig[rawSig] or ex.seenSig[sig]
                if not NavCore.isRailroadStreet(originalName, rawX0, rawY0) and (entry.cert or not duplicate) then
                    ex.pointReads = ex.pointReads + pointCount
                    if ex.pointReads > MAX_EXTRACT_POINTS then error("street extraction point limit exceeded") end
                    local pts = {}
                    for pi = 0, pointCount - 1 do
                        pts[pi * 2 + 1] = replacement and replacement[pi * 2 + 1] or st:getPointX(pi)
                        pts[pi * 2 + 2] = replacement and replacement[pi * 2 + 2] or st:getPointY(pi)
                    end
                    local width = st:getWidth()
                    local fingerprint
                    if entry.cert then
                        fingerprint = fingerprintOf(pts, width)
                        if not fingerprint or not ex.patch.geometrySet[fingerprint]
                            or (entry.src and sourceOwnsRoadCells(ex, entry.src, pts)) then
                            entry.cert, entry.hitSet = false, nil
                        elseif not entry.hitSet[fingerprint] then
                            entry.hitSet[fingerprint] = true
                            entry.hits = entry.hits + 1
                        end
                    end
                    if not duplicate then
                        if not fingerprint and (not validStreetPoints(pts) or not validWidth(width)) then
                            error("street geometry/width invalid")
                        end
                        if ex.totalSegments + pointCount - 1 > MAX_RAW_SEGMENTS then
                            error("raw segment limit exceeded")
                        end
                        if ex.outN >= MAX_STREETS then error("street count limit exceeded") end
                        local searchable = true
                        if originalName == name then originalName = nil end
                        local nameChars = #name + (originalName and #originalName or 0)
                        if #name > MAX_STREET_NAME_LENGTH
                            or (originalName and #originalName > MAX_STREET_NAME_LENGTH)
                            or ex.searchNameChars + nameChars > MAX_SEARCH_NAME_CHARS then
                            name, originalName, searchable = "", nil, false
                            ex.omittedSearchNames = ex.omittedSearchNames + 1
                        else
                            ex.searchNameChars = ex.searchNameChars + nameChars
                        end
                        ex.totalSegments = ex.totalSegments + pointCount - 1
                        ex.seenSig[sig], ex.seenSig[rawSig] = true, true
                        ex.outN = ex.outN + 1
                        ex.out[ex.outN] = {
                            name = name, src = entry.src, width = width, pts = pts,
                            originalName = originalName, searchable = searchable,
                        }
                    end
                end
            end
        end
    end
    return false
end

-- 純路網計算在暫停時也要推進：SP 大地圖預設會暫停；其餘狀態 O(1) 早退。
Events.OnTickEvenPaused.Add(function()
    if engine.state == "extracting" then
        if not engine.extract.wof then
            local winner, winnerErr = makeWinnerOf()
            if not winner then
                logf("winner", "map priority unavailable; routing disabled: " .. tostring(winnerErr))
                engine.state, engine.extract = "failed", nil
                return
            end
            engine.extract.wof = winner
        end
        local ok, done = pcall(stepExtract, engine.extract)
        if not ok then
            logf("extract", "street extract failed: " .. tostring(done))
            engine.state = "failed"
            engine.extract = nil
        elseif done then
            local ex = engine.extract
            engine.extract = nil
            if ex.outN == 0 then
                logf("empty", "no usable streets extracted")
                engine.state = "failed"
            else
                engine.searchState = ex.omittedSearchNames > 0 and "degraded" or "ok"
                if ex.omittedSearchNames > 0 then
                    logf("searchdegraded", string.format(
                        "street search degraded: %d over-limit names omitted",
                        ex.omittedSearchNames))
                end
                -- 抽取完整結束後、index 與 builder 之前一次性套 patch。runtime 不讀
                -- XML／不算 SHA；只比 generated full-q2-geometry+width set。任何
                -- mismatch/conflict 都只 log，applyRoadPatches preflight 保證 ex.out
                -- 仍是完全未修改的 raw 表。
                -- pcall 第二回傳：成功時＝applied 布林，拋錯時＝例外訊息
                local patchOk, applied, patchErr = pcall(
                    NavCore.applyRoadPatches, ex.out, ex.patch or MinidoracatMiniMapRoadPatches, ex.officialDir)
                if not patchOk then
                    engine.patchState = "raw"
                    logf("roadpatch", "patch exception; using raw streets: "
                        .. tostring(applied))
                elseif not applied then
                    engine.patchState = "raw"
                    logf("roadpatch", "patch skipped; using raw streets: "
                        .. tostring(patchErr))
                else
                    engine.patchState = "applied"
                    ex.outN = #ex.out
                end
                -- 街名索引（_Search.lua 搜尋用）：每街 {name, low, x, y}（首點）——
                -- graph 不存名稱、builder 完成即棄 streets 表，這裡留輕量索引。
                -- low＝建索引時一次性小寫（review：搜尋端每鍵對 1100 條 lower()
                -- 是每鍵 1100 次字串配置，移到這裡攤平為一次）。
                -- index 與 builder 共用同一 wof；索引逐 nonremoved segment 套與
                -- stepGate 相同的 cell winner，錨點取第一個實際保留子段起點。
                local wof = ex.wof
                local sidx, indexTs = {}, {}
                local sn = 0
                for i = 1, ex.outN do
                    local st = ex.out[i]
                    local ax, ay = NavCore.streetIndexAnchor(st, wof, indexTs)
                    if ax then
                        sn = sn + 1
                        sidx[sn] = {
                            name = st.name, low = st.name:lower(), x = ax, y = ay,
                            sourceDir = st.src,
                            originalLow = st.originalName and st.originalName:lower() or nil,
                        }
                    end
                end
                engine.streetIndex = sidx
                local buildOk, builder = pcall(NavCore.newBuild, ex.out, wof)
                if not buildOk then
                    logf("buildinit", "graph init failed: " .. tostring(builder))
                    engine.state, engine.builder = "failed", nil
                else
                    engine.builder, engine.state = builder, "building"
                end
            end
        end
        return
    end
    if engine.state ~= "building" then return end
    local ok, done = pcall(NavCore.step, engine.builder, STEP_BUDGET)
    if not ok then
        logf("build", "graph build failed: " .. tostring(done))
        engine.state = "failed"
        engine.builder = nil
        return
    end
    if done then
        engine.graph = engine.builder.graph
        engine.builder = nil
        engine.state = "ready"
        local g = engine.graph
        logf("ready", string.format("graph ready: %d nodes, %d snap segs",
            g.nodeCount, g.segCount))
        -- 數字 key 假設的上限告警（seenPair 段 <65536、edgeSeen 節點 <100000）：
        -- 超限不是報錯而是 key 碰撞靜默劣化（claude review）——至少可診斷
        if g.nodeCount > 90000 or g.segCount > 60000 then
            logf("limits", string.format(
                "graph near key-space limits: %d nodes, %d segs", g.nodeCount, g.segCount))
        end
    end
end)

-- 引擎啟動（設目標後首個繪製幀；同步部分只做容器蒐集，重活分幀）。
-- nodata（該實例容器空）：state 維持 idle、engine.nodata=true（_Search 據此顯示
-- 「無結果」而非「載入中」），冷卻 1 秒後可再探測。冷卻**存在 inner 上**
-- （`_minidoracatNavRetryAt`）而非模組 local：同幀多表面（分割畫面 per-player
-- 小地圖／世界地圖＋小地圖）共用一個 deadline 時，空側每次到期先推 deadline
-- 就把滿側永久擋在門外（codex review）；inner 隨世界重建，換世界不需重置。
-- 無街道地圖（多數 MOD 地圖無 streets.xml）代價＝每個 inner 每秒兩次 bridge
-- 探測。getTimestampMs 出處 LuaManager.java:9267-9274（節流範本 forageServer.lua:456-460）
-- test:nav-kick:start（scripts/test_nav_kick.lua 抽本區段；依賴 engine/beginExtract/logf/getTimestampMs 由 prelude 注入）
local function kickEngine(inner)
    if engine.state ~= "idle" then return end
    local mapAPI = inner and inner.mapAPI
    if not mapAPI then return end
    local now = getTimestampMs()
    if now < (inner._minidoracatNavRetryAt or 0) then return end
    local ok, ex, retry = pcall(beginExtract, mapAPI)
    if not ok or not ex then
        if not ok then
            logf("acquire", "street acquire failed: " .. tostring(ex))
        elseif retry == true then -- pcall 失敗時第三回傳是 stack trace，只認 true
            inner._minidoracatNavRetryAt = now + 1000
            engine.nodata = true
            return
        end
        engine.state, engine.nodata = "failed", nil -- 終態，不得殘留 nodata 遮住 failed
        return
    end
    engine.extract, engine.state, engine.nodata = ex, "extracting", nil
end
-- test:nav-kick:end

-- 世界生命週期重置：PZ 同一程序回主選單再進另一存檔時 client Lua 不重載，
-- 引擎單例會把上一世界的 graph／failed 終態帶進新世界（幽靈路網或永久直線）
Events.OnGameStart.Add(function()
    engine.state, engine.extract, engine.builder, engine.graph = "idle", nil, nil, nil
    engine.nodata = nil
    engine.patchState = "raw"
    engine.searchState = "ok"
    engine.streetIndex = nil
    for pn in pairs(navRoutes) do navRoutes[pn] = nil end
    -- 換世界＝預覽整筆丟棄（含開關本身）：新世界的行程與路網都是另一套，
    -- 留著舊段等於在新地圖上畫幽靈線
    for pn in pairs(navPreview) do navPreview[pn] = nil end
    for k in pairs(logOnce) do logOnce[k] = nil end
end)

local function clearRoute(pn)
    navRoutes[pn] = nil
end
Core.navInvalidateRoute = clearRoute

local function failNavEngine(err)
    logf("astar", "route search error; routing disabled this world: " .. tostring(err))
    engine.state, engine.graph, engine.builder = "failed", nil, nil
    for key in pairs(navRoutes) do navRoutes[key] = nil end
end

-- 路線狀態收斂（繪製幀＋OnTick 維護各一條路徑，便宜路徑優先）：target 消失→清；
-- target 變更→重算；增量投影更新行進進度（progressIdx/progX/progY 供裁切繪製），
-- 偏航 >12 格 → 3s 冷卻重算；無路狀態→位移 64 格才重試。目標投影由 _Itinerary
-- 維護，本函式一律以 target 座標與 route 錨點比對收斂，不需要任何寫入通知。
-- key：自己的目標＝pn（數字）；陣營分享目標＝"pn:作者"（字串）——同表混 key
-- test:nav-cache:start（scripts/test_nav_api.lua 抽本區段跑快取／偏航回歸測試）
-- 兩端 approach（越野接線）的權重：徒步 ×3（穿田是合理捷徑）、車上 ×12（車過不了
-- 樹林／圍籬）。2026-09-02 Carpenter Test Road 實爆：目標離該路 3 格、離 Dixie 64 格，
-- ×3 讓「Dixie 上 45 格＋越野 64 格」勝過「繞 KY-60 的 270 格正規路線」，AutoDrive
-- 只能拒啟動（起點太遠）。權重由呼叫端（手上已有 playerObj）算好傳入、記進快取；
-- 上下車換檔＝快取失效立刻重算（不吃冷卻）。
local function approachWeightFor(playerObj)
    return playerObj:getVehicle() and 12 or 3
end
-- v6 行程：活動段「確定」無路／尋路失敗才通知主檔（契約 6.3：暫時未就緒不等於
-- noroad/failed，所以 pending／extracting／building 一律不進來）。
-- **只有非繪製呼叫端可以通知**：主檔會據此暫停行程並存檔，那是狀態變更，
-- 不得由繪製幀觸發（契約 6.1：兩張圖開幾張、重繪幾次都不可改變行程）。
-- 因此 ensureRoute 多一個 notify 旗標——OnTick 的活動段維護與 addon 查詢面
-- （requestRoute）傳 true，drawOneRoute 不傳；requestDetour 只回報該次改道結果。
-- 收斂條件三層：只認數字 key（分享路線的 "pn:作者" 字串 key 不是行程）、
-- 主檔掛得出回呼、且該座標仍是目前活動目標（addon 查非活動目標時不得誤報）。
-- 是否暫停由 _Itinerary 按 phase 判定，本檔只驗活動目標座標。離線測試切片中
-- Core 是未定義全域＝nil，整個通知靜默略過。
local function navLegResult(key, tx, ty, state)
    if type(key) ~= "number" or not (Core and Core.navRouteResult) then return end
    local t = Core.navGetTarget and Core.navGetTarget(key)
    if not t or t.x ~= tx or t.y ~= ty then return end
    Core.navRouteResult(key, state)
end
local function ensureRoute(key, target, px, py, weight, notify)
    local rs = navRoutes[key]
    if not target then
        if rs then clearRoute(key) end
        return nil
    end
    if engine.state ~= "ready" then return nil end -- extracting/building/failed：先畫直線旗標
    local now = getTimestampMs()
    if rs and rs.tx == target.x and rs.ty == target.y and rs.approachWeight == weight then
        if rs.state == "noroad" then
            local fdx, fdy = px - rs.failX, py - rs.failY
            if fdx * fdx + fdy * fdy < NOROAD_RETRY_DIST * NOROAD_RETRY_DIST then
                if notify and not rs.notified then
                    rs.notified = true
                    navLegResult(key, target.x, target.y, "noroad")
                end
                return nil
            end
        elseif rs.route then
            -- 每幀增量投影（±12 段窗，O(25) 投影＝便宜）：progressIdx 單調前進
            -- 為主，投影點是繪製裁切起點——不更新會畫回頭線（codex/claude）
            local d, idx, qx, qy = NavCore.distToRoute(rs.route, px, py, rs.progressIdx or 1)
            rs.progressIdx, rs.progX, rs.progY = idx, qx, qy
            -- snapDist 隨每次查詢刷新成「當下玩家→路線最近點」（就是上一行的偏航 d）：
            -- 沿用快取時建圖當下的值會低報實際接線長度；而拿「玩家→pts[1]」當接線長
            -- （2026-09-02 AutoDrive 實爆）在沿線前進 100 格後停車再啟動會報 100——
            -- 車就在線上卻被 addon 當「起點太遠」拒啟動。首算時 progressIdx=1、
            -- d＝到首點距離，兩種定義相同；之後只有投影距離才是要越野接線的長度。
            rs.route.snapDist = d
            -- 倒車退出首點後，s被夾0，舊線看不見新跑道；由擁有路網的這層重新snap。
            -- 只認投影仍在首段、沿反方向至少一個移動閾值；後段折返到附近不算。
            local behindStart = false
            local pts = rs.route.pts
            if idx == 1 and pts and #pts >= 4 then
                local dx, dy = pts[3] - pts[1], pts[4] - pts[2]
                local length2 = dx * dx + dy * dy
                local along = (px - pts[1]) * dx + (py - pts[2]) * dy
                behindStart = length2 > 1e-12 and along < 0
                    and along * along >= REBUILD_MOVE_DIST * REBUILD_MOVE_DIST * length2
            end
            if d <= DEVIATION_DIST and not behindStart then return rs.route end
            if now - (rs.lastBuildMs or 0) < REBUILD_COOLDOWN_MS then return rs.route end
            -- 原地（或近乎原地）重算必得同一條線：snap 只看座標，位移不足時重跑
            -- A* 只是白燒＋換掉 table identity。深野外目標首點必遠、偏航恆成立，
            -- 沒這道閘就是每 3s 一條幾何相同的新表
            local mdx, mdy = px - (rs.buildX or px), py - (rs.buildY or py)
            if mdx * mdx + mdy * mdy < REBUILD_MOVE_DIST * REBUILD_MOVE_DIST then
                return rs.route
            end
        end
    end
    -- 重算（首算/target 變更/上下車換權重/偏航逾閾/無路重試）
    local route, aerr = NavCore.findRoute(engine.graph, px, py, target.x, target.y,
        nil, nil, nil, weight)
    if aerr then
        -- failed 不在這裡通知：engine 是全域終態，extract／建圖／winner 失敗
        -- 同樣會讓活動段永遠算不出路，卻不經過本函式。統一由 OnTick 的活動段
        -- 維護（見 nav-preview 區段 legStep）對「engine.state == failed 且仍有
        -- 活動目標」的 slot 通知一次，一條路徑、不重送。
        failNavEngine(aerr)
        return nil, "failed"
    end
    if route then route.patchState = engine.patchState end
    if route then
        navRoutes[key] = { state = "ok", route = route, tx = target.x, ty = target.y,
            progressIdx = 1, progX = route.sx, progY = route.sy, lastBuildMs = now,
            buildX = px, buildY = py, approachWeight = weight }
        return route
    end
    -- noroad 首次記 log：MP 實測曾因零診斷輸出無法區分「snap 失敗／A* 斷連／
    -- 繪製剔除」——不 log 就是診斷黑洞
    logf("noroad" .. tostring(key), string.format(
        "no route: player(%d,%d) target(%d,%d) - straight-line flag fallback",
        floor(px), floor(py), floor(target.x), floor(target.y)))
    navRoutes[key] = { state = "noroad", tx = target.x, ty = target.y,
        failX = px, failY = py, approachWeight = weight, notified = notify == true }
    if notify then navLegResult(key, target.x, target.y, "noroad") end
    return nil
end
-- test:nav-cache:end

-- 路線雙層線（深底＋亮青面，同旗標黑框色面美學；青色與自標金旗/分享青旗區分靠
-- 線形 vs 點形）。approach 段（玩家→進度投影點、終錨→目標）細半透明線＝非路網段。
local ROUTE_UNDER = { r = 0.0, g = 0.08, b = 0.12, a = 0.85, w = 5 }
local ROUTE_OVER = { r = 0.05, g = 0.86, b = 1.0, a = 0.9, w = 3 }
-- 分享路線樣式：底層固定深色；面層顏色跟作者旗色（Core.navShareColor 穩定
-- hash——單一分享者＝紅、多人自動輪色，與自己的青色主線明確區分），半透明
-- 細一階。per-author style 表快取（OnGameStart 隨 navRoutes 一併作廢無妨：
-- 表內容只依 author 名，跨世界重算結果相同）
local SHARED_UNDER = { r = 0.0, g = 0.06, b = 0.06, a = 0.5, w = 4 }
local sharedStyleCache = {}
local function sharedOverStyle(author)
    local st = sharedStyleCache[author]
    if not st then
        local cr, cg, cb = 1.0, 0.25, 0.25 -- 掛出缺席時退紅（單人語義）
        if Core.navShareColor then cr, cg, cb = Core.navShareColor(author) end
        st = { r = cr, g = cg, b = cb, a = 0.6, w = 2 }
        sharedStyleCache[author] = st
    end
    return st
end

-- 投影快取（模組級重用，單投影供雙 pass 共用——舊版兩 pass 各投影一次，
-- 跨界呼叫翻倍，claude/grok review）。UI 單執行緒，跨 inner 重用安全
local projX, projY = {}, {}
local wSampX, wSampY = {}, {} -- 抽樣點世界座標（段級剔除判定用；同上重用安全）

-- 世界視窗（uiToWorldX/Y 四角含等角旋轉，取 min/max 成軸對齊 bbox＋margin；
-- 原版用例 ISWorldMap.lua:917 右鍵座標同 API）：段世界 bbox 不相交＝跳過投影
local function drawRoutePolyline(inner, route, mapAPI, startIdx, startX, startY, styleU, styleO)
    local pts = route.pts
    local np = #pts / 2
    if np < 2 then return end
    local w, h = inner.width, inner.height
    -- ppu：兩軸向量長（等角投影下 X 位移同時貢獻 UI x/y，單取 x 低估 ~30%）
    local u0x = mapAPI:worldToUIX(startX, startY)
    local u0y = mapAPI:worldToUIY(startX, startY)
    local u8x = mapAPI:worldToUIX(startX + 8, startY)
    local u8y = mapAPI:worldToUIY(startX + 8, startY)
    local ppu = sqrt(dist2(u0x, u0y, u8x, u8y)) / 8
    if ppu < 1e-6 then return end
    local strideW = 3 / ppu
    -- 世界視窗 bbox：主檔 visibleWorldAABB（四角 uiToWorld 外接框；兩參
    -- uiToWorldY 的 centerWorldY 錯位參數經反編譯終審為死參——UIWorldMapV1
    -- :218-223 走 matrix overload（WorldMapRenderer.java:279-291）body 不用
    -- center，主檔 :2000-2007 同判且 Zone/POI 預裁同函式服役中）。margin 加
    -- strideW（抽樣段最長跨一個步長）；掛出缺席 → 不剔除（fail-open，UI
    -- clipSegment 仍保證畫面正確）
    local vminx, vmaxx, vminy, vmaxy
    if Core.visibleWorldAABB then
        vminx, vmaxx, vminy, vmaxy = Core.visibleWorldAABB(inner)
        local vm = strideW + 16
        vminx, vmaxx, vminy, vmaxy = vminx - vm, vmaxx + vm, vminy - vm, vmaxy + vm
    end
    local cull = vminx ~= nil
    -- 抽樣：只收集抽樣點世界座標（純 Lua 零跨界）；剔除與投影延後到段級
    local pn2 = 0
    local lx, ly = startX, startY
    local acc = 0
    wSampX[1], wSampY[1] = startX, startY
    pn2 = 1
    for i = startIdx + 1, np do
        local x, y = pts[i * 2 - 1], pts[i * 2]
        acc = acc + sqrt(dist2(lx, ly, x, y))
        if acc >= strideW or i == np then
            pn2 = pn2 + 1
            wSampX[pn2], wSampY[pn2] = x, y
            acc = 0
        end
        lx, ly = x, y
    end
    -- 段級剔除＋lazy 投影（2026-08-20 實測修正：舊實作是「點級哨兵」——AABB
    -- 只驗「該抽樣點的前一節」，false 卻同時砍掉以該點為端的前後兩條線；
    -- 「前一節離屏、後一節穿窗」時（拖動/縮放讓上一抽樣點跑遠）後一節被誤砍
    -- ＝路線中段消失。段級＝AABB 用相鄰抽樣點對（恰為實際畫的直線），命中才
    -- 投影、端點投影共享，離屏路段照舊零投影）
    local liveN = 0
    projX[1], projY[1] = nil, nil
    for k = 2, pn2 do
        projX[k], projY[k] = nil, nil
        local ax, ay, bx, by = wSampX[k - 1], wSampY[k - 1], wSampX[k], wSampY[k]
        local sminx, smaxx = ax, bx
        if sminx > smaxx then sminx, smaxx = smaxx, sminx end
        local sminy, smaxy = ay, by
        if sminy > smaxy then sminy, smaxy = smaxy, sminy end
        if not (cull and (smaxx < vminx or sminx > vmaxx or smaxy < vminy or sminy > vmaxy)) then
            if not projX[k - 1] then
                projX[k - 1] = mapAPI:worldToUIX(ax, ay)
                projY[k - 1] = mapAPI:worldToUIY(ax, ay)
            end
            projX[k] = mapAPI:worldToUIX(bx, by)
            projY[k] = mapAPI:worldToUIY(bx, by)
            liveN = liveN + 1
        end
    end
    for k = pn2 + 1, #projX do projX[k] = nil end -- 截尾（上次殘留）
    if cull and liveN == 0 and np - startIdx > 2
        and startX >= vminx and startX <= vmaxx and startY >= vminy and startY <= vmaxy then
        -- 剔除異常診斷：「起點投影在視窗內」卻整條剔光才算異常（AABB 語義若因
        -- 引擎版本漂移失效的症狀是「有路線但不畫」）。玩家把地圖平移去看別處時
        -- 全剔是正常行為，不 log（實測誤報教訓）
        logf("cullall", string.format(
            "route fully culled: view(%.0f..%.0f, %.0f..%.0f) route pts=%d",
            vminx, vmaxx, vminy, vmaxy, np - startIdx))
    end
    -- 雙 pass 畫線（clipSegment 取主檔零配置實作，經 Core 掛出共用單一來源）
    local clip = Core.clipSegment
    for pass = 1, 2 do
        local st = pass == 1 and (styleU or ROUTE_UNDER) or (styleO or ROUTE_OVER)
        for k = 2, pn2 do
            local ax, bxp = projX[k - 1], projX[k]
            if ax and bxp then
                local cx1, cy1, cx2, cy2
                if clip then
                    cx1, cy1, cx2, cy2 = clip(ax, projY[k - 1], bxp, projY[k], w, h)
                else
                    cx1, cy1, cx2, cy2 = ax, projY[k - 1], bxp, projY[k]
                end
                if cx1 then
                    inner:drawLine(nil, cx1, cy1, cx2, cy2, st.w, st.a, st.r, st.g, st.b)
                end
            end
        end
    end
end

local function drawApproach(inner, mapAPI, x1, y1, x2, y2, style)
    -- style 省略＝活動段原本的青色細線；預覽的未來段傳自己的淡樣式，共用同一條
    -- 投影／裁切路徑，不另開第二份繪製實作
    local ux1 = mapAPI:worldToUIX(x1, y1)
    local uy1 = mapAPI:worldToUIY(x1, y1)
    local ux2 = mapAPI:worldToUIX(x2, y2)
    local uy2 = mapAPI:worldToUIY(x2, y2)
    local clip = Core.clipSegment
    local cx1, cy1, cx2, cy2
    if clip then
        cx1, cy1, cx2, cy2 = clip(ux1, uy1, ux2, uy2, inner.width, inner.height)
    else
        cx1, cy1, cx2, cy2 = ux1, uy1, ux2, uy2
    end
    if cx1 then
        if style then
            inner:drawLine(nil, cx1, cy1, cx2, cy2,
                style.w, style.a, style.r, style.g, style.b)
        else
            inner:drawLine(nil, cx1, cy1, cx2, cy2, 1, 0.5, 0.05, 0.86, 1.0)
        end
    end
end

-- 依 key 畫一條路線（含行進裁切與 approach）；回傳是否有畫
local function drawOneRoute(inner, mapAPI, key, target, px, py, weight, styleU, styleO)
    local route = ensureRoute(key, target, px, py, weight)
    if not route then
        -- 無路線（graph 空/建圖失敗/建置中/真 noroad）：畫玩家→目標直線
        -- （同 approach 樣式）——旗標之外至少有方向線（2026-08-20 使用者回饋
        -- 「沒有路徑也沒有斜線」；nearestSnap fallback 後 noroad 僅剩無街道
        -- 資料的極端，建置中 1-3 秒亦先給直線、ready 後自動換路線）
        drawApproach(inner, mapAPI, px, py, target.x, target.y)
        return false
    end
    local rs = navRoutes[key]
    local sIdx = rs and rs.progressIdx or 1
    local sX = rs and rs.progX or route.sx
    local sY = rs and rs.progY or route.sy
    drawRoutePolyline(inner, route, mapAPI, sIdx, sX, sY, styleU, styleO)
    drawApproach(inner, mapAPI, px, py, sX, sY)                     -- 玩家→進度投影
    drawApproach(inner, mapAPI, route.ex, route.ey, target.x, target.y) -- 終錨→目標
    return true
end

--------------------------------------------------------------------------------
-- 全程預覽（v6 多停靠點行程，契約 6.6「路線」節）：剩餘行程的分段形狀預覽。
-- 與活動段徹底分家——只讀 engine.graph、只寫自己的 navPreview[pn]；不進
-- ensureRoute／navRoutes，不呼叫 requestRoute／requestDetour，不把各段拼成
-- 一條 Follower 路線。活動路線的 table identity、progressIdx 與 detour 覆寫
-- 因此完全不受預覽影響。
-- 分段：玩家當下位置 → 第一個 pending → 其後每個 pending；行程上限 16 站＝
-- 最多 16 段。每個 OnTick 全域只算一段（A* 毫秒級，但 16 段同幀＝爆幀預算）。
-- 失效只認三件事：行程 revision、路網 identity（重建／換世界）、徒步/車上
-- approach 權重。玩家移動不失效：預覽是「之後要走的形狀」，實際出發時
-- ensureRoute 會從當下位置另取活動路線（契約：新段不沿用預覽的假定起點），
-- 而第一段每幀都被活動青線覆蓋在上面。
-- 失敗語意：預覽自己的 noroad／A* 例外只標預覽狀態＋log-once 診斷，絕不
-- failNavEngine（會清掉正在行駛那段的快取）、也不走 navLegResult（行駛中的
-- 行程不因未來段算不出來而暫停）。
-- test:nav-preview:start
local PREVIEW_MAX_SEGS = 16 -- 契約 6.2 首版行程上限 16 站
-- 淡青未來線（比活動段 ROUTE_OVER 細一階、半透明）＋深底：與活動青線同色系
-- 但明顯次級，兩者重疊時活動線壓在上面仍清楚可辨
local PREVIEW_UNDER = { r = 0.0, g = 0.06, b = 0.10, a = 0.45, w = 3 }
local PREVIEW_OVER = { r = 0.35, g = 0.78, b = 1.0, a = 0.45, w = 1 }

-- 多站預設顯示剩餘路段，啟用只在非繪製維護節拍。
-- 明確關閉綁目前角色；下次維護發現物件不同或槽位空才移除，不寫存檔。
-- 單站仍可手動開啟。
local previewOff = {}

-- 隱藏／未開啟的地圖也要能泵冷引擎：kickEngine 只要 inner.mapAPI 的 streets
-- 容器，不需要可見表面（同 _Search.lua winRefresh 的既有做法）。小地圖每次取
-- 當下實例（Recreate 會換 inner，存快照＝抱死容器）；世界地圖用單例。
-- 不 add/clearStreetData、不開關任何視窗、不碰玩家地圖狀態。
local function navKickAvailable(pn)
    if engine.state ~= "idle" then return engine.state end
    local mm = getPlayerMiniMap and getPlayerMiniMap(pn)
    local inner = mm and mm.inner
    if inner then kickEngine(inner) end
    if engine.state == "idle" and ISWorldMap_instance then
        kickEngine(ISWorldMap_instance)
    end
    return engine.state
end

local function previewReset(pv)
    pv.segs, pv.total, pv.done, pv.dist = nil, 0, 0, 0
    pv.revision, pv.graph, pv.weight = nil, nil, nil
    pv.noroad = nil
    pv.state = "idle"
end

-- 重排分段（行程／路網／權重任一變動）：只收 pending 站，順序即行程順序。
-- 筆數用行程自己的 trip.count（契約 6.2 的衍生計數，已由主檔驗過連續槽），
-- 不用 # 猜長度。壞座標當場停收（NaN 進 A* 後所有距離比較恆為 false＝白跑
-- 整張路網）。
local function previewPlan(pv, trip, px, py, weight)
    local stops = trip.stops
    local segs, n = {}, 0
    local fx, fy = px, py
    local count = (type(stops) == "table" and type(trip.count) == "number")
        and trip.count or 0
    for i = 1, count do
        local s = stops[i]
        if type(s) == "table" and s.status == "pending" then
            if n >= PREVIEW_MAX_SEGS then break end
            local bx, by = s.x, s.y
            if type(bx) ~= "number" or bx ~= bx or type(by) ~= "number" or by ~= by then
                break
            end
            n = n + 1
            segs[n] = { ax = fx, ay = fy, bx = bx, by = by }
            fx, fy = bx, by
        end
    end
    pv.segs, pv.total, pv.done, pv.dist = segs, n, 0, 0
    pv.noroad = nil
    pv.revision, pv.graph, pv.weight = trip.revision, engine.graph, weight
    pv.state = n > 0 and "pending" or "idle"
end

-- 算一段。distance 逐段累加「路網長＋兩端接線」；沒算完的段一律不入帳，
-- 所以 done < total 時 distance 永遠是「已算出部分」而非完整門到門總長
-- （route.len 不含兩端 approach，契約明令不可直接當總距離）。
local function previewSegment(pv, weight)
    local seg = pv.segs[pv.done + 1]
    local route, aerr = NavCore.findRoute(engine.graph, seg.ax, seg.ay, seg.bx, seg.by,
        nil, nil, nil, weight)
    if aerr then
        -- 只標預覽：不動引擎、不碰行程。done 維持真實完成數——把它推到 total
        -- 等於謊報進度，還會讓繪製端對沒算出的段畫出假直線
        logf("preview", "itinerary preview search error: " .. tostring(aerr))
        pv.state = "failed"
        return
    end
    seg.route = route or false
    if route then
        pv.dist = pv.dist + route.len
            + sqrt(dist2(seg.ax, seg.ay, route.sx, route.sy))
            + sqrt(dist2(route.ex, route.ey, seg.bx, seg.by))
    else
        -- 無路段：距離記直線估計（畫出來的就是這條手動指引線），狀態降 noroad。
        -- 這只是預覽診斷，不代表該站不可達，也不通知行程。
        pv.noroad = true
        pv.dist = pv.dist + sqrt(dist2(seg.ax, seg.ay, seg.bx, seg.by))
    end
    pv.done = pv.done + 1
    if pv.done >= pv.total then pv.state = pv.noroad and "noroad" or "ok" end
end

-- 回 true＝本 tick 的單段預算已用掉
local function previewStep(pn, pv)
    local playerObj = getSpecificPlayer(pn)
    local trip = playerObj and Core.navItineraryState and Core.navItineraryState(pn) or nil
    if not trip then -- 換角色／換世界／沒有行程：不留殘骸
        if pv.segs then previewReset(pv) end
        pv.state = "idle" -- 明寫：上一輪可能停在 disabled/failed，不得黏著
        return false
    end
    -- NavRoute 選項與既有導航 gate（GPS 道具）：路線本身被擋時預覽照算＝白燒
    -- A*，且畫面上也不該出現。兩者都是可恢復的外部條件，故用 disabled 而非
    -- failed（failed 專指本場尋路真的壞了）；條件一恢復下個 tick 就重排。
    if getBoolOption("NavRoute", true) ~= true
        or (Core.navGateAllows and not Core.navGateAllows(pn, "draw"))
    then
        if pv.segs then previewReset(pv) end
        pv.state = "disabled"
        return false
    end
    if engine.state ~= "ready" then
        -- 舊段屬於已作廢的路網，先丟再說；idle 時順手泵一次冷引擎
        if pv.segs then previewReset(pv) end
        pv.state = engine.state == "failed" and "failed" or "idle"
        if engine.state == "idle" then navKickAvailable(pn) end
        return false
    end
    local weight = approachWeightFor(playerObj)
    if pv.revision ~= trip.revision or pv.graph ~= engine.graph or pv.weight ~= weight then
        previewPlan(pv, trip, playerObj:getX(), playerObj:getY(), weight)
    end
    if pv.state == "failed" or pv.done >= pv.total then return false end
    previewSegment(pv, weight)
    return true
end

-- 活動段的非繪製維護（契約 6.1：進度／狀態更新只由非繪製處理）：兩張地圖都
-- 關著時沒有任何繪製幀，ensureRoute 不會被呼叫，「無路」「引擎壞了」就永遠
-- 發現不了，行程會卡在載入中。這裡按固定間隔泵一次：idle→冷啟動、
-- ready→ensureRoute(notify)、failed→通知一次。
-- approach 段不進來：契約 6.3 明令車已停在道路端點後不再尋路、不因無路重複
-- 暫停，只留直線指引。
local LEG_TICKS = 15 -- ~0.25s（繪製開著時本來就每幀收斂，這裡只是關圖時的兜底）
local legTick = 0
local function legStep(pn)
    local t = Core.navGetTarget and Core.navGetTarget(pn)
    if not t then return end
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    local trip = Core.navItineraryState and Core.navItineraryState(pn)
    if trip and trip.phase == "approach" then return end
    if engine.state == "failed" then
        -- 確定失敗（extract／建圖／winner／A* 任一種都收斂到這個終態）
        navLegResult(pn, t.x, t.y, "failed")
        return
    end
    if engine.state == "idle" then
        navKickAvailable(pn)
        return
    end
    if engine.state ~= "ready" then return end
    ensureRoute(pn, t, playerObj:getX(), playerObj:getY(), approachWeightFor(playerObj), true)
end

-- 多站行程的預設啟用（非繪製路徑）：沒有狀態、沒被明確關閉、該槽有角色且
-- 行程有兩站以上就建狀態，之後由 previewStep 照既有節奏一段一段算。
local function previewAuto(pn)
    local playerObj = getSpecificPlayer(pn)
    if previewOff[pn] and previewOff[pn] ~= playerObj then
        previewOff[pn] = nil -- 換角色／換世界：關閉意願不跨角色沿用
    end
    if navPreview[pn] or previewOff[pn] or not playerObj then return end
    local trip = Core.navItineraryState and Core.navItineraryState(pn)
    if trip and type(trip.count) == "number" and trip.count >= 2 then
        navPreview[pn] = { state = "idle", total = 0, done = 0, dist = 0 }
    end
end

-- 活動段失敗會改行程狀態：保留 OnTick，在 _Itinerary 的到站判定之後處理。
Events.OnTick.Add(function()
    legTick = legTick + 1
    if legTick >= LEG_TICKS then
        legTick = 0
        for pn = 0, 3 do legStep(pn) end
    end
end)

-- 預覽是純計算；SP 暫停看圖也要持續排程，不推進站點或控制車輛。
local previewTick = 0
Events.OnTickEvenPaused.Add(function()
    previewTick = previewTick + 1
    if previewTick >= LEG_TICKS then
        previewTick = 0
        for pn = 0, 3 do previewAuto(pn) end
    end
    for pn, pv in pairs(navPreview) do
        if previewStep(pn, pv) then return end
    end
end)

local function previewSlot(pn)
    return type(pn) == "number" and pn == pn and pn % 1 == 0 and pn >= 0 and pn <= 3
end
-- 已算出的段是否仍屬「目前這一版行程＋目前這張路網」。編輯（含到站進度）到
-- 下一個 tick 重排之間必有空窗，讀取面與繪製面都得自己驗一次，否則會端出／
-- 畫出上一版 revision 的結果。權重不在此列：換車/下車只是同一版行程換條更合適
-- 的線，舊線仍是這版行程的形狀。
local function previewStale(pn, pv)
    local trip = Core.navItineraryState and Core.navItineraryState(pn)
    return not trip or pv.revision ~= trip.revision or pv.graph ~= engine.graph
end
-- UI：明確開／關剩餘行程預覽。關＝整筆丟棄（零殘留）＋記下關閉意願（見
-- previewOff：綁當下角色，換角色才失效），不改任何 NavRoute 選項、不碰活動
-- 路線。開＝清掉關閉意願並立刻建狀態（單站行程唯一的開啟途徑）。
-- 回 true＝已套用；false＝壞槽位。
Core.navSetPreview = function(pn, enabled)
    if not previewSlot(pn) then return false end
    if enabled ~= true then
        navPreview[pn] = nil
        previewOff[pn] = getSpecificPlayer(pn)
        return true
    end
    previewOff[pn] = nil
    if not navPreview[pn] then
        navPreview[pn] = { state = "idle", total = 0, done = 0, dist = 0 }
    end
    return true
end
-- UI：回 state, done, total, distance。state＝off（未開）／disabled（NavRoute
-- 選項關）／idle（無行程或路網未就緒）／pending（算到一半）／ok／noroad／failed。
-- distance 只含「已算出的段」，未全就緒時不是完整總距離——UI 以 done==total
-- 且 state=="ok" 判定可否當總長顯示。
Core.navPreviewState = function(pn)
    local pv = previewSlot(pn) and navPreview[pn] or nil
    if not pv then return "off", 0, 0, 0 end
    if pv.segs and previewStale(pn, pv) then return "pending", 0, 0, 0 end
    return pv.state or "idle", pv.done or 0, pv.total or 0, pv.dist or 0
end
Core.navKickAvailable = navKickAvailable
-- test:nav-preview:end

-- 未來段：先畫（活動青線隨後蓋上）。遵守 NavRoute 選項（呼叫端已查）、共用
-- drawRoutePolyline 的視窗剔除／抽樣／clip。approach 只是手動直線指引，
-- 不因此要求道路可達；整段無路者就只有那條直線。
-- test:nav-preview-draw:start（scripts/test_itinerary_routes.lua 抽本區段；
-- drawRoutePolyline／drawApproach 由該測試換成記錄樁，驗兩個表面同一份結果）
local function drawPreview(inner, mapAPI, pn)
    local pv = navPreview[pn]
    if not (pv and pv.segs) then return end
    if previewStale(pn, pv) then return end -- 編輯後的空窗不畫上一版的線
    -- 目前段只由活動線／手動指引畫，避免走過的路與舊改道以預覽殘留。
    local first = Core.navGetTarget(pn) and 2 or 1
    for i = first, pv.done do
        local seg = pv.segs[i]
        local route = seg.route
        if route then
            drawRoutePolyline(inner, route, mapAPI, 1, route.sx, route.sy,
                PREVIEW_UNDER, PREVIEW_OVER)
            drawApproach(inner, mapAPI, seg.ax, seg.ay, route.sx, route.sy, PREVIEW_OVER)
            drawApproach(inner, mapAPI, route.ex, route.ey, seg.bx, seg.by, PREVIEW_OVER)
        else
            drawApproach(inner, mapAPI, seg.ax, seg.ay, seg.bx, seg.by, PREVIEW_OVER)
        end
    end
end
-- test:nav-preview-draw:end

-- 主入口（主檔 drawNavTargets 開頭呼叫＝畫在旗標/箭頭之下；inner＝小地圖 inner
-- 或 ISWorldMap，共用 mapAPI/width/height/playerNum——相容論證同主檔 nav 一節）
local function drawNavRoute(inner)
    if getBoolOption("NavRoute", true) ~= true then return end
    local pn = inner.playerNum or 0
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    local px, py = playerObj:getX(), playerObj:getY()
    local weight = approachWeightFor(playerObj)
    local mapAPI = inner.mapAPI
    -- 未來段先畫：分享線與活動青線隨後蓋上。放在 target 早退之前——draft／
    -- waiting／paused 沒有活動目標，但剩餘行程照樣要看得見
    drawPreview(inner, mapAPI, pn)
    local target = Core.navGetTarget and Core.navGetTarget(pn) or nil
    -- 陣營分享目標的路線（接收方本地各自算路，零網路增量；沙盒閘門在
    -- navGetShared 內）。key 掃除：桶裡消失的作者，其殘留 route 一併清
    local shared = Core.navGetShared and Core.navGetShared(pn) or nil
    local prefix = pn .. ":"
    for k in pairs(navRoutes) do
        if type(k) == "string" and k:sub(1, #prefix) == prefix then
            local author = k:sub(#prefix + 1)
            if not (shared and shared[author]) then navRoutes[k] = nil end
        end
    end
    if shared then
        if engine.state == "idle" then kickEngine(inner) end
        for author, st in pairs(shared) do
            drawOneRoute(inner, mapAPI, prefix .. author, st, px, py, weight,
                SHARED_UNDER, sharedOverStyle(author))
        end
    end
    if not target then
        if navRoutes[pn] then clearRoute(pn) end
        return
    end
    -- approach（車停在道路端點、離站點還有一段越野）：契約 6.3／6.6 明令不再
    -- 尋路——只畫玩家→站點的手動直線指引，不進 ensureRoute（不重算、不重試、
    -- 不再因無路重複回報）。上一段行駛用的快取留著不動，換目標時自然收斂。
    local phase = Core.navItineraryState and Core.navItineraryState(pn)
    phase = phase and phase.phase
    if phase == "approach" then
        drawApproach(inner, mapAPI, px, py, target.x, target.y)
        return
    end
    if engine.state == "idle" then kickEngine(inner) end
    drawOneRoute(inner, mapAPI, pn, target, px, py, weight)
end

Core.drawNavRoute = drawNavRoute
-- _Search.lua：街名索引（ready 前回 nil＝搜尋端顯示載入中）＋引擎冷啟動
-- （搜尋可能發生在玩家從未設過導航目標時）
Core.navStreetIndex = function()
    -- streetIndex 於 extract 完成即建——building 期 graph 還在算但索引已可搜
    -- （review：等 ready 白白多顯示 1-3 秒載入中）；failed＝extract 失敗時本欄
    -- 必 nil、extract 成功後 build 失敗索引仍有效，天然安全
    return engine.streetIndex, engine.searchState
end
Core.navKickEngine = function(inner)
    if engine.state == "idle" then kickEngine(inner) end
    return engine.state
end
-- _Search.lua：唯讀狀態（refresh cache key＋pending 判定）。"nodata"＝idle 但上次
-- 探測到的容器是空的——搜尋端要顯示「無結果」而非永久「載入中」（claude/codex
-- review：retry 語意讓 idle 不再是「還在來的路上」）
Core.navEngineState = function()
    return engine.nodata and "nodata" or engine.state
end
Core.NavRouteCore = NavCore -- 除錯/測試面（離線測試另行抽取原始碼區段）

-- Addon 公開查詢面（nav API v4；首個消費者＝MinidoracatAutoDriveFor42，見
-- docs/plan-autodrive-addon.md M1）。回傳的 route／graph 皆為唯讀本體、不複製；
-- 不寫導航目標、不另建路網。requestRoute 會刻意讀寫主線共用的
-- navRoutes[playerNum] cache（更新進度、必要時 A* 重算），只用來取得玩家目前
-- 導航目標的路線；不得拿它做 speculative／多目標查詢，否則會與 UI 路線交替
-- 覆蓋同一 cache。設目標仍只走 Core.navSetTarget——含 addon 閘門與 modData
-- 持久化的唯一入口。getNavGraph 才是純查詢，回 graph 本體＋唯讀契約，避免每次
-- 複製 ~4k 節點的 SoA 扁平陣列；尾端另回 patchState／searchState。
-- 回 (route, state)：
--   route 保留 v1-v3 { pts,len,sx,sy,ex,ey,tx,ty }；v4 additive 加：
--   segSurface/segWidth（長度恰 #pts/2-1）、數值 cost／avoidPenalty、
--   approachSurface="unknown"、patchState="applied"|"raw"、snapDist。len/cost 均不含
--   兩端 approach，cost 不含 avoidPenalty；raw 表示未套 RoadPatch、仍以原始 streets 導航。
--   snapDist＝玩家當下座標到 pts[1]（起點 snap 投影點）的直線距離，即出發前必須
--   越野走完的接線長度；每次 requestRoute 都刷新（沿用快取時亦然），是路線可用性
--   的單一判準。ensureRoute 的偏航閾值同步收到 DEVIATION_DIST=12，正常情況下
--   snapDist 不會超過一個路幅。
--   state＝"ok"｜"noroad"｜"badargs"｜"noplayer"｜engine 狀態（idle／extracting／
--          building／failed）——皆穩定字串，addon 可直接分支。
-- badargs 從嚴（review 指認）：playerNum 須是 0-3 整數（非整數／越界會讓
-- getSpecificPlayer 拿錯槽／回 nil，錯得無聲）；targetX/Y 須是有限數——NaN／
-- ±Infinity 進 A* 後所有距離比較恆為 false，會白跑完整張路網才回 nil。
-- test:nav-api:start（scripts/test_nav_api.lua 抽本區段跑查詢面回歸測試）
local apiTarget = { x = 0, y = 0 } -- 餵 ensureRoute 的重用暫存（它只讀 x/y、不留參考）
-- 槽位／目標驗證＋玩家與 engine 就緒（requestRoute 與 requestDetour 共用）。
-- NaN 自比不等先擋；±Infinity 由範圍比較擋。engine idle 不在此冷啟動：kickEngine
-- 需要 mapAPI 的 streets 容器，查詢面沒有繪製表面；主線設目標的首個繪製幀會啟動。
local function apiPlayer(playerNum, targetX, targetY)
    if type(playerNum) ~= "number" or playerNum ~= playerNum
        or playerNum < 0 or playerNum > 3 or playerNum % 1 ~= 0
    then
        return nil, "badargs"
    end
    if type(targetX) ~= "number" or type(targetY) ~= "number"
        or targetX ~= targetX or targetY ~= targetY
        or targetX == math.huge or targetX == -math.huge
        or targetY == math.huge or targetY == -math.huge
    then
        return nil, "badargs"
    end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return nil, "noplayer" end
    if engine.state ~= "ready" then return nil, engine.state end
    return playerObj
end
MinidoracatMiniMapAPI.requestRoute = function(playerNum, targetX, targetY)
    local playerObj, argState = apiPlayer(playerNum, targetX, targetY)
    if not playerObj then return nil, argState end
    apiTarget.x, apiTarget.y = targetX, targetY
    -- 查詢面本身是非繪製呼叫（AutoDrive 的控制迴圈），確定無路可以直接通知行程
    local route, routeState = ensureRoute(playerNum, apiTarget,
        playerObj:getX(), playerObj:getY(), approachWeightFor(playerObj), true)
    if routeState or engine.state ~= "ready" then
        return route, routeState or engine.state
    end
    local rs = navRoutes[playerNum]
    return route, rs and rs.state or "noroad"
end
-- 繞開堵點重算（nav API v3；消費者＝AutoDrive addon 的 blocked 改道）。語意同
-- requestRoute，多三個避讓參數：路徑經過 (avoidX,avoidY) 半徑 avoidR 內的路網
-- 邊吃 AVOID_PENALTY 軟封鎖（仍可達：目標貼堵點時照樣給路，有替代就繞）。
-- 成功時**覆寫**該玩家的路線快取——minimap 與後續 requestRoute 沿用 detour 線；
-- target 未變、ensureRoute 不會立刻重算蓋回（偏航／冷卻規則照舊）。
-- 回 (route, state)：state 字彙同 requestRoute。
MinidoracatMiniMapAPI.requestDetour = function(playerNum, targetX, targetY, avoidX, avoidY, avoidR)
    if type(avoidX) ~= "number" or type(avoidY) ~= "number" or type(avoidR) ~= "number"
        or avoidX ~= avoidX or avoidY ~= avoidY or avoidR ~= avoidR
        or avoidX == math.huge or avoidX == -math.huge
        or avoidY == math.huge or avoidY == -math.huge
        or avoidR <= 0 or avoidR == math.huge
    then
        return nil, "badargs"
    end
    local playerObj, argState = apiPlayer(playerNum, targetX, targetY)
    if not playerObj then return nil, argState end
    local px, py = playerObj:getX(), playerObj:getY()
    local weight = approachWeightFor(playerObj)
    local route, aerr = NavCore.findRoute(engine.graph, px, py, targetX, targetY,
        avoidX, avoidY, avoidR, weight)
    if aerr then
        failNavEngine(aerr)
        return nil, "failed"
    end
    if route then route.patchState = engine.patchState end
    if not route then return nil, "noroad" end
    navRoutes[playerNum] = { state = "ok", route = route, tx = targetX, ty = targetY,
        progressIdx = 1, progX = route.sx, progY = route.sy,
        lastBuildMs = getTimestampMs(), buildX = px, buildY = py, approachWeight = weight }
    return route, "ok"
end
MinidoracatMiniMapAPI.getNavGraph = function()
    return engine.graph, engine.state, engine.patchState, engine.searchState
end
-- test:nav-api:end
