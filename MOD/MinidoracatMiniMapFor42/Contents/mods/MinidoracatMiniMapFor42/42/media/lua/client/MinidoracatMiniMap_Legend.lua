-- MinidoracatMiniMap_Legend.lua
-- 本檔範圍：世界地圖（M）的資源點圖例。接在原版「圖例」面板（ISWorldMapKey：左上角，
-- 隨 S 鍵／S 鈕與地圖符號面板一起顯示或隱藏，ISWorldMap.lua:290-295、1013-1040）正下方，
-- 列出地圖上正在畫的資源點類別（圖示＋名稱）與地下設施角標的意思。
-- 內容取自 POI 模組同一次建置的結果（Core.poiLegend）：只列勾選中、有貼圖的類別，
-- 彩色／單色與地圖一致；「顯示資源點」關閉或全部類別取消時資源點那段不畫。世界地圖有畫自訂道路
-- （_RoadDraw.lua Core.roadsLegend）時下面多一列線樣，有停用的路再多一列「不用於導航」；兩段都沒有＝整塊不畫。
-- 原版 8 列建築色塊保留不動（使用者 2026-09-30 裁決）。字與列高跟「地圖文字大小」，
-- 放不下時由 2 欄加到最多 4 欄。
-- 面板是世界地圖的直接子元件：原版街名 hover（ISWorldMap.lua:672 isMouseOverChild）與
-- 本 MOD 圖標名稱提示都會略過它蓋住的範圍；點擊與原版圖例一樣由面板接走。
-- 隱藏用 0×0 尺寸而不是 setVisible(false)：不可見的元件不跑 prerender，就沒有地方再把自己叫回來。
-- 載入序：字母序在主檔與 MinidoracatMiniMapPOI.lua 之後，Core.poiLegend 於事件期查表。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end
if not (ISWorldMap and ISWorldMap.createChildren and ISPanel) then return end
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

local PAD = 10 -- 同原版圖例 UI_BORDER_SPACING（ISWorldMapKey.lua:6）
local GAP = 6  -- 圖示與文字間距

-- 版面（純計算，test_map_legend.lua 抽段驗證）：回傳欄數、列數、列高、圖示邊長、欄寬、
-- 面板寬高與標題列高。n＝類別數；nameW／titleW／basementW＝最寬類別名、標題、地下設施說明
-- 的字寬（倍率 1 px，無地下設施列時 basementW＝nil）；fontH／titleH＝Small／Medium 字高；
-- minW＝至少要多寬（對齊原版圖例）；maxH＝可用高度，放不下就加欄（2→4），4 欄仍放不下時
-- 維持 4 欄、超出部分交給畫面邊界。extraRows／extraW＝類別下面另加的整列（自訂道路的線樣，
-- 樣本寬＝圖示邊長×2）與其中最寬的字寬；省略＝沒有
-- test:legend-layout:start
local MIN_COLS, MAX_COLS = 2, 4
local function legendLayout(n, nameW, titleW, basementW, fontH, titleH, tz, minW, maxH, extraRows, extraW)
    local iconS = fontH * tz + 2
    if iconS < 16 then iconS = 16 end
    iconS = iconS - iconS % 1
    local rowH = iconS + 4
    local headH = titleH * tz + PAD * 2
    headH = headH - headH % 1
    local extra = extraRows or 0
    local tailH = (basementW and rowH or 0) + extra * rowH
    local cols, rows = MIN_COLS, 0
    while true do
        rows = (n + cols - 1 - (n + cols - 1) % cols) / cols
        if headH + rows * rowH + tailH + PAD <= maxH or cols >= MAX_COLS or n == 0 then break end
        cols = cols + 1
    end
    local width = PAD * 2 + cols * (iconS + GAP + nameW * tz + PAD)
    local need = titleW * tz + PAD * 2
    if width < need then width = need end
    if basementW then
        need = PAD * 2 + iconS + GAP + basementW * tz
        if width < need then width = need end
    end
    if extra > 0 then
        need = PAD * 2 + iconS * 2 + GAP + (extraW or 0) * tz
        if width < need then width = need end
    end
    if width < minW then width = minW end
    width = width - width % 1
    return {
        cols = cols, rows = rows, rowH = rowH, iconS = iconS, headH = headH,
        colW = (width - PAD * 2) / cols, width = width,
        height = headH + rows * rowH + tailH + PAD,
    }
end
-- test:legend-layout:end

local LegendPanel = ISPanel:derive("MinidoracatMiniMapLegend")

function LegendPanel:new(map)
    local o = ISPanel.new(self, PAD, PAD, 0, 0)
    o.map = map
    -- 同原版圖例配色（ISWorldMapKey.lua:82-83）
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    return o
end

-- 字寬快取：類別名只在圖例重建（換語系需重啟、勾選變動才換表）時重量
function LegendPanel:measure(lg)
    local tm = getTextManager()
    local nameW = 0
    for i = 1, lg.count do
        local w = tm:MeasureStringX(UIFont.Small, lg[i].name)
        if w > nameW then nameW = w end
    end
    self._lg, self._nameW = lg, nameW
    self:measureTexts()
end

function LegendPanel:measureTexts()
    if self._title then return end
    local tm = getTextManager()
    self._title = getText("UI_MinidoracatMiniMap_SecPOI")
    self._titleW = tm:MeasureStringX(UIFont.Medium, self._title)
    self._basementText = getText("UI_MinidoracatMiniMap_LegendBasement")
    self._basementW = tm:MeasureStringX(UIFont.Small, self._basementText)
    -- 自訂道路兩列（_RoadDraw.lua 同一組線樣）：只有自訂道路時標題換成「自訂道路」
    self._roadsTitle = getText("UI_MinidoracatMiniMap_RoadSecTitle")
    self._roadsTitleW = tm:MeasureStringX(UIFont.Medium, self._roadsTitle)
    self._roadText = getText("UI_MinidoracatMiniMap_RoadLegendRoad")
    self._roadOffText = getText("UI_MinidoracatMiniMap_RoadNavOffMark")
    self._roadW = math.max(tm:MeasureStringX(UIFont.Small, self._roadText),
        tm:MeasureStringX(UIFont.Small, self._roadOffText))
end

function LegendPanel:setBounds(x, y, w, h)
    if self.x ~= x then self:setX(x) end
    if self.y ~= y then self:setY(y) end
    if self.width ~= w then self:setWidth(w) end
    if self.height ~= h then self:setHeight(h) end
end

function LegendPanel:prerender()
    local map = self.map
    local key = map and map.keyUI
    local lg = Core.poiLegend and Core.poiLegend()
    self._layout = nil
    -- 功能閘門 poi 被擋＝地圖上沒有資源點，資源點那段收起（_FeatureGate.lua；缺檔＝放行）；
    -- 世界地圖不畫資源點（「顯示在」世界地圖那格關、或選項面板收起地圖圖層）同樣收起
    local fa = Core.featureAllowed
    if not lg or lg.count == 0 or (fa and map and not fa(map.playerNum or 0, "poi", "world"))
        or not Core.layerOn("poi", "world") then
        lg = nil
    end
    -- 自訂道路（世界地圖有畫才列；Core.roadsLegend 在 _RoadDraw.lua）：一列線樣，有停用的再一列
    local roads = map and Core.roadsLegend and Core.roadsLegend(map.playerNum or 0)
    local roadRows = roads and (roads.anyOff and 2 or 1) or 0
    if (not lg and roadRows == 0) or (key and not key:isVisible()) then
        self:setBounds(self.x, self.y, 0, 0)
        return
    end
    if lg and self._lg ~= lg then self:measure(lg) end
    self:measureTexts()
    local x, y, minW = PAD, PAD, 0
    if key then
        -- 原版圖例的高度在它自己的 render 裡逐幀重算（ISWorldMapKey.lua:46），它排在本面板
        -- 之前的子元件，這裡讀到的是本幀值
        x, y, minW = key:getX(), key:getY() + key:getHeight() + PAD, key:getWidth()
    end
    local tm = getTextManager()
    local tz = Core.mapTextZoom()
    local L = legendLayout(lg and lg.count or 0, lg and self._nameW or 0, lg and self._titleW or self._roadsTitleW,
        lg and lg.basement and self._basementW or nil, tm:getFontHeight(UIFont.Small),
        tm:getFontHeight(UIFont.Medium), tz, minW, map.height - y - PAD * 4, roadRows, self._roadW)
    L.tz, L.fontH = tz, tm:getFontHeight(UIFont.Small) * tz
    L.lg, L.roadRows = lg, roadRows
    self._layout = L
    self:setBounds(x, y, L.width, L.height)
    ISPanel.prerender(self)
end

-- 線樣：同地圖上的自訂道路（黑底＋淺色虛線；停用＝淡化細虛線）
function LegendPanel:drawRoadSample(x, y, w, off)
    local RD = Core.RoadDraw
    if not RD then return end
    local under, over = off and RD.OFF_UNDER or RD.UNDER, off and RD.OFF_OVER or RD.OVER
    local on, gap = off and RD.OFF_DASH_ON or RD.DASH_ON, off and RD.OFF_DASH_OFF or RD.DASH_OFF
    self:drawLine(nil, x, y, x + w, y, under.w, under.a, under.r, under.g, under.b)
    local t = 0
    while t < w do
        local e = math.min(t + on, w)
        self:drawLine(nil, x + t, y, x + e, y, over.w, over.a, over.r, over.g, over.b)
        t = t + on + gap
    end
end

function LegendPanel:render()
    local L = self._layout
    if not L then return end
    local lg, tz = L.lg, L.tz
    local title, titleW = self._title, self._titleW
    if not lg then title, titleW = self._roadsTitle, self._roadsTitleW end
    local tx = (self.width - titleW * tz) / 2
    Core.drawMapText(self, title, tx - tx % 1, PAD, 1, 1, 1, 1, UIFont.Medium, tz)
    local iconS = L.iconS
    local textDy = (iconS - L.fontH) / 2
    local count = lg and lg.count or 0
    for i = 1, count do
        local e = lg[i]
        local col = (i - 1) % L.cols
        local x = PAD + col * L.colW
        local y = L.headH + ((i - 1 - col) / L.cols) * L.rowH + 2
        x = x - x % 1
        self:drawTextureScaled(e.tex, x, y, iconS, iconS, 1, e.r, e.g, e.b)
        local ty = y + textDy
        Core.drawMapText(self, e.name, x + iconS + GAP, ty - ty % 1, 1, 1, 1, 1, UIFont.Small, tz)
    end
    if lg and lg.basement then
        -- 角標畫法與地圖同一份（_Zones.lua drawBasementBadge）；圖例放大一些才看得清箭頭
        local y = L.headH + L.rows * L.rowH + 2
        local bs = iconS * 0.6
        bs = bs - bs % 1
        if Core.drawBasementBadge then
            Core.drawBasementBadge(self, PAD + iconS - bs, y + iconS - bs, bs, 1)
        end
        local ty = y + textDy
        Core.drawMapText(self, self._basementText, PAD + iconS + GAP, ty - ty % 1,
            1, 1, 1, 1, UIFont.Small, tz)
    end
    local y = L.headH + L.rows * L.rowH + 2 + (lg and lg.basement and L.rowH or 0)
    for k = 1, L.roadRows do
        local off = k == 2
        local ly = y + iconS / 2
        self:drawRoadSample(PAD, ly - ly % 1, iconS * 2, off)
        local ty = y + textDy
        Core.drawMapText(self, off and self._roadOffText or self._roadText, PAD + iconS * 2 + GAP, ty - ty % 1,
            1, 1, 1, 1, UIFont.Small, tz)
        y = y + L.rowH
    end
end

-- 建立：世界地圖 createChildren 之後掛上（ISWorldMap 實例建立時呼叫一次，ISWorldMap.lua:282）。
-- pcall 邊界同主檔爪印鈕：失敗只損失圖例，不得讓整張世界地圖建不起來
local originalCreateChildren = ISWorldMap.createChildren
function ISWorldMap:createChildren()
    originalCreateChildren(self)
    local ok, err = pcall(function()
        if self._minidoracatLegend then return end -- 冪等：重跑不重複加
        local panel = LegendPanel:new(self)
        panel:initialise()
        self:addChild(panel)
        self._minidoracatLegend = panel
    end)
    if not ok then log("world map legend install failed: " .. tostring(err)) end
end
