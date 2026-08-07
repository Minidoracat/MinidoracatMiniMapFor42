-- Zone 圖層渲染回歸測試（A1 stencil 保護、A2 provider 隔離、A3 AABB 早退、
-- drawClippedEdge alpha 契約）。仿 test_livestock_visibility.lua 的 stub 風格：
-- 抽主檔標記區段→補最小 stub→組裝可離線跑。用法：lua scripts/test_zone_render.lua
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local file = assert(io.open(sourcePath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local compile = loadstring or load

--------------------------------------------------------------------------------
-- drawClippedEdge alpha 契約：省略第 8 參→SH_EDGE_A(0.85)；顯式傳 0→保留 0
--------------------------------------------------------------------------------
local edgeBody = assert(source:match(
    "%-%- test:clipped%-edge:start\n(.-)\n%-%- test:clipped%-edge:end"),
    "找不到 drawClippedEdge 測試區段")
local edgePrelude = [=[
local recordedAlpha
-- drawLine 呼叫序：self, tex, cx1, cy1, cx2, cy2, width, alpha, r, g, b → alpha 為第 8 參
local inner = {
    width = 100, height = 100,
    drawLine = function(_, _, _, _, _, _, _, alpha) recordedAlpha = alpha end,
}
]=]
local edgeSuffix = [=[
return {
    draw = function(a)
        recordedAlpha = nil
        drawClippedEdge(inner, 10, 10, 20, 20, 1, 1, 1, a) -- 線段全在視窗內→必畫
        return recordedAlpha
    end,
}
]=]
local edgeChunk, edgeErr = compile(edgePrelude .. "\n" .. edgeBody .. "\n" .. edgeSuffix)
assert(edgeChunk, edgeErr)
local edge = edgeChunk()

assert(edge.draw(nil) == 0.85, "7 參呼叫未回退 SH_EDGE_A(0.85)")
assert(edge.draw(0) == 0, "顯式傳 alpha=0 未保留為 0")
assert(edge.draw(0.5) == 0.5, "顯式 alpha 未透傳")

--------------------------------------------------------------------------------
-- Zone fill/line 渲染：A1 stencil 保護、A2 provider 隔離、A3 AABB 早退
--------------------------------------------------------------------------------
local zoneBody = assert(source:match(
    "%-%- test:zone%-render:start\n(.-)\n%-%- test:zone%-render:end"),
    "找不到 zone 繪製測試區段")
local zonePrelude = [=[
local registeredZoneProviders = {}
local zoneLayerOn = true
local logs = {}
local function getBoolOption(id, default)
    if id == "ZoneLayer" then return zoneLayerOn end
    return default
end
local function log(msg) logs[#logs + 1] = msg end
local UIFont = { Small = "small" }
local function getTextManager()
    return {
        getFontHeight = function() return 10 end,
        MeasureStringX = function(_, _, s) return #s * 4 end,
    }
end
-- drawClippedEdge 用 stub 計數（真實版另在 clipped-edge 區段測 alpha 契約）
local drawClippedEdgeCount = 0
local function drawClippedEdge() drawClippedEdgeCount = drawClippedEdgeCount + 1 end
-- drawZoneIcons 的兩個標記區段外相依（抽段後是全域）：滑條與可視外接框 stub
local iconSize = 18
local function getSliderValue(id) return id == "PoiIconAlpha" and 100 or iconSize end
local zoneAABB = { 0, 100, 0, 100 }
local function visibleWorldAABB() return zoneAABB[1], zoneAABB[2], zoneAABB[3], zoneAABB[4] end
-- POI 距離閘的區段外相依：displayDist（鎖定選項名；沙盒×玩家合成另在
-- test_livestock_visibility.lua 的 display-distance 區段測）與玩家 stub
-- （記錄收到的 playerNum——防 inner.playerNum 被硬編碼 0 的回歸）
local poiDist = nil          -- nil＝未啟用（displayDist 對 0/缺值回 nil 的語意）
local playerPos = { 50, 50 } -- nil＝缺玩家（fail closed 分支）
local lastPlayerNum = nil
local function displayDist(name)
    if name == "PoiDisplayDistance" then return poiDist end
    return nil
end
local function getSpecificPlayer(pn)
    lastPlayerNum = pn
    if not playerPos then return nil end
    return {
        getX = function() return playerPos[1] end,
        getY = function() return playerPos[2] end,
    }
end
]=]
local zoneSuffix = [=[
return {
    fill = drawZoneFill,
    lines = drawZoneLines,
    icons = drawZoneIcons,
    safe = safeDrawZone,
    setAABB = function(a, b, c, d) zoneAABB = { a, b, c, d } end,
    setIconSize = function(s) iconSize = s end,
    addProvider = function(owner, fn, internal)
        registeredZoneProviders[#registeredZoneProviders + 1] = { owner = owner, fn = fn, internal = internal }
    end,
    clearProviders = function()
        for i = #registeredZoneProviders, 1, -1 do registeredZoneProviders[i] = nil end
    end,
    setZoneLayer = function(v) zoneLayerOn = v end,
    setPoiDist = function(d) poiDist = d end,
    setPlayerPos = function(x, y) playerPos = x and { x, y } or nil end,
    lastPn = function() return lastPlayerNum end,
    logCount = function()
        local n = 0
        for _ in ipairs(logs) do n = n + 1 end
        return n
    end,
    resetLogs = function() for i = #logs, 1, -1 do logs[i] = nil end end,
    edgeCount = function() return drawClippedEdgeCount end,
    resetEdgeCount = function() drawClippedEdgeCount = 0 end,
}
]=]
local zoneChunk, zoneErr = compile(zonePrelude .. "\n" .. zoneBody .. "\n" .. zoneSuffix)
assert(zoneChunk, zoneErr)
local zone = zoneChunk()

-- 建 inner stub：worldToUIX/Y 恆等投影（世界座標=UI 座標），繪製方法計數
local function makeInner(scale)
    local inner = {
        width = 100, height = 100,
        setCount = 0, clearCount = 0, polyCount = 0, rectCount = 0, textCount = 0,
        mapAPI = {
            worldToUIX = function(_, x) return x end,
            worldToUIY = function(_, _, y) return y end,
            -- px/世界格（LOD 檔位訊號）；預設 10＝細節檔，既有測試行為不變
            getWorldScale = function() return scale or 10 end,
        },
    }
    inner.setStencilRect = function(self) self.setCount = self.setCount + 1 end
    inner.clearStencilRect = function(self) self.clearCount = self.clearCount + 1 end
    inner.polyXs = {}
    inner.drawPolygon = function(self, _, x1)
        self.polyCount = self.polyCount + 1
        self.polyXs[#self.polyXs + 1] = x1
    end
    inner.drawRect = function(self) self.rectCount = self.rectCount + 1 end
    inner.drawText = function(self) self.textCount = self.textCount + 1 end
    return inner
end

local function visibleZone()
    return { {
        fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
        border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5, name = "Zone",
        rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } },
    } }
end

-- A4-1：ZoneLayer=false → 外部 provider 不被呼叫、不繪製；內部（internal）POI provider 照常
do
    zone.setZoneLayer(false)
    local extCalled, intCalled = 0, 0
    zone.addProvider("addonExternal", function() extCalled = extCalled + 1; return visibleZone() end)
    zone.addProvider("internalPOI", function() intCalled = intCalled + 1; return visibleZone() end, true)
    local inner = makeInner()
    zone.fill(inner)
    zone.lines(inner)
    assert(extCalled == 0, "ZoneLayer 關閉時外部 provider 不應被呼叫")
    assert(intCalled == 2, "ZoneLayer 關閉時內部 POI provider 仍應被呼叫（fill+lines 各一次）")
    assert(inner.polyCount == 1, "ZoneLayer 關閉時內部 POI provider 的可見 zone 仍應填色")
    zone.clearProviders()
    zone.setZoneLayer(true)
    zone.resetLogs()
end

-- A4-2：drawClippedEdge stub 計數＝可見 zone 四邊；離屏 rect 不繪製（A3）
do
    zone.addProvider("addonVis", visibleZone)
    local inner = makeInner()
    zone.fill(inner)
    assert(inner.setCount == 1 and inner.clearCount == 1, "可見 zone 應成對 set/clear stencil")
    assert(inner.polyCount == 1, "可見 zone 未填色")
    zone.resetEdgeCount()
    zone.lines(inner)
    assert(zone.edgeCount() == 4, "可見 zone 框線未畫四邊")
    zone.clearProviders()
    zone.resetLogs()

    zone.addProvider("addonOff", function()
        return { {
            fill = { r = 1, g = 1, b = 1 }, border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5,
            rects = { { x1 = 200, y1 = 200, x2 = 210, y2 = 210 } },
        } }
    end)
    local off = makeInner()
    zone.fill(off)
    assert(off.polyCount == 0 and off.setCount == 0, "A3：離屏 rect 不應觸發填色/stencil")
    zone.resetEdgeCount()
    zone.lines(off)
    assert(zone.edgeCount() == 0, "A3：離屏 rect 不應觸發框線繪製")
    zone.clearProviders()
    zone.resetLogs()
end

-- A3b：世界預裁與投影後 AABB 早退是兩層獨立防線——把世界框放大到涵蓋離屏
-- rect，使其通過世界預裁，仍須被投影後早退擋下（守住 A3 的原始保護對象）
do
    zone.setAABB(-1000, 1000, -1000, 1000)
    zone.addProvider("addonOffWide", function()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5,
            rects = { { x1 = 200, y1 = 200, x2 = 210, y2 = 210 } },
        } }
    end)
    local off = makeInner()
    zone.fill(off)
    assert(off.polyCount == 0 and off.setCount == 0, "A3b：投影後早退未擋下離屏 rect (fill)")
    zone.resetEdgeCount()
    zone.lines(off)
    assert(zone.edgeCount() == 0, "A3b：投影後早退未擋下離屏 rect (lines)")
    zone.clearProviders()
    zone.resetLogs()
    zone.setAABB(0, 100, 0, 100)
end

-- A6：區塊縮放 LOD——帶 lodRect 的 zone 三檔行為；無 lodRect 的 addon zone 不參與
do
    local function lodZone()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5, name = "Poi",
            rects = { { x1 = 30, y1 = 30, x2 = 40, y2 = 40 },
                { x1 = 40, y1 = 30, x2 = 48, y2 = 44 } },
            lodRect = { x1 = 30, y1 = 30, x2 = 48, y2 = 44 },
        } }
    end
    -- 細節檔（scale>=6）：逐房間＋名稱
    zone.addProvider("lod1", lodZone, true)
    local near = makeInner(10)
    zone.fill(near)
    assert(near.polyCount == 2, "A6 細節檔應畫全部矩形（得 " .. near.polyCount .. "）")
    zone.resetEdgeCount(); zone.lines(near)
    assert(zone.edgeCount() == 8 and near.textCount == 1, "A6 細節檔框線 8 邊＋名稱 1 次")
    zone.clearProviders()
    -- 中距檔（1.5<=scale<6）：聯集框一個、框線 4 邊、無名稱
    zone.addProvider("lod2", lodZone, true)
    local mid = makeInner(3)
    zone.fill(mid)
    assert(mid.polyCount == 1, "A6 中距檔應只畫聯集框（得 " .. mid.polyCount .. "）")
    zone.resetEdgeCount(); zone.lines(mid)
    assert(zone.edgeCount() == 0 and mid.textCount == 0,
        "A6 中距檔應純填色（無框線無名稱；edges=" .. zone.edgeCount() .. " text=" .. mid.textCount .. "）")
    zone.clearProviders()
    -- 拉遠檔（scale<1.5）：lodRect zone 整區不畫；無 lodRect 的 addon zone 照畫
    zone.addProvider("lod3", lodZone, true)
    zone.addProvider("lod4", visibleZone, true)
    local far = makeInner(1)
    zone.fill(far)
    assert(far.polyCount == 1, "A6 拉遠檔應僅 addon zone 填色（得 " .. far.polyCount .. "）")
    zone.resetEdgeCount(); zone.lines(far)
    assert(zone.edgeCount() == 4, "A6 拉遠檔應僅 addon zone 畫框線（得 " .. zone.edgeCount() .. "）")
    zone.clearProviders()

    -- A6b 檔位邊界：恰 1.5 進中距（聯集框）、恰 6 進細節（逐房間＋名稱）
    zone.addProvider("lod5", lodZone, true)
    local at15 = makeInner(1.5)
    zone.fill(at15)
    assert(at15.polyCount == 1, "A6b scale=1.5 應為中距檔（得 " .. at15.polyCount .. "）")
    zone.clearProviders()
    zone.addProvider("lod6", lodZone, true)
    local at6 = makeInner(6)
    zone.fill(at6)
    assert(at6.polyCount == 2, "A6b scale=6 應為細節檔（得 " .. at6.polyCount .. "）")
    zone.resetEdgeCount(); zone.lines(at6)
    assert(at6.textCount == 1, "A6b scale=6 名稱應顯示")
    zone.clearProviders()

    -- A6c 兩個不同 lodRect 的 zone 中距檔各畫各的座標——lodSingle 重用表不得殘留
    zone.addProvider("lod7", function()
        return {
            { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
              rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } },
              lodRect = { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } },
            { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
              rects = { { x1 = 60, y1 = 60, x2 = 70, y2 = 70 } },
              lodRect = { x1 = 60, y1 = 60, x2 = 70, y2 = 70 } },
        }
    end, true)
    local two = makeInner(3)
    zone.fill(two)
    assert(two.polyCount == 2, "A6c 兩 zone 應各一框")
    assert(two.polyXs[1] == 10 and two.polyXs[2] == 60,
        "A6c lodSingle 殘留：第二框沿用前一框座標（x=" .. tostring(two.polyXs[2]) .. "）")
    zone.clearProviders()

    -- A6d 圖標不被 LOD hide 檔隱藏：拉遠檔（區塊全隱）孤立圖標照畫——
    -- 去重疊只合併同格、不會讓孤立圖標消失
    zone.addProvider("lod8", function()
        return { { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = 40, y1 = 40, x2 = 50, y2 = 50 } },
            lodRect = { x1 = 40, y1 = 40, x2 = 50, y2 = 50 } } }
    end, true)
    local farIcon = { width = 100, height = 100, draws = 0 }
    farIcon.drawTextureScaled = function(self) self.draws = self.draws + 1 end
    farIcon.mapAPI = {
        worldToUIX = function(_, x) return x end,
        worldToUIY = function(_, _, y) return y end,
        getWorldScale = function() return 1 end,
    }
    zone.icons(farIcon); zone.clearProviders()
    assert(farIcon.draws == 1, "A6d 拉遠檔孤立圖標仍應畫（得 " .. farIcon.draws .. "）")
    zone.resetLogs()
end

-- A3c：多矩形 zone 的名稱恰畫一次、錨定 rects[1]（v3＝最大房間，與圖標同錨）
do
    zone.addProvider("addonNamed", function()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5, name = "Zone",
            rects = { { x1 = 30, y1 = 30, x2 = 50, y2 = 50 },
                { x1 = 60, y1 = 60, x2 = 70, y2 = 70 } },
        } }
    end)
    local named = makeInner()
    zone.lines(named)
    assert(named.textCount == 1,
        "A3c：多矩形 zone 名稱應恰畫一次（得 " .. named.textCount .. "）")
    zone.clearProviders()
    zone.resetLogs()
end

-- A1：setStencil 後繪製出錯，clearStencil 仍執行（set==clear），錯誤經 safeDrawZone log-once
do
    zone.addProvider("addonBoom", visibleZone)
    local inner = makeInner()
    inner.drawPolygon = function() error("gpu boom") end -- setStencil 後繪製爆
    zone.safe(inner, zone.fill, "_zoneFillErr")
    print(string.format("  A1 stencil 保護：drawPolygon 出錯 → set=%d clear=%d (須相等)",
        inner.setCount, inner.clearCount))
    assert(inner.setCount == 1, "A1：繪製出錯前應已 setStencilRect 一次")
    assert(inner.setCount == inner.clearCount, "A1：繪製出錯後 set/clear 未成對（stencil 洩漏）")
    assert(zone.logCount() == 1 and inner._zoneFillErr, "A1：繪製錯誤未經 safeDrawZone log-once")
    zone.clearProviders()
    zone.resetLogs()
end

-- A2：壞 provider 個別隔離——後續好 provider 照跑、stencil 成對、log-once 附 owner
do
    zone.addProvider("badOwner", function() error("provider boom") end)
    zone.addProvider("goodOwner", visibleZone)
    local inner = makeInner()
    zone.fill(inner)
    assert(inner.polyCount == 1, "A2：壞 provider 之後的好 provider 未填色 (fill)")
    assert(inner.setCount == 1 and inner.clearCount == 1, "A2：provider 出錯後 stencil 未成對清除")
    zone.resetEdgeCount()
    zone.lines(inner)
    assert(zone.edgeCount() == 4, "A2：壞 provider 之後的好 provider 未畫框線 (lines)")
    -- badOwner 跨 fill/lines 兩 pass 共觸發兩次錯誤，但同一 inner 依 owner 只記一次
    print(string.format(
        "  A2 provider 隔離：[badOwner, goodOwner] → good 填色=%d 框線=%d，錯誤 log=%d 筆 (log-once)",
        inner.polyCount, zone.edgeCount(), zone.logCount()))
    assert(zone.logCount() == 1, "A2：provider 錯誤未 log-once（應恰 1 筆）")
    zone.clearProviders()
    zone.resetLogs()
end

-- A2（順序）：好 provider 先設 stencil，隨後 provider 出錯不得洩漏 stencil
do
    zone.addProvider("goodFirst", visibleZone)
    zone.addProvider("badSecond", function() error("late boom") end)
    local inner = makeInner()
    zone.fill(inner)
    assert(inner.setCount == 1 and inner.clearCount == 1,
        "A2：先設 stencil 後 provider 出錯，clear 仍須成對")
    assert(inner.polyCount == 1, "A2：好 provider 的填色未繪製")
    zone.clearProviders()
    zone.resetLogs()
end

-- A5：drawZoneIcons 視野預裁——框外零投影、預裁不取代螢幕裁切、逐 rect 獨立、
-- 隨機不變式（中心在窗內者永不被預裁）。預設 AABB [0,100]²＝恆等投影下的視窗。
do
    local function makeIconInner(scale)
        local inner = { width = 100, height = 100, draws = 0, projs = 0 }
        inner.drawTextureScaled = function(self) self.draws = self.draws + 1 end
        inner.mapAPI = {
            worldToUIX = function(_, x) inner.projs = inner.projs + 1; return x end,
            worldToUIY = function(_, _, y) inner.projs = inner.projs + 1; return y end,
            getWorldScale = function() return scale or 10 end,
        }
        return inner
    end
    local function iconZoneOf(...)
        local rs = {}
        for _, r in ipairs({ ... }) do rs[#rs + 1] = { x1 = r[1], y1 = r[2], x2 = r[3], y2 = r[4] } end
        return function() return { { icon = { tex = "T", r = 1, g = 1, b = 1 }, rects = rs } } end
    end

    -- 仿射化後投影呼叫＝pass 固定 3 點採樣（6 次 worldToUI），每圖標 0 次——
    -- 以下 projs==6 同時鎖住「無逐圖標 Java 投影」這個優化本身
    -- A5-1 框內 rect：照畫
    zone.addProvider("icon1", iconZoneOf({ 40, 40, 50, 50 }), true)
    local a = makeIconInner(); zone.icons(a); zone.clearProviders()
    assert(a.draws == 1 and a.projs == 6, "A5-1 框內 rect 應照畫且零逐圖標投影（projs=" .. a.projs .. "）")

    -- A5-2 框外 rect：不畫、無逐圖標投影
    zone.addProvider("icon2", iconZoneOf({ 500, 500, 510, 510 }), true)
    local b = makeIconInner(); zone.icons(b); zone.clearProviders()
    assert(b.draws == 0 and b.projs == 6, "A5-2 框外 rect 應零繪製零逐圖標投影（projs=" .. b.projs .. "）")

    -- A5-3 rect 與框相交但圖標中心在窗外：預裁放行、螢幕裁切仍須擋下
    -- （預裁的安全論證依賴「繪製 ⇒ 中心在窗內」——見主檔 drawZoneIcons 註解）
    zone.addProvider("icon3", iconZoneOf({ 95, 40, 300, 50 }), true)
    local c = makeIconInner(); zone.icons(c); zone.clearProviders()
    assert(c.projs == 6 and c.draws == 0, "A5-3 中心出窗仍被畫出（螢幕裁切失效）")

    -- A5-4 多 rect zone：逐 rect 獨立裁切，框內那顆照畫
    zone.addProvider("icon4", iconZoneOf({ 40, 40, 50, 50 }, { 500, 500, 510, 510 }), true)
    local d = makeIconInner(); zone.icons(d); zone.clearProviders()
    assert(d.draws == 1 and d.projs == 6, "A5-4 多 rect zone 逐 rect 裁切語意改變")

    -- A5-5 隨機不變式（300 例 × 滑條 8/18/48）：預裁前後畫面必須逐筆一致
    math.randomseed(42)
    for _, s in ipairs({ 8, 18, 48 }) do
        zone.setIconSize(s)
        for _ = 1, 300 do
            local cx, cy = math.random() * 140 - 20, math.random() * 140 - 20
            local hw, hh = math.random() * 80, math.random() * 80
            zone.addProvider("icon5", iconZoneOf({ cx - hw, cy - hh, cx + hw, cy + hh }), true)
            local e = makeIconInner(); zone.icons(e); zone.clearProviders()
            local half = s / 2
            local shouldDraw = cx - half >= 1 and cy - half >= 1
                and cx + half <= 99 and cy + half <= 99
            assert(e.draws == (shouldDraw and 1 or 0), string.format(
                "A5-5 預裁改變畫面：size=%d center=(%.1f,%.1f) draws=%d 期望=%d",
                s, cx, cy, e.draws, shouldDraw and 1 or 0))
        end
    end
    zone.setIconSize(18)

    -- A5-6 iconOnce（POI v3 逐房間矩形）：兩個都在視窗內的矩形，帶旗標只畫
    -- rects[1] 一顆（防一棟 200 房疊 200 圖標）；無旗標維持每 rect 一顆
    zone.addProvider("icon6", function()
        return { { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = 40, y1 = 40, x2 = 50, y2 = 50 },
                { x1 = 60, y1 = 60, x2 = 70, y2 = 70 } } } }
    end, true)
    local f = makeIconInner(); zone.icons(f); zone.clearProviders()
    assert(f.draws == 1 and f.projs == 6, "A5-6 iconOnce 應只畫 rects[1]（draws=" .. f.draws .. "）")
    zone.addProvider("icon7", iconZoneOf({ 40, 40, 50, 50 }, { 60, 60, 70, 70 }), true)
    local g2 = makeIconInner(); zone.icons(g2); zone.clearProviders()
    assert(g2.draws == 2, "A5-6 無旗標的多矩形 zone 應每 rect 一顆（draws=" .. g2.draws .. "）")

    -- A7 圖標去重疊：中/遠距（scale<6）lodRect zone 同一圖標尺寸格只畫第一顆、
    -- 不同格照畫；細節檔（scale>=6）全畫（疊圖時眼睛只看得到最上面那顆——
    -- 拉遠時數百顆互疊圖標的 drawTextureScaled 是遠距檔最大殘餘成本）
    local function lodIconZone(x1, y1)
        return { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = x1, y1 = y1, x2 = x1 + 4, y2 = y1 + 4 } },
            lodRect = { x1 = x1, y1 = y1, x2 = x1 + 4, y2 = y1 + 4 } }
    end
    zone.addProvider("icon8", function()
        return { lodIconZone(40, 40), lodIconZone(44, 42), lodIconZone(80, 80) }
    end, true)
    local dc = makeIconInner(3)
    zone.icons(dc); zone.clearProviders()
    assert(dc.draws == 2, "A7 同格應去重疊、異格照畫（得 " .. dc.draws .. "）")
    zone.addProvider("icon9", function()
        return { lodIconZone(40, 40), lodIconZone(44, 42) }
    end, true)
    local dcd = makeIconInner(10)
    zone.icons(dcd); zone.clearProviders()
    assert(dcd.draws == 2, "A7 細節檔不去重疊（得 " .. dcd.draws .. "）")
end

-- A8 POI 顯示距離沙盒閘（PoiDisplayDistance）：僅 internal provider 受距離限制，
-- 三 pass（fill/lines/icons）同一判定；最近點語意含邊界（<=）；距離啟用但缺
-- 玩家時 fail closed（內部 provider 連呼叫都不發生）；外部 addon zone 不受影響
do
    local function distZone(x1, y1, x2, y2)
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5, name = "Z",
            icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = x1, y1 = y1, x2 = x2, y2 = y2 } },
            lodRect = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 },
        } }
    end
    local function makeDistInner()
        local inner = makeInner(10) -- 細節檔：LOD 不干擾距離閘
        inner.draws = 0
        inner.drawTextureScaled = function(self) self.draws = self.draws + 1 end
        return inner
    end

    -- A8-1 基本閘：近 zone（最近點 ~14 格）畫、遠 zone（~71 格）隱；三 pass 一致
    zone.setPoiDist(30)
    zone.setPlayerPos(10, 10)
    zone.addProvider("poiNear", function() return distZone(20, 20, 30, 30) end, true)
    zone.addProvider("poiFar", function() return distZone(60, 60, 70, 70) end, true)
    local a8 = makeDistInner()
    zone.fill(a8)
    assert(a8.polyCount == 1, "A8-1 fill 應只畫近 zone（得 " .. a8.polyCount .. "）")
    zone.resetEdgeCount(); zone.lines(a8)
    assert(zone.edgeCount() == 4, "A8-1 lines 應只畫近 zone 四邊（得 " .. zone.edgeCount() .. "）")
    -- 名稱與框線同段：遠 zone 的名稱必須一併被距離閘藏掉（近 zone 恰畫一次）
    assert(a8.textCount == 1, "A8-1 名稱應只畫近 zone 一次（得 " .. a8.textCount .. "）")
    zone.icons(a8)
    assert(a8.draws == 1, "A8-1 icons 應只畫近 zone 圖標（得 " .. a8.draws .. "）")
    -- playerNum 透傳：預設 inner 無 playerNum → fallback 0；帶 playerNum=1 的
    -- inner（分屏 P2）必須把 1 傳給 getSpecificPlayer，不得硬編碼 0
    assert(zone.lastPn() == 0, "A8-1 預設 inner 應以 playerNum 0 取玩家（得 " .. tostring(zone.lastPn()) .. "）")
    local p2 = makeDistInner()
    p2.playerNum = 1
    zone.addProvider("poiP2", function() return distZone(20, 20, 30, 30) end, true)
    zone.fill(p2)
    assert(zone.lastPn() == 1, "A8-1 分屏 inner 的 playerNum 未透傳（得 " .. tostring(zone.lastPn()) .. "）")
    zone.clearProviders()

    -- A8-2 邊界含等號：最近點恰 N 格＝顯示；N 縮 1 格＝隱藏
    zone.setPlayerPos(10, 40)
    zone.addProvider("poiEdge", function() return distZone(40, 40, 50, 50) end, true) -- 最近點 (40,40)，距 30
    local at = makeDistInner(); zone.fill(at)
    assert(at.polyCount == 1, "A8-2 恰在距離上（<=）應顯示")
    zone.setPoiDist(29)
    local under = makeDistInner(); zone.fill(under)
    assert(under.polyCount == 0, "A8-2 超出距離應隱藏")
    zone.clearProviders()

    -- A8-3 外部 addon zone 不受距離閘影響（同一顆遠 zone 改外部註冊）
    zone.setPoiDist(30)
    zone.setPlayerPos(10, 10)
    zone.addProvider("addonFarExt", function() return distZone(60, 60, 70, 70) end)
    local ext = makeDistInner()
    zone.fill(ext)
    assert(ext.polyCount == 1, "A8-3 外部 zone 不應被距離閘裁掉")
    zone.icons(ext)
    assert(ext.draws == 1, "A8-3 外部 zone 圖標不應被距離閘裁掉")
    zone.clearProviders()

    -- A8-4 fail closed：距離啟用但缺玩家→內部 provider 整段不畫（連 fn 都不呼叫）；
    -- 外部 provider 照常
    zone.setPlayerPos(nil)
    local intCalled = 0
    zone.addProvider("poiNoPlayer", function()
        intCalled = intCalled + 1
        return distZone(20, 20, 30, 30)
    end, true)
    zone.addProvider("addonNoPlayer", function() return distZone(20, 20, 30, 30) end)
    local nop = makeDistInner()
    zone.fill(nop); zone.icons(nop)
    assert(intCalled == 0, "A8-4 缺玩家時內部 provider 不應被呼叫（fail closed）")
    assert(nop.polyCount == 1 and nop.draws == 1, "A8-4 缺玩家時外部 provider 應照常繪製")
    zone.clearProviders()

    -- A8-5 閘未啟用（nil＝沙盒 0/缺值）：遠 zone 恢復顯示；此時缺玩家也不影響
    zone.setPoiDist(nil)
    zone.addProvider("poiFarOff", function() return distZone(60, 60, 70, 70) end, true)
    local off = makeDistInner()
    zone.fill(off)
    assert(off.polyCount == 1, "A8-5 閘未啟用時遠 zone 應照畫")
    zone.clearProviders()
    zone.setPlayerPos(50, 50)

    -- A8-6 逐房間判距（codex review：lodRect＝分類房間聯集 AABB，非整棟建築
    -- bbox；大型建物的分類房間可能只佔一角、AABB 含空白區）：production 形狀
    -- ＝lodRect ⊋ 各 rects。玩家在 AABB 內但距所有房間 >N → 必須隱藏（AABB
    -- 僅快速排除、不得當命中）；任一房間在 N 內 → 整 zone 顯示（三 pass 一致）
    local function compositeZone()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5, name = "Z",
            icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 },
                { x1 = 70, y1 = 10, x2 = 80, y2 = 20 } },
            lodRect = { x1 = 10, y1 = 10, x2 = 80, y2 = 20 },
        } }
    end
    zone.setPoiDist(15)
    zone.setPlayerPos(45, 15) -- AABB 內（距 AABB 0 格），距兩房各 25 格
    zone.addProvider("poiComposite", compositeZone, true)
    local comp = makeDistInner()
    zone.fill(comp)
    zone.resetEdgeCount(); zone.lines(comp)
    zone.icons(comp)
    assert(comp.polyCount == 0 and zone.edgeCount() == 0 and comp.draws == 0,
        "A8-6 AABB 內但距所有房間 >N 應隱藏（poly=" .. comp.polyCount
        .. " edges=" .. zone.edgeCount() .. " draws=" .. comp.draws .. "）")
    zone.clearProviders()
    zone.addProvider("poiComposite2", compositeZone, true)
    zone.setPlayerPos(85, 15) -- 距第二房 5 格、第一房 65 格：任一房命中即整 zone 顯示
    local comp2 = makeDistInner()
    zone.fill(comp2)
    assert(comp2.polyCount == 2, "A8-6 任一房間在距離內應整 zone 顯示（得 " .. comp2.polyCount .. "）")
    zone.resetEdgeCount(); zone.lines(comp2)
    assert(zone.edgeCount() == 8 and comp2.textCount == 1,
        "A8-6 lines 應畫兩房 8 邊＋名稱一次（edges=" .. zone.edgeCount() .. " text=" .. comp2.textCount .. "）")
    zone.icons(comp2)
    assert(comp2.draws == 1, "A8-6 iconOnce 圖標應畫一顆（得 " .. comp2.draws .. "）")
    zone.clearProviders()
    zone.setPoiDist(nil)
    zone.setPlayerPos(50, 50)
    zone.resetLogs()
end

print("zone render: clipped-edge alpha + A1 stencil + A2 isolation + A3 AABB + A5 icon-cull + A8 poi-distance cases passed")

--------------------------------------------------------------------------------
-- registerZoneAction API：參數驗證 / dormant / options 正規化 / onTrigger callback
--------------------------------------------------------------------------------
local actionBody = assert(source:match(
    "%-%- test:zone%-action:start\n(.-)\n%-%- test:zone%-action:end"),
    "找不到 zone-action 測試區段")
local actionPrelude = [=[
MinidoracatMiniMapAPI = {}
local function print() end
]=]
local actionSuffix = [=[
return {
    register = function(...) return MinidoracatMiniMapAPI.registerZoneAction(...) end,
    actions = registeredZoneActions,
}
]=]
local actionChunk, actionErr = compile(actionPrelude .. "\n" .. actionBody .. "\n" .. actionSuffix)
assert(actionChunk, actionErr)
local za = actionChunk()

-- dormant：壞參數一律不註冊（無 owner / 無 labelKey / 無 onTrigger / onTrigger 非 function / spec 非 table）
za.register(nil, { labelKey = "L", onTrigger = function() end })
za.register("owner", { onTrigger = function() end })
za.register("owner", { labelKey = "L" })
za.register("owner", { labelKey = "L", onTrigger = "nope" })
za.register("owner", "notatable")
assert(#za.actions == 0, "壞參數不應註冊任何動作（dormant），得到 " .. #za.actions)

-- 合法＋options 正規化（無/空 labelKey 的選項過濾）＋onTrigger 收到選中 value
local got = "unset"
za.register("ZonesOwner", {
    labelKey = "UI_Gen", tooltipKey = "UI_GenTip",
    options = {
        { value = "current", labelKey = "UI_Cur" },
        { value = "CH", labelKey = "UI_CH" },
        { value = "bad" },              -- 無 labelKey → 過濾
        { labelKey = "" },              -- 空 labelKey → 過濾
    },
    onTrigger = function(v) got = v end,
})
assert(#za.actions == 1, "合法參數應註冊一筆，得到 " .. #za.actions)
local a = za.actions[1]
assert(a.owner == "ZonesOwner" and a.labelKey == "UI_Gen" and a.tooltipKey == "UI_GenTip",
    "動作欄位未正確保存")
assert(#a.options == 2, "無/空 labelKey 的選項應被過濾，得到 " .. #a.options)
assert(a.options[1].value == "current" and a.options[2].value == "CH", "options 值未保留")
a.onTrigger(a.options[2].value)
assert(got == "CH", "onTrigger 未收到選中的 value，得到 " .. tostring(got))

-- 省略 options → 純按鈕（options=nil）；全部無效選項 → 亦退為純按鈕
za.register("Owner2", { labelKey = "UI_Btn", onTrigger = function() end })
assert(za.actions[2].options == nil, "省略 options 應為 nil（純按鈕）")
za.register("Owner3", { labelKey = "UI_Btn", options = { { value = 1 } }, onTrigger = function() end })
assert(za.actions[3].options == nil, "全部選項無效應退為 nil（純按鈕）")

-- 空 tooltipKey → 存成 nil；純按鈕 onTrigger 收 nil
local btnGot = "unset"
za.register("Owner4", { labelKey = "UI_Btn", tooltipKey = "",
    onTrigger = function(v) btnGot = v end })
assert(za.actions[4].tooltipKey == nil, "空 tooltipKey 應存為 nil")
za.actions[4].onTrigger(nil)
assert(btnGot == nil, "純按鈕 onTrigger 應收到 nil")

print("zone action: arg-validation / dormant / options-normalize / onTrigger cases passed")

--------------------------------------------------------------------------------
-- POI 圖標樣式選擇（MinidoracatMiniMapPOI.lua iconTexture）：單色 / 彩色 / 缺檔回退
-- 抽 provider 檔的 -- test:poi-icon: 標記區段→補 getTexture/log stub→離線斷言。
--------------------------------------------------------------------------------
local poiPath = arg[2]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMapPOI.lua"
local poiFile = assert(io.open(poiPath, "rb"))
local poiSource = poiFile:read("*a"):gsub("\r\n", "\n")
poiFile:close()
local iconBody = assert(poiSource:match(
    "%-%- test:poi%-icon:start\n(.-)\n%-%- test:poi%-icon:end"),
    "找不到 POI 圖標測試區段")
local iconPrelude = [=[
local textures = {}
local function getTexture(path) return textures[path] end
local logged = 0
local function log() logged = logged + 1 end
]=]
local iconSuffix = [=[
return {
    setTex = function(path, v) textures[path] = v end,
    pick = function(cat, colorMode) return iconTexture(cat, colorMode) end,
    logCount = function() return logged end,
}
]=]
local iconChunk, iconErr = compile(iconPrelude .. "\n" .. iconBody .. "\n" .. iconSuffix)
assert(iconChunk, iconErr)
local poi = iconChunk()

-- military：mono 與 color 皆備 → 單色回 mono＋isColor=false、彩色回 color＋isColor=true
poi.setTex("media/ui/poi_icons/poi_military.png", "MONO_MIL")
poi.setTex("media/ui/poi_icons/color/poi_military.png", "COLOR_MIL")
do
    local tex, isColor = poi.pick("military", false)
    assert(tex == "MONO_MIL" and isColor == false, "單色模式應取 mono 材質、isColor=false")
    local ctex, cIsColor = poi.pick("military", true)
    assert(ctex == "COLOR_MIL" and cIsColor == true, "彩色模式（檔在）應取 color 材質、isColor=true")
    local btex, bIsColor = poi.pick("military", false)
    assert(btex == "MONO_MIL" and bIsColor == false, "彩色快取後切回單色未取 mono")
end

-- police：僅 mono（模擬彩色素材未落地）→ 彩色模式回退 mono、isColor=false、log-once
poi.setTex("media/ui/poi_icons/poi_police.png", "MONO_POL")
do
    local tex, isColor = poi.pick("police", true)
    assert(tex == "MONO_POL" and isColor == false, "彩色檔缺應回退 mono、isColor=false")
    assert(poi.logCount() == 1, "缺檔回退應 log-once（第一次）")
    poi.setTex("media/ui/poi_icons/poi_gas.png", "MONO_GAS")
    poi.pick("gas", true) -- 另一類別彩色仍缺
    assert(poi.logCount() == 1, "缺檔 log 應全域 once，不重複")
end

-- 兩套皆缺 → tex=nil、isColor=false（主檔 iconPass 跳過該筆）
do
    local tex, isColor = poi.pick("nonexistent", false)
    assert(tex == nil and isColor == false, "材質全缺應回 nil、isColor=false")
end

print("poi icon: mono/color/fallback/log-once cases passed")

--------------------------------------------------------------------------------
-- POIData → zone 消費契約（buildPoiConverted，v3 rn/r）：座標轉換、iconOnce、
-- lodRect 聯集、無效矩形/整筆/未知類別略過、開關 gate
--（codex 終審抓出的 consumer 零覆蓋缺口——producer 與渲染端之間這一層若把
-- x2=x+w 算錯或漏 iconOnce，其餘測試全綠但 1704 筆 POI 全滅）
--------------------------------------------------------------------------------
local convBody = assert(poiSource:match(
    "%-%- test:poi%-convert:start\n(.-)\n%-%- test:poi%-convert:end"),
    "找不到 poi-convert 測試區段")
local convPrelude = [=[
local opts = { PoiIcons = true, PoiBlocks = true, PoiColorIcons = false }
local function getBoolOption(id, default)
    local v = opts[id]
    if v == nil then return default end
    return v
end
local function iconTexture(cat, colorMode) return "TEX_" .. cat, colorMode end
local function getText(key) return "T_" .. key end
local POI_FILL_ALPHA = 0.28
local POI_BORDER_ALPHA = 0.9
]=]
local convSuffix = [=[
return {
    build = buildPoiConverted,
    zones = function() return poiZones end,
    setOpt = function(k, v) opts[k] = v end,
}
]=]
local convChunk, convErr = compile(convPrelude .. "\n" .. convBody .. "\n" .. convSuffix)
assert(convChunk, convErr)
local conv = convChunk()

MinidoracatMiniMapPOICategories = { CATEGORIES = {
    police = { nameKey = "K_Police", color = { r = 0.2, g = 0.4, b = 0.8 } },
} }
MinidoracatMiniMapPOIData = {
    { cat = "police", rn = 3, r = {
        { x = 10, y = 20, w = 5, h = 4 },
        { x = 30, y = 20, w = 2, h = 2 },
        { x = 1, y = 1, w = 0, h = 3 },
    } },
    { cat = "police", rn = 1, r = { { x = 1, y = 1, w = 0, h = 1 } } },
    { cat = "nope", rn = 1, r = { { x = 1, y = 1, w = 1, h = 1 } } },
}
conv.build()
local zs = conv.zones()
assert(#zs == 1, "poi-convert：應恰 1 個 zone（無效整筆/未知類別須略過，得 " .. #zs .. "）")
local pz = zs[1]
assert(pz.iconOnce == true, "poi-convert：iconOnce 未設")
assert(#pz.rects == 2, "poi-convert：合法矩形應 2 個（w<=0 須略過）")
assert(pz.rects[1].x1 == 10 and pz.rects[1].y1 == 20 and pz.rects[1].x2 == 15 and pz.rects[1].y2 == 24,
    "poi-convert：rects[1] 座標轉換錯（x2 必須是 x+w）")
assert(pz.rects[2].x1 == 30 and pz.rects[2].x2 == 32 and pz.rects[2].y2 == 22,
    "poi-convert：rects[2] 轉換錯")
assert(pz.lodRect and pz.lodRect.x1 == 10 and pz.lodRect.y1 == 20
    and pz.lodRect.x2 == 32 and pz.lodRect.y2 == 24, "poi-convert：lodRect 聯集框錯")
assert(pz.name == "T_K_Police" and pz.icon and pz.icon.tex == "TEX_police",
    "poi-convert：name/icon 欄位錯")
assert(pz.fillAlpha == 0.28 and pz.borderAlpha == 0.9, "poi-convert：blocks 開時 alpha 應取常數")
assert(pz.icon.r == 0.2 and pz.category == "police", "poi-convert：單色染色/類別欄位錯")

conv.setOpt("Cat_police", false)
conv.build()
assert(#conv.zones() == 0, "poi-convert：Cat_ off 應整批略過")
conv.setOpt("Cat_police", nil)
conv.setOpt("PoiIcons", false)
conv.setOpt("PoiBlocks", false)
conv.build()
assert(#conv.zones() == 0, "poi-convert：icons+blocks 全關應為空")
MinidoracatMiniMapPOIData = nil
MinidoracatMiniMapPOICategories = nil

print("poi convert: rn/r 契約 / x2=x+w / iconOnce / lodRect / 略過與 gate cases passed")
