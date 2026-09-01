-- Addon 導航查詢面（MinidoracatMiniMapAPI.requestRoute / getNavGraph）離線回歸測試。
-- 仿 test_nav_gate.lua：抽 _NavRoute.lua 的 nav-api 標記區段→補最小 stub→離線跑，
-- 跑的是 production 本體（不在測試裡複製一份包裝邏輯）。
-- 核心不變量（addon 是外部程式碼，傳壞值得當場擋下，不得白燒尋路）：
--   * badargs 從嚴：playerNum 須為 0-3 整數；targetX/Y 須為有限數
--     （NaN／±Infinity 進 A* 後距離比較恆為 false＝跑完整張路網才回 nil）
--   * badargs／noplayer／engine 未 ready 一律不呼叫 ensureRoute（零副作用早退）
--   * 回傳的 route 是主線快取本體（不複製）；graph 亦回引擎本體（唯讀契約）
--   * state 是穩定字串：ok／noroad／badargs／noplayer／engine 狀態
-- 用法：lua scripts/test_nav_api.lua
local srcPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"

local file = assert(io.open(srcPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local mainPath = arg[2]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local mainFile = assert(io.open(mainPath, "rb"))
local mainSource = mainFile:read("*a"):gsub("\r\n", "\n")
mainFile:close()
assert(mainSource:match("MinidoracatMiniMapAPI%.navApiVersion%s*=%s*4"),
    "navApiVersion 必須為 4")

local compile = loadstring or load

local body = assert(source:match(
    "%-%- test:nav%-api:start[^\n]*\n(.-)\n%-%- test:nav%-api:end"),
    "找不到 nav-api 測試區段")

-- prelude 提供本區段於 _NavRoute.lua「之前」已存在的環境：engine／ensureRoute／
-- navRoutes／getSpecificPlayer／MinidoracatMiniMapAPI。
-- 注意：長字串 [=[ 後的首個換行會被 Lua 吃掉，body 與 suffix 之間須補顯式 "\n"
local prelude = [=[
local MinidoracatMiniMapAPI = {}
local engine = {
    state = "ready", graph = nil, patchState = "applied", searchState = "ok",
}
local navRoutes = {}
local players = {}
local calls = {}
local nextRoute, nextRouteState = nil, nil
local detourCalls = {}
local nextDetourRoute, nextDetourError = nil, nil
local NavCore = {
    findRoute = function(graph, sx, sy, tx, ty, ax, ay, ar)
        detourCalls[#detourCalls + 1] = {
            graph = graph, sx = sx, sy = sy, tx = tx, ty = ty,
            ax = ax, ay = ay, ar = ar,
        }
        return nextDetourRoute, nextDetourError
    end,
}
local function logf() end
local function getTimestampMs() return 12345 end
local function failNavEngine()
    engine.state, engine.graph = "failed", nil
    for key in pairs(navRoutes) do navRoutes[key] = nil end
end
local function getSpecificPlayer(pn) return players[pn] end
-- ensureRoute stub：記下實際收到的引數（含 target 表 identity，驗證重用暫存契約）
local function ensureRoute(key, target, px, py)
    calls[#calls + 1] = {
        key = key, target = target, tx = target.x, ty = target.y, px = px, py = py,
    }
    return nextRoute, nextRouteState
end
]=]
local suffix = [=[
return { API = MinidoracatMiniMapAPI, engine = engine, navRoutes = navRoutes,
    players = players, calls = calls, detourCalls = detourCalls,
    setRoute = function(r, state) nextRoute, nextRouteState = r, state end,
    setDetour = function(r, err) nextDetourRoute, nextDetourError = r, err end }
]=]
local T = assert(compile(prelude .. body .. "\n" .. suffix, "nav-api"))()
local API = T.API

local function player(x, y)
    return { getX = function() return x end, getY = function() return y end }
end
local function clear(t) for i = #t, 1, -1 do t[i] = nil end end
local function resetAll()
    T.engine.state = "ready"
    T.engine.searchState = "ok"
    T.engine.patchState = "applied"
    T.engine.graph = nil
    T.players[0], T.players[1], T.players[2], T.players[3] = nil, nil, nil, nil
    T.navRoutes[0], T.navRoutes[1], T.navRoutes[2], T.navRoutes[3] = nil, nil, nil, nil
    T.setRoute(nil)
    T.setDetour(nil, nil)
    clear(T.calls)
    clear(T.detourCalls)
end

local NAN = 0 / 0
local INF = math.huge

--------------------------------------------------------------------------------
-- 一、requestRoute 引數驗證（從嚴；壞值不得進尋路）
--------------------------------------------------------------------------------
-- A1: playerNum 型別／整數性／槽位範圍
resetAll()
T.players[0] = player(0, 0)
local badPn = { "0", nil, {}, true, 0.5, -0.0001, -1, 4, 99, NAN, INF, -INF }
local badPnLabels = { "字串", "nil", "table", "boolean", "0.5", "-0.0001",
    "-1", "4", "99", "NaN", "+Inf", "-Inf" }
for i = 1, 12 do
    local route, state = API.requestRoute(badPn[i], 10, 10)
    assert(route == nil and state == "badargs",
        "A1: playerNum=" .. badPnLabels[i] .. " 須回 badargs，實得 " .. tostring(state))
end

-- A2: targetX/Y 型別與有限性（NaN／±Infinity 是本次 review 的核心缺口）
resetAll()
T.players[0] = player(0, 0)
local badCoords = {
    { "10", 10, "x 字串" }, { 10, "10", "y 字串" },
    { nil, 10, "x nil" }, { 10, nil, "y nil" },
    { {}, 10, "x table" }, { 10, {}, "y table" },
    { NAN, 10, "x NaN" }, { 10, NAN, "y NaN" },
    { INF, 10, "x +Inf" }, { 10, INF, "y +Inf" },
    { -INF, 10, "x -Inf" }, { 10, -INF, "y -Inf" },
    { NAN, NAN, "xy 皆 NaN" },
}
for i = 1, #badCoords do
    local c = badCoords[i]
    local route, state = API.requestRoute(0, c[1], c[2])
    assert(route == nil and state == "badargs",
        "A2: " .. c[3] .. " 須回 badargs，實得 " .. tostring(state))
end

-- A3: badargs 一律零副作用——不查玩家、不進 ensureRoute（不得白跑一輪 A*）
assert(#T.calls == 0, "A3: badargs 不得呼叫 ensureRoute，實得 " .. #T.calls .. " 次")

-- A4: 合法邊界槽位 0 與 3 不得被誤擋（分割畫面第 4 槽）
resetAll()
T.players[0], T.players[3] = player(1, 2), player(3, 4)
T.setRoute({ pts = {} })
T.navRoutes[0], T.navRoutes[3] = { state = "ok" }, { state = "ok" }
local _, s0 = API.requestRoute(0, 10, 10)
local _, s3 = API.requestRoute(3, 10, 10)
assert(s0 == "ok" and s3 == "ok", "A4: 槽位 0／3 須合法，實得 " .. tostring(s0) .. "／" .. tostring(s3))
assert(#T.calls == 2, "A4: 兩次合法呼叫須各進 ensureRoute 一次")

--------------------------------------------------------------------------------
-- 二、早退狀態（noplayer／engine 未 ready）
--------------------------------------------------------------------------------
-- A5: 玩家不存在 → noplayer，且不進 ensureRoute
resetAll()
local route, state = API.requestRoute(1, 10, 10)
assert(route == nil and state == "noplayer", "A5: 無玩家須回 noplayer，實得 " .. tostring(state))
assert(#T.calls == 0, "A5: 無玩家不得呼叫 ensureRoute")

-- A6: engine 未 ready → 原樣回引擎狀態字串，且不進 ensureRoute
--     （idle 亦不在此冷啟動：kickEngine 需要繪製表面的 streets 容器）
resetAll()
T.players[0] = player(0, 0)
local engineStates = { "idle", "extracting", "building", "failed" }
for i = 1, #engineStates do
    T.engine.state = engineStates[i]
    clear(T.calls)
    route, state = API.requestRoute(0, 10, 10)
    assert(route == nil, "A6: engine=" .. engineStates[i] .. " 不得回 route")
    assert(state == engineStates[i],
        "A6: engine 狀態須原樣回傳，實得 " .. tostring(state))
    assert(#T.calls == 0, "A6: engine=" .. engineStates[i] .. " 不得呼叫 ensureRoute")
end

--------------------------------------------------------------------------------
-- 三、ready 路徑：引數轉遞、快取 identity、state 對應
--------------------------------------------------------------------------------
-- A7: ensureRoute 收到 (playerNum, target{x,y}, 玩家座標)；route 原封不動回傳
resetAll()
T.players[2] = player(77, 88)
local cached = {
    pts = { 1, 2, 3, 4 }, len = 42,
    segSurface = { "paved" }, segWidth = { 6 },
    cost = 42, avoidPenalty = 0, approachSurface = "unknown", patchState = "applied",
}
T.setRoute(cached)
T.navRoutes[2] = { state = "ok" }
route, state = API.requestRoute(2, 300, 400)
assert(#T.calls == 1, "A7: 須呼叫 ensureRoute 一次")
assert(T.calls[1].key == 2, "A7: key 須是 playerNum（重用主線同一份快取）")
assert(T.calls[1].tx == 300 and T.calls[1].ty == 400, "A7: 目標座標須原樣轉遞")
assert(T.calls[1].px == 77 and T.calls[1].py == 88, "A7: 起點須取玩家當前座標")
assert(route == cached, "A7: 回傳須是 ensureRoute 產物本體（不複製）")
assert(state == "ok", "A7: state 須取 navRoutes[playerNum].state")
assert(route.segSurface[1] == "paved" and route.segWidth[1] == 6
    and route.cost == 42 and route.avoidPenalty == 0
    and route.approachSurface == "unknown",
    "A7: v4 additive metadata 須隨 route 本體原樣暴露")

-- A8: 目標暫存是重用的同一張表（不每次配置），且 x/y 每次都被覆寫
route, state = API.requestRoute(2, -500, 600)
assert(#T.calls == 2, "A8: 第二次呼叫須再進 ensureRoute")
assert(T.calls[1].target == T.calls[2].target, "A8: 目標暫存須重用同一張表")
assert(T.calls[2].tx == -500 and T.calls[2].ty == 600, "A8: 第二次的座標須覆寫")

-- A9: navRoutes 狀態直通——noroad 與缺條目都回 "noroad"（addon 可直接分支）
T.navRoutes[2] = { state = "noroad" }
route, state = API.requestRoute(2, 10, 20)
assert(state == "noroad", "A9: rs.state=noroad 須直通，實得 " .. tostring(state))
T.navRoutes[2] = nil
route, state = API.requestRoute(2, 10, 20)
assert(state == "noroad", "A9: 無 navRoutes 條目須回 noroad，實得 " .. tostring(state))
-- A10: 無路時 ensureRoute 回 nil → route 為 nil，但仍回穩定字串（非拋錯）
resetAll()
T.players[0] = player(0, 0)
T.setRoute(nil)
T.navRoutes[0] = { state = "noroad" }
route, state = API.requestRoute(0, 10, 10)
assert(route == nil and state == "noroad", "A10: 無路須回 (nil, noroad)")

--------------------------------------------------------------------------------
-- A10b/c: ensureRoute terminal failure 不得沿用空 cache 或舊 ok cache
resetAll()
T.players[0] = player(0, 0)
T.setRoute(nil, "failed")
route, state = API.requestRoute(0, 99, 100)
assert(route == nil and state == "failed" and T.navRoutes[0] == nil,
    "A10b: 無 cache search error 須回 failed")

resetAll()
T.players[0] = player(0, 0)
T.navRoutes[0] = { state = "ok", route = { pts = {} }, tx = 1, ty = 2 }
T.setRoute(nil, "failed")
route, state = API.requestRoute(0, 99, 100)
assert(route == nil and state == "failed",
    "A10c: target-change search error 不得回舊 cache ok")

-- 四、getNavGraph：引擎本體＋狀態（唯讀契約，不得複製 ~4k 節點 SoA）
--------------------------------------------------------------------------------
-- A11: 回的 graph 就是 engine.graph 同一張表；state 同步
resetAll()
local graph = { nodeCount = 3, nx = { 1, 2, 3 } }
T.engine.graph = graph
local g, gs, gps, gss = API.getNavGraph()
assert(g == graph, "A11: getNavGraph 須回 engine.graph 本體（identity）")
assert(gs == "ready" and gps == "applied" and gss == "ok",
    "A11: 須一併回 engine/patch/search 狀態")

-- A12: 未建圖時回 (nil, 狀態)——addon 靠 state 分「還沒好」與「壞了」
T.engine.graph = nil
T.engine.state = "building"
g, gs, gps = API.getNavGraph()
assert(g == nil and gs == "building" and gps == "applied",
    "A12: 未建圖須回 (nil, building, applied)")
T.engine.state = "failed"
g, gs, gps = API.getNavGraph()
assert(g == nil and gs == "failed" and gps == "applied",
    "A12: 失敗須回 (nil, failed, applied)")


--------------------------------------------------------------------------------
-- 五、requestDetour wrapper：簽名不變、所有早退與 ok cache/v4 identity
--------------------------------------------------------------------------------
resetAll()
T.players[0] = player(1, 2)
local detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 0)
assert(detour == nil and detourState == "badargs" and #T.detourCalls == 0,
    "A13: avoidR<=0 badargs 且不得進 A*")

resetAll()
detour, detourState = API.requestDetour(1, 10, 20, 30, 40, 5)
assert(detour == nil and detourState == "noplayer" and #T.detourCalls == 0,
    "A14: detour 無玩家早退")

resetAll()
T.players[0] = player(1, 2)
T.engine.state = "building"
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5)
assert(detour == nil and detourState == "building" and #T.detourCalls == 0,
    "A15: detour engine state 直通")

resetAll()
T.players[0] = player(1, 2)
T.engine.graph = { id = "graph" }
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5)
assert(detour == nil and detourState == "noroad" and #T.detourCalls == 1
    and T.navRoutes[0] == nil, "A16: detour noroad 不寫 cache")

resetAll()
T.players[2] = player(7, 8)
T.engine.graph = { id = "graph" }
local detourV4 = {
    pts = { 1, 2, 3, 4 }, len = 2, cost = 2, avoidPenalty = 0,
    segSurface = { "paved" }, segWidth = { 6 }, approachSurface = "unknown",
    sx = 1, sy = 2, ex = 3, ey = 4, tx = 50, ty = 60,
}
T.setDetour(detourV4, nil)
detour, detourState = API.requestDetour(2, 50, 60, 70, 80, 9)
local dc = T.detourCalls[1]
assert(detour == detourV4 and detourState == "ok", "A17: detour v4 route identity 原樣回傳")
assert(dc.graph == T.engine.graph and dc.sx == 7 and dc.sy == 8
    and dc.tx == 50 and dc.ty == 60 and dc.ax == 70 and dc.ay == 80 and dc.ar == 9,
    "A17: detour 六參數與玩家/graph 原樣轉遞")
assert(T.navRoutes[2].route == detourV4 and T.navRoutes[2].state == "ok"
    and T.navRoutes[2].progressIdx == 1 and T.navRoutes[2].lastBuildMs == 12345
    and T.navRoutes[2].buildX == 7 and T.navRoutes[2].buildY == 8,
    "A17: detour 成功覆寫共用 cache")

resetAll()
T.players[0] = player(1, 2)
T.engine.graph = { id = "graph" }
T.setDetour(detourV4, "boom")
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5)
assert(detour == nil and detourState == "failed" and T.navRoutes[0] == nil
    and T.engine.state == "failed" and #T.detourCalls == 1,
    "A18: detour err terminal、latch engine failed、不寫 cache")
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5)
assert(detour == nil and detourState == "failed" and #T.detourCalls == 1,
    "A18: failed latch 後重呼不得再進 findRoute")

--------------------------------------------------------------------------------
-- 六、ensureRoute 快取／偏航（test:nav-cache 區段；跑 production 本體）
-- 實測病灶（2026-09-01 AutoDrive telemetry）：車在 (10716,9756) 拿到首點
-- (10716,9737) 的舊線——偏航 19 格 < 舊 DEVIATION_DIST=28 就一直沿用快取。
-- 小地圖靠 progressIdx 裁切藏住，addon 拿到未裁切本體＝被要求先斜穿 19 格房屋。
--------------------------------------------------------------------------------
local cacheBody = assert(source:match(
    "%-%- test:nav%-cache:start[^\n]*\n(.-)\n%-%- test:nav%-cache:end"),
    "找不到 nav-cache 測試區段")
-- 常數取自 production 原始碼（測試不得自帶第二份數值，否則調參時測試照樣綠）
local function constOf(name)
    return assert(tonumber(source:match("\nlocal " .. name .. " = (%-?[%d%.]+)")),
        "找不到常數 " .. name)
end
local DEVIATION_DIST = constOf("DEVIATION_DIST")
local REBUILD_COOLDOWN_MS = constOf("REBUILD_COOLDOWN_MS")
local REBUILD_MOVE_DIST = constOf("REBUILD_MOVE_DIST")
assert(DEVIATION_DIST < 19,
    "C0: DEVIATION_DIST 須小於實測病灶的 19 格偏航，實得 " .. DEVIATION_DIST)

local cachePrelude = ([=[
local floor, sqrt = math.floor, math.sqrt
local DEVIATION_DIST, REBUILD_COOLDOWN_MS = %s, %s
local REBUILD_MOVE_DIST, NOROAD_RETRY_DIST = %s, %s
local navRoutes = {}
local engine = { state = "ready", graph = { id = "g" }, patchState = "applied" }
local nowMs = 0
local findCalls = {}
local nextRoute, nextErr = nil, nil
local cleared = {}
local function dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end
local NavCore = {
    -- 真投影（非常數 stub）：偏航閾值是本節的受測對象，量測面必須是真幾何
    distToRoute = function(route, x, y)
        local pts = route.pts
        local bestD2, bi, bx, by = math.huge, 1, pts[1], pts[2]
        for i = 1, #pts / 2 - 1 do
            local ax, ay = pts[i * 2 - 1], pts[i * 2]
            local cx, cy = pts[i * 2 + 1], pts[i * 2 + 2]
            local dx, dy = cx - ax, cy - ay
            local l2 = dx * dx + dy * dy
            local t = 0
            if l2 > 1e-12 then
                t = ((x - ax) * dx + (y - ay) * dy) / l2
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
            end
            local qx, qy = ax + dx * t, ay + dy * t
            local d2v = dist2(x, y, qx, qy)
            if d2v < bestD2 then bestD2, bi, bx, by = d2v, i, qx, qy end
        end
        return sqrt(bestD2), bi, bx, by
    end,
    findRoute = function(graph, sx, sy, tx, ty)
        findCalls[#findCalls + 1] = { sx = sx, sy = sy, tx = tx, ty = ty }
        if nextErr then return nil, nextErr end
        if not nextRoute then return nil end
        return {
            pts = { nextRoute[1], nextRoute[2], nextRoute[3], nextRoute[4] },
            sx = nextRoute[1], sy = nextRoute[2],
            snapDist = sqrt(dist2(sx, sy, nextRoute[1], nextRoute[2])),
        }
    end,
}
local function getTimestampMs() return nowMs end
local function clearRoute(key) navRoutes[key] = nil; cleared[#cleared + 1] = key end
local function failNavEngine()
    engine.state, engine.graph = "failed", nil
    for k in pairs(navRoutes) do navRoutes[k] = nil end
end
local function logf() end
]=]):format(DEVIATION_DIST, REBUILD_COOLDOWN_MS, REBUILD_MOVE_DIST,
    constOf("NOROAD_RETRY_DIST"))
local cacheSuffix = [=[
return { ensureRoute = ensureRoute, navRoutes = navRoutes, engine = engine,
    findCalls = findCalls, cleared = cleared,
    setNow = function(v) nowMs = v end,
    setNext = function(r, e) nextRoute, nextErr = r, e end }
]=]
local C = assert(compile(cachePrelude .. cacheBody .. "\n" .. cacheSuffix, "nav-cache"))()
local tgt = { x = 10744.8, y = 9717.5 }

-- C1: 首算寫入 buildX/buildY（偏航重算的位移閘門需要它；漏寫＝閘門永遠擋住）
C.setNow(1000)
C.setNext({ 10716, 9737, 10751, 9737 })
local cr = C.ensureRoute(0, tgt, 10716, 9737)
assert(cr and #C.findCalls == 1, "C1: 首算須跑 findRoute")
assert(C.navRoutes[0].buildX == 10716 and C.navRoutes[0].buildY == 9737,
    "C1: cache 須記下本次 A* 起點")
assert(math.abs(cr.snapDist) < 1e-9, "C1: 站在 snap 點上 snapDist≈0")

-- C2: 走廊內（偏航 ≤ 閾值）沿用同一張表，snapDist 刷新成當下實距
cr = C.ensureRoute(0, tgt, 10719, 9737)
assert(cr == C.navRoutes[0].route and #C.findCalls == 1, "C2: 走廊內須命中快取")
assert(math.abs(cr.snapDist - 3) < 1e-9,
    "C2: snapDist 須刷新成當下 3 格，實得 " .. tostring(cr.snapDist))

-- C3: 實測病灶——車北移到 (10716,9756)，偏航 19 格、冷卻已過 → 必須重算
C.setNow(1000 + REBUILD_COOLDOWN_MS + 1)
C.setNext({ 10714.5, 9756, 10714.5, 9737 })
local before = C.navRoutes[0].route
cr = C.ensureRoute(0, tgt, 10716, 9756)
assert(#C.findCalls == 2 and cr ~= before, "C3: 偏航 19 格須重算，不得沿用舊線")
assert(cr.snapDist < DEVIATION_DIST,
    "C3: 重算後 snapDist 須落在一個路幅內，實得 " .. tostring(cr.snapDist))
assert(C.navRoutes[0].buildX == 10716 and C.navRoutes[0].buildY == 9756,
    "C3: 重算須更新 build 錨點")

-- C4: 偏航逾閾但冷卻未過 → 沿用舊表、不得白燒 A*
C.setNow(1000 + REBUILD_COOLDOWN_MS + 2)
before = C.navRoutes[0].route
cr = C.ensureRoute(0, tgt, 10716, 9756 + DEVIATION_DIST + 50)
assert(cr == before and #C.findCalls == 2, "C4: 冷卻內不得重算")

-- C5/C6 深野外：路網最近點本來就遠（首點必遠、偏航恆成立），冷卻到期就重跑
-- ＝每 3s 產一條幾何相同的新表。位移閘門才是這裡唯一的止血點。
local far = { x = 6000, y = 6000 }
C.setNow(20000)
C.setNext({ 5000, 5100, 5100, 5100 })
cr = C.ensureRoute(1, far, 5000, 5000)
assert(#C.findCalls == 3 and math.abs(cr.snapDist - 100) < 1e-9,
    "C5: 深野外首算 snapDist 須為實距 100")

-- C5: 冷卻已過但玩家近乎原地 → 同一張表（重算必得同一條線，換 identity 是純浪費）
C.setNow(20000 + REBUILD_COOLDOWN_MS + 1)
before = C.navRoutes[1].route
cr = C.ensureRoute(1, far, 5000 + REBUILD_MOVE_DIST - 1, 5000)
assert(cr == before and #C.findCalls == 3,
    "C5: 位移不足 REBUILD_MOVE_DIST 不得重算（table identity 須穩定）")

-- C6: 位移足夠 → 才重算
cr = C.ensureRoute(1, far, 5000 + REBUILD_MOVE_DIST + 1, 5000)
assert(#C.findCalls == 4 and cr ~= before, "C6: 位移足夠且偏航逾閾須重算")

print("test_nav_api: OK（nav API v4＋requestRoute A1-A12＋requestDetour A13-A18"
    .. "＋ensureRoute 快取/偏航 C0-C6）")
