-- MinidoracatMiniMapRoadShare.lua — 自訂道路分享（MP 伺服器端：指令、存檔、收件人、同步）
-- 伺服器自己存一個世界一個檔（不用全域 ModData：任何客戶端都能 ModData.request 任何 tag，
-- GlobalModData.java:153、171-200，陣營專用的路會外流）。存檔成功才換上、才轉送。
-- 作者＝連線帳號 player:getUsername()，不信封包裡的 author／sid。收件人在伺服器判斷：
-- Faction.getPlayerFaction(String)＋比名稱（Faction.java:123）、SafeHouse.isInSameSafehouse(String,String)
-- （SafeHouse.java:795，只看 owner／players 名單，管理員不會因為能進所有安全屋而收到）。
-- 名單列舉：faction:getOwner()／getPlayers()（Faction.java:241、281）、SafeHouse.getSafehouseList()／
-- getOwner()／getPlayers()（SafeHouse.java:640-658）。安全屋 MOD 代管的屋，屋主與成員也在原生名單裡。
-- OnClientCommand 簽名、sendServerCommand 用法同 MinidoracatMiniMapServer.lua；getOnlinePlayers 單機回空
-- （GameServer.java:3530-3549）。server 資料夾在 MP 客戶端也會載入（GameLoadingState.java:149），故閘 isClient。
-- 封包都帶 to（收件角色名）：分割畫面共用一條連線，客戶端照 to 分桶。
if isClient() then return end

local RS = {
    MODULE = "MinidoracatMiniMapRoads",
    MAX_PER_AUTHOR = 30,
    RATE_MS = 1000,
    SNAP_BATCH = 5,
    loadedPath = nil, store = nil, readOnly = false,
    lastPut = {}, -- [author] = 上次 roadPut 的毫秒（重送不算）
    lastSync = {}, -- [name] = 上次 roadSync 的毫秒（每人每秒 1 次，多的不回）
    seq = 0,
    warned = {},
}

function RS.warn(key, msg)
    if RS.warned[key] then return end
    RS.warned[key] = true
    print("[MinidoracatMiniMap] RoadShare " .. key .. ": " .. tostring(msg))
end

-- 政策缺席＝拒收（同 Server.lua navShareAllowed）；AllowRoadShare 不在任何旁路名單，故不傳 playerNum
function RS.allowed()
    local P = MinidoracatMiniMapPolicy
    if not P then
        RS.warn("policy", "policy facade missing, road share refused")
        return false
    end
    return P.readBool("AllowRoadShare", true) == true
end

function RS.path(Codec)
    return "MinidoracatMiniMap/roads/" .. Codec.fileKey(getWorld():getWorld()) .. ".txt"
end

-- 讀檔：沒有檔＝空、可寫；unreadable／unsupported＝只讀（讀不懂的檔不覆寫）；invalid＝空、可寫
-- （同收藏檔規則）；主檔 invalid／unreadable 時先讀備份（Codec.readStoreSafe）。例外一律當 unreadable
function RS.ensure(Codec)
    local path = RS.path(Codec)
    if RS.loadedPath == path then return end
    local ok, st, err, recovered = pcall(Codec.readStoreSafe, path, Codec.SERVER_TAG)
    if not ok then st, err = nil, "unreadable" end
    if err then RS.warn("load", err) elseif recovered then RS.warn("load", recovered .. ", read backup") end
    RS.loadedPath, RS.store = path, st or Codec.emptyStore()
    RS.readOnly = err == "unreadable" or err == "unsupported"
end

function RS.indexBySid(sid)
    local st = RS.store
    for i = 1, st.count do if st.roads[i].sid == sid then return i end end
    return nil
end

-- lid＝「來源碼:r編號」（兩台電腦同帳號的 r 編號不撞）
function RS.indexByLid(author, lid)
    local st, Codec = RS.store, MinidoracatMiniMapRoadCodec
    for i = 1, st.count do
        local r = st.roads[i]
        if r.author == author and Codec.lid(r) == lid then return i end
    end
    return nil
end

function RS.sameFaction(a, b)
    local fa, fb = Faction.getPlayerFaction(a), Faction.getPlayerFaction(b)
    return fa ~= nil and fb ~= nil and fa:getName() == fb:getName() -- 比名稱，不比物件
end

function RS.canSee(road, name)
    if road.author == name then return false end
    return (road.share.faction and RS.sameFaction(road.author, name))
        or (road.share.safehouse and SafeHouse.isInSameSafehouse(road.author, name)) or false
end

-- 可以使用的人數（含離線）：陣營 owner＋成員、作者所在每間安全屋的 owner＋成員，去重、不含作者
function RS.memberCount(road)
    local seen, n, author = {}, 0, road.author
    local function add(name)
        if name and name ~= author and not seen[name] then
            seen[name] = true
            n = n + 1
        end
    end
    local function addList(owner, list)
        add(owner)
        for i = 0, list:size() - 1 do add(list:get(i)) end
    end
    if road.share.faction then
        local f = Faction.getPlayerFaction(author)
        if f then addList(f:getOwner(), f:getPlayers()) end
    end
    if road.share.safehouse then
        local houses = SafeHouse.getSafehouseList()
        for i = 0, houses:size() - 1 do
            local h = houses:get(i)
            if h:getOwner() == author or h:getPlayers():contains(author) then addList(h:getOwner(), h:getPlayers()) end
        end
    end
    return n
end

-- 送給每位線上玩家（不含作者）：看得到新版＝roadUpsert；只看得到舊版＝roadRemove（換了分享對象）
function RS.broadcast(Codec, road, old)
    local wire = Codec.toWire(road)
    local online, list = 0, getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local name = p and p:getUsername()
        if name and name ~= road.author then
            if RS.canSee(road, name) then
                online = online + 1
                sendServerCommand(p, RS.MODULE, "roadUpsert", { to = name, road = wire })
            elseif old and RS.canSee(old, name) then
                sendServerCommand(p, RS.MODULE, "roadRemove", { to = name, sid = road.sid })
            end
        end
    end
    return online
end

function RS.onlineCount(road)
    local n, list = 0, getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local name = p and p:getUsername()
        if name and RS.canSee(road, name) then n = n + 1 end
    end
    return n
end

function RS.copyStore(st)
    local out = { nextId = st.nextId, count = st.count, roads = {}, offCount = 0, off = {} }
    for i = 1, st.count do out.roads[i] = st.roads[i] end
    return out
end

-- draft 寫檔（先備份再主檔）讀回成功才換上
function RS.commit(Codec, draft)
    if RS.readOnly then return "readonly" end
    local ok, saved = pcall(Codec.writeSafe, RS.loadedPath, Codec.encodeStore(draft, Codec.SERVER_TAG))
    if not (ok and saved) then
        RS.warn("save", ok and "read-back mismatch" or saved)
        return "savefailed"
    end
    RS.store = draft
    return nil
end

local Commands = {}

function Commands.roadPut(player, args, author)
    local lid = args.lid
    local function fail(reason)
        sendServerCommand(player, RS.MODULE, "roadPutFail", { to = author, lid = lid, reason = reason })
    end
    local Codec = MinidoracatMiniMapRoadCodec
    if not (RS.allowed() and Codec) then return fail("disabled") end
    RS.ensure(Codec)
    -- rev 一樣＝重送（回覆遺失）：回同一個結果，不算頻率
    local cur = type(lid) == "string" and RS.indexByLid(author, lid)
    local old = cur and RS.store.roads[cur]
    if old and args.rev == old.rev then
        sendServerCommand(player, RS.MODULE, "roadPutOk", { to = author, lid = lid, sid = old.sid,
            members = RS.memberCount(old), online = RS.onlineCount(old) })
        return
    end
    local now = getTimestampMs()
    local last = RS.lastPut[author]
    if last and now - last < RS.RATE_MS then return fail("rate") end
    RS.lastPut[author] = now
    local road = Codec.fromWire(args.road)
    if not (road and road.origin and Codec.lid(road) == lid and road.rev == args.rev
        and (road.share.faction or road.share.safehouse)) then
        return fail("invalid")
    end
    if old and road.rev < old.rev then return fail("invalid") end
    if args.sid ~= nil then
        local at = RS.indexBySid(args.sid)
        if at and at ~= cur then return fail("notowner") end
    end
    if not old then
        local mine = 0
        for i = 1, RS.store.count do if RS.store.roads[i].author == author then mine = mine + 1 end end
        if mine >= RS.MAX_PER_AUTHOR then return fail("limit") end
    end
    local draft = RS.copyStore(RS.store)
    road.author, road.enabled = author, true
    if old then
        road.sid = old.sid
        draft.roads[cur] = road
    else
        road.sid = "s" .. draft.nextId
        draft.nextId = draft.nextId + 1
        draft.count = draft.count + 1
        draft.roads[draft.count] = road
    end
    local err = RS.commit(Codec, draft)
    if err then return fail(err) end
    local online = RS.broadcast(Codec, road, old)
    sendServerCommand(player, RS.MODULE, "roadPutOk", { to = author, lid = lid, sid = road.sid,
        members = RS.memberCount(road), online = online })
end

-- 收回：只收作者的；沒有這條＝已收回（回成功，讓客戶端清掉 sid）。沙盒關閉也收（撤回不外流）
function Commands.roadDrop(player, args, author)
    local sid = args.sid
    local function reply(command, reason)
        sendServerCommand(player, RS.MODULE, command, { to = author, sid = sid, reason = reason })
    end
    local Codec = MinidoracatMiniMapRoadCodec
    if type(sid) ~= "string" or not Codec then return end
    RS.ensure(Codec)
    local at = RS.indexBySid(sid)
    if not at then return reply("roadDropped") end
    if RS.store.roads[at].author ~= author then return reply("roadDropFail", "notowner") end
    local draft = RS.copyStore(RS.store)
    for i = at, draft.count - 1 do draft.roads[i] = draft.roads[i + 1] end
    draft.roads[draft.count] = nil
    draft.count = draft.count - 1
    local err = RS.commit(Codec, draft)
    if err then return reply("roadDropFail", err) end
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local name = p and p:getUsername()
        if name and name ~= author then sendServerCommand(p, RS.MODULE, "roadRemove", { to = name, sid = sid }) end
    end
    reply("roadDropped")
end

-- 這位玩家看得到的路（不含自己的），每批 SNAP_BATCH 條；收齊同一個 seq 才整批替換。沙盒關閉＝空 snap
function Commands.roadSync(player, _, name)
    local now = getTimestampMs()
    local last = RS.lastSync[name]
    if last and now - last < RS.RATE_MS then return end
    RS.lastSync[name] = now
    local Codec = MinidoracatMiniMapRoadCodec
    local wires, n = {}, 0
    if RS.allowed() and Codec then
        RS.ensure(Codec)
        for i = 1, RS.store.count do
            local r = RS.store.roads[i]
            if RS.canSee(r, name) then
                n = n + 1
                wires[n] = Codec.toWire(r)
            end
        end
    end
    RS.seq = RS.seq + 1
    local parts = math.max(1, math.floor((n + RS.SNAP_BATCH - 1) / RS.SNAP_BATCH))
    for part = 1, parts do
        local roads, k = {}, 0
        for i = (part - 1) * RS.SNAP_BATCH + 1, math.min(n, part * RS.SNAP_BATCH) do
            k = k + 1
            roads[k] = wires[i]
        end
        sendServerCommand(player, RS.MODULE, "roadSnap", { to = name, seq = RS.seq, part = part, parts = parts,
            roads = roads })
    end
end

RS.Commands = Commands
Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= RS.MODULE then return end
    local fn = Commands[command]
    local name = fn and player and player:getUsername()
    -- 空表的 args 不上線：客戶端對空表只寫 false（GameClient.java:1837），伺服器收到 nil（GameServer.java:2267-2278）。
    -- roadSync 送的就是 {}：nil 當空表，各指令自己驗欄位；其他非表照舊不理
    if name and (args == nil or type(args) == "table") then fn(player, args or {}, name) end
end)
