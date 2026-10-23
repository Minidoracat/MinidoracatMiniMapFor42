-- 道路工具（MinidoracatMiniMap_RoadTool.lua）離線回歸：整檔載入真模組，原版工具基底照
-- ISWorldMapSymbols.lua:11-88 的語意換成假件，地圖投影用固定比例。守的是玩家看得到的錯：
-- 拖曳地圖被當成加點、復原、點選單內容、吸附（Shift、中間點）、存檔提醒（free、30 格外、急彎）、
-- 離開時草稿留著、存出去的路 RoadData 收得下（零長度段、每段資料筆數）。
-- 用法：lua scripts/test_road_tool.lua
local PATH = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
    .. "MinidoracatMiniMap_RoadTool.lua"
local f = assert(io.open(PATH, "rb"))
local source = f:read("*a")
f:close()

local failures, total = 0, 0
local function check(cond, msg)
    total = total + 1
    if not cond then
        failures = failures + 1
        print("FAIL " .. msg)
    end
end

--------------------------------------------------------------------------------
-- 假環境
--------------------------------------------------------------------------------
local calls = {}
local shift = false
local nearest = nil -- function(pn, x, y, maxDist) -> 結果
local Core = { ready = true }
Core.navNearestRoad = function(pn, x, y, maxDist, skip)
    calls[#calls + 1] = "near:" .. tostring(skip)
    return nearest and nearest(pn, x, y, maxDist) or nil
end
local drafts = {}
Core.roadsSetDraft = function(pn, d) drafts[#drafts + 1] = d end
Core.roadsClearDraft = function(pn) calls[#calls + 1] = "clearDraft" end
local store = {}
Core.roadsGet = function(pn, id)
    local r = store[id]
    if not r then return nil end
    local c = {}
    for k, v in pairs(r) do c[k] = v end
    return c
end
local saved = {}
Core.roadsSave = function(pn, road)
    saved[#saved + 1] = road
    road.id = road.id or "r1"
    return true, road.id
end
Core.navMessage = function(pn, text, good) calls[#calls + 1] = "msg:" .. text end

-- ISBaseObject／ISWorldMapSymbolTool（ISWorldMapSymbols.lua:11-88）
local Base = {}
function Base:derive(t)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.Type = t
    return o
end
function Base:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    return o
end
local SymTool = Base:derive("ISWorldMapSymbolTool")
function SymTool:activate() end
function SymTool:deactivate() end
function SymTool:onMouseDown(x, y)
    self.dragging, self.dragMoved, self.dragStartX, self.dragStartY = true, false, x, y
    return false
end
function SymTool:onMouseUp() self.dragging = false; return false end
function SymTool:onMouseMove()
    if self.dragging and not self.dragMoved then
        local mx, my = self:getMouseX(), self:getMouseY()
        if math.abs(mx - self.dragStartX) > 4 and math.abs(my - self.dragStartY) > 4 then self.dragMoved = true end
    end
    return false
end
function SymTool:getMouseX() return self.mapUI:getMouseX() end
function SymTool:getMouseY() return self.mapUI:getMouseY() end
function SymTool:new(symbolsUI)
    local o = Base.new(self)
    o.symbolsUI, o.mapUI, o.mapAPI = symbolsUI, symbolsUI.mapUI, symbolsUI.mapAPI
    return o
end

-- 地圖：1 格＝2 px，原點在 (0,0)
local S = 2
local mapAPI = {}
function mapAPI:worldToUIX(x) return x * S end
function mapAPI:worldToUIY(_, y) return y * S end
function mapAPI:uiToWorldX(x) return x / S end
function mapAPI:uiToWorldY(_, y) return y / S end
function mapAPI:getCenterWorldX() return 200 end
function mapAPI:getCenterWorldY() return 150 end
local mouse = { x = 0, y = 0 }
local mapUI = { width = 800, height = 600 }
function mapUI:getMouseX() return mouse.x end
function mapUI:getMouseY() return mouse.y end
function mapAPI:centerOn() end
function mapAPI:setZoom() end
function mapUI:getAbsoluteX() return 0 end
function mapUI:getAbsoluteY() return 0 end
function mapUI:isVisible() return true end
local symbolsUI = { mapUI = mapUI, mapAPI = mapAPI }
function symbolsUI:setCurrentTool(t)
    if t == self.currentTool then return end
    if self.currentTool then self.currentTool:deactivate() end
    self.currentTool = t
    if t then t:activate() end
end
mapUI.symbolsUI, mapUI.mapAPI, mapUI.playerNum = symbolsUI, mapAPI, 0

local menus = {}
local panels = {}
local function fakeElement(x, y, w, h)
    local e = { x = x, y = y, width = w, height = h, kids = {} }
    function e:initialise() end
    function e:instantiate() end
    function e:addChild(c) self.kids[#self.kids + 1] = c end
    function e:setX(v) self.x = v end
    function e:setY(v) self.y = v end
    function e:setVisible(v) self.visible = v end
    function e:addToUIManager() panels[#panels + 1] = self; self.shown = true end
    function e:removeFromUIManager() self.shown = false end
    function e:bringToTop() end
    function e:insertNewLineOfButtons(...) self.joypadButtonsY = { { ... } } end
    function e:setISButtonForB(b) self.buttonB = b end
    function e:insertNewListOfButtons(list) self.joypadButtonsY = self.joypadButtonsY or {} end
    function e:setHeight(v) self.height = v end
    function e:setMaxTextLength() end
    function e:setPlaceholderText() end
    return e
end
local env = setmetatable({
    MinidoracatMiniMapCore = Core,
    ISWorldMapSymbolTool = SymTool,
    ISWorldMap_instance = mapUI,
    ISWorldMap = { ShowWorldMap = function() end },
    getText = function(key, ...)
        local n = select("#", ...)
        if n == 0 then return key end
        local parts = { key }
        for i = 1, n do parts[#parts + 1] = tostring((select(i, ...))) end
        return table.concat(parts, "|", 1, #parts)
    end,
    isShiftKeyDown = function() return shift end,
    JoypadState = { players = {} },
    Keyboard = { KEY_RETURN = 28, KEY_BACK = 14, KEY_ESCAPE = 1 },
    Joypad = { AButton = 0 },
    getSpecificPlayer = function() return {} end,
    ISContextMenu = { get = function(pn, x, y)
        local m = { options = {} }
        function m:addOption(name, target, fn, a, b)
            local o = { name = name, fn = fn, target = target, a = a, b = b }
            self.options[#self.options + 1] = o
            return o
        end
        menus[#menus + 1] = m
        return m
    end },
    print = function() end,
    -- 確認面板用的最小 UI 假件（版面不在這裡驗，只看按了哪顆會怎樣）
    getTextManager = function()
        return { getFontHeight = function() return 15 end, MeasureStringX = function(_, _, s) return #s * 7 end }
    end,
    getCore = function() return { getScreenWidth = function() return 1920 end } end,
    UIFont = { Small = 1, Medium = 2 },
    ISPanelJoypad = { new = function(_, x, y, w, h) return fakeElement(x, y, w, h) end },
    ISButton = { new = function(_, x, y, w, h, title, target, fn)
        local b = fakeElement(x, y, w, h)
        b.title, b.target, b.onclick = title, target, fn
        return b
    end },
    ISTextEntryBox = { new = function(_, text, x, y, w, h)
        local b = fakeElement(x, y, w, h)
        function b:getText() return text end
        return b
    end },
}, { __index = _G })
assert(load(source, "=RoadTool", "t", env))()
local RT = Core.RoadTool
RT.makeBar = function() end -- 工具列是 UI 外觀，不在這裡測
local realOpenForm = RT.openForm -- E 段用真表單驗查詢參數
RT.openForm = function(tool) calls[#calls + 1] = "form"; tool.form = {} end
RT.closeForm = function(tool) RT.closeConfirm(tool); tool.form = nil end

local function newTool(opts)
    local t = RT.Tool:new(symbolsUI)
    assert(t:setup(0, opts or { mode = "draw" }))
    symbolsUI:setCurrentTool(t)
    return t
end
local function click(t, wx, wy)
    mouse.x, mouse.y = wx * S, wy * S
    t:onMouseDown(mouse.x, mouse.y)
    return t:onMouseUp(mouse.x, mouse.y)
end
local function reset()
    symbolsUI:setCurrentTool(nil)
    for k in pairs(calls) do calls[k] = nil end
    for k in pairs(drafts) do drafts[k] = nil end
    for k in pairs(saved) do saved[k] = nil end
    nearest, shift = nil, false
end

--------------------------------------------------------------------------------
-- D. 拖曳門檻：任一軸超過 4 px 就是平移地圖，不加點（原版要兩軸都超過，水平拖會被當成點一下）
--------------------------------------------------------------------------------
check(RT.dragMoved(100, 100, 105, 100) and RT.dragMoved(100, 100, 100, 95), "D1 只動一軸超過 4 px 也算拖曳")
check(not RT.dragMoved(100, 100, 104, 104), "D1 兩軸都在 4 px 內不算拖曳")
do
    local t = newTool()
    mouse.x, mouse.y = 100, 100
    t:onMouseDown(100, 100)
    mouse.x = 120 -- 純水平拖
    check(t:onMouseMove(20, 0) == false, "D2 拖曳時照原版平移（onMouseMove 回 false）")
    local r = t:onMouseUp(120, 100)
    check(r == false and t:count() == 0, "D2 水平拖地圖放開後不得加點")
    check(click(t, 50, 50) == true and t:count() == 1, "D3 點一下才加點")
    reset()
end

--------------------------------------------------------------------------------
-- U. 復原：右鍵空白處、Backspace 都一步一步退；空了不出錯
--------------------------------------------------------------------------------
do
    local t = newTool()
    click(t, 10, 10); click(t, 20, 10); click(t, 30, 10)
    check(t:count() == 3, "U0 三次點擊三個點")
    mouse.x, mouse.y = 300, 300
    check(t:onRightMouseUp(300, 300) == true and t:count() == 2, "U1 右鍵空白處＝復原一點，並吃掉這次右鍵")
    check(t:onKeyRelease(14) == true and t:count() == 1, "U2 Backspace＝復原")
    t:undo()
    check(t:count() == 0 and t:undo() == false, "U3 復原到空再按不出錯")
    check(t:isKeyConsumed(28) and t:isKeyConsumed(14) and not t:isKeyConsumed(1),
        "U4 Enter／Backspace 不讓遊戲收到，Esc 留給原版關工具")
    reset()
end

--------------------------------------------------------------------------------
-- M. 點選單內容依模式與頭尾
--------------------------------------------------------------------------------
local function ops(items)
    local t = {}
    for i = 1, #items do t[i] = items[i].op .. (items[i].off and "(off)" or "") end
    return table.concat(t, ",", 1, #t)
end
local snap2 = { "snap", "snap" }
check(ops(RT.pointMenuItems("draw", 3, 3, snap2)) == "finish,delete,endFree", "M1 畫線的最後一點：完成、刪除、這端不接")
check(ops(RT.pointMenuItems("draw", 2, 3, snap2)) == "delete", "M2 畫線的中間點：只有刪除（不接道路只給頭尾）")
check(ops(RT.pointMenuItems("draw", 1, 3, snap2)) == "delete,endFree", "M3 畫線的第一點：沒有完成")
check(ops(RT.pointMenuItems("draw", 1, 1, snap2)) == "delete", "M4 只有一點：不列完成與接法")
check(ops(RT.pointMenuItems("edit", 2, 4, snap2)) == "move,delete", "M5 編輯中間點：移動、刪除")
check(ops(RT.pointMenuItems("edit", 4, 4, { "snap", "free" })) == "move,delete,endSnap",
    "M6 已設不接的端點改列「這端接上道路」")
check(ops(RT.pointMenuItems("review", 1, 2, snap2)) == "move,delete(off),endFree",
    "M7 只剩兩點時刪除灰掉（路至少兩點）")
do
    local t = newTool()
    click(t, 10, 10); click(t, 40, 10)
    mouse.x, mouse.y = 80, 20
    check(t:onRightMouseUp(80, 20) == true and #menus == 1 and t:count() == 2,
        "M8 右鍵在點上開點選單、不復原")
    local opt = menus[1].options[1]
    opt.fn(opt.target, opt.a, opt.b)
    check(calls[#calls] == "form", "M8 選「完成」開存檔表單")
    reset()
end

--------------------------------------------------------------------------------
-- S. 吸附：端點靠近道路吸過去；Shift 這一點不吸；上一個終點變成中間點時放回原位
--------------------------------------------------------------------------------
nearest = function(pn, x, y, maxDist)
    if y > 8 and y < 12 then return { x = x, y = 10, dist = math.abs(y - 10), name = "Mabel St" } end
end
do
    local t = newTool()
    click(t, 50, 11)
    check(t.pts[2] == 10, "S1 第一點靠近道路吸到路上")
    shift = true
    click(t, 80, 11)
    shift = false
    check(t.pts[4] == 11, "S2 按住 Shift 的點不吸附")
    t:undo()
    click(t, 80, 11)
    check(t.pts[4] == 10, "S3 新的終點吸附")
    click(t, 80, 60)
    check(t.pts[4] == 11 and t.pts[2] == 10, "S4 終點變中間點後放回畫的位置，起點仍接著道路")
    check(t:count() == 3 and t.segW == nil, "S5 畫的路不帶每段資料（存檔時才填）")
    reset()
end

--------------------------------------------------------------------------------
-- I. 存檔提醒：free 端不提醒、30 格外不提醒、30 格內沒接上提醒並帶接上點；急彎；已接上
--------------------------------------------------------------------------------
do
    local line = { 0, 0, 100, 0 }
    nearest = function(pn, x, y, maxDist)
        if x == 0 then return { x = 0, y = 12, dist = 12, name = "Old Barn Rd" } end
        return { x = 100, y = 0.5, dist = 0.5, name = "Mabel St" }
    end
    local rows = RT.saveIssues(0, line, { "snap", "snap" })
    check(#rows == 2 and rows[1].kind == "endGap" and rows[1].e == 1 and rows[1].dist == 12 and rows[1].y == 12
        and rows[2].kind == "endOk", "I1 30 格內沒接上＝注意（附接上點），貼著道路＝已接上")
    rows = RT.saveIssues(0, line, { "free", "snap" })
    check(#rows == 1 and rows[1].e == 2, "I2 標成不接道路的一端不提醒")
    nearest = function(pn, x, y, maxDist) if maxDist >= 31 then return { x = 0, y = 31, dist = 31 } end end
    rows = RT.saveIssues(0, line, { "snap", "snap" })
    check(#rows == 0, "I3 30 格內沒有路不提醒")
    nearest = function() return { x = 0, y = 31, dist = 31 } end -- 不照 maxDist 的實作也擋得住
    rows = RT.saveIssues(0, line, { "snap", "snap" })
    check(#rows == 0, "I3b 回來的路超過 30 格照樣不提醒")
    nearest = nil
    -- 急彎：轉向約 120 度要提醒，90 度與直行不提醒
    local zig = { 0, 0, 10, 0, 5, 8.66, 5, 20, 5, 30 }
    local sharp = RT.sharpTurns(zig)
    check(#sharp == 1 and sharp[1].i == 2 and math.abs(sharp[1].deg - 120) < 1, "I4 約 120 度的轉角是急彎")
    check(#RT.sharpTurns({ 0, 0, 10, 0, 10, 10 }) == 0, "I5 直角不算急彎")
    rows = RT.saveIssues(0, zig, { "snap", "snap" })
    check(#rows == 1 and rows[1].kind == "sharp", "I6 急彎進提醒列")
    -- 建築：資料還沒掃完寫「檢查中」；穿過才算、貼牆不算
    MinidoracatMiniMapResourceAPI = { buildingsIn = function() return nil, "pending" end }
    rows = RT.saveIssues(0, line, { "snap", "snap" })
    check(#rows == 1 and rows[1].kind == "buildingsPending", "I7 房間資料未就緒寫建築檢查中")
    MinidoracatMiniMapResourceAPI = { buildingsIn = function()
        return { { x = 40, y = -5, w = 10, h = 10 }, { x = 60, y = 0, w = 5, h = 5 } }, 2
    end }
    rows = RT.saveIssues(0, line, { "snap", "snap" })
    check(#rows == 1 and rows[1].kind == "buildings" and rows[1].count == 1, "I8 穿過的建築才算（沿牆邊走過不算）")
    MinidoracatMiniMapResourceAPI = nil
end

--------------------------------------------------------------------------------
-- F. 離開時草稿留著；存好或沒動過不留
--------------------------------------------------------------------------------
do
    local t = newTool()
    click(t, 10, 10); click(t, 20, 30)
    symbolsUI:setCurrentTool(nil) -- Esc／手把 B／關地圖都走原版 setCurrentTool(nil)
    check(#drafts == 1 and drafts[1].pts[3] == 20 and drafts[1].source == "draw", "F1 離開時畫到一半的線存成草稿")
    reset()
    store.r9 = { id = "r9", name = "Back", pts = { 0, 0, 10, 0, 20, 0 }, segWidth = { 4, 4 },
        segSurface = { "dirt", "dirt" }, ends = { "snap", "free" }, source = "draw", enabled = true, rev = 2, sid = "s1" }
    t = newTool({ mode = "edit", roadId = "r9" })
    symbolsUI:setCurrentTool(nil)
    check(#drafts == 0, "F2 編輯沒改就離開不留草稿")
    t = newTool({ mode = "edit", roadId = "r9" })
    t:deletePoint(2)
    symbolsUI:setCurrentTool(nil)
    check(#drafts == 1 and drafts[1].roadId == "r9" and #drafts[1].segWidth == 1, "F3 改了形狀離開：草稿記著是哪條路")
    reset()
    t = newTool({ mode = "review", draft = { pts = { 0, 0, 5, 5 }, segWidth = { 5 }, segSurface = { "gravel" },
        measured = { false }, ends = { "snap", "snap" }, source = "record" } })
    symbolsUI:setCurrentTool(nil)
    check(#drafts == 1 and drafts[1].source == "record", "F4 錄好的路沒動就離開也留著（唯一一份）")
    reset()
    t = newTool()
    click(t, 10, 10); click(t, 20, 10)
    RT.saveFromForm(t, { roadSurface = "dirt", roadWidth = 4 })
    check(#saved == 1 and #drafts == 0 and symbolsUI.currentTool == nil, "F5 存好就離開工具、不留草稿")
    reset()
end

--------------------------------------------------------------------------------
-- R. 存出去的路 RoadData 收得下：0.5 格、沒有零長度段、每段資料恰好 n-1 筆、編輯保留原本欄位
--------------------------------------------------------------------------------
do
    local t = newTool()
    t.pts = { 10.2, 10, 10.1, 10.1, 20, 10, 30.74, 10 } -- 前兩點四捨五入後重合
    local road = RT.buildRoad(t, "", "gravel", 6)
    check(#road.pts == 6 and road.pts[5] == 30.5 and #road.segWidth == 2 and #road.segSurface == 2
        and road.segWidth[1] == 6 and road.segSurface[2] == "gravel", "R1 重合的點合併、座標進 0.5 格、每段資料 n-1 筆")
    reset()
    t = newTool({ mode = "review", draft = { pts = { 0, 0, 10, 0, 20, 0 }, segWidth = { 5, 7 },
        segSurface = { "gravel", "dirt" }, measured = { true, false }, ends = { "snap", "snap" }, source = "record" } })
    local s, w, rec = RT.formDefaults(t)
    check(s == "recorded" and w == "recorded" and rec, "R2 錄的路預設「依錄製」")
    local k = t:insertMid(2)
    check(k == 3 and #t.segW == 3 and t.segW[3] == 7 and t.segS[2] == "dirt", "R3 中段加點：那段的資料複製一份")
    t:deletePoint(2)
    road = RT.buildRoad(t, "x", "recorded", "recorded")
    check(#road.pts == 6 and #road.segWidth == 2 and road.segWidth[1] == 5 and road.segWidth[2] == 7,
        "R4 刪點合併兩段、依錄製保留逐段路寬")
    reset()
    t = newTool({ mode = "edit", roadId = "r9" })
    road = RT.buildRoad(t, "New", "paved", 8)
    check(road.id == "r9" and road.sid == "s1" and road.rev == 2 and road.ends[2] == "free" and road.enabled == true,
        "R5 編輯存檔保留 id、sid、版本與接法")
    reset()
end

--------------------------------------------------------------------------------
-- C. 捨棄要先確認：兩點以上先跳確認（預設焦點在取消、B＝取消），按取消什麼都不丟；0-1 點直接捨棄
--------------------------------------------------------------------------------
do
    local t = newTool({ mode = "review", draft = { pts = { 0, 0, 10, 0, 20, 0 }, segWidth = { 5, 5 },
        segSurface = { "dirt", "dirt" }, ends = { "snap", "snap" }, source = "record" } })
    t:finish()
    local c = RT.confirmDiscard(t)
    check(c and c.shown and symbolsUI.currentTool == t and t.form ~= nil, "C1 錄好的路按捨棄先跳確認，什麼都還沒丟")
    local row = c.joypadButtonsY[1]
    check(c.buttonB == row[1] and row[1].title == "UI_Cancel" and row[2].title == "UI_MinidoracatMiniMap_RoadDraftDiscard",
        "C2 第一顆（預設焦點）是取消、B＝取消、確認鈕寫明捨棄")
    row[1].onclick(c)
    check(not c.shown and symbolsUI.currentTool == t and t.form ~= nil, "C3 按取消回到存檔表單")
    c = RT.confirmDiscard(t)
    c.joypadButtonsY[1][2].onclick(c)
    local cleared = false
    for _, v in ipairs(calls) do if v == "clearDraft" then cleared = true end end
    check(symbolsUI.currentTool == nil and #drafts == 0 and cleared, "C4 確認捨棄才清草稿並離開工具")
    reset()
    t = newTool()
    click(t, 10, 10)
    check(RT.confirmDiscard(t) == nil and symbolsUI.currentTool == nil, "C5 只有一點直接捨棄、不跳確認")
    reset()
end

--------------------------------------------------------------------------------
-- E. 編輯既有的路：吸附與存檔表單「接上」的路網查詢都跳過這條路自己（不吸回舊形狀）；新畫的路不跳
--------------------------------------------------------------------------------
local function nearSkips()
    local out = {}
    for _, v in ipairs(calls) do
        local s = v:match("^near:(.*)$")
        if s then out[#out + 1] = s end
    end
    return out
end
do
    store.r9 = { id = "r9", name = "Back", pts = { 0, 0, 10, 0, 20, 0 }, segWidth = { 4, 4 },
        segSurface = { "dirt", "dirt" }, ends = { "snap", "snap" }, source = "draw", enabled = true, rev = 2 }
    local t = newTool({ mode = "edit", roadId = "r9" })
    t:setPoint(3, 25, 3) -- 拖終點（端點才吸附）
    realOpenForm(t)
    local skips = nearSkips()
    local allSkip = #skips >= 3
    for _, s in ipairs(skips) do if s ~= "r9" then allSkip = false end end
    check(allSkip, "E1 編輯時吸附與存檔表單兩端的查詢都帶 skipRoadId（實得 " .. table.concat(skips, ",", 1, #skips) .. "）")
    -- 路寬路面另存欄位：width 是面板寬度，蓋成 4 或 "recorded" 時表單底色只畫幾 px／drawRect 每幀出錯
    local f = t.form
    check(f ~= nil and type(f.width) == "number" and f.width >= 360 and f.roadWidth == 4 and f.roadSurface == "dirt",
        "E1b 表單的路寬、路面另存欄位，面板寬度不被蓋掉（width=" .. tostring(f and f.width) .. "）")
    reset()
    t = newTool({ mode = "review", draft = { pts = { 0, 0, 10, 0 }, ends = { "snap", "snap" }, source = "draw",
        roadId = "r9" } })
    t:setPoint(2, 12, 0)
    skips = nearSkips()
    check(t.mode == "edit" and skips[1] == "r9", "E2 繼續編輯既有路的草稿也跳過那條路")
    reset()
    t = newTool()
    click(t, 10, 10)
    realOpenForm(t)
    skips = nearSkips()
    check(#skips >= 1 and skips[1] == "nil", "E3 新畫的路不跳過任何路")
    reset()
end

-- E1d-E1e: 「建築檢查中」那一列在房間資料掃完後原地換成結果，不重建表單（打到一半的名稱不會被清掉）；
-- 拿掉 RT.refreshPending 或 openForm 沒記 pendingRow，那一列就永遠停在檢查中（2026-10-23 RU 實機截圖）
do
    local clock = 0
    getTimestampMs = function() return clock end
    MinidoracatMiniMapResourceAPI = { buildingsIn = function() return nil, "pending" end }
    local t = newTool()
    click(t, 10, 10); click(t, 60, 10)
    realOpenForm(t)
    local f = t.form
    local row = f and f.pendingRow and f.rows[f.pendingRow]
    check(row ~= nil and row.text == "UI_MinidoracatMiniMap_RoadIssueBuildingsPending",
        "E1d 房間資料還沒掃完時表單列「建築檢查中」")
    MinidoracatMiniMapResourceAPI = { buildingsIn = function() return { { x = 30, y = 5, w = 10, h = 10 } }, 1 end }
    RT.refreshPending(f)
    check(f.pendingRow == nil and row and row.text == "UI_MinidoracatMiniMap_RoadIssueBuildings|1" and not row.good,
        "E1d 掃完就原地換成穿過的棟數")
    MinidoracatMiniMapResourceAPI = { buildingsIn = function() return nil, "pending" end }
    realOpenForm(t)
    f = t.form
    row = f.pendingRow and f.rows[f.pendingRow]
    clock = 1000
    MinidoracatMiniMapResourceAPI = { buildingsIn = function() return {}, 0 end }
    RT.refreshPending(f)
    check(f.pendingRow == nil and row and row.hidden == true, "E1e 沒穿過建築就收起「檢查中」那一列")
    MinidoracatMiniMapResourceAPI, getTimestampMs = nil, nil
    reset()
end

-- E4-E6: 收到的路的右鍵子選單照命中結果的停用狀態列「用於導航」或「不用於導航」，點了切到相反狀態
do
    local function menuFor(hit)
        local m = { options = {} }
        function m:addOption(name, target, fn, a, b)
            local o = { name = name, target = target, fn = fn, a = a, b = b }
            self.options[#self.options + 1] = o
            return o
        end
        Core.roadsMapMenu(m, 0, hit)
        return m.options[1]
    end
    local o = menuFor({ kind = "received", off = true, road = { sid = "s5", name = "Mine" } })
    check(o.name == "UI_MinidoracatMiniMap_RoadNavOn" and o.a == "s5" and o.b == false,
        "E4 收到的路已停用（hit.off）：列「用於導航」，點了取消停用")
    o = menuFor({ kind = "received", road = { sid = "s5", name = "Mine" } })
    check(o.name == "UI_MinidoracatMiniMap_RoadNavOff" and o.b == true, "E5 沒有停用資訊＝當作沒停用")
    o = menuFor({ kind = "received", off = false, road = { sid = "s5", name = "Mine", off = true } })
    check(o.name == "UI_MinidoracatMiniMap_RoadNavOff", "E6 命中結果的狀態優先於道路物件上的舊欄位")
end

--------------------------------------------------------------------------------
-- P. 錄得太長分成幾段：存好第一段接著開下一段
--------------------------------------------------------------------------------
do
    local part = function(x) return { pts = { x, 0, x + 10, 0 }, segWidth = { 5 }, segSurface = { "dirt" },
        ends = { "snap", "snap" }, source = "record" } end
    local d1 = part(0)
    d1.parts, d1.part, d1.partCount = { part(10), part(20) }, 1, 3
    local t = newTool({ mode = "review", draft = d1 })
    RT.saveFromForm(t, { roadSurface = "recorded", roadWidth = "recorded" })
    local nextTool = symbolsUI.currentTool
    check(nextTool and nextTool ~= t and nextTool.pts[1] == 10 and nextTool.parts and #nextTool.parts == 1,
        "P1 存好第一段後開第二段，剩下的段跟著走")
    nextTool:finish()
    local c = RT.confirmDiscard(nextTool)
    c.joypadButtonsY[1][2].onclick(c)
    local third = symbolsUI.currentTool
    check(third and third.pts[1] == 20 and third.parts == nil, "P2 捨棄第二段也接著開最後一段")
    reset()
end

print(("test_road_tool: %d checks, %d failures"):format(total, failures))
if failures > 0 then os.exit(1) end
print("test_road_tool: PASS (drag D1-D3, undo U1-U4, point menu M1-M8, snap S1-S5, issues I1-I8, draft F1-F5, "
    .. "road shape R1-R5, discard confirm C1-C5, edit skip/received menu E1-E6, parts P1-P2)")
