-- Full production extraction -> patch -> graph: source names are not geometry identities.
local navPath = arg[1] or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"
local file = assert(io.open(navPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local compile = loadstring or load
local body = assert(source:match("%-%- test:navroute%-core:start\n(.-)\n%-%- test:navroute%-core:end"))
local nav = assert(compile(body .. "\nreturn NavCore", "road-source-core"))()
local canonical = "Muldraugh, KY"
local official = {
    { name = "West Road", width = 8, pts = { 0, 150, 20, 150 } },
    { name = "East Road", width = 8, pts = { 40, 150, 60, 150 } },
    { name = "Long Way", width = 8, pts = { 0, 150, 0, 500, 60, 500, 60, 150 } },
}
local patch = {
    schemaVersion = 1, tag = "source-regression", targetSrc = canonical,
    geometryCount = #official, geometrySet = {},
    removeCount = 0, remove = {}, widthCount = 0, width = {}, surfaceCount = 0, surface = {},
    addCount = 1, add = {
        { id = "missing-link", src = canonical, pts = { 20, 150, 40, 150 }, width = 8, surface = "paved", searchable = false },
    },
    bridgeCount = 0, bridge = {},
}
for i, st in ipairs(official) do patch.geometrySet[nav.fingerprintKey(st)] = "official:" .. i end
local function copyRows(rows, prefix)
    local copy = {}
    for i, st in ipairs(rows) do
        local pts = {}
        for pi, value in ipairs(st.pts) do pts[pi] = value end
        copy[i] = { name = (prefix or "") .. st.name, width = st.width, pts = pts }
    end
    return copy
end
local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local function event()
    local handlers = {}
    return { Add = function(fn) handlers[#handlers + 1] = fn end,
        fire = function() for _, fn in ipairs(handlers) do fn() end end }
end
local function world(sources, dirs, physical, opts)
    opts = opts or {}
    local containers, byRel, loadedDirs, prints = {}, {}, {}, {}
    local reads = 0
    for i, entry in ipairs(sources) do
        local records = {}
        for si, row in ipairs(entry.rows) do
            records[si] = {
                getNumPoints = function() reads = reads + 1; return #row.pts / 2 end,
                getUntranslatedText = function() return row.name end,
                -- 42.21 Translator.getText(raw)；模擬 debug translationPrefix（缺鍵加 "!"）
                getTranslatedText = function() return "!" .. row.name end,
                getWidth = function() return row.width end,
                getPointX = function(_, pi) return row.pts[pi * 2 + 1] end,
                getPointY = function(_, pi) return row.pts[pi * 2 + 2] end,
            }
        end
        local container = { streets = list(records) }
        containers[i] = container
        byRel[("media/maps/" .. entry.dir .. "/streets.xml"):lower()] = container
    end
    for i, dir in ipairs(dirs) do loadedDirs[dir] = i end
    local streetAPI = {
        getStreetDataCount = function() return #containers end,
        getStreetDataByIndex = function(_, i) return containers[i + 1] end,
        getStreetDataByRelativeFileName = function(_, rel) return byRel[rel:lower()] end,
    }
    local tick = event()
    local player = { getX = function() return opts.px or 5 end, getY = function() return opts.py or 150 end,
        getVehicle = function() return {} end }
    local env = setmetatable({
        print = function(line) prints[#prints + 1] = line end,
        Events = { OnTick = event(), OnTickEvenPaused = tick, OnGameStart = event() },
        MinidoracatMiniMapAPI = {}, MinidoracatMiniMapRoadPatches = opts.patch or patch,
        MinidoracatMiniMapCore = { ready = true, getBoolOption = function(_, fallback) return fallback end,
            getLoadedMapDirs = function() return loadedDirs end },
        getLotDirectories = function() return list(dirs) end,
        getStreets = function(data) return data.streets end,
        getSpecificPlayer = function() return player end,
        getTimestampMs = function() return 1000 end,
        fileExists = function(path)
            local dir, x, y = path:match("^media/maps/(.+)/(%-?%d+)_(%-?%d+)%.lotheader$")
            if not dir then return false end
            local owns = physical[dir:lower()]
            return type(owns) == "function" and owns(tonumber(x), tonumber(y)) or owns == true
        end,
    }, { __index = _G })
    if setfenv then
        local chunk = assert(compile(source, "road-source-world"))
        setfenv(chunk, env); chunk()
    else
        assert(load(source, "road-source-world", "t", env))()
    end
    env.MinidoracatMiniMapCore.navKickEngine({ mapAPI = { getStreetsAPI = function() return streetAPI end } })
    local graph, state, patchState, maxReads
    maxReads = 0
    for _ = 1, 10000 do
        local before = reads
        tick.fire()
        maxReads = math.max(maxReads, reads - before)
        graph, state, patchState = env.MinidoracatMiniMapAPI.getNavGraph()
        if state == "ready" or state == "failed" then break end
    end
    assert(state == "ready", "usable source roads must build: " .. tostring(state) .. " " .. table.concat(prints, " | "))
    assert(maxReads <= 48, "source certification must stay in the extraction budget")
    local api = env.MinidoracatMiniMapAPI
    local route, routeState = api.requestRoute(0, opts.qx or 55, opts.qy or 150)
    assert(route and routeState == "ok", "source graph must remain queryable")
    return route, patchState, graph, api, prints
end
local physical = { [canonical:lower()] = true }
local function direct(route, label)
    assert(math.abs(route.len - 50) < 0.01 and route.snapDist < 0.01 and math.abs(route.ex - 55) < 0.01,
        label .. ": missing road patch should connect the 50-square route")
end
local baseline, baselinePatch = world({ { dir = canonical, rows = official } }, { canonical }, physical)
assert(baselinePatch == "applied"); direct(baseline, "vanilla")
local carrier = "Unrelated Language Carrier"
local translated = copyRows(official, "Translated ")
local named, namedPatch = world({ { dir = carrier, rows = translated } }, { carrier, canonical }, physical)
assert(namedPatch == "applied", "a complete named translation source must receive road patches")
direct(named, "named translated source")
local unknown, unknownPatch = world({ { dir = carrier, rows = translated } }, { canonical }, physical)
assert(unknownPatch == "applied", "a complete by-index translation source must receive road patches")
direct(unknown, "unknown translated source")
local mixedCase, mixedCasePatch = world({ { dir = canonical, rows = official } }, { "muldraugh, ky" }, physical)
assert(mixedCasePatch == "applied"); direct(mixedCase, "case-insensitive source identity")
local doubled, doubledPatch = world({ { dir = carrier, rows = translated }, { dir = canonical, rows = official } },
    { carrier, canonical }, physical)
assert(doubledPatch == "applied"); direct(doubled, "two complete copies")
local reverseCopies, reversePatch = world({ { dir = canonical, rows = official }, { dir = carrier, rows = translated } },
    { canonical, carrier }, physical)
assert(reversePatch == "applied"); direct(reverseCopies, "official before translated copy")

-- Separate incomplete sources cannot assemble a false certificate by union.
local partial, partialPatch = world({ { dir = "Part A", rows = { official[1] } },
    { dir = "Part B", rows = { official[2], official[3] } } }, { canonical }, physical)
assert(partialPatch == "raw" and partial.len > 500, "partial source union cannot certify the official dataset")
local drifted = copyRows(official, "Changed ")
drifted[1].width = 9
local drift, driftPatch = world({ { dir = carrier, rows = drifted } }, { carrier, canonical }, physical)
assert(driftPatch == "raw" and drift.len > 500, "geometry/width drift must preserve raw roads rather than force a patch")
local physicalCopy, physicalPatch = world({ { dir = "Physical Map", rows = translated } },
    { "Physical Map", canonical }, { [canonical:lower()] = true, ["physical map"] = true })
assert(physicalPatch == "raw" and physicalCopy.len > 500, "a real map copying official geometry is not a translation carrier")

local extra = copyRows(official)
extra[#extra + 1] = { name = "Custom Road", width = 8, pts = { 1000, 1000, 1100, 1000 } }
local extraRoute, extraPatch = world({ { dir = carrier, rows = extra } }, { carrier, canonical }, physical)
assert(extraPatch == "raw" and extraRoute.len > 500, "a modified superset is not certified as an official copy")
local withShort = copyRows(official)
withShort[#withShort + 1] = { name = "Incomplete Road", width = 8, pts = {} }
local shortRoute, shortPatch = world({ { dir = carrier, rows = withShort } }, { carrier, canonical }, physical)
assert(shortPatch == "raw" and shortRoute.len > 500, "incomplete records cannot strengthen source evidence")
local noOfficial, noOfficialPatch = world({ { dir = carrier, rows = translated } }, { carrier }, physical)
assert(noOfficialPatch == "raw" and noOfficial.len > 500, "a total-conversion world must not borrow an inactive official source")

-- A carrier must not resurrect vanilla roads or added links under a winning map.
local replacement = { { name = "Replacement Road", width = 8, pts = { 0, 100, 60, 100 } } }
local covered, coveredPatch = world({ { dir = "Override", rows = replacement }, { dir = carrier, rows = translated } },
    { "Override", carrier, canonical }, {
        [canonical:lower()] = true,
        override = function(x, y) return x >= 0 and x <= 1 and y >= 0 and y <= 1 end,
    })
assert(coveredPatch == "applied", "unrelated map overrides do not invalidate source geometry certification")
assert(covered.snapDist >= 49, "the winning physical map must mask both carrier roads and generated links")

-- 舊版官方幾何（翻譯載體帶上一版 streets.xml）：patch.legacy 把舊指紋換算回現行街道。
-- Long Way 現行走 y=500；上一版多一個點、沿 y≈480-490 走（點數不同，去重簽名也不同，
-- 同 42.21 Oak St 的真實情形）。認證整包通過才換成現行點列，否則原樣保留。
local LEGACY_PTS = { 0, 150, 0, 480, 30, 490, 60, 480, 60, 150 }
local legacyWay = { name = "Long Way", width = 8, pts = LEGACY_PTS }
patch.legacyCount, patch.legacy = 1, { [nav.fingerprintKey(legacyWay)] = { width = 8, pts = official[3].pts } }
local function legacyRows(prefix)
    local rows = copyRows(official, prefix)
    local pts = {}
    for i, value in ipairs(LEGACY_PTS) do pts[i] = value end
    rows[3] = { name = (prefix or "") .. "Long Way", width = 8, pts = pts }
    return rows
end
-- (30,481) 離舊線約 8.5、離現行 y=500 約 19：終點落在 500 才代表舊線已不在路網裡。
local function endsOnCurrentLongWay(api, label)
    local r = assert(api.requestRoute(0, 30, 481), label .. ": route to the Long Way")
    assert(math.abs(r.ey - 500) < 0.01, label .. ": only the current y=500 Long Way remains, got ey=" .. tostring(r.ey))
end
local stale = legacyRows("Translated ")
local legacyNamed, legacyNamedPatch, _, legacyNamedApi, legacyPrints = world({ { dir = carrier, rows = stale } },
    { carrier, canonical }, physical)
assert(legacyNamedPatch == "applied", "a previous-build carrier must certify through legacy geometry")
direct(legacyNamed, "legacy named carrier")
endsOnCurrentLongWay(legacyNamedApi, "legacy named carrier")
assert(table.concat(legacyPrints, "\n"):find("upgrading 1 previous%-official"), "legacy upgrade is logged")
local legacyUnknown, legacyUnknownPatch, _, legacyUnknownApi = world({ { dir = carrier, rows = stale } }, { canonical }, physical)
assert(legacyUnknownPatch == "applied", "a by-index previous-build carrier must certify")
direct(legacyUnknown, "legacy by-index carrier"); endsOnCurrentLongWay(legacyUnknownApi, "legacy by-index carrier")
-- 官方與舊版載體同時載入（任一順序）：換算後重複的那條丟棄，不得讓 patch 見到同指紋兩次。
for _, order in ipairs({
    { { dir = carrier, rows = stale }, { dir = canonical, rows = official } },
    { { dir = canonical, rows = official }, { dir = carrier, rows = stale } },
}) do
    local both, bothPatch, _, bothApi = world(order, { order[1].dir, order[2].dir }, physical)
    assert(bothPatch == "applied", "official + previous-build carrier (" .. order[1].dir .. " first) must stay applied")
    direct(both, "official + legacy carrier"); endsOnCurrentLongWay(bothApi, "official + legacy carrier")
end
-- 容器沒整包通過就保留原始資料：舊版街先被記下待升級，之後才遇到不符的街，也不得換（fail closed）。
local staleSuperset = legacyRows("Translated ")
staleSuperset[#staleSuperset + 1] = { name = "Custom Road", width = 8, pts = { 1000, 1000, 1100, 1000 } }
local _, staleSupersetPatch, _, staleSupersetApi = world({ { dir = carrier, rows = staleSuperset } },
    { carrier, canonical }, physical)
assert(staleSupersetPatch == "raw", "a previous-build carrier with extra roads must stay raw")
assert(math.abs(staleSupersetApi.requestRoute(0, 30, 481).ey - 500) > 1, "uncertified carrier keeps its raw legacy geometry")
local _, stalePhysicalPatch = world({ { dir = "Physical Map", rows = stale } },
    { "Physical Map", canonical }, { [canonical:lower()] = true, ["physical map"] = true })
assert(stalePhysicalPatch == "raw", "legacy aliases do not turn a real map into a carrier")
local goodLegacy = patch.legacy
patch.legacy = { [nav.fingerprintKey(legacyWay)] = { width = 8, pts = { 0, 150, 0, 490, 60, 490, 60, 150 } } }
local _, corruptPatch = world({ { dir = carrier, rows = stale } }, { carrier, canonical }, physical)
assert(corruptPatch == "raw", "a legacy entry that does not land on a current street fails closed")
patch.legacy = goodLegacy

-- 真資料：正式 RoadPatch 的 geometrySet 反建 42.21 官方街道，再把 legacy 兩條換回 42.20.4
-- 幾何＝統一漢化 v3.35 的載體內容，走完整正式抽取→認證→patch→建圖。
do
    dofile("MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/shared/MinidoracatMiniMapRoadPatches.lua")
    local real = MinidoracatMiniMapRoadPatches
    local function decode(member)
        local geometry, widthQ = member:match("^(.-)|w:(%-?%d+)$")
        local pts, field = {}, 0
        for token in geometry:gmatch("[^:]+") do
            field = field + 1
            if field > 1 then pts[#pts + 1] = assert(tonumber(token)) / 2 end
        end
        return pts, tonumber(widthQ) / 2
    end
    local legacyOf = {}
    for old, entry in pairs(real.legacy) do legacyOf[nav.fingerprintKey(entry)] = old end
    local rows, swapped = {}, 0
    for member in pairs(real.geometrySet) do
        local pts, width = decode(legacyOf[member] or member)
        if legacyOf[member] then swapped = swapped + 1 end
        rows[#rows + 1] = { name = "中文街名 " .. #rows, width = width, pts = pts }
    end
    -- Branch Line（42.21 起歸鐵路、不在 geometrySet）：載體裡是中文名，只能靠首點簽名剔除，
    -- 漏剔就多一條未知街道、整包認證失敗。
    rows[#rows + 1] = { name = "旧马尔德劳车站支线", width = 3, pts = { 11899, 10640, 11874.5, 10615.5, 11874.5, 10480.5,
        11815.5, 10421.5, 11390.5, 10421.5, 11022.5, 10053.5, 11022.5, 9748, 11035.5, 9735, 11035.5, 9587, 11054, 9568.5,
        11098, 9568.5, 11102.5, 9564, 11102.5, 9257, 11102.5, 9123, 11147, 9078.5, 11547, 9078.5, 11575, 9050.5,
        12062, 9050.5, 12105, 9007.5 } }
    assert(swapped == real.legacyCount and swapped == 2, "real carrier carries both 42.20.4 legacy streets")
    -- 玩家站在 42.21 Flaherty Road 新線（x=8104）；舊線在 x=8106。
    local route, realPatch = world({ { dir = "Riverside, KY", rows = rows } }, { "Riverside, KY", canonical }, physical,
        { patch = real, px = 8104, py = 11170, qx = 8104, qy = 11190 })
    assert(realPatch == "applied", "統一漢化 v3.35 內容的載體必須套上正式 RoadPatch")
    assert(route.snapDist < 0.01 and math.abs(route.sx - 8104) < 0.01,
        "Flaherty Road uses the 42.21 alignment after the legacy upgrade, snap=" .. tostring(route.snapDist))
end
print("test_road_sources: PASS (vanilla, named/unknown carriers, complete copies, partial union, drift, physical maps, coverage, legacy carriers, real 42.20.4 carrier)")
