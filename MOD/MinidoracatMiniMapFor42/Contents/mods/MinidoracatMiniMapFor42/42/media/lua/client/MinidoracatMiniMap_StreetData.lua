-- 地圖街道載入協調：街名翻譯、語系無關的道路修正、addon 補充道路各自提供資料。
-- WorldMap.java:193-218 同步 combine。只在副本建立窗口暫改 raw 名稱／點列，
-- 結束後恢復；不碰來源 XML、不 dirty 玩家地圖、不使用 editor setter。
-- 42.21 起 raw 名稱是 untranslated（WorldMapStreet.java:178-188）：原名一律讀
-- getUntranslatedText()；getTranslatedText() = Translator.getText(raw)，debug 會加前綴。
-- clipToObscuredCells（:577-634）以 getTranslatedText() 固化 split；窗口寫入的是已驗證的
-- 譯文字串（非 UI_ 鍵，Translator 原樣回傳），保留 Java 空白正規化的 rejectedText 守衛。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- test:street-i18n:start
local function buildStreetSourceIndex(packs, logFn)
    local byDir = {}
    for _, pack in ipairs(packs or {}) do
        if type(pack) == "table" and type(pack.owner) == "string" and type(pack.entries) == "table" then
            for _, entry in ipairs(pack.entries) do
                if type(entry) == "table" and (entry.streetNames ~= nil or entry.streetRepairs ~= nil
                    or entry.streetSupplement ~= nil) then
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
                            supplement = entry.streetSupplement,
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
                or not rawequal(chosen.repairs, candidate.repairs)
                or not rawequal(chosen.supplement, candidate.supplement)) then
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
local function translateStreetName(original, key, translate)
    if not key then return original end
    local ok, value = pcall(translate, key)
    if not ok then
        logOnce("translation", "street name lookup failed: " .. tostring(value) .. "; keeping original names")
        return original
    end
    if type(value) ~= "string" or value:match("^%s*$") or value == key or rejectedText[value] then return original end
    return value
end

-- addon 補充道路（作者沒放進 streets.xml 的路）只驗結構；作者資料比對另做。
-- file 不得位於 media/maps/：那是地圖目錄自己的 streets.xml 命名空間，不能冒充。
local function validSupplement(sup, mapMod, dir)
    if type(sup) ~= "table" or sup.schemaVersion ~= 1 or sup.mapMod ~= mapMod
        or type(sup.mapDir) ~= "string" or type(dir) ~= "string" or sup.mapDir:lower() ~= dir:lower()
        or type(sup.file) ~= "string" or not sup.file:match("^media/[^%c]+%.xml$")
        or sup.file:lower():find("^media/maps/")
        or type(sup.upstreamStreetCount) ~= "number" or sup.upstreamStreetCount < 0
        or sup.upstreamStreetCount % 1 ~= 0
        or type(sup.roadCount) ~= "number" or sup.roadCount < 1 or sup.roadCount % 1 ~= 0
        or type(sup.names) ~= "table" then
        return false
    end
    for original, key in pairs(sup.names) do
        if type(original) ~= "string" or original == ""
            or type(key) ~= "string" or not key:match("^UI_[%w_.%-]+$") then
            return false
        end
    end
    return true
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

-- 作者自己的街道數：沒有 streets.xml＝0；有檔時用一次性 scratch 讀原生 raw 快取計數
-- （同下方顯示窗口的 scratch 用法，只讀不改）。讀不到回 nil＝狀態未知，補充道路不套。
local function upstreamStreetCount(dir)
    local rel = "media/maps/" .. dir .. "/streets.xml"
    if not fileExists(rel) then return 0 end
    local api
    local ok, count = pcall(function()
        api = UIWorldMap.new({}):getAPIv3():getStreetsAPI()
        api:addStreetData(rel)
        local data = api:getStreetDataByRelativeFileName(rel)
        return data and getStreets(data):size() or nil
    end)
    if api then pcall(function() api:clearStreetData() end) end
    return ok and count or nil
end

-- 已啟用、結構合法、且作者街道數仍等於 addon 綁定值的補充道路；否則 nil。
-- 作者一改 streets.xml（街道數不同）整份停用，改回作者資料。每目錄只判一次。
local supplementState = {}
Core.streetSupplement = function(dir)
    if type(dir) ~= "string" then return nil end
    local key = dir:lower()
    local state = supplementState[key]
    if state ~= nil then return state or nil end
    state = false
    local source = Core.streetSource(dir)
    local sup = source and source.supplement
    if sup ~= nil then
        if not validSupplement(sup, source.mapMod, dir) then
            logOnce("supplement-invalid:" .. key, "street supplement invalid for " .. dir .. "; ignored")
        else
            local count = upstreamStreetCount(dir)
            if count ~= sup.upstreamStreetCount then
                logOnce("supplement-pin:" .. key, "street supplement disabled for " .. dir
                    .. ": author street data changed (expected " .. sup.upstreamStreetCount
                    .. " streets, found " .. tostring(count) .. ")")
            elseif not fileExists(sup.file) then
                logOnce("supplement-file:" .. key, "street supplement file missing: " .. sup.file)
            else
                state = sup
            end
        end
    end
    supplementState[key] = state
    return state or nil
end

-- 顯示譯名不影響 raw 原名與道路型別辨識。
Core.streetDisplayName = function(original, dir)
    local source = Core.streetSource(dir)
    local key = source and source.names and source.names[original]
    if not key then
        local sup = Core.streetSupplement(dir)
        key = sup and sup.names[original] or nil
    end
    if not key and type(dir) == "string" and dir:lower() == "muldraugh, ky" then
        return translateStreetName(original, "UI_WorldMapStreet_" .. original, getTextOrNull)
    end
    return translateStreetName(original, key, currentTranslation)
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
    street:setUntranslatedText(change.translated)
    if street:getUntranslatedText() == "" and change.translated ~= "" then
        rejectedText[change.translated] = true
        street:setUntranslatedText(change.original)
    end
    change.translated = street:getUntranslatedText()
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
            if change.street:getUntranslatedText() == change.translated then
                change.street:setUntranslatedText(change.original)
            end
            change.street:clipToObscuredCells()
        end)
        if not ok then logOnce("restore", "street data restore failed: " .. tostring(err)) end
    end
end

local function suspendWindow(parent, suspended)
    for i = #parent, 1, -1 do
        local old = parent[i]
        local current = old.street:getUntranslatedText()
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

local function streetPoints(street)
    local pts = {}
    for i = 0, street:getNumPoints() - 1 do
        pts[#pts + 1] = street:getPointX(i)
        pts[#pts + 1] = street:getPointY(i)
    end
    return pts
end

-- 已知翻譯載體（主檔 Core.carrierStreets：統一漢化 B42Trans_CN 的 Riverside, KY/streets.xml）整包
-- 帶上一版官方街道。導航由 patch.legacy 在整包認證後升級；顯示端在副本建立窗口把完整指紋等於
-- 上一版官方的街暫換成現行幾何（加入玩家地圖時同步 combine 成顯示副本，隨後還原 raw，導航照舊
-- 讀 raw 自行升級），小地圖與世界地圖、目錄 loader 與兜底載入都走這裡。只認已知載體＋其 MOD
-- 啟用中：真正的地圖 MOD 自帶的舊版副本不動（它的路可能本來就該照舊線）。
local function activeCarrierFile(file)
    local list = Core.carrierStreets
    if type(list) ~= "table" or type(file) ~= "string" then return false end
    local low = file:lower()
    for _, carrier in ipairs(list) do
        if type(carrier.file) == "string" and carrier.file:lower() == low then
            local mods = getActivatedMods()
            for i = 0, mods:size() - 1 do
                if mods:get(i) == carrier.mod then return true end
            end
            return false
        end
    end
    return false
end

local legacyCounts
local function legacyGeometryChanges(data, changes)
    local patch, nav = MinidoracatMiniMapRoadPatches, Core.NavRouteCore
    local legacy = type(patch) == "table" and type(patch.legacy) == "table"
        and type(patch.geometrySet) == "table" and patch.legacy
    if not (legacy and nav) then return 0 end
    if not legacyCounts then
        legacyCounts = {}
        for key in pairs(legacy) do
            local count = type(key) == "string" and tonumber(key:match("^(%d+):"))
            if count then legacyCounts[count] = true end
        end
    end
    local streets, upgraded = getStreets(data), 0
    for i = 0, streets:size() - 1 do
        local street = streets:get(i)
        if legacyCounts[street:getNumPoints()] then -- 點數先篩，其餘街只花一次跨界呼叫
            local points, width = streetPoints(street), street:getWidth()
            local entry = legacy[nav.fingerprintKey({ pts = points, width = width }) or ""]
            if type(entry) == "table" and entry.width == width
                and patch.geometrySet[nav.fingerprintKey(entry) or ""] then
                local original = street:getUntranslatedText() or ""
                local change = {
                    street = street, original = original, translated = original,
                    replacement = entry.pts, originalPoints = points, width = width,
                }
                changes[#changes + 1] = change
                applyChange(change)
                upgraded = upgraded + 1
            end
        end
    end
    return upgraded
end

-- 補充道路的檔案不在 media/maps/<dir>/ 之下，引擎不會依地圖優先序裁切它
-- （WorldMapStreets.initObscuredCells 以檔案絕對路徑判定所屬地圖目錄）。外框涉及的
-- 300 格只要有一格被別的地圖勝出，就把路名退化成不產生副本的點（同 hideLabel 手法）；
-- 導航另由路網建置的 cell winner 以 src 裁切，不受這裡影響。
local function supplementVisible(street, dir, winner)
    if not winner then return true end
    local x0, y0 = street:getPointX(0), street:getPointY(0)
    local x1, y1 = x0, y0
    for i = 1, street:getNumPoints() - 1 do
        local x, y = street:getPointX(i), street:getPointY(i)
        if x < x0 then x0 = x elseif x > x1 then x1 = x end
        if y < y0 then y0 = y elseif y > y1 then y1 = y end
    end
    local low = dir:lower()
    for cy = math.floor(y0 / 300), math.floor(y1 / 300) do
        for cx = math.floor(x0 / 300), math.floor(x1 / 300) do
            local owner = winner(cx, cy)
            if owner and owner:lower() ~= low then return false end
        end
    end
    return true
end

-- addon 補充道路掛進玩家地圖：與作者 streets.xml 同一套顯示窗口（scratch 暫改 raw 譯名
-- → 目標地圖 addStreetData 建副本 → 還原），hover、搜尋、導航都讀同一個容器。
-- 檔案條數與 roadCount 不符＝生成物不一致，整份不掛（fail-closed）。
local function loadStreetSupplement(mapUI, directory, lang)
    local dir = type(directory) == "string" and directory:match("^media/maps/(.+)$") or nil
    local sup = dir and Core.streetSupplement(dir)
    if not sup then return end
    local targetAPI = mapUI.javaObject:getAPIv3():getStreetsAPI()
    if targetAPI:getStreetDataByRelativeFileName(sup.file) then return end
    local winner = mapUI._minidoracatStreetReferenceWinner
    if not winner and Core.makeStreetWinner then
        winner = Core.makeStreetWinner()
        mapUI._minidoracatStreetReferenceWinner = winner
    end
    local translate = lang == "CH" or lang == "CN" or lang == "JP"
    local changes, scratchAPI, hidden = {}, nil, 0
    local ok, err = pcall(function()
        scratchAPI = UIWorldMap.new({}):getAPIv3():getStreetsAPI()
        scratchAPI:addStreetData(sup.file)
        local data = scratchAPI:getStreetDataByRelativeFileName(sup.file)
        if not data then error("native street data unavailable") end
        local streets = getStreets(data)
        if streets:size() ~= sup.roadCount then
            error("expected " .. sup.roadCount .. " roads, file has " .. streets:size())
        end
        for i = 0, streets:size() - 1 do
            local street = streets:get(i)
            local original = street:getUntranslatedText() or ""
            local translated = translate
                and translateStreetName(original, sup.names[original], getTextOrNull) or original
            local replacement, originalPoints
            if not supplementVisible(street, dir, winner) then
                originalPoints = streetPoints(street)
                replacement = { originalPoints[1], originalPoints[2], originalPoints[1], originalPoints[2] }
                hidden = hidden + 1
            end
            if translated ~= original or replacement then
                local change = {
                    street = street, original = original, translated = translated,
                    replacement = replacement, originalPoints = originalPoints,
                    width = replacement and street:getWidth(),
                }
                changes[#changes + 1] = change
                applyChange(change)
            end
        end
        targetAPI:addStreetData(sup.file)
    end)
    restoreChanges(changes)
    if scratchAPI then pcall(function() scratchAPI:clearStreetData() end) end
    if ok then
        logOnce("supplement:" .. dir .. ":" .. lang, "street supplement loaded: " .. dir .. " ("
            .. sup.roadCount .. " roads, " .. lang
            .. (hidden > 0 and (", " .. hidden .. " labels under other maps") or "") .. ")")
    else
        logOnce("supplement-load:" .. dir, "street supplement skipped for " .. dir .. ": " .. tostring(err))
    end
end

function MapUtils.initDirectoryStreetData(mapUI, directory)
    local lang = Translator.getLanguage():name()
    local translate = lang == "CH" or lang == "CN" or lang == "JP"
    local changes, scratchAPI, window, parent, suspended = {}, nil, nil, nil, nil
    local prepared, prepareErr = pcall(function()
        local dir = type(directory) == "string" and directory:match("^media/maps/(.+)$") or nil
        local source = sourceForDirectory(dir)
        local carrier = dir and not source and activeCarrierFile(directory .. "/streets.xml")
        if not carrier and (not source or (not source.repairs and not (translate and source.names))) then return end
        local names = source and source.names
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
        if carrier then
            local upgraded = legacyGeometryChanges(data, changes)
            logOnce("carrier-display:" .. dir, "street carrier display: " .. dir .. " upgraded "
                .. upgraded .. " previous-official street geometries")
            return
        end
        for i = 0, streets:size() - 1 do
            local street = streets:get(i)
            local original = street:getUntranslatedText() or ""
            local repair = Core.streetRepair and Core.streetRepair(street, dir, i)
            local replacement = repair and repair.replacementPoints
            local translated = translate and translateStreetName(original, names and names[original], getTextOrNull) or original
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
    local okSupplement, supplementErr = pcall(loadStreetSupplement, mapUI, directory, lang)
    if not okSupplement then
        logOnce("supplement-error", "street supplement failed: " .. tostring(supplementErr))
    end
    return result
end

-- 已知載體的兜底載入（主檔 ensureStreetData：地圖清單沒有載體目錄時直接 addStreetData）：
-- 同一個顯示窗口，副本建好後還原 raw。另一個窗口正改同一份 raw 時不疊加，照原樣載入。
Core.addCarrierStreetData = function(mapUI, file)
    local targetAPI = mapUI.mapAPI:getStreetsAPI()
    local changes, scratchAPI, upgraded = {}, nil, 0
    local prepared, prepareErr = pcall(function()
        scratchAPI = UIWorldMap.new({}):getAPIv3():getStreetsAPI()
        scratchAPI:addStreetData(file)
        local data = scratchAPI:getStreetDataByRelativeFileName(file)
        if not data then error("native street data unavailable") end
        if inFlight[data] then return end
        upgraded = legacyGeometryChanges(data, changes)
    end)
    if not prepared then
        restoreChanges(changes)
        logOnce("carrier-prepare", "street carrier display unavailable: " .. tostring(prepareErr))
    end
    local loaded, err = pcall(function() targetAPI:addStreetData(file) end)
    if prepared then restoreChanges(changes) end
    if scratchAPI then pcall(function() scratchAPI:clearStreetData() end) end
    if upgraded > 0 then
        logOnce("carrier-display:" .. file, "street carrier display: " .. file .. " upgraded "
            .. upgraded .. " previous-official street geometries")
    end
    if not loaded then error(err) end
end
print("[MinidoracatMiniMap] StreetData armed (names, independent repairs, supplements and carrier geometry)")
