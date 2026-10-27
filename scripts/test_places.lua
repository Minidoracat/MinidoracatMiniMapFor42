-- 家／收藏點回歸：真 _Itinerary.lua＋真 _Places.lua 同環境載入，驗回家取代行程、
-- 確認門檻、自駕 claim、帳號檔持久化與格式相容、壞檔與寫入失敗、舊版 modData 搬移、
-- 分割畫面與死亡重生、檔名轉義與右鍵選單。
-- 用法：lua scripts/test_places.lua [places.lua] [itinerary.lua]
local dir = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
local placesPath = arg[1] or (dir .. "MinidoracatMiniMap_Places.lua")
local itineraryPath = arg[2] or (dir .. "MinidoracatMiniMap_Itinerary.lua")
local function readFile(path)
    local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text
end
-- 收藏檔的讀寫在 shared RoadCodec（遊戲裡 shared 先於 client 載入）
local codecPath = dir .. "../shared/MinidoracatMiniMap_RoadCodec.lua"
local sources = { readFile(codecPath), readFile(itineraryPath), readFile(placesPath) }
-- 主檔地圖文字／標記大小 helper：抽 test:map-text 真實作，滑條值由 placeSliders 控制
local mainSource = readFile(dir .. "MinidoracatMiniMap.lua"):gsub("\r\n", "\n")
local mapTextSource = assert(mainSource:match(
    "%-%- test:map%-text:start\n(.-)\n%-%- test:map%-text:end"), "找不到主檔 map-text 測試區段")
-- 「顯示在」兩格（Core.layerOn）：抽 test:layer-maps 真實作，選項值由 placeOpts 控制
local layerMapsSource = assert(mainSource:match(
    "%-%- test:layer%-maps:start\n(.-)\n%-%- test:layer%-maps:end"), "找不到主檔 layer-maps 測試區段")
-- 右鍵導航項鎖定 helper（Core.navMenuLock）：抽 _Nav.lua 的真實作
local menuLockSource = assert(readFile(dir .. "MinidoracatMiniMap_Nav.lua"):gsub("\r\n", "\n"):match(
    "%-%- test:nav%-menu%-lock:start\n(.-)\n%-%- test:nav%-menu%-lock:end"), "找不到 _Nav nav-menu-lock 測試區段")
local placeSliders, placeOpts = {}, {}

-- 假的 Zomboid/Lua 目錄，語意照 LuaManager.java：路徑含 ".." 回 nil（hasRelativePath）、寫入只收
-- 白名單副檔名、開寫就截斷（FileOutputStream append=false）、readLine 剝行尾。broken＝檔在卻打不開；
-- lossy＝寫入被吞掉（PrintWriter 不拋例外）。
local function newFs() return { files = {}, broken = {}, lossy = false } end
local DEFAULT_WORLD = { mode = "Sandbox", name = "Save1" }
local function fixture(opts)
    opts = opts or {}
    local fs, world = opts.fs or newFs(), opts.world or DEFAULT_WORLD
    local handlers, players, client = {}, {}, false
    local events = {}
    for _, name in ipairs({ "OnCreatePlayer", "OnGameStart", "OnTick" }) do
        handlers[name] = {}
        events[name] = { Add = function(fn) handlers[name][#handlers[name] + 1] = fn end }
    end
    local log = { messages = {}, prompts = {}, dialogs = {} }
    local core = { ready = true, navGateAllows = function() return true end,
        getBoolOption = function(id, default)
            if placeOpts[id] == nil then return default end
            return placeOpts[id]
        end }
    assert(load(mapTextSource, "map-text", "t", setmetatable({ Core = core,
        getSliderValue = function(id, default)
            if placeSliders[id] == nil then return default end
            return placeSliders[id]
        end }, { __index = _G })))()
    assert(load(layerMapsSource, "layer-maps", "t", setmetatable({ Core = core,
        getBoolOption = core.getBoolOption }, { __index = _G })))()
    -- 白 glyph 染色畫法（_Dots.lua adotsDrawGlyph）：記錄邊長與左上角
    core.adotsDrawGlyph = function(inner, tex, x, y, size)
        inner.glyphs[#inner.glyphs + 1] = { tex = tex, x = x, y = y, size = size }
    end
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
        isClient = function() return client end,
        getText = function(key, arg) if arg ~= nil then return key .. "|" .. tostring(arg) end return key end,
        ISTextBox = TextBox, ISToolTip = { new = function() return tooltip() end },
        getJoypadData = function() return nil end,
        HaloTextHelper = { addGoodText = function() end, addBadText = function() end },
        UIFont = { Small = "Small" }, getTexture = function(path) return path end,
        getTextManager = function()
            return { getFontHeight = function() return 10 end,
                MeasureStringX = function(_, _, s) return #s * 5 end }
        end,
        getWorld = function()
            return { getGameMode = function() return world.mode end, getWorld = function() return world.name end }
        end,
        cacheFileExists = function(path) return fs.files[path] ~= nil end,
        getFileReader = function(path)
            local text = fs.files[path]
            if path:find("..", 1, true) or fs.broken[path] or text == nil then return nil end
            local pos = 1
            return { close = function() end, readLine = function()
                if pos > #text then return nil end
                local nl = text:find("\n", pos, true) or #text + 1
                local line = text:sub(pos, nl - 1)
                pos = nl + 1
                return line
            end }
        end,
        getFileWriter = function(path)
            if path:find("..", 1, true) or not path:match("%.txt$") then return nil end
            fs.files[path] = ""
            local buf = {}
            return { write = function(_, s) buf[#buf + 1] = s end,
                close = function() fs.files[path] = fs.lossy and "" or table.concat(buf) end }
        end,
    }, { __index = _G })
    for i, source in ipairs(sources) do
        local chunk
        if setfenv then chunk = assert(loadstring(source)); setfenv(chunk, env)
        else chunk = assert(load(source, "module" .. i, "t", env)) end
        chunk()
    end
    assert(load(menuLockSource, "nav-menu-lock", "t", setmetatable({ Core = core }, { __index = env })))()
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
    return { core = core, api = api, player = player, players = players, log = log, fs = fs,
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
    -- 未設家又遇導航被擋：仍先說明怎麼設家（設了家才有意義談導航設備）
    local mb = menu(); t.core.placesAddMenu(mb, 0, 10, 20, "NeedGPS")
    eq(mb:find("UI_MinidoracatMiniMap_GoHome").toolTip.description, "UI_MinidoracatMiniMap_HomeNotSet",
        "未設家時導航被擋仍說明設定家")
    local set = assert(m:find("UI_MinidoracatMiniMap_SetHome"), "右鍵有設為家")
    set.fn(set.target, set.a, set.b)
    eq(lastMessage(t), "UI_MinidoracatMiniMap_HomeSet", "設為家回饋")
    local hx, hy, label = t.api.getNavHome(0)
    eq(hx, 10, "家 x"); eq(hy, 20, "家 y"); eq(label, "UI_MinidoracatMiniMap_PlaceHome", "無名家顯示「家」")
    m = menu(); t.core.placesAddMenu(m, 0, 30, 40)
    eq(m:find("UI_MinidoracatMiniMap_GoHome").notAvailable, nil, "設家後右鍵回家可用")
    -- 導航被擋（navBlocked＝原因文字）：已設家的回家變灰並說原因；設為家／加入收藏不受影響
    m = menu(); t.core.placesAddMenu(m, 0, 30, 40, "NeedGPS")
    go = m:find("UI_MinidoracatMiniMap_GoHome")
    eq(go.notAvailable, true, "導航被擋時右鍵回家不可用")
    eq(go.toolTip.description, "NeedGPS", "被擋的回家附導航被擋原因")
    eq(m:find("UI_MinidoracatMiniMap_SetHome").notAvailable, nil, "導航被擋不影響設為家")
    eq(m:find("UI_MinidoracatMiniMap_PlaceAdd").notAvailable, nil, "導航被擋不影響加入收藏")
    -- 已有家再「設為家」＝這裡另建一筆當家，舊家留在收藏（同搜尋視窗「設為家」：不刪地點，
    -- 誤點不會弄丟舊家座標；2026-10-11 設計稿作答）
    assert(t.core.placesSetHomeAt(0, 50, 60))
    local s = t.core.placesState(0)
    eq(s.count, 2, "設為家不覆蓋舊家：多一筆收藏")
    eq((t.api.getNavHome(0)), 50, "家換到新座標")
    eq(t.core.placeLabel(0, s.places[1]), "10, 20", "舊家留在收藏（無名顯示座標）")
end

-- 有名稱的家再「設為家」：舊家連名稱留在收藏，新家無名顯示「家」
do
    local t = fixture(); t.player(0)
    assert(t.core.placesSetHome(0, assert(t.core.placesAdd(0, 1, 2, "Base"))))
    assert(t.core.placesSetHomeAt(0, 7, 8))
    local s = t.core.placesState(0)
    eq(s.count, 2, "有名稱的舊家不被覆蓋")
    eq(s.places[1].label, "Base", "舊家名稱留在收藏"); eq(s.places[1].x, 1, "舊家座標留在收藏")
    local hx, _, label = t.api.getNavHome(0)
    eq(hx, 7, "家換到新座標"); eq(label, "UI_MinidoracatMiniMap_PlaceHome", "新家無名顯示「家」")
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

-- 公開 setNavTarget（navApiVersion 12）：任意座標走回家同一路徑；站名可自訂、nil／空白顯示座標；
-- 壞參數一律 badargs 且不建立行程；API 不顯示 MiniMap 訊息。
do
    local t = fixture(); local p = t.player(0)
    eq(t.api.navApiVersion, 12, "setNavTarget 隨 navApiVersion 12 宣告")
    local ok, why = t.api.setNavTarget(0, 100, 50, "  My car  ")
    eq(ok, true, "設定成功"); eq(why, "ok", "直接開始")
    local it = t.api.getNavItinerary(0)
    eq(it.count, 1, "單站"); eq(it.phase, "navigating", "立即導航")
    eq(it.stops[1].label, "My car", "站名去頭尾空白")
    local gx, gy = t.api.getNavTarget(0)
    eq(gx, 100, "目標 x"); eq(gy, 50, "目標 y")
    assert(t.api.setNavTarget(0, 200.5, -7))
    it = t.api.getNavItinerary(0)
    eq(it.count, 1, "單站時直接取代"); eq(it.stops[1].x, 200.5, "小數座標照存")
    eq(it.stops[1].label, nil, "nil 站名＝顯示座標")
    assert(t.api.setNavTarget(0, 300, 0, " \t"))
    eq(t.api.getNavItinerary(0).stops[1].label, nil, "空白站名＝顯示座標")
    eq(#t.log.messages, 0, "API 呼叫不顯示訊息"); eq(#t.log.prompts, 0, "單站不確認")
    -- 壞參數：playerNum 非 0-3 整數、座標非有限數或超界、站名非字串或過長
    local before = t.api.getNavItinerary(0).revision
    local huge, nan = math.huge, 0 / 0
    local bad = {
        { -1, 1, 1 }, { 4, 1, 1 }, { 0.5, 1, 1 }, { nan, 1, 1 }, { "0", 1, 1 }, { nil, 1, 1 },
        { 0, nan, 1 }, { 0, huge, 1 }, { 0, -huge, 1 }, { 0, "1", 1 }, { 0, nil, 1 }, { 0, 2e9, 1 },
        { 0, 1, nan }, { 0, 1, huge }, { 0, 1, nil }, { 0, 1, {} },
        { 0, 1, 1, 5 }, { 0, 1, 1, {} }, { 0, 1, 1, string.rep("x", 129) },
    }
    for i = 1, #bad do
        local b = bad[i]
        local bok, bwhy = t.api.setNavTarget(b[1], b[2], b[3], b[4])
        eq(bok, false, "壞參數不成功 case " .. i); eq(bwhy, "badargs", "壞參數原因 case " .. i)
    end
    eq(t.api.getNavItinerary(0).revision, before, "壞參數不動行程")
    assert(t.api.setNavTarget(0, 50, 50, string.rep("x", 128)), "128 字站名可用")
    -- 沒有玩家／已死亡
    eq(select(2, t.api.setNavTarget(1, 10, 10)), "noplayer", "空槽位")
    p.dead = true
    eq(select(2, t.api.setNavTarget(0, 10, 10)), "noplayer", "死亡")
    p.dead = nil
    -- 5 格內不建立會立刻到站的行程
    local near = fixture(); near.player(0)
    eq(select(2, near.api.setNavTarget(0, 3, 4)), "nearby", "5 格內")
    eq(near.api.getNavItinerary(0), nil, "nearby 不建行程")
    eq(select(2, near.api.setNavTarget(0, 9, 0)), "ok", "超過 5 格才導航")
    -- set 閘門擋住：回 blocked＋detailKey，原目標不變
    local gated = fixture(); gated.player(0)
    assert(gated.api.setNavTarget(0, 100, 0, "A"))
    gated.core.navGateAllows = function() return false, "UI_Test_NeedGPS" end
    local gok, gwhy, gkey = gated.api.setNavTarget(0, 200, 0, "B")
    eq(gok, false, "閘門擋住"); eq(gwhy, "blocked", "閘門原因"); eq(gkey, "UI_Test_NeedGPS", "閘門 detailKey")
    eq(gated.api.getNavTarget(0), 100, "被擋不覆蓋原目標")
end

-- setNavTarget 的確認門檻與自駕同回家：丟 ≥2 待前往站開確認（帶自訂站名）、多站 claim 中 busy、
-- 單站自駕中沿用 claim 只換目的地。
do
    local t = fixture(); vehicle(t.player(0))
    assert(edit(t, "append", 10, 0)); assert(edit(t, "append", 20, 0))
    local before = t.api.getNavItinerary(0).revision
    local ok, why = t.api.setNavTarget(0, 500, 0, "My car")
    eq(ok, true, "多站時開確認"); eq(why, "prompted", "回報已開確認")
    eq(#t.log.prompts, 1, "確認窗一次"); eq(t.log.prompts[1].op, "replace", "確認後走既有取代")
    eq(t.log.prompts[1].x, 500, "確認的是目標座標"); eq(t.log.prompts[1].label, "My car", "確認帶站名")
    eq(t.api.getNavItinerary(0).revision, before, "確認前行程不變")
    assert(t.api.claimNavLeg(0, "Auto", assert(t.api.startNavItinerary(0, t.api.getNavItinerary(0).revision))))
    eq(select(2, t.api.setNavTarget(0, 500, 0)), "busy", "多站自駕中")
    local s = fixture(); local sp = s.player(0); local v = vehicle(sp)
    assert(s.core.navSetTarget(0, 100, 0))
    local claimed = assert(s.api.claimNavLeg(0, "Auto", s.api.getNavLeg(0)))
    v.stopped = false
    eq(select(2, s.api.setNavTarget(0, 400, 0, "My car")), "ok", "單站自駕中直接換目的地")
    local leg, _, lx = s.api.getNavLeg(0)
    eq(leg, claimed, "沿用 claim token"); eq(lx, 400, "目的地換成新座標")
end

-- 收藏：新增／改名／移除／設為家；超過 16 筆可保存載回；移除家清掉家；長度與空白。
do
    local t = fixture(); t.player(0)
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
    for i = 3, 64 do assert(t.core.placesAdd(0, i, i, "Place " .. i)) end
    local restored = fixture({ fs = t.fs }); restored.player(0)
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

-- 持久化：寫進帳號檔 places/<模式>/<世界>_p<序號>.txt，不寫角色 modData；同存檔的新 fixture 完整
-- 載回（小數座標、名稱裡的 tab／%／換行原樣回來）；寫到一半的壞檔（沒有 END）當空清單且可覆寫；
-- 較新版本只讀、原檔不動。
do
    local t = fixture(); local p = t.player(0)
    local id = assert(t.core.placesAdd(0, 11.5, 12, "Shop\t1%\n2"))
    assert(t.core.placesSetHome(0, id))
    local path = "MinidoracatMiniMap/places/Sandbox/Save1_p0.txt"
    local text = assert(t.fs.files[path], "寫進帳號檔")
    eq(p.md.MinidoracatMiniMapPlaces, nil, "不寫角色 modData")
    local t2 = fixture({ fs = t.fs }); t2.player(0)
    local x, y, label = t2.api.getNavHome(0)
    eq(x, 11.5, "載回 x"); eq(y, 12, "載回 y"); eq(label, "Shop\t1%\n2", "名稱原樣載回")
    t.fs.files[path] = text:gsub("\nEND\t%d+$", "")
    local t3 = fixture({ fs = t.fs }); t3.player(0)
    eq(t3.core.placesError(0), "invalid", "沒有 END＝寫到一半的壞檔")
    eq(t3.core.placesState(0).count, 0, "壞檔當空清單")
    assert(t3.core.placesAdd(0, 1, 1, "New"))
    eq(t3.core.placesError(0), nil, "成功寫入後清錯誤")
    local future = "MMPLACES\t2\tnew-format"
    t.fs.files[path] = future
    local t4 = fixture({ fs = t.fs }); t4.player(0)
    eq(t4.core.placesError(0), "unsupported", "較新版本")
    local ok, why = t4.core.placesSetHomeAt(0, 1, 1)
    eq(ok, false, "較新版本拒絕寫入"); eq(why, "unsupported", "原因")
    eq(t.fs.files[path], future, "原檔未被覆寫")
end

-- 格式相容：這一版寫出的檔，往後的版本都要讀得懂（要改格式就升版本、舊檔照讀）。
do
    local fs = newFs()
    fs.files["MinidoracatMiniMap/places/Sandbox/Save1_p0.txt"] = table.concat({ "MMPLACES\t1\t4\t2",
        "1\t10\t20\tFarm %25 %09tab", "2\t30.5\t-40\t", "3\t50\t60\tShop", "END\t3" }, "\n")
    local t = fixture({ fs = fs }); t.player(0)
    local s = t.core.placesState(0)
    eq(t.core.placesError(0), nil, "既有格式沒有錯誤")
    eq(s.count, 3, "三筆"); eq(s.homeId, 2, "家")
    eq(s.places[1].label, "Farm % \ttab", "名稱解轉義")
    eq(s.places[2].x, 30.5, "小數座標"); eq(s.places[2].label, nil, "無名")
    eq(select(3, t.api.getNavHome(0)), "UI_MinidoracatMiniMap_PlaceHome", "無名的家顯示「家」")
    assert(t.core.placesAdd(0, 1, 1))
    eq(t.core.placesState(0).places[4].id, 4, "新筆接續 nextId")
end

-- 檔在卻打不開（被鎖、權限）：不當成沒有檔，寫入回 failed 且不蓋掉；打得開後下一次寫入先重讀再寫。
-- 寫入被吞掉（讀回不符）：回 failed，畫面與 revision 不變。
do
    local t = fixture(); t.player(0)
    assert(t.core.placesAdd(0, 1, 1, "Keep"))
    local path = "MinidoracatMiniMap/places/Sandbox/Save1_p0.txt"
    local before = t.fs.files[path]
    t.fs.broken[path] = true
    local t2 = fixture({ fs = t.fs }); t2.player(0)
    eq(t2.core.placesError(0), "unreadable", "打不開不是沒有檔")
    local ok, why = t2.core.placesAdd(0, 2, 2, "New")
    eq(ok, nil, "打不開時不寫"); eq(why, "failed", "原因")
    eq(t.fs.files[path], before, "沒有蓋掉打不開的檔")
    t.fs.broken[path] = nil
    assert(t2.core.placesAdd(0, 2, 2, "New"))
    local s = t2.core.placesState(0)
    eq(s.count, 2, "重讀後原本的收藏還在"); eq(s.places[1].label, "Keep", "原本那筆")
    local rev = s.revision
    t.fs.lossy = true
    ok, why = t2.core.placesAdd(0, 3, 3)
    eq(ok, nil, "讀回不符不套用"); eq(why, "failed", "原因")
    eq(t2.core.placesState(0).count, 2, "畫面維持原狀"); eq(t2.core.placesState(0).revision, rev, "revision 不變")
end

-- 舊版收藏（角色 modData）：第一次載入搬進帳號檔並清掉舊鍵，MP 等有 onlineID 才傳回伺服器一次，
-- 之後一般寫入不再傳；寫檔失敗保留舊鍵、照樣顯示，下一次寫入成功再清；已有帳號檔時舊鍵只清不用；
-- 舊鍵是壞資料照舊可覆寫，是較新版本只讀。
do
    local legacy = { schemaVersion = 1, nextId = 3, homeId = 2,
        places = { { id = 1, x = 5, y = 6, label = "Farm" }, { id = 2, x = 7, y = 8 } } }
    local t = fixture(); t.client(true)
    local p = t.player(0, { MinidoracatMiniMapPlaces = legacy })
    eq(t.core.placesState(0).count, 2, "舊收藏載入"); eq((t.api.getNavHome(0)), 7, "舊的家")
    eq(p.md.MinidoracatMiniMapPlaces, nil, "搬完清掉舊鍵")
    assert(t.fs.files["MinidoracatMiniMap/places/Sandbox/Save1_p0.txt"], "搬進帳號檔")
    t.fire("OnTick"); eq(p.sync, 0, "尚無 onlineID 不傳")
    p.online = 2
    t.fire("OnTick"); eq(p.sync, 1, "清掉舊鍵後傳回伺服器一次")
    t.fire("OnTick"); eq(p.sync, 1, "之後不重傳")
    assert(t.core.placesAdd(0, 9, 9)); t.fire("OnTick")
    eq(p.sync, 1, "一般寫入只寫帳號檔、不傳角色資料")
    local sp = fixture(); local sp0 = sp.player(0, { MinidoracatMiniMapPlaces = legacy }); sp0.online = 1
    sp.core.placesState(0); sp.fire("OnTick")
    eq(sp0.sync, 0, "單機不傳"); eq(sp0.md.MinidoracatMiniMapPlaces, nil, "單機也清掉舊鍵")
    local t2 = fixture(); t2.fs.lossy = true
    local p2 = t2.player(0, { MinidoracatMiniMapPlaces = legacy })
    eq(t2.core.placesState(0).count, 2, "搬移失敗仍顯示舊收藏")
    eq(p2.md.MinidoracatMiniMapPlaces, legacy, "搬移失敗保留舊鍵")
    -- 寫入失敗留下截斷的空檔：下次載入當壞檔（不是打不開），照樣改用角色上的舊收藏
    eq(t2.fs.files["MinidoracatMiniMap/places/Sandbox/Save1_p0.txt"], "", "寫入失敗留下空檔")
    local t2b = fixture({ fs = t2.fs }); t2b.player(0, { MinidoracatMiniMapPlaces = legacy })
    eq(t2b.core.placesError(0), nil, "空檔不是打不開"); eq(t2b.core.placesState(0).count, 2, "空檔時仍用舊收藏")
    t2.fs.lossy = false
    assert(t2.core.placesAdd(0, 1, 1))
    eq(p2.md.MinidoracatMiniMapPlaces, nil, "寫入成功後清掉舊鍵")
    eq(t2.core.placesState(0).count, 3, "舊收藏連同新增的都在")
    local stale = { schemaVersion = 1, nextId = 2, places = { { id = 1, x = 0, y = 0, label = "Stale" } } }
    local t3 = fixture({ fs = t.fs }); local p3 = t3.player(0, { MinidoracatMiniMapPlaces = stale })
    eq(t3.core.placesState(0).count, 3, "已有帳號檔時以帳號檔為準")
    eq(p3.md.MinidoracatMiniMapPlaces, nil, "角色上的舊鍵清掉")
    local bad = { schemaVersion = 1, nextId = 2, homeId = 9, places = { { id = 1, x = 0, y = 0 } } }
    local t4 = fixture(); local p4 = t4.player(0, { MinidoracatMiniMapPlaces = bad })
    eq(t4.core.placesError(0), "invalid", "舊鍵 homeId 指向不存在者＝壞資料")
    eq(t4.core.placesState(0).count, 0, "壞資料當空清單")
    assert(t4.core.placesAdd(0, 1, 1, "New"))
    eq(p4.md.MinidoracatMiniMapPlaces, nil, "覆寫成功後清掉壞的舊鍵")
    local future = { schemaVersion = 2, whatever = true }
    local t5 = fixture(); local p5 = t5.player(0, { MinidoracatMiniMapPlaces = future })
    eq(t5.core.placesError(0), "unsupported", "舊鍵是較新版本")
    eq(select(2, t5.core.placesSetHomeAt(0, 1, 1)), "unsupported", "較新版本拒絕寫入")
    eq(p5.md.MinidoracatMiniMapPlaces, future, "原資料未被覆寫")
end

-- 分割畫面各自一份；同槽位換角色（死亡重生）讀同一份；另一個存檔（多人＝另一個伺服器帳號）是另一份，
-- 檔名就是存檔資料夾名稱。
do
    local t = fixture(); t.player(0); t.player(1)
    assert(t.core.placesSetHomeAt(0, 10, 10))
    eq(select(2, t.api.getNavHome(1)), "nohome", "P2 沒有 P1 的家")
    assert(t.core.placesSetHomeAt(1, 20, 20))
    eq((t.api.getNavHome(0)), 10, "P1 的家不受影響")
    t.player(0, {})
    eq((t.api.getNavHome(0)), 10, "死亡重生的新角色看得到原本的家")
    local account = "127.0.0.1_16261_098f6bcd4621d373cade4e832627b4f6"
    local mp = fixture({ fs = t.fs, world = { mode = "Multiplayer", name = account } }); mp.player(0)
    eq(select(2, mp.api.getNavHome(0)), "nohome", "另一個存檔沒有這份")
    assert(mp.core.placesSetHomeAt(0, 30, 30))
    assert(t.fs.files["MinidoracatMiniMap/places/Multiplayer/" .. account .. "_p0.txt"], "多人檔名＝存檔資料夾名")
    local again = fixture({ fs = t.fs }); again.player(0)
    eq((again.api.getNavHome(0)), 10, "單機那份不受影響")
    eq(select(2, t.api.goNavHome(4)), "badargs", "壞槽位")
end

-- 檔名轉義：% / \ 與 ".." 轉成 %xx；路徑不含 ".."（否則 getFileWriter 回 nil）、不多出子目錄，
-- 不同世界名不撞檔。
do
    local seen = {}
    for _, name in ipairs({ "a..b", "a.%2eb", "a%b", "a%25b", "a/b", "a\\b", "a...b", "a.b" }) do
        local t = fixture({ world = { mode = "Sandbox", name = name } }); t.player(0)
        assert(t.core.placesAdd(0, 1, 1), "可寫入: " .. name)
        local path = next(t.fs.files)
        assert(path:match("^MinidoracatMiniMap/places/Sandbox/[^/\\]+_p0%.txt$") and not path:find("..", 1, true),
            "安全路徑: " .. path)
        assert(not seen[path], "不撞檔: " .. name); seen[path] = true
    end
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
    eq(t.core.placesState(0).count, 1, "換角色後舊對話框不寫入（新角色讀同一份，仍只有原本 1 筆）")
end

-- 地圖標記：圖示邊長跟「標記大小」滑條（預設 16），名稱跟「地圖文字大小」並掛在圖示正下方。
do
    local t = fixture(); t.player(0)
    assert(t.core.placesSetHomeAt(0, 500, 50))
    local function surface()
        local s = { playerNum = 0, width = 1000, height = 200, glyphs = {}, texts = {},
            mapAPI = { worldToUIX = function(_, x) return x end, worldToUIY = function(_, _, y) return y end } }
        function s:drawRect() end
        function s:drawText(txt, x, y) self.texts[#self.texts + 1] = { s = txt, x = x, y = y, zoom = 1 } end
        function s:drawTextZoomed(txt, x, y, z) self.texts[#self.texts + 1] = { s = txt, x = x, y = y, zoom = z } end
        return s
    end
    local s1 = surface(); t.core.drawPlaces(s1)
    eq(s1.glyphs[1].size, 16, "預設標記 16px"); eq(s1.glyphs[1].x, 492, "預設標記置中")
    eq(s1.texts[1].zoom, 1, "預設名稱原尺寸"); eq(s1.texts[1].y, 50 + 8 + 2, "名稱在圖示下方")
    placeSliders.MarkerIconSize, placeSliders.MapTextScale = 32, 200
    local s2 = surface(); t.core.drawPlaces(s2)
    eq(s2.glyphs[1].size, 32, "標記大小 32px"); eq(s2.glyphs[1].x, 484, "放大後仍置中")
    eq(s2.texts[1].zoom, 2, "名稱兩倍字"); eq(s2.texts[1].y, 50 + 16 + 2, "名稱在放大後的圖示下方")
    -- 字寬 #"UI_MinidoracatMiniMap_PlaceHome"*5*2 置中於 x=500
    eq(s2.texts[1].x, 500 - #"UI_MinidoracatMiniMap_PlaceHome" * 5, "兩倍名稱置中")
    placeSliders.MarkerIconSize, placeSliders.MapTextScale = nil, nil
    -- 「顯示在」小地圖那格關＝小地圖不畫標記與名稱；收藏資料不動；世界地圖那格照畫
    placeOpts.Places = false
    local s3 = surface(); t.core.drawPlaces(s3)
    eq(#s3.glyphs + #s3.texts, 0, "Places 關＝小地圖不畫家與收藏點")
    eq(t.core.placesState(0).count, 1, "Places 關不動收藏資料")
    local s4 = surface()
    ISWorldMap_instance = s4
    t.core.drawPlaces(s4)
    eq(#s4.glyphs, 1, "世界地圖那格開＝世界地圖照畫")
    placeOpts.WMPlaces = false
    local s5 = surface()
    ISWorldMap_instance = s5
    t.core.drawPlaces(s5)
    eq(#s5.glyphs + #s5.texts, 0, "WMPlaces 關＝世界地圖不畫")
    ISWorldMap_instance = nil
    placeOpts.Places, placeOpts.WMPlaces = nil, nil
end

-- 雙地圖右鍵的收藏圖標（Core.placeAt）：圖標至少算 24px 見方（標記 8px 也一樣）、名稱底框也算（要等
-- drawPlaces 建好字寬快取）、重疊取最後畫的那筆；這張地圖不畫收藏、或圖示在邊界外沒畫出來＝沒有目標。
-- 子選單（placesAddMenu 第 6 參）換成這一筆：設為家（家本身不列）／改名／從收藏移除，不列加入收藏；
-- 父項「收藏：名稱」（Core.placeMenuTitle）名稱太長截短。
do
    local t = fixture(); t.player(0)
    local shop = assert(t.core.placesAdd(0, 100, 50, "Shop"))
    local barn = assert(t.core.placesAdd(0, 300, 50, "Barn"))
    local over = assert(t.core.placesAdd(0, 310, 50, "Over")) -- 比 Barn 晚畫＝疊在上面
    assert(t.core.placesAdd(0, 3, 50, "Edge")) -- 圖示超出左緣，drawPlaces 不畫
    local s = { playerNum = 0, width = 1000, height = 200, glyphs = {},
        mapAPI = { worldToUIX = function(_, x) return x end, worldToUIY = function(_, _, y) return y end } }
    function s:drawRect() end
    function s:drawText() end
    function s:drawTextZoomed() end
    local function hit(x, y)
        local p = t.core.placeAt(s, x, y)
        return p and p.id
    end
    eq(hit(100, 50), shop, "點在圖標中心")
    eq(hit(111, 50), shop, "標記 16px 時仍算 24px 見方（右緣 12px 內）")
    eq(hit(113, 50), nil, "超出 24px 見方")
    eq(hit(112, 68), nil, "還沒畫過（沒有字寬快取）時名稱不算")
    t.core.drawPlaces(s)
    -- 名稱 "Shop" 寬 20：底框 x 90-110（±3）、y 60-70（圖示下緣＋2、字高 10）
    eq(hit(112, 68), shop, "名稱底框也算")
    eq(hit(305, 50), over, "重疊時取最後畫的那筆（最上層）")
    eq(hit(3, 50), nil, "超出邊界沒畫出來的不算")
    placeSliders.MarkerIconSize = 8
    eq(hit(111, 50), shop, "標記 8px 仍算 24px 見方")
    placeSliders.MarkerIconSize = 32
    eq(hit(115, 50), shop, "標記 32px 照圖示大小算")
    placeSliders.MarkerIconSize = nil
    placeOpts.Places = false
    eq(hit(100, 50), nil, "小地圖那格關＝小地圖沒有目標")
    ISWorldMap_instance = s
    eq(hit(100, 50), shop, "世界地圖那格開＝世界地圖照認")
    placeOpts.WMPlaces = false
    eq(hit(100, 50), nil, "世界地圖那格關＝世界地圖沒有目標")
    ISWorldMap_instance = nil
    placeOpts.Places, placeOpts.WMPlaces = nil, nil

    local function names(m)
        local out = {}
        for i, o in ipairs(m.options) do out[i] = o.name:gsub("^UI_MinidoracatMiniMap_", "") end
        return table.concat(out, ",")
    end
    local removed = {}
    t.core.navPromptPlaceRemove = function(pn, id) removed[#removed + 1] = pn .. ":" .. id end
    local m = menu(); t.core.placesAddMenu(m, 0, 100, 50, nil, t.core.placeAt(s, 100, 50))
    eq(names(m), "GoHome,SetHome,PlaceRename,PlaceRemove", "收藏上的子選單＝這一筆的動作、不列加入收藏")
    local set = m:find("UI_MinidoracatMiniMap_SetHome")
    set.fn(set.target, set.a)
    eq((t.api.getNavHome(0)), 100, "設為家＝這一筆變成家")
    eq(t.core.placesState(0).count, 4, "設為家不新增地點")
    eq(lastMessage(t), "UI_MinidoracatMiniMap_HomeSet", "設為家回饋")
    m = menu(); t.core.placesAddMenu(m, 0, 100, 50, nil, t.core.placeAt(s, 100, 50))
    eq(names(m), "GoHome,PlaceRename,PlaceRemove", "家本身不列設為家")
    local rename = m:find("UI_MinidoracatMiniMap_PlaceRename")
    rename.fn(rename.target, rename.a)
    local box = t.log.dialogs[#t.log.dialogs]
    eq(box.default, "Shop", "改名預填這一筆的名稱")
    box:press("OK", "Mall")
    eq(t.core.placeLabel(0, t.core.placesState(0).places[1]), "Mall", "改名寫進這一筆")
    local remove = m:find("UI_MinidoracatMiniMap_PlaceRemove")
    remove.fn(remove.target, remove.a)
    eq(removed[1], "0:" .. shop, "移除交給共用確認框（帶 pn 與這一筆的 id）")
    t.core.navPromptPlaceRemove = nil
    m = menu(); t.core.placesAddMenu(m, 0, 300, 50, nil, t.core.placeAt(s, 300, 50))
    eq(names(m), "GoHome,SetHome,PlaceRename", "缺確認框（_Search）時不列移除")
    m = menu(); t.core.placesAddMenu(m, 0, 600, 50, nil, t.core.placeAt(s, 600, 50))
    eq(names(m), "GoHome,SetHome,PlaceAdd", "空白處照舊：設為家（這裡）／加入收藏；缺搜尋視窗時不列管理收藏")
    -- 「管理收藏...」（2026-10-21 設計稿 minimap-places-entry-1021 作答）：空白處子選單最後一項，開搜尋視窗的
    -- 收藏頁（帶頁名＝視窗開著就切頁、不關）；收藏圖標上的子選單只管那一筆，不列
    local opened = {}
    t.core.toggleSearchWindow = function(pn, page) opened[#opened + 1] = tostring(pn) .. ":" .. tostring(page) end
    m = menu(); t.core.placesAddMenu(m, 0, 600, 50, nil, t.core.placeAt(s, 600, 50))
    eq(names(m), "GoHome,SetHome,PlaceAdd,PlaceManage", "空白處子選單最後是管理收藏")
    local manage = m:find("UI_MinidoracatMiniMap_PlaceManage")
    manage.fn(manage.target, manage.a)
    eq(opened[1], "0:places", "管理收藏開這位玩家的收藏頁")
    m = menu(); t.core.placesAddMenu(m, 0, 300, 50, nil, t.core.placeAt(s, 300, 50))
    eq(m:find("UI_MinidoracatMiniMap_PlaceManage"), nil, "收藏圖標上的子選單不列管理收藏")
    t.core.toggleSearchWindow = nil
    eq(t.core.placeMenuTitle(0, t.core.placesState(0).places[2]), "UI_MinidoracatMiniMap_PlaceMenuOf|Barn",
        "父項帶這一筆的名稱")
    assert(t.core.placesRename(0, barn, "Abcdefghijklmnopqrstuvwxyz"))
    eq(t.core.placeMenuTitle(0, t.core.placesState(0).places[2]),
        "UI_MinidoracatMiniMap_PlaceMenuOf|Abcdefghijklmnopqrs...", "名稱超過 20 字截短")
end

print("test_places: ok")
