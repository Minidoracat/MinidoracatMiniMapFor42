-- 手繪線離線測試共用的假環境（test_sketch_*.lua 用）：記憶體檔案系統、事件、時鐘、玩家與物品欄、
-- 正交投影的地圖假件（javaObject 記下每次 DrawPolygon）、原版符號工具基底（ISWorldMapSymbols.lua:11-88 語意）、
-- 最小 UI 假件。真模組照遊戲的方式整檔載入（全域表），投影輔助取主檔標記區段的真實作。
-- 用法：local H = dofile("scripts/sketch_harness.lua"); H.boot({ client = true, tool = true, share = true })
local H = {}
H.LUA = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/"
H.failures, H.total = 0, 0
function H.check(cond, msg)
    H.total = H.total + 1
    if not cond then
        H.failures = H.failures + 1
        print("FAIL " .. msg)
    end
end
function H.finish(name)
    print(string.format("%s: %d assertions, %d failures", name, H.total, H.failures))
    if H.failures > 0 then os.exit(1) end
end
function H.read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end
function H.slice(source, name)
    local tag = name:gsub("%-", "%%-")
    return assert(source:match("%-%- test:" .. tag .. ":start\n(.-)\n%-%- test:" .. tag .. ":end"), "找不到區段 " .. name)
end
-- 整檔載入（可在尾巴加 return 取出檔案 local）
function H.load(path, tail)
    return assert(load(H.read(path) .. (tail and ("\n" .. tail) or ""), "@" .. path))()
end

-- 記憶體檔案系統（getFileWriter 開檔即截斷；writeBroken＝寫不進去；unreadable[path]＝在卻打不開）
H.files, H.unreadable, H.writeBroken, H.writes = {}, {}, false, {}
function cacheFileExists(path) return H.files[path] ~= nil end
function getFileReader(path)
    if H.unreadable[path] or H.files[path] == nil then return nil end
    local lines, i = {}, 0
    if H.files[path] ~= "" then
        for line in (H.files[path] .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    end
    return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
end
function getFileWriter(path)
    H.files[path] = ""
    H.writes[#H.writes + 1] = path
    local lost = H.writeBroken
    return { write = function(_, text) if not lost then H.files[path] = H.files[path] .. text end end,
        close = function() end }
end

-- 事件
H.handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = { Add = function(fn) H.handlers[name] = H.handlers[name] or {}; table.insert(H.handlers[name], fn) end }
    rawset(t, name, e)
    return e
end })
function H.fire(name, ...)
    for _, fn in ipairs(H.handlers[name] or {}) do fn(...) end
end

H.now, H.autoMs = 100000, 0 -- autoMs＝每次讀時鐘自動前進（測每 tick 限時）
function getTimestampMs()
    H.now = H.now + H.autoMs
    return H.now
end
H.clientFlag = false
function isClient() return H.clientFlag end
function getWorld()
    return { getWorld = function() return "w1" end, getGameMode = function() return "Sandbox" end }
end
local zr = 0
function ZombRand(n) zr = zr + 1; return zr % n end
function getText(key, ...)
    local n = select("#", ...)
    if n == 0 then return key end
    local parts = { key }
    for i = 1, n do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, "|", 1, #parts)
end
function getTextOrNull(key) return key end
H.messages = {}
UIFont = { Small = 1, Medium = 2 }
function getTextManager()
    return { getFontHeight = function() return 15 end, MeasureStringX = function(_, _, s) return #s * 7 end }
end
Keyboard = { KEY_RETURN = 28, KEY_BACK = 14, KEY_ESCAPE = 1 }
Joypad = { AButton = 0, BButton = 1, XButton = 2, YButton = 3 }
JoypadState = { players = {} }
H.shift, H.rightDown = false, false
function isShiftKeyDown() return H.shift end
function isMouseButtonDown(b) return b == 1 and H.rightDown end
ItemTag = { get = function(r) return "tag:" .. tostring(r) end, ERASER = "tag:eraser" }
ResourceLocation = { of = function(s) return s end }

-- 玩家與物品欄：items[類型]＝true
function H.inventory(items)
    return { containsTypeRecurse = function(_, t) return items[t] == true end,
        containsTagRecurse = function() return false end }
end
H.players = {}
function H.player(name, pn, items)
    local p = { name = name, pn = pn, items = items or {}, dead = false, online = 1 }
    function p:getUsername() return self.name end
    function p:getOnlineID() return self.online end
    function p:isDead() return self.dead end
    function p:getPlayerNum() return self.pn end
    function p:getInventory() return H.inventory(self.items) end
    return p
end
function getSpecificPlayer(pn) return H.players[pn] end

-- 地圖假件：正交投影，每格 S px，中心 (cx, cy)
function H.map(opts)
    opts = opts or {}
    local m = { width = opts.w or 800, height = opts.h or 600, playerNum = opts.pn or 0, polys = {}, lines = 0,
        stencil = 0, cleared = 0 }
    local api = { S = opts.S or 4, cx = opts.cx or 1000, cy = opts.cy or 1000, zoom = opts.zoom or 17 }
    m.mapAPI = api
    function api:getWorldScale() return self.S end
    function api:getZoomF() return self.zoom end
    -- jit＝worldToUI 的捨入差（引擎 float32；getWorldScale 不受影響）
    function api:worldToUIX(x) return (x - self.cx) * self.S * (1 + (self.jit or 0)) + m.width / 2 end
    function api:worldToUIY(_, y) return (y - self.cy) * self.S * (1 + (self.jit or 0)) + m.height / 2 end
    function api:uiToWorldX(x, y, zoomF, cx) return ((cx or self.cx) * self.S + x - m.width / 2) / self.S end
    function api:uiToWorldY(x, y, zoomF, cx, cy) return ((cy or self.cy) * self.S + y - m.height / 2) / self.S end
    function api:getCenterWorldX() return self.cx end
    function api:getCenterWorldY() return self.cy end
    function api:centerOn(x, y) self.cx, self.cy = x, y end
    m.javaObject = { DrawPolygon = function(_, _, ...)
        if m.failDraw then error("draw boom") end
        m.polys[#m.polys + 1] = { ... }
    end }
    m.mouse = { x = 0, y = 0 }
    function m:getMouseX() return self.mouse.x end
    function m:getMouseY() return self.mouse.y end
    function m:setStencilRect() self.stencil = self.stencil + 1 end
    function m:clearStencilRect() self.cleared = self.cleared + 1 end
    function m:drawLine() self.lines = self.lines + 1 end
    function m:getAbsoluteX() return 0 end
    function m:getAbsoluteY() return 0 end
    function m:isVisible() return true end
    function m:addChild(c) c.parent = self; self.kids = self.kids or {}; self.kids[#self.kids + 1] = c end
    function m:removeChild(c) c.parent = nil end
    return m
end

-- 原版符號工具基底與符號面板（ISWorldMapSymbols.lua:11-88、1401-1441）
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
ISWorldMapSymbolTool = Base:derive("ISWorldMapSymbolTool")
function ISWorldMapSymbolTool:activate() end
function ISWorldMapSymbolTool:deactivate() end
function ISWorldMapSymbolTool:onMouseDown(x, y)
    self.dragging, self.dragMoved, self.dragStartX, self.dragStartY = true, false, x, y
    return false
end
function ISWorldMapSymbolTool:getMouseX() return self.mapUI:getMouseX() end
function ISWorldMapSymbolTool:getMouseY() return self.mapUI:getMouseY() end
function ISWorldMapSymbolTool:new(symbolsUI)
    local o = Base.new(self)
    o.symbolsUI, o.mapUI, o.mapAPI = symbolsUI, symbolsUI.mapUI, symbolsUI.mapAPI
    return o
end
-- 世界地圖：地圖假件＋符號面板（canWrite／canErase 照原版看玩家的物品欄）
function H.worldMap(opts)
    local m = H.map(opts)
    local sym = { mapUI = m, mapAPI = m.mapAPI, character = H.players[m.playerNum] }
    function sym:setCurrentTool(t)
        if t == self.currentTool then return end
        if self.currentTool then self.currentTool:deactivate() end
        self.currentTool = t
        if t then t:activate() end
    end
    function sym:canWrite()
        local inv = self.character:getInventory()
        for _, it in ipairs({ "Pen", "Pencil", "RedPen", "BluePen", "GreenPen" }) do
            if inv:containsTypeRecurse(it) then return true end
        end
        return false
    end
    function sym:canErase() return self.character:getInventory():containsTypeRecurse("Base.Eraser") end
    m.symbolsUI = sym
    ISWorldMap_instance = m
    return m
end

-- 最小 UI 假件（工具列、選單）
local function element(x, y, w, h)
    local e = { x = x, y = y, width = w, height = h, kids = {}, enabled = true }
    function e:initialise() end
    function e:addChild(c) c.parent = self; self.kids[#self.kids + 1] = c end
    function e:removeChild(c) c.parent = nil end
    function e:setX(v) self.x = v end
    function e:setWidth(v) self.width = v end
    function e:setHeight(v) self.height = v end
    function e:setVisible(v) self.visible = v end
    function e:setEnable(v) self.enabled = v end
    function e:setTitle(t) self.title = t end
    function e:drawText() end
    return e
end
ISPanel = { new = function(_, x, y, w, h) return element(x, y, w, h) end, prerender = function() end }
-- setEnable 照原版就地改寫 backgroundColor／borderColor 表（ISButton.lua:416-438）：工具列不能靠它，
-- 否則共用的配色表會被改掉（2026-11-08 sketch-sp 實機）
ISButton = { new = function(_, x, y, w, h, title, target, fn)
    local b = element(x, y, w, h)
    b.title, b.target, b.onclick, b.enable = title, target, fn, true
    b.backgroundColor = { r = 0, g = 0, b = 0, a = 1 }
    b.borderColor = { r = 0.7, g = 0.7, b = 0.7, a = 1 }
    function b:setEnable(v)
        self.enable = v
        if not self.bgEnabled then
            local c = self.backgroundColor
            self.bgEnabled = { r = c.r, g = c.g, b = c.b, a = c.a }
        end
        local src = v and self.bgEnabled or { r = 0, g = 0, b = 0, a = 1 }
        local c = self.backgroundColor
        c.r, c.g, c.b, c.a = src.r, src.g, src.b, src.a
    end
    return b
end }
H.menus = {}
ISContextMenu = { get = function()
    local m = { options = {} }
    function m:addOption(name, target, fn, a, b)
        local o = { name = name, target = target, fn = fn, a = a, b = b }
        self.options[#self.options + 1] = o
        return o
    end
    H.menus[#H.menus + 1] = m
    return m
end }
function setJoypadFocus() end
H.prints = {}
local rawPrint = print
function H.quiet(on) print = on and function(...) H.prints[#H.prints + 1] = table.concat({ ... }, " ") end or rawPrint end

-- 選項（ModOptions 假件）
H.opts = {}
local function opt(id, default)
    if H.opts[id] == nil then return default end
    return H.opts[id]
end

-- 載入：Core＋真 LAYER_MAPS／投影輔助＋RoadCodec＋SketchCodec＋RoadDraw（抽點層）＋Sketch；
-- o.tool＝SketchTool、o.share＝客戶端 SketchShare、o.server＝Groups＋伺服器 SketchShare（isClient 假）
function H.boot(o)
    o = o or {}
    local main = H.read(H.LUA .. "client/MinidoracatMiniMap.lua")
    local Core = { ready = true }
    MinidoracatMiniMapCore = Core
    H.Core = Core
    Core.getBoolOption = opt
    Core.getComboIndex = opt
    Core.getSliderValue = function(id, default, min, max)
        local v = opt(id, default)
        if v < min then return min end
        if v > max then return max end
        return v
    end
    local helpers = assert(load(H.slice(main, "visible-aabb") .. "\n" .. H.slice(main, "derive-affine")
        .. "\nreturn { visibleWorldAABB = visibleWorldAABB, deriveAffine = deriveAffine }", "=helpers"))()
    Core.visibleWorldAABB, Core.deriveAffine = helpers.visibleWorldAABB, helpers.deriveAffine
    assert(load(H.slice(main, "layer-maps"), "=layer-maps", "t",
        setmetatable({ Core = Core, getBoolOption = opt }, { __index = _G })))()
    H.zoneFrames = 0
    Core.zoneFrame = function(inner)
        H.zoneFrames = H.zoneFrames + 1
        local api = inner.mapAPI
        local f = { scale = api:getWorldScale() }
        f.vMinX, f.vMaxX, f.vMinY, f.vMaxY = Core.visibleWorldAABB(inner)
        f.acx, f.acy = math.floor((f.vMinX + f.vMaxX) / 2), math.floor((f.vMinY + f.vMaxY) / 2)
        f.p0x, f.p0y, f.sxx, f.sxy, f.syx, f.syy = Core.deriveAffine(api, f.acx, f.acy)
        return f
    end
    Core.navMessage = function(pn, text) H.messages[#H.messages + 1] = text end
    MinidoracatMiniMapRoadCodec, MinidoracatMiniMapSketchCodec = nil, nil
    H.load(H.LUA .. "shared/MinidoracatMiniMap_RoadCodec.lua")
    H.load(H.LUA .. "shared/MinidoracatMiniMap_SketchCodec.lua")
    if o.server then
        H.clientFlag = false
        H.load(H.LUA .. "server/MinidoracatMiniMapGroups.lua")
        H.SS = H.load(H.LUA .. "server/MinidoracatMiniMapSketchShare.lua", "return SS")
    end
    H.clientFlag = o.client == true
    H.quiet(true)
    H.load(H.LUA .. "client/MinidoracatMiniMap_RoadDraw.lua")
    H.load(H.LUA .. "client/MinidoracatMiniMap_Sketch.lua")
    if o.share then H.load(H.LUA .. "client/MinidoracatMiniMap_SketchShare.lua") end
    if o.tool then H.load(H.LUA .. "client/MinidoracatMiniMap_SketchTool.lua") end
    H.quiet(false)
    H.SK = Core.Sketch
    return Core
end

-- 跑 OnTickEvenPaused 直到這位玩家的帳號檔載完（最多 n 次）
function H.loadSlot(pn, n)
    for _ = 1, n or 1000 do
        local slot = H.SK.slots[pn]
        if slot and not slot.load then return slot end
        H.now = H.now + 16
        H.fire("OnTickEvenPaused")
    end
    return H.SK.slots[pn]
end

return H
