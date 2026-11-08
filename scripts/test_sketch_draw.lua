-- 手繪線繪製（Core.drawSketch）離線回歸：拉遠隱藏、線寬上下限、外框剔除、候選快取只在該重建時重建、
-- 超過預算整批換粗一層但每筆都畫到、畫面上很小的筆畫成一點且同一像素只畫一次、出錯也清 stencil、
-- 「顯示在」兩格（工具開著的世界地圖照畫）、收到的分享照「顯示別人分享的手繪」、RD.buildLevels 新參數。
-- 用法：lua scripts/test_sketch_draw.lua
local H = dofile("scripts/sketch_harness.lua")
local Core = H.boot()
local SK, check = H.SK, H.check
H.players[0] = H.player("alice", 0)
H.fire("OnCreatePlayer", 0)
local slot = H.loadSlot(0)

local function add(pts, z, w)
    local s = assert(SK.newStroke(0, { c = 3, w = w or 2, z = z or 17, share = false }, pts, #pts / 2))
    assert(SK.apply(0, {}, 0, { s }, 1))
    return s
end
local function polyWidth(p)
    -- 四邊形 (x1,y1)..(x4,y4)：第 1、4 點的距離＝線寬
    local dx, dy = p[1] - p[7], p[2] - p[8]
    return math.sqrt(dx * dx + dy * dy)
end

-- RD.buildLevels：segW 為 nil 不強制留點、tol0 換第 2 層容差；道路照舊（test_road_draw 另驗逐筆不變）
do
    local RD = Core.RoadDraw
    local pts = { 0, 0, 1, 0.05, 2, 0, 3, 0.05, 4, 0 }
    local lv = RD.buildLevels(pts, 5, nil, nil, 0.01)
    check(#lv[1] == 5 and lv[2] and lv[2].tol == 0.04 and lv[3].tol == 0.08 and #lv[3] == 2, "L1 segW 為 nil 照跑；容差從 tol0 逐層加倍")
    local lv2 = RD.buildLevels(pts, 5, nil, nil, 0.25)
    check(#lv2[2] == 2 and lv2[2].tol == 0.25, "L2 tol0＝0.25：只剩頭尾")
end

local map = H.map({ S = 4, cx = 1000, cy = 1000, zoom = 17 })
-- 線寬：畫的縮放 17、中＝4 px；拉近一級 8 px（上限 2 倍）、拉近兩級仍 8；拉遠一級 2 px、拉遠很多夾到 1
local s = add({ 990, 1000, 1010, 1000 })
Core.drawSketch(map)
check(#map.polys == 1 and math.abs(polyWidth(map.polys[1]) - 4) < 1e-6, "W1 畫的縮放下中＝4 px")
check(map.stencil == 1 and map.cleared == 1, "W2 stencil 成對")
local function widthAt(zoom)
    map.polys, map.mapAPI.zoom = {}, zoom
    Core.drawSketch(map)
    return map.polys[1] and polyWidth(map.polys[1]) or 0
end
check(math.abs(widthAt(18) - 8) < 1e-6 and math.abs(widthAt(19) - 8) < 1e-6, "W3 拉近最粗 2 倍")
check(math.abs(widthAt(16) - 2) < 1e-6 and math.abs(widthAt(15) - 1) < 1e-6, "W4 拉遠變細、最細 1 px")
-- 拉遠超過 SketchHideZoom（預設 3）級就不畫
check(widthAt(14) > 0, "H1 拉遠 3 級還畫")
check(widthAt(13.9) == 0, "H2 拉遠超過 3 級不畫")
H.opts.SketchHideZoom = 5
check(widthAt(12.5) > 0, "H3 設定拉遠 5 級：12.5 還畫")
H.opts.SketchHideZoom = nil
map.mapAPI.zoom = 17

-- 外框剔除：畫面外的不畫；候選快取在視野還在外擴框內時不重建
local far = add({ 5000, 5000, 5010, 5000 })
local rebuilds = SK.rebuilds or 0
map.polys = {}
Core.drawSketch(map)
check(#map.polys == 1, "C1 畫面外的筆不畫")
local r0 = SK.rebuilds
map.mapAPI.cx = 1010
Core.drawSketch(map)
check(SK.rebuilds == r0, "C2 視野小幅平移沿用候選快取")
map.mapAPI.cx = 3000
Core.drawSketch(map)
check(SK.rebuilds == r0 + 1, "C3 視野移出外擴框才重建")
map.mapAPI.cx = 1000
Core.drawSketch(map)
local r1 = SK.rebuilds
add({ 1000, 990 })
Core.drawSketch(map)
check(SK.rebuilds == r1 + 1, "C4 資料改版就重建")
check(rebuilds >= 0 and far.id > 0, "C5")

-- 單點筆：畫成一點（方塊）
map.polys = {}
Core.drawSketch(map)
check(#map.polys == 2, "D1 單點筆畫一個四邊形")

-- 預算：600 次上限，超過整批換粗一層，每筆仍至少畫一段
do
    local list = {}
    for i = 1, 40 do
        local pts = {}
        for k = 0, 99 do pts[#pts + 1] = 900 + k * 2; pts[#pts + 1] = 900 + i * 4 + (k % 2) * 1.5 end
        list[i] = add(pts)
    end
    map.polys = {}
    map.mapAPI.cx, map.mapAPI.cy, map.mapAPI.S = 1000, 980, 1.2
    Core.drawSketch(map)
    check(#map.polys <= SK.BUDGET and #map.polys >= 40, "B1 40 筆 ×100 點只畫 " .. #map.polys .. " 次（≤600）")
    -- 每一筆都有畫到：每筆的 y 不同
    local seen = 0
    for i = 1, 40 do
        local y = (900 + i * 4 - 980) * 1.2 + 300
        for _, p in ipairs(map.polys) do
            local cy = (p[2] + p[6]) / 2
            if math.abs(cy - y) < 3 then seen = seen + 1 break end
        end
    end
    check(seen == 40, "B2 超過預算不丟筆（40 筆都有畫，實際 " .. seen .. "）")
end

-- 拉很遠：外框不到 2 px 的筆畫成一點，同一像素只畫一次
do
    map.polys = {}
    map.mapAPI.S, map.mapAPI.zoom = 0.004, 15
    Core.drawSketch(map)
    local n = #map.polys
    check(n >= 1 and n <= 8, "T1 拉遠時同一像素的小筆只畫一次（" .. n .. " 次）")
    map.mapAPI.S, map.mapAPI.zoom = 4, 17
end

-- 可見的筆比預算還多（2,000 筆各約 3 格、擠在畫面裡；2026-11-08 sketch-perf-sp 實機 5,000 筆每幀 5,000 次、約 28 ms）：
-- 各筆換到最粗仍超過時，小筆合成格點，每幀照樣 ≤ BUDGET；畫面沒動時沿用上一幀的規劃
do
    for i = 0, 1999 do
        local x, y = 920 + (i % 50) * 3, 940 + math.floor(i / 50) * 3
        add({ x, y, x + 2, y + 1 })
    end
    map.polys = {}
    map.mapAPI.cx, map.mapAPI.cy, map.mapAPI.S, map.mapAPI.zoom = 1000, 1000, 4, 17
    Core.drawSketch(map)
    check(#map.polys <= SK.BUDGET and #map.polys >= 100, "B3 2000 筆擠在畫面裡只畫 " .. #map.polys .. " 次（≤600）")
    local pb = SK.planBuilds
    map.polys = {}
    Core.drawSketch(map)
    check(SK.planBuilds == pb and #map.polys > 0, "P1 畫面沒動沿用上一幀的規劃")
    -- 只平移、還在規劃框（視野外擴 PLAN_PAD）內：沿用規劃，位置照新的視角投影（小地圖跟著玩家走時每幀都是這樣；
    -- 2026-11-08 審查：只要 acx／p0x 一變就重算時，5,000 筆推估每幀 10–25 ms）
    local before = #map.polys
    map.polys = {}
    map.mapAPI.cx = 1001
    -- 引擎 float32 的捨入差：投影係數不會逐位元相同（2026-11-08 實機小地圖 z15 跟著玩家走：相對 1.2e-4–1.7e-4，
    -- 舊寫法容差 1e-4 時走路 8 秒重新規劃 29–70 次）；getWorldScale 不變
    map.mapAPI.jit = 3e-4
    Core.drawSketch(map)
    map.mapAPI.jit = nil
    check(SK.planBuilds == pb and #map.polys > 0 and #map.polys <= SK.BUDGET, "P2 框內平移沿用規劃（" .. #map.polys .. " 次）")
    -- 平移出框（縮放與候選沒變）：重新規劃，格子沿用上一幀的，只掃起頭 1 趟＋這個格子 1 趟（2026-11-08 實機：
    -- 每幀從頭加倍時 1,600 筆可見每幀 11 ms，從上一幀的一半起找時 7.8 ms）
    local dp = SK.dotPasses
    map.mapAPI.cx = 1060
    Core.drawSketch(map)
    check(SK.planBuilds == pb + 1, "P3a 平移出框才重新規劃")
    check(SK.dotPasses - dp <= 2, "P3 出框重新規劃只掃 " .. (SK.dotPasses - dp) .. " 趟（≤2）")
    map.mapAPI.cx = 1000
    -- 縮放檔位沒變但 getWorldScale 變了（例：視窗改大小的同一幀）：要重新規劃
    Core.drawSketch(map)
    local pb2 = SK.planBuilds
    map.mapAPI.S = 4 * 1.01
    Core.drawSketch(map)
    map.mapAPI.S = 4
    check(SK.planBuilds == pb2 + 1, "P2b scale 一變就重新規劃（" .. (SK.planBuilds - pb2) .. " 次）")
    local _ = before
end

-- 每幀呼叫數一定有上限：700 條橫跨畫面的長線（畫面上比 2×(寬+高) 還大，不能併成點）
do
    local slot = SK.slots[0]
    local keep = {}
    for i = 1, slot.store.count do keep[i] = slot.store.strokes[i] end
    local nKeep = slot.store.count
    assert(SK.apply(0, keep, nKeep, {}, 0))
    for i = 0, 699 do add({ 0, 900 + i * 0.25, 2000, 900 + i * 0.25 }) end
    map.polys = {}
    map.mapAPI.cx, map.mapAPI.cy, map.mapAPI.S, map.mapAPI.zoom = 1000, 1000, 4, 17
    Core.drawSketch(map)
    check(#map.polys <= SK.BUDGET and #map.polys >= 400, "B4 700 條長線只畫 " .. #map.polys .. " 次（≤600）")
    local rem = {}
    for i = 1, slot.store.count do rem[i] = slot.store.strokes[i] end
    assert(SK.apply(0, rem, slot.store.count, keep, nKeep))
end

-- 出錯也清 stencil
map.failDraw = true
map.stencil, map.cleared = 0, 0
local ok = pcall(Core.drawSketch, map)
check(not ok and map.stencil == 1 and map.cleared == 1, "S1 繪製中途出錯也 clearStencilRect")
map.failDraw = false

-- 「顯示在」兩格：小地圖看 Sketch、世界地圖看 WMSketch；手繪工具開著的那張世界地圖照畫
local mini = H.map({ S = 4, cx = 1000, cy = 1000, zoom = 17 })
H.opts.Sketch = false
Core.drawSketch(mini)
check(#mini.polys == 0, "G1 小地圖那格關掉不畫")
H.opts.Sketch = nil
local world = H.worldMap({ S = 4, cx = 1000, cy = 1000, zoom = 17 })
H.opts.WMSketch = false
Core.drawSketch(world)
check(#world.polys == 0, "G2 世界地圖那格關掉不畫")
Core.sketchToolOf = function(m) return m == world and {} or nil end
Core.drawSketch(world)
check(#world.polys > 0, "G3 手繪工具開著的世界地圖照畫")
Core.sketchToolOf = nil
H.opts.WMSketch = nil
mini.polys = {}
Core.drawSketch(mini)
check(#mini.polys > 0, "G4 兩格預設都開")

-- 收到的分享：SketchReceived 關掉不畫
do
    local before
    mini.polys = {}
    Core.drawSketch(mini)
    before = #mini.polys
    Core.sketchRecvReplace(0, { { lid = "aaaaaaaa:1", a = "bob", c = 4, w = 3, z = 17, pts = { 995, 1010, 1005, 1010 },
        np = 2 } }, 1)
    mini.polys = {}
    Core.drawSketch(mini)
    check(#mini.polys == before + 1, "R1 收到的分享照畫")
    H.opts.SketchReceived = false
    mini.polys = {}
    Core.drawSketch(mini)
    check(#mini.polys == before, "R2 顯示別人分享的手繪關掉就不畫")
    H.opts.SketchReceived = nil
end

-- 收齊的快照分 tick 準備、沒變的筆沿用（2026-11-08 審查：陣營或安全屋一變全服重新對帳，上千筆一幀全部重算）
do
    local function snap(n, x0)
        local list = {}
        for i = 1, n do
            local pts = { 900 + i % 100, 900 + math.floor(i / 100), 901 + i % 100 + x0, 900 + math.floor(i / 100) }
            list[i] = { lid = "bbbbbbbb:" .. i, a = "bob", c = 2, w = 1, z = 17, pts = pts, np = 2,
                wp = table.concat(pts, ",") }
        end
        return list
    end
    local real, calls = SK.prepare, 0
    SK.prepare = function(st) calls = calls + 1 return real(st) end
    local slot = SK.slots[0]
    H.autoMs = 1
    Core.sketchRecvReplace(0, snap(2000, 0), 2000)
    check(slot.recvLoad ~= nil and calls < 2000, "R3 2000 筆快照不在同一幀準備完（這幀 " .. calls .. " 筆）")
    Core.sketchRecvAdd(0, { { lid = "bbbbbbbb:9999", a = "bob", c = 2, w = 1, z = 17, pts = { 950, 950 }, np = 1, wp = "950,950" } }, 1)
    for _ = 1, 1000 do -- 每讀一次時鐘過 1 ms＝每 tick 4 筆
        if not slot.recvLoad then break end
        H.fire("OnTickEvenPaused")
    end
    check(slot.recvLoad == nil and slot.recvN == 2001, "R4 分幾個 tick 準備完才換上，期間的即時事件換上後照套")
    calls = 0
    local again = snap(2000, 0)
    again[7].wp, again[7].pts[3] = "changed", again[7].pts[3] + 5
    Core.sketchRecvReplace(0, again, 2000)
    for _ = 1, 1000 do
        if not slot.recvLoad then break end
        H.fire("OnTickEvenPaused")
    end
    check(calls == 1 and slot.recvN == 2000, "R5 內容沒變的 1999 筆沿用，只重算改過的 1 筆（重算 " .. calls .. "）")
    H.autoMs = 0
    SK.prepare = real
    Core.sketchRecvReplace(0, {}, 0)
end

-- 大筆（接近 500 點）一筆就要好幾毫秒：每筆都看時鐘，單一 tick 最多超支一筆（2026-11-08 審查第 10 條：舊寫法每 40 筆才看一次）
do
    local real, ticks, maxPer, per = SK.prepare, 0, 0, 0
    SK.prepare = function(st)
        per = per + 1
        H.now = H.now + 1 -- 假時鐘隨 prepare 前進：一筆 1 ms
        return real(st)
    end
    local list = {}
    for i = 1, 200 do
        list[i] = { lid = "cccccccc:" .. i, a = "carol", c = 1, w = 1, z = 17, pts = { i, 0, i + 1, 0 }, np = 2, wp = "x" .. i }
    end
    local slot = SK.slots[0]
    Core.sketchRecvReplace(0, list, 200)
    maxPer = per
    while slot.recvLoad and ticks < 1000 do
        per = 0
        ticks = ticks + 1
        H.fire("OnTickEvenPaused")
        if per > maxPer then maxPer = per end
    end
    SK.prepare = real
    check(slot.recvLoad == nil and slot.recvN == 200 and maxPer <= SK.LOAD_BUDGET_MS + 1,
        "R6 大筆收件每 tick 最多超支一筆（單 tick 最多 " .. maxPer .. " 筆、" .. ticks .. " 個 tick）")
    Core.sketchRecvReplace(0, {}, 0)
end

H.finish("test_sketch_draw")
