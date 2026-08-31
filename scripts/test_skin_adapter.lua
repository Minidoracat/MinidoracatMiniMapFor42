--[[
皮膚 adapter 煙霧測試：MinidoracatMiniMap_Skin.lua 現為家族 UI 框架
（MinidoracatUIFor42）的 thin adapter，本測試驗四態：

    lua scripts/test_skin_adapter.lua        （repo 根目錄執行；標準 Lua 5.x）

  A. 框架在場：fill/border、rev3 toggle／slider painters 與 Studio icons 轉發；
     9-slice 落點含絕對座標＋自身捲動補償＋floor。fits/reset 同步走框架。
  B. 框架缺席：fill/border、toggle 與 slider 走直角退回，icon 回 false 讓
     consumer 顯示純文字；fits 恆 false且全程不炸。
  C. Core 門檻：Core 缺席／未 ready 時 adapter 早退、不掛 Core.Skin。
  D. FloatIcon wrapper：框架浮鈕與 MiniMap 業務回呼、位置保存、顯示收斂。
框架自身行為由框架 repo 的 smoke_harness 覆蓋；此處只驗 adapter 契約。
]]

local SKIN = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Skin.lua"
local MUI_V1 = os.getenv("MUI_LUA")
    or "../MinidoracatUIFor42/MOD/MinidoracatUIFor42/Contents/mods/MinidoracatUIFor42/42/media/lua/client/MinidoracatUI/V1.lua"
local MAIN = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

do
    local probe = io.open(MUI_V1, "rb")
    if not probe then
        print("SKIP test_skin_adapter: framework V1.lua not found at " .. MUI_V1)
        print("     (clone MinidoracatUIFor42 beside this repo, or set MUI_LUA=<path to V1.lua>)")
        os.exit(0)
    end
    probe:close()
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
    function ISPanelStub:addToUIManager() end
    function ISPanelStub:removeFromUIManager() end
    function ISPanelStub:bringToTop() end
    function ISPanelStub:setCapture() end
    function ISPanelStub:isMouseOver() return false end
    function ISPanelStub:drawTextureScaled() end
    function ISPanelStub:drawTextCentre() end
    function ISPanelStub:drawRect() end
    function ISPanelStub:drawRectBorder() end
    _G.ISPanel = ISPanelStub
    _G.getCore = function()
        return {
            getScreenWidth = function() return 1920 end,
            getScreenHeight = function() return 1080 end,
            getKey = function() return 53 end,
        }
    end
    _G.getMouseX = function() return 0 end
    _G.getMouseY = function() return 0 end
    _G.getTimestampMs = function() return 5000000 end
    _G.getSpecificPlayer = function() return {} end
    _G.getTexture = function() return nil end -- 缺圖路徑：drawContent 畫 M
    _G.getText = function(key, a) return "[" .. tostring(key) .. (a and ("|" .. tostring(a)) or "") .. "]" end
    _G.getKeyName = function() return "SLASH" end
    _G.UIFont = { Small = "Small", Medium = "Medium", NewSmall = "NewSmall" }
    _G.getTextManager = function()
        return { getFontHeight = function() return 12 end,
            MeasureStringX = function(_, _, t) return string.len(t) * 10 end }
    end
    _G.Events = setmetatable({}, { __index = function()
        return { Add = function() end }
    end })
    local savedCalls = 0
    _G.PZAPI = { ModOptions = { save = function() savedCalls = savedCalls + 1 end } }

    -- 重載框架（態 B 拔掉了）＋widget
    dofile(MUI_V1)
    local MUI_DIR = MUI_V1:gsub("V1%.lua$", "")
    dofile(MUI_DIR .. "Widgets/FloatButton.lua")
    check(MinidoracatUI.v1.CAPABILITIES.floatButton == true, "態D 框架 FloatButton 能力就緒")

    _G.__floatIconOptionOn = true
    -- Core stub：modOptions 存 FloatIconPos；toggle 計數
    local optValue = nil
    local toggles, ghosts = 0, 0
    local core = {
        ready = true,
        modOptions = { getOption = function(_, id)
            if id == "FloatIconPos" then
                return {
                    setValue = function(_, v) optValue = v end,
                    getValue = function() return optValue end,
                }
            end
            return nil
        end },
        -- 間接旗標：_FloatIcon 載入期會把 Core.getBoolOption 快取成 local，
        -- 事後換函式無效——換旗標值才動得了它
        getBoolOption = function(_, default) return _G.__floatIconOptionOn end,
        debugWarn = { renderMode = function() return nil end, text = function() return nil end },
        togglePlayerMiniMap = function() toggles = toggles + 1 end,
        toggleGhost = function() ghosts = ghosts + 1 end,
        isGhost = function() return false end,
    }
    _G.MinidoracatMiniMapCore = core
    dofile("MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_FloatIcon.lua")

    core.updateFloatIconVisibility()
    local icon = core._floatIcon
    check(icon ~= nil, "態D 顯示收斂點經框架建立浮鈕（Core._floatIcon 觀察面）")
    check(icon:getX() == 1920 - 32 - 6 and icon:getY() == math.floor(1080 * 0.35),
        "態D 無存檔值：預設位置右緣偏上（1882, 378）")

    -- onClick / onRightClick 業務綁定
    icon.onClick(icon)
    check(toggles == 1, "態D 點擊綁 togglePlayerMiniMap")
    icon.onRightClick(icon)
    check(ghosts == 1, "態D 右鍵綁 Core.toggleGhost")

    -- onMoved 綁定 → ModOptions 存檔（floor＋立即 save）
    icon.onMoved(icon, 55.7, 66.2)
    check(optValue == "55,66" and savedCalls == 1,
        "態D 拖曳落點 floor 後存 FloatIconPos 並立即 save")

    -- 存檔位置載入：收斂點重讀（ESC 改欄位即時生效路徑）
    optValue = "200,300"
    core.updateFloatIconVisibility()
    check(icon:getX() == 200 and icon:getY() == 300, "態D 存檔位置經 setPosition 套用")

    -- tooltip 文字組裝（快捷鍵名＋ghost 熱鍵行；-debug 無資料不附加）
    local desc, maxW = icon.getTooltipText(icon)
    check(type(desc) == "string" and desc:find("SLASH", 1, true) ~= nil
        and desc:find("ghost_tip", 1, true) ~= nil and maxW == 300,
        "態D tooltip 含當前快捷鍵與 ghost 熱鍵行")

    -- 選項關閉 → 隱藏（tip 同步收掉不炸）
    _G.__floatIconOptionOn = false
    core.updateFloatIconVisibility()
    check(icon:getIsVisible() == false, "態D 選項關閉：浮鈕隱藏")
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
local EXPECTED_ASSERTIONS = 40
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
