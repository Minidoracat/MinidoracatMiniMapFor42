-- MOD 地圖框線（主檔 test:map-bounds 區段 drawMapBounds；2026-11-02 設計稿 minimap-mapbounds-1102）：
-- 畫不畫看「顯示在」兩格（test:layer-maps 的 Core.layerOn）與伺服器沙盒 AllowMapBounds；選項缺席時畫預設白；
-- 名稱畫在畫面最上方頂點的上方（等軸測＝菱形上角，俯視＝上緣兩角的中點），整個名稱在視窗內才畫。
-- 用法：lua scripts/test_map_bounds.lua [MinidoracatMiniMap.lua]
local path = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local file = assert(io.open(path, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local function section(name)
    return assert(source:match("%-%- test:" .. name .. ":start\n(.-)\n%-%- test:" .. name .. ":end"),
        "找不到主檔 " .. name .. " 測試區段")
end

local opts, combos, sandbox = {}, {}, {}
local edges, rects, texts = {}, {}, {}
local Core = {
    mapTextZoom = function() return 1 end,
    drawMapText = function(_, text, x, y) texts[#texts + 1] = { text = text, x = x, y = y } end,
}
local function getBoolOption(id, default)
    if opts[id] == nil then return default end
    return opts[id]
end
local function getComboIndex(id, default) return combos[id] or default end
local function sandboxGate(name, default)
    if sandbox[name] == nil then return default end
    return sandbox[name]
end
local function drawClippedEdge(_, x1, y1, x2, y2, r, g, b, a)
    edges[#edges + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, r = r, g = g, b = b, a = a }
end
getTextOrNull = function() return nil end
getTextManager = function()
    return { MeasureStringX = function(_, _, s) return #s * 6 end, getFontHeight = function() return 10 end }
end
UIFont = { Small = "Small" }
local compile = loadstring or load
local drawMapBounds = assert(compile(table.concat({
    "local Core, getBoolOption, getComboIndex, sandboxGate, drawClippedEdge, mapOverlays = ...",
    "local SH_EDGE_A = 0.85",
    section("layer%-maps"),
    section("map%-bounds"),
    "return drawMapBounds",
}, "\n")))(Core, getBoolOption, getComboIndex, sandboxGate, drawClippedEdge,
    { { bounds = { 100, 100, 200, 300 }, mapMod = "TestMap" } }) -- 名稱 7 字＝寬 42、字高 10

-- 等軸測：ux＝x−y＋ox、uy＝(x+y)/2＋oy（矩形成菱形，(100,100) 那角在最上面）；俯視：ux＝x＋ox、uy＝y＋oy
local function surface(iso, ox, oy)
    local s = { width = 800, height = 600 }
    s.mapAPI = {
        worldToUIX = function(_, x, y) if iso then return x - y + ox end return x + ox end,
        worldToUIY = function(_, x, y) if iso then return (x + y) / 2 + oy end return y + oy end,
    }
    function s:drawRect(x, y, w, h) rects[#rects + 1] = { x = x, y = y, w = w, h = h } end
    return s
end
local function draw(inner)
    edges, rects, texts = {}, {}, {}
    drawMapBounds(inner)
    return #edges, texts[1]
end
local function eq(a, b, why) assert(a == b, why .. ": " .. tostring(a) .. " != " .. tostring(b)) end

local mini, world = surface(true, 300, -50), surface(true, 300, -50)
ISWorldMap_instance = world

-- 預設：兩張地圖都畫、白色；名稱在菱形上角（300,50）的正上方：x＝300−21、y＝50−10−4
local n, label = draw(mini)
eq(n, 4, "預設小地圖畫四邊")
eq(edges[1].r + edges[1].g + edges[1].b, 3, "選項缺席時畫預設白")
eq(edges[1].a, 0.85, "預設不透明")
eq(label.text, "TestMap", "名稱")
eq(label.x, 279, "名稱水平置中在最上面那個頂點")
eq(label.y, 36, "名稱在頂點上方 4px")
eq((draw(world)), 4, "預設世界地圖也畫")

-- 俯視：上緣兩角同高，名稱置中在兩角中間（x 150）
local _, top = draw(surface(false, 0, -50))
eq(top.x, 150 - 21, "俯視時名稱在上緣中點")
eq(top.y, 50 - 14, "俯視時名稱在上緣上方")

-- 頂點貼近視窗上緣：名稱放不下就不畫，框線照畫
n, label = draw(surface(true, 300, -90)) -- 上角 y＝10
eq(n, 4, "名稱放不下框線照畫")
eq(label, nil, "名稱超出視窗不畫")

-- 「顯示在」兩格各管各的；世界地圖的「地圖圖層」總開關不管框線（不是圖層）
opts.MapBounds = false
eq((draw(mini)), 0, "小地圖那格關＝小地圖不畫")
eq((draw(world)), 4, "小地圖那格關不影響世界地圖")
opts.MapBounds, opts.WMMapBounds = nil, false
eq((draw(world)), 0, "世界地圖那格關＝世界地圖不畫")
eq((draw(mini)), 4, "世界地圖那格關不影響小地圖")
opts.WMMapBounds, opts.WMLayers = nil, false
eq((draw(world)), 4, "地圖圖層總開關不管框線")
opts.WMLayers = nil

-- 伺服器沙盒 AllowMapBounds 關：兩張地圖都不畫（玩家的格開著也一樣）
sandbox.AllowMapBounds = false
eq((draw(mini)) + (draw(world)), 0, "伺服器關掉＝兩張地圖都不畫")
sandbox.AllowMapBounds = nil

-- 玩家選的顏色與透明度照用
combos.MapBoundsColor, combos.MapBoundsAlpha = 1, 2
draw(mini)
eq(edges[1].g, 0.95, "選綠畫綠")
eq(edges[1].a, 0.85 * 0.5, "半透明")

print("test_map_bounds: ok")
