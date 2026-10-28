-- 主檔拆分後的區段來源：註冊/模式/距離/安全屋/導航閘門仍在主檔（arg[1]）；
-- worldmap-effective-tick 與 UNIFIED_WM_TICKS 在 _Settings.lua（arg[2]）；
-- 點雲取樣三段（zombie/animal-sampling、livestock-visibility）於主 chunk
-- locvar 上限拆檔後移至 _Dots.lua（arg[3]，2026-08-20）；zone 距離閘
-- （distGateParams 的 Poi/ZoneDisplayDistance 呼叫點）同理移至 _Zones.lua（arg[4]，2026-09-03）
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local settingsPath = arg[2]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Settings.lua"
local dotsPath = arg[3]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Dots.lua"
local zonesPath = arg[4]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Zones.lua"
local navPath = arg[5] -- nav-share-gate 切片自 2026-09-03 起在 _Nav.lua
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Nav.lua"
local safehousePath = arg[6] -- safehouse-distance 切片自 2026-09-03 起在 _Safehouse.lua
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Safehouse.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end
local source = readSource(sourcePath)
local settingsSource = readSource(settingsPath)
local dotsSource = readSource(dotsPath)
local zonesSource = readSource(zonesPath)
local navSource = readSource(navPath)
local safehouseSource = readSource(safehousePath)

local body = assert(dotsSource:match(
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
-- name-aware stub：sandboxDist 現會另查 AllInfoDistance（全域上限），
-- 第二參可注入全域值；缺鍵回 default＝與正式 sandboxGate 同語意
local distanceChunk, distanceErr = compile([[
local values = {}
local function sandboxGate(name, default)
    local v = values[name]
    if v == nil then return default end
    return v
end
]] .. distanceBody .. "\n" .. [[return function(value, global)
    values = { TestDistance = value, AllInfoDistance = global }
    return sandboxDist("TestDistance")
end
]])
assert(distanceChunk, distanceErr)
local normalizeDistance = distanceChunk()

-- displayDist 合成（伺服器沙盒值×玩家自訂值取較小正值）：sandboxDist/getSliderValue
-- 皆為標記區段外相依，stub 注入；getSliderValue 依正式版語意夾 min/max
local displayBody = assert(source:match(
    "%-%- test:display%-distance:start\n(.-)\n%-%- test:display%-distance:end"),
    "找不到 displayDist 測試區段")
local displayChunk, displayErr = compile([[
local serverDist, clientVal
local function sandboxDist(name) return serverDist end
local function getSliderValue(id, default, min, max)
    if id ~= "ClientTestDistance" then return default end
    if type(clientVal) ~= "number" then return default end
    if clientVal < min then return min end
    if clientVal > max then return max end
    return clientVal
end
]] .. displayBody .. "\n" .. [[return function(server, client)
    serverDist, clientVal = server, client
    return displayDist("TestDistance")
end
]])
assert(displayChunk, displayErr)
local mergeDist = displayChunk()

local sampleBody = assert(dotsSource:match(
    "%-%- test:animal%-sampling:start\n(.-)\n%-%- test:animal%-sampling:end"),
    "找不到 sampleAnimalDots 測試區段")
local samplePrelude = [=[
local now, mode, username = 1000, 1, "A"
local rectsByUser, animals, vehicles, distances = {}, {}, {}, {}
local disabledAnimalGroups, animalGroup = nil, "cow"
local function getTimestampMs() return now end
local function displayDist(name) return distances[name] end
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
local ADOTS_INTERVAL_MS, ADOTS_MAX, ADOTS_SCAN_MAX, SCAN_ALL = 500, 500, 1000, 1e9
-- 掃描間隔（沙盒）樁：回毫秒或 nil（即時）；reads 數取樣器實際讀了幾次（守「每幀不讀 policy」）
local scanSettings, scanReads = {}, 0
local function scanIntervalMs(name) scanReads = scanReads + 1; return scanSettings[name] end
local scanListeners = {} -- 掃描通知（零註冊；通知行為在 test_scan_listener）
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
    setScan = function(name, ms) scanSettings[name] = ms end,
    scanReads = function() return scanReads end,
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

local zombieBody = assert(dotsSource:match(
    "%-%- test:zombie%-sampling:start\n(.-)\n%-%- test:zombie%-sampling:end"),
    "找不到 sampleZombieDots 測試區段")
local zombiePrelude = [=[
local now, distance, playerPresent = 1000, nil, true
local zombies = {}
local ZDOTS_INTERVAL_MS, ZDOTS_MAX, ZDOTS_SCAN_MAX, SCAN_ALL = 300, 10, 100, 1e9
local scanSettings, scanReads = {}, 0
local function scanIntervalMs(name) scanReads = scanReads + 1; return scanSettings[name] end
local scanListeners = {} -- 掃描通知（零註冊；通知行為在 test_scan_listener）
local ZDOTS_NEAR, ZDOTS_MID, ZDOTS_MAXES = 20, 50, { 10 }
local function getTimestampMs() return now end
local function displayDist() return distance end
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
    return { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end }
end
]=]
local zombieSuffix = [=[
return {
    sample = sampleZombieDots,
    setScan = function(name, ms) scanSettings[name] = ms end,
    scanReads = function() return scanReads end,
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

local safehouseBody = assert(safehouseSource:match(
    "%-%- test:safehouse%-distance:start\n(.-)\n%-%- test:safehouse%-distance:end"),
    "找不到 drawSafehouses 測試區段")
-- 主檔滑條 helper（Core.mapTextZoom／drawMapText）抽真實作，接在 harness 的 Core 之後
local mapTextBody = assert(source:match(
    "%-%- test:map%-text:start\n(.-)\n%-%- test:map%-text:end"),
    "找不到主檔 map-text 測試區段")
-- 仿射投影（主檔 deriveAffine）抽真實作：安全屋四角用它投影
local affineBody = assert(source:match(
    "%-%- test:derive%-affine:start\n(.-)\n%-%- test:derive%-affine:end"),
    "找不到主檔 derive-affine 測試區段")
local safehousePrelude = [=[
local distance, ndistance, playerPresent, px, py = nil, nil, true, 0, 10
local houses, drawCount, iconCount, nameCount, drawnNames = {}, 0, 0, 0, {}
-- 快取時鐘：draw() 預設先前進 1000ms（跨過快取窗，既有斷言維持「每次都重讀」語意）；
-- drawSame() 不前進，用來驗快取命中；allowedCalls 數 playerAllowed 跨界呼叫
local clock, allowedCalls, username = 0, 0, "A"
function getTimestampMs() return clock end
-- 三顆玩家開關（預設只開範圍框，既有計數斷言只數框線）
local opts = { Safehouses = true, SafehouseIcons = false, SafehouseNames = false }
-- 滑條（圖標大小／地圖文字大小）：未設＝預設值
local sliders = {}
local function getSliderValue(id, default)
    if sliders[id] == nil then return default end
    return sliders[id]
end
local lastIcon, lastName = nil, nil
local function javaList(values)
    return { size = function() return #values end, get = function(_, i) return values[i + 1] end }
end
SafeHouse = { getSafehouseList = function() return javaList(houses) end }
local function getBoolOption(id, default)
    if opts[id] == nil then return default end
    return opts[id]
end
local function displayDist(name)
    if name == "SafehouseNameDistance" then return ndistance end
    return distance
end
-- 安全屋顯示模式改由 Policy 供給（隱私檢視生效時回最寬的 3）。harness 直接注入
-- 合成後的模式值＝「政策 ＋ 旁路」的唯一輸入；名稱模式獨立一鍵
local shMode, nameMode = 3, 3
local function safehouseDisplayMode() return shMode end
local function safehouseNameMode() return nameMode end
-- 陣營：myFaction 為 nil＝無陣營；members＝同陣營 username 集合
local factionMembers = nil
Faction = { getPlayerFaction = function(username)
    if not factionMembers then return nil end
    return {
        isOwner = function(_, name) return factionMembers[name] == "owner" end,
        isMember = function(_, name) return factionMembers[name] == true end,
    }
end }
local defaultPlayer = {
    getX = function() return px end,
    getY = function() return py end,
    getUsername = function() return username end,
}
-- 分割畫面第二位本機玩家（pn 1）：同位置、不同帳號
local username1 = "B"
local player1 = {
    getX = function() return px end,
    getY = function() return py end,
    getUsername = function() return username1 end,
}
local function getSpecificPlayer(pn)
    if not playerPresent then return nil end
    return pn == 1 and player1 or defaultPlayer
end
local edgeLog = {} -- 框線座標序列（候選列等價測試比對繪製順序用）
local function recordEdge(x1, y1, x2, y2)
    drawCount = drawCount + 1
    -- %g：仿射投影算出的是浮點（Lua 5.3+ 串接成 "14.0"），Kahlua 全是 double 且印成 "14"
    edgeLog[drawCount] = string.format("%g,%g,%g,%g", x1, y1, x2, y2)
end
local function drawClippedEdge(_, x1, y1, x2, y2) recordEdge(x1, y1, x2, y2) end
local SH_EDGE_A = 0.85
-- stencil：地圖框線直畫時整層開一次、外層無條件清除；stencilOpen 留著＝洩漏
local stencilOpen, stencilSets = false, 0
local function adotsTexture() return "tex" end
-- 視野外接框（主檔 visibleWorldAABB）：view＝nil 時回全世界；viewCalls 數跨界次數
local view, viewCalls = nil, 0
local Core = {
    adotsDrawGlyph = function(_, _, x, y, size)
        iconCount = iconCount + 1
        lastIcon = { x = x, y = y, size = size }
    end,
    visibleWorldAABB = function()
        viewCalls = viewCalls + 1
        if view then return view[1], view[2], view[3], view[4] end
        return -1e9, 1e9, -1e9, 1e9
    end,
}
function getTextManager()
    return { MeasureStringX = function() return 20 end, getFontHeight = function() return 10 end }
end
UIFont = { Small = "Small" }
-- worldScale＝px/格（拉遠 LOD 用）：預設 4，測試裡最小的屋（3 格）以外都比 16px 圖標大，既有斷言不受 LOD 影響
local worldScale = 4
local mapAPI = {
    worldToUIX = function(_, x) return x end,
    worldToUIY = function(_, _, y) return y end,
    uiToWorldX = function(_, x) return x end,
    uiToWorldY = function(_, _, y) return y end,
    getWorldScale = function() return worldScale end,
}
local function newInner(pn)
    return { playerNum = pn, mapAPI = mapAPI, width = 100, height = 100,
        javaObject = { DrawLine = function(_, _, x1, y1, x2, y2) recordEdge(x1, y1, x2, y2) end },
        setStencilRect = function() stencilOpen = true; stencilSets = stencilSets + 1 end,
        clearStencilRect = function() stencilOpen = false end,
        drawRect = function() end,
        drawText = function(_, text, x, y)
            nameCount = nameCount + 1; drawnNames[nameCount] = text; lastName = { x = x, y = y, zoom = 1 }
        end,
        drawTextZoomed = function(_, text, x, y, zoom)
            nameCount = nameCount + 1; drawnNames[nameCount] = text; lastName = { x = x, y = y, zoom = zoom }
        end }
end
local inner, inner1 = newInner(0), newInner(1)
local function safehouse(x1, y1, x2, y2, mine, owner, title)
    return {
        getX = function() return x1 end,
        getY = function() return y1 end,
        getX2 = function() return x2 end,
        getY2 = function() return y2 end,
        playerAllowed = function() allowedCalls = allowedCalls + 1; return mine end,
        getOwner = function() return owner or "Z" end,
        getTitle = function() return title or "Safehouse" end,
    }
end
]=]
local safehouseSuffix = [=[
return {
    draw = function()
        clock = clock + 1000
        drawCount, iconCount, nameCount, drawnNames = 0, 0, 0, {}
        drawSafehouses(inner)
        return drawCount, iconCount, nameCount
    end,
    drawSame = function()
        drawCount, iconCount, nameCount, drawnNames = 0, 0, 0, {}
        drawSafehouses(inner)
        return drawCount, iconCount, nameCount
    end,
    -- 分割畫面：第二位本機玩家（pn 1）的地圖，不前進時鐘
    drawSame1 = function()
        drawCount, iconCount, nameCount, drawnNames = 0, 0, 0, {}
        drawSafehouses(inner1)
        return drawCount, iconCount, nameCount
    end,
    stencil = function() return stencilOpen, stencilSets end,
    names = function() return drawnNames end,
    edges = function() return table.concat(edgeLog, ";", 1, drawCount) end,
    resetCandidates = function() inner._minidoracatShCand = nil end,
    candidateCount = function() return inner._minidoracatShCand and inner._minidoracatShCand.n end,
    candidateRows = function() return inner._minidoracatShCand and inner._minidoracatShCand.rows end,
    lastIcon = function() return lastIcon end,
    lastName = function() return lastName end,
    setSlider = function(id, value) sliders[id] = value end,
    advance = function(ms) clock = clock + ms end,
    allowedCalls = function() return allowedCalls end,
    resetAllowedCalls = function() allowedCalls = 0 end,
    setUsername = function(value) username = value end,
    setView = function(minX, maxX, minY, maxY) view = minX and { minX, maxX, minY, maxY } or nil end,
    viewCalls = function() return viewCalls end,
    resetViewCalls = function() viewCalls = 0 end,
    setDistance = function(value) distance = value end,
    setNameDistance = function(value) ndistance = value end,
    setPlayerPresent = function(value) playerPresent = value end,
    setPlayerPosition = function(x, y) px, py = x, y end,
    setHouses = function(value) houses = value end,
    setMode = function(value) shMode = value end,
    setNameMode = function(value) nameMode = value end,
    setOption = function(id, value) opts[id] = value end,
    setScale = function(value) worldScale = value end,
    setUsername1 = function(value) username1 = value end,
    setFaction = function(members) factionMembers = members end,
    modeAllows = safehouseModeAllows,
    safehouse = safehouse,
    inner = function() return inner end,
}
]=]
-- 「顯示在」兩格（Core.layerOn）：抽主檔真實作，讀 prelude 的 opts
local layerMapsBody = assert(source:match(
    "%-%- test:layer%-maps:start\n(.-)\n%-%- test:layer%-maps:end"), "找不到主檔 layer-maps 測試區段")
local safehouseChunk, safehouseErr = compile(safehousePrelude .. "\n" .. mapTextBody
    .. "\nlocal mapTextZoom, drawMapText = Core.mapTextZoom, Core.drawMapText\n"
    .. layerMapsBody .. "\n" .. affineBody .. "\n" .. safehouseBody .. "\n" .. safehouseSuffix)
assert(safehouseChunk, safehouseErr)
local safehouseHarness = safehouseChunk()

local navBody = assert(navSource:match(
    "%-%- test:nav%-share%-gate:start\n(.-)\n%-%- test:nav%-share%-gate:end"),
    "找不到 navShareGateTick 測試區段")
local navChunk, navErr = compile([[
local allowed = true
local navShared = { [0] = true }
local sharedTargets = { A = { x = 1, y = 1 } }
local lastAllowNavShare = true
local Core = { navShareAllowed = function() return allowed end }
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

-- 全域上限 AllInfoDistance（最優先、取較小正值）
assert(normalizeDistance(0, 40) == 40, "只設全域上限時應對個別項目生效")
assert(normalizeDistance(100, 40) == 40, "全域上限應壓過較鬆的個別值")
assert(normalizeDistance(30, 40) == 30, "較嚴的個別值不應被全域上限放寬")
assert(normalizeDistance(40, 40) == 40, "全域＝個別時應保留該值")
assert(normalizeDistance(nil, 0) == nil, "全域 0 應視為不限制")
assert(normalizeDistance(nil, -5) == nil, "負全域上限應忽略")
assert(normalizeDistance(nil, "50") == nil, "非數字全域上限應忽略")

-- displayDist：伺服器（含全域上限）×玩家自訂取較小正值；玩家只能收緊
assert(mergeDist(nil, nil) == nil, "皆未設應不限制")
assert(mergeDist(nil, 0) == nil, "玩家 0 應不限制")
assert(mergeDist(300, nil) == 300, "僅伺服器值應透傳")
assert(mergeDist(nil, 150) == 150, "僅玩家值應生效")
assert(mergeDist(300, 150) == 150, "玩家較嚴應勝出")
assert(mergeDist(100, 500) == 100, "玩家不得放寬伺服器上限")
assert(mergeDist(100, 100) == 100, "同值應保留")
assert(mergeDist(nil, 99999) == 2000, "玩家值應被 CLIENT_DIST_MAX 夾住")
assert(mergeDist(nil, "80") == nil, "非數字玩家值應視為不限制")

-- 設定視窗距離滑條的伺服器上限（只夾顯示、不截斷存值）與「值／上限」文字由 UI.SliderRow
-- 的 cap 負責，回歸在 scripts/test_settings_studio.lua 的 F 段

-- 命名契約守衛："Client"..沙盒名 三方對齊（displayDist 串接 ↔ ESC 註冊 step=1 ↔
-- 設定視窗 capBy/id）——日後新增距離沙盒選項漏註冊 Client 滑條時這裡會紅
local DIST_NAMES = { "ZombieDotDistance", "AnimalIconDistance", "VehicleIconDistance",
    "SafehouseDisplayDistance", "SafehouseNameDistance", "PoiDisplayDistance", "ZoneDisplayDistance" }
for _, n in ipairs(DIST_NAMES) do
    -- 消費端呼叫點可在主檔、_Dots.lua、_Zones.lua 或 _Safehouse.lua（距離閘門隨拆檔遷移）。
    -- 第二參 pn 是管理員檢視旁路的逐 slot 依據——漏傳＝該呼叫點永遠不旁路且靜默不報錯，
    -- 故守衛連「必須帶 pn」一起釘住（右括號改成逗號＋空白）
    assert(source:find('displayDist%("' .. n .. '", pn%)')
        or dotsSource:find('displayDist%("' .. n .. '", pn%)')
        or zonesSource:find('displayDist%("' .. n .. '", pn%)')
        or safehouseSource:find('displayDist%("' .. n .. '", pn%)'),
        "主檔/_Dots/_Zones/_Safehouse 缺 displayDist(\"" .. n .. "\", pn) 精確逐 slot 呼叫點")
    -- ESC 註冊點可在主檔（本體恆存選項，值域用 CLIENT_DIST_MAX 常數）或
    -- _Settings.lua（addon 條件選項 OnGameBoot 尾端追加，字面 2000＝同值——
    -- 該檔無 CLIENT_DIST_MAX local；值域對齊由本守衛釘住）
    assert(source:find('addSlider%("Client' .. n .. '", "UI_MinidoracatMiniMap_Dist%w+", 0, CLIENT_DIST_MAX, 1, 0%)')
        or settingsSource:find('addSlider%("Client' .. n .. '", "UI_MinidoracatMiniMap_Dist%w+", 0, 2000, 1, 0%)'),
        "ESC 頁缺 Client" .. n .. " 滑條註冊（或 step 不為 1／值域不對齊）")
    assert(settingsSource:find('capBy = "' .. n .. '"'),
        "統一視窗 distance 區缺 capBy=" .. n)
    assert(settingsSource:find('id = "Client' .. n .. '"'),
        "統一視窗 distance 區缺 id=Client" .. n)
end
assert(safehouseSource:find('local shMode = safehouseDisplayMode%(pn%)')
    and safehouseSource:find('local nameMode = safehouseNameMode%(pn%)'),
    "安全屋顯示／名稱模式必須使用目前 surface 的 pn")
assert(source:find('local pn = self%.playerNum or 0\n%s*local fa = Core%.featureAllowed')
    and source:find('sandboxGate%("AllowZombieIntensity", true, pn%)'),
    "殭屍熱度閘門不得借用 slot 0")
assert(dotsSource:find('local pn = el%.playerNum or 0\n%s*if sandboxGate%("AllowZombieDots", true, pn%)'),
    "殭屍點位閘門不得借用 slot 0")
assert(dotsSource:find('sandboxGate%("AllowAnimalDots", true, pn%)')
    and dotsSource:find('sandboxGate%("AllowVehicleDots", true, pn%)'),
    "動物／載具閘門必須使用目前 surface 的 pn")
assert(dotsSource:find('livestockVisibilityMode%(pn%)'),
    "牲畜隱私模式必須使用目前 surface 的 pn")
assert(dotsSource:find('if not sec or sec <= 0 or Policy%.tacticalActive%(pn%) then return nil end')
    and dotsSource:find('sampleZombieDots%(el, gateMax, "ZombieScanInterval"%)')
    and dotsSource:find('gateMax, "VehicleAnimalScanInterval"%)')
    and not dotsSource:find('scanIntervalMs%("'),
    "掃描間隔逐 slot 讀沙盒、戰術檢視一律即時，殭屍與載具動物各用自己的鍵；繪製端只傳鍵、不每幀讀 Policy")
assert(dotsSource:find('fa%(pn, "zombie", surface%)') and dotsSource:find('fa%(pn, "scan", surface%)'),
    "點雲功能閘門依表面判定（zombie／scan）")
assert(settingsSource:find('sandboxGate%("AllowZombieDots", true, pn%)')
    and settingsSource:find('sandboxGate%("AllowAnimalDots", true, pn%)')
    and settingsSource:find('sandboxGate%("AllowVehicleDots", true, pn%)'),
    "設定視窗 live gate 必須使用持有者 pn")
local stepOneCount = select(2, settingsSource:gsub('step = 1, fmt = "%%d"', ""))
assert(stepOneCount == 8, "統一視窗距離滑條 step 應全為 1（得 " .. stepOneCount .. "）")

local layerMappings = {
    { "ZombieDots", "AllowZombieDots" }, { "WMZombieDots", "AllowZombieDots" },
    { "AnimalWild", "AllowAnimalDots" }, { "WMAnimalWild", "AllowAnimalDots" },
    { "AnimalLivestock", "AllowAnimalDots" }, { "WMAnimalLivestock", "AllowAnimalDots" },
    { "VehicleDots", "AllowVehicleDots" }, { "WMVehicleDots", "AllowVehicleDots" },
}
-- 「顯示在」兩格的伺服器閘門宣告在主檔 Core.LAYER_MAPS（設定視窗 chip 的停用與分類開關都讀它）；
-- 同一格（同一對大括號內）必須帶對的 gate
for _, mapping in ipairs(layerMappings) do
    local id, gate = mapping[1], mapping[2]
    assert(source:match('{ id = "' .. id .. '"[^}]-gate = "' .. gate .. '"'),
        id .. " 未綁定正確伺服器閘門")
end

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

-- 掃描間隔（沙盒 ZombieScanInterval／VehicleAnimalScanInterval）與功能閘門 maxDist（gateMax）：
-- 定時模式以玩家為中心（視窗外也取）、錨點在玩家、間隔內不重掃；設定只在即時節流節奏
-- （殭屍 300ms／動物載具 500ms）重讀——每幀不讀 Policy，切換最多延遲一個節流窗；
-- gateMax 與 displayDist 取小。設定 0／nil 且 gateMax nil＝與加功能前相同
local ZK, VK = "ZombieScanInterval", "VehicleAnimalScanInterval"
local scanInner = { playerNum = 0 }
zombieHarness.setPlayerPresent(true)
zombieHarness.setDistance(nil)
zombieHarness.setZombies({ zombieHarness.zombie(10, 0), zombieHarness.zombie(500, 0) })
zombieHarness.setNow(5000)
local zReads = zombieHarness.scanReads()
assert(zombieHarness.sample(scanInner, nil, ZK).count == 1, "殭屍即時模式只取視窗內")
zombieHarness.setScan(ZK, 60000)
for t = 5010, 5290, 10 do -- 一個節流窗內 29 幀：設定剛改也不重讀
    zombieHarness.setNow(t)
    assert(zombieHarness.sample(scanInner, nil, ZK).count == 1, "殭屍節流窗內沿用舊設定")
end
assert(zombieHarness.scanReads() - zReads == 1, "殭屍掃描間隔每 ZDOTS_INTERVAL_MS 至多讀一次（每幀不讀 Policy）")
zombieHarness.setNow(5300)
local zst = zombieHarness.sample(scanInner, nil, ZK)
assert(zst.count == 2 and zst.acx == 0 and zst.acy == 0, "殭屍定時模式以玩家為中心取樣、錨點在玩家")
zombieHarness.setZombies({ zombieHarness.zombie(10, 0) })
zombieHarness.setNow(60000)
assert(zombieHarness.sample(scanInner, nil, ZK).count == 2, "殭屍定時模式間隔內不重掃")
zombieHarness.setNow(65400)
assert(zombieHarness.sample(scanInner, nil, ZK).count == 1, "殭屍定時模式滿間隔才重掃")
zombieHarness.setScan(ZK, nil) -- 戰術檢視開啟／沙盒改 0
zombieHarness.setZombies({ zombieHarness.zombie(10, 0), zombieHarness.zombie(20, 0),
    zombieHarness.zombie(500, 0) })
zombieHarness.setNow(65500)
assert(zombieHarness.sample(scanInner, nil, ZK).count == 1, "切回即時前仍在讀值節流窗內")
zombieHarness.setNow(65700)
assert(zombieHarness.sample(scanInner, nil, ZK).count == 2, "切回即時最多延遲一個節流窗就重取樣")
zombieHarness.setNow(66000)
assert(zombieHarness.sample(scanInner, 5, ZK).count == 0, "殭屍功能閘門 maxDist 生效")
zombieHarness.setDistance(30)
zombieHarness.setNow(66500)
assert(zombieHarness.sample(scanInner, 50, ZK).count == 2, "殭屍 maxDist 與 displayDist 取小")
zombieHarness.setDistance(8)
zombieHarness.setNow(67000)
assert(zombieHarness.sample(scanInner, 50, ZK).count == 0, "殭屍 displayDist 較小時以它為準")
zombieHarness.setDistance(nil)

local scanAInner = { playerNum = 0 }
harness.setMode(1)
harness.setDisabledAnimalGroups(nil)
harness.setPlayerPresent(true)
harness.setDistances(nil, nil)
harness.setAnimals({ harness.animal(10, 0, true), harness.animal(500, 0, true) })
harness.setVehicles({ harness.vehicle(20, 0), harness.vehicle(600, 0) })
harness.setNow(9000)
local aReads = harness.scanReads()
assert(harness.sample(scanAInner, true, false, true, false, nil, VK).count == 2, "動物載具即時模式只取視窗內")
harness.setScan(VK, 30000)
for t = 9010, 9490, 10 do -- 一個節流窗內 49 幀
    harness.setNow(t)
    harness.sample(scanAInner, true, false, true, false, nil, VK)
end
assert(harness.scanReads() - aReads == 1, "動物載具掃描間隔每 ADOTS_INTERVAL_MS 至多讀一次（每幀不讀 Policy）")
harness.setNow(9500)
local ast = harness.sample(scanAInner, true, false, true, false, nil, VK)
assert(ast.count == 4 and ast.acx == 0 and ast.acy == 0, "動物載具定時模式以玩家為中心取樣")
harness.setAnimals({ harness.animal(10, 0, true) })
harness.setNow(20000)
assert(harness.sample(scanAInner, true, false, true, false, nil, VK).count == 4,
    "動物載具定時模式間隔內不重掃")
harness.setNow(39500)
assert(harness.sample(scanAInner, true, false, true, false, nil, VK).count == 3,
    "動物載具定時模式滿間隔才重掃")
harness.setNow(39600)
assert(harness.sample(scanAInner, true, false, true, false, 15, VK).count == 1,
    "scan maxDist 同時套動物（10 格內）與載具（20 格被擋）")
harness.setDistances(5, nil)
harness.setNow(39700)
assert(harness.sample(scanAInner, true, false, true, false, 15, VK).count == 0,
    "scan maxDist 與動物 displayDist 取小")
harness.setDistances(nil, nil)
harness.setScan(VK, nil)

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
-- 「顯示在」兩格：小地圖那格關＝小地圖不畫；世界地圖那格照畫；世界地圖選項收起地圖圖層＝世界地圖不畫
safehouseHarness.setOption("SafehouseOnMini", false)
assert(safehouseHarness.draw() == 0, "SafehouseOnMini 關＝小地圖不畫安全屋")
ISWorldMap_instance = safehouseHarness.inner()
assert(safehouseHarness.draw() == 4, "SafehouseOnWorld 開＝世界地圖照畫")
safehouseHarness.setOption("WMLayers", false)
assert(safehouseHarness.draw() == 0, "收起地圖圖層＝世界地圖不畫安全屋")
safehouseHarness.setOption("WMLayers", nil)
safehouseHarness.setOption("SafehouseOnWorld", false)
assert(safehouseHarness.draw() == 0, "SafehouseOnWorld 關＝世界地圖不畫安全屋")
ISWorldMap_instance = nil
safehouseHarness.setOption("SafehouseOnMini", nil)
safehouseHarness.setOption("SafehouseOnWorld", nil)
assert(safehouseHarness.draw() == 4, "兩格恢復＝小地圖照畫")
-- 顯示模式四檔（隱私旁路生效時 safehouseDisplayMode 回 3＝與此處模式3同路徑）
safehouseHarness.setDistance(nil)
safehouseHarness.setHouses({ safehouseHarness.safehouse(10, 10, 20, 20, false, "Z"),
    safehouseHarness.safehouse(30, 30, 40, 40, true, "A"),
    safehouseHarness.safehouse(50, 50, 60, 60, false, "F") })
safehouseHarness.setMode(1)
assert(safehouseHarness.draw() == 0, "安全屋模式1未關閉全部框線")
safehouseHarness.setMode(2)
assert(safehouseHarness.draw() == 4, "安全屋模式2應只畫我方安全屋")
safehouseHarness.setMode(3)
assert(safehouseHarness.draw() == 12, "安全屋模式3應畫全部安全屋（隱私旁路同路徑）")
safehouseHarness.setMode(4)
assert(safehouseHarness.draw() == 4, "無陣營時模式4應退化為僅自己的")
safehouseHarness.setFaction({ F = true })
assert(safehouseHarness.draw() == 8, "模式4應畫自己＋屋主同陣營的安全屋")
safehouseHarness.setFaction({ F = "owner" })
assert(safehouseHarness.draw() == 8, "模式4：屋主是陣營擁有者亦算同陣營")
safehouseHarness.setFaction(nil)
-- 純函式判定表
local allows = safehouseHarness.modeAllows
assert(allows(1, true, true) == false and allows(2, false, true) == false
    and allows(2, true, false) == true and allows(3, false, false) == true
    and allows(4, false, true) == true and allows(4, false, false) == false,
    "safehouseModeAllows 判定表錯誤")
-- 圖標／名稱：圖標跟範圍模式與距離；名稱走獨立模式與獨立距離
safehouseHarness.setMode(3)
safehouseHarness.setOption("Safehouses", false)
safehouseHarness.setOption("SafehouseIcons", true)
safehouseHarness.setOption("SafehouseNames", true)
local rects, icons, names = safehouseHarness.draw()
assert(rects == 0 and icons == 3 and names == 3, "圖標／名稱開關應獨立於範圍框")
-- 圖標大小滑條（原固定 16px）：圖標邊長、置中與名稱掛點（圖標正下方）都跟著變；
-- 地圖文字 200% 時名稱以兩倍繪製、寬度加倍後仍置中（最後畫的是 (50..60) 那間，中心 55）
safehouseHarness.setSlider("SafehouseIconSize", 32)
safehouseHarness.setSlider("MapTextScale", 200)
safehouseHarness.draw()
local lastIconDrawn, lastNameDrawn = safehouseHarness.lastIcon(), safehouseHarness.lastName()
assert(lastIconDrawn.size == 32 and lastIconDrawn.x == 39 and lastIconDrawn.y == 39,
    "安全屋圖標應依滑條畫成 32px 並置中")
assert(lastNameDrawn.zoom == 2 and lastNameDrawn.x == 35 and lastNameDrawn.y == 55 + 16 + 1,
    "名稱應以兩倍字置中、掛在放大後的圖標正下方")
safehouseHarness.setSlider("SafehouseIconSize", nil)
safehouseHarness.setSlider("MapTextScale", nil)
safehouseHarness.setPlayerPosition(0, 10)
safehouseHarness.setDistance(10)
-- 三間：(10..20) 別人的在距內、(30..40) 自己的在距外、(50..60) 別人的在距外
rects, icons, names = safehouseHarness.draw()
assert(icons == 2 and names == 3, "範圍距離只裁圖標（自己的屋不裁），不裁名稱")
safehouseHarness.setNameDistance(10)
rects, icons, names = safehouseHarness.draw()
assert(icons == 2 and names == 2, "名稱距離應獨立裁名稱（自己的屋不裁）")
safehouseHarness.setDistance(nil)
safehouseHarness.setNameDistance(nil)
safehouseHarness.setNameMode(2)
rects, icons, names = safehouseHarness.draw()
assert(icons == 3 and names == 1, "名稱模式2只畫我方名稱、圖標不受影響")
safehouseHarness.setNameMode(1)
safehouseHarness.setMode(1)
rects, icons, names = safehouseHarness.draw()
assert(icons == 0 and names == 0, "兩模式皆關閉時不畫任何東西")
safehouseHarness.setNameMode(3)
safehouseHarness.setMode(3)
safehouseHarness.setPlayerPresent(false)
safehouseHarness.setNameDistance(10)
rects, icons, names = safehouseHarness.draw()
assert(icons == 0 and names == 0, "名稱距離啟用且缺玩家時整層 fail closed")
safehouseHarness.setPlayerPresent(true)
safehouseHarness.setNameDistance(nil)
safehouseHarness.setNameMode(3)
safehouseHarness.setOption("Safehouses", true)
safehouseHarness.setOption("SafehouseIcons", false)
safehouseHarness.setOption("SafehouseNames", false)

-- 快取與距離閘（2026-09-25）：幾何／成員 1 秒快取（重建時每列查一次成員）、距離閘先於陣營判定
do
    local H = safehouseHarness
    local mutable = { x1 = 10 }
    local moving = H.safehouse(10, 10, 20, 20, false)
    moving.getX = function() return mutable.x1 end
    H.setHouses({ moving })
    H.setMode(3); H.setNameMode(3)
    H.setPlayerPosition(0, 10); H.setDistance(10); H.setNameDistance(nil)
    assert(H.draw() == 4, "快取前置：距離內應畫")
    mutable.x1 = 500
    assert(H.drawSame() == 4, "快取窗內應沿用舊幾何（不重讀 getter）")
    H.advance(999)
    assert(H.drawSame() == 4, "未滿 1000ms 仍應命中快取")
    H.advance(1)
    assert(H.drawSame() == 0, "滿 1000ms 應重建並讀到新幾何")
    H.advance(-5000)
    mutable.x1 = 10
    assert(H.drawSame() == 4, "時鐘倒退應視為過期並重建")

    -- 筆數變動立即重建（不等 1 秒）
    H.setHouses({ moving, H.safehouse(10, 5, 20, 15, false) })
    assert(H.drawSame() == 8, "清單筆數變動應立即重建")

    -- 帳號變動立即重建，成員判定重查
    H.resetAllowedCalls()
    H.setUsername("B")
    H.drawSame()
    assert(H.allowedCalls() == 2, "帳號變動應重建並重查成員（2 間各 1 次）")
    H.setUsername("A")

    -- 距離閘：遠處別人的屋不畫（放在 100x100 畫面內：整條在畫面外的邊本來就不畫）
    local far = H.safehouse(80, 80, 90, 90, false)
    local near = H.safehouse(10, 10, 20, 20, true)
    H.setHouses({ far, near })
    assert(H.draw() == 4, "距離閘：只畫近的那間")

    -- 成員判定隨列快取：同一快取窗內重畫不再查，過期後每列重查一次
    H.resetAllowedCalls()
    H.drawSame(); H.drawSame()
    assert(H.allowedCalls() == 0, "快取窗內成員結果應重用")
    H.advance(1000)
    H.drawSame()
    assert(H.allowedCalls() == 2, "快取過期後每列重查一次成員")

    -- 名稱距離獨立：框線超距但名稱距離內，仍要查成員並畫名稱
    H.setOption("Safehouses", true); H.setOption("SafehouseNames", true)
    H.setHouses({ H.safehouse(10, 10, 20, 20, false) })
    H.setDistance(5); H.setNameDistance(20)
    local rects, _, names = H.draw()
    assert(rects == 0 and names == 1, "框線超距、名稱在距內：只畫名稱")
    H.setDistance(20); H.setNameDistance(5)
    rects, _, names = H.draw()
    assert(rects == 4 and names == 0, "框線在距內、名稱超距：只畫框線")

    -- 視野裁切（不限距離時）：畫面外整列跳過；相接／部分重疊仍畫
    H.setOption("SafehouseNames", false)
    H.setDistance(nil); H.setNameDistance(nil)
    H.setView(0, 100, 0, 100)
    local inView = H.safehouse(10, 10, 20, 20, false)
    local outView = H.safehouse(500, 500, 510, 510, false)
    local touching = H.safehouse(100, 50, 110, 60, false)   -- x1 == maxX：相接
    local straddle = H.safehouse(-5, -5, 5, 5, false)       -- 跨左上角
    local touchLeft = H.safehouse(-10, 50, 0, 60, false)    -- x2 == minX：相接
    local belowView = H.safehouse(50, 150, 60, 160, false)  -- 只有 Y 超出
    local touchTop = H.safehouse(50, -10, 60, 0, false)     -- y2 == minY：相接
    local touchBottom = H.safehouse(50, 100, 60, 110, false) -- y1 == maxY：相接
    H.setHouses({ inView, outView, touching, straddle, touchLeft, belowView, touchTop, touchBottom })
    -- 逐列看有沒有畫（整條落在畫面外的邊本來就不畫，邊數不能拿來判列）
    H.draw()
    local log = H.edges()
    local function has(s) return string.find(log, s, 1, true) ~= nil end
    assert(has("10,10,20,10") and has("100,50,110,50") and has("5,-5,5,5") and has("-10,50,0,50")
        and has("60,-10,60,0") and has("50,100,60,100"), "視野裁切：畫面內、四邊相接、跨邊的列都畫：" .. log)
    assert(not has("500,500") and not has(",150,"), "視野裁切：X 或 Y 超出的列不畫")
    H.setView(200, 300, 200, 300)
    assert(H.draw() == 0, "視野移走後全部裁掉")
    -- 所有已開圖層都有距離閘：不計算可見範圍（省 8 次 uiToWorld）
    H.setView(nil)
    H.setDistance(50)
    H.resetViewCalls()
    H.draw()
    assert(H.viewCalls() == 0, "框線有距離閘且名稱關閉時不應計算可見範圍")
    H.setOption("SafehouseNames", true); H.setNameDistance(nil)
    H.resetViewCalls()
    H.draw()
    assert(H.viewCalls() == 1, "名稱不限距離時應計算可見範圍")
    H.setOption("SafehouseNames", false); H.setDistance(nil)

    -- 無距離限制：全部畫，每間各查一次成員
    H.setDistance(nil); H.setNameDistance(nil)
    H.setOption("SafehouseNames", false)
    H.setHouses({ far, near })
    H.resetAllowedCalls()
    assert(H.draw() == 8, "無距離限制應畫全部")
    assert(H.allowedCalls() == 2, "無距離限制時每間各查一次成員")
end

-- 自己的屋（屋主或成員）不受距離閘（2026-10-14 Safehouse 交辦：正式服距離 20 格，離家稍遠就在世界地圖
-- 找不到自己家）：框、圖標、名稱照畫；別人的與同陣營的照距離閘；視野外照樣裁掉。
-- 座標都放在 100x100 畫面內（harness 投影＝恆等），圖標與名稱才畫得出來
do
    local H = safehouseHarness
    H.setMode(3); H.setNameMode(3); H.setView(nil); H.setFaction(nil)
    H.setOption("Safehouses", true); H.setOption("SafehouseIcons", true); H.setOption("SafehouseNames", true)
    H.setPlayerPosition(20, 20); H.setDistance(6); H.setNameDistance(6)
    H.setHouses({ H.safehouse(24, 24, 34, 34, false, "Z", "Near"), H.safehouse(60, 20, 70, 30, true, "A", "Home"),
        H.safehouse(20, 60, 30, 70, false, "F", "Ally"), H.safehouse(60, 60, 70, 70, false, "Z", "Far") })
    local edges, icons, names = H.draw()
    assert(edges == 8 and icons == 2 and names == 2, "距離閘：自己遠處的屋照畫框、圖標、名稱，別人遠處的不畫")
    assert(table.concat(H.names(), "|") == "Near (Z)|Home (A)", "名稱：近的別人＋遠的自己：" .. table.concat(H.names(), "|"))
    assert(H.candidateCount() == 2, "候選列：距離閘之外只多留自己的屋（得 " .. tostring(H.candidateCount()) .. "）")
    H.setMode(2); H.setNameMode(2)
    edges, icons, names = H.draw()
    assert(edges == 4 and icons == 1 and names == 1, "模式2＋距離閘：自己遠處的屋照畫")
    H.setMode(4); H.setNameMode(4); H.setFaction({ F = true })
    edges, icons, names = H.draw()
    assert(edges == 4 and names == 1 and H.names()[1] == "Home (A)", "模式4：同陣營遠處的屋照距離閘，只剩自己的")
    H.setDistance(nil); H.setNameDistance(nil)
    assert(H.draw() == 8, "模式4 不限距離：同陣營遠處的屋也畫（對照：上一條是距離閘擋的）")
    H.setFaction(nil); H.setMode(3); H.setNameMode(3)
    -- 名稱不限距離＝要算可見範圍：視野裁切照樣作用在自己的屋
    H.setDistance(6)
    H.setView(0, 50, 0, 50)
    edges, icons, names = H.draw()
    assert(edges == 4 and icons == 1 and names == 1, "視野外的自己的屋照樣裁掉")
    H.setView(55, 100, 0, 100)
    edges, icons, names = H.draw()
    assert(edges == 4 and icons == 1 and names == 2, "視野內：自己的屋不看距離；別人的框照距離、名稱不限距離照畫")
    H.setView(nil); H.setDistance(nil); H.setPlayerPosition(0, 10)
    H.setOption("SafehouseIcons", false); H.setOption("SafehouseNames", false)
end

-- 拉遠 LOD（2026-10-14 世界地圖整張入鏡實測每幀 11.7ms）：別人的屋在畫面上比圖標小只畫框，
-- 小於 4px 整間不畫；自己的屋多小都全畫
do
    local H = safehouseHarness
    H.setMode(3); H.setNameMode(3); H.setView(nil); H.setDistance(nil); H.setNameDistance(nil)
    H.setOption("Safehouses", true); H.setOption("SafehouseIcons", true); H.setOption("SafehouseNames", true)
    H.setHouses({ H.safehouse(10, 10, 20, 20, false, "Z", "Big"), H.safehouse(40, 40, 42, 42, true, "A", "Tiny"),
        H.safehouse(60, 10, 63, 13, false, "Z", "Small") })
    local function at(scale)
        H.setScale(scale)
        local e, i, n = H.draw()
        return e .. "/" .. i .. "/" .. n .. " " .. table.concat(H.names(), "|")
    end
    -- 4px/格：Big 40px 全畫、Small 12px 只畫框、自己 8px 全畫
    assert(at(4) == "12/2/2 Big (Z)|Tiny (A)", "LOD 4px/格：" .. at(4))
    -- 1px/格：Big 10px 只畫框、Small 3px 不畫
    assert(at(1) == "8/1/1 Tiny (A)", "LOD 1px/格：" .. at(1))
    -- 0.3px/格：別人的全不畫，自己的照畫
    assert(at(0.3) == "4/1/1 Tiny (A)", "LOD 0.3px/格：" .. at(0.3))
    H.setScale(4)
    H.setOption("SafehouseIcons", false); H.setOption("SafehouseNames", false)
end

-- 框線直畫的整層 stencil：畫了就開、畫完一定清（含中途丟錯）；漏清會讓當幀後續 UI 全被裁到地圖矩形
do
    local H = safehouseHarness
    H.setMode(3); H.setNameMode(3); H.setView(nil); H.setDistance(nil); H.setNameDistance(nil)
    H.setOption("Safehouses", true); H.setOption("SafehouseIcons", false); H.setOption("SafehouseNames", true)
    local bad = H.safehouse(10, 10, 20, 20, false, "Z", "Bad")
    H.setHouses({ bad })
    local _, sets0 = H.stencil()
    H.draw()
    local open, sets = H.stencil()
    assert(sets == sets0 + 1 and not open, "畫了框線：stencil 開一次、畫完清掉")
    bad.getTitle = function() error("injected title failure") end
    local ok = pcall(H.draw)
    open = H.stencil()
    assert(not ok and not open, "畫到一半丟錯：錯誤照樣往外丟，stencil 仍清掉")
    H.setOption("SafehouseNames", false)
end

-- 分割畫面：每位本機玩家各一份列快取。兩位帳號不同時輪流畫，不得每幀互相觸發重建（重查成員）
do
    local H = safehouseHarness
    H.setMode(3); H.setNameMode(3); H.setView(nil); H.setDistance(nil); H.setNameDistance(nil)
    H.setHouses({ H.safehouse(10, 10, 20, 20, false), H.safehouse(30, 30, 40, 40, false) })
    H.draw()
    H.drawSame1()
    H.resetAllowedCalls()
    for _ = 1, 3 do H.drawSame(); H.drawSame1() end
    assert(H.allowedCalls() == 0, "兩位本機玩家輪流畫：快取窗內都不重建（實際 " .. H.allowedCalls() .. "）")
    H.setUsername1("C")
    H.drawSame1()
    assert(H.allowedCalls() == 2, "第二位玩家換帳號只重建他自己那份")
    H.drawSame()
    assert(H.allowedCalls() == 2, "第一位玩家的快取不受影響")
    H.setUsername1("B")
end

-- 名稱標籤：標題＝屋主帳號（原版右鍵認領的預設標題）照原樣；自訂標題後綴「(屋主)」；
-- 空標題不畫；改名在快取重建後連同屋主一起反映
do
    local H = safehouseHarness
    H.setMode(3); H.setNameMode(3)
    H.setDistance(nil); H.setNameDistance(nil); H.setView(nil)
    H.setOption("Safehouses", false); H.setOption("SafehouseIcons", false)
    H.setOption("SafehouseNames", true)
    local title = "Alice"
    local claimed = H.safehouse(10, 10, 20, 20, false, "Alice")
    claimed.getTitle = function() return title end
    H.setHouses({ claimed, H.safehouse(30, 10, 40, 20, false, "Bob", "Bob's Farm"),
        H.safehouse(50, 10, 60, 20, false, "Carol", "") })
    H.draw()
    local got = H.names()
    assert(#got == 2 and got[1] == "Alice" and got[2] == "Bob's Farm (Bob)",
        "預設標題照原樣、自訂名稱後綴屋主帳號、空標題不畫：" .. table.concat(got, " | "))
    title = "Fort"
    H.draw()
    assert(H.names()[1] == "Fort (Alice)", "改名後快取重建應顯示新名稱與屋主帳號")
    H.setOption("SafehouseNames", false); H.setOption("Safehouses", true)
end

-- Safehouse MOD 的屋：原生屋主是服務帳號 "@MSH:<id>"，標籤與同陣營改用 v1.ownerName 的真正屋主；
-- 沒裝／資料未到（nil）／API 不合只顯示名稱、不算同陣營，絕不露出 "@MSH:"；資料到了在列快取重建時更新
do
    local H = safehouseHarness
    H.setMode(3); H.setNameMode(3)
    H.setDistance(nil); H.setNameDistance(nil); H.setView(nil)
    H.setOption("Safehouses", false); H.setOption("SafehouseIcons", false)
    H.setOption("SafehouseNames", true)
    local real, asked = {}, {}
    local api = { API_MAJOR = 1, CAPABILITIES = { ownerName = true },
        ownerName = function(owner) asked[#asked + 1] = owner; return real[owner] end }
    H.setHouses({ H.safehouse(10, 10, 20, 20, false, "@MSH:7", "Fort"),
        H.safehouse(30, 10, 40, 20, false, "@MSH:8", "Alice"),
        H.safehouse(50, 10, 60, 20, false, "Bob", "Bob's Farm") })
    local function labels() H.draw(); return table.concat(H.names(), " | ") end
    assert(labels() == "Fort | Alice | Bob's Farm (Bob)", "沒裝 Safehouse：服務帳號不得出現在標籤")
    MinidoracatSafehouse = { v1 = api }
    assert(labels() == "Fort | Alice | Bob's Farm (Bob)", "Safehouse 資料未到：只顯示名稱")
    assert(#asked == 2 and asked[1] == "@MSH:7" and asked[2] == "@MSH:8", "一般安全屋不應查 Safehouse")
    real["@MSH:7"], real["@MSH:8"] = "Alice", "Alice"
    -- 名稱＝真正屋主（"Alice"）只顯示一次；第一次查是 nil 也會在列快取重建（draw 前進 1 秒）後更新
    assert(labels() == "Fort (Alice) | Alice | Bob's Farm (Bob)",
        "資料到了：列快取重建後顯示真正屋主，名稱＝屋主只顯示一次")
    api.API_MAJOR = 2
    assert(labels() == "Fort | Alice | Bob's Farm (Bob)", "API_MAJOR 不合視同沒裝")
    api.API_MAJOR = 1
    -- 同陣營（模式4）：真正屋主 Alice 在我的陣營＝青框；資料未到不算同陣營
    H.setOption("SafehouseNames", false); H.setOption("Safehouses", true)
    H.setHouses({ H.safehouse(10, 10, 20, 20, false, "@MSH:7", "Fort") })
    H.setMode(4); H.setFaction({ Alice = true })
    assert(H.draw() == 4, "模式4：Safehouse 的屋以真正屋主判同陣營")
    real["@MSH:7"] = nil; H.setFaction({ ["@MSH:7"] = true })
    assert(H.draw() == 0, "模式4：真正屋主未到不算同陣營（不得拿服務帳號比對）")
    H.setFaction(nil); H.setMode(3)
    MinidoracatSafehouse = nil
end

-- Safehouse MOD 的一間多塊（每塊一個原生、屋主同為 "@MSH:<id>"）：同一間只畫外緣、交界不畫，圖標與名稱只標一次
-- （最大的那塊中心）；原版同一屋主的多間、不同標記的兩間照舊各畫各的
do
    local H = safehouseHarness
    H.setMode(3); H.setNameMode(3); H.setView(nil); H.setDistance(nil); H.setNameDistance(nil)
    H.setOption("Safehouses", true); H.setOption("SafehouseIcons", true); H.setOption("SafehouseNames", true)
    -- L：直條 (10,10)-(14,22) 48 格＋右下 (14,18)-(22,22) 32 格，共用 x＝14 的 y 18..22
    local function L(ownerA, ownerB)
        H.setHouses({ H.safehouse(10, 10, 14, 22, true, ownerA, "Base"), H.safehouse(14, 18, 22, 22, true, ownerB, "Base") })
    end
    L("@MSH:9", "@MSH:9")
    local edges, icons, names = H.draw()
    local log = H.edges()
    assert(edges == 7, "多塊：L 形兩塊畫 7 段外緣（交界不畫），實際 " .. edges)
    assert(not string.find(log, "14,18,14,22", 1, true) and not string.find(log, "14,22,14,18", 1, true),
        "多塊：塊與塊的交界不畫")
    assert(string.find(log, "14,10,14,18", 1, true) and string.find(log, "14,18,22,18", 1, true),
        "多塊：直條的右緣只畫到交界上方、橫條的上緣照畫")
    assert(icons == 1 and names == 1, "多塊：同一間只標一次圖標與名稱")
    local icon = H.lastIcon()
    assert(icon.x + icon.size / 2 == 12 and icon.y + icon.size / 2 == 16, "多塊：標在最大那塊（直條）的中心")
    -- 列快取每秒重建：各塊座標沒變就沿用上次的外緣段（同一張段表），畫出來逐筆相同；挪動一塊就重算
    H.setView(-1000, 1000, -1000, 1000)
    H.draw()
    local log1, rows1 = H.edges(), H.candidateRows()
    H.draw()
    local rows2 = H.candidateRows()
    assert(rows2 ~= rows1 and rows2[1].segs == rows1[1].segs and rows2[2].segs == rows1[2].segs and H.edges() == log1,
        "多塊：列快取重建時座標沒變的屋沿用上次的外緣段，畫法不變")
    H.setHouses({ H.safehouse(10, 10, 14, 22, true, "@MSH:9", "Base"), H.safehouse(14, 18, 22, 23, true, "@MSH:9", "Base") })
    H.draw()
    assert(H.candidateRows()[2].segs ~= rows2[2].segs and H.edges() ~= log1, "多塊：挪動一塊就重算外緣段")
    H.setView(nil)
    -- 對照：原版屋主（同一人相鄰的兩間）與不同標記的兩間不合併
    L("Bob", "Bob")
    edges, icons, names = H.draw()
    assert(edges == 8 and icons == 2 and names == 2, "原版同一屋主的兩間各畫各的")
    L("@MSH:9", "@MSH:10")
    edges, icons, names = H.draw()
    assert(edges == 8 and icons == 2 and names == 2, "不同標記的兩間不合併")
    H.setOption("SafehouseIcons", false); H.setOption("SafehouseNames", false)
end

-- 候選列（shCandidates，2026-10-07：數百間安全屋逐幀全掃）：沿用候選與每幀重篩的繪製逐筆相同
-- （框線座標序列、圖標數、名稱序列）。視野裁切與純距離閘兩種模式，玩家／視窗沿路徑移動、半徑中途改變
do
    local H = safehouseHarness
    H.setMode(3); H.setNameMode(3); H.setView(nil)
    H.setOption("Safehouses", true); H.setOption("SafehouseIcons", true); H.setOption("SafehouseNames", true)
    local seed = 7
    local function rnd(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n
    end
    -- 自己的屋（約 1/20）不看距離、一律在候選裡；比例太高，下方「候選只剩附近」的斷言就量不出篩選
    local houses = {}
    for i = 1, 300 do
        local x, y = rnd(600), rnd(600)
        houses[i] = H.safehouse(x, y, x + 3 + rnd(12), y + 3 + rnd(12), rnd(20) == 0, "O" .. (i % 9), "T" .. i)
    end
    H.setHouses(houses)
    H.draw()
    local function snapshot()
        local d, ic, n = H.drawSame()
        return d .. "/" .. ic .. "/" .. n .. "|" .. H.edges() .. "|" .. table.concat(H.names(), ",")
    end
    local drawn = 0
    for _, mode in ipairs({ "view", "dist" }) do
        for s = 0, 40 do
            local px, py = 50 + s * 9, 80 + s * 7
            H.setPlayerPosition(px, py)
            if mode == "view" then
                H.setDistance(nil); H.setNameDistance(nil)
                H.setView(px - 50, px + 50, py - 50, py + 50)
            else
                H.setView(nil)
                H.setDistance(s < 20 and 30 or 45); H.setNameDistance(20)
            end
            local cached = snapshot()
            H.resetCandidates()
            local fresh = snapshot()
            if s == 0 then -- 重篩後的候選只剩附近的列（殺「候選＝全部列」）
                assert(H.candidateCount() < #houses / 4,
                    mode .. "：候選列應只剩附近的安全屋（得 " .. tostring(H.candidateCount()) .. "）")
            end
            assert(cached == fresh, string.format("%s 第 %d 步：沿用候選與重篩的繪製不同\n  沿用：%s\n  重篩：%s",
                mode, s, cached:sub(1, 300), fresh:sub(1, 300)))
            if not cached:find("^0/") then drawn = drawn + 1 end
        end
    end
    assert(drawn > 40, "候選列等價測試的路徑太空（有繪製的步數 " .. drawn .. "）")
    H.setView(nil); H.setDistance(nil); H.setNameDistance(nil); H.setPlayerPosition(0, 10)
    H.setOption("SafehouseIcons", false); H.setOption("SafehouseNames", false)
end

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
