-- MinidoracatMiniMapResources.lua — 資源點的兩種版本與公開查詢 API（shared：客戶端與伺服器都載入）
--
-- 版本：
--   "minimap"：離線烘焙的資源點（gen_poi_data.py 的規則：優先序、住宅門檻、附屬房 10%；每棟一個主類別）。
--              原版是 MinidoracatMiniMapPOIData；地圖包等 addon 用 registerMapResources 註冊收錄地圖的資料。
--   "rooms"  ：執行期讀引擎 IsoMetaGrid 的 BuildingDef／RoomDef：一筆 BuildingDef 只要有一間房的名稱
--              在某類 rooms 清單裡就算那一類，一筆可同時屬於多類；涵蓋 Map= 載入的所有地圖（含地圖 MOD）。
--
-- 哪張地圖的烘焙資料算數：照引擎丟建築的同一條規則。一筆資料的建築外框左上角在 300 格的格子
-- (x/300, y/300)；getLotDirectories() 排在它的地圖前面、而且擁有這一格的地圖存在時，引擎丟掉這棟建築
-- （IsoMetaGrid.java:2108-2113、2128-2137），這筆資料也不顯示。「擁有」＝MapFiles.postLoad 的 hasCell300
-- （MapFiles.java:120-134）；Lua 讀不到它，所以原版與註冊地圖的格子清單（cells300）都是離線算好的。
-- 不認識的地圖目錄（地圖包沒收錄）當作不擁有任何格子：它蓋掉原版格子時，原版資源點照舊顯示。
--
-- 別名（registerMapResources 的 aliases）：地圖作者自訂的房名 → 原版房名，沿用該原版房名的類別。
-- 只用在那張地圖擁有的格子（同一個房名在不同地圖可以是不同東西）。房間資料版在掃描時查表；
-- 小地圖資源版的別名已在地圖包烘焙時套用。
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
local CELL = 300         -- 引擎決定建築去留的格子邊長（IsoMetaGrid.java:2108-2109）
local VANILLA_DIR = "Muldraugh, KY" -- POIData 沒寫 mapDir 時（舊資料、離線測試）當作原版目錄

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

-- 房名 → 類別：先查 20 類；查不到，再查這棟所在地圖的別名（自訂房名 → 原版房名）
local function catOf(name, rc, alias)
    if name == nil then return nil end
    local cat = rc[name]
    if cat == nil and alias then
        local target = alias[name]
        if target then cat = rc[target] end
    end
    return cat
end

local function currentGrid()
    local ok, grid = pcall(function() return getWorld():getMetaGrid() end)
    if ok then return grid end
    return nil
end

local warned = {}
local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatMiniMap] " .. msg)
end

--------------------------------------------------------------------------------
-- 地圖資源（resourceApiVersion 3）：原版與註冊地圖都是同一種 spec
-- { mapMod, mapDir, cells300 = { cx, cy, … }, poi = POIData 形狀, parking = ParkingData 形狀, aliasesRaw }
--------------------------------------------------------------------------------
local specs, specCount = {}, 0
local vanillaSpec = nil -- 由 MinidoracatMiniMapPOIData／ParkingData 建，任一資料表換了才重建
local world = nil       -- 目前世界算好的結果（buildWorld）

local function cellSet(list)
    local set = {}
    if type(list) ~= "table" then return set end
    local i = 1
    while list[i] ~= nil do
        local cx, cy = list[i], list[i + 1]
        if type(cx) == "number" and type(cy) == "number" and cx >= 0 and cy >= 0 and cy < 1000 then
            set[cx * 1000 + cy] = true
        end
        i = i + 2
    end
    return set
end

local function cellsOf(s)
    if not s.cells then s.cells = cellSet(s.cells300) end
    return s.cells
end

-- getLotDirectories()：引擎實際載入的地圖目錄，1 號最優先（Java 的 0 號；MapFiles.java:196-243、
-- LuaManager.java:8434-8440）。拿不到或是空的回 nil
local function lotDirs()
    local ok, dirs = pcall(getLotDirectories)
    if not ok or dirs == nil then return nil end
    local okSize, size = pcall(function() return dirs:size() end)
    if not okSize or type(size) ~= "number" then return nil end
    local out, n = {}, 0
    for i = 0, size - 1 do
        local d = dirs:get(i)
        if type(d) == "string" and d ~= "" then
            n = n + 1
            out[n] = d
        end
    end
    if n == 0 then return nil end
    return out, n
end

local function activeModSet()
    local set = {}
    local ok, mods = pcall(getActivatedMods)
    if ok and mods then
        for i = 0, mods:size() - 1 do set[mods:get(i)] = true end
    end
    return set
end

-- 一張地圖的別名，第一次用到時驗證一次：鍵不能已經是 20 類的房名，目標必須是 20 類的房名。
-- 回驗證過的表；沒有可用的別名回 false
local function aliasTable(s, rc)
    if s.aliases ~= nil then return s.aliases end
    if not rc then return false end
    local out, any = {}, false
    if type(s.aliasesRaw) == "table" then
        for name, target in pairs(s.aliasesRaw) do
            if type(name) == "string" and type(target) == "string" and rc[name] == nil and rc[target] ~= nil then
                out[name] = target
                any = true
            else
                warnOnce("alias:" .. s.mapDir .. ":" .. tostring(name), "map resources: alias '" .. tostring(name)
                    .. "' -> '" .. tostring(target) .. "' of map dir '" .. s.mapDir
                    .. "' ignored (the key is a category room or the target is not)")
            end
        end
    end
    s.aliases = any and out or false
    return s.aliases
end

-- 把 data 的條目接到 out 後面；keep(cx, cy) 回 false 的不接。回不接的筆數
local function appendEntries(out, data, keep)
    if type(data) ~= "table" then return 0 end
    local total = type(data.count) == "number" and data.count or #data
    local hidden = 0
    for i = 1, total do
        local e = data[i]
        if type(e) == "table" then
            local ok = true
            if keep then
                local c = e.b
                if type(c) ~= "table" and type(e.r) == "table" then c = e.r[1] end
                ok = type(c) == "table" and type(c.x) == "number" and type(c.y) == "number"
                    and keep(math.floor(c.x / CELL), math.floor(c.y / CELL))
            end
            if ok then
                out.count = out.count + 1
                out[out.count] = e
            else
                hidden = hidden + 1
            end
        end
    end
    return hidden
end

local function currentVanillaSpec()
    local data, parking = MinidoracatMiniMapPOIData, MinidoracatMiniMapParkingData
    if type(data) ~= "table" then data = nil end
    if type(parking) ~= "table" then parking = nil end
    if not data and not parking then return nil end
    if not vanillaSpec or vanillaSpec.poi ~= data or vanillaSpec.parking ~= parking then
        vanillaSpec = { mapDir = data and type(data.mapDir) == "string" and data.mapDir or VANILLA_DIR,
            cells300 = data and data.cells300, poi = data, parking = parking }
    end
    return vanillaSpec
end

-- 這個世界的小地圖資源（原版加已啟用的註冊地圖，照地圖優先序過濾）與別名查表。
-- spans＝每張地圖在 entries 裡的區段 { vanilla, mapMod, mapDir, from, to }（poi_blocks.json 匯出分原版與地圖 MOD 用）。
-- 拿不到地圖目錄（世界還沒載入、離線測試）時照舊只有原版、全部保留；這種結果不快取，下次再算。
local function buildWorld(grid)
    local w = { grid = grid, final = false, entries = { count = 0 }, parking = { count = 0 }, order = {},
        anyAlias = false, spans = { count = 0 } }
    local vanilla = currentVanillaSpec()
    local dirs, n = lotDirs()
    if not dirs then
        if vanilla then
            appendEntries(w.entries, vanilla.poi, nil)
            appendEntries(w.parking, vanilla.parking, nil)
            w.spans.count = 1
            w.spans[1] = { vanilla = true, from = 1, to = w.entries.count }
        end
        return w
    end
    w.final = true
    local active = activeModSet()
    -- 目錄 → 這個世界用的 spec；同一個目錄有兩個啟用中的註冊（例：同名資料夾的兩個地圖 MOD）就都不用
    local byDir = {}
    if vanilla then byDir[vanilla.mapDir] = vanilla end
    for i = 1, specCount do
        local s = specs[i]
        if active[s.mapMod] then
            local prev = byDir[s.mapDir]
            if prev == nil then
                byDir[s.mapDir] = s
            elseif prev ~= false then
                byDir[s.mapDir] = false
                warnOnce("dupdir:" .. s.mapDir, "map resources: more than one active registration for map dir '"
                    .. s.mapDir .. "'; ignoring all of them")
            end
        end
    end
    local order, m = w.order, 0
    for i = 1, n do
        local s = byDir[dirs[i]]
        if s then
            m = m + 1
            order[m] = s
        end
    end
    local memo = {}
    -- 擁有這一格、排最前的地圖序號；沒有任何已知地圖擁有回 m + 1
    local function topRank(cx, cy)
        local k = cx * 1000 + cy
        local t = memo[k]
        if t == nil then
            t = m + 1
            for i = 1, m do
                if cellsOf(order[i])[k] then
                    t = i
                    break
                end
            end
            memo[k] = t
        end
        return t
    end
    w.topRank = topRank
    local rc = roomCatTable()
    local report = ""
    for i = 1, m do
        local s = order[i]
        local before = w.entries.count
        -- 排在前面的地圖都不擁有這一格，引擎才會留下這張地圖的建築
        local function keep(cx, cy) return topRank(cx, cy) >= i end
        local hidden = appendEntries(w.entries, s.poi, keep)
        appendEntries(w.parking, s.parking, keep)
        w.spans.count = i
        w.spans[i] = { vanilla = s == vanilla, mapMod = s.mapMod, mapDir = s.mapDir, from = before + 1,
            to = w.entries.count }
        if s ~= vanilla and aliasTable(s, rc) then w.anyAlias = true end
        report = report .. (i > 1 and "; " or "") .. s.mapDir .. " " .. tostring(w.entries.count - before)
            .. (hidden > 0 and (" (" .. tostring(hidden) .. " hidden by map priority)") or "")
    end
    print("[MinidoracatMiniMap] map resources: " .. tostring(m) .. " maps with data in this world ("
        .. tostring(specCount) .. " registered), " .. tostring(w.entries.count) .. " minimap POIs, "
        .. tostring(w.parking.count) .. " parking areas: " .. report)
    return w
end

local function currentWorld()
    local grid = currentGrid()
    if world == nil or not world.final or world.grid ~= grid then world = buildWorld(grid) end
    return world
end

-- 這棟建築所在格子的地圖別名；沒有回 nil
local function aliasFor(w, def)
    if not w.anyAlias then return nil end
    local s = w.order[w.topRank(math.floor(def:getX() / CELL), math.floor(def:getY() / CELL))]
    return s and s.aliases or nil
end

-- 一筆 BuildingDef → { x, y, w, h, cats = { [cat] = true }, anchors = { [cat] = { x, y, w, h, basement } } }；
-- 沒有任何類別回 nil。anchors＝該類面積最大的房間矩形（RoomRect，地圖圖標與搜尋落點）。
-- getRooms 不含 emptyoutside 房（BuildingDef.java:98-104）；外框 getX/getY/getW/getH 含（:257-279）。
-- w：currentWorld()，查這棟的地圖別名；nil＝不查
local function describe(def, rc, w)
    local alias = w and aliasFor(w, def) or nil
    local rooms = def:getRooms()
    local cats, anchors, best
    for i = 0, rooms:size() - 1 do
        local room = rooms:get(i)
        local cat = catOf(room:getName(), rc, alias)
        if cat then
            if not cats then cats, anchors, best = {}, {}, {} end
            cats[cat] = true
            local rects = room:getRects()
            for k = 0, rects:size() - 1 do
                local r = rects:get(k)
                local rw, rh = r:getW(), r:getH()
                if rw > 0 and rh > 0 and rw * rh > (best[cat] or 0) then
                    best[cat] = rw * rh
                    anchors[cat] = { x = r:getX(), y = r:getY(), w = rw, h = rh, basement = room:getZ() < 0 }
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
    local w = currentWorld()
    local defs, list = scan.defs, scan.list
    local i, total = scan.i, scan.total
    local t0 = now()
    while i < total do
        local def = defs:get(i)
        i = i + 1
        local ok, b = pcall(describe, def, rc, w)
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

-- 小地圖資源版的索引：合併清單每筆一棟、一類；外框＝b（缺時退回 r 的聯集）
local baked, bakedFrom = nil, nil
local function bakedIndex()
    local w = currentWorld()
    if baked and bakedFrom == w then return baked end
    local data = w.entries
    local list = { n = 0 }
    for i = 1, data.count do
        local e = data[i]
        local r = type(e) == "table" and e.r
        local r1 = type(r) == "table" and r[1]
        if type(r1) == "table" and type(e.cat) == "string" and type(r1.w) == "number" and r1.w > 0
            and type(r1.h) == "number" and r1.h > 0 then
            local b = e.b
            local x, y, bw, bh
            if type(b) == "table" and type(b.w) == "number" and b.w > 0 and type(b.h) == "number" and b.h > 0 then
                x, y, bw, bh = b.x, b.y, b.w, b.h
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
                x, y, bw, bh = x1, y1, x2 - x1, y2 - y1
            end
            list.n = list.n + 1
            list[list.n] = { x = x, y = y, w = bw, h = bh, cats = { [e.cat] = true },
                anchors = { [e.cat] = { x = r1.x, y = r1.y, w = r1.w, h = r1.h, basement = e.u == 1 } } }
        end
    end
    baked, bakedFrom = list, w
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

local API = { resourceApiVersion = 4 }

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

-- 整區外框 b 與矩形相交（半開區間）的停車區（v4），回 list, n（list 是副本）；失敗回 nil, "badrect"。
-- 讀和停車場圖層同一份合併清單（地圖優先序已過濾），也跳過圖層不畫的區（沒有 b 或沒有一排有效的車位）。
-- 每筆 { x, y, w, h, rows = { { x, y, w, h }, … }, rowCount }：x,y,w,h＝整區外框 b，rows＝各排車位 r
function API.parkingIn(x, y, w, h)
    if not (finiteNumber(x) and finiteNumber(y) and finiteNumber(w) and finiteNumber(h) and w > 0 and h > 0) then
        return nil, "badrect"
    end
    local function valid(c)
        return type(c) == "table" and type(c.x) == "number" and type(c.y) == "number"
            and type(c.w) == "number" and type(c.h) == "number" and c.w > 0 and c.h > 0
    end
    local data = currentWorld().parking
    local out, n = {}, 0
    local x2, y2 = x + w, y + h
    for i = 1, data.count do
        local e = data[i]
        local b, r = e.b, e.r
        if valid(b) and type(r) == "table" and type(e.rn) == "number"
            and b.x < x2 and x < b.x + b.w and b.y < y2 and y < b.y + b.h then
            local rows, rc = {}, 0
            for k = 1, e.rn do
                local c = r[k]
                if valid(c) then
                    rc = rc + 1
                    rows[rc] = { x = c.x, y = c.y, w = c.w, h = c.h }
                end
            end
            if rc > 0 then
                n = n + 1
                out[n] = { x = b.x, y = b.y, w = b.w, h = b.h, rows = rows, rowCount = rc }
            end
        end
    end
    return out, n
end

-- 一筆 BuildingDef 的類別集合（房間資料版，含這棟所在地圖的別名；同步，不需要先掃描）；
-- 沒有類別或參數不對回 nil
function API.buildingCategories(def)
    if def == nil then return nil end
    local rc = roomCatTable()
    if not rc then return nil end
    local ok, b = pcall(describe, def, rc, currentWorld())
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

-- 註冊一張地圖的資源資料（v3；地圖包在 shared 載入時呼叫，客戶端與伺服器都要註冊）。
-- spec＝{ mapMod, mapDir, cells300 = { cx, cy, … }, poi = 和 MinidoracatMiniMapPOIData 同形狀|nil,
--        parking = 和 MinidoracatMiniMapParkingData 同形狀|nil（v3 起）,
--        aliases = { [自訂房名] = 原版房名 }|nil }。回 true；參數不對回 false, reason，只 log 一次、不丟錯
function API.registerMapResources(ownerModId, spec)
    if type(ownerModId) ~= "string" or ownerModId == "" then
        warnOnce("reg:badowner", "registerMapResources: ownerModId must be a non-empty string")
        return false, "badowner"
    end
    if type(spec) ~= "table" or type(spec.mapMod) ~= "string" or spec.mapMod == ""
        or type(spec.mapDir) ~= "string" or spec.mapDir == "" or type(spec.cells300) ~= "table"
        or (spec.poi ~= nil and type(spec.poi) ~= "table")
        or (spec.parking ~= nil and type(spec.parking) ~= "table")
        or (spec.aliases ~= nil and type(spec.aliases) ~= "table") then
        warnOnce("reg:badspec:" .. ownerModId, "registerMapResources(" .. ownerModId
            .. "): spec needs mapMod, mapDir, cells300 and optional poi/parking/aliases tables; ignored")
        return false, "badspec"
    end
    specCount = specCount + 1
    specs[specCount] = { owner = ownerModId, mapMod = spec.mapMod, mapDir = spec.mapDir,
        cells300 = spec.cells300, poi = spec.poi, parking = spec.parking, aliasesRaw = spec.aliases }
    world = nil
    scan.grid = nil -- 房間資料要用新的別名重掃（下一次 prepare／查詢時重新開始）
    return true
end
-- test:room-resources:end

MinidoracatMiniMapResourceAPI = API
-- 主 MOD 內部用（client 的資源點／停車場繪製與搜尋）：小地圖資源版的合併清單，形狀同 MinidoracatMiniMapPOIData
-- ／MinidoracatMiniMapParkingData（陣列＋count），唯讀、不複製。不是公開 API：addon 用 buildingsIn／parkingIn。
MinidoracatMiniMapResources = {
    minimapEntries = function() return currentWorld().entries end,
    parkingEntries = function() return currentWorld().parking end,
    -- poi_blocks.json 匯出用：回 (spans, entries)，spans[i] 是第 i 張地圖在 entries 的 from..to（見 buildWorld）
    minimapSpans = function()
        local w = currentWorld()
        return w.spans, w.entries
    end,
}
