--[[
皮膚 adapter 煙霧測試：MinidoracatMiniMap_Skin.lua 現為家族 UI 框架
（MinidoracatUIFor42）的 thin adapter，本測試驗三態：

    lua scripts/test_skin_adapter.lua        （repo 根目錄執行；標準 Lua 5.x）

  A. 框架在場：fill/border 轉發到框架 Skin（9-slice 落點含絕對座標＋自身捲動
     補償＋floor——Search 結果列高亮與 Settings 區段底的生產路徑）；fits 走框架
     夾限；reset 轉發不炸。
  B. 框架缺席（版本不合／框架 Lua 初始化失敗／離線 harness）：fill/border 落
     adapter 自己的直角退回（相對座標、alphaScale 有效）、fits 恆 false、全程不炸。
     注意：「玩家漏裝框架」不走這條——mod.info 已宣告 require=MinidoracatUIFor42，
     缺 MOD 由引擎直接拒載本 MOD（見框架 repo docs/ARCHITECTURE.md §1 三層防線）。
  C. Core 門檻：Core 缺席／未 ready 時 adapter 必須整檔早退、不掛 Core.Skin
     （半初始化防線：主檔版本檢查未過時本節不該存在）。
框架自身行為（NinePatch 生命週期、theme）由框架 repo 的 smoke_harness 覆蓋，
此處只驗 adapter 的轉發與退回契約。
]]

local SKIN = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Skin.lua"
local MUI_V1 = os.getenv("MUI_LUA")
    or "../MinidoracatUIFor42/MOD/MinidoracatUIFor42/Contents/mods/MinidoracatUIFor42/42/media/lua/client/MinidoracatUI/V1.lua"

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
    local el = { rects = {}, borders = {} }
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
print()
-- 條數守門（家族慣例）：整段被註解掉時數字變小但不會紅，靠這裡擋
local EXPECTED_ASSERTIONS = 14
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
