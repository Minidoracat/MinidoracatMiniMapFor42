-- 語系無關的 MOD 道路修正。僅套來源、原始點列及路寬完全符合的已核准資料。
-- 資料由 addon streetRepairs 提供；不在此猜測道路、不依街名/語言決定幾何。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end
local reported = {}
local function report(key, message)
    if reported[key] then return end
    reported[key] = true
    print("[MinidoracatMiniMap] street repair " .. message)
end

-- test:street-repairs:start
local function matchesStreet(street, width, points)
    if street:getWidth() ~= width or street:getNumPoints() * 2 ~= #points then return false end
    for i = 1, #points, 2 do
        local at = (i - 1) / 2
        if street:getPointX(at) ~= points[i] or street:getPointY(at) ~= points[i + 1] then return false end
    end
    return true
end

local function replaceStreetPoints(street, points)
    local n = #points / 2
    local old = street:getNumPoints()
    for i = old - 1, n, -1 do street:removePoint(i) end
    for i = 0, n - 1 do
        if i < old then street:setPoint(i, points[i * 2 + 1], points[i * 2 + 2])
        else street:addPoint(points[i * 2 + 1], points[i * 2 + 2]) end
    end
end

-- 不用 Kahlua frexp（其負數/小數實作不可靠）。二進位縮放檢查 24-bit significand；
-- 次正規數以最小 float32 單位驗證。先通過世界座標/finite 驗證才呼叫。
local function exactFloat32(value)
    value = math.abs(value)
    if value == 0 then return true end
    if value < 2 ^ -126 then
        local units = value / (2 ^ -149)
        return units == math.floor(units)
    end
    while value < 8388608 do value = value * 2 end
    while value >= 16777216 do value = value / 2 end
    return value == math.floor(value)
end

local function validOperation(op, validPoints, validWidth)
    if type(op) ~= "table" or not validWidth(op.expectedWidth) or not validPoints(op.expectedPoints) then return false end
    if op.replacementPoints ~= nil then
        if not validPoints(op.replacementPoints) or #op.replacementPoints > 766 then return false end
        for i = 1, #op.replacementPoints do
            if not exactFloat32(op.replacementPoints[i]) then return false end
        end
        local hasLength = false
        for i = 3, #op.replacementPoints, 2 do
            if op.replacementPoints[i] ~= op.replacementPoints[i - 2]
                or op.replacementPoints[i + 1] ~= op.replacementPoints[i - 1] then hasLength = true; break end
        end
        if not hasLength then return false end -- label mask 不能偽裝成刪除導航路段的 replacement。
    end
    if op.hideLabel ~= nil and type(op.hideLabel) ~= "boolean" then return false end
    if not op.replacementPoints and op.hideLabel ~= true then return false end
    if op.hideLabel then
        local ref = op.reference
        if type(ref) ~= "table" or type(ref.index) ~= "number" or ref.index < 0 or ref.index % 1 ~= 0
            or not validWidth(ref.width) or not validPoints(ref.points) then return false end
    end
    return true
end
-- test:street-repairs:end

Core.replaceStreetPoints = replaceStreetPoints
Core.matchesStreetRepair = matchesStreet

Core.streetRepair = function(street, dir, at)
    local source = Core.streetSource and Core.streetSource(dir)
    local repairs = source and source.repairs
    if not repairs then return nil end
    if repairs.schemaVersion ~= 1 or repairs.mapMod ~= source.mapMod
        or type(repairs.mapDir) ~= "string" or repairs.mapDir:lower() ~= dir:lower()
        or type(repairs.operations) ~= "table" then
        report(tostring(dir), "source mismatch for " .. tostring(dir) .. "; keeping raw streets")
        return nil
    end
    local op = repairs.operations[at]
    if op == nil then return nil end
    if not Core.validStreetPoints or not Core.validStreetWidth
        or not validOperation(op, Core.validStreetPoints, Core.validStreetWidth) then
        report("invalid:" .. dir, "invalid operation in " .. dir .. " (first index " .. at .. "); keeping raw street")
        return nil
    end
    if not matchesStreet(street, op.expectedWidth, op.expectedPoints) then
        report("drift:" .. dir, "upstream geometry changed in " .. dir .. " (first index " .. at .. "); mismatched repairs skipped")
        return nil
    end
    return op
end

-- 不預測之後是否會載入 canonical：只使用同一玩家 map 已存在的參照容器。
-- raw 存在不代表 split 可見；逐 bbox 的 300 格檢查是否被更高優先地圖遮蔽。
local function referenceVisible(points, dir, winner, preserveOwner)
    local x0, y0, x1, y1 = points[1], points[2], points[1], points[2]
    for i = 3, #points, 2 do
        x0, y0 = math.min(x0, points[i]), math.min(y0, points[i + 1])
        x1, y1 = math.max(x1, points[i]), math.max(y1, points[i + 1])
    end
    x0, y0 = math.floor(x0 / 300), math.floor(y0 / 300)
    x1, y1 = math.floor(x1 / 300), math.floor(y1 / 300)
    if (x1 - x0 + 1) * (y1 - y0 + 1) > 4096 then return false end
    for cy = y0, y1 do
        for cx = x0, x1 do
            local higher = winner(cx, cy, dir)
            if higher and higher ~= dir then return false end
            if preserveOwner and winner(cx, cy) == preserveOwner then return false end
        end
    end
    return true
end

local referenceDirs = { "Riverside, KY", "Muldraugh, KY" }
Core.canHideStreetLabel = function(op, mapUI, sourceDir, displayName)
    local ref = op.reference
    if not ref or op.replacementPoints or op.expectedWidth ~= ref.width
        or #op.expectedPoints ~= #ref.points then return false end
    for i = 1, #ref.points do
        if op.expectedPoints[i] ~= ref.points[i] then return false end
    end
    local winner = mapUI._minidoracatStreetReferenceWinner
    if not winner and Core.makeStreetWinner then
        winner = Core.makeStreetWinner()
        mapUI._minidoracatStreetReferenceWinner = winner
    end
    if not winner then return false end
    local api = mapUI.javaObject:getAPIv3():getStreetsAPI()
    for _, dir in ipairs(referenceDirs) do
        if dir ~= sourceDir then
            local data = api:getStreetDataByRelativeFileName("media/maps/" .. dir .. "/streets.xml")
            if data then
                local streets = getStreets(data)
                if ref.index < streets:size() then
                    local street = streets:get(ref.index)
                    local referenceName = street:getTranslatedText()
                    if matchesStreet(street, ref.width, ref.points)
                        and referenceName:find("%S")
                        and referenceVisible(ref.points, dir, winner,
                            referenceName ~= displayName and sourceDir or nil) then return true end
                end
            end
        end
    end
    return false
end
