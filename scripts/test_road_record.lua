-- Road recording (_RoadRecord.lua) offline regression. Loads the real file with fake PZ globals.
-- Invariants a player would see break:
--   * one point per tile moved (car position when driving); RAW_MAX auto-stops into review
--   * surface table = AutoDrive floorSurfaceId; bridge water under the deck is skipped
--   * width scan symmetric, recentres the point; an edge beyond MAX_W - 1 tiles or a road wider than
--     MAX_W = estimated width; a road point with one edge out of reach keeps the last lane offset
--   * short reversal legs vanish; surface / width class changes keep a vertex
--   * every draft <= 300 points, parts join end-to-end, segWidth / segSurface exactly n-1
--   * death / player gone / new game drops the recording and raises the lost flag once
-- Usage: lua scripts/test_road_record.lua
local ROOT = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/"
local compile = loadstring or load
local function readSource(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end
local SOURCE = readSource(ROOT .. "client/MinidoracatMiniMap_RoadRecord.lua")
local CODEC = readSource(ROOT .. "shared/MinidoracatMiniMap_RoadCodec.lua")

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected) .. ", actual=" .. tostring(actual) .. ")")
end

local GROUND = "blends_natural_01_16" -- grass: dirt surface, not a road tile
local FLAG = { water = "water", solidfloor = "solidfloor" }
local function obj(name, water)
    local props = { has = function(_, f) return f == FLAG.solidfloor or (water and f == FLAG.water) end }
    local sprite = { getProperties = function() return props end }
    return { getSprite = function() return sprite end, getSpriteName = function() return name end }
end
local function square(list)
    return { getObjects = function()
        return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
    end }
end

local function run(chunkSrc, name, env)
    local chunk
    if setfenv then chunk = assert(compile(chunkSrc, name)); setfenv(chunk, env)
    else chunk = assert(load(chunkSrc, name, "t", env)) end
    chunk()
end

local function fixture()
    local t = { tiles = {}, special = {}, events = {}, tool = {}, msgs = {}, title = {} }
    t.core = { ready = true,
        roadToolStart = function(pn, opts) t.tool[#t.tool + 1] = { pn = pn, opts = opts } end,
        navMessage = function(pn, text, good) t.msgs[#t.msgs + 1] = text end }
    t.player = { x = 0, y = 0, dead = false }
    local p = t.player
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return 0 end
    function p:getVehicle() return self.vehicle end
    function p:isDead() return self.dead end
    t.players = { [0] = p }
    local cell = { getGridSquare = function(_, x, y, z)
        local k = x .. "," .. y
        if t.special[k] then return square(t.special[k]) end
        return square({ obj(t.tiles[k] or GROUND) })
    end }
    local env = setmetatable({
        MinidoracatMiniMapCore = t.core,
        MinidoracatMiniMapAPI = { registerTitleStatus = function(owner, fn) t.title[#t.title + 1] = fn; return true end },
        IsoFlagType = FLAG,
        getCell = function() return cell end,
        getSpecificPlayer = function(pn) return t.players[pn] end,
        getText = function(key, ...)
            local s = key
            for _, v in ipairs({ ... }) do s = s .. "|" .. tostring(v) end
            return s
        end,
        Events = setmetatable({}, { __index = function(e, k)
            local ev = { Add = function(fn) t.events[k] = fn end }
            rawset(e, k, ev)
            return ev
        end }),
        print = function() end,
    }, { __index = _G })
    local okCodec = pcall(run, CODEC, "codec", env)
    t.codec = okCodec and rawget(env, "MinidoracatMiniMapRoadCodec") or nil
    run(SOURCE, "roadrecord", env)
    t.R = t.core.roadRecord
    return t
end

local function paint(t, x0, x1, y0, y1, name)
    for x = x0, x1 do for y = y0, y1 do t.tiles[x .. "," .. y] = name end end
end
local function moveTo(t, x, y)
    local who = t.player.vehicle or t.player
    who.x, who.y = x, y
    t.events.OnTick()
end
-- walk the polyline {x1,y1,x2,y2,...} in small steps, ticking each step
local function drive(t, path, step)
    step = step or 0.25
    for i = 3, #path, 2 do
        local ax, ay, bx, by = path[i - 2], path[i - 1], path[i], path[i + 1]
        local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
        local n = math.max(1, math.floor(len / step))
        for k = 1, n do moveTo(t, ax + (bx - ax) * k / n, ay + (by - ay) * k / n) end
    end
end
local function begin(t, x, y)
    local who = t.player.vehicle or t.player
    who.x, who.y = x, y
    return t.core.roadRecordStart(0)
end

-- draft invariants shared by every scenario: <= 300 points on the 0.5 grid, no zero-length
-- segment, segWidth / segSurface / measured exactly n-1, widths integer 3-16
local SURF_OK = { paved = true, gravel = true, dirt = true, unknown = true }
local function checkDraft(t, d, label)
    local k = #d.pts
    local n = k / 2
    check(k % 2 == 0 and n >= 2 and n <= 300, label .. " 2-300 points (n=" .. n .. ")")
    local ok = true
    for i = 1, k do if (d.pts[i] * 2) % 1 ~= 0 then ok = false end end
    for i = 3, k, 2 do if d.pts[i] == d.pts[i - 2] and d.pts[i + 1] == d.pts[i - 1] then ok = false end end
    check(ok, label .. " points on 0.5 grid, no zero-length segment")
    checkEq(#d.segWidth, n - 1, label .. " segWidth n-1")
    checkEq(#d.segSurface, n - 1, label .. " segSurface n-1")
    checkEq(#d.measured, n - 1, label .. " measured n-1")
    local wok = true
    for i = 1, n - 1 do
        local w = d.segWidth[i]
        if w % 1 ~= 0 or w < 3 or w > 16 or not SURF_OK[d.segSurface[i]] then wok = false end
    end
    check(wok, label .. " widths integer 3-16, known surfaces")
    if t.codec then
        local road = { pts = d.pts, segWidth = d.segWidth, segSurface = d.segSurface, ends = d.ends,
            source = d.source, enabled = true, share = {}, name = "x", id = "r1", rev = 1 }
        local valid, err = t.codec.validateRoad(road)
        check(valid, label .. " passes RoadCodec.validateRoad (" .. tostring(err) .. ")")
    end
end
local function allDrafts(d)
    local list = { d }
    for _, p in ipairs(d.parts or {}) do list[#list + 1] = p end
    return list
end

-- A. sampling threshold, car position, title status registered lazily
do
    local t = fixture()
    checkEq(#t.title, 0, "A1 no title status registration before the first recording")
    check(begin(t, 100.5, 50.5), "A2 start")
    check(not t.core.roadRecordStart(0), "A3 second start while recording refused")
    local rec = t.R.recs[0]
    moveTo(t, 101.4, 50.5)
    checkEq(rec.n, 1, "A4 moved 0.9: no point")
    moveTo(t, 101.5, 50.5)
    checkEq(rec.n, 2, "A5 moved 1.0: point taken")
    moveTo(t, 101.6, 50.5); moveTo(t, 102.3, 50.5)
    checkEq(rec.n, 2, "A6 distance measured from the last recorded point, not the last tick")
    t.player.vehicle = { x = 200.5, y = 80.5, getX = function(s) return s.x end,
        getY = function(s) return s.y end, getZ = function() return 0 end }
    t.events.OnTick()
    checkEq(rec.xs[rec.n], 200.5, "A7 in a car: the car position is recorded")
    checkEq(#t.title, 1, "A8 title status registered on first start")
    local st = t.core.roadRecordState(0)
    check(st and st.km > 0.09, "A9 state reports distance in km")
end

-- B. raw cap auto-stops into review with the recorded part kept
do
    local t = fixture()
    t.R.RAW_MAX = 50
    begin(t, 10.5, 10.5)
    drive(t, { 10.5, 10.5, 80.5, 10.5 })
    check(t.core.roadRecordState(0) == nil, "B1 recording stopped at the cap")
    checkEq(#t.tool, 1, "B2 review opened once")
    local d = t.tool[1] and t.tool[1].opts.draft
    checkEq(t.tool[1] and t.tool[1].opts.mode, "review", "B3 review mode")
    checkEq(d and d.rawN, 50, "B4 the 50 recorded points are kept")
    check(t.msgs[1] and t.msgs[1]:find("RoadRecTooLong", 1, true), "B5 too-long notice shown")
    checkEq(t.core.roadRecordLastLost(0), false, "B6 auto-stop is not a loss")
end

-- C. surface table (AutoDrive floorSurfaceId) and bridge water
do
    local t = fixture()
    local R = t.R
    local cases = {
        { "floors_exterior_natural_01_13", "gravel" }, { "blends_street_01_48", "gravel" },
        { "blends_street_01_55", "gravel" }, { "street_curbs_01_blend_gravel_3", "gravel" },
        { "blends_natural_01_0", "unknown" }, { "floors_exterior_natural_01_24", "unknown" },
        { "blends_natural_01_101", "unknown" }, { "carpentry_02_57", "unknown" },
        { "street_curbs_01_blend_dirt_2", "dirt" }, { "blends_natural_01_64", "dirt" },
        { "blends_natural_01_16", "dirt" }, { "floors_exterior_natural_01_7", "dirt" },
        { "blends_street_01_0", "paved" }, { "floors_exterior_street_01_3", "paved" },
        { "street_curbs_01_12", "paved" }, { "industry_01_39", "unknown" },
        { "blends_natural_02_3", "unknown" }, { nil, "unknown" },
    }
    for _, c in ipairs(cases) do checkEq(R.surfaceOf(c[1]), c[2], "C surface " .. tostring(c[1])) end
    check(R.isRoadName("blends_natural_01_64") and R.isRoadName("blends_natural_01_71"), "C1 dirt trail edge is road")
    check(not R.isRoadName("blends_natural_01_63") and not R.isRoadName("blends_natural_01_72")
        and not R.isRoadName("floors_exterior_natural_01_7"), "C2 plain dirt / grass is not road")
    check(not R.isRoadName("carpentry_02_57") and not R.isRoadName("blends_natural_01_0"), "C3 wood / sand is not road")
    local bridge = square({ obj("blends_natural_02_3", true), obj("blends_street_01_0"), obj("industry_01_39") })
    checkEq(R.dryFloorName(bridge), "blends_street_01_0", "C4 bridge: water underneath skipped")
    checkEq(R.dryFloorName(square({ obj("blends_natural_02_3", true) })), nil, "C5 open water has no dry floor")
    -- bridge square on the driven line reads paved, not water
    t.special["30,40"] = { obj("blends_natural_02_3", true), obj("blends_street_01_0") }
    local _, s = R.sample(30.5, 40.5, 0, 1, 0)
    checkEq(s, "paved", "C6 sampling on a bridge reads the deck surface")
end

-- D. width scan symmetric, recentred; estimated when no edge
do
    local t = fixture()
    local R = t.R
    paint(t, 0, 200, 48, 53, "blends_street_01_0") -- rows 48..53: 6 wide, centre y = 51
    local w1, s1, m1, cx1, cy1 = R.sample(100.5, 49.5, 0, 1, 0)   -- heading east, off-centre
    local w2, _, m2, cx2, cy2 = R.sample(100.5, 49.5, 0, -1, 0)   -- heading west, same spot
    checkEq(w1, 6, "D1 width = road tiles across")
    check(m1 and m2, "D2 both edges found = measured")
    checkEq(w2, w1, "D3 width does not depend on direction")
    checkEq(cy1, 51, "D4 point moved to the road centre (east)")
    checkEq(cy2, 51, "D5 point moved to the road centre (west)")
    checkEq(cx1, 100.5, "D6 no along-road shift")
    local w3, _, _, _, cy3 = R.sample(100.5, 52.5, 0, 1, 0)
    check(w3 == 6 and cy3 == 51, "D7 other lane gives the same width and centre")
    -- north-south road, cols 10..13 (4 wide, centre x = 12)
    paint(t, 10, 13, 0, 40, "floors_exterior_street_01_3")
    local w4, _, _, cx4 = R.sample(10.5, 20.5, 0, 0, 1)
    check(w4 == 4 and cx4 == 12, "D8 vertical road: width 4, centre x 12")
    -- wider than the scan: estimate, position untouched
    paint(t, 300, 400, 0, 30, "blends_street_01_0")
    local w5, _, m5, cx5, cy5 = R.sample(350.3, 15.2, 0, 1, 0)
    check(not m5 and w5 == R.DEFAULT_W and cx5 == 350.3 and cy5 == 15.2, "D9 edge beyond 15 tiles: estimated default width")
    local w6, s6, m6 = R.sample(500.5, 500.5, 0, 1, 0)
    check(not m6 and w6 == R.DEFAULT_W and s6 == "dirt", "D10 off-road: estimated, surface still read")
    -- one side only (the far edge 24 tiles away)
    paint(t, 0, 200, 60, 85, "blends_street_01_0")
    local _, _, m7 = R.sample(100.5, 61.5, 0, 1, 0)
    check(not m7, "D11 only one edge found: estimated")
    -- narrow dirt trail of edge blends counts as a road
    paint(t, 0, 200, 90, 91, "blends_natural_01_66")
    local w8, s8, m8, _, cy8 = R.sample(50.5, 90.5, 0, 1, 0)
    check(m8 and w8 == 2 and s8 == "dirt" and cy8 == 91, "D12 dirt trail: measured 2 wide, dirt, centred")
end

-- E. reversal legs removed (raw positions), long legs kept
do
    local t = fixture()
    local R = t.R
    local function line(...)
        local xs, ys, n = {}, {}, 0
        local stops = { ... }
        local x = stops[1]
        n = 1; xs[1], ys[1] = x, 0
        for i = 2, #stops do
            local dir = stops[i] > x and 1 or -1
            while x ~= stops[i] do x = x + dir; n = n + 1; xs[n], ys[n] = x, 0 end
        end
        return xs, ys, n
    end
    local function monotone(xs, idx, m)
        for k = 2, m do if xs[idx[k]] <= xs[idx[k - 1]] then return false end end
        return true
    end
    local xs, ys, n = line(0, 20, 17, 40)
    local idx, m = R.dropBacktrack(xs, ys, n)
    check(monotone(xs, idx, m), "E1 back 3 then forward: no backwards step left")
    checkEq(xs[idx[m]], 40, "E2 end kept")
    xs, ys, n = line(0, 30, 25)
    idx, m = R.dropBacktrack(xs, ys, n)
    check(monotone(xs, idx, m) and xs[idx[m]] == 30, "E3 short reversal at the end: ends at the farthest point")
    xs, ys, n = line(5, 8, 3, 30)
    idx, m = R.dropBacktrack(xs, ys, n)
    check(monotone(xs, idx, m) and xs[idx[m]] == 30, "E4 forward 3, back 5, forward: start reversal removed")
    xs, ys, n = line(5, 8, -20)
    idx, m = R.dropBacktrack(xs, ys, n)
    check(xs[idx[1]] == 8 and m == n - 3, "E4b short start then a long drive back: starts at the tip")
    xs, ys, n = line(0, 30, 20, 50)
    idx, m = R.dropBacktrack(xs, ys, n)
    checkEq(m, n, "E5 reversal leg of 10 tiles (>= 6) is kept")
    -- end to end through recording: draft polyline only moves forward
    paint(t, 0, 200, 8, 11, "blends_street_01_0")
    begin(t, 2.5, 9.5)
    drive(t, { 2.5, 9.5, 40.5, 9.5, 36.5, 9.5, 90.5, 9.5 })
    t.core.roadRecordStop(0)
    local d = t.tool[1].opts.draft
    local fwd = true
    for i = 3, #d.pts, 2 do if d.pts[i] <= d.pts[i - 2] then fwd = false end end
    check(fwd, "E6 recorded reversal does not reach the draft")
    checkDraft(t, d, "E7")
    checkEq(d.pts[2], 10, "E8 straight 4-wide road recorded on its centre line")
end

-- F. surface / width class changes keep a vertex; RDP <= 300; parts end-to-end
do
    local t = fixture()
    paint(t, 0, 60, 8, 11, "blends_street_01_0")
    paint(t, 61, 120, 8, 11, "blends_natural_01_66")
    t.tiles["30,9"] = "blends_natural_01_66" -- one odd tile: no extra vertex
    begin(t, 1.5, 9.5)
    drive(t, { 1.5, 9.5, 119.5, 9.5 })
    t.core.roadRecordStop(0)
    local d = t.tool[1].opts.draft
    checkDraft(t, d, "F1")
    checkEq(#d.pts / 2, 3, "F2 straight road keeps only ends plus the surface change")
    local bx = d.pts[3]
    check(bx >= 60 and bx <= 62, "F3 kept vertex sits at the surface change (x=" .. tostring(bx) .. ")")
    checkEq(d.segSurface[2], "dirt", "F4 dirt part marked dirt")
    check(d.measured[1] and d.measured[2], "F5 both parts measured")
    checkEq(d.segWidth[1], 4, "F6 width median 4")

    -- gentle long curve: one draft, simplified under 300
    local t2 = fixture()
    begin(t2, 1000, 0)
    local path = {}
    for a = 0, 180 do
        local r = a * math.pi / 180
        path[#path + 1] = 1000 * math.cos(r); path[#path + 1] = 1000 * math.sin(r)
    end
    drive(t2, path, 0.5)
    t2.core.roadRecordStop(0)
    local d2 = t2.tool[1].opts.draft
    check(d2.rawN > 3000, "F7 long curve recorded (" .. d2.rawN .. " raw points)")
    check(d2.parts == nil and #d2.pts / 2 <= 300, "F8 curve simplified to one draft <= 300 points")
    checkDraft(t2, d2, "F9")
    checkEq(d2.segSurface[1], "dirt", "F10 off-road recording is dirt")
    check(not d2.measured[1] and d2.segWidth[1] == t2.R.DEFAULT_W, "F11 unmeasured segment flagged with default width")

    -- zig-zag too wiggly for eps 8: split into end-to-end parts
    local t3 = fixture()
    begin(t3, 0, 0)
    local zz = {}
    for i = 0, 400 do zz[#zz + 1] = i * 10; zz[#zz + 1] = (i % 2) * 30 end
    drive(t3, zz, 0.5)
    t3.core.roadRecordStop(0)
    local d3 = t3.tool[1].opts.draft
    local parts = allDrafts(d3)
    check(#parts >= 2, "F12 over 300 vertices after eps 8: split (" .. #parts .. " parts)")
    for i, p in ipairs(parts) do
        checkDraft(t3, p, "F13 part " .. i)
        checkEq(p.part, i, "F14 part index " .. i)
        checkEq(p.partCount, #parts, "F15 part count " .. i)
        local nxt = parts[i + 1]
        if nxt then
            check(p.pts[#p.pts - 1] == nxt.pts[1] and p.pts[#p.pts] == nxt.pts[2], "F16 part " .. i .. " ends where the next starts")
        end
    end
    local total = 0
    for _, p in ipairs(parts) do total = total + math.floor(#p.pts / 2) - 1 end
    checkEq(total, 400, "F17 every zig-zag corner kept across parts (401 vertices)")
end

-- G. median / least grip per segment
do
    local t = fixture()
    local R = t.R
    local S = { "paved", "gravel", "paved", "unknown", "paved" }
    local W = { 5, 9, 6, 7, 5 }
    local M = { true, true, true, true, false }
    local w, s, m = R.segMeta(S, W, M, 1, 5)
    check(w == 7 and s == "gravel" and m, "G1 median of measured widths (5,6,7,9 -> 7), least grip gravel")
    local _, su = R.segMeta({ "unknown", "unknown" }, { 4, 4 }, { false, false }, 1, 3)
    checkEq(su, "unknown", "G2 unknown only when every sample is unknown")
    local _, sd = R.segMeta({ "unknown", "dirt" }, { 4, 4 }, { false, false }, 1, 3)
    checkEq(sd, "dirt", "G3 dirt beats unknown")
    local w2 = R.segMeta({ "paved" }, { 1 }, { true }, 1, 2)
    checkEq(w2, 3, "G4 width clamped to 3")
end

-- H. death / player gone / new game: drop and lost flag (read once)
do
    local t = fixture()
    begin(t, 5.5, 5.5)
    drive(t, { 5.5, 5.5, 20.5, 5.5 })
    t.events.OnPlayerDeath({})
    check(t.core.roadRecordState(0) ~= nil, "H1 another player's death does not stop recording")
    t.events.OnPlayerDeath(t.player)
    check(t.core.roadRecordState(0) == nil, "H2 own death drops the recording")
    checkEq(#t.tool, 0, "H3 nothing goes to review after death")
    checkEq(t.core.roadRecordLastLost(0), true, "H4 lost flag raised")
    checkEq(t.core.roadRecordLastLost(0), false, "H5 lost flag cleared after reading")
    check(not t.core.roadRecordStop(0), "H6 stop after loss does nothing")

    begin(t, 5.5, 5.5)
    t.players[0] = { getX = function() return 9 end, getY = function() return 9 end, getZ = function() return 0 end,
        getVehicle = function() end, isDead = function() return false end }
    t.events.OnTick()
    check(t.core.roadRecordState(0) == nil and t.core.roadRecordLastLost(0), "H7 respawned / replaced player: lost")
    t.players[0] = t.player
    begin(t, 5.5, 5.5)
    t.events.OnGameStart()
    check(t.core.roadRecordState(0) == nil and t.core.roadRecordLastLost(0), "H8 new game start: lost")
    t.events.OnGameStart()
    checkEq(t.core.roadRecordLastLost(0), false, "H9 game start without recording raises nothing")
end

-- I. too short: no review
do
    local t = fixture()
    begin(t, 5.5, 5.5)
    moveTo(t, 5.9, 5.5)
    check(not t.core.roadRecordStop(0), "I1 no movement: stop refuses")
    checkEq(#t.tool, 0, "I2 no review for a one-point recording")
    check(t.msgs[1] and t.msgs[1]:find("RoadRecTooShort", 1, true), "I3 too-short notice")
    checkEq(t.core.roadRecordLastLost(0), false, "I4 too short is not a loss")
end

-- J. driving in the right lane of an 8-wide road (2026-10-23 record-drive-sp: 37% of the paved
--    points "estimated" and the line zig-zagging between the centre and the lane): the lane side
--    holds more than 6 road tiles, so both edges must still be found and the point centred
do
    local t = fixture()
    local R = t.R
    paint(t, 0, 300, 100, 107, "blends_street_01_0") -- rows 100..107: 8 wide, centre y = 104
    local w, _, m, _, cy = R.sample(50.3, 106.4, 0, 1, 0)
    check(m and w == 8 and cy == 104, "J1 right lane of an 8-wide road: measured 8, centred (w=" .. tostring(w)
        .. " m=" .. tostring(m) .. " cy=" .. tostring(cy) .. ")")
    begin(t, 2.3, 106.4)
    drive(t, { 2.3, 106.4, 290.3, 106.4 })
    t.core.roadRecordStop(0)
    local d = t.tool[1].opts.draft
    checkDraft(t, d, "J2")
    checkEq(#d.pts / 2, 2, "J3 straight lane drive: two vertices")
    check(d.pts[2] == 104 and d.pts[4] == 104, "J4 both ends on the road centre line")
    check(d.measured[1] and d.segWidth[1] == 8, "J5 width measured 8")
    -- wider than MAX_W across: not a measurement
    paint(t, 0, 300, 200, 220, "blends_street_01_0") -- 21 wide
    local w2, _, m2 = R.sample(50.5, 210.5, 0, 1, 0)
    check(not m2 and w2 == R.DEFAULT_W, "J6 21 tiles across (> MAX_W): estimated")
end

-- K. side road junction: the lane side opens up for the side road's width; the point keeps the
--    lane offset instead of jumping back to the car, and the gap forces no vertex
do
    local t = fixture()
    paint(t, 0, 300, 100, 107, "blends_street_01_0")
    paint(t, 140, 145, 0, 99, "blends_street_01_0") -- 6-wide side road to the north
    begin(t, 2.3, 106.4)
    drive(t, { 2.3, 106.4, 290.3, 106.4 })
    local rec = t.R.recs[0]
    local gap = 0
    for i = 1, rec.n do if not rec.m[i] then gap = gap + 1 end end
    check(gap > 0 and gap <= 8, "K1 only the junction is unmeasured (" .. gap .. " points)")
    t.core.roadRecordStop(0)
    local d = t.tool[1].opts.draft
    checkDraft(t, d, "K2")
    checkEq(#d.pts / 2, 2, "K3 straight past the junction: two vertices")
    check(d.pts[2] == 104 and d.pts[4] == 104, "K4 on the centre line")
    check(d.measured[1] and d.segWidth[1] == 8, "K5 the junction gap does not make the segment estimated")
end

-- L. a centre tile off the road (shoulder, off-road) is never shifted by the carried lane offset
do
    local t = fixture()
    paint(t, 0, 100, 100, 107, "blends_street_01_0")
    begin(t, 2.3, 106.4)
    drive(t, { 2.3, 106.4, 100.3, 106.4, 110.3, 106.4 })
    local rec = t.R.recs[0]
    local moved = false
    for i = 1, rec.n do
        if rec.xs[i] >= 101 and (rec.cx[i] ~= rec.xs[i] or rec.cy[i] ~= rec.ys[i]) then moved = true end
    end
    check(not moved, "L1 off-road points stay where the car drove")
end

-- M. left turn at a junction (2026-10-23 record-drive-sp: a vertex off both roads and a 112 deg
--    "sharp turn" at the corner): cross-cuts through the junction grow wider than the road and
--    count as unmeasured, so every vertex stays on a road tile and the corner turns <= 100 deg
do
    for _, R0 in ipairs({ 3, 5, 8 }) do
        local t = fixture()
        paint(t, 0, 400, 100, 107, "blends_street_01_0")   -- E-W paved, 8 wide, centre y 104
        paint(t, 147, 152, 108, 400, "blends_street_01_48") -- N-S gravel, 6 wide, centre x 150
        -- westbound in the north lane, left turn into the southbound (west) lane
        local cx, cy = 148.4 + R0, 101.6 + R0
        local path = { 300.5, 101.6, cx, 101.6 }
        for a = 1, 18 do
            local th = math.pi / 2 + a * (math.pi / 2) / 18
            path[#path + 1] = cx + R0 * math.cos(th); path[#path + 1] = cy - R0 * math.sin(th)
        end
        path[#path + 1] = 148.4; path[#path + 1] = 300
        begin(t, 300.5, 101.6)
        drive(t, path)
        t.core.roadRecordStop(0)
        local d = t.tool[1].opts.draft
        checkDraft(t, d, "M1 r=" .. R0)
        local n = #d.pts / 2
        local onRoad, maxTurn = true, 0
        for k = 1, n do
            local x, y = d.pts[2 * k - 1], d.pts[2 * k]
            if not t.R.isRoadName(t.tiles[math.floor(x) .. "," .. math.floor(y)]) then onRoad = false end
            if k > 1 and k < n then
                local ax, ay = x - d.pts[2 * k - 3], y - d.pts[2 * k - 2]
                local bx, by = d.pts[2 * k + 1] - x, d.pts[2 * k + 2] - y
                local c = (ax * bx + ay * by) / math.sqrt((ax * ax + ay * ay) * (bx * bx + by * by))
                local deg = math.deg(math.acos(math.max(-1, math.min(1, c))))
                if deg > maxTurn then maxTurn = deg end
            end
        end
        check(onRoad, "M2 r=" .. R0 .. " every vertex on a road tile")
        check(maxTurn <= 100, string.format("M3 r=%d no turn sharper than 100 deg (%.0f)", R0, maxTurn))
        checkEq(d.pts[#d.pts - 1], 150, "M4 r=" .. R0 .. " ends on the gravel centre line")
    end
end

print(string.format("test_road_record: %d assertions, %d failures", assertions, failures))
if failures > 0 then os.exit(1) end
