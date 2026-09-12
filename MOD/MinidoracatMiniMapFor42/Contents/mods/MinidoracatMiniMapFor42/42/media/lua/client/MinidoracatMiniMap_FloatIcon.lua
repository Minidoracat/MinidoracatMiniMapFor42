-- MinidoracatMiniMap_FloatIcon.lua
-- 本檔範圍：浮動開關圖標——家族 UI 框架 FloatButton 的 thin wrapper。
-- 拖曳（setCapture 五件套＋4px 門檻）、每幀 clamp、右鍵 800ms 過期守衛、
-- tooltip 500ms 節流、無玩家自我隱藏——全部上移框架
-- `MinidoracatUI/Widgets/FloatButton.lua`（本檔曾有的實作正是其契約來源之一）。
-- 本檔只剩本 MOD 業務：
--   1. 位置持久化：原版 layout.ini（依解析度），拖曳放開立即保存
--   2. 點擊＝開關小地圖、右鍵＝穿透模式（Ghost）開關
--   3. 內容繪製：toggle 貼圖（缺圖畫「M」）＋穿透中染琥珀（含邊框）
--   4. hover 提示文字組裝（動作＋當前快捷鍵＋ghost 熱鍵＋-debug 渲染狀態）
--   5. updateFloatIconVisibility 顯示收斂點（選項開關）
--
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔先載，
-- 本檔載入期只讀 Core 的一次性賦值；框架 MOD 經 mod.info require= 先於本 MOD 全量載入。
--
-- 【退回】框架 FloatButton 能力缺席時不建圖標（degraded：無浮動入口——
-- 快捷鍵與 ESC 選項頁仍可開小地圖，防鎖死鏈不受影響）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

require "ISUI/ISLayoutManager"
local getBoolOption = Core.getBoolOption
local debugWarn = Core.debugWarn -- -debug 渲染警告（tooltip 顯示 text/renderMode）

local floatIcon -- 單例
local FLOAT_ICON_SIZE = 40
local LAYOUT_NAME = "MinidoracatMiniMapFloatIcon"

local function frameworkFloatButton()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.floatButton == true then
        return ui.FloatButton
    end
    return nil
end

-- ===== 原版版面存讀與舊位置一次性遷移 =====

local function positionNumbers(x, y)
    x, y = tonumber(x), tonumber(y)
    if x and y and x == x and y == y and math.abs(x) < math.huge and math.abs(y) < math.huge then
        return x, y
    end
end

local function defaultPosition(ui)
    ui:setPosition(getCore():getScreenWidth() - FLOAT_ICON_SIZE - 6,
        math.floor(getCore():getScreenHeight() * 0.35))
end

local layoutCallbacks = {}
function layoutCallbacks.RestoreLayout(ui, name, layout)
    local x, y = positionNumbers(layout.x, layout.y)
    if x then ui:setPosition(x, y) end
end
function layoutCallbacks.SaveLayout(ui, name, layout)
    layout.x, layout.y, layout.visible = ui:getX(), ui:getY(), nil
end

local function hasSavedLayout()
    for _, resolution in ipairs(ISLayoutManager.layouts) do
        for _, layout in ipairs(resolution.windows) do
            if layout.name == LAYOUT_NAME then return true end
        end
    end
    return false
end

local function readLegacyValue(reader)
    local value
    while true do
        local line = reader:readLine()
        if not line then return value end
        local candidate = string.match(line, "^textentry|MinidoracatMiniMap|FloatIconPos|(.*)$")
        -- 與 ModOptions.load 同樣採最後一筆非空值，空欄不覆蓋前值。
        if candidate and candidate ~= "" then value = candidate end
    end
end

local function legacyPosition()
    if not cacheFileExists("ModOptions.ini") then return nil end
    local reader = getFileReader("ModOptions.ini", false)
    if not reader then error("Cannot read legacy MiniMap floating-icon position") end
    local ok, value = pcall(readLegacyValue, reader)
    reader:close()
    if not ok then error(value) end
    local x, y = string.match(value or "", "^%s*(%d+)%s*,%s*(%d+)%s*$")
    return positionNumbers(x, y)
end

-- OnGameBoot 早於主選單 ModOptions.load/save；先落盤，連只套用設定就退出也不丟舊值。
-- 只新增原生格式 row，不建立圖標、不註冊假 window，也不廣播存檔事件。
local function backfillLegacyPosition()
    ISLayoutManager.ReadIni()
    local layouts = ISLayoutManager.layouts
    if not layouts then return false end -- 原版 Tutorial 刻意不載入，不能標成遷移完成。
    if hasSavedLayout() then return true end
    local x, y = legacyPosition()
    if not x then return true end
    local gameCore = getCore()
    local width, height = gameCore:getScreenWidth(), gameCore:getScreenHeight()
    local current
    for _, resolution in ipairs(layouts) do
        if resolution.width == width and resolution.height == height then
            current = resolution
            break
        end
    end
    if not current then
        current = { width = width, height = height, windows = {} }
        table.insert(layouts, current)
    end
    table.insert(current.windows, { name = LAYOUT_NAME, x = x, y = y })
    ISLayoutManager.WriteIni()
    return true
end

local migrationReady = false
local function migrateLegacyPositionOnce()
    if migrationReady then return true end
    local previous = ISLayoutManager.layouts
    local ok, result = pcall(backfillLegacyPosition)
    if ok then
        migrationReady = result
    else
        -- 不發布本次讀到一半的 cache；重試前已有的版面仍供原版存檔使用。
        ISLayoutManager.layouts = previous
        print("[MinidoracatMiniMap] Floating position migration failed: " .. tostring(result))
    end
    return migrationReady
end
Events.OnGameBoot.Add(migrateLegacyPositionOnce)

-- ===== tooltip 文字（500ms 節流由框架管；這裡只組字串）=====

-- 指定綁定的目前顯示文字（含修飾鍵前綴）：優先讀選項畫面 keyText，
-- 未就緒時退 Core 基本鍵名。hover 期間框架節流重建——玩家改鍵後 tip 即時反映
local function currentBindKeyText(bindName)
    if MainOptions and type(MainOptions.keyText) == "table" then
        for _, v in ipairs(MainOptions.keyText) do
            if not v.value and v.txt and v.txt:getName() == bindName then
                local prefix = MainOptions.getKeyPrefix and MainOptions.getKeyPrefix(v) or ""
                return prefix .. getKeyName(v.keyCode)
            end
        end
    end
    return getKeyName(getCore():getKey(bindName))
end

local function tooltipText()
    local desc = getText("UI_MinidoracatMiniMap_FloatIcon_tip",
        currentBindKeyText("MinidoracatMiniMap_Toggle"))
    if Core.toggleGhost then -- 穿透模式入口標註（_Ghost.lua 載入才顯示）
        desc = desc .. " \n" .. getText("UI_MinidoracatMiniMap_FloatIcon_ghost_tip",
            currentBindKeyText("MinidoracatMiniMap_Ghost"))
    end
    local mode = debugWarn.renderMode() -- -debug 限定：目前渲染管線狀態
    if mode then desc = desc .. " \n" .. mode end
    local warn = debugWarn.text()
    if warn then desc = desc .. " \n" .. warn end
    -- 多行不自動換行（同 ISButton.lua:326-330 的 maxLineWidth 切換）
    return desc, (mode or warn) and 1000 or 300
end

-- ===== 內容繪製（框架畫完皮膚後回呼）=====

-- 邊框色 table 由本檔持有（框架 colors.border 引用同一顆）：穿透切換時就地
-- 改 rgb——琥珀提示（小地圖琥珀邊框的次要提示，同 C 鈕雙件套慣例）。
-- 染色發生在 drawContent（皮膚之後），生效於下一幀——1 幀延遲肉眼不可辨。
local BORDER_COLOR = { r = 1, g = 1, b = 1, a = 0.35 }

local function drawContent(btn)
    local a = btn:isMouseOver() and 1.0 or 0.75
    local ghost = Core.isGhost and Core.isGhost()
    if ghost then
        BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b = 1, 0.85, 0.4
    else
        BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b = 1, 1, 1
    end
    if btn.tex then
        btn:drawTextureScaled(btn.tex, 3, 3, btn.width - 6, btn.height - 6, a,
            1, ghost and 0.85 or 1, ghost and 0.4 or 1)
    else
        -- 材質缺漏 nil-safe（同 POI 圖標慣例）：畫「M」替代
        local fh = getTextManager():getFontHeight(UIFont.Small)
        btn:drawTextCentre("M", btn.width / 2, (btn.height - fh) / 2, 1, 1, 1, a, UIFont.Small)
    end
end

-- ===== 建立與顯示收斂 =====

local function ensureFloatIcon()
    if floatIcon then return floatIcon end
    local FW = frameworkFloatButton()
    if not FW then return nil end
    -- 尚未成功讀取／遷移時不註冊預設位置，避免正常存檔把它寫成已遷移的記錄。
    if not migrateLegacyPositionOnce() then return nil end
    local ui = FW.new({
        size = FLOAT_ICON_SIZE,
        colors = {
            surface = { r = 0, g = 0, b = 0, a = 0.7 },
            border = BORDER_COLOR,
            hover = { r = 1, g = 1, b = 1, a = 0.06 },
        },
        drawContent = drawContent,
        getTooltip = tooltipText,
        onClick = Core.togglePlayerMiniMap,
        -- 右鍵＝穿透模式開關（本體在 _Ghost.lua，載入序在後——事件時查表）。
        -- FloatIcon 是頂層獨立元件、不隨小地圖穿透失效＝穿透中保證存在的滑鼠
        -- 回頭路（防鎖死鏈第二層；第一層熱鍵、第三層 ESC 選項頁）
        onRightClick = function()
            if Core.toggleGhost then Core.toggleGhost() end
        end,
        onMoved = ISLayoutManager.OnPostSave,
    })
    ui.tex = getTexture("media/ui/minimap_toggle.png")
    defaultPosition(ui)
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, layoutCallbacks, ui)
    floatIcon = ui
    Core._floatIcon = ui -- 內部觀察面（離線測試驗綁定用；underscore＝非公開 API）
    return ui
end

-- OnGameStart、主玩家同場重生與主檔 modOptions:apply() 共同呼叫；
-- 不建立已關閉的圖標；主檔經 Core.updateFloatIconVisibility
-- 呼叫時查表＋nil 防呆（本檔載入序在主檔之後）
local function updateFloatIconVisibility()
    if not getSpecificPlayer(0) then return end
    if getBoolOption("FloatIcon", true) then
        local ui = ensureFloatIcon()
        if ui then
            ui:setVisible(true)
            ui:bringToTop()
        end
    elseif floatIcon then
        floatIcon:hideTooltip() -- 隱藏後 prerender 停跑，tip 須在此收掉（框架方法）
        floatIcon:setVisible(false)
    end
end
Core.updateFloatIconVisibility = updateFloatIconVisibility
Events.OnGameStart.Add(updateFloatIconVisibility)
-- 同場重生不再觸發 OnGameStart；OnCreatePlayer 時玩家槽位才已補回。
Events.OnCreatePlayer.Add(function(playerNum)
    if playerNum == 0 then updateFloatIconVisibility() end
end)
Events.OnResolutionChange.Add(function()
    if not floatIcon then return end
    defaultPosition(floatIcon)
    ISLayoutManager.TryRestore(LAYOUT_NAME)
end)
