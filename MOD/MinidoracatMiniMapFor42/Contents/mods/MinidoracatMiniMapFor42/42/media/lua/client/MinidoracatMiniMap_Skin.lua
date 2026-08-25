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
-- 【API 契約】需要框架 API v1 rev>=1（fill/border/fits/_resetForTests）；
-- 版本不合＝當框架不存在處理。
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
local FW = nil
do
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.API_REVISION >= 1 and ui.Skin then
        FW = ui.Skin
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

Core.Skin = Skin
