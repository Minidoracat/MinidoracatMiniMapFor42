-- 世界地圖導航/座標（_WorldMapNav.lua）離線回歸測試。
-- 仿 test_ghost_gate.lua：抽標記區段→補最小 stub→組裝離線跑；導航回呼區段一併
-- 抽 production 本體（選單項要導到哪個行程操作＝本檔契約，不得在測試裡複製一份）。
-- 核心不變量：
--   (1) symbolsUI 工具作用中（currentTool / down 時快照的 ignoreRightMouseUp）
--       右鍵＝取消工具，原樣透傳、不疊選單；
--   (2) 前手建了選單（getPlayerContextMenu(pn) 呼叫後可見）→ 追加同一單例，不論
--       前手回什麼（DebugMenu 系建了選單回 nil）；前手回 true 但選單在 player 0
--       （原版 debug 硬編 0）也追加；都沒有 → ISContextMenu.get(self.playerNum, abs 座標)
--       自建——分割畫面歸屬用 playerNum、不硬編 0；
--   (3) 呼叫前手前把殘留舊選單藏掉：舊選單不會被誤判成「前手建的」；
--   (4) 選項組裝：TripAdd/TripPriority/SetTarget/TripManage/CopyHere/SearchMenu 恆有，
--       順序＝加到最後→（有待前往站才有的插入子選單）→先去這裡→取代整趟→行程管理；
--       TripClear 依行程狀態或載入錯誤（壞資料也要能清）；TripPause 依 navGetTarget；
--       ShareTarget 再疊 isClient＋Faction＋AllowNavShare 三閘；同一選單已有 SetTarget
--       就不再加（冪等）；
--   (5) 回呼分流：TripAdd→append／TripPriority→priority／SetTarget→replace 的
--       navPromptTarget（沒有舊的 next 語意），插入位置一律委派 Core.navInsertSubMenu
--       共用同一份錨點防線，TripManage→行程頁、TripPause→navPauseItinerary
--       （點選單不得自動出發）；
--   (6) 開圖自癒：別的 MOD 整個覆寫 onRightMouseUp（不呼叫前手）→ ShowWorldMap 後
--       重包一層，兩家選項都在；重包有上限；
--   (7) prerender 加繪：先座標列後導航；各自 pcall＋實例旗標 log-once。
-- 用法：lua scripts/test_worldmap_nav.lua [path/to/MinidoracatMiniMap_WorldMapNav.lua]
local navPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_WorldMapNav.lua"

local file = assert(io.open(navPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

-- 導航回呼（ISWorldMap:onMinidoracat*）：無標記，以首末函式名錨定整段
local callbackBody = assert(source:match(
    "(function ISWorldMap:onMinidoracatSetTarget.-\nfunction ISWorldMap:onMinidoracatPauseNav%(%).-\nend)\n"),
    "找不到 ISWorldMap 導航回呼區段（結構變了？同步更新錨點）")
local rightBody = assert(source:match(
    "%-%- test:wm%-rightclick:start\n(.-)\n%-%- test:wm%-rightclick:end"),
    "找不到 wm-rightclick 測試區段")
local preBody = assert(source:match(
    "%-%- test:wm%-prerender:start\n(.-)\n%-%- test:wm%-prerender:end"),
    "找不到 wm-prerender 測試區段")

local compile = loadstring or load

--------------------------------------------------------------------------------
-- stub 環境：原版 onRightMouseUp 行為可注入（origMode）；每位玩家一顆選單單例，
-- ISContextMenu.get 仿原版 hide→show→clear（ISContextMenu.lua:1166-1180）。
-- 行程狀態／錯誤／目標三者獨立可設＝選項閘門三條分支都測得到
--------------------------------------------------------------------------------
local env = [=[
local printed = {}
local function print(msg) printed[#printed + 1] = tostring(msg) end
local calls = {}                 -- 依序記錄可觀測事件
local origMode = "none"          -- none＝原版一般玩家（回 false）；debug＝原版 debug（get(0) 建選單回 true）；
                                 -- debugmenu＝DebugMenu 系（get(pn) 建選單、回 nil）
local playerObjs = {}            -- [pn] = 假玩家物件
local clientMode = false
local factionOf = nil            -- Faction.getPlayerFaction 回傳
local sandboxAllow = true
local navTarget = nil            -- Core.navGetTarget 回傳（活動站＝可暫停/可分享）
local tripState, tripError = nil, nil -- Core.navItineraryState／navItineraryError 回傳
local menus = {}                 -- [pn] = 選單單例
local gets = 0                   -- ISContextMenu.get 呼叫次數

local function mkContext(pn)
    local c = { pn = pn, options = {}, visible = false, hides = 0 }
    function c:addOption(name, target, fn, a, b)
        self.options[#self.options + 1] = { name = name, target = target, fn = fn, a = a, b = b }
    end
    function c:isVisible() return self.visible end
    function c:hideAndChildren() self.visible = false; self.hides = self.hides + 1 end
    function c:clear() self.options = {} end
    function c:getOptionFromName(name) -- 同原版 ISContextMenu.lua:889
        for _, o in ipairs(self.options) do if o.name == name then return o end end
    end
    return c
end
local function menuOf(pn)
    if not menus[pn] then menus[pn] = mkContext(pn) end
    return menus[pn]
end
local function getPlayerContextMenu(pn)
    calls[#calls + 1] = "getPlayerContextMenu:" .. tostring(pn)
    return menuOf(pn)
end
local ISContextMenu = {}
function ISContextMenu.get(pn, x, y)
    calls[#calls + 1] = string.format("ISContextMenu.get:%s:%s:%s", tostring(pn), tostring(x), tostring(y))
    gets = gets + 1
    local c = menuOf(pn)
    c:hideAndChildren(); c.visible = true; c:clear()
    return c
end

local ISWorldMap = {}
function ISWorldMap.onRightMouseUp(self, x, y)
    calls[#calls + 1] = "orig-rmb"
    if origMode == "debug" then
        local c = ISContextMenu.get(0, x + self:getAbsoluteX(), y + self:getAbsoluteY())
        c:addOption("vanilla-teleport")
        return true
    elseif origMode == "debugmenu" then
        local c = ISContextMenu.get(self.playerNum or 0, x + self:getAbsoluteX(), y + self:getAbsoluteY())
        c:addOption("debugmenu-root")
        return nil
    end
    return false
end
function ISWorldMap.ShowWorldMap(playerNum, centerX, centerY, zoom)
    calls[#calls + 1] = "orig-show:" .. tostring(playerNum)
end
function ISWorldMap.prerender(self)
    calls[#calls + 1] = "orig-prerender"
end

local function getSpecificPlayer(pn) return playerObjs[pn] end
local function getText(key, arg1)
    if arg1 then return key .. "|" .. arg1 end
    return key
end
local function isClient() return clientMode end
local Faction = { getPlayerFaction = function(p) return factionOf end }

local Core = { ready = true }
Core.navGetTarget = function(pn) return navTarget end
Core.navItineraryState = function(pn) return tripState end
Core.navItineraryError = function(pn) return tripError end
Core.navPromptTarget = function(pn, wx, wy, label, op)
    calls[#calls + 1] = string.format("prompt:%d:%s:%s:%s:%s", pn, tostring(wx), tostring(wy),
        tostring(label), tostring(op))
end
Core.navPromptClear = function(pn) calls[#calls + 1] = "promptClear:" .. pn end
Core.navPauseItinerary = function(pn, reason)
    calls[#calls + 1] = "pause:" .. pn .. ":" .. tostring(reason)
    return true
end
Core.toggleSearchWindow = function(pn, page)
    calls[#calls + 1] = "toggle:" .. pn .. ":" .. tostring(page)
end
Core.navShareTarget = function(pn) calls[#calls + 1] = "navShare:" .. pn end
Core.copyCoordsText = function(el, text) calls[#calls + 1] = "copy:" .. text end
Core.navShareAllowed = function() return sandboxAllow end
-- 插入子選單：本體只負責委派給 Core（錨點、owner／revision 防線都在 _Search.lua，
-- 不在這裡複製一份）。有待前往站時才會掛上那一項
local insertAnchors = false
Core.navInsertSubMenu = function(context, target, pn, x, y, label)
    calls[#calls + 1] = string.format("insertSub:%s:%s:%s:%s", tostring(pn),
        tostring(x), tostring(y), tostring(label))
    if not insertAnchors then return end
    context:addOption("UI_MinidoracatMiniMap_TripInsert", target, nil)
end
local drawCoordsFail, drawNavFail = false, false
Core.drawPlayerCoords = function(el)
    calls[#calls + 1] = "drawCoords"
    if drawCoordsFail then error("injected coords failure") end
end
Core.drawNavTargets = function(el)
    calls[#calls + 1] = "drawNav"
    if drawNavFail then error("injected nav failure") end
end
Core.drawAdminViewMarker = function() end

-- Extraction Mode 相容層用的最小環境：
--   Events.OnGameStart＝延後查全域（別的 MOD 的 class 可能比本檔晚建）；
--   ISUIElement 空右鍵回呼＝原版（ISUIElement.lua:1555-1561）什麼都不做、回 nil；
--   wantMouseEvents 走 javaObject 為 nil 的分支（:1837-1852）。
local gameStartHandlers = {}
local Events = { OnGameStart = { Add = function(fn)
    gameStartHandlers[#gameStartHandlers + 1] = fn
end } }
-- PZ 的 Kahlua rawget 會沿 metatable 一路往上找（只有 pairs 只列 class 自己的 key），
-- 靠 rawget 判斷「這個 class 自己有沒有設過」在遊戲裡會恆為非 nil＝永遠不會包
local realRawget = rawget
local function rawget(t, k)
    local v = realRawget(t, k)
    if v ~= nil then return v end
    local mt = getmetatable(t)
    if mt ~= nil then return rawget(mt, k) end
    return nil
end
local ISUIElement = {}
local wantReads = 0 -- isWantMouseEvents 被問過幾次：疊一層包就會多問一次
function ISUIElement:onRightMouseDown(x, y) calls[#calls + 1] = "base-rdown" end
function ISUIElement:onRightMouseUp(x, y) calls[#calls + 1] = "base-rup" end
function ISUIElement:setWantMouseEvents(want) self.wantMouseEvents = want end
function ISUIElement:isWantMouseEvents()
    wantReads = wantReads + 1
    return self.wantMouseEvents
end
-- 同原版 derive：setmetatable(child, parent); parent.__index = parent
local function derive(parent)
    local c = {}
    setmetatable(c, parent)
    parent.__index = parent
    return c
end
local ISPanel = derive(ISUIElement) -- 42.20.4 的 ISPanel 未自訂右鍵回呼
]=]

local suffix = [=[
return {
    ISWorldMap = ISWorldMap,
    ISContextMenu = ISContextMenu,
    calls = calls,
    printed = printed,
    clearCalls = function() for i = #calls, 1, -1 do calls[i] = nil end end,
    menu = menuOf,
    gets = function() return gets end,
    resetMenus = function() for k in pairs(menus) do menus[k] = nil end; gets = 0 end,
    setOrigMode = function(v) origMode = v end,
    setPlayer = function(pn, p) playerObjs[pn] = p end,
    setClient = function(v) clientMode = v end,
    setFaction = function(v) factionOf = v end,
    setSandbox = function(v) sandboxAllow = v end,
    setNavTarget = function(v) navTarget = v end,
    setTrip = function(state, err) tripState, tripError = state, err end,
    setInsertAnchors = function(v) insertAnchors = v end,
    setDrawFail = function(coords, nav) drawCoordsFail = coords; drawNavFail = nav end,
    ISUIElement = ISUIElement,
    ISPanel = ISPanel,
    derive = derive,
    fireGameStart = function()
        for _, fn in ipairs(gameStartHandlers) do fn() end
    end,
    wantReads = function() return wantReads end,
}
]=]

local mod = assert(compile(env .. "\n" .. callbackBody .. "\n" .. rightBody .. "\n"
    .. preBody .. "\n" .. suffix, "wm-nav"))()

-- 假世界地圖實例（wrap 後的 method 以 ":" 呼叫）
local function mkWM(pn)
    return setmetatable({
        playerNum = pn,
        symbolsUI = { currentTool = nil, ignoreRightMouseUp = false },
        mapAPI = {
            uiToWorldX = function(_, x, y) return 12.7 end,
            uiToWorldY = function(_, x, y) return 34.2 end,
        },
        getAbsoluteX = function() return 100 end,
        getAbsoluteY = function() return 200 end,
    }, { __index = mod.ISWorldMap })
end

local function names(menu)
    local t = {}
    for i, o in ipairs(menu.options) do t[i] = o.name end
    return table.concat(t, ",")
end
local function countName(menu, name)
    local n = 0
    for _, o in ipairs(menu.options) do if o.name == name then n = n + 1 end end
    return n
end
local SET = "UI_MinidoracatMiniMap_SetTarget"
-- 恆有的六項：加到行程最後／先去這裡／取代整趟／管理行程／複製座標／搜尋
-- （插入位置只在有待前往站時另掛一項，見 R10）
local OURS = "UI_MinidoracatMiniMap_TripAdd"
    .. ",UI_MinidoracatMiniMap_TripPriority"
    .. "," .. SET
    .. ",UI_MinidoracatMiniMap_TripManage"
    .. ",UI_MinidoracatMiniMap_CopyHere|12, 34, 0"
    .. ",UI_MinidoracatMiniMap_SearchMenu"
local OURS_N = 6

--------------------------------------------------------------------------------
-- R1/R2: symbols 工具作用中／down 快照旗標＝原樣透傳，不建選單、不碰單例
--------------------------------------------------------------------------------
mod.setPlayer(0, { name = "p0" })
local wm = mkWM(0)
wm.symbolsUI.currentTool = {}
mod.setOrigMode("debug")
local r = wm:onRightMouseUp(5, 6)
assert(r == true, "R1: 工具作用中須原樣回傳 original 結果")
assert(mod.calls[1] == "orig-rmb", "R1: 只跑 original")
assert(countName(mod.menu(0), SET) == 0, "R1: 工具作用中不得追加本 MOD 選項")
mod.clearCalls(); mod.resetMenus()

wm.symbolsUI.currentTool = nil
wm.symbolsUI.ignoreRightMouseUp = true
mod.setOrigMode("none")
r = wm:onRightMouseUp(5, 6)
assert(#mod.calls == 1 and mod.calls[1] == "orig-rmb", "R2: down 快照旗標同樣透傳、不碰選單")
mod.clearCalls(); mod.resetMenus()
wm.symbolsUI.ignoreRightMouseUp = false

--------------------------------------------------------------------------------
-- R3: 原版 debug（get(0) 建選單回 true）→ 追加同一單例、不再 get（會 clear 掉 debug 項）
--------------------------------------------------------------------------------
mod.setOrigMode("debug")
mod.setNavTarget(nil)
mod.setTrip(nil, nil)
r = wm:onRightMouseUp(5, 6)
assert(r == true, "R3: 追加路徑回 true")
assert(mod.gets() == 1, "R3: 只有原版那一次 get，本 MOD 不得再 get（實得 " .. mod.gets() .. "）")
assert(names(mod.menu(0)) == "vanilla-teleport," .. OURS,
    "R3: debug 項保留＋追加六項（實得 " .. names(mod.menu(0)) .. "）")
assert(mod.menu(0).visible, "R3: 選單維持可見")
mod.clearCalls(); mod.resetMenus()

--------------------------------------------------------------------------------
-- N1: DebugMenu 系前手（建了選單卻回 nil）→ 追加同一單例，不得自建洗掉它
--     （2026-09-05 kenzo_L：裝本 MOD 後只剩本 MOD 的項）
--------------------------------------------------------------------------------
mod.setOrigMode("debugmenu")
r = wm:onRightMouseUp(5, 6)
assert(r == true, "N1: 追加路徑回 true（已消費）")
assert(mod.gets() == 1, "N1: 前手建的選單不得被本 MOD 再 get 洗掉（實得 gets=" .. mod.gets() .. "）")
assert(names(mod.menu(0)) == "debugmenu-root," .. OURS,
    "N1: 前手選項保留＋追加六項（實得 " .. names(mod.menu(0)) .. "）")
mod.clearCalls(); mod.resetMenus()

--------------------------------------------------------------------------------
-- R4: 一般玩家（original 回 false、無選單）→ ISContextMenu.get(pn, abs 座標) 自建；
--     分割畫面 pn=1 歸屬正確
--------------------------------------------------------------------------------
mod.setPlayer(1, { name = "p1" })
local wm1 = mkWM(1)
mod.setOrigMode("none")
r = wm1:onRightMouseUp(5, 6)
assert(r == true, "R4: 自建路徑回 true（已消費）")
local gotGet = false
for _, c in ipairs(mod.calls) do if c == "ISContextMenu.get:1:105:206" then gotGet = true end end
assert(gotGet, "R4: 須以 self.playerNum=1 與絕對座標自建（實得 " .. table.concat(mod.calls, ",") .. "）")
local menu = mod.menu(1)
assert(names(menu) == OURS, "R4: 自建選單六項（實得 " .. names(menu) .. "）")
assert(#mod.menu(0).options == 0, "R4: 不得碰 player 0 的單例")
-- R7: CopyHere 文字帶 floor 座標；回呼參數同值
assert(menu.options[5].a == 12 and menu.options[5].b == 34, "R7: 回呼參數須為 floor 後座標")
-- R9: 回呼綁定走 playerNum，且三種目標操作分流正確（都不自動出發）
menu.options[1].fn(menu.options[1].target, menu.options[1].a, menu.options[1].b)
assert(mod.calls[#mod.calls] == "prompt:1:12.7:34.2:nil:append",
    "R9: TripAdd 須以 pn=1、原始世界座標走 append（實得 " .. tostring(mod.calls[#mod.calls]) .. "）")
menu.options[2].fn(menu.options[2].target, menu.options[2].a, menu.options[2].b)
assert(mod.calls[#mod.calls] == "prompt:1:12.7:34.2:nil:priority",
    "R9: TripPriority 須走 priority（舊的 next 已不存在）")
menu.options[3].fn(menu.options[3].target, menu.options[3].a, menu.options[3].b)
assert(mod.calls[#mod.calls] == "prompt:1:12.7:34.2:nil:replace", "R9: SetTarget 須走 replace")
menu.options[4].fn(menu.options[4].target)
assert(mod.calls[#mod.calls] == "toggle:1:itinerary", "R9: TripManage 須開行程頁")
menu.options[6].fn(menu.options[6].target)
assert(mod.calls[#mod.calls] == "toggle:1:nil", "R9: SearchMenu 維持原 toggle（不帶頁）")
-- R10: 有待前往站時另掛插入位置一項，且一律委派 Core 共用的錨點組裝
mod.clearCalls(); mod.resetMenus()
mod.setInsertAnchors(true)
r = wm1:onRightMouseUp(5, 6)
local m10 = mod.menu(1)
assert(names(m10) == "UI_MinidoracatMiniMap_TripAdd,UI_MinidoracatMiniMap_TripInsert"
    .. ",UI_MinidoracatMiniMap_TripPriority," .. SET
    .. ",UI_MinidoracatMiniMap_TripManage"
    .. ",UI_MinidoracatMiniMap_CopyHere|12, 34, 0"
    .. ",UI_MinidoracatMiniMap_SearchMenu",
    "R10: 插入位置須緊接在加到最後之後（實得 " .. names(m10) .. "）")
local delegated = false
for _, c in ipairs(mod.calls) do
    if c == "insertSub:1:12.7:34.2:nil" then delegated = true end
end
assert(delegated, "R10: 插入子選單須以 pn 與原始世界座標委派 Core.navInsertSubMenu（實得 "
    .. table.concat(mod.calls, ",") .. "）")
mod.setInsertAnchors(false)
mod.clearCalls(); mod.resetMenus()

--------------------------------------------------------------------------------
-- R3b: 分割畫面 pn=1 遇原版 debug（選單硬編在 player 0、回 true）→ 追加 player 0 單例
--------------------------------------------------------------------------------
mod.setOrigMode("debug")
r = wm1:onRightMouseUp(5, 6)
assert(names(mod.menu(0)) == "vanilla-teleport," .. OURS,
    "R3b: pn=1 的 debug 選單在 player 0，須追加該單例（實得 " .. names(mod.menu(0)) .. "）")
assert(mod.gets() == 1, "R3b: 不得另建")
mod.clearCalls(); mod.resetMenus()

--------------------------------------------------------------------------------
-- N4: 殘留的舊選單（上一次右鍵留著沒關）不得被當成「前手建的」——先藏、再自建新的
--------------------------------------------------------------------------------
mod.setOrigMode("none")
local stale = mod.menu(1)
stale.visible = true
stale:addOption("stale-option")
r = wm1:onRightMouseUp(5, 6)
assert(stale.hides >= 1, "N4: 呼叫前手前須先藏掉殘留選單")
assert(mod.gets() == 1 and names(mod.menu(1)) == OURS,
    "N4: 殘留選單不得被追加，須重建（實得 gets=" .. mod.gets() .. " " .. names(mod.menu(1)) .. "）")
mod.clearCalls(); mod.resetMenus()

--------------------------------------------------------------------------------
-- R5: playerObj nil（debug 主選單地圖）→ 回傳 handled、不建選單
--------------------------------------------------------------------------------
mod.setPlayer(1, nil)
r = wm1:onRightMouseUp(5, 6)
assert(r == false, "R5: 無玩家回傳 original 結果")
assert(mod.gets() == 0 and #mod.menu(1).options == 0, "R5: 無玩家不得建選單")
mod.clearCalls(); mod.resetMenus()
mod.setPlayer(1, { name = "p1" })

--------------------------------------------------------------------------------
-- R6: 有行程 → TripClear；有活動站 → TripPause；Share 三閘（isClient＋Faction＋沙盒）
--------------------------------------------------------------------------------
mod.setTrip({ count = 2, revision = 3 }, nil)
mod.setNavTarget({ id = 1, x = 1, y = 2 })
mod.setClient(true)
mod.setFaction({})
mod.setSandbox(true)
r = wm1:onRightMouseUp(5, 6)
local m6 = mod.menu(1)
assert(#m6.options == OURS_N + 3,
    "R6: 行程＋活動站＋陣營＋沙盒允許＝九項（實得 " .. #m6.options .. "）")
assert(m6.options[OURS_N + 1].name == "UI_MinidoracatMiniMap_TripClear", "R6: 第七項 TripClear")
assert(m6.options[OURS_N + 2].name == "UI_MinidoracatMiniMap_TripPause", "R6: 第八項 TripPause")
assert(m6.options[OURS_N + 3].name == "UI_MinidoracatMiniMap_ShareTarget", "R6: 第九項 ShareTarget")
-- 回呼：清空走確認對話框入口；暫停停導航（都不得直接改權威）
m6.options[OURS_N + 1].fn(m6.options[OURS_N + 1].target)
assert(mod.calls[#mod.calls] == "promptClear:1", "R6: TripClear 須走確認入口")
m6.options[OURS_N + 2].fn(m6.options[OURS_N + 2].target)
assert(mod.calls[#mod.calls] == "pause:1:cancelled", "R6: TripPause 須暫停行程")
mod.clearCalls(); mod.resetMenus()

mod.setSandbox(false) -- 伺服器禁分享：Share 消失、Clear/Pause 保留
r = wm1:onRightMouseUp(5, 6)
assert(#mod.menu(1).options == OURS_N + 2, "R6: 沙盒禁分享＝八項（無 Share）")
mod.clearCalls(); mod.resetMenus()
mod.setClient(false) -- 單機：無 Share
mod.setSandbox(true)
r = wm1:onRightMouseUp(5, 6)
assert(#mod.menu(1).options == OURS_N + 2, "R6: 單機＝八項（無 Share）")
mod.clearCalls(); mod.resetMenus()

-- R6b: 暫停中（無活動站）只留 TripClear；無行程無錯誤＝六項
mod.setNavTarget(nil)
r = wm1:onRightMouseUp(5, 6)
assert(names(mod.menu(1)) == OURS .. ",UI_MinidoracatMiniMap_TripClear",
    "R6b: 暫停中不得出現 TripPause（實得 " .. names(mod.menu(1)) .. "）")
mod.clearCalls(); mod.resetMenus()

-- R6c: 行程資料損壞（狀態讀不出來、只有錯誤）仍須能清除，否則玩家無法重建
mod.setTrip(nil, "unsupported")
r = wm1:onRightMouseUp(5, 6)
assert(names(mod.menu(1)) == OURS .. ",UI_MinidoracatMiniMap_TripClear",
    "R6c: 壞資料須保留 TripClear（實得 " .. names(mod.menu(1)) .. "）")
mod.clearCalls(); mod.resetMenus()
mod.setTrip(nil, nil)
r = wm1:onRightMouseUp(5, 6)
assert(names(mod.menu(1)) == OURS, "R6c: 無行程無錯誤＝只有六項")
mod.clearCalls(); mod.resetMenus()

--------------------------------------------------------------------------------
-- N2: 別的 MOD 在我們之後整個覆寫 onRightMouseUp（不呼叫前手；Cheat Menu Reborn
--     的 OnGameStart 覆寫／DebugMenu 直接賦值）→ 開圖前只剩它的選單（症狀重現）、
--     ShowWorldMap 後重包一層 → 兩家選項都在、只 log 一次
--------------------------------------------------------------------------------
local ours = mod.ISWorldMap.onRightMouseUp
local function cmrLike(self, x, y)
    mod.calls[#mod.calls + 1] = "cmr-rmb"
    local c = mod.ISContextMenu.get(0, x + self:getAbsoluteX(), y + self:getAbsoluteY())
    c:addOption("Teleport Here")
    return true
end
mod.ISWorldMap.onRightMouseUp = cmrLike
r = wm:onRightMouseUp(5, 6)
assert(names(mod.menu(0)) == "Teleport Here", "N2: 覆寫後（未開圖）本 MOD 選項確實消失＝症狀重現")
mod.clearCalls(); mod.resetMenus()

mod.ISWorldMap.ShowWorldMap(0)
assert(mod.calls[1] == "orig-show:0", "N2: ShowWorldMap 須先跑前手")
assert(mod.ISWorldMap.onRightMouseUp ~= cmrLike and mod.ISWorldMap.onRightMouseUp ~= ours,
    "N2: 開圖後須重包成新的一層（劫持者當前手）")
mod.clearCalls()
r = wm:onRightMouseUp(5, 6)
assert(r == true, "N2: 重包後回 true")
assert(names(mod.menu(0)) == "Teleport Here," .. OURS,
    "N2: 劫持者選項保留＋本 MOD 六項（實得 " .. names(mod.menu(0)) .. "）")
assert(mod.gets() == 1, "N2: 劫持者建的選單不得被再 get")
local relogs = 0
for _, l in ipairs(mod.printed) do if l:find("re%-wrapping") then relogs = relogs + 1 end end
assert(relogs == 1, "N2: 重包須 log 一次（實得 " .. relogs .. "）")
mod.clearCalls(); mod.resetMenus()

-- 已是我們的函式再開圖＝不動（不多包一層）
local stableFn = mod.ISWorldMap.onRightMouseUp
mod.ISWorldMap.ShowWorldMap(0)
assert(mod.ISWorldMap.onRightMouseUp == stableFn, "N2: 最外層已是本 MOD 時開圖不得再包")
mod.clearCalls()

--------------------------------------------------------------------------------
-- N3: 別的 MOD 有禮貌地 wrap 我們（呼叫前手再加自己的項）、我們又在開圖重包到最外層
--     → 鏈裡兩層都是我們，本 MOD 選項只能出現一組（冪等）
--------------------------------------------------------------------------------
local inner = mod.ISWorldMap.onRightMouseUp
mod.ISWorldMap.onRightMouseUp = function(self, x, y)
    local res = inner(self, x, y)
    mod.menu(self.playerNum or 0):addOption("polite-mod")
    return res
end
mod.ISWorldMap.ShowWorldMap(0)
r = wm:onRightMouseUp(5, 6)
assert(countName(mod.menu(0), SET) == 1,
    "N3: 鏈裡兩層本 MOD 只得追加一組（實得 " .. countName(mod.menu(0), SET) .. "，" .. names(mod.menu(0)) .. "）")
assert(countName(mod.menu(0), "UI_MinidoracatMiniMap_TripAdd") == 1,
    "N3: 行程選項同樣不得重複")
assert(countName(mod.menu(0), "polite-mod") == 1, "N3: 有禮貌的 MOD 選項保留")
mod.clearCalls(); mod.resetMenus()

--------------------------------------------------------------------------------
-- N5: 兩邊都在開圖時重包＝互踢；重包次數封頂後放手（鏈不得無限長）
--------------------------------------------------------------------------------
local rewraps = 0
local function noop() return false end
for _ = 1, 20 do
    mod.ISWorldMap.onRightMouseUp = noop
    mod.ISWorldMap.ShowWorldMap(0)
    if mod.ISWorldMap.onRightMouseUp ~= noop then rewraps = rewraps + 1 end
end
assert(rewraps < 20, "N5: 重包須有上限（實得 20 次全部重包）")
assert(rewraps >= 3, "N5: 上限不得低到正常互動就放棄（實得 " .. rewraps .. "）")
mod.clearCalls(); mod.resetMenus()

--------------------------------------------------------------------------------
-- R8: prerender 加繪順序＋log-once（實例旗標）
--------------------------------------------------------------------------------
local wmP = mkWM(0)
wmP:prerender()
assert(table.concat(mod.calls, ",") == "orig-prerender,drawCoords,drawNav",
    "R8: 順序須為 original→座標列→導航（實得 " .. table.concat(mod.calls, ",") .. "）")
mod.clearCalls()

local before = #mod.printed
mod.setDrawFail(false, true) -- 導航持續拋錯：log-once、座標列不受影響
wmP:prerender()
wmP:prerender()
assert(#mod.printed == before + 1 and mod.printed[#mod.printed]:find("worldmap nav draw failed", 1, true),
    "R8: 導航繪製失敗須 log-once（實得 " .. (#mod.printed - before) .. " 筆）")
mod.setDrawFail(false, false)
mod.clearCalls()

--------------------------------------------------------------------------------
-- X1-X9: Extraction Mode（3785397275）滿版 overlay 右鍵相容
-- 症狀：它的 overlay 是 ISPanel 子類、蓋滿整張地圖，setWantMouseEvents(false)
-- （MapMarkers.lua:127-150）擋不住右鍵——原版 ISUIElement 的空右鍵回呼回 nil
-- （ISUIElement.lua:1555-1561），KahluaThread.pcallBoolean 把 nil 轉 null，
-- UIElement.java:1450-1595 的 right 分支見 null 直接 consume=true（不看
-- consumeMouseEvents 旗標）＝右鍵被吃掉，原版 debug 與本 MOD 的導航選單都叫不出來。
-- 相容層：開局時只對「被動且沿用原版空回呼」的那個 class 補明確的 false。
--------------------------------------------------------------------------------
local function passiveInstance(cls)
    cls.__index = cls -- 同原版 :new（setmetatable(object, self); self.__index = self）
    local o = setmetatable({}, cls)
    o:setWantMouseEvents(false) -- MapMarkers.lua:131
    return o
end

-- X1: 沒裝 Extraction Mode／裝了但還沒有那個 class → 開局不得出錯
ExtractionMode = nil
mod.fireGameStart()
ExtractionMode = { ClientState = {} }
mod.fireGameStart()

-- X2: 它的 class 在本檔之後才建（OnTick 才掛 overlay）→ 開局才接得上
local Overlay = mod.derive(mod.ISPanel)
ExtractionMode = { MapOverlay = Overlay }
local worldOverlay = passiveInstance(Overlay)
assert(worldOverlay:onRightMouseUp(1, 2) == nil, "X2: 接上之前維持原版行為（回 nil）")
mod.clearCalls()
mod.fireGameStart()

-- X3: 世界地圖與小地圖兩個實例共用同一 class；右鍵按下/放開都要明確回 false，
--     且原版回呼照跑（副作用不得被吞）
local miniOverlay = passiveInstance(Overlay)
mod.clearCalls()
assert(worldOverlay:onRightMouseDown(1, 2) == false, "X3: 世界地圖 overlay 右鍵按下須回 false")
assert(worldOverlay:onRightMouseUp(1, 2) == false, "X3: 世界地圖 overlay 右鍵放開須回 false")
assert(miniOverlay:onRightMouseDown(1, 2) == false, "X3: 小地圖 overlay 同 class 亦須回 false")
assert(miniOverlay:onRightMouseUp(1, 2) == false, "X3: 小地圖 overlay 同 class 亦須回 false")
assert(table.concat(mod.calls, ",") == "base-rdown,base-rup,base-rdown,base-rup",
    "X3: 原版回呼須照常各跑一次（實得 " .. table.concat(mod.calls, ",") .. "）")
mod.clearCalls()

-- X4: 真的要吃滑鼠的實例（wantMouseEvents=true）不得被改成 false
local activeOverlay = setmetatable({}, Overlay)
activeOverlay:setWantMouseEvents(true)
assert(activeOverlay:onRightMouseDown(1, 2) == nil, "X4: 想吃滑鼠時 down 須維持原版回傳")
assert(activeOverlay:onRightMouseUp(1, 2) == nil, "X4: 想吃滑鼠時 up 須維持原版回傳")
mod.clearCalls()

-- X5: 回主選單再開一局（重複 OnGameStart）不得再包一層：行為不變、原版回呼只跑一次，
--     且一次右鍵只問一次 isWantMouseEvents（每疊一層就多問一次＝存檔讀檔幾十次後
--     鏈會無限長）
mod.fireGameStart()
mod.fireGameStart()
mod.clearCalls()
assert(worldOverlay:onRightMouseUp(1, 2) == false, "X5: 重複開局後行為不變")
assert(table.concat(mod.calls, ",") == "base-rup",
    "X5: 原版回呼仍只得跑一次（實得 " .. table.concat(mod.calls, ",") .. "）")
local readsBefore = mod.wantReads()
assert(activeOverlay:onRightMouseUp(1, 2) == nil, "X5: 想吃滑鼠的實例仍維持原版回傳")
assert(mod.wantReads() - readsBefore == 1,
    "X5: 重複開局不得再疊一層（一次右鍵問了 " .. (mod.wantReads() - readsBefore)
    .. " 次 isWantMouseEvents）")

-- X6: 父類回呼有明確回傳／副作用一律保留，只有 nil 才補 false
local sideFx = {}
local vanillaRightUp = mod.ISUIElement.onRightMouseUp
mod.ISUIElement.onRightMouseUp = function(self, x, y)
    sideFx[#sideFx + 1] = "up:" .. x .. "," .. y
    return true
end
local cls6 = mod.derive(mod.ISPanel)
ExtractionMode = { MapOverlay = cls6 }
mod.fireGameStart()
assert(passiveInstance(cls6):onRightMouseUp(7, 8) == true, "X6: 父類回 true 須原樣保留")
assert(sideFx[#sideFx] == "up:7,8", "X6: 父類副作用與座標須照常發生（實得 "
    .. tostring(sideFx[#sideFx]) .. "）")
mod.ISUIElement.onRightMouseUp = function(self, x, y) return false end
local cls6b = mod.derive(mod.ISPanel)
ExtractionMode = { MapOverlay = cls6b }
mod.fireGameStart()
assert(passiveInstance(cls6b):onRightMouseUp(1, 2) == false, "X6: 父類回 false 亦原樣保留")
mod.ISUIElement.onRightMouseUp = vanillaRightUp

-- X7: class 自己有 handler（rawget 有值）不得被覆蓋；兩個方法各自判斷、互不牽連
local cls7 = mod.derive(mod.ISPanel)
local ownDowns = 0
function cls7:onRightMouseDown(x, y) ownDowns = ownDowns + 1 end
ExtractionMode = { MapOverlay = cls7 }
mod.fireGameStart()
local o7 = passiveInstance(cls7)
local ownDownRet = o7:onRightMouseDown(1, 2)
assert(ownDownRet == nil and ownDowns == 1,
    "X7: 自訂 handler 須原封不動（實得 回傳 " .. tostring(ownDownRet)
    .. "、呼叫 " .. ownDowns .. " 次）")
assert(o7:onRightMouseUp(1, 2) == false, "X7: 另一個方法仍要獨立補上 false")

-- X8: 繼承來的不是原版那份（父類或別的 MOD 自訂）→ 不碰，免得改壞人家的語意
local base8 = mod.derive(mod.ISPanel)
function base8:onRightMouseUp(x, y) end -- 自訂但同樣回 nil：只能靠身分判斷
local cls8 = mod.derive(base8)
ExtractionMode = { MapOverlay = cls8 }
mod.fireGameStart()
assert(passiveInstance(cls8):onRightMouseUp(1, 2) == nil,
    "X8: 非原版的繼承 handler 不得被包（語意不明）")

-- X8b: class 自己的 slot 明確指回原版那份函式（rawget 有值、身分又相同）＝它已經自行
--      設定過，nil 語意是刻意的 → 不得改寫（只看身分會誤判成「沒人動過」）
local cls8b = mod.derive(mod.ISPanel)
cls8b.onRightMouseUp = mod.ISUIElement.onRightMouseUp
cls8b.onRightMouseDown = mod.ISUIElement.onRightMouseDown
ExtractionMode = { MapOverlay = cls8b }
mod.fireGameStart()
local o8b = passiveInstance(cls8b)
assert(o8b:onRightMouseUp(1, 2) == nil, "X8b: class 自訂過的 slot 須保留原本的 nil 語意")
assert(o8b:onRightMouseDown(1, 2) == nil, "X8b: down 同理")

-- X9: 沒登記在 ExtractionMode 的面板（原版 UI／別的 MOD）不受影響
local otherPanel = mod.derive(mod.ISPanel)
ExtractionMode = { MapOverlay = Overlay }
mod.fireGameStart()
assert(passiveInstance(otherPanel):onRightMouseUp(1, 2) == nil,
    "X9: 不相關面板須維持原版行為")
assert(passiveInstance(otherPanel):onRightMouseDown(1, 2) == nil, "X9: down 同理")
ExtractionMode = nil

print("test_worldmap_nav: OK（R1-R9＋N1-N5＋X1-X9（含 X8b）：工具透傳/前手選單合併/自建/歸屬/殘留選單/"
    .. "行程選項閘/回呼分流/開圖重包/冪等/重包上限/加繪順序/log-once/"
    .. "Extraction Mode 被動 overlay 右鍵放行）")
