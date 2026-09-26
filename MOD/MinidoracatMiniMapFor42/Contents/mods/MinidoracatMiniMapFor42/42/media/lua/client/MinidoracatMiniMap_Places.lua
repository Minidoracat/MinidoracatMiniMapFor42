-- MinidoracatMiniMap_Places.lua
-- 家與收藏點：每位本機角色一份（角色 modData，MP 沿用 transmitModData 傳回），
-- 「家」是收藏中被標記的那一筆。回家＝把行程取代成單站並立即導航，只有會丟掉
-- 2 個以上待前往站（或行程資料損壞）時才經既有確認面板。
-- 行程寫入仍只走 Core.navSetTarget／navPromptTarget；本檔不碰行程內部。
-- PZ API：getModData/transmitModData（同 _Itinerary.lua）；ISTextBox（ISAnimalUI.lua:459-469
-- 改名用例，maxChars 由 ISTextBox.lua:178 擋 OK）；ISToolTip＋notAvailable（原版右鍵慣例）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.placesState then return end
local API = MinidoracatMiniMapAPI
local DATA_KEY = "MinidoracatMiniMapPlaces"
local SCHEMA, MAX_LABEL = 1, 128
local MAX_COORD, MAX_INTEGER = 1e9, 9007199254740991
local HOME_RADIUS2 = 25 -- 與行程到站判定同為 5 格
local slots, warned = {}, {}
local sequence = 0

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
-- nil／空白＝無名；回 (label|nil, ok)。長度以 Kahlua String.len（UTF-16 units）計
local function cleanLabel(label)
    if label == nil then return nil, true end
    if type(label) ~= "string" then return nil, false end
    label = label:match("^%s*(.-)%s*$")
    if label == "" then return nil, true end
    return label, #label <= MAX_LABEL
end
local function warn(pn, kind, err)
    local key = kind .. tostring(pn)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatMiniMap] Places " .. kind .. ": " .. tostring(err))
end
local function serial()
    sequence = sequence + 1
    return sequence
end
local function emptyState()
    return { revision = serial(), count = 0, nextId = 1, places = {} }
end
local function copyState(state)
    local out = { revision = state.revision, count = state.count, nextId = state.nextId,
        homeId = state.homeId, places = {} }
    for i = 1, state.count do
        local p = state.places[i]
        out.places[i] = { id = p.id, x = p.x, y = p.y, label = p.label }
    end
    return out
end
local function indexOf(state, id)
    for i = 1, state.count do if state.places[i].id == id then return i end end
    return nil
end

-- 載回整份驗證：任何一筆不合即整份拒收（不偷偷裁掉壞筆）。較新 schema 回 unsupported，
-- 之後拒絕寫入，避免降級時用舊格式覆蓋新資料。
local function validate(value)
    if type(value) ~= "table" then return nil, "invalid" end
    local schema = rawget(value, "schemaVersion")
    if type(schema) == "number" and schema > SCHEMA then return nil, "unsupported" end
    if schema ~= SCHEMA then return nil, "invalid" end
    local rows, nextId, homeId = rawget(value, "places"), rawget(value, "nextId"), rawget(value, "homeId")
    if type(rows) ~= "table" or not integer(nextId) then return nil, "invalid" end
    local count = 0
    for key in pairs(rows) do
        if not integer(key) then return nil, "invalid" end
        count = count + 1
    end
    local state = { count = count, nextId = nextId, places = {} }
    local seen = {}
    for i = 1, count do
        local row = rawget(rows, i)
        if type(row) ~= "table" then return nil, "invalid" end
        local id, x, y = rawget(row, "id"), rawget(row, "x"), rawget(row, "y")
        local label, ok = cleanLabel(rawget(row, "label"))
        if not integer(id) or seen[id] or id >= nextId or not coordinate(x) or not coordinate(y)
            or not ok then return nil, "invalid" end
        seen[id] = true
        state.places[i] = { id = id, x = x, y = y, label = label }
    end
    if homeId ~= nil and not seen[homeId] then return nil, "invalid" end
    state.homeId = homeId
    return state
end
local function payload(state)
    local rows = {}
    for i = 1, state.count do
        local p = state.places[i]
        rows[i] = { id = p.id, x = p.x, y = p.y, label = p.label }
    end
    return { schemaVersion = SCHEMA, nextId = state.nextId, homeId = state.homeId, places = rows }
end
local function writeData(player, value)
    local md = player:getModData()
    if type(md) ~= "table" then error("player modData unavailable") end
    md[DATA_KEY] = value
end
local function readData(player)
    local md = player:getModData()
    if type(md) ~= "table" then return nil, "invalid" end
    local data = rawget(md, DATA_KEY)
    if data == nil then return nil end
    return validate(data)
end

-- 角色生命週期：同槽位換角色（死亡重生、換世界）即重載，不把前一位的收藏帶給下一位
local function ensure(pn)
    if not validPlayerNum(pn) then return nil end
    local player = getSpecificPlayer(pn)
    local slot = slots[pn]
    if slot and slot.player == player then return slot end
    if not player then
        slots[pn] = nil
        return nil
    end
    slot = { pn = pn, player = player }
    slots[pn] = slot
    local ok, state, reason = pcall(readData, player)
    if not ok then state, reason = nil, "invalid" end
    if reason then warn(pn, "load", reason) end
    slot.error = reason
    slot.state = state or emptyState()
    slot.state.revision = serial()
    return slot
end
local function writable(pn)
    if not validPlayerNum(pn) then return nil, "badargs" end
    local slot = ensure(pn)
    if not slot or slot.player:isDead() then return nil, "noplayer" end
    if slot.error == "unsupported" then return nil, "unsupported" end
    return slot
end
-- 單筆原子變更：先在複本上改、存檔成功才換上（失敗不套用、不留半套）
local function mutate(pn, change)
    local slot, reason = writable(pn)
    if not slot then return nil, reason end
    local draft = copyState(slot.state)
    local result, why = change(draft)
    if result == nil then return nil, why end
    draft.revision = serial()
    local ok, err = pcall(writeData, slot.player, payload(draft))
    if not ok then
        warn(pn, "save", err)
        return nil, "failed"
    end
    slot.state, slot.error = draft, nil
    -- MP OnCreatePlayer 時可能尚無 onlineID；下一個可送出的 tick 才傳回伺服器
    slot.syncDirty = isClient()
    return result
end
local function append(state, x, y, label)
    local id = state.nextId
    state.count, state.nextId = state.count + 1, id + 1
    state.places[state.count] = { id = id, x = x, y = y, label = label }
    return id
end

local function homeOf(pn)
    local slot = ensure(pn)
    local state = slot and slot.state
    local index = state and state.homeId and indexOf(state, state.homeId)
    return index and state.places[index] or nil
end
local function labelOf(pn, place)
    if place.label then return place.label end
    local slot = slots[pn]
    if slot and slot.state.homeId == place.id then return getText("UI_MinidoracatMiniMap_PlaceHome") end
    return string.format("%d, %d", math.floor(place.x), math.floor(place.y))
end

local function addPlace(pn, x, y, label)
    if not coordinate(x) or not coordinate(y) then return nil, "badargs" end
    local clean, ok = cleanLabel(label)
    if not ok then return nil, "badargs" end
    return mutate(pn, function(state) return append(state, x, y, clean) end)
end
local function renamePlace(pn, id, label)
    local clean, ok = cleanLabel(label)
    if not ok or not integer(id) then return false, "badargs" end
    local done, why = mutate(pn, function(state)
        local index = indexOf(state, id)
        if not index then return nil, "stale" end
        state.places[index].label = clean
        return true
    end)
    return done == true, why
end
local function removePlace(pn, id)
    if not integer(id) then return false, "badargs" end
    local done, why = mutate(pn, function(state)
        local index = indexOf(state, id)
        if not index then return nil, "stale" end
        for i = index, state.count - 1 do state.places[i] = state.places[i + 1] end
        state.places[state.count], state.count = nil, state.count - 1
        if state.homeId == id then state.homeId = nil end
        return true
    end)
    return done == true, why
end
local function setHome(pn, id)
    if not integer(id) then return false, "badargs" end
    local done, why = mutate(pn, function(state)
        if not indexOf(state, id) then return nil, "stale" end
        state.homeId = id
        return true
    end)
    return done == true, why
end
-- 已有家＝搬家（保留名稱）；沒有家＝新增一筆無名收藏並設為家
local function setHomeAt(pn, x, y)
    if not coordinate(x) or not coordinate(y) then return false, "badargs" end
    local done, why = mutate(pn, function(state)
        local index = state.homeId and indexOf(state, state.homeId)
        if index then
            state.places[index].x, state.places[index].y = x, y
            return true
        end
        local id, reason = append(state, x, y, nil)
        if not id then return nil, reason end
        state.homeId = id
        return true
    end)
    return done == true, why
end

-- 回家（公開 API 與 UI 共用；本函式不顯示訊息）。回 (true,"ok")／(true,"prompted")／
-- (false, reason, detailKey)。確認窗之後才真正取代，所以先擋掉「確認後必定失敗」的情況。
local function goHome(pn)
    if not validPlayerNum(pn) then return false, "badargs" end
    local player = getSpecificPlayer(pn)
    if not player or player:isDead() then return false, "noplayer" end
    local home = homeOf(pn)
    if not home then return false, "nohome" end
    local dx, dy = player:getX() - home.x, player:getY() - home.y
    if dx * dx + dy * dy <= HOME_RADIUS2 then return false, "athome" end
    local label = labelOf(pn, home)
    local trip = Core.navItineraryState and Core.navItineraryState(pn)
    local pending = 0
    for i = 1, (trip and trip.count or 0) do
        if trip.stops[i].status == "pending" then pending = pending + 1 end
    end
    local broken = Core.navItineraryError and Core.navItineraryError(pn)
    if pending >= 2 or broken then
        local snapshot = API.getNavItinerary and API.getNavItinerary(pn)
        if type(snapshot) == "table" and snapshot.claimed then return false, "busy" end
        local vehicle = player:getVehicle()
        if vehicle and not vehicle:isStopped() then return false, "notstopped" end
        if not Core.navPromptTarget then return false, "failed" end
        Core.navPromptTarget(pn, home.x, home.y, label, "replace")
        return true, "prompted"
    end
    if not Core.navSetTarget then return false, "failed" end
    local ok, reason, detailKey = Core.navSetTarget(pn, home.x, home.y, label)
    if not ok then return false, reason, detailKey end
    return true, "ok"
end

local ERROR_KEYS = {
    nohome = "UI_MinidoracatMiniMap_HomeNotSet", athome = "UI_MinidoracatMiniMap_AlreadyHome",
    unsupported = "UI_MinidoracatMiniMap_PlaceError_unsupported",
}
local function errorText(reason, detailKey)
    local key = ERROR_KEYS[reason]
    if key then return getText(key) end
    if Core.navErrorText then return Core.navErrorText(reason, detailKey) end
    return getText("UI_MinidoracatMiniMap_TripError_failed")
end
-- 訊息走搜尋視窗的共用通道（開著寫訊息列，否則 halo）；缺席時直接 halo
local function notify(pn, text, good)
    if Core.navMessage then return Core.navMessage(pn, text, good) end
    local player = getSpecificPlayer(pn)
    if not player then return end
    if good then HaloTextHelper.addGoodText(player, text) else HaloTextHelper.addBadText(player, text) end
end
local function report(pn, ok, reason, okKey)
    if ok then
        if okKey then notify(pn, getText(okKey), true) end
    else
        notify(pn, errorText(reason), false)
    end
    return ok
end

-- 命名對話框（原版 ISTextBox；手把依原版慣例接焦點）。按下時角色已換＝不寫入新角色
local function promptName(pn, default, apply)
    local player = getSpecificPlayer(pn)
    if not player then return end
    local modal = ISTextBox:new(0, 0, 280, 180, getText("UI_MinidoracatMiniMap_PlaceNameTitle"),
        default or "", nil, function(_, button)
            if button.internal ~= "OK" or getSpecificPlayer(pn) ~= player then return end
            apply(button.parent.entry:getText())
        end, pn)
    modal:initialise()
    modal:addToUIManager()
    modal.maxChars = MAX_LABEL
    if getJoypadData(pn) then
        modal:centerOnScreen(pn)
        modal.prevFocus = getJoypadFocus(pn)
        setJoypadFocus(pn, modal)
    end
end

local function menuGoHome(pn) Core.placesGoHome(pn) end
local function menuSetHome(pn, x, y)
    local ok, reason = setHomeAt(pn, x, y)
    report(pn, ok, reason, "UI_MinidoracatMiniMap_HomeSet")
end
local function menuAddPlace(pn, x, y) Core.placesPromptAdd(pn, x, y, nil) end

--------------------------------------------------------------------------------
-- 地圖標記：家＝house、其他收藏＝pin（框架 art/line 圖示，缺框架退原版地圖符號），
-- 名稱畫在圖示下方。形狀＋文字區分，不靠顏色。雙地圖經 Core.drawNavTargets 共用
--------------------------------------------------------------------------------
local ICON_SIZE = 16
local HOUSE_SYM = "media/ui/LootableMaps/map_house.png"
local PIN_SYM = "media/ui/LootableMaps/map_star.png"
local labelCache = {}
local function iconTexture(key, fallback)
    local Skin = Core.Skin
    local tex = Skin and Skin.iconTexture and Skin.iconTexture(key)
    if tex then return tex end
    return Core.adotsTexture and Core.adotsTexture(fallback) or getTexture(fallback)
end
local function drawPlaces(inner)
    local pn = inner.playerNum or 0
    local slot = ensure(pn)
    local state = slot and slot.state
    if not state or state.count == 0 then return end
    local drawGlyph = Core.adotsDrawGlyph
    if not drawGlyph then return end
    local tm = getTextManager()
    local fontH = tm:getFontHeight(UIFont.Small)
    local cache = labelCache[pn]
    if not cache or cache.revision ~= state.revision or cache.fontH ~= fontH then
        cache = { revision = state.revision, fontH = fontH }
        for i = 1, state.count do
            local text = labelOf(pn, state.places[i])
            cache[i] = { text = text, w = tm:MeasureStringX(UIFont.Small, text) }
        end
        labelCache[pn] = cache
    end
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local half = ICON_SIZE / 2
    for i = 1, state.count do
        local p = state.places[i]
        local ux, uy = mapAPI:worldToUIX(p.x, p.y), mapAPI:worldToUIY(p.x, p.y)
        if ux >= half and uy >= half and ux <= w - half and uy <= h - half then
            local home = p.id == state.homeId
            local tex = home and iconTexture("house", HOUSE_SYM) or iconTexture("pin", PIN_SYM)
            if tex then
                if home then
                    drawGlyph(inner, tex, ux - half, uy - half, ICON_SIZE, 1, 1, 1)
                else
                    drawGlyph(inner, tex, ux - half, uy - half, ICON_SIZE, 1, 0.9, 0.55)
                end
            end
            local lbl = cache[i]
            local lx, ly = ux - lbl.w / 2, uy + half + 2
            if lx < 2 then lx = 2 elseif lx > w - lbl.w - 2 then lx = w - lbl.w - 2 end
            if ly > h - fontH - 2 then ly = uy - half - fontH - 2 end
            inner:drawRect(lx - 3, ly, lbl.w + 6, fontH, 0.55, 0, 0, 0)
            inner:drawText(lbl.text, lx, ly, 1, 1, 1, 0.95, UIFont.Small)
        end
    end
end

Core.placesState = function(pn)
    local slot = ensure(pn)
    return slot and slot.state or nil
end
Core.placesError = function(pn)
    local slot = ensure(pn)
    return slot and slot.error or nil
end
Core.placesHome = homeOf
Core.placeLabel = labelOf
Core.placesAdd = addPlace
Core.placesRename = renamePlace
Core.placesRemove = removePlace
Core.placesSetHome = setHome
Core.placesSetHomeAt = setHomeAt
Core.placesErrorText = errorText
Core.drawPlaces = drawPlaces
Core.placesGoHome = function(pn)
    local ok, reason, detailKey = goHome(pn)
    if not ok then notify(pn, errorText(reason, detailKey), false) end
    return ok
end
Core.placesPromptAdd = function(pn, x, y, defaultLabel)
    promptName(pn, defaultLabel, function(text)
        local id, reason = addPlace(pn, x, y, text)
        report(pn, id ~= nil, reason, "UI_MinidoracatMiniMap_PlaceAdded")
    end)
end
Core.placesPromptRename = function(pn, id)
    local slot = ensure(pn)
    local index = slot and indexOf(slot.state, id)
    if not index then
        report(pn, false, "stale")
        return
    end
    promptName(pn, slot.state.places[index].label, function(text)
        local ok, reason = renamePlace(pn, id, text)
        report(pn, ok, reason)
    end)
end
-- 雙地圖右鍵共用：回家（未設家時依原版慣例 notAvailable＋說明）、設為家、加入收藏
Core.placesAddMenu = function(context, pn, worldX, worldY)
    local option = context:addOption(getText("UI_MinidoracatMiniMap_GoHome"), pn, menuGoHome)
    if not homeOf(pn) then
        option.notAvailable = true
        local tip = ISToolTip:new()
        tip:initialise()
        tip:setVisible(false)
        tip.description = getText("UI_MinidoracatMiniMap_HomeNotSet")
        option.toolTip = tip
    end
    context:addOption(getText("UI_MinidoracatMiniMap_SetHome"), pn, menuSetHome, worldX, worldY)
    context:addOption(getText("UI_MinidoracatMiniMap_PlaceAdd"), pn, menuAddPlace, worldX, worldY)
end

API.getNavHome = function(pn)
    if not validPlayerNum(pn) then return nil, "badargs" end
    local player = getSpecificPlayer(pn)
    if not player then return nil, "noplayer" end
    local home = homeOf(pn)
    if not home then return nil, "nohome" end
    return home.x, home.y, labelOf(pn, home)
end
API.goNavHome = goHome

Events.OnGameStart.Add(function()
    for pn = 0, 3 do slots[pn], labelCache[pn] = nil, nil end
    for key in pairs(warned) do warned[key] = nil end
end)
Events.OnTick.Add(function()
    for pn = 0, 3 do
        local slot = slots[pn]
        if slot and slot.syncDirty and isClient() and getSpecificPlayer(pn) == slot.player
            and slot.player:getOnlineID() >= 0 then
            local sent, err = pcall(slot.player.transmitModData, slot.player)
            if sent then slot.syncDirty = false else warn(pn, "sync", err) end
        end
    end
end)
