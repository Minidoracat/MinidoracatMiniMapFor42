-- 行程全程預覽與活動段非繪製維護（v6）離線回歸測試：抽 _NavRoute.lua 的
-- nav-cache（活動段快取／ensureRoute）、nav-preview（預覽引擎＋OnTick 維護）與
-- nav-preview-draw（雙表面繪製，繪製原語換成記錄樁）三個標記區段，
-- **編進同一個 chunk**、共用同一份 navRoutes／navPreview／engine／
-- NavCore，再用 navroute-core 區段的 production 建圖器建一張真路網（含一個斷連
-- 孤島）跑真 A*。
-- 之所以不做 findRoute 樁：本測試要證的正是「預覽與活動段共存時互不污染」，
-- 樁化的回音路線既無法證明快取隔離，也證不出真實的無路分支。
--
-- 核心不變量：
--   * 預覽只寫 navPreview：活動路線的 table identity、progressIdx、快取筆數
--     在整輪預覽前後逐一不變（契約 6.6：預覽不得呼叫 requestRoute/requestDetour）
--   * 每個 OnTick 全域至多算一段；站數以 trip.count 為準、16 段上限
--   * 失效只認 revision／graph identity／approach 權重三者
--   * 未算完不得標完整總距離：done<total 時 state=pending，distance 只含已算段；
--     預覽尋路例外時 done 維持真實完成數（不得謊報進度、不得畫沒算出的段）
--   * 多站行程（count>=2）預設自動啟用預覽：不必呼叫 navSetPreview，且兩張
--     地圖拿到同一份結果、後續站都畫得到；明確關閉綁當下角色（同角色期間
--     不自動復活、換角色即回到預設，舊角色的段不得沿用）
--   * NavRoute 選項或導航 gate 擋住時停算（disabled，可恢復）
--   * 行程狀態變更只由非繪製路徑觸發：繪製用的 ensureRoute 不通知，
--     OnTick 維護與 addon 查詢面才通知；approach 不再尋路
-- 用法：lua scripts/test_itinerary_routes.lua [NavRoute.lua 路徑]
local srcPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"

local file = assert(io.open(srcPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local compile = loadstring or load

local function section(name)
    return assert(source:match("%-%- test:" .. name .. ":start[^\n]*\n(.-)\n%-%- test:" .. name .. ":end"),
        "找不到 " .. name .. " 測試區段")
end
local function constOf(name)
    return assert(tonumber(source:match("\nlocal " .. name .. " = (%-?[%d%.]+)")),
        "找不到常數 " .. name)
end
local LEG_TICKS = constOf("LEG_TICKS")

-- production NavCore（真建圖＋真 A*）
local NavCore = assert(compile(section("navroute%-core") .. "\nreturn NavCore", "core"))()

--------------------------------------------------------------------------------
-- 真路網 fixture（Muldraugh 量級座標）：
--   grid  ── 橫街 y=9700（x 10700..10900）× 縱街 x=10800（y 9650..9750）中段互穿
--   island ── 遠處 (12000..12100, 12000) 完全斷連，用來製造真正的 noroad
--------------------------------------------------------------------------------
local function buildGraph()
    local b = NavCore.newBuild({
        { name = "Main Street", src = "M", pts = { 10700, 9700, 10900, 9700 } },
        { name = "Cross Street", src = "M", pts = { 10800, 9650, 10800, 9750 } },
        { name = "Island Road", src = "M", pts = { 12000, 12000, 12100, 12000 } },
    }, nil)
    for _ = 1, 100000 do
        if NavCore.step(b, 500) then return b.graph end
    end
    error("build 未在迴圈上限內完成")
end
local GRAPH = buildGraph()
assert(GRAPH and GRAPH.nodeCount > 0, "fixture：真路網須建成")

--------------------------------------------------------------------------------
-- 兩個 production 區段編進同一 chunk（共用狀態＝隔離性才有意義）
--------------------------------------------------------------------------------
local prelude = ([=[
local NavCore, GRAPH = ...
local floor, sqrt = math.floor, math.sqrt
local DEVIATION_DIST, REBUILD_COOLDOWN_MS = %s, %s
local REBUILD_MOVE_DIST, NOROAD_RETRY_DIST = %s, %s
local function dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end
local navRoutes = {}
local navPreview = {}
local engine = { state = "ready", graph = GRAPH, patchState = "applied", searchState = "ok" }
local nowMs = 1000
local function getTimestampMs() return nowMs end
local function clearRoute(key) navRoutes[key] = nil end
local function failNavEngine()
    engine.state, engine.graph = "failed", nil
    for k in pairs(navRoutes) do navRoutes[k] = nil end
end
local logs = {}
local function logf(key, msg) logs[#logs + 1] = key end
local players = {}
local function getSpecificPlayer(pn) return players[pn] end
local trips, results, kicks = {}, {}, {}
local activeTarget = nil
local navRouteOption, gateAllows = true, true
local function getBoolOption(name, default)
    if name == "NavRoute" then return navRouteOption end
    return default
end
local Core = {
    navItineraryState = function(pn) return trips[pn] end,
    navGetTarget = function(pn) return activeTarget end,
    navGateAllows = function(pn, context) return gateAllows end,
    navRouteResult = function(pn, state) results[#results + 1] = { pn = pn, state = state } end,
}
-- kickEngine 樁：只記錄被泵的表面（production 的 idle 早退由呼叫端守）
local function kickEngine(inner) kicks[#kicks + 1] = inner end
local getPlayerMiniMap, ISWorldMap_instance = nil, nil
-- 繪製原語樁：只記「哪個表面、從哪到哪」——本測試要證的是兩張地圖拿到同一份
-- 預覽、後續站確實有線，跟像素無關（真投影/裁切由 test_nav_draw 系列顧）
local draws = {}
local function drawRoutePolyline(inner, route, mapAPI, startIdx, startX, startY, styleU, styleO)
    draws[#draws + 1] = { surface = inner, kind = "route",
        ax = route.sx, ay = route.sy, bx = route.ex, by = route.ey }
end
local function drawApproach(inner, mapAPI, x1, y1, x2, y2, style)
    draws[#draws + 1] = { surface = inner, kind = "approach",
        ax = x1, ay = y1, bx = x2, by = y2 }
end
local ticks, pausedTicks = {}, {}
local Events = {
    OnTick = { Add = function(fn) ticks[#ticks + 1] = fn end },
    OnTickEvenPaused = { Add = function(fn) pausedTicks[#pausedTicks + 1] = fn end },
}
]=]):format(constOf("DEVIATION_DIST"), constOf("REBUILD_COOLDOWN_MS"),
    constOf("REBUILD_MOVE_DIST"), constOf("NOROAD_RETRY_DIST"))

local suffix = [=[
return {
    Core = Core, engine = engine, navRoutes = navRoutes, navPreview = navPreview,
    ensureRoute = ensureRoute, logs = logs, results = results, kicks = kicks,
    players = players, trips = trips,
    draws = draws, drawPreview = drawPreview,
    resetDraws = function() for i = #draws, 1, -1 do draws[i] = nil end end,
    tick = function()
        for i = 1, #pausedTicks do pausedTicks[i]() end
        for i = 1, #ticks do ticks[i]() end
    end,
    pausedTick = function() for i = 1, #pausedTicks do pausedTicks[i]() end end,
    setNow = function(v) nowMs = v end,
    setTarget = function(t) activeTarget = t end,
    setOption = function(v) navRouteOption = v end,
    setGate = function(v) gateAllows = v end,
    setSurfaces = function(mm, wm) getPlayerMiniMap = mm; ISWorldMap_instance = wm end,
}
]=]

local T = assert(compile(
    prelude .. section("nav%-cache") .. "\n" .. section("nav%-preview") .. "\n"
        .. section("nav%-preview%-draw") .. "\n" .. suffix,
    "itinerary-routes"))(NavCore, GRAPH)
local Core = T.Core

local function player(x, y, vehicle)
    return { getX = function() return x end, getY = function() return y end,
        getVehicle = function() return vehicle end }
end
local function stop(id, x, y, status)
    return { id = id, x = x, y = y, status = status or "pending" }
end
local function trip(revision, phase, ...)
    local stops = { ... }
    return { revision = revision, phase = phase, count = #stops, stops = stops }
end
local function keyCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
local function near(a, b, label)
    assert(math.abs(a - b) < 1e-6, label .. "：實得 " .. tostring(a) .. " 期望 " .. tostring(b))
end
-- 推進到「本 tick 不含活動段維護」的位置，讓預覽斷言不被 15 tick 的兜底干擾
local function ticks(n)
    for _ = 1, n do T.tick() end
end

-- 站點：S1 在橫街旁、S2 在縱街旁、S3 在斷連孤島上
local S1X, S1Y = 10750, 9702
local S2X, S2Y = 10800, 9740
local S3X, S3Y = 12050, 12002
local PX, PY = 10710, 9702

--------------------------------------------------------------------------------
-- 一、槽位驗證與預設狀態
--------------------------------------------------------------------------------
local badPn = { "0", nil, {}, true, 0.5, -1, 4, 0 / 0, math.huge }
for i = 1, 9 do
    assert(Core.navSetPreview(badPn[i], true) == false,
        "P0: 壞槽位 #" .. i .. " 須回 false")
end
assert(keyCount(T.navPreview) == 0, "P0: 壞槽位不得建立狀態")
local st, done, total, dist = Core.navPreviewState(0)
assert(st == "off" and done == 0 and total == 0 and dist == 0, "P0: 未開啟回 off/0/0/0")

--------------------------------------------------------------------------------
-- 二、分段預覽：每 tick 一段、真路網距離、未算完不得標完整總長
--------------------------------------------------------------------------------
T.players[0] = player(PX, PY)
T.trips[0] = trip(7, "navigating",
    stop(1, S1X, S1Y), stop(2, S2X, S2Y), stop(3, S3X, S3Y))

-- 先讓活動段走 production ensureRoute 建立真實快取（之後全程比對它沒被動過）
T.setTarget({ x = S1X, y = S1Y })
local activeRoute = T.ensureRoute(0, { x = S1X, y = S1Y }, PX, PY, 3)
assert(activeRoute and T.navRoutes[0].state == "ok", "P1: 活動段須先算出真路線")
local activeIdentity = T.navRoutes[0].route
local activeProgress = T.navRoutes[0].progressIdx
local activeKeys = keyCount(T.navRoutes)

assert(Core.navSetPreview(0, true) == true, "P1: 合法槽位開啟預覽")
st, done, total, dist = Core.navPreviewState(0)
assert(st == "idle" and total == 0, "P1: 剛開啟尚未排程")

T.tick()
st, done, total, dist = Core.navPreviewState(0)
assert(st == "pending" and done == 1 and total == 3,
    "P2: 每 tick 只算一段，實得 state=" .. st .. " done=" .. done .. " total=" .. total)
-- 真路網：玩家(10710,9702)→S1(10750,9702)，橫街 y=9700 同段直達 40 格＋兩端接線各 2
near(dist, 44, "P2: 第一段距離＝路網 40＋接線 2＋2")
local partial = dist

T.tick()
st, done, total, dist = Core.navPreviewState(0)
assert(st == "pending" and done == 2, "P2: 第二段仍為 pending（未全就緒）")
-- S1→S2：橫街 50 格到路口＋縱街 40 格，起點接線 2、終點接線 0
near(dist, partial + 92, "P2: 第二段累加真路網距離")
assert(dist > partial, "P2: distance 只累加已算出的段")

T.tick()
st, done, total, dist = Core.navPreviewState(0)
-- S2→孤島：真正斷連 → 該段無路，狀態降 noroad，距離改記直線估計
assert(st == "noroad" and done == 3 and total == 3,
    "P3: 斷連段須標 noroad，實得 " .. st)
assert(dist > partial + 92, "P3: 無路段以直線估計入帳，不靜默漏算")
assert(#T.results == 0, "P3: 預覽的 noroad 不得通知行程（不得暫停正在行駛的段）")

T.tick()
assert(select(2, Core.navPreviewState(0)) == 3, "P3: 全部算完後不再重算")

--------------------------------------------------------------------------------
-- 三、快取隔離：整輪預覽跑完，活動段 identity／進度／筆數逐一未變
--------------------------------------------------------------------------------
assert(T.navRoutes[0].route == activeIdentity, "P4: 活動路線 table identity 不得被預覽換掉")
assert(T.navRoutes[0].progressIdx == activeProgress, "P4: 活動段進度不得被預覽動到")
assert(keyCount(T.navRoutes) == activeKeys, "P4: 預覽不得在 navRoutes 新增任何 key")
local seg1 = T.navPreview[0].segs[1]
assert(seg1.route and seg1.route ~= activeIdentity,
    "P4: 預覽段是自己的路線物件，不與活動段共用")
assert(T.navPreview[0].segs[3].route == false, "P4: 無路段記為 false，不畫假路線")

-- 之後的預覽情境不需要活動目標；先撤掉，免得 OnTick 的活動段兜底參一腳
T.setTarget(nil)

--------------------------------------------------------------------------------
-- 四、失效條件：revision／graph identity／approach 權重
--------------------------------------------------------------------------------
-- revision：第一站完成後改版 → 重排並從第一段重算（arrived 前綴不入段）
T.trips[0] = trip(8, "navigating",
    stop(1, S1X, S1Y, "arrived"), stop(2, S2X, S2Y), stop(3, S3X, S3Y))
T.tick()
st, done, total, dist = Core.navPreviewState(0)
assert(total == 2 and done == 1 and st == "pending",
    "P5: revision 變更須重排（arrived 站不入段），實得 total=" .. total .. " done=" .. done)
assert(T.navPreview[0].revision == 8, "P5: 快取須記下新 revision")
T.tick()
assert(select(1, Core.navPreviewState(0)) == "noroad", "P5: 新一輪照樣算到孤島段")
local afterRev = select(4, Core.navPreviewState(0))

-- 同 revision 重跑不得再燒 A*（done 已達 total）
T.tick()
near(select(4, Core.navPreviewState(0)), afterRev, "P5: 同 revision 不重算")

-- 編輯完到下個 tick 重排之間：不得端出上一版 revision 的 done/total/distance
local stale = T.trips[0]
T.trips[0] = { revision = stale.revision + 1, count = stale.count, stops = stale.stops }
st, done, total, dist = Core.navPreviewState(0)
assert(st == "pending" and done == 0 and total == 0 and dist == 0,
    "P5b: 編輯後尚未重排時只回 pending/0，實得 " .. st .. "/" .. done .. "/" .. total)
T.tick()
assert(select(2, Core.navPreviewState(0)) == 1, "P5b: 下個 tick 依新 revision 重排")
T.tick()
near(select(4, Core.navPreviewState(0)), afterRev, "P5b: 同站點集合重算得同樣距離")

-- 權重：上車 → approach 權重 3→12，快取失效
T.players[0] = player(PX, PY, {})
T.tick()
st, done = Core.navPreviewState(0)
assert(done == 1 and T.navPreview[0].weight == 12,
    "P6: 上車換 approach 權重須重排，實得 done=" .. done)

-- graph identity：路網重建 → 舊段作廢
T.players[0] = player(PX, PY)
T.tick()
local before = T.navPreview[0].graph
T.engine.graph = buildGraph()
assert(T.engine.graph ~= before, "P7: fixture 須是新的 graph 物件")
T.tick()
assert(T.navPreview[0].graph == T.engine.graph and select(2, Core.navPreviewState(0)) == 1,
    "P7: 路網重建須讓預覽重算")

--------------------------------------------------------------------------------
-- 五、引擎未就緒／選項／gate：丟掉舊段、狀態明確、隱藏表面也能泵冷引擎
--------------------------------------------------------------------------------
T.engine.state = "building"
T.tick()
st, done, total = Core.navPreviewState(0)
assert(st == "idle" and done == 0 and total == 0, "P8: 建置中丟掉舊段並回 idle")
assert(T.navPreview[0].segs == nil, "P8: 舊路網的段不得留著畫")

T.engine.state = "failed"
T.tick()
assert(select(1, Core.navPreviewState(0)) == "failed", "P8: 引擎終態回 failed")

-- idle：以現存（可隱藏）小地圖 inner 與世界地圖單例泵引擎
T.engine.state = "idle"
local hiddenInner = { mapAPI = {}, hidden = true }
local worldMap = { mapAPI = {} }
T.setSurfaces(function(pn) return { inner = hiddenInner } end, worldMap)
T.tick()
assert(#T.kicks == 2 and T.kicks[1] == hiddenInner and T.kicks[2] == worldMap,
    "P9: idle 須泵小地圖 inner 與世界地圖單例（隱藏亦可），實得 " .. #T.kicks)
assert(select(1, Core.navPreviewState(0)) == "idle", "P9: 泵引擎期間狀態為 idle")
assert(Core.navKickAvailable(0) == "idle", "P9: navKickAvailable 回引擎狀態")
T.engine.state = "ready"
local kicksAtReady = #T.kicks
T.tick()
assert(#T.kicks == kicksAtReady, "P9: 非 idle 不得再泵（O(1) 早退）")

-- NavRoute 選項關閉：不算不畫，狀態 disabled（可恢復，與 failed 不同）
T.setOption(false)
T.tick()
st, done, total = Core.navPreviewState(0)
assert(st == "disabled" and total == 0 and T.navPreview[0].segs == nil,
    "P10: NavRoute 關閉須停算並回 disabled")
T.setOption(true)
T.tick()
assert(select(2, Core.navPreviewState(0)) == 1, "P10: 選項恢復即重新排程")

-- 導航 gate（GPS 道具）擋住：同樣停算、可恢復
T.setGate(false)
T.tick()
st, total = Core.navPreviewState(0)
assert(st == "disabled" and T.navPreview[0].segs == nil,
    "P10b: gate 擋住須停算（不得白燒 A*），實得 " .. st)
local burnt = #T.logs
T.tick()
assert(#T.logs == burnt, "P10b: gate 擋住期間不得產生尋路診斷")
T.setGate(true)
T.tick()
assert(select(2, Core.navPreviewState(0)) == 1, "P10b: gate 放行即恢復")

--------------------------------------------------------------------------------
-- 六、預覽尋路例外：只標預覽，done 維持真實完成數
--------------------------------------------------------------------------------
T.engine.graph = { nodeCount = 1 } -- 壞 SoA：production findRoute 以 pcall 回 (nil, err)
T.tick()
st, done, total = Core.navPreviewState(0)
assert(st == "failed" and done == 0,
    "P11: 預覽尋路例外只標 failed 且不得謊報 done，實得 " .. st .. "/" .. done)
assert(T.engine.state == "ready", "P11: 預覽失敗不得把引擎打成 failed（會斷了行駛中的段）")
assert(#T.results == 0, "P11: 預覽失敗不得通知行程")
T.tick()
assert(select(2, Core.navPreviewState(0)) == 0, "P11: failed 後停止續算，不每 tick 重燒 A*")
T.engine.graph = GRAPH
T.tick()
assert(select(2, Core.navPreviewState(0)) == 1, "P11: 換回有效路網即恢復")

--------------------------------------------------------------------------------
-- 七、沒有行程／關閉預覽：零殘留
--------------------------------------------------------------------------------
T.trips[0] = nil
T.tick()
st, done, total = Core.navPreviewState(0)
assert(st == "idle" and total == 0 and T.navPreview[0].segs == nil, "P12: 無行程不留殘骸")

T.trips[0] = trip(9, "navigating", stop(1, S1X, S1Y))
T.tick()
assert(select(2, Core.navPreviewState(0)) == 1, "P12: 重新有行程即恢復排程")
assert(Core.navSetPreview(0, false) == true, "P13: 關閉預覽")
assert(T.navPreview[0] == nil, "P13: 關閉＝整筆丟棄，零殘留")
st, done, total, dist = Core.navPreviewState(0)
assert(st == "off" and done == 0 and total == 0 and dist == 0, "P13: 關閉後回 off/0/0/0")
T.tick()
assert(keyCount(T.navPreview) == 0, "P13: 關閉後的 tick 不得復活狀態")

--------------------------------------------------------------------------------
-- 八、16 站上限（以 trip.count 為準）
--------------------------------------------------------------------------------
local many = {}
for i = 1, 16 do many[i] = stop(i, S1X + i, S1Y) end
T.trips[0] = { revision = 20, count = 16, stops = many }
Core.navSetPreview(0, true)
T.tick()
assert(select(3, Core.navPreviewState(0)) == 16, "P14: 16 站全收")
many[17] = stop(17, S1X + 17, S1Y)
T.trips[0] = { revision = 21, count = 17, stops = many }
T.tick()
assert(select(3, Core.navPreviewState(0)) == 16, "P14: 第 17 站不得進預覽（有界）")
Core.navSetPreview(0, false)

--------------------------------------------------------------------------------
-- 九、活動段結果回報：繪製不通知、非繪製才通知，且僅限目前活動目標
--------------------------------------------------------------------------------
local islandTarget = { x = S3X, y = S3Y }
T.setTarget(islandTarget)
T.trips[0] = trip(30, "navigating", stop(1, S3X, S3Y))
T.setNow(90000)

-- 繪製路徑（drawOneRoute 的呼叫形狀：不帶 notify）：寫快取但不得通知行程
local r, rerr = T.ensureRoute(0, islandTarget, PX, PY, 3)
assert(r == nil and rerr == nil and T.navRoutes[0].state == "noroad",
    "P15: 真斷連目標須落 noroad")
assert(#T.results == 0, "P15: 繪製幀不得改行程狀態（不得通知）")

-- 非繪製路徑（addon 查詢面／OnTick 維護）：確定無路才通知
T.ensureRoute(0, islandTarget, PX, PY, 3, true)
assert(#T.results == 1 and T.results[1].pn == 0 and T.results[1].state == "noroad",
    "P16: 非繪製呼叫端確定無路須通知一次")

-- 非活動目標（addon 查別處）：不得誤報
T.setTarget({ x = S1X, y = S1Y })
T.navRoutes[0] = nil
T.ensureRoute(0, { x = S3X + 5, y = S3Y }, PX, PY, 3, true)
assert(#T.results == 1, "P16: 非目前活動目標的 noroad 不得通知")

-- 分享路線（字串 key）不是行程
T.setTarget(islandTarget)
T.ensureRoute("0:someone", islandTarget, PX, PY, 3, true)
assert(#T.results == 1, "P16: 分享路線的 noroad 不得通知行程")

-- 位移不足時沿用 noroad 快取＝不重複通知（既有 NOROAD_RETRY_DIST 閘門）
T.navRoutes[0] = nil
T.ensureRoute(0, islandTarget, PX, PY, 3, true)
assert(#T.results == 2, "P17: 重新落 noroad 通知一次")
T.ensureRoute(0, islandTarget, PX + 1, PY, 3, true)
assert(#T.results == 2, "P17: 沿用 noroad 快取不得重複通知")

--------------------------------------------------------------------------------
-- 十、活動段的非繪製維護（兩張地圖都關著時的唯一收斂路徑）
--------------------------------------------------------------------------------
-- 可達目標：OnTick 兜底自己把路線算出來（沒有任何繪製幀參與），且是固定間隔
-- 而非每幀——連續 2×LEG_TICKS 個 tick 內恰好跑兩次（與起始相位無關）
T.setTarget({ x = S1X, y = S1Y })
T.trips[0] = trip(31, "navigating", stop(1, S1X, S1Y))
local runs = 0
for _ = 1, LEG_TICKS * 2 do
    T.navRoutes[0] = nil
    T.tick()
    if T.navRoutes[0] then runs = runs + 1 end
end
assert(runs == 2, "P18: 活動段維護須按固定間隔跑，實得 " .. runs .. " 次／"
    .. (LEG_TICKS * 2) .. " tick")
T.navRoutes[0] = nil
ticks(LEG_TICKS)
assert(T.navRoutes[0] and T.navRoutes[0].state == "ok",
    "P18: 維護以非繪製路徑算出活動路線")

-- approach：不再尋路（契約 6.3），不寫快取也不通知
T.navRoutes[0] = nil
T.setTarget(islandTarget)
T.trips[0] = trip(32, "approach", stop(1, S3X, S3Y))
local before18 = #T.results
ticks(LEG_TICKS)
assert(T.navRoutes[0] == nil and #T.results == before18,
    "P19: approach 段不得重新尋路或回報")

-- navigating＋真斷連：非繪製維護回報 noroad
T.trips[0] = trip(33, "navigating", stop(1, S3X, S3Y))
ticks(LEG_TICKS)
assert(#T.results == before18 + 1 and T.results[#T.results].state == "noroad",
    "P20: 兩張圖都關著時仍須發現無路")

-- 引擎終態：extract／建圖／winner 失敗都收斂到 engine.state=failed，須通知一次
T.engine.state = "failed"
local before20 = #T.results
ticks(LEG_TICKS)
assert(#T.results == before20 + 1 and T.results[#T.results].state == "failed",
    "P21: 引擎終態須讓正在導航的 slot 收到 failed")

-- 引擎 idle：維護順手泵冷引擎（不需要任何可見地圖）
T.engine.state = "idle"
local before21 = #T.kicks
ticks(LEG_TICKS)
assert(#T.kicks > before21, "P22: 活動段維護須在 idle 時泵引擎")

-- 沒有活動目標：維護完全不動作
T.setTarget(nil)
T.engine.state = "ready"
T.navRoutes[0] = nil
local before22 = #T.results
ticks(LEG_TICKS)
assert(T.navRoutes[0] == nil and #T.results == before22,
    "P23: 無活動目標的 slot 零成本早退")

--------------------------------------------------------------------------------
-- 十一、多站行程預設自動預覽（玩家不必先開規劃視窗按一次預覽）＋兩張地圖
-- 都畫得到後續站（實機 bug：三站只看得到目前段）
--------------------------------------------------------------------------------
T.setTarget(nil)
T.engine.state, T.engine.graph = "ready", GRAPH
T.players[0] = player(PX, PY) -- 新角色物件＝上一節的明確關閉意願失效
T.trips[0] = trip(40, "navigating",
    stop(1, S1X, S1Y), stop(2, S2X, S2Y), stop(3, S3X, S3Y))
local activeKeysAuto = keyCount(T.navRoutes)
for _ = 1, LEG_TICKS + 3 do T.pausedTick() end -- 暫停看圖時沒有 OnTick，仍須完成預覽。
st, done, total, dist = Core.navPreviewState(0)
assert(total == 3 and done == 3,
    "P24: 自動預覽須照既有節奏算完三段，實得 done=" .. done .. "/" .. total)
assert(keyCount(T.navRoutes) == activeKeysAuto, "P24: 自動預覽不得動到活動路線快取")

local mmInner = { playerNum = 0, mapAPI = {} }
local wmInner = { playerNum = 0, mapAPI = {} }
local function drawnFor(surface)
    local out = {}
    for i = 1, #T.draws do
        if T.draws[i].surface == surface then out[#out + 1] = T.draws[i] end
    end
    return out
end
local function reaches(list, x, y)
    for i = 1, #list do
        if list[i].bx == x and list[i].by == y then return true end
    end
    return false
end
T.resetDraws()
T.drawPreview(mmInner, mmInner.mapAPI, 0)
T.drawPreview(wmInner, wmInner.mapAPI, 0)
local mmDraw, wmDraw = drawnFor(mmInner), drawnFor(wmInner)
assert(#mmDraw > 0 and #mmDraw == #wmDraw,
    "P25: 小地圖與世界地圖須畫出同一份預覽，實得 " .. #mmDraw .. "/" .. #wmDraw)
assert(reaches(mmDraw, S1X, S1Y) and reaches(wmDraw, S1X, S1Y), "P25: 待辦首段須接到第一站")
assert(reaches(mmDraw, S2X, S2Y) and reaches(wmDraw, S2X, S2Y), "P25: 第二站須有路線")
assert(reaches(mmDraw, S3X, S3Y) and reaches(wmDraw, S3X, S3Y),
    "P25: 無路的第三站須有直線指引（不得靜默消失）")

-- 有活動目標時：目前段交給活動青線，預覽不重覆畫，但後續站照樣有線
T.setTarget({ x = S1X, y = S1Y })
T.resetDraws()
T.drawPreview(mmInner, mmInner.mapAPI, 0)
local withTarget = drawnFor(mmInner)
assert(not reaches(withTarget, S1X, S1Y), "P26: 目前段不得與活動線重覆繪製")
assert(reaches(withTarget, S2X, S2Y) and reaches(withTarget, S3X, S3Y),
    "P26: 後續站仍須畫出（實機 bug：只看得到目前段）")
T.setTarget(nil)

--------------------------------------------------------------------------------
-- 十二、單站保留手動、1→2 追加即自動、明確關閉不得自動復活
--------------------------------------------------------------------------------
Core.navSetPreview(0, false)
T.players[0] = player(PX, PY) -- 換角色＝回到預設（關閉意願不跨角色）
T.trips[0] = trip(41, "navigating", stop(1, S1X, S1Y))
ticks(LEG_TICKS)
assert(Core.navPreviewState(0) == "off", "P27: 單站行程不自動開預覽")
T.trips[0] = trip(42, "navigating", stop(1, S1X, S1Y), stop(2, S2X, S2Y))
ticks(LEG_TICKS + 2)
st, done, total = Core.navPreviewState(0)
assert(total == 2 and done == 2,
    "P28: 1→2 追加站後自動啟用並算完，實得 total=" .. total .. " done=" .. done)
Core.navSetPreview(0, false)
ticks(LEG_TICKS * 2)
assert(Core.navPreviewState(0) == "off",
    "P29: 明確關閉須保留（同一角色期間不得自動開回）")
T.resetDraws()
T.drawPreview(mmInner, mmInner.mapAPI, 0)
assert(#T.draws == 0, "P29: 明確關閉不再畫後續路段")
assert(Core.navSetPreview(0, true) == true, "P29: 單站/關閉後仍可手動開")
T.trips[0] = trip(43, "navigating", stop(1, S1X, S1Y))
ticks(2)
assert(select(3, Core.navPreviewState(0)) == 1, "P29: 手動開的單站照樣算一段")

--------------------------------------------------------------------------------
-- 十三、換角色時 Core 重新簽發 revision，新位置的路線取代上一位玩家的線
--------------------------------------------------------------------------------
T.players[0] = player(S2X, S2Y)
T.trips[0] = trip(51, "navigating", stop(1, S1X, S1Y))
T.tick()
st, done, total = Core.navPreviewState(0)
assert(done == 1 and total == 1, "P30: 換角色後依新行程計算")
T.resetDraws()
T.drawPreview(mmInner, mmInner.mapAPI, 0)
local newOrigin = false
for _, line in ipairs(drawnFor(mmInner)) do
    if line.ax == S2X and line.ay == S2Y then newOrigin = true end
end
assert(newOrigin, "P31: 路線由新角色的位置出發，不沿用舊線")

-- 清空行程（編輯/clear）：自動啟用的狀態同樣不留可畫的殘骸
T.trips[0] = nil
T.tick()
st, done, total = Core.navPreviewState(0)
assert(st == "idle" and done == 0 and total == 0,
    "P32: 清空行程後不得留下段")
T.resetDraws()
T.drawPreview(mmInner, mmInner.mapAPI, 0)
assert(#T.draws == 0, "P32: 沒有段就不得畫任何線")

print("test_itinerary_routes: OK（預覽分段/真路網距離 P1-P3、快取隔離 P4、"
    .. "失效條件 P5-P7、引擎/選項/gate P8-P10b、預覽例外 P11、零殘留 P12-P13、"
    .. "16 站上限 P14、回報邊界 P15-P17、非繪製維護 P18-P23、"
    .. "多站預設自動＋雙表面繪製 P24-P26、單站/追加/明確關閉 P27-P29、"
    .. "換角色隔離與清空 P30-P32）")
