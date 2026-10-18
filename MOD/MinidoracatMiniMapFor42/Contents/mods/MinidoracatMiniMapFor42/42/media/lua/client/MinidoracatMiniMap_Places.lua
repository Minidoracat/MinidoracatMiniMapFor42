-- MinidoracatMiniMap_Places.lua
-- 家與收藏點：每位本機玩家一份，存在玩家電腦的帳號檔（多人每個伺服器帳號一份、單機每個存檔
-- 一份，見 placesPath），角色死亡後新角色照樣讀得到。「家」是收藏中被標記的那一筆。回家＝
-- 把行程取代成單站並立即導航，只有會丟掉 2 個以上待前往站（或行程資料損壞）時才經既有確認面板。
-- 行程寫入仍只走 Core.navSetTarget／navPromptTarget；本檔不碰行程內部。
-- PZ API：cacheFileExists／getFileReader／getFileWriter（LuaManager.java:5544-5550、5936-5964、
-- 6727-6763）；getWorld():getGameMode()／getWorld()（IsoWorld.java:541、3208）；舊版搬移用
-- getModData／transmitModData（同 _Itinerary.lua）；ISTextBox（ISAnimalUI.lua:459-469 改名用例，
-- maxChars 由 ISTextBox.lua:178 擋 OK）；ISToolTip＋notAvailable（原版右鍵慣例）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.placesState then return end
local API = MinidoracatMiniMapAPI
local DATA_KEY = "MinidoracatMiniMapPlaces" -- 舊版存在角色 modData 的鍵：只剩搬移用（loadState）
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

-- 帳號檔（2026-10-14 設計稿 minimap-account-places-1014 作答：存在玩家電腦、只存家與收藏、
-- 單機每個存檔一份）：Zomboid/Lua/MinidoracatMiniMap/places/<模式>/<世界>_p<pn>.txt。
-- <模式>/<世界> 就是存檔資料夾 Saves/<模式>/<世界>（ZomboidFileSystem.getCurrentSaveDir）；MP 客戶端
-- 的世界名是 <IP>_<埠>_<帳號 MD5>（GameClient.doConnect，ConnectToServerState 經 createWorld 消毒），
-- 所以多人每個伺服器帳號一份，同原版私人地圖標記 map_symbols.bin；死亡重生的新角色讀同一檔。
-- getFileReader／getFileWriter 把 \ 也當分隔、路徑含 ".." 就回 nil（LuaManager.java:5937-5942、
-- 6728-6731）：先轉 %，再轉 / \ 與 ".."，可逆＝不同存檔不會撞名。
local KEY_ESC = { ["%"] = "%25", ["/"] = "%2f", ["\\"] = "%5c" }
local function fileKey(s)
    return (tostring(s):gsub("[%%/\\]", KEY_ESC):gsub("%.%.", ".%%2e"))
end
local function placesPath(pn)
    local world = getWorld()
    return "MinidoracatMiniMap/places/" .. fileKey(world:getGameMode()) .. "/"
        .. fileKey(world:getWorld()) .. string.format("_p%d.txt", pn)
end

-- 檔案格式（UTF-8，tab 分欄）：第一行 MMPLACES、版本、nextId、家的 id（無家留空）；每筆一行
-- id、x、y、名稱（名稱的 % tab CR LF 寫成 %25 %09 %0d %0a）；最後一行 END 與筆數。讀回交給
-- validate()：缺 END 或筆數不符（寫到一半）＝壞資料；版本較新只看第一行＝unsupported。
-- gsub 查表用整段比對、不用 capture：Kahlua 查不到時換成 capture 而不是原字串（StringLib.java:1434-1451）。
-- table.concat 一律給範圍（Kahlua # 不可信）。
local FILE_TAG = "MMPLACES"
local LABEL_ESC = { ["%"] = "%25", ["\t"] = "%09", ["\r"] = "%0d", ["\n"] = "%0a" }
local LABEL_UNESC = { ["%25"] = "%", ["%09"] = "\t", ["%0d"] = "\r", ["%0a"] = "\n" }
local function encodeState(state)
    local n = state.count
    local lines = { FILE_TAG .. "\t" .. SCHEMA .. "\t" .. state.nextId .. "\t" .. (state.homeId or "") }
    for i = 1, n do
        local p = state.places[i]
        lines[i + 1] = p.id .. "\t" .. tostring(p.x) .. "\t" .. tostring(p.y) .. "\t"
            .. (p.label and p.label:gsub("[%%\t\r\n]", LABEL_ESC) or "")
    end
    lines[n + 2] = "END\t" .. n
    return table.concat(lines, "\n", 1, n + 2)
end
local function decodeLines(lines, n)
    local head = n > 0 and lines[1] or ""
    local schema = tonumber(head:match("^" .. FILE_TAG .. "\t(%d+)"))
    if not schema then return nil end
    if schema > SCHEMA then return { schemaVersion = schema } end
    local nextId, homeId = head:match("^" .. FILE_TAG .. "\t%d+\t([^\t]*)\t([^\t]*)$")
    if not nextId or n < 2 or lines[n] ~= "END\t" .. (n - 2) then return nil end
    local rows = {}
    for i = 2, n - 1 do
        local id, x, y, label = lines[i]:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if not id then return nil end
        -- 數字欄壞了留原字串，交給 validate() 判 invalid
        rows[i - 1] = { id = tonumber(id) or id, x = tonumber(x) or x, y = tonumber(y) or y,
            label = label ~= "" and label:gsub("%%%x%x", LABEL_UNESC) or nil }
    end
    return { schemaVersion = schema, nextId = tonumber(nextId) or nextId,
        homeId = homeId ~= "" and (tonumber(homeId) or homeId) or nil, places = rows }
end
-- 逐行讀回（getFileReader 對「不存在」與 IOException 都回 nil；readLine 剝行尾，同 POIExport
-- readBackMatches）；pcall 確保讀到一半拋錯也會 close
local function readLines(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local lines, n = {}, 0
    local ok = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            n = n + 1
            lines[n] = line
            line = reader:readLine()
        end
    end)
    reader:close()
    if ok then return lines, n end
    return nil
end
-- 讀回全等才算寫成：LuaFileWriter 走 PrintWriter，磁碟錯誤不拋例外（同 POIExport）
local function writeFile(path, text)
    local writer = getFileWriter(path, true, false)
    if not writer then return false end
    if not pcall(function() writer:write(text); writer:close() end) then
        pcall(function() writer:close() end)
    end
    local lines, n = readLines(path)
    return lines ~= nil and table.concat(lines, "\n", 1, n) == text
end
-- 回 state／nil（沒有檔）／nil, reason：invalid、unsupported，或 unreadable（檔在卻打不開：
-- 不能當成沒有檔，否則下一次寫入會蓋掉它；cacheFileExists 只看 File.exists）
local function readFile(path)
    if not cacheFileExists(path) then return nil end
    local lines, n = readLines(path)
    if not lines then return nil, "unreadable" end
    local value = decodeLines(lines, n)
    if not value then return nil, "invalid" end
    return validate(value)
end
local function readLegacy(player)
    local md = player:getModData()
    local data = type(md) == "table" and rawget(md, DATA_KEY) or nil
    if data == nil then return nil end
    return validate(data)
end
local function dropLegacy(slot)
    local md = slot.player:getModData()
    if type(md) ~= "table" or rawget(md, DATA_KEY) == nil then return end
    md[DATA_KEY] = nil
    -- MP 要讓伺服器那份角色資料也清掉，否則下次登入舊收藏又回來；OnCreatePlayer 時可能還沒有
    -- onlineID，下一個可送出的 tick 才傳（檔尾 OnTick）
    slot.syncDirty = isClient()
end
-- 帳號檔為準，角色上的舊鍵只剩待清；沒有帳號檔（或壞檔）才搬角色上的舊收藏，寫檔成功才清舊鍵
-- （失敗就保留，下一次寫入成功再清）。檔打不開或版本較新：只讀，舊鍵也不動。
local function loadState(slot)
    local path = placesPath(slot.pn)
    local state, reason = readFile(path)
    if reason == "unreadable" or reason == "unsupported" then return nil, reason end
    if not state then
        local legacy, why = readLegacy(slot.player)
        if not legacy then return nil, why or reason end
        state = legacy
        if not writeFile(path, encodeState(state)) then return state end
    end
    dropLegacy(slot)
    return state
end
-- 例外一律當 unreadable：寧可只讀，也不蓋掉讀不到的檔
local function reload(slot)
    local ok, state, reason = pcall(loadState, slot)
    if not ok then
        warn(slot.pn, "load", state)
        state, reason = nil, "unreadable"
    elseif reason then
        warn(slot.pn, "load", reason)
    end
    slot.error = reason
    slot.state = state or emptyState()
    slot.state.revision = serial()
end

-- 角色生命週期：同槽位換角色（死亡重生、換世界）就重讀；同一帳號／存檔讀到同一個帳號檔
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
    reload(slot)
    return slot
end
local function writable(pn)
    if not validPlayerNum(pn) then return nil, "badargs" end
    local slot = ensure(pn)
    if not slot or slot.player:isDead() then return nil, "noplayer" end
    if slot.error == "unreadable" then reload(slot) end
    if slot.error == "unreadable" then return nil, "failed" end
    if slot.error == "unsupported" then return nil, "unsupported" end
    return slot
end
-- 單筆原子變更：先在複本上改、寫檔並讀回成功才換上（失敗不套用、不留半套）
local function mutate(pn, change)
    local slot, reason = writable(pn)
    if not slot then return nil, reason end
    local draft = copyState(slot.state)
    local result, why = change(draft)
    if result == nil then return nil, why end
    draft.revision = serial()
    local ok, saved = pcall(function() return writeFile(placesPath(pn), encodeState(draft)) end)
    if not (ok and saved) then
        warn(pn, "save", ok and "read-back mismatch" or saved)
        return nil, "failed"
    end
    slot.state, slot.error = draft, nil
    dropLegacy(slot)
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
-- 這裡新增一筆無名收藏並設為家；已有的家留在收藏（同搜尋視窗「設為家」只換哪一筆是家、不刪地點：
-- 右鍵誤點不會弄丟舊家座標，2026-10-11 設計稿 minimap-rightclick-1011 作答）
local function setHomeAt(pn, x, y)
    if not coordinate(x) or not coordinate(y) then return false, "badargs" end
    local done, why = mutate(pn, function(state)
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
-- 游標下的那筆設為家（雙地圖右鍵；同搜尋視窗「設為家」：只換哪一筆是家，不新增地點）
local function menuSetHomeId(pn, id)
    local ok, reason = setHome(pn, id)
    report(pn, ok, reason, "UI_MinidoracatMiniMap_HomeSet")
end
local function menuAddPlace(pn, x, y) Core.placesPromptAdd(pn, x, y, nil) end

--------------------------------------------------------------------------------
-- 地圖標記：家＝house、其他收藏＝pin（框架 art/line 圖示，缺框架退原版地圖符號），
-- 名稱畫在圖示下方。形狀＋文字區分，不靠顏色。雙地圖經 Core.drawNavTargets 共用
--------------------------------------------------------------------------------
local HOUSE_SYM = "media/ui/LootableMaps/map_house.png"
local PIN_SYM = "media/ui/LootableMaps/map_star.png"
local labelCache = {}
local function iconTexture(key, fallback)
    local Skin = Core.Skin
    local tex = Skin and Skin.iconTexture and Skin.iconTexture(key)
    if tex then return tex end
    return Core.adotsTexture and Core.adotsTexture(fallback) or getTexture(fallback)
end
-- 名稱底框的位置（繪製與右鍵命中共用）：預設在圖示下方；靠左右邊夾回，碰到底改放上方
local function labelBox(inner, ux, uy, half, lw, lblH)
    local lx, ly = ux - lw / 2, uy + half + 2
    if lx < 2 then lx = 2 elseif lx > inner.width - lw - 2 then lx = inner.width - lw - 2 end
    if ly > inner.height - lblH - 2 then ly = uy - half - lblH - 2 end
    return lx, ly
end
-- 一個家／收藏標記（圖示＋下方名稱；地圖與設定視窗預覽共用）：(ux, uy)＝UI 中心，
-- text／textW＝名稱與未縮放字寬，lblH＝已乘倍率的字高
local function drawPlaceAt(inner, home, ux, uy, iconSize, text, textW, tz, lblH)
    local drawGlyph = Core.adotsDrawGlyph
    if not drawGlyph then return end
    local half = iconSize / 2
    local tex = home and iconTexture("house", HOUSE_SYM) or iconTexture("pin", PIN_SYM)
    if tex then
        if home then
            drawGlyph(inner, tex, ux - half, uy - half, iconSize, 1, 1, 1)
        else
            drawGlyph(inner, tex, ux - half, uy - half, iconSize, 1, 0.9, 0.55)
        end
    end
    local lw = textW * tz
    local lx, ly = labelBox(inner, ux, uy, half, lw, lblH)
    inner:drawRect(lx - 3, ly, lw + 6, lblH, 0.55, 0, 0, 0)
    Core.drawMapText(inner, text, lx, ly, 1, 1, 1, 0.95, UIFont.Small, tz)
end

local function drawPlaces(inner)
    -- 「顯示在」這張地圖的格（Places／WMPlaces）關＝這張地圖不畫；回家、收藏清單與右鍵選單照常（只是顯示開關）
    if not Core.layerOn("places", inner == ISWorldMap_instance and "world" or "mini") then return end
    local pn = inner.playerNum or 0
    local slot = ensure(pn)
    local state = slot and slot.state
    if not state or state.count == 0 then return end
    if not Core.adotsDrawGlyph then return end
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
    -- 圖示邊長＝「標記大小」滑條（預設 16），名稱跟「地圖文字大小」；兩者每幀讀值
    local iconSize = Core.markerIconSize()
    local half = iconSize / 2
    local tz = Core.mapTextZoom()
    local lblH = fontH * tz
    for i = 1, state.count do
        local p = state.places[i]
        local ux, uy = mapAPI:worldToUIX(p.x, p.y), mapAPI:worldToUIY(p.x, p.y)
        if ux >= half and uy >= half and ux <= w - half and uy <= h - half then
            local lbl = cache[i]
            drawPlaceAt(inner, p.id == state.homeId, ux, uy, iconSize, lbl.text, lbl.w, tz, lblH)
        end
    end
end

-- 游標下的收藏（雙地圖右鍵用，Core.mapMenuFill）：圖標至少算 HIT_MIN 見方（WCAG 2.5.8 最小目標；
-- 標記大小滑條最小 8px），名稱底框也算；重疊時取最後畫的那筆（最上層，同 _Zones.lua iconPointer）。
-- 只認 drawPlaces 畫得出來的：這張地圖的「顯示在」那格關、或圖示在邊界外都沒有目標
local HIT_MIN = 24
Core.placeAt = function(inner, wx, wy)
    if not Core.layerOn("places", inner == ISWorldMap_instance and "world" or "mini") then return nil end
    local pn = inner.playerNum or 0
    local slot = ensure(pn)
    local state, api = slot and slot.state, inner.mapAPI
    if not (state and api) then return nil end
    local cx, cy = api:worldToUIX(wx, wy), api:worldToUIY(wx, wy)
    local size = Core.markerIconSize()
    local half, hit = size / 2, math.max(size, HIT_MIN) / 2
    local fontH = getTextManager():getFontHeight(UIFont.Small)
    local tz = Core.mapTextZoom()
    local lblH = fontH * tz
    -- 名稱字寬沿用 drawPlaces 的快取；快取還沒跟上（剛改名、換字級）就只認圖標
    local cache = labelCache[pn]
    if cache and (cache.revision ~= state.revision or cache.fontH ~= fontH) then cache = nil end
    for i = state.count, 1, -1 do
        local p = state.places[i]
        local ux, uy = api:worldToUIX(p.x, p.y), api:worldToUIY(p.x, p.y)
        if ux >= half and uy >= half and ux <= inner.width - half and uy <= inner.height - half then
            if math.abs(cx - ux) <= hit and math.abs(cy - uy) <= hit then return p end
            local lbl = cache and cache[i]
            if lbl then
                local lw = lbl.w * tz
                local lx, ly = labelBox(inner, ux, uy, half, lw, lblH)
                if cx >= lx - 3 and cx <= lx + lw + 3 and cy >= ly and cy <= ly + lblH then return p end
            end
        end
    end
    return nil
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
Core.drawPlaceAt = drawPlaceAt -- 設定視窗效果預覽
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
-- 「收藏：名稱」父項（Core.mapMenuFill）：名稱太長就截短，完整名稱在地圖標籤與確認框
local MENU_NAME_MAX = 20
Core.placeMenuTitle = function(pn, place)
    local name = labelOf(pn, place)
    if #name > MENU_NAME_MAX then name = name:sub(1, MENU_NAME_MAX - 1) .. "..." end
    return getText("UI_MinidoracatMiniMap_PlaceMenuOf", name)
end
-- 雙地圖右鍵「收藏」子選單（Core.mapMenuFill 傳子選單；不能掛子選單時是第一層）：回家（依原版慣例
-- notAvailable＋說明：未設家優先說明設定方法，否則 navBlocked＝Core.navMenuBlocked 的導航被擋原因）、
-- 設為家、加入收藏。place＝游標下的收藏（Core.placeAt）時改成這一筆的設為家（已是家不列）／改名／
-- 從收藏移除，不列加入收藏（同搜尋視窗收藏列；2026-10-18 設計稿 minimap-places-remove-1018 作答）
Core.placesAddMenu = function(context, pn, worldX, worldY, navBlocked, place)
    local option = context:addOption(getText("UI_MinidoracatMiniMap_GoHome"), pn, menuGoHome)
    Core.navMenuLock(option, not homeOf(pn) and getText("UI_MinidoracatMiniMap_HomeNotSet") or navBlocked)
    if place then
        local home = homeOf(pn)
        if not home or home.id ~= place.id then
            context:addOption(getText("UI_MinidoracatMiniMap_SetHome"), pn, menuSetHomeId, place.id)
        end
        context:addOption(getText("UI_MinidoracatMiniMap_PlaceRename"), pn, Core.placesPromptRename, place.id)
        if Core.navPromptPlaceRemove then -- 確認框在 _Search.lua（同搜尋視窗）
            context:addOption(getText("UI_MinidoracatMiniMap_PlaceRemove"), pn, Core.navPromptPlaceRemove, place.id)
        end
        return
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
-- 只有清掉角色上的舊版收藏時要傳（dropLegacy）；收藏本身存在帳號檔，不經伺服器
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
