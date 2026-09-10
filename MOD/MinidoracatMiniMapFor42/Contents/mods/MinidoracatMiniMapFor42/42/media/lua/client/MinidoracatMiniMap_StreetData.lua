-- 地圖街道載入協調：街名翻譯與語系無關的道路修正各自提供資料。
-- WorldMap.java:193-218 同步 combine。只在副本建立窗口暫改 raw 名稱／點列，
-- 結束後恢復；不碰來源 XML、不 dirty 玩家地圖、不使用 editor setter。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- test:street-i18n:start
local function buildStreetSourceIndex(packs, logFn)
    local byDir = {}
    for _, pack in ipairs(packs or {}) do
        if type(pack) == "table" and type(pack.owner) == "string" and type(pack.entries) == "table" then
            for _, entry in ipairs(pack.entries) do
                if type(entry) == "table" and (entry.streetNames ~= nil or entry.streetRepairs ~= nil) then
                    local valid = type(entry.mapDir) == "string" and entry.mapDir ~= ""
                        and (entry.mapMod == nil or type(entry.mapMod) == "string")
                    local names = entry.streetNames
                    if names ~= nil then
                        local validNames = type(names) == "table"
                        if validNames then
                            for original, key in pairs(names) do
                                if type(original) ~= "string" or original == ""
                                    or type(key) ~= "string" or not key:match("^UI_[%w_.%-]+$") then
                                    validNames = false
                                    break
                                end
                            end
                        end
                        if not validNames then
                            names = nil
                            if logFn then logFn("invalid street name dictionary from " .. pack.owner) end
                        end
                    end
                    if valid then
                        local dir = entry.mapDir:lower()
                        local candidates = byDir[dir]
                        if not candidates then candidates = {}; byDir[dir] = candidates end
                        candidates[#candidates + 1] = {
                            owner = pack.owner, mapMod = entry.mapMod,
                            names = names, repairs = entry.streetRepairs,
                        }
                    elseif logFn then logFn("invalid street source from " .. pack.owner) end
                end
            end
        end
    end
    return byDir
end

local function resolveStreetSource(candidates, activeSet)
    local chosen
    for _, candidate in ipairs(candidates or {}) do
        if candidate.mapMod == nil or (activeSet and activeSet[candidate.mapMod]) then
            if chosen and (chosen.owner ~= candidate.owner or not rawequal(chosen.names, candidate.names)
                or not rawequal(chosen.repairs, candidate.repairs)) then
                return nil
            end
            chosen = candidate
        end
    end
    return chosen
end

local logged = {}
local function logOnce(key, message)
    if logged[key] then return end
    logged[key] = true
    print("[MinidoracatMiniMap] " .. message)
end
local rejectedText = {}
local function translateStreetName(original, names, translate)
    local key = names and names[original]
    if not key then return original end
    local ok, value = pcall(translate, key)
    if not ok then
        logOnce("translation", "street name lookup failed: " .. tostring(value) .. "; keeping original names")
        return original
    end
    if type(value) ~= "string" or value:match("^%s*$") or value == key or rejectedText[value] then return original end
    return value
end
-- test:street-i18n:end

local index
local resolvedSources = {}
local inFlight = {}

local function sourceForDirectory(dir)
    if type(dir) ~= "string" then return nil end
    if not index then
        index = buildStreetSourceIndex(Core.registeredPacks, function(message)
            logOnce(message, message)
        end)
    end
    local candidates = index[dir:lower()]
    if not candidates then return nil end
    local active = {}
    local mods = getActivatedMods()
    for i = 0, mods:size() - 1 do active[mods:get(i)] = true end
    local chosen = resolveStreetSource(candidates, active)
    resolvedSources[dir:lower()] = chosen or false
    if not chosen then
        logOnce("conflict:" .. dir, "street names source ambiguous or inactive: " .. dir .. "; keeping original")
        return nil
    end
    return chosen
end

local function currentTranslation(key)
    local lang = Translator.getLanguage():name()
    if lang == "CH" or lang == "CN" or lang == "JP" then return getTextOrNull(key) end
    return nil
end

Core.streetSource = function(dir)
    if type(dir) ~= "string" then return nil end
    local source = resolvedSources[dir:lower()]
    if source == nil then source = sourceForDirectory(dir) end
    return source or nil
end

-- 顯示譯名不影響 raw 原名與道路型別辨識。
Core.streetDisplayName = function(original, dir)
    local source = Core.streetSource(dir)
    return translateStreetName(original, source and source.names, currentTranslation)
end

local origInit = MapUtils and MapUtils.initDirectoryStreetData
if type(origInit) ~= "function" then
    print("[MinidoracatMiniMap] StreetData DISABLED: directory loader unavailable")
    return
end

local function applyChange(change)
    local street = change.street
    if change.replacement then
        Core.replaceStreetPoints(street, change.replacement)
        change.pointsApplied = true
    end
    street:setTranslatedText(change.translated)
    if street:getTranslatedText() == "" and change.translated ~= "" then
        rejectedText[change.translated] = true
        street:setTranslatedText(change.original)
    end
    change.translated = street:getTranslatedText()
    street:clipToObscuredCells()
end

local function restoreChanges(changes)
    if not changes then return end
    for i = #changes, 1, -1 do
        local change = changes[i]
        local ok, err = pcall(function()
            if change.replacement and (not change.pointsApplied
                or Core.matchesStreetRepair(change.street, change.width, change.replacement)) then
                Core.replaceStreetPoints(change.street, change.originalPoints)
            end
            if change.street:getTranslatedText() == change.translated then
                change.street:setTranslatedText(change.original)
            end
            change.street:clipToObscuredCells()
        end)
        if not ok then logOnce("restore", "street data restore failed: " .. tostring(err)) end
    end
end

local function suspendWindow(parent, suspended)
    for i = #parent, 1, -1 do
        local old = parent[i]
        local current = old.street:getTranslatedText()
        local ownsPoints = old.replacement and old.pointsApplied
            and Core.matchesStreetRepair(old.street, old.width, old.replacement)
        local name = current == old.translated and old.original or current
        if ownsPoints or name ~= current then
            -- 反向交易：先還原外層，inner 完成後 restoreChanges 會恢復外層窗口。
            local change = {
                street = old.street, original = current, translated = name,
                replacement = ownsPoints and old.originalPoints,
                originalPoints = ownsPoints and old.replacement, width = old.width,
            }
            suspended[#suspended + 1] = change
            applyChange(change)
        end
    end
end

function MapUtils.initDirectoryStreetData(mapUI, directory)
    local lang = Translator.getLanguage():name()
    local translate = lang == "CH" or lang == "CN" or lang == "JP"
    local changes, scratchAPI, window, parent, suspended = {}, nil, nil, nil, nil
    local prepared, prepareErr = pcall(function()
        local dir = type(directory) == "string" and directory:match("^media/maps/(.+)$") or nil
        local source = sourceForDirectory(dir)
        if not source or (not source.repairs and not (translate and source.names)) then return end
        local names = source.names
        local relative = directory .. "/streets.xml"
        if not fileExists(relative) then return end
        local targetAPI = mapUI.javaObject:getAPIv3():getStreetsAPI()
        -- 不清除／重組已存在的玩家地圖副本；第三方已先載入者維持原狀。
        if targetAPI:getStreetDataByRelativeFileName(relative) then return end
        -- 一次性 scratch 不加入 UIManager，不 render/pick；僅取得原生 raw 快取。
        -- vanilla 建構用例：ISWorldMap.lua stashMapBoundsUI。
        local scratch = UIWorldMap.new({})
        scratchAPI = scratch:getAPIv3():getStreetsAPI()
        scratchAPI:addStreetData(relative)
        local data = scratchAPI:getStreetDataByRelativeFileName(relative)
        if not data then error("native street data unavailable") end
        -- 顯示抑制屬於特定 map；重入不能借用外層的隱藏結果。
        window, parent = data, inFlight[data]
        inFlight[data] = changes
        if parent then
            suspended = {}
            suspendWindow(parent, suspended)
        end
        local streets = getStreets(data)
        for i = 0, streets:size() - 1 do
            local street = streets:get(i)
            local original = street:getTranslatedText() or ""
            local repair = Core.streetRepair and Core.streetRepair(street, dir, i)
            local replacement = repair and repair.replacementPoints
            local translated = translate and translateStreetName(original, names, getTextOrNull) or original
            local hidden = repair and repair.hideLabel and Core.canHideStreetLabel
                and Core.canHideStreetLabel(repair, mapUI, dir, translated)
            if hidden then
                -- 退化顯示路徑使原生 Clipper 不產生重複副本；不是刪除 raw／導航道路。
                -- 不用空名稱，避免 pickStreet 選到一個空的 hover 標籤框。
                local x, y = repair.expectedPoints[1], repair.expectedPoints[2]
                replacement = { x, y, x, y }
            end
            if translated ~= original or replacement then
                local change = {
                    street = street, original = original, translated = translated,
                    replacement = replacement, originalPoints = replacement and repair.expectedPoints,
                    width = replacement and repair.expectedWidth,
                }
                changes[#changes + 1] = change
                applyChange(change)
            end
        end
        logOnce("loaded:" .. dir .. ":" .. lang,
            "street data prepared: " .. dir .. " (" .. lang .. ", " .. #changes .. " display changes)")
    end)
    -- prepare 失敗時先回到 raw，再呼叫原 loader；此時外層窗口仍保持暫停。
    if not prepared then
        restoreChanges(changes)
        logOnce("prepare", "street data unavailable: " .. tostring(prepareErr) .. "; using original loader")
    end
    local loaded, result = pcall(origInit, mapUI, directory)
    if prepared then restoreChanges(changes) end
    restoreChanges(suspended)
    if scratchAPI then
        -- 只清從未顯示、永不重用的 scratch（WorldMap.java:241-248 removeListener）。
        -- 死 lookup 隨 scratch 回收；絕不清玩家 map，也不呼叫 editor setter 標 dirty。
        local ok, err = pcall(function() scratchAPI:clearStreetData() end)
        if not ok then logOnce("cleanup", "street names scratch cleanup failed: " .. tostring(err)) end
    end
    if window then inFlight[window] = parent end
    if not loaded then error(result) end
    return result
end
print("[MinidoracatMiniMap] StreetData armed (names and independent repairs)")
