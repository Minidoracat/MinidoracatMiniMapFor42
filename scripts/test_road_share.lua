-- 自訂道路分享：伺服器（存檔、作者、rev、限制、收件人、沙盒）與客戶端（to 分桶、snap 收齊才替換）。
-- 用真的 RoadCodec（記憶體假檔案系統），伺服器送出的封包直接餵給客戶端處理器。
-- 用法：lua scripts/test_road_share.lua
local LUA = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/"

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end

-- 假 Java ---------------------------------------------------------------------------
local function jlist(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end,
        contains = function(_, v) for i = 1, #t do if t[i] == v then return true end end return false end }
end
local factions = { { name = "blue", owner = "alice", players = { "bob" } } }
local houses = { { owner = "carol", players = { "alice" } } }
local function allowed(h, name)
    if h.owner == name then return true end
    for i = 1, #h.players do if h.players[i] == name then return true end end
    return false
end
local function factionObj(f)
    return { getName = function() return f.name end, getOwner = function() return f.owner end,
        getPlayers = function() return jlist(f.players) end }
end
Faction = { getPlayerFaction = function(name)
    for i = 1, #factions do if allowed(factions[i], name) then return factionObj(factions[i]) end end
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
    isInSameSafehouse = function(a, b) -- 字串版：只看名單（SafeHouse.java:795）
        for i = 1, #houses do if allowed(houses[i], a) and allowed(houses[i], b) then return true end end
        return false
    end,
    hasSafehouse = function(name)
        for i = 1, #houses do if allowed(houses[i], name) then return houses[i] end end
        return nil
    end,
}

-- 記憶體檔案系統（getFileWriter 開檔即截斷；writeBroken＝寫不進去）---------------------
local files, unreadable, writeBroken = {}, {}, false
function cacheFileExists(path) return files[path] ~= nil end
function getFileReader(path)
    if unreadable[path] or files[path] == nil then return nil end
    local lines, i = {}, 0
    for line in (files[path] .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if files[path] == "" then lines = {} end
    return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
end
local bakBroken = false -- 只有備份檔（.bak.txt）寫不進去
function getFileWriter(path)
    files[path] = ""
    local lost = writeBroken or (bakBroken and path:match("%.bak%.txt$"))
    return { write = function(_, text) if not lost then files[path] = files[path] .. text end end,
        close = function() end }
end

local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end }
    rawset(t, name, e)
    return e
end })
local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

local now = 100000
function getTimestampMs() return now end
local worldName = "w1"
function getWorld() return { getWorld = function() return worldName end } end
local policyOn = true
local policy = { readBool = function(name, default)
    if name == "AllowRoadShare" then return policyOn end
    return default
end }
MinidoracatMiniMapPolicy = policy
local isClientFlag = false
function isClient() return isClientFlag end

local function player(name, pn)
    return { getUsername = function() return name end, getOnlineID = function() return 1 end,
        getPlayerNum = function() return pn end }
end
local P = { alice = player("alice"), bob = player("bob"), carol = player("carol"), dave = player("dave"),
    admin = player("admin") }
function getOnlinePlayers() return jlist({ P.alice, P.bob, P.carol, P.dave, P.admin }) end
local sent = {}
function sendServerCommand(target, module, command, args)
    sent[#sent + 1] = { to = target:getUsername(), module = module, command = command, args = args }
end

dofile(LUA .. "shared/MinidoracatMiniMap_RoadCodec.lua")
local Codec = MinidoracatMiniMapRoadCodec
local function loadWithTail(path, tail)
    local fh = assert(io.open(path, "rb"))
    local src = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    return assert(load(src .. "\n" .. tail, "@" .. path))()
end
local RS = loadWithTail(LUA .. "server/MinidoracatMiniMapRoadShare.lua", "return RS")
local function send(who, command, args)
    for _, fn in ipairs(handlers.OnClientCommand) do fn("MinidoracatMiniMapRoads", command, P[who], args) end
end

local function road(id, rev, share, n, origin)
    local pts = {}
    for i = 0, (n or 2) - 1 do pts[#pts + 1] = i * 10; pts[#pts + 1] = 0 end
    local w, s = {}, {}
    for i = 1, (n or 2) - 1 do w[i] = 4; s[i] = "dirt" end
    return { id = id, origin = origin or "aaaaaaaa", name = "Road " .. id, source = "draw", rev = rev, enabled = true,
        ends = { "snap", "free" }, share = share or { faction = true, safehouse = false }, pts = pts, segWidth = w,
        segSurface = s }
end
local function put(who, r, extra)
    local args = { lid = Codec.lid(r), sid = r.sid, rev = r.rev, road = Codec.toWire(r) }
    for k, v in pairs(extra or {}) do args[k] = v end
    send(who, "roadPut", args)
end
local function sentSince(from, command)
    local out = {}
    for i = from + 1, #sent do if not command or sent[i].command == command then out[#out + 1] = sent[i] end end
    return out
end
local function last() return sent[#sent] end
local function storedRevs()
    local out = {}
    for i = 1, RS.store.count do local r = RS.store.roads[i]; out[r.author .. ":" .. r.id] = r.rev end
    return out
end

--------------------------------------------------------------------------------
-- 1. 作者取自連線、不信 wire 的 author／sid；只有看得到的人收到 upsert（管理員不會）
--------------------------------------------------------------------------------
local forged = road("r1", 1)
forged.author, forged.sid = "mallory", "s99"
local mark = #sent
put("alice", forged)
local ok = sentSince(mark, "roadPutOk")[1]
check(ok and ok.to == "alice" and ok.args.to == "alice" and ok.args.lid == "aaaaaaaa:r1" and ok.args.sid == "s1",
    "roadPutOk to author with server-assigned sid")
check(RS.store.count == 1 and RS.store.roads[1].author == "alice" and RS.store.roads[1].sid == "s1",
    "stored author is the connected account, not the wire")
check(ok and ok.args.members == 1 and ok.args.online == 1, "faction share: 1 member, 1 online")
local ups = sentSince(mark, "roadUpsert")
check(#ups == 1 and ups[1].to == "bob" and ups[1].args.to == "bob" and ups[1].args.road.author == "alice",
    "upsert only to the faction member (not author, outsider, admin)")
local saved = Codec.readStore(RS.loadedPath, Codec.SERVER_TAG)
check(saved and saved.count == 1 and saved.roads[1].sid == "s1", "server file written and readable")

--------------------------------------------------------------------------------
-- 2. rev：相等＝重送（不算頻率、不重送 upsert）；較舊被拒；每秒 1 次
--------------------------------------------------------------------------------
mark = #sent
put("alice", road("r1", 1))
check(#sentSince(mark, "roadPutOk") == 1 and last().args.sid == "s1" and #sentSince(mark, "roadUpsert") == 0,
    "same rev = resend: same result, no rebroadcast")
mark = #sent
put("alice", road("r1", 2, { faction = true, safehouse = true }))
check(last().command == "roadPutFail" and last().args.reason == "rate", "second put within 1s is rate limited")
now = now + 1000
mark = #sent
put("alice", road("r1", 2, { faction = true, safehouse = true }))
ups = sentSince(mark, "roadUpsert")
check(last().command == "roadPutOk" and last().args.members == 2 and last().args.online == 2 and #ups == 2,
    "rev 2 with safehouse reaches faction member and safehouse owner")
now = now + 1000
put("alice", road("r1", 1))
check(last().command == "roadPutFail" and last().args.reason == "invalid" and storedRevs()["alice:r1"] == 2,
    "lower rev never overwrites (rev 1 after 2)")
now = now + 1000
-- 換分享對象：只看得到舊版的人收到 roadRemove
mark = #sent
put("alice", road("r1", 3, { faction = false, safehouse = true }))
local rem = sentSince(mark, "roadRemove")
check(#rem == 1 and rem[1].to == "bob" and rem[1].args.sid == "s1", "dropped audience gets roadRemove")

--------------------------------------------------------------------------------
-- 3. 非作者不能 drop、不能拿別人的 sid 覆寫
--------------------------------------------------------------------------------
send("bob", "roadDrop", { sid = "s1" })
check(last().command == "roadDropFail" and last().to == "bob" and last().args.reason == "notowner"
    and RS.store.count == 1, "non-author drop refused, road kept")
now = now + 1000
local steal = road("r1", 9)
steal.sid = "s1"
put("bob", steal)
check(last().command == "roadPutFail" and last().args.reason == "notowner" and RS.store.roads[1].author == "alice"
    and storedRevs()["alice:r1"] == 3, "non-author put with someone else's sid refused")

--------------------------------------------------------------------------------
-- 4. 每人最多 30 條（更新既有的不算新增）
--------------------------------------------------------------------------------
for i = 2, 30 do
    now = now + 1000
    put("alice", road("r" .. i, 1))
end
check(RS.store.count == 30 and last().command == "roadPutOk", "30 roads accepted")
now = now + 1000
put("alice", road("r31", 1))
check(last().command == "roadPutFail" and last().args.reason == "limit" and RS.store.count == 30, "31st road refused")
now = now + 1000
put("alice", road("r2", 2))
check(last().command == "roadPutOk", "updating an existing road at the limit still works")
now = now + 1000
put("dave", road("r1", 1))
check(last().command == "roadPutOk" and last().to == "dave", "limit is per author")

--------------------------------------------------------------------------------
-- 5. 寫檔失敗回 savefailed、不換上、不轉送
--------------------------------------------------------------------------------
writeBroken = true
now = now + 1000
mark = #sent
put("alice", road("r2", 3))
writeBroken = false
check(last().command == "roadPutFail" and last().args.reason == "savefailed", "write failure reports savefailed")
check(storedRevs()["alice:r2"] == 2 and #sentSince(mark, "roadUpsert") == 0, "failed save keeps old road, no upsert")
now = now + 1000
put("alice", road("r2", 3))
check(last().command == "roadPutOk" and storedRevs()["alice:r2"] == 3, "same rev succeeds once the disk works again")

--------------------------------------------------------------------------------
-- 6. 讀不懂的檔＝只讀；壞檔（invalid）可以覆寫
--------------------------------------------------------------------------------
worldName = "w2"
local p2 = RS.path(Codec)
files[p2] = "MMROADSRV\t9\t1\nEND\t0"
now = now + 1000
put("alice", road("r1", 1))
check(last().args.reason == "readonly" and files[p2] == "MMROADSRV\t9\t1\nEND\t0", "newer schema file is read-only")
worldName = "w3"
local p3 = RS.path(Codec)
files[p3] = "x"
unreadable[p3] = true
now = now + 1000
put("alice", road("r1", 1))
check(last().args.reason == "readonly" and files[p3] == "x", "unreadable file is read-only, not overwritten")
worldName = "w4"
files[RS.path(Codec)] = "garbage"
now = now + 1000
put("alice", road("r1", 1))
check(last().command == "roadPutOk" and last().args.sid == "s1", "invalid file starts empty and is writable")
worldName = "w1"
now = now + 1000
send("alice", "roadSync", {})
check(RS.store.count == 31, "switching back reloads the first world's file")

--------------------------------------------------------------------------------
-- 7. 惡意 wire 被拒
--------------------------------------------------------------------------------
local function rejected(args, label)
    now = now + 1000
    local before = RS.store.count
    send("dave", "roadPut", args)
    check(last().command == "roadPutFail" and last().args.reason == "invalid" and RS.store.count == before, label)
end
rejected({ lid = "aaaaaaaa:r5", rev = 1, road = "nope" }, "non-table wire rejected")
local w = Codec.toWire(road("r5", 1))
w.evil = "x"
rejected({ lid = "aaaaaaaa:r5", rev = 1, road = w }, "unknown wire field rejected")
rejected({ lid = "aaaaaaaa:r5", rev = 1, road = Codec.toWire(road("r5", 1, nil, 301)) }, "301 points rejected")
rejected({ lid = "aaaaaaaa:r5", rev = 1, road = Codec.toWire(road("r5", 1, { faction = false, safehouse = false })) },
    "share with no audience rejected")
rejected({ lid = "aaaaaaaa:r6", rev = 1, road = Codec.toWire(road("r5", 1)) }, "lid mismatching the wire rejected")
local plain = road("r5", 1)
plain.origin = nil
rejected({ lid = "r5", rev = 1, road = Codec.toWire(plain) }, "lid without origin rejected")
local before = #sent
for _, fn in ipairs(handlers.OnClientCommand) do fn("MinidoracatMiniMapRoads", "roadPut", P.dave, "x") end
check(#sent == before, "non-table args ignored")

--------------------------------------------------------------------------------
-- 8. roadSync：分批 5 條、同一個 seq；管理員收不到；沙盒關閉＝空 snap、拒收 put
--------------------------------------------------------------------------------
mark = #sent
send("carol", "roadSync", {})
local snaps = sentSince(mark, "roadSnap")
check(#snaps == 1 and snaps[1].args.parts == 1 and #snaps[1].args.roads == 1 and snaps[1].args.roads[1].sid == "s1",
    "safehouse owner syncs only the safehouse-shared road")
now = now + 1000
mark = #sent
send("bob", "roadSync", {})
snaps = sentSince(mark, "roadSnap")
local total, sameSeq = 0, true
for i = 1, #snaps do
    total = total + #snaps[i].args.roads
    sameSeq = sameSeq and snaps[i].args.seq == snaps[1].args.seq and snaps[i].args.parts == #snaps
        and snaps[i].args.part == i and snaps[i].to == "bob"
end
check(#snaps == 6 and total == 29 and #snaps[6].args.roads == 4 and sameSeq, "29 roads in 6 parts of 5, one seq")
mark = #sent
send("bob", "roadSync", {})
check(#sentSince(mark, "roadSnap") == 0, "second sync within 1s gets no reply")
mark = #sent
send("admin", "roadSync", {})
snaps = sentSince(mark, "roadSnap")
check(#snaps == 1 and #snaps[1].args.roads == 0, "admin not in faction/safehouse gets nothing")
policyOn = false
now = now + 1000
mark = #sent
send("bob", "roadSync", {})
snaps = sentSince(mark, "roadSnap")
check(#snaps == 1 and snaps[1].args.parts == 1 and #snaps[1].args.roads == 0, "disabled: empty snap")
now = now + 1000
put("alice", road("r3", 2))
check(last().args.reason == "disabled" and storedRevs()["alice:r3"] == 1, "disabled: put refused")
MinidoracatMiniMapPolicy = nil
now = now + 1000
put("alice", road("r3", 2))
check(last().args.reason == "disabled", "policy facade missing: put refused")
MinidoracatMiniMapPolicy, policyOn = policy, true

--------------------------------------------------------------------------------
-- 9. 作者收回：其他線上玩家都收到 roadRemove、作者收到 roadDropped；沒有這條＝也回成功
--------------------------------------------------------------------------------
mark = #sent
send("alice", "roadDrop", { sid = "s1" })
rem = sentSince(mark, "roadRemove")
check(#rem == 4 and last().command == "roadDropped" and last().to == "alice" and storedRevs()["alice:r1"] == nil,
    "author drop removes road and notifies others")
send("alice", "roadDrop", { sid = "s1" })
check(last().command == "roadDropped", "dropping an already-dropped sid is idempotent")

--------------------------------------------------------------------------------
-- 9b. 兩台電腦同帳號同 r 編號不互蓋；先寫備份，備份寫不成主檔不動；主檔壞了讀備份
--------------------------------------------------------------------------------
now = now + 1000
put("dave", road("r1", 1, nil, nil, "bbbbbbbb"))
local daveRoads = {}
for i = 1, RS.store.count do
    local r = RS.store.roads[i]
    if r.author == "dave" then daveRoads[#daveRoads + 1] = r end
end
check(last().command == "roadPutOk" and #daveRoads == 2 and daveRoads[1].sid ~= daveRoads[2].sid
    and daveRoads[1].origin ~= daveRoads[2].origin, "same r1 from two machines = two roads")
local mainBefore = files[RS.loadedPath]
bakBroken = true
now = now + 1000
put("dave", road("r1", 2, nil, nil, "bbbbbbbb"))
bakBroken = false
check(last().args.reason == "savefailed" and files[RS.loadedPath] == mainBefore, "backup write failure leaves main file")
check(files[Codec.backupPath(RS.loadedPath)] ~= nil, "server writes a backup file")
worldName = "w6"
local srvRoad = road("r1", 1)
srvRoad.author, srvRoad.sid = "alice", "s1"
local w6 = RS.path(Codec)
files[w6] = "MMROADSRV\t1\t2\nROAD"
files[Codec.backupPath(w6)] = Codec.encodeStore({ nextId = 2, count = 1, roads = { srvRoad }, offCount = 0, off = {} },
    Codec.SERVER_TAG)
now = now + 1000
send("alice", "roadSync", {})
check(RS.store.count == 1 and RS.store.roads[1].sid == "s1" and not RS.readOnly, "broken main file reads the backup")
worldName = "w1"
now = now + 1000
send("alice", "roadSync", {})

--------------------------------------------------------------------------------
-- 10. 客戶端：to 分桶、snap 收齊才整批替换、回覆更新 Roads
--------------------------------------------------------------------------------
isClientFlag = true
local local_ = { [0] = player("alice", 0), [1] = player("bob", 1) }
function getSpecificPlayer(pn) return local_[pn] end
local keys = { UI_MinidoracatMiniMap_RoadShareWhy_rate = true }
function getText(key, ...)
    local parts = { key }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, "|")
end
function getTextOrNull(key) return keys[key] and key or nil end
local clientSent = {}
function sendClientCommand(p, module, command, args)
    clientSent[#clientSent + 1] = { from = p:getUsername(), module = module, command = command, args = args }
end
local calls = { replace = {}, upsert = {}, remove = {}, setSid = {}, msg = {} }
local pending = {}
local own = { [0] = { r1 = { id = "r1", name = "Mine", share = { faction = true, safehouse = false }, rev = 1 } } }
MinidoracatMiniMapCore = { ready = true, policy = policy,
    navMessage = function(pn, text, good) calls.msg[#calls.msg + 1] = { pn = pn, text = text, good = good } end,
    roadsGet = function(pn, id) return own[pn] and own[pn][id] end,
    roadsList = function(pn)
        local out = {}
        for _, r in pairs(own[pn] or {}) do out[#out + 1] = r end
        return out
    end,
    roadsSetSid = function(pn, id, sid) calls.setSid[#calls.setSid + 1] = { pn = pn, id = id, sid = sid } end,
    roadsReplaceReceived = function(pn, list) calls.replace[#calls.replace + 1] = { pn = pn, list = list } end,
    roadsUpsertReceived = function(pn, r) calls.upsert[#calls.upsert + 1] = { pn = pn, road = r } end,
    roadsRemoveReceived = function(pn, sid) calls.remove[#calls.remove + 1] = { pn = pn, sid = sid } end,
    roadsPendingDrops = function(pn)
        local out = {}
        for i, sid in ipairs(pending[pn] or {}) do out[i] = sid end
        return out
    end,
    roadsClearPendingDrop = function(pn, sid)
        local list = pending[pn] or {}
        for i = #list, 1, -1 do if list[i] == sid then table.remove(list, i) end end
        return true
    end,
}
local Core = MinidoracatMiniMapCore
dofile(LUA .. "client/MinidoracatMiniMap_RoadShare.lua")
local function deliver(msgs)
    for i = 1, #msgs do fire("OnServerCommand", msgs[i].module, msgs[i].command, msgs[i].args) end
end

-- 伺服器真的送出的 6 批，倒著送：只在最後一批到時替換一次，給 bob（pn 1）
now = now + 1000
put("alice", road("r1", 5))
mark = #sent
send("bob", "roadSync", {})
snaps = sentSince(mark, "roadSnap")
local reversed = {}
for i = #snaps, 1, -1 do reversed[#reversed + 1] = snaps[i] end
deliver({ reversed[1], reversed[2], reversed[3], reversed[4], reversed[5] })
check(#calls.replace == 0, "partial snap does not replace")
deliver({ reversed[6] })
check(#calls.replace == 1 and calls.replace[1].pn == 1 and #calls.replace[1].list == 30
    and calls.replace[1].list[1].author == "alice" and calls.replace[1].list[30].sid ~= nil,
    "complete snap replaces once for the right player, in part order")
-- 換 seq：舊的半批丟掉；收齊新的才替換
deliver({ { module = "MinidoracatMiniMapRoads", command = "roadSnap",
    args = { to = "bob", seq = 900, part = 1, parts = 2, roads = {} } } })
deliver({ { module = "MinidoracatMiniMapRoads", command = "roadSnap",
    args = { to = "bob", seq = 901, part = 1, parts = 1, roads = { { name = "bad" }, Codec.toWire(RS.store.roads[1]) } } } })
check(#calls.replace == 2 and #calls.replace[2].list == 1, "new seq replaces; malformed road in snap skipped")
deliver({ { module = "MinidoracatMiniMapRoads", command = "roadSnap",
    args = { to = "bob", seq = 900, part = 2, parts = 2, roads = {} } } })
check(#calls.replace == 2, "late half of an abandoned seq never replaces")
deliver({ { module = "MinidoracatMiniMapRoads", command = "roadSnap",
    args = { to = "zed", seq = 902, part = 1, parts = 1, roads = {} } } })
check(#calls.replace == 2, "snap for a name not on this machine is ignored")

-- 回覆：put 成功記 sid、upsert／remove 照 to 分桶
local okMsg = { module = "MinidoracatMiniMapRoads", command = "roadPutOk",
    args = { to = "alice", lid = "aaaaaaaa:r1", sid = "s7", members = 5, online = 3 } }
deliver({ okMsg })
check(#calls.setSid == 1 and calls.setSid[1].pn == 0 and calls.setSid[1].sid == "s7"
    and calls.msg[#calls.msg].good == true and calls.msg[#calls.msg].text:find("|5|3", 1, true) ~= nil,
    "roadPutOk stores sid for the author's slot and reports members/online")
deliver({ { module = "MinidoracatMiniMapRoads", command = "roadPutFail", args = { to = "alice", lid = "r1", reason = "rate" } } })
check(calls.msg[#calls.msg].good == false and calls.msg[#calls.msg].text:find("RoadShareWhy_rate", 1, true) ~= nil,
    "roadPutFail shows the reason")
mark = #sent
now = now + 1000
put("alice", road("r1", 6))
deliver(sentSince(mark, "roadUpsert"))
check(#calls.upsert == 1 and calls.upsert[1].pn == 1 and calls.upsert[1].road.author == "alice",
    "server upsert lands on the recipient's slot only")
deliver({ { module = "MinidoracatMiniMapRoads", command = "roadRemove", args = { to = "bob", sid = "s1" } } })
check(#calls.remove == 1 and calls.remove[1].pn == 1, "roadRemove lands on the addressed slot")

-- 送出：沙盒關閉時不送、直接回饋；開啟時送 roadPut
policyOn = false
local r1 = road("r1", 7)
check(Core.roadSharePut(0, r1) == false and #clientSent == 0 and calls.msg[#calls.msg].good == false,
    "client refuses to send when sharing is off")
policyOn = true
check(Core.roadSharePut(0, r1) == true and clientSent[1].command == "roadPut" and clientSent[1].args.lid == "aaaaaaaa:r1"
    and clientSent[1].args.rev == 7 and Codec.fromWire(clientSent[1].args.road) ~= nil, "client sends a valid roadPut")
check(select(2, Core.roadShareAvailable(1)) == nil and select(2, (function()
    local_[2] = player("admin", 2); return Core.roadShareAvailable(2) end)()) == "UI_MinidoracatMiniMap_RoadShareNoGroup",
    "availability: grouped player ok, ungrouped player gets the reason")
local_[2] = nil

-- 同步防抖：連發事件只送一次，每位本機玩家各一次
fire("OnTick")
clientSent = {}
fire("SyncFaction"); fire("OnSafehousesChanged")
fire("OnTick")
check(#clientSent == 0, "sync waits for the debounce delay")
now = now + 1000
fire("OnTick"); fire("OnTick")
check(#clientSent == 2 and clientSent[1].command == "roadSync" and clientSent[2].command == "roadSync"
    and clientSent[1].from ~= clientSent[2].from, "one roadSync per local player after the delay")

-- 功能閘門 share：擋送出、不擋收到
Core.featureAllowed = function(_, feature)
    if feature == "share" then return false, "UI_Watch_NoComms" end
    return true
end
clientSent = {}
local upserts = #calls.upsert
check(Core.roadSharePut(0, r1) == false and #clientSent == 0
    and calls.msg[#calls.msg].text:find("UI_Watch_NoComms", 1, true) ~= nil, "feature gate blocks sending with its reason")
mark = #sent
now = now + 1000
put("alice", road("r1", 8))
deliver(sentSince(mark, "roadUpsert"))
check(#calls.upsert == upserts + 1, "feature gate does not block receiving")
Core.featureAllowed = nil

-- 待撤回：同步後重送 roadDrop；失敗不清；伺服器回 roadDropped（已不存在也回）才清
pending[0] = { "s50" }
clientSent = {}
fire("SyncFaction")
now = now + 1000
fire("OnTick")
local drops = {}
for i = 1, #clientSent do if clientSent[i].command == "roadDrop" then drops[#drops + 1] = clientSent[i] end end
check(#drops == 1 and drops[1].from == "alice" and drops[1].args.sid == "s50", "pending drop resent after sync")
deliver({ { module = "MinidoracatMiniMapRoads", command = "roadDropFail", args = { to = "alice", sid = "s50", reason = "savefailed" } } })
check(pending[0][1] == "s50", "failed drop stays pending")
mark = #sent
send("alice", "roadDrop", drops[1].args)
deliver(sentSince(mark, "roadDropped"))
check(#pending[0] == 0, "roadDropped (sid already gone on server) clears the pending drop")
clientSent = {}
fire("SyncFaction")
now = now + 1000
fire("OnTick")
drops = 0
for i = 1, #clientSent do if clientSent[i].command == "roadDrop" then drops = drops + 1 end end
check(drops == 0, "nothing resent once cleared")

local EXPECTED_ASSERTIONS = 63
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS .. ", actual " .. assertions)
    os.exit(1)
end
print("road share assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
