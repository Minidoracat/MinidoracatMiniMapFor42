-- MinidoracatMiniMap_FloatIcon.lua
-- 本檔範圍：浮動開關圖標——家族 UI 框架 FloatButton 的 thin wrapper。
-- 拖曳（setCapture 五件套＋4px 門檻）、每幀 clamp、右鍵 800ms 過期守衛、
-- tooltip 500ms 節流、無玩家自我隱藏——全部上移框架
-- `MinidoracatUI/Widgets/FloatButton.lua`（本檔曾有的實作正是其契約來源之一）。
-- 本檔只剩本 MOD 業務：
--   1. 位置持久化：ModOptions FloatIconPos（"x,y"，同 CustomSize "WxH" 先例）
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

local modOptions = Core.modOptions -- 無 PZAPI（版本過舊）時為 nil，沿用原 nil 檢查
local getBoolOption = Core.getBoolOption
local debugWarn = Core.debugWarn -- -debug 渲染警告（tooltip 顯示 text/renderMode）

local floatIcon -- 單例
local FLOAT_ICON_SIZE = 32

local function frameworkFloatButton()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.floatButton == true then
        return ui.FloatButton
    end
    return nil
end

-- ===== 位置持久化（ModOptions "x,y"）=====

local function floatIconSavePos(x, y)
    if not modOptions then return end
    local opt = modOptions:getOption("FloatIconPos")
    if not opt then return end
    opt:setValue(math.floor(x) .. "," .. math.floor(y))
    PZAPI.ModOptions:save() -- 立即落地 ModOptions.ini（同 CustomSize 拖曳縮放做法）
end

local function floatIconLoadPos()
    if not modOptions then return nil end
    local opt = modOptions:getOption("FloatIconPos")
    -- ""/"nil"/"-" 皆視為未設定（PZAPI textentry 空字串髒化問題，見主檔 unifiedCsvSet）
    local raw = opt and tostring(opt:getValue() or "") or ""
    local sx, sy = string.match(raw, "^%s*(%d+)%s*,%s*(%d+)%s*$")
    if sx then return tonumber(sx), tonumber(sy) end
    return nil
end

-- 套用存檔位置（未設定＝預設右緣偏上：避開右下角小地圖預設錨位與右上系統 HUD）。
-- 建立時與 modOptions:apply 皆呼叫——ESC 改動位置欄（含清空還原預設）即時生效。
-- 框架 setPosition 內建 clamp（存檔位置超界／解析度改變夾回）。
local function floatIconApplyPos(el)
    local x, y = floatIconLoadPos()
    if not x then
        x = getCore():getScreenWidth() - FLOAT_ICON_SIZE - 6
        y = math.floor(getCore():getScreenHeight() * 0.35)
    end
    el:setPosition(x, y)
end

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
        onMoved = function(_, x, y) floatIconSavePos(x, y) end,
    })
    ui.tex = getTexture("media/ui/minimap_toggle.png")
    floatIconApplyPos(ui)
    floatIcon = ui
    Core._floatIcon = ui -- 內部觀察面（離線測試驗綁定用；underscore＝非公開 API）
    return ui
end

-- OnGameStart 與主檔 modOptions:apply()（ESC 選項頁與統一視窗勾選共同收斂點）呼叫；
-- 懶建立，選項關閉且從未建立時零成本。主檔經 Core.updateFloatIconVisibility
-- 呼叫時查表＋nil 防呆（本檔載入序在主檔之後）
local function updateFloatIconVisibility()
    if not getSpecificPlayer(0) then return end
    if getBoolOption("FloatIcon", true) then
        local ui = ensureFloatIcon()
        if ui then
            floatIconApplyPos(ui) -- 重讀位置欄：ESC 改動/清空即時生效（拖曳存檔＝同值冪等）
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
