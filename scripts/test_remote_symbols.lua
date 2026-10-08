-- 其他玩家標記：主開關存 ModOptions、三個入口同步兩張地圖（主檔切片），
-- 作者清單的可見規則、「只看派系與安全屋成員」篩選與世界地圖右鍵「隱藏 X 的標記」（_RemoteSymbols.lua）。
-- 標準 Lua，不是 Kahlua；原版符號 API 是假物件，介面照 WorldMapSymbolsV2.java:72-149、401-406、475-513。
local CLIENT = arg and arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
local compile = loadstring or load
local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; io.write("FAIL " .. label .. "\n") end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected) .. ", actual=" .. tostring(actual) .. ")")
end
local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end

-- ── 一、作者清單與右鍵（_RemoteSymbols.lua 整檔載入）────────────────────────────
-- t: author, everyone, faction, safehouse, players（指名清單）, own（自己分享的）, private（沒分享）
local env = { mp = true, minimap = nil, factions = {}, houses = {}, opts = {}, sets = 0 }
local function symbol(t)
    local s = { t = t }
    function s:setVisible(v) t.visible = v; env.sets = env.sets + 1 end
    function s:isShared() return not t.private end
    function s:isAuthorLocalPlayer() return t.own == true end
    function s:getAuthor() return t.author end
    function s:isVisibleToEveryone() return t.everyone == true end
    function s:isVisibleToFaction() return t.faction == true end
    function s:isVisibleToSafehouse() return t.safehouse == true end
    function s:getVisibleToPlayerCount() return t.players and #t.players or 0 end
    function s:getVisibleToPlayerByIndex(i) return t.players[i + 1] end
    return s
end
local function symbolsApi(list)
    local api = { list = list, hidden = {}, hit = -1, calls = 0 }
    function api:getSymbolCount() return #self.list end
    function api:getSymbolByIndex(i) return self.list[i + 1] end
    function api:hitTest() return self.hit end
    function api:setAuthorHidden(author, hidden) self.hidden[author] = hidden or nil; self.calls = self.calls + 1 end
    function api:isAuthorHidden(author) return self.hidden[author] == true end
    return api
end
local function mapOf(api) return { mapAPI = { getSymbolsAPIv2 = function() return api end } } end

-- 派系／安全屋：getPlayers():size() 是篩選的「圈內人數」簽章
local function group()
    local g = { n = 1 }
    function g:getPlayers() local owner = self; return { size = function() return owner.n end } end
    return g
end
function isClient() return env.mp end
function getText(key, ...) return key .. ":" .. table.concat({ ... }, ",") end
function getSpecificPlayer(pn)
    if pn == 0 then return { getUsername = function() return "me" end } end
end
function getPlayerMiniMap(pn)
    if pn == 0 and env.minimap then return { inner = env.minimap } end
end
ISWorldMap_instance = nil
Faction = { getPlayerFaction = function(name) return env.factions[name] end }
SafeHouse = { hasSafehouse = function(name) return env.houses[name] end }
Events = { OnTick = { Add = function(fn) env.tick = fn end } }
env.applies, env.saves = 0, 0
MinidoracatMiniMapCore = { ready = true, getBoolOption = function(id, default)
    if env.opts[id] == nil then return default end
    return env.opts[id]
end, modOptions = {
    getOption = function(_, id) return { setValue = function(_, v) env.opts[id] = v end } end,
    apply = function() env.applies = env.applies + 1 end,
} }
PZAPI = { ModOptions = { save = function() env.saves = env.saves + 1 end } }
assert(compile(readFile(CLIENT .. "MinidoracatMiniMap_RemoteSymbols.lua"), "@_RemoteSymbols.lua"))()
local Core = MinidoracatMiniMapCore

local F1, F2, H1, H2 = group(), group(), group(), group()
env.factions = { me = F1, dave = F1, carol = F2 }
env.houses = { me = H1, erin = H1, frank = H2 }
local api = symbolsApi({
    symbol{ author = "bob", everyone = true },
    symbol{ author = "alice", everyone = true },
    symbol{ author = "alice", everyone = true },
    symbol{ author = "me", everyone = true, own = true },
    symbol{ author = "me", private = true },
    symbol{ author = "carol", faction = true },          -- 別的派系：看不到
    symbol{ author = "dave", faction = true },           -- 同派系
    symbol{ author = "erin", safehouse = true },         -- 同安全屋
    symbol{ author = "frank", safehouse = true },        -- 別的安全屋：看不到
    symbol{ author = "gina", players = { "x", "me" } },  -- 指名給我
    symbol{ author = "hank", players = { "x" } },        -- 沒指名我：看不到
})
env.minimap = mapOf(api)

local function keys(items)
    local out = {}
    for i = 1, #items do out[i] = items[i].key end
    return table.concat(out, ",")
end
local items = Core.remoteSymbolAuthors(0)
checkEq(keys(items), "alice,bob,dave,erin,gina", "R1 lists authors I can see, sorted")
checkEq(items[1].label, "UI_MinidoracatMiniMap_RemoteAuthorChip:alice,2", "R1 label carries the symbol count")
check(not keys(items):find("me", 1, true), "R2 own and private symbols are not listed")
check(not keys(items):find("carol", 1, true), "R3 a faction-only share from another faction leaks no author name")
check(not keys(items):find("frank", 1, true), "R4 a safehouse-only share from another safehouse is not listed")
check(not keys(items):find("hank", 1, true), "R5 a share naming other players only is not listed")

api.hidden.alice = true
checkEq(keys(Core.remoteSymbolAuthors(0)), "alice,bob,dave,erin,gina", "R6 hidden authors stay listed so they can come back")
check(Core.remoteSymbolHidden("alice") and not Core.remoteSymbolHidden("bob"), "R6 hidden state reads the vanilla list")
Core.setRemoteSymbolHidden("alice", false)
check(api.hidden.alice == nil, "R6 un-hiding writes the vanilla list")
Core.setRemoteSymbolHidden("bob", true)
check(api.hidden.bob == true, "R6 hiding writes the vanilla list")
api.hidden.bob = nil

env.minimap = nil
checkEq(#Core.remoteSymbolAuthors(0), 0, "R7 no open map: empty list")
ISWorldMap_instance = mapOf(api)
checkEq(keys(Core.remoteSymbolAuthors(0)), "alice,bob,dave,erin,gina", "R7 falls back to the world map without a mini-map")
ISWorldMap_instance = nil
env.minimap = mapOf(api)
env.mp = false
checkEq(#Core.remoteSymbolAuthors(0), 0, "R8 single player: empty list")
env.mp = true

-- 右鍵：只對游標下、別人分享的標記加一項；選了就把作者藏起來
local function menuAt(index)
    api.hit = index
    local context = { options = {} }
    function context:addOption(name, target, fn) self.options[#self.options + 1] = { name = name, target = target, fn = fn } end
    Core.remoteSymbolHideOption(context, mapOf(api), 10, 20)
    return context.options
end
checkEq(#menuAt(-1), 0, "H1 nothing under the cursor: no option")
checkEq(#menuAt(3), 0, "H2 own shared symbol: no option")
checkEq(#menuAt(4), 0, "H2 private symbol: no option")
local opts = menuAt(1)
checkEq(#opts, 1, "H3 another player's shared symbol: one option")
checkEq(opts[1] and opts[1].name, "UI_MinidoracatMiniMap_HideAuthor:alice", "H3 option names the author")
opts[1].fn(opts[1].target)
check(api.hidden.alice == true, "H3 choosing it hides the author")
api.hidden.alice = nil
env.mp = false
checkEq(#menuAt(1), 0, "H4 single player: no option")
env.mp = true

-- 只看派系與安全屋成員：本機可見旗標，圈外不畫、圈內照常；自己的與私人標記不碰
local function vis(i) return api.list[i].t.visible end
Core.remoteScopeApply()
checkEq(env.sets, 0, "T1 filter never turned on: no symbol is touched")
env.opts.RemoteTrustedOnly = true
Core.remoteScopeApply()
check(vis(1) == false and vis(2) == false and vis(10) == false, "T2 outsiders' shares are hidden (bob, alice, gina)")
check(vis(6) == false and vis(9) == false, "T2 shares from another faction or safehouse are hidden")
check(vis(7) == true and vis(8) == true, "T2 faction and safehouse members stay shown (dave, erin)")
check(vis(4) == nil and vis(5) == nil, "T2 own and private symbols are left alone")
local sets = env.sets
for _ = 1, 30 do env.tick() end
checkEq(env.sets, sets, "T3 nothing changed: the periodic check does not rescan")
api.list[#api.list + 1] = symbol{ author = "ivan", everyone = true }
for _ = 1, 29 do env.tick() end
checkEq(vis(12), nil, "T4 the check runs every 30 ticks")
env.tick()
checkEq(vis(12), false, "T4 a share that arrives later is hidden on the next check")
env.factions.bob, F1.n = F1, 2
for _ = 1, 30 do env.tick() end
check(vis(1) == true, "T5 an author who joins my faction comes back on the next check")
env.factions.bob, F1.n = nil, 1
env.opts.RemoteTrustedOnly = false
Core.remoteScopeApply()
check(vis(1) == true and vis(2) == true and vis(6) == true and vis(12) == true, "T6 filter off shows the outsiders again")
sets = env.sets
Core.remoteScopeApply()
checkEq(env.sets, sets, "T6 filter off: later checks do no work")
table.remove(api.list)
env.mp = false
env.opts.RemoteTrustedOnly = true
Core.remoteScopeApply()
checkEq(env.sets, sets, "T7 single player: nothing to filter")
env.mp = true

-- chip：亮＝畫得出來；開著篩選時點開圈外作者前，其他圈外作者先記進原版隱藏名單
local byKey = {}
for _, it in ipairs(Core.remoteSymbolAuthors(0)) do byKey[it.key] = it end
check(byKey.dave.trusted and byKey.erin.trusted, "C1 faction and safehouse members are marked trusted")
check(not byKey.alice.trusted and not byKey.gina.trusted, "C1 others, including a player who named me, are not")
check(not Core.remoteAuthorShown(byKey.alice) and Core.remoteAuthorShown(byKey.dave), "C2 filter on: outsiders off, members on")
env.opts.RemoteTrustedOnly = false
check(Core.remoteAuthorShown(byKey.alice), "C2 filter off: an outsider's chip is on")
api.hidden.dave = true
check(not Core.remoteAuthorShown(byKey.dave), "C2 a hidden member's chip is off")
api.hidden.dave = nil
Core.remoteHideOutsiders("alice", 0)
check(api.hidden.bob == true and api.hidden.gina == true, "C3 the other outsiders are written to the vanilla list")
check(api.hidden.alice == nil and api.hidden.dave == nil and api.hidden.erin == nil, "C3 the kept author and members are not")
local calls = api.calls
Core.setRemoteSymbolHidden("bob", true)
checkEq(api.calls, calls, "C4 hiding an author who is already hidden sends no packet")
Core.remoteShowAllAuthors(0)
check(next(api.hidden) == nil, "C5 show all puts every listed author back")
env.factions.gina = F1
check(Core.remoteAuthorTrusted("gina") and not byKey.gina.trusted, "C6 trust is looked up now, not from the list snapshot")
env.factions.gina = nil
check(not Core.remoteAuthorTrusted("gina"), "C6 leaving the faction makes the author an outsider again")
check(byKey.dave.tag == "faction" and byKey.erin.tag == "safehouse" and byKey.alice.tag == nil,
    "C7 the tag tells a faction member from a safehouse member")
checkEq(byKey.alice.count, 2, "C7 count carries the symbol count")

-- 切換規則（設定分類的作者按鈕與清單視窗共用）
env.opts.RemoteTrustedOnly = true
api.hidden = { alice = true }
local applies, saves = env.applies, env.saves
Core.remoteAuthorSet("alice", true, 0)
check(api.hidden.alice == nil, "M1 turning an outsider on shows that author")
check(api.hidden.bob == true and api.hidden.gina == true and api.hidden.dave == nil and api.hidden.erin == nil,
    "M1 the other outsiders stay hidden through the vanilla list; members are untouched")
check(env.opts.RemoteTrustedOnly == false and env.applies == applies + 1 and env.saves == saves + 1,
    "M1 the filter turns off, is applied and saved")
api.hidden = {}
env.opts.RemoteTrustedOnly = true
Core.remoteAuthorSet("dave", true, 0)
check(env.opts.RemoteTrustedOnly == true and next(api.hidden) == nil, "M2 turning a member on changes nothing else")
Core.remoteAuthorSet("bob", false, 0)
check(api.hidden.bob == true and env.opts.RemoteTrustedOnly == true, "M3 hiding an author keeps the filter")
api.hidden = {}
env.factions.gina = F1
Core.remoteAuthorSet("gina", true, 0)
check(env.opts.RemoteTrustedOnly == true and next(api.hidden) == nil, "M4 an author who just joined my faction counts as a member")
env.factions.gina = nil
Core.remoteAuthorSetMany({ byKey.alice, byKey.dave }, true)
check(env.opts.RemoteTrustedOnly == false and next(api.hidden) == nil,
    "M5 showing several including an outsider turns the filter off without hiding anyone")
env.opts.RemoteTrustedOnly = true
Core.remoteAuthorSetMany({ byKey.alice, byKey.bob }, false)
check(api.hidden.alice and api.hidden.bob and api.hidden.gina == nil and env.opts.RemoteTrustedOnly == true,
    "M6 hiding several touches only those and keeps the filter")
api.hidden = {}
env.opts.RemoteTrustedOnly = false
-- 作者清單簽章：新分享、圈內人數、本 MOD 改隱藏名單都會讓它變；什麼都沒變就不變
local sig0 = Core.remoteListSig(0)
checkEq(Core.remoteListSig(0), sig0, "L1 nothing changed: same signature")
api.list[#api.list + 1] = symbol{ author = "ivan", everyone = true }
local sig1 = Core.remoteListSig(0)
check(sig1 ~= sig0, "L2 a new share changes the signature")
table.remove(api.list)
F1.n = 3
check(Core.remoteListSig(0) ~= sig0, "L3 my faction's size changes the signature")
F1.n = 1
opts = menuAt(1)
opts[1].fn(opts[1].target)
check(api.hidden.alice == true and Core.remoteListSig(0) ~= sig0, "L4 hiding from the right-click menu changes the signature")
api.hidden.alice = nil
env.opts.RemoteTrustedOnly = nil

-- ── 二、主開關：存 ModOptions、三個入口同步兩張地圖（主檔切片）────────────────────────
local mainSource = readFile(CLIENT .. "MinidoracatMiniMap.lua")
local function section(name)
    return assert(mainSource:match("%-%- test:" .. name .. ":start\n(.-)\n%-%- test:" .. name .. ":end"), name)
end
local prefix = [=[
local client, values, saves = true, {}, 0
local function isClient() return client end
local function getBoolOption(id, default)
    if values[id] == nil then return default end
    return values[id]
end
local modOptions = { getOption = function(_, id) return { setValue = function(_, v) values[id] = v end } end }
local PZAPI = { ModOptions = { save = function() saves = saves + 1 end } }
local function log() end
local function applyMiniMapPyramids() end
local Core = {}
local function surface()
    local s = { values = {} }
    s.mapAPI = { setBoolean = function(_, n, v) s.values[n] = v end, getBoolean = function(_, n) return s.values[n] end }
    return s
end
local minis = {}
local function getPlayerMiniMap(pn) return minis[pn] and { inner = minis[pn] } or nil end
local ISWorldMap_instance
local ISWorldMap = { initDataAndStyle = function() end }
local WorldMapOptions = { onTickBox = function(_, _, selected, option) option:setValue(selected) end }
local ISMiniMapOptionsPanel = { onTickBox = function(self, _, selected, option) option:setValue(selected) end }
]=]
local suffix = [=[
return {
    values = values, saves = function() return saves end, Core = Core,
    setClient = function(v) client = v end,
    mini = function(pn) minis[pn] = surface(); return minis[pn] end,
    world = function()
        local wm = surface()
        setmetatable(wm, { __index = ISWorldMap })
        ISWorldMap_instance = wm
        wm:initDataAndStyle()
        return wm
    end,
    apply = applyToggleOptions,
    worldOptions = WorldMapOptions, gearPanel = ISMiniMapOptionsPanel,
}
]=]
local M = assert(compile(prefix .. section("map%-toggles") .. "\n" .. section("remote%-symbols%-sync") .. "\n"
    .. section("worldmap%-init") .. "\n" .. section("remote%-symbols%-wm") .. "\n" .. section("panel%-sync")
    .. "\n" .. suffix, "remote-symbols-main"))()

-- 預設＝顯示（跟原版一樣，更新後沒有人看到變化）
local mini = M.mini(0)
M.apply(mini.mapAPI)
checkEq(mini.values.RemoteSymbols, true, "S1 default keeps other players' symbols shown")
-- 存的值在下次登入套回兩張地圖（原版兩個面板都不存，ISMiniMap.lua:605-616、ISWorldMap.lua:1385-1404）
M.values.RemoteSymbols = false
M.apply(mini.mapAPI)
local world = M.world()
checkEq(mini.values.RemoteSymbols, false, "S2 a new mini-map applies the saved value")
checkEq(world.values.RemoteSymbols, false, "S2 the world map applies the saved value when it opens")

-- 小地圖齒輪：存檔並帶動世界地圖
local function option(name) return { getName = function() return name end,
    setValue = function(_, v) mini.values[name] = v end } end
local saves = M.saves()
M.gearPanel.onTickBox({ map = mini }, 1, true, option("RemoteSymbols"))
checkEq(M.values.RemoteSymbols, true, "S3 gear panel tick is saved to ModOptions")
check(M.saves() == saves + 1, "S3 gear panel tick writes ModOptions.ini")
checkEq(world.values.RemoteSymbols, true, "S3 gear panel tick reaches the world map")

-- 世界地圖選項：存檔並帶動小地圖
local wmOption = { getName = function() return "RemoteSymbols" end,
    setValue = function(_, v) world.values.RemoteSymbols = v end }
M.worldOptions.onTickBox({}, 1, false, wmOption)
checkEq(M.values.RemoteSymbols, false, "S4 world map options tick is saved to ModOptions")
checkEq(mini.values.RemoteSymbols, false, "S4 world map options tick reaches the mini-map")
-- 世界地圖選項的其他勾選不碰這個值
local other = { getName = function() return "Isometric" end, setValue = function() end }
M.worldOptions.onTickBox({}, 1, true, other)
checkEq(M.values.RemoteSymbols, false, "S5 other world map options leave the saved value alone")

-- 設定視窗／ESC 頁：apply 路徑同步兩張地圖
M.values.RemoteSymbols = true
M.Core.syncRemoteSymbols(true)
check(mini.values.RemoteSymbols == true and world.values.RemoteSymbols == true, "S6 sync reaches both maps")

-- 單機：不碰原版值
M.setClient(false)
local sp = M.mini(1)
M.apply(sp.mapAPI)
checkEq(sp.values.RemoteSymbols, nil, "S7 single player leaves the vanilla option alone")
M.Core.syncRemoteSymbols(false)
checkEq(world.values.RemoteSymbols, true, "S7 single player sync is a no-op")

print(string.format("test_remote_symbols: %d assertions, %d failures", assertions, failures))
if failures > 0 then os.exit(1) end
