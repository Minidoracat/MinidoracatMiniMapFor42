-- 手繪線分享離線回歸：伺服器（server/MinidoracatMiniMapSketchShare.lua：每位作者一個檔、索引、收件人、
-- 對帳、快照跨 tick、上限、限速、沙盒、nil args、十六進位檔名）＋客戶端（client/MinidoracatMiniMap_SketchShare.lua：
-- 佇列、to 分桶、快照收齊才替換、收齊前的即時事件不丟）。伺服器送出的封包直接餵給客戶端處理器，
-- 客戶端送出的照引擎把空表改成 nil 再餵給伺服器。alice、bob 同陣營，carol 圈外，dave 和 alice 同一間安全屋。
-- 為了一個客戶端模擬多台電腦，客戶端的 pn 1～3 在伺服器看起來是各自電腦的主座位（srv：getPlayerNum＝0）；
-- 真的分割畫面座位（seat＝true）伺服器看到 getPlayerNum ~= 0、沒有身分（MinidoracatMiniMapGroups.principal）。
-- 用法：lua scripts/test_sketch_share.lua
local H = dofile("scripts/sketch_harness.lua")

local function jlist(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end,
        contains = function(_, v) for i = 1, #t do if t[i] == v then return true end end return false end }
end
local factions = { { name = "blue", owner = "alice", players = { "bob" } } }
local houses = { { owner = "dave", players = { "alice" } } }
local function member(g, name)
    if g.owner == name then return true end
    for i = 1, #g.players do if g.players[i] == name then return true end end
    return false
end
Faction = { getPlayerFaction = function(name)
    for i = 1, #factions do
        local f = factions[i]
        if member(f, name) then
            return { getName = function() return f.name end, getOwner = function() return f.owner end,
                getPlayers = function() return jlist(f.players) end }
        end
    end
    return nil
end }
SafeHouse = {
    isInSameSafehouse = function(a, b)
        for i = 1, #houses do if member(houses[i], a) and member(houses[i], b) then return true end end
        return false
    end,
    getSafehouseList = function() return jlist({}) end,
    hasSafehouse = function() return nil end,
}
H.policyOn = true
MinidoracatMiniMapPolicy = { readBool = function(name, d)
    if name == "AllowSketchShare" then return H.policyOn end
    return d
end }

local Core = H.boot({ server = true, share = true, tool = false, client = true })
Core.policy = MinidoracatMiniMapPolicy
local SK, SS, SH, C, check = H.SK, H.SS, Core.SketchShare, MinidoracatMiniMapSketchCodec, H.check

local alice, bob, carol, dave = H.player("alice", 0), H.player("bob", 1), H.player("carol"), H.player("dave")
local online = { alice, bob, carol, dave }
local srvOf = {}
local function srv(p)
    if p.seat then return p end
    local v = srvOf[p]
    if not v then
        v = { getUsername = function() return p.name end, getPlayerNum = function() return 0 end }
        srvOf[p] = v
    end
    return v
end
function getOnlinePlayers()
    local list = {}
    for i = 1, #online do list[i] = srv(online[i]) end
    return jlist(list)
end
local function setOnline(list) online = list end

-- 網路：客戶端 → 伺服器（空表變 nil，GameClient.java:1837）；伺服器 → 客戶端（記下每一包）
local toServer, toClient = {}, {}
function sendClientCommand(p, module, command, args)
    toServer[#toServer + 1] = { from = p:getUsername(), command = command, args = args }
    if type(args) == "table" and next(args) == nil then args = nil end
    for _, fn in ipairs(H.handlers.OnClientCommand) do fn(module, command, srv(p), args) end
end
function sendServerCommand(target, module, command, args)
    toClient[#toClient + 1] = { to = target:getUsername(), command = command, args = args }
    for _, fn in ipairs(H.handlers.OnServerCommand or {}) do fn(module, command, args) end
end
local function sentTo(name, command, from)
    local out = {}
    for i = (from or 0) + 1, #toClient do
        local m = toClient[i]
        if m.to == name and (not command or m.command == command) then out[#out + 1] = m end
    end
    return out
end
local function clientSent(command, from)
    local out = {}
    for i = (from or 0) + 1, #toServer do
        if toServer[i].command == command then out[#out + 1] = toServer[i] end
    end
    return out
end
local function tick(ms)
    H.now = H.now + (ms or 100)
    H.fire("OnTick")
    H.fire("OnTickEvenPaused")
end
local function settle(seconds)
    for _ = 1, (seconds or 3) * 10 do tick(100) end
end
local function draw(pn, pts, share)
    local s = assert(SK.newStroke(pn, { c = 3, w = 2, z = 17, share = share }, pts, #pts / 2))
    assert(SK.apply(pn, {}, 0, { s }, 1))
    return s
end
local function recvCount(pn)
    local slot = SK.slots[pn]
    return slot and slot.recvN or 0
end

-- 登入：兩位本機玩家。照引擎順序：先 OnCreatePlayer（GameLoadingState.java:429）、進遊戲才 OnGameStart
-- （IngameState.java:766）；OnGameStart 清掉狀態後仍要送出登入對帳（2026-11-08 share-sketch-mp 場 3 實機）
H.players[0], H.players[1] = alice, bob
H.fire("OnCreatePlayer", 0)
H.fire("OnCreatePlayer", 1)
H.fire("OnGameStart")
settle(2)
local syncs = clientSent("skSync")
check(#syncs == 2 and syncs[1].args.origin ~= nil and syncs[1].args.ids == "", "Y1 登入後各送一次 skSync（帶來源碼與空清單）")
check(#sentTo("alice", "skSnap") == 1 and #sentTo("bob", "skSnap") == 1, "Y2 各收到一份（空）快照")

-- 分享的筆送上伺服器、存檔、即時給同陣營的 bob；carol 收不到；私人的不送
local mark = #toClient
local s1 = draw(0, { 0, 0, 10, 0 }, true)
draw(0, { 0, 5, 10, 5 }, false)
settle(3)
local pushes = clientSent("skPush")
check(#pushes == 1 and #pushes[1].args.adds == 1 and pushes[1].args.dels == nil, "P1 只送分享的那一筆")
local hexA = C.hexName("alice")
local fileA = "MinidoracatMiniMap/sketch/w1/" .. hexA .. ".txt"
check(H.files[fileA] and H.files[fileA]:find("S\t" .. C.lid(SK.slots[0].store.origin, s1.id), 1, true)
    and H.files["MinidoracatMiniMap/sketch/w1/index.txt"]:find("A\t" .. hexA .. "\talice", 1, true),
    "P2 伺服器寫作者檔與索引")
check(#sentTo("bob", "skAdd", mark) == 1 and recvCount(1) == 1, "P3 同陣營的 bob 即時收到")
check(#sentTo("carol", nil, mark) == 0, "P4 圈外的 carol 收不到")
check(#sentTo("dave", "skAdd", mark) == 1, "P5 同安全屋的 dave 收到")
check(#sentTo("alice", "skAdd", mark) == 0, "P6 作者自己不收")

-- 擦除同步：作者擦掉＝收回（bob 那邊消失），切出的片段照樣分享
mark = #toClient
local rem, nr, add, na = SK.eraseAt(0, 5, 0, 1)
SK.apply(0, rem, nr, add, na)
settle(3)
local last = clientSent("skPush")[#clientSent("skPush")]
check(nr == 1 and na == 2 and #last.args.dels == 1 and #last.args.adds == 2, "E1 擦中間：一刪兩加")
check(#sentTo("bob", "skDel", mark) == 1 and recvCount(1) == 2, "E2 bob 那邊原筆消失、兩段出現")

-- 離線補收：bob 離線時 alice 畫的線，bob 上線補收
H.players[1] = nil
setOnline({ alice, carol, dave })
tick()
local s3 = draw(0, { 20, 20, 30, 30 }, true)
settle(3)
H.players[1] = bob
setOnline({ alice, bob, carol, dave })
SK.slots[1] = nil
H.fire("OnCreatePlayer", 1)
settle(2)
check(recvCount(1) == 3, "O1 bob 上線補收離線時畫的線（共 3 筆）")

-- 對帳：伺服器有、作者清單沒有的刪掉（作者離線時擦掉的），並通知 bob
mark = #toClient
do
    local store = SK.slots[0].store
    local i = SK.indexOf(store, s3.id)
    SK.removeAt(store, i) -- 不經 apply：模擬離線時擦掉、撤回沒送出
    SH.q[0] = nil
    SH.requestSync(0)
    SS.lastSync.alice = nil
    settle(2)
end
check(not H.files[fileA]:find(":" .. s3.id .. "\t", 1, true) and #sentTo("bob", "skDel", mark) == 1 and recvCount(1) == 2,
    "K1 對帳刪掉離線時擦掉的筆，bob 跟著消失")

-- 對帳：清單有、伺服器沒有的回 skNeed，客戶端補送
do
    local s4 = draw(0, { 40, 40, 50, 50 }, true)
    SH.q[0] = nil -- 這一包沒送到
    mark = #toClient
    SS.lastSync.alice = nil
    SH.requestSync(0)
    settle(4)
    check(#sentTo("alice", "skNeed", mark) == 1 and H.files[fileA]:find(":" .. s4.id .. "\t", 1, true), "K2 skNeed 要回缺的筆")
end

-- 每位作者上限：超過就 skFail limit，提示一次
do
    mark = #toClient
    H.messages = {}
    local pts = {}
    for k = 1, 500 do pts[#pts + 1] = 1000 + k; pts[#pts + 1] = 0 end
    for _ = 1, 21 do draw(0, pts, true) end
    settle(30)
    check(#sentTo("alice", "skFail", mark) >= 1 and H.messages[1] == "UI_MinidoracatMiniMap_SketchShareWhy_limit",
        "L1 超過每人 10,000 點：伺服器拒收並提示")
    local data = C.decodeAuthor((function()
        local out = {}
        for l in (H.files[fileA] .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l end
        return out, #out
    end)())
    check(data and data.points <= C.SHARE_MAX_POINTS, "L2 伺服器檔沒超過上限")
    local n, pts = Core.SketchShare.sharedTotals(0)
    check(pts <= C.SHARE_MAX_POINTS and Core.sketchShareRoom(0, 501) == false,
        "L3 伺服器拒收的筆本機改成私人（本機分享 " .. pts .. " 點），之後放不下的照樣私人")
end

-- 限速：同一秒第二包回 rate，客戶端對帳一次補齊
do
    SS.lastPush.alice = H.now
    mark = #toClient
    SS.Commands.skPush(alice, { dels = { "abcdef12:999" } }, "alice")
    check(sentTo("alice", "skFail", mark)[1].args.reason == "rate" and SH.syncAt[0] ~= nil, "Z1 限速：回 rate、客戶端排對帳")
end

-- nil args：skSync 不帶參數照樣回快照（不刪任何東西）
do
    mark = #toClient
    SS.lastSync.bob = nil
    sendClientCommand(bob, "MinidoracatMiniMapSketch", "skSync", {})
    check(#sentTo("bob", "skSnap", mark) >= 1, "N1 args 是 nil 當空表")
end

-- 白名單：壞封包整包拒收
do
    mark = #toClient
    SS.lastPush.alice = nil
    SS.Commands.skPush(alice, { adds = { { id = "abcdef12:5", c = "1", w = "1", z = "17", p = "1,2", a = "eve" } } }, "alice")
    SS.lastPush.alice = nil
    SS.Commands.skPush(alice, { adds = "x" }, "alice")
    local fails = sentTo("alice", "skFail", mark)
    check(#fails == 2 and fails[1].args.reason == "invalid" and fails[2].args.reason == "invalid", "V1 壞封包回 invalid")
end

-- 快照跨 tick：第一批當場送，其餘每 tick 一批；收齊前收到的即時事件收齊後照套
do
    SS.SNAP_CHARS = 200
    SS.lastSync.bob = nil
    mark = #toClient
    SS.Commands.skSync(srv(bob), {}, "bob")
    local parts = sentTo("bob", "skSnap", mark)
    local total = parts[1] and parts[1].args.parts or 0
    check(total > 3 and #parts == 1, "Q1 快照分 " .. total .. " 批，當場只送第一批")
    -- 收齊前 alice 又畫一筆，bob 先收到即時 skAdd
    SS.lastPush.alice = nil
    local before = recvCount(1)
    SS.Commands.skPush(alice, { adds = { C.toWire("abcdef12", { id = 77, c = 1, w = 1, z = 17, pts = { 1, 1 }, np = 1 }) } },
        "alice")
    check(recvCount(1) == before, "Q2 收齊前的即時事件先存著")
    for _ = 1, total + 2 do tick(16) end
    local snap = SK.slots[1].recv.alice
    check(snap and snap["abcdef12:77"] ~= nil, "Q3 收齊替換後再套即時事件，不丟")
    SS.SNAP_CHARS = 24000
end

-- 沙盒 AllowSketchShare=false：新增拒收、撤回照做、快照變空（收到的清掉）、工具不能選分享
do
    H.policyOn = false
    check(Core.sketchShareAvailable(0) == false, "D1 沙盒關：不能分享")
    mark = #toClient
    SS.lastPush.alice = nil
    SS.Commands.skPush(alice, { adds = { C.toWire("abcdef12", { id = 78, c = 1, w = 1, z = 17, pts = { 1, 1 }, np = 1 }) },
        dels = { "abcdef12:77" } }, "alice")
    check(sentTo("alice", "skFail", mark)[1].args.reason == "disabled" and not H.files[fileA]:find("abcdef12:78", 1, true)
        and not H.files[fileA]:find("abcdef12:77", 1, true), "D2 新增拒收、撤回照做")
    settle(3) -- 客戶端發現可用性變了 → 對帳 → 空快照
    check(recvCount(1) == 0, "D3 沙盒關：bob 收到的清掉")
    H.policyOn = true
    settle(3)
    check(recvCount(1) > 0, "D4 沙盒再開：對帳補回")
end

-- 伺服器重開：從檔案讀回
do
    local n = SS.authors.alice.count
    SS.dir, SS.authors, SS.names, SS.nNames = nil, {}, {}, 0
    SS.ensure()
    check(SS.authors.alice and SS.authors.alice.count == n and SS.nNames == 1, "S1 伺服器重開後讀回作者檔與索引")
end

-- 帳號含控制字元與冒號：十六進位檔名無損，不和別人撞名
do
    local weird = H.player("ev:e\1", nil)
    SS.lastPush[weird:getUsername()] = nil
    SS.Commands.skPush(weird, { adds = { C.toWire("abcdef12", { id = 1, c = 1, w = 1, z = 17, pts = { 1, 1 }, np = 1 }) } },
        "ev:e\1")
    local hex = C.hexName("ev:e\1")
    check(H.files["MinidoracatMiniMap/sketch/w1/" .. hex .. ".txt"] ~= nil and hex ~= C.hexName("ev_e\1"),
        "F1 帳號 ev:e\\1 寫成十六進位檔名")
    SS.dir = nil
    SS.ensure()
    check(SS.authors["ev:e\1"] and SS.authors["ev:e\1"].count == 1, "F2 重開後從索引讀回原帳號")
end

-- 帳號檔還在載入：等載完才對帳（清單不完整會讓伺服器刪掉還在的筆）
do
    local erin = H.player("erin", 2)
    local big = { nextId = 601, origin = "abcdef99", count = 600, strokes = {} }
    for i = 1, 600 do
        big.strokes[i] = { id = i, c = 1, w = 1, z = 17, share = i <= 2, pts = { i, 0 }, np = 1 }
    end
    H.files["MinidoracatMiniMap/sketch/Sandbox/w1_p2.txt"] = C.encodeStore(big)
    H.players[2] = erin
    online[#online + 1] = erin
    H.autoMs = 2
    H.fire("OnCreatePlayer", 2)
    local first
    for _ = 1, 2000 do -- 每讀一次時鐘過 2 ms＝每 tick 只做一筆（解碼或準備），1200 筆
        tick(100)
        for i = 1, #toServer do
            if toServer[i].from == "erin" and toServer[i].command == "skSync" then first = toServer[i] break end
        end
        if first then break end
    end
    H.autoMs = 0
    check(first and first.args and first.args.ids == "1,2" and first.args.origin == "abcdef99",
        "Y3 帳號檔載完才對帳（清單完整）")
end

-- ====== 2026-11-08 審查第 1 輪修正 ======
local MOD = "MinidoracatMiniMapSketch"
local DIR = "MinidoracatMiniMap/sketch/w1/"
local function ptsN(n, x0)
    local p = {}
    for k = 1, n do p[#p + 1] = (x0 or 0) + k; p[#p + 1] = 7 end
    return p
end
local function wire(origin, id, n, x0)
    return C.toWire(origin, { id = id, c = 1, w = 1, z = 17, pts = ptsN(n, x0), np = n })
end
local function push(p, args)
    SS.lastPush[p.name] = nil
    SS.Commands.skPush(srv(p), args, p.name)
end
local function decodeFile(path)
    local out = {}
    for l in (H.files[path] .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l end
    return C.decodeAuthor(out, #out)
end
local gina = H.player("gina")
factions[1].players[#factions[1].players + 1] = "gina"
online[#online + 1] = gina

-- 1b. 分割畫面第 2～4 位（伺服器 getPlayerNum ~= 0）沒有身分：分享拒（identity）、對帳不回、不當收件人
do
    local frank = H.player("frank", 1)
    frank.seat = true
    factions[1].players[#factions[1].players + 1] = "frank" -- 填了不在線陣營成員的名字
    online[#online + 1] = frank
    local mark = #toClient
    SS.lastPush.frank = nil
    sendClientCommand(frank, MOD, "skPush", { adds = { wire("abcdef55", 1, 2) } })
    local f = sentTo("frank", "skFail", mark)
    check(#f == 1 and f[1].args.reason == "identity" and H.files[DIR .. C.hexName("frank") .. ".txt"] == nil,
        "I1 分割畫面座位分享回 identity、伺服器不存")
    mark = #toClient
    SS.lastSync.frank = nil
    sendClientCommand(frank, MOD, "skSync", {})
    check(#sentTo("frank", nil, mark) == 0, "I2 分割畫面座位對帳不回（收不到快照）")
    mark = #toClient
    push(gina, { adds = { wire("abcdef66", 1, 2) } })
    check(#sentTo("bob", "skAdd", mark) == 1 and #sentTo("frank", nil, mark) == 0, "I3 即時轉送不送給分割畫面座位")
    local q = { player = frank, name = "frank", seq = 999, parts = { {} }, next = 1 }
    check(SS.sendPart(q) == false, "I4 快照批次給沒有身分的收件人：取消")
    check(Core.sketchShareAvailable(1) == false and select(2, Core.sketchShareAvailable(1))
        == "UI_MinidoracatMiniMap_SketchShareWhy_identity", "I5 客戶端第 2～4 位不能選分享，說原因")
end

-- 2. 同 lid 換成更長的筆也要算上限
do
    local hank = H.player("hank")
    online[#online + 1] = hank
    local o = "abcdef77"
    for b = 0, 3 do
        local adds = {}
        for k = 1, 5 do adds[k] = wire(o, b * 5 + k, b * 5 + k <= 19 and 500 or 300) end
        if b == 3 then adds[5] = wire(o, 20, 300) end
        push(hank, { adds = adds })
    end
    push(hank, { adds = { wire(o, 21, 150) } }) -- 19×500＋300＋150＝9,950
    local mark = #toClient
    push(hank, { adds = { wire(o, 20, 400) } }) -- 換長：10,050
    local f = sentTo("hank", "skFail", mark)
    local data = decodeFile(DIR .. C.hexName("hank") .. ".txt")
    check(#f == 1 and f[1].args.reason == "limit" and f[1].args.ids and f[1].args.ids[1] == o .. ":20"
        and data and data.points == 9950, "M1 同 lid 換成更長超過上限：拒收、回 lid、檔照樣讀得回")
end

-- 2b. 伺服器因上限拒收（含同 lid 換長、伺服器保留舊版）：客戶端轉私人並撤回，伺服器與收件端一起刪
do
    local st = SK.slots[0].store
    local target
    for i = 1, st.count do if st.strokes[i].share then target = st.strokes[i] end end
    local lid = C.lid(st.origin, target.id)
    check(SS.posMap(SS.authors.alice)[lid] ~= nil and SK.slots[1].recv.alice and SK.slots[1].recv.alice[lid] ~= nil,
        "M2 前提：伺服器與 bob 都有這筆")
    SH.handlers.skFail(0, { reason = "limit", ids = { lid } })
    SS.lastPush.alice = nil
    settle(3)
    check(target.share == false and not SS.posMap(SS.authors.alice)[lid] and not SK.slots[1].recv.alice[lid],
        "M3 轉私人同時撤回：本機私人、伺服器與 bob 都刪掉")
end

-- 3. 伺服器讀檔：主檔壞＋備份較新＝只讀；索引壞＝只讀；索引沒有、檔卻在＝不覆寫（三種原檔位元組都不變）
do
    local idx = DIR .. "index.txt"
    local keepIdx = H.files[idx]
    local names = {}
    for i = 1, SS.nNames do names[i] = SS.names[i] end
    names[#names + 1] = "ivan"
    H.files[idx] = C.encodeIndex(#names, names)
    local pIvan = DIR .. C.hexName("ivan") .. ".txt"
    local newer = "MMSKSRV\t99\nEND\t0"
    newer = (C.encodeAuthor(0, {}):gsub("\t%d+\n", "\t99\n", 1))
    H.files[pIvan] = "garbage"
    H.files[(pIvan:gsub("%.txt$", ".bak.txt"))] = newer
    SS.dir = nil
    SS.ensure()
    local ivan = H.player("ivan")
    local mark = #toClient
    push(ivan, { adds = { wire("abcdef88", 1, 2) } })
    check(SS.authors.ivan.ro == true and sentTo("ivan", "skFail", mark)[1].args.reason == "readonly"
        and H.files[pIvan] == "garbage" and H.files[(pIvan:gsub("%.txt$", ".bak.txt"))] == newer,
        "R1 作者主檔壞＋備份較新：只讀，兩份不動")
    H.files[idx] = "garbage"
    H.files[(idx:gsub("%.txt$", ".bak.txt"))] = "garbage"
    SS.dir = nil
    SS.ensure()
    local jack = H.player("jack")
    mark = #toClient
    push(jack, { adds = { wire("abcdef89", 1, 2) } })
    check(SS.indexRo == true and sentTo("jack", "skFail", mark)[1].args.reason == "readonly" and H.files[idx] == "garbage"
        and H.files[DIR .. C.hexName("jack") .. ".txt"] == nil, "R2 索引壞：只讀，不會重寫成只剩新作者")
    H.files[idx] = keepIdx
    H.files[(idx:gsub("%.txt$", ".bak.txt"))] = keepIdx
    SS.dir = nil
    SS.ensure()
    local pKate = DIR .. C.hexName("kate") .. ".txt"
    local orphan = C.encodeAuthor(1, { { id = "abcdef90:1", c = "1", w = "1", z = "17", p = "4,4" } })
    H.files[pKate] = orphan
    local kate = H.player("kate")
    mark = #toClient
    push(kate, { adds = { wire("abcdef90", 2, 2) } })
    check(sentTo("kate", "skFail", mark)[1].args.reason == "readonly" and H.files[pKate] == orphan
        and H.files[idx] == keepIdx, "R3 索引沒有、作者檔卻在：不覆寫")
end

-- 4. 一包 2,000 個刪除對 1,000 筆：先建表、一趟壓縮（逐筆線性找是百萬次比較）
do
    local liam = H.player("liam")
    local o = "abcdef91"
    for b = 0, 4 do
        local adds = {}
        for k = 1, 200 do adds[k] = wire(o, b * 200 + k, 1) end
        push(liam, { adds = adds })
    end
    local t0 = os.clock()
    for r = 1, 5 do
        local dels = {}
        for k = 1, 2000 do dels[k] = o .. ":" .. (100000 * r + k) end
        dels[2000] = o .. ":" .. r -- 真的刪一筆
        dels[1999] = o .. ":" .. r -- 重複
        push(liam, { dels = dels })
    end
    local dt = os.clock() - t0
    check(SS.authors.liam.count == 995, "C1 刪除去重：1,000 筆刪掉 5 筆")
    check(dt < 0.08, string.format("C2 5 包 × 2,000 刪除對 1,000 筆 %.3f 秒（< 0.08）", dt))
end

-- 5. 快照分批之間權限變了：取消佇列
do
    SS.SNAP_CHARS = 30
    SS.lastSync.bob = nil
    local mark = #toClient
    SS.Commands.skSync(srv(bob), {}, "bob")
    local first = sentTo("bob", "skSnap", mark)
    H.policyOn = false
    SS.tick()
    check(#first == 1 and first[1].args.parts > 2 and #sentTo("bob", "skSnap", mark) == 1 and SS.queue.bob == nil,
        "Q4 第一批之後沙盒關掉：後面幾批不送")
    H.policyOn = true
    SS.lastSync.bob = nil
    mark = #toClient
    SS.Commands.skSync(srv(bob), {}, "bob")
    local keep = factions[1].players
    factions[1].players = { "gina", "frank", "hank", "liam" }
    SS.tick()
    check(#sentTo("bob", "skSnap", mark) == 1 and SS.queue.bob == nil, "Q5 第一批之後退出陣營：後面幾批不送")
    factions[1].players = keep
    SS.SNAP_CHARS = 24000
    SS.lastSync.bob = nil
    SS.Commands.skSync(srv(bob), {}, "bob")
    for _ = 1, 5 do tick(16) end
end

-- 6. 同一包同 lid 既刪又加：伺服器先刪後加，轉送也先 skDel 再 skAdd，三方一致
do
    local lid = "abcdef66:1"
    local mark = #toClient
    push(gina, { dels = { lid }, adds = { wire("abcdef66", 1, 3, 50) } })
    local seq = {}
    for i = mark + 1, #toClient do
        if toClient[i].to == "bob" then seq[#seq + 1] = toClient[i].command end
    end
    local file = decodeFile(DIR .. C.hexName("gina") .. ".txt")
    local got = SK.slots[1].recv.gina and SK.slots[1].recv.gina[lid]
    check(seq[1] == "skDel" and seq[2] == "skAdd" and file and file.count == 1 and file.strokes[1].np == 3
        and got and got.np == 3, "O2 同 lid 先刪後加：伺服器、轉送順序、收件端都是新的那筆")
end

-- 7. 分享名額滿時擦除：片段超過名額改私人、原筆照樣撤回；對帳清單超過分享上限也照樣對帳
do
    -- mona 在客戶端是 pn 3，模擬另一台電腦的主座位：客戶端的分割畫面限制對她放行
    local realAvail = Core.sketchShareAvailable
    Core.sketchShareAvailable = function(pn) if pn == 3 then return true end return realAvail(pn) end
    local mona = H.player("mona", 3)
    H.players[3] = mona
    online[#online + 1] = mona
    H.fire("OnCreatePlayer", 3)
    settle(2)
    local list = {}
    for k = 1, 999 do list[k] = assert(SK.newStroke(3, { c = 1, w = 1, z = 17, share = true }, { 3000 + k, 3000 }, 1)) end
    list[1000] = assert(SK.newStroke(3, { c = 1, w = 1, z = 17, share = true }, { 5000, 5000, 5010, 5000 }, 2))
    assert(SK.apply(3, {}, 0, list, 1000))
    settle(14)
    check(SS.authors.mona and SS.authors.mona.count == 1000, "E3 1,000 筆分享都上了伺服器")
    if not SS.authors.mona then return H.finish("test_sketch_share") end
    local rem, nr, add, na = SK.eraseAt(3, 5005, 5000, 1)
    check(nr == 1 and na == 2 and add[1].share == true and add[2].share == false, "E4 擦成兩段：超過名額的那段改私人")
    SK.apply(3, rem, nr, add, na)
    settle(3)
    local o = SK.slots[3].store.origin
    local pos = SS.posMap(SS.authors.mona)
    check(not pos[C.lid(o, list[1000].id)] and pos[C.lid(o, add[1].id)] and not pos[C.lid(o, add[2].id)],
        "E5 伺服器撤回原筆、收下名額內的那段")
    -- 離線時刪掉那段（撤回沒送出）：對帳收回
    local store = SK.slots[3].store
    SK.removeAt(store, SK.indexOf(store, add[1].id))
    SH.q[3] = nil
    SS.lastSync.mona = nil
    SH.requestSync(3)
    settle(2)
    check(not SS.posMap(SS.authors.mona)[C.lid(o, add[1].id)], "E6 離線刪掉的片段對帳收回")
    -- 本機標成分享的筆比伺服器上限還多（別的狀態留下的）：清單照樣能對帳，不會靜默跳過
    local ids = {}
    for k = 1, 1200 do ids[k] = tostring(900000 + k) end
    local mark = #toClient
    SS.lastSync.mona = nil
    SS.Commands.skSync(srv(mona), { origin = o, ids = table.concat(ids, ",") }, "mona")
    check(SS.authors.mona.count == 0 and #sentTo("mona", "skFail", mark) == 0, "E7 1,200 筆的對帳清單照樣對帳")
    -- 伺服器回超過 1,000 個 id 的 skNeed：客戶端照樣拆得開、排進佇列（上限同伺服器拆清單）
    local need = {}
    for i = 1, store.count do
        if store.strokes[i].share then need[#need + 1] = tostring(store.strokes[i].id) end
    end
    local nShared = #need
    for k = 1, 101 do need[#need + 1] = tostring(800000 + k) end
    SH.q[3] = nil
    SH.handlers.skNeed(3, { ids = table.concat(need, ",") })
    local queued = 0
    for _ in pairs(SH.q[3] and SH.q[3].adds or {}) do queued = queued + 1 end
    check(#need > 1000 and queued == nShared, "E8 skNeed " .. #need .. " 個 id：名額內的 " .. queued .. " 筆排進佇列")
    settle(14)
    check(SS.authors.mona.count == nShared, "E9 補傳後伺服器有 " .. SS.authors.mona.count .. " 筆")
    Core.sketchShareAvailable = realAvail
end

H.finish("test_sketch_share")
