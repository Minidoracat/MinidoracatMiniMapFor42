-- 已知翻譯載體（統一漢化 B42Trans_CN）的顯示窗口：Riverside, KY/streets.xml 仍是 42.20.4 官方幾何，
-- 加入玩家地圖（同步 combine 顯示副本）的瞬間，把 patch.legacy 的舊版街換成 42.21 幾何，之後 raw 還原
-- （導航照舊讀 raw 自行升級）。守：目錄 loader（統一漢化先載／後載兩種包裝順序）與兜底載入兩條路、
-- 其他街不動、MOD 未啟用或非載體目錄不動。資料取正式 RoadPatches 的 legacy 條目。
-- 用法：lua scripts/test_carrier_display.lua
local root = arg[1] or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
local PATCH = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/shared/MinidoracatMiniMapRoadPatches.lua"
local CARRIER_DIR = "media/maps/Riverside, KY"
local CARRIER_FILE = CARRIER_DIR .. "/streets.xml"

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
local function decode(member)
    local geometry, widthQ = member:match("^(.-)|w:(%-?%d+)$")
    local pts, field = {}, 0
    for token in geometry:gmatch("[^:]+") do
        field = field + 1
        if field > 1 then pts[#pts + 1] = assert(tonumber(token)) / 2 end
    end
    return pts, tonumber(widthQ) / 2
end

local patchEnv = {}
assert(loadfile(PATCH, "t", patchEnv))()
local patch = assert(patchEnv.MinidoracatMiniMapRoadPatches)
local legacyStreets, current = {}, {}
for old, entry in pairs(patch.legacy) do
    local pts, width = decode(old)
    legacyStreets[#legacyStreets + 1] = { name = "legacy " .. #legacyStreets, pts = pts, width = width, target = entry.pts }
end
assert(#legacyStreets == 2, "正式 RoadPatch 應有兩條 42.20.4 legacy 街")
local plainMember = next(patch.geometrySet)
local plainPts, plainWidth = decode(plainMember)

local function rawStreet(points, name, width)
    local st = { points = copy(points), name = name, width = width }
    function st:getNumPoints() return #self.points / 2 end
    function st:getPointX(i) return self.points[i * 2 + 1] end
    function st:getPointY(i) return self.points[i * 2 + 2] end
    function st:getWidth() return self.width end
    function st:getUntranslatedText() return self.name end
    function st:setUntranslatedText(text) self.name = text:match("^%s*$") and "" or text end
    function st:getTranslatedText() return self.name end
    function st:removePoint(i) table.remove(self.points, i * 2 + 2); table.remove(self.points, i * 2 + 1) end
    function st:setPoint(i, x, y) self.points[i * 2 + 1], self.points[i * 2 + 2] = x, y end
    function st:addPoint(x, y) self.points[#self.points + 1] = x; self.points[#self.points + 1] = y end
    function st:clipToObscuredCells() self.split = { name = self.name, points = copy(self.points) } end
    st:clipToObscuredCells()
    return st
end

local function event()
    return { Add = function() end }
end

-- order：nil＝不裝統一漢化包裝；"first"＝統一漢化先載（本 MOD 包在外層）；"last"＝統一漢化後載（它包外層）
local function world(opts)
    local streets = { rawStreet(plainPts, "plain", plainWidth) }
    for _, legacy in ipairs(legacyStreets) do streets[#streets + 1] = rawStreet(legacy.pts, legacy.name, legacy.width) end
    local data = { [CARRIER_FILE] = streets, ["media/maps/Other Map/streets.xml"] = streets }
    local prints = {}
    local function makeMap()
        local loaded, order, shown = {}, {}, {}
        local api = {
            addStreetData = function(_, path)
                if data[path] and not loaded[path] then
                    loaded[path] = data[path]; order[#order + 1] = data[path]
                    for _, st in ipairs(data[path]) do shown[st.name] = copy(st.split.points) end
                end
            end,
            getStreetDataCount = function() return #order end,
            getStreetDataByIndex = function(_, at) return order[at + 1] end,
            getStreetDataByRelativeFileName = function(_, path) return loaded[path] end,
            clearStreetData = function() end,
        }
        local mapAPI = { getStreetsAPI = function() return api end }
        return { javaObject = { getAPIv3 = function() return mapAPI end }, mapAPI = mapAPI }, shown
    end
    local core = {
        ready = true, getBoolOption = function(_, d) return d end, registeredPacks = {},
        getLoadedMapDirs = function() return { ["Muldraugh, KY"] = 1 } end,
        carrierStreets = { { mod = "B42Trans_CN", file = CARRIER_FILE, langs = { CH = true, CN = true } } },
    }
    local env = setmetatable({
        print = function(line) prints[#prints + 1] = line end,
        MinidoracatMiniMapCore = core, MinidoracatMiniMapAPI = {}, MinidoracatMiniMapRoadPatches = patch,
        Events = { OnTick = event(), OnTickEvenPaused = event(), OnGameStart = event() },
        Translator = { getLanguage = function() return { name = function() return "CH" end } end },
        getTextOrNull = function() return nil end,
        getActivatedMods = function() return javaList(opts.active == false and {} or { "B42Trans_CN" }) end,
        getLotDirectories = function() return javaList({ "Muldraugh, KY" }) end,
        fileExists = function(path) return data[path] ~= nil end,
        getStreets = function(raw) return javaList(raw) end,
        getTimestampMs = function() return 1000 end,
    }, { __index = _G })
    env.UIWorldMap = { new = function() return (makeMap()).javaObject end }
    env.MapUtils = { initDirectoryStreetData = function(ui, dir)
        ui.mapAPI:getStreetsAPI():addStreetData(dir .. "/streets.xml")
    end }
    local function installCarrierSkip() -- B42Trans ISMapDefinitions_CN.lua：略過 Muldraugh，其餘交給前手
        local inner = env.MapUtils.initDirectoryStreetData
        env.MapUtils.initDirectoryStreetData = function(ui, dir)
            if dir:find("Muldraugh, KY", 1, true) or dir:find("muldraugh, ky", 1, true) then return end
            inner(ui, dir)
        end
    end
    if opts.order == "first" then installCarrierSkip() end
    for _, file in ipairs({ "MinidoracatMiniMap_NavRoute.lua", "MinidoracatMiniMap_StreetData.lua",
        "MinidoracatMiniMap_StreetRepairs.lua" }) do
        assert(loadfile(root .. file, "t", env))()
    end
    if opts.order == "last" then installCarrierSkip() end
    local ui, shown = makeMap()
    if opts.fallback then
        core.addCarrierStreetData(ui, CARRIER_FILE)
    else
        env.MapUtils.initDirectoryStreetData(ui, "media/maps/Muldraugh, KY")
        env.MapUtils.initDirectoryStreetData(ui, opts.dir or CARRIER_DIR)
    end
    return shown, streets, table.concat(prints, "\n")
end

local function expectUpgraded(label, shown, streets, log)
    assert(shown.plain and same(shown.plain, plainPts), label .. ": unrelated street keeps its geometry")
    for i, legacy in ipairs(legacyStreets) do
        assert(shown[legacy.name] and same(shown[legacy.name], legacy.target),
            label .. ": displayed " .. legacy.name .. " uses the 42.21 geometry")
        local raw = streets[i + 1]
        assert(same(raw.points, legacy.pts) and same(raw.split.points, legacy.pts),
            label .. ": raw " .. legacy.name .. " is restored to the carrier's own points")
    end
    assert(log:find("upgraded 2 previous%-official street geometries"), label .. ": display upgrade is logged")
end
local function expectUntouched(label, shown)
    for _, legacy in ipairs(legacyStreets) do
        assert(shown[legacy.name] and same(shown[legacy.name], legacy.pts), label .. ": " .. legacy.name .. " stays as loaded")
    end
end

for _, order in ipairs({ "first", "last" }) do
    local shown, streets, log = world({ order = order })
    expectUpgraded("directory loader, carrier " .. order, shown, streets, log)
end
local shown, streets, log = world({ fallback = true })
expectUpgraded("fallback loader", shown, streets, log)
expectUntouched("carrier mod inactive", (world({ order = "last", active = false })))
expectUntouched("unrelated map directory", (world({ order = "last", dir = "media/maps/Other Map" })))
print("test_carrier_display: PASS (directory loader both wrap orders, fallback loader, restore, inactive/unrelated untouched)")
