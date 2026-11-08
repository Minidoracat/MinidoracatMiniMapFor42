-- 資源點「已清空」分享與重置偵測：伺服器（上限與頻率、收件人、作者檔與索引、要用才載入、B2、B3、刷新推送）
-- 與客戶端（上傳分批、整份重傳、快照分批、刷新寫回本機）。用真的 ClearedCodec、RoadCodec（記憶體假檔案系統），
-- 伺服器送出的封包直接餵給客戶端處理器。用法：lua scripts/test_cleared_share.lua
local LUA = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/"

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end

-- 假 Java（陣營、安全屋同 test_road_share）-----------------------------------------------
local function jlist(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end,
        contains = function(_, v) for i = 1, #t do if t[i] == v then return true end end return false end }
end
local factions = { { name = "blue", owner = "alice", players = { "bob" } } }
local houses = { { owner = "carol", players = { "alice" } } }
local function member(h, name)
    if h.owner == name then return true end
    for i = 1, #h.players do if h.players[i] == name then return true end end
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
    getSafehouseList = function()
        local out = {}
        for i = 1, #houses do
            local h = houses[i]
            out[i] = { getOwner = function() return h.owner end, getPlayers = function() return jlist(h.players) end }
        end
        return jlist(out)
    end,
    isInSameSafehouse = function(a, b)
        for i = 1, #houses do if member(houses[i], a) and member(houses[i], b) then return true end end
        return false
    end,
    hasSafehouse = function(name)
        for i = 1, #houses do if member(houses[i], name) then return houses[i] end end
        return nil
    end,
}

local files = {}
function cacheFileExists(path) return files[path] ~= nil end
function getFileReader(path)
    if files[path] == nil then return nil end
    local lines, i = {}, 0
    for line in (files[path] .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
end
local readCount = {}
local realReader = getFileReader
function getFileReader(path, ...)
    readCount[path] = (readCount[path] or 0) + 1
    return realReader(path, ...)
end
function getFileWriter(path)
    files[path] = ""
    return { write = function(_, text) files[path] = files[path] .. text end, close = function() end }
end

local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end,
        Remove = function() end }
    rawset(t, name, e)
    return e
end })
local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

local nowMs = 100000
function getTimestampMs() return nowMs end
local hours = 500
function getGameTime() return { getWorldAgeHours = function() return hours end } end
function getWorld() return { getWorld = function() return "srv1" end, getGameMode = function() return "Multiplayer" end } end
local clientFlag, serverFlag = false, true
function isClient() return clientFlag end
function isServer() return serverFlag end
function getText(key) return key end
function getTexture() return nil end
function instanceof() return false end
function ZombRand() return 0 end
local printed = {}
local realPrint = print
function print(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
    printed[#printed + 1] = table.concat(t, " ")
    realPrint(...)
end
local policyOn = true
MinidoracatMiniMapPolicy = { readBool = function(name, d)
    if name == "AllowClearedShare" then return policyOn end
    return d
end }

-- seat＝伺服器上的 getPlayerNum()（分割畫面第 2～4 位是 1～3，名字是客戶端自己填的）
local function player(name, pn, seat)
    return { getUsername = function() return name end, getOnlineID = function() return 1 end,
        getPlayerNum = function() return seat or 0 end,
        getCurrentBuildingDef = function() return nil end, isDead = function() return false end, pn = pn }
end
local P = { alice = player("alice", 0), bob = player("bob"), carol = player("carol"), dave = player("dave"),
    admin = player("admin"), ["a:b"] = player("a:b"), seat = player("frank", nil, 1), gina = player("gina"),
    hank = player("hank"), ivy = player("ivy") }
local online = { P.alice, P.bob, P.carol, P.dave, P.admin }
function getOnlinePlayers() return jlist(online) end
local sent = {}
local deliver -- 客戶端處理器（載入客戶端後設定）
function sendServerCommand(target, module, command, args)
    sent[#sent + 1] = { to = target:getUsername(), module = module, command = command, args = args }
    if deliver and target == P.alice then deliver(module, command, args) end
end
local function sentSince(from, command, to)
    local out = {}
    for i = from + 1, #sent do
        local s = sent[i]
        if (not command or s.command == command) and (not to or s.to == to) then out[#out + 1] = s end
    end
    return out
end

dofile(LUA .. "shared/MinidoracatMiniMap_ClearedCodec.lua")
dofile(LUA .. "shared/MinidoracatMiniMap_RoadCodec.lua")
local function loadWithTail(path, tail)
    local fh = assert(io.open(path, "rb"))
    local src = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    return assert(load(src .. "\n" .. tail, "@" .. path))()
end
local CS = loadWithTail(LUA .. "server/MinidoracatMiniMapClearedShare.lua", "return CS")
dofile(LUA .. "server/MinidoracatMiniMapGroups.lua")
local C = MinidoracatMiniMapClearedCodec
fire("OnServerStarted")

-- 空表的 args 不上線：伺服器收到 nil（同 test_road_share）。沒帶來源碼的補上預設的 ORIGIN
local ORIGIN = "a1a1a1a1"
local function send(who, command, args)
    if type(args) == "table" and args.origin == nil and not args.noOrigin then args.origin = ORIGIN end
    if type(args) == "table" then args.noOrigin = nil end
    local empty = type(args) == "table"
    for _ in pairs(type(args) == "table" and args or {}) do empty = false break end
    if empty then args = nil end
    for _, fn in ipairs(handlers.OnClientCommand) do fn("MinidoracatMiniMapCleared", command, P[who], args) end
end
-- 有翻過進度的預設是拿過的（會上傳）；只翻過沒拿的另外測（21 段）
local function mark(x, y, ch, s, n, t)
    local m = C.newMark(x, y, 16, 16)
    m.vh, m.ch, m.cs, m.s, m.n, m.oh = 100, ch or 0, (ch or 0) > 0 and "a" or "-", s or 0, n or 10, 100
    m.t = t or ((s or 0) > 0 and 1 or 0)
    return m
end
local function wire(m) return C.toWire(m) end
local function tickServer(n)
    for _ = 1, n or 1 do fire("OnTickEvenPaused") end
end
local DIR = "MinidoracatMiniMap/cleared/srv1/"
local HEX_ALICE = C.hex("alice")

-- 1. 收件人、上限與頻率 -------------------------------------------------------------------
local m1 = mark(64, 64, 300, 10, 10)
local before = #sent
send("alice", "clrPut", { marks = { wire(m1) }, share = true })
local ups = sentSince(before, "clrTeamUpsert")
local to = {}
for _, s in ipairs(ups) do to[s.to] = true end
check(to.bob and to.carol and not to.dave and not to.admin and not to.alice and #ups == 2,
    "1a 只送給同陣營（bob）與同安全屋（carol），不給陌生人、管理員、作者自己")
check(ups[1] and ups[1].args.to == ups[1].to and ups[1].args.a == "alice" and ups[1].args.marks[1] == wire(m1),
    "1b 封包帶 to、作者與 wire")
before = #sent
send("alice", "clrPut", { marks = { wire(mark(200, 200, 300)) }, share = true })
check(sentSince(before, "clrPutFail")[1] and sentSince(before, "clrPutFail")[1].args.reason == "rate",
    "1c 每秒最多 1 次")
nowMs = nowMs + 1000
local many = {}
for i = 1, 65 do many[i] = wire(mark(i * 20, 5000, 300)) end
before = #sent
send("alice", "clrPut", { marks = many, share = true })
check(sentSince(before, "clrPutFail")[1] and sentSince(before, "clrPutFail")[1].args.reason == "invalid",
    "1d 一包超過 64 筆整包拒收")
nowMs = nowMs + 1000
before = #sent
send("alice", "clrPut", { marks = { wire(mark(300, 300, 0, 0)) }, share = true })
check(sentSince(before, "clrPutFail")[1] and sentSince(before, "clrPutFail")[1].args.reason == "invalid",
    "1e 只有去過（不會存的）不收")
nowMs = nowMs + 1000
policyOn = false
local m2 = mark(96, 64, 0, 4, 10)
before = #sent
send("alice", "clrPut", { marks = { wire(m2) }, share = true })
check(#sentSince(before, "clrTeamUpsert") == 0 and CS.authors[HEX_ALICE].store.count == 2,
    "1f 沙盒關：照存、不轉送")
policyOn = true
nowMs = nowMs + 1000
before = #sent
send("dave", "clrPut", { marks = { wire(mark(500, 500, 300)) }, share = false })
check(#sentSince(before, "clrTeamUpsert") == 0, "1g 作者沒開分享：不轉送")

-- 2. 作者檔與索引、要用才載入 ----------------------------------------------------------------
nowMs = nowMs + 31000
tickServer(8)
check(files[DIR .. HEX_ALICE .. ".txt"] ~= nil and files[DIR .. HEX_ALICE .. ".txt"]:find("^MMCLRSRV\t1\t1\t[1-9]%d*\t") ~= nil,
    "2a 作者檔（十六進位檔名、share 1）")
check(files[DIR .. "index.txt"] and files[DIR .. "index.txt"]:find("\nA\t" .. HEX_ALICE .. "\t2\t1") ~= nil
    and files[DIR .. "index.txt"]:find("\nC\t") == nil, "2b 索引只記作者（chunk 表不存檔）")
nowMs = nowMs + 1000
send("a:b", "clrPut", { marks = { wire(mark(900, 900, 300)) }, share = false })
nowMs = nowMs + 31000
tickServer(8)
check(files[DIR .. C.hex("a:b") .. ".txt"] ~= nil, "2c 帳號含檔名不允許的字元也寫得出來")
-- 重開伺服器：作者檔不常駐，要用才載入
CS.index, CS.indexPath, CS.authors = nil, nil, {}
fire("OnServerStarted")
check(CS.authors[HEX_ALICE] == nil, "2d 開服不留作者檔在記憶體")
check(CS.index.chunks["8,8"] and CS.index.chunks["8,8"][HEX_ALICE] and CS.index.authors[HEX_ALICE].count == 2,
    "2e 開服從作者檔重建 chunk 表")

-- 3. 同步：自己的筆數、隊友快照分批 -----------------------------------------------------------
nowMs = nowMs + 1000
local bobMarks = {}
for i = 1, 70 do bobMarks[i] = wire(mark(2000 + i * 20, 2000, 300)) end
for k = 0, 1 do
    local part = {}
    for i = 1, 64 do part[i] = bobMarks[k * 64 + i] end
    nowMs = nowMs + 1000
    send("bob", "clrPut", { marks = part, share = true })
end
nowMs = nowMs + 1000
before = #sent
send("alice", "clrSync", { seq = 0, count = 2, share = true })
local ok = sentSince(before, "clrSyncOk", "alice")[1]
check(ok and ok.args.count == 2 and ok.args.seq == CS.authors[HEX_ALICE].store.seq and ok.args.seq > 0,
    "3a clrSyncOk 回自己的筆數與序號（上傳也發修改序號 us，序號跟著前進）")
local snaps = sentSince(before, "clrTeamSnap", "alice")
local got = 0
for _, s in ipairs(snaps) do got = got + #s.args.marks end
check(#snaps == 2 and got == 70 and snaps[1].args.parts == 2, "3b 隊友快照分批（70 筆分 2 包）")
before = #sent
send("dave", "clrSync", { seq = 0, count = 0, share = true })
snaps = sentSince(before, "clrTeamSnap", "dave")
check(#snaps == 1 and #snaps[1].args.marks == 0, "3c 陌生人收到空快照")
nowMs = nowMs + 1000
policyOn = false
before = #sent
send("carol", "clrSync", { seq = 0, count = 0, share = true })
snaps = sentSince(before, "clrTeamSnap", "carol")
check(#snaps == 1 and #snaps[1].args.marks == 0, "3d 沙盒關：空快照")
policyOn = true

-- 4. B2：重新生成的 chunk 只刷新有標記的建築，只通知主人與隊友 ------------------------------------------
local function chunkAt(x, y, new)
    return { isNewChunk = function() return new end,
        getGridSquare = function(_, cx) return { getX = function() return x + cx end, getY = function() return y end } end }
end
hours = 600
before = #sent
fire("LoadChunk", chunkAt(64, 64, false))
fire("LoadChunk", chunkAt(4000, 4000, true))
tickServer()
check(#sentSince(before) == 0, "4a 不是新的、或沒有標記的 chunk 什麼都不做")
fire("LoadChunk", chunkAt(64, 64, true))
fire("LoadChunk", chunkAt(72, 64, true)) -- 同一棟（x 64..73）跨兩個 chunk、同一個 tick：只刷新一次
check(#sentSince(before) == 0, "4b LoadChunk 當下不載入作者檔（排到下個 tick）")
tickServer()
local st = CS.authors[HEX_ALICE].store
local srv = st.marks[1]
check(srv.ch == 0 and srv.rh == 600 and srv.s == 0 and srv.rs > 0 and srv.rs == st.seq,
    "4c 伺服器那筆改已刷新、序號只發一個（同一棟跨兩個 chunk）")
local rf = sentSince(before, "clrRefreshed")
local tm = sentSince(before, "clrTeamUpsert")
local tmTo = {}
for _, s in ipairs(tm) do tmTo[s.to] = true end
check(#rf == 1 and rf[1].to == "alice" and #rf[1].args.marks == 1, "4d 主人收到 clrRefreshed")
check(tmTo.bob and tmTo.carol and not tmTo.dave and not tmTo.admin, "4e 只通知隊友，不廣播")
before = #sent
fire("LoadChunk", chunkAt(64, 64, true))
tickServer()
check(#sentSince(before, "clrRefreshed") == 0, "4f 已刷新的不重複刷新")

-- 5. 客戶端：刷新寫回本機、count 不同整份重傳、上傳分批 -----------------------------------------------
clientFlag, serverFlag = true, false
local opts = { ClearedShare = true }
MinidoracatMiniMapCore = { ready = true, policy = MinidoracatMiniMapPolicy,
    getBoolOption = function(id, d) if opts[id] == nil then return d end return opts[id] end,
    getSliderValue = function(_, d) return d end }
local Core = MinidoracatMiniMapCore
function getSpecificPlayer(pn) return pn == 0 and P.alice or nil end
function getCell() return nil end
local clientSent = {}
function sendClientCommand(p, module, command, args)
    clientSent[#clientSent + 1] = { command = command, args = args, p = p }
end
dofile(LUA .. "client/MinidoracatMiniMap_Cleared.lua")
dofile(LUA .. "client/MinidoracatMiniMap_ClearedShare.lua")
local CL = Core.Cleared
deliver = function(module, command, args)
    for _, fn in ipairs(handlers.OnServerCommand) do fn(module, command, args) end
end
local s = CL.slot(0)
s.store.origin = ORIGIN -- 和上面伺服器那段用同一個來源碼
local own = mark(64, 64, 300, 10, 10)
own.oh = 300
s.store.count, s.store.marks[1] = 1, own
local own2 = mark(96, 64, 0, 4, 10)
s.store.count, s.store.marks[2] = 2, own2
local oneMore = mark(128, 64, 400, 1, 1)
s.store.count, s.store.marks[3] = 3, oneMore
fire("OnCreatePlayer", 0)
fire("OnTick") -- 第一次 tick 記下沙盒與分享設定（也排一次同步）
nowMs = nowMs + 2000
fire("OnTick")
local sync = clientSent[#clientSent]
check(sync and sync.command == "clrSync" and sync.args.seq == 0 and sync.args.count == 3 and sync.args.share == true,
    "5a 登入後防抖送 clrSync（序號、會存的筆數、分享）")
-- 伺服器處理
serverFlag, clientFlag = true, false
before = #sent
send("alice", "clrSync", sync.args)
clientFlag, serverFlag = true, false
check(own.ch == 0 and own.rh == 600 and own.s == 0, "5b 錯過的刷新寫回本機那筆")
check(s.store.refreshSeq == CS.authors[HEX_ALICE].store.seq, "5c 記下伺服器序號")
check(own2.ch == 0 and own2.rh == 0 and own2.s == 4, "5d 沒刷新的不動")
check(s.upload and oneMore.u and own.u and own2.u, "5e 筆數不同（伺服器 2、本機 3）＝整份重傳（含剛刷新的）")
nowMs = nowMs + 2000
local n0 = #clientSent
fire("OnTick")
local put = clientSent[#clientSent]
check(#clientSent == n0 + 1 and put.command == "clrPut" and put.args.reset == true and #put.args.marks == 3,
    "5f 第一包帶 reset，只送會存的")
check(not s.upload, "5g 送完清掉待上傳")
local team = CL.team[0]
check(team and team.n == 70, "5h 隊友快照收齊才換上")
-- 伺服器收 reset：先清再收
serverFlag, clientFlag = true, false
nowMs = nowMs + 1000
send("alice", "clrPut", put.args)
check(CS.authors[HEX_ALICE].store.count == 3, "5i 伺服器整份換成客戶端那份")
-- 伺服器刷新過、客戶端還沒看到的不被舊資料蓋掉
local stale = mark(64, 64, 300, 10, 10)
stale.oh = 100
nowMs = nowMs + 1000
send("alice", "clrPut", { marks = { wire(stale) }, share = true })
local kept = CS.authors[HEX_ALICE].at[ORIGIN][C.key(stale)]
check(kept.ch == 0 and kept.rh == 600, "5j 掃描早於伺服器刷新的舊上傳不蓋掉已刷新")
check(stale.t == 1 and kept.t == 0, "21k 保留已刷新時拿過也歸零（同 C.refresh）")
clientFlag, serverFlag = true, false

-- 6. 刪除與隊友移除 -----------------------------------------------------------------------
serverFlag, clientFlag = true, false
before = #sent
nowMs = nowMs + 1000
send("bob", "clrDrop", { keys = { C.key(C.fromWire(bobMarks[1])) } })
local rem = sentSince(before, "clrTeamRemove")
local remTo = {}
for _, r in ipairs(rem) do remTo[r.to] = true end
check(remTo.alice and #rem[1].args.keys == 1, "6a 刪除通知看得到的人")
check(CL.team[0].n == 69, "6b 客戶端移掉那一筆")
-- 關分享：隊友那邊整位作者移除
nowMs = nowMs + 1000
before = #sent
send("bob", "clrSync", { seq = 0, count = 69, share = false })
rem = sentSince(before, "clrTeamRemove", "alice")
check(#rem == 1 and rem[1].args.keys == nil and CL.team[0].n == 0, "6c 作者關分享：隊友移除他全部的標記")

-- 7. B3：重置清單 --------------------------------------------------------------------------
local RESETS = "MinidoracatMiniMap/chunk_resets_srv1.txt"
local function resetsFile(runs)
    local lines = { "MMRESETS\t1\t" .. runs[1].id }
    for _, r in ipairs(runs) do
        lines[#lines + 1] = "RUN\t" .. r.id .. "\t" .. r.ms .. "\t" .. #r.chunks
        lines[#lines + 1] = "C\t" .. table.concat(r.chunks, ";")
    end
    lines[#lines + 1] = "END\t" .. #runs
    return table.concat(lines, "\n")
end
-- 一輪寫檔（作者先、索引最後；重置的 run 等作者寫完才進索引）
local function saveRound()
    nowMs = nowMs + CS.SAVE_MS + 1
    tickServer(30)
end
-- 準備：alice 有一筆已清空在 chunk 16,8（x 128..143）
nowMs = nowMs + 1000
send("alice", "clrPut", { marks = { wire(mark(128, 64, 700, 1, 1)) }, share = true })
local since = CS.index.since
local function aliceMark(x)
    local e = CS.authors[HEX_ALICE]
    return e.at[ORIGIN][C.key({ x = x, y = 64, w = 16, h = 16 })]
end
files[RESETS] = resetsFile({
    { id = "2026-11-09_06-00-00", ms = since + 10, chunks = { "16,8", "17,8" } },
    { id = "2026-11-08_06-00-00", ms = since - 10, chunks = { "12,8" } },
})
CS.resetsAt = 0
hours = 800
before = #sent
tickServer()
check(aliceMark(128).ch == 0 and aliceMark(128).rh == 800, "7a 開服讀清單：碰到的已清空改已刷新")
check(CS.index.run == nil and CS.runPending and CS.runPending.run == "2026-11-09_06-00-00",
    "7b0 套用了，但作者寫進檔前不進索引")
saveRound()
check(CS.index.run == "2026-11-09_06-00-00" and files[DIR .. "index.txt"]:find("^MMCLRIDX\t1\t2026%-11%-09_06%-00%-00\t") ~= nil,
    "7b 作者寫完後索引記下最後套用的 run id")
check(#sentSince(before, "clrRefreshed", "alice") == 1, "7c 主人收到刷新")
-- 同一份清單不再套用；只看第一行
aliceMark(128).ch, aliceMark(128).cs = 900, "m"
local reads = readCount[RESETS] or 0
nowMs = nowMs + CS.RESETS_CHECK_MS + 1
tickServer()
check(aliceMark(128).ch == 900 and (readCount[RESETS] or 0) == reads + 1, "7d 之後每 10 分鐘只讀第一行，同一次執行不再套用")
-- 新的一次放最前面，舊的照留：只套新的
files[RESETS] = resetsFile({
    { id = "2026-11-09_12-00-00", ms = nowMs + 1, chunks = { "16,8" } }, -- 開始移檔在上一次刷新之後（Q12）
    { id = "2026-11-09_06-00-00", ms = since + 10, chunks = { "16,8", "17,8" } },
})
nowMs = nowMs + CS.RESETS_CHECK_MS + 1
hours = 900
tickServer()
saveRound()
check(aliceMark(128).ch == 0 and aliceMark(128).rh == 900 and CS.index.run == "2026-11-09_12-00-00",
    "7e 新的一次套用")
-- 比水位（索引建立時間、已套用的最新 RUN）早的不套
aliceMark(128).ch, aliceMark(128).cs = 950, "m"
files[RESETS] = resetsFile({ { id = "old-run", ms = since - 5, chunks = { "16,8" } } })
nowMs = nowMs + CS.RESETS_CHECK_MS + 1
tickServer()
check(aliceMark(128).ch == 950, "7f 比索引建立早的執行不套用")
-- R1：產生端拿掉最新的 RUN（還原）：剩下的比已套用的水位舊，不重套（ivy 是之後才有的作者，自己的 rms 擋不到）
nowMs = nowMs + 1000
send("ivy", "clrPut", { marks = { wire(mark(128, 64, 940, 1, 1)) }, share = false })
files[RESETS] = resetsFile({ { id = "2026-11-09_06-00-00", ms = since + 10, chunks = { "16,8" } } })
nowMs = nowMs + CS.RESETS_CHECK_MS + 1
tickServer()
check(aliceMark(128).ch == 950 and CS.authors[C.hex("ivy")].store.marks[1].ch == 940,
    "7f2 最新的 RUN 被拿掉：舊的 run id 不重套（單調水位）")
-- I9：同一個檔頭先壞（拒收、不記成看過），修好後下一輪套用
local goodRuns = { { id = "2026-11-10_06-00-00", ms = nowMs + 1, chunks = { "16,8" } } }
files[RESETS] = resetsFile(goodRuns):gsub("\nC\t16,8", "\nC\t16,x")
nowMs = nowMs + CS.RESETS_CHECK_MS + 1
tickServer()
check(aliceMark(128).ch == 950, "7f3 壞的清單不套用")
files[RESETS] = resetsFile(goodRuns)
nowMs = nowMs + CS.RESETS_CHECK_MS + 1
hours = 960
tickServer()
check(aliceMark(128).ch == 0 and aliceMark(128).rh == 960, "7f4 同一個檔頭修好後下一輪照樣套用")
saveRound()
-- 壞行整份拒收
local function rejected(text, label)
    local runs = CS.parseResets((function()
        local l = {}
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do l[#l + 1] = line end
        return l
    end)(), (function() local n = 0 for _ in (text .. "\n"):gmatch("([^\n]*)\n") do n = n + 1 end return n end)())
    check(runs == nil, label)
end
rejected("MMRESETS\t1\tr1\nRUN\tr1\t1\t2\nC\t1,1\nEND\t1", "7g chunk 數不符整份拒收")
rejected("MMRESETS\t1\tr1\nRUN\tr1\t1\t1\nC\t1,x\nEND\t1", "7h 座標不是整數整份拒收")
rejected("MMRESETS\t1\tr2\nRUN\tr1\t1\t1\nC\t1,1\nEND\t1", "7i 檔頭的最新 id 不是第一個 RUN")
rejected("MMRESETS\t2\tr1\nRUN\tr1\t1\t1\nC\t1,1\nEND\t1", "7j 版本不認得")
rejected("MMRESETS\t1\tr1\nRUN\tr1\t2\t1\nC\t1,1\nRUN\tr1\t1\t1\nC\t1,1\nEND\t2", "7k run id 重複")
rejected("MMRESETS\t1\tr2\nRUN\tr2\t1\t1\nC\t1,1\nRUN\tr1\t2\t1\nC\t1,1\nEND\t2", "7k2 RUN 毫秒不是由新到舊遞減")
rejected("MMRESETS\t1\tr1\nRUN\tr1\t1\t1\nC\t1,1\nEND\t2", "7l END 次數不符")
rejected("MMRESETS\t1\tr1\nRUN\tr1\t1\t1\nC\t1,1\nX\tjunk\nEND\t1", "7m 不認得的行")
local okRuns = CS.parseResets({ "MMRESETS\t1\tr1", "RUN\tr1\t1700000000000\t3", "C\t1,1;-2,3", "C\t4,5", "END\t1" }, 5)
check(okRuns and okRuns[1].got == 3 and okRuns[1].chunks[2][1] == -2, "7n 一次執行可以分好幾行 C")
local sixtyOne = { "MMRESETS\t1\tr1" }
for i = 1, 61 do
    sixtyOne[#sixtyOne + 1] = "RUN\tr" .. i .. "\t" .. (1000 - i) .. "\t1"
    sixtyOne[#sixtyOne + 1] = "C\t1,1"
end
sixtyOne[#sixtyOne + 1] = "END\t61"
check(CS.parseResets(sixtyOne, #sixtyOne) == nil, "7o 超過 60 次執行整份拒收")
check(CS.resetsPath() == RESETS, "7p 檔名用存檔名（同 players_<存檔名>.json）")

-- 8. 身分、只讀、寫檔失敗、大清單、對帳、快照沒變（2026-11-08 審查自查） ------------------------------------
serverFlag, clientFlag = true, false
-- 分割畫面第 2 位自稱不在線的隊友 frank：寫入被拒、同步不回、收不到任何分享或刷新
factions[1].players = { "bob", "frank" }
online[#online + 1] = P.seat
nowMs = nowMs + 1000
before = #sent
send("seat", "clrPut", { marks = { wire(mark(3000, 3000, 300)) }, share = true })
send("seat", "clrDrop", { keys = { "3000,3000,16,16" } })
local fails = sentSince(before, "clrPutFail", "frank")
check(#fails == 2 and fails[1].args.reason == "identity" and fails[2].args.reason == "identity"
    and CS.authors[C.hex("frank")] == nil, "8a 沒有身分的座位：寫入回 identity、不建作者")
before = #sent
send("seat", "clrSync", { seq = 0, count = 0, share = true })
check(#sentSince(before, nil, "frank") == 0, "8b 沒有身分的座位：同步不回")
nowMs = nowMs + 1000
before = #sent
send("alice", "clrPut", { marks = { wire(mark(480, 480, 300)) }, share = true })
local upTo = {}
for _, u in ipairs(sentSince(before, "clrTeamUpsert")) do upTo[u.to] = true end
check(upTo.bob and not upTo.frank, "8c 隊友名單裡有 frank，但這個座位收不到分享")
before = #sent
CS.applyChunks({ { 60, 60 } }, 1)
upTo = {}
for _, u in ipairs(sentSince(before, "clrTeamUpsert")) do upTo[u.to] = true end
check(upTo.bob and not upTo.frank and #sentSince(before, "clrRefreshed", "alice") == 1, "8d 刷新也不通知沒有身分的座位")
online[#online] = nil
factions[1].players = { "bob" }

-- 作者檔：主檔壞、備份是較新版本 → 只讀不覆寫；主檔與備份都壞 → 只讀
local GINA = DIR .. C.hex("gina") .. ".txt"
local Codec = MinidoracatMiniMapRoadCodec
files[GINA], files[Codec.backupPath(GINA)] = "junk", "MMCLRSRV\t9\t1\t0\nEND\t0"
nowMs = nowMs + 1000
before = #sent
send("gina", "clrPut", { marks = { wire(mark(4000, 4000, 300)) }, share = true })
check(sentSince(before, "clrPutFail", "gina")[1] and sentSince(before, "clrPutFail", "gina")[1].args.reason == "readonly",
    "8e 備份讀不懂（較新版本）：只讀")
CS.authors[C.hex("gina")] = nil
files[Codec.backupPath(GINA)] = "junk too"
nowMs = nowMs + 1000
before = #sent
send("gina", "clrPut", { marks = { wire(mark(4000, 4000, 300)) }, share = true })
nowMs = nowMs + CS.SAVE_MS + 1
tickServer(8)
check(sentSince(before, "clrPutFail", "gina")[1] and files[GINA] == "junk", "8f 主檔與備份都壞：只讀、不用空資料覆寫")

-- 寫檔失敗：留著下一輪再寫
local realWrite = Codec.writeSafe
Codec.writeSafe = function() return false end
nowMs = nowMs + 1000
send("alice", "clrPut", { marks = { wire(mark(512, 480, 300)) }, share = true })
nowMs = nowMs + CS.SAVE_MS + 1
tickServer(8)
check(CS.authors[HEX_ALICE].dirty == true and CS.indexDirty == true, "8g 寫檔失敗不清掉未保存")
Codec.writeSafe = realWrite
nowMs = nowMs + CS.SAVE_MS + 1
tickServer(8)
check(CS.authors[HEX_ALICE].dirty == false and files[DIR .. HEX_ALICE .. ".txt"]:find("\nB\t512\t480\t") ~= nil,
    "8h 下一輪寫成功")
nowMs = nowMs + 1000
local upd = mark(512, 480, 310)
upd.s = 3
send("alice", "clrPut", { marks = { wire(upd) }, share = true })
check(CS.authors[HEX_ALICE].dirty == true and CS.indexDirty == false, "8h2 只改內容（chunk、筆數、分享沒變）不重寫索引")

-- 一包大清單：只看前 MAX_PUT 筆
local parses, realParse = 0, C.parseKey
C.parseKey = function(...) parses = parses + 1 return realParse(...) end
local big = {}
for i = 1, 10000 do big[i] = i .. ",1,16,16" end
nowMs = nowMs + 1000
send("alice", "clrDrop", { keys = big })
C.parseKey = realParse
check(parses <= CS.MAX_PUT, "8i 刪除清單上萬筆只看前 64 筆（got " .. parses .. "）")

-- 對帳：clrSyncOk 帶 digest；客戶端筆數一樣但內容不同就整份重傳，有待送的不對帳
nowMs = nowMs + 1000
before = #sent
send("alice", "clrSync", { seq = 0, count = 0, share = true })
local okMsg = sentSince(before, "clrSyncOk", "alice")[1]
local ast = CS.authors[HEX_ALICE].store
check(okMsg and okMsg.args.digest == C.storeDigest(ast.marks, ast.count), "8j clrSyncOk 帶伺服器那份的 digest")
clientFlag, serverFlag = true, false
local S = CL.Share
local cs = CL.slots[0]
local function clearPending()
    cs.upload, cs.drops = nil, {}
    CL.Share.resetting[0], CL.Share.reset[0] = nil, nil
    for i = 1, cs.store.count do cs.store.marks[i].u = nil end
end
clearPending()
local count0, digest0 = S.relevantCount(cs), C.storeDigest(cs.store.marks, cs.store.count)
S.handlers.clrSyncOk(0, { count = count0, seq = cs.store.refreshSeq, digest = digest0 })
check(not cs.upload, "8k 筆數與 digest 都對：不重傳")
S.handlers.clrSyncOk(0, { count = count0, seq = cs.store.refreshSeq, digest = (digest0 + 1) % 2147483647 })
check(cs.upload == true, "8l 筆數一樣、內容不同：整份重傳")
clearPending()
cs.drops["1,1,16,16"] = true
S.handlers.clrSyncOk(0, { count = count0 + 5, seq = cs.store.refreshSeq, digest = 0 })
check(not cs.upload, "8m 還有待送的刪除：不對帳")
clearPending()

-- 分割畫面第 2 位：送出前就擋（伺服器沒有他的身分），不送同步也不上傳
local realGet = getSpecificPlayer
getSpecificPlayer = function(pn) if pn == 1 then return P.seat end return realGet(pn) end
local seatSlot = CL.slot(1)
seatSlot.store.count, seatSlot.store.marks[1] = 1, mark(8000, 8000, 300)
seatSlot.upload = true
S.requestSync(1)
nowMs = nowMs + 5000
local c0 = #clientSent
fire("OnTick")
local fromSeat = 0
for i = c0 + 1, #clientSent do if clientSent[i].p == P.seat then fromSeat = fromSeat + 1 end end
check(fromSeat == 0, "8m2 分割畫面第 2 位不送 clrSync／clrPut")
CL.slots[1] = nil
getSpecificPlayer = realGet

-- 快照內容沒變：不解碼、不重建；中間有增量更新就照常換上
local function snap(seq, marks)
    S.handlers.clrTeamSnap(0, { seq = seq, part = 1, parts = 1, marks = marks })
end
local tw = { { a = "bob", m = wire(mark(7000, 7000, 300)) }, { a = "carol", m = wire(mark(7100, 7000, 300)) } }
snap(9001, tw)
local rev1 = CL.rev
snap(9002, tw)
check(CL.rev == rev1 and CL.team[0].n == 2, "8n 同樣的快照不重建")
S.handlers.clrTeamUpsert(0, { a = "bob", marks = { wire(mark(7200, 7000, 300)) } })
check(CL.team[0].n == 3, "8o 增量加一筆")
snap(9003, tw)
check(CL.team[0].n == 2 and CL.rev > rev1 + 1, "8p 增量之後同樣的快照照常換上")
S.handlers.clrTeamUpsert(0, { a = "bob", marks = { tw[1].m } })
check(CL.team[0].n == 2, "8q 同一棟再送一次是更新不是新增")
S.handlers.clrTeamRemove(0, { a = "bob", keys = { "7000,7000,16,16" } })
check(CL.team[0].n == 1 and CL.team[0].list[1].a == "carol", "8r 依外框移除")

-- 索引壞掉（主檔與備份都壞）：只讀，不把索引重寫成只有新作者
serverFlag, clientFlag = true, false
CS.index, CS.indexPath, CS.authors = nil, nil, {}
files[DIR .. "index.txt"], files[Codec.backupPath(DIR .. "index.txt")] = "junk", nil
fire("OnServerStarted")
nowMs = nowMs + 1000
before = #sent
send("bob", "clrPut", { marks = { wire(mark(5000, 5000, 300)) }, share = true })
nowMs = nowMs + CS.SAVE_MS + 1
tickServer(8)
check(CS.indexReadOnly and sentSince(before, "clrPutFail", "bob")[1] and files[DIR .. "index.txt"] == "junk",
    "8s 索引壞掉：只讀、不覆寫")

-- 9 起：2026-11-08 第 1 輪審查修正 ----------------------------------------------------------------------------
local realWrite = Codec.writeSafe
local function freshServer()
    serverFlag, clientFlag = true, false
    local gone = {}
    for k in pairs(files) do if k:sub(1, #DIR) == DIR then gone[#gone + 1] = k end end
    for i = 1, #gone do files[gone[i]] = nil end
    files[RESETS] = nil
    CS.index, CS.indexPath, CS.authors, CS.runPending, CS.resetsHead = nil, nil, {}, nil, nil
    CS.lastPut, CS.lastDrop, CS.lastSync, CS.originOf = {}, {}, {}, {}
    CS.pendingChunks, CS.pendingN, CS.saveQueue, CS.saveQn = {}, 0, nil, 0
    fire("OnServerStarted")
end
local function tsend(who, command, args)
    nowMs = nowMs + CS.RATE_MS + 1
    send(who, command, args)
end
local function lastFail(who) local f = sentSince(before, "clrPutFail", who); return f[#f] and f[#f].args end

-- 9. B1 chunk 預算：每位作者 5 萬個 chunk；超過整包拒收、store 不變；預算內只展開有變動的外框 ----------------------
do
    freshServer()
    local function bigMark(x)
        local m = C.newMark(x, 0, 512, 512) -- 8 的倍數對齊：64×64＝4,096 個 chunk
        m.vh, m.ch, m.cs, m.n, m.s, m.oh = 1, 5, "m", 1, 1, 1
        return wire(m)
    end
    local twelve = {}
    for i = 1, 12 do twelve[i] = bigMark(i * 1024) end
    tsend("hank", "clrPut", { marks = twelve, share = false })
    local he = CS.authors[C.hex("hank")]
    check(he.store.count == 12, "9a 前提：12 筆最大外框（49,152 個 chunk）在預算內")
    local idxCount = CS.index.authors[he.hex].count
    before = #sent
    tsend("hank", "clrPut", { marks = { bigMark(13 * 1024) }, share = false })
    check(lastFail("hank") and lastFail("hank").reason == "limit" and he.store.count == 12
        and CS.index.authors[he.hex].count == idxCount, "9b 超過預算整包拒收、store 與索引不變")
    local expanded, realKeys = 0, C.chunkKeys
    C.chunkKeys = function(m) local k, n = realKeys(m); expanded = expanded + n; return k, n end
    tsend("hank", "clrPut", { marks = { wire(mark(80000, 80000, 300)) }, share = false })
    C.chunkKeys = realKeys
    check(he.store.count == 13 and expanded <= 9, "9c 預算內新增一筆只展開那一筆的 chunk（got " .. expanded .. "）")
    -- I2（伺服器端）：空的 reset 包清掉這台電腦的那份
    tsend("hank", "clrPut", { marks = {}, share = false, reset = true, done = true })
    check(he.store.count == 0 and CS.index.authors[he.hex] == nil, "9d 空的 reset 包清掉這個來源碼的全部標記")
end

-- 10. B3 隊友快照看作者檔的分享旗標，不看索引 ------------------------------------------------------------
do
    freshServer()
    tsend("carol", "clrPut", { marks = { wire(mark(9000, 9000, 300)) }, share = true })
    saveRound()
    Codec.writeSafe = function(path, text)
        if path == DIR .. "index.txt" then return false end
        return realWrite(path, text)
    end
    tsend("carol", "clrSync", { seq = 0, count = 1, share = false })
    saveRound()
    Codec.writeSafe = realWrite
    CS.index, CS.indexPath, CS.authors = nil, nil, {}
    fire("OnServerStarted")
    check(CS.index.authors[C.hex("carol")].share == false, "10a0 開服重建時讀得懂的作者檔會修正索引的分享旗標")
    CS.index.authors[C.hex("carol")].share = true -- 索引仍可能比作者檔舊（例：作者檔只讀時不修正）
    before = #sent
    tsend("alice", "clrSync", { seq = 0, count = 0, share = true })
    local fromCarol = 0
    for _, sm in ipairs(sentSince(before, "clrTeamSnap", "alice")) do
        for _, e in ipairs(sm.args.marks) do if e.a == "carol" then fromCarol = fromCarol + 1 end end
    end
    check(fromCarol == 0, "10b 作者檔沒開分享：快照不給")
end

-- 11. B4 寫檔順序與每個寫檔邊界中斷後重開 -------------------------------------------------------------------
do
    freshServer()
    local HEX_DAVE = C.hex("dave")
    tsend("alice", "clrPut", { marks = { wire(mark(600, 600, 300)) }, share = false })
    tsend("dave", "clrPut", { marks = { wire(mark(600, 600, 300)) }, share = false })
    saveRound()
    files[RESETS] = resetsFile({ { id = "crash-1", ms = CS.index.since + 100, chunks = { "75,75" } } })
    local order = {}
    Codec.writeSafe = function(path, text)
        order[#order + 1] = path
        if path == DIR .. HEX_ALICE .. ".txt" then return false end
        return realWrite(path, text)
    end
    CS.resetsAt = 0
    hours = 1000
    tickServer()
    check(CS.authors[HEX_ALICE].store.marks[1].rh == 1000 and CS.authors[HEX_DAVE].store.marks[1].rh == 1000,
        "11a 前提：兩位作者都刷新")
    CS.indexDirty = true -- 這一輪索引也有別的變動要寫
    saveRound()
    check(#order >= 2 and order[#order] == DIR .. "index.txt" and order[1] ~= DIR .. "index.txt",
        "11b 一輪寫檔：作者先、索引最後")
    check(not files[DIR .. "index.txt"]:find("crash%-1"), "11c alice 寫不進去：索引不記這次 RUN")
    -- dave 看到刷新後又清空（他的客戶端處理過這個序號）
    local re = mark(600, 600, 1100)
    re.rs = CS.authors[HEX_DAVE].store.marks[1].rs
    tsend("dave", "clrPut", { marks = { wire(re) }, share = false })
    saveRound()
    Codec.writeSafe = realWrite
    -- 停機重開：記憶體沒了，alice 的檔還是舊的
    CS.index, CS.indexPath, CS.authors, CS.runPending, CS.resetsHead = nil, nil, {}, nil, nil
    fire("OnServerStarted")
    hours = 1200
    tickServer()
    local a, d = CS.author(HEX_ALICE).store.marks[1], CS.author(HEX_DAVE).store.marks[1]
    check(a.ch == 0 and a.rh == 1200, "11d 重開：沒寫進去的 alice 照樣重播")
    check(d.ch == 1100, "11e 重開：dave 已套用過（作者檔的 rms），之後又清空的不被再標已刷新")
    saveRound()
    check(CS.index.run == "crash-1" and files[DIR .. "index.txt"]:find("crash%-1") ~= nil, "11f 全部寫進檔後索引才記")
end

-- 12. I1 同一個帳號兩台電腦：各自一份、對帳收斂、隊友看到合併、刷新套到全部來源碼 --------------------------------
local OA, OB = "aaaa0001", "bbbb0002"
do
    freshServer()
    local p1a = mark(1000, 1000, 300, 10, 10)
    local p1b = mark(1000, 1000, 0, 4, 10)
    p1b.vh, p1b.oh = 200, 200
    local p2b = mark(1100, 1000, 350, 10, 10)
    tsend("bob", "clrPut", { marks = { wire(p1a) }, share = true, origin = OA })
    tsend("bob", "clrPut", { marks = { wire(p1b), wire(p2b) }, share = true, origin = OB })
    local bst = CS.authors[C.hex("bob")].store
    check(bst.count == 3, "12a 兩台電腦各自一份（同一棟兩筆）")
    local function okFor(origin)
        before = #sent
        tsend("bob", "clrSync", { seq = 0, count = 0, share = true, origin = origin })
        return sentSince(before, "clrSyncOk", "bob")[1].args
    end
    local da = C.storeDigest({ C.fromWire(wire(p1a)) }, 1)
    local db = C.storeDigest({ C.fromWire(wire(p1b)), C.fromWire(wire(p2b)) }, 2)
    local ra = okFor(OA)
    check(ra.count == 1 and ra.digest == da, "12b A 登入：筆數與摘要只算 A，和 A 本機一致")
    local rb = okFor(OB)
    check(rb.count == 2 and rb.digest == db, "12c B 登入：只算 B，一致")
    ra = okFor(OA)
    check(ra.count == 1 and ra.digest == da, "12d 再換回 A：仍一致（收斂，不會每次登入整份重傳）")
    tsend("bob", "clrPut", { marks = { wire(p1a) }, share = true, origin = OA, reset = true, done = true })
    check(bst.count == 3, "12e A 的整份重傳（reset…done）不刪 B 的")
    before = #sent
    tsend("alice", "clrSync", { seq = 0, count = 0, share = true })
    local got = {}
    for _, sm in ipairs(sentSince(before, "clrTeamSnap", "alice")) do
        for _, e in ipairs(sm.args.marks) do if e.a == "bob" then got[#got + 1] = C.fromWire(e.m) end end
    end
    local g1
    for _, m in ipairs(got) do if m.x == 1000 then g1 = m end end
    check(#got == 2, "12f 隊友看到合併後一棟一筆")
    check(g1 and g1.ch > 0 and g1.s == 10, "12g 合併取最新狀態（A 的已清空比 B 的進度新，B 排在前面）")
    local function find(origin, x)
        for i = 1, bst.count do
            local m = bst.marks[i]
            if m.o == origin and m.x == x then return m end
        end
    end
    hours = 1300
    CS.applyChunks({ { 125, 125 } }, 1)
    check(find(OA, 1000).rh == 1300 and find(OB, 1000).rh == 1300, "12h 刷新套到所有來源碼")
    tsend("bob", "clrPut", { marks = { wire(p1a) }, share = true, origin = OA, reset = true })
    check(find(OA, 1000).ch == 0 and find(OA, 1000).rh == 1300, "12i 刷新後拿舊資料整份重傳：保留已刷新")
    local late = mark(1000, 1000, 300, 10, 10)
    late.oh = 5000 -- 管理員撥過時鐘：本機最後掃描時數比刷新時數大，但沒處理過這次刷新（rs 舊）
    tsend("bob", "clrPut", { marks = { wire(late) }, share = true, origin = OA })
    check(find(OA, 1000).ch == 0 and find(OA, 1000).rh == 1300, "12i2 I14 伺服器端比序號、不比時數")
    for k, o in ipairs({ "cccc0003", "dddd0004" }) do
        tsend("bob", "clrPut", { marks = { wire(mark(1200 + k * 20, 1000, 300)) }, share = true, origin = o })
    end
    tsend("bob", "clrPut", { marks = { wire(mark(1300, 1000, 300)) }, share = true, origin = "eeee0005" })
    check(bst.on == 4 and bst.origins.eeee0005 and not bst.origins[OB] and find(OB, 1100) == nil,
        "12j 第 5 台電腦擠掉最久沒同步的那台")
    -- I3：客戶端游標比伺服器新（伺服器回滾）：這台電腦有序號的筆全部重送，clrSyncOk 回伺服器的序號
    local bseq = bst.seq
    before = #sent
    tsend("bob", "clrSync", { seq = bseq + 1000000, count = 0, share = true, origin = OA })
    local rf, okm = 0, sentSince(before, "clrSyncOk", "bob")[1]
    for _, r in ipairs(sentSince(before, "clrRefreshed", "bob")) do rf = rf + #r.args.marks end
    check(rf >= 1 and okm.args.seq == bseq, "12k 水位超前：重送有序號的筆、回伺服器的序號")
end

-- 13. I10 超過容量：整包先驗，前半包不套用 ---------------------------------------------------------------
do
    freshServer()
    tsend("ivy", "clrPut", { marks = { wire(mark(0, 30000, 300)) }, share = false })
    local ie = CS.authors[C.hex("ivy")]
    local ist = ie.store
    for i = 2, C.MAX_MARKS - 1 do
        local m = mark((i % 200) * 16, math.floor(i / 200) * 16 + 20000, 300)
        m.o, m.rs = ORIGIN, 0
        ist.count = ist.count + 1
        ist.marks[ist.count] = m
        CS.track(ie, m, 1) -- 直接塞 store 也要登記（clrPut 的筆數與預算看 CS.track 的合計）
    end
    ie.dirty, CS.indexDirty = false, false
    before = #sent
    tsend("ivy", "clrPut", { marks = { wire(mark(40000, 40000, 300)), wire(mark(40100, 40000, 300)) }, share = false })
    check(lastFail("ivy") and lastFail("ivy").reason == "limit" and ist.count == C.MAX_MARKS - 1 and not ie.dirty
        and not CS.indexDirty, "13a 超過筆數上限：整包拒收，store、dirty、索引都不變")
end

-- 14. N3 伺服器只讀：clrSyncOk 帶 readOnly ----------------------------------------------------------------
do
    files[GINA], files[Codec.backupPath(GINA)] = "junk", "junk too"
    CS.authors[C.hex("gina")] = nil
    before = #sent
    tsend("gina", "clrSync", { seq = 0, count = 0, share = true })
    local okm = sentSince(before, "clrSyncOk", "gina")[1]
    check(okm and okm.args.readOnly == true, "14a 作者檔只讀：clrSyncOk 帶 readOnly")
end

-- 15. N9 每個壞掉的作者檔都記一行、帶檔名 ----------------------------------------------------------------
do
    for k in pairs(printed) do printed[k] = nil end
    local xa, xb = DIR .. C.hex("xa") .. ".txt", DIR .. C.hex("xb") .. ".txt"
    files[xa], files[xb] = "junk", "junk"
    CS.author(C.hex("xa"), "xa")
    CS.author(C.hex("xb"), "xb")
    local sa, sb = false, false
    for _, line in ipairs(printed) do
        if line:find(xa, 1, true) then sa = true end
        if line:find(xb, 1, true) then sb = true end
    end
    check(sa and sb, "15a 兩個壞掉的作者檔各記一行、帶檔名")
end

-- 16. N5 clrDrop 限頻；N12 同步被限頻要回覆；N11 刷新分批 ---------------------------------------------------
do
    freshServer()
    tsend("dave", "clrPut", { marks = { wire(mark(3000, 3000, 300)), wire(mark(3100, 3000, 300)) }, share = false })
    before = #sent
    tsend("dave", "clrDrop", { keys = { "3000,3000,16,16" } })
    nowMs = nowMs + 10
    send("dave", "clrDrop", { keys = { "3100,3000,16,16" } })
    check(CS.authors[C.hex("dave")].store.count == 1 and lastFail("dave") and lastFail("dave").reason == "rate"
        and lastFail("dave").cmd == "clrDrop", "16a 一秒內第二包刪除被拒（rate、cmd＝clrDrop）")
    before = #sent
    tsend("dave", "clrSync", { seq = 0, count = 1, share = false })
    nowMs = nowMs + 10
    send("dave", "clrSync", { seq = 0, count = 1, share = false })
    check(#sentSince(before, "clrSyncRate", "dave") == 1, "16b 同步被限頻：回 clrSyncRate")
    -- alice 70 筆一起刷新：主人收到的分批，序號只放在最後一包
    local list70 = {}
    for i = 1, 70 do list70[i] = wire(mark(20000 + i * 16, 0, 300)) end
    local p1, p2 = {}, {}
    for i = 1, 64 do p1[i] = list70[i] end
    for i = 65, 70 do p2[#p2 + 1] = list70[i] end
    tsend("alice", "clrPut", { marks = p1, share = false })
    tsend("alice", "clrPut", { marks = p2, share = false })
    tsend("alice", "clrSync", { seq = 0, count = 70, share = false })
    local chunks = {}
    for i = 1, 70 do chunks[i] = { math.floor((20000 + i * 16) / 8), 0 } end
    before = #sent
    CS.applyChunks(chunks, 70)
    local rfs = sentSince(before, "clrRefreshed", "alice")
    check(#rfs == 2 and #rfs[1].args.marks == 64 and rfs[1].args.seq == nil
        and rfs[2].args.seq == CS.authors[HEX_ALICE].store.seq, "16c 刷新分批（64＋6），序號只在最後一包")
end

-- 17. 客戶端：零筆重傳、游標、刷新序號、閘門、只讀、限頻、隊友重建 ---------------------------------------------------
clientFlag, serverFlag = true, false
deliver = nil
do
    local cs0 = CL.slots[0]
    local keepCount, keepMarks = cs0.store.count, cs0.store.marks
    local function quiet()
        clearPending()
        S.syncAt[0], S.putAt[0], S.retry[0], S.srvRO[0], S.reset[0] = nil, nil, nil, nil, nil
    end
    local function tickSent()
        local c0 = #clientSent
        fire("OnTick")
        local out = {}
        for i = c0 + 1, #clientSent do out[#out + 1] = clientSent[i] end
        return out
    end
    -- I2：本機零筆、伺服器有：照樣送帶 reset 的空包
    quiet()
    cs0.store.count, cs0.store.marks = 0, {}
    S.handlers.clrSyncOk(0, { count = 3, seq = cs0.store.refreshSeq, digest = 5 })
    nowMs = nowMs + 5000
    local out = tickSent()
    check(#out == 1 and out[1].command == "clrPut" and out[1].args.reset == true and #out[1].args.marks == 0
        and out[1].args.origin == cs0.store.origin, "17a 本機零筆：送帶 reset 的空包（帶來源碼）")
    cs0.store.count, cs0.store.marks = keepCount, keepMarks
    -- I3：游標改回伺服器的值（回滾）
    quiet()
    cs0.store.refreshSeq = 9000000000000
    S.handlers.clrSyncOk(0, { count = S.relevantCount(cs0), seq = 5,
        digest = C.storeDigest(cs0.store.marks, cs0.store.count) })
    check(cs0.store.refreshSeq == 5, "17b 伺服器序號比本機游標小：游標改回伺服器的值")
    -- I14／N8：伺服器刷新時數早於本機最後掃描（時鐘撥回），但序號新＝照樣套用；處理過的不重套；游標只在帶 seq 的包推進
    local lm = mark(7700, 7700, 300, 10, 10)
    lm.oh, lm.rs = 900, 100
    cs0.store.count = cs0.store.count + 1
    cs0.store.marks[cs0.store.count] = lm
    local srvm = mark(7700, 7700, 0, 0, 10)
    srvm.rh, srvm.rs = 500, 200
    S.handlers.clrRefreshed(0, { marks = { wire(srvm) } })
    check(lm.ch == 0 and lm.rh == 500 and lm.rs == 200, "17c 時鐘撥回：刷新時數比本機掃描早，但序號新＝套用")
    lm.ch, lm.cs = 950, "m"
    S.handlers.clrRefreshed(0, { marks = { wire(srvm) } })
    check(lm.ch == 950, "17d 處理過的刷新不重套")
    check(cs0.store.refreshSeq == 5, "17e 沒帶 seq 的包不推進游標")
    S.handlers.clrRefreshed(0, { marks = {}, seq = 300 })
    check(cs0.store.refreshSeq == 300, "17f 帶 seq 的最後一包處理完才推進")
    -- I7：功能閘門關＝不送、留著；開了補送
    quiet()
    local gate = false
    Core.featureAllowed = function(_, f) if f == "share" then return gate end return true end
    lm.u, cs0.upload = true, true
    nowMs = nowMs + 5000
    out = tickSent()
    check(#out == 0 and lm.u and cs0.upload, "17g 功能閘門關：不送 clrPut，待送的留著")
    gate = true
    out = tickSent()
    check(#out == 1 and out[1].command == "clrPut", "17h 閘門開：補送")
    Core.featureAllowed = nil
    -- N4：被 rate 拒絕只重送那一包；間隔是伺服器的 2 倍以上
    quiet()
    lm.u, cs0.upload = true, true
    nowMs = nowMs + 5000
    out = tickSent()
    local pkt = out[1] and out[1].args
    S.handlers.clrPutFail(0, { reason = "rate", cmd = "clrPut", id = pkt and pkt.id })
    local others = false
    for i = 1, cs0.store.count do if cs0.store.marks[i].u then others = true end end
    check(pkt and not others and not S.reset[0], "17i rate 拒絕：不整份重傳")
    nowMs = nowMs + S.RATE_MS
    out = tickSent()
    check(#out == 1 and out[1].args == pkt, "17j 原樣重送被拒的那一包")
    check(S.RATE_MS >= 2 * CS.RATE_MS, "17k 客戶端間隔至少是伺服器限頻的 2 倍")
    -- N5：只有刪除時也佔用間隔，不會每個 tick 都送
    quiet()
    for i = 1, S.MAX_PUT + 1 do cs0.drops[(7000 + i * 16) .. ",7700,16,16"] = true end
    cs0.upload = true
    nowMs = nowMs + 5000
    out = tickSent()
    check(#out == 1 and out[1].command == "clrDrop" and out[1].args.origin == cs0.store.origin, "17l 送刪除（帶來源碼）")
    nowMs = nowMs + 50
    out = tickSent()
    check(#out == 0, "17m 只刪除時也等間隔")
    -- N12：同步被限頻：排到間隔之後再送
    quiet()
    S.syncSent[0] = nowMs
    S.handlers.clrSyncRate(0, {})
    check(S.syncAt[0] and S.syncAt[0] >= nowMs + S.RATE_MS, "17n clrSyncRate：排到間隔之後重送同步")
    -- N3：伺服器只讀：不對帳、這次登入不上傳，設定頁有原因
    quiet()
    S.handlers.clrSyncOk(0, { count = 999, digest = 1, seq = cs0.store.refreshSeq, readOnly = true })
    check(not cs0.upload and S.srvRO[0], "17o 伺服器只讀：不對帳、不重傳")
    lm.u, cs0.upload = true, true
    nowMs = nowMs + 5000
    out = tickSent()
    check(#out == 0 and Core.clearedShareProblem(0) == "UI_MinidoracatMiniMap_ClearedServerReadOnly",
        "17p 只讀時一次同步後不再送 clrPut，設定頁寫原因")
    S.handlers.clrPutFail(0, { reason = "readonly", cmd = "clrPut" })
    check(S.srvRO[0], "17q clrPutFail readonly 也停")
    quiet()
    -- N6：隊友只有進度變了不重建圖標，已清空集合有增減才重建
    local r0 = CL.rev
    CL.lookup(0, { x = 8800, y = 8800, w = 16, h = 16 }) -- 先建好查找索引
    S.handlers.clrTeamUpsert(0, { a = "zed", marks = { wire(mark(8800, 8800, 0, 3, 10)) } })
    local _, tm = CL.lookup(0, { x = 8800, y = 8800, w = 16, h = 16 })
    check(CL.rev == r0 and tm and tm.m.s == 3, "17r 進度 upsert：不重建圖標，查找照樣讀到")
    S.handlers.clrTeamUpsert(0, { a = "zed", marks = { wire(mark(8800, 8800, 300, 10, 10)) } })
    check(CL.rev == r0 + 1, "17s 已清空 upsert：重建")
    S.handlers.clrTeamUpsert(0, { a = "zed", marks = { wire(mark(8800, 8800, 310, 10, 10)) } })
    check(CL.rev == r0 + 1, "17t 已清空只換時間：不重建")
    S.handlers.clrTeamRemove(0, { a = "zed", keys = { "8800,8800,16,16" } })
    check(CL.rev == r0 + 2, "17u 移掉已清空：重建")
end

-- 18：序號是毫秒級大數；Kahlua 的 % 先把商轉 int（KahluaThread.java:1064），x % 1 在 2^31 以上不是 0，
-- 桌面 Lua 測不出來，所以直接掃已清空四個檔不准用 % 1 判整數（2026-11-08 clrfix-reset 場 3 客戶端游標一直是 0）
do
    local bad = {}
    for _, f in ipairs({ "shared/MinidoracatMiniMap_ClearedCodec.lua", "server/MinidoracatMiniMapClearedShare.lua",
        "client/MinidoracatMiniMap_Cleared.lua", "client/MinidoracatMiniMap_ClearedShare.lua" }) do
        local fh = assert(io.open(LUA .. f, "rb"))
        local n = 0
        for line in fh:lines() do
            n = n + 1
            local code = line:gsub("%-%-.*$", "")
            -- x % 1（判整數）與序號、毫秒、rs／us 取餘數（seq % 1000 這類），兩種在 2^31 以上都會錯
            if code:find("%%%s*1[^%d]") or code:find("%%%s*1$") or code:find("[sS]eq%s*%%") or code:find("[mM]s%s*%%")
                or code:find("%.[ru]s%s*%%") then bad[#bad + 1] = f .. ":" .. n end
        end
        fh:close()
    end
    check(#bad == 0, "18a 已清空的程式不用 % 判整數或取大數的餘數（Kahlua 大數會錯）: " .. table.concat(bad, ", "))
    -- 18b 只是行為記錄、不是回歸防線（桌面 Lua 的 % 不截斷，1794099693707 % 1 == 0 也是真）；防線是上面 18a 的掃描
    local cs0 = CL.slots[0]
    S.applyRefreshed(0, cs0, {}, 1794099693707)
    check(cs0.store.refreshSeq == 1794099693707, "18b 毫秒級序號照樣推進游標")
end

-- 19：2026-11-08 第 2 輪審查修正 ----------------------------------------------------------------------------
local function withUnreadable(paths, fn)
    local real = getFileReader
    getFileReader = function(p, ...) if paths[p] then return nil end return real(p, ...) end
    fn()
    getFileReader = real
end
local function restart()
    CS.index, CS.indexPath, CS.authors, CS.runPending, CS.resetsHead = nil, nil, {}, nil, nil
    fire("OnServerStarted")
end
local ALICE_FILE = DIR .. HEX_ALICE .. ".txt"
local ALICE_BAD = { [ALICE_FILE] = true, [Codec.backupPath(ALICE_FILE)] = true }
-- Q2：作者檔暫時讀不到，不能把它在索引裡的 chunk 刪掉
do
    freshServer()
    tsend("alice", "clrPut", { marks = { wire(mark(600, 600, 300)) }, share = true })
    saveRound()
    restart()
    withUnreadable(ALICE_BAD, function()
        CS.author(HEX_ALICE, "alice")
        CS.indexDirty = true -- 別的原因要寫索引
        saveRound()
    end)
    check(files[DIR .. "index.txt"]:find("\nA\t" .. HEX_ALICE .. "\t1\t1") ~= nil
        and CS.index.chunks["75,75"] and CS.index.chunks["75,75"][HEX_ALICE],
        "19a Q2 作者檔讀不到：索引照留這位作者，chunk 表也不刪")
    restart()
    before = #sent
    tsend("bob", "clrSync", { seq = 0, count = 0, share = true })
    local fromAlice = 0
    for _, sm in ipairs(sentSince(before, "clrTeamSnap", "bob")) do
        for _, e in ipairs(sm.args.marks) do if e.a == "alice" then fromAlice = fromAlice + 1 end end
    end
    check(fromAlice == 1, "19b Q2 恢復後重開：隊友同步照樣拿得到")
end
-- Q3：只讀作者被重置碰到，索引不提交 run；恢復後重開重播
do
    freshServer()
    tsend("alice", "clrPut", { marks = { wire(mark(128, 64, 700, 1, 1)) }, share = true })
    saveRound()
    restart()
    files[RESETS] = resetsFile({ { id = "q3-run", ms = nowMs + 1, chunks = { "16,8" } } })
    nowMs = nowMs + 10
    withUnreadable(ALICE_BAD, function()
        CS.resetsAt = 0
        tickServer()
        saveRound()
    end)
    check(CS.index.run == nil and not files[DIR .. "index.txt"]:find("q3%-run"), "19c Q3 只讀作者被碰到：索引不記 run")
    restart()
    CS.resetsAt = 0
    hours = 1500
    tickServer()
    check(aliceMark(128).ch == 0 and aliceMark(128).rh == 1500, "19d Q3 作者檔恢復後重開：重播套上")
    saveRound()
    check(CS.index.run == "q3-run", "19e Q3 作者寫進去之後才提交")
end
-- Q4：整份重傳兩段式：第一包不刪還沒送到的舊筆，兩包之間照樣刷新，done 才刪沒送到的
do
    freshServer()
    local all = {}
    for i = 1, 70 do all[i] = wire(mark(3000 + i * 16, 3000, 300)) end
    local function part(a, b)
        local t = {}
        for i = a, b do t[#t + 1] = all[i] end
        return t
    end
    tsend("bob", "clrPut", { marks = part(1, 64), share = true })
    tsend("bob", "clrPut", { marks = part(65, 70), share = true })
    local e = CS.authors[C.hex("bob")]
    local function at(x)
        for i = 1, e.store.count do if e.store.marks[i].x == x then return e.store.marks[i] end end
    end
    tsend("bob", "clrPut", { marks = part(1, 64), share = true, reset = true })
    check(e.store.count == 70, "19f Q4 reset 第一包不刪還沒送到的舊筆")
    hours = 1600
    CS.applyChunks({ { 507, 375 }, { 515, 375 } }, 2) -- 第 66 筆（x 4056）、第 70 筆（x 4120）
    check(at(4056).rh == 1600 and at(4120).rh == 1600, "19g Q4 兩包之間照樣刷新還沒送到的筆")
    tsend("bob", "clrPut", { marks = part(65, 69), share = true, done = true })
    check(at(4056).ch == 0 and at(4056).rh == 1600, "19h Q4 後續包帶重置前的已清空：保留伺服器的刷新")
    check(e.store.count == 69 and at(4120) == nil and e.keep[ORIGIN] == nil, "19i Q4 done：刪掉這次沒送到的舊筆")
    -- 中途放棄的整份重傳（沒有 done）：太久沒有下一包就丟掉這次的記錄，之後的一般上傳不被當成重傳中
    tsend("bob", "clrPut", { marks = part(1, 64), share = true, reset = true })
    check(e.keep[ORIGIN] ~= nil, "19i2 Q4 reset 後開始記這次送到的")
    nowMs = nowMs + CS.KEEP_MS + 1
    tsend("bob", "clrPut", { marks = { all[65] }, share = true })
    check(e.keep[ORIGIN] == nil and e.store.count == 69, "19i3 Q4 重傳中途放棄：過期後不再當成重傳中、舊筆不刪")
end
-- Q5（伺服器端）：失敗回覆帶回請求編號
do
    freshServer()
    nowMs = nowMs + 5000
    before = #sent
    send("alice", "clrPut", { marks = { wire(mark(5000, 5000, 300)) }, share = true, id = 41 })
    send("alice", "clrPut", { marks = { wire(mark(5100, 5000, 300)) }, share = true, id = 42 })
    send("alice", "clrDrop", { keys = { "5000,5000,16,16" }, id = 43 })
    send("alice", "clrDrop", { keys = { "5000,5000,16,16" }, id = 44 })
    local f = sentSince(before, "clrPutFail", "alice")
    check(#f == 2 and f[1].args.id == 42 and f[1].args.cmd == "clrPut" and f[2].args.id == 44, "19j Q5 失敗回覆帶回那一包的 id")
end
-- Q7／Q8／Q13：兩台電腦的合併：已清空有效到被刷新為止，再比伺服器序號；同一棟（C.same）只輸出一筆
do
    freshServer()
    local e
    local function rep(x)
        local w, n = CS.mergedWires(e)
        local out = {}
        for i = 1, n do
            local m = C.fromWire(w[i])
            if math.abs(m.x - x) < 8 then out[#out + 1] = m end
        end
        return out
    end
    tsend("bob", "clrPut", { marks = { wire(mark(7000, 7000, 300, 10, 10)) }, share = true, origin = OA })
    e = CS.authors[C.hex("bob")]
    local walk = mark(7000, 7000, 0, 3, 10)
    walk.vh, walk.oh = 9000, 9000 -- 另一台後來（遊戲時數大）走進去翻了幾格
    tsend("bob", "clrPut", { marks = { wire(walk) }, share = true, origin = OB })
    local r = rep(7000)
    check(#r == 1 and r[1].ch == 300, "19k Q13 另一台後來翻幾格：已清空照樣是代表")
    local back = mark(7000, 7000, 50, 10, 10)
    back.vh, back.oh = 40, 40 -- 管理員撥回時鐘後另一台清空：遊戲時數小，但是後送到的
    tsend("bob", "clrPut", { marks = { wire(back) }, share = true, origin = OB })
    r = rep(7000)
    check(#r == 1 and r[1].ch == 50, "19l Q7 兩台都清空：比伺服器序號、不比遊戲時數")
    hours = 1700
    CS.applyChunks({ { 875, 875 } }, 1)
    r = rep(7000)
    check(#r == 1 and r[1].ch == 0 and r[1].rh == 1700, "19m 刷新後兩台都是已刷新")
    local again = mark(7000, 7000, 1800, 10, 10)
    local oa
    for i = 1, e.store.count do if e.store.marks[i].o == OA then oa = e.store.marks[i] end end
    again.rs = oa.rs -- 處理過這次刷新
    tsend("bob", "clrPut", { marks = { wire(again) }, share = true, origin = OA })
    r = rep(7000)
    check(#r == 1 and r[1].ch == 1800, "19n 刷新之後再清空的那台是代表")
    -- Q8：同一棟、外框不同（地上／地下）的兩台：只輸出一筆，增量更新拿掉另一個外框
    tsend("bob", "clrPut", { marks = { wire(mark(7400, 7000, 300, 10, 10)) }, share = true, origin = OA })
    local under = C.newMark(7402, 7001, 14, 15)
    under.vh, under.oh, under.s, under.n, under.t = 9000, 9000, 2, 10, 1
    before = #sent
    tsend("bob", "clrPut", { marks = { wire(under) }, share = true, origin = OB })
    r = rep(7400)
    check(#r == 1 and r[1].x == 7400 and r[1].ch == 300, "19o Q8 同一棟不同外框：只輸出一筆（已清空那台）")
    local up, rm = sentSince(before, "clrTeamUpsert", "alice"), sentSince(before, "clrTeamRemove", "alice")
    local upKey = up[1] and C.key(C.fromWire(up[1].args.marks[1]))
    local rmKeys = {}
    for _, k in ipairs(rm[1] and rm[1].args.keys or {}) do rmKeys[k] = true end
    check(upKey == "7400,7000,16,16" and rmKeys["7402,7001,14,15"] and not rmKeys["7400,7000,16,16"],
        "19p Q8 增量：送代表那筆、拿掉同棟另一個外框")
end
-- Q12：線上重置：RUN 毫秒（開始移檔）早於 B2 刷新，之後又清空的不被清單蓋回已刷新
do
    freshServer()
    tsend("alice", "clrPut", { marks = { wire(mark(128, 64, 700, 1, 1)) }, share = true })
    local runMs = nowMs
    nowMs = nowMs + 5000
    hours = 1900
    CS.applyChunks({ { 16, 8 } }, 1) -- 移檔之後有人走過去：B2
    local again = mark(128, 64, 1950, 1, 1)
    again.rs = aliceMark(128).rs
    tsend("alice", "clrPut", { marks = { wire(again) }, share = true })
    files[RESETS] = resetsFile({ { id = "online-1", ms = runMs, chunks = { "16,8" } } })
    CS.resetsAt = 0
    tickServer()
    check(aliceMark(128).ch == 1950, "19q Q12 RUN 早於這筆的刷新序號：跳過")
    nowMs = nowMs + 100
    files[RESETS] = resetsFile({ { id = "online-2", ms = nowMs, chunks = { "16,8" } },
        { id = "online-1", ms = runMs, chunks = { "16,8" } } })
    nowMs = nowMs + CS.RESETS_CHECK_MS + 1
    hours = 2000
    tickServer()
    check(aliceMark(128).ch == 0 and aliceMark(128).rh == 2000, "19r Q12 RUN 晚於這筆的刷新序號：照常刷新")
end
-- Q10：本機數量超過上限時，摘要照線上格式夾（本機摘要＝wire 來回的摘要）
do
    local big = mark(1, 1, 0, 5, 10)
    big.n, big.s = 250000, 120000
    check(C.digest(big) == C.digest(C.fromWire(C.toWire(big))), "19s Q10 數量超過上限：本機摘要＝送出去的摘要")
end
-- 客戶端 ------------------------------------------------------------------------------------------
serverFlag, clientFlag = false, true
-- Q1：外框超過網路上限：本機照存、讀得回來，不上傳、不算對帳；超過本機上限的不記
do
    local cs0 = CL.slots[0]
    local wide = C.newMark(9000, 9000, 600, 20)
    wide.vh, wide.ch, wide.cs, wide.oh = 1, 5, "m", 1
    local text = C.encodeClient({ refreshSeq = 0, origin = "abcdabcd", count = 1, marks = { wide } })
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local back = C.decodeClient(lines, #lines)
    check(back and back.count == 1 and back.marks[1].w == 600, "19t Q1 本機檔收超過網路上限的外框（讀得回來）")
    local _, cnt = C.storeDigest({ wide }, 1)
    check(not C.uploadable(wide) and cnt == 0, "19u Q1 超過網路上限：不上傳、不算進對帳")
    local before = S.relevantCount(cs0)
    cs0.store.count = cs0.store.count + 1
    cs0.store.marks[cs0.store.count] = wide
    check(S.relevantCount(cs0) == before, "19v Q1 同步帶的筆數不算它")
    cs0.store.marks[cs0.store.count] = nil
    cs0.store.count = cs0.store.count - 1
    check(CL.add(cs0, { x = 1, y = 1, w = 4001, h = 10 }) == nil, "19w Q1 超過本機上限的外框不記")
end
-- Q5（客戶端）：好幾包在途，依 id 找回被拒的那一包
do
    local cs0 = CL.slots[0]
    S.sent[0], S.retry[0] = nil, nil
    S.send(0, P.alice, "clrPut", { marks = { "first" } })
    local id1 = S.nextId
    S.send(0, P.alice, "clrDrop", { keys = { "77,77,16,16" } })
    local id2 = S.nextId
    S.send(0, P.alice, "clrPut", { marks = { "third" } })
    S.handlers.clrPutFail(0, { reason = "rate", cmd = "clrPut", id = id1 })
    check(S.retry[0] and S.retry[0][1] and S.retry[0][1].marks[1] == "first", "19x Q5 依 id 重送被拒的第一包，不是最後送的")
    S.handlers.clrPutFail(0, { reason = "rate", cmd = "clrDrop", id = id2 })
    check(cs0.drops["77,77,16,16"] == true, "19y Q5 被拒的刪除依 id 放回")
    -- 被拒的是整份重傳的第一包（帶 reset）：從頭再來，不排進重送（重送會排在之後已收下的包後面）
    local uFlags = {}
    for i = 1, cs0.store.count do uFlags[i] = cs0.store.marks[i].u end
    S.reset[0], S.resetting[0] = nil, nil
    S.send(0, P.alice, "clrPut", { marks = { "r1" }, reset = true })
    S.handlers.clrPutFail(0, { reason = "rate", cmd = "clrPut", id = S.nextId })
    check(S.reset[0] == true and S.resetting[0] == true and #S.retry[0] == 1,
        "19y2 被拒的是帶 reset 的第一包：整份重傳重來，不排進重送")
    for i = 1, cs0.store.count do cs0.store.marks[i].u = uFlags[i] end
    S.reset[0], S.resetting[0] = nil, nil
    cs0.drops["77,77,16,16"], S.retry[0], cs0.upload = nil, nil, nil
end
-- Q9：隊友或自己的進度變了，搜尋看的資料版本也變
do
    local r0 = Core.clearedDataRevision()
    S.teamChanged(false)
    local r1 = Core.clearedDataRevision()
    CL.dirty(CL.slots[0])
    check(r1 > r0 and Core.clearedDataRevision() > r1, "19z Q9 隊友進度、自己的資料變了：搜尋的資料版本前進")
end
-- Q6：手動標過、第一次真的走進去：圖標要重建
do
    local cs0 = CL.slots[0]
    local hand = C.newMark(9500, 9500, 10, 10)
    hand.ch, hand.cs = 5, "m"
    cs0.store.count = cs0.store.count + 1
    cs0.store.marks[cs0.store.count] = hand
    local rev = CL.rev
    local def = { getX = function() return 9500 end, getY = function() return 9500 end,
        getW = function() return 10 end, getH = function() return 10 end }
    CL.visit(0, cs0, def)
    check(hand.vh > 0 and CL.rev > rev, "19A Q6 第一次走進手動標過的建築：圖標重建")
end
-- Q11：新 chunk 記滿要丟之前，先把有帳號檔的玩家建好 slot（晚加入也收得到刷新）
do
    serverFlag, clientFlag = false, false
    local keepMax, keepN, keepList = CL.NEW_MAX, CL.newN, CL.newChunks
    CL.NEW_MAX, CL.newN, CL.newChunks, CL.adopted = 1, 1, { { 0, 0 } }, false
    local m1 = C.newMark(2000, 2000, 16, 16)
    m1.vh, m1.ch, m1.cs, m1.oh = 1, 5, "m", 1
    local path = CL.path(1)
    files[path] = C.encodeClient({ refreshSeq = 0, origin = "cdcdcdcd", count = 1, marks = { m1 } })
    CL.slots[1] = nil
    fire("LoadChunk", chunkAt(2000, 2000, true))
    local s1 = CL.slots[1]
    check(s1 and s1.store.marks[1].ch == 0 and s1.store.marks[1].rh > 0, "19B Q11 記滿之後：有帳號檔的晚加入玩家照樣收到刷新")
    CL.slots[1], files[path] = nil, nil
    CL.NEW_MAX, CL.newN, CL.newChunks = keepMax, keepN, keepList
    serverFlag, clientFlag = false, true
end

-- 20：第 2 輪審查 Q14–Q22 ------------------------------------------------------------------------------
serverFlag, clientFlag = true, false
-- Q14（伺服器端）：保留伺服器刷新的那筆回送給這台電腦
do
    freshServer()
    tsend("alice", "clrPut", { marks = { wire(mark(128, 64, 700, 1, 1)) }, share = true })
    hours = 2100
    CS.applyChunks({ { 16, 8 } }, 1)
    before = #sent
    tsend("alice", "clrPut", { marks = { wire(mark(128, 64, 700, 1, 1)) }, share = true }) -- 錯過刷新、rs 舊
    local rf = sentSince(before, "clrRefreshed", "alice")
    check(aliceMark(128).ch == 0 and #rf == 1 and #rf[1].args.marks == 1 and rf[1].args.seq == nil,
        "20a Q14 保留伺服器的刷新時回送那一筆給這台（不帶 seq）")
end
-- Q15：同步只更新記憶體裡的時間，不讓作者 dirty
do
    freshServer()
    tsend("alice", "clrPut", { marks = { wire(mark(600, 600, 300)) }, share = true })
    saveRound()
    local e = CS.authors[HEX_ALICE]
    tsend("alice", "clrSync", { seq = 0, count = 1, share = true })
    check(e.dirty ~= true and e.store.origins[ORIGIN] == nowMs, "20b Q15 同步不讓作者重寫檔（時間只記在記憶體）")
end
-- Q17：沒開分享時不做合併
do
    freshServer()
    local calls, real = 0, CS.mergedWires
    CS.mergedWires = function(...) calls = calls + 1 return real(...) end
    tsend("dave", "clrPut", { marks = { wire(mark(600, 600, 300)) }, share = false })
    tsend("dave", "clrPut", { marks = { wire(mark(700, 600, 300)) }, share = false })
    CS.mergedWires = real
    check(calls == 0, "20c Q17 作者沒開分享：不做合併")
end
-- Q20：手動標、沒走進去過（vh＝0）的建築，新 chunk（第一次生成也是）不刷新；B3 照套
do
    freshServer()
    local hand = mark(128, 64, 700, 1, 1)
    hand.vh = 0
    tsend("alice", "clrPut", { marks = { wire(hand) }, share = true })
    hours = 2200
    CS.applyChunks({ { 16, 8 } }, 1)
    check(aliceMark(128).ch == 700, "20d Q20 沒走進去過的手動標記：新 chunk 不刷新")
    CS.applyChunks({ { 16, 8, nowMs + 1 } }, 1)
    check(aliceMark(128).ch == 0, "20e Q20 重置清單照套")
end
-- Q21：外框在世界範圍外整包拒收；chunk 表只在記憶體（開服重建），作者淘汰後照樣找得到
do
    freshServer()
    CS.wb = { x0 = 0, y0 = 0, x1 = 20000, y1 = 20000 }
    before = #sent
    tsend("alice", "clrPut", { marks = { wire(mark(-5000, 600, 300)) }, share = true })
    check(lastFail("alice") and lastFail("alice").reason == "invalid" and CS.authors[HEX_ALICE] == nil,
        "20f Q21 世界範圍外的外框拒收")
    CS.wb = nil
    tsend("alice", "clrPut", { marks = { wire(mark(600, 600, 300)) }, share = true })
    saveRound()
    -- 整份重傳換成另一棟（筆數、分享都沒變）：chunk 表跟著換，索引不用重寫
    tsend("alice", "clrPut", { marks = { wire(mark(800, 600, 300)) }, share = true, reset = true, done = true })
    check(CS.index.chunks["100,75"] and CS.index.chunks["100,75"][HEX_ALICE] and not CS.index.chunks["75,75"]
        and CS.indexDirty == false, "20m Q21 只有 chunk 變：記憶體的表跟著換、索引不重寫")
    saveRound()
    check(files[DIR .. "index.txt"]:find("\nC\t") == nil, "20n Q21 索引檔沒有 chunk 行")
    -- 淘汰（不在線、閒置 EVICT_MS）後 B2 照樣找得到這位作者
    tsend("ivy", "clrPut", { marks = { wire(mark(1600, 600, 300)) }, share = false })
    saveRound()
    nowMs = nowMs + CS.EVICT_MS + 1
    CS.evict(nowMs)
    check(CS.authors[C.hex("ivy")] == nil, "20o 前提：ivy 被淘汰")
    hours = 2300
    CS.applyChunks({ { 200, 75 } }, 1)
    local ie = CS.authors[C.hex("ivy")]
    check(ie and ie.store.marks[1].rh == 2300 and ie.store.marks[1].ch == 0, "20o Q21 作者淘汰後 B2 照樣刷新他的標記")
    -- 開服時作者檔讀不到：不知道他的 chunk，重置 run 不提交；讀得到之後才提交
    withUnreadable(ALICE_BAD, function() restart() end)
    check(CS.missing[HEX_ALICE] == true, "20p 前提：開服時 alice 讀不到")
    files[RESETS] = resetsFile({ { id = "q21-run", ms = nowMs + 1, chunks = { "200,75" } } })
    nowMs = nowMs + 10
    CS.resetsAt = 0
    tickServer()
    saveRound()
    check(CS.runPending and CS.index.run == nil and not files[DIR .. "index.txt"]:find("q21%-run"),
        "20p Q21 開服讀不到的作者：重置 run 不提交")
    CS.author(HEX_ALICE, "alice")
    saveRound()
    check(CS.index.run == "q21-run" and next(CS.missing) == nil, "20q Q21 讀得到之後才提交")
end
-- Q21（clrPut 增量，2026-11-08 實測 2950 筆整份重傳每包 18–31 ms）：CS.track 維護的索引與合計和從 store 重算的一樣；
-- 整份重傳每包只看這包的外框鍵；線上沒有看得到的人不算合併
do
    freshServer()
    local function consistent(e)
        local at, cnt, cost, total, kN, kC = {}, {}, {}, 0, {}, {}
        local st = e.store
        for i = 1, st.count do
            local m = st.marks[i]
            local key, c = C.key(m), C.chunkCost(m)
            at[m.o] = at[m.o] or {}
            if at[m.o][key] then return false, "dup " .. key end
            at[m.o][key] = m
            cnt[m.o], cost[m.o], total = (cnt[m.o] or 0) + 1, (cost[m.o] or 0) + c, total + c
            local keep = e.keep[m.o]
            if keep and keep[key] then kN[m.o], kC[m.o] = (kN[m.o] or 0) + 1, (kC[m.o] or 0) + c end
        end
        if total ~= e.total then return false, "total" end
        for o, map in pairs(e.at) do
            for key, m in pairs(map) do
                if not (at[o] and at[o][key] == m) then return false, "at " .. key end
            end
            if (cnt[o] or 0) ~= (e.cnt[o] or 0) or (cost[o] or 0) ~= (e.cost[o] or 0) then return false, "cnt " .. o end
            if e.keep[o] and ((kN[o] or 0) ~= (e.keepN[o] or 0) or (kC[o] or 0) ~= (e.keepCost[o] or 0)) then
                return false, "keep " .. o
            end
        end
        for o, map in pairs(at) do
            for key in pairs(map) do
                if not (e.at[o] and e.at[o][key]) then return false, "missing " .. key end
            end
        end
        return true
    end
    local function put(origin, list, extra)
        local args = { marks = {}, share = true, origin = origin }
        for i, m in ipairs(list) do args.marks[i] = wire(m) end
        for k, v in pairs(extra or {}) do args[k] = v end
        tsend("alice", "clrPut", args)
    end
    local function big(x, y) -- 跨好幾個 chunk 的外框：預算合計錯了才看得出來
        local m = mark(x, y, 300)
        m.w, m.h = 40, 24
        return m
    end
    put(ORIGIN, { mark(600, 600, 300), big(700, 600), mark(800, 600, 300) })
    local e = CS.authors[HEX_ALICE]
    local ok, why = consistent(e)
    check(ok, "20r Q21 增量索引：一般上傳後和重算一致 " .. tostring(why))
    put(ORIGIN, { big(700, 600), mark(900, 600, 300) }, { reset = true })
    ok, why = consistent(e)
    check(ok and e.keepN[ORIGIN] == 2 and e.keepCost[ORIGIN] == C.chunkCost(big(700, 600)) + C.chunkCost(mark(900, 600, 300)),
        "20r Q21 整份重傳中：keep 的筆數與 chunk 數 " .. tostring(why))
    tsend("alice", "clrDrop", { keys = { C.key(big(700, 600)) }, origin = ORIGIN })
    ok, why = consistent(e)
    check(ok and e.keepN[ORIGIN] == 1, "20r Q21 重傳中刪掉 keep 裡的一筆：合計跟著扣 " .. tostring(why))
    put(ORIGIN, { mark(1000, 600, 300) }, { done = true })
    ok, why = consistent(e)
    check(ok and e.store.count == 2, "20r Q21 done 刪掉沒再送到的：索引一致 " .. tostring(why))
    for i = 1, 4 do put(string.format("dddd%04d", i), { mark(600 + i * 16, 700, 300) }) end
    ok, why = consistent(e)
    check(ok and e.store.on == 4, "20r Q21 第 5 台電腦擠掉最久沒同步的那台：索引一致 " .. tostring(why))
    -- 整份重傳每包只看這包的外框鍵：2048 筆的作者（有線上隊友）送 64 筆的 reset 包，C.key 呼叫數跟包走、不跟總筆數走
    freshServer()
    for k = 0, 31 do
        local list = {}
        for i = 1, 64 do list[i] = mark(((k * 64 + i) % 64) * 16, 30000 + k * 16, 300) end
        put(ORIGIN, list)
    end
    e = CS.authors[HEX_ALICE]
    check(e.store.count == 2048, "20s 前提：2048 筆")
    local list = {}
    for i = 1, 64 do list[i] = mark((i % 64) * 16, 30000, 300) end
    local keyCalls, realKey = 0, C.key
    C.key = function(m) keyCalls = keyCalls + 1; return realKey(m) end
    before = #sent
    put(ORIGIN, list, { reset = true })
    C.key = realKey
    check(#sentSince(before, "clrTeamUpsert") > 0 and keyCalls < 64 * 8,
        "20s Q21 整份重傳一包只看這包的外框鍵（C.key " .. keyCalls .. " 次）")
    ok, why = consistent(e)
    check(ok, "20s Q21 整份重傳後索引一致 " .. tostring(why))
    -- 沒有線上看得到的人：不算合併（gina 不在任何陣營或安全屋）
    tsend("gina", "clrPut", { marks = { wire(mark(5000, 5000, 300)) }, share = true })
    local merges, realMerged = 0, CS.mergedWires
    CS.mergedWires = function(...) merges = merges + 1; return realMerged(...) end
    tsend("gina", "clrPut", { marks = { wire(mark(5000, 5016, 300)) }, share = true })
    CS.mergedWires = realMerged
    check(CS.authors[C.hex("gina")].store.count == 2 and merges == 0, "20t Q21 線上沒有看得到的人：不算合併")
end
-- B4／Q12：作者已套用到某個 RUN（rms），重播時那之後才新標的（rs＝0）不被刷新
do
    serverFlag, clientFlag = true, false
    freshServer()
    tsend("alice", "clrPut", { marks = { wire(mark(128, 64, 700, 1, 1)) }, share = true })
    local e = CS.authors[HEX_ALICE]
    e.store.rms = nowMs + 50
    CS.applyChunks({ { 16, 8, nowMs + 50 } }, 1)
    check(aliceMark(128).ch == 700, "20l 作者已套用過的 RUN 重播：之後新標的不被刷新（rms）")
end
-- Q14（客戶端）：這次登入第一包 clrSyncOk 前的 clrRefreshed 不推游標
do
    serverFlag, clientFlag = false, true
    local cs0 = CL.slots[0]
    S.synced[0] = nil
    cs0.store.refreshSeq = 10
    S.handlers.clrRefreshed(0, { to = "alice", marks = {}, seq = 999 })
    check(cs0.store.refreshSeq == 10, "20i Q14 同步之前的刷新不推游標")
    S.handlers.clrSyncOk(0, { to = "alice", count = S.relevantCount(cs0), seq = 20,
        digest = C.storeDigest(cs0.store.marks, cs0.store.count) })
    S.handlers.clrRefreshed(0, { to = "alice", marks = {}, seq = 30 })
    check(cs0.store.refreshSeq == 30, "20j Q14 同步之後照常推進")
    -- Q20（單機 B2）：沒走進去過的手動標記，新 chunk 不刷新
    local hand = C.newMark(9800, 9800, 8, 8)
    hand.ch, hand.cs = 5, "m"
    cs0.store.count = cs0.store.count + 1
    cs0.store.marks[cs0.store.count] = hand
    CL.refreshChunk(cs0, 1225, 1225)
    check(hand.ch == 5, "20k Q20 單機：沒走進去過的手動標記遇到新 chunk 不刷新")
    cs0.store.marks[cs0.store.count] = nil
    cs0.store.count = cs0.store.count - 1
end

-- 21. 拿過（2026-11-08 使用者裁定）：翻過進度只在拿過東西或已清空後才上傳、分享 ---------------------------------
do
    freshServer()
    before = #sent
    tsend("alice", "clrPut", { marks = { wire(mark(64, 64, 0, 3, 10, 0)) }, share = true })
    local f = lastFail("alice")
    check(f and f.reason == "invalid" and CS.authors[HEX_ALICE] == nil and #sentSince(before, "clrTeamUpsert", "bob") == 0,
        "21a 伺服器拒收只有進度、沒拿過的 clrPut（隊友收不到）")
    before = #sent
    tsend("alice", "clrPut", { marks = { wire(mark(64, 64, 0, 3, 10, 1)) }, share = true })
    check(CS.authors[HEX_ALICE].store.count == 1 and aliceMark(64).t == 1 and #sentSince(before, "clrTeamUpsert", "bob") == 1,
        "21b 拿過才收、轉送給隊友")
    tsend("alice", "clrPut", { marks = { wire(mark(96, 64, 300, 0, 10, 0)) }, share = true })
    check(CS.authors[HEX_ALICE].store.count == 2, "21c 已清空不論拿沒拿都收")
    saveRound()
    check(files[ALICE_FILE]:find("\nB\t64\t64\t16\t16\t[^\n]*\t1\t" .. ORIGIN .. "\t%d+\n") ~= nil,
        "21d 作者檔 B 行帶拿過（15 欄＋來源碼＋us）")
    restart()
    CS.author(HEX_ALICE, "alice")
    check(aliceMark(64).t == 1 and aliceMark(96).t == 0, "21e 作者檔寫出後讀回一致")
    CS.applyChunks({ { 8, 8 } }, 1)
    check(aliceMark(64).t == 0 and aliceMark(64).rh > 0 and aliceMark(64).s == 0, "21f 伺服器 B2 刷新：拿過歸零")
end
do
    serverFlag, clientFlag = false, true
    local cs0 = CL.slots[0]
    local n0, d0 = S.relevantCount(cs0), C.storeDigest(cs0.store.marks, cs0.store.count)
    local look = C.newMark(9600, 9600, 8, 8)
    look.vh, look.n = 5, 4
    cs0.store.count = cs0.store.count + 1
    cs0.store.marks[cs0.store.count] = look
    local was = C.relevant(look)
    look.s = 2
    CL.touch(cs0, look, was)
    check(not look.u and S.relevantCount(cs0) == n0 and C.storeDigest(cs0.store.marks, cs0.store.count) == d0,
        "21g 只翻過沒拿：不標待上傳、不進對帳筆數與摘要")
    local function flushed()
        S.putAt[0], S.retry[0], cs0.drops, cs0.upload = 0, nil, {}, true
        local c0 = #clientSent
        S.flush(0, P.alice, cs0, nowMs)
        for i = c0 + 1, #clientSent do
            for _, w in ipairs(clientSent[i].args.marks or {}) do
                if w:find("^9600,9600,") then return C.fromWire(w) end
            end
        end
        return nil
    end
    check(flushed() == nil, "21h 只翻過沒拿：不送")
    was = C.relevant(look)
    look.t = 1
    CL.touch(cs0, look, was)
    check(look.u and S.relevantCount(cs0) == n0 + 1 and C.storeDigest(cs0.store.marks, cs0.store.count) ~= d0,
        "21i 拿過：標待上傳、算進對帳筆數與摘要")
    local got = flushed()
    check(got and got.t == 1 and got.s == 2, "21j 拿過：送出（帶拿過與翻過數）")
    cs0.store.marks[cs0.store.count] = nil
    cs0.store.count = cs0.store.count - 1
end

print("cleared share assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
