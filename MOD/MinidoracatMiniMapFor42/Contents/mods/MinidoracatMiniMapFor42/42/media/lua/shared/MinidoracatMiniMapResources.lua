-- MinidoracatMiniMapResources.lua — 資源點的兩種版本與公開查詢 API（shared：客戶端與伺服器都載入）
--
-- 版本：
--   "minimap"：離線烘焙的 MinidoracatMiniMapPOIData（gen_poi_data.py 的規則：優先序、住宅門檻、
--              附屬房 10%；每棟一個主類別；只有原版地圖）。
--   "rooms"  ：執行期讀引擎 IsoMetaGrid 的 BuildingDef／RoomDef：一筆 BuildingDef 只要有一間房的名稱
--              在某類 rooms 清單裡就算那一類，一筆可同時屬於多類；涵蓋 Map= 載入的所有地圖（含地圖 MOD）。
--
-- 房間資料的判定單位是引擎的一筆 BuildingDef（lotheader 的一筆紀錄），不合併同一棟的地上／地下紀錄：
-- 和伺服器 getBuildingsIntersecting 同一個單位，也不必在執行期比對全部房間矩形（2026-10-10 設計稿）。
-- 房名照引擎原字串比對：lotheader 原字串不轉小寫（IsoMetaGrid.java:2238-2240），配 loot 也分大小寫
-- （ItemPickerJava.java:571 rooms.containsKey(room.getName())）。
--
-- 掃描：用到才掃（prepare("rooms") 或第一次 rooms 查詢），掛 OnTickEvenPaused 分批做，每 tick 最多
-- SCAN_BUDGET_MS 毫秒（原版約 9 千筆 BuildingDef、8.5 萬間房，一次做完會卡一下）。掃完摘掉事件。
-- 只保留數字，不保留 BuildingDef 參照。換存檔（IsoMetaGrid 換成另一個物件）時重掃。
--
-- 公開契約（版本、守衛範本、回傳形狀）只寫在本機 docs/addon-api.md §3.19。

local SCAN_BUDGET_MS = 4 -- 每 tick 的掃描時間上限（毫秒；getTimestampMs 解析度 1ms）
local CHECK_EVERY = 16   -- 每掃幾筆 BuildingDef 看一次時鐘

-- test:room-resources:start
local roomCat = nil -- 房名 → 類別 key（第一次用到時由 CATEGORIES 建；一個房名只在一類）

local function catTables()
    local C = MinidoracatMiniMapPOICategories
    if type(C) ~= "table" or type(C.CATEGORIES) ~= "table" or type(C.ORDER) ~= "table" then
        return nil, nil
    end
    return C.CATEGORIES, C.ORDER
end

local function roomCatTable()
    if roomCat then return roomCat end
    local cats, order = catTables()
    if not cats then return nil end
    local rc = {}
    for i = 1, #order do
        local key = order[i]
        local def = cats[key]
        local rooms = def and def.rooms
        if type(rooms) == "table" then
            for k = 1, #rooms do
                local name = rooms[k]
                if type(name) == "string" and rc[name] == nil then rc[name] = key end
            end
        end
    end
    roomCat = rc
    return rc
end

-- 一筆 BuildingDef → { x, y, w, h, cats = { [cat] = true }, anchors = { [cat] = { x, y, w, h, basement } } }；
-- 沒有任何類別回 nil。anchors＝該類面積最大的房間矩形（RoomRect，地圖圖標與搜尋落點）。
-- getRooms 不含 emptyoutside 房（BuildingDef.java:98-104）；外框 getX/getY/getW/getH 含（:257-279）。
local function describe(def, rc)
    local rooms = def:getRooms()
    local cats, anchors, best
    for i = 0, rooms:size() - 1 do
        local room = rooms:get(i)
        local name = room:getName()
        local cat = name and rc[name]
        if cat then
            if not cats then cats, anchors, best = {}, {}, {} end
            cats[cat] = true
            local rects = room:getRects()
            for k = 0, rects:size() - 1 do
                local r = rects:get(k)
                local w, h = r:getW(), r:getH()
                if w > 0 and h > 0 and w * h > (best[cat] or 0) then
                    best[cat] = w * h
                    anchors[cat] = { x = r:getX(), y = r:getY(), w = w, h = h, basement = room:getZ() < 0 }
                end
            end
        end
    end
    if not cats then return nil end
    local b = { x = def:getX(), y = def:getY(), w = def:getW(), h = def:getH(), cats = cats, anchors = anchors }
    -- 沒有有效矩形的類別（理論上不會）：落點退回整棟外框
    for cat in pairs(cats) do
        if not anchors[cat] then anchors[cat] = { x = b.x, y = b.y, w = b.w, h = b.h, basement = false } end
    end
    return b
end

local function now()
    local ok, t = pcall(getTimestampMs)
    if ok and type(t) == "number" then return t end
    return 0
end

local scan = { state = "idle", grid = nil, defs = nil, i = 0, total = 0, list = { n = 0 },
    startMs = 0, busyMs = 0, maxTickMs = 0, ticks = 0 }
local scanTick -- 事件 callback（掛上時才有值）

local function finishScan()
    scan.state = "ready"
    scan.defs = nil
    if scanTick and Events and Events.OnTickEvenPaused then Events.OnTickEvenPaused.Remove(scanTick) end
    scanTick = nil
    print("[MinidoracatMiniMap] room resources scanned: " .. tostring(scan.total) .. " buildings, "
        .. tostring(scan.list.n) .. " with categories, busy " .. tostring(scan.busyMs) .. " ms over "
        .. tostring(scan.ticks) .. " ticks (max " .. tostring(scan.maxTickMs) .. " ms/tick), wall "
        .. tostring(now() - scan.startMs) .. " ms")
end

-- 掃一批；回 true＝掃完。budgetMs＝nil 時一次掃完（離線測試）
local function scanStep(budgetMs)
    if scan.state ~= "scanning" then return scan.state == "ready" end
    local rc = roomCatTable()
    local defs, list = scan.defs, scan.list
    local i, total = scan.i, scan.total
    local t0 = now()
    while i < total do
        local def = defs:get(i)
        i = i + 1
        local ok, b = pcall(describe, def, rc)
        if ok and b then
            list.n = list.n + 1
            list[list.n] = b
        end
        if budgetMs and i % CHECK_EVERY == 0 and now() - t0 >= budgetMs then break end
    end
    scan.i = i
    local spent = now() - t0
    scan.busyMs = scan.busyMs + spent
    scan.ticks = scan.ticks + 1
    if spent > scan.maxTickMs then scan.maxTickMs = spent end
    if i >= total then
        finishScan()
        return true
    end
    return false
end

local function currentGrid()
    local ok, grid = pcall(function() return getWorld():getMetaGrid() end)
    if ok then return grid end
    return nil
end

-- 開始（或確認）房間資料掃描；回 true＝已可查詢。世界還沒載入時回 false，下次再呼叫會重試。
local function prepareRooms()
    local grid = currentGrid()
    if not grid then return false end
    if scan.grid == grid and scan.state ~= "idle" then return scan.state == "ready" end
    if not roomCatTable() then return false end
    local ok, defs = pcall(function() return grid:getBuildings() end)
    if not ok or not defs then return false end
    local total = defs:size()
    if total <= 0 then return false end
    if scanTick and Events and Events.OnTickEvenPaused then Events.OnTickEvenPaused.Remove(scanTick) end
    scan = { state = "scanning", grid = grid, defs = defs, i = 0, total = total, list = { n = 0 },
        startMs = now(), busyMs = 0, maxTickMs = 0, ticks = 0 }
    if Events and Events.OnTickEvenPaused then
        scanTick = function() scanStep(SCAN_BUDGET_MS) end
        Events.OnTickEvenPaused.Add(scanTick)
        return false
    end
    return scanStep(nil)
end

-- 小地圖資源版的索引：POIData 每筆一棟、一類；外框＝b（缺時退回 r 的聯集）
local baked = nil
local function bakedIndex()
    if baked then return baked end
    local data = MinidoracatMiniMapPOIData
    local list = { n = 0 }
    -- 筆數用 count（烘焙檔與 poi_blocks.json 匯出同一個欄位），缺時退回 #data
    local count = type(data) == "table" and (type(data.count) == "number" and data.count or #data) or 0
    for i = 1, count do
        local e = data[i]
        local r = type(e) == "table" and e.r
        local r1 = type(r) == "table" and r[1]
        if type(r1) == "table" and type(e.cat) == "string" and type(r1.w) == "number" and r1.w > 0
            and type(r1.h) == "number" and r1.h > 0 then
            local b = e.b
            local x, y, w, h
            if type(b) == "table" and type(b.w) == "number" and b.w > 0 and type(b.h) == "number" and b.h > 0 then
                x, y, w, h = b.x, b.y, b.w, b.h
            else
                local x1, y1, x2, y2 = r1.x, r1.y, r1.x + r1.w, r1.y + r1.h
                for k = 2, (e.rn or 1) do
                    local rk = r[k]
                    if type(rk) == "table" then
                        if rk.x < x1 then x1 = rk.x end
                        if rk.y < y1 then y1 = rk.y end
                        if rk.x + rk.w > x2 then x2 = rk.x + rk.w end
                        if rk.y + rk.h > y2 then y2 = rk.y + rk.h end
                    end
                end
                x, y, w, h = x1, y1, x2 - x1, y2 - y1
            end
            list.n = list.n + 1
            list[list.n] = { x = x, y = y, w = w, h = h, cats = { [e.cat] = true },
                anchors = { [e.cat] = { x = r1.x, y = r1.y, w = r1.w, h = r1.h, basement = e.u == 1 } } }
        end
    end
    baked = list
    return list
end

local function finiteNumber(v)
    return type(v) == "number" and v == v and v > -1e9 and v < 1e9
end

local function copyBuilding(b)
    local cats, anchors = {}, {}
    for cat in pairs(b.cats) do
        cats[cat] = true
        local a = b.anchors[cat]
        anchors[cat] = { x = a.x, y = a.y, w = a.w, h = a.h, basement = a.basement }
    end
    return { x = b.x, y = b.y, w = b.w, h = b.h, cats = cats, anchors = anchors }
end

local API = { resourceApiVersion = 1 }

-- 外框與矩形相交（半開區間 [x, x+w)×[y, y+h)）的建築，回 list, n（list 是副本）；
-- 失敗回 nil, reason："badrect"／"badversion"／"pending"（房間資料還沒掃完，已開始背景掃描）
function API.buildingsIn(x, y, w, h, version)
    if not (finiteNumber(x) and finiteNumber(y) and finiteNumber(w) and finiteNumber(h) and w > 0 and h > 0) then
        return nil, "badrect"
    end
    local list
    if version == "minimap" then
        list = bakedIndex()
    elseif version == "rooms" then
        if not prepareRooms() then return nil, "pending" end
        list = scan.list
    else
        return nil, "badversion"
    end
    local out, n = {}, 0
    local x2, y2 = x + w, y + h
    for i = 1, list.n do
        local b = list[i]
        if b.x < x2 and x < b.x + b.w and b.y < y2 and y < b.y + b.h then
            n = n + 1
            out[n] = copyBuilding(b)
        end
    end
    return out, n
end

-- 一筆 BuildingDef 的類別集合（房間資料版；同步，不需要先掃描）；沒有類別或參數不對回 nil
function API.buildingCategories(def)
    if def == nil then return nil end
    local rc = roomCatTable()
    if not rc then return nil end
    local ok, b = pcall(describe, def, rc)
    if not ok or not b then return nil end
    return b.cats
end

-- 先開始背景掃描；回 true＝這個版本已可查詢（"minimap" 永遠是 true）
function API.prepare(version)
    if version == "minimap" then return true end
    if version == "rooms" then return prepareRooms() end
    return false
end

-- 20 類的副本，照顯示順序：{ key, nameKey, color = { r, g, b }, rooms = { … } }；回 list, n
function API.categories()
    local cats, order = catTables()
    local out, n = {}, 0
    if not cats then return out, 0 end
    for i = 1, #order do
        local key = order[i]
        local def = cats[key]
        if type(def) == "table" then
            local c = def.color or {}
            local rooms = {}
            if type(def.rooms) == "table" then
                for k = 1, #def.rooms do rooms[k] = def.rooms[k] end
            end
            n = n + 1
            out[n] = { key = key, nameKey = def.nameKey, color = { r = c.r, g = c.g, b = c.b }, rooms = rooms }
        end
    end
    return out, n
end
-- test:room-resources:end

MinidoracatMiniMapResourceAPI = API
