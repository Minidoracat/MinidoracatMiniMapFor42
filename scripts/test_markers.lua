-- Marker provider（_Markers.lua）離線回歸：整份 production 模組載進沙箱。
-- 不變量：
--   * providerFn 收到畫面擁有者的 playerNum 與表面；不同 slot 只畫自己那份名單
--   * 超出視窗的 marker 不畫；非 live 半透明；有 label 才畫字
--   * 一個 provider 拋錯不拖垮其他 provider，且每場只 log 一次
--   * 同 owner 重註冊＝取代（不重複畫）；壞參數拒收
--   * v2：scale 夾 1..2.5；ring→badge→icon 由外而內、各差 4／6px；裁切以最外層為準；
--     非 live 0.55 乘到所有層；缺 badge.texture 時 ring 靜默略過；label 先黑影後色字、置於最外層右側垂直置中，
--     右側會被視窗右緣切掉時改放最外層左側
--   * 玩家「標記大小」滑條等比放大基準邊長與 badge／ring 外擴；「地圖文字大小」放大標籤
-- 用法：lua scripts/test_markers.lua [MinidoracatMiniMap_Markers.lua]
local path = arg[1] or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Markers.lua"
local file = assert(io.open(path, "rb"))
local source = file:read("*a")
file:close()

local printed = {}
MinidoracatMiniMapCore = {}
MinidoracatMiniMapAPI = {}
UIFont = { Small = "Small" }
getTextManager = function() return { getFontHeight = function() return 10 end, MeasureStringX = function(_, _, s) return #s * 6 end } end
print = function(msg) printed[#printed + 1] = msg end
assert((loadstring or load)(source))()
local API, Core = MinidoracatMiniMapAPI, MinidoracatMiniMapCore
-- 主檔滑條 helper（Core.markerIconSize／mapTextZoom／drawMapText）抽 test:map-text 真實作，
-- 滑條值由本測試控制（未設＝預設值）
local sliders = {}
do
    local mainPath = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
    local mf = assert(io.open(mainPath, "rb"))
    local body = assert(mf:read("*a"):gsub("\r\n", "\n"):match("%-%- test:map%-text:start\n(.-)\n%-%- test:map%-text:end"))
    mf:close()
    local env = setmetatable({ Core = Core, getSliderValue = function(id, default)
        local v = sliders[id]
        if v == nil then return default end
        return v
    end }, { __index = _G })
    assert(load(body, "map-text", "t", env))()
end

local fails = 0
local function check(cond, name)
    if not cond then fails = fails + 1; io.stdout:write("FAIL " .. name .. "\n") else io.stdout:write("ok   " .. name .. "\n") end
end

local function inner(pn)
    local d = { tex = {}, text = {} }
    d.el = {
        playerNum = pn, width = 200, height = 200,
        mapAPI = { worldToUIX = function(_, x) return x end, worldToUIY = function(_, _, y) return y end },
        drawTextureScaled = function(_, tex, x, y, w, h, a, r, g, b)
            d.tex[#d.tex + 1] = { tex = tex, x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
        end,
        drawText = function(_, s, x, y, r, g, b, a) d.text[#d.text + 1] = { s = s, x = x, y = y, r = r, g = g, b = b, a = a } end,
        drawTextZoomed = function(_, s, x, y, z, r, g, b, a)
            d.text[#d.text + 1] = { s = s, x = x, y = y, zoom = z, r = r, g = g, b = b, a = a }
        end,
    }
    return d
end

check(API.markerApiVersion == 2, "markerApiVersion is 2")
API.registerMarkerProvider("", function() end)
API.registerMarkerProvider("X", "not a function")
check(#printed == 2, "bad arguments are rejected with a log line")
local d0 = inner(0); Core.drawMarkers(d0.el, "mini")
check(#d0.tex == 0, "rejected providers are never drawn")

local calls = {}
local buckets = {
    [0] = { revision = 1, markers = { { id = "a", x = 50, y = 60, texture = "carA", r = 0.2, state = "live", label = "A" } } },
    [1] = { revision = 1, markers = { { id = "b", x = 70, y = 80, texture = "carB", state = "lastKnown" },
                                      { id = "off", x = 500, y = 80, texture = "carB", state = "live" } } },
}
API.registerMarkerProvider("VM", function(pn, surface) calls[#calls + 1] = pn .. ":" .. surface; return buckets[pn] end)

local a = inner(0); Core.drawMarkers(a.el, "mini")
check(calls[#calls] == "0:mini", "provider receives playerNum 0 and surface mini")
check(#a.tex == 1 and a.tex[1].tex == "carA" and a.tex[1].x == 44 and a.tex[1].y == 54 and a.tex[1].w == 12,
    "slot 0 draws only its own marker, centered, 12px on the minimap")
check(a.tex[1].a == 1 and a.tex[1].r == 0.2 and #a.text == 2 and a.text[2].s == "A", "live marker is opaque, tinted, labelled")
check(a.text[1].r == 0 and a.text[1].x == a.text[2].x + 1 and a.text[1].y == a.text[2].y + 1
    and a.text[2].r == 1 and a.text[2].g == 1 and a.text[2].b == 1,
    "v1 label: black 1px shadow under a white label")
check(a.text[2].x == 44 + 12 + 2 and a.text[2].y == 60 - 5, "v1 label sits right of the icon, vertically centred")

local b = inner(1); Core.drawMarkers(b.el, "world")
check(calls[#calls] == "1:world", "provider receives playerNum 1 and surface world")
check(#b.tex == 1 and b.tex[1].tex == "carB" and b.tex[1].w == 16, "slot 1 draws only its own in-view marker, 16px on the world map")
check(b.tex[1].a == 0.55 and #b.text == 0, "non-live marker is translucent; no label means no text")

local nPrinted = #printed
API.registerMarkerProvider("Broken", function() error("boom") end)
API.registerMarkerProvider("Late", function() return { revision = 1, markers = { { id = "l", x = 20, y = 20, texture = "late" } } } end)
local c = inner(0); Core.drawMarkers(c.el, "mini"); Core.drawMarkers(c.el, "mini")
local late = 0
for _, t in ipairs(c.tex) do if t.tex == "late" then late = late + 1 end end
check(late == 2, "a throwing provider does not block providers after it")
check(#printed == nPrinted + 1 and printed[#printed]:find("Broken", 1, true), "provider error is logged once per session")

API.registerMarkerProvider("Late", function() return { revision = 2, markers = {} } end)
local e = inner(0); Core.drawMarkers(e.el, "mini")
local lateAfter = 0
for _, t in ipairs(e.tex) do if t.tex == "late" then lateAfter = lateAfter + 1 end end
check(lateAfter == 0 and #e.tex == 1, "re-registering an owner replaces its provider instead of drawing twice")

-- v2：slot 2 專用名單（VM provider 依 pn 取 buckets；其餘 provider 已空或每場只 log 一次）
local function draw2(surface, list)
    buckets[2] = { revision = 1, markers = list }
    local d = inner(2); Core.drawMarkers(d.el, surface)
    return d
end

local sc = draw2("mini", { { id = "big", x = 100, y = 100, texture = "car", state = "live", scale = 5 },
                           { id = "small", x = 100, y = 100, texture = "car", state = "live", scale = 0.5 },
                           { id = "str", x = 100, y = 100, texture = "car", state = "live", scale = "2" } })
check(sc.tex[1].w == 30 and sc.tex[1].x == 85, "scale above 2.5 clamps to 2.5 (12 * 2.5 = 30px, centred)")
check(sc.tex[2].w == 12 and sc.tex[3].w == 12, "scale below 1 or non-number falls back to 1")
local sw = draw2("world", { { id = "w", x = 100, y = 100, texture = "car", state = "live", scale = 1.3 } })
check(sw.tex[1].w == 21, "world scale rounds 16 * 1.3 to 21px")

local br = draw2("mini", { { id = "br", x = 100, y = 100, texture = "car", state = "live", r = 0.1,
    badge = { texture = "disc", r = 0.2, g = 0.3, b = 0.4, a = 0.8 }, ring = { r = 1, g = 0, b = 0, a = 0.5 },
    label = "Mine", labelColor = { r = 1, g = 0.8, b = 0 } } })
check(#br.tex == 3 and br.tex[1].tex == "disc" and br.tex[2].tex == "disc" and br.tex[3].tex == "car",
    "ring, then badge, then icon (outermost first)")
check(br.tex[1].w == 22 and br.tex[1].x == 89 and br.tex[1].r == 1 and br.tex[1].g == 0 and br.tex[1].a == 0.5,
    "ring is badge texture 10px larger than the icon, ring colour")
check(br.tex[2].w == 18 and br.tex[2].x == 91 and br.tex[2].b == 0.4 and br.tex[2].a == 0.8,
    "badge is 6px larger than the icon, badge colour")
check(br.tex[3].w == 12 and br.tex[3].x == 94 and br.tex[3].r == 0.1, "icon keeps its size and tint on top")
check(br.text[1].r == 0 and br.text[2].r == 1 and br.text[2].g == 0.8 and br.text[2].b == 0,
    "labelColor tints the label over its black shadow")
check(br.text[2].x == 89 + 22 + 2 and br.text[2].y == 95, "label sits right of the ring, vertically centred")

local clip = draw2("mini", { { id = "v1edge", x = 8, y = 100, texture = "car", state = "live" },
                             { id = "v2edge", x = 8, y = 100, texture = "car", state = "live",
                               badge = { texture = "disc" }, ring = {} } })
check(#clip.tex == 1 and clip.tex[1].tex == "car" and clip.tex[1].x == 2,
    "clip uses the outermost layer: ring past the edge skips the whole marker, bare icon still draws")

local ghost = draw2("mini", { { id = "g", x = 100, y = 100, texture = "car", state = "lastKnown", label = "G",
    badge = { texture = "disc", a = 0.8 }, ring = {} } })
check(ghost.tex[1].a == 0.55 and ghost.tex[2].a == 0.8 * 0.55 and ghost.tex[3].a == 0.55
    and ghost.text[1].a == 0.55 and ghost.text[2].a == 0.55, "non-live 0.55 applies to every layer and the label")

-- 視窗寬 200：圖示在 x=180 時「41 tiles east」（13 字 × 6 = 78px）放右側會超出右緣，改放左側
local edge = draw2("mini", { { id = "e", x = 180, y = 100, texture = "car", state = "live", label = "41 tiles east" } })
check(edge.text[2].x == 174 - 2 - 78 and edge.text[2].y == 95,
    "a label that would cross the right edge sits left of the marker instead")
local near = draw2("mini", { { id = "n2", x = 150, y = 100, texture = "car", state = "live", label = "E 41" } })
check(near.text[2].x == 144 + 12 + 2, "a label that fits on the right stays on the right")

local nPrinted2 = #printed
local nob = draw2("mini", { { id = "n", x = 100, y = 100, texture = "car", state = "live",
    badge = { r = 1 }, ring = { r = 1 } } })
check(#nob.tex == 1 and nob.tex[1].tex == "car" and nob.tex[1].w == 12 and #printed == nPrinted2,
    "ring without badge.texture is skipped silently; icon still draws")

-- 標記大小 32px（×2）：小地圖基準 12→24、世界 16→32，badge／ring 外擴 6／10→12／20；
-- 地圖文字 200%：標籤走縮放繪製、字高 10→20 的一半讓位
sliders.MarkerIconSize, sliders.MapTextScale = 32, 200
local big = draw2("mini", { { id = "b", x = 100, y = 100, texture = "car", state = "live",
    badge = { texture = "disc" }, ring = {}, label = "Big" } })
check(big.tex[3].w == 24 and big.tex[3].x == 88, "marker size 32 doubles the minimap icon (12 -> 24, centred)")
check(big.tex[2].w == 36 and big.tex[1].w == 44, "badge and ring padding scale with the marker size")
check(big.text[2].zoom == 2 and big.text[2].x == 78 + 44 + 2 and big.text[2].y == 100 - 10,
    "label is drawn at 2x and still sits right of the ring, vertically centred")
local bigw = draw2("world", { { id = "w2", x = 100, y = 100, texture = "car", state = "live", scale = 1.3 } })
check(bigw.tex[1].w == 42, "world base doubles too and scale still applies (32 * 1.3 = 41.6 -> 42)")
sliders.MarkerIconSize, sliders.MapTextScale = nil, nil
io.stdout:write(fails == 0 and "PASS test_markers\n" or ("FAIL test_markers (" .. fails .. ")\n"))
os.exit(fails == 0 and 0 or 1)
