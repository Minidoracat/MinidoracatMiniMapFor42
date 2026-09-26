-- 搜尋／行程視窗離線回歸測試（原生 ISUI 殼）。
-- 用法：lua scripts/test_itinerary_ui.lua [_Search 檔]
--
-- 為什麼要整檔載入而不是抽段：本檔守的是**視窗殼行為**——開窗/切頁/收合不誤關、
-- 提示列永不當座標、確認面板的 owner+revision 防線與防誤觸、按 phase 的動作
-- 可用性、預覽距離的誠實標示、ESC 解焦不攔遊戲鍵、視窗絕不大於 viewport、
-- 名稱按實寬換行不截字。v7 另加：接續模式兩個入口只送明確布林且空／壞行程與舊版
-- API 一律停用並說明、插入位置選單的 owner/revision/錨點三重防線、逐站停等標記
-- 只吃待前往站、waiting 的「已停靠／已略過＋下一目標」語意、狀態與錯誤收不住時
-- 的全文出口。這些都是「元件擺放＋狀態轉移」的性質，切段跑不出來。
-- 基本情境使用英數鍵名；極窄版情境另載實際 CH 按鈕文案，套原版字級尺寸。
-- 這只驗證布局／事件行為，不冒充遊戲字型渲染或手把實機驗收。
-- 環境：以最小 ISUI stub 取代引擎元件；Core 側依 docs/addon-api.md §6 契約
-- 實作一份可控假件（含 _Itinerary.lua 的 start/guide/skip 守衛條件），
-- 並記錄每次呼叫供斷言。Core.Skin 刻意留 nil：同時驗證「UI 框架缺席仍可開窗」。

local sourcePath = arg[1] or
    "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Search.lua"
local fh = assert(io.open(sourcePath, "rb"))
local source = fh:read("*a"):gsub("\r\n", "\n")
fh:close()

-- CH 實際文案（狀態徽章／按鈕）：字寬與疊字都要用真文案量才算數。只搬 client
-- 檔的暫存副本裡沒有翻譯資產時退回 repo 內的 production 路徑，不複製資產。
local function loadCH()
    local path, replaced = sourcePath:gsub("[/\\]client[/\\][^/\\]+$", "/shared/Translate/CH/UI.json")
    local file = replaced == 1 and io.open(path, "rb") or nil
    if not file then
        file = assert(io.open("MOD/MinidoracatMiniMapFor42/Contents/mods/"
            .. "MinidoracatMiniMapFor42/42/media/lua/shared/Translate/CH/UI.json", "rb"),
            "找不到 CH 翻譯檔（請在 repo 根目錄執行）")
    end
    local out = {}
    -- 此 fixture 只取沒有 JSON escape 的按鈕／狀態字串，不在 production 解析 JSON。
    for keyName, value in file:read("*a"):gmatch('"([^"]+)"%s*:%s*"([^"\\]*)"') do
        out[keyName] = value
    end
    file:close()
    return out
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(msg .. "：期望 " .. tostring(expected) .. " 得到 " .. tostring(actual), 2)
    end
end
local function truthy(value, msg)
    if not value then error(msg, 2) end
end
local function falsy(value, msg)
    if value then error(msg .. "（得到 " .. tostring(value) .. "）", 2) end
end
local function contains(haystack, needle, msg)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        error(msg .. "：" .. tostring(haystack) .. " 未包含 " .. needle, 2)
    end
end
-- 換行後的顯示文字：斷行位置是版面決定的，斷言要看「接回來的整段」而不是某一行
local function linesText(lines)
    return lines and table.concat(lines, "") or nil
end
local function linesContain(lines, needle, msg)
    contains(linesText(lines), needle, msg)
end
local function listText(list)
    local rows = {}
    for i = 1, #list.items do rows[i] = linesText(list.items[i].item.lines) or "" end
    return table.concat(rows, "")
end
local function tripText(win)
    return (linesText(win.headLines) or "") .. listText(win.tripList)
end
--------------------------------------------------------------------------------
-- 最小 ISUI stub
--------------------------------------------------------------------------------
local UI = { added = {}, removed = {}, joypadFocus = {}, prevFocusRestored = 0 }

local Element = {}
Element.__index = Element
local function newElement(x, y, w, h)
    return setmetatable({ x = x or 0, y = y or 0, width = w or 0, height = h or 0,
        visible = true, children = {} }, Element)
end
function Element:initialise() end
function Element:instantiate() end
function Element:addChild(child) self.children[#self.children + 1] = child; child.parent = self end
function Element:setX(v) self.x = v end
function Element:setY(v) self.y = v end
function Element:setWidth(v) self.width = v end
function Element:setHeight(v) self.height = v end
function Element:getWidth() return self.width end
function Element:getHeight() return self.height end
function Element:setVisible(v) self.visible = v and true or false end
function Element:isVisible() return self.visible end
function Element:getIsVisible() return self.visible end
function Element:addToUIManager()
    UI.added[#UI.added + 1] = self
    if self.payload then UI.confirm = self end
end
function Element:removeFromUIManager()
    UI.removed[#UI.removed + 1] = self
    if UI.confirm == self then UI.confirm = nil end
end
function Element:bringToTop() UI.top = self end
function Element:setWantKeyEvents(want) self.wantKeyEvents = want end
function Element:isMouseOver() return false end
function Element:isMouseOverScrollBar() return false end
function Element:getYScroll() return 0 end
function Element:getMouseX() return 0 end
function Element:getMouseY() return 0 end
function Element:getAbsoluteX() return self.x end
function Element:getAbsoluteY() return self.y end
function Element:drawRect() end
function Element:drawRectBorder() end
function Element:drawText() end
function Element:drawLine() end
function Element:onGainJoypadFocus(joypadData) self.joyfocus = joypadData end
function Element:onLoseJoypadFocus() self.joyfocus = nil end

ISPanel = { new = function(_, x, y, w, h) return newElement(x, y, w, h) end }
ISPanel.onGainJoypadFocus = Element.onGainJoypadFocus
ISPanel.onLoseJoypadFocus = Element.onLoseJoypadFocus

ISButton = { new = function(_, x, y, w, h, title, target, onclick)
    local o = newElement(x, y, w, h)
    o.title, o.target, o.onclick, o.enable = title, target, onclick, true
    o.setTitle = function(self, t) self.title = t end
    o.setEnable = function(self, v) self.enable = v and true or false end
    return o
end }

ISScrollingListBox = { new = function(_, x, y, w, h)
    local o = newElement(x, y, w, h)
    o.items, o.selected, o.itemheight, o.yScroll = {}, 1, 20, 0
    o.addItem = function(self, text, item)
        local row = { text = text, item = item, itemindex = #self.items + 1, height = self.itemheight }
        self.items[row.itemindex] = row
        return row
    end
    o.clear = function(self) self.items, self.selected, self.yScroll = {}, 1, 0 end
    o.rowAt = function(self, _, y)
        local y0 = 0
        for i, row in ipairs(self.items) do
            local h = row.height or self.itemheight
            if y >= y0 and y < y0 + h then return i end
            y0 = y0 + h
        end
        return -1
    end
    -- 原版 ensureVisible（ISScrollingListBox.lua:623-639）：只把該列的頂端或底端
    -- 對齊可視範圍，沒有列內捲動也沒有逐頁捲動。列高大於清單高時必然只露出一端，
    -- 中段按幾次方向鍵都看不到——「全文讀得到」的斷言就是靠這份真實行為判定。
    -- 這裡用瞬間捲動取代原版的 smoothScroll：測的是「最終能不能露出」
    o.ensureVisible = function(self, index)
        self.ensuredIndex = index
        if not index or index < 1 or index > #self.items then return end
        local y, height = 0, 0
        for k = 1, #self.items do
            local row = self.items[k]
            if k == index then height = row.height or self.itemheight; break end
            y = y + (row.height or self.itemheight)
        end
        if y <= -self.yScroll then
            self.yScroll = -y
        elseif y + height > -self.yScroll + self.height then
            self.yScroll = -(y + height - self.height)
        end
    end
    o.getYScroll = function(self) return self.yScroll end
    o.setOnMouseDoubleClick = function(self, target, fn) self.dblTarget, self.dblFn = target, fn end
    return o
end }

ISTextEntryBox = { new = function(_, title, x, y, w, h)
    local o = newElement(x, y, w, h)
    o.text, o.focused = title or "", false
    o.getInternalText = function(self) return self.text end
    o.setClearButton = function() end
    o.setPlaceholderText = function() end
    o.focus = function(self) self.focused = true end
    o.unfocus = function(self) self.focused = false end
    o.isFocused = function(self) return self.focused end
    o.hasClearButton = function() return true end
    o.onJoypadDown = function(self) self.oskShown = true end
    return o
end }

ISWorldMap = { pings = {}, ShowWorldMap = function(pn, x, y, zoom)
    ISWorldMap.pings[#ISWorldMap.pings + 1] = { pn = pn, x = x, y = y, zoom = zoom }
end }
ISWorldMap_instance = nil

UIFont = { Small = 1, Medium = 2 }
Keyboard = { KEY_ESCAPE = 1, KEY_TAB = 15, KEY_RETURN = 28, KEY_UP = 200,
    KEY_DOWN = 208, KEY_LEFT = 203, KEY_RIGHT = 205, KEY_W = 17, KEY_A = 30,
    KEY_S = 31, KEY_D = 32, KEY_T = 20, KEY_SEMICOLON = 39, KEY_SLASH = 53,
    KEY_APOSTROPHE = 40 }
Joypad = { AButton = 1, BButton = 2, XButton = 3, YButton = 4 }
JoypadState = { players = {} }
function setJoypadFocus(pn, control)
    local data = JoypadState.players[pn + 1]
    if not data then return end
    if control and control ~= data.focus then
        data.prevprevfocus, data.prevfocus = data.prevfocus, data.focus
    end
    data.focus = control
end
function setPrevFocusForPlayer(pn)
    local data = JoypadState.players[pn + 1]
    if not data then return end
    data.focus, data.prevfocus, data.prevprevfocus = data.prevfocus, data.prevprevfocus, nil
end
ISContextMenu = { get = function(pn, x, y)
    local menu = newElement(x, y, 200, 200)
    menu.options, menu.player, menu.mouseOver = {}, pn, 1
    menu.itemHgt = getTextManager():getFontHeight(UIFont.Small) + 6
    menu.padTopBottom, menu.scrollIndicatorHgt = 1, 12
    function menu:calcWidth()
        local width = 0
        for _, option in ipairs(self.options) do
            width = math.max(width, getTextManager():MeasureStringX(UIFont.Small, option.text))
        end
        return math.max(100, width + 32)
    end
    function menu:calcHeight()
        self.scrollHeight = #self.options * self.itemHgt
        self.scrollAreaHeight = self.scrollHeight
        self.height = self.scrollHeight + self.padTopBottom * 2
    end
    function menu:setSlideGoalX(_, x) self:setX(x) end
    function menu:setSlideGoalY(_, y) self:setY(y) end
    function menu:addOption(text, target, fn, param)
        -- param1 一路帶到 onSelect（原版 ISContextMenu.lua:70 同樣把 param 傳回去）：
        -- 插入位置選項就是靠它捕捉 owner／revision／錨點
        local item = { text = text, target = target, onSelect = fn, param = param }
        self.options[#self.options + 1] = item
        self:calcHeight()
        self:setWidth(self:calcWidth())
        return item
    end
    function menu:closeAll()
        self:setVisible(false)
        if JoypadState.players[self.player + 1] then setJoypadFocus(self.player, self.origin) end
    end
    function menu:onJoypadDirDown() self.mouseOver = self.mouseOver % #self.options + 1 end
    function menu:onJoypadDirUp() self.mouseOver = (self.mouseOver - 2) % #self.options + 1 end
    function menu:onJoypadDown(button)
        if button == Joypad.BButton then self:closeAll(); return end
        local item = self.options[self.mouseOver]
        if button == Joypad.AButton and item and not item.notAvailable then
            self:closeAll()
            item.onSelect(item.target, item.param)
        end
    end
    return menu
end }
function isShiftKeyDown() return false end

local fontHeights = { [UIFont.Small] = 14, [UIFont.Medium] = 18 }
local textManager = {
    MeasureStringX = function(_, _, text) return #tostring(text) * 6 end,
    getFontHeight = function(_, font) return fontHeights[font] or 14 end,
}
function getTextManager() return textManager end
function getText(key, a, b, c)
    local out = tostring(key)
    if a then out = out .. "|" .. tostring(a) end
    if b then out = out .. "|" .. tostring(b) end
    if c then out = out .. "|" .. tostring(c) end
    return out
end
function getTextOrNull() return nil end
function getActivatedMods()
    return { size = function() return 0 end, get = function() return "" end }
end
local clock = 1000
function getTimestampMs() return clock end
local screen = { w = 1920, h = 1080 }
keyBinding = {}
local boundKeys = { MinidoracatMiniMap_Toggle = Keyboard.KEY_SLASH,
    MinidoracatMiniMap_Ghost = Keyboard.KEY_APOSTROPHE }
function getCore()
    return {
        getScreenWidth = function() return screen.w end,
        getScreenHeight = function() return screen.h end,
        getKey = function(_, name) return boundKeys[name] or 0 end,
    }
end
function getPlayerScreenLeft() return 0 end
function getPlayerScreenTop() return 0 end
function getPlayerScreenWidth() return screen.w end
function getPlayerScreenHeight() return screen.h end

local halos = {}
HaloTextHelper = {
    addBadText = function(playerObj, text)
        halos[#halos + 1] = { player = playerObj, text = text }
    end,
    addGoodText = function(playerObj, text)
        halos[#halos + 1] = { player = playerObj, text = text, good = true }
    end,
}

local players = {}
local function makePlayer(x, y) return { x = x or 0, y = y or 0,
    getX = function(self) return self.x end, getY = function(self) return self.y end } end
players[0] = makePlayer(0, 0)
players[1] = makePlayer(500, 500)
function getSpecificPlayer(pn) return players[pn] end

local hooks = {}
Events = {
    OnGameStart = { Add = function() end },
    OnGameBoot = { Add = function(fn) hooks.boot = fn end },
    OnKeyPressed = { Add = function(fn) hooks.key = fn end },
}
MinidoracatMiniMapStreetNames = nil
MinidoracatMiniMapPOICategories = nil
MinidoracatMiniMapPOIData = nil

--------------------------------------------------------------------------------
-- Core 假件（依 §6 契約；記錄呼叫供斷言）
--------------------------------------------------------------------------------
local trips, tripErrors, calls = {}, {}, {}
local result = {
    edit = { ok = true, reason = "ok" },
    set = { ok = true, reason = "ok" },
    pause = { ok = true, reason = "ok" },
    guide = { ok = true, reason = "ok" },
    start = { token = "tok", reason = "ok" },
    canUndo = false,
    preview = { state = "off", done = 0, total = 0, distance = 0 },
    continuation = { ok = true, reason = "ok" },
}
local Core = {
    ready = true,
    navEngineState = function() return "ready" end,
    navStreetIndex = function() return {} end,
}
MinidoracatMiniMapCore = Core
MinidoracatMiniMapAPI = {}

local function record(kind, t)
    t.kind = kind
    calls[#calls + 1] = t
    return t
end
local function rev(pn) return trips[pn] and trips[pn].revision or 0 end

Core.navItineraryState = function(pn) return trips[pn] end
Core.navItineraryError = function(pn) return tripErrors[pn] end
Core.navErrorText = function(reason, detailKey)
    if reason == "blocked" and type(detailKey) == "string" and detailKey ~= "" then
        return detailKey
    end
    return "UI_MinidoracatMiniMap_TripError_" .. tostring(reason or "failed")
end
Core.navEditItinerary = function(pn, expectedRevision, op, a, b, c, d)
    record("edit", { pn = pn, rev = expectedRevision, op = op, a = a, b = b, c = c, d = d })
    if expectedRevision ~= rev(pn) then return false, "stale" end
    return result.edit.ok, result.edit.reason
end
Core.navSetTarget = function(pn, x, y, label)
    record("set", { pn = pn, x = x, y = y, label = label })
    return result.set.ok, result.set.reason
end
Core.navPauseItinerary = function(pn, reason)
    record("pause", { pn = pn, reason = reason })
    return result.pause.ok, result.pause.reason
end
Core.navGuideItinerary = function(pn, expectedRevision, mode)
    record("guide", { pn = pn, rev = expectedRevision, mode = mode })
    return result.guide.ok, result.guide.reason
end
Core.navSetPreview = function(pn, enabled)
    record("preview", { pn = pn, enabled = enabled })
    return true
end
Core.navPreviewState = function()
    local p = result.preview
    return p.state, p.done, p.total, p.distance
end
Core.navCanUndo = function() return result.canUndo end
Core.navKickAvailable = function(pn) record("kick", { pn = pn }) end
MinidoracatMiniMapAPI.startNavItinerary = function(pn, expectedRevision)
    record("start", { pn = pn, rev = expectedRevision })
    return result.start.token, result.start.reason
end
-- v7 公開 setter（UI 唯一的模式入口）＋版本欄位：UI 必須同時查兩者
MinidoracatMiniMapAPI.navApiVersion = 7
MinidoracatMiniMapAPI.setNavContinuation = function(pn, expectedRevision, enabled)
    record("continuation", { pn = pn, rev = expectedRevision, enabled = enabled })
    return result.continuation.ok, result.continuation.reason
end

-- v7 認領表面：真 Core 只在 API.getNavItinerary 的**複本**上補 claimed
-- （_Itinerary.lua getItinerary:294-296），私有 raw trip（navItineraryState）永遠
-- 沒有這個欄位。fixture 照這個形狀做，才測得出 UI 有沒有讀錯資料來源。
-- claim／release／report 在真 Core 都會推進 revision（claim:358、release:410、
-- commit:173），所以改 claims 的情境一律同時給新的 revision
local claims = {}
MinidoracatMiniMapAPI.getNavItinerary = function(pn)
    record("snapshot", { pn = pn })
    local trip = trips[pn]
    if not trip then return nil, "noitinerary" end
    local copy = { schemaVersion = 2, revision = trip.revision, count = trip.count,
        nextStopId = trip.nextStopId, currentStopId = trip.currentStopId,
        phase = trip.phase, reason = trip.reason, autoContinue = trip.autoContinue,
        stops = {}, claimed = claims[pn] == true }
    for i = 1, trip.count do
        local s = trip.stops[i]
        copy.stops[i] = { id = s.id, x = s.x, y = s.y, label = s.label,
            status = s.status, pause = s.pause }
    end
    return copy
end

assert((loadstring or load)(source, "search-ui"))()

--------------------------------------------------------------------------------
-- 測試輔助
--------------------------------------------------------------------------------
local function clearCalls() for i = #calls, 1, -1 do calls[i] = nil end end
local function lastCall(kind)
    for i = #calls, 1, -1 do
        if calls[i].kind == kind then return calls[i] end
    end
    return nil
end
local function countCalls(kind)
    local n = 0
    for i = 1, #calls do
        if calls[i].kind == kind then n = n + 1 end
    end
    return n
end
local function stop(id, x, y, status, label, pause)
    return { id = id, x = x, y = y, status = status or "pending", label = label,
        pause = pause == true }
end
-- v7 快照（schemaVersion 2）：trip.autoContinue 與 stop.pause 是布林。
-- claimed **不**寫進這份私有 raw trip——真 Core 只在公開 API 的複本上補
-- （見上方 getNavItinerary），所以 options.claimed 只改 claims 表
local function setTrip(pn, phase, stops, currentStopId, reason, revision, options)
    trips[pn] = { schemaVersion = 2, revision = revision or 7, count = #stops,
        nextStopId = #stops + 1, stops = stops, currentStopId = currentStopId,
        phase = phase, reason = reason,
        autoContinue = not (options ~= nil and options.auto == false) }
    claims[pn] = options ~= nil and options.claimed == true
end
-- 次要動作不在底部：可見就直接按，否則照玩家路徑經「動作…」選單選同名項目
local function pressButton(btn)
    truthy(btn, "按鈕不存在")
    truthy(btn.enable, "按鈕應可用才按得下")
    if btn:isVisible() then
        btn.onclick(btn.target, btn)
        return
    end
    local w = btn.target
    local more = w.page == "itinerary" and w.tripMoreBtn or w.searchMoreBtn
    truthy(more:isVisible(), "按鈕須可見，或能從動作選單選到")
    more.onclick(more.target, more)
    local menu = w.nativeMenu
    for i, option in ipairs(menu.options) do
        if option.text == btn.title then
            menu.mouseOver = i
            menu:onJoypadDown(Joypad.AButton)
            return
        end
    end
    error("動作選單沒有「" .. tostring(btn.title) .. "」", 2)
end
local function openWindow(pn, page)
    Core.toggleSearchWindow(pn, page)
    for i = #UI.added, 1, -1 do
        if UI.added[i].tabs then return UI.added[i] end
    end
    return nil
end
-- 行程清單的列一律以 stopId 找，不用固定索引：狀態列收不住時清單前面會多出全文
-- 列，用索引選站會選到說明列（那不是站，動作理當停用）
local function tripRow(win, stopId)
    for i = 1, #win.tripList.items do
        local row = win.tripList.items[i]
        if row.item.kind == "trip" and row.item.stopId == stopId then return row, i end
    end
    error("行程清單裡找不到站 " .. tostring(stopId), 2)
end
local function tripRowCount(win)
    local count = 0
    for _, row in ipairs(win.tripList.items) do
        if row.item.kind == "trip" then count = count + 1 end
    end
    return count
end
local function selectStop(win, stopId)
    local row, index = tripRow(win, stopId)
    win.tripList.selected = index
    win._tripSel = nil
    win:prerender() -- 讓選取相依的按鈕依新選取重算
    return row.item
end
local function key(win, code)
    win:onKeyRelease(code)
    return win:isKeyConsumed(code) -- 真 UIElement：先派發，再詢問是否已消耗。
end
local win

--------------------------------------------------------------------------------
-- A. 開窗／切頁／收合／owner-transfer
--------------------------------------------------------------------------------
setTrip(0, "draft", { stop(1, 100, 100), stop(2, 200, 200) }, nil, nil, 7)
win = openWindow(0)
truthy(win and win.page == "search", "A1: 不帶 page 開窗須落在搜尋頁")
truthy(win:isVisible(), "A1: 開窗須可見")
truthy(win.entry:isFocused(), "A1: 搜尋頁開窗須聚焦輸入框（可直接打字）")

Core.toggleSearchWindow(0, "itinerary")
eq(win.page, "itinerary", "A2: 明確 page 須切頁")
truthy(win:isVisible(), "A2: 明確 page 不得關窗")
falsy(win.entry:isFocused(), "A2: 行程頁不得留著聚焦的輸入框（會白攔遊戲鍵盤）")

Core.toggleSearchWindow(0, "itinerary")
truthy(win:isVisible(), "A3: 同一頁再按明確 page 仍不得關窗（右鍵入口按兩次）")
eq(win.page, "itinerary", "A3: 頁面不變")

Core.toggleSearchWindow(0, "search")
eq(win.page, "search", "A4: 可切回搜尋頁")

local removedBefore = #UI.removed
Core.toggleSearchWindow(0)
eq(#UI.removed, removedBefore + 1, "A5: 不帶 page 且同一玩家＝關窗（原 toggle 語意）")
falsy(win:isVisible(), "A5: 關窗後不可見")
falsy(win.entry:isFocused(), "A5: 關窗必解焦，否則不可見輸入框續攔遊戲鍵盤")

-- 視窗收合：只留標題列，完全不吃鍵盤；再按快捷鍵/按鈕等於展開而非關窗
win = openWindow(0, "itinerary")
local fullH = win.height
pressButton(win.collapseBtn)
truthy(win.collapsed, "A6: 收合旗標")
truthy(win.height < fullH, "A6: 收合後高度只剩標題列")
falsy(win.tripList:isVisible(), "A6: 收合時清單不可見")
falsy(win.startBtn:isVisible(), "A6: 收合時動作鈕不可見")
falsy(win.entry:isFocused(), "A6: 收合必解焦")
falsy(win:isKeyConsumed(Keyboard.KEY_ESCAPE), "A7: 收合時連 ESC 都不攔（不吃遊戲鍵）")
falsy(win:isKeyConsumed(Keyboard.KEY_TAB), "A7: 收合時 TAB 不攔")
falsy(win.focus, "A7: 收合時無焦點環")
removedBefore = #UI.removed
Core.toggleSearchWindow(0)
eq(#UI.removed, removedBefore, "A8: 收合狀態下再 toggle＝展開，不得關窗")
falsy(win.collapsed, "A8: 已展開")
eq(win.height, fullH, "A8: 展開回原高度")
truthy(win.tripList:isVisible(), "A8: 展開後清單回來")

-- 分割畫面：他人按下不得誤關，且行程必須改查新擁有者
setTrip(1, "waiting", { stop(9, 800, 800, "arrived"), stop(10, 900, 900) }, 9, nil, 3)
win:prerender()
eq(tripRowCount(win), 2, "A9: pn0 行程兩站，不把全文說明當成站")
eq(tripRow(win, 1).item.stopId, 1, "A9: 列出的是 pn0 的站")
Core.toggleSearchWindow(1)
truthy(win:isVisible(), "A10: 他人按下須 owner-transfer，不得誤關")
eq(win.playerNum, 1, "A10: 擁有者已轉移")
win:prerender()
eq(tripRow(win, 9).item.stopId, 9, "A10: 行程改查新擁有者，不把前一位玩家的行程搬過來")
Core.toggleSearchWindow(1)

--------------------------------------------------------------------------------
-- B. 提示列永不當座標／站點；復原入口保留
--------------------------------------------------------------------------------
trips[0], tripErrors[0] = nil, nil
win = openWindow(0, "itinerary")
win:prerender()
truthy(#win.tripList.items >= 2, "B1: 空行程須顯示說明列（怎麼建立、怎麼選模式）")
falsy(win.tripList.items[1].item.stopId, "B1: 說明列不是站點")
local mapPings = #ISWorldMap.pings
win.tripList.selected = 1
truthy(win.tripMoreBtn:isVisible(), "B2: 空行程頁仍須保留復原入口（動作選單）")
result.canUndo = true
win._tRev = nil
win:prerender()
truthy(win.undoBtn.enable, "B2: 快照為 nil 但 Core 說可復原時，復原必須按得下")
clearCalls()
pressButton(win.undoBtn)
eq(lastCall("edit").op, "undo", "B2: 復原走 undo")
eq(lastCall("edit").rev, 0, "B2: 無行程時 expectedRevision=0")
result.canUndo = false
win._tRev = nil
win:prerender()
clearCalls()
falsy(win.upBtn.enable, "B3: 選到說明列時上移須不可用")
falsy(win.removeBtn.enable, "B3: 選到說明列時移除須不可用")
falsy(win.mapBtn.enable, "B3: 選到說明列時在地圖顯示須不可用")
win.upBtn.onclick(win.upBtn, win.upBtn)
win.removeBtn.onclick(win.removeBtn, win.removeBtn)
win.mapBtn.onclick(win.mapBtn, win.mapBtn)
eq(countCalls("edit"), 0, "B4: 說明列不得觸發任何行程編輯")
eq(#ISWorldMap.pings, mapPings, "B4: 說明列不得產生地圖座標 ping")

tripErrors[0] = "invalid"
win._tRev = nil
win:prerender()
truthy(#win.tripList.items >= 2, "B5: 資料損壞須顯示原因與重建說明")
linesContain(win.tripList.items[1].item.lines, "TripError_invalid", "B5: 第一列說明損壞原因")
falsy(win.tripList.items[1].item.stopId, "B5: 損壞提示列不是站點")
truthy(win.clearBtn.enable, "B6: 資料損壞時清空必須可按（那是重建出口）")

--------------------------------------------------------------------------------
-- C. 取代／清空的確認、明確動詞、預設取消、owner+revision 防線
--    本段刻意先關窗：驗證「地圖右鍵直接編輯行程、視窗沒開」時失敗仍看得見
--    （退原版 halo 壞訊息，同 navSetTarget 既有通道），不得靜默
--------------------------------------------------------------------------------
Core.toggleSearchWindow(0)
falsy(win:isVisible(), "C0: 本段在關窗狀態下跑")
tripErrors[0] = nil
trips[0] = nil
clearCalls()
UI.confirm = nil
Core.navPromptTarget(0, 111, 222, "Home", "replace")
falsy(UI.confirm, "C1: 沒有舊行程時取代不必確認")
eq(lastCall("set").x, 111, "C1: 直接走 navSetTarget")

setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 7)
clearCalls()
UI.confirm = nil
Core.navPromptTarget(0, 333, 444, "Bar", "replace")
local panel = UI.confirm
truthy(panel, "C2: 有舊行程時取代須先確認")
eq(countCalls("set"), 0, "C2: 確認前不得寫入")
falsy(panel.onConfirm, "C2: 預設焦點在取消（破壞性動作不接受順手 Enter）")
panel:onKeyRelease(Keyboard.KEY_RETURN)
eq(countCalls("set"), 0, "C2: 直接按 Enter 只會取消，不得執行取代")
falsy(panel:isVisible(), "C2: 取消後面板關閉")

clearCalls()
Core.navPromptTarget(0, 555, 666, "Baz", "replace")
panel = UI.confirm
panel:onKeyRelease(Keyboard.KEY_TAB)
truthy(panel.onConfirm, "C3: TAB 把焦點移到動作鈕")
panel:onKeyRelease(Keyboard.KEY_RETURN)
eq(lastCall("set").x, 555, "C3: 焦點在動作鈕時 Enter 才執行")

clearCalls()
Core.navPromptTarget(0, 1, 1, "Esc", "replace")
panel = UI.confirm
panel:onKeyRelease(Keyboard.KEY_ESCAPE)
eq(countCalls("set"), 0, "C4: ESC 取消")
clearCalls()
Core.navPromptTarget(0, 2, 2, "PadB", "replace")
panel = UI.confirm
panel:onJoypadDown(Joypad.BButton)
eq(countCalls("set"), 0, "C5: 手把 B 取消")
clearCalls()
Core.navPromptTarget(0, 3, 3, "PadA", "replace")
panel = UI.confirm
panel:onJoypadDown(Joypad.AButton)
eq(countCalls("set"), 0, "C6: 手把 A 在預設焦點（取消）上不得直接刪改")

-- 確認期間行程被改動（revision 前進）→ 整筆拒絕
clearCalls()
Core.navPromptTarget(0, 777, 888, "Stale", "replace")
panel = UI.confirm
trips[0].revision = 8
pressButton(panel.actionBtn)
eq(countCalls("set"), 0, "C7: revision 已變的舊面板不得覆蓋新行程")
contains(halos[#halos].text, "TripError_stale", "C7: 須明確回報 stale")

-- 確認期間換角色（同槽位不同角色物件）→ 不碰新角色
clearCalls()
Core.navPromptTarget(0, 999, 1000, "Swap", "replace")
panel = UI.confirm
players[0] = makePlayer(0, 0)
pressButton(panel.actionBtn)
eq(countCalls("set"), 0, "C8: 換角色後的舊面板不得寫入新角色行程")

-- 正常確認：以捕捉時的 revision 套用
clearCalls()
setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 11)
Core.navPromptTarget(0, 1234, 5678, "Yes", "replace")
panel = UI.confirm
pressButton(panel.actionBtn)
local setCall = lastCall("set")
truthy(setCall, "C9: 確認後須寫入")
eq(setCall.x, 1234, "C9: 帶原座標")
eq(setCall.label, "Yes", "C9: 帶名稱")

-- 資料損壞時 snapshot 為 nil，取代同樣要確認
trips[0], tripErrors[0] = nil, "unsupported"
clearCalls()
UI.confirm = nil
Core.navPromptTarget(0, 1, 2, nil, "replace")
truthy(UI.confirm, "C10: 損壞資料存在時取代仍須明確確認")
eq(countCalls("set"), 0, "C10: 確認前不得寫入")
pressButton(UI.confirm.cancelBtn)

-- 損壞資料且無站點：清空必須可用（重建出口），不得回報「沒有行程」
clearCalls()
UI.confirm = nil
Core.navPromptClear(0)
truthy(UI.confirm, "C11: 損壞資料時清空須彈確認，不得拒絕")
pressButton(UI.confirm.actionBtn)
eq(lastCall("edit").op, "clear", "C11: 確認後送出 clear 以重建")
eq(lastCall("edit").rev, 0, "C11: 損壞且無站點時 expectedRevision=0")

-- 真的什麼都沒有時才回報沒有行程
tripErrors[0], trips[0] = nil, nil
clearCalls()
UI.confirm = nil
Core.navPromptClear(0)
falsy(UI.confirm, "C12: 既無站點也無損壞時不彈確認窗")
eq(countCalls("edit"), 0, "C12: 不得送出 clear")
contains(halos[#halos].text, "TripError_noitinerary", "C12: 須明確回報沒有行程")

-- append/priority 不確認、不自動出發，且帶目前 revision
setTrip(0, "navigating", { stop(1, 100, 100) }, 1, nil, 21)
clearCalls()
UI.confirm = nil
Core.navPromptTarget(0, 300, 400, "Add", "append")
falsy(UI.confirm, "C13: 加入停靠點不需確認")
eq(lastCall("edit").op, "append", "C13: op=append")
eq(lastCall("edit").rev, 21, "C13: 帶目前 revision")
eq(countCalls("start"), 0, "C13: 加入停靠點不得自動出發")
Core.navPromptTarget(0, 300, 400, "First", "priority")
eq(lastCall("edit").op, "priority", "C14: op=priority（舊的 next 已不存在）")
eq(countCalls("start"), 0, "C14: 開始導航由 Core 在 priority 內完成，UI 不另發 start")
-- 未知／舊 op：零編輯、零確認、零導航。落回 replace 語意等於把一次編輯升格成
-- 取代整趟，空行程時更直接建立單站行程並立刻出發——那是這支函式最破壞性的
-- 一條路，不能靠猜（review UI-1）。本 MOD 三個入口都明傳 op
clearCalls()
UI.confirm = nil
Core.navPromptTarget(0, 300, 400, "Legacy", "next")
eq(countCalls("edit"), 0, "C14b: 舊 op 名稱不是編輯入口")
eq(countCalls("set"), 0, "C14b: 也不得升格成取代並立刻導航")
falsy(UI.confirm, "C14b: 不得開取代確認")
contains(halos[#halos].text, "TripError_badargs", "C14b: 須明確回報 badargs，不得靜默")
Core.navPromptTarget(0, 300, 400, "Bogus", "sideways")
Core.navPromptTarget(0, 300, 400, "NoOp")
eq(countCalls("edit") + countCalls("set"), 0,
    "C14c: 任意未知字串與省略 op 同樣零副作用（沒有隱含預設）")
falsy(UI.confirm, "C14c: 也都不得開確認")
-- 空行程是最危險的分支：落回 replace 會直接 navSetTarget 建立單站行程並發車
trips[0] = nil
clearCalls()
Core.navPromptTarget(0, 300, 400, "Legacy", "next")
eq(countCalls("set"), 0, "C14d: 空行程時未知 op 不得直接建立導航")
eq(countCalls("edit"), 0, "C14d: 也不得送出任何編輯")
falsy(UI.confirm, "C14d: 空行程時也不得開確認")
setTrip(0, "navigating", { stop(1, 100, 100) }, 1, nil, 21)

-- 有站點的清空確認
clearCalls()
UI.confirm = nil
Core.navPromptClear(0)
truthy(UI.confirm, "C15: 清空須確認")
eq(countCalls("edit"), 0, "C15: 確認前不得清空")
pressButton(UI.confirm.actionBtn)
eq(lastCall("edit").op, "clear", "C15: 確認後才 clear")
eq(lastCall("edit").rev, 21, "C15: clear 帶捕捉時的 revision")

-- 面板開著時底層視窗完全不處理鍵盤，且開面板前必先解焦輸入框
win = openWindow(0, "search")
truthy(win.entry:isFocused(), "C16: 搜尋頁開窗聚焦輸入框")
UI.confirm = nil
Core.navPromptClear(0)
truthy(UI.confirm, "C16: 面板開啟")
falsy(win.entry:isFocused(), "C16: 開面板前必先解焦，否則底層吃掉 Enter/ESC")
falsy(win:isKeyConsumed(Keyboard.KEY_ESCAPE), "C17: 面板開著時底層視窗不攔鍵")
falsy(win:isKeyConsumed(Keyboard.KEY_TAB), "C17: 面板開著時底層 TAB 也不攔")
pressButton(UI.confirm.cancelBtn)
truthy(win:isKeyConsumed(Keyboard.KEY_ESCAPE), "C18: 面板關閉後底層恢復處理 ESC")

--------------------------------------------------------------------------------
-- D. 行程頁動作接的是真契約
--------------------------------------------------------------------------------
setTrip(0, "waiting", { stop(1, 100, 100, "arrived"), stop(2, 200, 200), stop(3, 300, 300) }, 1, nil, 31)
win = openWindow(0, "itinerary")
win._tRev = nil
win:prerender()
clearCalls()
pressButton(win.startBtn)
eq(lastCall("start").rev, 31, "D1: 開始/繼續走 API.startNavItinerary 並帶目前 revision")

-- 邊界動作不得假亮；實際重排與 token 保留另以尾端真 Core 情境驗證。
selectStop(win, 3)
truthy(win.upBtn.enable, "D2: 最後一個待辦可上移")
falsy(win.downBtn.enable, "D3: 最後一站沒有更後的位置")
truthy(win.removeBtn.enable, "D4: 合法站點仍可移除")
selectStop(win, 2)
falsy(win.upBtn.enable, "D4: 不能上移跨過已抵達前綴")
truthy(win.downBtn.enable, "D4: 待辦區內可下移")

-- 停止導航／手動前往
setTrip(0, "approach", { stop(1, 100, 100) }, 1, nil, 41)
win._tRev = nil
win:prerender()
clearCalls()
pressButton(win.pauseBtn)
eq(lastCall("pause").reason, "manual", "D5: 停止導航走 navPauseItinerary(manual)")
pressButton(win.manualBtn)
eq(lastCall("guide").rev, 41, "D6: 手動前往走 navGuideItinerary 並帶 revision")

-- 略過：只認「目前站且仍 pending」，對象是 currentStopId 不是選取列
setTrip(0, "navigating", { stop(1, 10, 10, "arrived"), stop(2, 20, 20), stop(3, 30, 30) }, 2, nil, 45)
win._tRev = nil
win:prerender()
selectStop(win, 3)
clearCalls()
pressButton(win.skipBtn)
eq(lastCall("edit").op, "skip", "D7: 略過走 skip")
eq(lastCall("edit").a, 2, "D7: 略過對象是目前站，不是選取的那站")

-- 預覽開關：狀態是權威，按鈕只送明確 on/off
result.preview = { state = "off", done = 0, total = 0, distance = 0 }
win._tRev = nil
win:prerender()
clearCalls()
pressButton(win.previewBtn)
eq(lastCall("preview").enabled, true, "D8: 預覽關閉時按下＝開啟")
result.preview = { state = "ok", done = 2, total = 2, distance = 1500 }
win._tRev = nil
win:prerender()
pressButton(win.previewBtn)
eq(lastCall("preview").enabled, false, "D9: 預覽開啟時按下＝關閉")

-- 失敗必回報原因，不得靜默
result.edit = { ok = false, reason = "notstopped" }
selectStop(win, 1)
clearCalls()
pressButton(win.removeBtn)
linesContain(win.msgLines, "TripError_notstopped", "D10: 編輯被拒須在視窗內顯示原因")
result.edit = { ok = true, reason = "ok" }
result.start = { token = nil, reason = "blocked" }
setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 51)
win._tRev = nil
win:prerender()
pressButton(win.startBtn)
linesContain(win.msgLines, "TripError_blocked", "D11: 開始被 gate 擋須顯示原因")
result.start = { token = "tok", reason = "ok" }

--------------------------------------------------------------------------------
-- E. 按 phase 的動作可用性（逐條對齊 _Itinerary.lua 守衛，不得假亮）
--------------------------------------------------------------------------------
local function phaseState(phase, reason, stops, current)
    -- draft 依契約 currentStopId 必為 nil；不能寫成 `and nil or 1`（Lua 恆得 1）
    if current == nil and phase ~= "draft" then current = 1 end
    setTrip(0, phase, stops or { stop(1, 100, 100, "pending") }, current, reason, 61)
    win._tRev = nil
    win:prerender()
end
phaseState("draft")
truthy(win.startBtn.enable, "E1: draft 可開始")
falsy(win.pauseBtn.enable, "E1: draft 沒有導航可停")
falsy(win.manualBtn.enable, "E1: draft 不是 guide 的合法狀態")
falsy(win.skipBtn.enable, "E1: draft 沒有 currentStopId，略過不得假亮")
phaseState("navigating")
falsy(win.startBtn.enable, "E2: 導航中不需再開始")
truthy(win.pauseBtn.enable, "E2: 導航中可停止")
truthy(win.manualBtn.enable, "E2: 導航中可改手動前往")
truthy(win.skipBtn.enable, "E2: 導航中目前站可略過")
phaseState("approach")
truthy(win.manualBtn.enable, "E3: 直線指引須有直接切回道路的出口")
truthy(win.pauseBtn.enable, "E3: approach 可停止")
-- waiting：currentStopId 指向剛完成的站（非 pending）→ 略過不得假亮
phaseState("waiting", nil, { stop(1, 10, 10, "arrived"), stop(2, 20, 20) }, 1)
truthy(win.startBtn.enable, "E4: waiting 可繼續下一站")
falsy(win.pauseBtn.enable, "E4: waiting 沒有進行中的導航")
falsy(win.manualBtn.enable, "E4: waiting 不是 guide 的合法狀態")
falsy(win.skipBtn.enable, "E4: waiting 的目前站已完成，略過不得假亮")
phaseState("paused", "noroad")
truthy(win.startBtn.enable, "E5: paused 可恢復")
truthy(win.manualBtn.enable, "E5: 無路時仍要能明確手動前往")
truthy(win.skipBtn.enable, "E5: paused 的目前站仍 pending，可略過")
setTrip(0, "completed", { stop(1, 100, 100, "arrived") }, nil, nil, 62)
win._tRev = nil
win:prerender()
falsy(win.startBtn.enable, "E6: completed 沒有 pending 站可出發")
falsy(win.skipBtn.enable, "E6: completed 沒有可略過的站")
truthy(win.clearBtn.enable, "E6: completed 仍可清空")
result.canUndo = true
win._tRev = nil
win:prerender()
truthy(win.undoBtn.enable, "E7: Core 說可復原時復原可用")
result.canUndo = false
win._tRev = nil
win:prerender()
falsy(win.undoBtn.enable, "E7: Core 說不可復原時復原不可用")

--------------------------------------------------------------------------------
-- F. phase 色語與預覽距離的誠實標示
--------------------------------------------------------------------------------
phaseState("paused", "manual")
local normalPaused = win.headColor
phaseState("paused", "noroad")
truthy(win.headColor ~= normalPaused, "F1: 無路的 paused 須與正常停止導航區分")
phaseState("navigating")
truthy(win.headColor ~= normalPaused, "F2: 導航中與停止不同色")

result.preview = { state = "pending", done = 0, total = 0, distance = 0 }
win._tRev = nil
win:prerender()
local sub = table.concat(win.subLines, "")
falsy(sub:find("TripPreviewDist", 1, true), "F3: 重排空窗的 distance 0 不得標成總長")
falsy(sub:find("TripPreviewPartial", 1, true), "F3: distance 0 完全不顯示距離")
result.preview = { state = "pending", done = 1, total = 3, distance = 800 }
win._tRev = nil
win:prerender()
linesContain(win.subLines, "TripPreviewPartial", "F4: 未全就緒只能標已算出部分")
result.preview = { state = "ok", done = 2, total = 3, distance = 900 }
win._tRev = nil
win:prerender()
linesContain(win.subLines, "TripPreviewPartial", "F5: state=ok 但段數未齊仍是部分和")
result.preview = { state = "ok", done = 3, total = 3, distance = 2400 }
win._tRev = nil
win:prerender()
linesContain(win.subLines, "TripPreviewDist", "F6: 只有 ok 且 done==total 才報全程距離")
result.preview = { state = "disabled", done = 0, total = 0, distance = 0 }
win._tRev = nil
win:prerender()
falsy(win.previewBtn.enable, "F7: 沿道路導航關閉時預覽不可按")
result.preview = { state = "off", done = 0, total = 0, distance = 0 }

--------------------------------------------------------------------------------
-- G. 鍵盤：可見焦點、ESC 逐級退出、不攔遊戲移動鍵
--------------------------------------------------------------------------------
setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 71)
win._tRev = nil
win:prerender()
falsy(win.focus, "G1: 未按 TAB 前不建立焦點環")
falsy(win:isKeyConsumed(Keyboard.KEY_UP), "G1: 沒有焦點環時方向鍵不攔")
falsy(win:isKeyConsumed(Keyboard.KEY_W), "G2: 移動鍵永不攔")
falsy(win:isKeyConsumed(Keyboard.KEY_A), "G2: 移動鍵永不攔")
falsy(win:isKeyConsumed(Keyboard.KEY_S), "G2: 移動鍵永不攔")
falsy(win:isKeyConsumed(Keyboard.KEY_D), "G2: 移動鍵永不攔")
falsy(win:isKeyConsumed(Keyboard.KEY_T), "G2: 聊天鍵不攔")
truthy(key(win, Keyboard.KEY_TAB), "G3: TAB 須被本視窗消耗")
truthy(win.focus, "G3: TAB 後建立焦點環（可見焦點）")
truthy(win:isKeyConsumed(Keyboard.KEY_UP), "G4: 有焦點環時方向鍵才接手")
truthy(win:isKeyConsumed(Keyboard.KEY_RETURN), "G4: 有焦點環時 Enter 才接手")
falsy(win:isKeyConsumed(Keyboard.KEY_W), "G4: 焦點環不改變移動鍵政策")
key(win, Keyboard.KEY_DOWN)
truthy(win.focus, "G5: 方向鍵在焦點環內移動")
key(win, Keyboard.KEY_ESCAPE)
falsy(win.focus, "G6: ESC 先退出焦點環")
truthy(win:isVisible(), "G6: 第一次 ESC 不關窗")
removedBefore = #UI.removed
key(win, Keyboard.KEY_ESCAPE)
eq(#UI.removed, removedBefore + 1, "G7: 沒有焦點環時 ESC 才關窗")

win = openWindow(0, "search")
truthy(win.entry:isFocused(), "G8: 搜尋頁開窗聚焦輸入框")
removedBefore = #UI.removed
win.entry.onOtherKey(win.entry, Keyboard.KEY_ESCAPE)
falsy(win.entry:isFocused(), "G9: 打字中 ESC 先解焦（不再攔遊戲鍵盤）")
eq(#UI.removed, removedBefore, "G9: 解焦不等於關窗")
win.entry:focus()
win.entry.onOtherKey(win.entry, Keyboard.KEY_TAB)
falsy(win.entry:isFocused(), "G10: 打字中 TAB 解焦")
truthy(win.focus, "G10: 並接手到焦點環")

key(win, Keyboard.KEY_RIGHT)
eq(win.page, "itinerary", "G11: 右方向鍵可達行程頁")
key(win, Keyboard.KEY_LEFT)
eq(win.page, "search", "G11: 左方向鍵回搜尋頁")
win:onJoypadDown(Joypad.XButton)
eq(win.page, "itinerary", "G12: 手把 X 換頁")
win:onJoypadDown(Joypad.XButton)
eq(win.page, "search", "G12: 手把 X 可換回")

--------------------------------------------------------------------------------
-- H. 手把：原生 joypad focus 取得與交還
--------------------------------------------------------------------------------
Core.toggleSearchWindow(0)
JoypadState.players[1] = { player = 0 }
win = openWindow(0, "itinerary")
eq(JoypadState.players[1].focus, win, "H1: 有手把時開窗須取得原生 joypad focus")
win:onGainJoypadFocus(JoypadState.players[1])
truthy(win.focus, "H2: 取得手把焦點即建立可見焦點")
win:onJoypadDown(Joypad.YButton)
truthy(win.collapsed, "H3: 手把 Y 收合")
win:onJoypadDown(Joypad.AButton)
falsy(win.collapsed, "H3: 收合時手把 A 展開")
win:onJoypadDown(Joypad.BButton)
falsy(win:isVisible(), "H4: 手把 B 關窗")
eq(JoypadState.players[1].focus, nil, "H4: 關窗須交還玩家，不留死焦點")
win = openWindow(0, "itinerary")
Core.navPromptClear(0)
local dialog = UI.confirm
eq(JoypadState.players[1].focus, dialog, "H5: 確認框持有焦點")
truthy(key(dialog, Keyboard.KEY_ESCAPE), "H5: 取消後同一個ESC仍已消耗")
eq(JoypadState.players[1].focus, win, "H5: 取消返回主窗而非推入死確認框")
truthy(win:isVisible(), "H5: 取消確認不關主窗")
win:onJoypadDown(Joypad.BButton)
eq(JoypadState.players[1].focus, nil, "H6: 再關主窗仍返回玩家")
JoypadState.players[1] = nil

--------------------------------------------------------------------------------
-- I. 版面：視窗絕不大於 viewport；主要動作固定可達；次要動作空間不足時折疊
--------------------------------------------------------------------------------
local function assertLayout(tag)
    for _, page in ipairs({ "search", "itinerary" }) do
        Core.toggleSearchWindow(0, page)
        local w
        for i = #UI.added, 1, -1 do
            if UI.added[i].tabs then w = UI.added[i]; break end
        end
        local trip = page == "itinerary"
        local list = trip and w.tripList or w.list
        local defs = trip and w.tripBtns or w.searchBtns
        local where = tag .. " " .. page .. "："
        truthy(w.width <= screen.w - 20, where .. "視窗寬不得超出 viewport")
        truthy(w.height <= screen.h - 20, where .. "視窗高不得超出 viewport")
        truthy(list.width > 0 and list.height > 0, where .. "清單須有實際大小")
        truthy(list.y + list.height <= defs[1].btn.y,
            where .. "主要動作須在清單之外（不會被捲走）")
        truthy(list.y >= 0 and list.y + list.height <= w.height, where .. "清單須落在視窗內")
        local visible = 0
        for i = 1, #defs do
            local btn = defs[i].btn
            if btn:isVisible() then
                visible = visible + 1
                truthy(btn.x >= 0 and btn.x + btn.width <= w.width,
                    where .. "按鈕不得超出視窗寬（換列失效）")
                truthy(btn.y >= list.y + list.height and btn.y + btn.height <= w.height,
                    where .. "可見按鈕須全部落在清單之下且在視窗內")
            end
            -- 次要動作只在「動作…」選單，主要動作必須留在底部
            truthy(btn:isVisible() or defs[i].group == "more",
                where .. "主要動作不得被折疊")
        end
        if trip then
            -- 模式列是整趟行程的前提：不得被折疊、不得超出視窗、不得壓到清單上
            for i = 1, #w.modeBtns do
                local btn = w.modeBtns[i].btn
                truthy(btn:isVisible(), where .. "接續模式入口不得被折疊")
                truthy(btn.x >= 0 and btn.x + btn.width <= w.width,
                    where .. "模式鈕不得超出視窗寬")
                truthy(btn.y + btn.height <= list.y, where .. "模式鈕須落在清單之上")
            end
        end
        truthy(visible >= 3, where .. "至少要看得到主要動作與更多動作鈕")
    end
end
setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 81)
Core.toggleSearchWindow(0)
assertLayout("I1 預設 1920x1080")
Core.toggleSearchWindow(0)
screen = { w = 640, h = 560 }
assertLayout("I2 窄 viewport 640x560")
Core.toggleSearchWindow(0)
fontHeights = { [UIFont.Small] = 26, [UIFont.Medium] = 33 }
textManager.getFontHeight = function(_, font) return fontHeights[font] or 26 end
assertLayout("I3 大字級 26/33")
Core.toggleSearchWindow(0)
screen = { w = 320, h = 540 }
assertLayout("I4 320x540 大字級（Main 指定最小可用組合）")
Core.toggleSearchWindow(0)
screen = { w = 320, h = 1080 }
assertLayout("I4b 320x1080 大字級（窄但高）")
Core.toggleSearchWindow(0)
screen = { w = 320, h = 540 }
Core.toggleSearchWindow(0, "itinerary") -- 回到 I4 結束時的狀態（視窗開著）
-- 次要動作一律在「動作…」原生選單，主清單仍保留至少一列且可保持選取。
Core.toggleSearchWindow(0)
win = openWindow(0, "itinerary")
falsy(win.upBtn:isVisible(), "I5: 次要動作不佔底部按鈕列")
pressButton(win.tripMoreBtn)
truthy(win.nativeMenu and win.nativeMenu:isVisible(), "I5: 動作選單可開啟")
truthy(win.tripList.height >= win.tripList.itemheight, "I6: 操作時仍看得到選取的站")
truthy(key(win, Keyboard.KEY_ESCAPE), "I7: ESC只消耗於關動作選單")
truthy(win:isVisible(), "I7: 關選單不關行程")
falsy(win.nativeMenu:isVisible(), "I7: 動作選單已關閉")
Core.toggleSearchWindow(0)
screen = { w = 1920, h = 1080 }
fontHeights = { [UIFont.Small] = 14, [UIFont.Medium] = 18 }
textManager.getFontHeight = function(_, font) return fontHeights[font] or 14 end

-- I8. 右鍵：選中滑鼠下的站並在滑鼠處開出該頁全部動作；空白處不開
setTrip(0, "draft", { stop(1, 10, 10), stop(2, 20, 20) }, nil, nil, 290)
win = openWindow(0, "itinerary")
win:prerender(); win:prerender()
local _, row2 = tripRow(win, 2)
local rowY = 2
for i = 1, row2 - 1 do rowY = rowY + (win.tripList.items[i].height or win.tripList.itemheight) end
win.tripList:onRightMouseUp(30, rowY)
eq(win.tripList.selected, row2, "I8: 右鍵先選中滑鼠下的站")
local rmenu = win.nativeMenu
truthy(rmenu and rmenu:isVisible(), "I8: 右鍵開出動作選單")
eq(rmenu.x, win:getAbsoluteX() + win.tripList.x + 30, "I8: 選單開在滑鼠處")
local texts = {}
for _, option in ipairs(rmenu.options) do texts[option.text] = option end
truthy(texts[win.startBtn.title] and texts[win.removeBtn.title], "I8: 右鍵含主要與次要動作")
falsy(texts[win.tripMoreBtn.title], "I8: 選單不列「動作…」自己")
falsy(texts[win.upBtn.title].notAvailable, "I8: 第二站可上移")
rmenu:closeAll()
win.tripList:onRightMouseUp(30, 9999)
falsy(win.nativeMenu:isVisible(), "I8: 空白處右鍵不開選單")
Core.toggleSearchWindow(0)

--------------------------------------------------------------------------------
-- J. 名稱按實測字寬換行：完整可讀、不截字、不溢出
--------------------------------------------------------------------------------
local longName = string.rep("ABCDEFGH", 16) -- 128 單位、無空白
setTrip(0, "draft", {
    stop(1, 100, 100, "pending", longName),
    stop(2, 2, 2, "pending", "Ok"),
    stop(3, 3, 3, "pending",
        "A name with several separate words inside it that has to break across lines"),
}, nil, nil, 91)
win._tRev = nil
win:prerender()
local row1 = tripRow(win, 1)
local it1 = row1.item
truthy(#it1.lines > 1, "J1: 過長名稱須真正換成多行")
falsy(it1.lines.truncated, "J1: 站名不得截斷")
eq(table.concat(it1.lines, ""), longName, "J2: 各行接回來須與原名完全相同（零字遺失）")
local room = win.tripList.width - it1.nameX - 14
for i = 1, #it1.lines do
    truthy(textManager:MeasureStringX(UIFont.Small, it1.lines[i]) <= room,
        "J3: 第 " .. i .. " 行實測寬度不得超出可用空間")
end
truthy(row1.height > win.tripList.itemheight, "J4: 換行列須加高，不得疊字")
local it2 = tripRow(win, 2).item
eq(#it2.lines, 1, "J6: 短名稱維持單行")
local it3 = tripRow(win, 3).item
truthy(#it3.lines > 1, "J7: 含空白的長名稱也要換行")
for i = 1, #it3.lines do
    falsy(it3.lines[i]:sub(1, 1) == " ", "J7: 換行後不得以空白開頭")
    truthy(textManager:MeasureStringX(UIFont.Small, it3.lines[i]) <= room,
        "J7: 空白斷行後每行仍須合寬")
end
-- 缺名稱時顯示座標（契約：缺省顯示座標，不解讀標記）
setTrip(0, "draft", { stop(1, 1234, 5678) }, nil, nil, 92)
win._tRev = nil
win:prerender()
eq(tripRow(win, 1).item.label, "1234, 5678", "J8: 沒有名稱的站顯示座標")
-- 說明列同樣換行、不溢出
trips[0], tripErrors[0] = nil, nil
win._tRev = nil
win:prerender()
local info = win.tripList.items[1].item
truthy(info.lines and #info.lines >= 1, "J9: 說明列也走換行")
for i = 1, #info.lines do
    truthy(textManager:MeasureStringX(UIFont.Small, info.lines[i])
        <= win.tripList.width - 12 - 14, "J9: 說明列不得溢出清單寬")
end
-- 狀態列與預覽列共用版面預留的行數（狀態列較長，可以多佔一行，但兩者總和不得
-- 超出預留區──那就會壓到清單上）
setTrip(0, "paused", { stop(1, 1, 1) }, 1, "noroad", 93)
win._tRev = nil
win:prerender()
truthy(#win.headLines >= 1 and #win.subLines >= 1, "J10: 兩列都要畫得出來")
truthy(#win.headLines + #win.subLines <= 4, "J10: 總行數不得超出預留區")
for _, lines in ipairs({ win.headLines, win.subLines }) do
    for i = 1, #lines do
        truthy(textManager:MeasureStringX(UIFont.Small, lines[i]) <= win.width - 20,
            "J11: 狀態／預覽列不得溢出視窗寬")
    end
end
-- 用「開始導航」觸發一則長錯誤訊息（paused 時它才是可按的那顆）
result.start = { token = nil, reason = "notstopped" }
clearCalls()
pressButton(win.startBtn)
truthy(win.msgLines and #win.msgLines >= 1, "J12: 須顯示錯誤訊息")
truthy(#win.msgLines <= 2, "J12: 訊息列不得超出預留行數")
for i = 1, #win.msgLines do
    truthy(textManager:MeasureStringX(UIFont.Small, win.msgLines[i]) <= win.width - 20,
        "J12: 訊息列不得溢出視窗寬")
end
result.start = { token = "tok", reason = "ok" }

--------------------------------------------------------------------------------
-- K. 刷新紀律：狀態未變不重建；重建以 stopId 保留選取
--------------------------------------------------------------------------------
setTrip(0, "draft", { stop(1, 10, 10), stop(2, 20, 20), stop(3, 30, 30) }, nil, nil, 101)
win._tRev = nil
win:prerender()
local firstRow = tripRow(win, 1)
win:prerender()
win:prerender()
eq(tripRow(win, 1), firstRow, "K1: 行程未變、玩家未移動時不得重建清單")
selectStop(win, 3)
players[0].x, players[0].y = 400, 400
win:prerender()
truthy(tripRow(win, 1) ~= firstRow, "K2: 玩家移動一段距離後須重算距離")
eq(win.tripList.items[win.tripList.selected].item.stopId, 3,
    "K3: 距離刷新不得把選取彈回第一站")
-- 排序改變時依 stopId 跟著走，而不是固定索引
setTrip(0, "draft", { stop(3, 30, 30), stop(1, 10, 10), stop(2, 20, 20) }, nil, nil, 102)
win:prerender()
eq(win.tripList.items[win.tripList.selected].item.stopId, 3, "K4: 站點重排後選取跟著 stopId")
-- 選取的站被移除 → 不得指到別的站的座標
setTrip(0, "draft", { stop(1, 10, 10), stop(2, 20, 20) }, nil, nil, 103)
win:prerender()
eq(win.tripList.selected, 1, "K5: 原選取站已不存在時退回第一列")
clearCalls()
Core.toggleSearchWindow(0, "search")
win:prerender()
truthy(countCalls("kick") > 0, "K6: 搜尋頁每次刷新泵一次引擎（冷啟動唯一入口）")

--------------------------------------------------------------------------------
-- L. 每幀繪製路徑：兩份 doDrawItem 都要能跑完，且畫出來的文字不得互相疊字
--------------------------------------------------------------------------------
-- 實際文字矩形：只認 doDrawItem 真正下的 drawText（欄位有沒有填好不算數），
-- 寬高一律取當下字型 stub，窄版大字同樣成立
local capture = nil
function Element:drawText(text, x, y)
    if capture then capture[#capture + 1] = { text = tostring(text), x = x, y = y } end
end
local function rowRects(list, row, y0)
    capture = {}
    list.doDrawItem(list, y0, row, false)
    local boxes = capture
    capture = nil
    for i = 1, #boxes do
        local b = boxes[i]
        b.x2 = b.x + textManager:MeasureStringX(UIFont.Small, b.text)
        b.y2 = b.y + textManager:getFontHeight(UIFont.Small)
    end
    return boxes
end
-- 同一列的任兩段文字不得相交，且都要落在列高與清單可用寬內。逐列單獨量（每列
-- 都畫在 y=0），繞開「捲出清單的列不畫」早退，短清單也量得到每一列
local function assertNoOverlap(list, tag)
    for i = 1, #list.items do
        local row = list.items[i]
        local hgt = row.height or list.itemheight
        local boxes = rowRects(list, row, 0)
        local painted = {}
        for n = 1, #boxes do painted[n] = boxes[n].text end
        local it = row.item
        local expected = it.kind == "trip" and (it.tag .. it.label .. it.badge .. it.right) or it.label
        eq(table.concat(painted, "", 1, #painted):gsub("%s", ""), expected:gsub("%s", ""),
            tag .. "-" .. i .. "：編號、完整站名、狀態與座標文字不得消失")
        for a = 1, #boxes do
            local p = boxes[a]
            truthy(p.x >= 0 and p.x2 <= list.width,
                tag .. "-" .. i .. "：「" .. p.text .. "」超出清單可用寬")
            truthy(p.y >= 0 and p.y2 <= hgt,
                tag .. "-" .. i .. "：「" .. p.text .. "」超出列高")
            for b = a + 1, #boxes do
                local q = boxes[b]
                falsy(p.x < q.x2 and q.x < p.x2 and p.y < q.y2 and q.y < p.y2,
                    tag .. "-" .. i .. "：「" .. p.text .. "」與「" .. q.text .. "」疊字")
            end
        end
    end
end

local function drawAll(list, tag)
    local y = 0
    for i = 1, #list.items do
        local row = list.items[i]
        local nextY = list.doDrawItem(list, y, row, false)
        eq(nextY, y + (row.height or list.itemheight), tag .. " 第 " .. i .. " 列高度推進")
        y = nextY
    end
    return y
end
setTrip(0, "waiting", {
    stop(1, 100, 100, "arrived", "Home"),
    stop(2, 200, 200, "skipped", string.rep("Long Name ", 12)),
    stop(3, 300, 300, "pending"),
}, 1, nil, 111)
win = openWindow(0, "itinerary")
win._tRev = nil
win:prerender()
truthy(drawAll(win.tripList, "L1") > 0, "L1: 行程列繪製須跑完")
trips[0], tripErrors[0] = nil, "invalid"
win._tRev = nil
win:prerender()
truthy(drawAll(win.tripList, "L2") > 0, "L2: 損壞/空行程的說明列繪製須跑完")
tripErrors[0] = nil
Core.toggleSearchWindow(0, "search")
win.entry.text = "12895,3499"
win._lastText = nil
win:prerender()
eq(#win.list.items, 1, "L3: 座標查詢一筆結果")
eq(win.list.items[1].item.kind, "coord", "L3: 為座標項")
truthy(drawAll(win.list, "L3") > 0, "L3: 搜尋結果列繪製須跑完")
win.entry.text = "nothing here"
win._lastText = nil
win:prerender()
truthy(#win.list.items > 0, "L4: 查無命中須有說明列")
truthy(drawAll(win.list, "L4") > 0, "L4: 說明列繪製須跑完")

-- 實機截圖情境：三站、站名缺省顯示座標、首站進行中其餘待前往、常規寬度。
-- 這一版面狀態與座標和站名同列——狀態曾被畫在站名的起點上，直接疊成一團。
do
    local oldText = getText
    local ch = loadCH()
    getText = function(k, a, b, c) return ch[k] or oldText(k, a, b, c) end
    setTrip(0, "navigating", { stop(1, 10819, 9807), stop(2, 10751, 9857),
        stop(3, 10893, 9971) }, 1, nil, 112)
    win = openWindow(0, "itinerary")
    win._tRev = nil
    win:prerender()
    eq(tripRowCount(win), 3, "L5: 三站都在清單裡，全文說明不影響站數")
    local firstStop = tripRow(win, 1)
    eq(firstStop.item.label, "10819, 9807", "L5: 缺省站名顯示座標")
    eq(firstStop.height, win.tripList.itemheight, "L5: 放得下的一列不額外加高")
    assertNoOverlap(win.tripList, "L5")
    -- 長站名與各狀態：名稱佔滿整列時右欄改走獨立一列，同樣不得疊字
    setTrip(0, "waiting", {
        stop(1, 100, 100, "arrived", "Home"),
        stop(2, 200, 200, "skipped", string.rep("Long Name ", 12)),
        stop(3, 300, 300, "pending", string.rep("ABCDEFGH", 16)),
    }, 1, nil, 113)
    win._tRev = nil
    win:prerender()
    assertNoOverlap(win.tripList, "L6")
    getText = oldText
end

--------------------------------------------------------------------------------
-- M. 鍵盤開窗入口（可重綁、不與既有鍵衝突）
--------------------------------------------------------------------------------
truthy(hooks.boot, "M1: 須在 OnGameBoot 註冊按鍵綁定")
truthy(hooks.key, "M1: 須註冊 OnKeyPressed 處理")
hooks.boot()
local bind
for i = 1, #keyBinding do
    if keyBinding[i].value == "MinidoracatMiniMap_Search" then bind = keyBinding[i] end
end
truthy(bind, "M2: keyBinding 須有可重綁的 MinidoracatMiniMap_Search")
truthy(bind.key ~= Keyboard.KEY_SLASH and bind.key ~= Keyboard.KEY_APOSTROPHE,
    "M2: 預設鍵不得與本 MOD 既有兩鍵衝突")
boundKeys.MinidoracatMiniMap_Search = bind.key
Core.toggleSearchWindow(0)
falsy(win:isVisible(), "M3: 先關窗")
hooks.key(bind.key)
for i = #UI.added, 1, -1 do
    if UI.added[i].tabs then win = UI.added[i]; break end
end
truthy(win:isVisible(), "M3: 快捷鍵可開窗（不必用滑鼠）")
hooks.key(bind.key)
falsy(win:isVisible(), "M4: 快捷鍵可再關窗")
local addedBefore = #UI.added
hooks.key(bind.key + 100)
eq(#UI.added, addedBefore, "M5: 其他鍵不得誤觸")
hooks.key(0)
eq(#UI.added, addedBefore, "M6: 未綁定（key 0）不得誤觸")

--------------------------------------------------------------------------------
-- N. 分割畫面：搜尋落點 ping 只畫在擁有者的表面
--------------------------------------------------------------------------------
win = openWindow(0, "search")
win.entry.text = "12895,3499"
win._lastText = nil
win:prerender()
win.list.selected = 1
local pingsBefore = #ISWorldMap.pings
win.list.dblFn(win.list.dblTarget)
eq(#ISWorldMap.pings, pingsBefore + 1, "N1: 雙擊結果須開大地圖")
eq(Core.searchPing.pn, 0, "N1: ping 帶發起者 pn")
local drawn = 0
local mapAPI = { worldToUIX = function() return 50 end, worldToUIY = function() return 50 end }
local surface = newElement(0, 0, 200, 200)
surface.drawLine = function() drawn = drawn + 1 end
surface.drawRect = function() drawn = drawn + 1 end
surface.playerNum = 1
Core.drawSearchPing(surface, mapAPI)
eq(drawn, 0, "N2: 非擁有者的表面不得畫 ping（分割畫面不串）")
surface.playerNum = 0
Core.drawSearchPing(surface, mapAPI)
truthy(drawn > 0, "N3: 擁有者的表面須畫 ping")
clock = clock + 20000
Core.drawSearchPing(surface, mapAPI)
falsy(Core.searchPing, "N4: 逾時後 ping 自動清除")

-- 長確認文字須能捲完，按鈕不能重疊；事件消耗依真 Java 派送先後。
do
    setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 150)
    local oldMeasure = textManager.MeasureStringX
    screen = { w = 320, h = 540 }
    fontHeights = { [UIFont.Small] = 38, [UIFont.Medium] = 48 }
    textManager.MeasureStringX = function(_, _, text) return #text * 26 end
    Core.navPromptTarget(0, 100, 200, string.rep("A", 128), "replace")
    local panel = UI.confirm
    truthy(panel and panel.messageList, "O1: 確認訊息有獨立捲動區")
    local list = panel.messageList
    truthy(list.height > 0 and #list.items * list.itemheight > list.height,
        "O1: 長文字保留於可捲動區，不畫出按鈕區")
    contains(linesText(panel.lines), string.rep("A", 128), "O1: 完整地名仍可讀")
    truthy(list.y + list.height <= panel.cancelBtn.y, "O2: 訊息不覆蓋取消")
    truthy(panel.cancelBtn.y + panel.cancelBtn.height <= panel.actionBtn.y,
        "O2: 窄版兩動作分列不重疊")
    for _ = 1, #list.items do key(panel, Keyboard.KEY_DOWN) end
    eq(list.ensuredIndex, #list.items, "O3: 鍵盤可捲到最後一行")
    truthy(key(panel, Keyboard.KEY_ESCAPE), "O4: 關閉後仍消耗該次取消鍵")
    truthy(win:isVisible(), "O4: 只關確認，不連帶關主窗")
    textManager.MeasureStringX = oldMeasure
    screen = { w = 1920, h = 1080 }
    fontHeights = { [UIFont.Small] = 14, [UIFont.Medium] = 18 }
end

do
    local translations = loadCH()
    local oldText, oldMeasure = getText, textManager.MeasureStringX
    getText = function(keyName) return translations[keyName] or oldText(keyName) end
    screen = { w = 320, h = 540 }
    setTrip(0, "draft", { stop(1, 100, 100), stop(2, 200, 200) }, nil, nil, 151)
    for _, metrics in ipairs({ { 26, 32, 18 }, { 33, 40, 22 }, { 38, 45, 26 } }) do
        fontHeights = { [UIFont.Small] = metrics[1], [UIFont.Medium] = metrics[2] }
        textManager.MeasureStringX = function(_, _, text)
            local _, count = text:gsub("[^\128-\191]", "")
            return count * metrics[3]
        end
        for _, defs in ipairs({ win.tabs, win.modeBtns, win.searchBtns, win.tripBtns }) do
            for _, d in ipairs(defs) do
                d.text = getText(d.key)
                if d.altKey and utf8.len(getText(d.altKey)) > utf8.len(d.text) then
                    d.text = getText(d.altKey)
                end
                d.btn:setTitle(getText(d.key))
            end
        end
        pressButton(win.collapseBtn)
        pressButton(win.collapseBtn)
        truthy(win.width <= screen.w - 20 and win.height <= screen.h - 20,
            "P0: 重排真的使用窄 viewport 與新字級")
        for _, page in ipairs({ "search", "itinerary" }) do
            win = openWindow(0, page)
            local list = page == "search" and win.list or win.tripList
            truthy(list.height >= list.itemheight, "P1: 窄版大字保留可閱讀清單")
            truthy(win.titleX + win.titleW <= win.collapseBtn.x - 8,
                "P2: 標題不覆蓋收合按鈕")
            local defs = page == "search" and win.searchBtns or win.tripBtns
            for _, d in ipairs(defs) do
                if d.btn:isVisible() then
                    truthy(textManager:MeasureStringX(UIFont.Small, d.btn.title) <= d.btn.width - 16,
                        "P3: 真文案不超出主要動作按鈕")
                end
            end
        end
        setTrip(0, "waiting", {
            { id = 1, x = 100, y = 100, label = string.rep("Long Stop Name ", 5), status = "arrived" },
            { id = 2, x = 200, y = 200, label = string.rep("LongName", 7), status = "pending" },
        }, 1, nil, 152)
        win:prerender()
        truthy(textManager:MeasureStringX(UIFont.Small, win.startBtn.title) <= win.startBtn.width - 16,
            "P4: 到站改成下一站動詞，不必重開窗也不裁掉文字")
        -- 窄版大字：座標／狀態連一列都放不下，也不得互疊或溢出（曾把座標右對齊
        -- 到負座標，整段壓在狀態徽章與編號上）
        truthy(win.page == "itinerary", "P5: 本段在行程頁量測")
        assertNoOverlap(win.tripList, "P5")
        setTrip(0, "draft", { stop(1, 100, 100), stop(2, 200, 200) }, nil, nil, 153)
        win:prerender()
    end
    getText, textManager.MeasureStringX = oldText, oldMeasure
    screen = { w = 1920, h = 1080 }
    fontHeights = { [UIFont.Small] = 14, [UIFont.Medium] = 18 }
end

--------------------------------------------------------------------------------
-- Q. 接續模式：兩個入口各送明確布林；空／壞行程與舊版 API 不得假操作
--------------------------------------------------------------------------------
Core.toggleSearchWindow(0) -- 關掉 P 段留下的窄版視窗，下面要重排回預設 viewport
do
    setTrip(0, "draft", { stop(1, 100, 100), stop(2, 200, 200) }, nil, nil, 201)
    win = openWindow(0, "itinerary")
    win._tRev = nil
    win:prerender()
    truthy(win.autoBtn:isVisible() and win.stopModeBtn:isVisible(),
        "Q1: 行程頁頂部固定看得到自動接續／逐點停等兩個入口")
    truthy(win.autoBtn.y + win.autoBtn.height <= win.tripList.y,
        "Q1: 模式列在清單之外，不會被捲走")
    truthy(win.autoBtn.enable and win.stopModeBtn.enable, "Q1: 有行程時兩個入口都可用")
    clearCalls()
    pressButton(win.stopModeBtn)
    local switched = lastCall("continuation")
    truthy(switched, "Q2: 逐點停等走 API.setNavContinuation")
    eq(switched.enabled, false, "Q2: 送明確 false，不是 toggle（顯示晚一幀不會反向）")
    eq(switched.rev, 201, "Q2: 帶目前 revision")
    eq(countCalls("start") + countCalls("pause") + countCalls("guide") + countCalls("edit"), 0,
        "Q2: 切模式不得發車、煞車或改行程內容")
    setTrip(0, "draft", { stop(1, 100, 100), stop(2, 200, 200) }, nil, nil, 202, { auto = false })
    win._tRev = nil
    win:prerender()
    contains(tripText(win), "TripModeNow_stop", "Q3: 狀態或全文列說出逐點停等")
    clearCalls()
    pressButton(win.autoBtn)
    eq(lastCall("continuation").enabled, true, "Q4: 自動接續送明確 true")
    eq(lastCall("continuation").rev, 202, "Q4: 帶目前 revision")
    setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 203)
    win._tRev = nil
    win:prerender()
    contains(tripText(win), "TripModeNow_auto", "Q5: 狀態或全文列說出自動接續")
end

-- 空行程／壞資料／舊版 API：兩個入口停用，且清單裡要說明原因（不做假操作）
do
    trips[0], tripErrors[0] = nil, nil
    win._tRev = nil
    win:prerender()
    falsy(win.autoBtn.enable, "Q6: 沒有行程時不得假裝可以選模式")
    falsy(win.stopModeBtn.enable, "Q6: 兩個入口一起停用")
    contains(listText(win.tripList), "TripModeNeedTrip", "Q6: 清單要說明為什麼不能選")
    setTrip(0, "draft", { stop(1, 1, 1) }, nil, nil, 204)
    tripErrors[0] = "invalid"
    win._tRev = nil
    win:prerender()
    falsy(win.autoBtn.enable, "Q7: 資料損壞時不得改模式（那份資料還在等重建）")
    tripErrors[0] = nil
    MinidoracatMiniMapAPI.navApiVersion = 6
    win._tRev = nil
    win:prerender()
    falsy(win.autoBtn.enable, "Q8: navApiVersion<7＝整組不支援")
    contains(listText(win.tripList), "TripModeUnsupported", "Q8: 要說明這個版本不支援")
    clearCalls()
    win.autoBtn.onclick(win.autoBtn.target, win.autoBtn)
    eq(countCalls("continuation"), 0, "Q8: 停用時按下去也不得呼叫 setter")
    MinidoracatMiniMapAPI.navApiVersion = 7
    local keepSetter = MinidoracatMiniMapAPI.setNavContinuation
    MinidoracatMiniMapAPI.setNavContinuation = nil
    win._tRev = nil
    win:prerender()
    falsy(win.autoBtn.enable, "Q9: 版本夠但 setter 不在（舊 Core 混搭）同樣視為不支援")
    MinidoracatMiniMapAPI.setNavContinuation = keepSetter
end

--------------------------------------------------------------------------------
-- R. 插入位置：原生選單列待前往站＋加尾，點擊時驗 owner／revision／錨點
--------------------------------------------------------------------------------
do
    setTrip(0, "navigating", { stop(1, 10, 10, "arrived", "A"), stop(2, 20, 20, "pending", "B"),
        stop(3, 30, 30, "pending", "C") }, 2, nil, 211)
    win = openWindow(0, "search")
    win.entry.text = "12895,3499"
    win._lastText = nil
    win:prerender() -- 建清單
    win:prerender() -- 依新清單重算動作可用性
    truthy(win.insertBtn.enable, "R1: 選到結果時插入可用")
    pressButton(win.insertBtn)
    local menu = win.nativeMenu
    truthy(menu and menu:isVisible(), "R1: 插入走原生選單（鍵盤與手把同一份路由）")
    eq(#menu.options, 3, "R1: 兩個待前往錨點＋加到最後（已抵達的站不是錨點）")
    contains(menu.options[1].text, "TripInsertBefore", "R1: 選項說出插在哪一站之前")
    clearCalls()
    menu:onJoypadDown(Joypad.AButton) -- 焦點在第一項
    local applied = lastCall("edit")
    eq(applied.op, "insert", "R2: 第一項走 insert")
    eq(applied.d, 2, "R2: 錨點＝第一個待前往站的 stopId")
    eq(applied.rev, 211, "R2: 帶建立選單時捕捉的 revision")
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    menu.mouseOver = #menu.options
    clearCalls()
    menu:onJoypadDown(Joypad.AButton)
    eq(lastCall("edit").op, "append", "R3: 最後一項是加到行程最後")
    falsy(lastCall("edit").d, "R3: 加尾不帶錨點")
    -- 選單開著期間行程被改動（自駕推進／別的入口）→ 延遲點擊整筆拒絕
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    setTrip(0, "navigating", { stop(2, 20, 20, "arrived", "B"), stop(3, 30, 30, "pending", "C") },
        3, nil, 212)
    clearCalls()
    menu:onJoypadDown(Joypad.AButton)
    eq(countCalls("edit"), 0, "R4: revision 已變的舊選單不得插入")
    linesContain(win.msgLines, "TripError_stale", "R4: 須明確回報 stale，不得靜默")
    -- 同一 revision 下錨點已被走完（極限情況）→ 仍要擋，不落到別人的位置上
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    trips[0].stops[2].status = "arrived"
    clearCalls()
    menu:onJoypadDown(Joypad.AButton)
    eq(countCalls("edit"), 0, "R5: 錨點已不是待前往站時不得插入")
    -- 沒有任何待前往站可當錨點：插入等於加尾，不開只有一個選項的選單
    if win.nativeMenu then win.nativeMenu:closeAll() end
    setTrip(0, "completed", { stop(1, 10, 10, "arrived") }, nil, nil, 213)
    clearCalls()
    pressButton(win.insertBtn)
    eq(lastCall("edit").op, "append", "R6: 零錨點時直接加到行程最後")
    falsy(win.nativeMenu and win.nativeMenu:isVisible(), "R6: 不開空選單")
end

--------------------------------------------------------------------------------
-- S. 逐站停等標記與清單／狀態文字語意
--------------------------------------------------------------------------------
do
    setTrip(0, "navigating", { stop(1, 10, 10, "pending", "A"), stop(2, 20, 20, "pending", "B"),
        stop(3, 30, 30, "pending", "C") }, 1, nil, 221)
    win = openWindow(0, "itinerary")
    win._tRev = nil
    win:prerender()
    contains(tripRow(win, 1).item.badge, "TripStatus_going",
        "S1: 目前目標的狀態文字是「前往中」")
    contains(tripRow(win, 2).item.badge, "TripStatus_pending", "S1: 其餘仍是待前往")
    contains(tripRow(win, 3).item.badge, "TripLastMark",
        "S2: 最後一站標最後目標（純文字標記，不新建終點站）")
    falsy(tripRow(win, 2).item.badge:find("TripLastMark", 1, true),
        "S2: 中間站不得標成最後目標")
    selectStop(win, 2)
    truthy(win.pauseStopBtn.enable, "S3: 選到待前往站時可標記停等")
    contains(win.pauseStopBtn.title, "TripMarkPause", "S3: 未標記時動詞是標記")
    clearCalls()
    pressButton(win.pauseStopBtn)
    local marked = lastCall("edit")
    eq(marked.op, "pause", "S3: 走 pause op")
    eq(marked.a, 2, "S3: 對象是選取的那站")
    eq(marked.b, true, "S3: 送明確布林")
    eq(countCalls("continuation"), 0, "S3: 逐站停等不是整趟模式，不得改模式設定")
    setTrip(0, "navigating", { stop(1, 10, 10, "pending", "A"),
        stop(2, 20, 20, "pending", "B", true), stop(3, 30, 30, "pending", "C") }, 1, nil, 222)
    win._tRev = nil
    win:prerender()
    selectStop(win, 2)
    contains(tripRow(win, 2).item.badge, "TripPauseMark",
        "S4: 停等站在清單上看得到明確標記文字")
    contains(win.pauseStopBtn.title, "TripUnmarkPause", "S4: 已標記時動詞是取消")
    clearCalls()
    pressButton(win.pauseStopBtn)
    eq(lastCall("edit").b, false, "S4: 取消標記送明確 false")
    -- 已完成的站不可改標記
    setTrip(0, "waiting", { stop(1, 10, 10, "arrived", "A"), stop(2, 20, 20, "skipped", "B"),
        stop(3, 30, 30, "pending", "C") }, 1, nil, 223)
    win._tRev = nil
    win:prerender()
    selectStop(win, 1)
    falsy(win.pauseStopBtn.enable, "S5: 已抵達的站不可改停等標記")
    clearCalls()
    win.pauseStopBtn.onclick(win.pauseStopBtn.target, win.pauseStopBtn)
    eq(countCalls("edit"), 0, "S5: 而且按下去也不得有任何編輯")
    -- waiting：已停靠＋下一目標都要說出來；剛完成的那站不是下一步
    contains(tripText(win), "TripHeadStopped", "S6: 顯示已停靠與下一目標")
    contains(tripText(win), "TripHeadCounts", "S6: 已抵達／已略過分開計數")
    falsy(tripRow(win, 1).item.badge:find("TripStatus_going", 1, true),
        "S6: waiting 的舊站不得顯示成前往中")
    -- waiting 由略過產生：不得說成已停靠／已抵達
    setTrip(0, "waiting", { stop(1, 10, 10, "skipped", "A"), stop(2, 20, 20, "pending", "B") },
        1, nil, 224)
    win._tRev = nil
    win:prerender()
    contains(tripText(win), "TripHeadSkipped", "S7: 略過造成的等待要說略過")
    falsy(tripText(win):find("TripHeadStopped", 1, true), "S7: 不得把略過說成已停靠")
    -- 被動接續被 gate 擋下：waiting 帶 reason，狀態要說出原因而不是假裝刻意停靠
    setTrip(0, "waiting", { stop(1, 10, 10, "arrived", "A"), stop(2, 20, 20, "pending", "B") },
        1, "unavailable", 225)
    win._tRev = nil
    win:prerender()
    contains(tripText(win), "TripReason_unavailable", "S8: waiting 帶原因時要顯示原因")
    truthy(win.headColor ~= normalPaused, "S8: 設備不可用不是玩家自己停的，配色須有區別")
    -- 自駕已認領目前站：重排／刪除不得假亮，停等標記仍可改。claimed 只存在於
    -- API.getNavItinerary 的複本上（真 Core 的私有 raw trip 沒有這個欄位），
    -- 讀錯來源時鎖定完全失效、玩家只會拿到事後錯誤（review UI-2）
    setTrip(0, "navigating", { stop(1, 10, 10, "pending", "A"), stop(2, 20, 20, "pending", "B"),
        stop(3, 30, 30, "pending", "C") }, 1, nil, 226, { claimed = true })
    falsy(Core.navItineraryState(0).claimed,
        "S9: 私有 raw 快照不含 claimed（fixture 與真 Core 同形狀）")
    win._tRev = nil
    win:prerender()
    selectStop(win, 1)
    falsy(win.removeBtn.enable, "S9: 認領中的目前站不得假亮移除")
    falsy(win.upBtn.enable, "S9: 也不得假亮重排")
    falsy(win.downBtn.enable, "S9: 下移同樣停用")
    truthy(win.pauseStopBtn.enable, "S9: 停等只決定到站後要不要等，仍可改")
    clearCalls()
    pressButton(win.pauseStopBtn)
    eq(lastCall("edit").op, "pause", "S9: 認領中仍送得出停等標記")
    -- 認領只鎖目前站：後續站的合法編輯照舊（不冒稱整份行程都鎖住）
    selectStop(win, 2)
    falsy(win.upBtn.enable, "S10: 後續站不能上移跨過認領中的目前站")
    truthy(win.downBtn.enable, "S10: 不影響目前站的後移仍可用")
    selectStop(win, 3)
    truthy(win.removeBtn.enable, "S10: 認領中後續站仍可移除")
    truthy(win.upBtn.enable, "S10: 後續站仍可重排")
    clearCalls()
    pressButton(win.removeBtn)
    eq(lastCall("edit").a, 3, "S10: 編輯對象是選取的後續站")
    eq(lastCall("edit").rev, 226, "S10: 帶目前 revision（Core 才能保留 active token／claim）")
    -- 認領解除（release／report 都會推進 revision）→ 目前站恢復可編輯，
    -- 依 revision 快取的布林不得把鎖定卡住
    setTrip(0, "navigating", { stop(1, 10, 10, "pending", "A"), stop(2, 20, 20, "pending", "B") },
        1, nil, 227)
    win._tRev = nil
    win:prerender()
    selectStop(win, 1)
    truthy(win.removeBtn.enable, "S11: 認領解除後目前站恢復可編輯")
    falsy(win.upBtn.enable, "S11: 第一站沒有更前的位置")
    truthy(win.downBtn.enable, "S11: 認領解除後恢復合法的下移")
    -- getNavItinerary 會複製整份行程：同一 revision 內的距離重算（每 8 格移動）
    -- 與每幀刷新都不得再抄一次
    local px, py = players[0].x, players[0].y
    local movedFrom = tripRow(win, 1)
    clearCalls()
    for i = 1, 6 do
        players[0].x, players[0].y = px + i * 40, py + i * 40
        win:prerender()
    end
    truthy(tripRow(win, 1) ~= movedFrom,
        "S12: 距離刷新確實重建過清單（否則下一條等於沒測到）")
    eq(countCalls("snapshot"), 0, "S12: 同一 revision 內不得重複複製整份行程")
    players[0].x, players[0].y = px, py
    win._tRev = nil
    win:prerender()
end

--------------------------------------------------------------------------------
-- T. 搜尋頁動作可用性：選不到地點就不得有亮著卻沒反應的按鈕
--------------------------------------------------------------------------------
do
    local fields = { "gotoBtn", "addBtn", "insertBtn", "priorityBtn", "replaceBtn" }
    setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 231)
    win = openWindow(0, "search")
    win.entry.text = ""
    win._lastText = nil
    win:prerender()
    win:prerender()
    truthy(#win.list.items >= 1, "T1: 還沒輸入時要有說明列，不是一片空白")
    linesContain(win.list.items[1].item.lines, "SearchEmptyHint",
        "T1: 說明為什麼動作還不能用")
    for i = 1, #fields do
        falsy(win[fields[i]].enable, "T1: " .. fields[i] .. " 在沒有選到地點時須停用")
    end
    clearCalls()
    UI.confirm = nil
    local pingsT = #ISWorldMap.pings
    for i = 1, #fields do
        local btn = win[fields[i]]
        btn.onclick(btn.target, btn)
    end
    eq(countCalls("edit") + countCalls("set"), 0, "T2: 停用的動作按下去不得改行程")
    eq(#ISWorldMap.pings, pingsT, "T2: 也不得開大地圖")
    falsy(UI.confirm, "T2: 更不得彈出取代確認")
    win.entry.text = "nothing here"
    win._lastText = nil
    win:prerender()
    win:prerender()
    eq(win.list.items[1].item.kind, "info", "T3: 查無命中只有說明列")
    falsy(win.addBtn.enable, "T3: 說明列不能加入行程")
    win.entry.text = "12895,3499"
    win._lastText = nil
    win:prerender()
    win:prerender()
    truthy(win.addBtn.enable and win.insertBtn.enable and win.priorityBtn.enable
        and win.replaceBtn.enable and win.gotoBtn.enable,
        "T4: 選到真地點後動作恢復可用")
    clearCalls()
    pressButton(win.addBtn)
    eq(lastCall("edit").op, "append", "T5: 主要動作是加到行程最後")
    clearCalls()
    pressButton(win.priorityBtn)
    eq(lastCall("edit").op, "priority", "T6: 先去這裡走 priority（沒有 next 舊語意）")
    eq(countCalls("start"), 0, "T6: 出發由 Core 在 priority 內完成，UI 不另發 start")
end

--------------------------------------------------------------------------------
-- U. 狀態／預覽／錯誤訊息收不住時的全文出口（關鍵狀態不得只剩「...」）
--------------------------------------------------------------------------------
do
    -- 全文列是**一段訊息被換行拆成多列**，接回來要用空字串接（同 linesText 的
    -- 理由：斷行位置是版面決定的，斷言只看接回來的整段）
    local oldMeasure = textManager.MeasureStringX
    textManager.MeasureStringX = function(_, _, text) return #tostring(text) * 26 end
    Core.toggleSearchWindow(0)
    local longName = string.rep("LongStopName", 4)
    setTrip(0, "navigating", { stop(1, 100, 100, "pending", longName),
        stop(2, 200, 200, "pending", "B") }, 1, nil, 241)
    win = openWindow(0, "itinerary")
    win._tRev = nil
    win:prerender()
    truthy(win.headLines and win.headLines.truncated,
        "U1: 本情境的狀態列確實收不住（否則測不到全文出口）")
    contains(win.headLines[#win.headLines], "...", "U1: 收不住時要有截斷提示")
    contains(listText(win.tripList), longName, "U2: 完整狀態文字要在可捲清單裡讀得到")
    contains(listText(win.tripList), "TripPreview_", "U2: 預覽列全文同樣有出口")
    -- 錯誤訊息：兩行放不下時完整原因也要進清單
    selectStop(win, 2) -- 選第二站（第一站是目前站；全文列在清單最前面）
    truthy(win.removeBtn.enable, "U3: 選到的是真的站（移除可用）")
    result.edit = { ok = false, reason = "notstopped" }
    clearCalls()
    pressButton(win.removeBtn)
    truthy(win.msgLines and win.msgLines.truncated, "U3: 這個字級下錯誤訊息放不下兩行")
    win:prerender()
    contains(listText(win.tripList), "TripError_notstopped", "U4: 錯誤原因全文要進可捲清單")
    result.edit = { ok = true, reason = "ok" }
    clock = clock + 20000
    win:prerender() -- 訊息過期：清掉全文列並作廢 cache
    win:prerender() -- 重建清單
    falsy(listText(win.tripList):find("TripError_notstopped", 1, true),
        "U5: 訊息退場後清單不留殘骸")
    textManager.MeasureStringX = oldMeasure
    Core.toggleSearchWindow(0)
end

--------------------------------------------------------------------------------
-- V. 全文出口一行一列：原版 ensureVisible 下鍵盤／手把要能逐行讀完
--    （單一超高列只對齊列首或列尾，中段永遠捲不到——review UI-3）
--------------------------------------------------------------------------------
do
    local oldMeasure = textManager.MeasureStringX
    local function infoFullText(list)
        local out = {}
        for i = 1, #list.items do
            local it = list.items[i].item
            if it.kind == "info" then out[#out + 1] = linesText(it.lines) end
        end
        return table.concat(out, "")
    end
    -- 320x540 大字級＋兩個長站名：waiting 的狀態列遠高於清單可視高度
    screen = { w = 320, h = 540 }
    fontHeights = { [UIFont.Small] = 26, [UIFont.Medium] = 33 }
    textManager.MeasureStringX = function(_, _, text) return #tostring(text) * 18 end
    local stoppedName = string.rep("StoppedStopName", 8)
    local nextName = string.rep("NextStopName", 10)
    setTrip(0, "waiting", { stop(1, 100, 100, "arrived", stoppedName),
        stop(2, 200, 200, "pending", nextName) }, 1, nil, 251)
    win = openWindow(0, "itinerary")
    win._tRev = nil
    win:prerender()
    local list = win.tripList
    truthy(win.headLines == nil or win.headLines.truncated,
        "V1: 本情境的狀態列確實放不進預留區（否則測不到全文出口）")
    local full = infoFullText(list)
    contains(full, stoppedName, "V2: 已停靠站全名在清單的全文列裡讀得到")
    contains(full, nextName, "V2: 下一目標全名也讀得到")
    contains(full, "TripPreview_", "V2: 預覽列全文同樣有出口")
    eq(tripRowCount(win), 2, "V2: 站點仍是兩列（全文列不得被算成站，站也不得被拆開）")
    -- 每一個全文列都不得高於清單可視高度：原版 ensureVisible 只對齊列首／列尾，
    -- 比清單高的列中段無論按幾次方向鍵都露不出來
    local infoRows = 0
    for i = 1, #list.items do
        if list.items[i].item.kind == "info" then
            infoRows = infoRows + 1
            truthy((list.items[i].height or list.itemheight) <= list.height,
                "V3: 第 " .. i .. " 列全文列不得高於清單可視高度（中段會讀不到）")
        end
    end
    truthy(infoRows > 2, "V3: 全文確實拆成多列（不是塞成單一超高列）")
    -- 拆出來的每一行仍是說明列，不是站也不是地點
    list.selected = 1
    win._tripSel = nil
    win:prerender()
    eq(list.items[1].item.kind, "info", "V4: 第一列是全文列")
    falsy(win.mapBtn.enable, "V4: 全文列不是地點（在地圖顯示須停用）")
    falsy(win.removeBtn.enable, "V4: 也不是站（移除須停用）")
    -- 鍵盤：走真正的焦點環→listStep→原版 ensureVisible
    local function listFocused(w)
        local entries = w.tripFocus
        local entry = w.focus and entries and entries[w.focus] or nil
        return entry ~= nil and entry.isList == true
    end
    local guard = 0
    while not listFocused(win) and guard < 20 do
        key(win, Keyboard.KEY_TAB)
        guard = guard + 1
    end
    truthy(listFocused(win), "V5: 焦點環走得到行程清單")
    for _ = 1, #list.items do key(win, Keyboard.KEY_DOWN) end
    eq(list.ensuredIndex, #list.items, "V5: 方向鍵可一路移到最後一列")
    eq(list.selected, #list.items, "V5: 選取也跟著到最後一列")
    -- 逐列停下來讀：每個全文列都必須完整落在可視範圍內
    for i = 1, #list.items do
        if list.items[i].item.kind == "info" then
            list:ensureVisible(i)
            local top = 0
            for k = 1, i - 1 do top = top + (list.items[k].height or list.itemheight) end
            local h = list.items[i].height or list.itemheight
            truthy(top + list.yScroll >= 0 and top + h + list.yScroll <= list.height,
                "V6: 第 " .. i .. " 列在原版 ensureVisible 下須完整露出")
        end
    end
    textManager.MeasureStringX = oldMeasure
    screen = { w = 1920, h = 1080 }
    fontHeights = { [UIFont.Small] = 14, [UIFont.Medium] = 18 }
    Core.toggleSearchWindow(0)
end

--------------------------------------------------------------------------------
-- W. 插入錨點選單：長站名不得把原生選單撐出畫面，全文要有鍵盤可達的出口
--    （原生 calcWidth 以最長選項全文寬算寬、render 每幀改回全文寬——review UI-4）
--------------------------------------------------------------------------------
do
    local oldMeasure = textManager.MeasureStringX
    textManager.MeasureStringX = function(_, _, text) return #tostring(text) * 15 end
    local longAnchor = string.rep("AnchorStopName", 9)
    setTrip(0, "navigating", { stop(1, 10, 10, "arrived", "A"),
        stop(2, 20, 20, "pending", longAnchor), stop(3, 30, 30, "pending", "C") }, 2, nil, 261)
    win = openWindow(0, "search")
    win.entry.text = "12895,3499"
    win._lastText = nil
    win:prerender()
    win:prerender()
    truthy(win.insertBtn.enable, "W1: 選到結果時插入可用")
    pressButton(win.insertBtn)
    local menu = win.nativeMenu
    truthy(menu and menu:isVisible(), "W1: 插入選單開啟")
    eq(#menu.options, 3, "W1: 兩個待前往錨點＋加到最後")
    local longOption, pick, shortPick
    for i = 1, #menu.options do
        local option = menu.options[i]
        if option.param and option.param.before == 2 then longOption, pick = option, i end
        if option.param and option.param.before == 3 then shortPick = i end
    end
    truthy(longOption and shortPick, "W2: 長短站名兩個錨點都在選單裡")
    local fullText = getText("UI_MinidoracatMiniMap_TripInsertBefore", "2", longAnchor)
    truthy(textManager:MeasureStringX(UIFont.Small, fullText) > screen.w,
        "W2 前提: 全文選項確實寬過整個 viewport（否則測不到有界標籤）")
    truthy(textManager:MeasureStringX(UIFont.Small, longOption.text)
        <= math.floor(screen.w / 2), "W2: 有界標籤須遠小於 viewport 寬")
    falsy(longOption.text:find(longAnchor, 1, true), "W3: 選項不塞完整長站名")
    contains(longOption.text, "TripInsertBefore|2|", "W3: 但仍說得出插在第幾站之前")
    -- 截短的項目：點下去先開既有可捲確認面板，全文用鍵盤讀得完
    clearCalls()
    UI.confirm = nil
    menu.mouseOver = pick
    menu:onJoypadDown(Joypad.AButton)
    eq(countCalls("edit"), 0, "W4: 截短項目不得直接寫入")
    local panel = UI.confirm
    truthy(panel and panel.messageList, "W4: 重用既有可捲確認面板，不另造 modal")
    contains(linesText(panel.lines), longAnchor, "W5: 完整錨點站名在確認面板裡讀得到")
    truthy(#panel.messageList.items > 1, "W5: 全文一行一列放進可捲區")
    for _ = 1, #panel.messageList.items do key(panel, Keyboard.KEY_DOWN) end
    eq(panel.messageList.ensuredIndex, #panel.messageList.items,
        "W5: 鍵盤可捲到最後一行")
    falsy(panel.onConfirm, "W6: 預設焦點在取消")
    panel:onKeyRelease(Keyboard.KEY_RETURN)
    eq(countCalls("edit"), 0, "W6: 直接 Enter 只取消，不插入")
    -- 確認後才以捕捉的 revision 與穩定 stopId 套用
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    menu.mouseOver = pick
    clearCalls()
    menu:onJoypadDown(Joypad.AButton)
    panel = UI.confirm
    panel:onKeyRelease(Keyboard.KEY_TAB)
    panel:onKeyRelease(Keyboard.KEY_RETURN)
    local applied = lastCall("edit")
    truthy(applied, "W7: 確認後須送出編輯")
    eq(applied.op, "insert", "W7: 走 insert")
    eq(applied.d, 2, "W7: 錨點仍是原本捕捉的 stopId")
    eq(applied.rev, 261, "W7: 帶捕捉時的 revision")
    -- 確認面板開著期間錨點被走完 → 整筆拒絕，不落到別人算好的位置上
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    menu.mouseOver = pick
    menu:onJoypadDown(Joypad.AButton)
    panel = UI.confirm
    trips[0].stops[2].status = "arrived"
    clearCalls()
    panel:onKeyRelease(Keyboard.KEY_TAB)
    panel:onKeyRelease(Keyboard.KEY_RETURN)
    eq(countCalls("edit"), 0, "W8: 確認期間錨點已被走完須整筆拒絕")
    linesContain(win.msgLines, "TripError_stale", "W8: 並明確回報 stale")
    -- 放得下的短站名照舊一步完成（不為了一致性把每次插入都變兩步）
    trips[0].stops[2].status = "pending"
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    menu.mouseOver = shortPick
    clearCalls()
    UI.confirm = nil
    menu:onJoypadDown(Joypad.AButton)
    falsy(UI.confirm, "W9: 短站名不必多一步確認")
    eq(lastCall("edit").op, "insert", "W9: 直接 insert")
    eq(lastCall("edit").d, 3, "W9: 錨點正確")
    textManager.MeasureStringX = oldMeasure
    Core.toggleSearchWindow(0)
end

-- Y. 插入與更多選單貼著觸發按鈕，不借用視窗標題的位置。
do
    screen = { w = 1568, h = 843 }
    setTrip(0, "draft", { stop(1, 10, 10), stop(2, 20, 20), stop(3, 30, 30) }, nil, nil, 280)
    win = openWindow(0, "search")
    win.entry.text = "12895,3499"
    win:prerender(); win:prerender()
    local anchor = win.searchMoreBtn
    win:setX(100); win:setY(20)
    pressButton(win.insertBtn)
    local menu = win.nativeMenu
    eq(menu.x, win:getAbsoluteX() + anchor.x, "Y1: 插入選單對齊動作鈕左緣")
    eq(menu.y, win:getAbsoluteY() + anchor.y + anchor.height,
        "Y1: 下方有空間時貼著動作鈕展開")
    menu:closeAll()

    win:setY(screen.h - anchor.y - anchor.height - 1)
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    eq(menu.y + menu.height, win:getAbsoluteY() + anchor.y,
        "Y2: 下方不足時貼著同一顆按鈕往上展開")
    menu:closeAll()

    local oldLeft, oldWidth = getPlayerScreenLeft, getPlayerScreenWidth
    getPlayerScreenLeft = function(pn) return pn == 1 and 784 or 0 end
    getPlayerScreenWidth = function() return 784 end
    setTrip(1, "draft", { stop(7, 10, 10), stop(8, 20, 20) }, nil, nil, 281)
    Core.toggleSearchWindow(1, "search")
    win.entry.text = "12895,3499"
    win:prerender(); win:prerender()
    win:setX(1500 - win.searchMoreBtn.x)
    win:setY(20)
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    truthy(menu.x >= 784 and menu.x + menu.width <= 1568,
        "Y3: 右緣翻移仍留在發起玩家的分割畫面")
    menu:closeAll()
    getPlayerScreenLeft, getPlayerScreenWidth = oldLeft, oldWidth
    Core.toggleSearchWindow(1)

    screen = { w = 320, h = 540 }
    setTrip(0, "draft", { stop(1, 10, 10) }, nil, nil, 282)
    win = openWindow(0, "itinerary")
    pressButton(win.tripMoreBtn)
    menu = win.nativeMenu
    truthy(menu and menu:isVisible(), "Y4: 窄版更多動作使用同一定位流程")
    local top = win:getAbsoluteY() + win.tripMoreBtn.y
    local bottom = top + win.tripMoreBtn.height
    truthy(menu.y == bottom or menu.y + menu.height == top,
        "Y4: 更多選單也貼著更多鈕，而非視窗標題")
    Core.toggleSearchWindow(0)
    local oldHeight = getPlayerScreenHeight
    local oldFontH = fontHeights[UIFont.Small]
    screen = { w = 1920, h = 1080 }
    getPlayerScreenHeight = function() return 540 end
    fontHeights[UIFont.Small] = 38
    local many = {}
    for i = 1, 16 do many[i] = stop(i, i * 10, 10) end
    setTrip(0, "draft", many, nil, nil, 283)
    win = openWindow(0, "search")
    win.entry.text = "12895,3499"
    win:prerender(); win:prerender()
    pressButton(win.insertBtn)
    menu = win.nativeMenu
    eq(#menu.options, 17, "Y5: 可捲選單保留全部插入位置")
    truthy(menu.y >= 0 and menu.y + menu.height <= 540,
        "Y5: 原生整屏高度不會越過發起玩家的 viewport")
    truthy(menu.scrollHeight > menu.height, "Y5: 放不下的項目仍可捲動，不被刪除")
    Core.toggleSearchWindow(0)
    getPlayerScreenHeight = oldHeight
    fontHeights[UIFont.Small] = oldFontH
    screen = { w = 1920, h = 1080 }
end

--------------------------------------------------------------------------------
-- Z. 收藏／回家：Core.places* 以契約假件驗 UI 接線（權威在 _Places.lua）
--------------------------------------------------------------------------------
do
    local places = { revision = 1, count = 0, places = {} }
    local placeErr = nil
    local placeResult = { ok = true }
    local function setPlaces(list, homeId)
        places = { revision = places.revision + 1, count = #list, homeId = homeId, places = list }
    end
    Core.placesState = function(pn) return pn == 0 and places or nil end
    Core.placesError = function() return placeErr end
    Core.placeLabel = function(_, p)
        if p.label then return p.label end
        if p.id == places.homeId then return "UI_MinidoracatMiniMap_PlaceHome" end
        return string.format("%d, %d", p.x, p.y)
    end
    Core.placesErrorText = function(reason) return "PlaceError_" .. tostring(reason) end
    Core.placesSetHome = function(pn, id)
        record("placeHome", { pn = pn, id = id })
        return placeResult.ok, placeResult.reason
    end
    Core.placesPromptRename = function(pn, id) record("placeRename", { pn = pn, id = id }) end
    Core.placesPromptAdd = function(pn, x, y, label)
        record("placeAdd", { pn = pn, x = x, y = y, label = label })
    end
    Core.placesRemove = function(pn, id)
        record("placeRemove", { pn = pn, id = id })
        return true
    end
    Core.placesGoHome = function(pn) record("goHome", { pn = pn }); return true end
    local function selectPlace(id)
        for i, row in ipairs(win.list.items) do
            if row.item.placeId == id then win.list.selected = i end
        end
        win:prerender()
    end
    local function optionTexts(menu)
        local out = {}
        for i, option in ipairs(menu.options) do out[i] = option.text end
        return table.concat(out, ",", 1, #out)
    end
    local P = "UI_MinidoracatMiniMap_"

    players[0] = makePlayer(0, 0)
    setTrip(0, "draft", { stop(1, 100, 100) }, nil, nil, 301)
    win = openWindow(0, "search")
    win.entry.text = ""
    win._lastText = nil
    win:prerender(); win:prerender()
    linesContain(win.list.items[1].item.lines, "PlacesEmpty", "Z1: 收藏為空時先說明怎麼加入")
    linesContain(win.list.items[2].item.lines, "SearchEmptyHint", "Z1: 原本的搜尋說明仍保留")
    falsy(win.placeBtn.enable, "Z1: 沒選到地點時收藏鈕停用")

    setPlaces({ { id = 1, x = 100, y = 0, label = "Shop" }, { id = 2, x = 300, y = 400 },
        { id = 3, x = 30, y = 40, label = "Farm" } }, 2)
    win:prerender(); win:prerender()
    local items = win.list.items
    eq(items[1].item.kind, "place", "Z2: 未輸入時列出收藏")
    eq(items[1].item.placeId, 2, "Z2: 家排第一（即使它在收藏清單中間）")
    truthy(items[1].item.home, "Z2: 家列帶 home 旗標")
    eq(items[1].item.tag, P .. "PlaceHome", "Z2: 家用家標籤")
    eq(items[1].item.label, P .. "PlaceHome", "Z2: 無名的家顯示 Core.placeLabel")
    eq(items[2].item.placeId, 1, "Z2: 其餘照收藏順序")
    eq(items[3].item.placeId, 3, "Z2: 其餘照收藏順序")
    eq(items[2].item.tag, P .. "SearchKindPlace", "Z2: 其他收藏用收藏標籤")
    eq(items[1].item.right, "(300, 400)  500m", "Z2: 右欄沿用座標＋距離格式")
    linesContain(items[4].item.lines, "SearchEmptyHint", "Z2: 搜尋說明接在收藏之後")
    truthy(win.addBtn.enable and win.gotoBtn.enable and win.placeBtn.enable,
        "Z2: 選到收藏列時既有動作與收藏鈕可用")
    clearCalls()
    pressButton(win.addBtn)
    eq(lastCall("edit").op, "append", "Z2: 收藏列可直接加到行程最後")
    eq(lastCall("edit").a, 300, "Z2: 帶收藏座標 X")
    eq(lastCall("edit").b, 400, "Z2: 帶收藏座標 Y")

    -- 刷新紀律：只有 revision／錯誤／8 格位置桶改變才重建；重建以 placeId 保留選取
    local before = win.list.items[1]
    win:prerender(); win:prerender()
    eq(win.list.items[1], before, "Z3: 收藏與位置未變時零重建")
    selectPlace(3)
    places.revision = places.revision + 1 -- 同表就地改名：只有 revision 看得出變化
    places.places[3].label = "Barn"
    win:prerender()
    truthy(win.list.items[1] ~= before, "Z3: revision 變更才重建")
    eq(win.list.items[win.list.selected].item.placeId, 3, "Z4: 重建以 placeId 保留選取")
    eq(win.list.items[win.list.selected].item.label, "Barn", "Z4: 重建後顯示新名稱")
    before = win.list.items[1]
    placeErr = "unsupported"
    win:prerender()
    truthy(win.list.items[1] ~= before, "Z3: 錯誤狀態改變也要重建")
    contains(listText(win.list), "PlaceError_unsupported", "Z3: 較新 schema 要說明為何不能改")
    eq(win.list.items[1].item.placeId, 2, "Z3: 錯誤說明不擠掉家第一")
    placeErr = nil
    win:prerender()
    before = win.list.items[1]
    players[0].x = 4
    win:prerender()
    eq(win.list.items[1], before, "Z3: 同一 8 格桶內移動不重建")
    players[0].x = 80
    win:prerender()
    truthy(win.list.items[1] ~= before, "Z3: 走出 8 格桶後重算距離")
    players[0].x = 0
    win:prerender()

    -- 收藏鈕：選中項決定選單內容；點擊時驗 owner，失敗必顯示
    selectPlace(1)
    pressButton(win.placeBtn)
    local menu = win.nativeMenu
    eq(optionTexts(menu), P .. "PlaceMenuSetHome," .. P .. "PlaceRename," .. P .. "PlaceRemove",
        "Z5: 非家收藏列出設為家／改名／移除")
    clearCalls()
    menu:onJoypadDown(Joypad.AButton)
    eq(lastCall("placeHome").id, 1, "Z6: 設為家走 Core.placesSetHome(捕捉的 placeId)")
    truthy(win.msgGood, "Z6: 成功回饋用成功色")
    linesContain(win.msgLines, "HomeSet", "Z6: 成功要說出來")
    placeResult = { ok = false, reason = "stale" }
    pressButton(win.placeBtn)
    win.nativeMenu:onJoypadDown(Joypad.AButton)
    falsy(win.msgGood, "Z6: 失敗不得用成功色")
    linesContain(win.msgLines, "PlaceError_stale", "Z6: 失敗走 placesErrorText，不得靜默")
    placeResult = { ok = true }
    selectPlace(2)
    pressButton(win.placeBtn)
    eq(optionTexts(win.nativeMenu), P .. "PlaceRename," .. P .. "PlaceRemove",
        "Z5: 已是家不列設為家")
    win.nativeMenu:closeAll()
    selectPlace(1)
    pressButton(win.placeBtn)
    menu = win.nativeMenu
    players[0] = makePlayer(0, 0)
    clearCalls()
    menu:onJoypadDown(Joypad.AButton)
    eq(countCalls("placeHome"), 0, "Z7: 換角色後的舊選單不得改新角色的收藏")
    win:prerender()
    selectPlace(1)
    pressButton(win.placeBtn)
    win.nativeMenu.mouseOver = 2
    clearCalls()
    win.nativeMenu:onJoypadDown(Joypad.AButton)
    eq(lastCall("placeRename").id, 1, "Z6: 改名走 Core.placesPromptRename")

    -- 移除：共用確認面板；不驗行程 revision，只驗 owner 與收藏仍在
    selectPlace(3)
    pressButton(win.placeBtn)
    win.nativeMenu.mouseOver = 3
    UI.confirm = nil
    clearCalls()
    win.nativeMenu:onJoypadDown(Joypad.AButton)
    local panel = UI.confirm
    truthy(panel, "Z8: 移除收藏先確認")
    eq(panel.payload.op, "placeRemove", "Z8: 確認面板 op=placeRemove")
    eq(panel.payload.placeId, 3, "Z8: 帶捕捉的 placeId")
    contains(linesText(panel.lines), "PlaceConfirmRemove|Barn", "Z8: 確認文字帶顯示名稱")
    eq(panel.actionBtn.title, P .. "PlaceRemove", "Z8: 動作鈕是明確動詞")
    eq(countCalls("placeRemove"), 0, "Z8: 確認前不得移除")
    setTrip(0, "navigating", { stop(1, 100, 100) }, 1, nil, 302)
    pressButton(panel.actionBtn)
    eq(lastCall("placeRemove") and lastCall("placeRemove").id, 3,
        "Z9: 行程 revision 改變不影響收藏移除（不走行程 revision 檢查）")
    Core.navPromptPlaceRemove(0, 1)
    panel = UI.confirm
    setPlaces({ { id = 2, x = 300, y = 400 }, { id = 3, x = 30, y = 40, label = "Barn" } }, 2)
    clearCalls()
    pressButton(panel.actionBtn)
    eq(countCalls("placeRemove"), 0, "Z10: 收藏已不存在時拒絕")
    linesContain(win.msgLines, "PlaceError_stale", "Z10: 並明確回報")
    Core.navPromptPlaceRemove(0, 3)
    panel = UI.confirm
    players[0] = makePlayer(0, 0)
    clearCalls()
    pressButton(panel.actionBtn)
    eq(countCalls("placeRemove"), 0, "Z10: 換角色後的舊面板不得移除新角色的收藏")
    UI.confirm = nil
    Core.navPromptPlaceRemove(0, 99)
    falsy(UI.confirm, "Z10: 不存在的收藏不開確認")
    linesContain(win.msgLines, "PlaceError_stale", "Z10: 而是回報 stale")

    -- 非收藏結果：只列加入收藏；座標結果不帶預設名稱，其他結果帶結果名稱
    win.entry.text = "12895,3499"
    win:prerender(); win:prerender()
    pressButton(win.placeBtn)
    eq(optionTexts(win.nativeMenu), P .. "PlaceAdd", "Z11: 非收藏結果只列加入收藏")
    clearCalls()
    win.nativeMenu:onJoypadDown(Joypad.AButton)
    local added = lastCall("placeAdd")
    eq(added.x, 12895, "Z11: 帶結果座標 X")
    eq(added.y, 3499, "Z11: 帶結果座標 Y")
    falsy(added.label, "Z11: 座標結果不把座標字串存成名稱（搬家後會說謊）")
    local oldIndex = Core.navStreetIndex
    Core.navStreetIndex = function() return { { name = "Oak St", low = "oak st", x = 40, y = 60 } } end
    win.entry.text = "oak"
    win:prerender(); win:prerender()
    pressButton(win.placeBtn)
    win.nativeMenu:onJoypadDown(Joypad.AButton)
    eq(lastCall("placeAdd").label, "Oak St", "Z11: 其他結果以結果名稱當預設名稱")
    Core.navStreetIndex = oldIndex

    -- 回家：行程頁主要列（停止之後、更多之前），永遠可按，鍵盤／手把可達
    Core.toggleSearchWindow(0, "itinerary")
    local homeAt, pauseAt, moreAt
    for i, d in ipairs(win.tripBtns) do
        if d.btn == win.homeBtn then homeAt = i end
        if d.btn == win.pauseBtn then pauseAt = i end
        if d.btn == win.tripMoreBtn then moreAt = i end
    end
    truthy(homeAt == pauseAt + 1 and homeAt < moreAt and win.tripBtns[homeAt].group == nil,
        "Z12: 回家是主要動作，在停止之後、更多之前")
    trips[0] = nil
    win._tRev = nil
    win:prerender()
    truthy(win.homeBtn:isVisible() and win.homeBtn.enable, "Z12: 沒有行程時回家仍可按")
    clearCalls()
    pressButton(win.homeBtn)
    eq(lastCall("goHome") and lastCall("goHome").pn, 0, "Z12: 回家走 Core.placesGoHome(pn)")
    local found
    for i, entry in ipairs(win.tripFocus) do
        if entry.el == win.homeBtn then found = i end
    end
    truthy(found, "Z13: 回家在手把／鍵盤焦點鏈中")
    win.focus = nil
    local guard = 0
    while win.focus ~= found and guard < 40 do
        key(win, Keyboard.KEY_TAB)
        guard = guard + 1
    end
    eq(win.focus, found, "Z13: 鍵盤 TAB 走得到回家")
    clearCalls()
    key(win, Keyboard.KEY_RETURN)
    eq(countCalls("goHome"), 1, "Z13: Enter 觸發回家")
    clearCalls()
    win:onJoypadDown(Joypad.AButton)
    eq(countCalls("goHome"), 1, "Z13: 手把 A 觸發回家")

    -- 窄版大字：回家不被折疊；收藏鈕經「更多」原生選單可達並開出收藏選單
    Core.toggleSearchWindow(0)
    screen = { w = 320, h = 540 }
    fontHeights = { [UIFont.Small] = 26, [UIFont.Medium] = 33 }
    win = openWindow(0, "itinerary")
    truthy(win.homeBtn:isVisible() and win.homeBtn.x + win.homeBtn.width <= win.width
        and win.homeBtn.y + win.homeBtn.height <= win.height, "Z14: 窄版回家仍在視窗內可按")
    Core.toggleSearchWindow(0, "search")
    win.entry.text = ""
    win._lastText = nil
    win:prerender(); win:prerender()
    eq(win.list.items[1].item.placeId, 2, "Z14: 窄版仍是家排第一")
    pressButton(win.searchMoreBtn)
    local pick
    for i, option in ipairs(win.nativeMenu.options) do
        if option.text == win.placeBtn.title then pick = i end
    end
    truthy(pick and not win.nativeMenu.options[pick].notAvailable, "Z14: 更多選單含可用的收藏")
    win.nativeMenu.mouseOver = pick
    win.nativeMenu:onJoypadDown(Joypad.AButton)
    eq(optionTexts(win.nativeMenu), P .. "PlaceRename," .. P .. "PlaceRemove",
        "Z14: 經更多選單開出收藏選單")
    win.nativeMenu:closeAll()
    Core.toggleSearchWindow(0)
    screen = { w = 1920, h = 1080 }
    fontHeights = { [UIFont.Small] = 14, [UIFont.Medium] = 18 }

    -- navMessage：視窗不在時退 halo，好壞分通道
    Core.navMessage(0, "done", true)
    eq(halos[#halos].text, "done", "Z15: 視窗不在時退 halo")
    truthy(halos[#halos].good, "Z15: good=true 走 addGoodText")
    Core.navMessage(0, "oops")
    falsy(halos[#halos].good, "Z15: 其餘走 addBadText")

    -- 缺 _Places（單獨抽載）：不列收藏、收藏鈕停用、回家顯示 generic 錯誤，不丟錯
    for _, name in ipairs({ "placesState", "placesError", "placeLabel", "placesErrorText",
        "placesSetHome", "placesPromptRename", "placesPromptAdd", "placesRemove", "placesGoHome" }) do
        Core[name] = nil
    end
    win = openWindow(0, "search")
    win.entry.text = ""
    win._lastText = nil
    win:prerender(); win:prerender()
    linesContain(win.list.items[1].item.lines, "SearchEmptyHint", "Z16: 缺 _Places 時只剩搜尋說明")
    win.entry.text = "12895,3499"
    win:prerender(); win:prerender()
    truthy(win.addBtn.enable, "Z16 前提: 選到了真地點")
    falsy(win.placeBtn.enable, "Z16: 缺 _Places 時收藏鈕停用")
    Core.toggleSearchWindow(0, "itinerary")
    pressButton(win.homeBtn)
    linesContain(win.msgLines, "TripError_failed", "Z16: 缺 _Places 時回家顯示 generic 錯誤")
    UI.confirm = nil
    Core.navPromptPlaceRemove(0, 1)
    falsy(UI.confirm, "Z16: 缺 _Places 時移除不開確認也不丟錯")
    Core.toggleSearchWindow(0)
end

-- X. 真 Core／UI 聯測：raw trip 與 public claim 表面必須真的接得上。
do
    Events.OnCreatePlayer = { Add = function() end }
    Events.OnTick = { Add = function() end }
    function isClient() return false end
    local p = getSpecificPlayer(0)
    local data = {}
    local car = { isStopped = function() return true end,
        isDriver = function(_, who) return who == p end }
    p.getModData = function() return data end
    p.getVehicle = function() return car end
    p.isDead = function() return false end
    Core.navGateAllows = function() return true end
    local corePath = arg[2] or sourcePath:gsub("[/\\]client[/\\][^/\\]+$",
        "/client/MinidoracatMiniMap_Itinerary.lua")
    dofile(corePath)
    truthy(Core.navLoadItinerary(0), "X: 真角色行程載入")
    truthy(Core.navSetTarget(0, 100, 0, "A"), "X: 建立目前目標")
    local api = MinidoracatMiniMapAPI
    truthy(Core.navEditItinerary(0, api.getNavItinerary(0).revision, "append", 200, 0, "B"),
        "X: 新增下一目標")
    truthy(Core.navEditItinerary(0, api.getNavItinerary(0).revision, "append", 300, 0, "C"),
        "X: 新增最後目標")
    local token = api.claimNavLeg(0, "Auto", api.getNavLeg(0))
    truthy(token, "X: 真駕駛取得 claim")
    local itinerary = api.getNavItinerary(0)
    falsy(Core.navItineraryState(0).claimed, "X: raw trip 沒有認領欄位")
    truthy(itinerary.claimed, "X: public 快照反映認領")
    local window = openWindow(0, "itinerary")
    window:prerender()
    selectStop(window, itinerary.stops[1].id)
    falsy(window.removeBtn.enable or window.upBtn.enable or window.downBtn.enable,
        "X: 真 claim 鎖住目前站結構操作")
    truthy(window.pauseStopBtn.enable, "X: 真 claim 不鎖停等偏好")
    selectStop(window, itinerary.stops[2].id)
    falsy(window.upBtn.enable, "X: 不可用後續站跨過認領中的目標")
    truthy(window.removeBtn.enable, "X: 後續站仍可移除")
    selectStop(window, itinerary.stops[3].id)
    truthy(window.upBtn.enable, "X: 後續區段內的上移仍可用")
    pressButton(window.upBtn)
    window:prerender()
    eq(api.getNavItinerary(0).stops[2].id, itinerary.stops[3].id, "X: 真 Core 完成後續重排")
    eq(api.getNavLeg(0), token, "X: UI 後續重排不換活動 token")
    truthy(api.getNavItinerary(0).claimed, "X: UI 後續重排不丟 claim")
    truthy(api.releaseNavLeg(0, "Auto", token, "manual"), "X: 先停止接管再改指引")
    window:prerender()
    local px, py = p:getX(), p:getY()
    pressButton(window.manualBtn)
    local guided = api.getNavItinerary(0)
    eq(guided.phase, "approach", "X: 直線指引不再要求道路路線")
    eq(api.getNavTarget(0), 100, "X: 直線指引仍指向同一目標")
    eq(guided.stops[1].status, "pending", "X: 改指引不假報到站")
    eq(p:getX(), px, "X: 按鈕不移動玩家 X")
    eq(p:getY(), py, "X: 按鈕不移動玩家 Y")
    truthy(window.manualBtn.tooltip, "X: 直線指引有用途說明")
    window:prerender()
    local directTitle = window.manualBtn.title
    contains(directTitle, "TripRoads", "X: 直線模式時按鈕明示改回道路")
    truthy(Core.navEditItinerary(0, guided.revision, "append", 400, 0, "D"),
        "X: 模擬畫面未刷新時行程已更新")
    pressButton(window.manualBtn)
    eq(api.getNavItinerary(0).phase, "approach", "X: 過期道路切換保留原指引")
    window:prerender()
    pressButton(window.manualBtn)
    window:prerender()
    local road = api.getNavItinerary(0)
    eq(road.phase, "navigating", "X: 同一顆按鈕直接切回道路")
    eq(road.currentStopId, guided.currentStopId, "X: 切回仍是同一目標")
    eq(road.count, 4, "X: 切回不清空後續目標")
    eq(api.getNavTarget(0), 100, "X: 切回不改目的地座標")
    falsy(road.claimed, "X: 切回道路不接管車輛")
    truthy(window.manualBtn.title ~= directTitle, "X: 道路模式恢復直線指引按鈕")
    pressButton(window.manualBtn)
    eq(api.getNavItinerary(0).phase, "approach", "X: 可再次切為直線")
    Core.toggleSearchWindow(0)
    screen = { w = 320, h = 540 }
    window = openWindow(0, "itinerary")
    window:prerender()
    pressButton(window.tripMoreBtn)
    local menu = window.nativeMenu
    truthy(menu and menu:isVisible(), "X: 窄版切換經更多選單")
    local chosen
    for i, option in ipairs(menu.options) do
        if option.text == window.manualBtn.title then chosen = i; break end
    end
    truthy(chosen, "X: 更多選單提供切回道路")
    truthy(Core.navPauseItinerary(0, "manual"), "X: 選單開啟期間停止導航")
    window:prerender()
    menu.mouseOver = chosen
    menu:onJoypadDown(Joypad.AButton)
    eq(api.getNavItinerary(0).phase, "paused",
        "X: 舊道路選項不能借背後的新 revision 反向啟動直線")
    truthy(Core.navGuideItinerary(0, api.getNavItinerary(0).revision, "approach"))
    window:prerender()
    pressButton(window.tripMoreBtn)
    menu = window.nativeMenu
    for i, option in ipairs(menu.options) do
        if option.text == window.manualBtn.title then menu.mouseOver = i; break end
    end
    menu:onJoypadDown(Joypad.AButton)
    eq(api.getNavItinerary(0).phase, "navigating", "X: 新更多選單仍可正常切回道路")
    Core.toggleSearchWindow(0)
    screen = { w = 1920, h = 1080 }
end

print("test_itinerary_ui: 全數通過（A 開窗切頁收合 / B 提示列防呆 / C 確認防線與防誤觸 / "
    .. "D 契約接線 / E 動作可用性 / F 色語與距離誠實 / G 鍵盤 / H 手把 / "
    .. "I 版面不超 viewport / J 實寬換行 / K 刷新與選取保留 / L 繪製路徑與文字不疊 / "
    .. "M 快捷鍵入口 / N 分割畫面 ping / Q 接續模式兩入口 / R 插入錨點防線 / "
    .. "S 逐站停等與認領鎖定 / T 搜尋頁動作可用性 / U 全文出口 / "
    .. "V 全文列逐行可讀 / W 插入錨點有界標籤與全文出口 / X 真 Core 接管與直線指引 / Y 按鈕錨定 / "
    .. "Z 收藏清單與回家）")
