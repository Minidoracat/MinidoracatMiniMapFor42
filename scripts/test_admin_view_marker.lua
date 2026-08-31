-- ADMIN VIEW marker: visibility, memoization, Skin fallback and log-once wiring.
local mainPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local wmPath = arg[2]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_WorldMapNav.lua"
local function read(path)
    local fh = assert(io.open(path, "rb"))
    local text = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    return text
end
local source, wmSource = read(mainPath), read(wmPath)
local body = assert(source:match(
    "%-%- test:admin%-view%-marker:start\n(.-)\n%-%- test:admin%-view%-marker:end"),
    "missing admin view marker test block")
local compile = loadstring or load
local prefix = [==[
local tactical, privacy = false, false
local measureCount, measureMode, skinMode = 0, "ok", "ok"
local logs = {}
local lastPn
local Policy = {
    tacticalActive = function(pn) lastPn = pn; return tactical end,
    privacyActive = function(pn) lastPn = pn; return privacy end,
}
local UIFont = { Small = "Small" }
local function getText() return "ADMIN VIEW" end
local function getTextManager()
    return {
        MeasureStringX = function()
            measureCount = measureCount + 1
            if measureMode == "throw" then error("measure boom") end
            if measureMode == "nil" then return nil end
            return 80
        end,
        getFontHeight = function() return measureMode == "nil" and nil or 14 end,
    }
end
local function log(message) logs[#logs + 1] = message end
local Core = { Skin = {
    COLORS = { BG_PANEL = {}, ACCENT_AMBER = {} },
    fill = function(inner, x, y, w, h)
        if skinMode == "throw" then error("skin boom") end
        inner.fills = inner.fills + 1
        inner.lastW, inner.lastH = w, h
    end,
    border = function(inner) inner.borders = inner.borders + 1 end,
} }
]==]
local tail = [==[
return {
    draw = drawAdminViewMarker,
    setActive = function(t, p) tactical, privacy = t, p end,
    setSkin = function(mode) skinMode = mode end,
    setMeasure = function(mode) measureMode = mode end,
    measures = function() return measureCount end,
    logs = logs,
    lastPn = function() return lastPn end,
}
]==]
local chunk, err = compile(prefix .. "\n" .. body .. "\n" .. tail, "@admin-marker")
assert(chunk, err)
local h = chunk()
local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
local function logCount(fragment)
    local count = 0
    for i = 1, #h.logs do
        if h.logs[i]:find(fragment, 1, true) then count = count + 1 end
    end
    return count
end
local function element(pn)
    return {
        playerNum = pn, fills = 0, borders = 0, rects = 0, texts = 0,
        drawRect = function(self) self.rects = self.rects + 1 end,
        drawRectBorder = function(self) self.borders = self.borders + 1 end,
        drawText = function(self) self.texts = self.texts + 1 end,
    }
end

local normal = element(2)
h.draw(normal)
check(normal.texts == 0 and h.measures() == 0 and h.lastPn() == 2,
    "no bypass draws no marker and preserves player slot")

h.setActive(true, false)
local admin = element(1)
h.draw(admin)
check(admin.fills == 1 and admin.borders == 1 and admin.texts == 1,
    "tactical bypass draws Skin marker")
check(h.measures() == 1 and h.lastPn() == 1,
    "marker measures once and uses owner slot")
h.draw(admin)
check(h.measures() == 1 and admin.texts == 2,
    "marker memoizes translated text metrics")

h.setMeasure("throw")
local measureFallback = element(0)
h.draw(measureFallback); h.draw(measureFallback)
check(measureFallback.fills == 2 and measureFallback.texts == 2,
    "measurement exception keeps marker visible with fixed metrics")
check(h.measures() == 2 and logCount("measurement failed") == 1,
    "failed metrics are memoized and logged once")
check(type(measureFallback.lastW) == "number" and measureFallback.lastW >= 72
    and type(measureFallback.lastH) == "number" and measureFallback.lastH > 0,
    "measurement exception commits numeric fallback metrics")

h.setMeasure("nil")
local nilMetrics = element(0)
h.draw(nilMetrics)
check(nilMetrics.fills == 1 and nilMetrics.texts == 1,
    "nil metrics keep marker visible")
check(logCount("measurement failed") == 2,
    "each affected map instance reports invalid metrics once")
check(type(nilMetrics.lastW) == "number" and type(nilMetrics.lastH) == "number",
    "invalid metrics commit numeric fallback metrics")
h.setMeasure("ok")

h.setSkin("throw")
local fallback = element(0)
h.draw(fallback); h.draw(fallback)
check(fallback.rects == 2 and fallback.borders == 2 and fallback.texts == 2,
    "Skin failure falls back to rectangular marker every frame")
check(logCount("skin failed") == 1,
    "Skin failure logs once")

check(source:find("pcall%(drawAdminViewMarker, self%)") ~= nil
    and source:find("_minidoracatAdminMarkErrLogged", 1, true) ~= nil,
    "minimap prerender calls marker with log-once error handling")
check(wmSource:find("pcall%(Core%.drawAdminViewMarker, self%)") ~= nil
    and wmSource:find("_minidoracatWMAdminMarkErrLogged", 1, true) ~= nil,
    "world map prerender calls marker with log-once error handling")

local EXPECTED_ASSERTIONS = 14
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS
        .. ", actual " .. assertions)
    os.exit(1)
end
print("admin view marker assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
