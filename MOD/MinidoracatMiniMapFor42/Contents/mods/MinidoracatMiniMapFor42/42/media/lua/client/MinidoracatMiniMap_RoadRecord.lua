-- MinidoracatMiniMap_RoadRecord.lua
-- Custom roads: record a road while driving (design claim 2).
-- idle -> recording (Core.roadRecordStart) -> review (Core.roadRecordStop simplifies, then
-- RoadEditor Core.roadToolStart(pn, {mode="review", draft=...})); death / leaving -> lost.
-- OnTick only compares distance; a point (plus floor reads) is taken after moving >= STEP.
-- Surface table mirrors AutoDrive floorSurfaceId (MDAD_Sensor.lua:316-345) and the renderer
-- classify_tile (MinidoracatMapRendering src/road_surface.rs:72-109).
-- Engine API: getSpecificPlayer / getVehicle / getX / getY / getZ (ISVehicleMenu.lua, IsoMovingObject);
-- getCell():getGridSquare (ISWorldObjectContextMenu.lua); square:getObjects, obj:getSprite,
-- sprite:getProperties, props:has(IsoFlagType.*), obj:getSpriteName (MDAD_Sensor.lua:372-390, 1363);
-- OnPlayerDeath (ISPlayerData.lua), OnGameStart / OnTick (see _Itinerary.lua tail).
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.roadRecordStart then return end

local Rec = {}
Core.roadRecord = Rec -- tests and diagnostics read the helpers
local Codec = MinidoracatMiniMapRoadCodec

Rec.STEP = 1.0             -- one point per tile moved
Rec.RAW_MAX = 20000        -- raw points (~20 km); reaching it auto-stops into review
Rec.PTS_MAX = Codec and Codec.MAX_POINTS or 300
Rec.MIN_W = Codec and Codec.MIN_WIDTH or 3
Rec.MAX_W = Codec and Codec.MAX_WIDTH or 16
Rec.DEFAULT_W = 4          -- save form "narrow 4" default; used where width was not measured
Rec.SCAN = 6               -- tiles scanned to each side for the road edge
Rec.BACK_COS = -0.8660254  -- cos(150 deg): turn sharper than this is a reversal tip
Rec.BACK_ARM = 6           -- reversal legs shorter than this are dropped
Rec.RDP_CHUNK = 256       -- pass-1 RDP run length (bounds the O(n^2) worst case)
Rec.EPS0, Rec.EPS_GROW, Rec.EPS_MAX = 0.75, 1.5, 8
Rec.DEBOUNCE = 3           -- a surface / width class change must hold this many points to force a vertex

local recs, lost = {}, {}  -- per player slot
local SURF = { "unknown", "paved", "gravel", "dirt" } -- index = grip rank + 1 (higher = less grip)
Rec.recs, Rec.lost = recs, lost
local RANK = { unknown = 0, paved = 1, gravel = 2, dirt = 3 }

-- Surface table (AutoDrive floorSurfaceId; vanilla ISShovelGroundCursor.lua:108-130)
local GRAVEL = { floors_exterior_natural_01_13 = true, blends_street_01_48 = true,
    blends_street_01_53 = true, blends_street_01_54 = true, blends_street_01_55 = true }
local SAND_CLAY = { blends_natural_01_0 = true, blends_natural_01_5 = true, blends_natural_01_6 = true,
    blends_natural_01_7 = true, floors_exterior_natural_01_24 = true, blends_natural_01_96 = true,
    blends_natural_01_101 = true, blends_natural_01_102 = true, blends_natural_01_103 = true }
-- dirt -> grass blend edge: narrow dirt trails are made of these (road_surface.rs DirtEdge)
local DIRT_EDGE = {}
for i = 64, 71 do DIRT_EDGE["blends_natural_01_" .. i] = true end

function Rec.starts(s, p) return string.sub(s, 1, #p) == p end

function Rec.surfaceOf(name)
    if type(name) ~= "string" then return "unknown" end
    local starts = Rec.starts
    if GRAVEL[name] or starts(name, "street_curbs_01_blend_gravel") then return "gravel" end
    if SAND_CLAY[name] or starts(name, "carpentry_02") then return "unknown" end
    if starts(name, "street_curbs_01_blend_dirt") or starts(name, "blends_natural_01_")
            or starts(name, "floors_exterior_natural") then return "dirt" end
    if starts(name, "blends_street") or starts(name, "floors_exterior_street")
            or starts(name, "street_curbs") then return "paved" end
    return "unknown"
end

-- Road edge test: paved, gravel and dirt-trail edge are road; grass and plain dirt are not.
function Rec.isRoadName(name)
    if type(name) ~= "string" then return false end
    if DIRT_EDGE[name] then return true end
    local s = Rec.surfaceOf(name)
    return s == "paved" or s == "gravel"
end

-- First solid floor that is not water (AutoDrive waterUnderfoot): bridge squares stack
-- water / street / deck and getFloor() returns the water at the bottom.
function Rec.dryFloorName(sq)
    if not sq then return nil end
    local objs = sq:getObjects()
    if not objs then return nil end
    local water, solid = IsoFlagType.water, IsoFlagType.solidfloor
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        local sp = obj:getSprite()
        local props = sp and sp:getProperties()
        if props and not props:has(water) and props:has(solid) then return obj:getSpriteName() end
    end
    return nil
end

-- Road tiles from the origin outward along (dx, dy); nil = no edge within SCAN tiles.
function Rec.scan(cell, ox, oy, z, dx, dy)
    for k = 1, Rec.SCAN do
        local sq = cell:getGridSquare(math.floor(ox + k * dx), math.floor(oy + k * dy), z)
        if not Rec.isRoadName(Rec.dryFloorName(sq)) then return k - 1 end
    end
    return nil
end

-- One sample at (x, y) heading (hx, hy) (unit). Returns width, surface, measured, cx, cy:
-- both edges found -> width = left + right + 1 and the point moves to the road centre;
-- otherwise DEFAULT_W, measured=false and the driven position.
function Rec.sample(x, y, z, hx, hy)
    local cell = getCell()
    local tx, ty = math.floor(x), math.floor(y)
    local name = Rec.dryFloorName(cell:getGridSquare(tx, ty, z))
    local s = Rec.surfaceOf(name)
    if not Rec.isRoadName(name) then return Rec.DEFAULT_W, s, false, x, y end
    local ox, oy = tx + 0.5, ty + 0.5
    local l = Rec.scan(cell, ox, oy, z, hy, -hx)  -- left of travel (y grows south)
    local r = Rec.scan(cell, ox, oy, z, -hy, hx)  -- right of travel
    if not (l and r) then return Rec.DEFAULT_W, s, false, x, y end
    local off = (r - l) / 2
    return l + r + 1, s, true, ox - off * hy, oy + off * hx
end

function Rec.measure(rec, i, z, hx, hy)
    local w, s, m, cx, cy = Rec.sample(rec.xs[i], rec.ys[i], z, hx, hy)
    rec.w[i], rec.s[i], rec.m[i], rec.cx[i], rec.cy[i] = w, s, m, cx, cy
    local st = rec.state
    st.surface, st.measured, st.width = s, m, m and w or nil
end

-- Append a raw point; samples need a heading, so point 1 is measured when point 2 arrives.
function Rec.push(rec, x, y, z)
    local n = rec.n
    local hx, hy
    if n > 0 then
        local dx, dy = x - rec.xs[n], y - rec.ys[n]
        local d = math.sqrt(dx * dx + dy * dy)
        rec.len = rec.len + d
        rec.state.km = rec.len / 1000
        hx, hy = dx / d, dy / d
    end
    n = n + 1
    rec.n, rec.xs[n], rec.ys[n] = n, x, y
    if n == 1 then rec.z1 = z; return end
    if n == 2 then Rec.measure(rec, 1, rec.z1, hx, hy) end
    Rec.measure(rec, n, z, hx, hy)
end

function Rec.tick(pn)
    local rec = recs[pn]
    local p = getSpecificPlayer(pn)
    if not p or p ~= rec.player or p:isDead() then return Rec.drop(pn) end
    local who = p:getVehicle() or p -- in a car: record the car's position
    local x, y = who:getX(), who:getY()
    local n = rec.n
    local dx, dy = x - rec.xs[n], y - rec.ys[n]
    if dx * dx + dy * dy < Rec.STEP * Rec.STEP then return end
    if n >= Rec.RAW_MAX then return Core.roadRecordStop(pn, "toolong") end
    Rec.push(rec, x, y, math.floor(who:getZ()))
end

-- Death / leaving: points are discarded and the lost flag is raised for the UI.
function Rec.drop(pn)
    if recs[pn] then recs[pn] = nil; lost[pn] = true end
end

-- Indices kept after removing reversal legs (tips turning > 150 deg whose leg is < BACK_ARM).
-- Detection uses the driven positions: centred points can zig-zag when an edge is missed.
function Rec.dropBacktrack(xs, ys, n)
    local L, tips, nt = { 0 }, {}, 0
    for i = 2, n do
        local dx, dy = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
        L[i] = L[i - 1] + math.sqrt(dx * dx + dy * dy)
    end
    for i = 2, n - 1 do
        local ax, ay = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
        local bx, by = xs[i + 1] - xs[i], ys[i + 1] - ys[i]
        local den = math.sqrt((ax * ax + ay * ay) * (bx * bx + by * by))
        if den > 0 and (ax * bx + ay * by) / den < Rec.BACK_COS then nt = nt + 1; tips[nt] = i end
    end
    local drop, used = {}, {}
    local function cut(a, b) for i = a, b do drop[i] = true end end
    local j = 1
    -- back then forward again: drop the reverse leg and the same length of the outbound pass
    -- before it, so the path resumes forward where the reverse leg ended
    while j < nt do
        local t1, t2 = tips[j], tips[j + 1]
        local back = L[t2] - L[t1]
        if back < Rec.BACK_ARM then
            local a = t1
            while a > 1 and L[t1] - L[a - 1] <= back do a = a - 1 end
            cut(a, t2); used[j], used[j + 1] = true, true; j = j + 2
        else
            j = j + 1
        end
    end
    for k = 1, nt do -- short reversal right after the start: start at the tip
        if not used[k] then
            if L[tips[k]] < Rec.BACK_ARM then cut(1, tips[k] - 1) end
            break
        end
    end
    for k = nt, 1, -1 do -- short reversal at the end: end at the tip
        if not used[k] then
            if L[n] - L[tips[k]] < Rec.BACK_ARM then cut(tips[k] + 1, n) end
            break
        end
    end
    local out, m = {}, 0
    for i = 1, n do if not drop[i] then m = m + 1; out[m] = i end end
    return out, m
end

function Rec.widthClass(w) if w <= 4 then return 1 elseif w <= 7 then return 2 end return 3 end

-- Must-keep flags: ends, plus every point where the surface or width class changes and the
-- new class holds DEBOUNCE points (single noisy samples do not burn the 300-point budget).
function Rec.metaBreaks(S, W, M, m)
    local key = {}
    for i = 1, m do key[i] = RANK[S[i]] * 10 + (M[i] and Rec.widthClass(W[i]) or 0) end
    local keep, cur = { [1] = true, [m] = true }, key[1]
    for i = 2, m do
        if key[i] ~= cur then
            local held = true
            for j = i + 1, math.min(m, i + Rec.DEBOUNCE - 1) do
                if key[j] ~= key[i] then held = false; break end
            end
            if held then keep[i] = true; cur = key[i] end
        end
    end
    return keep
end

function Rec.segDist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and ((px - ax) * dx + (py - ay) * dy) / len2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local ex, ey = ax + t * dx - px, ay + t * dy - py
    return math.sqrt(ex * ex + ey * ey)
end

-- Ramer-Douglas-Peucker once, recording for every point the largest epsilon that still keeps
-- it (min of its split distance and its parent's): RDP(eps) keeps exactly imp[i] > eps, so
-- trying growing epsilons costs one pass. Points never split at EPS0 get 0; must-keeps huge.
function Rec.rdpImportance(X, Y, m, keep)
    local HUGE = 1e30
    local imp = {}
    for i = 1, m do imp[i] = keep[i] and HUGE or 0 end
    local sa, sb, sp, top = {}, {}, {}, 0
    local prev = 1
    for i = 2, m do
        if keep[i] then top = top + 1; sa[top], sb[top], sp[top] = prev, i, HUGE; prev = i end
    end
    while top > 0 do
        local a, b, pimp = sa[top], sb[top], sp[top]
        top = top - 1
        local best, bk = Rec.EPS0, nil
        for k = a + 1, b - 1 do
            local d = Rec.segDist(X[k], Y[k], X[a], Y[a], X[b], Y[b])
            if d > best then best, bk = d, k end
        end
        if bk then
            local v = best < pimp and best or pimp
            imp[bk] = v
            top = top + 1; sa[top], sb[top], sp[top] = a, bk, v
            top = top + 1; sa[top], sb[top], sp[top] = bk, b, v
        end
    end
    return imp
end

function Rec.half(v) return math.floor(v * 2 + 0.5) / 2 end

-- Segment metadata over filtered samples [a, b): width = median of measured widths when at
-- least half were measured (else DEFAULT_W, measured=false); surface = least grip seen,
-- unknown only when every sample is unknown.
function Rec.segMeta(S, W, M, a, b)
    local rank, mc, hist = 0, 0, {}
    for i = a, b - 1 do
        local r = RANK[S[i]]
        if r > rank then rank = r end
        if M[i] then mc = mc + 1; hist[W[i]] = (hist[W[i]] or 0) + 1 end
    end
    local surf = SURF[rank + 1]
    if mc * 2 < b - a then return Rec.DEFAULT_W, surf, false end
    local lo, hi = math.floor((mc + 1) / 2), math.floor(mc / 2) + 1 -- median ranks (equal when odd)
    local seen, wlo, whi = 0, nil, nil
    for w = 1, 64 do
        local c = hist[w]
        if c then
            seen = seen + c
            if not wlo and seen >= lo then wlo = w end
            if seen >= hi then whi = w; break end
        end
    end
    local w = math.floor((wlo + whi) / 2 + 0.5)
    if w < Rec.MIN_W then w = Rec.MIN_W elseif w > Rec.MAX_W then w = Rec.MAX_W end
    return w, surf, true
end

-- rec -> list of drafts (end-to-end parts, each <= PTS_MAX points), or nil when too short.
function Rec.finish(rec)
    if rec.n < 2 then return nil end
    local idx, m = Rec.dropBacktrack(rec.xs, rec.ys, rec.n)
    local X, Y, W, S, M = {}, {}, {}, {}, {}
    for k = 1, m do
        local i = idx[k]
        X[k], Y[k], W[k], S[k], M[k] = rec.cx[i], rec.cy[i], rec.w[i], rec.s[i], rec.m[i]
    end
    if m < 2 then return nil end
    local keep = Rec.metaBreaks(S, W, M, m)
    -- Plain RDP is O(n^2) on an even wiggle (the max sits at one end every split; 20000 points
    -- took 1.2 s in Lua 5.4). Pass 1 runs RDP at EPS0 inside RDP_CHUNK-point runs (cuts kept);
    -- pass 2 ranks the survivors exactly, so only the EPS0 pre-pass error is added.
    local keep1, last = {}, 1
    for i = 1, m do
        if keep[i] or i - last >= Rec.RDP_CHUNK then keep1[i] = true; last = i end
    end
    local imp1 = Rec.rdpImportance(X, Y, m, keep1)
    local J, X2, Y2, K2, n2 = {}, {}, {}, {}, 0
    for i = 1, m do
        if imp1[i] > Rec.EPS0 then n2 = n2 + 1; J[n2], X2[n2], Y2[n2], K2[n2] = i, X[i], Y[i], keep[i] end
    end
    local imp = Rec.rdpImportance(X2, Y2, n2, K2)
    local eps, sel, cnt = Rec.EPS0, nil, 0
    repeat
        sel, cnt = eps, 0
        for j = 1, n2 do if imp[j] > sel then cnt = cnt + 1 end end
        eps = eps * Rec.EPS_GROW
    until cnt <= Rec.PTS_MAX or eps > Rec.EPS_MAX
    -- kept vertices on the 0.5 grid; a vertex landing on the previous one is merged into it
    local K, RX, RY, k = {}, {}, {}, 0
    for j = 1, n2 do
        if imp[j] > sel then
            local i = J[j]
            local x, y = Rec.half(X[i]), Rec.half(Y[i])
            if k > 0 and x == RX[k] and y == RY[k] then
                if i == m then K[k] = i end
            else
                k = k + 1; K[k], RX[k], RY[k] = i, x, y
            end
        end
    end
    if k < 2 then return nil end
    local raw = {}
    for i = 1, rec.n do raw[2 * i - 1], raw[2 * i] = rec.xs[i], rec.ys[i] end
    local drafts, nd, s = {}, 0, 1
    repeat
        local e = math.min(s + Rec.PTS_MAX - 1, k)
        local d = { pts = {}, segWidth = {}, segSurface = {}, measured = {}, ends = { "snap", "snap" },
            source = "record", raw = raw, rawN = rec.n }
        for j = s, e do
            local o = j - s
            d.pts[2 * o + 1], d.pts[2 * o + 2] = RX[j], RY[j]
            if j < e then
                d.segWidth[o + 1], d.segSurface[o + 1], d.measured[o + 1] = Rec.segMeta(S, W, M, K[j], K[j + 1])
            end
        end
        nd = nd + 1; drafts[nd] = d
        s = e
    until s >= k
    for i = 1, nd do drafts[i].part, drafts[i].partCount = i, nd end
    if nd > 1 then
        local rest = {}
        for i = 2, nd do rest[i - 1] = drafts[i] end
        drafts[1].parts = rest
    end
    return drafts
end

-- Title bar status (titleStatusApiVersion 1), registered on the first recording so the
-- title bar stays un-hooked for players who never record. "warn" = red recording look.
function Rec.titleStatus(pn)
    local st = Core.roadRecordState(pn)
    if not st then return nil end
    local km = string.format("%.1f", st.km)
    if not st.surface then return getText("UI_MinidoracatMiniMap_RoadRecTitle", km), "warn" end
    local surf = getText("UI_MinidoracatMiniMap_RoadSurface_" .. st.surface)
    if st.measured then
        return getText("UI_MinidoracatMiniMap_RoadRecTitleWidth", km, surf, tostring(st.width)), "warn"
    end
    return getText("UI_MinidoracatMiniMap_RoadRecTitleSurface", km, surf), "warn"
end

Core.roadRecordStart = function(pn)
    if recs[pn] then return false end
    local p = getSpecificPlayer(pn)
    if not p or p:isDead() then return false end
    if not Rec.titleRegistered then
        local api = MinidoracatMiniMapAPI
        if api and api.registerTitleStatus then
            Rec.titleRegistered = api.registerTitleStatus("MinidoracatMiniMapRoadRecord", Rec.titleStatus)
        end
    end
    local rec = { player = p, n = 0, len = 0, xs = {}, ys = {}, cx = {}, cy = {}, w = {}, s = {}, m = {},
        state = { km = 0 } }
    recs[pn] = rec
    local who = p:getVehicle() or p
    Rec.push(rec, who:getX(), who:getY(), math.floor(who:getZ()))
    return true
end

-- Stop -> simplify -> review. why == "toolong" is the automatic stop at RAW_MAX.
-- Returns false when nothing was recording or the road is too short to keep.
Core.roadRecordStop = function(pn, why)
    local rec = recs[pn]
    if not rec then return false end
    recs[pn] = nil
    if why == "toolong" and Core.navMessage then
        Core.navMessage(pn, getText("UI_MinidoracatMiniMap_RoadRecTooLong"), false)
    end
    local drafts = Rec.finish(rec)
    if not drafts then
        if Core.navMessage then Core.navMessage(pn, getText("UI_MinidoracatMiniMap_RoadRecTooShort"), false) end
        return false
    end
    if Core.roadToolStart then
        Core.roadToolStart(pn, { mode = "review", draft = drafts[1] })
    elseif Core.roadsSetDraft then -- editor missing: keep the recording as an unsaved draft
        Core.roadsSetDraft(pn, drafts[1])
    end
    return true
end

-- nil when not recording; otherwise { km=, surface=, width=, measured= } (width nil = not measured)
Core.roadRecordState = function(pn)
    local rec = recs[pn]
    return rec and rec.state or nil
end

-- true once after a recording was lost to death or leaving the game (read clears it)
Core.roadRecordLastLost = function(pn)
    local v = lost[pn] == true
    lost[pn] = nil
    return v
end

Events.OnTick.Add(function()
    for pn = 0, 3 do
        if recs[pn] then
            local ok, err = pcall(Rec.tick, pn)
            if not ok then
                print("[MinidoracatMiniMap] road record tick failed: " .. tostring(err))
                Rec.drop(pn)
            end
        end
    end
end)
-- OnPlayerDeath can also fire for other players in MP: only the recording player counts.
Events.OnPlayerDeath.Add(function(p)
    for pn = 0, 3 do
        local rec = recs[pn]
        if rec and rec.player == p then Rec.drop(pn) end
    end
end)
-- Client Lua is not reloaded between saves: a recording alive at the next game start was left behind.
Events.OnGameStart.Add(function()
    for pn = 0, 3 do Rec.drop(pn) end
end)
