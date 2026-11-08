-- 殭屍點裡的 NPC 換色（_Dots.lua 的 npc-tags、scan-listener、zombie-sampling、zombie-dots-draw 四段真程式＋真的
-- ADOTS_PALETTE／adotsColor）：registerNpcTag 登記規則、取樣只對選進來的點讀 getVariableBoolean、第一個命中的 tag
-- 決定顏色、NPC 排在尾端畫、勾選／伺服器閘門關＝殭屍色且不讀變數、不持有殭屍物件、別層變淡、定時掃描、每 tag 顏色。
-- 用法：lua scripts/test_npc_dots.lua [_Dots.lua]
local path = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Dots.lua"
local file = assert(io.open(path, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local compile = loadstring or load

local function section(name)
    local esc = name:gsub("%-", "%%-")
    return assert(source:match("%-%- test:" .. esc .. ":start\n(.-)\n%-%- test:" .. esc .. ":end"),
        "找不到 " .. name .. " 測試區段")
end
local function extractFn(name)
    return assert(source:match("\n(local function " .. name .. "%(.-\nend)\n"), "找不到 " .. name)
end

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected) .. ", actual=" .. tostring(actual) .. ")")
end

local prelude = [=[
local now, opts, gates, combos, players, zombies, logs, floorMode, scanSec = 1000, {}, {}, {}, {}, {}, {}, 1, 0
local listFail
local function log(msg) logs[#logs + 1] = msg end
local Core = { policy = {
    readNumber = function(name, default) if name == "ZombieScanInterval" then return scanSec end return default end,
    tacticalActive = function() return false end,
} }
Core.floorMarksMode = function() return floorMode end
MinidoracatMiniMapAPI = {}
local function getTimestampMs() return now end
local function displayDist() return nil end
local function getComboIndex(id, default)
    local v = combos[id]
    if type(v) ~= "number" then return default end
    return v
end
local function getSliderValue(_, default) return default end
-- 記下每次問 AllowNpcDotColor 的 pn（戰術旁路靠它，_Policy.lua gate）；nil 記成字串 "nil"
local npcGatePns = {}
local function sandboxGate(name, default, pn)
    if name == "AllowNpcDotColor" then npcGatePns[#npcGatePns + 1] = pn == nil and "nil" or pn end
    if gates[name] == nil then return default end
    return gates[name]
end
local function getBoolOption(id, default)
    if opts[id] == nil then return default end
    return opts[id]
end
local function visibleWorldAABB() return -1000, 1000, -1000, 1000 end
-- 投影：視野中心 (0,0) 落在元件 (500,500)，一格一像素
local function deriveAffine() return 500, 500, 1, 0, 0, 1 end
local function getSpecificPlayer(pn) return players[pn] end
local function javaList(values)
    return { size = function() return #values end,
        get = function(_, i)
            if listFail and i >= listFail then error("IndexOutOfBounds") end
            return values[i + 1]
        end }
end
local cell = { getZombieList = function() return javaList(zombies) end }
local function getCell() return cell end
local ZDOTS_INTERVAL_MS, ZDOTS_MAX, ZDOTS_SCAN_MAX, SCAN_ALL = 300, 200, 4000, 1e9
local ZDOTS_NEAR, ZDOTS_MID, ZDOTS_MAXES = 30, 80, { 100, 200, 400, 800 }
local ZDOTS_COLORS, ZDOTS_EDGE_A, ZDOTS_FLOOR_A = { { 1.0, 0.62, 0.05 } }, 0.8, 0.3
local function zdotsStateFor(inner)
    if not inner._state then
        inner._state = { near = {}, mid = {}, far = {}, dots = {}, count = 0, nextMs = 0 }
    end
    return inner._state
end
]=]
local suffix = [=[
return {
    api = MinidoracatMiniMapAPI,
    npc = npc,
    palette = ADOTS_PALETTE,
    draw = function(el) drawZombieDotsOn(el, "ZombieDots", "mini") end,
    sample = function(el) return sampleZombieDots(el, nil, "ZombieScanInterval") end,
    setNow = function(v) now = v end,
    setZombies = function(v) zombies = v end,
    setFloorMode = function(v) floorMode = v end,
    setScanSec = function(v) scanSec = v end,
    setListFail = function(v) listFail = v end,
    opts = opts, gates = gates, combos = combos, players = players, logs = logs,
    npcGatePns = function() local out = npcGatePns; npcGatePns = {}; return out end,
    zombieColor = ZDOTS_COLORS[1], floorA = ZDOTS_FLOOR_A,
}
]=]
local chunk = assert(compile(prelude
    .. assert(source:match("\n(local ADOTS_PALETTE = {.-\n})\n"), "找不到 ADOTS_PALETTE") .. "\n"
    .. extractFn("adotsColor") .. "\n"
    .. section("scan-listener") .. "\n" .. section("npc-tags") .. "\n" .. section("zombie-sampling") .. "\n"
    .. section("zombie-dots-draw") .. "\n" .. suffix))
local h = chunk()
h.opts.ZombieDots = true
h.players[0] = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }
local api, npc, P = h.api, h.npc, h.palette

-- 殭屍（x 當編號）：vars＝動畫變數；getVariableBoolean 是計數的間諜
local reads = 0
local function zombie(x, y, z, vars)
    return { getX = function() return x end, getY = function() return y end, getZ = function() return z or 0 end,
        getVariableBoolean = function(_, name) reads = reads + 1; return vars ~= nil and vars[name] == true end }
end
local function element(pn)
    local el = { playerNum = pn or 0, mapAPI = {}, width = 3000, height = 3000, bodies = {} }
    function el:drawRect(x, y, w, hh, a, r, g, b)
        if not (r == 0 and g == 0 and b == 0) then self.bodies[#self.bodies + 1] = { x = x + 1 - 500, a = a, c = { r, g, b } } end
    end
    return el
end
-- 一幀：回傳本體點（依畫的順序）與「x → 顏色」
local function frame(el)
    el.bodies = {}
    h.draw(el)
    local byX = {}
    for _, b in ipairs(el.bodies) do byX[b.x] = b end
    return el.bodies, byX
end
local function same(c, want) return c[1] == want[1] and c[2] == want[2] and c[3] == want[3] end
local function resample(el) h.setNow(el._state and el._state.nextMs or 0) end
local function poolRefs(el)
    local n = 0
    for _, pool in ipairs({ el._state.near, el._state.mid, el._state.far }) do
        for _, d in ipairs(pool) do if d.o ~= nil then n = n + 1 end end
    end
    return n
end
local ZC = h.zombieColor

-- N1 零登記：全部殭屍色，getVariableBoolean 0 次，桶裡不存殭屍物件
h.setZombies({ zombie(1, 0, 0, { Bandit = true }), zombie(2, 0, 0), zombie(3, 0, 0, { ALifeActor = true }) })
local el = element()
local bodies, byX = frame(el)
check(#bodies == 3 and same(byX[1].c, ZC) and same(byX[3].c, ZC), "N1 no registration: every dot in zombie colour")
checkEq(reads, 0, "N1 no registration: getVariableBoolean never called")
checkEq(poolRefs(el), 0, "N1 no registration: no zombie object kept")

-- N8 登記規則
checkEq(api.npcApiVersion, 1, "N8 npcApiVersion is 1")
local bad = {
    { nil, "bandits", "UI_B", "Bandit" }, { "", "bandits", "UI_B", "Bandit" }, { "   ", "bandits", "UI_B", "Bandit" },
    { "Compat", "Bandits", "UI_B", "Bandit" }, { "Compat", "1bandits", "UI_B", "Bandit" },
    { "Compat", "band-its", "UI_B", "Bandit" }, { "Compat", "", "UI_B", "Bandit" },
    { "Compat", string.rep("a", 25), "UI_B", "Bandit" }, { "Compat", "bandits", "", "Bandit" },
    { "Compat", "bandits", "UI_B", nil }, { "Compat", "bandits", "UI_B", 5 },
    { "Compat", "bandits", "UI_\195\169", "Bandit" }, { "Comp\tat", "bandits", "UI_B", "Bandit" },
}
for i, a in ipairs(bad) do
    checkEq(api.registerNpcTag(a[1], a[2], a[3], a[4]), false, "N8 bad arguments refused #" .. i)
end
checkEq(npc.n, 0, "N8 refused registrations add nothing")
checkEq(api.registerNpcTag("Compat", string.rep("a", 24), "UI_A", "A"), true, "N8 a 24-char tag is accepted")
-- 重新開一份乾淨的登記表（上一行佔了第 1 格；預設色依登記順序要從頭驗）
h = chunk()
h.opts.ZombieDots = true
h.players[0] = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }
api, npc = h.api, h.npc
checkEq(api.registerNpcTag("Compat", "bandits", "UI_B", "Bandit"), true, "N8 first tag registers")
checkEq(api.registerNpcTag("Compat", "bandits", "UI_B", "Bandit"), true, "N8 same fields again = idempotent true")
checkEq(npc.n, 1, "N8 idempotent registration does not add a second entry")
local logs0 = #h.logs
checkEq(api.registerNpcTag("Other", "bandits", "UI_B", "Bandit"), false, "N8 tag taken by another owner refused")
checkEq(api.registerNpcTag("Other", "bandits", "UI_B", "Bandit"), false, "N8 refused again")
checkEq(#h.logs, logs0 + 1, "N8 the taken tag logs once")
checkEq(api.registerNpcTag("Compat", "bandits", "UI_B", "OtherVar"), false, "N8 same tag with other fields refused")
checkEq(npc.tags[1].color, 4, "DC1 first tag defaults to palette 4 (sky blue)")
checkEq(npc.tags[1].opt, "NpcDotColor_bandits", "DC1 option id is NpcDotColor_<tag>")

-- N2 一個 tag：命中的點用該 tag 的顏色（預設天藍），而且排在最後畫
reads = 0
h.setZombies({ zombie(1, 0, 0, { Bandit = true }), zombie(2, 0, 0), zombie(3, 0, 0), zombie(4, 0, 0, { Bandit = true }) })
el = element()
bodies, byX = frame(el)
check(same(byX[1].c, P[4]) and same(byX[4].c, P[4]), "N2 tagged zombies drawn in the tag colour (sky blue)")
check(same(byX[2].c, ZC) and same(byX[3].c, ZC), "N2 other zombies keep the zombie colour")
check(same(bodies[3].c, P[4]) and same(bodies[4].c, P[4]) and same(bodies[1].c, ZC) and same(bodies[2].c, ZC),
    "N2 NPC dots are drawn after the zombie dots")
checkEq(reads, 4, "N2 one getVariableBoolean per selected dot per tag")
-- N7 取樣後所有桶項目都不持有殭屍物件（含中途失敗的那輪）
checkEq(poolRefs(el), 0, "N7 no bucket keeps a zombie object after sampling")
h.setListFail(2)
resample(el)
frame(el)
checkEq(el._state.count, 0, "N7 a failing sample draws nothing this round")
checkEq(poolRefs(el), 0, "N7 a sample that fails midway still drops the zombie objects")
h.setListFail(nil)
resample(el)
frame(el)

-- 每 tag 顏色：換這個 tag 的下拉
h.combos.NpcDotColor_bandits = 8
bodies, byX = frame(el)
check(same(byX[1].c, P[8]), "PC1 the per-tag colour option recolours that tag next frame")
h.combos.NpcDotColor_bandits = nil

-- N4 勾選關：殭屍色、不重新取樣、不讀變數
local nextMs = el._state.nextMs
reads = 0
h.opts.NpcDotTint = false
bodies, byX = frame(el)
check(same(byX[1].c, ZC) and same(byX[4].c, ZC), "N4 tick off: NPCs drawn in zombie colour")
checkEq(el._state.nextMs, nextMs, "N4 toggling the tick does not force a resample")
resample(el)
frame(el)
checkEq(reads, 0, "N4 tick off: the next sample reads no variable")
checkEq(poolRefs(el), 0, "N4 tick off: no zombie object kept")
h.opts.NpcDotTint = nil
resample(el)
bodies, byX = frame(el)
check(same(byX[1].c, P[4]), "N4 tick back on: colours return after the next sample")

-- N5 伺服器關：殭屍色，下一次取樣讀 0 次
h.gates.AllowNpcDotColor = false
bodies, byX = frame(el)
check(same(byX[1].c, ZC), "N5 server off: NPCs drawn in zombie colour at once")
reads = 0
resample(el)
frame(el)
checkEq(reads, 0, "N5 server off: the next sample reads no variable")
h.gates.AllowNpcDotColor = nil
resample(el)
frame(el)
-- N5b 閘門按這張地圖的玩家問（戰術旁路逐 slot）：分割畫面第二位（playerNum 1）的表面，取樣與繪製都把 1 傳進閘門
h.gates.AllowNpcDotColor = false
local el1 = element(1)
h.npcGatePns()
frame(el1) -- 新表面：先取樣、再畫
local pns = h.npcGatePns()
check(#pns == 2 and pns[1] == 1 and pns[2] == 1,
    "N5b sampling and drawing ask the server gate for the map owner's slot (" .. table.concat(pns, ",") .. ")")
frame(el1) -- 節流窗內：只畫
pns = h.npcGatePns()
check(#pns == 1 and pns[1] == 1, "N5b a frame without resampling asks once, for the owner's slot (" .. table.concat(pns, ",") .. ")")
h.gates.AllowNpcDotColor = nil

-- N6 別層變淡也套在 NPC 點上
h.setFloorMode(2)
h.setZombies({ zombie(1, 0, 1, { Bandit = true }), zombie(2, 0, 0, { Bandit = true }) })
resample(el)
bodies, byX = frame(el)
check(same(byX[1].c, P[4]) and byX[1].a == h.floorA and byX[2].a == 1, "N6 an NPC on another floor fades like zombies")
h.setFloorMode(1)

-- N9 多個 tag：第一個命中的 tag（登記順序）決定顏色；預設色依登記順序 天藍、綠、紫紅、白
checkEq(api.registerNpcTag("Compat", "alife", "UI_A", "ALifeActor"), true, "N9 second tag registers")
checkEq(api.registerNpcTag("X", "third", "UI_X", "X3"), true, "DC2 third tag registers")
checkEq(api.registerNpcTag("X", "fourth", "UI_X", "X4"), true, "DC2 fourth tag registers")
check(npc.tags[2].color == 2 and npc.tags[3].color == 6 and npc.tags[4].color == 1,
    "DC2 defaults follow registration order: green, magenta, white")
logs0 = #h.logs
checkEq(api.registerNpcTag("X", "fifth", "UI_X", "X5"), false, "N8 a fifth tag is refused")
api.registerNpcTag("X", "fifth", "UI_X", "X5")
checkEq(#h.logs, logs0 + 1, "N8 the full registry logs once")
h.setZombies({ zombie(1, 0, 0, { Bandit = true, ALifeActor = true }), zombie(2, 0, 0, { ALifeActor = true }),
    zombie(3, 0, 0, { X4 = true }), zombie(4, 0, 0) })
resample(el)
reads = 0
bodies, byX = frame(el)
check(same(byX[1].c, P[4]), "N9 a zombie with both variables takes the first registered tag")
check(same(byX[2].c, P[2]) and same(byX[3].c, P[1]) and same(byX[4].c, ZC), "N9 each tag draws its own colour")
checkEq(reads, 1 + 2 + 4 + 4, "N9 reads stop at the first hit (1+2+4+4)")
checkEq(el._state.dots[1].npc, nil, "N9 the plain zombie is moved to the front")

-- N3 300 隻、上限 100：讀變數次數 ≤ 100 × tag 數
local many = {}
for i = 1, 300 do many[i] = zombie(i % 50, math.floor(i / 50), 0, (i % 3 == 0) and { ALifeActor = true } or nil) end
h.setZombies(many)
h.combos.ZombieDotMax = 1 -- 100
resample(el)
reads = 0
frame(el)
checkEq(el._state.count, 100, "N3 the sample keeps the 100-dot limit")
check(reads <= 100 * npc.n, "N3 at most 100 x tags variable reads (" .. reads .. ")")
local seenNpc, orderOk = false, true
for i = 1, el._state.count do
    if el._state.dots[i].npc then seenNpc = true elseif seenNpc then orderOk = false end
end
check(seenNpc and orderOk, "N3 every NPC sits after every zombie in the sample")
h.combos.ZombieDotMax = nil

-- N10 定時掃描：旗標跟著那次掃描，兩次掃描之間變數改了也不變
h.setScanSec(5)
local vars = { Bandit = true }
h.setZombies({ zombie(1, 0, 0, vars) })
h.setNow(1000000)
local tel = element()
bodies, byX = frame(tel)
check(same(byX[1].c, P[4]), "N10 timed scan records the NPC flag")
vars.Bandit = false
h.setNow(1000000 + 1000)
bodies, byX = frame(tel)
check(same(byX[1].c, P[4]), "N10 flag stays with the scan between scans")
h.setNow(1000000 + 6000)
bodies, byX = frame(tel)
check(same(byX[1].c, ZC), "N10 the next scan picks up the change")
h.setScanSec(0)

-- OnGameBoot 之後才登記：照樣成功、log 一次說沒有選項，顏色用預設（這裡另開一份登記表）
h = chunk()
api, npc = h.api, h.npc
npc.booted = true
logs0 = #h.logs
checkEq(api.registerNpcTag("Late", "late", "UI_L", "L"), true, "LB1 a tag registered after OnGameBoot still registers")
checkEq(#h.logs, logs0 + 1, "LB1 late registration logs once")
check(h.logs[#h.logs]:find("after OnGameBoot", 1, true) ~= nil, "LB1 the log says there is no option")
api.registerNpcTag("Late", "late", "UI_L", "L")
checkEq(#h.logs, logs0 + 1, "LB1 idempotent repeat does not log again")
checkEq(npc.tags[1].color, 4, "LB2 late tag uses its default colour slot")

print("npc dots assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
