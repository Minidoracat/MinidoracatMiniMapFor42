-- 世界地圖資源點圖例（MinidoracatMiniMap_Legend.lua）離線回歸。
-- 版面：抽 test:legend-layout 真實作驗欄數隨可用高度增加、字級倍率、地下列與最小寬度。
-- 面板：整檔載入真模組，ISPanel／ISWorldMap 換成假件，驗掛載冪等、跟著原版圖例顯示／隱藏、
-- 位置接在原版圖例下方、內容與圖例資料一致。地圖上的真實外觀由 E2E legend-sp 截圖驗。
-- 用法：lua scripts/test_map_legend.lua
local CLIENT = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end
local function slice(source, name)
    local tag = name:gsub("%-", "%%-")
    return assert(source:match("%-%- test:" .. tag .. ":start\n(.-)\n%-%- test:" .. tag .. ":end"),
        "找不到區段 " .. name)
end
local legendSource = read(CLIENT .. "MinidoracatMiniMap_Legend.lua")
local mainSource = read(CLIENT .. "MinidoracatMiniMap.lua")

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print("FAIL " .. msg)
    end
end

--------------------------------------------------------------------------------
-- A. 版面（純計算）
--------------------------------------------------------------------------------
local layout = assert(load("local PAD, GAP = 10, 6\n" .. slice(legendSource, "legend-layout")
    .. "\nreturn legendLayout", "=legend-layout"))()
do
    -- 20 類、字高 15／標題 19、倍率 1、無地下列：1080p 放得下 → 2 欄 10 列
    local L = layout(20, 60, 90, nil, 15, 19, 1, 0, 1000)
    check(L.cols == 2 and L.rows == 10, "A1 放得下時維持 2 欄（得 " .. L.cols .. " 欄）")
    check(L.iconS == 17 and L.rowH == 21 and L.headH == 39, "A1 圖示＝字高＋2、列高＝圖示＋4、標題列＝標題字高＋上下留白")
    check(L.height == 39 + 10 * 21 + 10, "A1 高度＝標題列＋列數×列高＋底邊留白")
    check(L.width == 20 + 2 * (17 + 6 + 60 + 10), "A1 寬度＝左右留白＋欄數×（圖示＋間距＋最寬名稱＋欄距）")
    -- 高度不夠：加欄到放得下為止（3 欄 7 列）
    local L3 = layout(20, 60, 90, nil, 15, 19, 1, 0, 39 + 7 * 21 + 10)
    check(L3.cols == 3 and L3.rows == 7, "A2 2 欄放不下時應加到剛好放得下的 3 欄（得 " .. L3.cols .. "）")
    -- 連 4 欄都放不下：停在 4 欄，不再加
    local L4 = layout(20, 60, 90, nil, 15, 19, 1, 0, 50)
    check(L4.cols == 4 and L4.rows == 5, "A3 最多 4 欄（得 " .. L4.cols .. "）")
    -- 字級 200%：圖示、列高與欄寬跟著放大
    local Lz = layout(20, 60, 90, nil, 15, 19, 2, 0, 2000)
    check(Lz.iconS == 32 and Lz.rowH == 36 and Lz.width == 20 + 2 * (32 + 6 + 120 + 10),
        "A4 文字 200% 時圖示／列高／名稱寬都放大")
    -- 地下列：多一列高度；最小寬度（對齊原版圖例）與標題／地下說明的寬度需求
    local Lb = layout(20, 60, 90, 300, 15, 19, 1, 0, 1000)
    check(Lb.height == L.height + 21, "A5 有地下設施列時多一列高度")
    check(Lb.width == 20 + 17 + 6 + 300, "A5 地下說明比兩欄還寬時面板撐開到放得下")
    local Lm = layout(20, 60, 90, nil, 15, 19, 1, 400, 1000)
    check(Lm.width == 400 and Lm.colW == (400 - 20) / 2, "A6 比原版圖例窄時對齊它的寬度、欄寬平均分配")
    local Ln = layout(3, 60, 90, nil, 15, 19, 1, 0, 1000)
    check(Ln.cols == 2 and Ln.rows == 2, "A7 類別數不整除欄數時列數無條件進位")
end

--------------------------------------------------------------------------------
-- B. 面板（整檔載入）
--------------------------------------------------------------------------------
local legendData = { count = 0, basement = false }
local sliders = {}
local drawn
local function resetDrawn() drawn = { tex = {}, text = {}, badges = 0, bg = 0 } end
resetDrawn()

local Panel = {}
Panel.__index = Panel
function Panel:derive(name)
    local c = setmetatable({ Type = name }, { __index = self })
    c.__index = c
    return c
end
function Panel:new(x, y, w, h)
    return setmetatable({ x = x, y = y, width = w, height = h }, self)
end
function Panel:initialise() end
function Panel:prerender() drawn.bg = drawn.bg + 1 end
function Panel:setX(v) self.x = v end
function Panel:setY(v) self.y = v end
function Panel:setWidth(v) self.width = v end
function Panel:setHeight(v) self.height = v end
function Panel:drawTextureScaled(tex, x, y, w, h, a, r, g, b)
    drawn.tex[#drawn.tex + 1] = { tex = tex, x = x, y = y, w = w, r = r, g = g, b = b }
end
function Panel:drawText(s, x, y) drawn.text[#drawn.text + 1] = { s = s, x = x, y = y, zoom = 1 } end
function Panel:drawTextZoomed(s, x, y, z) drawn.text[#drawn.text + 1] = { s = s, x = x, y = y, zoom = z } end

local createCalls = 0
local Core = { ready = true }
Core.poiLegend = function() return legendData end
Core.drawBasementBadge = function() drawn.badges = drawn.badges + 1 end
assert(load(slice(mainSource, "map-text"), "=map-text", "t", setmetatable({ Core = Core,
    getSliderValue = function(id, default)
        if sliders[id] == nil then return default end
        return sliders[id]
    end }, { __index = _G })))()
local WorldMap = { createChildren = function() createCalls = createCalls + 1 end }
local env = setmetatable({
    MinidoracatMiniMapCore = Core,
    ISPanel = Panel,
    ISWorldMap = WorldMap,
    UIFont = { Small = "Small", Medium = "Medium" },
    getText = function(key) return key end,
    getTextManager = function()
        return {
            MeasureStringX = function(_, font, s) return #s * (font == "Medium" and 8 or 6) end,
            getFontHeight = function(_, font) return font == "Medium" and 19 or 15 end,
        }
    end,
    print = function() end,
}, { __index = _G })
assert(load(legendSource, "=Legend", "t", env))()

-- 原版圖例假件：左上角、寬 330、高 380，可見性可切換
local key = { visible = true, x = 10, y = 10, w = 330, h = 380 }
function key:isVisible() return self.visible end
function key:getX() return self.x end
function key:getY() return self.y end
function key:getWidth() return self.w end
function key:getHeight() return self.h end
local map = setmetatable({ height = 1080, keyUI = key, kids = {} }, { __index = WorldMap })
function map:addChild(c) self.kids[#self.kids + 1] = c end

WorldMap.createChildren(map)
WorldMap.createChildren(map) -- 重跑不得重複加
local panel = map._minidoracatLegend
check(createCalls == 2 and #map.kids == 1 and panel and panel.map == map,
    "B1 世界地圖建子元件後掛上一個圖例面板，重跑冪等且原版 createChildren 照跑")

local function frame()
    resetDrawn()
    panel:prerender()
    panel:render()
end

-- B2 圖例資料為空（顯示資源點關閉）：整塊不畫、0×0（不擋滑鼠）
frame()
check(panel.width == 0 and panel.height == 0 and drawn.bg == 0 and #drawn.text == 0,
    "B2 沒有類別時圖例為 0×0 且不畫")

-- B3 有類別：接在原版圖例正下方、左緣對齊、至少一樣寬；標題＋每類一列（圖示染色＋名稱）
legendData = { count = 3, basement = true,
    { name = "Police", tex = "TP", r = 0.2, g = 0.4, b = 0.8 },
    { name = "Gas", tex = "TG", r = 0.5, g = 0.2, b = 0.7 },
    { name = "Pharmacy", tex = "TR", r = 1, g = 1, b = 1 } }
frame()
check(panel.x == 10 and panel.y == 10 + 380 + 10 and panel.width >= 330 and panel.height > 0,
    "B3 圖例應接在原版圖例下方 10px、左緣對齊、寬度不小於原版圖例")
check(#drawn.tex == 3 and drawn.tex[1].tex == "TP" and drawn.tex[1].r == 0.2 and drawn.tex[3].r == 1,
    "B3 每類畫一個圖示、沿用圖例資料的染色")
local names = {}
for _, t in ipairs(drawn.text) do names[#names + 1] = t.s end
check(names[1] == "UI_MinidoracatMiniMap_SecPOI" and names[2] == "Police" and names[4] == "Pharmacy"
    and names[5] == "UI_MinidoracatMiniMap_LegendBasement" and drawn.badges == 1,
    "B3 標題、類別名與地下設施說明列（含角標）都要畫")
check(drawn.tex[2].x > drawn.tex[1].x and drawn.tex[3].y > drawn.tex[1].y,
    "B3 兩欄由左而右、再換列")

-- B4 按 S 收起原版圖例（符號面板）：本圖例一起收
key.visible = false
frame()
check(panel.width == 0 and panel.height == 0 and #drawn.text == 0, "B4 原版圖例隱藏時本圖例一起隱藏")
key.visible = true

-- B5 地圖文字 200%：字以兩倍繪製、面板變大；同一組資料與倍率下尺寸穩定
frame()
local w1 = panel.width
frame()
check(panel.width == w1, "B5 同一組資料與倍率下尺寸穩定")
sliders.MapTextScale = 200
frame()
check(drawn.text[2].zoom == 2 and panel.width > w1, "B5 地圖文字 200% 時圖例文字兩倍、面板放大")
sliders.MapTextScale = nil

-- B6 原版圖例不存在（第三方替換）：退回左上角照畫
map.keyUI = nil
frame()
check(panel.x == 10 and panel.y == 10 and panel.height > 0, "B6 沒有原版圖例時放在左上角")

-- B7 功能閘門 poi 被擋（世界地圖、該地圖目前玩家）：地圖上沒有資源點，圖例一併收起；放行即恢復
map.playerNum = 1
local asked
Core.featureAllowed = function(pn, feature, surface)
    asked = tostring(pn) .. ":" .. feature .. ":" .. tostring(surface)
    return false
end
frame()
check(panel.width == 0 and panel.height == 0 and #drawn.tex == 0 and asked == "1:poi:world",
    "B7 poi 被擋時圖例收起（問該地圖玩家的 world 表面）")
Core.featureAllowed = function() return true end
frame()
check(panel.height > 0, "B7 放行後圖例恢復")
Core.featureAllowed = nil

if failures > 0 then
    print(("map legend: %d check(s) failed"):format(failures))
    os.exit(1)
end
print("map legend: layout A1-A7 + panel mount/visibility/position/content B1-B7 cases passed")
