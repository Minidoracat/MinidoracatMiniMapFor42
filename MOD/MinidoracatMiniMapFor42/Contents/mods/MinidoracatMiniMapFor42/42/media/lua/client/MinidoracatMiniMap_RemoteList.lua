-- MinidoracatMiniMap_RemoteList.lua
-- 本檔範圍：「其他玩家標記」的作者清單視窗。作者超過 20 位時，設定分類改成摘要＋「管理作者...」，
-- 按下開這個視窗（使用者裁定 2026-10-08：分類 20 位以內照舊列出、要「只看已隱藏」、設定視窗總搜尋
-- 不找作者、底部兩顆按鈕只作用在目前清單上的作者）。本檔只做畫面與篩選；作者資料與切換規則在
-- _RemoteSymbols.lua（Core.remoteSymbolAuthors／remoteSymbolHidden／remoteAuthorShown／remoteAuthorSet／
-- remoteAuthorSetMany／remoteListSig）。
-- 框架元件都是 rev 17 已有的（設定視窗本來就要 rev 17）：UI.Window（可拉大）、UI.TextField、UI.Checkbox、
-- UI.VirtualList（物件池：列數隨視窗高度，不隨作者數；MinidoracatUI/VirtualList.lua:1-21）、UI.Button、UI.Skin.toggle。
-- 子元件一律先 addChild 再移位：沒有父元件時原版 setX/setY 會夾在螢幕內（ISUIElement.lua:188-220）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

local listUI -- 單例，同設定視窗
local REFRESH_FRAMES = 30 -- 約半秒比一次作者清單簽章（新分享、陣營進出、別處改了隱藏）
local PAD = 8
local TOGGLE_W = 36
local TAG_TRUST = { r = 0.42, g = 0.62, b = 0.28, a = 0.45 }
local TAG_HIDDEN = { r = 0.62, g = 0.26, b = 0.26, a = 0.45 }
local TAG_KEYS = { faction = "UI_MinidoracatMiniMap_RemoteTagFaction", safehouse = "UI_MinidoracatMiniMap_RemoteTagSafehouse" }
local RowCell -- 第一次開窗才 derive（ISPanel 在框架載入後才確定存在）

-- 搜尋：帳號裡任一段連續文字，不分大小寫；勾「只看已隱藏」時只留原版隱藏名單裡的作者。
-- 每筆順便記下 hidden／shown（畫面每幀只讀欄位，不再問引擎）
-- test:remote-list-filter:start
local function normalizeQuery(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$") or ""):lower()
end
local function filterAuthors(items, query, hiddenOnly)
    local out, hidden = {}, 0
    for i = 1, #items do
        local it = items[i]
        it.hidden = Core.remoteSymbolHidden(it.key)
        it.shown = Core.remoteAuthorShown(it)
        if (it.hidden or not hiddenOnly) and (query == "" or it.key:lower():find(query, 1, true)) then
            out[#out + 1] = it
            if it.hidden then hidden = hidden + 1 end
        end
    end
    return out, hidden
end
-- test:remote-list-filter:end

local function listSig(win)
    local sig = Core.remoteListSig and Core.remoteListSig(win._playerNum) or ""
    return sig .. (Core.getBoolOption("RemoteTrustedOnly", false) and "|t" or "|f")
end

-- 重新取作者、套搜尋與勾選，更新清單、計數與底部按鈕
local function refresh(win)
    local all = Core.remoteSymbolAuthors(win._playerNum)
    local items, hidden = filterAuthors(all, win._query, win._only:getChecked())
    win._items = items
    win._list:setItems(items)
    local n = tostring(#items)
    win._showBtn:setTitle(getText("UI_MinidoracatMiniMap_RemoteShowThese", n))
    win._hideBtn:setTitle(getText("UI_MinidoracatMiniMap_RemoteHideThese", n))
    win._showBtn:setEnabled(#items > 0)
    win._hideBtn:setEnabled(#items > 0)
    if #all == 0 then
        win._meta = getText("UI_MinidoracatMiniMap_RemoteNoAuthors")
    elseif #items == 0 then
        win._meta = getText("UI_MinidoracatMiniMap_RemoteListEmpty")
    else
        win._meta = getText("UI_MinidoracatMiniMap_RemoteListCount", tostring(#all), n, tostring(hidden))
    end
    win._sig = listSig(win)
end

-- 一列：開關＋帳號＋標籤（陣營／安全屋／已隱藏）＋右側標記數。文字與寬度在 bind 時算好，prerender 只畫
local function rowPrerender(self)
    local it = self._item
    if not it then return end
    local win = self._list._win
    local UI, colors, font = win._UI, win.theme.colors, win._font
    local h, fontH = self.height, win._fontH
    if self._list:isSelected(self._index) then UI.Skin.fill(self, 0, 0, self.width, h, colors.hover, win._shape, 1) end
    UI.Skin.toggle(self, 4, math.floor((h - 20) / 2), TOGGLE_W, 20, it.shown, win._toggleColors, 1)
    local ty = math.floor((h - fontH) / 2)
    local c = it.shown and colors.text or colors.textMuted
    local x = TOGGLE_W + 12
    self:drawText(self._nameText, x, ty, c.r, c.g, c.b, c.a or 1, font)
    if self._tagText then
        local tx = x + self._nameW + 6
        UI.Skin.fill(self, tx, ty - 1, self._tagW, fontH + 2, self._tagColor, win._shape, 1)
        self:drawText(self._tagText, tx + 5, ty, colors.text.r, colors.text.g, colors.text.b, 1, font)
    end
    local m = colors.textMuted
    self:drawTextRight(self._countText, self.width - 6, ty, m.r, m.g, m.b, m.a or 1, font)
end

local function createCell(list)
    if not RowCell then
        RowCell = ISPanel:derive("MinidoracatMiniMapRemoteRow")
        RowCell.prerender = rowPrerender
    end
    local cell = RowCell:new(0, 0, list.width, list.rowHeight)
    cell.background = false
    cell._list = list
    return cell
end

local function bindCell(list, cell, item, index)
    local win = list._win
    local font, tm = win._font, getTextManager()
    cell._item, cell._index = item, index
    cell._countText = tostring(item.count or 0)
    local countW = tm:MeasureStringX(font, cell._countText)
    local tagKey = item.hidden and "UI_MinidoracatMiniMap_RemoteTagHidden" or TAG_KEYS[item.tag]
    cell._tagText = tagKey and getText(tagKey) or nil
    cell._tagColor = item.hidden and TAG_HIDDEN or TAG_TRUST
    cell._tagW = cell._tagText and tm:MeasureStringX(font, cell._tagText) + 10 or 0
    local room = cell.width - TOGGLE_W - 12 - countW - 12 - (cell._tagText and cell._tagW + 6 or 0)
    cell._nameText = win._UI.Text.fit(item.key, math.max(16, room), font)
    cell._nameW = tm:MeasureStringX(font, cell._nameText)
end

-- 點一列（滑鼠、Enter、手把 A）＝切換這位作者
local function onRow(list, item)
    local win = list._win
    Core.remoteAuthorSet(item.key, not item.shown, win._playerNum)
    refresh(win)
end

local function onQuery(field, text)
    local win = field._win
    local q = normalizeQuery(text)
    if q == win._query then return end
    win._query = q
    win._list:setScrollOffset(0)
    refresh(win)
end

local function onHiddenOnly(win)
    win._list:setScrollOffset(0)
    refresh(win)
end

-- 底部兩顆按鈕只作用在目前清單上的作者（搜尋與「只看已隱藏」之後的）
local function onShowThese(win)
    Core.remoteAuthorSetMany(win._items, true)
    refresh(win)
end
local function onHideThese(win)
    Core.remoteAuthorSetMany(win._items, false)
    refresh(win)
end

local function layout(win)
    local w, h = win.width, win.height
    local y = win:titleBarHeight() + PAD
    win._search:setX(PAD)
    win._search:setY(y)
    win._search:setWidth(w - PAD * 2)
    y = y + win._search.height + 6
    win._metaY = y
    y = y + win._fontH + 6
    win._only:setX(PAD)
    win._only:setY(y)
    y = y + win._only.height + 6
    local half = math.floor((w - PAD * 2 - 6) / 2)
    local by = h - win._showBtn.height - PAD - 4 -- 4：右下角縮放把手
    win._showBtn:setX(PAD)
    win._showBtn:setY(by)
    win._showBtn:setWidth(half)
    win._hideBtn:setX(PAD + half + 6)
    win._hideBtn:setY(by)
    win._hideBtn:setWidth(w - PAD * 2 - half - 6)
    win._list:setX(PAD)
    win._list:setY(y)
    win._list:resize(w - PAD * 2, math.max(win._list.rowHeight, by - 6 - y))
end

local function listPrerender(self)
    self._tick = (self._tick or 0) + 1
    if self._tick >= REFRESH_FRAMES then
        self._tick = 0
        if listSig(self) ~= self._sig then refresh(self) end
    end
    self._UI.Window.prerender(self)
    local c = self.theme.colors.textMuted
    self:drawText(self._meta or "", PAD, self._metaY, c.r, c.g, c.b, c.a or 1, self._font)
end

-- 顯示／隱藏：同設定視窗（_Settings.lua studioSetVisible），手把交給視窗擁有者，隱藏時還原原焦點
-- （從設定視窗開的＝回到設定視窗）
local function listSetVisible(self, visible)
    local was = self.javaObject ~= nil and self:getIsVisible()
    ISPanel.setVisible(self, visible)
    if was == (visible == true) then return end
    local Focus = self._UI.Focus
    if not Focus then return end
    if visible then
        Focus.onFocus(self)
        local pn = self._playerNum or 0
        if JoypadState and JoypadState.players[pn + 1] then Focus.takeJoypad(self, pn) end
    else
        Focus.releaseJoypad(self)
        Focus.clear(self)
    end
end

local function create(UI, font)
    local fontH = getTextManager():getFontHeight(font)
    local win = UI.Window.new{ width = math.max(360, fontH * 24), height = 520, minWidth = 300, minHeight = 280,
        resizable = true, icon = "users", font = font, onResize = layout,
        title = getText("UI_MinidoracatMiniMap_RemoteListTitle") }
    local colors = win.theme.colors
    win._UI, win._font, win._fontH = UI, font, fontH
    win._query, win._playerNum, win._items = "", 0, {}
    win._toggleColors = { off = colors.well, on = colors.accent, border = colors.border }
    win._shape = UI.Skin.shapeOf(win.theme, "control")
    win.prerender = listPrerender
    win.setVisible = listSetVisible
    win:setVisible(false)
    win:addToUIManager()
    local search = UI.TextField.new{ width = 200, font = font, clearButton = true,
        placeholder = getText("UI_MinidoracatMiniMap_RemoteSearchHint"), onChange = onQuery }
    search._win = win
    win._search = search
    win:addChild(search)
    win._only = UI.Checkbox.new{ label = getText("UI_MinidoracatMiniMap_RemoteHiddenOnly"), target = win,
        onChange = onHiddenOnly, font = font }
    win:addChild(win._only)
    local list = UI.VirtualList.new{ x = 0, y = 0, width = 200, height = 200, rowHeight = math.max(24, fontH + 10),
        padding = 2, createCell = createCell, bindCell = bindCell, onSelect = onRow }
    list._win = win
    list:initialise()
    win._list = list
    win:addChild(list)
    -- 明示寬度：之後 setTitle 改人數時不自動改寬（Controls.lua Button.new 的 _autoWidth）
    win._showBtn = UI.Button.new{ width = 100, title = "", target = win, onClick = onShowThese, font = font }
    win._hideBtn = UI.Button.new{ width = 100, title = "", target = win, onClick = onHideThese, font = font }
    win:addChild(win._showBtn)
    win:addChild(win._hideBtn)
    layout(win)
    return win
end

-- 開清單（設定分類的「管理作者...」）。anchor＝設定視窗：沿用它的框架與字型，放在它右邊（放不下改左邊），
-- 夾進該玩家的畫面；已開著就照新擁有者重整並放到最上層
function Core.openRemoteAuthors(pn, anchor)
    local UI, font = anchor and anchor._UI, anchor and anchor._font
    if not (UI and UI.Window and UI.VirtualList and UI.TextField and UI.Checkbox) then return end
    pn = pn or 0
    local win = listUI
    if win and win._font ~= font then
        if win:isVisible() then win:close() end
        win:removeFromUIManager()
        win = nil
    end
    if not win then
        win = create(UI, font)
        listUI = win
    end
    win._playerNum = pn
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    if win.height > sh - 20 then
        win:setHeight(math.max(win.minHeight, sh - 20))
        layout(win)
    end
    local ax, aw = anchor:getAbsoluteX(), anchor.width
    local x = ax + aw + 8
    if x + win.width > sx + sw then x = ax - win.width - 8 end
    if x < sx then x = sx + math.floor((sw - win.width) / 2) end
    win:setX(x)
    win:setY(math.max(sy, math.min(anchor:getAbsoluteY(), sy + sh - win.height)))
    refresh(win)
    win:setVisible(true)
    win:bringToTop()
end

-- 測試與 E2E 的觀測面（不是公開 API）
Core.remoteListWindow = function()
    local win = listUI
    if not win then return nil end
    return { win = win, search = win._search, only = win._only, list = win._list, showBtn = win._showBtn,
        hideBtn = win._hideBtn, items = win._items, meta = win._meta }
end
