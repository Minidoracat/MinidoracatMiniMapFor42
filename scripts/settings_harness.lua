-- 地圖顯示設定視窗的離線測試台（test_settings_studio.lua／test_addon_settings.lua 共用）。
-- 載入**真的** UI 框架（同層 MinidoracatUIFor42 repo 的 V1＋Focus＋Widgets，可用 MUI_LUA 指到 V1.lua）、
-- 真的 _Settings.lua 與 _Markers.lua，地圖畫法 helper 從 _Dots／_Zones／_Safehouse／_Places 原始碼
-- 抽出同名函式本體（不另寫一份），PZ 原生面（ISPanel／ISButton／ISTextEntryBox、ModOptions、玩家、
-- 手把、沙盒）是可控的假物件。用法：
--   local H = dofile("scripts/settings_harness.lua")
--   local env = H.load{ framework = true | false | "old" }   -- 每次呼叫都重建全部全域
--   env.boot() / env.open(pn) / env.frame() / env.studio()（＝Core.settingsWindow()）
-- 限制：標準 Lua 不是 Kahlua；版面以「每字 8px、Small 14px、Medium 18px」的可控量測驗。
local H = {}

local REPO_CLIENT = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
local REPO_SHARED = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/shared/"
local MUI_V1 = os.getenv("MUI_LUA")
    or "../MinidoracatUIFor42/MOD/MinidoracatUIFor42/Contents/mods/MinidoracatUIFor42/42/media/lua/client/MinidoracatUI/V1.lua"
local MUI_CLIENT = MUI_V1:gsub("MinidoracatUI/V1%.lua$", "")
local compile = loadstring or load

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end
H.readFile = readFile
H.SETTINGS = REPO_CLIENT .. "MinidoracatMiniMap_Settings.lua"

function H.frameworkPresent()
    return readFile(MUI_V1) ~= nil
end

-- 從原始碼抽出頂層 `local function name(...)` 到它的 `end`（第 0 欄）
local function extractFn(source, name)
    local body = source:match("\n(local function " .. name .. "%(.-\nend)\n")
    return assert(body, "missing local function " .. name)
end

-- 翻譯：真的 CH/UI.json（本 MOD）＋框架 CH/IG_UI.json（逐行 "key": "value"），
-- 缺鍵 getText 回鍵名、getTextOrNull 回 nil
local function loadTranslations()
    local t = {}
    local sources = { REPO_SHARED .. "Translate/CH/UI.json",
        MUI_CLIENT:gsub("client/$", "") .. "shared/Translate/CH/IG_UI.json" }
    for i = 1, #sources do
        local src = readFile(sources[i]) or ""
        for line in src:gmatch("[^\n]+") do
            local k, v = line:match('^%s*"([^"]+)":%s*"(.*)",?%s*$')
            if k then t[k] = v:gsub('\\"', '"'):gsub("\\n", "\n") end
        end
    end
    return t
end
local TRANSLATIONS = loadTranslations()

-- ============================================================
-- 原生 ISUI 最小語意面（同框架 smoke_harness.lua 的 stub，另記錄繪製呼叫）
-- ============================================================
local function installISUI(env)
    ISPanel = {}
    ISPanel.__index = ISPanel
    function ISPanel:derive(name)
        local class = setmetatable({ Type = name }, self)
        class.__index = class
        return class
    end
    function ISPanel.new(class, x, y, w, h)
        local o = setmetatable({}, class)
        o.x, o.y, o.width, o.height = x, y, w, h
        o.visible = true
        o.children = {}
        o.childrenInOrder = o.children
        o.javaObject = {}
        o.draws = {}
        o.wantMouseEvents = true
        return o
    end
    function ISPanel:initialise() end
    function ISPanel:instantiate() end
    function ISPanel:setX(x) self.x = x end
    function ISPanel:setY(y) self.y = y end
    function ISPanel:getX() return self.x end
    function ISPanel:getY() return self.y end
    function ISPanel:setWidth(w) self.width = w end
    function ISPanel:setHeight(h) self.height = h end
    function ISPanel:getWidth() return self.width end
    function ISPanel:getHeight() return self.height end
    function ISPanel:getRight() return self.x + self.width end
    function ISPanel:getBottom() return self.y + self.height end
    function ISPanel:getAbsoluteX()
        local p = self.parent
        return (p and p:getAbsoluteX() or 0) + self.x
    end
    function ISPanel:getAbsoluteY()
        local p = self.parent
        if not p then return self.y end
        return p:getAbsoluteY() + self.y + (p._scrollChildren and p:getYScroll() or 0)
    end
    function ISPanel:getXScroll() return 0 end
    function ISPanel:getYScroll() return self._ys or 0 end
    function ISPanel:setYScroll(y)
        local h = self._sh or 0
        if -y > h - self.height then y = -(h - self.height) end
        if y > 0 then y = 0 end
        self._ys = y
    end
    function ISPanel:setScrollHeight(h) self._sh = h; self:setYScroll(self:getYScroll()) end
    function ISPanel:getScrollHeight() return self._sh or 0 end
    function ISPanel:setScrollChildren(b) self._scrollChildren = b end
    function ISPanel:setRenderClippedChildren() end
    function ISPanel:createChildren() end
    function ISPanel:setVisible(v) self.visible = v == true end
    function ISPanel:getIsVisible() return self.visible end
    function ISPanel:isVisible() return self.visible end
    function ISPanel:addToUIManager() self.inUIManager = true end
    function ISPanel:removeFromUIManager() self.inUIManager = false end
    function ISPanel:setAlwaysOnTop() end
    function ISPanel:setWantKeyEvents(v) self.wantKeyEvents = v end
    function ISPanel:bringToTop() env.topCount = (env.topCount or 0) + 1; self.broughtToTop = env.topCount end
    function ISPanel:setCapture(v) self.captured = v end
    function ISPanel:onRightMouseDown() end
    function ISPanel:onRightMouseUp() end
    function ISPanel:isMouseOver() return self._mouseOver == true end
    function ISPanel:getMouseX() return 0 end
    function ISPanel:getMouseY() return 0 end
    function ISPanel:addChild(c) self.children[#self.children + 1] = c; c.parent = self end
    function ISPanel:removeChild(c)
        for i = #self.children, 1, -1 do
            if self.children[i] == c then table.remove(self.children, i) end
        end
        c.parent = nil
    end
    function ISPanel:isReallyVisible()
        local e = self
        while e do
            if not e.visible then return false end
            e = e.parent
        end
        return true
    end
    local function rec(self, kind, a, b, c, d, e, f, g, h, i, j)
        self.draws[#self.draws + 1] = { kind = kind, a, b, c, d, e, f, g, h, i, j }
    end
    function ISPanel:setStencilRect() end
    function ISPanel:clearStencilRect() end
    function ISPanel:repaintStencilRect() end
    function ISPanel:drawText(text, x, y, r, g, b, a, font) rec(self, "text", text, x, y, r, g, b, a, font) end
    function ISPanel:drawTextCentre(text, x, y, r, g, b, a, font) rec(self, "text", text, x, y, r, g, b, a, font) end
    function ISPanel:drawTextRight(text, x, y, r, g, b, a, font) rec(self, "text", text, x, y, r, g, b, a, font) end
    function ISPanel:drawTextZoomed(text, x, y, z, r, g, b, a, font) rec(self, "text", text, x, y, r, g, b, a, font) end
    function ISPanel:drawRect(x, y, w, h, a, r, g, b) rec(self, "rect", x, y, w, h, a, r, g, b) end
    function ISPanel:drawRectBorder(x, y, w, h, a, r, g, b) rec(self, "border", x, y, w, h, a, r, g, b) end
    function ISPanel:drawTextureScaled(t, x, y, w, h, a, r, g, b) rec(self, "tex", t, x, y, w, h, a, r, g, b) end
    function ISPanel:drawTextureScaledAspect(t, x, y, w, h, a, r, g, b) rec(self, "tex", t, x, y, w, h, a, r, g, b) end
    function ISPanel:drawTexture(t, x, y, a, r, g, b) rec(self, "tex", t, x, y, 0, 0, a, r, g, b) end
    function ISPanel:drawLine(t, x1, y1, x2, y2, th, a, r, g, b) rec(self, "line", x1, y1, x2, y2, a, r, g, b) end
    function ISPanel:render() end

    ISButton = ISPanel:derive("ISButton")
    function ISButton.new(class, x, y, w, h, title, target, onclick)
        local o = ISPanel.new(class, x, y, math.max(w, getTextManager():MeasureStringX(UIFont.Small, title) + 10), h)
        o.title, o.target, o.onclick, o.onClickArgs = title, target, onclick, {}
        o.enable, o.font, o.pressed = true, UIFont.Small, false
        return o
    end
    function ISButton:onMouseDown() self.pressed = true end
    function ISButton:onMouseUp()
        local process = self.pressed
        self.pressed = false
        if self.enable and process and self.onclick then self.onclick(self.target, self) end
    end
    function ISButton:onMouseUpOutside() self.pressed = false end
    function ISButton:forceClick()
        if self:getIsVisible() and self.enable and self.onclick then self.onclick(self.target, self) end
    end
    function ISButton:updateTooltip() end

    ISTextEntryBox = ISPanel:derive("ISTextEntryBox")
    function ISTextEntryBox:new(title, x, y, w, h)
        local o = ISPanel.new(self, x, y, w, h)
        o.title = title
        o._text = title or ""
        return o
    end
    function ISTextEntryBox:instantiate() self.javaObject = {} end
    function ISTextEntryBox:getInternalText() return self._text end
    function ISTextEntryBox:getText() return self._text end
    function ISTextEntryBox:setText(s) self._text = s or "" end
    function ISTextEntryBox:focus() self._focused = true end
    function ISTextEntryBox:unfocus() self._focused = false end
    function ISTextEntryBox:isFocused() return self._focused == true end
    function ISTextEntryBox:setEditable(e) self._editable = e end
    function ISTextEntryBox:setOnlyNumbers() end
    function ISTextEntryBox:setMaxTextLength() end
    function ISTextEntryBox:setTextRGBA() end
    function ISTextEntryBox:setTooltip(t) self.tooltip = t end
    function ISTextEntryBox:setClearButton(b) self._clearButton = b end
end

-- ============================================================
-- 主環境
-- ============================================================
function H.load(opts)
    opts = opts or {}
    local env = { applies = 0, saves = 0, halo = {}, printed = {}, joyFocus = {}, toasts = {} }
    env.values = {}       -- ModOptions 值（id → value）
    env.gates = {}        -- sandboxGate 覆寫（名稱 → bool）
    env.dists = {}        -- sandboxDist 覆寫（名稱 → number）
    env.livestockMode = 1
    env.mp = opts.mp == true
    env.mouseDown = false
    env.viewports = { [0] = { 0, 0, 1920, 1080 }, [1] = { 960, 0, 960, 1080 } }
    env.joypads = {}
    env.policy = { can = false, tactical = false, privacy = false, allowTactical = false, allowPrivacy = false, rev = 0 }

    print = function(msg) env.printed[#env.printed + 1] = tostring(msg) end
    getText = function(key, a, b, c)
        local s = TRANSLATIONS[key] or key
        if a ~= nil then s = s:gsub("%%1", tostring(a)) end
        if b ~= nil then s = s:gsub("%%2", tostring(b)) end
        if c ~= nil then s = s:gsub("%%3", tostring(c)) end
        return s
    end
    getTextOrNull = function(key) return TRANSLATIONS[key] end
    UIFont = { Small = "Small", Medium = "Medium", NewSmall = "NewSmall", Large = "Large" }
    getTextManager = function()
        return {
            MeasureStringX = function(_, _, text) return #tostring(text or "") * 8 end,
            getFontHeight = function(_, font) return font == "Medium" and 18 or 14 end,
        }
    end
    getCore = function()
        return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end }
    end
    getMouseX = function() return 0 end
    getMouseY = function() return 0 end
    getTimestampMs = function() return 1000000 end
    getSoundManager = function() return { playUISound = function() end } end
    isMouseButtonDown = function() return env.mouseDown end
    isClient = function() return env.mp end
    Keyboard = { KEY_ESCAPE = 1, KEY_TAB = 15, KEY_RETURN = 28, KEY_NUMPADENTER = 156, KEY_SPACE = 57,
        KEY_UP = 200, KEY_DOWN = 208, KEY_LEFT = 203, KEY_RIGHT = 205, KEY_HOME = 199, KEY_END = 207,
        KEY_PRIOR = 201, KEY_NEXT = 209, KEY_LSHIFT = 42, KEY_RSHIFT = 54, KEY_LCONTROL = 29,
        KEY_RCONTROL = 157, KEY_C = 46 }
    Joypad = { AButton = 0, BButton = 1, XButton = 2, YButton = 3, LBumper = 4, RBumper = 5 }
    getJoypadData = function(pn) return env.joypads[pn] end
    JoypadState = { players = {} }
    setJoypadFocus = function(pn, el)
        env.joyFocus[pn] = el
        if env.joypads[pn] then env.joypads[pn].focus = el end
    end
    getJoypadFocus = function(pn) return env.joypads[pn] and env.joypads[pn].focus end
    NinePatchTexture = nil
    getTexture = function(path) return { path = path } end
    HaloTextHelper = { addBadText = function(_, text) env.halo[#env.halo + 1] = text end,
        addGoodText = function(_, text) env.halo[#env.halo + 1] = text end }
    local players = {}
    getSpecificPlayer = function(pn)
        if pn > 1 then return nil end
        players[pn] = players[pn] or { getX = function() return 100 end, getY = function() return 100 end,
            getUsername = function() return "P" .. pn end }
        return players[pn]
    end
    getPlayerScreenLeft = function(pn) return env.viewports[pn][1] end
    getPlayerScreenTop = function(pn) return env.viewports[pn][2] end
    getPlayerScreenWidth = function(pn) return env.viewports[pn][3] end
    getPlayerScreenHeight = function(pn) return env.viewports[pn][4] end
    local engine = {}
    local minimaps = {}
    getPlayerMiniMap = function(pn)
        if pn > 1 then return nil end
        if not minimaps[pn] then
            engine[pn] = {}
            local api = { getBoolean = function(_, n) return engine[pn][n] == true end,
                setBoolean = function(_, n, v) engine[pn][n] = v end }
            minimaps[pn] = { playerNum = pn, inner = { mapAPI = api }, visible = true,
                getAbsoluteX = function() return 1500 end, getAbsoluteY = function() return 40 end,
                isReallyVisible = function(self) return self.visible end }
        end
        return minimaps[pn]
    end
    env.engine = engine
    env.minimap = getPlayerMiniMap

    local boots, starts = {}, {}
    Events = { OnGameBoot = { Add = function(fn) boots[#boots + 1] = fn end },
        OnGameStart = { Add = function(fn) starts[#starts + 1] = fn end } }

    -- ModOptions（PZAPI 介面）：getOption 對任何 id 都有，值存 env.values；apply 照主檔尾端呼叫
    -- Core.settingsAfterApply；addTickBox 等只記錄 ESC 頁註冊
    local options = {}
    env.registered = {}
    local function option(id)
        local o = options[id]
        if not o then
            o = { id = id, getValue = function() return env.values[id] end,
                setValue = function(_, v) env.values[id] = v end }
            options[id] = o
        end
        return o
    end
    local Core = {}
    local modOptions = {
        getOption = function(_, id) return option(id) end,
        apply = function()
            env.applies = env.applies + 1
            if Core.settingsAfterApply then Core.settingsAfterApply() end
        end,
        addSeparator = function() end,
        addTitle = function() end,
        addTickBox = function(_, id) env.registered[#env.registered + 1] = id; return option(id) end,
        addSlider = function(_, id) env.registered[#env.registered + 1] = id; return option(id) end,
        addTextEntry = function(_, id) env.registered[#env.registered + 1] = id; return option(id) end,
        addComboBox = function(_, id)
            env.registered[#env.registered + 1] = id
            local o = option(id)
            o.addItem = function() end
            return o
        end,
    }
    PZAPI = { ModOptions = { save = function() env.saves = env.saves + 1 end } }
    MinidoracatMiniMapAPI = {}
    env.API = MinidoracatMiniMapAPI

    -- 框架
    MinidoracatUI = nil
    installISUI(env)
    if opts.framework ~= false then
        package.path = MUI_CLIENT .. "?.lua;" .. package.path
        for k in pairs(package.loaded) do
            if k:find("^MinidoracatUI/") then package.loaded[k] = nil end
        end
        dofile(MUI_V1)
        local files = { "TextWrap", "Focus", "Widgets/Controls", "Widgets/Window", "Widgets/Dropdown",
            "Widgets/ScrollPanel", "Widgets/NavList", "Widgets/Preview", "Widgets/Toast" }
        for i = 1, #files do require("MinidoracatUI/" .. files[i]) end
        env.UI = MinidoracatUI.v1
        if opts.framework == "old" then
            -- 舊框架：rev 16，rev 17 的旗標全 false（Toast 仍在）
            local old = {}
            for k, v in pairs(env.UI) do old[k] = v end
            old.API_REVISION = 16
            old.CAPABILITIES = {}
            for k, v in pairs(env.UI.CAPABILITIES) do old.CAPABILITIES[k] = v end
            old.CAPABILITIES.navList, old.CAPABILITIES.sliderRow = false, false
            old.CAPABILITIES.preview, old.CAPABILITIES.controlTooltips = false, false
            old.Toast = { show = function(o) env.toasts[#env.toasts + 1] = o end }
            MinidoracatUI = { v1 = old }
        end
    end

    -- 假 Core（主檔匯出面）
    MinidoracatMiniMapCore = Core
    Core.ready = true
    Core.modOptions = modOptions
    Core.getBoolOption = function(id, default)
        local v = env.values[id]
        if v == nil then return default end
        return v
    end
    Core.getComboIndex = function(id, default)
        local v = env.values[id]
        if type(v) ~= "number" then return default end
        return v
    end
    Core.getSliderValue = function(id, default, lo, hi)
        local v = env.values[id]
        if type(v) ~= "number" then v = default end
        if lo and v < lo then v = lo end
        if hi and v > hi then v = hi end
        return v
    end
    Core.sandboxGate = function(name, default, pn)
        env.lastGatePn = pn
        local v = env.gates[name]
        if v == nil then return default end
        return v
    end
    Core.sandboxDist = function(name, pn) env.lastDistPn = pn; return env.dists[name] end
    Core.livestockVisibilityMode = function() return env.livestockMode end
    Core.unifiedCsvSet = function(raw)
        local set = {}
        for key in tostring(raw or ""):gmatch("[^,]+") do
            if key ~= "-" then set[key] = true end
        end
        return set
    end
    Core.ADOTS_ART = { cow = { icon = "cow", sym = "cow.png", item = "Item_Cow" },
        deer = { icon = "deer", sym = "deer.png", item = "Item_Deer" },
        chicken = { icon = "chicken", sym = "chicken.png", item = "Item_Chicken" } }
    Core.ADOTS_SPECIES_UI = {
        { key = "cow", label = "UI_MinidoracatMiniMap_Sp_Cow", groups = { "cow" } },
        { key = "deer", label = "UI_MinidoracatMiniMap_Sp_Deer", groups = { "deer" } },
        { key = "chicken", label = "UI_MinidoracatMiniMap_Sp_Chicken", groups = { "chicken" } },
    }
    Core.ADOTS_VEHCAT_UI = {
        { key = "standard", label = "UI_MinidoracatMiniMap_VCat_Standard" },
        { key = "heavy", label = "UI_MinidoracatMiniMap_VCat_Heavy" },
    }
    Core.ADOTS_COLOR_ITEMS = { "UI_MinidoracatMiniMap_AColor_White", "UI_MinidoracatMiniMap_AColor_Green",
        "UI_MinidoracatMiniMap_AColor_Orange", "UI_MinidoracatMiniMap_AColor_SkyBlue" }
    Core.registeredZoneActions = {}
    Core.registeredPacks = {}
    Core.registeredZoneProviders = {}
    Core.hasExternalZoneProvider = function()
        for i = 1, #Core.registeredZoneProviders do
            if not Core.registeredZoneProviders[i].internal then return true end
        end
        return false
    end
    Core.zoneExternalCategories = function() return env.zoneCats or {} end
    Core.isBehindWorldMap = function(win, pn) return env.behindWorldMap == pn end
    Core.safehouseDisplayMode = function() return env.safehouseMode or 3 end
    Core.safehouseNameMode = function() return env.safehouseNameMode or 3 end
    local P = env.policy
    Core.policy = {
        hasCanSeeAll = function() return P.can end,
        readBool = function(name, default)
            if name == "AllowAdminTacticalView" then return P.allowTactical end
            if name == "AllowAdminPrivacyView" then return P.allowPrivacy end
            return default
        end,
        localTactical = function() return P.tactical end,
        localPrivacy = function() return P.privacy end,
        setLocalTactical = function(pn, v)
            P.lastPn = pn
            P.tactical = v and P.allowTactical or false
            if not P.tactical then P.privacy = false end
            P.rev = P.rev + 1
            return P.tactical
        end,
        setLocalPrivacy = function(pn, v)
            P.privacy = v and P.allowPrivacy and P.tactical or false
            P.rev = P.rev + 1
            return P.privacy
        end,
        getRevision = function() return P.rev end,
    }
    Core.adotsTexture = function(path) return path and { path = path } or nil end
    Core.poiIconTexture = function(key, colorMode) return { poi = key }, colorMode end
    Core.Skin = { iconTexture = function(key) return { icon = key } end }

    -- 主檔 test:map-text 真實作（mapTextZoom／drawMapText／markerIconSize）
    do
        local main = assert(readFile(REPO_CLIENT .. "MinidoracatMiniMap.lua"))
        local body = assert(main:match("%-%- test:map%-text:start\n(.-)\n%-%- test:map%-text:end"))
        local chunk = assert(compile("local Core, getSliderValue = ...\n" .. body))
        chunk(Core, Core.getSliderValue)
    end
    Core.drawClippedEdge = function(inner, x1, y1, x2, y2, r, g, b, a)
        inner:drawLine(nil, x1, y1, x2, y2, 1, a or 0.9, r, g, b)
    end
    -- 地圖畫法 helper：原始碼抽出的真函式（地圖與預覽共用同一份）
    do
        local dots = assert(readFile(REPO_CLIENT .. "MinidoracatMiniMap_Dots.lua"))
        local src = table.concat({
            "local Core, getComboIndex, drawMapText, adotsTexture = ...",
            "local ZDOTS_COLORS = { { 1.0, 0.62, 0.05 }, { 1.0, 0.9, 0.1 } }",
            "local ZDOTS_EDGE_A = 0.8",
            "local ADOTS_VEH_SYM = 'steeringwheel.png'",
            "local adotsBodyACache = {}",
            extractFn(dots, "drawZombieDot"), extractFn(dots, "zdotsColor"),
            extractFn(dots, "adotsDrawGlyph"), extractFn(dots, "adotsVehTexture"),
            extractFn(dots, "adotsDrawIcon"), extractFn(dots, "adotsDrawName"),
            "local function adotsStyleTexture(art, styleItem)",
            "    if styleItem and art then return { item = art.item }, true end",
            "    return { sym = art and art.sym }, false",
            "end",
            "local PALETTE = { { 1, 1, 1 }, { 0.47, 0.88, 0.37 }, { 0.9, 0.62, 0 }, { 0.45, 0.8, 1 } }",
            "local function adotsColor(id, default) return PALETTE[getComboIndex(id, default)] or PALETTE[default] end",
            "return drawZombieDot, zdotsColor, adotsDrawGlyph, adotsVehTexture, adotsDrawIcon, adotsDrawName,",
            "    adotsStyleTexture, adotsColor",
        }, "\n")
        Core.drawZombieDot, Core.zdotsColor, Core.adotsDrawGlyph, Core.adotsVehTexture, Core.adotsDrawIcon,
            Core.adotsDrawName, Core.adotsStyleTexture, Core.adotsColor =
            assert(compile(src))(Core, Core.getComboIndex, Core.drawMapText, Core.adotsTexture)
        local zones = assert(readFile(REPO_CLIENT .. "MinidoracatMiniMap_Zones.lua"))
        src = table.concat({
            "local drawMapText = ...",
            "local function iconTipText() return nil end",
            extractFn(zones, "drawBasementBadge"), extractFn(zones, "drawZoneIcon"), extractFn(zones, "drawZoneName"),
            "return drawZoneIcon, drawZoneName",
        }, "\n")
        Core.drawZoneIcon, Core.drawZoneName = assert(compile(src))(Core.drawMapText)
        local sh = assert(readFile(REPO_CLIENT .. "MinidoracatMiniMap_Safehouse.lua"))
        src = table.concat({
            "local Core, drawClippedEdge, adotsTexture, drawMapText = ...",
            "local SH_ICON = 'house.png'",
            "local shNameW, shFontH = {}, nil",
            extractFn(sh, "drawSafehouseAt"),
            "return drawSafehouseAt",
        }, "\n")
        Core.drawSafehouseAt = assert(compile(src))(Core, Core.drawClippedEdge, Core.adotsTexture, Core.drawMapText)
        local places = assert(readFile(REPO_CLIENT .. "MinidoracatMiniMap_Places.lua"))
        src = table.concat({
            "local Core = ...",
            "local HOUSE_SYM, PIN_SYM = 'house.png', 'star.png'",
            extractFn(places, "iconTexture"), extractFn(places, "drawPlaceAt"),
            "return drawPlaceAt",
        }, "\n")
        Core.drawPlaceAt = assert(compile(src))(Core)
    end
    -- 真的 _Markers.lua（圖層偏好 MarkerLayers 與 drawMarkerAt）
    assert(compile(assert(readFile(REPO_CLIENT .. "MinidoracatMiniMap_Markers.lua")), "@_Markers.lua"))()
    if not MinidoracatMiniMapPOICategories then dofile(REPO_SHARED .. "MinidoracatMiniMapPOICategories.lua") end

    -- 真的 _Settings.lua
    local settingsPath = opts.settingsPath or H.SETTINGS
    assert(compile(assert(readFile(settingsPath)), "@_Settings.lua"))()
    env.Core = Core

    function env.boot() for i = 1, #boots do boots[i]() end end
    function env.start() for i = 1, #starts do starts[i]() end end
    function env.studio() return Core.settingsWindow() end
    function env.frame()
        local s = Core.settingsWindow()
        if s and s.win:isVisible() then s.win:prerender() end
    end
    -- 開窗（小地圖齒輪：outer＝該玩家小地圖）
    function env.open(pn)
        Core.toggleSettingsWindow(getPlayerMiniMap(pn or 0))
        return Core.settingsWindow()
    end
    -- inspector 現有控制項（依類型／條件）
    function env.controls(pred)
        local s = Core.settingsWindow()
        local out = {}
        for _, el in ipairs(s and s.controls or {}) do
            if pred(el) then out[#out + 1] = el end
        end
        return out
    end
    function env.byKey(key)
        local s = Core.settingsWindow()
        return s and s.find(key)
    end
    function env.type(el) return getmetatable(el) and getmetatable(el).Type end
    function env.labelOf(el) return el.label or el.title or (el._lines and el._lines[1]) end
    return env
end

return H
