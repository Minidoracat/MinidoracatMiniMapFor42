-- 自訂道路併進導航路網的離線回歸（設計稿 plan-minimap-custom-roads-1023 主張 1.2／1.4／5.1）。
-- 甲、抽 _NavRoute.lua 的 navroute-core 區段：吸附與釘住、CUSTOM_SLACK、pn 遮罩、segCustom、
--     零官方街道、加了自訂道路後官方路線逐點不變。
-- 乙、整檔載入（隔離 env，仿 test_nav_kick 11+）：重建生命週期——防抖、換圖後路線快取換新表、
--     重建中又改路、失敗保留舊圖並只告訴玩家一次、換世界丟 pending、nodata／零官方街道。
-- 用法：lua scripts/test_nav_custom_roads.lua [_NavRoute.lua 路徑]
local srcPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"

local file = assert(io.open(srcPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local compile = loadstring or load
local body = assert(source:match("%-%- test:navroute%-core:start\n(.-)\n%-%- test:navroute%-core:end"),
    "找不到 navroute-core 測試區段")
local mod = assert(compile(body .. "\nreturn NavCore\n", "navroute-core"))()

local function road(pts, opts)
    opts = opts or {}
    local sw, ss = {}, {}
    for k = 1, #pts / 2 - 1 do sw[k], ss[k] = opts.width or 4, opts.surface or "dirt" end
    return {
        road = { name = opts.name or "Custom", pts = pts, segWidth = sw, segSurface = ss,
            ends = opts.ends or { "snap", "snap" } },
        usableBy = opts.mask or 1, ownerPn = opts.owner, roadId = opts.id,
    }
end

local function official(pts, width, name)
    return { name = name or "Official", src = "M", width = width or 4, pts = pts }
end

local function build(streetsIn, entries, winnerOf, budget)
    local streets = {}
    for i = 1, #streetsIn do streets[i] = streetsIn[i] end
    if entries then
        local added, skipped = mod.customStreets(entries, streets)
        assert(skipped == 0 and added == #entries, "fixture 的自訂道路都要合法")
    end
    local b = mod.newBuild(streets, winnerOf)
    for _ = 1, 1000000 do
        if mod.step(b, budget or 37) then return b.graph end
    end
    error("build 未完成")
end

local function nodeAt(g, x, y)
    for i = 1, g.nodeCount do
        if math.abs(g.nx[i] - x) < 1e-6 and math.abs(g.ny[i] - y) < 1e-6 then return i end
    end
    return nil
end

local function passes(r, x, y)
    for i = 1, #r.pts, 2 do
        if math.abs(r.pts[i] - x) < 1e-6 and math.abs(r.pts[i + 1] - y) < 1e-6 then return true end
    end
    return false
end

local function find(g, sx, sy, tx, ty, pn)
    return mod.findRoute(g, sx, sy, tx, ty, nil, nil, nil, 12, nil, nil, pn)
end

local function customCount(r)
    local n = 0
    for i = 1, #r.pts / 2 - 1 do
        if r.segCustom[i] then n = n + 1 end
    end
    for k in pairs(r.segCustom) do
        assert(r.segCustom[k] == true and k >= 1 and k <= #r.pts / 2 - 1, "segCustom 只放段號→true")
    end
    return n
end

local CUSTOM_PATH = { 0, 0, 50, 3, 100, 0 }

--------------------------------------------------------------------------------
-- 甲一、中間點不被官方路拉走：(50,3) 離官方路中心 5 格，落在兩路半寬和＋1＝6 內，
-- 沒釘住會 T 字吸到 (50,8)（或被 markKeep 留原點＋短接線，兩路就接上了）
--------------------------------------------------------------------------------
do
    local g = build({ official({ 0, 8, 100, 8 }, 6) }, { road(CUSTOM_PATH) })
    assert(nodeAt(g, 50, 3), "中間點留在原位")
    assert(not nodeAt(g, 50, 8), "官方路不得因自訂道路中間點被切出路口")
    local r = assert(find(g, 0, 0, 100, 0, 0), "沿自訂道路的路線")
    assert(passes(r, 50, 3) and customCount(r) == #r.pts / 2 - 1, "整條走在自訂道路上")
end

-- 甲二、官方端點反向拉：官方死巷端點 (50,2) 的量化 key 比 (50,3) 小，沒釘住時中間點會被拖到
-- (50,2)；釘住後只能官方端點自己接過來
do
    local g = build({ official({ 50, 2, 50, -40 }) }, { road(CUSTOM_PATH) })
    assert(nodeAt(g, 50, 3), "中間點不被官方端點反向拖走")
    assert(not nodeAt(g, 50, 2), "官方死巷端點接到中間點上")
    local r = assert(find(g, 50, -40, 100, 0, 0), "官方死巷接得上自訂道路")
    assert(passes(r, 50, 3), "經過自訂道路原本的中間點")
    assert(not r.segCustom[1] and r.segCustom[#r.pts / 2 - 1], "官方段不標自訂、自訂段標自訂")
end

-- 甲二之一、編輯形狀時排除自己那條路的舊版本：吸到旁邊的官方路；不給 skip 照舊；
-- 別的玩家傳同名 id 不會排除這條；收到的路（沒有 owner）不受影響
do
    local g = build({ official({ 0, 0, 100, 0 }, 4, "Main St") }, {
        road({ 0, 10, 100, 10 }, { mask = 3, owner = 0, id = "r1", name = "Mine" }),
        road({ 0, 30, 100, 30 }, { mask = 1, id = "r1", name = "Received" }),
    })
    local plain = assert(mod.nearestRoad(g, 0, 50, 12, 20))
    assert(plain.custom and plain.name == "Mine" and plain.dist == 2, "不給第 5 參：照舊吸到最近的自訂道路")
    local skip = assert(mod.nearestRoad(g, 0, 50, 12, 20, "r1"), "排除自己那條")
    assert(not skip.custom and skip.name == "Main St" and skip.dist == 12, "排除後吸到旁邊的官方路")
    local other = assert(mod.nearestRoad(g, 1, 50, 12, 20, "r1"))
    assert(other.custom and other.name == "Mine", "pn1 傳同名 id 不排除 pn0 的路")
    local received = assert(mod.nearestRoad(g, 0, 50, 28, 5, "r1"))
    assert(received.name == "Received", "沒有 owner 的路不被排除")
end

-- 甲二之二、自訂道路中間點剛好落在官方死巷端點 (50,5)：那一點照官方規則 T 吸附到 (50,0)，
-- 官方路線和沒有自訂道路時逐點相同（不釘住、也不因自訂段橫拖而保留原端點）
do
    local base = { official({ 0, 0, 100, 0 }), official({ 50, 30, 50, 5 }) }
    local plain = build(base, nil)
    local mixed = build(base, { road({ 20, 40, 50, 5, 80, 40 }) })
    assert(nodeAt(plain, 50, 0) and not nodeAt(plain, 50, 5), "對照：官方死巷端點 T 吸附到 (50,0)")
    assert(nodeAt(mixed, 50, 0), "官方死巷端點照舊 T 吸附")
    for _, q in ipairs({ { 50, 30, 100, 0 }, { 50, 30, 0, 0 }, { 0, 0, 100, 0 }, { 100, 0, 50, 30 } }) do
        local a = assert(find(plain, q[1], q[2], q[3], q[4], 0))
        local r = assert(find(mixed, q[1], q[2], q[3], q[4], 0))
        assert(#a.pts == #r.pts and a.len == r.len and customCount(r) == 0, "官方路線不變")
        for i = 1, #a.pts do assert(a.pts[i] == r.pts[i], "官方路線逐點相同") end
    end
    local via = assert(find(mixed, 20, 40, 100, 0, 0), "自訂道路經同一路口接上官方路")
    assert(passes(via, 50, 0) and via.segCustom[1], "自訂段走到官方路口")
end

-- 甲三、跨 300 格接縫：預切出的 (300,0) 是連續切點；官方端點 (300,-2.5) key 較小也拖不動它
do
    local wof = function(_, _, src) return src end
    local g = build({ official({ 300, -2.5, 300, -40 }) }, { road({ 250, 0, 350, 0 }) }, wof)
    assert(nodeAt(g, 300, 0) and not nodeAt(g, 300, -2.5), "切點留在自訂道路上，官方端點接過來")
    local r = assert(find(g, 250, 0, 350, 0, 0), "跨接縫的自訂道路走得通")
    for i = 2, #r.pts, 2 do assert(r.pts[i] == 0, "跨接縫不折到官方端點") end
    assert(find(g, 300, -40, 350, 0, 0), "官方死巷經接縫切點進自訂道路")
end

-- 甲四、free 端點不接、snap 端點 1 格內接上：官方路 y=0 寬 4、自訂寬 4 → 容差 2＋2＋1＝5
do
    local main = official({ -50, 0, 50, 0 })
    local function joined(endY, ends)
        local g = build({ main }, { road({ 0, 20, 0, endY }, { ends = ends }) })
        return nodeAt(g, 0, 0) ~= nil, g
    end
    assert(joined(4.5, { "free", "snap" }), "對照：snap 端點 4.5 格接上")
    assert(not joined(4.5, { "snap", "free" }), "free 端點不接")
    assert(joined(4.9, { "free", "snap" }), "snap 端點在路緣 1 格內接上")
    assert(not joined(5.5, { "free", "snap" }), "snap 端點超出路緣 1 格不接（ATTACH_SLACK 4.5 會接）")
    local _, g = joined(4.9, { "free", "snap" })
    local r = assert(find(g, 0, 20, 40, 0, 0), "接上後可轉進官方路")
    assert(r.segCustom[1] and not r.segCustom[#r.pts / 2 - 1], "segCustom 只標自訂段")
end

-- 甲五、交叉成路口
do
    local g = build({ official({ -50, 0, 50, 0 }) }, { road({ 0, -30, 0, 30 }, { ends = { "free", "free" } }) })
    local r = assert(find(g, 0, -30, 50, 0, 0), "交叉處可轉彎")
    assert(passes(r, 0, 0) and r.segCustom[1] and not r.segCustom[#r.pts / 2 - 1], "經路口、segCustom 正確")
end

-- 甲六、官方死巷端點貼著自訂道路（路緣 1 格內）才接
do
    local g = build({ official({ 0, 30, 0, 4.8 }), official({ 20, 30, 20, 6 }) }, { road({ -50, 0, 50, 0 }) })
    assert(nodeAt(g, 0, 0), "端點離自訂道路路緣 0.8 格：接上")
    assert(not nodeAt(g, 20, 0), "端點離路緣 2 格：不接（官方之間的 4.5 格間隙不套用）")
end

-- 甲七、pn 遮罩：pn1 的私路 pn0 選不到、也吸附不到
do
    local g = build({ official({ 0, 0, 100, 0 }), official({ 0, 200, 100, 200 }) },
        { road({ 50, 0, 50, 200 }, { mask = 2, name = "Private" }) })
    assert(find(g, 0, 0, 0, 200, 1), "pn1 走得到自己的路")
    assert(find(g, 0, 0, 0, 200, 0) == nil, "pn0 不得借 pn1 的私路")
    assert(find(g, 0, 0, 0, 200, nil) == nil, "沒給 pn 只走官方街道")
    local own = assert(mod.nearestRoad(g, 1, 52, 100, 10), "pn1 吸附到私路")
    assert(own.custom and own.name == "Private" and math.abs(own.dist - 2) < 1e-9, "吸附結果帶道路名與 custom")
    assert(mod.nearestRoad(g, 0, 52, 100, 10) == nil, "pn0 吸附不到 pn1 的私路")
    local other = assert(mod.nearestRoad(g, 0, 52, 100, 500), "pn0 只看得到官方街道")
    assert(not other.custom and other.dist == 100, "最近的是官方街道")
    local start = assert(find(g, 52, 90, 100, 0, 0), "pn0 起點吸附不到私路，改從官方街道起步")
    assert(start.snapDist == 90 and customCount(start) == 0, "起點不在私路上")
end

-- 甲八、segCustom：同段直達、官方＋自訂重疊＝官方、自訂＋自訂＝遮罩聯集
do
    local g = build({ official({ 0, 0, 100, 0 }) }, {
        road({ 0, 0, 100, 0 }, { mask = 1 }),
        road({ 0, 50, 100, 50 }, { mask = 1 }), road({ 0, 50, 100, 50 }, { mask = 3 }),
        road({ 0, 100, 100, 100 }, { mask = 2 }),
    })
    local merged = assert(find(g, 10, 0, 90, 0, 1), "重疊官方段任何人都能走")
    assert(customCount(merged) == 0, "官方＋自訂重疊算官方")
    for _, pn in ipairs({ 0, 1 }) do
        local r = assert(find(g, 10, 50, 90, 50, pn), "自訂＋自訂重疊：兩個遮罩都能走")
        assert(#r.pts == 4 and r.segCustom[1] == true, "同段直達也帶 segCustom")
    end
    assert(find(g, 10, 50, 90, 50, 2) == nil or customCount(find(g, 10, 50, 90, 50, 2)) == 0,
        "聯集不得多出 pn2（1|3 用加法會變 4）")
    local r = assert(find(g, 10, 100, 90, 100, 1))
    assert(#r.pts == 4 and r.segCustom[1], "自訂道路同段直達")
end

-- 甲九、零官方街道：只有自訂道路也能建圖選路
do
    local g = build({}, { road({ 0, 0, 100, 0, 100, 100 }), road({ 50, -50, 50, 50 }, { ends = { "free", "free" } }) })
    local r = assert(find(g, 0, 0, 100, 100, 0), "只有自訂道路也能選路")
    assert(customCount(r) == #r.pts / 2 - 1, "整條都是自訂段")
    assert(find(g, 50, -50, 100, 100, 0), "自訂道路之間的交叉成路口")
end

-- 甲十、壞資料整條略過，好的照收
do
    local out = {}
    local bad = road({ 0, 0, 10, 0 })
    bad.road.segWidth[1] = 0
    local added, skipped = mod.customStreets({
        road({ 0, 0, 10, 0 }, { mask = 0 }), road({ 0, 0, 10, 0 }, { mask = 16 }), bad,
        road({ 0, 0, 10, 0 }, { mask = 1.5 }), { road = { pts = { 1, 1 } }, usableBy = 1 },
        road({ 0, 0, 10, 0, 20, 0 }, { mask = 15 }),
    }, out)
    assert(added == 1 and skipped == 5 and #out == 1, "只收合法的那一條")
    assert(out[1].custom and out[1].searchable == false and out[1].width == 4 and out[1].src == nil,
        "形狀同 RoadPatch add、不參與搜尋、沒有來源目錄")
end

-- 甲十一、官方圖加了不相干的自訂道路：官方路線逐點不變（含分批建圖）
do
    dofile("MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/shared/MinidoracatMiniMapRoadPatches.lua")
    local patch = MinidoracatMiniMapRoadPatches
    local members = {}
    for m in pairs(patch.geometrySet) do members[#members + 1] = m end
    table.sort(members)
    local function streets()
        local out = {}
        for _, member in ipairs(members) do
            local geometry, widthQ = member:match("^(.-)|w:(%-?%d+)$")
            local pts, field = {}, 0
            for token in geometry:gmatch("[^:]+") do
                field = field + 1
                if field > 1 then pts[#pts + 1] = tonumber(token) / 2 end
            end
            out[#out + 1] = { name = "s" .. #out, src = patch.targetSrc, width = tonumber(widthQ) / 2, pts = pts }
        end
        assert(mod.applyRoadPatches(out, patch))
        return out
    end
    local wof = function(_, _, src) return src end
    local plain = build(streets(), nil, wof, 5000)
    local far = road({ 1000, 1000, 1000, 1300, 1300, 1300 }, { width = 16 })
    local mixed = build(streets(), { far }, wof, 211)
    math.randomseed(7)
    for _ = 1, 120 do
        local sx, sy = math.random(3000, 15000), math.random(3000, 15000)
        local tx, ty = math.random(3000, 15000), math.random(3000, 15000)
        local a, b = find(plain, sx, sy, tx, ty, 0), find(mixed, sx, sy, tx, ty, 0)
        assert((a == nil) == (b == nil), "官方路線有無一致")
        if a then
            assert(#a.pts == #b.pts and a.len == b.len and a.cost == b.cost, "官方路線長度一致")
            for i = 1, #a.pts do assert(a.pts[i] == b.pts[i], "官方路線逐點一致") end
            assert(customCount(b) == 0, "官方路線不標自訂")
        end
    end
end

-- 甲十二、目標旁的自訂死路不得擠掉官方終點候選（2026-10-23 E2E：徒步離目標 95 m 卻被迫繞 506 格）。
-- 目標 (150,63) 離 QR 52.5 格（要從 L1、L2 繞過去）、離 M1 63 格；自訂道路從 QR 接到目標。
-- 徒步（×3）照存路前停在 M1 越野接近（344 < 沿自訂道路 595）；車上（×12）走自訂道路到目標（595 < 911）
do
    local streetsIn = {
        official({ 0, 0, 200, 0 }, 4, "M1"), official({ 0, 0, 0, 200 }, 4, "L1"),
        official({ 0, 200, 202.5, 200 }, 4, "L2"), official({ 202.5, 200, 202.5, 40 }, 4, "QR"),
    }
    local plain = build(streetsIn)
    local g = build(streetsIn, { road({ 202.5, 63, 176, 55, 150, 63 }, { ends = { "snap", "free" } }) })
    local function walk(gr) return mod.findRoute(gr, 0, 5, 150, 63, nil, nil, nil, 3, nil, nil, 0) end
    local base, r = assert(walk(plain), "存路前徒步有路"), assert(walk(g), "存路後徒步有路")
    assert(math.abs(base.ex - 150) < 1e-6 and math.abs(base.ey) < 1e-6, "存路前停在 M1 上離目標最近處")
    assert(customCount(r) == 0 and r.ex == base.ex and r.ey == base.ey and r.len == base.len,
        "徒步：自訂死路不擠掉官方候選，照存路前走 M1、越野接近")
    local car = assert(find(g, 0, 5, 150, 63, 0), "車上有路")
    assert(customCount(car) > 0 and math.abs(car.ex - 150) < 1e-6 and math.abs(car.ey - 63) < 1e-6,
        "車上：沿自訂道路開到目標")
end

--------------------------------------------------------------------------------
-- 乙、整檔載入：重建生命週期
--------------------------------------------------------------------------------
local LOT_DIR = "Muldraugh, KY"
local function javaList(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local function event()
    local handlers = {}
    return {
        Add = function(fn) handlers[#handlers + 1] = fn end,
        fire = function() for i = 1, #handlers do handlers[i]() end end,
    }
end
local function record(pts, name)
    return {
        getNumPoints = function() return #pts / 2 end,
        getUntranslatedText = function() return name end,
        getTranslatedText = function() return name end,
        getWidth = function() return 5 end,
        getPointX = function(_, i) return pts[i * 2 + 1] end,
        getPointY = function(_, i) return pts[i * 2 + 2] end,
    }
end
-- 兩條不相連的官方街；玩家在 R1 西端，目標 R2 西端，只能經自訂道路
local function baseRecords()
    return { record({ 3100, 3100, 3400, 3100 }, "R1"), record({ 3100, 3300, 3400, 3300 }, "R2") }
end
local V1 = road({ 3200, 3100, 3200, 3300 }, { name = "Farm Track", owner = 0, id = "r1" })
local V2 = road({ 3200, 3100, 3250, 3200, 3200, 3300 }, { name = "Farm Track" })
local V3 = road({ 3200, 3100, 3150, 3200, 3200, 3300 }, { name = "Farm Track" })
local V4 = road({ 3200, 3100, 3260, 3200, 3200, 3300 }, { name = "Farm Track" })
local function fillers(list)
    for f = 1, 6 do
        local pts = {}
        for k = 0, 299 do pts[k * 2 + 1], pts[k * 2 + 2] = 5000 + k * 2, 5000 + f * 50 + (k % 2) end
        list[#list + 1] = road(pts, { name = "Filler" })
    end
    return list
end
local function overflow()
    local list = {}
    for f = 1, 60 do
        local pts = {}
        for k = 0, 299 do pts[k * 2 + 1], pts[k * 2 + 2] = 8000 + k * 2, 8000 + f * 20 end
        list[#list + 1] = road(pts, { name = "Too many" })
    end
    return list
end

local function world(records, list)
    local W = { clock = 1000, prints = {}, msgs = {}, list = list, records = records }
    local container = { streets = javaList(records) }
    W.count = #records > 0 and 1 or 0
    local streetsAPI = {
        getStreetDataCount = function() return W.count end,
        getStreetDataByRelativeFileName = function(_, rel)
            return W.count > 0 and rel == "media/maps/" .. LOT_DIR .. "/streets.xml" and container or nil
        end,
        getStreetDataByIndex = function(_, i) return W.count > 0 and i == 0 and container or nil end,
    }
    W.surface = { mapAPI = { getStreetsAPI = function() return streetsAPI end } }
    local player = {
        getX = function() return 3100 end, getY = function() return 3100 end,
        getVehicle = function() return nil end,
    }
    local tick, gameStart = event(), event()
    local env = {
        math = math, string = string, table = table, pairs = pairs, ipairs = ipairs,
        type = type, tostring = tostring, tonumber = tonumber,
        error = error, pcall = pcall, select = select,
        print = function(line) W.prints[#W.prints + 1] = tostring(line) end,
        Events = { OnTick = event(), OnTickEvenPaused = tick, OnGameStart = gameStart },
        MinidoracatMiniMapAPI = {},
        MinidoracatMiniMapCore = {
            ready = true,
            getBoolOption = function(_, default) return default end,
            getLoadedMapDirs = function() return { [LOT_DIR] = 1 } end,
            roadsActive = function(max)
                W.lastMax = max
                return W.list
            end,
            navMessage = function(pn, text, good) W.msgs[#W.msgs + 1] = { pn = pn, text = text, good = good } end,
        },
        getText = function(key) return key end,
        fileExists = function() return true end,
        getLotDirectories = function() return javaList({ LOT_DIR }) end,
        getStreets = function(data) return data.streets end,
        getSpecificPlayer = function(pn) return pn == 0 and player or nil end,
        getTimestampMs = function() return W.clock end,
        ISWorldMap_instance = W.surface,
    }
    if setfenv then
        local chunk = assert(compile(source, "navroute-full"))
        setfenv(chunk, env)
        chunk()
    else
        assert(load(source, "navroute-full", "t", env))()
    end
    W.core, W.api, W.gameStart = env.MinidoracatMiniMapCore, env.MinidoracatMiniMapAPI, gameStart
    function W.run(n) for _ = 1, n or 1 do tick.fire() end end
    function W.wait(pred)
        for _ = 1, 600 do
            if pred() then return true end
            tick.fire()
        end
        return pred()
    end
    function W.state() return select(2, W.api.getNavGraph()) end
    function W.graph() return (W.api.getNavGraph()) end
    function W.change(newList)
        W.list = newList
        W.core.navCustomRoadsChanged()
    end
    function W.rebuilt()
        local n = 0
        for _, line in ipairs(W.prints) do
            if line:find("graph rebuilt", 1, true) then n = n + 1 end
        end
        return n
    end
    return W
end

local function routeTo(W) return W.api.requestRoute(0, 3100, 3300) end

-- 乙一：第一次建圖就帶自訂道路；吸附照 pn 遮罩
local W = world(baseRecords(), { V1 })
W.core.navKickEngine(W.surface)
assert(W.wait(function() return W.state() == "ready" end), "首次建圖 ready")
assert(W.lastMax == 16384 - 2, "roadsActive 的段數上限扣掉官方段數")
local r1 = assert(routeTo(W), "經自訂道路接兩條官方街")
assert(customCount(r1) > 0 and passes(r1, 3200, 3200) == false and W.core.navGraphState() == "ready")
local hit = assert(W.core.navNearestRoad(0, 3205, 3200, 20), "畫線吸附到自訂道路")
assert(hit.custom and hit.name == "Farm Track" and hit.dist == 5 and hit.x == 3200 and hit.y == 3200)
assert(W.core.navNearestRoad(1, 3205, 3200, 20) == nil, "pn1 看不到 pn0 的路")
local skipped = assert(W.core.navNearestRoad(0, 3205, 3200, 200, "r1"), "第 5 參轉給核心")
assert(not skipped.custom and skipped.dist == 100, "編輯中的路不吸回自己的舊版本")
assert(W.core.navNearestRoad(0, 3205, 3200, 0 / 0) == nil and W.core.navNearestRoad(4, 3205, 3200, 20) == nil,
    "壞參數回 nil")

-- 乙二：改形狀 → 防抖期間照舊服務 → 換圖後同目標拿到新表、新形狀
local g1 = W.graph()
W.change({ V2 })
assert(W.core.navGraphState() == "building", "剛改的路還沒併進路網")
W.run(5)
assert(W.graph() == g1 and W.state() == "ready", "防抖期間不重建、舊圖照常 ready")
assert(routeTo(W) == r1, "換圖前同目標沿用同一顆快取")
W.clock = W.clock + 1000
assert(W.wait(function() return W.graph() ~= g1 end), "防抖到期後換圖")
assert(W.state() == "ready" and W.core.navGraphState() == "ready")
local r2 = assert(routeTo(W))
assert(r2 ~= r1, "換圖後同目標回新的 route 表（偏航 12 格內也不沿用舊快取）")
assert(passes(r2, 3250, 3200) and not passes(r1, 3250, 3200), "新路線照新形狀")

-- 乙三：重建中又改路 → 舊結果丟掉，只換最後一版
local g2, rebuiltBefore = W.graph(), W.rebuilt()
W.change(fillers({ V3 }))
W.clock = W.clock + 1000
W.run(3)
assert(W.graph() == g2 and W.core.navGraphState() == "building", "fixture 要讓重建跨多個 tick")
W.change(fillers({ V4 }))
W.run(10)
assert(W.graph() == g2, "過期的 pending 不得換上去")
W.clock = W.clock + 1000
assert(W.wait(function() return W.graph() ~= g2 end))
local r4 = assert(routeTo(W))
assert(passes(r4, 3260, 3200) and not passes(r4, 3150, 3200), "換上的是最後一版")
assert(W.rebuilt() == rebuiltBefore + 1, "中間那版沒有換上")

-- 乙四：建圖失敗保留舊圖、告訴玩家一次、同一版不再重試；改回合法的路就恢復
local g4 = W.graph()
W.change(overflow())
W.clock = W.clock + 1000
W.run(20)
assert(W.graph() == g4 and W.state() == "ready", "失敗保留舊圖")
assert(#W.msgs == 1 and W.msgs[1].pn == 0 and W.msgs[1].good == false
    and W.msgs[1].text == "UI_MinidoracatMiniMap_RoadNavBuildFailed", "告訴玩家一次")
W.run(50)
assert(#W.msgs == 1 and W.core.navGraphState() == "ready", "同一版不重試、不重複通知")
assert(routeTo(W) and passes(routeTo(W), 3260, 3200), "舊圖照常選路")
W.change({ V1 })
W.clock = W.clock + 1000
assert(W.wait(function() return W.graph() ~= g4 end) and not passes(routeTo(W), 3260, 3200), "改路後恢復")

-- 乙五：換世界丟掉 pending（新世界的道路不同；舊世界那版不得在新世界換上）
W.change(fillers({ V2 }))
W.clock = W.clock + 1000
W.run(3)
assert(W.core.navGraphState() == "building")
W.gameStart.fire()
W.run(30)
assert(W.graph() == nil and W.state() == "idle", "換世界後 pending 不得換上")
W.list = { V1 }
W.core.navKickEngine(W.surface)
assert(W.wait(function() return W.state() == "ready" end), "新世界建圖")
W.run(300) -- 上一世界那版若沒丟掉，這段時間足夠它建完換上
assert(not passes(routeTo(W), 3250, 3200), "新世界只用新世界的道路")

-- 乙六：讀不到官方街道（nodata）：沒有自訂道路維持 idle；有就只用自訂道路建圖
local empty = world({}, {})
empty.core.navKickEngine(empty.surface)
empty.run(10)
assert(empty.state() == "idle" and empty.graph() == nil, "沒自訂道路：照舊 nodata idle")
empty.change({ V1 })
assert(empty.wait(function() return empty.state() == "ready" end), "畫了路就建圖")
local onlyCustom = assert(empty.api.requestRoute(0, 3200, 3300), "只有自訂道路也能選路")
assert(customCount(onlyCustom) == #onlyCustom.pts / 2 - 1)
-- 冷啟動先探到空的那一側：官方街道其實讀得到 → 改抽官方街道、併進自訂道路
for _, rec in ipairs(baseRecords()) do empty.records[#empty.records + 1] = rec end
empty.count = 1
assert(empty.wait(function() return empty.state() == "extracting" end), "探到官方街道就重抽")
assert(empty.wait(function() return empty.state() == "ready" end))
local both = assert(empty.api.requestRoute(0, 3100, 3300), "官方街道＋自訂道路")
assert(customCount(both) > 0 and customCount(both) < #both.pts / 2 - 1)
-- 沒有官方街道的地圖刪光自訂道路：回 nodata
local again = world({}, { V1 })
again.core.navKickEngine(again.surface)
assert(again.wait(function() return again.state() == "ready" end))
again.change({})
again.clock = again.clock + 1000
assert(again.wait(function() return again.state() == "idle" end) and again.graph() == nil, "刪光回 idle")

-- 乙七：抽到的全是鐵路（零官方街道、outN==0）→ failed；畫了路就從 failed 建起來
local rails = world({ record({ 3100, 3100, 3400, 3100 }, "Some Railroad") }, {})
rails.core.navKickEngine(rails.surface)
assert(rails.wait(function() return rails.state() == "failed" end), "沒有路：failed")
rails.change({ V1 })
rails.clock = rails.clock + 1000
assert(rails.wait(function() return rails.state() == "ready" end), "畫了路就建圖")
assert(rails.api.requestRoute(0, 3200, 3300), "只有自訂道路也能選路")

-- 乙八：第一次建圖就因自訂道路失敗 → 退回只有官方街道，告訴玩家一次
local fallback = world(baseRecords(), overflow())
fallback.core.navKickEngine(fallback.surface)
assert(fallback.wait(function() return fallback.state() == "ready" end), "退回官方街道")
assert(#fallback.msgs == 1, "告訴玩家一次")
assert(fallback.api.requestRoute(0, 3400, 3100), "官方街道照常選路")
assert(fallback.core.navGraphState() == "ready")

-- 乙九：第一次建圖跑到一半才因自訂道路失敗（一條路來回穿過 R1 同一段 299 次，超過單段切點上限）
-- → 同樣退回官方街道
local zig = {}
for k = 0, 299 do zig[k * 2 + 1], zig[k * 2 + 2] = 3101 + k, 3100 + (k % 2 == 0 and -5 or 5) end
local midway = world(baseRecords(), { road(zig, { name = "Zigzag" }) })
midway.core.navKickEngine(midway.surface)
assert(midway.wait(function() return midway.state() ~= "extracting" and midway.state() ~= "idle" end))
assert(midway.wait(function() return midway.state() == "ready" end), "建圖中途失敗也退回官方街道")
assert(#midway.msgs == 1 and midway.api.requestRoute(0, 3400, 3100), "告訴玩家一次、官方街道照常")

print("test_nav_custom_roads: OK")
