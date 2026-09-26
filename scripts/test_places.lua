-- 家／收藏點回歸：真 _Itinerary.lua＋真 _Places.lua 同環境載入，驗回家取代行程、
-- 確認門檻、自駕 claim、持久化、壞資料、分割畫面與角色切換、MP 傳回與右鍵選單。
-- 用法：lua scripts/test_places.lua [places.lua] [itinerary.lua]
local dir = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
local placesPath = arg[1] or (dir .. "MinidoracatMiniMap_Places.lua")
local itineraryPath = arg[2] or (dir .. "MinidoracatMiniMap_Itinerary.lua")
local function readFile(path)
    local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text
end
local sources = { readFile(itineraryPath), readFile(placesPath) }

local function fixture()
    local handlers, players, client = {}, {}, false
    local events = {}
    for _, name in ipairs({ "OnCreatePlayer", "OnGameStart", "OnTick" }) do
        handlers[name] = {}
        events[name] = { Add = function(fn) handlers[name][#handlers[name] + 1] = fn end }
    end
    local log = { messages = {}, prompts = {}, dialogs = {} }
    local core = { ready = true, navGateAllows = function() return true end }
    core.navMessage = function(pn, text, good) log.messages[#log.messages + 1] = { pn = pn, text = text, good = good } end
    core.navPromptTarget = function(pn, x, y, label, op)
        log.prompts[#log.prompts + 1] = { pn = pn, x = x, y = y, label = label, op = op }
    end
    local api = {}
    local function tooltip()
        local t = {}
        function t:initialise() end
        function t:setVisible() end
        return t
    end
    local TextBox = {}
    function TextBox:new(_, _, _, _, title, default, target, onclick, pn)
        local box = { title = title, default = default, target = target, onclick = onclick, pn = pn }
        function box:initialise() end
        function box:addToUIManager() log.dialogs[#log.dialogs + 1] = self end
        function box:press(internal, text)
            self.onclick(self.target, { internal = internal, parent = { entry = { getText = function() return text end } } })
        end
        return box
    end
    local env = setmetatable({ MinidoracatMiniMapCore = core, MinidoracatMiniMapAPI = api,
        Events = events, getSpecificPlayer = function(pn) return players[pn] end,
        isClient = function() return client end, getText = function(key) return key end,
        ISTextBox = TextBox, ISToolTip = { new = function() return tooltip() end },
        getJoypadData = function() return nil end,
        HaloTextHelper = { addGoodText = function() end, addBadText = function() end },
    }, { __index = _G })
    for i, source in ipairs(sources) do
        local chunk
        if setfenv then chunk = assert(loadstring(source)); setfenv(chunk, env)
        else chunk = assert(load(source, "module" .. i, "t", env)) end
        chunk()
    end
    local function player(pn, md)
        local p = { pn = pn, x = 0, y = 0, md = md or {}, sync = 0, online = -1 }
        function p:getModData() return self.md end
        function p:getVehicle() return self.vehicle end
        function p:getX() return self.x end
        function p:getY() return self.y end
        function p:isDead() return self.dead == true end
        function p:getOnlineID() return self.online end
        function p:transmitModData() self.sync = self.sync + 1 end
        players[pn] = p
        core.navLoadItinerary(pn)
        return p
    end
    return { core = core, api = api, player = player, players = players, log = log,
        client = function(v) client = v end,
        fire = function(event, ...) for _, fn in ipairs(handlers[event]) do fn(...) end end }
end
local function vehicle(p)
    local v = { stopped = true, driver = p, x = p.x, y = p.y }
    function v:isStopped() return self.stopped end
    function v:isDriver(who) return self.driver == who end
    function v:getX() return self.x end
    function v:getY() return self.y end
    p.vehicle = v
    return v
end
local function eq(a, b, why) assert(a == b, why .. ": " .. tostring(a) .. " != " .. tostring(b)) end
local function lastMessage(t) local m = t.log.messages[#t.log.messages]; return m and m.text end
local function edit(t, op, a, b, c)
    local it = t.api.getNavItinerary(0)
    return t.core.navEditItinerary(0, it and it.revision or 0, op, a, b, c)
end
local function menu()
    local m = { options = {} }
    function m:addOption(name, target, fn, a, b)
        local o = { name = name, target = target, fn = fn, a = a, b = b }
        self.options[#self.options + 1] = o
        return o
    end
    function m:find(name) for _, o in ipairs(self.options) do if o.name == name then return o end end end
    return m
end

-- 未設家：API 回 nohome；UI 入口顯示設定方法（不是灰掉不說話）；右鍵「回家」不可用並附說明。
do
    local t = fixture(); t.player(0)
    local ok, why = t.api.goNavHome(0)
    eq(ok, false, "未設家不可回家"); eq(why, "nohome", "未設家原因")
    eq(t.core.placesGoHome(0), false, "UI 入口回報失敗")
    eq(lastMessage(t), "UI_MinidoracatMiniMap_HomeNotSet", "按下說明如何設定家")
    eq(select(2, t.api.getNavHome(0)), "nohome", "getNavHome 未設家")
    local m = menu(); t.core.placesAddMenu(m, 0, 10, 20)
    local go = assert(m:find("UI_MinidoracatMiniMap_GoHome"), "右鍵有回家")
    eq(go.notAvailable, true, "未設家時右鍵回家不可用")
    eq(go.toolTip.description, "UI_MinidoracatMiniMap_HomeNotSet", "不可用項附說明")
    local set = assert(m:find("UI_MinidoracatMiniMap_SetHome"), "右鍵有設為家")
    set.fn(set.target, set.a, set.b)
    eq(lastMessage(t), "UI_MinidoracatMiniMap_HomeSet", "設為家回饋")
    local hx, hy, label = t.api.getNavHome(0)
    eq(hx, 10, "家 x"); eq(hy, 20, "家 y"); eq(label, "UI_MinidoracatMiniMap_PlaceHome", "無名家顯示「家」")
    m = menu(); t.core.placesAddMenu(m, 0, 30, 40)
    eq(m:find("UI_MinidoracatMiniMap_GoHome").notAvailable, nil, "設家後右鍵回家可用")
    -- 再設一次＝搬家，不累積第二筆
    assert(t.core.placesSetHomeAt(0, 50, 60))
    eq(t.core.placesState(0).count, 1, "搬家不新增收藏")
    eq((t.api.getNavHome(0)), 50, "家已搬到新座標")
end

-- 一鍵回家：沒有行程或只有一站時直接取代成單站並開始導航；站名為家的顯示名。
do
    local t = fixture(); t.player(0)
    assert(t.core.placesSetHomeAt(0, 100, 0))
    local ok, why = t.api.goNavHome(0)
    eq(ok, true, "無行程直接回家"); eq(why, "ok", "直接開始")
    local it = t.api.getNavItinerary(0)
    eq(it.count, 1, "單站"); eq(it.phase, "navigating", "立即導航")
    eq(it.stops[1].label, "UI_MinidoracatMiniMap_PlaceHome", "站名＝家")
    eq(#t.log.prompts, 0, "不跳確認")
    assert(t.core.navSetTarget(0, 300, 300, "Elsewhere"))
    ok, why = t.api.goNavHome(0)
    eq(why, "ok", "只有一個目的地時直接取代"); eq(#t.log.prompts, 0, "單站不確認")
    eq(t.api.getNavItinerary(0).stops[1].x, 100, "目的地換成家")
end

-- 會丟掉 2 個以上待前往站才確認；確認前行程不變。多站自駕中直接回 busy，不開沒用的確認窗。
do
    local t = fixture(); local p = t.player(0)
    assert(t.core.placesSetHomeAt(0, 100, 0))
    assert(edit(t, "append", 10, 0)); assert(edit(t, "append", 20, 0))
    local before = t.api.getNavItinerary(0).revision
    local ok, why = t.api.goNavHome(0)
    eq(ok, true, "多站時開確認"); eq(why, "prompted", "回報已開確認")
    eq(#t.log.prompts, 1, "確認窗一次"); eq(t.log.prompts[1].op, "replace", "確認後走既有取代")
    eq(t.log.prompts[1].x, 100, "確認的是家座標")
    eq(t.api.getNavItinerary(0).revision, before, "確認前行程不變")
    -- 已完成一站、只剩一站待前往：只丟 1 站，不確認
    local t2 = fixture(); t2.player(0)
    assert(t2.core.placesSetHomeAt(0, 100, 0))
    assert(edit(t2, "append", 0, 0)); assert(edit(t2, "append", 20, 0))
    assert(t2.api.startNavItinerary(0, t2.api.getNavItinerary(0).revision))
    assert(t2.api.setNavContinuation(0, t2.api.getNavItinerary(0).revision, false))
    t2.fire("OnTick")
    eq(t2.api.getNavItinerary(0).phase, "waiting", "第一站到達")
    ok, why = t2.api.goNavHome(0)
    eq(why, "ok", "只剩一站待前往時一鍵取代"); eq(#t2.log.prompts, 0, "不確認")
    -- 車還在動：確認後必定失敗，先擋
    local v = vehicle(p); v.stopped = false
    ok, why = t.api.goNavHome(0)
    eq(ok, false, "行駛中不開確認窗"); eq(why, "notstopped", "請先停車")
    v.stopped = true
    assert(t.api.claimNavLeg(0, "Auto", assert(t.api.startNavItinerary(0, t.api.getNavItinerary(0).revision))))
    ok, why = t.api.goNavHome(0)
    eq(ok, false, "多站自駕中不可回家"); eq(why, "busy", "先停止自駕")
    eq(#t.log.prompts, 1, "busy 不開確認窗")
end

-- 單站自駕中回家：沿用同一 claim／token，只換目的地（AutoDrive 不中斷）。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(t.core.placesSetHomeAt(0, 400, 0))
    assert(t.core.navSetTarget(0, 100, 0))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", t.api.getNavLeg(0)))
    v.stopped = false
    local ok, why = t.api.goNavHome(0)
    eq(ok, true, "單站自駕中可回家"); eq(why, "ok", "直接換目的地")
    local leg, _, lx = t.api.getNavLeg(0)
    eq(leg, claimed, "沿用 claim token"); eq(lx, 400, "目的地是家")
end

-- 已在家：不建立會立刻完成的行程；API 不顯示 MiniMap 訊息，UI 入口才顯示。
do
    local t = fixture(); local p = t.player(0)
    assert(t.core.placesSetHomeAt(0, 3, 4))
    local ok, why = t.api.goNavHome(0)
    eq(ok, false, "5 格內不回家"); eq(why, "athome", "已在家")
    eq(#t.log.messages, 0, "API 呼叫不顯示訊息")
    eq(t.api.getNavItinerary(0), nil, "沒有建立行程")
    t.core.placesGoHome(0)
    eq(lastMessage(t), "UI_MinidoracatMiniMap_AlreadyHome", "UI 顯示已在家")
    p.x = 9
    eq(select(2, t.api.goNavHome(0)), "ok", "超過 5 格才回家")
end

-- 收藏：新增／改名／移除／設為家；超過 16 筆可保存載回；移除家清掉家；長度與空白。
do
    local t = fixture(); local p = t.player(0)
    local a = assert(t.core.placesAdd(0, 1, 2, "  Base  "))
    local s = t.core.placesState(0)
    eq(s.places[1].label, "Base", "名稱去頭尾空白")
    local b = assert(t.core.placesAdd(0, 5, 6, "   "))
    eq(t.core.placeLabel(0, t.core.placesState(0).places[2]), "5, 6", "無名顯示座標")
    assert(t.core.placesRename(0, b, "Farm"))
    eq(t.core.placesState(0).places[2].label, "Farm", "改名")
    local ok, why = t.core.placesAdd(0, 1, 1, string.rep("x", 129))
    eq(ok, nil, "過長名稱拒收"); eq(why, "badargs", "過長原因")
    assert(t.core.placesSetHome(0, a))
    eq((t.api.getNavHome(0)), 1, "把既有收藏設為家")
    eq(select(3, t.api.getNavHome(0)), "Base", "有名稱的家顯示名稱")
    assert(t.core.placesSetHomeAt(0, 7, 8))
    eq(t.core.placesState(0).places[1].label, "Base", "搬家保留名稱")
    for i = 3, 64 do assert(t.core.placesAdd(0, i, i, "Place " .. i)) end
    local restored = fixture(); restored.player(0, p.md)
    local loaded = restored.core.placesState(0)
    eq(loaded.count, 64, "超過 16 筆完整載回")
    eq(loaded.homeId, a, "載回保留家")
    for i = 3, 64 do
        eq(loaded.places[i].x, i, "載回收藏座標")
        eq(loaded.places[i].label, "Place " .. i, "載回收藏名稱")
    end
    assert(restored.core.placesSetHome(0, loaded.places[64].id))
    eq((restored.api.getNavHome(0)), 64, "第 64 筆可設為家")
    assert(restored.api.goNavHome(0))
    eq(restored.api.getNavItinerary(0).stops[1].x, 64, "可導航到第 64 筆收藏")
    local rev = t.core.placesState(0).revision
    assert(t.core.placesRemove(0, a))
    assert(t.core.placesState(0).revision ~= rev, "變更換新 revision")
    eq(t.core.placesState(0).homeId, nil, "移除家即無家")
    eq(t.core.placesState(0).count, 63, "移除一筆")
    ok, why = t.core.placesRemove(0, a)
    eq(ok, false, "重複移除"); eq(why, "stale", "已不存在")
end

-- 持久化：寫入角色 modData，換 fixture 同份 modData 可完整載回；壞資料當空清單且可覆寫；
-- 較新 schema 拒絕寫入、原資料不動。
do
    local t = fixture(); local p = t.player(0)
    local id = assert(t.core.placesAdd(0, 11, 12, "Shop"))
    assert(t.core.placesSetHome(0, id))
    local saved = p.md.MinidoracatMiniMapPlaces
    eq(saved.schemaVersion, 1, "schema"); eq(saved.homeId, id, "存 homeId")
    local t2 = fixture(); t2.player(0, p.md)
    local x, y, label = t2.api.getNavHome(0)
    eq(x, 11, "載回 x"); eq(y, 12, "載回 y"); eq(label, "Shop", "載回名稱")
    local bad = { MinidoracatMiniMapPlaces = { schemaVersion = 1, nextId = 2, homeId = 9,
        places = { { id = 1, x = 0, y = 0 } } } }
    local t3 = fixture(); t3.player(0, bad)
    eq(t3.core.placesError(0), "invalid", "homeId 指向不存在者＝壞資料")
    eq(t3.core.placesState(0).count, 0, "壞資料當空清單")
    assert(t3.core.placesAdd(0, 1, 1, "New"))
    eq(t3.core.placesError(0), nil, "成功寫入後清錯誤")
    local future = { schemaVersion = 2, whatever = true }
    local t4 = fixture(); local p4 = t4.player(0, { MinidoracatMiniMapPlaces = future })
    eq(t4.core.placesError(0), "unsupported", "較新 schema")
    local ok, why = t4.core.placesSetHomeAt(0, 1, 1)
    eq(ok, false, "較新 schema 拒絕寫入"); eq(why, "unsupported", "原因")
    eq(p4.md.MinidoracatMiniMapPlaces, future, "原資料未被覆寫")
end

-- 分割畫面各自一份；同槽位換角色（死亡重生）不把前一位的收藏帶過去。
do
    local t = fixture(); t.player(0); t.player(1)
    assert(t.core.placesSetHomeAt(0, 10, 10))
    eq(select(2, t.api.getNavHome(1)), "nohome", "P2 沒有 P1 的家")
    assert(t.core.placesSetHomeAt(1, 20, 20))
    eq((t.api.getNavHome(0)), 10, "P1 的家不受影響")
    t.player(0, {})
    eq(select(2, t.api.getNavHome(0)), "nohome", "新角色不繼承舊角色的家")
    eq(select(2, t.api.goNavHome(4)), "badargs", "壞槽位")
end

-- MP：寫入後等取得 onlineID 的 tick 才傳回伺服器；單機不傳。
do
    local t = fixture(); local p = t.player(0)
    t.client(true)
    assert(t.core.placesAdd(0, 1, 1))
    t.fire("OnTick"); eq(p.sync, 0, "尚無 onlineID 不傳")
    p.online = 3
    t.fire("OnTick"); eq(p.sync, 1, "取得 onlineID 後傳一次")
    t.fire("OnTick"); eq(p.sync, 1, "沒有新變更不重傳")
    local t2 = fixture(); local p2 = t2.player(0); p2.online = 1
    assert(t2.core.placesAdd(0, 1, 1)); t2.fire("OnTick")
    eq(p2.sync, 0, "單機不傳")
end

-- 命名對話框：OK 才寫入；取消或換角色後才按 OK 都不寫。
do
    local t = fixture(); t.player(0)
    t.core.placesPromptAdd(0, 5, 5, "Default")
    local box = t.log.dialogs[1]
    eq(box.default, "Default", "預填名稱"); eq(box.pn, 0, "對話框屬於該玩家")
    box:press("CANCEL", "X")
    eq(t.core.placesState(0).count, 0, "取消不寫入")
    box:press("OK", "Named")
    eq(t.core.placesState(0).places[1].label, "Named", "OK 寫入")
    eq(lastMessage(t), "UI_MinidoracatMiniMap_PlaceAdded", "新增回饋")
    t.core.placesPromptRename(0, t.core.placesState(0).places[1].id)
    local rename = t.log.dialogs[2]
    eq(rename.default, "Named", "改名預填現名")
    rename:press("OK", "Renamed")
    eq(t.core.placesState(0).places[1].label, "Renamed", "改名寫入")
    t.core.placesPromptAdd(0, 9, 9, nil)
    local stale = t.log.dialogs[3]
    t.player(0, {})
    stale:press("OK", "Hijack")
    eq(t.core.placesState(0).count, 0, "換角色後舊對話框不寫入新角色")
end

print("test_places: ok")
