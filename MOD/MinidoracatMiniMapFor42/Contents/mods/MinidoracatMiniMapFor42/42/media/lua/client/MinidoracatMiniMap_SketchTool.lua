-- MinidoracatMiniMap_SketchTool.lua
-- 本檔範圍：世界地圖的手繪工具（筆、直線、橡皮擦、復原／重做、清除全部）、工具列、手把 X 的手繪選單、
-- Core.sketchToolStart（按鈕列筆鈕）與 Core.sketchToolDraw（正在畫的那一筆、橡皮擦圈）。
-- 工具掛在原版地圖符號面板的工具槽（ISWorldMapSymbols:setCurrentTool，ISWorldMapSymbols.lua:1431-1441），
-- 同 _RoadTool.lua：滑鼠、鍵盤、手把 A／B 由原版路由進來（ISWorldMap.lua:825-910、1203-1215、1343-1360），
-- Esc 與 B 由原版關工具＝deactivate（畫到一半的那筆存起來、立刻寫檔）。onMouseDown 回 true＝地圖不平移
-- （ISWorldMap.lua:830-832）；右鍵拖曳照原版平移公式（:856-858）呼叫 centerOn，右鍵點一下＝復原。
-- 筆照原版（2026-11-08 使用者裁定）：畫要筆或鉛筆、顏色只能選身上有的筆（判定同 ISWorldMapSymbols:checkInventory，
-- :1310-1330；全都沒有但 canWrite 為真時同原版用黑色），擦要橡皮擦（symbolsUI:canErase，:1412-1416）；
-- 復原、重做不用物品。原版 checkInventory 只關原版自己的工具（:1381-1398），所以本工具下筆時自己檢查、
-- 工具列每 INV_EVERY 幀刷新一次。資料一律走 _Sketch.lua（Core.Sketch）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.sketchToolStart then return end
if not (ISWorldMapSymbolTool and ISWorldMapSymbolTool.derive) then return end

local ST = {
    SAMPLE_PX = 2,    -- 拖曳每移動幾 px 取一點
    SIMPLIFY_PX = 0.5, -- 停筆時抽點容差（畫的那個縮放下的 px）
    ERASER_PX = 10,   -- 橡皮擦半徑（畫面 px）
    PAN_PX = 4,       -- 右鍵拖曳門檻（同原版 ISWorldMap.lua:849）
    UNDO_MAX = 50,
    INV_EVERY = 30,   -- 每幾幀重查身上的筆與橡皮擦
    prefs = {},       -- [pn] = { mode, c, w, share }：只記在記憶體，每次遊戲重來（分享預設私人）
    COLOR_TIPS = { "Tooltip_Map_NeedBlackPen", "Tooltip_Map_NeedPencil", "Tooltip_Map_NeedRedPen",
        "Tooltip_Map_NeedBluePen", "Tooltip_Map_NeedGreenPen" },
    MODE_KEYS = { pen = "UI_MinidoracatMiniMap_SketchPen", line = "UI_MinidoracatMiniMap_SketchLine",
        erase = "UI_MinidoracatMiniMap_SketchEraser" },
    WIDTH_KEYS = { "UI_MinidoracatMiniMap_SketchThin", "UI_MinidoracatMiniMap_SketchMedium",
        "UI_MinidoracatMiniMap_SketchThick" },
}
Core.SketchTool = ST
local Tool = ISWorldMapSymbolTool:derive("MinidoracatSketchTool")
ST.Tool = Tool

local function SK() return Core.Sketch end

function ST.say(pn, key, ...)
    if Core.navMessage then Core.navMessage(pn or 0, getText(key, ...), false) end
end
-- 資料層拒絕的原因 → 提示（noplayer／empty 不說）
function ST.sayWhy(pn, why)
    local C = MinidoracatMiniMapSketchCodec
    if why == "full" then
        ST.say(pn, "UI_MinidoracatMiniMap_SketchFull", string.format("%d", C.DRAW_STROKES), string.format("%d", C.DRAW_POINTS))
    elseif why == "readonly" or why == "loading" then
        ST.say(pn, "UI_MinidoracatMiniMap_Sketch_" .. why)
    end
end

function ST.prefsOf(pn)
    local p = ST.prefs[pn]
    if not p then
        p = { mode = "pen", c = 1, w = 2, share = false }
        ST.prefs[pn] = p
    end
    return p
end

--------------------------------------------------------------------------------
-- 身上的筆與橡皮擦（原版寫法：containsTagRecurse(物品 tag) 或 containsTypeRecurse(物品)）
--------------------------------------------------------------------------------
function ST.hasItem(inv, item)
    if inv == nil then return true end
    local ok, tagged = pcall(function() return inv:containsTagRecurse(ItemTag.get(ResourceLocation.of(item))) end)
    return (ok and tagged) or inv:containsTypeRecurse(item)
end
-- 回 { canWrite, canErase, have[1..5] }；選的顏色身上沒有就換成第一個有的（同原版 checkInventory）
function Tool:refreshInv()
    local sym = self.symbolsUI
    local player = getSpecificPlayer(self.pn)
    local inv = player and player:getInventory() or nil
    local items = SK().ITEMS
    local have, any = {}, false
    for i = 1, #items do
        have[i] = ST.hasItem(inv, items[i])
        any = any or have[i]
    end
    local canWrite = any
    if sym and sym.canWrite then canWrite = sym:canWrite() == true end
    if canWrite and not any then have[1] = true end
    local canErase = inv == nil or inv:containsTypeRecurse("Base.Eraser")
    if sym and sym.canErase then canErase = sym:canErase() == true end
    local P = self.prefs
    if canWrite and not have[P.c] then
        for i = 1, #items do
            if have[i] then
                P.c = i
                break
            end
        end
    end
    self.inv = { canWrite = canWrite, canErase = canErase, have = have }
    return self.inv
end

--------------------------------------------------------------------------------
-- 工具狀態
--------------------------------------------------------------------------------
function Tool:new(symbolsUI)
    local o = ISWorldMapSymbolTool.new(self, symbolsUI)
    o.undoStack, o.redoStack = {}, {}
    return o
end

function Tool:toWorld(x, y)
    return self.mapAPI:uiToWorldX(x, y), self.mapAPI:uiToWorldY(x, y)
end
function Tool:scale()
    local s = self.mapAPI:getWorldScale()
    return (s and s > 0) and s or 1
end
function Tool:center()
    return self.mapUI.width / 2, self.mapUI.height / 2
end
-- 手把模式：準星在畫面中央（同 _RoadTool.lua Tool:isJoypad；分割畫面 pn≠0 一律手把）
function Tool:isJoypad()
    local pn = self.pn or 0
    return pn ~= 0 or (JoypadState and JoypadState.players[pn + 1] ~= nil
        and not (wasMouseActiveMoreRecentlyThanJoypad and wasMouseActiveMoreRecentlyThanJoypad()))
end
function Tool:cursor()
    if self:isJoypad() then return self:center() end
    return self:getMouseX(), self:getMouseY()
end

-- 一步改動：rem／add＝以 id 為鍵的表（同一次拖曳擦除合成一步：剛切出又被擦掉的片段兩邊抵銷）
function ST.newOp() return { rem = {}, add = {} } end
function ST.arr(map)
    local out, n = {}, 0
    for _, s in pairs(map) do
        n = n + 1
        out[n] = s
    end
    return out, n
end
function ST.opEmpty(op)
    for _ in pairs(op.rem) do return false end
    for _ in pairs(op.add) do return false end
    return true
end
function ST.opMerge(op, rem, nr, add, na)
    for k = 1, nr do
        local s = rem[k]
        if op.add[s.id] then op.add[s.id] = nil else op.rem[s.id] = s end
    end
    for k = 1, na do op.add[add[k].id] = add[k] end
end
function Tool:pushOp(op)
    if not op or ST.opEmpty(op) then return end
    local u = self.undoStack
    u[#u + 1] = op
    if #u > ST.UNDO_MAX then table.remove(u, 1) end
    self.redoStack = {}
end
-- 復原＝拿掉這一步加的、加回這一步拿掉的；重做反過來。資料層拒絕（只讀、超過硬上限）就留在原堆疊
function Tool:replay(from, to, undo)
    local op = from[#from]
    if not op then return false end
    local add, na = ST.arr(op.add)
    local rem, nr = ST.arr(op.rem)
    local ok, why
    if undo then ok, why = SK().apply(self.pn, add, na, rem, nr) else ok, why = SK().apply(self.pn, rem, nr, add, na) end
    if not ok then
        ST.sayWhy(self.pn, why)
        return false
    end
    from[#from] = nil
    to[#to + 1] = op
    return true
end
function Tool:undo()
    if self.cur or self.erasing then return false end
    return self:replay(self.undoStack, self.redoStack, true)
end
function Tool:redo()
    if self.cur or self.erasing then return false end
    return self:replay(self.redoStack, self.undoStack, false)
end
-- 清除全部（自己的）：也算一步，可以復原。擦要橡皮擦（2026-11-08 使用者裁定），工具列與手把選單都走這裡、當下重查
function Tool:clearAll()
    local slot = SK().slots[self.pn]
    local store = slot and slot.store
    if not store or store.count == 0 then return false end
    if not self:refreshInv().canErase then
        ST.say(self.pn, "Tooltip_Map_CantErase")
        return false
    end
    local rem, n = {}, store.count
    for i = 1, n do rem[i] = store.strokes[i] end
    local ok, why = SK().apply(self.pn, rem, n, {}, 0)
    if not ok then
        ST.sayWhy(self.pn, why)
        return false
    end
    local op = ST.newOp()
    ST.opMerge(op, rem, n, {}, 0)
    self:pushOp(op)
    return true
end

--------------------------------------------------------------------------------
-- 下筆、拖曳、停筆（滑鼠與手把共用；x, y＝地圖元件座標）
--------------------------------------------------------------------------------
function Tool:begin(x, y)
    local P, inv = self.prefs, self.inv or self:refreshInv()
    local _, why = SK().writable(self.pn)
    if why then
        ST.sayWhy(self.pn, why)
        return false
    end
    local wx, wy = self:toWorld(x, y)
    if P.mode == "erase" then
        if not inv.canErase then
            ST.say(self.pn, "Tooltip_Map_CantErase")
            return false
        end
        self.erasing, self.op = true, ST.newOp()
        self.lastX, self.lastY = wx, wy
        self:eraseAt(wx, wy)
        return true
    end
    if not inv.canWrite then
        ST.say(self.pn, "UI_MinidoracatMiniMap_SketchNeedPen")
        return false
    end
    if not inv.have[P.c] then
        ST.say(self.pn, ST.COLOR_TIPS[P.c])
        return false
    end
    self.cur = { pts = { wx, wy }, np = 1, line = P.mode == "line" }
    self.lastX, self.lastY = wx, wy
    return true
end

function Tool:eraseAt(wx, wy)
    local pn = self.pn
    local rem, nr, add, na = SK().eraseAt(pn, wx, wy, ST.ERASER_PX / self:scale())
    if not rem or nr == 0 then return end
    local ok, why = SK().apply(pn, rem, nr, add, na)
    if not ok then
        ST.sayWhy(pn, why)
        return
    end
    ST.opMerge(self.op, rem, nr, add, na)
end

function Tool:extend(x, y)
    local wx, wy = self:toWorld(x, y)
    local s = self:scale()
    local dx, dy = (wx - self.lastX) * s, (wy - self.lastY) * s
    if self.erasing then
        -- 移動太快時沿路每半個半徑擦一次，不跳過中間
        local d = math.sqrt(dx * dx + dy * dy)
        if d < 1 then return end
        local steps = math.ceil(d / (ST.ERASER_PX / 2))
        local lx, ly = self.lastX, self.lastY
        for k = 1, steps do
            self:eraseAt(lx + (wx - lx) * k / steps, ly + (wy - ly) * k / steps)
        end
        self.lastX, self.lastY = wx, wy
        return
    end
    local cur = self.cur
    if not cur then return end
    if cur.line or (isShiftKeyDown and isShiftKeyDown()) then
        -- 直線：只留起點與目前這一點
        cur.np = 2
        cur.pts[3], cur.pts[4] = wx, wy
        return
    end
    if dx * dx + dy * dy < ST.SAMPLE_PX * ST.SAMPLE_PX then return end
    local n = cur.np + 1
    cur.pts[n * 2 - 1], cur.pts[n * 2] = wx, wy
    cur.np = n
    self.lastX, self.lastY = wx, wy
    -- 每筆最多 MAX_STROKE_PTS 點：先存一段，從最後一點接著畫，畫的過程不中斷
    if n >= MinidoracatMiniMapSketchCodec.MAX_STROKE_PTS then
        self:commit(cur.pts, n)
        self.cur = { pts = { wx, wy }, np = 1 }
    end
end

function Tool:finishStroke()
    if self.erasing then
        self.erasing = false
        self:pushOp(self.op)
        self.op = nil
        return
    end
    local cur = self.cur
    self.cur = nil
    if cur then self:commit(cur.pts, cur.np) end
end

-- 停筆：在畫的縮放下抽掉不到 SIMPLIFY_PX 的點（RD.buildLevels 第 2 層），存成一筆、記一步
function Tool:commit(pts, np)
    local pn, P = self.pn, self.prefs
    local RD = Core.RoadDraw
    if np > 2 and RD and RD.buildLevels then
        local tol = ST.SIMPLIFY_PX / self:scale()
        local lv = RD.buildLevels(pts, np, nil, nil, tol)
        local pick = lv[2] and lv[2].tol <= tol and lv[2] or nil
        if pick then
            local out, m = {}, #pick
            for j = 1, m do
                local i = pick[j]
                out[j * 2 - 1], out[j * 2] = pts[i * 2 - 1], pts[i * 2]
            end
            pts, np = out, m
        end
    end
    local z = math.floor(self.mapAPI:getZoomF() + 0.5)
    if z < 1 then z = 1 elseif z > MinidoracatMiniMapSketchCodec.MAX_Z then z = MinidoracatMiniMapSketchCodec.MAX_Z end
    local share = P.share and Core.sketchShareAvailable ~= nil and Core.sketchShareAvailable(pn) == true
    if share and Core.sketchShareRoom and not Core.sketchShareRoom(pn, np) then
        share = false
        ST.say(pn, "UI_MinidoracatMiniMap_SketchShareFull")
    end
    local s, why = SK().newStroke(pn, { c = P.c, w = P.w, z = z, share = share }, pts, np)
    if not s then
        ST.sayWhy(pn, why)
        return false
    end
    local ok
    ok, why = SK().apply(pn, {}, 0, { s }, 1)
    if not ok then
        ST.sayWhy(pn, why)
        return false
    end
    local op = ST.newOp()
    op.add[s.id] = s
    self:pushOp(op)
    return true
end

--------------------------------------------------------------------------------
-- 輸入（原版經 ISWorldMapSymbols 轉來；回 true＝原版不再處理）
--------------------------------------------------------------------------------
function Tool:onMouseDown(x, y)
    ISWorldMapSymbolTool.onMouseDown(self, x, y)
    self:refreshInv()
    self:begin(x, y)
    return true -- 不論能不能畫，左鍵都不拿來平移（右鍵拖曳才平移）
end

function Tool:onMouseMove(dx, dy)
    local r = self.rdrag
    if r then
        if isMouseButtonDown and not isMouseButtonDown(1) then
            self.rdrag = nil
        else
            local x, y = self:getMouseX(), self:getMouseY()
            if not r.moved and (math.abs(x - r.x) > ST.PAN_PX or math.abs(y - r.y) > ST.PAN_PX) then r.moved = true end
            if r.moved then
                local api = self.mapAPI
                local wx = api:uiToWorldX(x, y, r.zoomF, r.cx, r.cy)
                local wy = api:uiToWorldY(x, y, r.zoomF, r.cx, r.cy)
                api:centerOn(r.cx + r.wx - wx, r.cy + r.wy - wy)
            end
            return true
        end
    end
    if self.cur or self.erasing then
        self:extend(self:getMouseX(), self:getMouseY())
        return true
    end
    return false
end

function Tool:onMouseUp(x, y)
    self.dragging = false
    if self.padDown then return false end
    if self.cur or self.erasing then
        self:finishStroke()
        return true
    end
    return false
end

function Tool:onRightMouseDown(x, y)
    local api = self.mapAPI
    self.rdrag = { x = x, y = y, cx = api:getCenterWorldX(), cy = api:getCenterWorldY(), zoomF = api:getZoomF(),
        wx = api:uiToWorldX(x, y), wy = api:uiToWorldY(x, y) }
    return true
end

function Tool:onRightMouseUp(x, y)
    local r = self.rdrag
    self.rdrag = nil
    if not (r and r.moved) then self:undo() end
    return true
end

function Tool:isKeyConsumed(key)
    return key == Keyboard.KEY_BACK
end

function Tool:onKeyRelease(key)
    if key == Keyboard.KEY_BACK then
        if isShiftKeyDown and isShiftKeyDown() then self:redo() else self:undo() end
        return true
    end
    return false -- Esc：原版關工具
end

-- 手把 A：下筆／停筆（下筆後隨搖桿捲動在準星取點）
function Tool:onJoypadDownInMap(button, joypadData)
    if button ~= Joypad.AButton then return end
    if self.padDown then
        self.padDown = false
        self:finishStroke()
        return
    end
    self:refreshInv()
    local cx, cy = self:center()
    self.padDown = self:begin(cx, cy) == true
end

function Tool:getJoypadAButtonText()
    return getText(self.padDown and "UI_MinidoracatMiniMap_SketchPadUp" or "UI_MinidoracatMiniMap_SketchPadDown")
end

-- 原版每幀在地圖 prerender 呼叫（ISWorldMap.lua:366 → ISWorldMapSymbols.lua:1459-1462）
function Tool:render()
    self.frame = (self.frame or 0) + 1
    if self.frame % ST.INV_EVERY == 0 then self:refreshInv() end
    if self.padDown then self:extend(self:center()) end
end

function Tool:activate()
    self:refreshInv()
    local ok, err = pcall(ST.makeBar, self)
    if not ok then print("[MinidoracatMiniMap] sketch tool bar failed: " .. tostring(err)) end
end

-- 原版關工具（Esc、手把 B、關地圖、按 S 收符號面板）都走這裡：畫到一半的那筆存起來、立刻寫檔
function Tool:deactivate()
    self.padDown, self.rdrag = false, nil
    self:finishStroke()
    if self.bar then
        self.bar:setVisible(false)
        if self.bar.parent then self.bar.parent:removeChild(self.bar) end
        self.bar = nil
    end
    if Core.sketchFlush then Core.sketchFlush(self.pn) end
end

function Tool:exit()
    local sym = self.symbolsUI
    if sym and sym.currentTool == self then sym:setCurrentTool(nil) end
end

function Tool:setMode(mode) self.prefs.mode = mode end
function Tool:setColor(c)
    if self.inv and self.inv.have[c] then self.prefs.c = c end
end
function Tool:setWidth(w) self.prefs.w = w end
function Tool:toggleShare()
    if Core.sketchShareAvailable and Core.sketchShareAvailable(self.pn) == true then
        self.prefs.share = not self.prefs.share
    end
end

--------------------------------------------------------------------------------
-- 工具列（地圖上方置中）：模式、五色、粗細／復原、重做、清除全部、分享（多人）、離開／兩行操作提示
--------------------------------------------------------------------------------
-- 工具列配色表只讀、不改：不用 ISButton:setEnable——它就地改寫 backgroundColor／borderColor 表（ISButton.lua:416-438），
-- 共用的 ON 表會被改成別顆的底色（2026-11-08 sketch-sp 實機：換到橡皮擦後所有選中的鈕都變黑），停用時底色也被塗黑、
-- 看不出是哪個顏色。這裡只設 btn.enable（停用時字變灰，ISButton.lua:250-257），顏色鈕自己換暗色表
local ON = { r = 0.29, g = 0.42, b = 0.56, a = 1 }
local OFF = { r = 0, g = 0, b = 0, a = 1 }
local SEL = { r = 1, g = 1, b = 1, a = 1 }
local UNSEL = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
local NOPEN = { r = 0.7, g = 0.1, b = 0.1, a = 0.7 }
local function setOn(btn, on)
    btn.backgroundColor = on and ON or OFF
end

function ST.shareTitle(on)
    return getText(on and "UI_MinidoracatMiniMap_SketchShareGroup" or "UI_MinidoracatMiniMap_SketchSharePrivate")
end

local function barPrerender(self)
    ISPanel.prerender(self)
    local tool = self.tool
    local P, inv = tool.prefs, tool.inv or tool:refreshInv()
    local b = self.btns
    for mode, btn in pairs(b.mode) do
        setOn(btn, P.mode == mode)
        local ok = mode == "erase" and inv.canErase or (mode ~= "erase" and inv.canWrite)
        btn.enable = ok == true
        btn.tooltip = not ok and getText(mode == "erase" and "Tooltip_Map_CantErase"
            or "UI_MinidoracatMiniMap_SketchNeedPen") or nil
    end
    for i = 1, #b.color do
        local btn = b.color[i]
        local have = inv.have[i] == true
        btn.enable = have
        btn.backgroundColor = have and btn.full or btn.dim
        btn.backgroundColorMouseOver = btn.backgroundColor
        btn.tooltip = not have and getText(ST.COLOR_TIPS[i]) or nil
        btn.borderColor = not have and NOPEN or (P.c == i and SEL or UNSEL)
    end
    for i = 1, #b.width do setOn(b.width[i], P.w == i) end
    b.undo.enable = #tool.undoStack > 0
    b.redo.enable = #tool.redoStack > 0
    local slot = Core.Sketch.slots[tool.pn]
    b.clear.enable = slot ~= nil and slot.store ~= nil and slot.store.count > 0 and inv.canErase == true
    b.clear.tooltip = not inv.canErase and getText("Tooltip_Map_CantErase") or nil
    if b.share then
        local avail, whyKey = false, nil
        if Core.sketchShareAvailable then avail, whyKey = Core.sketchShareAvailable(tool.pn) end
        local on = P.share and avail == true
        b.share:setTitle(ST.shareTitle(on))
        setOn(b.share, on)
        b.share.enable = avail == true
        b.share.tooltip = avail ~= true and whyKey and getText(whyKey) or getText("UI_MinidoracatMiniMap_SketchShare_tooltip")
    end
    local x = (self.parent.width - self.width) / 2
    if self.x ~= x then self:setX(x - x % 1) end
end

function ST.makeBar(tool)
    local map = tool.mapUI
    local tm = getTextManager()
    local fh = tm:getFontHeight(UIFont.Small)
    local bh = fh + 6
    local pad, gap = 6, 4
    local bar = ISPanel:new(0, 10, 100, 100)
    bar:initialise()
    bar.backgroundColor = { r = 0.07, g = 0.07, b = 0.07, a = 0.92 }
    bar.borderColor = { r = 0.27, g = 0.27, b = 0.27, a = 1 }
    bar.tool = tool
    local btns = { mode = {}, color = {}, width = {} }
    bar.btns = btns
    local x, y, rowW = pad, pad, 0
    local function add(label, fn, w)
        w = w or (tm:MeasureStringX(UIFont.Small, label) + 16)
        local b = ISButton:new(x, y, w, bh, label, bar, fn)
        b:initialise()
        bar:addChild(b)
        x = x + w + gap
        if x > rowW then rowW = x end
        return b
    end
    local function space() x = x + 8 end
    for _, mode in ipairs({ "pen", "line", "erase" }) do
        btns.mode[mode] = add(getText(ST.MODE_KEYS[mode]), function() tool:setMode(mode) end)
    end
    space()
    local colors = Core.Sketch.COLORS
    for i = 1, #colors do
        local b = add("", function() tool:setColor(i) end, bh)
        local c = colors[i]
        -- 身上沒有這支筆：同一色、透明度 0.35（看得出是哪色、又明顯是停用），框線換成原版停用的紅框
        b.full, b.dim = { r = c.r, g = c.g, b = c.b, a = 1 }, { r = c.r, g = c.g, b = c.b, a = 0.35 }
        b.backgroundColor, b.backgroundColorMouseOver = b.full, b.full
        btns.color[i] = b
    end
    space()
    for i = 1, 3 do btns.width[i] = add(getText(ST.WIDTH_KEYS[i]), function() tool:setWidth(i) end) end
    x, y = pad, y + bh + gap
    btns.undo = add(getText("UI_MinidoracatMiniMap_SketchUndo"), function() tool:undo() end)
    btns.redo = add(getText("UI_MinidoracatMiniMap_SketchRedo"), function() tool:redo() end)
    btns.clear = add(getText("UI_MinidoracatMiniMap_SketchClear"), function() tool:clearAll() end)
    if isClient() then
        local w = math.max(tm:MeasureStringX(UIFont.Small, ST.shareTitle(false)),
            tm:MeasureStringX(UIFont.Small, ST.shareTitle(true))) + 16
        btns.share = add(ST.shareTitle(false), function() tool:toggleShare() end, w)
    end
    btns.exit = add(getText("UI_MinidoracatMiniMap_SketchExit"), function() tool:exit() end)
    btns.exit.borderColor = { r = 0.85, g = 0.71, b = 0.35, a = 1 }
    local hints = { getText("UI_MinidoracatMiniMap_SketchHint"), getText("UI_MinidoracatMiniMap_SketchHintPad") }
    local hintY = y + bh + gap + 2
    local w = rowW + pad - gap
    for k = 1, #hints do
        local hw = tm:MeasureStringX(UIFont.Small, hints[k]) + pad * 2
        if hw > w then w = hw end
    end
    if w > map.width - 20 then w = map.width - 20 end
    bar:setWidth(w)
    bar:setHeight(hintY + #hints * (fh + 2) + 4)
    bar:setX((map.width - w) / 2)
    bar.hints, bar.hintY, bar.fontH = hints, hintY, fh
    bar.prerender = barPrerender
    function bar:render()
        for k = 1, #self.hints do
            self:drawText(self.hints[k], pad, self.hintY + (k - 1) * (self.fontH + 2), 0.9, 0.9, 0.9, 1, UIFont.Small)
        end
    end
    map:addChild(bar)
    tool.bar = bar
end

--------------------------------------------------------------------------------
-- 手把 X：手繪選單（_WorldMapNav.lua 的 ISWorldMap.onJoypadDown 包裝只在本工具作用中時轉來）
--------------------------------------------------------------------------------
function ST.menuDo(tool, op, arg)
    if op == "mode" then tool:setMode(arg)
    elseif op == "color" then tool:setColor(arg)
    elseif op == "width" then tool:setWidth(arg)
    elseif op == "undo" then tool:undo()
    elseif op == "redo" then tool:redo()
    elseif op == "clear" then tool:clearAll()
    elseif op == "share" then tool:toggleShare()
    elseif op == "exit" then tool:exit()
    end
end
-- 回選單的項目 { text, op, arg, off（灰掉的原因文字） }（離線測試直接看）
function ST.menuItems(tool)
    local inv, P = tool.inv or tool:refreshInv(), tool.prefs
    local items = {}
    local function add(text, op, arg, off) items[#items + 1] = { text = text, op = op, arg = arg, off = off } end
    for _, mode in ipairs({ "pen", "line", "erase" }) do
        local off
        if mode == "erase" and not inv.canErase then off = getText("Tooltip_Map_CantErase") end
        if mode ~= "erase" and not inv.canWrite then off = getText("UI_MinidoracatMiniMap_SketchNeedPen") end
        add(getText(ST.MODE_KEYS[mode]), "mode", mode, off)
    end
    for i = 1, #Core.Sketch.COLORS do
        add(getText("UI_MinidoracatMiniMap_SketchColor" .. i), "color", i, not inv.have[i] and getText(ST.COLOR_TIPS[i]) or nil)
    end
    for i = 1, 3 do add(getText(ST.WIDTH_KEYS[i]), "width", i) end
    add(getText("UI_MinidoracatMiniMap_SketchUndo"), "undo", nil, #tool.undoStack == 0 and "" or nil)
    add(getText("UI_MinidoracatMiniMap_SketchRedo"), "redo", nil, #tool.redoStack == 0 and "" or nil)
    add(getText("UI_MinidoracatMiniMap_SketchClear"), "clear", nil, not inv.canErase and getText("Tooltip_Map_CantErase") or nil)
    if isClient() then
        local avail, whyKey = false, nil
        if Core.sketchShareAvailable then avail, whyKey = Core.sketchShareAvailable(tool.pn) end
        add(ST.shareTitle(P.share and avail == true), "share", nil, avail ~= true and whyKey and getText(whyKey) or nil)
    end
    add(getText("UI_MinidoracatMiniMap_SketchExit"), "exit")
    return items
end
Core.sketchPadMenu = function(map, joypadData)
    local tool = Core.sketchToolOf(map)
    if not tool then return false end
    if tool.padDown then
        tool.padDown = false
        tool:finishStroke()
    end
    local pn = tool.pn or 0
    local cx, cy = tool:center()
    local menu = ISContextMenu.get(pn, cx + map:getAbsoluteX(), cy + map:getAbsoluteY())
    if not menu then return false end
    local items = ST.menuItems(tool)
    for k = 1, #items do
        local it = items[k]
        local opt = menu:addOption(it.text, tool, ST.menuDo, it.op, it.arg)
        if it.off then
            opt.notAvailable = true
            if it.off ~= "" and Core.navMenuLock then Core.navMenuLock(opt, it.off) end
        end
    end
    if JoypadState and JoypadState.players[pn + 1] then
        menu.origin = map
        menu.mouseOver = 1
        setJoypadFocus(pn, menu)
    end
    return true
end

--------------------------------------------------------------------------------
-- 地圖上的工具畫面（_WorldMapNav.lua 世界地圖 prerender 在導航之後呼叫）：正在畫的那一筆、橡皮擦圈
--------------------------------------------------------------------------------
Core.sketchToolOf = function(map)
    local sym = map and map.symbolsUI
    local tool = sym and sym.currentTool
    if tool and getmetatable(tool) == Tool then return tool end
    return nil
end

function Tool:drawOverlay()
    local map, api = self.mapUI, self.mapAPI
    local cur = self.cur
    if cur then
        local SKm = SK()
        local col = SKm.COLORS[self.prefs.c] or SKm.COLORS[1]
        local hw = (SKm.WPX[self.prefs.w] or 4) / 2
        local acx, acy = math.floor(cur.pts[1]), math.floor(cur.pts[2])
        local p0x, p0y, sxx, sxy, syx, syy = Core.deriveAffine(api, acx, acy)
        local jo = map.javaObject
        local pts = cur.pts
        local function at(i)
            local dx, dy = pts[i * 2 - 1] - acx, pts[i * 2] - acy
            return p0x + dx * sxx + dy * syx, p0y + dx * sxy + dy * syy
        end
        local lx, ly = at(1)
        if cur.np == 1 then
            SKm.seg(jo, lx - hw, ly, lx + hw, ly, hw, col, 1)
        else
            map:setStencilRect(0, 0, map.width, map.height)
            local ok, err = pcall(function()
                for i = 2, cur.np do
                    local x, y = at(i)
                    SKm.seg(jo, lx, ly, x, y, hw, col, 1)
                    lx, ly = x, y
                end
            end)
            map:clearStencilRect()
            if not ok then error(err, 0) end
        end
    end
    if self.prefs.mode == "erase" then
        local x, y = self:cursor()
        local r, seg = ST.ERASER_PX, 20
        local px, py = x + r, y
        for k = 1, seg do
            local t = k / seg * 2 * math.pi
            local nx, ny = x + r * math.cos(t), y + r * math.sin(t)
            map:drawLine(nil, px, py, nx, ny, 1, 1, 1, 1, 1)
            px, py = nx, ny
        end
    end
end

Core.sketchToolDraw = function(map)
    local tool = Core.sketchToolOf(map)
    if tool then tool:drawOverlay() end
end

-- 按鈕列筆鈕：開這位玩家的世界地圖並開工具；工具已經開著＝關掉
Core.sketchToolStart = function(pn)
    pn = pn or 0
    if not getSpecificPlayer(pn) then return false end
    local map = ISWorldMap_instance
    if not (map and map:isVisible() and map.playerNum == pn) then
        if not (ISWorldMap and ISWorldMap.ShowWorldMap) then return false end
        ISWorldMap.ShowWorldMap(pn)
        map = ISWorldMap_instance
        if not (map and map:isVisible()) then return false end
    end
    local sym = map.symbolsUI
    if not (sym and sym.setCurrentTool) then return false end
    local open = Core.sketchToolOf(map)
    if open then
        open:exit()
        return true
    end
    SK().ensure(pn)
    local tool = Tool:new(sym)
    tool.pn, tool.prefs = pn, ST.prefsOf(pn)
    sym:setCurrentTool(tool)
    if JoypadState and JoypadState.players[pn + 1] then setJoypadFocus(pn, map) end
    return true
end
