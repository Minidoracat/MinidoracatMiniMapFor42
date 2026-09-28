-- chunk 格線圖層（MinidoracatMiniMap_ChunkGrid.lua）離線回歸。
-- 整檔載入真模組；投影輔助（visibleWorldAABB／deriveAffine）取主檔標記區段的真實作，
-- 地圖 API 以正交／等軸測（同 WorldMapRenderer.calcMatrices：平面旋 45° 後 y 乘 cos60°）
-- 仿射假件取代，javaObject 假件記錄每次繪製（元件絕對座標非 0，抓漏加／多加偏移）。
-- 驗：預設關與拉遠零成本、格線落在 8 的倍數且不漏、棋盤格貼圖對齊 64 格並蓋滿畫面、
-- 所在 chunk 編號與含端點範圍（含負座標）、逐格編號只在放得下時畫、任何縮放下繪製呼叫數
-- 有上限、繪製中途出錯 stencil 仍配對清除。
-- 用法：lua scripts/test_chunk_grid.lua [模組路徑]
local MAIN = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local MODULE = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_ChunkGrid.lua"

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
local player = nil
local TEX = { name = "checker" }
local Core = {
    ready = true,
    getBoolOption = function(id, default)
        if opts[id] == nil then return default end
        return opts[id]
    end,
    visibleWorldAABB = helpers.visibleWorldAABB,
    deriveAffine = helpers.deriveAffine,
}
local env = setmetatable({
    MinidoracatMiniMapCore = Core,
    UIFont = { Small = "Small" },
    getSpecificPlayer = function() return player end,
    getTexture = function(path) return path == "media/ui/minimap_chunk_checker.png" and TEX or nil end,
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return 7 * #s end, getFontHeight = function() return 14 end }
    end,
    getText = function(key, ...)
        local parts = {}
        for i, v in ipairs({ ... }) do parts[i] = tostring(v) end
        return key .. ":" .. table.concat(parts, ",", 1, #parts)
    end,
}, { __index = _G })
assert(load(readSource(MODULE), "=ChunkGrid", "t", env))()
local draw = assert(Core.drawChunkGrid, "模組未匯出 Core.drawChunkGrid")

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print("FAIL " .. msg)
    end
end

-- 仿射地圖假件：center＝畫面中心對應的世界座標；calls 數跨界呼叫
local COS45 = math.cos(math.pi / 4)
local function newMapAPI(scale, iso, cx, cy, w, h)
    local api = { calls = 0 }
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
    function api:getWorldScale() self.calls = self.calls + 1; return scale end
    function api:worldToUIX(x, y) self.calls = self.calls + 1; return (fwd(x, y)) end
    function api:worldToUIY(x, y) self.calls = self.calls + 1; local _, v = fwd(x, y); return v end
    function api:uiToWorldX(x, y) self.calls = self.calls + 1; return (inv(x, y)) end
    function api:uiToWorldY(x, y) self.calls = self.calls + 1; local _, v = inv(x, y); return v end
    api.inv = inv
    return api
end

-- 元件：javaObject 假件的座標語意照 UIElement.java——DrawLine／DrawPolygon／DrawText*／
-- DrawTextureScaledColor 收元件相對座標（Java 自加絕對座標），四角 DrawTexture 收絕對座標
local ABS_X, ABS_Y = 100, 50
local function newInner(api, w, h)
    local rec = { lines = {}, polys = {}, tex = {}, rects = {}, texts = {}, set = 0, clear = 0 }
    local jo = {}
    function jo:getAbsoluteX() return ABS_X end
    function jo:getAbsoluteY() return ABS_Y end
    function jo:DrawLine(_, x1, y1, x2, y2, thick, r, g, b, a)
        rec.lines[#rec.lines + 1] = { x1, y1, x2, y2, thick = thick, r = r, a = a }
    end
    function jo:DrawPolygon(_, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a)
        rec.polys[#rec.polys + 1] = { x1, y1, x2, y2, x3, y3, x4, y4, r = r, a = a }
    end
    function jo:DrawTexture(t, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a)
        rec.tex[#rec.tex + 1] = { x1 - ABS_X, y1 - ABS_Y, x2 - ABS_X, y2 - ABS_Y,
            x3 - ABS_X, y3 - ABS_Y, x4 - ABS_X, y4 - ABS_Y, t = t, a = a }
    end
    function jo:DrawTextureScaledColor(_, x, y, rw, rh, r, g, b, a) rec.rects[#rec.rects + 1] = { x, y, rw, rh, a = a } end
    function jo:DrawText(_, t, x, y) rec.texts[#rec.texts + 1] = { t = t, x = x, y = y } end
    function jo:DrawTextCentre(_, t, x, y) rec.texts[#rec.texts + 1] = { t = t, x = x, y = y, centre = true } end
    local inner = { mapAPI = api, width = w, height = h, playerNum = 0, javaObject = jo }
    function inner:setStencilRect() rec.set = rec.set + 1 end
    function inner:clearStencilRect() rec.clear = rec.clear + 1 end
    return inner, rec
end

local function near(a, b) return math.abs(a - b) < 1e-6 end
local function roundi(v) return math.floor(v + 0.5) end
local function calls(rec) return #rec.lines + #rec.polys + #rec.tex + #rec.rects + #rec.texts end
local function run(scale, iso, cx, cy, w, h)
    local api = newMapAPI(scale, iso, cx, cy, w, h)
    local inner, rec = newInner(api, w, h)
    draw(inner)
    return rec, api
end
local function currentLabel(rec)
    for _, t in ipairs(rec.texts) do
        if t.t:find("^UI_MinidoracatMiniMap_ChunkInfo:") then return t.t end
    end
end
-- 貼圖覆蓋：每張貼圖的四角須是世界座標 64 的倍數構成的 64×64 方塊；回傳 block 集合
local function checkerBlocks(tag, rec, api)
    local blocks = {}
    for _, q in ipairs(rec.tex) do
        check(q.t == TEX and near(q.a, 0.14), tag .. " 底色應以棋盤格貼圖、alpha 0.14 繪製")
        local x1, y1 = api.inv(q[1], q[2])
        local x2, y2 = api.inv(q[3], q[4])
        local x4, y4 = api.inv(q[7], q[8])
        check(near(x1 / 64, roundi(x1 / 64)) and near(y1 / 64, roundi(y1 / 64)),
            tag .. " 貼圖原點應落在 64 格的倍數：" .. x1 .. "," .. y1)
        check(near(x2 - x1, 64) and near(y2, y1) and near(y4 - y1, 64) and near(x4, x1),
            tag .. " 貼圖應恰好涵蓋 8×8 chunk（右上＝+64,0、左下＝0,+64）")
        local key = roundi(x1 / 64) .. "," .. roundi(y1 / 64)
        check(not blocks[key], tag .. " 同一方塊不應重複鋪貼圖：" .. key)
        blocks[key] = true
    end
    return blocks
end

--------------------------------------------------------------------------------
-- A. 預設關（選項未註冊／未存檔）：不碰地圖 API、不畫任何東西
player = { getX = function() return 10763.9 end, getY = function() return 9771.2 end }
do
    local rec, api = run(4, false, 10763.3, 9771.7, 300, 300)
    check(api.calls == 0 and calls(rec) == 0 and rec.set == 0, "A 預設關應零成本")
end
opts.ChunkGrid = true

-- B. 拉遠（chunk < 12px）：只查一次縮放就返回
for _, iso in ipairs({ false, true }) do
    local rec, api = run(1.4, iso, 10763.3, 9771.7, 1920, 1080)
    check(api.calls == 1 and calls(rec) == 0 and rec.set == 0,
        "B 拉遠應只付一次 getWorldScale（iso=" .. tostring(iso) .. "）")
end

-- C. 正交：格線落在 8 的倍數且不漏、棋盤格貼圖蓋滿畫面、所在 chunk 編號與含端點範圍
do
    local W, H, S, CX, CY = 300, 300, 4, 10763.3, 9771.7
    local rec, api = run(S, false, CX, CY, W, H)
    local xmin, xmax = CX - W / 2 / S, CX + W / 2 / S
    local ymin, ymax = CY - H / 2 / S, CY + H / 2 / S
    local seenX, seenY, thick = {}, {}, 0
    for _, l in ipairs(rec.lines) do
        if l.thick == 2 then
            thick = thick + 1
        else
            local wx1, wy1 = api.inv(l[1], l[2])
            local wx2, wy2 = api.inv(l[3], l[4])
            if near(wx1, wx2) then
                check(near(wx1 / 8, roundi(wx1 / 8)), "C 直線應落在 x=8k：" .. wx1)
                seenX[roundi(wx1)] = (seenX[roundi(wx1)] or 0) + 1
            else
                check(near(wy1, wy2) and near(wy1 / 8, roundi(wy1 / 8)), "C 橫線應落在 y=8k：" .. wy1)
                seenY[roundi(wy1)] = (seenY[roundi(wy1)] or 0) + 1
            end
        end
    end
    for x = math.ceil(xmin / 8) * 8, xmax, 8 do check(seenX[x] == 1, "C 缺或重複直線 x=" .. x) end
    for y = math.ceil(ymin / 8) * 8, ymax, 8 do check(seenY[y] == 1, "C 缺或重複橫線 y=" .. y) end
    local blocks = checkerBlocks("C", rec, api)
    for y = math.floor(ymin / 64), math.floor(ymax / 64) do
        for x = math.floor(xmin / 64), math.floor(xmax / 64) do
            check(blocks[x .. "," .. y], "C 畫面內的 8×8 chunk 方塊都應鋪上底色：" .. x .. "," .. y)
        end
    end
    local amber = {}
    for _, p in ipairs(rec.polys) do if p.r == 1 then amber[#amber + 1] = p end end
    check(#amber == 1 and thick == 4, "C 所在 chunk 應有一塊琥珀底色與四條粗框")
    if amber[1] then
        local wx, wy = api.inv(amber[1][1], amber[1][2])
        check(near(wx, 10760) and near(wy, 9768), "C 所在 chunk 左上角應為 (10760,9768)")
    end
    check(currentLabel(rec) == "UI_MinidoracatMiniMap_ChunkInfo:1345,1221,10760,10767,9768,9775",
        "C 所在 chunk 標籤應為編號＋含端點範圍：" .. tostring(currentLabel(rec)))
    check(rec.set == 1 and rec.clear == 1, "C stencil 應開一次並清除")
end

-- D. 負座標世界：所在 chunk 取 floor、貼圖方塊對齊到負的 64 倍數
do
    player = { getX = function() return -0.5 end, getY = function() return -8.1 end }
    local rec, api = run(4, false, -12.5, -3.2, 200, 200)
    check(currentLabel(rec) == "UI_MinidoracatMiniMap_ChunkInfo:-1,-2,-8,-1,-16,-9",
        "D 負座標所在 chunk 應為 (-1,-2) 範圍 -8..-1／-16..-9：" .. tostring(currentLabel(rec)))
    local blocks = checkerBlocks("D", rec, api)
    check(blocks["-1,-1"] and blocks["0,0"], "D 跨 0 的四個方塊都應鋪上底色")
    player = { getX = function() return 10763.9 end, getY = function() return 9771.2 end }
end

-- E. 逐格編號：放得下才畫、編號即所在 chunk、底墊不互疊、所在 chunk 不另標
local function checkLabels(tag, rec, api, expectSome)
    local labels, plates = {}, {}
    for _, t in ipairs(rec.texts) do if t.centre then labels[#labels + 1] = t end end
    for _, r in ipairs(rec.rects) do if r.a == 0.45 then plates[#plates + 1] = r end end
    check((#labels > 0) == expectSome, tag .. " 逐格編號數量不符預期：" .. #labels)
    check(#plates == #labels, tag .. " 每個編號應有一塊底墊")
    for k, t in ipairs(labels) do
        local i, j = t.t:match("^(%-?%d+),(%-?%d+)$")
        i, j = tonumber(i), tonumber(j)
        check(i ~= nil, tag .. " 編號格式應為 i,j：" .. t.t)
        check(not (i == 1345 and j == 1221), tag .. " 所在 chunk 不應再標中央編號")
        local p = plates[k]
        if i and p then
            for _, c in ipairs({ { p[1], p[2] }, { p[1] + p[3], p[2] }, { p[1], p[2] + p[4] },
                { p[1] + p[3], p[2] + p[4] } }) do
                local wx, wy = api.inv(c[1], c[2])
                check(math.floor(wx / 8) == i and math.floor(wy / 8) == j,
                    tag .. " 底墊應整塊落在所標的 chunk 內：" .. t.t)
            end
        end
    end
    for a = 1, #plates do
        for b = a + 1, #plates do
            local p, q = plates[a], plates[b]
            check(not (p[1] < q[1] + q[3] and q[1] < p[1] + p[3] and p[2] < q[2] + q[4] and q[2] < p[2] + p[4]),
                tag .. " 底墊不應互疊")
        end
    end
end
do
    local rec, api = run(10, false, 10763.3, 9771.7, 400, 400) -- chunk 80px
    checkLabels("E 正交 80px", rec, api, true)
    rec, api = run(8.5, false, 10763.3, 9771.7, 400, 400) -- chunk 68px，底墊 69px 放不下
    checkLabels("E 正交 68px", rec, api, false)
    rec, api = run(20, true, 10763.3, 9771.7, 600, 400)
    checkLabels("E 等軸測 20px/格", rec, api, true)
    rec, api = run(8, true, 10763.3, 9771.7, 600, 400)
    checkLabels("E 等軸測 8px/格", rec, api, false)
end

-- E2. 文字另有開關：關掉後不畫任何文字與底墊，底色、格線與所在 chunk 琥珀框照畫
do
    opts.ChunkGridLabels = false
    local rec = run(10, false, 10763.3, 9771.7, 400, 400) -- chunk 80px：文字開啟時會有逐格編號
    local thick = 0
    for _, l in ipairs(rec.lines) do if l.thick == 2 then thick = thick + 1 end end
    check(#rec.texts == 0 and #rec.rects == 0, "E2 文字關閉時不應畫任何文字或底墊")
    check(#rec.lines > thick and #rec.tex > 0 and thick == 4, "E2 文字關閉時格線、底色與所在 chunk 框照畫")
    opts.ChunkGridLabels = nil
end

-- F. 效能上限：世界地圖與小地圖尺寸下掃過整段縮放，每幀繪製呼叫數封頂
do
    local worst, worstTex = 0, 0
    for _, size in ipairs({ { 1920, 1080 }, { 2560, 1440 }, { 3840, 2160 }, { 300, 300 }, { 600, 600 } }) do
        for _, iso in ipairs({ false, true }) do
            local s = 0.5
            while s <= 30 do
                local rec = run(s, iso, 10763.3, 9771.7, size[1], size[2])
                if calls(rec) > worst then worst = calls(rec) end
                if #rec.tex > worstTex then worstTex = #rec.tex end
                check(rec.set == rec.clear, "F stencil 開關應配對")
                check(#rec.polys <= 1, "F 底色不應逐格畫四邊形（只剩所在 chunk）")
                s = s * 1.15
            end
        end
    end
    check(worstTex <= 160, "F 棋盤格貼圖數應封頂（實得 " .. worstTex .. "）")
    check(worst <= 600, "F 每幀繪製呼叫數應封頂（實得 " .. worst .. "）")
end

-- G. 繪製中途出錯：錯誤交回呼叫端，stencil 仍清除（否則引擎全域 stencil 洩漏）
do
    local api = newMapAPI(4, false, 10763.3, 9771.7, 300, 300)
    local inner, rec = newInner(api, 300, 300)
    inner.javaObject.DrawLine = function() error("line boom") end
    local ok, err = pcall(draw, inner)
    check(not ok and tostring(err):find("line boom", 1, true), "G 錯誤應交回呼叫端")
    check(rec.set == 1 and rec.clear == 1, "G 出錯後 stencil 仍應清除")
end

if failures > 0 then
    print(("chunk grid: %d check(s) failed"):format(failures))
    os.exit(1)
end
print("chunk grid: off/LOD/alignment/checker-texture/current-chunk/labels/caps/stencil cases passed")
