-- 真行程模組的狀態／持久化／接管回歸；不複製行程演算法。
local modulePath = arg[1] or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Itinerary.lua"
local function readFile(path)
    local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text
end
local source = readFile(modulePath)
local function fixture()
    local handlers, players, gateAllowed, shared, client = {}, {}, true, 0, false
    local events = {}
    for _, name in ipairs({ "OnCreatePlayer", "OnGameStart", "OnTick" }) do
        handlers[name] = {}
        events[name] = { Add = function(fn) handlers[name][#handlers[name] + 1] = fn end }
    end
    local core = { ready = true,
        navGateAllows = function() return gateAllowed, "NeedGPS" end,
        navTargetChanged = function() shared = shared + 1 end,
    }
    local api = {}
    local env = setmetatable({ MinidoracatMiniMapCore = core, MinidoracatMiniMapAPI = api,
        Events = events, getSpecificPlayer = function(pn) return players[pn] end,
        isClient = function() return client end, getText = function(key) return key end,
    }, { __index = _G })
    local chunk
    if setfenv then chunk = assert(loadstring(source)); setfenv(chunk, env)
    else chunk = assert(load(source, modulePath, "t", env)) end
    chunk()
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
    return { core = core, api = api, player = player, players = players,
        gate = function(v) gateAllowed = v end, client = function(v) client = v end,
        shared = function() return shared end,
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
local function trip(t, pn) return t.api.getNavItinerary(pn or 0) end
local function edit(t, op, a, b, c, pn)
    pn = pn or 0
    local it = trip(t, pn)
    return t.core.navEditItinerary(pn, it and it.revision or 0, op, a, b, c)
end
local function start(t, pn)
    pn = pn or 0
    return t.api.startNavItinerary(pn, trip(t, pn).revision)
end
local function eq(a, b, why) assert(a == b, why .. ": " .. tostring(a) .. " != " .. tostring(b)) end
-- 新增站點需要第四個資料參數（insert 的錨點）時才走這個入口。
local function editAt(t, op, a, b, c, d, pn)
    pn = pn or 0
    local it = trip(t, pn)
    return t.core.navEditItinerary(pn, it and it.revision or 0, op, a, b, c, d)
end
-- 站級強制停留旗標；契約要求只能作用在 pending 站。
local function hold(t, stopId, value, pn)
    pn = pn or 0
    return t.core.navEditItinerary(pn, trip(t, pn).revision, "pause", stopId, value)
end
-- 全域自動續行開關；新行程預設開啟，舊案例要手動停等就明確關掉。
local function autoContinue(t, value, pn)
    pn = pn or 0
    return t.api.setNavContinuation(pn, trip(t, pn).revision, value)
end
local function pendingCount(it)
    local n = 0
    for i = 1, it.count do if it.stops[i].status == "pending" then n = n + 1 end end
    return n
end

-- 有序重訪與重疊站：一次 tick 只消耗目前站，draft/waiting 不因腳下有站就跳過。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 0, 0, "Home")); assert(edit(t, "append", 20, 0, "Fuel"))
    assert(edit(t, "append", 0, 0, "Home")); assert(edit(t, "append", 0, 0, "Home"))
    assert(autoContinue(t, false), "本案例明確要求逐站手動續行")
    t.fire("OnTick"); eq(trip(t).phase, "draft", "draft 不抵達")
    assert(start(t)); t.fire("OnTick")
    eq(trip(t).phase, "waiting", "第一站等待繼續")
    t.fire("OnTick"); eq(trip(t).stops[2].status, "pending", "不自動跳下一站")
    p.x = 20; assert(start(t)); t.fire("OnTick")
    p.x = 0; assert(start(t)); t.fire("OnTick")
    eq(trip(t).stops[4].status, "pending", "同座標仍是不同站")
    assert(start(t)); t.fire("OnTick"); eq(trip(t).phase, "completed", "明確逐站完成")
    assert(edit(t, "append", 40, 0)); eq(trip(t).phase, "draft", "完成後加站回草稿")
end

-- 車仍移動不完成；claim 有效時 MiniMap 不擅自完成，站與幾何 token 分離。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    local token = assert(start(t))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", token)); assert(claimed ~= token)
    assert(edit(t, "append", 300, 0)); eq(t.api.getNavLeg(0), claimed, "後續編輯不動token")
    p.x, v.x, v.stopped = 100, 100, false
    t.fire("OnTick"); eq(trip(t).phase, "navigating", "進距離圈仍不搶到站")
    local ok, why = t.api.reportNavArrival(0, "Auto", claimed)
    eq(ok, false, "移動中拒報"); eq(why, "notstopped", "停妥守衛")
    local before = trip(t)
    ok, why = edit(t, "move", before.currentStopId, 1)
    eq(ok, false, "移動目前站拒絕"); eq(why, "busy", "claim守衛")
    eq(trip(t).revision, before.revision, "拒绝不改revision")
    v.stopped = true; t.fire("OnTick")
    eq(trip(t).phase, "navigating", "有claim停妥也不自行完成")
    ok, why = t.api.reportNavArrival(0, "Auto", claimed)
    eq(ok, true, "真正停妥回報"); eq(why, "arrived", "本站到達")
    local doneRev, shares = trip(t).revision, t.shared()
    ok, why = t.api.reportNavArrival(0, "Auto", claimed)
    eq(why, "duplicate", "重送不重複完成"); eq(trip(t).revision, doneRev, "重送不存檔")
    eq(t.shared(), shares, "重送不分享")
    eq(t.api.getNavTarget(0), nil, "等待不提前暴露下一站")
    local second = assert(start(t))
    t.api.reportNavArrival(0, "Other", claimed)
    eq(t.api.getNavLeg(0), second, "舊或他人回報不污染新段")
    local newClaim = assert(t.api.claimNavLeg(0, "Auto", second))
    t.gate(false); p.vehicle = nil
    ok, why = t.api.releaseNavLeg(0, "Auto", newClaim, "unavailable")
    eq(ok, true, "下車與無設備仍可解除"); eq(trip(t).phase, "paused", "解除保留待辦")
    eq(trip(t).stops[2].status, "pending", "解除不是抵達")
end

-- 道路終點不是指定站；轉徒步 token，取消後不自行完成。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 30, 0)); local token = assert(start(t))
    token = assert(t.api.claimNavLeg(0, "Auto", token))
    local ok, why = t.api.reportNavArrival(0, "Auto", token)
    eq(why, "road_end", "距目的地30格只到道路末端")
    eq(trip(t).stops[1].status, "pending", "road_end保留pending")
    local walkToken = t.api.getNavLeg(0); assert(walkToken and walkToken ~= token)
    eq(select(2, t.api.claimNavLeg(0, "Auto", walkToken)), "state", "不可接管徒步段")
    t.core.navPauseItinerary(0, "cancelled"); p.x, v.x = 30, 30
    t.fire("OnTick"); eq(trip(t).phase, "paused", "取消後不完成")
    assert(t.core.navGuideItinerary(0, trip(t).revision, "approach")); t.fire("OnTick")
    eq(trip(t).phase, "completed", "手動抵達原座標才完成")
end

-- 編輯正規化、恢復、筆數與邊界拒絕皆保留合法行程。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 10, 0)); assert(edit(t, "append", 20, 0))
    assert(autoContinue(t, false), "本案例明確要求逐站手動續行")
    assert(start(t))
    local first = trip(t).currentStopId
    assert(edit(t, "remove", first)); eq(trip(t).phase, "draft", "刪目前站回draft")
    assert(edit(t, "undo")); eq(trip(t).phase, "draft", "復原不自動啟動")
    eq(trip(t).stops[1].id, first, "復原保留站點id")
    assert(start(t)); p.x = 10; t.fire("OnTick")
    assert(edit(t, "remove", trip(t).stops[2].id)); eq(trip(t).phase, "completed", "刪光待辦完成")
    assert(edit(t, "clear")); assert(edit(t, "append", 100, 100))
    for i = 2, 16 do assert(edit(t, "append", 100 + i, 100)) end
    local rev = trip(t).revision
    eq(edit(t, "append", 117, 100), false, "第17站拒绝")
    eq(trip(t).revision, rev, "超限不改資料")
    eq(edit(t, "append", 0/0, 100), false, "NaN拒絕")
    eq(edit(t, "replace", math.huge, 100), false, "Infinity拒絕")
    eq(t.core.navEditItinerary(0, rev - 1, "clear"), false, "過期編輯拒絕")
    local snapshot = trip(t); snapshot.stops[1].x = 999
    eq(trip(t).stops[1].x, 100, "快照不可改權威")
    assert(edit(t, "clear")); assert(edit(t, "append", 100, 0))
    assert(edit(t, "remove", trip(t).stops[1].id)); assert(t.core.navCanUndo(0))
    assert(edit(t, "undo")); eq(trip(t).count, 1, "最後一站亦可復原")
end

-- 同角色UI重建不重載；新世界/新角色不能復活token；MP只在online就緒後傳。
do
    local t = fixture(); t.client(true)
    local p = t.player(0, { MinidoracatMiniMapTX = 20, MinidoracatMiniMapTY = 40 })
    eq(trip(t).phase, "paused", "舊單點遷移為待確認")
    eq(trip(t).autoContinue, false, "舊單點遷移不自動續行")
    eq(trip(t).stops[1].pause, false, "舊單點遷移補齊站級旗標")
    eq(p.md.MinidoracatMiniMapTX, nil, "刪除舊權威")
    eq(p.md.MinidoracatMiniMapItinerary.count, nil, "衍生count不持久化")
    eq(p.sync, 0, "創建不發MP封包")
    local token = assert(start(t)); local rev = trip(t).revision
    t.core.navLoadItinerary(0); eq(t.api.getNavLeg(0), token, "UI重建不重置token")
    eq(trip(t).revision, rev, "UI重建不覆蓋進度")
    p.online = 42; t.fire("OnTick"); eq(p.sync, 1, "就緒後同步")
    t.fire("OnTick"); eq(p.sync, 1, "穩態不重傳")
    t.fire("OnGameStart"); eq(trip(t).phase, "paused", "重進存檔不自駕")
    assert(start(t) ~= token, "新世界不得重用token")
    local other = t.player(1); assert(edit(t, "append", 500, 600, nil, 1))
    local one = trip(t, 1).stops[1].x
    t.player(0); eq(trip(t), nil, "同槽新角色不繼承舊行程")
    eq(trip(t, 1).stops[1].x, one, "分屏互不干擾")
    local corrupt = { schemaVersion = 99 }
    p = t.player(0, { MinidoracatMiniMapItinerary = corrupt, MinidoracatMiniMapTX = 1, MinidoracatMiniMapTY = 2 })
    eq(trip(t), nil, "未知schema不退回舊目標"); eq(p.md.MinidoracatMiniMapItinerary, corrupt, "保留壞資料")
    eq(edit(t, "append", 3, 4), false, "不能append覆蓋壞資料")
    assert(edit(t, "clear")); eq(p.md.MinidoracatMiniMapItinerary, nil, "明確重建才清壞資料")
end

-- 不可信的持久化 revision 不得污染其他槽位；一次存取失敗可重試原編輯。
do
    local t = fixture()
    local p = t.player(0, { MinidoracatMiniMapItinerary = {
        schemaVersion = 1, revision = 9007199254740990, nextStopId = 2,
        phase = "draft", stops = { { id = 1, x = 100, y = 0, status = "pending" } },
    } })
    eq(trip(t).autoContinue, false, "v1持久資料遷移為手動續行")
    assert(start(t), "合法持久 revision 上界載入後仍可開始")
    t.player(1); assert(edit(t, "append", 200, 0, nil, 1))
    local a = assert(start(t, 1))
    t.core.navPauseItinerary(1); local b = assert(start(t, 1))
    assert(a ~= b, "其他槽位的token不受輸入revision影響")
    t.core.navPauseItinerary(0)
    local getData = p.getModData
    p.getModData = function() error("temporary modData fault") end
    eq(edit(t, "append", 300, 0), false, "保存失敗拒絕本次編輯")
    p.getModData = getData
    assert(edit(t, "append", 300, 0), "恢復後可重試，不要求重建有效行程")
end

do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0)); assert(start(t))
    t.core.navPauseItinerary(0); local id = trip(t).currentStopId
    v.stopped = false
    assert(edit(t, "remove", trip(t).stops[2].id))
    assert(edit(t, "undo"), "純後續站復原不需停車")
    eq(trip(t).phase, "paused", "純後續復原保留paused")
    eq(trip(t).currentStopId, id, "純後續復原保留目前站")
end

do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    t.players[0] = nil; t.fire("OnTick")
    local getData, calls = p.getModData, 0
    p.getModData = function(self)
        calls = calls + 1
        if calls == 2 then error("save after successful load") end
        return getData(self)
    end
    t.players[0] = p
    t.core.navLoadItinerary(0)
    p.getModData = getData
    eq(trip(t) and trip(t).count, 2, "載入成功但回存失敗仍保留有效行程")
    eq(t.core.navEditItinerary(0, 0, "append", 300, 0), false, "不可把載入資料當空清單覆寫")
    assert(edit(t, "append", 300, 0))
    eq(trip(t).count, 3, "回存恢復後追加保留原本兩站")
end

-- v7 能力協商：消費者用 navApiVersion >= 7 才分級信任續行語意，宣告了就必須真的能切。
do
    local t = fixture(); t.player(0)
    local version = t.api.navApiVersion
    assert(type(version) == "number" and version == version and version >= 7,
        "v7 Core 必須宣告 navApiVersion >= 7: " .. tostring(version))
    assert(edit(t, "append", 10, 0))
    eq(trip(t).schemaVersion, 2, "快照宣告 schemaVersion 2")
    eq(type(trip(t).autoContinue), "boolean", "續行模式必須是 boolean 才可被守衛判讀")
    assert(autoContinue(t, false), "宣告的版本必須真的支援續行開關")
    eq(trip(t).autoContinue, false, "續行開關確實改變權威狀態")
end

-- 普通兩點 A→B：被動到站自動續發，一個 tick 最多消耗一站，最後一站才完成。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 0, 0, "A")); assert(edit(t, "append", 0, 0, "B"))
    eq(trip(t).autoContinue, true, "新行程預設自動續行")
    eq(trip(t).stops[1].pause, false, "新站預設不強制停留")
    local first = assert(start(t))
    local second = trip(t).stops[2].id
    t.fire("OnTick")
    local it = trip(t)
    eq(it.stops[1].status, "arrived", "腳下的第一站確實抵達")
    eq(it.phase, "navigating", "同一 commit 就啟用下一站")
    eq(it.currentStopId, second, "目前站換成 B")
    eq(it.stops[2].status, "pending", "一個 tick 最多完成一站")
    eq(it.activation, "continue", "續行來源標記為 continue")
    eq(it.reason, nil, "成功續行不留原因")
    local token = t.api.getNavLeg(0)
    assert(token and token ~= first, "續行必須換新 token: " .. tostring(token))
    eq(t.api.getNavTarget(0), 0, "目標投影到 B")
    t.fire("OnTick")
    it = trip(t)
    eq(it.phase, "completed", "最後一站抵達才算整趟完成")
    eq(pendingCount(it), 0, "完成後沒有待辦站")
    eq(it.currentStopId, nil, "完成後沒有目前站")
    eq(it.activation, nil, "完成後不留啟用來源")
    eq(t.api.getNavLeg(0), nil, "完成後沒有可執行段")
end

-- 站級 pause=true 強制等待，優先於全域自動續行，且不關閉全域模式。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 0, 0, "A")); assert(edit(t, "append", 0, 0, "B"))
    assert(hold(t, trip(t).stops[1].id, true))
    eq(trip(t).stops[1].pause, true, "站級強制停留已記錄")
    assert(start(t)); t.fire("OnTick")
    local it = trip(t)
    eq(it.stops[1].status, "arrived", "強制停留站仍算抵達")
    eq(it.phase, "waiting", "強制停留優先於自動續行")
    eq(it.stops[2].status, "pending", "強制停留不啟用下一站")
    eq(it.autoContinue, true, "站級旗標不改全域模式")
    eq(it.activation, nil, "等待中沒有啟用來源")
    eq(t.api.getNavLeg(0), nil, "等待中沒有可執行段")
    eq(t.api.getNavTarget(0), nil, "等待中不提前暴露下一站")
    t.fire("OnTick")
    eq(trip(t).phase, "waiting", "等待不會被 tick 自行解除")
end

-- 全域關閉＝每站都等；waiting 期間切回自動也不得自己出發，要明確 start。
do
    local t = fixture(); local p = t.player(0)
    for _ = 1, 3 do assert(edit(t, "append", 0, 0)) end
    assert(autoContinue(t, false))
    assert(start(t)); t.fire("OnTick")
    local it = trip(t)
    eq(it.phase, "waiting", "關閉後第一站就等")
    eq(it.stops[2].status, "pending", "關閉後不續發")
    assert(autoContinue(t, true), "等待中允許切回自動")
    it = trip(t)
    eq(it.phase, "waiting", "切換模式本身不是出發")
    eq(t.api.getNavLeg(0), nil, "切換模式不簽發段")
    t.fire("OnTick")
    eq(trip(t).phase, "waiting", "沒有看到 waiting 就出發的 watcher")
    eq(trip(t).stops[2].status, "pending", "等待中的下一站不被偷跑")
    assert(start(t)); t.fire("OnTick")
    it = trip(t)
    eq(it.stops[2].status, "arrived", "明確開始後推進一站")
    eq(it.currentStopId, it.stops[3].id, "切回自動後才續發第三站")
    t.fire("OnTick")
    eq(trip(t).phase, "completed", "逐 tick 推進到完成")
end

-- 到站時 gate 不允許：抵達照算，但保留 waiting＋reason=unavailable，不假出發也不重試。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 0, 0, "A")); assert(edit(t, "append", 50, 0, "B"))
    assert(start(t))
    t.gate(false)
    t.fire("OnTick")
    local it = trip(t)
    eq(it.stops[1].status, "arrived", "gate 不影響已發生的抵達")
    eq(it.phase, "waiting", "gate 不允許時保留待續")
    eq(it.reason, "unavailable", "明示不可用而非假裝出發")
    eq(it.stops[2].status, "pending", "下一站未被啟用")
    eq(it.currentStopId, it.stops[1].id, "waiting 停在剛完成的站")
    eq(t.api.getNavLeg(0), nil, "沒有簽發假 token")
    t.fire("OnTick")
    eq(trip(t).phase, "waiting", "gate 失敗不自動重試")
    t.gate(true); t.fire("OnTick")
    eq(trip(t).phase, "waiting", "gate 恢復也要等明確開始")
    assert(start(t))
    eq(trip(t).phase, "navigating", "明確開始才出發")
    eq(trip(t).currentStopId, trip(t).stops[2].id, "出發到原本的下一站")
end

-- mode／pause 在控車期間不奪權、不換 token；同值是 no-op；非 boolean 拒絕。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", assert(start(t))))
    local current = trip(t).currentStopId
    assert(autoContinue(t, false), "控車期間仍可切換續行模式")
    eq(t.api.getNavLeg(0), claimed, "切模式不換 token")
    eq(trip(t).claimed, true, "切模式不奪走控車權")
    eq(trip(t).currentStopId, current, "切模式不換目前站")
    eq(trip(t).autoContinue, false, "切模式確實生效")
    local noop = trip(t).revision
    assert(autoContinue(t, false), "同值切換回報成功")
    eq(trip(t).revision, noop, "同值不推進 revision")
    assert(hold(t, trip(t).stops[2].id, true), "控車期間可標記後續站強制停")
    eq(t.api.getNavLeg(0), claimed, "標記後續站不換 token")
    eq(trip(t).claimed, true, "標記後續站不奪權")
    noop = trip(t).revision
    assert(hold(t, trip(t).stops[2].id, true), "同值站級旗標回報成功")
    eq(trip(t).revision, noop, "同值站級旗標不推進 revision")
    eq(select(2, t.api.setNavContinuation(0, trip(t).revision, 1)), "badargs", "續行模式只收 boolean")
    eq(select(2, t.api.setNavContinuation(0, trip(t).revision, nil)), "badargs", "缺少 boolean 拒絕")
    eq(select(2, hold(t, trip(t).stops[2].id, "yes")), "badargs", "站級旗標只收 boolean")
    eq(select(2, hold(t, 999999, true)), "badargs", "不存在的站拒絕")
    eq(t.api.getNavLeg(0), claimed, "被拒絕的編輯不動 token")
end

-- getNavLeg 維持六回傳；activation 只在快照，不擠進段的回傳位置。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    assert(start(t))
    eq(select("#", t.api.getNavLeg(0)), 6, "有目標時仍是六回傳")
    local token, id, x, y, phase, revision = t.api.getNavLeg(0)
    eq(id, trip(t).currentStopId, "第二位是站id")
    eq(x, 100, "第三位是x"); eq(y, 0, "第四位是y")
    eq(phase, "navigating", "第五位是phase")
    eq(revision, trip(t).revision, "第六位是revision")
    assert(token, "有目標就有 token")
    eq(trip(t).activation, "start", "啟用來源只出現在快照")
    t.core.navPauseItinerary(0, "manual")
    eq(select("#", t.api.getNavLeg(0)), 6, "無目標時也是六回傳")
    eq(select(5, t.api.getNavLeg(0)), "paused", "無目標仍報 phase")
    eq(trip(t).activation, nil, "非活動狀態清除啟用來源")
end

-- activation 不持久化；v2 新欄位存得回、讀得回；重新進入一律停駛。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 10, 20, "A")); assert(edit(t, "append", 30, 40, "B"))
    assert(hold(t, trip(t).stops[2].id, true))
    assert(start(t))
    eq(trip(t).activation, "start", "開始記錄啟用來源")
    local payload = p.md.MinidoracatMiniMapItinerary
    eq(payload.schemaVersion, 2, "存回 v2")
    eq(payload.activation, nil, "啟用來源不持久化")
    eq(payload.count, nil, "衍生 count 仍不持久化")
    eq(payload.autoContinue, true, "續行模式持久化")
    eq(payload.stops[2].pause, true, "站級強制停留持久化")
    eq(payload.stops[1].pause, false, "未標記的站存 false")
    t.fire("OnGameStart")
    local back = trip(t)
    eq(back.phase, "paused", "重新進入存檔不自駕")
    eq(back.activation, nil, "重載沒有啟用來源")
    eq(back.autoContinue, true, "重載保留續行模式")
    eq(back.stops[2].pause, true, "重載保留站級強制停留")
    eq(t.api.getNavLeg(0), nil, "重載沒有可執行段")
    t.fire("OnTick")
    eq(trip(t).phase, "paused", "重載後也沒有自行出發")
end

-- v2 的兩個 boolean 是必填：缺少或錯型都拒絕整筆，不退回舊目標、不覆寫壞資料。
do
    local t = fixture()
    local function payload()
        return { schemaVersion = 2, revision = 5, nextStopId = 3, phase = "draft", autoContinue = true,
            stops = { { id = 1, x = 10, y = 0, status = "pending", pause = false },
                { id = 2, x = 20, y = 0, label = "B", status = "pending", pause = true } } }
    end
    t.player(0, { MinidoracatMiniMapItinerary = payload() })
    local it = trip(t)
    eq(it.count, 2, "合法 v2 完整載回")
    eq(it.autoContinue, true, "載回續行模式")
    eq(it.stops[2].pause, true, "載回站級強制停留")
    eq(it.phase, "draft", "草稿維持草稿")
    local missing = payload(); missing.autoContinue = nil
    local one = t.player(1, { MinidoracatMiniMapItinerary = missing })
    eq(trip(t, 1), nil, "缺少續行模式拒絕載入")
    eq(t.core.navItineraryError(1), "invalid", "記錄為格式錯誤")
    eq(one.md.MinidoracatMiniMapItinerary, missing, "保留壞資料等明確重建")
    eq(edit(t, "append", 1, 1, nil, 1), false, "壞資料不得被追加覆寫")
    local wrong = payload(); wrong.autoContinue = "true"
    t.player(2, { MinidoracatMiniMapItinerary = wrong })
    eq(trip(t, 2), nil, "續行模式錯型拒絕載入")
    local badStop = payload(); badStop.stops[2].pause = nil
    t.player(3, { MinidoracatMiniMapItinerary = badStop })
    eq(trip(t, 3), nil, "站級旗標缺少拒絕載入")
    eq(t.core.navItineraryError(3), "invalid", "站級錯誤也記錄為格式錯誤")
end

-- v1 存檔遷移：續行模式與站級旗標補成 false，遷移後行為真的是逐站等待。
do
    local t = fixture()
    local p = t.player(0, { MinidoracatMiniMapItinerary = {
        schemaVersion = 1, revision = 3, nextStopId = 3, phase = "navigating", currentStopId = 1,
        stops = { { id = 1, x = 10, y = 0, status = "pending" },
            { id = 2, x = 20, y = 0, label = "B", status = "pending" } } } })
    local it = trip(t)
    eq(it.schemaVersion, 2, "遷移後升級 schema")
    eq(it.autoContinue, false, "v1 遷移不自動續行")
    eq(it.stops[1].pause, false, "v1 遷移補齊站級旗標")
    eq(it.stops[2].pause, false, "v1 每一站都補齊")
    eq(it.phase, "paused", "v1 的進行中行程改為待確認")
    eq(p.md.MinidoracatMiniMapItinerary.schemaVersion, 2, "存回新 schema")
    eq(p.md.MinidoracatMiniMapItinerary.autoContinue, false, "存回遷移後的模式")
    assert(start(t)); t.fire("OnTick")
    eq(trip(t).phase, "navigating", "尚未進入距離圈")
    p.x = 10; t.fire("OnTick")
    it = trip(t)
    eq(it.stops[1].status, "arrived", "抵達第一站")
    eq(it.phase, "waiting", "遷移後每站等待")
    eq(it.stops[2].status, "pending", "遷移後不自動續發")
end

-- append 保持當前段：不換 token、不換目前站、加在尾端。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 10, 0)); assert(start(t))
    local token, current = t.api.getNavLeg(0), trip(t).currentStopId
    assert(edit(t, "append", 20, 0), "行進中可以加站")
    local it = trip(t)
    eq(it.phase, "navigating", "append 不中斷目前段")
    eq(it.currentStopId, current, "append 不換目前站")
    eq(t.api.getNavLeg(0), token, "append 不換 token")
    eq(it.count, 2, "append 加一站")
    eq(it.stops[2].x, 20, "append 加在尾端")
end

-- insert 用穩定錨點：錨點前插入、nil 等於尾端、過期／不存在／已完成錨點拒絕。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 10, 0, "A")); assert(edit(t, "append", 20, 0, "B"))
    assert(edit(t, "append", 30, 0, "C"))
    local ids = { trip(t).stops[1].id, trip(t).stops[2].id, trip(t).stops[3].id }
    assert(editAt(t, "insert", 15, 0, "A2", ids[2]), "插在指定錨點之前")
    local it = trip(t)
    eq(it.count, 4, "插入增加一站")
    eq(it.stops[2].label, "A2", "新站落在錨點前一格")
    eq(it.stops[3].id, ids[2], "錨點本身仍在其後")
    eq(it.stops[4].id, ids[3], "其餘站相對順序保留")
    eq(select(2, editAt(t, "insert", 16, 0, nil, 999999)), "badargs", "不存在的錨點拒絕")
    eq(select(2, t.core.navEditItinerary(0, trip(t).revision - 1, "insert", 16, 0, nil, ids[3])),
        "stale", "過期 revision 拒絕插入")
    eq(trip(t).count, 4, "被拒絕的插入不改資料")
    assert(editAt(t, "insert", 40, 0, "tail"), "沒有錨點就插在尾端")
    eq(trip(t).stops[trip(t).count].label, "tail", "nil 錨點等於 append")
    assert(start(t)); p.x = 10; t.fire("OnTick")
    eq(trip(t).stops[1].status, "arrived", "第一站已完成")
    eq(select(2, editAt(t, "insert", 5, 0, nil, ids[1])), "state", "已完成的站不能當錨點")
    local current = trip(t).currentStopId
    assert(editAt(t, "insert", 12, 0, "before-current", current), "插在目前站前需重新規劃")
    it = trip(t)
    eq(it.phase, "draft", "動到目前站回草稿")
    eq(it.currentStopId, nil, "草稿沒有目前站")
    eq(t.api.getNavLeg(0), nil, "回草稿收回段")
end

-- priority 取代舊 next：插在待辦最前並立刻導航，不自行控車、不開自動續行。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 10, 0, "A")); assert(edit(t, "append", 20, 0, "B"))
    assert(edit(t, "append", 30, 0, "C"))
    assert(autoContinue(t, false))
    assert(start(t))
    local ids = { trip(t).stops[1].id, trip(t).stops[2].id, trip(t).stops[3].id }
    local before = t.api.getNavLeg(0)
    assert(edit(t, "priority", 5, 0, "Urgent"))
    local it = trip(t)
    eq(it.count, 4, "優先站加入行程")
    eq(it.stops[1].label, "Urgent", "插在待辦最前")
    eq(it.stops[2].id, ids[1], "原待辦順序保留")
    eq(it.stops[3].id, ids[2], "原待辦順序保留")
    eq(it.stops[4].id, ids[3], "原待辦順序保留")
    eq(it.phase, "navigating", "優先站立即開始導航")
    eq(it.currentStopId, it.stops[1].id, "目前站換成優先站")
    eq(it.activation, "priority", "有後續站時啟用來源為 priority")
    eq(it.autoContinue, false, "優先站不擅自打開自動續行")
    eq(it.claimed, false, "優先站不自行取得控車權")
    eq(t.api.getNavTarget(0), 5, "目標投影到優先站")
    local token = t.api.getNavLeg(0)
    assert(token and token ~= before, "優先站簽發新 token: " .. tostring(token))
    assert(edit(t, "clear")); assert(edit(t, "append", 60, 0))
    assert(start(t)); p.x = 60; t.fire("OnTick")
    eq(trip(t).phase, "completed", "單站行程已完成")
    assert(edit(t, "priority", 70, 0, "New"))
    it = trip(t)
    eq(it.activation, "start", "沒有其他待辦時視為重新開始")
    eq(it.phase, "navigating", "仍然直接開始導航")
    eq(it.currentStopId, it.stops[2].id, "新站成為目前站")
    eq(select(2, t.core.navEditItinerary(0, trip(t).revision, "next", 80, 0)), "badargs",
        "沒有 next 別名")
end

-- 控車期間 priority／動到目前站的 insert 一律拒絕；只有後續站可安排。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", assert(start(t))))
    local rev, current = trip(t).revision, trip(t).currentStopId
    local ok, why = edit(t, "priority", 5, 0, "Urgent")
    eq(ok, false, "控車期間拒絕優先站"); eq(why, "busy", "由 claim 守住")
    ok, why = editAt(t, "insert", 5, 0, nil, current)
    eq(ok, false, "控車期間拒絕插在目前站前"); eq(why, "busy", "由 claim 守住")
    eq(trip(t).revision, rev, "被拒絕不改資料")
    eq(trip(t).currentStopId, current, "被拒絕不換目前站")
    eq(t.api.getNavLeg(0), claimed, "被拒絕不動 token")
    assert(editAt(t, "insert", 150, 0, nil, trip(t).stops[2].id), "控車期間仍可安排後續站")
    eq(t.api.getNavLeg(0), claimed, "安排後續站不動 token")
    eq(trip(t).currentStopId, current, "安排後續站不換目前站")
    eq(trip(t).claimed, true, "安排後續站不奪權")
end

-- move 動到目前站同樣回草稿（remove 已有案例），且收回段。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 10, 0)); assert(edit(t, "append", 20, 0))
    assert(autoContinue(t, false)); assert(start(t))
    local current = trip(t).currentStopId
    assert(edit(t, "move", current, 1))
    local it = trip(t)
    eq(it.phase, "draft", "移動目前站回草稿")
    eq(it.currentStopId, nil, "草稿沒有目前站")
    eq(it.stops[2].id, current, "順序確實交換")
    eq(t.api.getNavLeg(0), nil, "回草稿收回段")
end

-- 手動 skip 不算抵達、不自動續發，即使自動續行開著。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 10, 0)); assert(edit(t, "append", 20, 0))
    assert(start(t))
    eq(trip(t).autoContinue, true, "此案例保持自動續行開啟")
    local current = trip(t).currentStopId
    assert(edit(t, "skip", current))
    local it = trip(t)
    eq(it.stops[1].status, "skipped", "標記為略過")
    eq(it.phase, "waiting", "略過後等待明確開始")
    eq(it.stops[2].status, "pending", "略過不自動續發")
    eq(it.activation, nil, "略過不留啟用來源")
    eq(t.api.getNavLeg(0), nil, "略過沒有簽發新段")
    t.fire("OnTick")
    eq(trip(t).phase, "waiting", "略過後也沒有 watcher 出發")
end

-- 受控回報：continue 處置仍停在 waiting，Core 不替 claim 主自己開下一段。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", assert(start(t))))
    p.x, v.x = 100, 100
    local ok, outcome, disposition, revision = t.api.reportNavArrival(0, "Auto", claimed)
    eq(ok, true, "停妥回報成功"); eq(outcome, "arrived", "本站到達")
    eq(disposition, "continue", "自動續行的處置是 continue")
    eq(revision, trip(t).revision, "回傳已提交的 revision")
    local it = trip(t)
    eq(it.phase, "waiting", "受控回報成功仍等 Driver 開段")
    eq(it.stops[2].status, "pending", "Core 不自己啟用下一站")
    eq(it.currentStopId, it.stops[1].id, "waiting 停在剛完成的站")
    eq(it.activation, nil, "受控回報不留啟用來源")
    eq(it.claimed, false, "抵達後交回控車權")
    eq(t.api.getNavLeg(0), nil, "沒有自動簽發的新 token")
    eq(t.api.getNavTarget(0), nil, "等待中不提前暴露下一站")
    local again = { t.api.reportNavArrival(0, "Auto", claimed) }
    eq(again[1], true, "重送視為已處理"); eq(again[2], "duplicate", "重送為 duplicate")
    eq(again[3], nil, "重送不給處置"); eq(again[4], nil, "重送不給 revision")
    eq(select("#", t.api.reportNavArrival(0, "Auto", claimed)), 2, "重送只有兩個回傳")
    t.fire("OnTick")
    eq(trip(t).phase, "waiting", "重送後仍不自行出發")
    eq(trip(t).stops[2].status, "pending", "重送不推進行程")
end

-- 受控回報：全域關閉與站級強制停都回 stopover，而且仍在 waiting。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    assert(autoContinue(t, false))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", assert(start(t))))
    p.x, v.x = 100, 100
    local ok, outcome, disposition, revision = t.api.reportNavArrival(0, "Auto", claimed)
    eq(ok, true, "停妥回報成功"); eq(outcome, "arrived", "本站到達")
    eq(disposition, "stopover", "全域關閉的處置是 stopover")
    eq(revision, trip(t).revision, "回傳已提交的 revision")
    eq(trip(t).phase, "waiting", "stopover 停在等待")
    eq(trip(t).stops[2].status, "pending", "stopover 不續發")
end
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    assert(hold(t, trip(t).stops[1].id, true))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", assert(start(t))))
    p.x, v.x = 100, 100
    local ok, outcome, disposition = t.api.reportNavArrival(0, "Auto", claimed)
    eq(ok, true, "停妥回報成功"); eq(outcome, "arrived", "本站到達")
    eq(disposition, "stopover", "站級強制停優先於自動續行")
    eq(trip(t).autoContinue, true, "站級強制停不關閉全域模式")
    eq(trip(t).phase, "waiting", "站級強制停停在等待")
end

-- 受控回報：最後一站回 completed，沒有待辦也沒有目標。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", assert(start(t))))
    p.x, v.x = 100, 100
    local ok, outcome, disposition, revision = t.api.reportNavArrival(0, "Auto", claimed)
    eq(ok, true, "停妥回報成功"); eq(outcome, "arrived", "本站到達")
    eq(disposition, "completed", "最後一站的處置是 completed")
    eq(revision, trip(t).revision, "回傳已提交的 revision")
    local it = trip(t)
    eq(it.phase, "completed", "整趟完成")
    eq(pendingCount(it), 0, "完成後沒有待辦站")
    eq(it.currentStopId, nil, "完成後沒有目前站")
    eq(t.api.getNavTarget(0), nil, "完成後沒有目標")
    eq(t.api.getNavLeg(0), nil, "完成後沒有段")
end

-- 受控回報：road_end 的處置與結果一致，且不算抵達。
do
    local t = fixture(); local p = t.player(0); local v = vehicle(p)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    local claimed = assert(t.api.claimNavLeg(0, "Auto", assert(start(t))))
    p.x, v.x = 80, 80
    local ok, outcome, disposition, revision = t.api.reportNavArrival(0, "Auto", claimed)
    eq(ok, true, "道路末端仍是成功回報"); eq(outcome, "road_end", "尚未到站")
    eq(disposition, "road_end", "處置與結果一致")
    eq(revision, trip(t).revision, "回傳已提交的 revision")
    eq(trip(t).phase, "approach", "轉為徒步接近")
    eq(trip(t).stops[1].status, "pending", "道路末端不算抵達")
    eq(trip(t).activation, nil, "道路末端不是啟用來源")
end

-- 快照必須深複製新欄位：外部改動不得污染權威。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 10, 0)); assert(edit(t, "append", 20, 0))
    local held = trip(t).stops[2].id
    assert(hold(t, held, true))
    assert(start(t))
    local snap = trip(t)
    snap.autoContinue, snap.activation, snap.claimed = false, "priority", true
    snap.stops[2].pause, snap.stops[2].id = false, -1
    local fresh = trip(t)
    eq(fresh.autoContinue, true, "快照不可改續行模式")
    eq(fresh.activation, "start", "快照不可改啟用來源")
    eq(fresh.claimed, false, "快照不可改控車狀態")
    eq(fresh.stops[2].pause, true, "快照不可改站級強制停留")
    eq(fresh.stops[2].id, held, "快照不可改站id")
end

-- gate 是 addon 回呼；回呼內的新模式／取消不能被呼叫前的副本覆蓋。
do
    local t = fixture(); t.player(0)
    assert(edit(t, "append", 0, 0)); assert(edit(t, "append", 50, 0)); assert(start(t))
    local entered = false
    t.core.navGateAllows = function()
        if not entered then entered = true; assert(autoContinue(t, false)) end
        return true
    end
    t.fire("OnTick")
    assert(trip(t).autoContinue == false and t.api.getNavTarget(0) == 0,
        "passive continuation must not overwrite the mode changed by its gate")
    t.fire("OnTick")
    assert(trip(t).phase == "waiting" and trip(t).stops[1].status == "arrived",
        "the next tick observes manual mode and finishes only the current stop")
end
do
    local t = fixture(); t.player(0)
    assert(edit(t, "append", 0, 0)); assert(edit(t, "append", 50, 0)); assert(start(t))
    t.core.navGateAllows = function() assert(edit(t, "clear")); return true end
    t.fire("OnTick")
    assert(trip(t) == nil and t.api.getNavTarget(0) == nil,
        "a gate callback clearing the trip cannot be undone by the old arrival")
end
for _, operation in ipairs({ "start", "claim", "priority", "replace", "guide", "undo" }) do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 100, 0)); assert(edit(t, "append", 200, 0))
    if operation ~= "start" then assert(start(t)) end
    if operation == "claim" then vehicle(p) end
    if operation == "undo" then assert(edit(t, "remove", trip(t).stops[2].id)) end
    local oldToken, oldCount = t.api.getNavLeg(0), trip(t).count
    t.core.navGateAllows = function() assert(autoContinue(t, false)); return true end
    local ok, why
    if operation == "start" then ok, why = start(t)
    elseif operation == "claim" then ok, why = t.api.claimNavLeg(0, "Auto", oldToken)
    elseif operation == "replace" then ok, why = t.core.navSetTarget(0, 300, 0)
    elseif operation == "guide" then ok, why = t.core.navGuideItinerary(0, trip(t).revision, "approach")
    elseif operation == "priority" then ok, why = edit(t, operation, 300, 0)
    else ok, why = edit(t, operation) end
    assert(not ok and why == "stale", operation .. " rejects work superseded inside its gate")
    assert(trip(t).autoContinue == false and trip(t).count == oldCount
        and t.api.getNavLeg(0) == oldToken and not trip(t).claimed,
        operation .. " preserves the newer state and does not take control")
end

-- 指引雙向切換：目前站、進度與偏好不變，不先 pause 再 start。
do
    local t = fixture(); local p = t.player(0)
    assert(edit(t, "append", 0, 0, "A")); assert(edit(t, "append", 100, 0, "B"))
    assert(edit(t, "append", 200, 0, "C"))
    assert(hold(t, trip(t).stops[2].id, true)); assert(start(t)); t.fire("OnTick")
    local before = trip(t)
    assert(t.core.navGuideItinerary(0, before.revision, "approach"))
    local direct, directToken = trip(t), t.api.getNavLeg(0)
    assert(direct.phase == "approach" and direct.activation == nil)
    assert(t.core.navGuideItinerary(0, direct.revision, "navigating"))
    local road = trip(t)
    assert(road.phase == "navigating" and road.activation == "start" and not road.claimed)
    eq(t.api.getNavTarget(0), 100, "切回道路仍是目前目標")
    eq(road.currentStopId, before.currentStopId, "切換不選其他站")
    eq(road.count, 3, "切換保留完整清單")
    for i = 1, road.count do
        eq(road.stops[i].id, before.stops[i].id, "切換保留順序與穩定 ID")
        eq(road.stops[i].status, before.stops[i].status, "切換不完成／略過站點")
        eq(road.stops[i].pause, before.stops[i].pause, "切換保留停靠旗標")
    end
    eq(road.autoContinue, before.autoContinue, "切換保留接續模式")
    assert(t.api.getNavLeg(0) ~= directToken, "模式改變撤銷舊段 token")
    local ok, why = t.core.navGuideItinerary(0, direct.revision, "approach")
    assert(not ok and why == "stale", "舊畫面不能反向切回")
    assert(t.core.navGuideItinerary(0, road.revision, "navigating"))
    eq(trip(t).revision, road.revision, "同模式不重啟")

    local car = vehicle(p)
    local claimed = assert(t.api.claimNavLeg(0, "Auto", t.api.getNavLeg(0)))
    ok, why = t.core.navGuideItinerary(0, trip(t).revision, "approach")
    assert(not ok and why == "busy" and t.api.getNavLeg(0) == claimed,
        "切換仍須先交還自駕")
    local stopBefore = select(2, t.api.getNavLeg(0))
    assert(t.api.releaseNavLeg(0, "Auto", claimed, "manual"))
    -- 手動交還：導航不中斷（仍 navigating、同一站、getNavTarget 仍有目標），舊 claim 失效、
    -- 換新段 token 可再 claim。違規證明：manual 改回 paused 即紅。
    do
        local leg, stop, _, _, phase = t.api.getNavLeg(0)
        assert(phase == "navigating" and stop == stopBefore and leg ~= claimed
            and t.api.getNavTarget(0) ~= nil, "手動交還保留導航與目標")
        local ok2, why2 = t.api.reportNavArrival(0, "Auto", claimed)
        assert(not ok2 and why2 ~= "arrived", "舊 claim 不能再回報")
        local again = assert(t.api.claimNavLeg(0, "Auto", leg), "新段 token 可重新接管")
        assert(t.api.releaseNavLeg(0, "Auto", again, "manual"))
    end
    assert(t.core.navGuideItinerary(0, trip(t).revision, "approach"))
    direct, directToken = trip(t), t.api.getNavLeg(0)
    car.stopped = false
    ok, why = t.core.navGuideItinerary(0, direct.revision, "navigating")
    assert(not ok and why == "notstopped", "車未停妥不切換")
    car.stopped = true; t.gate(false)
    ok, why = t.core.navGuideItinerary(0, direct.revision, "navigating")
    assert(not ok and why == "blocked" and t.api.getNavLeg(0) == directToken,
        "gate 拒絕仍保留直線指引")
    t.gate(true)
    local readData = p.getModData
    p.getModData = function() error("guidance save fault") end
    ok, why = t.core.navGuideItinerary(0, direct.revision, "navigating")
    assert(not ok and why == "failed" and trip(t).phase == "approach"
        and t.api.getNavLeg(0) == directToken, "保存失敗不留半完成切換")
    p.getModData = readData
    t.core.navGateAllows = function()
        assert(t.core.navPauseItinerary(0, "manual"))
        return true
    end
    ok, why = t.core.navGuideItinerary(0, direct.revision, "navigating")
    assert(not ok and why == "stale" and trip(t).phase == "paused",
        "切回途中取消不能被舊候選覆寫")
end

print("test_itinerary: PASS (ordered stops, token ownership, stopping, editing, persistence, "
    .. "split-screen, continuation mode, stop holds, passive auto-continue, gate hold-off, "
    .. "insert/priority anchors, report dispositions, v1/v2 migration)")
