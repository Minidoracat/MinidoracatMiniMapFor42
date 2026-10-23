-- MinidoracatMiniMap_RoadDraw.lua
-- 本檔範圍：自訂道路圖層（兩張地圖共用）——黑底＋淺色虛線、停用的淡化細虛線、收到的路標作者名；
-- 右鍵命中（Core.roadMapHit）與世界地圖圖例要的摘要（Core.roadsLegend）。
-- 呼叫點：_Nav.lua drawNavTargets 在導航路線之前呼叫 Core.drawCustomRoads（青色路線蓋在上面）；
-- 小地圖與世界地圖都經 drawNavTargets，所以一個入口管兩張地圖。
-- 資料只讀 RoadData 的 Core.roadsVisible(pn)（分割畫面每位玩家一份），依 Core.roadsRevision() 快取，
-- 每幀不配置表；離屏段用 Core.visibleWorldAABB 剔除、Core.clipSegment 裁到元件矩形。
-- 畫線一律 ISUIElement:drawLine(nil, ...)（ISUIElement.lua:1235，同 _NavRoute drawRoutePolyline）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.drawCustomRoads then return end
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

local RD = {
    -- 樣式：底邊 #141414、面 #f3ead0 虛線；停用的淡化細虛線（設計稿 3.5）。導航路線 5／3 px 蓋在上面
    UNDER = { r = 0.08, g = 0.08, b = 0.08, a = 0.85, w = 6 },
    OVER = { r = 0.953, g = 0.918, b = 0.816, a = 1, w = 2 },
    OFF_UNDER = { r = 0.08, g = 0.08, b = 0.08, a = 0.35, w = 4 },
    OFF_OVER = { r = 0.953, g = 0.918, b = 0.816, a = 0.55, w = 1 },
    DASH_ON = 7, DASH_OFF = 5, OFF_DASH_ON = 4, OFF_DASH_OFF = 4,
    -- 每幀上限：畫面內的段數與虛線呼叫數。超過段數就停畫（ponytail: 全圖幾千條路才會碰到，
    -- 要更多就做依縮放抽點）；超過虛線預算改畫實線，線還在、只是不分段
    MAX_SEGS = 4000, MAX_DASH = 3000,
    HIT_PX = 8, -- 右鍵命中半徑（畫面 px）
}
Core.RoadDraw = RD

-- 「顯示在」兩格（主檔 Core.LAYER_MAPS.customRoads）；表上沒有這列＝照畫
function RD.layerOn(surface)
    local lm = Core.LAYER_MAPS
    if not (lm and lm.customRoads and Core.layerOn) then return true end
    return Core.layerOn("customRoads", surface)
end

-- 每位玩家一份快取：roadsVisible 的結果＋每條的外接框與標籤，revision 變了才重建
local caches = {}
function RD.cacheFor(pn)
    if not Core.roadsVisible then return nil end
    local rev = Core.roadsRevision and Core.roadsRevision()
    local c = caches[pn]
    if c and rev ~= nil and c.rev == rev then return c end
    local list = Core.roadsVisible(pn) or {}
    c = { rev = rev, n = 0, anyOff = false }
    for i = 1, #list do
        local e = list[i]
        local road = e and e.road
        local pts = road and road.pts
        local np = pts and #pts / 2 or 0
        if np >= 2 then
            local minx, miny, maxx, maxy = pts[1], pts[2], pts[1], pts[2]
            for k = 2, np do
                local x, y = pts[k * 2 - 1], pts[k * 2]
                if x < minx then minx = x elseif x > maxx then maxx = x end
                if y < miny then miny = y elseif y > maxy then maxy = y end
            end
            local label
            local name = road.name or ""
            if e.enabled == false then
                label = getText("UI_MinidoracatMiniMap_RoadLabelOff", name)
            elseif e.kind == "received" and e.author then
                label = getText("UI_MinidoracatMiniMap_RoadLabelAuthor", name, e.author)
            end
            c.n = c.n + 1
            c[c.n] = { road = road, id = road.id, np = np, off = e.enabled == false, kind = e.kind,
                minx = minx, miny = miny, maxx = maxx, maxy = maxy, label = label,
                labelW = label and getTextManager():MeasureStringX(UIFont.Small, label) or 0 }
            if e.enabled == false then c.anyOff = true end
        end
    end
    caches[pn] = c
    return c
end

-- 世界地圖圖例（_Legend.lua）：這位玩家的世界地圖上有沒有自訂道路、有沒有停用的
Core.roadsLegend = function(pn)
    if not RD.layerOn("world") then return nil end
    local c = RD.cacheFor(pn)
    if not c or c.n == 0 then return nil end
    return c
end

-- 一段畫面座標的虛線；phase＝上一段留下的週期位置（轉角處虛線接得上），回傳新的 phase
local dashBudget = 0
local function dashLine(inner, x1, y1, x2, y2, st, on, off, phase)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.5 then return phase end
    if dashBudget <= 0 then
        inner:drawLine(nil, x1, y1, x2, y2, st.w, st.a, st.r, st.g, st.b)
        return phase
    end
    local ux, uy = dx / len, dy / len
    local period = on + off
    local t = 0
    while t < len do
        local p = (phase + t) % period
        if p < on then
            local e = t + on - p
            if e > len then e = len end
            inner:drawLine(nil, x1 + ux * t, y1 + uy * t, x1 + ux * e, y1 + uy * e, st.w, st.a, st.r, st.g, st.b)
            dashBudget = dashBudget - 1
            t = e
        else
            t = t + period - p
        end
    end
    return (phase + len) % period
end

-- 一條折線（世界座標 pts，np 點）：先整條底邊再整條虛線面。view＝{minx,maxx,miny,maxy}（nil＝不剔除）。
-- 回傳這條用掉的畫面內段數。投影結果存模組層陣列，兩趟共用、不配置
local projX, projY = {}, {}
function RD.drawPolyline(inner, pts, np, under, over, on, off, view, segBudget)
    local mapAPI = inner.mapAPI
    local clip = Core.clipSegment
    local w, h = inner.width, inner.height
    local used = 0
    for k = 1, np do projX[k] = nil end
    for k = 2, np do
        local ax, ay, bx, by = pts[k * 2 - 3], pts[k * 2 - 2], pts[k * 2 - 1], pts[k * 2]
        local live = true
        if view then
            local sminx, smaxx = ax, bx
            if sminx > smaxx then sminx, smaxx = smaxx, sminx end
            local sminy, smaxy = ay, by
            if sminy > smaxy then sminy, smaxy = smaxy, sminy end
            live = not (smaxx < view[1] or sminx > view[2] or smaxy < view[3] or sminy > view[4])
        end
        if live and used < segBudget then
            if not projX[k - 1] then
                projX[k - 1], projY[k - 1] = mapAPI:worldToUIX(ax, ay), mapAPI:worldToUIY(ax, ay)
            end
            projX[k], projY[k] = mapAPI:worldToUIX(bx, by), mapAPI:worldToUIY(bx, by)
            used = used + 1
        end
    end
    for pass = 1, 2 do
        local phase = 0
        for k = 2, np do
            local ux1, ux2 = projX[k - 1], projX[k]
            if ux1 and ux2 then
                local x1, y1, x2, y2 = ux1, projY[k - 1], ux2, projY[k]
                if clip then x1, y1, x2, y2 = clip(x1, y1, x2, y2, w, h) end
                if x1 then
                    if pass == 1 then
                        inner:drawLine(nil, x1, y1, x2, y2, under.w, under.a, under.r, under.g, under.b)
                    else
                        phase = dashLine(inner, x1, y1, x2, y2, over, on, off, phase)
                    end
                end
            end
        end
    end
    return used
end

-- 標籤：折線中間那一點，底下墊半透明黑底（地形淺色時也看得清）
local function drawLabel(inner, e, tz)
    local pts = e.road.pts
    local k = math.floor((e.np + 1) / 2)
    local mapAPI = inner.mapAPI
    local x, y = pts[k * 2 - 1], pts[k * 2]
    local ux, uy = mapAPI:worldToUIX(x, y), mapAPI:worldToUIY(x, y)
    local tw = e.labelW * tz
    local th = getTextManager():getFontHeight(UIFont.Small) * tz
    ux, uy = ux + 6, uy - th - 4
    if ux > inner.width or uy > inner.height or ux + tw < 0 or uy + th < 0 then return end
    inner:drawRect(ux - 3, uy - 1, tw + 6, th + 2, 0.75, 0.07, 0.07, 0.07)
    Core.drawMapText(inner, e.label, ux, uy, 0.953, 0.918, 0.816, e.off and 0.75 or 1, UIFont.Small, tz)
end

-- 主入口（_Nav.lua drawNavTargets）：inner＝小地圖 inner 或 ISWorldMap。分割畫面只畫該 pn 的路。
-- 道路工具作用中的這張世界地圖：圖層開關關著也畫（要看得到才吸附得準），正在編輯的那條交給工具畫
local view = {}
Core.drawCustomRoads = function(inner)
    local pn = inner.playerNum or 0
    local surface = inner == ISWorldMap_instance and "world" or "mini"
    local tool = surface == "world" and Core.roadToolOf and Core.roadToolOf(inner) or nil
    if not tool and not RD.layerOn(surface) then return end
    local c = RD.cacheFor(pn)
    if not c or c.n == 0 then return end
    local cull
    if Core.visibleWorldAABB then
        local m = 16
        local x1, x2, y1, y2 = Core.visibleWorldAABB(inner)
        view[1], view[2], view[3], view[4] = x1 - m, x2 + m, y1 - m, y2 + m
        cull = view
    end
    local skip = tool and tool.roadId
    dashBudget = RD.MAX_DASH
    local segs = RD.MAX_SEGS
    -- 停用的先畫，啟用的蓋在上面
    for pass = 1, 2 do
        local wantOff = pass == 1
        for i = 1, c.n do
            local e = c[i]
            if e.off == wantOff and segs > 0 and not (skip and e.kind == "own" and e.id == skip)
                and not (cull and (e.maxx < cull[1] or e.minx > cull[2] or e.maxy < cull[3] or e.miny > cull[4])) then
                if wantOff then
                    segs = segs - RD.drawPolyline(inner, e.road.pts, e.np, RD.OFF_UNDER, RD.OFF_OVER,
                        RD.OFF_DASH_ON, RD.OFF_DASH_OFF, cull, segs)
                else
                    segs = segs - RD.drawPolyline(inner, e.road.pts, e.np, RD.UNDER, RD.OVER,
                        RD.DASH_ON, RD.DASH_OFF, cull, segs)
                end
            end
        end
    end
    local tz = Core.mapTextZoom and Core.mapTextZoom() or 1
    for i = 1, c.n do
        local e = c[i]
        if e.label and not (skip and e.kind == "own" and e.id == skip)
            and not (cull and (e.maxx < cull[1] or e.minx > cull[2] or e.maxy < cull[3] or e.miny > cull[4])) then
            drawLabel(inner, e, tz)
        end
    end
end

-- 地圖右鍵命中（_Nav.lua mapMenuFill）：這張地圖不畫自訂道路就不判定（同收藏 placeAt）。
-- 命中半徑是畫面 HIT_PX 換成世界格；資料端 Core.roadsAt 決定是哪一條
Core.roadMapHit = function(target, wx, wy)
    if not Core.roadsAt then return nil end
    local surface = target == ISWorldMap_instance and "world" or "mini"
    if not RD.layerOn(surface) then return nil end
    local mapAPI = target.mapAPI
    local ax, ay = mapAPI:worldToUIX(wx, wy), mapAPI:worldToUIY(wx, wy)
    local bx, by = mapAPI:worldToUIX(wx + 8, wy), mapAPI:worldToUIY(wx + 8, wy)
    local ppu = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) / 8
    if ppu <= 0 then return nil end
    local ok, hit = pcall(Core.roadsAt, target.playerNum or 0, wx, wy, RD.HIT_PX / ppu)
    if not ok then
        log("road hit test failed: " .. tostring(hit))
        return nil
    end
    return hit
end

Events.OnGameStart.Add(function()
    for k in pairs(caches) do caches[k] = nil end
end)
