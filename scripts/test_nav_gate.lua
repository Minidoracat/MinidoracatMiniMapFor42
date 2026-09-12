-- Addon 導航閘門（registerNavGate／navGateAllows）、繪製閘門（drawNavTargets）與
-- 目標查詢（getNavTarget）離線回歸測試。
-- 真 _Itinerary.lua（行程權威／navSetTarget／到站／getNavTarget）與真 _Nav.lua
-- （gate 註冊表／繪製／編號站點／分享）依遊戲載入序載進同一沙箱＝跑 production
-- 本體，測試不再自備 navTargets 假權威。
-- 核心不變量（addon 是外部程式碼，錯得起但不能拖垮導航）：
--   * 零註冊＝放行（addon 不裝零影響）
--   * 多 gate 為 AND，且「明確回 false」才擋——忘了 return 不該讓導航靜默死掉
--   * gate 拋錯＝fail-open，且依 owner 每場只 log 一次（不得每幀刷屏）
--   * set 被擋＝回 (false, "blocked", 第一個擋阻者的 reasonKey)，且行程、modData、
--     分享通道一律不動；錯誤文字由 Core.navErrorText 決定（detailKey 優先），
--     gate 拋錯的訊息不得被當成 reasonKey 洩漏給玩家
--   * draw 被擋只擋導航層（路線／分享旗／行程站點）：搜尋 ping 照畫
--   * 繪製永不改狀態：站在目標上畫幾幀也不到站、不清目標；到站只由真 OnTick 產生
--   * getNavTarget 是純狀態讀取：槽位驗證從嚴、無活動站回 "notarget"、只交出純量
-- 用法：lua scripts/test_nav_gate.lua [_Nav.lua] [_Itinerary.lua]
local CLIENT = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
local navPath = arg[1] or (CLIENT .. "MinidoracatMiniMap_Nav.lua")
local itineraryPath = arg[2] or (CLIENT .. "MinidoracatMiniMap_Itinerary.lua")

local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return (text:gsub("\r\n", "\n"))
end
local navSource = readFile(navPath)
local itinerarySource = readFile(itineraryPath)
local compile = loadstring or load

--------------------------------------------------------------------------------
-- 沙箱：只把 PZ 全域換成假物件，兩個 production 檔原封不動執行
--------------------------------------------------------------------------------
local function fixture()
    local printed, packets, players, handlers, events = {}, {}, {}, {}, {}
    local client, shareAllowed = false, true
    local draws = { route = 0, ping = 0, rects = 0, routeFail = false, texts = {} }
    for _, name in ipairs({ "OnCreatePlayer", "OnGameStart", "OnTick", "OnServerCommand" }) do
        handlers[name] = {}
        events[name] = { Add = function(fn) handlers[name][#handlers[name] + 1] = fn end }
    end
    -- 主檔載入期一次性賦值的共用成員（_Nav.lua 在 chunk 頂端就取，須先備好）
    local core = {
        ready = true,
        policy = { readBool = function() return shareAllowed end },
        getBoolOption = function(_, default) return default end,
        clipSegment = function(x1, y1, x2, y2) return x1, y1, x2, y2 end,
        copyCoordsText = function() end,
    }
    local api = {}
    local textManager = {
        MeasureStringX = function(_, _, text) return #tostring(text) * 6 end,
        getFontHeight = function() return 12 end,
    }
    local env = setmetatable({
        MinidoracatMiniMapCore = core, MinidoracatMiniMapAPI = api, Events = events,
        ISMiniMapInner = {}, -- 無 onRightMouseUp＝小地圖右鍵 wrap 不安裝（本測試不涉）
        getSpecificPlayer = function(pn) return players[pn] end,
        isClient = function() return client end,
        getText = function(key) return "T:" .. tostring(key) end,
        getTextManager = function() return textManager end,
        getTimestampMs = function() return 0 end,
        UIFont = { Small = 1, Medium = 2 },
        sendClientCommand = function(_, _, command, args)
            packets[#packets + 1] = { command = command, args = args }
        end,
        print = function(msg) printed[#printed + 1] = tostring(msg) end,
    }, { __index = _G })
    local function run(source, name)
        local chunk
        if setfenv then
            chunk = assert(compile(source, name))
            setfenv(chunk, env)
        else
            chunk = assert(load(source, name, "t", env))
        end
        chunk()
    end
    run(itinerarySource, "itinerary") -- 同目錄字母序：_Itinerary（I）早於 _Nav（N）
    run(navSource, "nav")
    -- 其他檔擁有的繪製層（_NavRoute／_Search）在此以可觀測樁掛上
    core.drawNavRoute = function()
        draws.route = draws.route + 1
        if draws.routeFail then error("injected route failure") end
    end
    core.drawSearchPing = function() draws.ping = draws.ping + 1 end

    local function player(pn, username)
        local p = { x = 0, y = 0, md = {}, online = -1, name = username or ("p" .. pn) }
        function p:getModData() return self.md end
        function p:getVehicle() return self.vehicle end
        function p:getX() return self.x end
        function p:getY() return self.y end
        function p:isDead() return self.dead == true end
        function p:getOnlineID() return self.online end
        function p:getUsername() return self.name end
        function p:transmitModData() end
        players[pn] = p
        core.navLoadItinerary(pn)
        return p
    end
    -- 繪製表面：drawNavTargets 只要求 mapAPI 做世界→UI 轉換（此處恆等）＋繪製方法
    local function inner(pn)
        return {
            playerNum = pn or 0, width = 200, height = 200,
            mapAPI = {
                worldToUIX = function(_, wx) return wx end,
                worldToUIY = function(_, _, wy) return wy end,
            },
            drawRect = function() draws.rects = draws.rects + 1 end,
            drawRectBorder = function() end,
            drawLine = function() end,
            drawText = function(_, text) draws.texts[#draws.texts + 1] = tostring(text) end,
        }
    end
    return {
        core = core, api = api, printed = printed, packets = packets, draws = draws,
        player = player, inner = inner,
        client = function(v) client = v end,
        share = function(v) shareAllowed = v end,
        fire = function(event, ...)
            for _, fn in ipairs(handlers[event]) do fn(...) end
        end,
        resetDraws = function()
            draws.route, draws.ping, draws.rects, draws.routeFail = 0, 0, 0, false
            for i = #draws.texts, 1, -1 do draws.texts[i] = nil end
        end,
    }
end

local function eq(a, b, why) assert(a == b, why .. ": " .. tostring(a) .. " != " .. tostring(b)) end
local function trip(t, pn) return t.core.navItineraryState(pn or 0) end
local function edit(t, op, a, b, c, pn)
    pn = pn or 0
    local st = trip(t, pn)
    return t.core.navEditItinerary(pn, st and st.revision or 0, op, a, b, c)
end
local function start(t, pn)
    pn = pn or 0
    return t.api.startNavItinerary(pn, trip(t, pn).revision)
end
local function hasText(t, want)
    for _, text in ipairs(t.draws.texts) do
        if text == want then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- 一、註冊與判定（真 registerNavGate／navGateAllows）
--------------------------------------------------------------------------------
do
    local t = fixture()
    local API, Core = t.api, t.core
    local function reset() Core.navGates = {} end

    -- G1: 零註冊＝放行（addon 不裝零影響）
    eq(Core.navGateAllows(0, "set"), true, "G1 零 gate 放行 set")
    eq(Core.navGateAllows(0, "draw"), true, "G1 零 gate 放行 draw")

    -- G2: 引數驗證——owner 非空字串、gateFn 是 function；回 false、不進註冊表、各記一次 log
    local badCases = {
        { nil, function() end }, { "", function() end }, { 42, function() end },
        { "A", nil }, { "A", "nope" },
    }
    local logs = #t.printed
    for i = 1, #badCases do
        eq(API.registerNavGate(badCases[i][1], badCases[i][2]), false,
            "G2 壞引數須回 false（case " .. i .. "）")
    end
    eq(#Core.navGates, 0, "G2 壞引數不得進註冊表")
    eq(#t.printed - logs, #badCases, "G2 每次壞引數各記一次 log")

    -- G3: 合法註冊回 true；同 owner 重註冊＝覆蓋（不疊加）
    reset()
    local hits = {}
    eq(API.registerNavGate("A", function() hits[#hits + 1] = "old"; return true end), true,
        "G3 合法註冊回 true")
    eq(API.registerNavGate("A", function() hits[#hits + 1] = "new"; return true end), true,
        "G3 重註冊回 true")
    eq(#Core.navGates, 1, "G3 同 owner 重註冊須覆蓋")
    Core.navGateAllows(0, "set")
    eq(#hits, 1, "G3 覆蓋後只跑一個 fn")
    eq(hits[1], "new", "G3 跑的是新 fn")

    -- G4: 多 gate AND——全放行才放行，任一明確 false 即擋
    reset()
    API.registerNavGate("A", function() return true end)
    API.registerNavGate("B", function() return true end)
    eq(Core.navGateAllows(0, "set"), true, "G4 兩 gate 皆放行")
    API.registerNavGate("B", function() return false end)
    eq(Core.navGateAllows(0, "set"), false, "G4 任一 false 即擋")

    -- G5: 只有「明確 false」才擋（addon 忘了 return 不得讓導航靜默死掉）
    reset()
    API.registerNavGate("A", function() end)
    eq(Core.navGateAllows(0, "set"), true, "G5 回 nil 須放行")
    API.registerNavGate("A", function() return 0 end)
    eq(Core.navGateAllows(0, "set"), true, "G5 回非 false 真值須放行")

    -- G6: playerNum／context 原樣傳入（addon 靠 context 分「設目標」與「繪製」）
    reset()
    local seen = {}
    API.registerNavGate("A", function(pn, ctx) seen[#seen + 1] = tostring(pn) .. ":" .. tostring(ctx) end)
    Core.navGateAllows(2, "draw")
    Core.navGateAllows(0, "set")
    eq(seen[1], "2:draw", "G6 第一次原樣傳入")
    eq(seen[2], "0:set", "G6 第二次原樣傳入")

    -- G7: gate 拋錯＝fail-open，依 owner log-once；壞 gate 不得吃掉別人的擋阻
    reset()
    logs = #t.printed
    API.registerNavGate("Boom", function() error("injected gate failure") end)
    eq(Core.navGateAllows(0, "set"), true, "G7 拋錯須 fail-open")
    Core.navGateAllows(0, "set")
    Core.navGateAllows(0, "draw")
    eq(#t.printed - logs, 1, "G7 拋錯須 log-once")
    assert(t.printed[#t.printed]:find("nav gate error", 1, true), "G7 log 須指名 gate 錯誤")
    assert(t.printed[#t.printed]:find("Boom", 1, true), "G7 log 須含 owner")
    API.registerNavGate("Blocker", function() return false end)
    eq(Core.navGateAllows(0, "set"), false, "G7 壞 gate 不得吃掉擋阻")

    -- G8: 同 owner 重註冊須重置錯誤旗標（新 fn 的錯誤值得記一次新 log）
    logs = #t.printed
    API.registerNavGate("Boom", function() error("second failure") end)
    Core.navGateAllows(0, "set")
    eq(#t.printed - logs, 1, "G8 重註冊後新 fn 的錯誤須再記一次")

    -- G9: 第二回傳＝第一個擋阻者的 reasonKey；放行不得回髒值
    reset()
    API.registerNavGate("A", function() return false, "K1" end)
    local allowed, reason = Core.navGateAllows(0, "draw")
    eq(allowed, false, "G9 擋阻")
    eq(reason, "K1", "G9 帶回 reasonKey")
    reset()
    API.registerNavGate("A", function() return true, "K1" end)
    allowed, reason = Core.navGateAllows(0, "draw")
    eq(allowed, true, "G9 放行")
    eq(reason, nil, "G9 放行不得回 reasonKey")
    reset()
    API.registerNavGate("A", function() return true end)
    API.registerNavGate("B", function() return false, "KB" end)
    API.registerNavGate("C", function() return false, "KC" end)
    local _, firstKey = Core.navGateAllows(0, "set")
    eq(firstKey, "KB", "G9 短路回第一個擋阻者的鍵")
end

--------------------------------------------------------------------------------
-- 二、set 閘門接入真行程：拒絕不得改行程／不得靜默
--------------------------------------------------------------------------------
do
    local t = fixture()
    local API, Core = t.api, t.core
    local p = t.player(0)

    -- S1: 無 gate＝寫入單站行程、持久化、立即可查
    assert(Core.navSetTarget(0, 100, 200, "Depot"), "S1 無 gate 須成功")
    eq(trip(t).phase, "navigating", "S1 單站直接導航")
    eq(trip(t).count, 1, "S1 單站")
    eq(p.md.MinidoracatMiniMapItinerary.stops[1].x, 100, "S1 須存 modData")
    local gx, gy = API.getNavTarget(0)
    eq(gx, 100, "S1 查得目標 x")
    eq(gy, 200, "S1 查得目標 y")

    -- S2: set 被擋＝(false, blocked, reasonKey)，行程／modData 一律不動
    Core.navGates = {}
    API.registerNavGate("A", function(_, ctx) return ctx ~= "set", "UI_Addon_NeedGPS" end)
    local revision, stored = trip(t).revision, p.md.MinidoracatMiniMapItinerary
    local ok, reason, detail = Core.navSetTarget(0, 777, 888)
    eq(ok, false, "S2 被擋須回 false（不得回 nil）")
    eq(reason, "blocked", "S2 被擋理由")
    eq(detail, "UI_Addon_NeedGPS", "S2 帶回 addon 的 reasonKey")
    eq(trip(t).revision, revision, "S2 被擋不得改 revision")
    eq(p.md.MinidoracatMiniMapItinerary, stored, "S2 被擋不得動 modData")
    eq(API.getNavTarget(0), 100, "S2 被擋不得覆蓋既有目標")
    eq(Core.navGateAllows(0, "draw"), true, "S2 該 gate 只擋 set")
    eq(Core.navErrorText(reason, detail), "T:UI_Addon_NeedGPS", "S2 錯誤文字優先 detailKey")

    -- S3: 行程編輯同走 set 閘門，被擋不得加站
    local okEdit, whyEdit, detailEdit = edit(t, "append", 300, 400)
    eq(okEdit, false, "S3 append 被擋")
    eq(whyEdit, "blocked", "S3 append 理由")
    eq(detailEdit, "UI_Addon_NeedGPS", "S3 append 帶 reasonKey")
    eq(trip(t).count, 1, "S3 被擋不得加站")

    -- S4: gate 拋錯的訊息不得成為 reasonKey；退回 generic 行程錯誤鍵
    Core.navGates = {}
    API.registerNavGate("Boom", function() error("secret failure text") end)
    API.registerNavGate("Blocker", function() return false end)
    local _, whyBoom, detailBoom = Core.navSetTarget(0, 3, 4)
    eq(whyBoom, "blocked", "S4 仍被擋")
    eq(detailBoom, nil, "S4 錯誤訊息不得成為 reasonKey")
    eq(Core.navErrorText(whyBoom, detailBoom), "T:UI_MinidoracatMiniMap_TripError_blocked",
        "S4 無 detailKey 退回 generic 行程錯誤鍵")

    -- S5: 無玩家＝(false, noplayer)，不問 gate、不建槽位
    Core.navGates = {}
    local probed = 0
    API.registerNavGate("A", function() probed = probed + 1; return true end)
    local okNo, whyNo = Core.navSetTarget(3, 1, 2)
    eq(okNo, false, "S5 無玩家須回 false")
    eq(whyNo, "noplayer", "S5 無玩家理由")
    eq(probed, 0, "S5 無玩家不得呼叫 gate")
    eq(trip(t, 3), nil, "S5 無玩家不得建行程")
    local noneX, noneWhy = API.getNavTarget(3)
    eq(noneX, nil, "S5 空槽位無目標")
    eq(noneWhy, "notarget", "S5 空槽位回 notarget")
    eq(trip(t, 3), nil, "S5 查詢不得建出槽位條目")

    -- S6: 放行成功＝不帶錯誤理由，且新目標立刻生效
    Core.navGates = {}
    local okSet, reasonSet = Core.navSetTarget(0, 42, 43)
    eq(okSet, true, "S6 放行須回 true")
    eq(reasonSet, "ok", "S6 成功不帶錯誤理由")
    eq(API.getNavTarget(0), 42, "S6 新目標立刻生效")
end

--------------------------------------------------------------------------------
-- 三、分享通道：目標變更撤回分享，後續站編輯不重播
--------------------------------------------------------------------------------
do
    local t = fixture()
    t.client(true)
    local p = t.player(0, "Alice")
    p.online = 7
    assert(t.core.navSetTarget(0, 120, 130), "H0 前置寫入")
    t.core.navShareTarget(0)
    eq(#t.packets, 1, "H1 分享須送封包")
    eq(t.packets[1].command, "shareTarget", "H1 分享封包名")
    assert(t.core.navSetTarget(0, 140, 150), "H2 換目標")
    eq(t.packets[#t.packets].command, "clearShared", "H2 目標變更須撤回分享")
    local sent = #t.packets
    assert(edit(t, "append", 400, 400), "H3 加後續站")
    eq(#t.packets, sent, "H3 後續站編輯不得動分享通道")
end

--------------------------------------------------------------------------------
-- 四、繪製閘門與「繪製永不改狀態」
--------------------------------------------------------------------------------
do
    local t = fixture()
    local API, Core = t.api, t.core
    t.client(true)
    local p = t.player(0, "Alice")
    assert(edit(t, "append", 30, 30, "First"), "D0 第一站")
    assert(edit(t, "append", 60, 60, "Second"), "D0 第二站")
    assert(API.setNavContinuation(0, trip(t).revision, false), "D0 明確驗逐點手動到站")
    assert(start(t), "D0 出發")
    t.fire("OnServerCommand", "MinidoracatMiniMap", "sharedTarget",
        { author = "Bob", to = "Alice", x = 90, y = 90 })
    local inner = t.inner(0)

    -- D1: 放行＝路線層、分享旗、搜尋 ping、編號站點全畫
    t.resetDraws()
    Core.drawNavTargets(inner)
    eq(t.draws.route, 1, "D1 放行須畫路線層")
    eq(t.draws.ping, 1, "D1 須畫搜尋 ping")
    assert(hasText(t, "Bob"), "D1 須畫分享者旗標")
    assert(hasText(t, "127m"), "D1 分享旗須帶距離")
    assert(hasText(t, "1/2"), "D1 目前站須畫 目前/總數")
    assert(hasText(t, "2"), "D1 未到站須畫編號")

    -- D2: draw 被擋＝導航層全不畫，搜尋 ping 照畫，狀態一律不動
    Core.navGates = {}
    API.registerNavGate("A", function(_, ctx) return ctx ~= "draw" end)
    local revision, stored = trip(t).revision, p.md.MinidoracatMiniMapItinerary
    t.resetDraws()
    Core.drawNavTargets(inner)
    eq(t.draws.route, 0, "D2 被擋不得畫路線層（連 A* 都不該算）")
    eq(#t.draws.texts, 0, "D2 被擋不得畫分享旗／站點")
    eq(t.draws.ping, 1, "D2 搜尋 ping 不屬導航層，被擋仍須畫")
    eq(trip(t).revision, revision, "D2 繪製不得改 revision")
    eq(p.md.MinidoracatMiniMapItinerary, stored, "D2 繪製不得寫 modData")

    -- D3: 站在目標上，放行或被擋都不得到站、不得清目標；到站只由真 OnTick 產生
    p.x, p.y = 30, 30
    t.resetDraws()
    Core.drawNavTargets(inner)
    Core.navGates = {}
    Core.drawNavTargets(inner)
    Core.drawNavTargets(inner)
    eq(trip(t).phase, "navigating", "D3 繪製不得到站")
    eq(trip(t).stops[1].status, "pending", "D3 繪製不得推進站點")
    assert(Core.navGetTarget(0) ~= nil, "D3 繪製不得清目標")
    t.fire("OnTick")
    eq(trip(t).phase, "waiting", "D3 真 tick 才到站")
    eq(trip(t).stops[1].status, "arrived", "D3 到站記在站點上")
    eq(API.getNavTarget(0), nil, "D3 等待中不提前暴露下一站")

    -- D4: 路線層拋錯＝fail-open 續畫站點，且依實例 log-once
    assert(start(t), "D4 前往第二站")
    t.resetDraws()
    t.draws.routeFail = true
    local logs = #t.printed
    Core.drawNavTargets(inner)
    Core.drawNavTargets(inner)
    eq(#t.printed - logs, 1, "D4 路線錯誤須 log-once")
    assert(t.printed[#t.printed]:find("nav route draw failed", 1, true),
        "D4 log 須指名路線繪製失敗")
    assert(hasText(t, "2/2"), "D4 路線壞掉不得連坐站點繪製")

    -- D5: 行程清空＝站點層不畫，分享旗與搜尋 ping 仍照畫（無行程不得吃掉其他層）
    t.draws.routeFail = false
    assert(edit(t, "clear"), "D5 清空行程")
    t.resetDraws()
    Core.drawNavTargets(inner)
    eq(trip(t), nil, "D5 行程已清空")
    assert(hasText(t, "Bob"), "D5 分享旗不受行程清空影響")
    assert(not hasText(t, "2/2"), "D5 清空後不得再畫站點")
    eq(t.draws.ping, 1, "D5 無行程時搜尋 ping 仍須畫")
end

--------------------------------------------------------------------------------
-- 五、getNavTarget 查詢面（唯讀、從嚴、只交出純量）
--------------------------------------------------------------------------------
do
    local t = fixture()
    local API, Core = t.api, t.core
    -- Q1: 四槽分割畫面各讀自己的活動站
    for pn = 0, 3 do
        t.player(pn)
        assert(Core.navSetTarget(pn, pn * 10, pn * 10 + 1), "Q1 槽位 " .. pn .. " 前置寫入")
    end
    for pn = 0, 3 do
        local gx, gy = API.getNavTarget(pn)
        eq(gx, pn * 10, "Q1 槽位 " .. pn .. " x")
        eq(gy, pn * 10 + 1, "Q1 槽位 " .. pn .. " y")
    end

    -- Q2: 型別／NaN／±Infinity／非整數／越界一律 badargs（壞槽位會靜靜讀到別人的槽）
    local badPn = { -1, 4, 100, "0", true, {}, 1.5, -0.5, 0 / 0, math.huge, -math.huge }
    for i = 1, #badPn do
        local gx, why = API.getNavTarget(badPn[i])
        assert(gx == nil and why == "badargs", "Q2 壞 playerNum 須 badargs（case " .. i .. "）")
    end
    local nilX, nilWhy = API.getNavTarget(nil)
    assert(nilX == nil and nilWhy == "badargs", "Q2 nil playerNum 須 badargs")

    -- Q3: 無活動站（暫停）＝notarget，行程本身仍在
    assert(Core.navPauseItinerary(0, "manual"), "Q3 暫停")
    local pausedX, pausedWhy = API.getNavTarget(0)
    assert(pausedX == nil and pausedWhy == "notarget", "Q3 暫停須回 notarget")
    eq(trip(t).count, 1, "Q3 暫停不刪行程")

    -- Q4: 只交出純量，改回傳值不影響內部狀態；讀取即時反映新目標
    local ix, iy = API.getNavTarget(1)
    assert(type(ix) == "number" and type(iy) == "number", "Q4 兩回傳須皆為 number")
    ix, iy = -999, -888
    eq(API.getNavTarget(1), 10, "Q4 改回傳值不得影響內部狀態")
    assert(Core.navSetTarget(1, 555, 666), "Q4 改寫目標")
    local sx, sy = API.getNavTarget(1)
    eq(sx, 555, "Q4 即時反映新目標 x")
    eq(sy, 666, "Q4 即時反映新目標 y")
end

print("test_nav_gate: OK（註冊/判定 G1-G9＋set 閘門 S1-S6＋分享撤回 H1-H3"
    .. "＋繪製閘門與繪製唯讀 D1-D5＋getNavTarget Q1-Q4）")
