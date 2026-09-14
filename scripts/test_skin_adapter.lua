--[[
皮膚 adapter 煙霧測試：MinidoracatMiniMap_Skin.lua 現為家族 UI 框架
（MinidoracatUIFor42）的 thin adapter，本測試驗五態：

    lua scripts/test_skin_adapter.lua        （repo 根目錄執行；標準 Lua 5.x）
    lua scripts/test_skin_adapter.lua --family-floats
      （另載同層公告／交易浮鈕，驗三包共用同一份 layout.ini）

  A. 框架在場：fill/border、rev3 toggle／slider painters 與 Studio icons 轉發；
     9-slice 落點含絕對座標＋自身捲動補償＋floor。fits/reset 同步走框架。
  B. 框架缺席：fill/border、toggle 與 slider 走直角退回，icon 回 false 讓
     consumer 顯示純文字；fits 恆 false且全程不炸。
  C. Core 門檻：Core 缺席／未 ready 時 adapter 早退、不掛 Core.Skin。
  D. FloatIcon wrapper：框架浮鈕與 MiniMap 業務回呼、顯示收斂。
     同場重生的玩家空窗／主槽恢復／選項關閉／分屏隔離。
  D2. 位置持久化＝原版 layout.ini：載入**真的** ISLayoutManager.lua，只把原生
     檔案 API（getFileReader／getFileWriter／cacheFileExists）換成記憶體殼，
     所以 WriteIni→ReadIni→重建實例跑的是原版序列化與解析度配對本身。
     驗拖曳放開立即落盤、依解析度各自記錄、ModOptions 舊位置一次性遷移。
     全程只碰記憶體，不讀寫真的 layout.ini／ModOptions.ini，也不啟動遊戲。
  E. 主檔工具列 icon consumer：定位狀態／複製／文字退回。
框架自身行為由框架 repo 的 smoke_harness 覆蓋；此處只驗 adapter 契約。

可覆寫路徑（環境變數，皆可選）：
  MUI_LUA        家族框架 V1.lua
  PZ_LUA         原版 media/lua（取 ISUI/ISLayoutManager.lua）
  MM_FLOAT_LUA   小地圖浮鈕候選檔（預設走本 repo production）
  NB_FLOAT_LUA   公告浮鈕候選檔；EC_FLOAT_LUA 交易浮鈕候選檔（同上）
]]

local SKIN = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Skin.lua"
local MUI_V1 = os.getenv("MUI_LUA")
    or "../MinidoracatUIFor42/MOD/MinidoracatUIFor42/Contents/mods/MinidoracatUIFor42/42/media/lua/client/MinidoracatUI/V1.lua"
local MAIN = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local MM_FLOAT = os.getenv("MM_FLOAT_LUA")
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_FloatIcon.lua"
local PZ_LUA = os.getenv("PZ_LUA") or "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua"
local ISLM = PZ_LUA .. "/client/ISUI/ISLayoutManager.lua"
local NB_DIR = "../MinidoracatNoticeBoardFor42/MOD/MinidoracatNoticeBoardFor42/Contents/mods/MinidoracatNoticeBoardFor42/42/media/lua/client/NoticeBoard/"
local EC_DIR = "../MinidoracatEconomyFor42/MOD/MinidoracatEconomyFor42/Contents/mods/MinidoracatEconomyFor42/42/media/lua/client/MinidoracatEconomy/"
local NB_FLOAT = os.getenv("NB_FLOAT_LUA") or (NB_DIR .. "NBFloatButton.lua")
local EC_FLOAT = os.getenv("EC_FLOAT_LUA") or (EC_DIR .. "ECFloatButton.lua")
local familyFloats = arg[1] == "--family-floats"

-- 缺前提一律 SKIP＋exit 0（明寫 SKIP，不是 PASS）；有跑就要過末尾條數守門
local function requireFile(path, hint)
    local probe = io.open(path, "rb")
    if probe then probe:close(); return end
    print("SKIP test_skin_adapter: not found " .. path)
    print("     (" .. hint .. ")")
    os.exit(0)
end

requireFile(MUI_V1, "clone MinidoracatUIFor42 beside this repo, or set MUI_LUA=<path to V1.lua>")
requireFile(MM_FLOAT, "set MM_FLOAT_LUA=<path to MinidoracatMiniMap_FloatIcon.lua>")
requireFile(ISLM, "set PZ_LUA=<ProjectZomboid media/lua>; the shipped ISLayoutManager.lua drives layout.ini")
requireFile(PZ_LUA .. "/client/PZAPI/ModOptions.lua", "set PZ_LUA; the shipped ModOptions load/save drives the menu-upgrade regression")
if familyFloats then
    requireFile(NB_DIR .. "NBSkin.lua", "clone MinidoracatNoticeBoardFor42 beside this repo")
    requireFile(NB_FLOAT, "clone MinidoracatNoticeBoardFor42, or set NB_FLOAT_LUA=<path to NBFloatButton.lua>")
    requireFile(EC_FLOAT, "clone MinidoracatEconomyFor42, or set EC_FLOAT_LUA=<path to ECFloatButton.lua>")
end

local failures = 0
local assertionCount = 0
local function check(ok, label)
    assertionCount = assertionCount + 1
    if ok then print("  PASS  " .. label)
    else failures = failures + 1; print("  FAIL  " .. label) end
end
local function nearly(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

-- ===== 最小 PZ 全域（_Skin.lua 的載入需求）=====
_G.require = function() return nil end -- adapter 內 pcall(require,...) 安全空轉

local function newElement(absX, absY, scrollX, scrollY)
    local el = { rects = {}, borders = {}, tex = {} }
    function el:getAbsoluteX() return absX end
    function el:getAbsoluteY() return absY end
    function el:getXScroll() return scrollX or 0 end
    function el:getYScroll() return scrollY or 0 end
    function el:drawRect(x, y, w, h, a, r, g, b)
        el.rects[#el.rects + 1] = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
    end
    function el:drawRectBorder(x, y, w, h, a, r, g, b)
        el.borders[#el.borders + 1] = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
    end
    function el:drawTextureScaled(texture, x, y, w, h, a, r, g, b)
        el.tex[#el.tex + 1] = { texture = texture, x = x, y = y, w = w, h = h,
            a = a, r = r, g = g, b = b }
    end
    return el
end

local function loadSkin()
    -- _Skin.lua 開頭的 Core.ready 門檻：給最小 Core 讓它掛 Core.Skin
    _G.MinidoracatMiniMapCore = { ready = true }
    dofile(SKIN)
    return _G.MinidoracatMiniMapCore.Skin, _G.MinidoracatMiniMapCore
end

-- ============================================================
print("態 A：框架在場（轉發）")
-- ============================================================
do
    dofile(MUI_V1)
    check(MinidoracatUI ~= nil and MinidoracatUI.v1 ~= nil, "框架 facade 已發布")

    local Skin, Core = loadSkin()
    check(Skin ~= nil and Core.Skin == Skin, "adapter 掛上 Core.Skin")
    check(Skin.COLORS.BG_PANEL.a == 0.8 and Skin.COLORS.ROW_HOVER.a == 0.06
        and Skin.COLORS.ACCENT_AMBER.r == 1, "COLORS 色票保留（BG_PANEL/ROW_HOVER/ACCENT_AMBER 抽查）")

    -- 9-slice 落點：stub NinePatchTexture（模擬引擎首呼叫回 null）
    local calls, patches = {}, {}
    _G.NinePatchTexture = {
        getSharedTexture = function(path)
            calls[path] = (calls[path] or 0) + 1
            if calls[path] == 1 then return nil end
            return { render = function(_, x, y, w, h, r, g, b, a)
                patches[#patches + 1] = { path = path, x = x, y = y, w = w, h = h, r = r, g = g, b = b, a = a }
            end }
        end,
    }
    Skin.reset() -- 轉發框架 _resetForTests，不得炸
    -- Search.lua:322 生產形狀：捲動清單列（yScroll 非零）＋小數座標
    local row = newElement(200.0, 100.0, 0, -37)
    Skin.fill(row, 2.6, 11.4, 300, 24, Skin.COLORS.ROW_SELECTED)
    check(#patches == 1 and patches[1].path == "media/ui/MinidoracatUI/mui_round_fill.png",
        "態A fill 轉發框架 9-slice（round fill 貼圖）")
    check(patches[1].x == 202 and patches[1].y == 74,
        "態A 絕對座標＋自身捲動補償＋floor（202.6→202、74.4→74）——列高亮不錯位的關鍵")
    Skin.fill(row, 0, 0, 300, 20, Skin.COLORS.TITLEBAR_FILL, true, 0.5)
    check(patches[#patches].path == "media/ui/MinidoracatUI/mui_roundtop_fill.png"
        and nearly(patches[#patches].a, 0.10 * 0.5),
        "態A topOnly boolean 直通＋alphaScale 乘算（標題列生產形狀）")
    Skin.border(row, 0, 0, 300, 24, Skin.COLORS.BORDER)
    check(patches[#patches].path == "media/ui/MinidoracatUI/mui_round_border.png",
        "態A border 轉發框架（round border 貼圖）")
    check(Skin.fits(12, 12, false) == true and Skin.fits(11, 12, false) == false
        and Skin.fits(12, 6, true) == true, "態A fits 走框架夾限（12x12／roundTop 12x6）")
    _G.getTexture = function(path) return { path = path } end
    Skin.reset()
    local toggleOk = Skin.toggle(row, 0, 0, 38, 22, true)
    check(toggleOk ~= false and patches[#patches - 1].path:find("mui_pill_fill.png", 1, true)
        and patches[#patches].path:find("mui_pill_border.png", 1, true),
        "態A toggle 轉發 rev3 專用 pill fill/border")
    check(#row.tex >= 2 and row.tex[#row.tex].x == 20,
        "態A toggle on 的圓形 knob 位於右側")
    local sliderEl = newElement(0, 0)
    check(Skin.slider(sliderEl, 0, 0, 100, 20, 0.5) == true
        and #sliderEl.rects == 2 and #sliderEl.borders == 1
        and sliderEl.tex[#sliderEl.tex].x == 44,
        "態A slider 轉發 rev3 現代 track/fill/圓形 knob")
    for _, key in ipairs({ "layers", "lock", "unlock", "locate", "copy" }) do
        local iconOk = Skin.icon(row, key, 4, 5, 16, Skin.COLORS.TEXT_MUTED)
        check(iconOk == true
            and row.tex[#row.tex].texture.path:find(
                "mui_icon_" .. key .. ".png", 1, true),
            "態A Studio icon 轉發 rev3 Icons.draw：" .. key)
    end
    check(Skin.icon(row, "missing", 0, 0, 16) == false,
        "態A 未知 icon fail-soft 供 consumer 退純文字")
    _G.getTexture = nil
    _G.NinePatchTexture = nil
    Skin.reset()
end

-- ============================================================
print("態 B：框架缺席（退回紅線）")
-- ============================================================
do
    _G.MinidoracatUI = nil -- 拔掉框架後重載 adapter：FW 綁 nil
    local Skin = loadSkin()
    local el = newElement(999, 999) -- 絕對座標不得被退回路徑使用
    local okAll = pcall(function()
        Skin.fill(el, 1, 2, 300, 50, Skin.COLORS.BG_PANEL, false, 0.5)
        Skin.border(el, 1, 2, 300, 50, Skin.COLORS.BORDER)
        Skin.reset()
    end)
    check(okAll, "態B fill/border/reset 全程不炸")
    check(#el.rects == 1 and #el.borders == 1, "態B fill→drawRect、border→drawRectBorder")
    check(el.rects[1].x == 1 and el.rects[1].w == 300 and nearly(el.rects[1].a, 0.8 * 0.5),
        "態B 退回矩形用相對座標且 alphaScale 有效")
    check(Skin.fits(500, 500, false) == false, "態B fits 恆 false（無貼圖可畫）")
    local toggleEl = newElement(0, 0)
    local fallbackOk, fallbackPainted = pcall(Skin.toggle, toggleEl, 0, 0, 38, 22, true)
    check(fallbackOk and fallbackPainted == true
        and #toggleEl.rects == 2 and #toggleEl.borders == 1,
        "態B toggle 缺框架仍回 true 並畫直角 track/knob")
    check(Skin.icon(toggleEl, "layers", 0, 0, 16) == false,
        "態B icon 缺框架回 false，不留下空白功能")
    local sliderEl = newElement(0, 0)
    check(Skin.slider(sliderEl, 0, 0, 100, 20, 0.5,
        { fill = { r = 1, g = 0.5, b = 0.2, a = 1 } }) == true
        and #sliderEl.rects == 3,
        "態B slider 缺框架／部分色票仍畫 track/fill/knob")
end

-- ============================================================
print("態 C：Core 門檻（半初始化防線）")
-- ============================================================
do
    _G.MinidoracatMiniMapCore = nil
    local okNil = pcall(dofile, SKIN)
    check(okNil and _G.MinidoracatMiniMapCore == nil, "態C Core 缺席：早退不炸、不建 Core")
    _G.MinidoracatMiniMapCore = { ready = false }
    local okNotReady = pcall(dofile, SKIN)
    check(okNotReady and _G.MinidoracatMiniMapCore.Skin == nil,
        "態C Core.ready=false：早退且不掛 Core.Skin（版本檢查未過時本節不存在）")
end

-- ============================================================
print("態 D：FloatIcon wrapper（業務綁定——點擊/右鍵/位置持久化/顯示收斂）")
-- ============================================================
do
    -- 框架 widget 需要的最小 vanilla 面（拖曳/門檻/clamp 本體由框架 harness 覆蓋，
    -- 這裡只驗 wrapper 把 MiniMap 業務綁對）
    local players, elements = { [0] = {} }, {}
    local ISPanelStub = {}
    ISPanelStub.__index = ISPanelStub
    function ISPanelStub:derive(name)
        local c = setmetatable({ Type = name }, self); c.__index = c; return c
    end
    function ISPanelStub.new(class, x, y, w, h)
        local o = setmetatable({}, class)
        o.x, o.y, o.width, o.height = x, y, w, h
        o.visible = true
        return o
    end
    function ISPanelStub:initialise() end
    function ISPanelStub:setX(x) self.x = x end
    function ISPanelStub:setY(y) self.y = y end
    function ISPanelStub:getX() return self.x end
    function ISPanelStub:getY() return self.y end
    function ISPanelStub:getAbsoluteY() return self.y end
    function ISPanelStub:getHeight() return self.height end
    function ISPanelStub:setVisible(v) self.visible = v end
    function ISPanelStub:getIsVisible() return self.visible end
    -- 模擬 UIManager flush 後的順序：同物件重 add 會移到尾端，不只是集合去重。
    function ISPanelStub:addToUIManager()
        if self._nativeAlwaysOnTop == nil then self._nativeAlwaysOnTop = false end
        self:removeFromUIManager()
        elements[#elements + 1] = self
    end
    function ISPanelStub:removeFromUIManager()
        for i = #elements, 1, -1 do
            if elements[i] == self then table.remove(elements, i); return end
        end
    end
    function ISPanelStub:setAlwaysOnTop(value)
        if self._nativeAlwaysOnTop ~= nil then self._nativeAlwaysOnTop = value end
    end
    -- UIManager.java:545-556 將原生置頂元件穩定移到最後；Lua 欄位不參與。
    local function flushLayers()
        local normal, top = {}, {}
        for _, element in ipairs(elements) do
            local layer = element._nativeAlwaysOnTop and top or normal
            layer[#layer + 1] = element
        end
        for _, element in ipairs(top) do normal[#normal + 1] = element end
        elements = normal
    end
    function ISPanelStub:bringToTop() self:addToUIManager() end
    function ISPanelStub:setCapture() end
    function ISPanelStub:isMouseOver() return false end
    function ISPanelStub:drawTextureScaled() end
    function ISPanelStub:drawTextCentre() end
    function ISPanelStub:drawRect() end
    function ISPanelStub:drawRectBorder() end
    _G.ISPanel = ISPanelStub
    local screenW, screenH = 1920, 1080 -- 可變：解析度切換走真事件路徑
    local mouseX, mouseY = 0, 0
    local gameMode = "Sandbox"
    _G.getCore = function()
        return {
            getScreenWidth = function() return screenW end,
            getScreenHeight = function() return screenH end,
            getKey = function() return 53 end,
            getGameMode = function() return gameMode end,
        }
    end
    _G.getMouseX = function() return mouseX end
    _G.getMouseY = function() return mouseY end
    _G.getTimestampMs = function() return 5000000 end
    _G.getSpecificPlayer = function(pn) return players[pn] end
    _G.getTexture = function() return nil end -- 缺圖路徑：drawContent 畫 M
    _G.getText = function(key, a) return "[" .. tostring(key) .. (a and ("|" .. tostring(a)) or "") .. "]" end
    _G.getKeyName = function() return "SLASH" end
    _G.UIFont = { Small = "Small", Medium = "Medium", NewSmall = "NewSmall" }
    _G.getTextManager = function()
        return { getFontHeight = function() return 12 end,
            MeasureStringX = function(_, _, t) return string.len(t) * 10 end }
    end
    -- 事件表可重建：冷啟動換新表，舊 module 的處理器不會留下幽靈單例
    local function installEvents()
        _G.Events = setmetatable({}, { __index = function(events, name)
            local handlers = {}
            local event = { Add = function(fn) handlers[#handlers + 1] = fn end, handlers = handlers }
            rawset(events, name, event)
            return event
        end })
    end
    installEvents()
    local function fire(name, ...)
        for _, fn in ipairs(Events[name].handlers) do fn(...) end
    end
    -- 廣播面：拖曳只准直呼 ISLayoutManager.OnPostSave，不准廣播 OnPostSave
    -- （廣播會連帶觸發其他 MOD 掛在存檔時機的整包寫入）
    local broadcasts = {}
    _G.triggerEvent = function(name, ...)
        broadcasts[name] = (broadcasts[name] or 0) + 1
        fire(name, ...)
    end
    local savedCalls = 0
    _G.PZAPI = { ModOptions = { save = function() savedCalls = savedCalls + 1 end } }

    -- ===== 記憶體檔案殼：原生檔案 API 的唯一替身 =====
    -- 只換 I/O；ini 的序列化／解析與解析度配對全由真原版 ISLayoutManager 跑，
    -- 測試這邊不重寫任何一行演算法。真 layout.ini／ModOptions.ini 全程不被碰。
    local vfs, writeCount = {}, {}
    local failWrite, unreadable
    local function resetDisk(files)
        vfs, writeCount = {}, {}
        for name, text in pairs(files or {}) do vfs[name] = text end
    end
    local function writes(name) return writeCount[name] or 0 end
    _G.cacheFileExists = function(name) return vfs[name] ~= nil end
    _G.getFileReader = function(name, createIfMissing)
        if unreadable == name then return nil end -- 檔在、但開不起來（權限／IO 壞）
        if vfs[name] == nil then
            if not createIfMissing then return nil end
            vfs[name] = ""
        end
        local text, pos = vfs[name], 1
        local reader = {}
        function reader:readLine()
            if pos > #text then return nil end
            local line
            local from, to = string.find(text, "\r?\n", pos)
            if from then line, pos = string.sub(text, pos, from - 1), to + 1
            else line, pos = string.sub(text, pos), #text + 1 end
            return line
        end
        function reader:close() pos = #text + 1 end
        return reader
    end
    _G.getFileWriter = function(name, _, append)
        if failWrite == name then error("simulated write failure: " .. name) end
        local buffer, writer = {}, {}
        function writer:write(text) buffer[#buffer + 1] = text end
        function writer:close()
            vfs[name] = (append and (vfs[name] or "") or "") .. table.concat(buffer)
            writeCount[name] = (writeCount[name] or 0) + 1
        end
        return writer
    end

    -- 原版 ISLayoutManager 用到的引擎字串函式（Java 注入面），照原語意補上
    function string.trim(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end
    function string.split(s, sep)
        local out = {}
        for field in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = field end
        return out
    end
    _G.luautils = {
        stringStarts = function(s, start) return string.sub(s, 1, string.len(start)) == start end,
        split = function(s, sep) return string.split(s, sep or "%s") end,
    }
    _G.ISUIHandler = {} -- 原版 SaveWindowVisible 會查 visibleUI（本家族不寫可見性）
    dofile(ISLM)

    -- 讀回磁碟上的 layout.ini 做斷言：只認格式，不重算位置
    local function iniRows()
        local out, res = {}, nil
        for line in string.gmatch((vfs["layout.ini"] or "") .. "\n", "(.-)\r?\n") do
            local w, h = string.match(line, "^%[(%d+)x(%d+)%]$")
            if w then
                res = w .. "x" .. h
                out[res] = out[res] or {}
            elseif res and line ~= "" then
                local row = { name = string.match(line, "^(%S+)"), fields = 0 }
                for key, value in string.gmatch(line, "(%w+)=(%S+)") do
                    row[key] = value
                    row.fields = row.fields + 1
                end
                out[res][row.name] = row
            end
        end
        return out
    end
    local function rowAt(res, name)
        local section = iniRows()[res]
        return section and section[name] or nil
    end

    -- 真拖曳（框架 setCapture 五件套）：按下→超過 4px 門檻的移動→放開
    local function dragHold(btn, toX, toY)
        mouseX, mouseY = btn:getX() + 5, btn:getY() + 5
        btn:onMouseDown(5, 5)
        mouseX, mouseY = toX + 5, toY + 5
        btn:onMouseMove(0, 0)
    end
    local function dragRelease(btn) btn:onMouseUp(5, 5) end
    local function drag(btn, toX, toY) dragHold(btn, toX, toY); dragRelease(btn) end

    -- 重載框架（態 B 拔掉了）＋widget
    dofile(MUI_V1)
    local MUI_DIR = MUI_V1:gsub("V1%.lua$", "")
    dofile(MUI_DIR .. "Widgets/FloatButton.lua")
    check(MinidoracatUI.v1.CAPABILITIES.floatButton == true, "態D 框架 FloatButton 能力就緒")

    _G.__floatIconOptionOn = true
    -- Core stub：位置持久化已移交原版 layout.ini，ModOptions 只留計數器當負面證據
    local toggles, ghosts = 0, 0
    local core = {
        ready = true,
        -- FloatIconPos 選項已退役：getOption 一律 nil，浮鈕不得再依賴它
        modOptions = { getOption = function() return nil end },
        -- 間接旗標：_FloatIcon 載入期會把 Core.getBoolOption 快取成 local，
        -- 事後換函式無效——換旗標值才動得了它
        getBoolOption = function(_, default) return _G.__floatIconOptionOn end,
        debugWarn = { renderMode = function() return nil end, text = function() return nil end },
        togglePlayerMiniMap = function() toggles = toggles + 1 end,
        toggleGhost = function() ghosts = ghosts + 1 end,
        isGhost = function() return false end,
    }
    _G.MinidoracatMiniMapCore = core
    dofile(MM_FLOAT)

    fire("OnCreatePlayer", 1, {})
    check(core._floatIcon == nil, "態D 非主玩家建立不新增主玩家浮鈕")
    fire("OnGameStart")
    local icon = core._floatIcon
    check(icon ~= nil, "態D 顯示收斂點經框架建立浮鈕（Core._floatIcon 觀察面）")
    check(icon.width == 40 and icon.height == 40, "態D 小地圖開關採家族 40x40 點擊區域")

    -- onClick / onRightClick 業務綁定
    icon.onClick(icon)
    check(toggles == 1, "態D 點擊綁 togglePlayerMiniMap")
    icon.onRightClick(icon)
    check(ghosts == 1, "態D 右鍵綁 Core.toggleGhost")

    -- 位置持久化的斷言全在態 D2（真 ini 往返）；這裡只把圖標拖到已知位置，
    -- 讓底下的重生／分屏斷言有一個「非預設且已落盤」的座標可比對
    drag(icon, 200, 300)
    local notice, economy -- 家族浮鈕單例（冷啟動後重新取得）

    -- tooltip 文字組裝（快捷鍵名＋ghost 熱鍵行；-debug 無資料不附加）
    local desc, maxW = icon.getTooltipText(icon)
    check(type(desc) == "string" and desc:find("SLASH", 1, true) ~= nil
        and desc:find("ghost_tip", 1, true) ~= nil and maxW == 300,
        "態D tooltip 含當前快捷鍵與 ghost 熱鍵行")

    -- 選項關閉 → 隱藏（tip 同步收掉不炸）
    _G.__floatIconOptionOn = false
    core.updateFloatIconVisibility()
    check(icon:getIsVisible() == false, "態D 選項關閉：浮鈕隱藏")
    fire("OnCreatePlayer", 0, players[0])
    check(not icon:getIsVisible(), "態D 重生仍尊重關閉浮鈕選項")
    _G.__floatIconOptionOn = true
    core.updateFloatIconVisibility()
    -- 原版 accept 還原 UI 後先清 players[0]；AddCoopPlayer 多 tick 後才補回。
    players[0] = nil
    icon:prerender()
    check(not icon:getIsVisible(), "態D 建角空窗由真 FloatButton 自我隱藏")
    players[0] = {}
    fire("OnCreatePlayer", 0, players[0])
    check(icon:getIsVisible() and icon:getX() == 200 and icon:getY() == 300,
        "態D 同槽新角色恢復圖標與保存位置，不靠 OnGameStart")
    fire("OnCreatePlayer", 0, players[0])
    check(#elements == 1, "態D 重複角色事件不累加浮鈕")
    icon:setVisible(false)
    fire("OnCreatePlayer", 1, {})
    check(not icon:getIsVisible(), "態D 分屏建角不喚醒已隱藏的主玩家浮鈕")

    if familyFloats then
        _G.NBClient = { getUnreadIds = function() return {} end,
            UNREAD_CHANGED_EVENT = "MinidoracatNB_UnreadChanged" }
        _G.NBPanel = { toggle = function() end }
        dofile(NB_DIR .. "NBSkin.lua")
        dofile(NB_FLOAT)
        local client = true
        _G.isClient = function() return client end
        _G.MinidoracatEconomy = {
            CURRENCIES = { survivor = { iconDefault = "media/ui/MinidoracatEconomy/currency_survivor.png" } },
            Client = { Panel = { toggle = function() end } },
        }
        dofile(EC_FLOAT)
        fire("OnGameStart")
        notice, economy = NBFloatButton.instance, MinidoracatEconomy.Client.FloatButton.instance
        local buttons = { icon, notice, economy }
        local function visible(a, b, c)
            return icon:getIsVisible() == a and notice:getIsVisible() == b and economy:getIsVisible() == c
        end
        local laterWindow = ISPanelStub.new(ISPanelStub, 200, 300, 40, 40)
        laterWindow:addToUIManager()
        flushLayers()
        check(elements[#elements] == laterWindow,
            "家族浮鈕不越過後開視窗的原生繪製層級")
        check(notice.width == icon.width and notice.height == icon.height
            and economy.width == icon.width and economy.height == icon.height,
            "家族浮鈕：三個實際 consumer 的點擊區域一致")
        notice:setPosition(270, 310); economy:setPosition(340, 320)
        players[0] = nil
        for _, button in ipairs(buttons) do button:prerender() end
        check(visible(false, false, false) and #elements == 4,
            "家族浮鈕：建角空窗只隱藏，三個單例仍在 UI 清單")
        players[0] = {}
        fire("OnCreatePlayer", 0, players[0])
        check(visible(true, true, true) and icon:getX() == 200 and icon:getY() == 300
            and notice:getX() == 270 and notice:getY() == 310
            and economy:getX() == 340 and economy:getY() == 320,
            "家族浮鈕：同場新角色恢復全部圖標並保留各自拖曳位置")
        fire("OnCreatePlayer", 0, players[0]); fire("OnGameStart")
        check(#elements == 4 and elements[1] == notice and elements[2] == economy
            and elements[3] == laterWindow and elements[4] == icon,
            "家族浮鈕：公告交易保留層級、小地圖沿用 bringToTop，不新增圖標")
        for _, button in ipairs(buttons) do button:setVisible(false) end
        fire("OnCreatePlayer", 1, {})
        check(visible(false, false, false), "家族浮鈕：ESC 隱藏期間，其他分屏角色不強開主玩家 UI")
        _G.__floatIconOptionOn = false
        players[0] = {}
        fire("OnCreatePlayer", 0, players[0])
        check(visible(false, true, true), "家族浮鈕：小地圖選項關閉不妨礙另外兩個入口恢復")
        economy:setVisible(false); client = false
        fire("OnCreatePlayer", 0, players[0])
        check(not economy:getIsVisible(), "家族浮鈕：交易入口重生後仍遵守 MP client 限制")
        client = true
    end

    -- ============================================================
    print()
    print("態 D2：原版 layout.ini 位置持久化（真 ISLayoutManager＋記憶體檔案殼）")
    -- ============================================================
    -- 冷啟動＝新 session 的最小模型：UI 清單、事件表、ISLayoutManager 快取與
    -- 各包單例全部歸零後重新載入，只有「磁碟」（vfs）延續。因此還原路徑必須
    -- 真的經過 WriteIni 寫出的文字再 ReadIni 回來，不是讀記憶體裡的殘留狀態。
    local function coldBoot(menuOnly)
        for i = #elements, 1, -1 do table.remove(elements, i) end
        installEvents()
        dofile(ISLM) -- windows 歸零、layouts 回 nil（下次 TryRestore 重讀 ini）
        core._floatIcon = nil
        dofile(MM_FLOAT)
        if familyFloats then
            _G.NBFloatButton = nil -- 清 _eventsInstalled：事件重掛到新事件表
            dofile(NB_FLOAT)
            dofile(EC_FLOAT)
        end
        fire("OnGameBoot")
        if menuOnly then return end
        fire("OnGameStart")
        icon = core._floatIcon
        if familyFloats then
            notice = NBFloatButton.instance
            economy = MinidoracatEconomy.Client.FloatButton.instance
        end
    end
    local function changeResolution(w, h)
        local oldW, oldH = screenW, screenH
        screenW, screenH = w, h -- 引擎先更新尺寸才發事件（Core.java:2242-2262）
        fire("OnResolutionChange", oldW, oldH, w, h)
    end
    local MM_NAME = "MinidoracatMiniMapFloatIcon"

    _G.__floatIconOptionOn = true
    players[0] = {}

    -- 各解析度的「初次預設」取空磁碟冷啟動的觀察值：測試不重算 consumer 的公式
    resetDisk({}); coldBoot()
    local def1080X, def1080Y = icon:getX(), icon:getY()
    screenW, screenH = 1280, 720
    resetDisk({}); coldBoot()
    local def720X, def720Y = icon:getX(), icon:getY()
    screenW, screenH = 1920, 1080

    resetDisk({}); coldBoot()
    dragHold(icon, 640, 500)
    check(icon:getX() == 640 and icon:getY() == 500 and writes("layout.ini") == 0
        and not string.find(vfs["layout.ini"] or "", MM_NAME, 1, true),
        "態D2 拖曳中（未放開）位置即時跟手但不落盤")
    dragRelease(icon)
    local row = rowAt("1920x1080", MM_NAME)
    check(row ~= nil and tonumber(row.x) == 640 and tonumber(row.y) == 500,
        "態D2 放開立即寫入當前解析度區段（原版 WriteIni 真路徑）")
    check(writes("layout.ini") == 1 and (broadcasts.OnPostSave or 0) == 0 and savedCalls == 0,
        "態D2 只寫一次、不廣播 OnPostSave 事件、也不再碰 ModOptions")
    check(row.fields == 2 and row.visible == nil,
        "態D2 記錄只有 x/y：不寫可見性（原版 visible 欄位退役）")

    coldBoot()
    check(icon:getX() == 640 and icon:getY() == 500,
        "態D2 同解析度重開遊戲：經 ini 往返還原拖曳位置")
    local writesBefore = writes("layout.ini")
    changeResolution(1280, 720)
    check(icon:getX() == def720X and icon:getY() == def720Y and icon:getIsVisible()
        and writes("layout.ini") == writesBefore,
        "態D2 換到無記錄解析度：用該解析度初次預設、不借舊解析度座標、不落盤也不動可見性")
    drag(icon, 300, 200)
    check(tonumber((rowAt("1280x720", MM_NAME) or {}).x) == 300
        and tonumber((rowAt("1920x1080", MM_NAME) or {}).x) == 640,
        "態D2 兩個解析度各自記錄並存（新解析度存檔不覆蓋舊解析度）")
    changeResolution(1920, 1080)
    check(icon:getX() == 640 and icon:getY() == 500,
        "態D2 切回原解析度：還原該解析度自己的記錄")

    _G.__floatIconOptionOn = false
    core.updateFloatIconVisibility()
    changeResolution(1280, 720)
    check(not icon:getIsVisible() and icon:getX() == 300 and icon:getY() == 200,
        "態D2 圖標關閉期間換解析度：座標照還原但不把圖標強開回來")
    ISLayoutManager.OnPostSave()
    local hiddenRow = rowAt("1280x720", MM_NAME)
    check(not icon:getIsVisible() and hiddenRow ~= nil and hiddenRow.fields == 2
        and hiddenRow.visible == nil and tonumber(hiddenRow.x) == 300,
        "態D2 存檔時機保存隱藏中的圖標：只記座標、不記可見性，也不強開強關")
    _G.__floatIconOptionOn = true
    core.updateFloatIconVisibility()
    screenW, screenH = 1920, 1080

    -- ===== 舊 ModOptions 位置一次性遷移（原生記錄＝遷移完成標記）=====
    local OTHER_MOD = "tickbox|SomeOtherMod|Foo|true\r\n"
    local function legacyFile(value)
        return OTHER_MOD .. "textentry|MinidoracatMiniMap|FloatIconPos|" .. value .. "\r\n"
    end
    local legacy = legacyFile("700,400")

    resetDisk({ ["ModOptions.ini"] = legacy })
    coldBoot()
    check(icon:getX() == 700 and icon:getY() == 400
        and tonumber((rowAt("1920x1080", MM_NAME) or {}).x) == 700
        and tonumber((rowAt("1920x1080", MM_NAME) or {}).y) == 400
        and vfs["ModOptions.ini"] == legacy,
        "態D2 舊 FloatIconPos 一次遷入當前解析度記錄，且舊設定檔原樣保留")
    vfs["ModOptions.ini"] = legacyFile("900,900") -- 舊值事後被改：已遷移就不該再看
    coldBoot()
    check(icon:getX() == 700 and icon:getY() == 400,
        "態D2 已有原生記錄：舊值不再參與（記錄本身就是遷移完成依據）")

    resetDisk({ ["ModOptions.ini"] = legacy,
        ["layout.ini"] = "[1280x720]\r\n" .. MM_NAME .. " x=111 y=222\r\n" })
    coldBoot()
    check(icon:getX() == def1080X and icon:getY() == def1080Y
        and rowAt("1920x1080", MM_NAME) == nil
        and tonumber((rowAt("1280x720", MM_NAME) or {}).x) == 111,
        "態D2 別的解析度已有記錄：當前解析度用預設，不借舊座標也不新增列")

    resetDisk({ ["ModOptions.ini"] = legacyFile("abc,def") })
    coldBoot()
    check(icon:getX() == def1080X and icon:getY() == def1080Y
        and writes("layout.ini") == 0 and rowAt("1920x1080", MM_NAME) == nil,
        "態D2 無效舊值：回預設、不造座標、不寫 ini")

    resetDisk({ ["ModOptions.ini"] = legacy })
    failWrite = "layout.ini"
    pcall(coldBoot)
    failWrite = nil
    check(vfs["ModOptions.ini"] == legacy and rowAt("1920x1080", MM_NAME) == nil,
        "態D2 遷移寫入失敗：不改寫也不刪除舊設定檔（來源永遠唯讀）")
    coldBoot()
    check(icon:getX() == 700 and icon:getY() == 400
        and tonumber((rowAt("1920x1080", MM_NAME) or {}).x) == 700,
        "態D2 寫入失敗沒被當成功：下次啟動仍會重試遷移")

    resetDisk({ ["ModOptions.ini"] = legacy })
    unreadable = "ModOptions.ini"
    pcall(coldBoot)
    unreadable = nil
    check(core._floatIcon == nil and rowAt("1920x1080", MM_NAME) == nil
        and vfs["ModOptions.ini"] == legacy,
        "態D2 舊設定檔在、但讀不到：不建立預設圖標將失敗誤存成已遷移")

    local intactLayout = "[1920x1080]\r\n" .. MM_NAME .. " x=88 y=99\r\n"
        .. "[1280x720]\r\nForeignWindow x=21 y=34\r\n"
    resetDisk({ ["layout.ini"] = intactLayout, ["ModOptions.ini"] = legacy })
    unreadable = "layout.ini"
    pcall(coldBoot)
    local firstBlocked = core._floatIcon == nil
    unreadable = nil
    fire("OnGameStart") -- 同一 session 重試，不能用冷啟動幫 production 清掉失敗 cache。
    local recovered = core._floatIcon
    check(firstBlocked and recovered and recovered:getX() == 88 and recovered:getY() == 99
        and vfs["layout.ini"] == intactLayout and writes("layout.ini") == 0,
        "態D2 版面讀取失敗後重試仍讀完整檔案，不以空 cache 遷移覆寫其他解析度")
    resetDisk({})

    if familyFloats then
        -- ===== 三包共用同一份 layout.ini =====
        local NB_NAME, EC_NAME = "MinidoracatNBFloatButton", "MinidoracatEconomyFloatButton"
        local function trio() return { icon, notice, economy } end
        screenW, screenH = 1280, 720
        resetDisk({}); coldBoot()
        local def720 = {}
        for i, btn in ipairs(trio()) do def720[i] = { x = btn:getX(), y = btn:getY() } end
        screenW, screenH = 1920, 1080
        resetDisk({}); coldBoot()

        local target = { { x = 120, y = 140 }, { x = 300, y = 360 }, { x = 700, y = 820 } }
        for i, btn in ipairs(trio()) do drag(btn, target[i].x, target[i].y) end
        local rows = { rowAt("1920x1080", MM_NAME), rowAt("1920x1080", NB_NAME),
            rowAt("1920x1080", EC_NAME) }
        local placed = rows[1] ~= nil and rows[2] ~= nil and rows[3] ~= nil
        for i, want in ipairs(target) do
            placed = placed and tonumber(rows[i].x) == want.x and tonumber(rows[i].y) == want.y
        end
        check(placed and writes("layout.ini") == 3,
            "家族 layout：三個浮鈕各自放開即存，三列共存於同一解析度區段")
        check(rows[1].fields == 2 and rows[2].fields == 2 and rows[3].fields == 2,
            "家族 layout：三列都只有 x/y（沒有人再寫 visible）")

        coldBoot()
        check(icon:getX() == 120 and icon:getY() == 140
            and notice:getX() == 300 and notice:getY() == 360
            and economy:getX() == 700 and economy:getY() == 820,
            "家族 layout：冷啟動經同一份 ini 各自還原，互不串位")
        changeResolution(1280, 720)
        check(icon:getX() == def720[1].x and icon:getY() == def720[1].y
            and notice:getX() == def720[2].x and notice:getY() == def720[2].y
            and economy:getX() == def720[3].x and economy:getY() == def720[3].y,
            "家族 layout：換到無記錄解析度，三鈕各自回自己的初次預設")
        notice:setVisible(false); economy:setVisible(false)
        changeResolution(1920, 1080)
        check(icon:getX() == 120 and notice:getX() == 300 and economy:getX() == 700
            and icon:getIsVisible() and not notice:getIsVisible()
            and not economy:getIsVisible(),
            "家族 layout：切回原解析度還原三鈕記錄，隱藏中的入口不被還原強開")
    end

    -- 升級後先在主選單套用設定，再直接退出：不能只把舊位置留在記憶體。
    local savedModOptions = PZAPI.ModOptions
    local beforeMenuSave = "textentry|MinidoracatMiniMap|FloatIconPos|120,240\r\n" .. OTHER_MOD
    resetDisk({ ["ModOptions.ini"] = beforeMenuSave })
    players[0] = nil
    coldBoot(true)
    local menuHasNoWidget = core._floatIcon == nil and #elements == 0
    dofile(PZ_LUA .. "/client/PZAPI/ModOptions.lua")
    PZAPI.ModOptions:create("MinidoracatMiniMap", "test")
    PZAPI.ModOptions:load()
    PZAPI.ModOptions:save() -- 真原版：兩筆 OtherOptions 會黏連，不由 fixture 改寫內容。
    players[0] = {}
    coldBoot() -- 丟棄上一輪所有 module local，只有磁碟文字延續。
    check(menuHasNoWidget and icon:getX() == 120 and icon:getY() == 240,
        "態D2 主選單套用後直接退出仍保留舊位置，不靠尚未建立的圖標或記憶體候選")
    PZAPI.ModOptions = savedModOptions

    resetDisk({ ["ModOptions.ini"] = legacy })
    gameMode = "Tutorial"; players[0] = nil
    coldBoot(true)
    local tutorialSkipped = writes("layout.ini") == 0 and core._floatIcon == nil
    gameMode = "Sandbox"; players[0] = {}
    fire("OnGameStart") -- 同一 Lua session，不再給一次 OnGameBoot。
    local resumed = core._floatIcon
    check(tutorialSkipped and resumed and resumed:getX() == 700 and resumed:getY() == 400
        and writes("layout.ini") == 1,
        "態D2 原版暫不載入版面時不標成完成，切回可保存模式仍能遷移")

    resetDisk({ ["layout.ini"] = intactLayout, ["ModOptions.ini"] = legacy })
    coldBoot(true) -- 模擬別的原生視窗已成功載入完整 cache。
    installEvents()
    dofile(MM_FLOAT) -- 未完成的遷移狀態，沿用已載入的 native cache。
    unreadable = "layout.ini"
    fire("OnGameBoot")
    unreadable = nil
    local otherSave = pcall(ISLayoutManager.OnPostSave)
    check(otherSave and tonumber((rowAt("1280x720", "ForeignWindow") or {}).x) == 21
        and tonumber((rowAt("1920x1080", MM_NAME) or {}).x) == 88
        and core._floatIcon == nil,
        "態D2 重試讀取失敗保留原有完整 cache，不中斷其他視窗的原版保存")
end
print()
print("態 E：小地圖工具列 icon consumer（定位狀態／複製／文字退回）")
do
    local fh = assert(io.open(MAIN, "rb"))
    local source = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    local body = assert(source:match(
        "%-%- test:minimap%-toolbar%-icons:start\n(.-)\n%-%- test:minimap%-toolbar%-icons:end"),
        "missing minimap toolbar icon test block")
    local compile = loadstring or load
    local chunk, err = compile([[
local iconAvailable = true
local amber, muted, primary = { id = "amber" }, { id = "muted" }, { id = "primary" }
local ISButton = { render = function(self) self.baseRender = (self.baseRender or 0) + 1 end }
local UIFont = { Small = "Small" }
local function getTextManager()
    return { getFontHeight = function() return 12 end }
end
local function getBoolOption() return true end
local Core = { Skin = {
    COLORS = { ACCENT_AMBER = amber, TEXT_MUTED = muted, TEXT_PRIMARY = primary },
    icon = function(self, key, x, y, size, color)
        self.iconKey, self.iconSize, self.iconColor = key, size, color
        return iconAvailable
    end,
} }
]] .. body .. "\n" .. [[
return toolbarIconButtonRender, installToolbarIcon,
    function(value) iconAvailable = value end, amber, muted, primary
]])
    assert(chunk, err)
    local renderIcon, installIcon, setIconAvailable, amber, muted, primary = chunk()
    local owner = { inner = {} }
    local function button()
        return {
            title = "old", image = "old", width = 22, height = 22, mouseOver = false,
            setTitle = function(self, value) self.title = value end,
            setImage = function(self, value) self.image = value end,
            drawTextCentre = function(self, text) self.fallback = text end,
        }
    end
    local locate = button()
    installIcon(locate, owner, "locate", "C")
    check(locate.title == "" and locate.image == nil and locate.render == renderIcon
        and locate._minidoracatFallback == "C",
        "態E 定位鈕移除 C 標籤並安裝共用 renderer")
    renderIcon(locate)
    check(locate.iconKey == "locate" and locate.iconSize == 16
        and locate.iconColor == muted and locate.baseRender == 1,
        "態E 已置中時 locate icon 使用 muted 狀態")
    owner.inner._minidoracatFreelook = true
    renderIcon(locate)
    check(locate.iconColor == amber, "態E 自由查看時 locate icon 轉琥珀")
    setIconAvailable(false)
    local fallback = button()
    installIcon(fallback, owner, "locate", "C")
    renderIcon(fallback)
    check(fallback.fallback == "C", "態E 框架缺圖時定位鈕退回 C")
    setIconAvailable(true)
    local copy = button()
    installIcon(copy, owner, "copy", "XY")
    renderIcon(copy)
    check(copy.iconKey == "copy" and copy.iconColor == primary
        and copy._minidoracatFallback == "XY",
        "態E 複製鈕使用 copy icon 並保留 XY 退回")
end
print()
-- 條數守門（家族慣例）：整段被註解掉時數字變小但不會紅，靠這裡擋
-- 預設 65；--family-floats 另驗三包共用版面、重生與原生視窗層級。
local EXPECTED_ASSERTIONS = familyFloats and 78 or 65
if assertionCount ~= EXPECTED_ASSERTIONS then
    print("斷言條數不符：預期 " .. EXPECTED_ASSERTIONS .. "、實際 " .. assertionCount
        .. "（有測試被刪掉或跳過？）")
    os.exit(1)
end
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過（" .. assertionCount .. " 斷言）")
