-- 朝向箭頭與視野扇形（_Nav.lua test:player-facing 區段）：方向經 mapAPI 投影後在俯視與等軸測都對、
-- 坐車看車頭、自己圖標或勾選關掉就不畫、靠邊不畫、跟著標記大小縮放、紅色本體畫在最上層；扇形墊在
-- 箭頭下面、貼地投影；其他玩家只在多人、照原版 MapRemotePlayerVisibility 與沙盒 RemoteFacingDisplay 畫，
-- 隊友青、其他人白；別層的其他玩家照 FloorMarkStyle 畫（BFH 式縮小、樓下變暗；BF6 式箭頭裡加小三角），
-- 由下往上畫。等軸測假件同 WorldMapRenderer.calcMatrices：平面旋 45° 後 y 乘 cos60°（2026-10-18
-- 原型實測等軸測北＝(0.894, -0.447)）。
local navPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Nav.lua"
local fh = assert(io.open(navPath, "rb"))
local source = fh:read("*a"):gsub("\r\n", "\n")
fh:close()
local body = assert(source:match("%-%- test:player%-facing:start\n(.-)\n%-%- test:player%-facing:end"),
    "missing player-facing test block")

-- 世界狀態：本機玩家、伺服器同步的玩家、沙盒、原版伺服器選項、陣營、安全屋、管理員、時鐘
local opts, players, online, size = {}, {}, {}, 16
local mp, now, texture = false, 0, true
local sandbox, serverOpts, faction, safehouse, admins = {}, {}, {}, {}, {}
local calls = { safehouse = 0 }
local Core = {
    markerIconSize = function() return size end,
    sandboxGate = function(name, default)
        if sandbox[name] == nil then return default end
        return sandbox[name]
    end,
    adotsTexture = function(path) return texture and { path = path } or nil end,
    getComboIndex = function(id, default)
        if opts[id] == nil then return default end
        return opts[id]
    end,
}
local env = setmetatable({
    Core = Core,
    getBoolOption = function(id, default)
        if opts[id] == nil then return default end
        return opts[id]
    end,
    getSpecificPlayer = function(pn) return players[pn] end,
    isClient = function() return mp end,
    getTimestampMs = function() return now end,
    getOnlinePlayers = function()
        return { size = function() return #online end, get = function(_, i) return online[i + 1] end }
    end,
    getServerOptions = function()
        return { getInteger = function(_, key) return serverOpts[key] end }
    end,
    Faction = { isInSameFaction = function(p, name)
        return faction[p.name] ~= nil and faction[p.name] == faction[name]
    end },
    SafeHouse = { isInSameSafehouse = function(a, b)
        calls.safehouse = calls.safehouse + 1
        return safehouse[a] ~= nil and safehouse[a] == safehouse[b]
    end },
    MinidoracatMiniMapPolicy = { hasCanSeeAll = function(pn) return admins[pn] == true end },
    -- 原版 getPlayerInfo：RealX／RealY 是最後一個網路封包的位置（真的回傳 Java Float，這裡用 Lua 數字）
    getPlayerInfo = function(p) return p.net end,
    Vector3f = { new = function()
        return { x = function(self) return self.vx end, z = function(self) return self.vz end }
    end },
}, { __index = _G })
local compile = loadstring or load
local chunk = assert(compile("local Core, getBoolOption = Core, getBoolOption\n" .. body, "@player-facing", "t", env))
if setfenv then setfenv(chunk, env) end
chunk()

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local W, H, S = 400, 400, 4 -- 元件寬高、每格像素
local CX, CY = 1000, 1000   -- 地圖中心（世界座標）
local AX, AY = 100, 50      -- 元件在畫面上的絕對位置（四角 DrawTexture 收絕對座標）
local function mapAPI(iso, showPlayers, showRemote)
    local api = {}
    local function rel(x, y)
        local dx, dy = (x - CX) * S, (y - CY) * S
        if iso then
            local r = math.sqrt(0.5)
            dx, dy = (dx - dy) * r, (dx + dy) * r * 0.5
        end
        return dx + W / 2, dy + H / 2
    end
    function api:worldToUIX(x, y) return (rel(x, y)) end
    function api:worldToUIY(x, y) return select(2, rel(x, y)) end
    function api:getWorldScale() return S end
    function api:getBoolean(name)
        if name == "Players" then return showPlayers ~= false end
        if name == "RemotePlayers" then return showRemote ~= false end
        return false
    end
    return api
end
local function element(api)
    local el = { mapAPI = api, width = W, height = H, polys = {}, quads = {}, rects = {}, log = {}, stencil = 0, cleared = 0 }
    function el:drawPolygon(_, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a)
        self.polys[#self.polys + 1] = { x1, y1, x2, y2, x3, y3, x4, y4, r = r, g = g, b = b, a = a }
        self.log[#self.log + 1] = "poly"
    end
    function el:drawTextureAllPoint(tex, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a)
        self.quads[#self.quads + 1] = { x1, y1, x2, y2, x3, y3, x4, y4, r = r, g = g, b = b, a = a, tex = tex }
        self.log[#self.log + 1] = "quad"
    end
    function el:drawRect(x, y, w, h, a, r, g, b)
        self.rects[#self.rects + 1] = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
        self.log[#self.log + 1] = "rect"
    end
    function el:getAbsoluteX() return AX end
    function el:getAbsoluteY() return AY end
    function el:setStencilRect() self.stencil = self.stencil + 1 end
    function el:clearStencilRect() self.cleared = self.cleared + 1 end
    return el
end
local function player(x, y, angle, vehicle, name)
    local p = { dead = false, name = name or "me", invisible = false, sees = {}, isLocal = true, z = 0 }
    function p:getX() return x end
    function p:getY() return y end
    function p:getZ() return self.z end
    function p:isDead() return self.dead end
    function p:getVehicle() return vehicle end
    function p:getAnimAngleRadians() return angle end
    function p:getUsername() return self.name end
    function p:isLocalPlayer() return self.isLocal end
    function p:isInvisible() return self.invisible end
    function p:checkCanSeeClient(other) return self.sees[other.name] == true end
    return p
end
local function remote(x, y, angle, name)
    local p = player(x, y, angle, nil, name)
    p.isLocal = false
    return p
end
local function vehicle(x, y, fx, fz)
    local v = {}
    function v:getX() return x end
    function v:getY() return y end
    function v:getForwardVector(out) out.vx, out.vz = fx, fz; return out end
    return v
end
-- 紅色本體（最後一層）尖端相對中心的單位向量與距離
local function tipDir(el, cx, cy)
    local red = el.polys[#el.polys]
    local dx, dy = red[1] - cx, red[2] - cy
    local n = math.sqrt(dx * dx + dy * dy)
    return dx / n, dy / n, n
end
local function near(a, b) return math.abs(a - b) < 0.01 end
local function draw(iso, list, showPlayers, showRemote)
    players = list
    local el = element(mapAPI(iso, showPlayers, showRemote))
    Core.drawPlayerFacing(el)
    return el
end
-- 扇形四角（tl, tr, br, bl）換回元件座標：頂點＝tl、bl 中點；遠端＝tr、br 中點
local function coneAxis(q)
    local ax, ay = (q[1] + q[7]) / 2 - AX, (q[2] + q[8]) / 2 - AY
    local fx, fy = (q[3] + q[5]) / 2 - AX, (q[4] + q[6]) / 2 - AY
    local dx, dy = fx - ax, fy - ay
    local n = math.sqrt(dx * dx + dy * dy)
    return ax, ay, dx / n, dy / n, n
end
-- 箭頭本體（每支第二層）的顏色分類
local function bodies(el, kind)
    local n = 0
    for i = 2, #el.polys, 2 do
        local p = el.polys[i]
        local k = (p.r > 0.9 and p.g < 0.2) and "self" or (p.b > 0.9 and p.r < 0.5) and "team"
            or (p.r > 0.9 and p.g > 0.9) and "other" or "?"
        if k == kind then n = n + 1 end
    end
    return n
end

-- F1 俯視：面向東指右、面向北指上；兩層、紅色在最上面
local el = draw(false, { [0] = player(CX, CY, 0) })
local ux, uy = tipDir(el, W / 2, H / 2)
check(#el.polys == 2 and near(ux, 1) and near(uy, 0), "F1 top-down east points right")
check(el.polys[1].r == 0 and el.polys[1].g == 0 and el.polys[1].b == 0
    and el.polys[2].r > 0.9 and el.polys[2].g < 0.2, "F1 black outline, then red body on top")
el = draw(false, { [0] = player(CX, CY, -math.pi / 2) })
ux, uy = tipDir(el, W / 2, H / 2)
check(near(ux, 0) and near(uy, -1), "F1 top-down north points up")

-- F2 等軸測：北指右上、東指右下（和 2026-10-18 原型實測一致）
el = draw(true, { [0] = player(CX, CY, -math.pi / 2) })
ux, uy = tipDir(el, W / 2, H / 2)
check(near(ux, 0.894) and near(uy, -0.447), "F2 isometric north points up-right")
el = draw(true, { [0] = player(CX, CY, 0) })
ux, uy = tipDir(el, W / 2, H / 2)
check(near(ux, 0.894) and near(uy, 0.447), "F2 isometric east points down-right")

-- F3 坐車：位置與方向都看車（角色面向東、車頭向北、車停在中心西邊 10 格）
el = draw(false, { [0] = player(CX, CY, 0, vehicle(CX - 10, CY, 0, -1)) })
ux, uy = tipDir(el, W / 2 - 10 * S, H / 2)
check(#el.polys == 2 and near(ux, 0) and near(uy, -1), "F3 in a vehicle the arrow follows the vehicle heading")
check(near(el.polys[2][1], W / 2 - 10 * S), "F3 in a vehicle the arrow sits on the vehicle")

-- F4 勾選關、或這張地圖的自己圖標關：都不畫
opts.PlayerFacing = false
el = draw(false, { [0] = player(CX, CY, 0) })
check(#el.polys == 0, "F4 PlayerFacing off draws no arrow")
opts.PlayerFacing = nil
el = draw(false, { [0] = player(CX, CY, 0) }, false)
check(#el.polys == 0 and #el.quads == 0 and el.stencil == 0, "F4 own marker hidden on this map draws nothing")

-- F5 玩家在畫面外或貼邊（自由查看拖走）：不畫，留給原版紅點
el = draw(false, { [0] = player(CX + 60, CY, 0) })
check(#el.polys == 0 and #el.quads == 0, "F5 player outside the map draws nothing")
el = draw(false, { [0] = player(CX + (W / 2 - 4) / S, CY, 0) })
check(#el.polys == 0, "F5 player within half an arrow of the edge draws nothing")

-- F6 同原版畫全部本機玩家；死掉的不畫
local dead = player(CX + 5, CY, 0)
dead.dead = true
el = draw(false, { [0] = player(CX, CY, 0), [1] = player(CX - 5, CY + 5, math.pi), [2] = dead })
check(#el.polys == 4 and #el.quads == 2, "F6 every living local player gets an arrow and a cone")

-- F7 大小跟「標記大小」滑條
el = draw(false, { [0] = player(CX, CY, 0) })
local _, _, small = tipDir(el, W / 2, H / 2)
size = 32
el = draw(false, { [0] = player(CX, CY, 0) })
local _, _, large = tipDir(el, W / 2, H / 2)
size = 16
check(near(large / small, 2), "F7 arrow length scales with the marker size slider")

-- F8 凹四邊形要以尖端（第 0 點）為扇心才畫得對：每一層第 0 點都是沿方向最遠的點
el = draw(false, { [0] = player(CX, CY, math.pi / 4) })
local ok = true
for _, poly in ipairs(el.polys) do
    local d = {}
    for i = 1, 4 do
        d[i] = (poly[i * 2 - 1] - W / 2) * math.sqrt(0.5) + (poly[i * 2] - H / 2) * math.sqrt(0.5)
    end
    if not (d[1] > d[2] and d[1] > d[3] and d[1] > d[4]) then ok = false end
end
check(ok, "F8 every layer starts at the tip so the concave dart triangulates correctly")

-- C1 扇形：一個、紅色、墊在箭頭下面；整段包 stencil，畫完一定 clear
el = draw(false, { [0] = player(CX, CY, 0) })
check(#el.quads == 1 and el.log[1] == "quad" and el.log[2] == "poly", "C1 the cone is drawn first, under the arrow")
check(el.quads[1].r == 1 and el.quads[1].g < 0.3 and el.quads[1].a == 0.85 and el.quads[1].tex ~= nil,
    "C1 own cone is red and translucent")
check(el.stencil == 1 and el.cleared == 1, "C1 drawing is clipped to the map and the clip is cleared")

-- C2 頂點在玩家（加上元件絕對位置）、沿朝向伸出標記大小 × 4.5 px；等軸測照投影壓扁
local ax, ay, cdx, cdy, clen = coneAxis(el.quads[1])
check(near(ax, W / 2) and near(ay, H / 2) and near(cdx, 1) and near(cdy, 0) and near(clen, 72),
    "C2 top-down cone starts at the player and points along the facing")
el = draw(true, { [0] = player(CX, CY, -math.pi / 2) })
ax, ay, cdx, cdy = coneAxis(el.quads[1])
check(near(ax, W / 2) and near(cdx, 0.894) and near(cdy, -0.447), "C2 isometric cone follows the projection")

-- C3 兩個勾選各管各的；貼圖缺了照畫箭頭
opts.PlayerCone = false
el = draw(false, { [0] = player(CX, CY, 0) })
check(#el.quads == 0 and #el.polys == 2, "C3 PlayerCone off keeps the arrow")
opts.PlayerCone, opts.PlayerFacing = nil, false
el = draw(false, { [0] = player(CX, CY, 0) })
check(#el.quads == 1 and #el.polys == 0, "C3 PlayerFacing off keeps the cone")
opts.PlayerFacing = nil
texture = false
el = draw(false, { [0] = player(CX, CY, 0) })
check(#el.quads == 0 and #el.polys == 2, "C3 a missing cone texture still draws the arrow")
texture = true

-- 多人：me（本機）、mate（同陣營）、bob（陌生人）、ghost（隱形的陌生人）、corpse（死掉的隊友）
local me = player(CX, CY, 0, nil, "me")
local mate = remote(CX + 10, CY, -math.pi / 2, "mate")
local bob = remote(CX - 10, CY, math.pi / 2, "bob")
local ghost = remote(CX, CY + 10, 0, "ghost")
ghost.invisible = true
local corpse = remote(CX, CY - 10, 0, "corpse")
corpse.dead = true
faction.me, faction.mate, faction.corpse = "F", "F", "F"
online = { me, mate, bob, ghost, corpse }
serverOpts.MapRemotePlayerVisibility = 4
local function mpDraw(showRemote)
    now = now + 2000 -- 每次都過了快取期
    return draw(false, { [0] = me }, nil, showRemote)
end

-- R1 單機不畫其他玩家
el = draw(false, { [0] = me })
check(#el.polys == 2 and bodies(el, "self") == 1, "R1 single player draws only local players")

-- R2 多人、沙盒預設（只限陣營與安全屋成員）：隊友青色箭頭與扇形，陌生人不畫；本機在最上面
mp = true
el = mpDraw()
check(bodies(el, "team") == 1 and bodies(el, "other") == 0 and bodies(el, "self") == 1 and #el.quads == 2,
    "R2 default level draws teammates only")
local mateBody = el.polys[2]
check(near(mateBody[1], W / 2 + 10 * S) and near(mateBody[2], H / 2 - 0.55 * 1.25 * size * 0.8)
    and mateBody.b == 1 and mateBody.g > 0.7, "R2 the teammate arrow is cyan, one size smaller, on the teammate")
check(el.log[1] == "quad" and el.log[2] == "quad" and el.log[3] == "rect" and el.log[4] == "poly" and bodies(el, "self") == 1
    and el.polys[#el.polys].r > 0.9 and el.polys[#el.polys].g < 0.2,
    "R2 all cones first, then the teammate's dot cover and arrow, own arrow drawn last on top")
local _, _, rdx, rdy = coneAxis(el.quads[1])
check(near(rdx, 0) and near(rdy, -1), "R2 the teammate cone points where the teammate faces")

-- R3 第 3 段（地圖上看得到的所有玩家）：陌生人白色；隱形與死掉的不畫
sandbox.RemoteFacingDisplay = 3
el = mpDraw()
check(bodies(el, "team") == 1 and bodies(el, "other") == 1 and #el.quads == 3, "R3 level 3 adds other players in white")

-- R4 第 1 段（關閉）：只剩自己
sandbox.RemoteFacingDisplay = 1
el = mpDraw()
check(#el.polys == 2 and bodies(el, "self") == 1, "R4 level 1 draws no other players")
sandbox.RemoteFacingDisplay = 3

-- R5 不會比原版地圖多：原版 1＝誰都不畫（隊友也不畫）；2＝只有陣營；缺選項當 1
serverOpts.MapRemotePlayerVisibility = 1
el = mpDraw()
check(#el.polys == 2, "R5 vanilla visibility 1 hides everyone, teammates too")
serverOpts.MapRemotePlayerVisibility = nil
el = mpDraw()
check(#el.polys == 2, "R5 a missing vanilla option counts as 1")
serverOpts.MapRemotePlayerVisibility = 2
el = mpDraw()
check(bodies(el, "team") == 1 and bodies(el, "other") == 0, "R5 vanilla visibility 2 shows the faction only")

-- R6 原版 3＝陣營＋本機玩家看得到的人
serverOpts.MapRemotePlayerVisibility = 3
el = mpDraw()
check(bodies(el, "team") == 1 and bodies(el, "other") == 0, "R6 vanilla visibility 3 hides strangers we cannot see")
me.sees.bob = true
el = mpDraw()
check(bodies(el, "other") == 1, "R6 vanilla visibility 3 shows strangers we can see")
me.sees.bob = nil

-- R7 原版 4＝所有人，但自己隱形時看不到（對方能不能看隱形讀不到，當作不能）
serverOpts.MapRemotePlayerVisibility = 4
me.invisible = true
el = mpDraw()
check(#el.polys == 2, "R7 vanilla visibility 4 shows nobody while we are invisible")
me.invisible = false

-- R8 管理員（CanSeeAll）看全部，隱形的也看得到；不是管理員看不到隱形的
admins[0] = true
serverOpts.MapRemotePlayerVisibility = 1
el = mpDraw()
check(bodies(el, "other") == 2 and bodies(el, "team") == 1, "R8 admins see everyone, invisible players too")
admins[0] = nil
serverOpts.MapRemotePlayerVisibility = 4

-- R9 玩家勾選「其他玩家顯示朝向」關、或這張地圖的「其他玩家」關：都不畫其他玩家
opts.RemoteFacing = false
el = mpDraw()
check(#el.polys == 2, "R9 RemoteFacing off draws no other players")
opts.RemoteFacing = nil
el = mpDraw(false)
check(#el.polys == 2, "R9 remote players hidden on this map draws no other players")

-- R10 同安全屋也算隊友；判斷每位玩家每秒才重算一次（安全屋判斷會掃全部安全屋）
sandbox.RemoteFacingDisplay = 2
safehouse.me, safehouse.bob = "H", "H"
el = mpDraw()
check(bodies(el, "team") == 2, "R10 same safehouse counts as a teammate")
local before = calls.safehouse
Core.drawPlayerFacing(element(mapAPI(false)))
check(calls.safehouse == before, "R10 team checks are cached within a second")
safehouse.bob = nil
Core.drawPlayerFacing(element(mapAPI(false)))
now = now + 999
el = draw(false, { [0] = me })
check(bodies(el, "team") == 2, "R10 a cached teammate stays for up to a second")
now = now + 1
el = draw(false, { [0] = me })
check(bodies(el, "team") == 1 and calls.safehouse > before, "R10 the cache refreshes after a second")

-- R11 原版在其他玩家的網路位置畫 6×6 純紅點（UIWorldMap.renderPlayer：元件座標取整數再減 3）。徒步的其他玩家
-- 照 getPlayerInfo 的 RealX／RealY 畫（真的值是 Java Float，只能 tostring），箭頭底下先在同一格蓋不透明的黑；
-- 自己的箭頭是紅的不蓋。此時 sandbox＝2、只有隊友 mate（CX+10, CY，面向北）會畫
local function javaFloat(v) return setmetatable({}, { __tostring = function() return tostring(v) end }) end
el = mpDraw()
local cover = el.rects[1]
check(#el.rects == 1 and cover.x == math.floor(W / 2 + 10 * S) - 3 and cover.y == math.floor(H / 2) - 3
    and cover.w == 6 and cover.h == 6 and cover.a == 1 and cover.r == 0 and cover.g == 0 and cover.b == 0,
    "R11 a teammate's arrow covers the vanilla red dot with opaque black, own arrow does not")
mate.net = { RealX = javaFloat(CX + 11.3), RealY = javaFloat(CY + 0.6) }
el = mpDraw()
local nx, ny = W / 2 + 11.3 * S, H / 2 + 0.6 * S
local cax, cay = coneAxis(el.quads[1])
check(near(el.polys[2][1], nx) and near(el.polys[2][2], ny - 0.55 * 1.25 * size * 0.8) and near(cax, nx) and near(cay, ny)
    and el.rects[1].x == math.floor(nx) - 3 and el.rects[1].y == math.floor(ny) - 3,
    "R11 on foot, arrow, cone and cover sit at the network position where vanilla draws the dot")
mate.net = { RealX = javaFloat(CX + 50), RealY = javaFloat(CY) }
el = mpDraw()
check(near(el.polys[2][1], W / 2 + 10 * S), "R11 a network position 8+ tiles off the character falls back to the character")
mate.net = nil
el = mpDraw()
check(near(el.polys[2][1], W / 2 + 10 * S) and el.rects[1].x == math.floor(W / 2 + 10 * S) - 3,
    "R11 without network info the arrow and cover use the character position")
mate.net = { RealX = javaFloat(CX + 11.3), RealY = javaFloat(CY + 0.6) }
local walk = mate.getVehicle
mate.getVehicle = function() return vehicle(CX + 10, CY + 2, 0, -1) end
el = mpDraw()
check(near(el.polys[2][1], W / 2 + 10 * S) and near(el.polys[2][2], H / 2 + 2 * S - 0.55 * 1.25 * size * 0.8),
    "R11 in a vehicle the arrow stays on the vehicle")
mate.getVehicle, mate.net = walk, nil

-- R12 畫面外的人先略過：位置用同幀仿射（Core.zoneFrame；這裡以主檔 test:derive-affine 真實作從本測試的投影導出）
-- 投影，離元件邊超過餘量的隊友不讀朝向、不呼叫 getPlayerInfo；徒步的餘量多 8 格（網路位置離角色不到 8 格），
-- 角色在元件外 4 格、網路位置在畫面內的照畫；畫出來的與不剔除時逐筆相同（俯視與等軸測）
do
    local mf = assert(io.open("MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua", "rb"))
    local slice = assert(mf:read("*a"):gsub("\r\n", "\n"):match("%-%- test:derive%-affine:start\n(.-)\n%-%- test:derive%-affine:end"))
    mf:close()
    local derive = assert(compile(slice .. "\nreturn deriveAffine", "@derive-affine", "t", {}))()
    local far = remote(CX + 200, CY, 0, "far")
    local rim = remote(CX + W / 2 / S + 4, CY, -math.pi / 2, "rim")
    rim.net = { RealX = javaFloat(CX + W / 2 / S - 3), RealY = javaFloat(CY) }
    faction.far, faction.rim = "F", "F"
    local farReads = 0
    local farAngle = far.getAnimAngleRadians
    far.getAnimAngleRadians = function(p) farReads = farReads + 1; return farAngle(p) end
    local infoOf = env.getPlayerInfo
    env.getPlayerInfo = function(p) if p == far then farReads = farReads + 1 end; return infoOf(p) end
    online = { me, mate, bob, ghost, corpse, far, rim }
    local function dump(e)
        local out = {}
        for _, p in ipairs(e.polys) do out[#out + 1] = table.concat({ p[1], p[2], p[3], p[4], p.r, p.a }, ",") end
        for _, q in ipairs(e.quads) do out[#out + 1] = table.concat({ q[1], q[2], q[5], q[6], q.a }, ",") end
        for _, r in ipairs(e.rects) do out[#out + 1] = table.concat({ r.x, r.y }, ",") end
        return table.concat(out, ";")
    end
    local function culledDraw(iso)
        Core.zoneFrame = function(e)
            local f = { acx = CX, acy = CY }
            f.p0x, f.p0y, f.sxx, f.sxy, f.syx, f.syy = derive(e.mapAPI, CX, CY)
            return f
        end
        now = now + 2000
        local e = draw(iso, { [0] = me })
        Core.zoneFrame = nil
        return e
    end
    local plain = mpDraw()
    local readsPlain = farReads
    farReads = 0
    local culled = culledDraw(false)
    check(dump(culled) == dump(plain) and bodies(culled, "team") == 2, "R12 view cull draws exactly what the uncull path draws")
    check(readsPlain == 2 and farReads == 0, "R12 an off-view teammate is skipped before reading facing and network position")
    check(near(culled.polys[4][1], W - 3 * S), "R12 a teammate just outside the map is drawn at its on-screen network position")
    now = now + 2000
    local isoPlain = draw(true, { [0] = me })
    check(dump(culledDraw(true)) == dump(isoPlain), "R12 isometric: the cull draws exactly what the uncull path draws")
    env.getPlayerInfo, far.getAnimAngleRadians = infoOf, farAngle
    online = { me, mate, bob, ghost, corpse }
end

-- 別層：mate 在樓上、bob（陌生人）在地下室；自己在地面。預設 FloorMarks 開、BFH 式
sandbox.RemoteFacingDisplay = 3
mate.z, bob.z = 1, -1
local R = size * 0.8
local function tip(sz) return 0.55 * 1.25 * sz end

-- FL0 伺服器關掉（沙盒 AllowFloorMarks＝false）：勾選開著也不分樓層，照收集順序、原大小
sandbox.AllowFloorMarks = false
el = mpDraw()
check(#el.polys == 6 and near(H / 2 - el.polys[2][2], tip(R)) and el.polys[2].b == 1 and el.polys[4].r > 0.9,
    "FL0 a server can turn floor marks off")
sandbox.AllowFloorMarks = nil

-- FL1 BFH 式（伺服器沒設＝預設開）：樓下先畫、樓上再畫、自己最上面；別層小一號，樓上照原色、樓下變暗（外框一起），扇形跟著
el = mpDraw()
check(#el.polys == 6 and near(el.polys[2][1], W / 2 - 40) and near(el.polys[4][1], W / 2 + 40)
    and el.polys[6].r > 0.9 and el.polys[6].g < 0.2, "FL1 draws below, then above, then yourself on top")
check(near(H / 2 - el.polys[4][2], tip(R * 0.65)) and el.polys[4].b == 1 and el.polys[4].a == 1,
    "FL1 BFH: a teammate upstairs is one size smaller and keeps its bright color")
check(near(el.polys[2][2] - H / 2, tip(R * 0.65)) and near(el.polys[2].r, 0.95 * 0.55) and near(el.polys[2].a, 0.8)
    and near(el.polys[1].a, 0.85 * 0.8), "FL1 BFH: a player downstairs is smaller and darker, outline too")
check(near(el.polys[6][1] - W / 2, tip(size)), "FL1 your own arrow keeps its size")
local _, _, _, _, mateCone = coneAxis(el.quads[2])
check(el.quads[1].a == 0.3 and el.quads[2].a == 0.6 and el.quads[3].a == 0.85 and near(mateCone, R * 0.65 * 4.5),
    "FL1 BFH: cones follow the floor, fainter below and shorter on other floors")

-- FL2 BF6 式：大小顏色扇形不變，別層的箭頭本體後面多一個黑色小三角，尖端朝上＝樓上
opts.FloorMarkStyle = 2
el = mpDraw()
check(#el.polys == 8 and el.polys[3].r == 0 and el.polys[3].a == 0.9 and el.polys[6].r == 0 and el.polys[6].a == 0.9,
    "FL2 BF6: one black mark inside each arrow on another floor, none on yours")
check(el.polys[3][2] > el.polys[3][4] and el.polys[6][2] < el.polys[6][4], "FL2 BF6: the mark points down for below, up for above")
check(near(H / 2 - el.polys[5][2], tip(R)) and el.polys[5].b == 1 and el.polys[5].a == 1 and el.quads[1].a == 0.85,
    "FL2 BF6: size, color and cone stay the same")

-- FL3 勾選關：選了 BF6 也不加記號、不縮，照收集順序畫
opts.FloorMarks = false
el = mpDraw()
check(#el.polys == 6 and near(H / 2 - el.polys[2][2], tip(R)) and el.polys[2].b == 1,
    "FL3 FloorMarks off: no marks, full size, collected order")
opts.FloorMarks, opts.FloorMarkStyle = nil, nil

-- FL4 樓層以這張地圖的玩家為準：分割畫面第二位在樓上時，樓上的隊友算同層、地下室的 bob 算樓下
local upstairs = player(CX, CY + 5, 0, nil, "me2")
upstairs.z = 1
players = { [0] = me, [1] = upstairs }
now = now + 2000
el = element(mapAPI(false))
el.playerNum = 1
Core.drawPlayerFacing(el)
check(#el.polys == 8 and near(H / 2 - el.polys[4][2], tip(R)) and near(el.polys[2].r, 0.95 * 0.55),
    "FL4 floors are compared with the map owner, not player 1")

-- FL5 樓梯上算下面那層（z 往下取整數，地下室也一樣）
mate.z, bob.z = 0.5, -0.5
el = mpDraw()
check(near(el.polys[2].r, 0.95 * 0.55) and near(H / 2 - el.polys[4][2], tip(R)),
    "FL5 on the stairs a player counts as the lower floor")

local EXPECTED_ASSERTIONS = 63
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS .. ", actual " .. assertions)
    os.exit(1)
end
print("player facing assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
