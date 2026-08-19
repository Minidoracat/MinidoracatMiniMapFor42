-- 世界地圖導航/座標（_WorldMapNav.lua）離線回歸測試。
-- 仿 test_ghost_gate.lua：抽標記區段→補最小 stub→組裝離線跑。
-- 核心不變量：
--   (1) symbolsUI 工具作用中（currentTool / down 時快照的 ignoreRightMouseUp）
--       右鍵＝取消工具，原樣透傳、不疊選單；
--   (2) 原版 handled（debug/admin 已建 player-0 選單）→ getPlayerContextMenu(0)
--       追加同一單例；一般玩家 → ISContextMenu.get(self.playerNum, abs 座標) 自建
--       ——分割畫面歸屬用 playerNum、不硬編 0；
--   (3) 選項組裝：SetTarget/CopyHere 恆有；ClearTarget 依 navGetTarget；ShareTarget
--       再疊 isClient＋Faction＋AllowNavShare 三閘；
--   (4) prerender 加繪：先座標列後導航；各自 pcall＋實例旗標 log-once。
-- 用法：lua scripts/test_worldmap_nav.lua
local navPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_WorldMapNav.lua"

local file = assert(io.open(navPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local rightBody = assert(source:match(
    "%-%- test:wm%-rightclick:start\n(.-)\n%-%- test:wm%-rightclick:end"),
    "找不到 wm-rightclick 測試區段")
local preBody = assert(source:match(
    "%-%- test:wm%-prerender:start\n(.-)\n%-%- test:wm%-prerender:end"),
    "找不到 wm-prerender 測試區段")

local compile = loadstring or load

--------------------------------------------------------------------------------
-- stub 環境：ISWorldMap 原版行為可注入（handledResult）；選單雙路可觀測
--------------------------------------------------------------------------------
local env = [=[
local printed = {}
local function print(msg) printed[#printed + 1] = tostring(msg) end
local calls = {}                 -- 依序記錄可觀測事件
local handledResult = false      -- 原版 onRightMouseUp 回傳（true＝debug/admin 已建選單）
local playerObjs = {}            -- [pn] = 假玩家物件
local clientMode = false
local factionOf = nil            -- Faction.getPlayerFaction 回傳
local sandboxAllow = true
local navTarget = nil            -- Core.navGetTarget 回傳

local function mkContext(tag)
    local c = { tag = tag, options = {} }
    function c:addOption(text, target, fn, a, b)
        self.options[#self.options + 1] = { text = text, target = target, fn = fn, a = a, b = b }
    end
    return c
end
local appendedMenu = mkContext("appended") -- getPlayerContextMenu(0) 單例
local builtMenu = nil                      -- ISContextMenu.get 新建

local ISWorldMap = {}
function ISWorldMap.onRightMouseUp(self, x, y)
    calls[#calls + 1] = "orig-rmb"
    return handledResult
end
function ISWorldMap.prerender(self)
    calls[#calls + 1] = "orig-prerender"
end

local function getSpecificPlayer(pn) return playerObjs[pn] end
local function getPlayerContextMenu(pn)
    calls[#calls + 1] = "getPlayerContextMenu:" .. tostring(pn)
    return appendedMenu
end
local ISContextMenu = {}
function ISContextMenu.get(pn, x, y)
    calls[#calls + 1] = string.format("ISContextMenu.get:%s:%s:%s", tostring(pn), tostring(x), tostring(y))
    builtMenu = mkContext("built")
    return builtMenu
end
local function getText(key, arg1)
    if arg1 then return key .. "|" .. arg1 end
    return key
end
local function isClient() return clientMode end
local Faction = { getPlayerFaction = function(p) return factionOf end }

local Core = { ready = true }
Core.navGetTarget = function(pn) return navTarget end
Core.navSetTarget = function(pn, wx, wy) calls[#calls + 1] = string.format("navSet:%d:%s:%s", pn, tostring(wx), tostring(wy)) end
Core.navClearTarget = function(pn) calls[#calls + 1] = "navClear:" .. pn end
Core.navShareTarget = function(pn) calls[#calls + 1] = "navShare:" .. pn end
Core.copyCoordsText = function(el, text) calls[#calls + 1] = "copy:" .. text end
Core.sandboxGate = function(name, dflt) return sandboxAllow end
local drawCoordsFail, drawNavFail = false, false
Core.drawPlayerCoords = function(el)
    calls[#calls + 1] = "drawCoords"
    if drawCoordsFail then error("injected coords failure") end
end
Core.drawNavTargets = function(el)
    calls[#calls + 1] = "drawNav"
    if drawNavFail then error("injected nav failure") end
end

-- 回呼方法（主檔/本檔於載入期定義；此處以等價 stub 供 addOption target 呼叫）
function ISWorldMap:onMinidoracatSetTarget(wx, wy) Core.navSetTarget(self.playerNum or 0, wx, wy) end
function ISWorldMap:onMinidoracatClearTarget() Core.navClearTarget(self.playerNum or 0) end
function ISWorldMap:onMinidoracatShareTarget() Core.navShareTarget(self.playerNum or 0) end
function ISWorldMap:onMinidoracatCopyCoords(wx, wy) Core.copyCoordsText(self, string.format("%d,%d,0", wx, wy)) end
]=]

local suffix = [=[
return {
    ISWorldMap = ISWorldMap,
    calls = calls,
    printed = printed,
    clearCalls = function() for i = #calls, 1, -1 do calls[i] = nil end end,
    appendedMenu = appendedMenu,
    builtMenu = function() return builtMenu end,
    resetBuilt = function() builtMenu = nil end,
    setHandled = function(v) handledResult = v end,
    setPlayer = function(pn, p) playerObjs[pn] = p end,
    setClient = function(v) clientMode = v end,
    setFaction = function(v) factionOf = v end,
    setSandbox = function(v) sandboxAllow = v end,
    setNavTarget = function(v) navTarget = v end,
    setDrawFail = function(coords, nav) drawCoordsFail = coords; drawNavFail = nav end,
}
]=]

local mod = assert(compile(env .. "\n" .. rightBody .. "\n" .. preBody .. "\n" .. suffix,
    "wm-nav"))()

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

--------------------------------------------------------------------------------
-- R1/R2: symbols 工具作用中／down 快照旗標＝原樣透傳，不建選單
--------------------------------------------------------------------------------
mod.setPlayer(0, { name = "p0" })
local wm = mkWM(0)
wm.symbolsUI.currentTool = {}
mod.setHandled(true)
local r = wm:onRightMouseUp(5, 6)
assert(r == true, "R1: 工具作用中須原樣回傳 original 結果")
assert(mod.calls[1] == "orig-rmb" and #mod.calls == 1, "R1: 只跑 original、不得建選單")
mod.clearCalls()

wm.symbolsUI.currentTool = nil
wm.symbolsUI.ignoreRightMouseUp = true
r = wm:onRightMouseUp(5, 6)
assert(#mod.calls == 1 and mod.calls[1] == "orig-rmb", "R2: down 快照旗標同樣透傳")
mod.clearCalls()
wm.symbolsUI.ignoreRightMouseUp = false

--------------------------------------------------------------------------------
-- R3: debug/admin（original 回 true）→ 追加 player-0 單例；不自建
--------------------------------------------------------------------------------
mod.setHandled(true)
mod.setNavTarget(nil)
r = wm:onRightMouseUp(5, 6)
assert(r == true, "R3: 追加路徑回 true")
assert(mod.calls[2] == "getPlayerContextMenu:0", "R3: 須追加原版 player-0 單例")
assert(mod.builtMenu() == nil, "R3: 不得另建選單（會 clear 掉 debug 選項）")
assert(#mod.appendedMenu.options == 2, "R3: 無目標時追加 SetTarget+CopyHere 兩項")
assert(mod.appendedMenu.options[1].text == "UI_MinidoracatMiniMap_SetTarget", "R3: 首項 SetTarget")
mod.clearCalls()

--------------------------------------------------------------------------------
-- R4: 一般玩家（original 回 false）→ ISContextMenu.get(pn, abs 座標) 自建；
--     分割畫面 pn=1 歸屬正確
--------------------------------------------------------------------------------
mod.setPlayer(1, { name = "p1" })
local wm1 = mkWM(1)
mod.setHandled(false)
r = wm1:onRightMouseUp(5, 6)
assert(r == true, "R4: 自建路徑回 true（已消費）")
assert(mod.calls[2] == "ISContextMenu.get:1:105:206",
    "R4: 須以 self.playerNum=1 與絕對座標自建（實得 " .. tostring(mod.calls[2]) .. "）")
local menu = mod.builtMenu()
assert(menu and #menu.options == 2, "R4: 自建選單兩項")
-- R7: CopyHere 文字帶 floor 座標；回呼參數同值
assert(menu.options[2].text == "UI_MinidoracatMiniMap_CopyHere|12, 34, 0",
    "R7: CopyHere 文字須帶 floor 座標（實得 " .. tostring(menu.options[2].text) .. "）")
assert(menu.options[2].a == 12 and menu.options[2].b == 34, "R7: 回呼參數須為 floor 後座標")
-- R9: 回呼綁定走 playerNum
menu.options[1].fn(menu.options[1].target, menu.options[1].a, menu.options[1].b)
assert(mod.calls[#mod.calls] == "navSet:1:12.7:34.2", "R9: SetTarget 回呼須以 pn=1 寫入原始世界座標")
mod.clearCalls()
mod.resetBuilt()

--------------------------------------------------------------------------------
-- R5: playerObj nil（debug 主選單地圖）→ 回傳 handled、不建選單
--------------------------------------------------------------------------------
mod.setPlayer(1, nil)
r = wm1:onRightMouseUp(5, 6)
assert(r == false, "R5: 無玩家回傳 original 結果")
assert(#mod.calls == 1 and mod.builtMenu() == nil, "R5: 無玩家不得建選單")
mod.clearCalls()
mod.setPlayer(1, { name = "p1" })

--------------------------------------------------------------------------------
-- R6: 有目標 → ClearTarget；Share 三閘（isClient＋Faction＋沙盒）
--------------------------------------------------------------------------------
mod.setNavTarget({ x = 1, y = 2 })
mod.setClient(true)
mod.setFaction({})
mod.setSandbox(true)
r = wm1:onRightMouseUp(5, 6)
local m6 = mod.builtMenu()
assert(#m6.options == 4, "R6: 目標＋陣營＋沙盒允許＝4 項（實得 " .. #m6.options .. "）")
assert(m6.options[3].text == "UI_MinidoracatMiniMap_ClearTarget", "R6: 第三項 ClearTarget")
assert(m6.options[4].text == "UI_MinidoracatMiniMap_ShareTarget", "R6: 第四項 ShareTarget")
mod.clearCalls()
mod.resetBuilt()

mod.setSandbox(false) -- 伺服器禁分享：Share 消失、Clear 保留
r = wm1:onRightMouseUp(5, 6)
assert(#mod.builtMenu().options == 3, "R6: 沙盒禁分享＝3 項（無 Share）")
mod.clearCalls()
mod.resetBuilt()
mod.setClient(false) -- 單機：無 Share
mod.setSandbox(true)
r = wm1:onRightMouseUp(5, 6)
assert(#mod.builtMenu().options == 3, "R6: 單機＝3 項（無 Share）")
mod.clearCalls()
mod.resetBuilt()
mod.setNavTarget(nil)

--------------------------------------------------------------------------------
-- R8: prerender 加繪順序＋log-once（實例旗標）
--------------------------------------------------------------------------------
local wmP = mkWM(0)
wmP:prerender()
assert(table.concat(mod.calls, ",") == "orig-prerender,drawCoords,drawNav",
    "R8: 順序須為 original→座標列→導航（實得 " .. table.concat(mod.calls, ",") .. "）")
mod.clearCalls()

mod.setDrawFail(false, true) -- 導航持續拋錯：log-once、座標列不受影響
wmP:prerender()
wmP:prerender()
assert(#mod.printed == 1 and mod.printed[1]:find("worldmap nav draw failed", 1, true),
    "R8: 導航繪製失敗須 log-once（實得 " .. #mod.printed .. " 筆）")
mod.setDrawFail(false, false)
mod.clearCalls()

print("test_worldmap_nav: OK（R1-R9：工具透傳/追加/自建/歸屬/選項閘/回呼/加繪順序/log-once）")
