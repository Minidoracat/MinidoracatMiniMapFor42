-- 迷霧回歸：執行主檔切片；known/visited 仿 WorldMapVisited 的 2-bit 狀態。
-- 防原始停霧、晚到局部快照、ANY-of 誤判、重連與停用後繼續揭露。
-- 真 Java 的範圍／inflate／Kahlua bridge 另以隔離 JVM 冒煙，不把本模型當引擎實測。
local path = arg[1] or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local f = assert(io.open(path, "rb"))
local source = f:read("*a"):gsub("\r\n", "\n")
f:close()
local function section(name)
    return assert(source:match("%-%- test:" .. name .. ":start\n(.-)\n%-%- test:" .. name .. ":end"), name)
end
local compile = loadstring or load
local prefix = [=[
local client, failVisited = false, false
local messages, cells = {}, {}
local minCX, minCY, maxCX, maxCY = 5, -7, 7, 1
local dirty = 0
local function event()
    local handlers = {}
    return {
        Add = function(fn) handlers[#handlers + 1] = fn end,
        Remove = function(fn) for i, old in ipairs(handlers) do if old == fn then table.remove(handlers, i); return end end end,
        fire = function() local copy = {}; for i, fn in ipairs(handlers) do copy[i] = fn end; for _, fn in ipairs(copy) do fn() end end,
    }
end
local Events = { OnGameStart = event(), OnTickEvenPaused = event(), OnDisconnect = event(), OnMainMenuEnter = event() }
local SandboxVars = { Map = { MapAllKnown = false } }
local engineKnown = false
local mapOption = { getValue = function() return engineKnown end }
local sandbox = { getOptionByName = function(_, name) if name == "Map.MapAllKnown" then return mapOption end end }
local function getSandboxOptions() return sandbox end
local function isClient() return client end
local function log(message) messages[#messages + 1] = message end
local function getBoolOption(_, default) return default end
local grid = {
    getMinX = function() return minCX end, getMinY = function() return minCY end,
    getMaxX = function() return maxCX end, getMaxY = function() return maxCY end,
}
local world = { getMetaGrid = function() return grid end }
local function getWorld() return world end
local function width() return (maxCX - minCX + 1) * 8 end
local function height() return (maxCY - minCY + 1) * 8 end
local function resetCells()
    cells = {}; for i = 1, width() * height() do cells[i] = 0 end
    cells[2] = 3 -- 曾走過的 unit，補 known 不可清掉 visited。
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function unit(v, minimum, count, isMax)
    local u = math.floor(clamp(v - minimum * 256, 0, count * 32 - 1) / 32)
    -- 42.20.4 coordToUnit 在除以 32 後才取 %32；刻意照原生而非理想化模型。
    if isMax and u % 32 == 0 then u = u - 1 end
    return u
end
local visited = {}
function visited:setKnownInSquares(x1, y1, x2, y2)
    local changed = false
    for y = unit(y1, minCY, height(), false), unit(y2, minCY, height(), true) do
        for x = unit(x1, minCX, width(), false), unit(x2, minCX, width(), true) do
            local i = y * width() + x + 1
            if cells[i] < 2 then cells[i] = cells[i] + 2; changed = true end
        end
    end
    if changed then dirty = dirty + 1 end
end
function visited:setKnownInCells(x1, y1, x2, y2)
    self:setKnownInSquares(x1 * 256, y1 * 256, (x2 + 1) * 256, (y2 + 1) * 256)
end
function visited:isKnown(x1, y1, x2, y2)
    local function index(v, minimum, count, isMax)
        local square = clamp(v - minimum * 256, 0, count * 32 - 1)
        local u = math.floor(square / 32)
        if isMax and square % 32 == 0 then u = u - 1 end
        return u
    end
    for y = index(y1 - 1, minCY, height(), false), index(y2 + 1, minCY, height(), true) do
        for x = index(x1 - 1, minCX, width(), false), index(x2 + 1, minCX, width(), true) do
            if cells[y * width() + x + 1] >= 2 then return true end
        end
    end
    return false
end
local WorldMapVisited = { getInstance = function()
    if failVisited then error("injected visited failure") end
    return visited
end }
local ISWorldMap = { initDataAndStyle = function(self) self.hideUnvisitedAreas = true end }
local function applyMiniMapPyramids() end
]=]
local suffix = [=[
local function newMiniMap()
    local map = { HideUnvisited = true }
    function map:setBoolean(name, value) self[name] = value end
    applyToggleOptions(map)
    return map
end
local function newWorldMap()
    local map = setmetatable({}, { __index = ISWorldMap })
    map:initDataAndStyle()
    map.HideUnvisited = map.hideUnvisitedAreas -- 原版 ShowWorldMap 的套用。
    return map
end
return {
    events = Events, messages = messages,
    setup = function(mp, allKnown) client = mp; engineKnown = allKnown; SandboxVars.Map.MapAllKnown = allKnown end,
    spoofKnown = function(value) SandboxVars.Map.MapAllKnown = value end,
    fail = function(value) failVisited = value end,
    clear = resetCells,
    loadKnown = function() visited:setKnownInCells(minCX, minCY, maxCX, maxCY) end,
    partial = function()
        resetCells()
        -- 每一帶都有 known（四角也全知），仍有內部未知：ANY-of/角落不能證明全圖已知。
        for y = 0, height() - 1, 32 do cells[y * width() + 1] = 2 end
        cells[width()] = 2; cells[(height() - 1) * width() + 1] = 2; cells[width() * height()] = 2
    end,
    raw = function(i) return cells[i] end,
    count = function() return width() * height() end,
    dirty = function() return dirty end,
    moveBounds = function() minCX = -3; minCY = 2; maxCX = -1; maxCY = 6; resetCells() end,
    mini = newMiniMap, world = newWorldMap,
    apply = applyToggleOptions,
    fog = function(map, i)
        if not map.HideUnvisited or cells[i] % 2 == 1 then return "clear" end
        return cells[i] >= 2 and "thin" or "opaque"
    end,
}
]=]
local env = assert(compile(prefix .. section("map%-toggles") .. "\n" .. section("worldmap%-init")
    .. "\n" .. section("map%-known") .. "\n" .. suffix, "fog-of-war"))()
local function allKnown()
    for i = 1, env.count() do
        assert(env.raw(i) == (i == 2 and 3 or 2), "incorrect known/visited flags at unit " .. i)
    end
end
local function tick() env.events.OnTickEvenPaused.fire() end

-- 原始回報：全圖已知仍有薄霧，地圖重建／設定重套不可把整層關掉。
for _, mp in ipairs({ false, true }) do
    for _, known in ipairs({ false, true }) do
        env.setup(mp, known); env.clear(); env.events.OnGameStart.fire()
        if not mp then
            -- SP 由引擎載入的 known 模擬在此，不要求 MOD 代做。
            assert(env.raw(1) == 0, "SP must stay with vanilla visited loading")
            if known then env.loadKnown() end
        end
        local mini, world = env.mini(), env.world()
        local expected = known and "thin" or "opaque"
        assert(env.fog(mini, 1) == expected and env.fog(world, 1) == expected, "map initialization disabled fog")
        env.apply(mini)
        assert(env.fog(mini, 1) == expected, "settings application disabled fog")
        assert(env.fog(mini, 2) == "clear" and env.fog(world, 2) == "clear", "visited area must remain clear")
        mini.HideUnvisited = false; env.apply(mini)
        assert(env.fog(mini, 1) == "clear", "must not override an intentional debug setting")
    end
end

env.setup(true, true); env.clear(); env.events.OnGameStart.fire(); allKnown()
local mini = env.mini()
-- 晚到封包且每帶都部分 known：最遲一輪三個 ticks 恢復全部，而不是只顧角落。
env.partial(); assert(env.fog(mini, 3) == "opaque")
for _ = 1, 3 do tick() end
allKnown(); assert(env.fog(mini, 3) == "thin")
local dirty = env.dirty()
for _ = 1, 120 do tick() end
assert(env.dirty() == dirty, "already-known sweeps must not dirty the fog texture")
-- 開局很久以後才到、且當前帶完全未知：快車道下一 tick 恢復遠端，無任意截止時間。
env.clear(); tick(); tick()
allKnown()

-- 停用不得補資料；重新啟用則立即補全，既有 visited 不受影響。
env.setup(true, false); env.clear(); tick()
assert(env.raw(1) == 0 and env.raw(2) == 3, "disabled MapAllKnown revealed or erased data")
env.spoofKnown(true); tick()
assert(env.raw(1) == 0, "Lua mirror overrode the authoritative sandbox option")
env.setup(true, true); tick(); allKnown()

-- 斷線／回主選單停止碰舊世界；換存檔重連必用新 bounds，不重複註冊。
for _, eventName in ipairs({ "OnDisconnect", "OnMainMenuEnter" }) do
    env.events[eventName].fire(); env.clear(); tick()
    assert(env.raw(1) == 0, "disconnected callback still changed map data")
    env.moveBounds(); env.events.OnGameStart.fire(); env.events.OnGameStart.fire(); allKnown()
end

-- 真實 API 錯誤可見，後續恢復仍重試，不把一次故障變永久停用。
env.clear(); env.fail(true); env.events.OnGameStart.fire(); tick()
assert(#env.messages == 1 and env.messages[1]:find("injected visited failure", 1, true), "missing error cause or log flood")
env.fail(false); tick(); allKnown()
print("test_fog_of_war: OK (fog states, late snapshots, bounded repair, lifecycle, error recovery)")
