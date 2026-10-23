-- MinidoracatMiniMap_RoadTool.lua
-- 本檔範圍：世界地圖的「畫道路／編輯形狀／檢查錄好的路」工具、工具列與操作提示、點選單、
-- 存檔表單（名稱、路面、路寬、提醒列）、Core.roadToolStart、Core.roadsShowOnMap，以及地圖右鍵的
-- 道路子選單（Core.roadsMapMenu，_Nav.lua mapMenuFill 呼叫）。設計稿 temp/plan-minimap-custom-roads-1023
-- 主張 1、1.1-1.3、3.3-3.5。
-- 工具掛在原版地圖符號面板的工具槽（ISWorldMapSymbols:setCurrentTool，ISWorldMapSymbols.lua:1431-1441）：
-- 滑鼠、鍵盤、手把 A／B 都由原版路由進來（ISWorldMap.lua:825-910、1203-1215、1343-1360），Esc 與 B 由原版
-- 關掉工具（ISWorldMapSymbols.lua:1692-1726）＝deactivate 把畫到一半的線留成草稿（Core.roadsSetDraft）。
-- setCurrentTool 的副作用只有 setUserEditing(true)：引擎在編輯中把「超出縮放範圍」的玩家地圖標記畫成 25%
-- 透明而不是淡出（WorldMapBaseSymbol.java:457、WorldMapTextSymbol.java:218；作者隱藏判斷另要
-- DimUnsharedSymbols，:246），不開符號面板、不改資料，所以沿用工具槽、不另包 ISWorldMap 事件。
-- 道路資料一律走 RoadData 的 Core.roads*；路網吸附走 NavCore 的 Core.navNearestRoad（都做 nil 防護）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.roadToolStart then return end
if not (ISWorldMapSymbolTool and ISWorldMapSymbolTool.derive) then return end
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

local RT = {
    DRAG_PX = 4,         -- 拖曳門檻（任一軸，原版要兩軸都超過，ISWorldMapSymbols.lua:36）
    HIT_PX = 9,          -- 點的命中半徑（畫面 px）
    MID_PX = 7,          -- 中段小圓的命中半徑
    SNAP_PX = 18,        -- 吸附範圍（畫面 px，換成格再夾在 SNAP_MIN..SNAP_MAX）
    SNAP_MIN = 2, SNAP_MAX = 30,
    CONNECT_NEAR = 30,   -- 存檔提醒：端點 30 格內有路才提醒沒接上（使用者 2026-10-23 確認）
    CONNECTED = 1.5,     -- 端點離道路這麼近就算接上（NavCore 建圖另有自己的容差）
    SHARP_DEG = 100,     -- 急彎門檻（轉向角，0＝直行）
    UNDO_MAX = 100,
    MAX_POINTS = 300,    -- 同 RoadCodec.MAX_POINTS
    WIDTHS = { 4, 6, 8 },
    WIDTH_KEYS = { "UI_MinidoracatMiniMap_RoadWidthNarrow", "UI_MinidoracatMiniMap_RoadWidthNormal",
        "UI_MinidoracatMiniMap_RoadWidthWide" },
    SURFACES = { "paved", "gravel", "dirt" },
    RAW_DRAW_MAX = 600,  -- 錄製原始軌跡最多畫幾段（抽樣）
}
Core.RoadTool = RT
local Tool = ISWorldMapSymbolTool:derive("MinidoracatRoadTool")
RT.Tool = Tool

--------------------------------------------------------------------------------
-- 純計算（scripts/test_road_tool.lua 直接測）
--------------------------------------------------------------------------------
function RT.half(v) return math.floor(v * 2 + 0.5) / 2 end

function RT.dragMoved(sx, sy, mx, my)
    return math.abs(mx - sx) > RT.DRAG_PX or math.abs(my - sy) > RT.DRAG_PX
end

-- 點選單：mode＝draw／edit／review，i＝第幾點，n＝點數，ends＝{起點, 終點}。回 { {key, op, off?}, ... }
function RT.pointMenuItems(mode, i, n, ends)
    local items = {}
    local function add(key, op, off) items[#items + 1] = { key = key, op = op, off = off } end
    if mode == "draw" then
        if i == n and n >= 2 then add("UI_MinidoracatMiniMap_RoadFinish", "finish") end
        add("UI_MinidoracatMiniMap_RoadPtDelete", "delete")
    else
        add("UI_MinidoracatMiniMap_RoadPtMove", "move")
        add("UI_MinidoracatMiniMap_RoadPtDelete", "delete", n <= 2)
    end
    if n >= 2 and (i == 1 or i == n) then
        local e = i == 1 and 1 or 2
        if ends[e] == "free" then
            add("UI_MinidoracatMiniMap_RoadPtEndSnap", "endSnap")
        else
            add("UI_MinidoracatMiniMap_RoadPtEndFree", "endFree")
        end
    end
    return items
end

-- 轉向角（度）：a→b→c 在 b 轉了多少，0＝直行、180＝回頭；零長段回 0
function RT.turnDeg(ax, ay, bx, by, cx, cy)
    local ux, uy, vx, vy = bx - ax, by - ay, cx - bx, cy - by
    local lu, lv = math.sqrt(ux * ux + uy * uy), math.sqrt(vx * vx + vy * vy)
    if lu < 1e-6 or lv < 1e-6 then return 0 end
    local c = (ux * vx + uy * vy) / (lu * lv)
    if c > 1 then c = 1 elseif c < -1 then c = -1 end
    return math.deg(math.acos(c))
end

-- 急彎：中間點轉向角超過 SHARP_DEG。回 { {i=, deg=}, ... }
function RT.sharpTurns(pts)
    local out = {}
    local n = #pts / 2
    for i = 2, n - 1 do
        local d = RT.turnDeg(pts[i * 2 - 3], pts[i * 2 - 2], pts[i * 2 - 1], pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2])
        if d > RT.SHARP_DEG then out[#out + 1] = { i = i, deg = d } end
    end
    return out
end

-- 端點接上狀態：free＝不提醒（nil）；附近 CONNECT_NEAR 格沒路或路網沒好＝不提醒（nil）；
-- CONNECTED 內＝已接上；其他＝沒接上（附接上點）。skipId＝編輯中的那條路（不算自己接上自己）
function RT.endState(pn, x, y, mode, skipId)
    if mode == "free" or not Core.navNearestRoad then return nil end
    local ok, near = pcall(Core.navNearestRoad, pn, x, y, RT.CONNECT_NEAR, skipId)
    if not ok or type(near) ~= "table" or type(near.dist) ~= "number" or near.dist > RT.CONNECT_NEAR then
        return nil
    end
    return { ok = near.dist <= RT.CONNECTED, dist = near.dist, name = near.name, x = near.x, y = near.y }
end

-- 線段與矩形（世界座標，[x1,x2]×[y1,y2]）相交：Liang-Barsky
function RT.segHitsRect(ax, ay, bx, by, x1, y1, x2, y2)
    local t0, t1 = 0, 1
    local dx, dy = bx - ax, by - ay
    local p = { -dx, dx, -dy, dy }
    local q = { ax - x1, x2 - ax, ay - y1, y2 - ay }
    for k = 1, 4 do
        if p[k] == 0 then
            if q[k] < 0 then return false end
        else
            local t = q[k] / p[k]
            if p[k] < 0 then
                if t > t1 then return false end
                if t > t0 then t0 = t end
            else
                if t < t0 then return false end
                if t < t1 then t1 = t end
            end
        end
    end
    return true
end

-- 可能穿過幾棟建築（房間資料版 buildingsIn；外框內縮 0.5 格，貼著牆走不算）。回 count 或 nil, "pending"
function RT.buildingsCrossed(pts)
    local api = MinidoracatMiniMapResourceAPI
    if not (api and api.buildingsIn) then return 0 end
    local seen, count = {}, 0
    local n = #pts / 2
    for k = 2, n do
        local ax, ay, bx, by = pts[k * 2 - 3], pts[k * 2 - 2], pts[k * 2 - 1], pts[k * 2]
        local minx, miny = math.min(ax, bx), math.min(ay, by)
        local list, m = api.buildingsIn(minx, miny, math.abs(bx - ax) + 1, math.abs(by - ay) + 1, "rooms")
        if not list then
            if m == "pending" then return nil, "pending" end
            return 0
        end
        for j = 1, m do
            local b = list[j]
            local key = b.x .. "," .. b.y .. "," .. b.w .. "," .. b.h
            if not seen[key] and RT.segHitsRect(ax, ay, bx, by, b.x + 0.5, b.y + 0.5, b.x + b.w - 0.5, b.y + b.h - 0.5) then
                seen[key] = true
                count = count + 1
            end
        end
    end
    return count
end

-- 存檔表單的提醒列：{ kind=, ... }。kind：endOk／endGap（e＝1 起點／2 終點）、sharp、buildings、
-- buildingsPending、estimated
function RT.saveIssues(pn, pts, ends, measured, skipId)
    local rows = {}
    local n = #pts / 2
    for e = 1, 2 do
        local i = e == 1 and 1 or n
        local st = RT.endState(pn, pts[i * 2 - 1], pts[i * 2], ends[e], skipId)
        if st then
            rows[#rows + 1] = { kind = st.ok and "endOk" or "endGap", e = e, name = st.name, dist = st.dist,
                x = st.x, y = st.y }
        end
    end
    local sharp = RT.sharpTurns(pts)
    for k = 1, math.min(#sharp, 3) do
        rows[#rows + 1] = { kind = "sharp", i = sharp[k].i, deg = sharp[k].deg }
    end
    local count, why = RT.buildingsCrossed(pts)
    if why == "pending" then
        rows[#rows + 1] = { kind = "buildingsPending" }
    elseif count and count > 0 then
        rows[#rows + 1] = { kind = "buildings", count = count }
    end
    if measured then
        local guess = 0
        for k = 1, n - 1 do if measured[k] == false then guess = guess + 1 end end
        if guess > 0 then rows[#rows + 1] = { kind = "estimated", count = guess } end
    end
    return rows
end

local function copyList(t)
    if not t then return nil end
    local out = {}
    for i = 1, #t do out[i] = t[i] end
    return out
end
RT.copyList = copyList

local function fmtInt(v) return string.format("%d", math.floor(v + 0.5)) end
RT.fmtInt = fmtInt

--------------------------------------------------------------------------------
-- 工具狀態：pts＝扁平世界座標，segW／segS／measured＝每段資料（畫的路沒有，存檔時由表單填）
--------------------------------------------------------------------------------
function Tool:new(symbolsUI)
    local o = ISWorldMapSymbolTool.new(self, symbolsUI)
    o.pts, o.ends, o.undoStack = {}, { "snap", "snap" }, {}
    return o
end

function Tool:count() return #self.pts / 2 end

-- opts 同 Core.roadToolStart。回 true＝可以開始
function Tool:setup(pn, opts)
    self.pn = pn
    local d = opts.draft
    local mode = opts.mode or "draw"
    if mode == "edit" and opts.roadId then
        local road = Core.roadsGet and Core.roadsGet(pn, opts.roadId)
        if not road then return false end
        d = { pts = road.pts, segWidth = road.segWidth, segSurface = road.segSurface, ends = road.ends,
            source = road.source, roadId = road.id }
        self.name = road.name
    elseif d and d.roadId then
        mode = "edit"
        local road = Core.roadsGet and Core.roadsGet(pn, d.roadId)
        self.name = road and road.name or d.name
    elseif d and mode == "review" and d.source ~= "record" then
        mode = "draw" -- 繼續畫的草稿
    end
    self.mode = mode
    if d then
        self.pts = copyList(d.pts) or {}
        self.segW, self.segS, self.measured = copyList(d.segWidth), copyList(d.segSurface), copyList(d.measured)
        self.ends = { d.ends and d.ends[1] or "snap", d.ends and d.ends[2] or "snap" }
        self.source = d.source or "draw"
        self.roadId = d.roadId
        self.raw, self.rawN = d.raw, d.rawN
        self.parts, self.part, self.partCount = d.parts, d.part, d.partCount
    else
        self.source = "draw"
    end
    -- 錄好的路沒存就離開也要留著（RoadRecord 交過來的就是唯一一份）
    self.dirty = mode == "review"
    self:changed(true)
    return true
end

function Tool:changed(keepDirty)
    if not keepDirty then self.dirty = true end
    local len, pts = 0, self.pts
    for k = 2, self:count() do
        local dx, dy = pts[k * 2 - 1] - pts[k * 2 - 3], pts[k * 2] - pts[k * 2 - 2]
        len = len + math.sqrt(dx * dx + dy * dy)
    end
    self.lenTiles = len
    self.snapKey = nil
end

function Tool:pushUndo()
    local s = self.undoStack
    s[#s + 1] = { pts = copyList(self.pts), segW = copyList(self.segW), segS = copyList(self.segS),
        measured = copyList(self.measured), ends = { self.ends[1], self.ends[2] }, lastRaw = self.lastRaw }
    if #s > RT.UNDO_MAX then table.remove(s, 1) end
end

function Tool:undo()
    local s = self.undoStack
    local top = s[#s]
    if not top then return false end
    s[#s] = nil
    self.pts, self.segW, self.segS, self.measured = top.pts, top.segW, top.segS, top.measured
    self.ends, self.lastRaw = top.ends, top.lastRaw
    self.moving = nil
    self:changed()
    return true
end

-- 每段資料跟著點數走：插在第 k 段（k、k+1 點之間）＝第 k 段複製一份；刪點＝合併相鄰兩段（留前一段）
local function segInsert(t, k)
    if t then table.insert(t, k, t[k] or t[k - 1]) end
end
local function segRemove(t, k)
    if t and t[k] ~= nil then table.remove(t, k) end
end

-- 吸附：Shift 按著不吸；不是端點不吸；navNearestRoad 沒有或沒路回 nil。編輯既有的路時跳過它自己
-- （navNearestRoad 第 5 參 skipRoadId，NavCore），不然端點會吸回這條路的舊形狀
function Tool:snapFor(wx, wy, isEnd)
    if not isEnd or not Core.navNearestRoad then return nil end
    if isShiftKeyDown and isShiftKeyDown() then return nil end
    local ppu = self:ppu()
    local maxDist = ppu > 0 and RT.SNAP_PX / ppu or RT.SNAP_MAX
    if maxDist < RT.SNAP_MIN then maxDist = RT.SNAP_MIN elseif maxDist > RT.SNAP_MAX then maxDist = RT.SNAP_MAX end
    local ok, near = pcall(Core.navNearestRoad, self.pn, wx, wy, maxDist, self.roadId)
    if ok and type(near) == "table" and type(near.x) == "number" and type(near.y) == "number" then
        return near
    end
    return nil
end

function Tool:ppu()
    local api = self.mapAPI
    local cx, cy = api:getCenterWorldX(), api:getCenterWorldY()
    local ax, ay = api:worldToUIX(cx, cy), api:worldToUIY(cx, cy)
    local bx, by = api:worldToUIX(cx + 8, cy), api:worldToUIY(cx + 8, cy)
    return math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) / 8
end

-- 畫線加點（新點一定是終點，吸附）。上一個終點不再是端點：吸附過就放回原位（中間點不吸附）
function Tool:addPoint(wx, wy)
    local n = self:count()
    if n >= RT.MAX_POINTS then
        RT.say(self.pn, getText("UI_MinidoracatMiniMap_RoadMaxPoints", fmtInt(RT.MAX_POINTS)), false)
        return false
    end
    local rx, ry = RT.half(wx), RT.half(wy)
    local snap = self:snapFor(wx, wy, true)
    local x, y = rx, ry
    if snap then x, y = RT.half(snap.x), RT.half(snap.y) end
    -- 跟上一點重合＝零長度段（RoadData 拒存）：不加
    if n >= 1 and self.pts[n * 2 - 1] == x and self.pts[n * 2] == y then return false end
    self:pushUndo()
    if self.lastRaw and n >= 2 then
        self.pts[n * 2 - 1], self.pts[n * 2] = self.lastRaw[1], self.lastRaw[2]
    end
    self.lastRaw = snap and n >= 1 and { rx, ry } or nil
    self.pts[n * 2 + 1], self.pts[n * 2 + 2] = x, y
    if n >= 1 then
        if self.segW then self.segW[n] = self.segW[n - 1] or RT.WIDTHS[1] end
        if self.segS then self.segS[n] = self.segS[n - 1] or "dirt" end
        if self.measured then self.measured[n] = false end
    end
    self:changed()
    return true
end

function Tool:deletePoint(i)
    local n = self:count()
    if i < 1 or i > n or (self.mode ~= "draw" and n <= 2) then return false end
    self:pushUndo()
    table.remove(self.pts, i * 2)
    table.remove(self.pts, i * 2 - 1)
    local k = i == 1 and 1 or i - 1
    if i < n and i > 1 then k = i end
    segRemove(self.segW, k)
    segRemove(self.segS, k)
    segRemove(self.measured, k)
    if i == n then self.lastRaw = nil end
    self:changed()
    return true
end

-- 第 k 段中間插一點，回新點的編號
function Tool:insertMid(k)
    local pts = self.pts
    local x = RT.half((pts[k * 2 - 1] + pts[k * 2 + 1]) / 2)
    local y = RT.half((pts[k * 2] + pts[k * 2 + 2]) / 2)
    self:pushUndo()
    table.insert(pts, k * 2 + 1, y)
    table.insert(pts, k * 2 + 1, x)
    segInsert(self.segW, k)
    segInsert(self.segS, k)
    segInsert(self.measured, k)
    self:changed()
    return k + 1
end

-- 把第 i 點放到 (wx, wy)；端點吸附，中間點不吸附
function Tool:setPoint(i, wx, wy)
    local n = self:count()
    local snap = self:snapFor(wx, wy, i == 1 or i == n)
    if snap then wx, wy = snap.x, snap.y end
    self.pts[i * 2 - 1], self.pts[i * 2] = RT.half(wx), RT.half(wy)
    if i == n then self.lastRaw = nil end
    self:changed()
end

function Tool:setEnd(e, mode)
    self:pushUndo()
    self.ends[e] = mode
    self:changed()
end

-- 畫面上哪一點在 (x, y)（元件座標）；最近的優先
function Tool:pointAt(x, y)
    local api, pts = self.mapAPI, self.pts
    local best, bestD = nil, RT.HIT_PX * RT.HIT_PX
    for i = 1, self:count() do
        local wx, wy = pts[i * 2 - 1], pts[i * 2]
        local dx, dy = api:worldToUIX(wx, wy) - x, api:worldToUIY(wx, wy) - y
        local d = dx * dx + dy * dy
        if d <= bestD then best, bestD = i, d end
    end
    return best
end

-- 中段小圓（編輯／檢查）：回段號 k
function Tool:midAt(x, y)
    if self.mode == "draw" or self:count() >= RT.MAX_POINTS then return nil end
    local api, pts = self.mapAPI, self.pts
    for k = 1, self:count() - 1 do
        local wx, wy = (pts[k * 2 - 1] + pts[k * 2 + 1]) / 2, (pts[k * 2] + pts[k * 2 + 2]) / 2
        local dx, dy = api:worldToUIX(wx, wy) - x, api:worldToUIY(wx, wy) - y
        if dx * dx + dy * dy <= RT.MID_PX * RT.MID_PX then return k end
    end
    return nil
end

function Tool:toWorld(x, y)
    return self.mapAPI:uiToWorldX(x, y), self.mapAPI:uiToWorldY(x, y)
end

-- 手把模式：準星在畫面中央（同原版 ISWorldMap.lua:390-392 的判斷）
function Tool:isJoypad()
    local pn = self.pn or 0
    return pn ~= 0 or (JoypadState and JoypadState.players[pn + 1] ~= nil
        and not (wasMouseActiveMoreRecentlyThanJoypad and wasMouseActiveMoreRecentlyThanJoypad()))
end

function Tool:cursor()
    if self:isJoypad() then return self.mapUI.width / 2, self.mapUI.height / 2 end
    return self:getMouseX(), self:getMouseY()
end

--------------------------------------------------------------------------------
-- 輸入（原版經 ISWorldMapSymbols 轉來；回 true＝原版不再處理）
--------------------------------------------------------------------------------
function Tool:onMouseDown(x, y)
    ISWorldMapSymbolTool.onMouseDown(self, x, y)
    if self.form or self.moving or self.mode == "draw" then return false end
    local i = self:pointAt(x, y)
    if i then
        self:pushUndo()
        self.moveIdx, self.moveNew = i, false
        return true
    end
    local k = self:midAt(x, y)
    if k then
        self.moveIdx, self.moveNew = self:insertMid(k), true
        return true
    end
    return false
end

function Tool:onMouseMove(dx, dy)
    if self.moveIdx then
        local wx, wy = self:toWorld(self:getMouseX(), self:getMouseY())
        self:setPoint(self.moveIdx, wx, wy)
        self.moveMoved = true
        return true
    end
    if self.dragging and not self.dragMoved
        and RT.dragMoved(self.dragStartX, self.dragStartY, self:getMouseX(), self:getMouseY()) then
        self.dragMoved = true
    end
    return false
end

function Tool:onMouseUp(x, y)
    local wasDragging, moved = self.dragging, self.dragMoved
    self.dragging = false
    if self.moveIdx then
        -- 按了點沒拖：拿掉按下時記的復原（中段加點那筆保留）
        if not self.moveMoved and not self.moveNew then
            self.undoStack[#self.undoStack] = nil
        end
        self.moveIdx, self.moveMoved, self.moveNew = nil, nil, nil
        return true
    end
    if self.form or not wasDragging or moved then return false end
    return self:click(x, y)
end

-- 點一下（滑鼠放開或手把 A）：x, y＝元件座標
function Tool:click(x, y)
    if self.moving then
        local wx, wy = self:toWorld(x, y)
        self:setPoint(self.moving, wx, wy)
        self.moving = nil
        return true
    end
    local i = self:pointAt(x, y)
    if self.mode == "draw" then
        if i and i == self:count() and i >= 2 then
            self:finish()
        elseif not i then
            self:addPoint(self:toWorld(x, y))
        end
        return true
    end
    return false
end

function Tool:onRightMouseUp(x, y)
    if self.form then return true end
    if self.moving then
        self:undo() -- 「移動這點」按下時記過一筆：取消＝回到原位
        return true
    end
    local i = self:pointAt(x, y)
    if i then self:openPointMenu(i, x, y) else self:undo() end
    return true
end

function Tool:isKeyConsumed(key)
    return key == Keyboard.KEY_RETURN or key == Keyboard.KEY_BACK
end

function Tool:onKeyRelease(key)
    if self.form then return false end
    if key == Keyboard.KEY_BACK then
        self:undo()
        return true
    end
    if key == Keyboard.KEY_RETURN then
        self:finish()
        return true
    end
    return false -- Esc：原版關工具，deactivate 留草稿
end

function Tool:onJoypadDownInMap(button, joypadData)
    if button ~= Joypad.AButton or self.form then return end
    local cx, cy = self.mapUI.width / 2, self.mapUI.height / 2
    if self.moving then
        self:click(cx, cy)
        return
    end
    local i = self:pointAt(cx, cy)
    if i then
        self:openPointMenu(i, cx, cy)
    elseif self.mode == "draw" then
        self:addPoint(self:toWorld(cx, cy))
    else
        local k = self:midAt(cx, cy)
        if k then self:insertMid(k) end
    end
end

function Tool:getJoypadAButtonText()
    if self.form then return nil end
    local cx, cy = self.mapUI.width / 2, self.mapUI.height / 2
    if self.moving then return getText("UI_MinidoracatMiniMap_RoadPadPlace") end
    if self:pointAt(cx, cy) then return getText("UI_MinidoracatMiniMap_RoadPadMenu") end
    if self.mode == "draw" then return getText("UI_MinidoracatMiniMap_RoadPadAdd") end
    if self:midAt(cx, cy) then return getText("UI_MinidoracatMiniMap_RoadPadInsert") end
    return nil
end

--------------------------------------------------------------------------------
-- 點選單（右鍵在點上／手把 A 在點上）
--------------------------------------------------------------------------------
function RT.pointMenuDo(tool, op, i)
    if op == "finish" then
        tool:finish()
    elseif op == "delete" then
        tool:deletePoint(i)
    elseif op == "move" then
        tool:pushUndo()
        tool.moving = i
    elseif op == "endFree" or op == "endSnap" then
        tool:setEnd(i == 1 and 1 or 2, op == "endFree" and "free" or "snap")
    end
end

function Tool:openPointMenu(i, x, y)
    local map = self.mapUI
    local pn = self.pn or 0
    local menu = ISContextMenu.get(pn, x + map:getAbsoluteX(), y + map:getAbsoluteY())
    if not menu then return end
    local items = RT.pointMenuItems(self.mode, i, self:count(), self.ends)
    for k = 1, #items do
        local it = items[k]
        local opt = menu:addOption(getText(it.key), self, RT.pointMenuDo, it.op, i)
        if it.off and Core.navMenuLock then
            Core.navMenuLock(opt, getText("UI_MinidoracatMiniMap_RoadPtMinPoints"))
        end
    end
    if JoypadState and JoypadState.players[pn + 1] then
        menu.origin = map
        menu.mouseOver = 1
        setJoypadFocus(pn, menu)
    end
end

--------------------------------------------------------------------------------
-- 完成、離開、草稿
--------------------------------------------------------------------------------
function Tool:finish()
    if self:count() < 2 then
        RT.say(self.pn, getText("UI_MinidoracatMiniMap_RoadPtMinPoints"), false)
        return false
    end
    self.moving = nil
    RT.openForm(self)
    return true
end

function Tool:draftTable()
    return { pts = copyList(self.pts), segWidth = copyList(self.segW), segSurface = copyList(self.segS),
        measured = copyList(self.measured), ends = { self.ends[1], self.ends[2] }, source = self.source,
        roadId = self.roadId, raw = self.raw, rawN = self.rawN, parts = self.parts, part = self.part,
        partCount = self.partCount }
end

function Tool:activate()
    local ok, err = pcall(RT.makeBar, self)
    if not ok then log("road tool bar failed: " .. tostring(err)) end
end

-- 原版關工具（Esc、手把 B、關地圖、按 S 收符號面板）都走這裡：草稿留著，「道路」分頁可以繼續或捨棄
function Tool:deactivate()
    RT.closeForm(self)
    if self.bar then
        self.bar:setVisible(false)
        if self.bar.parent then self.bar.parent:removeChild(self.bar) end
        self.bar = nil
    end
    if self.done or not self.dirty or self:count() < 1 then return end
    if Core.roadsSetDraft then Core.roadsSetDraft(self.pn, self:draftTable()) end
end

function Tool:exit()
    local sym = self.symbolsUI
    if sym and sym.currentTool == self then sym:setCurrentTool(nil) end
end

-- 存好或捨棄之後：還有下一段錄好的路就接著開
function RT.afterDone(tool)
    tool.done = true
    if Core.roadsClearDraft then Core.roadsClearDraft(tool.pn) end
    tool:exit()
    local parts = tool.parts
    if parts and parts[1] then
        local nextDraft = parts[1]
        local rest = {}
        for k = 2, #parts do rest[#rest + 1] = parts[k] end
        nextDraft.parts = rest[1] and rest or nil
        Core.roadToolStart(tool.pn, { mode = "review", draft = nextDraft })
    end
end

function RT.say(pn, text, good)
    if Core.navMessage then Core.navMessage(pn or 0, text, good) end
end

--------------------------------------------------------------------------------
-- 工具列（地圖上方置中，一直顯示）：標題＋點數與長度、復原／完成／離開、兩行操作提示
--------------------------------------------------------------------------------
function RT.barTitle(tool)
    local n, len = fmtInt(tool:count()), fmtInt(tool.lenTiles or 0)
    local t
    if tool.mode == "edit" then
        t = getText("UI_MinidoracatMiniMap_RoadBarEdit", tool.name or "", n, len)
    elseif tool.mode == "review" then
        t = getText("UI_MinidoracatMiniMap_RoadBarReview", n, fmtInt(tool.rawN or tool:count()))
        if tool.partCount and tool.partCount > 1 then
            t = t .. "  " .. getText("UI_MinidoracatMiniMap_RoadBarPart", fmtInt(tool.part or 1), fmtInt(tool.partCount))
        end
    else
        t = getText("UI_MinidoracatMiniMap_RoadBarDraw", n, len)
    end
    return t
end

function RT.barHints(tool)
    local lines
    if tool.mode == "draw" then
        lines = { getText("UI_MinidoracatMiniMap_RoadHintDraw"), getText("UI_MinidoracatMiniMap_RoadHintPadDraw") }
    else
        lines = { getText("UI_MinidoracatMiniMap_RoadHintEdit"), getText("UI_MinidoracatMiniMap_RoadHintPadEdit") }
    end
    if tool.measured then
        for k = 1, #tool.measured do
            if tool.measured[k] == false then
                lines[#lines + 1] = getText("UI_MinidoracatMiniMap_RoadHintEstimated")
                break
            end
        end
    end
    return lines
end

local function barPrerender(self)
    ISPanel.prerender(self)
    local tool = self.tool
    local fh = self.fontH
    self:drawText(RT.barTitle(tool), 8, 5, 1, 1, 1, 1, UIFont.Small)
    for k = 1, #self.hints do
        self:drawText(self.hints[k], 8, self.hintY + (k - 1) * (fh + 2), 0.9, 0.9, 0.9, 1, UIFont.Small)
    end
    local btn = self.doneBtn
    btn:setEnable(tool:count() >= 2)
    self.undoBtn:setEnable(#tool.undoStack > 0)
    local x = (self.parent.width - self.width) / 2
    if self.x ~= x then self:setX(x - x % 1) end
end

function RT.makeBar(tool)
    local map = tool.mapUI
    local tm = getTextManager()
    local fh = tm:getFontHeight(UIFont.Small)
    local bh = fh + 6
    local hints = RT.barHints(tool)
    local labels = { getText("UI_MinidoracatMiniMap_RoadUndo"), getText("UI_MinidoracatMiniMap_RoadFinish"),
        getText("UI_MinidoracatMiniMap_RoadExit") }
    local bw = {}
    local btnsW = 0
    for k = 1, 3 do
        bw[k] = tm:MeasureStringX(UIFont.Small, labels[k]) + 16
        btnsW = btnsW + bw[k] + 6
    end
    -- 標題留最寬的情況（300 點、長度五位數）：寬度不跟著點數跳
    local widest = setmetatable({ lenTiles = 99999, rawN = 99999 }, { __index = tool })
    function widest.count() return RT.MAX_POINTS end
    local titleW = tm:MeasureStringX(UIFont.Small, RT.barTitle(widest))
    local w = titleW + 24 + btnsW
    for k = 1, #hints do
        local hw = tm:MeasureStringX(UIFont.Small, hints[k]) + 16
        if hw > w then w = hw end
    end
    if w > map.width - 20 then w = map.width - 20 end
    local hintY = bh + 10
    local h = hintY + #hints * (fh + 2) + 4
    local bar = ISPanel:new((map.width - w) / 2, 10, w, h)
    bar:initialise()
    bar.backgroundColor = { r = 0.07, g = 0.07, b = 0.07, a = 0.92 }
    bar.borderColor = { r = 0.27, g = 0.27, b = 0.27, a = 1 }
    bar.tool, bar.fontH, bar.hints, bar.hintY = tool, fh, hints, hintY
    bar.prerender = barPrerender
    local x = w - btnsW - 2
    local fns = {
        function() tool:undo() end,
        function() tool:finish() end,
        function() tool:exit() end,
    }
    local btns = {}
    for k = 1, 3 do
        local b = ISButton:new(x, 4, bw[k], bh, labels[k], bar, fns[k])
        b:initialise()
        if k == 2 then b.borderColor = { r = 0.85, g = 0.71, b = 0.35, a = 1 } end
        bar:addChild(b)
        btns[k] = b
        x = x + bw[k] + 6
    end
    bar.undoBtn, bar.doneBtn = btns[1], btns[2]
    map:addChild(bar)
    tool.bar = bar
end

--------------------------------------------------------------------------------
-- 地圖上的工具畫面（_WorldMapNav.lua 世界地圖 prerender 在導航之後呼叫）：正在編的線、點、中段小圓、
-- 畫線預覽與吸附圈、錄製原始軌跡
--------------------------------------------------------------------------------
Core.roadToolOf = function(map)
    local sym = map and map.symbolsUI
    local tool = sym and sym.currentTool
    if tool and getmetatable(tool) == Tool then return tool end
    return nil
end

local function circle(el, x, y, r, a, cr, cg, cb, wdt)
    local seg = 16
    local px, py = x + r, y
    for k = 1, seg do
        local t = k / seg * 2 * math.pi
        local nx, ny = x + r * math.cos(t), y + r * math.sin(t)
        el:drawLine(nil, px, py, nx, ny, wdt, a, cr, cg, cb)
        px, py = nx, ny
    end
end

function Tool:drawOverlay()
    local map, api, pts = self.mapUI, self.mapAPI, self.pts
    local n = self:count()
    local RD = Core.RoadDraw
    -- 錄製原始軌跡：細灰線，抽樣到 RAW_DRAW_MAX 段
    local raw = self.raw
    if raw and #raw >= 4 then
        local rn = #raw / 2
        local step = math.max(1, math.ceil(rn / RT.RAW_DRAW_MAX))
        local clip = Core.clipSegment
        local px, py = api:worldToUIX(raw[1], raw[2]), api:worldToUIY(raw[1], raw[2])
        local k = 1 + step
        while true do
            if k > rn then k = rn end
            local x, y = api:worldToUIX(raw[k * 2 - 1], raw[k * 2]), api:worldToUIY(raw[k * 2 - 1], raw[k * 2])
            local x1, y1, x2, y2 = px, py, x, y
            if clip then x1, y1, x2, y2 = clip(px, py, x, y, map.width, map.height) end
            if x1 then map:drawLine(nil, x1, y1, x2, y2, 1, 0.9, 0.37, 0.36, 0.32) end
            px, py = x, y
            if k >= rn then break end
            k = k + step
        end
    end
    if n >= 2 and RD then
        RD.drawPolyline(map, pts, n, RD.UNDER, RD.OVER, RD.DASH_ON, RD.DASH_OFF, nil, RT.MAX_POINTS)
    end
    local cx, cy = self:cursor()
    -- 畫線預覽：最後一點到游標（或準星）的細虛線＋吸附圈與路名
    local snapX, snapY, snapName
    if self.form == nil and (self.mode == "draw" and not self:pointAt(cx, cy) or self.moving or self.moveIdx) then
        local wx, wy = self:toWorld(cx, cy)
        local idx = self.moving or self.moveIdx
        local isEnd = idx == nil or idx == 1 or idx == n
        local key = string.format("%.1f,%.1f,%s", wx, wy, tostring(isShiftKeyDown and isShiftKeyDown()))
        if self.snapKey ~= key then
            self.snapKey = key
            self.snapHit = self:snapFor(wx, wy, isEnd)
        end
        local hit = self.snapHit
        if hit then snapX, snapY, snapName = api:worldToUIX(hit.x, hit.y), api:worldToUIY(hit.x, hit.y), hit.name end
        if self.mode == "draw" and not idx and n >= 1 then
            local lx, ly = api:worldToUIX(pts[n * 2 - 1], pts[n * 2]), api:worldToUIY(pts[n * 2 - 1], pts[n * 2])
            local tx, ty = snapX or cx, snapY or cy
            local dx, dy = tx - lx, ty - ly
            local len = math.sqrt(dx * dx + dy * dy)
            local t = 0
            while t < len do
                local e = math.min(t + 3, len)
                map:drawLine(nil, lx + dx * t / len, ly + dy * t / len, lx + dx * e / len, ly + dy * e / len,
                    1.5, 1, 0.953, 0.918, 0.816)
                t = t + 6
            end
        end
    end
    -- 中段小圓（編輯／檢查）
    if self.mode ~= "draw" and n < RT.MAX_POINTS then
        for k = 1, n - 1 do
            local wx, wy = (pts[k * 2 - 1] + pts[k * 2 + 1]) / 2, (pts[k * 2] + pts[k * 2 + 2]) / 2
            local x, y = api:worldToUIX(wx, wy), api:worldToUIY(wx, wy)
            if x > -8 and y > -8 and x < map.width + 8 and y < map.height + 8 then
                map:drawRect(x - 3, y - 3, 7, 7, 0.9, 0.85, 0.82, 0.73)
                map:drawRectBorder(x - 4, y - 4, 9, 9, 1, 0.08, 0.08, 0.08)
            end
        end
    end
    -- 點：白方塊黑框；不接道路的端點畫灰；游標下的點金框
    local hover = self:pointAt(cx, cy)
    for i = 1, n do
        local x, y = api:worldToUIX(pts[i * 2 - 1], pts[i * 2]), api:worldToUIY(pts[i * 2 - 1], pts[i * 2])
        if x > -8 and y > -8 and x < map.width + 8 and y < map.height + 8 then
            local free = (i == 1 and self.ends[1] == "free") or (i == n and n >= 2 and self.ends[2] == "free")
            local c = free and 0.55 or 1
            map:drawRect(x - 3, y - 3, 7, 7, 1, c, c, c)
            if hover == i or self.moving == i then
                map:drawRectBorder(x - 5, y - 5, 11, 11, 1, 0.85, 0.71, 0.35)
            else
                map:drawRectBorder(x - 4, y - 4, 9, 9, 1, 0.08, 0.08, 0.08)
            end
        end
    end
    -- 「移動這點」：新位置跟著游標（或準星），點一下放下
    if self.moving then
        local gx, gy = snapX or cx, snapY or cy
        map:drawRect(gx - 3, gy - 3, 7, 7, 0.8, 1, 1, 1)
        map:drawRectBorder(gx - 5, gy - 5, 11, 11, 1, 0.85, 0.71, 0.35)
    end
    if snapX then
        circle(map, snapX, snapY, 9, 1, 1, 1, 1, 2)
        local label = snapName and snapName ~= "" and getText("UI_MinidoracatMiniMap_RoadSnapTo", snapName)
            or getText("UI_MinidoracatMiniMap_RoadSnapUnnamed")
        local tw = getTextManager():MeasureStringX(UIFont.Small, label)
        local th = getTextManager():getFontHeight(UIFont.Small)
        map:drawRect(snapX + 12, snapY + 8, tw + 8, th + 2, 0.9, 0.07, 0.07, 0.07)
        map:drawRectBorder(snapX + 12, snapY + 8, tw + 8, th + 2, 1, 0.3, 0.49, 0.33)
        map:drawText(label, snapX + 16, snapY + 9, 0.75, 0.91, 0.78, 1, UIFont.Small)
    end
end

Core.roadToolDraw = function(map)
    local tool = Core.roadToolOf(map)
    if tool then tool:drawOverlay() end
end

--------------------------------------------------------------------------------
-- 存檔表單（名稱、路面、路寬、提醒列；繼續編輯／捨棄／儲存）
--------------------------------------------------------------------------------
function RT.closeForm(tool)
    RT.closeConfirm(tool)
    local f = tool.form
    if not f then return end
    tool.form = nil
    f:setVisible(false)
    f:removeFromUIManager()
    if JoypadState and JoypadState.players[(tool.pn or 0) + 1] then setJoypadFocus(tool.pn, tool.mapUI) end
end

-- 捨棄：草稿清掉、離開工具；分段錄製接著開下一段（RT.afterDone）
function RT.discard(tool)
    RT.closeForm(tool)
    RT.say(tool.pn, getText("UI_MinidoracatMiniMap_RoadDiscarded"), true)
    RT.afterDone(tool)
end

function RT.closeConfirm(tool)
    local c = tool.confirm
    if not c then return end
    tool.confirm = nil
    c:setVisible(false)
    c:removeFromUIManager()
    if JoypadState and JoypadState.players[(tool.pn or 0) + 1] then
        setJoypadFocus(tool.pn, tool.form or tool.mapUI)
    end
end

-- 捨棄前確認（同 _Search.lua createConfirmPanel 的規則：按鈕寫明「捨棄」、預設焦點在取消、手把 B＝取消，
-- Enter 不觸發任何一顆）。錄的路與畫到一半的線只在記憶體，誤按就沒了；0-1 點沒什麼好丟，直接捨棄
function RT.confirmDiscard(tool)
    if tool:count() <= 1 then
        RT.discard(tool)
        return
    end
    RT.closeConfirm(tool)
    local pn = tool.pn or 0
    local tm = getTextManager()
    local fh = tm:getFontHeight(UIFont.Small)
    local bh, pad = fh + 8, 12
    -- 文字與按鈕沿用「道路」分頁捨棄草稿的同一組鍵（_Search.lua）
    local text = getText("UI_MinidoracatMiniMap_RoadConfirmDiscard")
    local cancelText, actionText = getText("UI_Cancel"), getText("UI_MinidoracatMiniMap_RoadDraftDiscard")
    local cw, aw = tm:MeasureStringX(UIFont.Small, cancelText) + 24, tm:MeasureStringX(UIFont.Small, actionText) + 24
    local W = math.max(300, tm:MeasureStringX(UIFont.Small, text) + pad * 2, cw + aw + pad * 3)
    local sw = getCore():getScreenWidth() - 40
    if W > sw then W = sw end
    local H = pad + fh + pad + bh + pad
    local c = ISPanelJoypad:new(0, 0, W, H)
    c:initialise()
    c:instantiate()
    c.prerender = function(self)
        self:drawRect(0, 0, self.width, self.height, 0.96, 0.07, 0.07, 0.07)
        self:drawRectBorder(0, 0, self.width, self.height, 1, 0.54, 0.42, 0.2)
        self:drawText(text, pad, pad, 1, 1, 1, 1, UIFont.Small)
    end
    local cancel = ISButton:new(pad, H - pad - bh, cw, bh, cancelText, c, function() RT.closeConfirm(tool) end)
    cancel:initialise()
    c:addChild(cancel)
    local action = ISButton:new(W - pad - aw, H - pad - bh, aw, bh, actionText, c, function() RT.discard(tool) end)
    action:initialise()
    action.backgroundColor = { r = 0.45, g = 0.12, b = 0.08, a = 0.7 }
    c:addChild(action)
    c:insertNewLineOfButtons(cancel, action)
    c:setISButtonForB(cancel)
    local map = tool.mapUI
    local x = map:getAbsoluteX() + (map.width - W) / 2
    local y = map:getAbsoluteY() + (map.height - H) / 2
    c:setX(x - x % 1)
    c:setY(y - y % 1)
    c:addToUIManager()
    c:bringToTop()
    tool.confirm = c
    if JoypadState and JoypadState.players[pn + 1] then
        c.joypadIndexY, c.joypadIndex = 1, 1
        c.joypadButtons = c.joypadButtonsY[1]
        setJoypadFocus(pn, c)
    end
    return c
end

-- 每段都同值才回那個值，否則 nil（錄製的路）
local function uniform(t, m)
    if not t or not t[1] then return nil end
    for k = 2, m do if t[k] ~= t[1] then return nil end end
    return t[1]
end

-- 預設選項：畫的新路＝泥土、窄；錄的路＝依錄製（第三值＝要不要列「依錄製」）；編輯畫的路＝原本的值
function RT.formDefaults(tool)
    if tool.source == "record" and tool.segW then return "recorded", "recorded", true end
    local m = tool:count() - 1
    return uniform(tool.segS, m) or "dirt", uniform(tool.segW, m) or RT.WIDTHS[1], false
end

-- 錄的路在表單「依錄製」底下列出錄到什麼：路面照第一次出現的順序，路寬只算量到的段，而且同一種
-- 路面、同一個寬度累計至少 SUMMARY_MIN_LEN 格才算進範圍（路口一小段寬的不撐大範圍；整種路面都不夠
-- 長才全算）；整種路面都是推定的只寫路面名稱。畫的路回 nil。
RT.SUMMARY_MIN_LEN = 5
function RT.recordedSummary(tool)
    if tool.source ~= "record" or not (tool.segS and tool.segW) then return nil end
    local order, lens, pts = {}, {}, tool.pts
    for k = 1, tool:count() - 1 do
        local s, w = tool.segS[k], tool.segW[k]
        if s then
            if not lens[s] then order[#order + 1], lens[s] = s, {} end
            if type(w) == "number" and not (tool.measured and tool.measured[k] == false) then
                local dx, dy = pts[k * 2 + 1] - pts[k * 2 - 1], pts[k * 2 + 2] - pts[k * 2]
                lens[s][w] = (lens[s][w] or 0) + math.sqrt(dx * dx + dy * dy)
            end
        end
    end
    if #order == 0 then return nil end
    local parts = {}
    for i = 1, #order do
        local s = order[i]
        local lo, hi, alo, ahi
        for w, len in pairs(lens[s]) do
            alo, ahi = alo and math.min(alo, w) or w, ahi and math.max(ahi, w) or w
            if len >= RT.SUMMARY_MIN_LEN then lo, hi = lo and math.min(lo, w) or w, hi and math.max(hi, w) or w end
        end
        if not lo then lo, hi = alo, ahi end
        local name = getText("UI_MinidoracatMiniMap_RoadSurface_" .. s)
        if not lo then
            parts[i] = name
        elseif lo == hi then
            parts[i] = getText("UI_MinidoracatMiniMap_RoadRecordedItem", name,
                getText("UI_MinidoracatMiniMap_RoadWidth", fmtInt(lo)))
        else
            parts[i] = getText("UI_MinidoracatMiniMap_RoadRecordedItem", name,
                getText("UI_MinidoracatMiniMap_RoadWidthRange", fmtInt(lo), fmtInt(hi)))
        end
    end
    return getText("UI_MinidoracatMiniMap_RoadRecordedSummary",
        table.concat(parts, getText("UI_MinidoracatMiniMap_RoadSep")))
end

function RT.issueText(row)
    local endLabel = row.e and getText(row.e == 1 and "UI_MinidoracatMiniMap_RoadEndStart"
        or "UI_MinidoracatMiniMap_RoadEndEnd")
    local name = row.name and row.name ~= "" and row.name or getText("UI_MinidoracatMiniMap_RoadUnnamed")
    if row.kind == "endOk" then
        return getText("UI_MinidoracatMiniMap_RoadIssueConnected", endLabel, name), true
    elseif row.kind == "endGap" then
        return getText("UI_MinidoracatMiniMap_RoadIssueGap", endLabel, fmtInt(row.dist), name), false
    elseif row.kind == "sharp" then
        return getText("UI_MinidoracatMiniMap_RoadIssueSharp", fmtInt(row.i), fmtInt(row.deg)), false
    elseif row.kind == "buildings" then
        return getText("UI_MinidoracatMiniMap_RoadIssueBuildings", fmtInt(row.count)), false
    elseif row.kind == "buildingsPending" then
        return getText("UI_MinidoracatMiniMap_RoadIssueBuildingsPending"), false
    elseif row.kind == "estimated" then
        return getText("UI_MinidoracatMiniMap_RoadIssueEstimated", fmtInt(row.count)), false
    end
    return "", false
end

-- 「接上」：在這一端外面補一點接到道路上（不移動原本的端點）
function RT.connectEnd(tool, row)
    local n = tool:count()
    if n >= RT.MAX_POINTS or not row.x then return end
    tool:pushUndo()
    local x, y = RT.half(row.x), RT.half(row.y)
    if row.e == 1 then
        table.insert(tool.pts, 1, y)
        table.insert(tool.pts, 1, x)
        segInsert(tool.segW, 1)
        segInsert(tool.segS, 1)
        segInsert(tool.measured, 1)
    else
        tool.pts[n * 2 + 1], tool.pts[n * 2 + 2] = x, y
        if tool.segW then tool.segW[n] = tool.segW[n - 1] end
        if tool.segS then tool.segS[n] = tool.segS[n - 1] end
        if tool.measured then tool.measured[n] = tool.measured[n - 1] end
        tool.lastRaw = nil
    end
    tool:changed()
end

-- 組要存的道路：編輯＝從原本那條的副本改（保留 id、sid、分享旗、enabled、rev，rev 由 RoadData 加）。
-- 座標進 0.5 格、相鄰重合的點合併（RoadData 拒存零長度段）；每段資料取「到這一點」的原本那段
function RT.buildRoad(tool, name, surface, width)
    local road = {}
    local old = tool.roadId and Core.roadsGet and Core.roadsGet(tool.pn, tool.roadId)
    if old then for k, v in pairs(old) do road[k] = v end end
    road.id = tool.roadId
    road.name = name
    local src, pts, segW, segS = tool.pts, {}, {}, {}
    local np = 0
    for i = 1, #src / 2 do
        local x, y = RT.half(src[i * 2 - 1]), RT.half(src[i * 2])
        if np == 0 or x ~= pts[np * 2 - 1] or y ~= pts[np * 2] then
            if np >= 1 then
                local k = i - 1
                segW[np] = width ~= "recorded" and width or tool.segW and tool.segW[k] or RT.WIDTHS[1]
                segS[np] = surface ~= "recorded" and surface or tool.segS and tool.segS[k] or "dirt"
            end
            np = np + 1
            pts[np * 2 - 1], pts[np * 2] = x, y
        end
    end
    road.pts, road.segWidth, road.segSurface = pts, segW, segS
    road.ends = { tool.ends[1], tool.ends[2] }
    road.source = tool.source or "draw"
    if road.enabled == nil then road.enabled = true end
    if not road.share then road.share = { faction = false, safehouse = false } end
    return road
end

function RT.saveFromForm(tool, form)
    local name = form.entry and form.entry:getText() or ""
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 128 then name = name:sub(1, 128) end
    local road = RT.buildRoad(tool, name, form.roadSurface, form.roadWidth)
    local ok, res = false, "failed"
    if Core.roadsSave then ok, res = Core.roadsSave(tool.pn, road) end
    if not ok then
        form.errorText = Core.roadsErrorText and Core.roadsErrorText(res)
            or getText("UI_MinidoracatMiniMap_RoadError")
        return false
    end
    -- 名稱空白＝RoadData 給預設名：讀回存好的那筆
    local saved = Core.roadsGet and Core.roadsGet(tool.pn, res or road.id)
    RT.say(tool.pn, getText("UI_MinidoracatMiniMap_RoadSaved", saved and saved.name or name), true)
    RT.afterDone(tool)
    return true
end

local function chipStyle(btn, on)
    btn.borderColor = on and { r = 0.85, g = 0.71, b = 0.35, a = 1 } or { r = 0.33, g = 0.33, b = 0.33, a = 1 }
    btn.backgroundColor = on and { r = 0.23, g = 0.2, b = 0.13, a = 1 } or { r = 0.13, g = 0.13, b = 0.13, a = 1 }
end

-- 「建築檢查中」那一列：房間資料掃完就原地換成結果（每 0.5 秒查一次）；沒穿過建築＝收起那一列，不重建表單
-- （重建會清掉打到一半的名稱與輸入焦點）
function RT.refreshPending(form)
    local now = getTimestampMs and getTimestampMs() or 0
    if now < (form.pendingAt or 0) then return end
    form.pendingAt = now + 500
    local count, why = RT.buildingsCrossed(form.tool.pts)
    if why == "pending" then return end
    local r = form.rows[form.pendingRow]
    form.pendingRow = nil
    if count and count > 0 then
        r.text, r.good = RT.issueText({ kind = "buildings", count = count })
    else
        r.hidden = true
    end
end

local function formPrerender(self)
    if self.pendingRow then RT.refreshPending(self) end
    self:drawRect(0, 0, self.width, self.height, 0.96, 0.07, 0.07, 0.07)
    self:drawRectBorder(0, 0, self.width, self.height, 1, 0.24, 0.24, 0.24)
    self:drawText(self.title, 10, 7, 1, 1, 1, 1, UIFont.Medium)
    for k = 1, #self.labels do
        local l = self.labels[k]
        self:drawText(l.text, l.x, l.y, 0.66, 0.66, 0.66, 1, UIFont.Small)
    end
    for k = 1, #self.rows do
        local r = self.rows[k]
        if not r.hidden then
            local tag = r.good and self.okText or self.noteText
            local tw = self.tagW[r.good and 1 or 2]
            if r.good then
                self:drawRectBorder(10, r.y, tw + 8, self.fontH + 2, 1, 0.3, 0.49, 0.33)
                self:drawText(tag, 14, r.y + 1, 0.56, 0.82, 0.6, 1, UIFont.Small)
            else
                self:drawRectBorder(10, r.y, tw + 8, self.fontH + 2, 1, 0.54, 0.42, 0.2)
                self:drawText(tag, 14, r.y + 1, 1, 0.71, 0.33, 1, UIFont.Small)
            end
            self:drawText(r.text, 10 + self.tagW[3] + 14, r.y + 1, 0.9, 0.9, 0.9, 1, UIFont.Small)
        end
    end
    if self.errorText then
        self:drawText(self.errorText, 10, self.errorY, 1, 0.45, 0.35, 1, UIFont.Small)
    end
    if self.joyfocus then
        self:drawRectBorder(2, 2, self.width - 4, self.height - 4, 1, 1, 1, 1)
    end
end

function RT.openForm(tool)
    RT.closeForm(tool)
    local pn = tool.pn or 0
    local tm = getTextManager()
    local fh = tm:getFontHeight(UIFont.Small)
    local bh = fh + 8
    local pad = 10
    local okText, noteText = getText("UI_MinidoracatMiniMap_RoadIssueOk"), getText("UI_MinidoracatMiniMap_RoadIssueNote")
    local okW, noteW = tm:MeasureStringX(UIFont.Small, okText), tm:MeasureStringX(UIFont.Small, noteText)
    local textX = pad + math.max(okW, noteW) + 14
    -- 提醒列先算：表單寬度放得下最長的一列（文字標示等級，不只靠顏色；沒接上的端點附「接上」）
    local rows = RT.saveIssues(pn, tool.pts, tool.ends, tool.measured, tool.roadId)
    local connectText = getText("UI_MinidoracatMiniMap_RoadConnect")
    local cw = tm:MeasureStringX(UIFont.Small, connectText) + 14
    local W = math.max(360, fh * 26)
    for k = 1, #rows do
        rows[k].text, rows[k].good = RT.issueText(rows[k])
        local need = textX + tm:MeasureStringX(UIFont.Small, rows[k].text) + pad
            + (rows[k].kind == "endGap" and cw + 6 or 0)
        if need > W then W = need end
    end
    local recSummary = RT.recordedSummary(tool)
    if recSummary then W = math.max(W, pad * 2 + tm:MeasureStringX(UIFont.Small, recSummary)) end
    local sw = getCore():getScreenWidth() - 40
    if W > sw then W = sw end
    local form = ISPanelJoypad:new(0, 0, W, 100)
    form:initialise()
    form:instantiate()
    form.tool, form.fontH = tool, fh
    form.title = getText("UI_MinidoracatMiniMap_RoadSaveTitle")
    form.okText, form.noteText = okText, noteText
    form.tagW = { okW, noteW, math.max(okW, noteW) }
    form.labels, form.rows = {}, {}
    form.prerender = formPrerender
    local labelW = 0
    local labelKeys = { "UI_MinidoracatMiniMap_RoadFieldName", "UI_MinidoracatMiniMap_RoadFieldSurface",
        "UI_MinidoracatMiniMap_RoadFieldWidth" }
    for k = 1, 3 do labelW = math.max(labelW, tm:MeasureStringX(UIFont.Small, getText(labelKeys[k]))) end
    local x0 = pad + labelW + 10
    local y = tm:getFontHeight(UIFont.Medium) + 16
    -- 名稱
    form.labels[1] = { text = getText(labelKeys[1]), x = pad, y = y + 4 }
    local entry = ISTextEntryBox:new(tool.name or "", x0, y, W - x0 - pad, bh)
    entry:initialise()
    entry:instantiate()
    entry:setMaxTextLength(128)
    if entry.setPlaceholderText then entry:setPlaceholderText(getText("UI_MinidoracatMiniMap_RoadNamePlaceholder")) end
    form:addChild(entry)
    form.entry = entry
    form:insertNewLineOfButtons(entry)
    y = y + bh + 6
    -- 路面、路寬：chip（ISButton）
    local defS, defW, hasMeta = RT.formDefaults(tool)
    -- 不叫 surface／width：width 是面板自己的寬度（ISUIElement），蓋掉它表單底色只畫幾 px、"recorded" 還會讓 drawRect 每幀出錯
    form.roadSurface, form.roadWidth = defS, defW
    local function chipRow(labelText, values, texts, field)
        form.labels[#form.labels + 1] = { text = labelText, x = pad, y = y + 4 }
        local x = x0
        local btns = {}
        for k = 1, #values do
            local tw = tm:MeasureStringX(UIFont.Small, texts[k]) + 14
            if x + tw > W - pad and x > x0 then
                x = x0
                y = y + bh + 4
            end
            local b = ISButton:new(x, y, tw, bh, texts[k], form, function(target)
                target[field] = values[k]
                for j = 1, #btns do chipStyle(btns[j], j == k) end
            end)
            b:initialise()
            chipStyle(b, form[field] == values[k])
            form:addChild(b)
            btns[k] = b
            x = x + tw + 6
        end
        form:insertNewListOfButtons(btns)
        y = y + bh + 6
    end
    local sv, st = {}, {}
    for k = 1, #RT.SURFACES do
        sv[k] = RT.SURFACES[k]
        st[k] = getText("UI_MinidoracatMiniMap_RoadSurface_" .. RT.SURFACES[k])
    end
    local wv, wt = {}, {}
    for k = 1, #RT.WIDTHS do
        wv[k] = RT.WIDTHS[k]
        wt[k] = getText(RT.WIDTH_KEYS[k], fmtInt(RT.WIDTHS[k]))
    end
    if hasMeta then
        sv[#sv + 1], st[#st + 1] = "recorded", getText("UI_MinidoracatMiniMap_RoadAsRecorded")
        wv[#wv + 1], wt[#wt + 1] = "recorded", getText("UI_MinidoracatMiniMap_RoadAsRecorded")
    end
    chipRow(getText(labelKeys[2]), sv, st, "roadSurface")
    chipRow(getText(labelKeys[3]), wv, wt, "roadWidth")
    if recSummary then
        form.labels[#form.labels + 1] = { text = recSummary, x = pad, y = y }
        y = y + fh + 6
    end
    for k = 1, #rows do
        local row = rows[k]
        form.rows[#form.rows + 1] = { y = y, text = row.text, good = row.good }
        if row.kind == "buildingsPending" then form.pendingRow = #form.rows end
        if row.kind == "endGap" and tool:count() < RT.MAX_POINTS then
            local b = ISButton:new(W - pad - cw, y - 2, cw, bh - 2, connectText, form, function()
                RT.connectEnd(tool, row)
                RT.openForm(tool)
            end)
            b:initialise()
            form:addChild(b)
            form:insertNewLineOfButtons(b)
        end
        y = y + math.max(fh + 6, bh)
    end
    form.errorY = y + 2
    y = y + fh + 8
    -- 按鈕：繼續編輯／捨棄／儲存（儲存是主要動作）
    local labels = { getText("UI_MinidoracatMiniMap_RoadKeepEditing"), getText("UI_MinidoracatMiniMap_RoadDraftDiscard"),
        getText("UI_MinidoracatMiniMap_RoadSave") }
    local fns = {
        function() RT.closeForm(tool) end,
        function() RT.confirmDiscard(tool) end,
        function()
            if RT.saveFromForm(tool, form) then RT.closeForm(tool) end
        end,
    }
    -- 手把玩家才掛 B 鍵：原版有手把圖示時字往右推 37 px（ISButton.lua:238-245、setWidthToTitle :449-453），
    -- 用滑鼠也掛的話圖示會蓋住「繼續編輯」的字
    local joy = JoypadState and JoypadState.players[pn + 1] ~= nil
    local x = pad
    local btns = {}
    for k = 1, 3 do
        local tw = tm:MeasureStringX(UIFont.Small, labels[k]) + 20
        if k == 1 and joy then tw = tw + 37 end
        local b = ISButton:new(x, y, tw, bh, labels[k], form, fns[k])
        b:initialise()
        if k == 3 then b.borderColor = { r = 0.85, g = 0.71, b = 0.35, a = 1 } end
        form:addChild(b)
        btns[k] = b
        x = x + tw + 8
    end
    form:insertNewListOfButtons(btns)
    if joy then form:setISButtonForB(btns[1]) end
    form:setHeight(y + bh + pad)
    local map = tool.mapUI
    local fx = map:getAbsoluteX() + (map.width - W) / 2
    local fy = map:getAbsoluteY() + (map.height - form.height) / 2
    form:setX(fx - fx % 1)
    form:setY(fy - fy % 1)
    form:addToUIManager()
    form:bringToTop()
    tool.form = form
    if JoypadState and JoypadState.players[pn + 1] then
        form.joypadIndexY, form.joypadIndex = #form.joypadButtonsY, 3
        form.joypadButtons = form.joypadButtonsY[form.joypadIndexY]
        setJoypadFocus(pn, form)
    end
    return form
end

--------------------------------------------------------------------------------
-- 公開給其他檔（契約）
--------------------------------------------------------------------------------
local function bboxOf(pts)
    local n = pts and #pts / 2 or 0
    if n < 1 then return nil end
    local minx, miny, maxx, maxy = pts[1], pts[2], pts[1], pts[2]
    for k = 2, n do
        local x, y = pts[k * 2 - 1], pts[k * 2]
        minx, maxx = math.min(minx, x), math.max(maxx, x)
        miny, maxy = math.min(miny, y), math.max(maxy, y)
    end
    return minx, miny, maxx, maxy
end
RT.bboxOf = bboxOf

-- 放得下寬 w、高 h（格）的 bbox、佔畫面 70% 的世界地圖縮放。每格像素數＝2^zoom × renderer 高度 ÷ 地球周長
-- （MapProjection.java:23-25、WorldMapRenderer.java:357-360；1009 px 高、zoom 18 一格約 6.6 px）；等軸測先繞 Z 轉 45°
-- 再繞 X 轉 60°（WorldMapRenderer.java:190-191），bbox 在畫面上寬 (w+h)·√½、高 (w+h)·√½÷2。
-- 用算的不用 worldToUIX 量：剛開圖那一幀還沒 render，投影矩陣是初始的單位矩陣（WorldMapRenderer.java:543-554），
-- 量出來永遠放不下，會一路縮到最遠（2026-10-23 E2E 存路前後截圖看不到路）。
function RT.fitZoom(w, h, viewW, viewH, iso)
    local ex, ey = w, h
    if iso then ex, ey = (w + h) * 0.70710678, (w + h) * 0.35355339 end
    local px = math.min(viewW * 0.7 / math.max(ex, 1), viewH * 0.7 / math.max(ey, 1))
    return math.log(px * 4.007501668557849E7 / viewH) / math.log(2)
end

-- 開世界地圖（這位玩家）、置中在 bbox，有範圍就照 RT.fitZoom 縮放（引擎再夾到最遠／最近的縮放）
function RT.openMapAt(pn, minx, miny, maxx, maxy)
    local cx, cy = minx and (minx + maxx) / 2, miny and (miny + maxy) / 2
    local map = ISWorldMap_instance
    if not (map and map:isVisible() and map.playerNum == pn) then
        if not (ISWorldMap and ISWorldMap.ShowWorldMap) then return nil end
        ISWorldMap.ShowWorldMap(pn, cx, cy, cx and 16 or nil)
        map = ISWorldMap_instance
        if not (map and map:isVisible()) then return nil end
    elseif cx then
        map.mapAPI:centerOn(cx, cy)
    end
    if cx and (maxx > minx or maxy > miny) then
        map.mapAPI:setZoom(RT.fitZoom(maxx - minx, maxy - miny, map.width, map.height, map.isometric))
    end
    return map
end

-- opts.mode＝draw／edit／review；opts.roadId（edit）、opts.draft（review／繼續草稿）、opts.near＝{x=,y=}
Core.roadToolStart = function(pn, opts)
    opts = opts or {}
    if not getSpecificPlayer(pn) then return false end
    local tool = Tool:new({}) -- 先建狀態：路不存在就不開地圖
    if not tool:setup(pn, opts) then
        RT.say(pn, Core.roadsErrorText and Core.roadsErrorText("notfound") or getText("UI_MinidoracatMiniMap_RoadError"),
            false)
        return false
    end
    -- 存檔表單的「可能穿過建築」要房間資料：開工具就先開始背景掃描（MinidoracatMiniMapResources.lua API.prepare），
    -- 畫線的幾秒內通常就掃完，表單少見「檢查中」
    local res = MinidoracatMiniMapResourceAPI
    if res and res.prepare then pcall(res.prepare, "rooms") end
    local minx, miny, maxx, maxy = bboxOf(tool.pts)
    if opts.near and not minx then
        minx, miny, maxx, maxy = opts.near.x, opts.near.y, opts.near.x, opts.near.y
    end
    local map = RT.openMapAt(pn, minx, miny, maxx, maxy)
    local sym = map and map.symbolsUI
    if not (sym and sym.setCurrentTool) then return false end
    -- 同 ISWorldMapSymbolTool:new 掛的三個欄位（ISWorldMapSymbols.lua:79-86）
    tool.symbolsUI, tool.mapUI, tool.mapAPI = sym, sym.mapUI, sym.mapAPI
    sym:setCurrentTool(tool)
    if JoypadState and JoypadState.players[pn + 1] then setJoypadFocus(pn, map) end
    return true
end

-- 開世界地圖置中這條路（kind＝own／received，idOrSid）
Core.roadsShowOnMap = function(pn, kind, idOrSid)
    local road
    if kind == "received" then
        local list = Core.roadsReceived and Core.roadsReceived(pn) or {}
        for i = 1, #list do if list[i].sid == idOrSid then road = list[i] end end
    else
        road = Core.roadsGet and Core.roadsGet(pn, idOrSid)
    end
    if not (road and road.pts) then
        RT.say(pn, Core.roadsErrorText and Core.roadsErrorText("notfound") or getText("UI_MinidoracatMiniMap_RoadError"),
            false)
        return false
    end
    return RT.openMapAt(pn, bboxOf(road.pts)) ~= nil
end

--------------------------------------------------------------------------------
-- 地圖右鍵「道路：名稱」子選單（_Nav.lua mapMenuFill；收藏圖標優先由呼叫端判斷）
--------------------------------------------------------------------------------
Core.roadMenuTitle = function(hit)
    local name = hit.road and hit.road.name or ""
    if #name > 40 then name = name:sub(1, 40) .. "..." end
    return getText("UI_MinidoracatMiniMap_RoadMenuOf", name)
end

function RT.menuEdit(pn, id) Core.roadToolStart(pn, { mode = "edit", roadId = id }) end
function RT.menuRename(pn, id) if Core.roadsPromptRename then Core.roadsPromptRename(pn, id) end end
function RT.menuShare(pn, id) if Core.roadsOpenShare then Core.roadsOpenShare(pn, id) end end
function RT.menuDelete(pn, id) if Core.roadsPromptDelete then Core.roadsPromptDelete(pn, id) end end
local function report(pn, ok, err, okKey)
    if ok then
        if okKey then RT.say(pn, getText(okKey), true) end
    else
        RT.say(pn, Core.roadsErrorText and Core.roadsErrorText(err) or getText("UI_MinidoracatMiniMap_RoadError"), false)
    end
end
function RT.menuSetEnabled(pn, id, on)
    local ok, err = false, "failed"
    if Core.roadsSetEnabled then ok, err = Core.roadsSetEnabled(pn, id, on) end
    report(pn, ok, err)
end
function RT.menuReceivedOff(pn, sid, off)
    local ok, err = false, "failed"
    if Core.roadsSetReceivedOff then ok, err = Core.roadsSetReceivedOff(pn, sid, off) end
    report(pn, ok, err)
end
function RT.menuCopy(pn, sid)
    local id, err = nil, "failed"
    if Core.roadsCopyReceived then id, err = Core.roadsCopyReceived(pn, sid) end
    report(pn, id ~= nil and id ~= false, err, "UI_MinidoracatMiniMap_RoadCopied")
end

-- hit＝Core.roadMapHit 的結果 { road=, kind= }
Core.roadsMapMenu = function(menu, pn, hit)
    local road = hit.road
    if hit.kind == "received" then
        -- 停用狀態在命中結果上（RoadShare 的 roadsAt 回 hit.off）；舊資料退讀 road.off，都沒有＝沒停用
        local off = hit.off
        if off == nil then off = road.off end
        off = off == true
        menu:addOption(getText(off and "UI_MinidoracatMiniMap_RoadNavOn" or "UI_MinidoracatMiniMap_RoadNavOff"),
            pn, RT.menuReceivedOff, road.sid, not off)
        local opt = menu:addOption(getText("UI_MinidoracatMiniMap_RoadCopy"), pn, RT.menuCopy, road.sid)
        if not Core.roadsCopyReceived and Core.navMenuLock then
            Core.navMenuLock(opt, getText("UI_MinidoracatMiniMap_RoadError"))
        end
        return
    end
    local id = road.id
    menu:addOption(getText("UI_MinidoracatMiniMap_RoadEditShape"), pn, RT.menuEdit, id)
    if Core.roadsPromptRename then
        menu:addOption(getText("UI_MinidoracatMiniMap_RoadRename"), pn, RT.menuRename, id)
    end
    -- 單機沒有分享（同搜尋視窗「動作…」，_Search.lua 只在 isClient() 列）；多人不能分享時灰掉並寫原因
    if isClient() then
        local share = menu:addOption(getText("UI_MinidoracatMiniMap_RoadShare"), pn, RT.menuShare, id)
        local okShare, why = false, nil
        if Core.roadShareAvailable then okShare, why = Core.roadShareAvailable(pn) end
        if not (okShare and Core.roadsOpenShare) and Core.navMenuLock then
            Core.navMenuLock(share, getText(why or "UI_MinidoracatMiniMap_RoadError"))
        end
    end
    local on = road.enabled ~= false
    menu:addOption(getText(on and "UI_MinidoracatMiniMap_RoadNavOff" or "UI_MinidoracatMiniMap_RoadNavOn"),
        pn, RT.menuSetEnabled, id, not on)
    if Core.roadsPromptDelete then
        menu:addOption(getText("UI_MinidoracatMiniMap_RoadDelete"), pn, RT.menuDelete, id)
    end
end
