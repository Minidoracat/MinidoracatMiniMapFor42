-- 穿透模式（GhostMode）離線回歸測試：gate 契約＋applyGhost 清理面。
-- 仿 test_key_migration.lua：抽 _Ghost.lua 標記區段→補最小 stub→組裝離線跑。
-- 核心不變量：gate 在 ghost 時「必須 return false 不是 nil」——UIElement.java
-- 右鍵收尾對 nil 是無條件消費，改成裸 return 會讓右鍵從穿透翻轉成消費且症狀隱晦。
-- 用法：lua scripts/test_ghost_gate.lua
local ghostPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Ghost.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end
local source = readSource(ghostPath)
local compile = loadstring or load

--------------------------------------------------------------------------------
-- gate 契約：ghost 回 false 且不呼叫 orig；非 ghost 原樣轉發（含 nil）；
-- orig 缺失時回 false（≠nil）；class nil 不炸
--------------------------------------------------------------------------------
local gateBody = assert(source:match(
    "%-%- test:ghost%-gate:start\n(.-)\n%-%- test:ghost%-gate:end"),
    "找不到 ghost-gate 測試區段")
-- 注意：長字串 [=[ 後的首個換行會被 Lua 吃掉，body 與 suffix 之間須補顯式 "\n"
-- marker 涵蓋 gate 函式＋GATED 佈線迴圈（三 class × 五事件）：prelude 提供三個
-- class stub，佈線在抽取執行時真的跑——漏列 class/handler 會被 G6 抓到
local gateChunk = assert(compile([=[
local ghostOn = false
local function isGhost() return ghostOn end
local ISMiniMapInner = { onMouseDown = function() return true end } -- 原版主動消費代表
local ISMiniMapOuter = {}
local ISMiniMapTitleBar = {}
]=] .. gateBody .. "\n" .. [=[
return {
    classes = { inner = ISMiniMapInner, outer = ISMiniMapOuter, titleBar = ISMiniMapTitleBar },
    GATED = GATED,
    gate = gate,
    setGhost = function(v) ghostOn = v end,
}
]=], "ghost-gate"))()

local calls
local class = {}
function class.onMouseDown(self, x, y)
    calls[#calls + 1] = { x = x, y = y }
    return true
end
class.onRightMouseUp = nil -- 原本不存在的 handler

gateChunk.gate(class, "onMouseDown")
gateChunk.gate(class, "onRightMouseUp")
gateChunk.gate(nil, "onMouseDown") -- G4: class nil 不炸

-- G1: ghost on → 回 false（明確 false，非 nil）且不呼叫 orig
calls = {}
gateChunk.setGhost(true)
local r = class.onMouseDown({}, 1, 2)
assert(r == false, "G1: ghost 時必須 return false（不是 nil/true）")
assert(#calls == 0, "G1: ghost 時不得呼叫 orig")

-- G2: ghost off → 轉發引數與回傳值
gateChunk.setGhost(false)
r = class.onMouseDown({}, 7, 9)
assert(r == true, "G2: 非 ghost 須回傳 orig 的值")
assert(#calls == 1 and calls[1].x == 7 and calls[1].y == 9, "G2: 引數須原樣轉發")

-- G3: orig 缺失＋非 ghost → 回 false（與未定義在 Java 路徑同義；不得回 nil）
r = class.onRightMouseUp({}, 0, 0)
assert(r == false, "G3: orig 缺失時必須 return false（不是 nil）")

-- G5: orig 回 nil 的語意保留（原版 onMouseUp 常回 nil→由 consume 旗標決定）
class.onMouseUpNilOrig = function(self) return nil end
gateChunk.gate(class, "onMouseUpNilOrig")
r = class.onMouseUpNilOrig({})
assert(r == nil, "G5: orig 回 nil 須原樣轉發（不得變 false）")

-- G6: 佈線覆蓋面——三 class × 五事件共 15 個 slot 全部被 gate 換上、ghost 時回 false；
--     inner 的原版 onMouseDown（回 true）在非 ghost 時仍原樣轉發
assert(#gateChunk.GATED == 5, "G6: GATED 清單須為五事件")
for cname, cls in pairs(gateChunk.classes) do
    for _, ev in ipairs(gateChunk.GATED) do
        assert(type(cls[ev]) == "function", "G6: " .. cname .. "." .. ev .. " 未被 gate 佈線")
        gateChunk.setGhost(true)
        assert(cls[ev]({}) == false, "G6: ghost 時 " .. cname .. "." .. ev .. " 須回 false")
    end
end
gateChunk.setGhost(false)
assert(gateChunk.classes.inner.onMouseDown({}) == true, "G6: 非 ghost 時 inner 原版 handler 須生效")

--------------------------------------------------------------------------------
-- applyGhost 清理面：want 旗標只動 inner；進穿透清 inner/titleBar 拖曳、
-- 右鍵旗標、freelook、capture；nil 引數＝套全玩家＋cancelResize
--------------------------------------------------------------------------------
local applyBody = assert(source:match(
    "%-%- test:ghost%-apply:start\n(.-)\n%-%- test:ghost%-apply:end"),
    "找不到 ghost-apply 測試區段")

local function mkPart(name, rec, want0)
    local p = { dragging = true, rightMouseDown = true, _minidoracatFreelook = true,
        _want = want0 }
    function p:isWantMouseEvents() return self._want end
    function p:setWantMouseEvents(v)
        self._want = v
        rec[name .. ".want"] = v
    end
    p.setCapture = function(self, v) rec[name .. ".capture"] = v end
    return p
end
-- outer 本身也是 part（stale picker 修正：全組都要放行）；bottomPanel 原值 false
-- 驗證快照忠實還原（不得硬編 true）
local function mkMM(rec)
    local mm = mkPart("outer", rec, true)
    mm.inner = mkPart("inner", rec, true)
    mm.titleBar = mkPart("titleBar", rec, true)
    mm.bottomPanel = mkPart("bottomPanel", rec, false)
    return mm
end

local applyEnv = [=[
local ghostOn = true
local sliderVal = 50
local function isGhost() return ghostOn end
local function getSliderValue(id, d, mn, mx) return sliderVal end
local Core = {
    chromeCalls = 0, cancelCalls = 0,
}
Core.applyChromeOpacity = function() Core.chromeCalls = Core.chromeCalls + 1 end
Core.cancelResize = function() Core.cancelCalls = Core.cancelCalls + 1 end
local minimaps = {}
local function getPlayerMiniMap(pn) return minimaps[pn] end
]=]
local applyChunk = assert(compile(applyEnv .. applyBody .. "\n" .. [=[
return {
    applyGhost = applyGhost,
    Core = Core,
    setGhost = function(v) ghostOn = v end,
    setMiniMaps = function(t) minimaps = t end,
    setSlider = function(v) sliderVal = v end,
}
]=], "ghost-apply"))()

-- A1: 進穿透（mm 給定）：全組（outer/inner/titleBar/bottomPanel）want=false
--     （stale picker 修正——outer 消費 mouse-move 會讓世界指向不更新）＋原值快照；
--     拖曳/右鍵旗標/freelook/capture 全清（黏鼠 bug 防線）
local rec = {}
local mm = mkMM(rec)
applyChunk.setGhost(true)
applyChunk.applyGhost(mm)
assert(rec["outer.want"] == false and rec["inner.want"] == false
    and rec["titleBar.want"] == false and rec["bottomPanel.want"] == false,
    "A1: 全組須 setWantMouseEvents(false)（僅設 inner＝outer 吃 mouse-move、stale picker）")
assert(mm._minidoracatWantMouse == true and mm.bottomPanel._minidoracatWantMouse == false,
    "A1: 原值須快照（bottomPanel 原 false 也要照實記）")
assert(mm.inner.dragging == false and mm.inner.rightMouseDown == false
    and mm.inner._minidoracatFreelook == nil, "A1: inner 手勢殘留須清")
assert(mm.titleBar.dragging == false, "A1: titleBar.dragging 須清（黏鼠 bug）")
assert(rec["inner.capture"] == false and rec["titleBar.capture"] == false,
    "A1: inner/titleBar capture 須釋放")
assert(applyChunk.Core.chromeCalls == 1, "A1: 須重套 applyChromeOpacity")

-- A2a: 退出穿透（同一 mm）：want 依快照忠實還原（inner→true、bottomPanel→false，
--      不得硬編 true）、快照欄位清除
applyChunk.setGhost(false)
applyChunk.applyGhost(mm)
assert(mm.inner._want == true and mm._want == true and mm.titleBar._want == true,
    "A2a: 原值 true 的元件須還原 true")
assert(mm.bottomPanel._want == false, "A2a: 原值 false 的元件須還原 false（非硬編 true）")
assert(mm._minidoracatWantMouse == nil, "A2a: 快照欄位須清除")

-- A2b: 從未進過穿透的 mm 在 ghost off 下：不動 want、不清手勢
rec = {}
mm = mkMM(rec)
applyChunk.applyGhost(mm)
assert(rec["inner.want"] == nil, "A2b: 未進過穿透不得動 want 旗標")
assert(mm.inner.dragging == true and mm.titleBar.dragging == true,
    "A2b: 非進穿透不得清拖曳狀態")

-- A3: nil 引數＝套所有現存小地圖＋進穿透時 cancelResize
rec = {}
local mm0, mm2 = mkMM(rec), { inner = mkPart("inner2", rec, true) }
applyChunk.setMiniMaps({ [0] = mm0, [2] = mm2 })
applyChunk.setGhost(true)
local before = applyChunk.Core.cancelCalls
applyChunk.applyGhost(nil)
assert(rec["inner.want"] == false and rec["inner2.want"] == false,
    "A3: nil 引數須套用到所有現存小地圖（分割畫面 P2+）")
assert(applyChunk.Core.cancelCalls == before + 1, "A3: 進穿透須 cancelResize")

--------------------------------------------------------------------------------
-- 地圖本體壓暗（dimMapBody，分層策略）：內容層（pyramid/text）×0.5、被蓋住的
-- polygon 與底紙/背景歸零（疊層不透明度相乘累積＝奶霧感的根因）、向量模式
-- （無 pyramid）polygon 即內容 ×0.5；RGB 不動、快照還原、冪等不複利、
-- 無 fill 存取器的層（Line）pcall 跳過不炸
--------------------------------------------------------------------------------
local function mkLayer(count, alpha0, kind, id)
    local L = { fills = {}, n = count }
    for i = 0, count - 1 do
        L.fills[i] = { r = 10 + i, g = 20 + i, b = 30 + i, a = alpha0 }
    end
    function L:getFillStops() return self.n end
    function L:getFillRed(i) return self.fills[i].r end
    function L:getFillGreen(i) return self.fills[i].g end
    function L:getFillBlue(i) return self.fills[i].b end
    function L:getFillAlpha(i) return self.fills[i].a end
    function L:setFillRGBA(i, r, g, b, a)
        local f = self.fills[i]
        f.r, f.g, f.b, f.a = r, g, b, a
    end
    -- 分類走 layer:getTypeString()（"Pyramid"/"Texture"/"Text"/"Polygon"/"Line"；
    -- 引擎穩定型別字串，Kahlua 免探測缺失 method）；快照鍵走 getID()
    function L:getTypeString() return kind end
    function L:getID() return id end
    return L
end
local pyr = mkLayer(2, 255, "Pyramid", "pyr1")
local txt = mkLayer(1, 200, "Text", "txt1")
local poly = mkLayer(1, 255, "Polygon", "poly1")
local paper = mkLayer(1, 255, "Texture", "paper1") -- 底紙/背景 texture
local lineLayer = { getTypeString = function() return "Line" end,
    getID = function() return "line1" end } -- Line：分類 skip、完全不碰
local function mkStyle(layers)
    return {
        getLayerCount = function() return #layers + 1 end, -- 0-based：n = #+1
        getLayerByIndex = function(_, i) return layers[i] end,
    }
end
-- mapAPI stub：底紙/未探索遮罩三方法記錄最後一次呼叫的 alpha
local function mkMapAPI(style)
    local A = { calls = {} }
    A.getStyleAPI = function() return style end
    A.setBackgroundRGBA = function(_, r, g, b, a) A.calls.bg = a end
    A.setUnvisitedRGBA = function(_, r, g, b, a) A.calls.uv = a end
    A.setUnvisitedGridRGBA = function(_, r, g, b, a) A.calls.uvg = a end
    return A
end
rec = {}
local mmD = mkMM(rec)
local apiD = mkMapAPI(mkStyle({ [0] = paper, [1] = poly, [2] = lineLayer, [3] = txt, [4] = pyr }))
mmD.inner.mapAPI = apiD

-- A4: 進穿透（圖片模式）：pyramid 255→128、text 200→100、polygon→0、底紙→0、
--     背景→0；RGB 保留；冪等不複利
applyChunk.setGhost(true)
applyChunk.applyGhost(mmD)
assert(pyr.fills[0].a == 128 and pyr.fills[1].a == 128, "A4: pyramid＝內容層 ×0.5")
assert(txt.fills[0].a == 100, "A4: text ×0.5")
assert(poly.fills[0].a == 0, "A4: polygon 被 pyramid 蓋住＝歸零（防疊層累積）")
assert(paper.fills[0].a == 0, "A4: 底紙 texture 歸零")
assert(pyr.fills[0].r == 10 and pyr.fills[1].g == 21, "A4: RGB 不得變動")
assert(apiD.calls.bg == 0, "A4: 底紙 quad setBackgroundRGBA alpha 須歸零（第一死點）")
assert(apiD.calls.uv == 0.5 and apiD.calls.uvg == 0.5, "A4: 未探索遮罩 alpha 須壓 0.5")
applyChunk.applyGhost(mmD) -- 第二次套用（多入口重複呼叫）
assert(pyr.fills[0].a == 128, "A4: 冪等——重複套用不得複利遞減")

-- A5: 退出＝全數還原、快照清除
applyChunk.setGhost(false)
applyChunk.applyGhost(mmD)
assert(pyr.fills[0].a == 255 and txt.fills[0].a == 200
    and poly.fills[0].a == 255 and paper.fills[0].a == 255, "A5: alpha 須還原快照值")
assert(apiD.calls.bg == 1.0 and apiD.calls.uv == 1.0 and apiD.calls.uvg == 1.0,
    "A5: 底紙/未探索遮罩須還原 vanilla alpha=1.0")
assert(mmD.inner._minidoracatGhostSnap == nil, "A5: 快照須清除")

-- A6: 向量模式（無 pyramid）：polygon 即內容 ×0.5、底紙仍歸零
local poly2, paper2 = mkLayer(1, 255, "Polygon", "p2"), mkLayer(1, 255, "Texture", "pa2")
rec = {}
local mmV = mkMM(rec)
mmV.inner.mapAPI = mkMapAPI(mkStyle({ [0] = paper2, [1] = poly2 }))
applyChunk.setGhost(true)
applyChunk.applyGhost(mmV)
assert(poly2.fills[0].a == 128, "A6: 向量模式 polygon＝內容 ×0.5")
assert(paper2.fills[0].a == 0, "A6: 向量模式底紙仍歸零")

-- A7: 滑條改動＝先還原再以新值重壓（穿透中調整即時生效、不複利）
applyChunk.setSlider(20)
applyChunk.applyGhost(mmV)
assert(poly2.fills[0].a == 51, "A7: 滑條 20% 須以原值重壓（255×0.2=51，非 128×0.2）")
applyChunk.setGhost(false)
applyChunk.applyGhost(mmV)
assert(poly2.fills[0].a == 255, "A7: 滑條改動後退出仍還原原始值")
applyChunk.setSlider(50)

-- A8: in-place 重掛（index 漂移）：快照鍵＝getID，layer 順序調換後退出仍還原到
--     「正確的那一層」，不會把 A 層 alpha 寫進 B 層
local pyr3 = mkLayer(1, 255, "Pyramid", "p3")
local txt3 = mkLayer(1, 200, "Text", "t3")
local layers3 = { [0] = txt3, [1] = pyr3 }
rec = {}
local mmR = mkMM(rec)
mmR.inner.mapAPI = mkMapAPI(mkStyle(layers3))
applyChunk.setGhost(true)
applyChunk.applyGhost(mmR)
assert(pyr3.fills[0].a == 128 and txt3.fills[0].a == 100, "A8: 前置壓暗")
layers3[0], layers3[1] = layers3[1], layers3[0] -- 模擬第三方 in-place 重掛：index 對調
applyChunk.setGhost(false)
applyChunk.applyGhost(mmR)
assert(pyr3.fills[0].a == 255 and txt3.fills[0].a == 200,
    "A8: index 對調後仍須以 id 反查還原（255/200，不得互換成 200/255 系錯值）")

print("test_ghost_gate: OK（gate G1-G6＋清理 A1-A3＋壓暗分層 A4-A8）")
