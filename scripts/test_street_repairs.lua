-- 真 runtime 模組聯測：幾何修正與翻譯分離，隱藏標籤不能刪掉導航道路。
local root = arg[1] or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
local function javaList(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local function copy(points)
    local out = {}; for i = 1, #points do out[i] = points[i] end; return out
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local RECT = { 100, 100, 200, 100, 200, 110, 100, 110 }
local LINE = { 100, 105, 200, 105 }
local function rawStreet(points, name, width)
    local st = { points = copy(points), name = name or "Main", width = width or 8 }
    function st:getNumPoints() return #self.points / 2 end
    function st:getPointX(i) return self.points[i * 2 + 1] end
    function st:getPointY(i) return self.points[i * 2 + 2] end
    function st:getWidth() return self.width end
    function st:getTranslatedText() return self.name end
    function st:setTranslatedText(name) self.name = name end
    function st:removePoint(i) table.remove(self.points, i * 2 + 2); table.remove(self.points, i * 2 + 1) end
    function st:setPoint(i, x, y) self.points[i * 2 + 1], self.points[i * 2 + 2] = x, y end
    function st:addPoint(x, y) self.points[#self.points + 1] = x; self.points[#self.points + 1] = y end
    function st:clipToObscuredCells()
        -- 真 PZClipper probe 已驗證：兩重合點沒有 split，不會建立 hover 副本。
        if #self.points == 4 and self.points[1] == self.points[3] and self.points[2] == self.points[4] then
            self.split = nil
        else self.split = { name = self.name, points = copy(self.points) } end
    end
    st:clipToObscuredCells()
    return st
end
local function event()
    local fns = {}
    return { Add = function(fn) fns[#fns + 1] = fn end, fire = function() for _, fn in ipairs(fns) do fn() end end }
end
local function setup(op, lang, options)
    options = options or {}
    local street = rawStreet(options.points or RECT)
    local rel = "media/maps/Fixture/streets.xml"
    local referenceRel = options.carrier and "media/maps/Riverside, KY/streets.xml" or "media/maps/Muldraugh, KY/streets.xml"
    local data = { [rel] = { street } }
    if options.existingLine then table.insert(data[rel], 1, rawStreet(LINE, "Existing")) end
    if options.reference then data[referenceRel] = { rawStreet(options.reference) } end
    local visibleClears, scratchClears = 0, 0
    local function makeMap(scratch)
        local loaded, order, shown = {}, {}, {}
        local api = {
            addStreetData = function(_, path)
                if data[path] and not loaded[path] then
                    loaded[path] = data[path]; order[#order + 1] = data[path]
                    for _, st in ipairs(data[path]) do
                        if st.split then shown[#shown + 1] = { name = st.split.name, points = copy(st.split.points) } end
                    end
                end
            end,
            getStreetDataCount = function() return #order end,
            getStreetDataByIndex = function(_, at) return order[at + 1] end,
            getStreetDataByRelativeFileName = function(_, path) return loaded[path] end,
            clearStreetData = function()
                if scratch then scratchClears = scratchClears + 1 else visibleClears = visibleClears + 1 end
            end,
        }
        local mapAPI = { getStreetsAPI = function() return api end }
        return { javaObject = { getAPIv3 = function() return mapAPI end }, mapAPI = mapAPI }, shown, api
    end
    local ticks = event()
    local core = {
        ready = true, getBoolOption = function(_, d) return d end,
        getLoadedMapDirs = function() return { Fixture = 1, ["Muldraugh, KY"] = 2 } end,
        registeredPacks = { { owner = "Pack", entries = { {
            mapDir = "Fixture", mapMod = "FixtureMod",
            streetNames = not options.noNames and { Main = "UI_Fixture_name" } or nil,
            streetRepairs = { schemaVersion = 1, mapMod = options.owner or "FixtureMod", mapDir = "Fixture",
                operations = { [options.existingLine and 1 or 0] = op } },
        } } } },
    }
    local env = setmetatable({
        MinidoracatMiniMapCore = core, MinidoracatMiniMapAPI = {},
        Events = { OnTick = ticks, OnGameStart = event() },
        Translator = { getLanguage = function() return { name = function() return lang end } end },
        getTextOrNull = function()
            if options.translationError then error("bad translation formatter") end
            if not options.missingTranslation then return "Localized " .. lang end
        end,
        getActivatedMods = function() return javaList({ "FixtureMod" }) end,
        getLotDirectories = function() return javaList(options.reference and { "Fixture", "Muldraugh, KY" } or { "Fixture" }) end,
        fileExists = function(path)
            return data[path] ~= nil or (options.referenceOccluded == true and path:match("%.lotheader$") ~= nil)
                or (options.ownerCell == true and path:match("^media/maps/Fixture/.*%.lotheader$") ~= nil)
        end,
        getStreets = function(raw) return javaList(raw) end,
        getTimestampMs = function() return 1000 end,
        getSpecificPlayer = function() return { getX = function() return 100 end, getY = function() return 105 end, getVehicle = function() return nil end } end,
    }, { __index = _G })
    env.UIWorldMap = { new = function() return makeMap(true).javaObject end }
    local nestedShown
    env.MapUtils = { initDirectoryStreetData = function(ui, dir)
        ui.mapAPI:getStreetsAPI():addStreetData(dir .. "/streets.xml")
        if options.nestedNoReference then
            options.nestedNoReference = false
            local nested
            nested, nestedShown = makeMap(false)
            env.MapUtils.initDirectoryStreetData(nested, dir)
        end
        if options.loaderError then error("inner loader failure") end
    end }
    for _, file in ipairs({ "MinidoracatMiniMap_NavRoute.lua", "MinidoracatMiniMap_StreetData.lua", "MinidoracatMiniMap_StreetRepairs.lua" }) do
        assert(loadfile(root .. file, "t", env))()
    end
    local ui, shown, api = makeMap(false)
    if options.reference then api:addStreetData(referenceRel) end
    local ok, err = pcall(env.MapUtils.initDirectoryStreetData, ui, "media/maps/Fixture")
    return {
        core = core, api = env.MinidoracatMiniMapAPI, ticks = ticks, street = street,
        ui = ui, shown = shown, ok = ok, err = err,
        nestedShown = nestedShown,
        clears = function() return visibleClears, scratchClears end,
    }
end
local op = { expectedWidth = 8, expectedPoints = RECT, replacementPoints = LINE }
local baseRoute
for _, lang in ipairs({ "CH", "CN", "JP", "EN" }) do
    local w = setup(op, lang)
    assert(w.ok, w.err)
    assert(same(w.shown[1].points, LINE), lang .. " display must use repaired centerline")
    assert(same(w.street.points, RECT) and w.street.name == "Main", "source data must be restored")
    w.core.navKickEngine(w.ui)
    for _ = 1, 100 do w.ticks.fire() end
    local route, state = w.api.requestRoute(0, 200, 105)
    assert(state == "ok", tostring(state))
    assert(route.snapDist == 0 and route.len == 100, "centerline must be usable from its start")
    for i = 2, #route.pts, 2 do assert(route.pts[i] == 105, "navigation must not retain old outline edges") end
    if baseRoute then assert(same(route.pts, baseRoute), "route geometry must be language independent") else baseRoute = route.pts end
    assert(#w.core.navStreetIndex() == 1, "byIndex revisit must not reintroduce the unmodified outline")
    assert(w.clears() == 0, "player map must never be cleared")
end
local noNames = setup(op, "EN", { noNames = true })
assert(same(noNames.shown[1].points, LINE), "repair must not require a translation dictionary")
local drifted = copy(RECT); drifted[1] = drifted[1] + 1
local drift = setup(op, "CH", { points = drifted })
assert(same(drift.shown[1].points, drifted), "upstream geometry drift must not receive stale repair")
local wrongSource = setup(op, "CH", { owner = "OtherMod" })
assert(same(wrongSource.shown[1].points, RECT), "same coordinates from a different source must not be repaired")
local failed = setup(op, "JP", { loaderError = true })
assert(not failed.ok and tostring(failed.err):find("inner loader failure", 1, true))
assert(same(failed.street.points, RECT) and failed.street.name == "Main", "loader failure must restore names and all points")
local hiddenOp = { expectedWidth = 8, expectedPoints = LINE, hideLabel = true,
    reference = { index = 0, width = 8, points = LINE } }
local absent = setup(hiddenOp, "CH", { points = LINE })
assert(absent.shown[1].name ~= "", "no canonical source: keep label")
local masked = setup(hiddenOp, "CH", { points = LINE, reference = LINE })
assert(masked.ok, masked.err)
assert(#masked.shown == 1 and masked.shown[1].name == "Main", "only the canonical display copy remains")
assert(same(masked.street.points, LINE) and masked.street.name == "Main", "hidden duplicate remains intact in raw source")
masked.core.navKickEngine(masked.ui)
for _ = 1, 100 do masked.ticks.fire() end
local route, state = masked.api.requestRoute(0, 200, 105)
assert(state == "ok" and route.len == 100, "hiding a label must not remove navigation connectivity")
local clipped = setup(hiddenOp, "CH", { points = LINE, reference = LINE, referenceOccluded = true })
assert(#clipped.shown == 2 and clipped.shown[2].name ~= "", "canonical raw exists but is obscured: do not hide own label")
local movedRef = copy(LINE); movedRef[1] = 101
local referenceDrift = setup(hiddenOp, "CH", { points = LINE, reference = movedRef })
assert(#referenceDrift.shown == 2, "changed canonical geometry invalidates label suppression")

local duplicate = setup(op, "CH", { existingLine = true })
duplicate.core.navKickEngine(duplicate.ui)
for _ = 1, 100 do duplicate.ticks.fire() end
assert(#duplicate.core.navStreetIndex() == 1, "effective duplicate must still mark its raw signature before byIndex revisit")
local nested = setup(hiddenOp, "CH", { points = LINE, reference = LINE, nestedNoReference = true })
assert(nested.ok, nested.err)
assert(#nested.shown == 1 and #nested.nestedShown == 1, "inner map without reference retains its own label")
assert(nested.nestedShown[1].name ~= "" and same(nested.nestedShown[1].points, LINE), "inner map must not inherit outer masking")
assert(same(nested.street.points, LINE) and nested.street.name == "Main", "nested windows restore the raw source")
local fractional = setup({ expectedWidth = 8, expectedPoints = RECT, replacementPoints = {100,105.1,200,105.1} }, "CH")
assert(same(fractional.street.points, RECT) and same(fractional.shown[1].points, RECT), "non-float32 replacement must be rejected on both consumers")
local tooLong = {}; for i = 0, 384 do tooLong[#tooLong + 1] = 100 + i; tooLong[#tooLong + 1] = 105 end
local oversized = setup({ expectedWidth = 8, expectedPoints = RECT, replacementPoints = tooLong }, "CH")
assert(same(oversized.shown[1].points, RECT), "native clip buffer overflow must be rejected before display")
assert(oversized.core.streetRepair(oversized.street, "Fixture", 0) == nil, "Nav must reject the same oversized operation")
local owner = setup(hiddenOp, "CH", { points = LINE, reference = LINE, carrier = true, ownerCell = true })
assert(#owner.shown == 2, "visible carrier must not replace a different local road name on the owning map")
local sameName = setup(hiddenOp, "EN", { points = LINE, reference = LINE, carrier = true, ownerCell = true })
assert(#sameName.shown == 1, "identical visible labels may still be deduplicated")
local degenerate = setup({ expectedWidth = 8, expectedPoints = RECT, replacementPoints = {100,100,100,100} }, "EN")
assert(same(degenerate.shown[1].points, RECT), "navigation repair cannot delete a road through degenerate geometry")
local badTranslation = setup(op, "CH", { translationError = true })
assert(badTranslation.ok and same(badTranslation.shown[1].points, LINE), "translation failure cannot disable geometry repair")
badTranslation.core.navKickEngine(badTranslation.ui)
for _ = 1, 100 do badTranslation.ticks.fire() end
local badTrRoute, badTrState = badTranslation.api.requestRoute(0, 200, 105)
assert(badTrState == "ok" and badTrRoute.len == 100, "translation failure cannot disable navigation")
print("test_street_repairs: PASS (four languages, live navigation, source drift, restore, independent dictionaries)")
