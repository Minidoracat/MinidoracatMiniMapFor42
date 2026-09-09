-- 導航引擎冷啟動離線回歸測試：抽 _NavRoute.lua 的 nav-extract（真 beginExtract）
-- 與 nav-kick（kickEngine）兩個區段，以 stub mapAPI／getTimestampMs 驗狀態機。
-- 守 2026-09-05 MP 回報的根因修正：空容器（total==0）不得進 failed 終態、冷卻
-- per-inner（同幀多表面不互相飢餓）、其他失敗仍 failed 且不殘留 nodata。
-- 另加一組「整檔載入」實驗（隔離 env、真 OnTick 泵）：守零點／單點 street
-- record 不得害整份路網退場（2026-09-09 Tikitown 類 MOD 地圖回報）。
-- 用法：lua scripts/test_nav_kick.lua [_NavRoute.lua 路徑]
local navPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"

local file = assert(io.open(navPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local function slice(name)
    return assert(source:match(
        "%-%- test:" .. name .. ":start[^\n]*\n(.-)\n%-%- test:" .. name .. ":end"),
        "找不到 " .. name .. " 測試區段")
end

local compile = loadstring or load
local prelude = [=[
local engine = { state = "idle" }
local logs = {}
local function logf(key, msg) logs[#logs + 1] = key .. ": " .. msg end
local MAX_STREET_CONTAINERS = 1024
local clock = 0
local function getTimestampMs() return clock end
]=]
local suffix = [=[
return {
    kick = kickEngine, engine = engine, logs = logs,
    setClock = function(ms) clock = ms end,
    reset = function()
        engine.state, engine.extract, engine.nodata = "idle", nil, nil
        for i = #logs, 1, -1 do logs[i] = nil end
    end,
}
]=]
local m = assert(compile(prelude .. slice("nav%-extract") .. "\n" .. slice("nav%-kick") .. "\n" .. suffix, "nav-kick"))()

-- 全域 stub（beginExtract 直接引用）：getStreets 存在即可（不會走到抽取）、
-- lot dirs 給一個目錄
getStreets = function() return { size = function() return 0 end } end
getLotDirectories = function()
    return { size = function() return 1 end, get = function() return "Muldraugh, KY" end }
end

local probes = 0
-- inner stub：count 由閉包供給；countErr＝getStreetDataCount 拋錯；noApi＝getStreetsAPI 回 nil
local function inner(count, countErr, noApi)
    local api = {
        getStreetDataCount = function()
            probes = probes + 1
            if countErr then error("boom", 0) end
            return count()
        end,
        getStreetDataByRelativeFileName = function() return { tag = "data" } end,
        getStreetDataByIndex = function() return { tag = "data" } end,
    }
    return { mapAPI = { getStreetsAPI = function() return (not noApi) and api or nil end } }
end
local function fixed(n) return function() return n end end

local pass, fail = 0, 0
local function ok(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. msg) end
end

-- 1. 空容器（真 beginExtract total==0）⇒ 維持 idle、標 nodata、per-inner 冷卻；不進 failed
m.reset(); m.setClock(1000); probes = 0
local a = inner(fixed(0))
m.kick(a)
ok(m.engine.state == "idle", "total==0 不得進 failed，實為 " .. tostring(m.engine.state))
ok(m.engine.nodata == true, "total==0 要標 nodata")
ok(a._minidoracatNavRetryAt == 2000, "冷卻寫在 inner 上（now+1000），實為 " .. tostring(a._minidoracatNavRetryAt))
ok(#m.logs == 1 and m.logs[1]:find("nodata: ", 1, true) == 1, "total==0 只 log nodata（非 acquire）")

-- 2. 同 inner 冷卻內再 kick ⇒ 不探測
m.setClock(1500)
m.kick(a)
ok(probes == 1, "冷卻內同 inner 不得再探測，實得 " .. probes)

-- 3. 另一個 inner 同幀 kick、容器滿 ⇒ 不受 a 的冷卻影響，立即進 extracting、nodata 清
local b = inner(fixed(1))
m.kick(b)
ok(probes == 2, "不同 inner 不得被別人的冷卻擋住")
ok(m.engine.state == "extracting", "滿側應立即接手，實為 " .. tostring(m.engine.state))
ok(m.engine.nodata == nil, "成功後 nodata 要清掉")

-- 4. 非 idle ⇒ 早退不探測
m.kick(a); m.kick(b)
ok(probes == 2, "非 idle 不得探測")

-- 5. 冷卻到期、同 inner 仍空 ⇒ 再探測、再 arm、仍 idle
m.reset(); m.setClock(1000); probes = 0
local n = 0
a = inner(function() return n end)
m.kick(a)
m.setClock(2000)
m.kick(a)
ok(probes == 2 and m.engine.state == "idle" and a._minidoracatNavRetryAt == 3000,
    "到期仍空應再探測並重新 arm（idle），實為 state=" .. tostring(m.engine.state)
    .. " retryAt=" .. tostring(a._minidoracatNavRetryAt))

-- 6. 再到期、容器補上 ⇒ 進 extracting
n = 1
m.setClock(3000)
m.kick(a)
ok(m.engine.state == "extracting", "到期＋容器補上應進 extracting，實為 " .. tostring(m.engine.state))

-- 7. 先 nodata、之後 getStreetsAPI 回 nil（API 缺席）⇒ failed 且 nodata 必須清掉
m.reset(); m.setClock(1000)
m.kick(inner(fixed(0)))
ok(m.engine.nodata == true, "前置：nodata 已標")
m.kick(inner(fixed(0), false, true))
ok(m.engine.state == "failed", "getStreetsAPI 缺席應進 failed")
ok(m.engine.nodata == nil, "failed 不得殘留 nodata（否則 navEngineState 遮住終態）")

-- 8. getStreetDataCount 拋錯 ⇒ failed＋acquire log（pcall 失敗的第三回傳不得被當 retry）
m.reset()
m.kick(inner(fixed(0), true))
ok(m.engine.state == "failed", "探測拋錯應進 failed")
ok(#m.logs == 1 and m.logs[1]:find("acquire: street acquire failed", 1, true), "拋錯要 log acquire")

-- 9. inner 無 mapAPI ⇒ 早退
m.reset(); probes = 0
m.kick({})
ok(probes == 0 and m.engine.state == "idle", "無 mapAPI 早退")

-- 10. getStreets 全域缺失（PZ <42.20）⇒ failed＋api log，不是 retry
m.reset()
local saved = getStreets
getStreets = nil
m.kick(inner(fixed(1)))
getStreets = saved
ok(m.engine.state == "failed" and m.logs[1] and m.logs[1]:find("api: ", 1, true) == 1,
    "getStreets 缺失應進 failed 並 log api")

--------------------------------------------------------------------------------
-- 11+. 整檔載入實驗（隔離 env）：真 _NavRoute.lua 全檔 → navKickEngine → OnTick
-- → 公開查詢面（getNavGraph／requestRoute）。不複製 stepExtract／winnerOf 邏輯，
-- 跑的就是 production 本體。
-- 守 Little Township B42 的單點街回報，另以零點 record 驗 n<2 安全邊界：
-- 退化街道不得讓同一世界的正常路網永久退直線。
-- 契約：n<2 只略過（不讀其座標）、仍吃每 tick 48 筆預算、每世界只 log 一次；
-- 4096 點上限、width 驗證照舊 error（壞資料的閘門不放寬）。
-- cell gate（300 街道格／256 lot）另由 test_nav_route.lua 守，這裡 fileExists
-- 一律 true，讓本情境與格網改動解耦；env 也不共用上面切片測試的 _G 樁。
--------------------------------------------------------------------------------
local LOT_DIR = "Muldraugh, KY"
local LAT_ORIGIN, LAT_STEP, LAT_LINES = 3100, 20, 13
local LAT_END = LAT_ORIGIN + LAT_STEP * (LAT_LINES - 1)

local function javaList(items)
    return {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end, -- Java 0-based
    }
end

local function event()
    local handlers = {}
    return {
        Add = function(fn) handlers[#handlers + 1] = fn end,
        fire = function() for i = 1, #handlers do handlers[i]() end end,
    }
end

-- WorldMapStreet 樁：getNumPoints 計次（驗每 tick 分幀預算）；pts 缺席＝零點／
-- 單點 record，座標 getter 一律拋錯——「安全略過」的定義就是不去碰它們
local function record(hits, points, pts, width, name)
    local function noCoords()
        error("degenerate street coords must not be read", 0)
    end
    return {
        getNumPoints = function() hits.n = hits.n + 1; return points end,
        getTranslatedText = function() return name or "Stub St" end,
        getWidth = function() return width end,
        getPointX = pts and function(_, i) return pts[i * 2 + 1] end or noCoords,
        getPointY = pts and function(_, i) return pts[i * 2 + 2] end or noCoords,
    }
end
local function road(hits, x1, y1, x2, y2, name, width)
    return record(hits, 2, { x1, y1, x2, y2 }, width or 5, name)
end
local function shortRoad(hits, points) return record(hits, points, nil) end

-- 13×13 棋盤（間距 20 > 半寬和＋ATTACH_SLACK，不會誤黏成一團）＝26 條合法街道；
-- 兩對角間有 480 格沿路路線，搭配短街後的重複來源走訪會跨過每 tick 預算。
local function lattice(hits, out)
    for i = 1, LAT_LINES do
        local at = LAT_ORIGIN + LAT_STEP * (i - 1)
        out[#out + 1] = road(hits, LAT_ORIGIN, at, LAT_END, at, "Row " .. i)
        out[#out + 1] = road(hits, at, LAT_ORIGIN, at, LAT_END, "Col " .. i)
    end
    return out
end

-- 整檔載入 → 冷啟動 → 泵 OnTick 到終態 → 查一次公開路線面。
-- 容器同時由 by-rel（src=dir）與 byIndex（src=nil）命中＝真遊戲的樣子，
-- 每筆 record 因此被走訪兩次，26/30 筆就能跨過 48 筆/tick 的分幀邊界
local function runWorld(makeRecords)
    local hits, prints = { n = 0 }, {}
    local records = makeRecords(hits)
    local recordCount = #records
    local container = { streets = javaList(records) }
    local streetsAPI = {
        getStreetDataCount = function() return 1 end,
        getStreetDataByRelativeFileName = function(_, rel)
            return rel == "media/maps/" .. LOT_DIR .. "/streets.xml" and container or nil
        end,
        getStreetDataByIndex = function(_, i) return i == 0 and container or nil end,
    }
    local surface = { mapAPI = { getStreetsAPI = function() return streetsAPI end } }
    local player = {
        getX = function() return LAT_ORIGIN end,
        getY = function() return LAT_ORIGIN end,
        getVehicle = function() return nil end,
    }
    local tick = event()
    local env = {
        math = math, string = string, table = table, pairs = pairs, ipairs = ipairs,
        type = type, tostring = tostring, tonumber = tonumber,
        error = error, pcall = pcall, select = select,
        print = function(line) prints[#prints + 1] = tostring(line) end,
        Events = { OnTick = tick, OnGameStart = event() },
        MinidoracatMiniMapAPI = {},
        MinidoracatMiniMapCore = {
            ready = true,
            getBoolOption = function(_, default) return default end,
            getLoadedMapDirs = function() return { [LOT_DIR] = 1 } end,
        },
        fileExists = function() return true end,
        getLotDirectories = function() return javaList({ LOT_DIR }) end,
        getStreets = function(data) return data.streets end,
        getSpecificPlayer = function(pn) return pn == 0 and player or nil end,
        getTimestampMs = function() return 1000 end,
    }
    if setfenv then -- 5.1（PZ Kahlua 同代）
        local chunk = assert(compile(source, "navroute-full"))
        setfenv(chunk, env)
        chunk()
    else            -- 5.2+
        assert(load(source, "navroute-full", "t", env))()
    end
    local api = env.MinidoracatMiniMapAPI
    env.MinidoracatMiniMapCore.navKickEngine(surface)
    local out = { prints = prints, container = container, recordCount = recordCount,
        maxReads = 0, extractTicks = 0 }
    for _ = 1, 400 do
        local before = hits.n
        tick.fire()
        local read = hits.n - before
        if read > 0 then out.extractTicks = out.extractTicks + 1 end
        if read > out.maxReads then out.maxReads = read end
        out.graph, out.state = api.getNavGraph()
        if out.state == "ready" or out.state == "failed" then break end
    end
    out.route, out.routeState = api.requestRoute(0, LAT_END, LAT_END)
    return out
end
local function why(w) return tostring(w.state) .. "｜log: " .. (w.prints[1] or "-") end

-- 11. 控制組（全合法）：先證明 fixture 本身能建圖、能走——後面的差分才有意義
local clean = runWorld(function(hits) return lattice(hits, {}) end)
ok(clean.state == "ready", "控制組：合法街道應建圖 ready，實為 " .. why(clean))
ok(clean.routeState == "ok" and clean.route ~= nil,
    "控制組：對角應找得到路線，實為 " .. tostring(clean.routeState))

-- 12. 混合資料（合法街道 ∪ 零點／單點 record）：整份路網仍要活著
local firstShort
local mixed = runWorld(function(hits)
    local items = { shortRoad(hits, 0) } -- 首筆＝log 取樣的 first source/index/points
    firstShort = items[1]
    lattice(hits, items)
    table.insert(items, 9, shortRoad(hits, 1)) -- 夾在合法街道中間
    items[#items + 1] = shortRoad(hits, 1)     -- 走訪第二輪時落在下一個 tick
    items[#items + 1] = shortRoad(hits, 0)
    return items
end)
ok(mixed.state == "ready",
    "零點／單點 record 不得害整份路網退場，實為 " .. why(mixed))
ok(mixed.graph ~= nil, "ready 必須真的發布 graph")
ok(mixed.routeState == "ok" and mixed.route ~= nil,
    "混合資料下合法路線仍要走得到，實為 " .. tostring(mixed.routeState))
ok(mixed.route and mixed.route.len and mixed.route.len > 400,
    "路線要沿棋盤走完全程（>400 格，非孤島短段），實為 "
    .. tostring(mixed.route and mixed.route.len))
ok(mixed.route and mixed.route.snapDist and mixed.route.snapDist < 1,
    "玩家就站在路口，接線距離應近 0，實為 "
    .. tostring(mixed.route and mixed.route.snapDist))

-- 13. 略過的 record 仍計入每 tick 預算：否則單幀跨界呼叫會超支掉幀
ok(mixed.maxReads <= 48, "每 tick 至多 48 筆（略過的也算），實為 " .. mixed.maxReads)
ok(mixed.extractTicks >= 2, "抽取要真的分幀推進，實為 " .. mixed.extractTicks .. " tick")

-- 14. log 一次：4 筆短街（且各被走訪兩輪）只該比控制組多一行輸出
ok(#mixed.prints == #clean.prints + 1, string.format(
    "略過 4 筆短街只該多一行 log（每世界一次），clean=%d mixed=%d",
    #clean.prints, #mixed.prints))

-- 15. 來源容器唯讀：略過不等於從 Java list 裡拿掉
ok(mixed.container.streets:size() == mixed.recordCount
    and mixed.container.streets:get(0) == firstShort,
    "略過的 record 仍須原樣留在來源 list")

-- 16. 全是短街 ⇒ 沒有可導航路網：要 failed，不得發布空 graph
local allShort = runWorld(function(hits)
    local items = {}
    for i = 1, 6 do items[i] = shortRoad(hits, i % 2) end
    return items
end)
ok(allShort.state == "failed", "全短街應進 failed，實為 " .. why(allShort))
ok(allShort.graph == nil, "failed 不得發布 graph")
ok(allShort.route == nil and allShort.routeState == "failed",
    "沒有路網時查詢面要回 failed，實為 " .. tostring(allShort.routeState))

-- 17. 壞資料閘門未放寬：>4096 點與不合法 width 仍是 error → failed
local hugeStreet = runWorld(function(hits)
    local items = lattice(hits, {})
    items[#items + 1] = record(hits, 4097, nil) -- MAX_POINTS_PER_STREET=4096
    return items
end)
ok(hugeStreet.state == "failed" and hugeStreet.graph == nil,
    "4097 點仍須 error 進 failed，實為 " .. why(hugeStreet))

local badWidth = runWorld(function(hits)
    local items = lattice(hits, {})
    items[#items + 1] = road(hits, LAT_ORIGIN, LAT_END + 40, LAT_END, LAT_END + 40,
        "Bad Width Rd", 0)
    return items
end)
ok(badWidth.state == "failed" and badWidth.graph == nil,
    "width=0 仍須 error 進 failed，實為 " .. why(badWidth))

if fail > 0 then
    print(string.format("test_nav_kick: %d passed, %d FAILED", pass, fail))
    os.exit(1)
end
print(string.format("test_nav_kick: OK（%d 斷言）", pass))
