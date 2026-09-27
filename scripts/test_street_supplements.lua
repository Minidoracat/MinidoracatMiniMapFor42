-- 真 runtime 模組聯測：addon 補充道路（作者沒放進 streets.xml 的路）掛進玩家地圖後，
-- 顯示譯名、搜尋原名／譯名、導航都讀同一份；作者資料一變（街道數不同）或檔案條數不符就整份不掛。
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
local SUP_NAME = "Fixture Rd 01 (MiniMap)"
local SUP_LINE = { 100, 105, 200, 105 }
local SUP_FILE = "media/minimap/streets/fixture.xml"
local OWN_FILE = "media/maps/Fixture/streets.xml"
local function rawStreet(points, name, width)
    local st = { points = copy(points), name = name, width = width or 6 }
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

local function setup(lang, options)
    options = options or {}
    local supStreet = rawStreet(SUP_LINE, SUP_NAME)
    local data = { [SUP_FILE] = { supStreet } }
    if options.extraSupplementStreet then data[SUP_FILE][2] = rawStreet({ 100, 300, 200, 300 }, "Fixture Rd 02 (MiniMap)") end
    local ownStreet
    if options.ownStreets then
        -- 作者自己的街：index 0 與補充檔 index 0 撞號，驗補充道路不吃作者 XML 的修正
        ownStreet = rawStreet({ 100, 400, 200, 400 }, "Own St")
        data[OWN_FILE] = { ownStreet }
    end
    local visibleClears, scratchClears = 0, 0
    local function makeMap(scratch)
        local loaded, order, shown = {}, {}, {}
        local api = {
            addStreetData = function(_, path)
                if data[path] and not loaded[path] then
                    loaded[path] = data[path]; order[#order + 1] = data[path]
                    for _, st in ipairs(data[path]) do
                        if st.split then shown[#shown + 1] = { name = st.split.name, points = copy(st.split.points), file = path } end
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
    local sup = {
        schemaVersion = 1, mapMod = "FixtureMod", mapDir = "Fixture", file = options.file or SUP_FILE,
        upstreamStreetCount = options.pinCount or 0, roadCount = options.roadCount or 1,
        names = { [SUP_NAME] = "UI_Fixture_road_01" },
    }
    local repairs = options.ownStreets and {
        schemaVersion = 1, mapMod = "FixtureMod", mapDir = "Fixture",
        operations = { [0] = { expectedWidth = 6, expectedPoints = { 100, 400, 200, 400 },
            replacementPoints = { 100, 401, 200, 401 } } },
    } or nil
    local ticks = event()
    local core = {
        ready = true, getBoolOption = function(_, d) return d end,
        getLoadedMapDirs = function()
            if options.occluded then return { Other = 1, Fixture = 2 } end
            return { Fixture = 1 }
        end,
        registeredPacks = { { owner = "Pack", entries = { {
            mapDir = "Fixture", mapMod = "FixtureMod", streetSupplement = sup, streetRepairs = repairs,
        } } } },
    }
    local logs = {}
    local env = setmetatable({
        MinidoracatMiniMapCore = core, MinidoracatMiniMapAPI = {},
        Events = { OnTick = event(), OnTickEvenPaused = ticks, OnGameStart = event() },
        Translator = { getLanguage = function() return { name = function() return lang end } end },
        getTextOrNull = function(key)
            if key == "UI_Fixture_road_01" then return "Localized " .. lang end
        end,
        getActivatedMods = function() return javaList(options.inactive and {} or { "FixtureMod" }) end,
        getLotDirectories = function() return javaList(options.occluded and { "Other", "Fixture" } or { "Fixture" }) end,
        fileExists = function(path)
            if data[path] ~= nil then return true end
            -- 遮蔽：Other 佔 Fixture 所有 300 格（lotheader 兩角都在）
            return options.occluded == true and path:match("^media/maps/Other/.*%.lotheader$") ~= nil
        end,
        getStreets = function(raw) return javaList(raw) end,
        getTimestampMs = function() return 1000 end,
        getSpecificPlayer = function() return { getX = function() return 100 end, getY = function() return 105 end, getVehicle = function() return nil end } end,
        print = function(msg) logs[#logs + 1] = tostring(msg) end,
    }, { __index = _G })
    env.UIWorldMap = { new = function() return makeMap(true).javaObject end }
    env.MapUtils = { initDirectoryStreetData = function(ui, dir)
        ui.mapAPI:getStreetsAPI():addStreetData(dir .. "/streets.xml")
    end }
    for _, file in ipairs({ "MinidoracatMiniMap_NavRoute.lua", "MinidoracatMiniMap_StreetData.lua", "MinidoracatMiniMap_StreetRepairs.lua" }) do
        assert(loadfile(root .. file, "t", env))()
    end
    local ui, shown = makeMap(false)
    local ok, err = pcall(env.MapUtils.initDirectoryStreetData, ui, "media/maps/Fixture")
    local function logged(needle)
        for _, line in ipairs(logs) do if line:find(needle, 1, true) then return true end end
        return false
    end
    local function route()
        core.navKickEngine(ui)
        for _ = 1, 100 do ticks.fire() end
        return env.MinidoracatMiniMapAPI.requestRoute(0, 200, 105)
    end
    return {
        core = core, ui = ui, shown = shown, ok = ok, err = err, supStreet = supStreet, ownStreet = ownStreet,
        logged = logged, route = route, clears = function() return visibleClears, scratchClears end,
    }
end

local function shownFrom(w, file)
    local out = {}
    for _, s in ipairs(w.shown) do if s.file == file then out[#out + 1] = s end end
    return out
end
local function indexFor(w, low)
    for _, e in ipairs(w.core.navStreetIndex() or {}) do
        if e.low == low or e.originalLow == low then return e end
    end
end

for _, lang in ipairs({ "CH", "CN", "JP", "EN" }) do
    local w = setup(lang)
    assert(w.ok, w.err)
    local sup = shownFrom(w, SUP_FILE)
    assert(#sup == 1, lang .. " supplement must be mounted on the player map")
    local expected = lang == "EN" and SUP_NAME or ("Localized " .. lang)
    assert(sup[1].name == expected, lang .. " display name: " .. tostring(sup[1].name))
    assert(same(sup[1].points, SUP_LINE), "display geometry is the supplement line")
    assert(w.supStreet.name == SUP_NAME and same(w.supStreet.points, SUP_LINE), "raw supplement data must be restored")
    assert(w.logged("street supplement loaded: Fixture (1 roads, " .. lang .. ")"), lang .. " load must be logged")
    local r, state = w.route()
    assert(state == "ok" and r.len == 100, lang .. " navigation must use the supplement road: " .. tostring(state))
    local byOriginal = indexFor(w, SUP_NAME:lower())
    assert(byOriginal and byOriginal.sourceDir == "Fixture", lang .. " original name must be searchable with map source")
    if lang ~= "EN" then
        assert(byOriginal.name == expected and byOriginal.originalLow == SUP_NAME:lower(),
            lang .. " search keeps translated and original names on one anchor")
    end
    assert(w.clears() == 0, "player map must never be cleared")
end

local inactive = setup("CH", { inactive = true })
assert(inactive.ok and #shownFrom(inactive, SUP_FILE) == 0, "inactive map MOD: supplement must not load")

local changed = setup("CH", { ownStreets = true, pinCount = 0 })
assert(changed.ok and #shownFrom(changed, SUP_FILE) == 0, "author streets.xml appeared: supplement must retire")
assert(changed.logged("author street data changed (expected 0 streets, found 1)"), "retirement must say why")
local _, changedState = changed.route()
assert(changedState ~= "ok" or indexFor(changed, SUP_NAME:lower()) == nil, "retired supplement must not reach navigation")

local pinned = setup("CH", { ownStreets = true, pinCount = 1 })
assert(pinned.ok and #shownFrom(pinned, SUP_FILE) == 1, "pinned author count still matches: supplement stays")
assert(same(pinned.supStreet.points, SUP_LINE), "author repair op #0 must not touch supplement road #0")
local pinnedRoute = pinned.route()
assert(pinnedRoute and pinnedRoute.len == 100, "supplement road keeps its own geometry in navigation")
assert(not pinned.logged("upstream geometry changed"), "supplement streets must not be matched against author repairs")

local mismatch = setup("CH", { roadCount = 2 })
assert(mismatch.ok and #shownFrom(mismatch, SUP_FILE) == 0, "file/table road count mismatch fails closed")
assert(mismatch.logged("expected 2 roads, file has 1"), "count mismatch must be logged")
assert(mismatch.supStreet.name == SUP_NAME, "failed load restores raw data")

local fake = setup("CH", { file = "media/maps/Fixture/streets.xml" })
assert(fake.ok and #shownFrom(fake, SUP_FILE) == 0, "supplement must not pose as a map directory streets.xml")
assert(fake.logged("street supplement invalid for Fixture"), "invalid supplement must be logged")

local occluded = setup("CH", { occluded = true })
assert(occluded.ok, occluded.err)
assert(#shownFrom(occluded, SUP_FILE) == 0, "label under a higher-priority map must not be displayed")
assert(same(occluded.supStreet.points, SUP_LINE), "occlusion hiding restores raw points")
assert(occluded.logged("1 labels under other maps"), "occlusion must be counted in the load log")

print("test_street_supplements: PASS (four languages, search, navigation, author retirement, repair isolation, fail-closed, occlusion)")
