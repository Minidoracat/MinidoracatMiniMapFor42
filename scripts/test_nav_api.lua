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

local compile = loadstring or load

local body = assert(source:match(
    "%-%- test:nav%-api:start[^\n]*\n(.-)\n%-%- test:nav%-api:end"),
    "找不到 nav-api 測試區段")
-- 快取失效三處（世界重置、clearRoute／Core.navInvalidateRoute、failNavEngine）跑 production 本體：v11 待接受的改道
-- 要跟著撤銷（base＝nil 時只比 base 分不出「清過了」）
local invalidateBody = assert(source:match(
    "%-%- test:nav%-invalidate:start[^\n]*\n(.-)\n%-%- test:nav%-invalidate:end"),
    "找不到 nav-invalidate 測試區段")

-- prelude 提供本區段於 _NavRoute.lua「之前」已存在的環境：engine／ensureRoute／
-- navRoutes／navDetours／getSpecificPlayer／MinidoracatMiniMapAPI；中間接 nav-invalidate 區段（production）。
-- 注意：長字串 [=[ 後的首個換行會被 Lua 吃掉，body 與 suffix 之間須補顯式 "\n"
local prelude = [=[
local MinidoracatMiniMapAPI = {}
local engine = {
    state = "ready", graph = nil, patchState = "applied", searchState = "ok",
}
local navRoutes = {}
local navPreview = {}
local navDetours = {}
local logOnce = {}
local Core = {}
local worldReset = nil
local Events = { OnGameStart = { Add = function(fn) worldReset = fn end } }
local players = {}
local calls = {}
local nextRoute, nextRouteState = nil, nil
local detourCalls = {}
local nextDetourRoute, nextDetourError = nil, nil
local kicks = {}
local nextKickState = nil
local NavCore = {
    findRoute = function(graph, sx, sy, tx, ty, ax, ay, ar, approachWeight, more, maxSnap, pn)
        detourCalls[#detourCalls + 1] = {
            graph = graph, sx = sx, sy = sy, tx = tx, ty = ty,
            ax = ax, ay = ay, ar = ar, w = approachWeight, more = more, maxSnap = maxSnap, pn = pn,
        }
        return nextDetourRoute, nextDetourError
    end,
}
local function logf() end
local function getTimestampMs() return 12345 end
]=] .. invalidateBody .. "\n" .. [=[
-- approachWeightFor 定義在 nav-cache 區段（production 同檔在前），這裡給同語意樁
local function approachWeightFor(p) return p:getVehicle() and 12 or 3 end
local function getSpecificPlayer(pn) return players[pn] end
-- navKickAvailable 定義在 nav-preview 區段（production 同檔在前）：記下槽位，可模擬泵完的引擎狀態
local function navKickAvailable(pn)
    kicks[#kicks + 1] = pn
    if nextKickState then engine.state = nextKickState end
    return engine.state
end
-- ensureRoute stub：記下實際收到的引數（含 target 表 identity，驗證重用暫存契約）
local function ensureRoute(key, target, px, py, weight, notify, pn)
    calls[#calls + 1] = {
        key = key, target = target, tx = target.x, ty = target.y, px = px, py = py, w = weight,
        notify = notify, pn = pn,
    }
    return nextRoute, nextRouteState
end
]=]
local suffix = [=[
return { API = MinidoracatMiniMapAPI, engine = engine, navRoutes = navRoutes, navDetours = navDetours,
    players = players, calls = calls, detourCalls = detourCalls, kicks = kicks,
    invalidate = Core.navInvalidateRoute, worldReset = worldReset, failNavEngine = failNavEngine,
    setRoute = function(r, state) nextRoute, nextRouteState = r, state end,
    setKick = function(state) nextKickState = state end,
    setDetour = function(r, err) nextDetourRoute, nextDetourError = r, err end }
]=]
local T = assert(compile(prelude .. body .. "\n" .. suffix, "nav-api"))()
local API = T.API

local function player(x, y, vehicle)
    return { getX = function() return x end, getY = function() return y end,
        getVehicle = function() return vehicle end }
end
local function clear(t) for i = #t, 1, -1 do t[i] = nil end end
local function resetAll()
    T.engine.state = "ready"
    T.engine.searchState = "ok"
    T.engine.patchState = "applied"
    T.engine.graph = nil
    T.players[0], T.players[1], T.players[2], T.players[3] = nil, nil, nil, nil
    for k in pairs(T.navRoutes) do T.navRoutes[k] = nil end
    for k in pairs(T.navDetours) do T.navDetours[k] = nil end
    T.setRoute(nil)
    T.setKick(nil)
    T.setDetour(nil, nil)
    clear(T.calls)
    clear(T.detourCalls)
    clear(T.kicks)
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
assert(T.calls[1].w == 3, "A7: 徒步 approach 權重 3 須傳進 ensureRoute")
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
assert(dc.w == 3 and T.navRoutes[2].approachWeight == 3,
    "A17: 徒步 detour 帶 approach 權重 3 並記進 cache")
T.players[2].getVehicle = function() return {} end
T.setDetour(detourV4, nil)
detour, detourState = API.requestDetour(2, 50, 60, 70, 80, 9)
assert(T.detourCalls[2].w == 12 and T.navRoutes[2].approachWeight == 12,
    "A17: 車上 detour 帶 approach 權重 12（cache 記權重，下車後 ensureRoute 會換檔重算）")

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

-- A19（v9）：第 7 參 moreAvoid 原表轉給 findRoute；不傳＝nil（v8 呼叫逐位元不變）
resetAll()
T.players[0] = player(1, 2)
T.engine.graph = { id = "graph" }
T.setDetour(detourV4, nil)
local more = { 100, 200, 40, -5.5, 7, 12 }
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, more)
assert(detour == detourV4 and detourState == "ok" and T.detourCalls[1].more == more,
    "A19: moreAvoid 原表轉遞給 findRoute")
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5)
assert(detourState == "ok" and T.detourCalls[2].more == nil, "A19: 六參數呼叫不帶 moreAvoid")

-- A20（v9）：moreAvoid 驗參同主圈——外部傳壞值當場擋下、不進 A*
for label, bad in pairs({
    ["非表"] = 5, ["長度非 3 倍數"] = { 1, 2 }, ["超過 8 圈"] = {
        1, 1, 1, 2, 2, 1, 3, 3, 1, 4, 4, 1, 5, 5, 1, 6, 6, 1, 7, 7, 1, 8, 8, 1, 9, 9, 1 },
    ["NaN"] = { NAN, 0, 5 }, ["Infinity"] = { 0, INF, 5 }, ["r=0"] = { 0, 0, 0 }, ["r<0"] = { 0, 0, -1 },
    ["非數字"] = { "a", 0, 5 },
}) do
    resetAll()
    T.players[0] = player(1, 2)
    T.engine.graph = { id = "graph" }
    detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, bad)
    assert(detour == nil and detourState == "badargs" and #T.detourCalls == 0,
        "A20: moreAvoid " .. label .. " → badargs 且不進 A*")
end

-- A21（v10）：第 8 參 maxSnap 原值轉給 findRoute；不傳＝nil（v9 呼叫逐位元不變）
resetAll()
T.players[0] = player(1, 2)
T.engine.graph = { id = "graph" }
T.setDetour(detourV4, nil)
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, nil, 20)
assert(detour == detourV4 and detourState == "ok" and T.detourCalls[1].maxSnap == 20
    and T.detourCalls[1].more == nil, "A21: maxSnap 轉遞給 findRoute")
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, more)
assert(detourState == "ok" and T.detourCalls[2].maxSnap == nil and T.detourCalls[2].more == more,
    "A21: 七參數呼叫不帶 maxSnap")

-- A22（v10）：maxSnap 須是有限正數——壞值當場 badargs、不進 A*
for label, bad in pairs({
    ["非數字"] = "20", ["0"] = 0, ["負數"] = -1, ["NaN"] = NAN, ["Infinity"] = INF, ["表"] = {},
}) do
    resetAll()
    T.players[0] = player(1, 2)
    T.engine.graph = { id = "graph" }
    detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, nil, bad)
    assert(detour == nil and detourState == "badargs" and #T.detourCalls == 0,
        "A22: maxSnap " .. label .. " → badargs 且不進 A*")
end

-- A23（v11）：第 9 參 deferCommit=true——算出照回、引數照轉，但不寫快取（藍線與 requestRoute 維持原線）
local function detourRoute(tag)
    return { tag = tag, pts = { 1, 2, 3, 4 }, len = 2, cost = 2, avoidPenalty = 0,
        segSurface = { "paved" }, segWidth = { 6 }, sx = 1, sy = 2, ex = 3, ey = 4 }
end
local function deferredSetup()
    resetAll()
    T.players[0] = player(7, 8)
    T.engine.graph = { id = "graph" }
    local base = { state = "ok", route = detourRoute("base"), tx = 10, ty = 20 }
    T.navRoutes[0] = base
    return base
end
local base = deferredSetup()
local dA = detourRoute("A")
T.setDetour(dA, nil)
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, nil, 20, true)
assert(detour == dA and detourState == "ok" and T.detourCalls[1].maxSnap == 20 and T.navRoutes[0] == base,
    "A23: deferCommit=true 回改道線但不寫快取")
-- A24：commitDetour 收這條＝寫進快取（同 v10 覆寫的欄位），重複 commit 冪等
local cok, cstate = API.commitDetour(0, dA)
local rs0 = T.navRoutes[0]
assert(cok == true and cstate == "ok" and rs0 ~= base and rs0.route == dA and rs0.state == "ok"
    and rs0.progressIdx == 1 and rs0.tx == 10 and rs0.ty == 20 and rs0.buildX == 7 and rs0.buildY == 8
    and rs0.lastBuildMs == 12345 and rs0.approachWeight == 3, "A24: commit 後快取＝改道線（欄位同 v10 覆寫）")
cok, cstate = API.commitDetour(0, dA)
assert(cok == true and cstate == "ok" and T.navRoutes[0] == rs0, "A24: 快取已是這條＝再 commit 仍 ok、不換條目")
-- A25：stale 一律不寫——別的表、被新請求取代、快取期間換過、引擎失敗、別的槽、非 deferred／無路請求之後
local function staleCase(label, prep, route, pn)
    local b = deferredSetup()
    local d = detourRoute("S")
    T.setDetour(d, nil)
    API.requestDetour(0, 10, 20, 30, 40, 5, nil, nil, true)
    local r = prep and prep(d) or d
    local okc, st = API.commitDetour(pn or 0, route or r)
    assert(okc == false and st == "stale" and (T.navRoutes[0] == b or T.navRoutes[0] == nil
        or T.navRoutes[0].route ~= d), "A25: " .. label .. " → (false, stale) 且不寫，實得 " .. tostring(st))
end
staleCase("別的 table", nil, detourRoute("other"))
staleCase("新的 deferred 請求取代", function(d)
    T.setDetour(detourRoute("B"), nil)
    API.requestDetour(0, 10, 20, 30, 40, 5, nil, nil, true)
    return d
end)
staleCase("之後的非 deferred 請求", function(d)
    local b2 = detourRoute("C")
    T.setDetour(b2, nil)
    API.requestDetour(0, 10, 20, 30, 40, 5)
    assert(T.navRoutes[0].route == b2, "A25: 不帶第 9 參照 v10 覆寫快取")
    return d
end)
staleCase("之後的無路請求", function(d)
    T.setDetour(nil, nil)
    API.requestDetour(0, 10, 20, 30, 40, 5, nil, nil, true)
    return d
end)
staleCase("快取期間被重算換掉", function(d)
    T.navRoutes[0] = { state = "ok", route = detourRoute("rebuilt"), tx = 10, ty = 20 }
    return d
end)
staleCase("快取期間被清掉（換目標）", function(d) T.navRoutes[0] = nil return d end)
staleCase("引擎失敗", function(d) T.engine.state = "failed" return d end)
staleCase("別的槽位", nil, nil, 1)
-- A26：deferCommit=false 等同不傳（v10 覆寫）；壞值 badargs 且不進 A*
deferredSetup()
T.setDetour(dA, nil)
detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, nil, nil, false)
assert(detourState == "ok" and T.navRoutes[0].route == dA, "A26: deferCommit=false 照 v10 覆寫快取")
for label, bad in pairs({ ["字串"] = "true", ["數字"] = 1, ["表"] = {} }) do
    deferredSetup()
    detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, nil, nil, bad)
    assert(detour == nil and detourState == "badargs" and #T.detourCalls == 0,
        "A26: deferCommit " .. label .. " → badargs 且不進 A*")
end
-- A27：commitDetour 驗參——槽位同 requestRoute、route 須是表
for label, args in pairs({ ["槽位 4"] = { 4, dA }, ["槽位 0.5"] = { 0.5, dA }, ["槽位 NaN"] = { NAN, dA },
    ["槽位字串"] = { "0", dA }, ["route nil"] = { 0, nil }, ["route 字串"] = { 0, "r" } }) do
    cok, cstate = API.commitDetour(args[1], args[2])
    assert(cok == false and cstate == "badargs", "A27: commitDetour " .. label .. " → badargs")
end

-- A28（v11）：快取原本是 nil（base＝nil）時，快取失效也要讓待接受的改道失效——清成 nil 前後都是 nil，只比 base 分不出來。
-- 三處失效（production nav-invalidate 區段）：Core.navInvalidateRoute（_Itinerary 換目標／取消活動站走這條）、世界重置、
-- 引擎失敗。後兩者把 engine 打成 idle／failed，這裡手動拉回 ready（＝之後重建好），只驗 navDetours 有沒有被撤銷。
local function nilBaseSetup()
    resetAll()
    T.players[0], T.players[1] = player(7, 8), player(1, 1)
    T.engine.graph = { id = "graph" }
    local d = detourRoute("nil-base")
    T.setDetour(d, nil)
    detour, detourState = API.requestDetour(0, 10, 20, 30, 40, 5, nil, nil, true)
    assert(detour == d and detourState == "ok" and T.navRoutes[0] == nil, "A28: 前提：快取是 nil 時 deferred 照回、不寫")
    return d
end
local dn = nilBaseSetup()
cok, cstate = API.commitDetour(0, dn)
assert(cok == true and cstate == "ok" and T.navRoutes[0] and T.navRoutes[0].route == dn,
    "A28: 快取是 nil、中間沒失效＝照常 commit（nil 基底不是一律拒）")
dn = nilBaseSetup()
T.invalidate(1)
cok, cstate = API.commitDetour(0, dn)
assert(cok == true and cstate == "ok", "A28: 別的槽位清快取不影響這一槽待接受的改道")
for label, invalidate in pairs({
    ["換目標／取消（Core.navInvalidateRoute）"] = function() T.invalidate(0) end,
    ["世界重置（OnGameStart）"] = function() T.worldReset(); T.engine.state = "ready" end,
    ["引擎失敗（failNavEngine）"] = function() T.failNavEngine("boom"); T.engine.state = "ready" end,
}) do
    dn = nilBaseSetup()
    invalidate()
    cok, cstate = API.commitDetour(0, dn)
    assert(cok == false and cstate == "stale" and T.navRoutes[0] == nil,
        "A28: 快取 nil→" .. label .. "→commit＝(false, stale) 且不寫，實得 " .. tostring(cok) .. "/" .. tostring(cstate))
end

--------------------------------------------------------------------------------
-- 五b、v13 requestRouteFrom／requestDetourFrom：從指定起點算路，快取在 "from:"..pn，不碰玩家那一格
-- （navRoutes[pn] 會畫藍線、判行程到站；召喚寫進去＝玩家的導航被換成車的路線）
--------------------------------------------------------------------------------
-- F1：起點／槽位／目標壞值＝badargs，零副作用（不泵引擎、不進 ensureRoute）
for label, args in pairs({
    ["起點 NaN"] = { 0, NAN, 5, 10, 10 }, ["起點 Infinity"] = { 0, 5, INF, 10, 10 },
    ["起點字串"] = { 0, "5", 5, 10, 10 }, ["起點 nil"] = { 0, nil, 5, 10, 10 },
    ["槽位 4"] = { 4, 5, 5, 10, 10 }, ["槽位表"] = { {}, 5, 5, 10, 10 },
    ["目標 NaN"] = { 0, 5, 5, NAN, 10 }, ["目標 nil"] = { 0, 5, 5, 10, nil },
}) do
    resetAll()
    T.players[0] = player(1, 2)
    T.engine.state = "idle"
    local r, st = API.requestRouteFrom(args[1], args[2], args[3], args[4], args[5])
    assert(r == nil and st == "badargs" and #T.calls == 0 and #T.kicks == 0,
        "F1: requestRouteFrom " .. label .. " → badargs 且不泵、不進 ensureRoute，實得 " .. tostring(st))
end
-- F2：沒有玩家＝noplayer，不泵引擎
resetAll()
T.engine.state = "idle"
route, state = API.requestRouteFrom(1, 5, 5, 10, 10)
assert(route == nil and state == "noplayer" and #T.kicks == 0 and #T.calls == 0, "F2: noplayer 早退且不泵")
-- F3：引擎 idle＝先泵一次（召喚時玩家多半沒有導航目標，沒人會啟動它），回泵完的狀態；其他狀態不泵、原樣回
resetAll()
T.players[2] = player(1, 2)
T.engine.state = "idle"
T.setKick("extracting")
route, state = API.requestRouteFrom(2, 5, 5, 10, 10)
assert(route == nil and state == "extracting" and #T.kicks == 1 and T.kicks[1] == 2 and #T.calls == 0,
    "F3: idle 先 navKickAvailable(pn)，回泵完的狀態、不進 ensureRoute，實得 " .. tostring(state))
resetAll()
T.players[0] = player(1, 2)
T.engine.state = "idle"
route, state = API.requestRouteFrom(0, 5, 5, 10, 10)
assert(state == "idle" and #T.kicks == 1, "F3: 泵不動（沒有地圖表面）照回 idle")
for _, es in ipairs({ "extracting", "building", "failed" }) do
    resetAll()
    T.players[0] = player(1, 2)
    T.engine.state = es
    route, state = API.requestRouteFrom(0, 5, 5, 10, 10)
    assert(route == nil and state == es and #T.kicks == 0 and #T.calls == 0, "F3: " .. es .. " 不泵、原樣回")
end
resetAll()
T.players[0] = player(1, 2)
T.engine.state = "idle"
API.requestRoute(0, 10, 10)
assert(#T.kicks == 0, "F3: requestRoute 照舊不泵（契約不變）")
-- F4：ready＝ensureRoute("from:"..pn, {toX,toY}, 起點, 權重 12, 不通知行程, pn)；玩家那一格不動
resetAll()
T.players[3] = player(1, 2)
local base3 = { state = "ok", route = { tag = "player" }, tx = 99, ty = 99 }
T.navRoutes[3] = base3
local fromRoute = { tag = "from", snapDist = 1.5 }
T.setRoute(fromRoute, nil)
T.navRoutes["from:3"] = { state = "ok", route = fromRoute }
route, state = API.requestRouteFrom(3, 500.5, 600.5, 700, 800)
local fc = T.calls[1]
assert(route == fromRoute and state == "ok", "F4: route 原樣回、state 取 from 格")
assert(fc.key == "from:3" and fc.tx == 700 and fc.ty == 800 and fc.px == 500.5 and fc.py == 600.5
    and fc.w == 12 and fc.notify == nil and fc.pn == 3,
    "F4: ensureRoute 收到 from key、起點座標、權重 12、notify=nil、pn")
assert(T.navRoutes[3] == base3, "F4: 玩家自己的導航快取不動")
T.navRoutes["from:3"] = { state = "noroad" }
T.setRoute(nil, nil)
route, state = API.requestRouteFrom(3, 500.5, 600.5, 700, 800)
assert(route == nil and state == "noroad", "F4: from 格 noroad 直通")
T.setRoute(nil, "failed")
route, state = API.requestRouteFrom(3, 500.5, 600.5, 700, 800)
assert(route == nil and state == "failed", "F4: ensureRoute terminal 狀態直通")

-- F5：requestDetourFrom 驗參同 requestDetour（另驗起點），壞值不進 A*；槽位不是數字也不得拋錯
for label, args in pairs({
    ["起點 NaN"] = { 0, NAN, 5, 10, 10, 30, 40, 5 }, ["起點 nil"] = { 0, nil, 5, 10, 10, 30, 40, 5 },
    ["槽位表"] = { {}, 5, 5, 10, 10, 30, 40, 5 }, ["槽位 nil"] = { nil, 5, 5, 10, 10, 30, 40, 5 },
    ["avoidR 0"] = { 0, 5, 5, 10, 10, 30, 40, 0 }, ["avoidX Infinity"] = { 0, 5, 5, 10, 10, INF, 40, 5 },
    ["moreAvoid 長度"] = { 0, 5, 5, 10, 10, 30, 40, 5, { 1, 2 } }, ["maxSnap 0"] = { 0, 5, 5, 10, 10, 30, 40, 5, nil, 0 },
    ["目標 NaN"] = { 0, 5, 5, NAN, 10, 30, 40, 5 },
}) do
    resetAll()
    T.players[0] = player(1, 2)
    T.engine.graph = { id = "graph" }
    local ok, r, st = pcall(API.requestDetourFrom, args[1], args[2], args[3], args[4], args[5], args[6], args[7],
        args[8], args[9], args[10])
    assert(ok and r == nil and st == "badargs" and #T.detourCalls == 0,
        "F5: requestDetourFrom " .. label .. " → badargs 且不進 A*，實得 " .. tostring(ok) .. "/" .. tostring(st))
end
-- F6：從起點算、權重 12、帶 pn；一律 deferCommit：兩格都不寫，commitDetour 才寫進 from 格，玩家那一格不動
local function fromSetup()
    resetAll()
    T.players[0] = player(7, 8)
    T.engine.graph = { id = "graph" }
    local playerBase = { state = "ok", route = detourRoute("player"), tx = 10, ty = 20 }
    local fromBase = { state = "ok", route = detourRoute("from-base"), tx = 10, ty = 20 }
    T.navRoutes[0], T.navRoutes["from:0"] = playerBase, fromBase
    return playerBase, fromBase
end
local pBase, fBase = fromSetup()
local dF = detourRoute("F")
T.setDetour(dF, nil)
local more2 = { 1, 1, 3 }
detour, detourState = API.requestDetourFrom(0, 500, 600, 10, 20, 30, 40, 5, more2, 20)
dc = T.detourCalls[1]
assert(detour == dF and detourState == "ok", "F6: 改道線原樣回")
assert(dc.sx == 500 and dc.sy == 600 and dc.tx == 10 and dc.ty == 20 and dc.ax == 30 and dc.ay == 40 and dc.ar == 5
    and dc.more == more2 and dc.maxSnap == 20 and dc.w == 12 and dc.pn == 0,
    "F6: findRoute 從起點算、權重 12、避讓參數與 pn 原樣轉遞")
assert(T.navRoutes[0] == pBase and T.navRoutes["from:0"] == fBase, "F6: deferCommit 固定開：兩格都不寫")
cok, cstate = API.commitDetour(0, dF)
local fr = T.navRoutes["from:0"]
assert(cok == true and cstate == "ok" and fr ~= fBase and fr.route == dF and fr.tx == 10 and fr.ty == 20
    and fr.buildX == 500 and fr.buildY == 600 and fr.approachWeight == 12 and fr.progressIdx == 1,
    "F6: commitDetour 寫進 from 格（起點、權重 12）")
assert(T.navRoutes[0] == pBase, "F6: commit 召喚改道不動玩家的藍線")
cok, cstate = API.commitDetour(0, dF)
assert(cok == true and cstate == "ok" and T.navRoutes["from:0"] == fr, "F6: 重複 commit 冪等")
-- F7：兩格同時有待接受的改道：各自 commit 到自己那一格
pBase, fBase = fromSetup()
local dP = detourRoute("P")
T.setDetour(dP, nil)
API.requestDetour(0, 10, 20, 30, 40, 5, nil, nil, true)
dF = detourRoute("F2")
T.setDetour(dF, nil)
API.requestDetourFrom(0, 500, 600, 10, 20, 30, 40, 5)
assert(T.navDetours[0].entry.route == dP and T.navDetours["from:0"].entry.route == dF,
    "F7: requestDetourFrom 不清玩家那一格待接受的改道")
cok = API.commitDetour(0, dF)
assert(cok and T.navRoutes["from:0"].route == dF and T.navRoutes[0] == pBase, "F7: 召喚改道進 from 格")
cok = API.commitDetour(0, dP)
assert(cok and T.navRoutes[0].route == dP and T.navRoutes["from:0"].route == dF, "F7: 玩家改道進玩家那一格")
-- F8：from 格的 stale：快取換過、引擎失敗、別的槽位；玩家換目標（clearRoute(pn)）不打斷召喚
local function fromStale(label, prep, pn)
    local _, fb = fromSetup()
    local d = detourRoute("S")
    T.setDetour(d, nil)
    API.requestDetourFrom(0, 500, 600, 10, 20, 30, 40, 5)
    prep()
    local okc, st = API.commitDetour(pn or 0, d)
    assert(okc == false and st == "stale" and not (T.navRoutes["from:0"] and T.navRoutes["from:0"].route == d),
        "F8: " .. label .. " → (false, stale) 且不寫，實得 " .. tostring(st))
    return fb
end
fromStale("from 格被重算換掉", function()
    T.navRoutes["from:0"] = { state = "ok", route = detourRoute("rebuilt"), tx = 10, ty = 20 }
end)
fromStale("新的 requestDetourFrom 取代", function()
    T.setDetour(detourRoute("newer"), nil)
    API.requestDetourFrom(0, 500, 600, 10, 20, 30, 40, 5)
end)
fromStale("引擎失敗（failNavEngine）", function() T.failNavEngine("boom"); T.engine.state = "ready" end)
fromStale("世界重置", function() T.worldReset(); T.engine.state = "ready" end)
fromStale("別的槽位", function() end, 1)
fromSetup()
dF = detourRoute("keep")
T.setDetour(dF, nil)
API.requestDetourFrom(0, 500, 600, 10, 20, 30, 40, 5)
T.invalidate(0)
assert(T.navRoutes[0] == nil and T.navRoutes["from:0"] ~= nil, "F8: clearRoute(pn) 不清 from 格")
cok, cstate = API.commitDetour(0, dF)
assert(cok == true and cstate == "ok" and T.navRoutes["from:0"].route == dF and T.navRoutes[0] == nil,
    "F8: 玩家換目標不打斷召喚的改道（commit 照常、玩家那一格仍空）")
-- F9：requestDetour 照舊帶玩家槽位當 pn、從玩家位置算（抽 detourCore 後行為不變）
resetAll()
T.players[1] = player(3, 4)
T.engine.graph = { id = "graph" }
T.setDetour(detourRoute("p1"), nil)
API.requestDetour(1, 10, 20, 30, 40, 5)
dc = T.detourCalls[1]
assert(dc.sx == 3 and dc.sy == 4 and dc.w == 3 and dc.pn == 1 and T.navRoutes[1].route.tag == "p1"
    and T.navRoutes["from:1"] == nil, "F9: requestDetour 起點是玩家、pn 是槽位、只寫玩家那一格")

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

local coreBody = assert(source:match(
    "%-%- test:navroute%-core:start[^\n]*\n(.-)\n%-%- test:navroute%-core:end"))
local realCore = assert(compile(coreBody .. "\nreturn NavCore", "nav-cache-core"))()
local cachePrelude = ([=[
local floor, sqrt = math.floor, math.sqrt
local routeDistance = ...
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
    distToRoute = routeDistance,
    findRoute = function(graph, sx, sy, tx, ty, ax, ay, ar, approachWeight, more, maxSnap, pn)
        findCalls[#findCalls + 1] = { sx = sx, sy = sy, tx = tx, ty = ty, w = approachWeight, pn = pn }
        if nextErr then return nil, nextErr end
        if not nextRoute then return nil end
        local pts = {}
        for i = 1, #nextRoute do pts[i] = nextRoute[i] end
        return {
            pts = pts,
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
local C = assert(compile(cachePrelude .. cacheBody .. "\n" .. cacheSuffix, "nav-cache"))(realCore.distToRoute)
local tgt = { x = 10744.8, y = 9717.5 }

-- C1: 首算寫入 buildX/buildY（偏航重算的位移閘門需要它；漏寫＝閘門永遠擋住）
C.setNow(1000)
C.setNext({ 10716, 9737, 10751, 9737 })
local cr = C.ensureRoute(0, tgt, 10716, 9737)
assert(cr and #C.findCalls == 1, "C1: 首算須跑 findRoute")
assert(C.navRoutes[0].buildX == 10716 and C.navRoutes[0].buildY == 9737,
    "C1: cache 須記下本次 A* 起點")
assert(math.abs(cr.snapDist) < 1e-9, "C1: 站在 snap 點上 snapDist≈0")

-- C2: 走廊內（偏航 ≤ 閾值）沿用同一張表，snapDist 刷新成當下到路線的投影距離
-- （沿線 3 格＋側偏 3 格 → 3；舊「玩家→首點」定義會得 4.24）
cr = C.ensureRoute(0, tgt, 10719, 9740)
assert(cr == C.navRoutes[0].route and #C.findCalls == 1, "C2: 走廊內須命中快取")
assert(math.abs(cr.snapDist - 3) < 1e-9,
    "C2: snapDist 須刷新成當下投影距離 3 格，實得 " .. tostring(cr.snapDist))

-- C2b（2026-09-02 AutoDrive 實爆）：沿線前進 30 格、車仍在線上 → snapDist 是投影距離 0，
-- 不是「玩家→首點」的 30；舊定義讓 addon 在「停車再啟動」時把在路上的車當起點太遠拒啟動
cr = C.ensureRoute(0, tgt, 10746, 9737)
assert(cr == C.navRoutes[0].route and #C.findCalls == 1, "C2b: 沿線前進仍命中快取")
assert(math.abs(cr.snapDist) < 1e-9,
    "C2b: 沿線前進 snapDist 須為投影距離 0，實得 " .. tostring(cr.snapDist))
cr = C.ensureRoute(0, tgt, 10746, 9742)
assert(math.abs(cr.snapDist - 5) < 1e-9,
    "C2b: 沿線 30 格＋側偏 5 格 snapDist 須為 5，實得 " .. tostring(cr.snapDist))

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

-- C7（2026-09-02 Carpenter 實爆）：approach 權重由呼叫端傳入（徒步 3、車上 12）——
-- 換權重＝快取失效立刻重算（不吃 3s 冷卻），同權重照常命中快取
C.setNow(50000)
C.setNext({ 8000, 8000, 8100, 8000 })
local tgt2 = { x = 8100, y = 8000 }
cr = C.ensureRoute(2, tgt2, 8000, 8000, 3)
local calls0 = #C.findCalls
assert(cr and C.findCalls[calls0].w == 3, "C7: 徒步首算 approach 權重 3，實得 " .. tostring(C.findCalls[calls0].w))
C.setNow(50000 + 100) -- 冷卻未過
cr = C.ensureRoute(2, tgt2, 8000, 8000, 12)
assert(#C.findCalls == calls0 + 1 and C.findCalls[calls0 + 1].w == 12,
    "C7: 上車立刻以權重 12 重算（不吃冷卻），實得 calls=" .. tostring(#C.findCalls - calls0))
cr = C.ensureRoute(2, tgt2, 8001, 8000, 12)
assert(#C.findCalls == calls0 + 1, "C7: 車上同權重命中快取")
cr = C.ensureRoute(2, tgt2, 8001, 8000, 3)
assert(#C.findCalls == calls0 + 2 and C.findCalls[calls0 + 2].w == 3, "C7: 下車換回權重 3 重算")

-- C8：倒車到路線起點後方，側向仍在12格容差內，也要把退出的跑道交回新路線。
do
    local target = { x = 10592, y = 10097 }
    C.setNow(60000)
    C.setNext({10592, 9996.9, 10592, 10097})
    local original = C.ensureRoute(3, target, 10593.8, 9996.9, 12)
    C.setNext({10592, 9985.5, 10592, 10097})
    C.setNow(60100)
    assert(C.ensureRoute(3, target, 10593.8, 9985.5, 12) == original,
        "C8: 起點後方仍遵守既有冷卻，不因倒車每幀重算")
    C.setNow(60000 + REBUILD_COOLDOWN_MS + 1)
    assert(C.ensureRoute(3, target, 10600, 9996.9, 12) == original,
        "C8: 純側向8格不屬起點反向延長線，仍沿用快取")
    assert(C.ensureRoute(3, target, 10592.5, 9992, 12) == original,
        "C8: 小幅後退不足8格不重算")
    local reanchored = C.ensureRoute(3, target, 10593.8, 9985.5, 12)
    assert(reanchored ~= original and reanchored.snapDist < 2
            and reanchored.pts[2] < 9986,
        "C8: 倒車11.4格後路線重新從車旁起算，不能把真跑道留在s=0之外")
    C.setNow(70000)
    assert(C.ensureRoute(3, target, 10593.8, 9985.5, 12) == reanchored,
        "C8: 原地不再反覆重錨")

    C.setNow(80000)
    C.setNext({10592,9996.9,10592,10097,10612,10097,10612,9946.9,10592,9946.9,10592,9986.9})
    local loop = C.ensureRoute("loop", target, 10592, 9996.9, 12)
    C.setNow(80000 + REBUILD_COOLDOWN_MS + 1)
    assert(C.ensureRoute("loop", target, 10592, 9984, 12) == loop,
        "C8: 已在折返路線後段，不因落在首段後方誤判重算")
end

-- C9（v13）：第 7 參 pn＝自訂道路遮罩的槽位。不傳＝照舊從 key 推（數字 key 本身、分享路線 "pn:作者" 取冒號前）；
-- "from:<pn>" 推不出來（tonumber("from")＝nil），所以 requestRouteFrom 一定要帶
do
    local target = { x = 9000, y = 9000 }
    C.setNext({ 9000, 8000, 9000, 9000 })
    local function pnOf(key, pn)
        C.navRoutes[key] = nil
        C.ensureRoute(key, target, 9000, 8000, 12, nil, pn)
        return C.findCalls[#C.findCalls].pn
    end
    assert(pnOf(2) == 2, "C9: 數字 key 不傳 pn＝key 本身")
    assert(pnOf("1:alice") == 1, "C9: 分享路線 key 不傳 pn＝冒號前的槽位")
    assert(pnOf("from:3") == nil, "C9: from key 推不出槽位（requestRouteFrom 必須帶 pn）")
    assert(pnOf("from:3", 3) == 3, "C9: 帶 pn＝照用")
end

print("test_nav_api: OK（requestRoute A1-A12＋requestDetour A13-A22＋deferCommit／commitDetour A23-A28"
    .. "＋requestRouteFrom／requestDetourFrom F1-F9＋ensureRoute 快取/偏航 C0-C9）")
