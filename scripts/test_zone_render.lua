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
-- deriveAffine 已前移出 zone-render 區段（殭屍/動物繪製共用），獨立標記抽取後
-- 拼在 zone body 之前——維持單一事實來源，不在 prelude 放複製品
local affineBody = assert(source:match(
    "%-%- test:derive%-affine:start\n(.-)\n%-%- test:derive%-affine:end"),
    "找不到 deriveAffine 測試區段")
local csvBody = assert(source:match(
    "%-%- test:csv%-set:start\n(.-)\n%-%- test:csv%-set:end"),
    "找不到 unifiedCsvSet 測試區段")
local zcatBody = assert(source:match(
    "%-%- test:zone%-categories:start\n(.-)\n%-%- test:zone%-categories:end"),
    "找不到 zoneExternalCategories 測試區段")
zoneBody = csvBody .. "\n" .. affineBody .. "\n" .. zoneBody .. "\n" .. zcatBody
local zonePrelude = [=[
local registeredZoneProviders = {}
local zoneLayerOn = true
local logs = {}
local boolOverrides = {}
local function getBoolOption(id, default)
    if id == "ZoneLayer" then return zoneLayerOn end
    local v = boolOverrides[id]
    if v ~= nil then return v end
    return default
end
-- ZoneCategoryFilter 的 modOptions/unifiedCsvSet stub（zoneDisabledCats 用）：
-- catFilterValue=nil＝無選項（篩選停用），字串＝CSV 停用清單
local catFilterValue = nil
local modOptions = {
    getOption = function(_, id)
        if id == "ZoneCategoryFilter" and catFilterValue ~= nil then
            return { getValue = function() return catFilterValue end }
        end
        return nil
    end,
}
-- unifiedCsvSet 不做 stub：production 版經 test:csv-set 標記抽取（單一事實
-- 來源，防 stub 語意分歧——codex review 抓出 stub trim 與 production 不一致）
local Core = {}
local zoneCatErrLogged = {}
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
    setBoolOverride = function(id, v) boolOverrides[id] = v end,
    setCatFilter = function(v) catFilterValue = v end,
    zoneCategories = function() return Core.zoneExternalCategories() end,
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

    -- A4-3 框線與名稱解耦（2026-08-13）：borderAlpha==0／無 border 只代表不畫框，
    -- 名稱照畫。POI 區塊模式＝純色塊＋名稱走此路；Zones addon 的 borderAlpha=0
    -- 區域（其 name 為必填）以前被一併吞掉，此改動一併修正
    zone.addProvider("noBorderNamed", function()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Zone",
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 },
                { x1 = 30, y1 = 10, x2 = 40, y2 = 20 } },
        } }
    end)
    local nb = makeInner()
    zone.resetEdgeCount(); zone.lines(nb)
    assert(zone.edgeCount() == 0, "A4-3 無 border 不得畫框線（得 " .. zone.edgeCount() .. "）")
    assert(nb.textCount == 1, "A4-3 無 border 時名稱仍須畫一次（得 " .. nb.textCount .. "）")
    zone.clearProviders()
    -- 顯式 borderAlpha=0 同理
    zone.addProvider("zeroBorderNamed", function()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Zone",
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0,
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } },
        } }
    end)
    local zb = makeInner()
    zone.resetEdgeCount(); zone.lines(zb)
    assert(zone.edgeCount() == 0 and zb.textCount == 1,
        "A4-3 borderAlpha=0 應無框線但有名稱（edges=" .. zone.edgeCount()
        .. " text=" .. zb.textCount .. "）")
    zone.clearProviders()
    -- 無框線又無名稱＝整段跳過（不得白跑投影）
    zone.addProvider("noBorderNoName", function()
        return { { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } } } }
    end)
    local nn = makeInner()
    zone.resetEdgeCount(); zone.lines(nn)
    assert(zone.edgeCount() == 0 and nn.textCount == 0,
        "A4-3 無框線無名稱應整段跳過")
    zone.clearProviders()

    -- A4-3b 空 rects 的 name-only zone 不得打死整個 pass：外部 addon 可給
    -- name＋rects={}，rn 強制 1 會對 rects[1]=nil 解參考，safeDrawZone 只能整段
    -- 中止——後續合法 zone 的名稱全滅（codex review mutation probe 實證）。
    -- 契約：空者靜默跳過，後續 zone 照畫
    zone.addProvider("emptyThenValid", function()
        return {
            { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Empty", rects = {} },
            { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Valid",
                rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } } },
        }
    end)
    local ev = makeInner()
    local okLines = pcall(zone.lines, ev)
    zone.clearProviders()
    assert(okLines, "A4-3b 空 rects name-only zone 讓 lines pass 拋錯")
    assert(ev.textCount == 1,
        "A4-3b 空 zone 之後的合法 zone 名稱應照畫（得 " .. ev.textCount .. "）")

    -- A4-4 「只畫名稱時只投影 rects[1]」的等價性前提：名稱恆錨定 rects[1]，故
    -- rects[1] 離屏時名稱必不畫——與其餘矩形是否在屏內無關。這條性質成立，
    -- rn=1 的優化才不改變任何輸出（該優化本身無視覺差異，測不到，只能鎖前提）
    zone.addProvider("nameAnchorOffscreen", function()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Zone",
            rects = { { x1 = 200, y1 = 200, x2 = 210, y2 = 210 },  -- 錨點離屏
                { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } },          -- 其餘在屏內
        } }
    end)
    local ao = makeInner()
    zone.lines(ao)
    assert(ao.textCount == 0,
        "A4-4 錨點矩形離屏時名稱不得畫（得 " .. ao.textCount .. "）")
    zone.clearProviders()
    zone.resetLogs()

    -- A10 聚合旗標（ZR-1）：zones 表帶 hasFill/hasLine/hasIcon==false 時對應 pass
    -- 整段跳過（即使個別 zone 有可畫內容——旗標是 provider 的聲明，錯設是 provider
    -- 的 bug、不是 renderer 要兜的）；nil（外部 addon 未聲明）照舊逐 zone 判斷
    local function flaggedZones(flags)
        local zs = { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Z",
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5,
            icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } },
        } }
        for k, v in pairs(flags) do zs[k] = v end
        return function() return zs end
    end
    zone.addProvider("flagOff", flaggedZones({ hasFill = false, hasLine = false, hasIcon = false }), true)
    local fo = makeInner()
    fo.draws = 0
    fo.drawTextureScaled = function(self) self.draws = self.draws + 1 end
    zone.fill(fo); zone.resetEdgeCount(); zone.lines(fo); zone.icons(fo)
    assert(fo.polyCount == 0 and zone.edgeCount() == 0 and fo.textCount == 0 and fo.draws == 0,
        "A10 三旗標 false 應整段跳過（poly=" .. fo.polyCount .. " edges=" .. zone.edgeCount()
        .. " text=" .. fo.textCount .. " icons=" .. fo.draws .. "）")
    zone.clearProviders()
    zone.addProvider("flagOn", flaggedZones({ hasFill = true, hasLine = true, hasIcon = true }), true)
    local fn2 = makeInner()
    fn2.draws = 0
    fn2.drawTextureScaled = function(self) self.draws = self.draws + 1 end
    zone.fill(fn2); zone.resetEdgeCount(); zone.lines(fn2); zone.icons(fn2)
    assert(fn2.polyCount == 1 and zone.edgeCount() == 4 and fn2.textCount == 1 and fn2.draws == 1,
        "A10 三旗標 true 應照畫（poly=" .. fn2.polyCount .. " edges=" .. zone.edgeCount()
        .. " text=" .. fn2.textCount .. " icons=" .. fn2.draws .. "）")
    zone.clearProviders()
    zone.resetLogs()

    -- A11 名稱遠距顯示（ZoneNamesFar，預設開；僅外部 zone）：外部 lodRect zone
    -- 於中距檔名稱照畫、框線仍不畫；關閉選項→名稱同 POI 鎖細節檔；內部（POI）
    -- 不受此選項影響，名稱恆鎖細節檔防洗版
    local function extLodNamed()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Zone",
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5,
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } },
            lodRect = { x1 = 10, y1 = 10, x2 = 20, y2 = 20 },
        } }
    end
    zone.addProvider("extLodNamed", extLodNamed) -- 外部
    local a11 = makeInner(3) -- 中距檔
    zone.resetEdgeCount(); zone.lines(a11)
    assert(a11.textCount == 1 and zone.edgeCount() == 0,
        "A11 外部 lod zone 中距：名稱應畫、框線不畫（text=" .. a11.textCount
        .. " edges=" .. zone.edgeCount() .. "）")
    zone.setBoolOverride("ZoneNamesFar", false)
    local a11b = makeInner(3)
    zone.resetEdgeCount(); zone.lines(a11b)
    assert(a11b.textCount == 0, "A11 關閉後中距不畫名稱（得 " .. a11b.textCount .. "）")
    zone.setBoolOverride("ZoneNamesFar", nil)
    zone.clearProviders()
    zone.addProvider("intLodNamed", extLodNamed, true) -- 同 zone 改內部註冊
    local a11c = makeInner(3)
    zone.resetEdgeCount(); zone.lines(a11c)
    assert(a11c.textCount == 0, "A11 內部（POI）zone 不受 ZoneNamesFar 影響（得 " .. a11c.textCount .. "）")
    -- 細節檔不受影響（框線＋名稱照舊）
    zone.clearProviders()
    zone.addProvider("extLodNamed2", extLodNamed)
    local a11d = makeInner(10)
    zone.resetEdgeCount(); zone.lines(a11d)
    assert(a11d.textCount == 1 and zone.edgeCount() == 4,
        "A11 細節檔行為不變（text=" .. a11d.textCount .. " edges=" .. zone.edgeCount() .. "）")
    zone.clearProviders()
    zone.resetLogs()

    -- A12 外部 zone 類別篩選（ZoneCategoryFilter CSV 停用清單）：停用類別的
    -- zone 三 pass 全跳過；無類別/未停用照畫；內部（POI）zone 不受此清單影響
    local function catZones()
        return { { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Shop",
                category = "shop",
                rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } } },
            { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Pvp",
                category = "pvp",
                rects = { { x1 = 30, y1 = 10, x2 = 40, y2 = 20 } } },
            { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, name = "Plain",
                rects = { { x1 = 50, y1 = 10, x2 = 60, y2 = 20 } } } }
    end
    zone.setCatFilter("shop")
    zone.addProvider("catExt", catZones)
    local a12 = makeInner()
    zone.fill(a12)
    assert(a12.polyCount == 2, "A12 停用 shop 後 fill 應剩 2（得 " .. a12.polyCount .. "）")
    zone.resetEdgeCount(); zone.lines(a12)
    assert(a12.textCount == 2, "A12 停用 shop 後名稱應剩 2（得 " .. a12.textCount .. "）")
    zone.clearProviders()
    -- 內部 zone 帶同名 category 不受影響（POI 的 category 是自家命名空間）
    zone.addProvider("catInt", function()
        return { { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, category = "shop",
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } } } }
    end, true)
    local a12b = makeInner()
    zone.fill(a12b)
    assert(a12b.polyCount == 1, "A12 內部 zone 不受類別清單影響（得 " .. a12b.polyCount .. "）")
    zone.clearProviders()
    -- icons pass 同判定（codex review：原測試漏 icons，移除 icons 的 disCats 仍會綠）
    local function catIconZones()
        return { { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true, category = "shop",
                rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 } } },
            { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true, category = "pvp",
                rects = { { x1 = 60, y1 = 60, x2 = 70, y2 = 70 } } } }
    end
    zone.addProvider("catExtIcons", catIconZones)
    local a12i = makeInner()
    a12i.draws = 0
    a12i.drawTextureScaled = function(self) self.draws = self.draws + 1 end
    zone.icons(a12i)
    assert(a12i.draws == 1, "A12 icons pass 停用 shop 應只畫 1 顆（得 " .. a12i.draws .. "）")
    zone.clearProviders()
    zone.addProvider("catIntIcons", catIconZones, true) -- 內部：icons 亦免疫
    local a12j = makeInner()
    a12j.draws = 0
    a12j.drawTextureScaled = function(self) self.draws = self.draws + 1 end
    zone.icons(a12j)
    assert(a12j.draws == 2, "A12 內部 zone 的 icons 不受類別清單影響（得 " .. a12j.draws .. "）")
    zone.clearProviders()
    -- raw 比對快取失效：換停用值即刻生效（shop 恢復、pvp 隱藏）
    zone.setCatFilter("pvp")
    zone.addProvider("catExt2", catZones)
    local a12c = makeInner()
    zone.fill(a12c)
    assert(a12c.polyCount == 2, "A12 換停用值後 fill 應為 shop+plain（得 " .. a12c.polyCount .. "）")
    zone.resetEdgeCount(); zone.lines(a12c)
    assert(a12c.textCount == 2, "A12 換停用值後名稱應為 2（得 " .. a12c.textCount .. "）")
    zone.clearProviders()
    zone.setCatFilter(nil)
    zone.resetLogs()

    -- A13 Core.zoneExternalCategories：可編碼過濾（含逗號/sentinel 不進清單——
    -- 停用「a,b」會誤傷類別 a 與 b）、排序、去重、internal 排除、壞 provider log-once
    zone.addProvider("zcExt", function()
        return { { category = "shop" }, { category = "a,b" }, { category = "-" },
            { category = "nil" }, { category = "bar" }, { category = "shop" }, {} }
    end)
    zone.addProvider("zcInt", function() return { { category = "internalcat" } } end, true)
    local zc = zone.zoneCategories()
    assert(#zc == 2 and zc[1] == "bar" and zc[2] == "shop",
        "A13 應僅列可編碼外部類別且排序（得 " .. table.concat(zc, "|") .. "）")
    zone.clearProviders()
    zone.resetLogs()
    zone.addProvider("zcBad", function() error("boom") end)
    zone.zoneCategories()
    zone.zoneCategories()
    assert(zone.logCount() == 1, "A13 壞 provider 應 log-once（得 " .. zone.logCount() .. "）")
    zone.clearProviders()
    zone.resetLogs()

    -- A9 底襯（haloAlpha）：細節檔每 rect 先畫外擴暗色 quad 再畫填色（2 poly/rect，
    -- 且底襯先畫——fill 蓋掉同 zone 內部接縫的前提）；中距檔僅聯集框填色、零底襯
    -- （城市尺度熱點不得新增成本）；無 haloAlpha 的 zone 行為不變（既有測試涵蓋）
    local function haloZone()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, haloAlpha = 0.5,
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 },
                { x1 = 30, y1 = 10, x2 = 40, y2 = 20 } },
            lodRect = { x1 = 10, y1 = 10, x2 = 40, y2 = 20 },
        } }
    end
    zone.addProvider("haloDetail", haloZone, true)
    local hd = makeInner(10)
    zone.fill(hd)
    assert(hd.polyCount == 4, "A9 細節檔應 2 底襯＋2 填色（得 " .. hd.polyCount .. "）")
    -- 順序：前兩個 poly 是外擴底襯（x < 10），後兩個是填色（x == 10 / 30）
    assert(hd.polyXs[1] < 10 and hd.polyXs[3] == 10,
        "A9 底襯須先於填色繪製（x1=" .. tostring(hd.polyXs[1]) .. " x3=" .. tostring(hd.polyXs[3]) .. "）")
    zone.clearProviders()
    zone.addProvider("haloMid", haloZone, true)
    local hm = makeInner(3)
    zone.fill(hm)
    assert(hm.polyCount == 1, "A9 中距檔應僅聯集框填色、無底襯（得 " .. hm.polyCount .. "）")
    zone.clearProviders()
    -- A9b 無 lodRect 的地標/大範圍 zone：底襯不受檔位限制——中距、拉遠皆
    -- 2 底襯＋2 填色（地堡實測回饋：中距整棟同框時沒暗邊＝看不出區域）。
    -- 刻意用「外部」provider 註冊：halo 檔位判斷無 internal 分支，此案例同時
    -- 鎖住外部/legacy zone（無 lodRect 帶 haloAlpha）的新契約——描邊跟填色走
    local function landmarkZone()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2, haloAlpha = 0.5,
            rects = { { x1 = 10, y1 = 10, x2 = 20, y2 = 20 },
                { x1 = 30, y1 = 10, x2 = 40, y2 = 20 } },
        } }
    end
    zone.addProvider("landmarkMid", landmarkZone)
    local lmMid = makeInner(3)
    zone.fill(lmMid)
    assert(lmMid.polyCount == 4,
        "A9b 無 lodRect zone 中距檔應 2 底襯＋2 填色（得 " .. lmMid.polyCount .. "）")
    assert(lmMid.polyXs[1] < 10 and lmMid.polyXs[3] == 10,
        "A9b 底襯仍須先於填色繪製")
    local lmFar = makeInner(1)
    zone.fill(lmFar)
    assert(lmFar.polyCount == 4,
        "A9b 無 lodRect zone 拉遠檔應照畫底襯＋填色（得 " .. lmFar.polyCount .. "）")
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

    -- A5-7 iconRect（POI 整棟外框模式）：圖標錨點改用 iconRect，fill/line 仍走
    -- rects——整棟框中心對商場類建物離實際店面數十格。rects 用一個「中心在窗外」
    -- 的巨框、iconRect 用窗內小房間：畫到＝確實吃 iconRect（吃 rects 會被裁掉）
    zone.addProvider("icon10", function()
        return { { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = -400, y1 = -400, x2 = 60, y2 = 60 } },
            iconRect = { x1 = 40, y1 = 40, x2 = 50, y2 = 50 } } }
    end, true)
    local ir = makeIconInner(); zone.icons(ir); zone.clearProviders()
    assert(ir.draws == 1, "A5-7 iconRect 未被採用為錨點（draws=" .. ir.draws .. "）")
    -- 無 iconRect 的同一 zone：巨框中心在窗外 → 不畫（證明上一條不是碰巧）
    zone.addProvider("icon11", function()
        return { { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = -400, y1 = -400, x2 = 60, y2 = 60 } } } }
    end, true)
    local nr = makeIconInner(); zone.icons(nr); zone.clearProviders()
    assert(nr.draws == 0, "A5-7 對照組：巨框中心在窗外本不該畫（draws=" .. nr.draws .. "）")

    -- A5-8 殘缺 iconRect 不得打死整個 pass：iconRect 是新公開的選配欄位，外部
    -- addon 給 { x1 = 40 } 這種殘缺表時，直接讀 x2 會 nil 比數字拋錯，而
    -- safeDrawZone 包的是整個 icon pass ——一個壞 zone 會讓當幀所有 provider 的
    -- 圖標全滅。契約：四欄不齊即忽略、回退 rects[ri]（codex review）
    zone.addProvider("icon12", function()
        return { { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = 40, y1 = 40, x2 = 50, y2 = 50 } },
            iconRect = { x1 = 40 } },
            { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
                rects = { { x1 = 60, y1 = 60, x2 = 70, y2 = 70 } } } }
    end, true)
    local bad = makeIconInner()
    local okPass = pcall(zone.icons, bad)
    zone.clearProviders()
    assert(okPass, "A5-8 殘缺 iconRect 讓整個 icon pass 拋錯")
    assert(bad.draws == 2, "A5-8 殘缺 iconRect 應回退 rects[1]，兩顆圖標都要畫（得 "
        .. bad.draws .. "）")

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
    -- A7b 無 lodRect 的地標 zone 刻意繞過去重疊：同格兩顆也都畫（地標圖標
    -- 不得被鄰格圖標吃掉——去重疊只作用於 lodRect zone）
    local function landmarkIconZone(x1, y1)
        return { icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            rects = { { x1 = x1, y1 = y1, x2 = x1 + 4, y2 = y1 + 4 } } }
    end
    zone.addProvider("icon10", function()
        return { landmarkIconZone(40, 40), landmarkIconZone(44, 42) }
    end, true)
    local dcl = makeIconInner(3)
    zone.icons(dcl); zone.clearProviders()
    assert(dcl.draws == 2, "A7b 無 lodRect zone 同格也應全畫（得 " .. dcl.draws .. "）")
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

    -- A8-2b 無 lodRect 的內部地標 zone 同受距離閘（鎖 zoneWithinDist 的
    -- lodRect nil guard——快速排除跳過、直接逐 rects 判距）
    zone.setPoiDist(30)
    zone.setPlayerPos(10, 10)
    zone.addProvider("poiLmNear", function()
        return { { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            rects = { { x1 = 20, y1 = 20, x2 = 30, y2 = 30 } } } }
    end, true)
    zone.addProvider("poiLmFar", function()
        return { { fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            rects = { { x1 = 60, y1 = 60, x2 = 70, y2 = 70 } } } }
    end, true)
    local lmDist = makeDistInner()
    zone.fill(lmDist)
    assert(lmDist.polyCount == 1,
        "A8-2b 無 lodRect 內部 zone 應同受距離閘（近畫遠隱，得 " .. lmDist.polyCount .. "）")
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

    -- A8-7 distRects 覆寫量測對象（POI 整棟外框模式）：畫的是整棟框，但可見距離
    -- 必須仍由分類房間決定——外框是外觀選項，不得讓大型建物提早數十格解鎖
    -- （codex review blocker 的收口）。無 distRects 者維持量 rects，addon 行為不變
    local function wholeZone()
        return { {
            fill = { r = 1, g = 1, b = 1 }, fillAlpha = 0.2,
            border = { r = 1, g = 1, b = 1 }, borderAlpha = 0.5, name = "Z",
            icon = { tex = "T", r = 1, g = 1, b = 1 }, iconOnce = true,
            -- 整棟框橫跨 10..80，實際分類房間只在 70..80 那一角
            rects = { { x1 = 10, y1 = 10, x2 = 80, y2 = 20 } },
            lodRect = { x1 = 10, y1 = 10, x2 = 80, y2 = 20 },
            iconRect = { x1 = 70, y1 = 10, x2 = 80, y2 = 20 },
            distRects = { { x1 = 70, y1 = 10, x2 = 80, y2 = 20 } },
        } }
    end
    zone.setPoiDist(15)
    zone.setPlayerPos(15, 15) -- 整棟框內（距框 0 格），但距實際房間 55 格
    zone.addProvider("poiWhole", wholeZone, true)
    local wh = makeDistInner()
    zone.fill(wh); zone.resetEdgeCount(); zone.lines(wh); zone.icons(wh)
    assert(wh.polyCount == 0 and zone.edgeCount() == 0 and wh.draws == 0,
        "A8-7 distRects 未生效：站在整棟框內、離分類房間 55 格仍被畫出（poly="
        .. wh.polyCount .. " edges=" .. zone.edgeCount() .. " draws=" .. wh.draws .. "）")
    zone.clearProviders()
    zone.addProvider("poiWhole2", wholeZone, true)
    zone.setPlayerPos(85, 15) -- 距分類房間 5 格 → 整棟框整個顯示
    local wh2 = makeDistInner()
    zone.fill(wh2); zone.icons(wh2)
    assert(wh2.polyCount == 1 and wh2.draws == 1,
        "A8-7 分類房間在距離內時整棟框應顯示（poly=" .. wh2.polyCount
        .. " draws=" .. wh2.draws .. "）")
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
-- x2=x+w 算錯或漏 iconOnce，其餘測試全綠但 1692 筆 POI 全滅）
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
local POI_HALO_ALPHA = 0.5
local POI_LOD_MAX_EDGE = 100
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
assert(pz.fillAlpha == 0.28, "poi-convert：blocks 開時 fillAlpha 應取常數")
-- 區塊模式無框線：不得帶 border/borderAlpha（帶了主檔就會畫 4 條線/矩形）
assert(pz.border == nil and pz.borderAlpha == nil,
    "poi-convert：POI zone 不得帶 border/borderAlpha（區塊模式已改為純色塊）")
assert(pz.haloAlpha == 0.5, "poi-convert：blocks 開時應帶 haloAlpha 底襯（得 " .. tostring(pz.haloAlpha) .. "）")
assert(zs.hasFill == true and zs.hasLine == true and zs.hasIcon == true,
    "poi-convert：icons+blocks 全開時三聚合旗標應皆 true（ZR-1）")
assert(pz.icon.r == 0.2 and pz.category == "police", "poi-convert：單色染色/類別欄位錯")

-- 預設組合（icons 開、blocks 關）：fill/lines 旗標必須 false——主檔兩個 pass
-- 據此整段跳過（ZR-1 的核心收益場景）
conv.setOpt("PoiBlocks", false)
conv.build()
local iconOnly = conv.zones()
assert(iconOnly.hasFill == false and iconOnly.hasLine == false and iconOnly.hasIcon == true,
    "poi-convert：icons-only 時旗標應 fill/line=false、icon=true（ZR-1）")
conv.setOpt("PoiBlocks", true)
conv.build()

conv.setOpt("Cat_police", false)
conv.build()
assert(#conv.zones() == 0, "poi-convert：Cat_ off 應整批略過")
conv.setOpt("Cat_police", nil)
conv.setOpt("PoiIcons", false)
conv.setOpt("PoiBlocks", false)
conv.build()
assert(#conv.zones() == 0, "poi-convert：icons+blocks 全關應為空")

-- 整棟外框模式（PoiWholeBuilding）：rects 換成單一 b、lodRect 跟著變整棟，
-- 圖標另走 iconRect 釘住原最大房間（整棟框中心對商場類建物離實際店面數十格）
conv.setOpt("PoiIcons", true)
conv.setOpt("PoiBlocks", true)
MinidoracatMiniMapPOICategories = { CATEGORIES = {
    police = { nameKey = "K_Police", color = { r = 0.2, g = 0.4, b = 0.8 } },
} }
MinidoracatMiniMapPOIData = {
    { cat = "police", rn = 2, r = {
        { x = 10, y = 20, w = 5, h = 4 },
        { x = 30, y = 20, w = 2, h = 2 },
    }, b = { x = 0, y = 0, w = 100, h = 80 } },
    -- 無 b（測試 fixture／未來資料缺欄）→ 整棟模式須退回逐房間，不得整筆消失
    { cat = "police", rn = 1, r = { { x = 200, y = 200, w = 4, h = 4 } } },
    -- b 尺寸非正 → 同樣退回逐房間（與 r 的矩形驗證同口徑）
    { cat = "police", rn = 1, r = { { x = 300, y = 300, w = 4, h = 4 } },
        b = { x = 0, y = 0, w = 0, h = 80 } },
}
conv.setOpt("PoiWholeBuilding", true)
conv.build()
local wz = conv.zones()
assert(#wz == 3, "poi-convert 整棟：應仍 3 個 zone（得 " .. #wz .. "）")
assert(#wz[1].rects == 1, "poi-convert 整棟：rects 應收斂成 1 個整棟框（得 " .. #wz[1].rects .. "）")
assert(wz[1].rects[1].x1 == 0 and wz[1].rects[1].y1 == 0
    and wz[1].rects[1].x2 == 100 and wz[1].rects[1].y2 == 80,
    "poi-convert 整棟：整棟框座標錯（x2 必須是 x+w）")
assert(wz[1].lodRect.x2 == 100 and wz[1].lodRect.y2 == 80,
    "poi-convert 整棟：lodRect 未跟著整棟框")
assert(wz[1].iconRect and wz[1].iconRect.x1 == 10 and wz[1].iconRect.x2 == 15,
    "poi-convert 整棟：iconRect 未釘在原最大房間")
assert(wz[2].iconRect == nil and #wz[2].rects == 1 and wz[2].rects[1].x1 == 200,
    "poi-convert 整棟：缺 b 應退回逐房間且不帶 iconRect")
assert(wz[3].iconRect == nil and wz[3].rects[1].x1 == 300,
    "poi-convert 整棟：b 尺寸非正應退回逐房間")
-- 關閉即回逐房間，且不殘留 iconRect（簽章重建路徑）
conv.setOpt("PoiWholeBuilding", false)
conv.build()
local nz = conv.zones()
assert(#nz[1].rects == 2 and nz[1].iconRect == nil,
    "poi-convert：整棟模式關閉未回到逐房間矩形")

-- 整棟模式嚴格隔離於區塊模式（codex review blocker）：PoiBlocks 關閉時區塊根本不畫
-- （alpha=0 早退），此時換幾何＝零視覺效果卻改距離閘 → 圖標提早數十格出現。
-- 契約：blocks 關 → 幾何完全不動；blocks 開 → 換整棟框但 distRects 保住房間矩形，
-- 使距離閘量測對象恆為分類房間（該開關純外觀、不改可見距離）
conv.setOpt("PoiWholeBuilding", true)
conv.setOpt("PoiBlocks", false)
conv.build()
local io1 = conv.zones()
assert(#io1[1].rects == 2 and io1[1].iconRect == nil and io1[1].distRects == nil
    and io1[1].haloAlpha == nil,
    "poi-convert：blocks 關時整棟模式不得更動幾何（圖標距離閘會被連帶改變）")
conv.setOpt("PoiBlocks", true)
conv.build()
local io2 = conv.zones()
assert(#io2[1].rects == 1 and io2[1].distRects and #io2[1].distRects == 2,
    "poi-convert：blocks 開時 distRects 應保留原房間矩形供距離閘量測")
assert(io2[1].distRects[1].x1 == 10 and io2[1].distRects[1].x2 == 15,
    "poi-convert：distRects 應是房間矩形而非整棟框")
conv.setOpt("PoiWholeBuilding", false)
conv.build()

-- 大型地標 LOD 豁免（POI_LOD_MAX_EDGE=100，沿 Zones addon attachLodRect 同判準）：
-- 畫的幾何聯集最長邊 >100 格 → 不附 lodRect＝任何縮放照畫；<=100 照附
-- （上方 b=100x80 恰在門檻上、lodRect 有附，即 at-threshold 附掛側的既有覆蓋）
MinidoracatMiniMapPOIData = {
    -- 逐房間聯集 101 格寬（10..111）→ 豁免
    { cat = "police", rn = 2, r = {
        { x = 10, y = 20, w = 5, h = 4 },
        { x = 109, y = 20, w = 2, h = 2 },
    } },
    -- 整棟 b 177x110（March Ridge 地堡實例尺寸）→ 豁免；房間聯集本身很小
    { cat = "police", rn = 1, r = { { x = 210, y = 220, w = 5, h = 4 } },
        b = { x = 200, y = 200, w = 177, h = 110 } },
    -- 縱向 101 格（高度單邊超標）→ 同樣豁免（最長邊取 max(w,h)，勿只驗寬）
    { cat = "police", rn = 2, r = {
        { x = 500, y = 500, w = 4, h = 5 },
        { x = 500, y = 597, w = 4, h = 4 },
    } },
}
conv.build()
local lm = conv.zones()
assert(#lm == 3, "poi-convert 地標：應 3 個 zone（得 " .. #lm .. "）")
assert(lm[1].lodRect == nil,
    "poi-convert 地標：逐房間聯集 >100 格應豁免 LOD（lodRect 應為 nil）")
assert(lm[2].lodRect ~= nil,
    "poi-convert 地標：整棟模式關閉時量的是房間聯集（小）——lodRect 應照附")
assert(lm[3].lodRect == nil,
    "poi-convert 地標：縱向 101 格應同樣豁免（最長邊須取 max(w,h)）")
conv.setOpt("PoiWholeBuilding", true)
conv.build()
local lw = conv.zones()
assert(lw[2].lodRect == nil,
    "poi-convert 地標：整棟模式下 b=177x110 應豁免 LOD（lodRect 應為 nil）")
assert(lw[2].rects[1].x2 == 377, "poi-convert 地標：整棟框仍應正常換上")
-- 開→關往返：lodRect 必須重新附回（stale nil 殘留＝地標豁免「黏住」一般建物）
conv.setOpt("PoiWholeBuilding", false)
conv.build()
local lb = conv.zones()
assert(lb[2].lodRect ~= nil,
    "poi-convert 地標：整棟模式關閉後 lodRect 應重新附回（不得殘留 nil）")
-- 預設值契約（0.14.2 起預設開）：選項未設時帶 b 的條目應畫整棟框——
-- 鎖 getBoolOption("PoiWholeBuilding", true) 的 fallback，預設翻回 false 此處炸
conv.setOpt("PoiWholeBuilding", nil)
conv.build()
local ld = conv.zones()
assert(#ld[2].rects == 1 and ld[2].rects[1].x2 == 377,
    "poi-convert 預設：PoiWholeBuilding 未設時應預設整棟框（0.14.2 契約）")
print("poi landmark LOD exemption cases passed")

MinidoracatMiniMapPOIData = nil
MinidoracatMiniMapPOICategories = nil

print("poi convert: rn/r 契約 / x2=x+w / iconOnce / lodRect / 整棟外框 / 略過與 gate cases passed")
