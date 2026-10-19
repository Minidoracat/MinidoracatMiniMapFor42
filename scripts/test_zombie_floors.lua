-- 別層殭屍點（_Dots.lua 的 zombie-sampling 與 zombie-dots-draw 兩段真程式，設計稿 minimap-floors-v2-1019）：
-- 取樣時記每隻殭屍的樓層（z 取整數，地下室是負數，樓梯上算下面那層），畫的時候和這張地圖的玩家
-- （el.playerNum）比，不同樓層的點透明度乘 ZDOTS_FLOOR_A；伺服器沒開放（Core.floorMarksMode 回 1）、勾選
-- FloorMarks 關、或這張地圖沒有玩家時不變淡。玩家換樓層下一幀就生效，不必等重新取樣。
-- 用法：lua scripts/test_zombie_floors.lua [_Dots.lua]
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

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end

local prelude = [=[
local now, opts, players, zombies, logs, floorMode = 1000, {}, {}, {}, {}, 2
local function log(msg) logs[#logs + 1] = msg end
local Core = { policy = {
    readNumber = function(_, default) return default end,
    tacticalActive = function() return false end,
} }
-- 伺服器開放與否由 _Nav.lua 的 Core.floorMarksMode 判（test_player_facing 驗它的規則）；這裡換成可切的樁
Core.floorMarksMode = function() return floorMode end
MinidoracatMiniMapAPI = {}
local function getTimestampMs() return now end
local function displayDist() return nil end
local function getComboIndex(_, default) return default end
local function getSliderValue(_, default) return default end
local function sandboxGate(_, default) return default end
local function getBoolOption(id, default)
    if opts[id] == nil then return default end
    return opts[id]
end
local function visibleWorldAABB() return -100, 100, -100, 100 end
-- 投影：視野中心 (0,0) 落在元件 (50,50)，一格一像素
local function deriveAffine() return 50, 50, 1, 0, 0, 1 end
local function getSpecificPlayer(pn) return players[pn] end
local function javaList(values)
    return { size = function() return #values end, get = function(_, i) return values[i + 1] end }
end
local cell = { getZombieList = function() return javaList(zombies) end }
local function getCell() return cell end
local ZDOTS_INTERVAL_MS, ZDOTS_MAX, ZDOTS_SCAN_MAX, SCAN_ALL = 300, 10, 100, 1e9
local ZDOTS_NEAR, ZDOTS_MID, ZDOTS_MAXES = 20, 50, { 10 }
local ZDOTS_COLORS, ZDOTS_EDGE_A, ZDOTS_FLOOR_A = { { 1, 0.62, 0.05 } }, 0.8, 0.3
local function zdotsStateFor(inner)
    if not inner._state then
        inner._state = { near = {}, mid = {}, far = {}, dots = {}, count = 0, nextMs = 0 }
    end
    return inner._state
end
]=]
local suffix = [=[
return {
    draw = function(el) drawZombieDotsOn(el, "ZombieDots", "mini") end,
    setNow = function(v) now = v end,
    opts = opts,
    players = players,
    setZombies = function(v) zombies = v end,
    setFloorMode = function(v) floorMode = v end,
    floorA = ZDOTS_FLOOR_A,
}
]=]
local chunk = assert(compile(prelude .. section("scan-listener") .. "\n" .. section("zombie-sampling") .. "\n"
    .. section("zombie-dots-draw") .. "\n" .. suffix))
local h = chunk()
h.opts.ZombieDots = true

local function actor(x, y, z)
    return { getX = function() return x end, getY = function() return y end, getZ = function() return z end }
end
-- 每顆點兩個 drawRect：描邊、本體；回傳本體的 alpha，以 x 座標（50 + 世界 x）對應殭屍
local function bodyAlpha(el)
    local out = {}
    for i = 2, #el.rects, 2 do
        local r = el.rects[i]
        out[r.x + 1 - 50] = r.a -- 本體從 ux-1 起畫
    end
    return out
end
local function element(pn)
    local el = { playerNum = pn, mapAPI = {}, width = 200, height = 200, rects = {} }
    function el:drawRect(x, y, w, hh, a, r, g, b) self.rects[#self.rects + 1] = { x = x, y = y, a = a } end
    return el
end
local function frame(el)
    el.rects = {}
    h.draw(el)
    return bodyAlpha(el)
end

-- 殭屍：x 當編號。1 地面、2 二樓、3 地下室、4 樓梯上（0.5，算地面）、5 往地下室的樓梯上（-0.5，算地下室）
h.setZombies({ actor(1, 0, 0), actor(2, 0, 1), actor(3, 0, -1), actor(4, 0, 0.5), actor(5, 0, -0.5) })
h.players[0] = actor(0, 0, 0)
local faded = h.floorA

-- Z1 自己在地面：二樓、地下室與往下的樓梯上變淡；地面與往上的樓梯上照舊
local el = element(0)
local a = frame(el)
check(a[1] == 1 and a[4] == 1, "Z1 dots on your floor keep full alpha (stairs going up count as the lower floor)")
check(a[2] == faded and a[3] == faded and a[5] == faded, "Z1 dots above, below and on stairs down fade")
check(el.rects[1].a == 0.8 and el.rects[3].a == 0.8 * faded, "Z1 the outline fades with the dot")

-- Z2 自己上二樓：下一幀就換成二樓的點最亮（同一份取樣，不必等重新掃描）
h.players[0] = actor(0, 0, 1)
a = frame(el)
check(a[2] == 1 and a[1] == faded and a[4] == faded, "Z2 changing floor updates the next frame without resampling")

-- Z3 勾選 FloorMarks 關：全部照舊
h.opts.FloorMarks = false
a = frame(el)
check(a[1] == 1 and a[2] == 1 and a[3] == 1 and a[5] == 1, "Z3 FloorMarks off draws every dot at full alpha")
h.opts.FloorMarks = nil

-- Z4 樓層以這張地圖的玩家為準（分割畫面第二位在地下室）
h.players[1] = actor(0, 0, -1)
a = frame(element(1))
check(a[3] == 1 and a[5] == 1 and a[1] == faded, "Z4 the map owner's floor decides, not player 1's")

-- Z5 這張地圖沒有玩家：不變淡
a = frame(element(2))
check(a[1] == 1 and a[2] == 1 and a[3] == 1, "Z5 a map without a player draws every dot at full alpha")

-- Z6 伺服器沒開放（多人預設）：勾選開著也全部照舊
h.setFloorMode(1)
a = frame(element(0))
check(a[1] == 1 and a[2] == 1 and a[3] == 1 and a[5] == 1, "Z6 the server switch off draws every dot at full alpha")
h.setFloorMode(2)

print("zombie floor assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
