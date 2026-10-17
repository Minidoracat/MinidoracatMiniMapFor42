-- MinidoracatMiniMap_WorldPanel.lua
-- 本檔範圍：世界地圖（M）按鈕列「MiniMap」鈕開的面板。本 MOD 在世界地圖上的開關集中在這裡
-- （2026-10-18 使用者裁定：原版齒輪選項面板在 debug 與多人管理員會列出全部原版選項，已經太長，
-- 本 MOD 不再往裡面加勾選）。內容依序：圖片化地圖；地圖圖層（WMLayers）與縮排在它底下的各圖層
-- 世界地圖那格；家與收藏、導航路線、陣營分享目標的世界地圖那格；多人另有「只看陣營與安全屋成員的標記」。
-- 格、預設值與停用條件都來自 Core.LAYER_MAPS（設定視窗「顯示在」列同一張），停用判定共用設定視窗的
-- Core.settingsEntryEnabled。
-- 面板沿用原版選項面板 WorldMapOptions（黑底、手把 B 回按鈕列，ISWorldMap.lua:204-224），是世界地圖的子元件；
-- 每次打開都重建，伺服器閘門與區域 addon 有無照當下。勾選每幀讀選項值（ESC 頁、設定視窗改了也同步），
-- 寫入同設定視窗：setValue → apply（開著的設定視窗跟著重建）→ save。
-- 載入序：字母序在主檔與 _Settings 之後；Core.toggleWorldPanel 由主檔按鈕列的 MiniMap 鈕在點擊時呼叫。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready and Core.LAYER_MAPS) then return end
if not (WorldMapOptions and ISTickBox) then return end

-- {LAYER_MAPS 名稱, 列名翻譯鍵}。LAYERS 吃「地圖圖層」總開關（縮排；總開關關＝停用、值保留），
-- OTHERS 不是圖層、不受總開關影響（同世界地圖 prerender wrap 的分法）
local LAYERS = {
    { "poi", "UI_MinidoracatMiniMap_SecPOI" }, { "parking", "UI_MinidoracatMiniMap_Parking" },
    { "zones", "UI_MinidoracatMiniMap_SecZones" }, { "zombie", "UI_MinidoracatMiniMap_SecZombie" },
    { "wild", "UI_MinidoracatMiniMap_RowWild" }, { "livestock", "UI_MinidoracatMiniMap_RowLivestock" },
    { "vehicles", "UI_MinidoracatMiniMap_SecVehicles" }, { "safehouse", "UI_MinidoracatMiniMap_SecSafehouse" },
}
local OTHERS = {
    { "places", "UI_MinidoracatMiniMap_RowPlaces" }, { "navRoute", "UI_MinidoracatMiniMap_RowNavRoute" },
    { "shared", "UI_MinidoracatMiniMap_RowShared" },
}

local Panel = WorldMapOptions:derive("MinidoracatMiniMapWorldPanel")

local function writeOption(id, value)
    local modOptions = Core.modOptions
    local opt = modOptions and modOptions:getOption(id)
    if not opt then return end
    opt:setValue(value)
    if modOptions.apply then modOptions:apply() end
    PZAPI.ModOptions:save()
end

-- 一列勾選：id＝ModOptions 鍵；cell＝LAYER_MAPS 的格（伺服器閘門等停用條件）；sub＝縮排、受地圖圖層總開關
function Panel:addRow(id, default, labelKey, tooltipKey, cell, sub)
    local fontH = getTextManager():getFontHeight(UIFont.Small)
    local tick = ISTickBox:new(sub and 27 or 11, self.rowY, 10, fontH + 4, "", self,
        function(_, _, selected) writeOption(id, selected and true or false) end)
    tick:initialise()
    local label = getText(labelKey)
    tick:addOption(label)
    tick:setWidthToFit()
    local enabledFn = Core.settingsEntryEnabled
    local gated = cell ~= nil and enabledFn ~= nil and not enabledFn(cell, self.map.playerNum or 0)
    if gated then
        tick.tooltip = getText("UI_MinidoracatMiniMap_ServerDisabled")
    elseif tooltipKey then
        tick.tooltip = getText(tooltipKey) -- 滑鼠停在選項上才顯示（ISTickBox.lua:113-133）
    end
    local origPrerender = tick.prerender
    function tick:prerender()
        self:setSelected(1, Core.getBoolOption(id, default) == true)
        self:disableOption(label, gated or (sub == true and not Core.getBoolOption("WMLayers", true)))
        origPrerender(self)
    end
    self:addChild(tick)
    self:insertNewLineOfButtons(tick) -- 手把一列一顆（同原版 ISWorldMap.lua:77）
    self.rowY = tick:getBottom() + 6
    tick._minidoracatOption = id -- E2E 依選項鍵找列
end

function Panel:createChildren()
    self.joypadButtonsY = {}
    self.joypadIndex, self.joypadIndexY = 1, 1
    self.rowY = self:titleBarHeight() + 6
    local mp = isClient()
    self:addRow("MapImagery", true, "UI_MinidoracatMiniMap_MapImagery", "UI_MinidoracatMiniMap_MapImagery_tooltip")
    self:addRow("WMLayers", true, "UI_MinidoracatMiniMap_WMLayers", "UI_MinidoracatMiniMap_WMLayers_tooltip")
    local options = Core.modOptions
    for pass = 1, 2 do
        local list = pass == 1 and LAYERS or OTHERS
        for i = 1, #list do
            local cell = Core.LAYER_MAPS[list[i][1]][2]
            -- 選項沒註冊（自訂區域：沒有區域 addon）或多人限定的格在單機：不列
            if options:getOption(cell.id) and (mp or not cell.mpOnly) then
                self:addRow(cell.id, cell.default, list[i][2],
                    pass == 1 and "UI_MinidoracatMiniMap_WMCell_tooltip" or nil, cell, pass == 1)
            end
        end
    end
    if mp then
        self:addRow("RemoteTrustedOnly", false, "UI_MinidoracatMiniMap_RemoteTrustedOnly",
            "UI_MinidoracatMiniMap_RemoteTrustedOnly_tooltip")
    end
    -- 尺寸沿原版 createChildren 尾段：子元件最大右／下緣；標題列的字也要放得下
    local w, h = getTextManager():MeasureStringX(self.titleBarFont or UIFont.Small, self.title or "") + 10, 0
    for _, child in pairs(self:getChildren()) do
        w = math.max(w, child:getRight())
        h = math.max(h, child:getBottom())
    end
    self:setWidth(w + 11)
    self:setHeight(h + self:resizeWidgetHeight())
end

-- 點面板外面收起；點的是開它的那顆鈕時不收（交給鈕的切換，同原版 optionBtn 的處理 ISWorldMap.lua:191-202）
function Panel:onMouseDownOutside(x, y)
    if self:isMouseOver() or (self.button and self.button:isMouseOver()) then return end
    self:setVisible(false)
    if self.joyfocus then setJoypadFocus(self.joyfocus.player, self.map.buttonPanel) end
end

-- 開／關。開＝重建後貼在按鈕上方（位置算法同原版 onChangeOptions，ISWorldMap.lua:1092-1110）
function Core.toggleWorldPanel(map, button)
    local old = map._minidoracatWorldPanel
    if old and old:isVisible() then
        old:setVisible(false)
        return
    end
    if old then map:removeChild(old) end
    local panel = Panel:new(0, 0, 300, 300, map)
    panel.title = getText("UI_MinidoracatMiniMap_Options")
    panel.button = button
    map:addChild(panel) -- addChild → instantiate → createChildren
    map._minidoracatWorldPanel = panel
    if map.optionsUI and map.optionsUI:isVisible() then map.optionsUI:setVisible(false) end
    panel:setX(math.min(map.width - 20 - panel.width, button.parent.x + button.x))
    panel:setY(button.parent.y + button.y - panel.height)
    local pn = map.playerNum or 0
    if JoypadState.players[pn + 1] then setJoypadFocus(pn, panel) end
end
