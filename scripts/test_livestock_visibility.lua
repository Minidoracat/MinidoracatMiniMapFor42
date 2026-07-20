-- 主檔拆分後：牲畜/取樣/註冊區段仍在主檔（arg[1]）；
-- worldmap-effective-tick 與 UNIFIED_WM_TICKS 已移至 _Settings.lua（arg[2]）
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local settingsPath = arg[2]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Settings.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end
local source = readSource(sourcePath)
local settingsSource = readSource(settingsPath)

local body = assert(source:match(
    "%-%- test:livestock%-visibility:start\n(.-)\n%-%- test:livestock%-visibility:end"),
    "找不到 adotsLivestockVisible 測試區段")
local compile = loadstring or load

local registryBody = assert(source:match(
    "%-%- test:animal%-group%-registry:start\n(.-)\n%-%- test:animal%-group%-registry:end"),
    "找不到 registerAnimalGroup 測試區段")
local registryChunk, registryErr = compile([[
local messages = {}
local function print(message) messages[#messages + 1] = message end
local ADOTS_SPECIES_UI = {
    { key = "cow", label = "UI_Cow", groups = { "cow" } },
    { key = "rodent", label = "UI_Rodent", groups = { "rat", "mouse" } },
}
local ADOTS_ART = { cow = { sym = "cow.png" } }
local ADOTS_FALLBACK_SYM = "paw.png"
MinidoracatMiniMapAPI = {}
]] .. registryBody .. "\n" .. [[
return {
    register = MinidoracatMiniMapAPI.registerAnimalGroup,
    species = ADOTS_SPECIES_UI,
    art = ADOTS_ART,
    messages = messages,
}
]])
assert(registryChunk, registryErr)
local registry = registryChunk()

local chunk, err = compile(body .. "\nreturn adotsLivestockVisible")
assert(chunk, err)
local visible = chunk()

local modeBody = assert(source:match(
    "%-%- test:livestock%-effective%-mode:start\n(.-)\n%-%- test:livestock%-effective%-mode:end"),
    "找不到 livestockVisibilityMode 測試區段")
local modeChunk, modeErr = compile([[
local rawMode, client
local function sandboxGate(_, default)
    if rawMode == nil then return default end
    return rawMode
end
local function isClient() return client end
]] .. modeBody .. "\n" .. [[return function(raw, isMp)
    rawMode, client = raw, isMp
    return livestockVisibilityMode()
end
]])
assert(modeChunk, modeErr)
local effectiveMode = modeChunk()

local distanceBody = assert(source:match(
    "%-%- test:sandbox%-distance:start\n(.-)\n%-%- test:sandbox%-distance:end"),
    "找不到 sandboxDist 測試區段")
local distanceChunk, distanceErr = compile([[
local rawDistance
local function sandboxGate(_, default)
    if rawDistance == nil then return default end
    return rawDistance
end
]] .. distanceBody .. "\n" .. [[return function(value)
    rawDistance = value
    return sandboxDist("TestDistance")
end
]])
assert(distanceChunk, distanceErr)
local normalizeDistance = distanceChunk()

local worldMapBody = assert(settingsSource:match(
    "%-%- test:worldmap%-effective%-tick:start\n(.-)\n%-%- test:worldmap%-effective%-tick:end"),
    "找不到 unifiedWorldMapTickOn 測試區段")
local worldMapChunk, worldMapErr = compile([[
local options, gates, mode = {}, {}, 2
local function getBoolOption(id, default)
    local value = options[id]
    if value == nil then return default end
    return value
end
local function sandboxGate(id, default)
    local value = gates[id]
    if value == nil then return default end
    return value
end
local function livestockVisibilityMode() return mode end
]] .. worldMapBody .. "\n" .. [[return {
    enabled = unifiedWorldMapTickOn,
    setOption = function(id, value) options[id] = value end,
    setGate = function(id, value) gates[id] = value end,
    setMode = function(value) mode = value end,
}
]])
assert(worldMapChunk, worldMapErr)
local worldMap = worldMapChunk()

local sampleBody = assert(source:match(
    "%-%- test:animal%-sampling:start\n(.-)\n%-%- test:animal%-sampling:end"),
    "找不到 sampleAnimalDots 測試區段")
local samplePrelude = [=[
local now, mode, username = 1000, 1, "A"
local rectsByUser, animals, vehicles, distances = {}, {}, {}, {}
local disabledAnimalGroups, animalGroup = nil, "cow"
local function getTimestampMs() return now end
local function sandboxDist(name) return distances[name] end
local function livestockVisibilityMode() return mode end
local defaultPlayer = {
    getX = function() return 0 end,
    getY = function() return 0 end,
    getUsername = function() return username end,
}
local player = defaultPlayer
local function getSpecificPlayer() return player end
local function adotsDisabledGroups(optId)
    if optId == "AnimalSpeciesFilter" then
        return disabledAnimalGroups, disabledAnimalGroups and "dog" or "-"
    end
    return nil, "-"
end
local ADOTS_SPECIES_UI, ADOTS_VEHCAT_UI = {}, {}
local function visibleWorldAABB() return -100, 100, -100, 100 end
local ADOTS_INTERVAL_MS, ADOTS_MAX, ADOTS_SCAN_MAX = 500, 500, 1000
local function adotsSafehouseRects(user) return rectsByUser[user] end
local function adotsLivestockVisible(ax, ay, currentMode, rects)
    if currentMode == 1 then return true end
    if currentMode == 4 or rects == nil then return false end
    for i = 1, #rects do
        local r = rects[i]
        if ax >= r.x1 and ax < r.x2 and ay >= r.y1 and ay < r.y2 then return r.allowed end
    end
    return currentMode == 2
end
local function adotsGroup() return animalGroup end
local function adotsVehCategory() return "standard" end
local function log(err) error(err) end
local function javaList(values)
    return { size = function() return #values end, get = function(_, i) return values[i + 1] end }
end
local cell = {
    getAnimals = function() return javaList(animals) end,
    getVehicles = function()
        return { toArray = function() return vehicles end }
    end,
}
local function getCell() return cell end
local function animal(x, y, wild)
    return {
        getX = function() return x end,
        getY = function() return y end,
        isDead = function() return false end,
        isWild = function() return wild end,
        getAnimalType = function() return wild and "deer" or "cow" end,
    }
end
local function vehicle(x, y)
    return {
        getX = function() return x end,
        getY = function() return y end,
    }
end
]=]
local sampleSuffix = [=[
return {
    sample = sampleAnimalDots,
    setNow = function(value) now = value end,
    setMode = function(value) mode = value end,
    setUsername = function(value) username = value end,
    setAnimals = function(value) animals = value end,
    setVehicles = function(value) vehicles = value end,
    setAnimalGroup = function(value) animalGroup = value end,
    setDisabledAnimalGroups = function(value) disabledAnimalGroups = value end,
    setDistances = function(animalDistance, vehicleDistance)
        distances.AnimalIconDistance = animalDistance
        distances.VehicleIconDistance = vehicleDistance
    end,
    setPlayerPresent = function(value) player = value and defaultPlayer or nil end,
    setRects = function(user, value) rectsByUser[user] = value end,
    animal = animal,
    vehicle = vehicle,
}
]=]
local sampleChunk, sampleErr = compile(samplePrelude .. "\n" .. sampleBody .. "\n" .. sampleSuffix)
assert(sampleChunk, sampleErr)
local harness = sampleChunk()

local zombieBody = assert(source:match(
    "%-%- test:zombie%-sampling:start\n(.-)\n%-%- test:zombie%-sampling:end"),
    "找不到 sampleZombieDots 測試區段")
local zombiePrelude = [=[
local now, distance, playerPresent = 1000, nil, true
local zombies = {}
local ZDOTS_INTERVAL_MS, ZDOTS_MAX, ZDOTS_SCAN_MAX = 300, 10, 100
local ZDOTS_NEAR, ZDOTS_MID, ZDOTS_MAXES = 20, 50, { 10 }
local function getTimestampMs() return now end
local function sandboxDist() return distance end
local function getComboIndex() return 1 end
local function visibleWorldAABB() return -100, 100, -100, 100 end
local function zdotsStateFor(inner)
    if not inner._state then
        inner._state = { near = {}, mid = {}, far = {}, dots = {}, count = 0, nextMs = 0 }
    end
    return inner._state
end
local defaultPlayer = {
    getX = function() return 0 end,
    getY = function() return 0 end,
}
local function getSpecificPlayer() return playerPresent and defaultPlayer or nil end
local function javaList(values)
    return { size = function() return #values end, get = function(_, i) return values[i + 1] end }
end
local cell = { getZombieList = function() return javaList(zombies) end }
local function getCell() return cell end
local function log(err) error(err) end
local function zombie(x, y)
    return { getX = function() return x end, getY = function() return y end }
end
]=]
local zombieSuffix = [=[
return {
    sample = sampleZombieDots,
    setNow = function(value) now = value end,
    setDistance = function(value) distance = value end,
    setPlayerPresent = function(value) playerPresent = value end,
    setZombies = function(value) zombies = value end,
    zombie = zombie,
}
]=]
local zombieChunk, zombieErr = compile(zombiePrelude .. "\n" .. zombieBody .. "\n" .. zombieSuffix)
assert(zombieChunk, zombieErr)
local zombieHarness = zombieChunk()

local safehouseBody = assert(source:match(
    "%-%- test:safehouse%-distance:start\n(.-)\n%-%- test:safehouse%-distance:end"),
    "找不到 drawSafehouses 測試區段")
local safehousePrelude = [=[
local distance, playerPresent, px, py = nil, true, 0, 10
local houses, drawCount = {}, 0
local function javaList(values)
    return { size = function() return #values end, get = function(_, i) return values[i + 1] end }
end
SafeHouse = { getSafehouseList = function() return javaList(houses) end }
local function getBoolOption() return true end
local function sandboxDist() return distance end
local function sandboxGate() return 3 end
local defaultPlayer = {
    getX = function() return px end,
    getY = function() return py end,
    getUsername = function() return "A" end,
}
local function getSpecificPlayer() return playerPresent and defaultPlayer or nil end
local function drawClippedEdge() drawCount = drawCount + 1 end
local mapAPI = {
    worldToUIX = function(_, x) return x end,
    worldToUIY = function(_, _, y) return y end,
}
local inner = { playerNum = 0, mapAPI = mapAPI, width = 100, height = 100 }
local function safehouse(x1, y1, x2, y2, mine)
    return {
        getX = function() return x1 end,
        getY = function() return y1 end,
        getX2 = function() return x2 end,
        getY2 = function() return y2 end,
        playerAllowed = function() return mine end,
    }
end
]=]
local safehouseSuffix = [=[
return {
    draw = function()
        drawCount = 0
        drawSafehouses(inner)
        return drawCount
    end,
    setDistance = function(value) distance = value end,
    setPlayerPresent = function(value) playerPresent = value end,
    setPlayerPosition = function(x, y) px, py = x, y end,
    setHouses = function(value) houses = value end,
    safehouse = safehouse,
}
]=]
local safehouseChunk, safehouseErr = compile(
    safehousePrelude .. "\n" .. safehouseBody .. "\n" .. safehouseSuffix)
assert(safehouseChunk, safehouseErr)
local safehouseHarness = safehouseChunk()

local navBody = assert(source:match(
    "%-%- test:nav%-share%-gate:start\n(.-)\n%-%- test:nav%-share%-gate:end"),
    "找不到 navShareGateTick 測試區段")
local navChunk, navErr = compile([[
local allowed = true
local navShared = { [0] = true }
local sharedTargets = { A = { x = 1, y = 1 } }
local lastAllowNavShare = true
local function sandboxGate() return allowed end
]] .. navBody .. "\n" .. [[return {
    tick = navShareGateTick,
    receive = navAcceptShared,
    setAllowed = function(value) allowed = value end,
    addCached = function()
        navShared[0] = true
        sharedTargets.A = { x = 1, y = 1 }
    end,
    cacheEmpty = function() return next(navShared) == nil and next(sharedTargets) == nil end,
}
]])
assert(navChunk, navErr)
local navHarness = navChunk()

assert(registry.register("MinidoracatMiniMapCompatFor42", "dog",
    "UI_MinidoracatMiniMapCompat_Dog"), "合法動物群組註冊失敗")
assert(#registry.species == 3, "合法註冊未加入物種定義")
assert(registry.species[3].owner == "MinidoracatMiniMapCompatFor42"
    and registry.species[3].groups[1] == "dog", "註冊資料內容錯誤")
assert(registry.art.dog and registry.art.dog.sym == "paw.png", "未知物種未使用原版爪印備援")
assert(registry.register("MinidoracatMiniMapCompatFor42", "dog",
    "UI_MinidoracatMiniMapCompat_Dog"), "相同註冊應為冪等成功")
assert(#registry.species == 3, "相同註冊重複加入物種定義")
assert(registry.register("MinidoracatMiniMapCompatFor42", "horse",
    "UI_MinidoracatMiniMapCompat_Horse", "map_horse.png", "Item_Horse.png"),
    "自訂素材動物群組註冊失敗")
assert(#registry.species == 4 and registry.art.horse.sym == "map_horse.png"
    and registry.art.horse.item == "Item_Horse.png", "自訂素材未完整保存")
assert(registry.register("MinidoracatMiniMapCompatFor42", "horse",
    "UI_MinidoracatMiniMapCompat_Horse", "map_horse.png", "Item_Horse.png"),
    "相同自訂素材註冊應為冪等成功")
assert(not registry.register("MinidoracatMiniMapCompatFor42", "horse",
    "UI_MinidoracatMiniMapCompat_Horse", "other_horse.png", "Item_Horse.png"),
    "相同群組不應靜默更換素材")
assert(not registry.register("OtherCompat", "dog", "UI_OtherDog"),
    "不同擁有者不應覆蓋既有群組")
assert(not registry.register("Compat", "cow", "UI_OtherCow"),
    "第三方定義不應覆蓋內建群組")
assert(not registry.register("Compat", "mouse", "UI_Mouse"),
    "第三方定義不應覆蓋合併物種的子群組")
for _, invalid in ipairs({ "", " ", "-", "nil", "dog,cat" }) do
    assert(not registry.register("Compat", invalid, "UI_Invalid"),
        "非法 group 應被拒絕: " .. invalid)
end
assert(not registry.register("", "cat", "UI_Cat")
    and not registry.register("Compat", "cat", ""), "空 owner/label 應被拒絕")
assert(not registry.register("Compat", "cat", "UI_Cat", "")
    and not registry.register("Compat", "bird", "UI_Bird", nil, 42),
    "空白或非字串素材路徑應被拒絕")

assert(normalizeDistance(nil) == nil, "距離缺值應視為不限制")
assert(normalizeDistance(0) == nil, "距離 0 應視為不限制")
assert(normalizeDistance(-1) == nil, "負距離應視為不限制")
assert(normalizeDistance("10") == nil, "非數字距離應視為不限制")
assert(normalizeDistance(10) == 10, "正數距離未保留")

local worldMapMappings = {
    { "WMZombieDots", "AllowZombieDots" },
    { "WMAnimalWild", "AllowAnimalDots" },
    { "WMAnimalLivestock", "AllowAnimalDots" },
    { "WMVehicleDots", "AllowVehicleDots" },
}
for _, mapping in ipairs(worldMapMappings) do
    local id, gate = mapping[1], mapping[2]
    assert(settingsSource:match('id = "' .. id .. '".-gate = "' .. gate .. '"'),
        id .. " 未綁定正確伺服器閘門")
    worldMap.setOption(id, true)
    worldMap.setGate(gate, true)
    worldMap.setMode(2)
    assert(worldMap.enabled({ id = id, gate = gate }), id .. " 啟用狀態判斷失敗")
    worldMap.setGate(gate, false)
    assert(not worldMap.enabled({ id = id, gate = gate }), id .. " 未受伺服器閘門壓制")
    worldMap.setGate(gate, true)
end
worldMap.setOption("WMZombieDots", false)
assert(not worldMap.enabled({ id = "WMZombieDots", gate = "AllowZombieDots" }),
    "未勾選的世界地圖項目不應計入摘要")
worldMap.setOption("WMZombieDots", true)
worldMap.setMode(4)
assert(worldMap.enabled({ id = "WMAnimalWild", gate = "AllowAnimalDots" }),
    "牲畜模式4不應壓制野生動物")
assert(not worldMap.enabled({ id = "WMAnimalLivestock", gate = "AllowAnimalDots" }),
    "牲畜模式4未壓制世界地圖牲畜摘要")

local inner = {}
local own = { { x1 = 0, y1 = 0, x2 = 10, y2 = 10, allowed = true } }
local other = { { x1 = 0, y1 = 0, x2 = 10, y2 = 10, allowed = false } }

harness.setRects("A", own)
harness.setRects("B", other)
harness.setAnimalGroup("cow")
harness.setDisabledAnimalGroups(nil)
harness.setAnimals({ harness.animal(5, 5, false) })
harness.setNow(1000)
harness.setMode(1)
harness.setUsername("A")
assert(harness.sample(inner, false, true, false).count == 1, "模式1取樣失敗")
harness.setNow(1100)
harness.setMode(4)
assert(harness.sample(inner, false, true, false).count == 0, "模式4未清除舊牲畜點池")
harness.setNow(1200)
harness.setMode(2)
assert(harness.sample(inner, false, true, false).count == 1, "1→4→2 熱切換命中舊快取")
harness.setNow(2000)
harness.setUsername("A")
assert(harness.sample(inner, false, true, false).count == 1, "我方安全屋取樣失敗")
harness.setNow(2100)
harness.setUsername("B")
assert(harness.sample(inner, false, true, false).count == 0, "username 變更未淘汰快取")
harness.setNow(2200)
harness.setMode(4)
harness.setAnimals({ harness.animal(5, 5, false), harness.animal(6, 6, true) })
local sampled = harness.sample(inner, true, true, false)
assert(sampled.count == 1 and sampled.dots[1].wild == true, "模式4錯誤隱藏野生動物")

harness.setMode(1)
harness.setAnimalGroup("dog")
harness.setAnimals({ harness.animal(5, 5, false) })
harness.setDisabledAnimalGroups(nil)
harness.setNow(2250)
sampled = harness.sample(inner, false, true, false)
assert(sampled.count == 1 and sampled.dots[1].group == "dog", "已註冊 dog 群組未進入點池")
harness.setDisabledAnimalGroups({ dog = true })
harness.setNow(2260)
assert(harness.sample(inner, false, true, false).count == 0, "停用 dog 篩選未立即清除點池")
harness.setDisabledAnimalGroups(nil)
harness.setAnimalGroup("cow")

local empty = {}

local cases = {
    { "模式1不需安全屋資料", 5, 5, 1, nil, true },
    { "模式2我方屋內", 5, 5, 2, own, true },
    { "模式2其他屋內", 5, 5, 2, other, false },
    { "模式2屋外", 20, 20, 2, own, true },
    { "模式2有效空清單", 5, 5, 2, empty, true },
    { "模式2缺API", 5, 5, 2, nil, false },
    { "模式3我方屋內", 5, 5, 3, own, true },
    { "模式3其他屋內", 5, 5, 3, other, false },
    { "模式3屋外", 20, 20, 3, own, false },
    { "模式3有效空清單", 5, 5, 3, empty, false },
    { "模式3缺API", 5, 5, 3, nil, false },
    { "模式4全部隱藏", 5, 5, 4, own, false },
    { "東界採半開區間", 10, 5, 3, own, false },
}

for _, case in ipairs(cases) do
    local actual = visible(case[2], case[3], case[4], case[5])
    assert(actual == case[6], case[1] .. ": expected " .. tostring(case[6])
        .. ", got " .. tostring(actual))
end

for mode = 1, 4 do
    assert(effectiveMode(mode, true) == mode, "MP 模式 " .. mode .. " 未保留")
end
assert(effectiveMode(nil, true) == 2, "MP 缺值未回預設模式2")
assert(effectiveMode(0, true) == 2 and effectiveMode(5, true) == 2, "MP 越界未回模式2")
assert(effectiveMode(2, false) == 1 and effectiveMode(3, false) == 1, "單機模式2/3未視為模式1")
assert(effectiveMode(4, false) == 4, "單機模式4未保留")

harness.setMode(1)
harness.setUsername("A")
harness.setPlayerPresent(true)
harness.setVehicles({})
harness.setAnimals({ harness.animal(10, 0, false), harness.animal(10.1, 0, false) })
harness.setDistances(10, nil)
harness.setNow(3000)
assert(harness.sample(inner, false, true, false).count == 1, "動物距離邊界應含等於上限")
harness.setPlayerPresent(false)
harness.setNow(3025)
assert(harness.sample(inner, false, true, false).count == 0, "同距離下玩家消失未立即清除動物快取")
harness.setPlayerPresent(true)
harness.setNow(3030)
assert(harness.sample(inner, false, true, false).count == 1, "玩家恢復後未立即重建動物快取")
harness.setDistances(5, nil)
harness.setNow(3050)
assert(harness.sample(inner, false, true, false).count == 0, "動物距離熱切換未立即淘汰快取")
harness.setDistances(10, nil)
harness.setPlayerPresent(false)
harness.setNow(3100)
assert(harness.sample(inner, false, true, false).count == 0, "動物距離啟用且缺玩家時未 fail closed")

harness.setPlayerPresent(true)
harness.setAnimals({})
harness.setVehicles({ harness.vehicle(10, 0), harness.vehicle(10.1, 0) })
harness.setDistances(nil, 10)
harness.setNow(3200)
assert(harness.sample(inner, false, false, true).count == 1, "載具距離邊界應含等於上限")
harness.setPlayerPresent(false)
harness.setNow(3210)
assert(harness.sample(inner, false, false, true).count == 0, "同距離下玩家消失未立即清除載具快取")
harness.setPlayerPresent(true)
harness.setNow(3215)
assert(harness.sample(inner, false, false, true).count == 1, "玩家恢復後未立即重建載具快取")
harness.setDistances(nil, 5)
harness.setNow(3225)
assert(harness.sample(inner, false, false, true).count == 0, "載具距離熱切換未立即淘汰快取")
harness.setDistances(nil, 10)
harness.setPlayerPresent(false)
harness.setNow(3250)
assert(harness.sample(inner, false, false, true).count == 0, "載具距離啟用且缺玩家時未 fail closed")
harness.setPlayerPresent(true)
harness.setDistances(nil, nil)

local zombieInner = { playerNum = 0 }
zombieHarness.setZombies({ zombieHarness.zombie(10, 0), zombieHarness.zombie(10.1, 0) })
zombieHarness.setDistance(10)
zombieHarness.setPlayerPresent(true)
zombieHarness.setNow(1000)
assert(zombieHarness.sample(zombieInner).count == 1, "殭屍距離邊界應含等於上限")
zombieHarness.setPlayerPresent(false)
zombieHarness.setNow(1025)
assert(zombieHarness.sample(zombieInner).count == 0, "同距離下玩家消失未立即清除殭屍快取")
zombieHarness.setPlayerPresent(true)
zombieHarness.setNow(1030)
assert(zombieHarness.sample(zombieInner).count == 1, "玩家恢復後未立即重建殭屍快取")
zombieHarness.setDistance(5)
zombieHarness.setNow(1050)
assert(zombieHarness.sample(zombieInner).count == 0, "殭屍距離熱切換未立即淘汰快取")
zombieHarness.setDistance(10)
zombieHarness.setPlayerPresent(false)
zombieHarness.setNow(1100)
assert(zombieHarness.sample(zombieInner).count == 0, "殭屍距離啟用且缺玩家時未 fail closed")
zombieHarness.setDistance(nil)
zombieHarness.setNow(1150)
assert(zombieHarness.sample(zombieInner).count == 2, "未限制距離時缺玩家未沿用視窗中心")

safehouseHarness.setHouses({ safehouseHarness.safehouse(10, 10, 20, 20, false) })
safehouseHarness.setPlayerPosition(0, 10)
safehouseHarness.setPlayerPresent(true)
safehouseHarness.setDistance(10)
assert(safehouseHarness.draw() == 4, "安全屋最近點距離邊界應含等於上限")
safehouseHarness.setDistance(9.9)
assert(safehouseHarness.draw() == 0, "安全屋距離應採矩形最近點而非中心")
safehouseHarness.setDistance(10)
safehouseHarness.setPlayerPresent(false)
assert(safehouseHarness.draw() == 0, "安全屋距離啟用且缺玩家時未 fail closed")
safehouseHarness.setPlayerPresent(true)
safehouseHarness.setPlayerPosition(15, 15)
safehouseHarness.setDistance(1)
assert(safehouseHarness.draw() == 4, "玩家位於安全屋矩形內時應顯示")

assert(not navHarness.cacheEmpty(), "導航測試初始快取缺失")
navHarness.setAllowed(false)
navHarness.tick()
assert(navHarness.cacheEmpty(), "關閉導航分享未清除既有快取")
navHarness.addCached()
navHarness.tick()
assert(navHarness.cacheEmpty(), "關閉後延遲抵達的導航封包未被清除")
navHarness.receive("A", "B", 2, 3)
assert(navHarness.cacheEmpty(), "關閉期間抵達的導航封包不應進入快取")
navHarness.setAllowed(true)
navHarness.tick()
assert(navHarness.cacheEmpty(), "重開導航分享不應復活舊座標")
navHarness.receive("A", "B", 2, 3)
assert(not navHarness.cacheEmpty(), "開啟導航分享時應接受有效封包")

print("livestock visibility: " .. #cases
    .. " policy cases + registry/mode/distance/gate/cache cases passed")
