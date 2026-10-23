-- 自訂道路圖層（MinidoracatMiniMap_RoadDraw.lua）離線回歸。
-- 整檔載入真模組；投影輔助（visibleWorldAABB／deriveAffine）與地圖文字取主檔標記區段的真實作，
-- 地圖 API 以正交／等軸測仿射假件取代，javaObject 假件記錄每次 DrawPolygon／DrawLine。
-- 驗：三款畫法的路帶寬度（路寬×每格 px、拉遠夾最細寬度、等軸測與「世界推出再投影」相同）、
-- miter 上限、6000 段在整片入鏡／中距／近距三種縮放下繪製呼叫數在預算內且每條入鏡的路都有畫、
-- 三個開關、透明度、分享的路描邊變藍、stencil 成對（含繪製中途出錯）、道路工具編輯中那條不畫、
-- 設定預覽照開關畫對的樣本、圖例列。
-- 用法：lua scripts/test_road_draw.lua [模組路徑]
local MAIN = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local MODULE = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_RoadDraw.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end
local function slice(source, name)
    local tag = name:gsub("%-", "%%-")
    return assert(source:match("%-%- test:" .. tag .. ":start\n(.-)\n%-%- test:" .. tag .. ":end"),
        "找不到區段 " .. name)
end

local main = readSource(MAIN)
local helpers = assert(load(slice(main, "visible-aabb") .. "\n" .. slice(main, "derive-affine")
    .. "\nreturn { visibleWorldAABB = visibleWorldAABB, deriveAffine = deriveAffine }", "=helpers"))()

local opts = {}
local function opt(id, default)
    if opts[id] == nil then return default end
    return opts[id]
end
local roads, rev, tool = {}, 1, nil
local Core = {
    ready = true,
    getBoolOption = opt,
    getComboIndex = opt,
    getSliderValue = function(id, default, min, max)
        local v = opt(id, default)
        if v < min then return min end
        if v > max then return max end
        return v
    end,
    visibleWorldAABB = helpers.visibleWorldAABB,
    deriveAffine = helpers.deriveAffine,
    roadsVisible = function() return roads end,
    roadsRevision = function() return rev end,
    roadToolOf = function() return tool end,
}
assert(load(slice(main, "map-text"), "=map-text", "t", setmetatable({ Core = Core,
    getSliderValue = Core.getSliderValue }, { __index = _G })))()
local WORLD = {}
local env = setmetatable({
    MinidoracatMiniMapCore = Core,
    ISWorldMap_instance = WORLD,
    UIFont = { Small = "Small" },
    Events = { OnGameStart = { Add = function() end } },
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return 7 * #s end, getFontHeight = function() return 14 end }
    end,
    getText = function(key, ...)
        local parts = {}
        for i, v in ipairs({ ... }) do parts[i] = tostring(v) end
        return key .. ":" .. table.concat(parts, ",", 1, #parts)
    end,
}, { __index = _G })
assert(load(readSource(MODULE), "=RoadDraw", "t", env))()
local RD = assert(Core.RoadDraw, "模組未匯出 Core.RoadDraw")
local draw = assert(Core.drawCustomRoads, "模組未匯出 Core.drawCustomRoads")

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print("FAIL " .. msg)
    end
end
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end

-- 仿射地圖假件（同 test_chunk_grid）：center＝畫面中心對應的世界座標
local COS45 = math.cos(math.pi / 4)
local function newMapAPI(scale, iso, cx, cy, w, h)
    local api = {}
    local function fwd(wx, wy)
        local dx, dy = wx - cx, wy - cy
        if iso then
            return w / 2 + (dx - dy) * COS45 * scale, h / 2 + (dx + dy) * COS45 * 0.5 * scale
        end
        return w / 2 + dx * scale, h / 2 + dy * scale
    end
    local function inv(ux, uy)
        local rx, ry = (ux - w / 2) / scale, (uy - h / 2) / scale
        if iso then
            local a, b = rx / COS45, ry / 0.5 / COS45
            return cx + (a + b) / 2, cy + (b - a) / 2
        end
        return cx + rx, cy + ry
    end
    function api:getWorldScale() return scale end
    function api:worldToUIX(x, y) return (fwd(x, y)) end
    function api:worldToUIY(x, y) local _, v = fwd(x, y); return v end
    function api:uiToWorldX(x, y) return (inv(x, y)) end
    function api:uiToWorldY(x, y) local _, v = inv(x, y); return v end
    api.fwd, api.inv = fwd, inv
    return api
end

-- 元件：javaObject 記 DrawPolygon／DrawLine；元件方法記 stencil、標籤底框與字
local function newInner(api, w, h, world)
    local rec = { polys = {}, lines = {}, texts = {}, rects = {}, set = 0, clear = 0, depth = 0, maxDepth = 0 }
    local jo = {}
    function jo:DrawPolygon(_, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a)
        rec.polys[#rec.polys + 1] = { x1, y1, x2, y2, x3, y3, x4, y4, r = r, g = g, b = b, a = a }
    end
    function jo:DrawLine(_, x1, y1, x2, y2, thick, r, g, b, a)
        rec.lines[#rec.lines + 1] = { x1, y1, x2, y2, w = thick, r = r, g = g, b = b, a = a }
    end
    local inner = world or {}
    inner.mapAPI, inner.width, inner.height, inner.playerNum, inner.javaObject = api, w, h, 0, jo
    function inner:setStencilRect(x, y, sw, sh)
        rec.set = rec.set + 1
        rec.depth = rec.depth + 1
        if rec.depth > rec.maxDepth then rec.maxDepth = rec.depth end
        rec.stencil = { x, y, sw, sh }
    end
    function inner:clearStencilRect() rec.clear = rec.clear + 1; rec.depth = rec.depth - 1 end
    function inner:drawRect(x, y, rw, rh) rec.rects[#rec.rects + 1] = { x, y, rw, rh } end
    function inner:drawText(t, x, y) rec.texts[#rec.texts + 1] = { t = t, x = x, y = y } end
    function inner:drawTextZoomed(t, x, y) rec.texts[#rec.texts + 1] = { t = t, x = x, y = y } end
    -- 預覽走元件方法（jo＝nil）：參數序照 ISUIElement.lua:1235、1254
    function inner:drawPolygon(_, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a)
        rec.polys[#rec.polys + 1] = { x1, y1, x2, y2, x3, y3, x4, y4, r = r, g = g, b = b, a = a, wrap = true }
    end
    function inner:drawLine(_, x1, y1, x2, y2, thick, a, r, g, b)
        rec.lines[#rec.lines + 1] = { x1, y1, x2, y2, w = thick, r = r, g = g, b = b, a = a, wrap = true }
    end
    return inner, rec
end

local function sameColor(o, c) return near(o.r, c.r) and near(o.g, c.g) and near(o.b, c.b) end
local function calls(rec) return #rec.polys + #rec.lines end
local function setRoads(list) roads = list; rev = rev + 1 end
local function road(id, pts, width, surf, kind, enabled, name, author)
    local w, s = {}, {}
    for i = 1, #pts / 2 - 1 do w[i], s[i] = width, surf end
    return { road = { id = id, name = name or ("R" .. id), pts = pts, segWidth = w, segSurface = s },
        kind = kind or "own", enabled = enabled ~= false, author = author }
end
local function run(scale, iso, cx, cy, w, h, world)
    local api = newMapAPI(scale, iso, cx, cy, w, h)
    local inner, rec = newInner(api, w, h, world)
    draw(inner)
    return rec, api
end
-- 點到直線（a→b）的距離
local function distLine(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return math.abs((px - ax) * dy - (py - ay) * dx) / math.sqrt(dx * dx + dy * dy)
end
local function filter(list, fn)
    local out = {}
    for i = 1, #list do if fn(list[i]) then out[#out + 1] = list[i] end end
    return out
end

--------------------------------------------------------------------------------
-- G. 幾何：路帶寬度、最細寬度、miter
--------------------------------------------------------------------------------
local SURF = RD.SURF
do
    opts = {}
    setRoads({ road(1, { 100, 100, 120, 100 }, 6, "paved") })
    -- A：俯視每格 4 px，路寬 6 → 填色帶 24 px，描邊多推 1.6 px
    local rec = run(4, false, 110, 100, 400, 300)
    local fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    local case = filter(rec.polys, function(p) return sameColor(p, SURF.paved.case) end)
    check(#fill == 1 and near(math.abs(fill[1][2] - fill[1][8]), 24), "G1 A 填色帶寬＝路寬 6×每格 4 px＝24")
    check(#case == 1 and near(math.abs(case[1][2] - case[1][8]), 24 + 2 * RD.A_CASE), "G1 A 描邊每側多推 A_CASE px")
    check(#fill == 1 and near(math.abs(fill[1][3] - fill[1][1]), 80), "G1 路帶長＝20 格×4 px")
    -- 拉遠：每格 0.2 px → 1.2 px，夾到最細寬度（預設 3、改 5）
    rec = run(0.2, false, 110, 100, 400, 300)
    fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    check(#fill == 1 and near(math.abs(fill[1][2] - fill[1][8]), 3), "G2 拉遠時路帶夾到 CustomRoadMinWidth 預設 3 px")
    opts.CustomRoadMinWidth = 5
    rec = run(0.2, false, 110, 100, 400, 300)
    fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    check(#fill == 1 and near(math.abs(fill[1][2] - fill[1][8]), 5), "G2 最細寬度 5 px 生效")
    opts.CustomRoadMinWidth = 9
    rec = run(0.2, false, 110, 100, 400, 300)
    fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    check(#fill == 1 and near(math.abs(fill[1][2] - fill[1][8]), 6), "G2 最細寬度超界夾到 6")
    opts.CustomRoadMinWidth = nil
    -- B：路廊同寬；C：固定 4／7 px，不隨縮放
    opts.CustomRoadStyle = 2
    rec = run(4, false, 110, 100, 400, 300)
    fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    check(#fill == 1 and near(math.abs(fill[1][2] - fill[1][8]), 24), "G3 B 路廊寬＝路寬×每格 px")
    opts.CustomRoadStyle = 3
    for _, s in ipairs({ 0.2, 4 }) do
        rec = run(s, false, 110, 100, 400, 300)
        local inner = filter(rec.polys, function(p) return sameColor(p, SURF.paved.line) end)
        case = filter(rec.polys, function(p) return sameColor(p, SURF.paved.case) end)
        check(#inner == 1 and near(math.abs(inner[1][2] - inner[1][8]), RD.C_LINE)
            and #case == 1 and near(math.abs(case[1][2] - case[1][8]), RD.C_CASE),
            "G3 C 內線 4 px、描邊 7 px 不隨縮放（每格 " .. s .. " px）")
    end
    opts.CustomRoadStyle = nil
    -- 等軸測：路帶兩側＝世界座標推出 ±3 格再投影的兩條線
    local api
    rec, api = run(4, true, 110, 100, 400, 300)
    fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    local ax, ay = api.fwd(100, 97)
    local bx, by = api.fwd(120, 97)
    local cx2, cy2 = api.fwd(100, 103)
    local want = distLine(cx2, cy2, ax, ay, bx, by)
    local got = #fill == 1 and distLine(fill[1][7], fill[1][8], fill[1][1], fill[1][2], fill[1][3], fill[1][4]) or -1
    check(near(got, want, 1e-6), "G4 等軸測路帶寬＝世界推出再投影（得 " .. got .. "，應 " .. want .. "）")
    -- 直角轉彎：miter 交點離中心 d√2；近乎迴轉：不超過 MITER×半寬
    setRoads({ road(1, { 100, 100, 120, 100, 120, 120 }, 6, "paved") })
    rec, api = run(4, false, 110, 110, 400, 300)
    fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    local px, py = api.fwd(120, 100)
    local o = #fill == 2 and math.sqrt((fill[1][3] - px) ^ 2 + (fill[1][4] - py) ^ 2) or -1
    check(near(o, 12 * math.sqrt(2), 1e-6), "G5 直角轉彎 miter＝半寬×√2（得 " .. o .. "）")
    check(#fill == 2 and near(fill[1][3], fill[2][1]) and near(fill[1][4], fill[2][2]), "G5 相鄰兩段共用轉角點、沒有缺口")
    setRoads({ road(1, { 100, 100, 140, 100, 100, 102 }, 6, "paved") })
    rec, api = run(4, false, 120, 100, 400, 300)
    local worst = 0
    px, py = api.fwd(140, 100)
    for _, p in ipairs(filter(rec.polys, function(q) return not sameColor(q, RD.CENTER) end)) do
        for k = 1, 4 do
            local d = math.sqrt((p[k * 2 - 1] - px) ^ 2 + (p[k * 2] - py) ^ 2)
            if d < 60 and d > worst then worst = d end
        end
    end
    check(worst > 0 and worst <= RD.MITER * (12 + RD.A_CASE) + 1e-6,
        "G6 近乎迴轉的轉角外推不超過 MITER×半寬（得 " .. worst .. "）")
end

--------------------------------------------------------------------------------
-- S. 樣式、開關、透明度
--------------------------------------------------------------------------------
do
    opts = {}
    -- 路長 100 格：每格 4 px＝400 px，放得下假 getText 的長標籤
    local P = { 100, 100, 200, 100 }
    setRoads({ road(1, P, 6, "paved"), road(2, { 100, 110, 200, 110 }, 6, "gravel", "received", true, "Farm", "bob"),
        road(3, { 100, 120, 200, 120 }, 6, "dirt", "own", false, "Back") })
    local rec = run(4, false, 150, 110, 600, 300)
    local blue = filter(rec.polys, function(p) return sameColor(p, RD.BLUE) end)
    check(#blue == 1 and near(math.abs(blue[1][2] - blue[1][8]), 24 + 2 * RD.A_CASE_RECV), "S1 A 分享的路描邊變藍、加寬")
    local recvFill = filter(rec.polys, function(p) return sameColor(p, SURF.gravel.fill) end)
    check(#recvFill == 1 and near(recvFill[1].a, 0.85), "S2 預設透明度 85%")
    local offFill = filter(rec.polys, function(p) return sameColor(p, SURF.dirt.fill) end)
    check(#offFill == 1 and near(offFill[1].a, 0.85 * RD.A_OFF_FILL), "S2 停用的路填色 ×0.30")
    check(#filter(rec.polys, function(p) return sameColor(p, SURF.dirt.case) end) == 0, "S2 A 停用的路沒有描邊")
    local offEdge = filter(rec.polys, function(p) return sameColor(p, RD.OFF_EDGE) end)
    check(#offEdge > 4, "S2 A 停用的路兩側淺灰虛線（得 " .. #offEdge .. " 段）")
    local center = filter(rec.polys, function(p) return sameColor(p, RD.CENTER) end)
    check(#center == 34 and near(math.abs(center[1][2] - center[1][8]), RD.CENTER_W),
        "S3 柏油每格 ≥3 px 畫中線虛線：400 px／12＝34 段、寬＝CENTER_W（得 " .. #center .. "）")
    -- 停用的先畫：第一個 polygon 是停用的泥土路
    check(sameColor(rec.polys[1], SURF.dirt.fill), "S4 停用的路先畫、啟用的蓋上去")
    -- 標籤：自己的路寫名稱、分享的寫作者、停用的寫「不用於導航」
    local texts = {}
    for _, t in ipairs(rec.texts) do texts[t.t] = true end
    check(texts.R1 and texts["UI_MinidoracatMiniMap_RoadLabelAuthor:Farm,bob"]
        and texts["UI_MinidoracatMiniMap_RoadLabelOff:Back"], "S5 三種標籤都寫")
    -- 標籤寫在路中段的上方：R1 畫面上 100→500、y 110、半寬 12；底框置中在 x 300、整個在路面上緣之上
    local lab
    for i, t in ipairs(rec.texts) do if t.t == "R1" then lab = rec.rects[i] end end
    check(lab and near(lab[1] + lab[3] / 2, 300) and lab[2] + lab[4] <= 110 - 12,
        "S5 標籤在路中段上方置中、不蓋路面")
    -- 拉遠：路比標籤短就不寫（每格 2 px：100 格＝200 px，標籤 R1＝14 px 寫；長標籤 329 px 不寫）
    rec = run(2, false, 150, 110, 600, 300)
    texts = {}
    for _, t in ipairs(rec.texts) do texts[t.t] = true end
    check(texts.R1 and not texts["UI_MinidoracatMiniMap_RoadLabelAuthor:Farm,bob"], "S6 路在畫面上比標籤短就不寫名稱")
    rec = run(1.5, false, 150, 110, 600, 300)
    check(#filter(rec.polys, function(p) return sameColor(p, RD.CENTER) end) == 0, "S3 每格 <3 px 不畫中線")
    -- 開關
    opts.CustomRoadNames = false
    rec = run(4, false, 150, 110, 600, 300)
    check(#rec.texts == 0 and #rec.rects == 0, "S7 名稱關掉：所有標籤都不寫")
    opts.CustomRoadNames, opts.CustomRoadReceived = nil, false
    rec = run(4, false, 150, 110, 600, 300)
    check(#filter(rec.polys, function(p) return sameColor(p, RD.BLUE) or sameColor(p, SURF.gravel.fill) end) == 0,
        "S8 分享的路關掉：不畫")
    opts.CustomRoadReceived, opts.CustomRoadDisabled = nil, false
    rec = run(4, false, 150, 110, 600, 300)
    check(#filter(rec.polys, function(p) return sameColor(p, SURF.dirt.fill) end) == 0
        and #filter(rec.polys, function(p) return sameColor(p, RD.OFF_EDGE) end) == 0, "S9 不用於導航的路關掉：不畫")
    opts.CustomRoadDisabled, opts.CustomRoadAlpha = nil, 50
    rec = run(4, false, 150, 110, 600, 300)
    local fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    check(#fill == 1 and near(fill[1].a, 0.5), "S10 透明度 50% 乘到填色")
    -- B：路廊淡填色＋米色邊線；分享的邊線淺藍；停用的邊線虛線 ×0.6
    opts.CustomRoadAlpha, opts.CustomRoadStyle = nil, 2
    rec = run(4, false, 150, 110, 600, 300)
    fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    check(#fill == 1 and near(fill[1].a, 0.85 * RD.B_FILL), "S11 B 填色 ×0.28")
    check(#filter(rec.polys, function(p) return sameColor(p, RD.B_EDGE) and near(p.a, 0.85) end) == 2,
        "S11 B 自己的路兩條米色邊線")
    check(#filter(rec.polys, function(p) return sameColor(p, RD.B_EDGE_RECV) end) == 2, "S11 B 分享的路邊線淺藍")
    check(#filter(rec.polys, function(p) return sameColor(p, RD.B_EDGE) and near(p.a, 0.85 * RD.B_OFF_EDGE) end) > 4,
        "S11 B 停用的路邊線改虛線 ×0.6")
    -- 預算只夠每段一個 polygon（3 條各一段）：B 拿掉邊線，填色改用 A 的濃度
    local budget = RD.BUDGET
    RD.BUDGET = 3
    rec = run(4, false, 150, 110, 600, 300)
    RD.BUDGET = budget
    fill = filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end)
    local offB = filter(rec.polys, function(p) return sameColor(p, SURF.dirt.fill) end)
    check(#filter(rec.polys, function(p) return sameColor(p, RD.B_EDGE) end) == 0 and #fill == 1
        and near(fill[1].a, 0.85) and #offB == 1 and near(offB[1].a, 0.85 * RD.A_OFF_FILL),
        "S11 B 預算拿掉邊線時填色改用 A 的濃度")
    -- C：分享的描邊藍；泥土內線虛線；停用整體 ×0.4
    opts.CustomRoadStyle = 3
    rec = run(4, false, 150, 110, 600, 300)
    check(#filter(rec.polys, function(p) return sameColor(p, RD.BLUE) end) == 1, "S12 C 分享的路描邊藍")
    local dirt = filter(rec.polys, function(p) return sameColor(p, SURF.dirt.line) end)
    local dcase = filter(rec.polys, function(p) return sameColor(p, SURF.dirt.case) end)
    check(#dirt >= 6 and near(math.abs(dirt[1][2] - dirt[1][8]), RD.C_LINE) and near(dirt[1].a, 0.85 * RD.C_OFF),
        "S12 C 泥土內線 8 on／4 off 虛線、寬＝C_LINE、停用 ×0.4")
    check(#dcase == 1 and math.abs(dcase[1][2] - dcase[1][8]) > RD.C_LINE, "S12 C 泥土虛線窄於描邊")
    opts = {}
end
-- 標籤避讓：兩條平行的路相距 2 格（每格 4 px＝8 px，字高 14），底框會重疊，只寫一個；
-- 停用的路排在前面也讓給啟用的路
do
    opts = {}
    setRoads({ road(1, { 100, 100, 200, 100 }, 4, "dirt", "own", false, "Back"),
        road(2, { 100, 102, 200, 102 }, 4, "paved", "own", true, "Main") })
    local rec = run(4, false, 150, 101, 600, 300)
    local texts = {}
    for _, t in ipairs(rec.texts) do texts[#texts + 1] = t.t end
    check(#texts == 1 and texts[1] == "Main", "S13 標籤底框重疊只寫一個、啟用的路優先（得 "
        .. table.concat(texts, ",") .. "）")
    setRoads({ road(1, { 100, 100, 200, 100 }, 4, "dirt", "own", false, "Back"),
        road(2, { 100, 120, 200, 120 }, 4, "paved", "own", true, "Main") })
    rec = run(4, false, 150, 110, 600, 300)
    check(#rec.texts == 2, "S13 相距夠遠的兩條都寫")
end
-- 快取：版本變了只重算形狀有變的路（資料層改路一律整條換新表）。整批重算時，改一條路要把
-- 29 條×300 點的多層簡化全部重做，Kahlua 每次卡 1.5–2.7 秒（E2E share-road-persist-mp 1024a）
do
    local list = {}
    for i = 1, 5 do list[i] = road(i, { 0, i * 10, 50, i * 10 + 2, 100, i * 10 }, 4, "dirt", "own", true) end
    setRoads(list)
    local orig, n = RD.buildLevels, 0
    RD.buildLevels = function(...) n = n + 1; return orig(...) end
    RD.cacheFor(0)
    check(n == 5, "C1 第一次建快取每條路各算一次多層簡化（得 " .. n .. "）")
    n = 0
    local next = {}
    for i = 1, 5 do next[i] = list[i] end
    next[3] = road(3, { 0, 30, 60, 36, 100, 30 }, 4, "dirt", "own", true)
    next[4] = { road = list[4].road, kind = "own", enabled = false } -- 同一條路改成停用：形狀沒變
    setRoads(next)
    local c = RD.cacheFor(0)
    check(n == 1, "C1 改一條路的形狀只重算那一條（得 " .. n .. "）")
    check(c[4].off == true and c[4].levels and #c[4].levels >= 1 and c.ownOff == 1,
        "C1 形狀沒變、狀態改了：沿用簡化結果，停用照新狀態")
    -- 收到分享快照時整批換成新表、內容相同（同 sid）：沿用，不重算；內容變了的那條才重算
    -- （整批重算 30 條×300 點，登入與換陣營時 Kahlua 卡 1.4–1.5 秒，E2E share-road-persist-mp 1024c）
    local function copy(e, dy)
        local r = e.road
        local pts = {}
        for k = 1, #r.pts do pts[k] = r.pts[k] + ((dy and k % 2 == 0) and dy or 0) end
        local w, s = {}, {}
        for k = 1, #r.segWidth do w[k], s[k] = r.segWidth[k], r.segSurface[k] end
        return { road = { id = r.id, name = r.name, pts = pts, segWidth = w, segSurface = s },
            kind = e.kind, enabled = e.enabled }
    end
    local snap = {}
    for i = 1, 5 do snap[i] = copy(next[i]) end
    n = 0
    setRoads(snap)
    RD.cacheFor(0)
    check(n == 0, "C2 換成內容相同的新表：沿用多層簡化（重算 " .. n .. " 次）")
    local snap2 = {}
    for i = 1, 5 do snap2[i] = snap[i] end
    snap2[2] = copy(snap[2], 4)
    setRoads(snap2)
    RD.cacheFor(0)
    check(n == 1, "C2 同一條路內容改了：只重算那一條（重算 " .. n .. " 次）")
    RD.buildLevels = orig
    setRoads({})
end

--------------------------------------------------------------------------------
-- B. 預算：20 條×300 點（5980 段），三種縮放、三款畫法、俯視／等軸測
--------------------------------------------------------------------------------
local ROADS, PTS, SPACING, Y0 = 20, 300, 60, 1000
do
    local list = {}
    for r = 1, ROADS do
        local pts = {}
        for i = 1, PTS do
            local x = 1000 + (i - 1) * 5
            pts[i * 2 - 1] = x
            pts[i * 2] = Y0 + r * SPACING + 10 * math.sin(x / 100 * 2 * math.pi) + ((i * 37) % 7 - 3) * 0.3
        end
        local surf = ({ "paved", "gravel", "dirt" })[r % 3 + 1]
        list[r] = road(r, pts, 6, surf, r % 5 == 0 and "received" or "own", r % 7 ~= 3, "Road" .. r, "bob")
    end
    setRoads(list)
    -- 呼叫歸屬：polygon 重心／線段中點反投影成世界 y，換成第幾條
    local function owner(api, x, y)
        local _, wy = api.inv(x, y)
        return math.floor((wy - Y0) / SPACING + 0.5)
    end
    local function inView(api, r, w, h)
        local pts = list[r].road.pts
        for i = 1, PTS do
            local x, y = api.fwd(pts[i * 2 - 1], pts[i * 2])
            if x >= 0 and x <= w and y >= 0 and y <= h then return true end
        end
        return false
    end
    local W, H = 1600, 900
    local zooms = { { "整片入鏡", 0.4 }, { "中距", 1.5 }, { "近距", 8 } }
    local report = {}
    for _, iso in ipairs({ false, true }) do
        for style = 1, 3 do
            opts = { CustomRoadStyle = style }
            for _, z in ipairs(zooms) do
                local rec, api = run(z[2], iso, 1750, 1600, W, H)
                local n = calls(rec)
                local tag = (iso and "等軸測" or "俯視") .. " " .. ({ "A", "B", "C" })[style] .. " " .. z[1]
                check(n <= RD.BUDGET, "B1 " .. tag .. " 繪製呼叫 " .. n .. " 超過預算 " .. RD.BUDGET)
                check(rec.set == 1 and rec.clear == 1 and rec.depth == 0, "B2 " .. tag .. " stencil 成對")
                local hit = {}
                for _, p in ipairs(rec.polys) do
                    hit[owner(api, (p[1] + p[3] + p[5] + p[7]) / 4, (p[2] + p[4] + p[6] + p[8]) / 4)] = true
                end
                local missing, seen = {}, 0
                for r = 1, ROADS do
                    if inView(api, r, W, H) then
                        seen = seen + 1
                        if not hit[r] then missing[#missing + 1] = r end
                    end
                end
                check(#missing == 0, "B3 " .. tag .. " 入鏡的路沒畫到：" .. table.concat(missing, ","))
                report[#report + 1] = tag .. "=" .. n .. "（入鏡 " .. seen .. " 條）"
            end
        end
    end
    opts = {}
    -- 整片入鏡＋最細寬度 6：仍在預算內（強迫降級到更粗的層）
    opts.CustomRoadMinWidth = 6
    local rec = run(1.5, false, 1750, 1600, W, H)
    check(calls(rec) <= RD.BUDGET, "B4 中距＋最細 6 px 仍在預算內（得 " .. calls(rec) .. "）")
    opts = {}
    print("calls: " .. table.concat(report, "；"))
end

--------------------------------------------------------------------------------
-- T. stencil 例外、道路工具、預覽、圖例
--------------------------------------------------------------------------------
do
    opts = {}
    setRoads({ road(7, { 100, 100, 120, 100 }, 6, "paved"), road(8, { 100, 110, 120, 110 }, 6, "gravel") })
    -- 繪製中途出錯：clear 仍呼叫、錯誤往外丟
    local api = newMapAPI(4, false, 110, 105, 400, 300)
    local inner, rec = newInner(api, 400, 300)
    inner.javaObject.DrawPolygon = function() error("boom") end
    local ok = pcall(draw, inner)
    check(not ok and rec.set == 1 and rec.clear == 1, "T1 繪製出錯時 stencil 照樣清掉、錯誤往外丟")
    -- 道路工具作用中的世界地圖：編輯中那條（own id 7）不畫，其他照畫
    tool = { roadId = 7 }
    rec = run(4, false, 110, 105, 400, 300, WORLD)
    check(#filter(rec.polys, function(p) return sameColor(p, SURF.paved.fill) end) == 0
        and #filter(rec.polys, function(p) return sameColor(p, SURF.gravel.fill) end) == 1,
        "T2 道路工具正在編輯的那條交給工具畫")
    tool = nil
    -- 預覽：元件方法、stencil＝預覽矩形；預設五條、各開關少掉對應那條
    local function preview()
        local el, r = newInner(newMapAPI(1, false, 0, 0, 1, 1), 600, 200)
        Core.drawRoadsPreview(el, 20, 30, 540, 136)
        return r
    end
    local function labels(r)
        local t = {}
        for _, x in ipairs(r.texts) do t[#t + 1] = x.t end
        table.sort(t)
        return table.concat(t, "|")
    end
    local r = preview()
    check(r.set == 1 and r.clear == 1 and r.stencil and r.stencil[1] == 20 and r.stencil[2] == 30
        and r.stencil[3] == 540 and r.stencil[4] == 136, "T3 預覽 stencil 裁到預覽矩形且成對")
    check(#r.polys > 0 and r.polys[1].wrap, "T3 預覽走元件 drawPolygon")
    check(#r.texts == 5, "T3 預覽預設五條樣本都寫標籤（得 " .. labels(r) .. "）")
    check(#filter(r.polys, function(p) return sameColor(p, RD.BLUE) end) == 1, "T3 預覽的分享路描邊藍")
    check(#filter(r.polys, function(p) return sameColor(p, RD.CENTER) end) > 0, "T3 預覽柏油有中線")
    for _, p in ipairs(r.polys) do
        if p[1] < 20 or p[1] > 560 or p[2] < 30 or p[2] > 166 then
            check(false, "T3 預覽樣本畫出預覽矩形外")
            break
        end
    end
    opts.CustomRoadReceived = false
    r = preview()
    check(#r.texts == 4 and #filter(r.polys, function(p) return sameColor(p, RD.BLUE) end) == 0,
        "T4 預覽：分享的路關掉少那條")
    opts.CustomRoadReceived, opts.CustomRoadDisabled = nil, false
    r = preview()
    check(#r.texts == 4 and #filter(r.polys, function(p) return sameColor(p, RD.OFF_EDGE) end) == 0,
        "T4 預覽：不用於導航的路關掉少那條")
    opts.CustomRoadDisabled, opts.CustomRoadNames = nil, false
    r = preview()
    check(#r.texts == 0 and #r.polys > 0, "T4 預覽：名稱關掉只畫路不寫字")
    opts.CustomRoadNames, opts.CustomRoadStyle, opts.CustomRoadAlpha = nil, 3, 40
    r = preview()
    local cases = filter(r.polys, function(p) return sameColor(p, SURF.paved.case) end)
    check(#cases > 0 and near(math.abs(cases[1][2] - cases[1][8]), RD.C_CASE) and near(cases[1].a, 0.4),
        "T4 預覽照目前畫法（C）與透明度")
    opts = {}
    -- 圖例列
    setRoads({ road(1, { 0, 0, 10, 0 }, 6, "paved") })
    local L = Core.roadsLegend(0)
    check(L and L.n == 1 and L[1] == "road", "T5 只有自己的路：一列")
    setRoads({ road(1, { 0, 0, 10, 0 }, 6, "paved"), road(2, { 0, 0, 10, 0 }, 6, "paved", "received", true),
        road(3, { 0, 0, 10, 0 }, 6, "paved", "own", false) })
    L = Core.roadsLegend(0)
    check(L and L.n == 3 and L[2] == "received" and L[3] == "off", "T5 有分享與停用的路：三列")
    opts.CustomRoadReceived, opts.CustomRoadDisabled = false, false
    L = Core.roadsLegend(0)
    check(L and L.n == 1, "T5 開關關掉的列不列")
    opts = {}
    setRoads({ road(2, { 0, 0, 10, 0 }, 6, "paved", "received", true) })
    opts.CustomRoadReceived = false
    check(Core.roadsLegend(0) == nil, "T5 只剩關掉的那種路：圖例不列")
    opts = {}
    -- 圖例色塊：A 三種路面
    local el, lr = newInner(newMapAPI(1, false, 0, 0, 1, 1), 100, 30)
    RD.drawLegendSample(el, 10, 5, 48, 16, "road")
    check(#filter(lr.polys, function(p) return sameColor(p, SURF.paved.fill) end) == 1
        and #filter(lr.polys, function(p) return sameColor(p, SURF.gravel.fill) end) == 1
        and #filter(lr.polys, function(p) return sameColor(p, SURF.dirt.fill) end) == 1, "T6 圖例 A：三種路面色塊")
end

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("OK test_road_draw")
