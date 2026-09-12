-- MinidoracatMiniMap_Itinerary.lua
-- 行程是唯一權威；導航投影、分享與車輛執行權都由它衍生。
-- PZ API：getSpecificPlayer/getNumActivePlayers（ISJoyPadListBox.lua）；
-- getModData/transmitModData（原 _Nav.lua）；isDriver/isStopped（ISVehicleMenu.lua）；
-- OnCreatePlayer（ISPlayerData.lua）、OnGameStart/OnTick（原 NavRoute）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.navLoadItinerary then return end
local API = MinidoracatMiniMapAPI
local DATA_KEY = "MinidoracatMiniMapItinerary"
local MAX_STOPS, MAX_COORD, MAX_INTEGER = 16, 1e9, 9007199254740991
local slots, warned = {}, {}
local sequence = 0 -- 同一 Lua 程序不重設，換世界亦不重用 token/revision。

local function validPlayerNum(pn)
    return type(pn) == "number" and pn == pn and pn >= 0 and pn <= 3 and pn % 1 == 0
end
local function integer(value)
    return type(value) == "number" and value == value and value >= 1
        and value < MAX_INTEGER and value % 1 == 0
end
local function coordinate(value)
    return type(value) == "number" and value == value and value >= -MAX_COORD and value <= MAX_COORD
end
local function labelValid(value)
    -- Kahlua String.len 是 UTF-16 units；標準 Lua 的非 ASCII 邊界另用真 Kahlua 驗證。
    return value == nil or (type(value) == "string" and #value <= 128)
end
local function serial()
    sequence = sequence + 1
    return sequence
end
local function newToken()
    return "trip:" .. tostring(serial())
end
local function warn(pn, kind, err)
    local key = kind .. tostring(pn)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatMiniMap] Itinerary " .. kind .. ": " .. tostring(err))
end
local function copyStop(stop)
    return { id = stop.id, x = stop.x, y = stop.y, label = stop.label, status = stop.status, pause = stop.pause }
end
local function copyTrip(trip, persisted)
    if not trip then return nil end
    local copy = {
        schemaVersion = 2, revision = trip.revision, stops = {},
        nextStopId = trip.nextStopId, currentStopId = trip.currentStopId,
        phase = trip.phase, reason = trip.reason, autoContinue = trip.autoContinue,
    }
    for i = 1, trip.count do copy.stops[i] = copyStop(trip.stops[i]) end
    if not persisted then copy.count, copy.activation = trip.count, trip.activation end
    return copy
end
local function firstPending(trip)
    for i = 1, trip.count do
        if trip.stops[i].status == "pending" then return i end
    end
    return nil
end
local function stopIndex(trip, id)
    for i = 1, trip.count do if trip.stops[i].id == id then return i end end
    return nil
end
local function active(trip)
    return trip and (trip.phase == "navigating" or trip.phase == "approach")
end
local function validateTrip(value)
    if type(value) ~= "table" then return nil, "invalid" end
    local schema = rawget(value, "schemaVersion")
    if schema ~= 1 and schema ~= 2 then return nil, "unsupported" end
    local automatic = false
    if schema == 2 then
        automatic = rawget(value, "autoContinue")
        if type(automatic) ~= "boolean" then return nil, "invalid" end
    end
    local stops, revision, nextId = rawget(value, "stops"), rawget(value, "revision"), rawget(value, "nextStopId")
    local phase, current = rawget(value, "phase"), rawget(value, "currentStopId")
    if type(stops) ~= "table" or not integer(revision) or not integer(nextId) then return nil, "invalid" end
    if phase ~= "draft" and phase ~= "navigating" and phase ~= "approach"
        and phase ~= "waiting" and phase ~= "paused" and phase ~= "completed" then return nil, "invalid" end
    local count = 0
    for key in pairs(stops) do
        if not integer(key) or key > MAX_STOPS then return nil, "invalid" end
        count = count + 1
    end
    if count == 0 or count > MAX_STOPS then return nil, "invalid" end
    local out, seen, pending = {}, {}, nil
    for i = 1, count do
        local row = rawget(stops, i)
        if type(row) ~= "table" then return nil, "invalid" end
        local id, x, y = rawget(row, "id"), rawget(row, "x"), rawget(row, "y")
        local label, status = rawget(row, "label"), rawget(row, "status")
        if not integer(id) or seen[id] or id >= nextId or not coordinate(x)
            or not coordinate(y) or not labelValid(label) then return nil, "invalid" end
        local stopPause = false
        if schema == 2 then
            stopPause = rawget(row, "pause")
            if type(stopPause) ~= "boolean" then return nil, "invalid" end
        end
        if status == "pending" then
            if not pending then pending = i end
        elseif (status ~= "arrived" and status ~= "skipped") or pending then
            return nil, "invalid"
        end
        seen[id] = true
        out[i] = { id = id, x = x, y = y, label = label, status = status, pause = stopPause }
    end
    if phase == "draft" then
        if current ~= nil or not pending then return nil, "invalid" end
    elseif phase == "completed" then
        if current ~= nil or pending then return nil, "invalid" end
    elseif phase == "waiting" then
        if not pending or pending == 1 or current ~= out[pending - 1].id then return nil, "invalid" end
    elseif not pending or current ~= out[pending].id then
        return nil, "invalid"
    end
    local reason = rawget(value, "reason")
    if reason ~= nil and reason ~= "manual" and reason ~= "cancelled" and reason ~= "unavailable"
        and reason ~= "noroad" and reason ~= "failed" then return nil, "invalid" end
    return { schemaVersion = 2, revision = revision, nextStopId = nextId, count = count,
        stops = out, currentStopId = current, phase = phase, reason = reason, autoContinue = automatic }
end
local function writeData(player, payload)
    local md = player:getModData()
    if type(md) ~= "table" then error("player modData unavailable") end
    md[DATA_KEY] = payload
    md.MinidoracatMiniMapTX, md.MinidoracatMiniMapTY = nil, nil
end
local function save(slot, trip)
    if getSpecificPlayer(slot.pn) ~= slot.player then return false, "noplayer" end
    local ok, err = pcall(writeData, slot.player, copyTrip(trip, true))
    if not ok then
        warn(slot.pn, "save", err)
        return false, "failed"
    end
    -- MP OnCreatePlayer/OnGameStart 尚未取得 onlineID；首個可送出的 tick 才傳回。
    slot.syncDirty = isClient()
    return true
end
local function target(slot)
    if slot and active(slot.trip) then return slot.current end
    return nil
end
local function updateCurrent(slot)
    local trip = slot.trip
    local index = trip and trip.currentStopId and stopIndex(trip, trip.currentStopId)
    slot.current = index and trip.stops[index] or nil
end
local function notify(slot, oldId, oldX, oldY)
    local current = target(slot)
    local x, y = current and current.x, current and current.y
    if oldId ~= (current and current.id) or oldX ~= x or oldY ~= y then
        if Core.navInvalidateRoute then Core.navInvalidateRoute(slot.pn) end
        if Core.navTargetChanged then
            local ok, err = pcall(Core.navTargetChanged, slot.pn, slot.player)
            if not ok then warn(slot.pn, "share", err) end
        end
    end
end
local function publish(slot, trip, token, claim, receipt)
    if trip and not token then trip.activation = nil end
    local before = target(slot)
    local oldId, oldX, oldY = before and before.id, before and before.x, before and before.y
    slot.trip, slot.token, slot.claim = trip, token, claim
    slot.receipt = receipt or slot.receipt
    slot.version = trip and trip.revision or serial()
    slot.undo, slot.undoVersion, slot.error = nil, nil, nil
    updateCurrent(slot)
    notify(slot, oldId, oldX, oldY)
end
local function commit(slot, trip, token, claim, receipt)
    if trip then trip.revision = serial() end
    local ok, reason = save(slot, trip)
    if not ok then return false, reason end
    publish(slot, trip, token, claim, receipt)
    return true, "ok"
end
local function pause(slot, reason)
    if not active(slot.trip) then return true, "ok" end
    local trip = copyTrip(slot.trip)
    trip.phase, trip.reason, trip.revision = "paused", reason or "cancelled", serial()
    -- 終止權限先於持久化：存檔/傳送失敗也不得保留可繼續施力的 claim。
    publish(slot, trip, nil, nil)
    save(slot, trip)
    return true, "ok"
end
local function forget(pn)
    local slot = slots[pn]
    if slot then
        local before = target(slot)
        local id, x, y = before and before.id, before and before.x, before and before.y
        slot.trip, slot.current, slot.token, slot.claim, slot.receipt = nil, nil, nil, nil, nil
        notify(slot, id, x, y)
    end
    slots[pn] = nil
end
local function readData(player)
    local md = player:getModData()
    if type(md) ~= "table" then return nil, "invalid" end
    local data = rawget(md, DATA_KEY)
    if data ~= nil then return validateTrip(data) end
    local x, y = rawget(md, "MinidoracatMiniMapTX"), rawget(md, "MinidoracatMiniMapTY")
    if x == nil and y == nil then return nil end
    if not coordinate(x) or not coordinate(y) then return nil, "invalid" end
    return { schemaVersion = 2, revision = 1, count = 1, nextStopId = 2,
        phase = "paused", currentStopId = 1, autoContinue = false,
        stops = { { id = 1, x = x, y = y, status = "pending", pause = false } } }
end
local function loadPlayer(pn)
    if not validPlayerNum(pn) then return false, "badargs" end
    local player = getSpecificPlayer(pn)
    local old = slots[pn]
    if old and old.player == player then return true end
    if old then forget(pn) end
    if not player then return false, "noplayer" end
    local slot = { pn = pn, player = player, version = serial() }
    slots[pn] = slot
    local ok, trip, reason = pcall(readData, player)
    if not ok then reason, trip = "invalid", nil end
    if reason then
        slot.error = reason
        warn(pn, "load", ok and reason or "modData read failed")
        return false, reason
    end
    if trip then
        -- 舊 revision 只驗格式，載回重新簽發；不能用外部數字推進 token 序號。
        if active(trip) then trip.phase, trip.reason = "paused", "manual" end
        trip.revision = serial()
        local saved, saveReason = save(slot, trip)
        publish(slot, trip, nil, nil)
        -- 回存暫時失敗不等於空行程；保留已驗證資料，後續編輯可重試保存。
        if not saved then return false, saveReason end
    end
    return true
end
local function writable(pn)
    if not validPlayerNum(pn) then return nil, "badargs" end
    loadPlayer(pn)
    local slot = slots[pn]
    if not slot or not slot.player or getSpecificPlayer(pn) ~= slot.player or slot.player:isDead() then
        return nil, "noplayer"
    end
    return slot
end
local function gate(slot, context)
    if type(Core.navGateAllows) ~= "function" then
        return false, "blocked", "UI_MinidoracatMiniMap_NavBlocked"
    end
    local version = slot.version
    local checked, enabled, detail = pcall(Core.navGateAllows, slot.pn, context)
    if not checked then warn(slot.pn, "gate", enabled) end
    -- Addon callbacks may edit or cancel the trip; their newer state wins.
    if slots[slot.pn] ~= slot or slot.version ~= version
        or getSpecificPlayer(slot.pn) ~= slot.player then return false, "stale" end
    if not checked then return false, "failed" end
    if not enabled then return false, "blocked", detail end
    return true
end
local function parked(slot)
    local vehicle = slot.player:getVehicle()
    if vehicle and not vehicle:isStopped() then return false, "notstopped" end
    return true
end
local function editAllowed(slot)
    if slot.claim then return false, "busy" end
    return parked(slot)
end
local function activateNext(trip, kind)
    local index = firstPending(trip)
    if not index then return nil end
    trip.phase, trip.currentStopId, trip.reason = "navigating", trip.stops[index].id, nil
    trip.activation = kind
    return newToken()
end

local function finishStop(trip, id, status)
    local index = stopIndex(trip, id)
    local stop = trip.stops[index]
    stop.status = status
    trip.reason, trip.activation = nil, nil
    if not firstPending(trip) then
        trip.phase, trip.currentStopId = "completed", nil
        return "completed"
    end
    trip.phase, trip.currentStopId = "waiting", id
    if status == "arrived" and trip.autoContinue and not stop.pause then return "continue" end
    return "stopover"
end
local function getItinerary(pn)
    if not validPlayerNum(pn) then return nil, "badargs" end
    local slot = slots[pn]
    if not slot or not slot.trip then return nil, "noitinerary" end
    local copy = copyTrip(slot.trip)
    copy.claimed = slot.claim ~= nil
    copy.canUndo = slot.undo ~= nil and slot.undoVersion == slot.version
    return copy
end
local function getLeg(pn)
    if not validPlayerNum(pn) then return nil, "badargs" end
    local slot = slots[pn]
    local trip = slot and slot.trip
    if not trip then return nil, "noitinerary" end
    local current = target(slot)
    if current then return slot.token, current.id, current.x, current.y, trip.phase, trip.revision end
    return nil, nil, nil, nil, trip.phase, trip.revision
end
local function getTarget(pn)
    if not validPlayerNum(pn) then return nil, "badargs" end
    local current = target(slots[pn])
    if not current then return nil, "notarget" end
    return current.x, current.y
end
local function start(pn, expectedRevision)
    if not integer(expectedRevision) then return nil, "badargs" end
    local slot, reason = writable(pn)
    if not slot then return nil, reason end
    local old = slot.trip
    if not old then return nil, "noitinerary" end
    if expectedRevision ~= old.revision then return nil, "stale" end
    if old.phase ~= "draft" and old.phase ~= "paused" and old.phase ~= "waiting" then return nil, "state" end
    local allowed, why = editAllowed(slot)
    if not allowed then return nil, why end
    local enabled, why, detail = gate(slot, "set")
    if not enabled then return nil, why, detail end
    local trip = copyTrip(old)
    local token = activateNext(trip, "start")
    if not token then return nil, "state" end
    local ok, err = commit(slot, trip, token, nil)
    if not ok then return nil, err end
    if Core.navKickAvailable then Core.navKickAvailable(pn) end
    return token, "ok"
end
local function claim(pn, owner, expectedToken)
    if type(owner) ~= "string" or owner == "" or type(expectedToken) ~= "string" or expectedToken == "" then
        return nil, "badargs"
    end
    local slot, reason = writable(pn)
    if not slot then return nil, reason end
    if not slot.trip then return nil, "noitinerary" end
    if expectedToken ~= slot.token then return nil, "stale" end
    if slot.trip.phase ~= "navigating" then return nil, "state" end
    if slot.claim then
        if slot.claim.owner == owner then
            local vehicle = slot.player:getVehicle()
            if vehicle ~= slot.claim.vehicle or not vehicle:isDriver(slot.player) then return nil, "notdriver" end
            return slot.token, "ok"
        end
        return nil, "busy"
    end
    local vehicle = slot.player:getVehicle()
    if not vehicle or not vehicle:isDriver(slot.player) then return nil, "notdriver" end
    if not vehicle:isStopped() then return nil, "notstopped" end
    local allowed, why, detail = gate(slot, "draw")
    if not allowed then return nil, why, detail end
    local token = newToken()
    slot.token, slot.claim = token, { owner = owner, vehicle = vehicle }
    slot.trip.revision = serial()
    slot.version = slot.trip.revision
    slot.undo, slot.undoVersion = nil, nil
    return token, "ok"
end
local function owned(pn, owner, token, operation, reason, needsPlayer)
    if not validPlayerNum(pn) or type(owner) ~= "string" or owner == ""
        or type(token) ~= "string" or token == "" then return nil, "badargs" end
    local slot = slots[pn]
    if not slot then return nil, "stale" end
    local player = getSpecificPlayer(pn)
    if player and player ~= slot.player then
        loadPlayer(pn)
        return nil, "stale"
    end
    local receipt = slot.receipt
    if receipt and receipt.owner == owner and receipt.token == token
        and receipt.operation == operation and receipt.reason == reason then return nil, "duplicate" end
    if needsPlayer and (not player or player:isDead()) then return nil, "noplayer" end
    if token ~= slot.token then return nil, "stale" end
    if not slot.trip or slot.trip.phase ~= "navigating" then return nil, "state" end
    if not slot.claim or slot.claim.owner ~= owner then return nil, "busy" end
    return slot
end
local function report(pn, owner, token)
    local slot, reason = owned(pn, owner, token, "report", nil, true)
    if not slot then return reason == "duplicate", reason end
    local vehicle = slot.claim.vehicle
    if slot.player:getVehicle() ~= vehicle or not vehicle:isDriver(slot.player) then return false, "notdriver" end
    if not vehicle:isStopped() then return false, "notstopped" end
    local trip = copyTrip(slot.trip)
    local current = slot.current
    local dx, dy = vehicle:getX() - current.x, vehicle:getY() - current.y
    local outcome, nextToken, disposition
    if dx * dx + dy * dy <= 25 then
        disposition = finishStop(trip, current.id, "arrived")
        outcome = "arrived"
    else
        trip.phase, trip.reason, trip.activation = "approach", nil, nil
        nextToken, outcome, disposition = newToken(), "road_end", "road_end"
    end
    local receipt = { owner = owner, token = token, operation = "report" }
    local ok, err = commit(slot, trip, nextToken, nil, receipt)
    if not ok then return false, err end
    return true, outcome, disposition, trip.revision
end
local function release(pn, owner, token, reason)
    if reason ~= "manual" and reason ~= "cancelled" and reason ~= "unavailable"
        and reason ~= "noroad" and reason ~= "failed" then return false, "badargs" end
    local slot, err = owned(pn, owner, token, "release", reason, false)
    if not slot then return err == "duplicate", err end
    local trip = copyTrip(slot.trip)
    trip.phase, trip.reason, trip.revision = "paused", reason, serial()
    publish(slot, trip, nil, nil, { owner = owner, token = token, operation = "release", reason = reason })
    if getSpecificPlayer(pn) == slot.player then save(slot, trip) end
    return true, "released"
end
local function edit(pn, expectedRevision, operation, a, b, c, d)
    if type(expectedRevision) ~= "number" or expectedRevision < 0 or expectedRevision % 1 ~= 0
        or expectedRevision >= MAX_INTEGER then return false, "badargs" end
    local slot, reason = writable(pn)
    if not slot then return false, reason end
    local old = slot.trip
    if expectedRevision ~= (old and old.revision or 0) then return false, "stale" end
    if slot.error and operation ~= "replace" and operation ~= "clear" then return false, slot.error end
    local trip = old and copyTrip(old) or {
        schemaVersion = 2, revision = 1, stops = {}, count = 0, nextStopId = 1,
        phase = "draft", autoContinue = true,
    }
    local touched, setGate, removed, restore = false, false, nil, false
    local priorityId, priorityKind
    if operation == "mode" then
        if not old then return false, "noitinerary" end
        if type(a) ~= "boolean" then return false, "badargs" end
        if trip.autoContinue == a then return true, "ok" end
        trip.autoContinue = a
    elseif operation == "pause" then
        if not old then return false, "noitinerary" end
        if not integer(a) or type(b) ~= "boolean" then return false, "badargs" end
        local index = stopIndex(trip, a)
        if not index then return false, "badargs" end
        if trip.stops[index].status ~= "pending" then return false, "state" end
        if trip.stops[index].pause == b then return true, "ok" end
        trip.stops[index].pause = b
    elseif operation == "append" or operation == "insert"
        or operation == "priority" or operation == "replace" then
        if not coordinate(a) or not coordinate(b) or not labelValid(c) then return false, "badargs" end
        if operation == "replace" then
            touched = old ~= nil
            trip.stops, trip.count, trip.currentStopId, trip.phase, trip.reason = {}, 0, nil, "draft", nil
            trip.autoContinue = true
        elseif trip.count >= MAX_STOPS then return false, "limit" end
        if trip.nextStopId >= MAX_INTEGER - 1 then return false, "limit" end
        local position = trip.count + 1
        if operation == "priority" then
            local first = firstPending(trip)
            position, touched = first or position, true
            priorityId, priorityKind = trip.nextStopId, first and "priority" or "start"
        elseif operation == "insert" and d ~= nil then
            if not integer(d) then return false, "badargs" end
            position = stopIndex(trip, d)
            if not position then return false, "badargs" end
            if trip.stops[position].status ~= "pending" then return false, "state" end
            touched = d == trip.currentStopId
        end
        for i = trip.count, position, -1 do trip.stops[i + 1] = trip.stops[i] end
        trip.stops[position] = {
            id = trip.nextStopId, x = a, y = b, label = c, status = "pending", pause = false,
        }
        trip.count, trip.nextStopId, setGate = trip.count + 1, trip.nextStopId + 1, true
    elseif operation == "move" or operation == "remove" or operation == "skip" then
        if not old or not integer(a) then return false, "badargs" end
        local index = stopIndex(trip, a)
        if not index then return false, "badargs" end
        touched = a == trip.currentStopId
        if operation == "move" then
            if b ~= -1 and b ~= 1 then return false, "badargs" end
            local other = index + b
            if other < 1 or other > trip.count or trip.stops[index].status ~= "pending"
                or trip.stops[other].status ~= "pending" then return false, "state" end
            if trip.stops[other].id == trip.currentStopId then touched = true end
            trip.stops[index], trip.stops[other] = trip.stops[other], trip.stops[index]
        elseif operation == "remove" then
            removed = copyTrip(old)
            for i = index, trip.count - 1 do trip.stops[i] = trip.stops[i + 1] end
            trip.stops[trip.count], trip.count = nil, trip.count - 1
        else
            if a ~= trip.currentStopId or trip.stops[index].status ~= "pending" then return false, "state" end
            finishStop(trip, a, "skipped")
        end
    elseif operation == "clear" then
        touched, trip = old ~= nil, nil
    elseif operation == "undo" then
        if not slot.undo or slot.undoVersion ~= slot.version then return false, "undo" end
        trip, setGate, restore = copyTrip(slot.undo), true, true
        if old and trip.currentStopId == old.currentStopId then
            trip.phase = old.phase
        elseif firstPending(trip) then
            trip.phase, trip.currentStopId = "draft", nil
            touched = old and old.currentStopId ~= nil
        end
    else
        return false, "badargs"
    end
    if touched then
        local allowed, why = editAllowed(slot)
        if not allowed then return false, why end
    end
    if setGate then
        local allowed, why, detail = gate(slot, "set")
        if not allowed then return false, why, detail end
    end
    if trip then
        if trip.count == 0 then trip = nil
        elseif priorityId then
            trip.phase, trip.currentStopId, trip.reason = "navigating", priorityId, nil
            trip.activation = priorityKind
        elseif not firstPending(trip) then trip.phase, trip.currentStopId, trip.reason = "completed", nil, nil
        elseif operation ~= "skip" and (touched or trip.phase == "completed") then
            trip.phase, trip.currentStopId, trip.reason = "draft", nil, nil
        end
        if trip and not active(trip) then trip.activation = nil end
    end
    local keep = trip and active(trip) and not touched
    local token = priorityId and newToken() or (keep and slot.token or nil)
    local ok, why = commit(slot, trip, token, keep and slot.claim or nil)
    if not ok then return false, why end
    if removed and not restore then slot.undo, slot.undoVersion = removed, slot.version end
    if priorityId and Core.navKickAvailable then Core.navKickAvailable(pn) end
    return true, "ok"
end
local function setTarget(pn, x, y, label)
    if not coordinate(x) or not coordinate(y) or not labelValid(label) then return false, "badargs" end
    local slot, reason = writable(pn)
    if not slot then return false, reason end
    local allowed, why = editAllowed(slot)
    if not allowed then return false, why end
    local enabled, why, detail = gate(slot, "set")
    if not enabled then return false, why, detail end
    local id = slot.trip and slot.trip.nextStopId or 1
    if id >= MAX_INTEGER - 1 then return false, "limit" end
    local trip = { schemaVersion = 2, revision = 1, count = 1, nextStopId = id + 1,
        phase = "navigating", currentStopId = id, autoContinue = true, activation = "start",
        stops = { { id = id, x = x, y = y, label = label, status = "pending", pause = false } } }
    local ok, err = commit(slot, trip, newToken(), nil)
    if ok and Core.navKickAvailable then Core.navKickAvailable(pn) end
    return ok, err
end
local function guide(pn, expectedRevision, mode)
    if mode ~= "approach" and mode ~= "navigating" then return false, "badargs" end
    local slot, reason = writable(pn)
    if not slot then return false, reason end
    local old = slot.trip
    if not old then return false, "noitinerary" end
    if expectedRevision ~= old.revision then return false, "stale" end
    if old.phase ~= "paused" and old.phase ~= "navigating" and old.phase ~= "approach" then return false, "state" end
    if old.phase == mode then return true, "ok" end
    local allowed, why = editAllowed(slot)
    if not allowed then return false, why end
    local enabled, why, detail = gate(slot, "set")
    if not enabled then return false, why, detail end
    local trip = copyTrip(old)
    trip.phase, trip.reason = mode, nil
    trip.activation = mode == "navigating" and "start" or nil
    local ok, err = commit(slot, trip, newToken(), nil)
    if ok and slot.trip == trip and mode == "navigating" then
        -- 同一目標的模式切換不會經 notify 清快取，切回道路須從目前位置重算。
        if old.phase == "approach" and Core.navInvalidateRoute then Core.navInvalidateRoute(pn) end
        if Core.navKickAvailable then Core.navKickAvailable(pn) end
    end
    return ok, err
end
local function tickSlot(pn)
    local slot = slots[pn]
    if not slot then return end
    local player = getSpecificPlayer(pn)
    if player ~= slot.player then
        if player then loadPlayer(pn) else forget(pn) end
        return
    end
    if slot.syncDirty and isClient() and player:getOnlineID() >= 0 then
        local sent, err = pcall(player.transmitModData, player)
        if sent then slot.syncDirty = false else warn(pn, "sync", err) end
    end
    if not active(slot.trip) then return end
    if player:isDead() then pause(slot, "unavailable"); return end
    local vehicle = player:getVehicle()
    if slot.claim then
        if vehicle ~= slot.claim.vehicle or not vehicle:isDriver(player) then pause(slot, "unavailable") end
        return
    end
    if vehicle and not vehicle:isStopped() then return end
    local current = slot.current
    local dx, dy = player:getX() - current.x, player:getY() - current.y
    if dx * dx + dy * dy <= 25 then
        local trip = copyTrip(slot.trip)
        local disposition = finishStop(trip, current.id, "arrived")
        local token
        if disposition == "continue" then
            local enabled, reason = gate(slot, "set")
            if reason == "stale" then return end
            if enabled then
                token = activateNext(trip, "continue")
            else
                trip.reason = "unavailable"
            end
        end
        local saved = commit(slot, trip, token, nil)
        if saved and token and Core.navKickAvailable then Core.navKickAvailable(pn) end
    end
end

Core.navLoadItinerary = loadPlayer
Core.navItineraryState = function(pn) return slots[pn] and slots[pn].trip end
Core.navItineraryError = function(pn) return slots[pn] and slots[pn].error end
Core.navCanUndo = function(pn)
    local slot = slots[pn]
    return slot ~= nil and slot.undo ~= nil and slot.undoVersion == slot.version
end
Core.navGetTarget = function(pn) return target(slots[pn]) end
Core.navEditItinerary = edit
Core.navSetTarget = setTarget
Core.navGuideItinerary = guide
Core.navClearTarget = function(pn)
    local slot = slots[pn]
    return edit(pn, slot and slot.trip and slot.trip.revision or 0, "clear")
end
Core.navPauseItinerary = function(pn, reason)
    if not validPlayerNum(pn) then return false, "badargs" end
    local slot = slots[pn]
    if not slot or not slot.trip then return false, "noitinerary" end
    return pause(slot, reason)
end
Core.navRouteResult = function(pn, state)
    local slot = slots[pn]
    if slot and slot.trip and slot.trip.phase == "navigating" and (state == "noroad" or state == "failed") then
        pause(slot, state)
    end
end
Core.navErrorText = function(reason, detailKey)
    if reason == "blocked" and type(detailKey) == "string" and detailKey ~= "" then return getText(detailKey) end
    return getText("UI_MinidoracatMiniMap_TripError_" .. (reason or "failed"))
end
API.getNavItinerary, API.getNavLeg = getItinerary, getLeg
API.startNavItinerary, API.claimNavLeg = start, claim
API.reportNavArrival, API.releaseNavLeg = report, release
API.getNavTarget = getTarget
API.setNavContinuation = function(pn, expectedRevision, enabled)
    return edit(pn, expectedRevision, "mode", enabled)
end
API.navApiVersion = 7

Events.OnCreatePlayer.Add(function(pn) loadPlayer(pn) end)
Events.OnGameStart.Add(function()
    for pn = 0, 3 do forget(pn) end
    for key in pairs(warned) do warned[key] = nil end
    for pn = 0, 3 do loadPlayer(pn) end
end)
Events.OnTick.Add(function()
    for pn = 0, 3 do
        if slots[pn] then
            local ok, err = pcall(tickSlot, pn)
            if not ok then
                local slot = slots[pn]
                if slot then pause(slot, "failed") end
                warn(pn, "tick", err)
            end
        end
    end
end)
