-- Full production extraction -> patch -> graph: source names are not geometry identities.
local navPath = arg[1] or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"
local file = assert(io.open(navPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local compile = loadstring or load
local body = assert(source:match("%-%- test:navroute%-core:start\n(.-)\n%-%- test:navroute%-core:end"))
local nav = assert(compile(body .. "\nreturn NavCore", "road-source-core"))()
local canonical = "Muldraugh, KY"
local official = {
    { name = "West Road", width = 8, pts = { 0, 150, 20, 150 } },
    { name = "East Road", width = 8, pts = { 40, 150, 60, 150 } },
    { name = "Long Way", width = 8, pts = { 0, 150, 0, 500, 60, 500, 60, 150 } },
}
local patch = {
    schemaVersion = 1, tag = "source-regression", targetSrc = canonical,
    geometryCount = #official, geometrySet = {},
    removeCount = 0, remove = {}, widthCount = 0, width = {}, surfaceCount = 0, surface = {},
    addCount = 1, add = {
        { id = "missing-link", src = canonical, pts = { 20, 150, 40, 150 }, width = 8, surface = "paved", searchable = false },
    },
    bridgeCount = 0, bridge = {},
}
for i, st in ipairs(official) do patch.geometrySet[nav.fingerprintKey(st)] = "official:" .. i end
local function copyRows(rows, prefix)
    local copy = {}
    for i, st in ipairs(rows) do
        local pts = {}
        for pi, value in ipairs(st.pts) do pts[pi] = value end
        copy[i] = { name = (prefix or "") .. st.name, width = st.width, pts = pts }
    end
    return copy
end
local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local function event()
    local handlers = {}
    return { Add = function(fn) handlers[#handlers + 1] = fn end,
        fire = function() for _, fn in ipairs(handlers) do fn() end end }
end
local function world(sources, dirs, physical)
    local containers, byRel, loadedDirs, prints = {}, {}, {}, {}
    local reads = 0
    for i, entry in ipairs(sources) do
        local records = {}
        for si, row in ipairs(entry.rows) do
            records[si] = {
                getNumPoints = function() reads = reads + 1; return #row.pts / 2 end,
                getTranslatedText = function() return row.name end,
                getWidth = function() return row.width end,
                getPointX = function(_, pi) return row.pts[pi * 2 + 1] end,
                getPointY = function(_, pi) return row.pts[pi * 2 + 2] end,
            }
        end
        local container = { streets = list(records) }
        containers[i] = container
        byRel[("media/maps/" .. entry.dir .. "/streets.xml"):lower()] = container
    end
    for i, dir in ipairs(dirs) do loadedDirs[dir] = i end
    local streetAPI = {
        getStreetDataCount = function() return #containers end,
        getStreetDataByIndex = function(_, i) return containers[i + 1] end,
        getStreetDataByRelativeFileName = function(_, rel) return byRel[rel:lower()] end,
    }
    local tick = event()
    local player = { getX = function() return 5 end, getY = function() return 150 end,
        getVehicle = function() return {} end }
    local env = setmetatable({
        print = function(line) prints[#prints + 1] = line end,
        Events = { OnTick = tick, OnGameStart = event() },
        MinidoracatMiniMapAPI = {}, MinidoracatMiniMapRoadPatches = patch,
        MinidoracatMiniMapCore = { ready = true, getBoolOption = function(_, fallback) return fallback end,
            getLoadedMapDirs = function() return loadedDirs end },
        getLotDirectories = function() return list(dirs) end,
        getStreets = function(data) return data.streets end,
        getSpecificPlayer = function() return player end,
        getTimestampMs = function() return 1000 end,
        fileExists = function(path)
            local dir, x, y = path:match("^media/maps/(.+)/(%-?%d+)_(%-?%d+)%.lotheader$")
            if not dir then return false end
            local owns = physical[dir:lower()]
            return type(owns) == "function" and owns(tonumber(x), tonumber(y)) or owns == true
        end,
    }, { __index = _G })
    if setfenv then
        local chunk = assert(compile(source, "road-source-world"))
        setfenv(chunk, env); chunk()
    else
        assert(load(source, "road-source-world", "t", env))()
    end
    env.MinidoracatMiniMapCore.navKickEngine({ mapAPI = { getStreetsAPI = function() return streetAPI end } })
    local graph, state, patchState, maxReads
    maxReads = 0
    for _ = 1, 10000 do
        local before = reads
        tick.fire()
        maxReads = math.max(maxReads, reads - before)
        graph, state, patchState = env.MinidoracatMiniMapAPI.getNavGraph()
        if state == "ready" or state == "failed" then break end
    end
    assert(state == "ready", "usable source roads must build: " .. tostring(state) .. " " .. table.concat(prints, " | "))
    assert(maxReads <= 48, "source certification must stay in the extraction budget")
    local route, routeState = env.MinidoracatMiniMapAPI.requestRoute(0, 55, 150)
    assert(route and routeState == "ok", "source graph must remain queryable")
    return route, patchState, graph
end
local physical = { [canonical:lower()] = true }
local function direct(route, label)
    assert(math.abs(route.len - 50) < 0.01 and route.snapDist < 0.01 and math.abs(route.ex - 55) < 0.01,
        label .. ": missing road patch should connect the 50-square route")
end
local baseline, baselinePatch = world({ { dir = canonical, rows = official } }, { canonical }, physical)
assert(baselinePatch == "applied"); direct(baseline, "vanilla")
local carrier = "Unrelated Language Carrier"
local translated = copyRows(official, "Translated ")
local named, namedPatch = world({ { dir = carrier, rows = translated } }, { carrier, canonical }, physical)
assert(namedPatch == "applied", "a complete named translation source must receive road patches")
direct(named, "named translated source")
local unknown, unknownPatch = world({ { dir = carrier, rows = translated } }, { canonical }, physical)
assert(unknownPatch == "applied", "a complete by-index translation source must receive road patches")
direct(unknown, "unknown translated source")
local mixedCase, mixedCasePatch = world({ { dir = canonical, rows = official } }, { "muldraugh, ky" }, physical)
assert(mixedCasePatch == "applied"); direct(mixedCase, "case-insensitive source identity")
local doubled, doubledPatch = world({ { dir = carrier, rows = translated }, { dir = canonical, rows = official } },
    { carrier, canonical }, physical)
assert(doubledPatch == "applied"); direct(doubled, "two complete copies")
local reverseCopies, reversePatch = world({ { dir = canonical, rows = official }, { dir = carrier, rows = translated } },
    { canonical, carrier }, physical)
assert(reversePatch == "applied"); direct(reverseCopies, "official before translated copy")

-- Separate incomplete sources cannot assemble a false certificate by union.
local partial, partialPatch = world({ { dir = "Part A", rows = { official[1] } },
    { dir = "Part B", rows = { official[2], official[3] } } }, { canonical }, physical)
assert(partialPatch == "raw" and partial.len > 500, "partial source union cannot certify the official dataset")
local drifted = copyRows(official, "Changed ")
drifted[1].width = 9
local drift, driftPatch = world({ { dir = carrier, rows = drifted } }, { carrier, canonical }, physical)
assert(driftPatch == "raw" and drift.len > 500, "geometry/width drift must preserve raw roads rather than force a patch")
local physicalCopy, physicalPatch = world({ { dir = "Physical Map", rows = translated } },
    { "Physical Map", canonical }, { [canonical:lower()] = true, ["physical map"] = true })
assert(physicalPatch == "raw" and physicalCopy.len > 500, "a real map copying official geometry is not a translation carrier")

local extra = copyRows(official)
extra[#extra + 1] = { name = "Custom Road", width = 8, pts = { 1000, 1000, 1100, 1000 } }
local extraRoute, extraPatch = world({ { dir = carrier, rows = extra } }, { carrier, canonical }, physical)
assert(extraPatch == "raw" and extraRoute.len > 500, "a modified superset is not certified as an official copy")
local withShort = copyRows(official)
withShort[#withShort + 1] = { name = "Incomplete Road", width = 8, pts = {} }
local shortRoute, shortPatch = world({ { dir = carrier, rows = withShort } }, { carrier, canonical }, physical)
assert(shortPatch == "raw" and shortRoute.len > 500, "incomplete records cannot strengthen source evidence")
local noOfficial, noOfficialPatch = world({ { dir = carrier, rows = translated } }, { carrier }, physical)
assert(noOfficialPatch == "raw" and noOfficial.len > 500, "a total-conversion world must not borrow an inactive official source")

-- A carrier must not resurrect vanilla roads or added links under a winning map.
local replacement = { { name = "Replacement Road", width = 8, pts = { 0, 100, 60, 100 } } }
local covered, coveredPatch = world({ { dir = "Override", rows = replacement }, { dir = carrier, rows = translated } },
    { "Override", carrier, canonical }, {
        [canonical:lower()] = true,
        override = function(x, y) return x >= 0 and x <= 1 and y >= 0 and y <= 1 end,
    })
assert(coveredPatch == "applied", "unrelated map overrides do not invalidate source geometry certification")
assert(covered.snapDist >= 49, "the winning physical map must mask both carrier roads and generated links")
print("test_road_sources: PASS (vanilla, named/unknown carriers, complete copies, partial union, drift, physical maps, coverage)")
