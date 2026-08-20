-- 離線重現：vanilla streets.xml 全量進 NavCore，跑指定起訖找路。
-- 用法：lua scripts/repro_nav.lua [sx sy tx ty]
-- 預設＝2026-08-20 使用者實測案例：Muldraugh 市區 → 軍事基地（無路徑回報）
local srcPath = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"
local xmlPath = "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/maps/Muldraugh, KY/streets.xml"

local f = assert(io.open(srcPath, "rb"))
local source = f:read("*a"):gsub("\r\n", "\n")
f:close()
local core = assert(source:match("%-%- test:navroute%-core:start\n(.-)\n%-%- test:navroute%-core:end"),
    "找不到 navroute-core 區段")
local chunk = assert((loadstring or load)(core .. "\nreturn NavCore", "navcore"))
local NavCore = chunk()

-- 讀 vanilla streets.xml（桌面 Lua，io 可用）
local xf = assert(io.open(xmlPath, "rb"))
local xml = xf:read("*a")
xf:close()
local streets = {}
for name, body in xml:gmatch('<street name="([^"]*)"[^>]*>(.-)</street>') do
    local pts = {}
    for x, y in body:gmatch('<point x="([%d%.%-]+)" y="([%d%.%-]+)"') do
        pts[#pts + 1] = tonumber(x)
        pts[#pts + 1] = tonumber(y)
    end
    if #pts >= 4 then
        streets[#streets + 1] = { name = name, src = nil, pts = pts }
    end
end
print(("streets parsed: %d"):format(#streets))

local b = NavCore.newBuild(streets, nil)
local t0 = os.clock()
while not NavCore.step(b, 100000) do end
local g = b.graph
print(("build: %.2fs, nodes=%d snapSegs=%d"):format(os.clock() - t0, g.nodeCount or -1,
    g.segs and #g.segs or -1))

local sx, sy = tonumber(arg[1]) or 12895, tonumber(arg[2]) or 3498
local tx, ty = tonumber(arg[3]) or 5783, tonumber(arg[4]) or 12484
local starts = NavCore.snapCandidates(g, sx, sy, 2)
local ends = NavCore.snapCandidates(g, tx, ty, 2)
print(("start snap: %d candidates"):format(#starts))
print(("end snap: %d candidates"):format(#ends))
local r = NavCore.findRoute(g, sx, sy, tx, ty)
if r then
    print(("route: len=%d pts=%d"):format(math.floor(r.len or -1), r.pts and #r.pts / 2 or -1))
else
    print("route: NIL (noroad)")
end

-- 毛刺診斷：印出路徑全點列（找短折返段）
if r and arg[5] == "dump" then
    local pts = r.pts
    for i = 1, #pts / 2 do
        local x, y = pts[i * 2 - 1], pts[i * 2]
        local seg = ""
        if i > 1 then
            local px2, py2 = pts[i * 2 - 3], pts[i * 2 - 2]
            local d = math.sqrt((x - px2) ^ 2 + (y - py2) ^ 2)
            seg = string.format("  seg=%.1f", d)
        end
        print(string.format("%3d: %.1f, %.1f%s", i, x, y, seg))
    end
end
