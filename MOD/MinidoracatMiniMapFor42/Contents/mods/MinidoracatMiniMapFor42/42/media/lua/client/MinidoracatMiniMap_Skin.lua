-- MinidoracatMiniMap_Skin.lua
-- 本檔範圍：本 MOD 色票權威＋家族 UI 框架（MinidoracatUIFor42）的 thin adapter。
--
-- 圓角繪製核心（NinePatchTexture 生命週期、絕對座標＋自身捲動補償＋floor、
-- 直角退回、具名函式 pcall 零配置）已上移框架 `MinidoracatUI/V1.lua`（該 repo
-- docs/ARCHITECTURE.md；本 MOD 曾經的 renderNine／getXScroll 改良已收編為框架
-- 標準行為）。本檔只剩：色票 COLORS、fill/border/fits/reset 轉發、框架缺席時
-- 的直角退回。貼圖（mui_*.png）隨框架 MOD 散布，本 MOD 不再攜帶 PNG。
--
-- 【退回紅線】（同換皮前）框架缺席（未安裝、版本不合、測試環境）時視窗照開——
-- 一律退直角 drawRect/drawRectBorder，絕不 error。正式發佈以 mod.info 的
-- `require=MinidoracatUIFor42` 保證框架先載入（ZomboidFileSystem.java:807-833）。
--
-- 【API 契約】核心圓角需要框架 API v1 rev>=1；rev>=3 時額外轉發 toggle／slider
-- painters 與 Studio chrome icons；rev>=4 另有 art 圖示（地圖符號＋分類 icon，
-- Skin.iconTexture 取貼圖）。版本不合或資產缺失＝走本檔直角／純文字／原版符號退回。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

if not (MinidoracatUI and MinidoracatUI.v1) then
    -- 測試環境／異常順序防禦：Kahlua require 對缺檔行為未查證，pcall 包住
    pcall(require, "MinidoracatUI/V1")
end

MinidoracatMiniMapSkin = MinidoracatMiniMapSkin or {}
local Skin = MinidoracatMiniMapSkin

-- 色票（與 NoticeBoard 同源，UI 家族一致；r,g,b,a 皆 0-1）
-- 值刻意保持字面（不從框架 theme 取）：框架缺席時色票也要在。
-- 整包保留含目前未引用項——跨 MOD 視覺一致性優先（claude review 裁決：保留並明示）
Skin.COLORS = {
    BG_PANEL = { r = 0, g = 0, b = 0, a = 0.8 },
    BORDER = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 },
    TITLE_TEXT = { r = 1, g = 1, b = 1, a = 1.0 },
    TITLEBAR_FILL = { r = 1, g = 1, b = 1, a = 0.10 },
    ROW_HOVER = { r = 1, g = 1, b = 1, a = 0.06 },
    ROW_SELECTED = { r = 1, g = 1, b = 1, a = 0.12 },
    TEXT_PRIMARY = { r = 1, g = 1, b = 1, a = 1.0 },
    TEXT_MUTED = { r = 0.62, g = 0.62, b = 0.62, a = 1.0 },
    ACCENT_AMBER = { r = 1, g = 0.85, b = 0.4, a = 1.0 },
    FIELD_BG = { r = 0, g = 0, b = 0, a = 0.5 },
    PLACEHOLDER_TEXT = { r = 0.55, g = 0.55, b = 0.55, a = 1.0 },
}

-- 載入期綁定：本檔字母序在主檔之後、且 mod.info require= 保證框架 MOD 先載入
local FW, FWIcons, FWRevision = nil, nil, 0
do
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.API_REVISION >= 1 and ui.Skin then
        FW = ui.Skin
        FWRevision = ui.API_REVISION
        if ui.API_REVISION >= 2 and ui.Icons then FWIcons = ui.Icons end
    end
end

-- 只給測試用：環境切換時清框架的貼圖載入狀態
function Skin.reset()
    if FW then
        FW._resetForTests()
    end
end

-- 矩形夠不夠大到能走 9-slice。框架缺席一律 false（fill/border 直接退直角）。
function Skin.fits(width, height, topOnly)
    if FW then
        return FW.fits(width, height, topOnly)
    end
    return false
end

-- 圓角填色。topOnly=true 只圓上兩角（標題列）。alphaScale＝動畫 alpha 乘數
function Skin.fill(element, x, y, width, height, color, topOnly, alphaScale)
    if FW then
        return FW.fill(element, x, y, width, height, color, topOnly, alphaScale)
    end
    element:drawRect(x, y, width, height,
        (color.a or 1) * (alphaScale or 1), color.r, color.g, color.b)
end

-- 1px 圓角邊框。topOnly=true 上圓、底邊開放
function Skin.border(element, x, y, width, height, color, topOnly, alphaScale)
    if FW then
        return FW.border(element, x, y, width, height, color, topOnly, alphaScale)
    end
    element:drawRectBorder(x, y, width, height,
        (color.a or 1) * (alphaScale or 1), color.r, color.g, color.b)
end

local TOGGLE_COLORS = {
    off = Skin.COLORS.ROW_SELECTED,
    on = Skin.COLORS.ACCENT_AMBER,
    knob = Skin.COLORS.TEXT_PRIMARY,
    border = Skin.COLORS.BORDER,
}
local SLIDER_COLORS = {
    track = Skin.COLORS.FIELD_BG,
    fill = Skin.COLORS.ACCENT_AMBER,
    knob = Skin.COLORS.TEXT_PRIMARY,
    border = Skin.COLORS.BORDER,
}
local function adapterColor(colors, key, fallback)
    local color = type(colors) == "table" and colors[key] or nil
    if type(color) ~= "table" or color.r == nil or color.g == nil or color.b == nil then
        return fallback
    end
    return color
end

-- Studio 的共用繪製縫：rev 3 走框架一致的 20px pill；舊框架／離線 harness
-- 仍畫得出可辨識開關。element 的互動與狀態歸 consumer，框架只負責視覺。
function Skin.toggle(element, x, y, width, height, on, colors, alphaScale)
    colors = colors or TOGGLE_COLORS
    if FWRevision >= 3 and type(FW.toggle) == "function" then
        return FW.toggle(element, x, y, width, height, on, colors, alphaScale)
    end
    local scale = alphaScale or 1
    local trackH = math.min(20, height)
    local trackY = y + math.floor((height - trackH) / 2)
    local track = adapterColor(colors, on and "on" or "off",
        on and TOGGLE_COLORS.on or TOGGLE_COLORS.off)
    local border = adapterColor(colors, "border", TOGGLE_COLORS.border)
    local knobColor = adapterColor(colors, "knob", TOGGLE_COLORS.knob)
    Skin.fill(element, x, trackY, width, trackH, track, false, scale)
    Skin.border(element, x, trackY, width, trackH, border, false, scale)
    local knob = math.max(8, trackH - 6)
    local knobX = on and (x + width - knob - 3) or (x + 3)
    local knobY = trackY + math.floor((trackH - knob) / 2)
    Skin.fill(element, knobX, knobY, knob, knob, knobColor, false, scale)
    return true
end

function Skin.slider(element, x, y, width, height, ratio, colors, alphaScale)
    colors = colors or SLIDER_COLORS
    if FWRevision >= 3 and type(FW.slider) == "function" then
        return FW.slider(element, x, y, width, height, ratio, colors, alphaScale)
    end
    if type(ratio) ~= "number" or ratio ~= ratio or width < 12 or height < 12 then return false end
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    local scale = alphaScale or 1
    local trackY = y + math.floor((height - 4) / 2)
    local track = adapterColor(colors, "track", SLIDER_COLORS.track)
    local fill = adapterColor(colors, "fill", SLIDER_COLORS.fill)
    local knob = adapterColor(colors, "knob", SLIDER_COLORS.knob)
    local border = adapterColor(colors, "border", SLIDER_COLORS.border)
    element:drawRect(x, trackY, width, 4, (track.a or 1) * scale,
        track.r, track.g, track.b)
    element:drawRectBorder(x, trackY - 1, width, 6, (border.a or 1) * scale,
        border.r, border.g, border.b)
    local fillW = math.floor(width * ratio + 0.5)
    if fillW > 0 then
        element:drawRect(x, trackY, fillW, 4, (fill.a or 1) * scale,
            fill.r, fill.g, fill.b)
    end
    local knobX = x + fillW - 6
    Skin.fill(element, knobX, y + math.floor((height - 12) / 2), 12, 12,
        knob, false, scale)
    return true
end

function Skin.icon(element, name, x, y, size, color, alpha)
    if FWRevision >= 3 and FWIcons and type(FWIcons.draw) == "function" then
        return FWIcons.draw(element, name, x, y, size, color, alpha)
    end
    return false
end

-- 取框架圖示貼圖（供繪製端 drawTextureScaled 自畫，如地圖上的動物／安全屋符號）。
-- rev>=4 才有 art key；舊 rev 對 art key 回 nil（Icons.get 未知 key 回 nil），
-- 呼叫端退回原版 LootableMaps 符號。回 nil＝缺框架／缺資產／未知 key，絕不拋錯
function Skin.iconTexture(name)
    if FWRevision >= 2 and FWIcons and type(FWIcons.get) == "function" then
        return FWIcons.get(name)
    end
    return nil
end

Core.Skin = Skin
