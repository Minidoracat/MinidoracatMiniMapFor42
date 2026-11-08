-- MinidoracatMiniMap_ClearedShare.lua — 資源點「已清空」的多人同步（客戶端）。伺服器端與封包說明在
-- server/MinidoracatMiniMapClearedShare.lua；資料在 _Cleared.lua（Core.Cleared）。
-- 自己的標記以本機帳號檔為準，「會存」的（C.relevant：已清空、已刷新、有翻過進度而且拿過東西）上傳一份到伺服器；
-- 只翻過沒拿的進度只在本機。只有伺服器回寫「已刷新」。
-- 伺服器以（來源碼, 建築）存：同一個帳號兩台電腦各自一份、不互刪，隊友看到合併的結果（帳號檔的來源碼見 _Cleared.lua）。
-- 上傳：每位本機玩家每 RATE_MS 至多一包（clrDrop 或 clrPut 輪流佔用同一個間隔）、一包至多 MAX_PUT 筆；
-- RATE_MS 取伺服器限頻（1 秒）的 2 倍以上，伺服器卡一下時兩包才不會在同一個 tick 被處理。每包帶請求編號 id，
-- 伺服器的失敗回覆帶回同一個 id，被 rate 拒絕只重送那一包（最近 SENT_KEEP 包留著內容）。
-- 整份重傳：第一包帶 reset、最後一包帶 done，伺服器收到 done 才刪掉這台電腦沒再送的舊筆（中間照常刷新）。
-- 功能閘門 share（addon，例：錶沒有通訊）關＝不送 clrPut／clrDrop、待送的留著；同步照送（收隊友與自己的刷新）。
-- 同步（clrSync）：登入、陣營或安全屋變動、沙盒或「分享給隊友」改變時，防抖 SYNC_DELAY_MS 後送，兩次同步至少隔
-- RATE_MS；伺服器回的筆數或摘要（只算這台電腦的來源碼）和本機不同＝整份重傳（第一包帶 reset，本機零筆也送）。
-- 伺服器作者檔或索引只讀（clrSyncOk readOnly、clrPutFail readonly）＝這次登入不對帳、不上傳（設定頁寫原因）。
-- 刷新：clrRefreshed 分批送，帶 seq 的那包（最後一包、或 clrSyncOk）處理完才推進本機 refreshSeq。
-- 防抖、to 分流、事件的寫法同 _RoadShare.lua。單機不做。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready and Core.Cleared) or Core.Cleared.Share then return end
local CL = Core.Cleared

local S = {
    MODULE = "MinidoracatMiniMapCleared",
    SYNC_DELAY_MS = 1000,
    RATE_MS = 2100,
    MAX_PUT = 64,
    syncAt = {},  -- [pn] = 要送 clrSync 的時刻
    syncSent = {}, -- [pn] = 上次送 clrSync 的時刻
    putAt = {},   -- [pn] = 下次可以送 clrPut／clrDrop 的時刻
    reset = {},   -- [pn] = 下一包 clrPut 帶 reset（整份重傳）
    nextId = 0,   -- 請求編號（每包 +1）
    sent = {},    -- [pn] = { [id] = { cmd, args } }：最近 SENT_KEEP 包，失敗回覆用 id 找回原封包
    SENT_KEEP = 16,
    retry = {},   -- [pn] = { args… }：要原樣重送的 clrPut（依失敗順序）
    resetting = {}, -- [pn] = 整份重傳中（最後一包帶 done）
    srvRO = {},   -- [pn] = 伺服器那份只讀（這次登入不對帳、不上傳）
    synced = {},  -- [pn] = 這次登入收過 clrSyncOk（之前的 clrRefreshed 不推游標）
    snaps = {},   -- [pn] = { seq, parts, got, have }
    raw = {},     -- [pn] = 上一份收齊的隊友快照（a, wire 交錯）；增量更新後作廢
    lastPolicy = nil, lastShare = nil,
}
CL.Share = S

function S.share() return Core.getBoolOption("ClearedShare", true) == true end
function S.policyOn()
    local P = Core.policy
    return P ~= nil and P.readBool("AllowClearedShare", true) == true
end
-- 功能閘門 share（_FeatureGate.lua；零註冊＝開）
function S.gateOpen(pn)
    local fa = Core.featureAllowed
    return not fa or fa(pn, "share") ~= false
end
-- 設定頁：伺服器那份只讀時的說明鍵（nil＝沒事）
Core.clearedShareProblem = function(pn)
    if S.srvRO[pn] then return "UI_MinidoracatMiniMap_ClearedServerReadOnly" end
    return nil
end

function S.pnOf(to)
    if type(to) ~= "string" then return nil end
    for pn = 0, 3 do
        local p = getSpecificPlayer(pn)
        if p and p:getUsername() == to then return pn end
    end
    return nil
end

function S.relevantCount(s)
    local C, st, n = CL.codec(), s.store, 0
    for i = 1, st.count do
        if C.uploadable(st.marks[i]) then n = n + 1 end
    end
    return n
end

function S.requestSync(pn)
    local now = getTimestampMs()
    for p = 0, 3 do
        if pn == nil or pn == p then
            S.syncAt[p] = math.max(now + S.SYNC_DELAY_MS, (S.syncSent[p] or 0) + S.RATE_MS)
        end
    end
end

-- 送一包並記下內容（失敗回覆帶 id 時找得回來）
function S.send(pn, p, cmd, args)
    S.nextId = S.nextId + 1
    args.id = S.nextId
    local sent = S.sent[pn] or {}
    S.sent[pn] = sent
    sent[args.id] = { cmd = cmd, args = args }
    sent[args.id - S.SENT_KEEP] = nil
    sendClientCommand(p, S.MODULE, cmd, args)
end

-- 送一包：先重送被拒的，再送刪除（clrDrop），沒有刪除才上傳；都佔用同一個 RATE_MS 間隔
function S.flush(pn, p, s, now)
    if (S.putAt[pn] or 0) > now then return end
    local origin = s.store.origin
    local rq = S.retry[pn]
    if rq and rq[1] then
        S.send(pn, p, "clrPut", table.remove(rq, 1))
        S.putAt[pn] = now + S.RATE_MS
        return
    end
    local keys, kn = {}, 0
    for key in pairs(s.drops) do
        kn = kn + 1
        keys[kn] = key
        s.drops[key] = nil
        if kn >= S.MAX_PUT then break end
    end
    if kn > 0 then
        S.send(pn, p, "clrDrop", { keys = keys, origin = origin })
        S.putAt[pn] = now + S.RATE_MS
        return -- s.upload 留著：下一個間隔再看還有沒有刪除或上傳
    end
    local C = CL.codec()
    local wires, n, more = {}, 0, false
    local st = s.store
    for i = 1, st.count do
        local m = st.marks[i]
        if m.u then
            if n >= S.MAX_PUT then
                more = true
                break
            end
            m.u = nil
            if C.uploadable(m) then
                n = n + 1
                wires[n] = C.toWire(m)
            end
        end
    end
    -- 整份重傳的第一包本機零筆也要送（伺服器清掉這台電腦的那份）；最後一包帶 done
    if n > 0 or S.reset[pn] or S.resetting[pn] then
        local done = S.resetting[pn] and not more or nil
        S.send(pn, p, "clrPut", { marks = wires, share = S.share(), reset = S.reset[pn] == true, done = done,
            origin = origin })
        S.reset[pn] = nil
        if done then S.resetting[pn] = nil end
        S.putAt[pn] = now + S.RATE_MS
        CL.dirty(s)
    end
    s.upload = more or nil
end

-- 整份重傳：全部會存的標記標待上傳，第一包帶 reset、最後一包帶 done（伺服器收到 done 才刪這台電腦沒再送的舊筆）
function S.reupload(pn, s)
    local C, st = CL.codec(), s.store
    for i = 1, st.count do
        if C.uploadable(st.marks[i]) then st.marks[i].u = true end
    end
    S.reset[pn], S.resetting[pn] = true, true
    s.upload = true
end

function S.tick()
    if not isClient() then return end
    local on, share = S.policyOn(), S.share()
    if on ~= S.lastPolicy or share ~= S.lastShare then
        S.lastPolicy, S.lastShare = on, share
        S.requestSync()
    end
    local now = getTimestampMs()
    for pn = 0, 0 do -- 分割畫面第 2～4 位在伺服器沒有身分（MinidoracatMiniMapGroups.principal）：不同步
        local p = getSpecificPlayer(pn)
        local s = p and CL.slots[pn]
        if s and p:getOnlineID() >= 0 then -- 登入初期還沒有 onlineID（同 _RoadShare.lua）
            local due = S.syncAt[pn]
            if due and now >= due and not s.readOnly then
                S.syncAt[pn] = nil
                S.syncSent[pn] = now
                sendClientCommand(p, S.MODULE, "clrSync", { seq = s.store.refreshSeq, count = S.relevantCount(s),
                    share = share, origin = s.store.origin })
            elseif (s.upload or S.pendingRetry(pn)) and not S.syncAt[pn] and not S.srvRO[pn] and S.gateOpen(pn) then
                S.flush(pn, p, s, now)
            end
        end
    end
end

-- 伺服器回覆 ---------------------------------------------------------------------------
function S.decodeList(list)
    local C, out, n = CL.codec(), {}, 0
    if type(list) ~= "table" then return out, 0 end
    for _, w in pairs(list) do
        local m = C.fromWire(w)
        if m then
            n = n + 1
            out[n] = m
        end
    end
    return out, n
end

-- 每筆都處理（套用、或確定不適用只記序號）；帶 seq 的那包處理完才推進游標（seq＝伺服器現在的序號，回滾時會變小）。
-- seq 是毫秒級的大數：整數判斷用 math.floor，不用 % 1（Kahlua 的 % 先把商轉 int，KahluaThread.java:1064，
-- 超過 2^31 就不是 0）
function S.applyRefreshed(pn, s, list, seq)
    local marks, n = S.decodeList(list)
    for i = 1, n do CL.applyRefresh(pn, marks[i]) end
    if type(seq) == "number" and seq >= 0 and math.floor(seq) == seq and seq ~= s.store.refreshSeq then
        s.store.refreshSeq = seq
        CL.dirty(s)
    end
end

function S.team(pn)
    local t = CL.team[pn]
    if not t then
        t = { n = 0, list = {} }
        CL.team[pn] = t
    end
    return t
end

-- 拿掉這位作者的某些外框（keys＝{ [C.key] = true }；nil＝全部），一次掃完；回拿掉的已清空外框 { [C.key] = true }, 個數
function S.teamRemove(t, author, keys)
    local C, k, keep, gone, gn = CL.codec(), 0, {}, {}, 0
    for i = 1, t.n do
        local e = t.list[i]
        local key = (keys or e.m.ch > 0) and C.key(e.m)
        if not (e.a == author and (keys == nil or keys[key])) then
            k = k + 1
            keep[k] = e
        elseif e.m.ch > 0 and not gone[key] then
            gone[key] = true
            gn = gn + 1
        end
    end
    t.list, t.n = keep, k
    return gone, gn
end

-- 隊友資料改了：已清空集合有增減才重建圖標（CL.bump），只有進度變了只讓查找索引重建（提示、搜尋照樣讀到新的）
function S.teamChanged(clearedChanged)
    if clearedChanged then CL.bump() else CL.teamRev = CL.teamRev + 1 end
end

function S.pendingRetry(pn) return S.retry[pn] ~= nil and S.retry[pn][1] ~= nil end
-- 有沒有還沒送出的上傳或刪除（有的話伺服器那份本來就還沒跟上，不對帳）
function S.pending(s, pn)
    if s.upload or S.pendingRetry(pn) or S.resetting[pn] then return true end
    for _ in pairs(s.drops) do return true end
    return false
end

S.handlers = {
    clrSyncOk = function(pn, args)
        local s = CL.slots[pn]
        if not s then return end
        S.applyRefreshed(pn, s, nil, args.seq)
        S.synced[pn] = true
        if args.readOnly == true then
            S.srvRO[pn] = true
            return
        end
        if S.pending(s, pn) then return end
        -- 這台電腦的筆數或內容對不上（例：伺服器停機前沒寫進檔）就整份重傳
        local digest, count = CL.codec().storeDigest(s.store.marks, s.store.count)
        if (type(args.count) == "number" and args.count ~= count)
            or (type(args.digest) == "number" and args.digest ~= digest) then
            S.reupload(pn, s)
        end
    end,
    clrSyncRate = function(pn) S.requestSync(pn) end,
    clrRefreshed = function(pn, args)
        local s = CL.slots[pn]
        -- 這次登入第一包 clrSyncOk 之前收到的刷新照套，但不推游標（seq 是伺服器現在的序號，
        -- 離線期間的刷新要等同步時才補送；先推過頭就永遠補不到）
        if s then S.applyRefreshed(pn, s, args.marks, S.synced[pn] and args.seq or nil) end
    end,
    clrTeamSnap = function(pn, args)
        local seq, part, parts = args.seq, args.part, args.parts
        if type(seq) ~= "number" or type(part) ~= "number" or type(parts) ~= "number"
            or part < 1 or part > parts or parts > 10000 or math.floor(part) ~= part or math.floor(parts) ~= parts then return end
        local b = S.snaps[pn]
        if not b or b.seq ~= seq then
            b = { seq = seq, parts = parts, got = 0, have = {} }
            S.snaps[pn] = b
        end
        if b.parts ~= parts or b.have[part] then return end
        b.have[part] = type(args.marks) == "table" and args.marks or {}
        b.got = b.got + 1
        if b.got < parts then return end
        S.snaps[pn] = nil
        -- 陣營／安全屋同步事件全服都會觸發：內容和上一份一樣就不解碼、不重建圖標
        local raw, rn = {}, 0
        for k = 1, parts do
            for _, e in pairs(b.have[k]) do
                if type(e) == "table" and type(e.a) == "string" and type(e.m) == "string" then
                    raw[rn + 1], raw[rn + 2] = e.a, e.m
                    rn = rn + 2
                end
            end
        end
        local old = S.raw[pn]
        if old and old.n == rn then
            local same = true
            for i = 1, rn do
                if old[i] ~= raw[i] then
                    same = false
                    break
                end
            end
            if same then return end
        end
        -- ponytail: 內容有變時同一幀解碼全部（隊友數 × 會存的標記）；隊友多到卡頓再改成分 tick 解碼
        raw.n = rn
        S.raw[pn] = raw
        local C, list, n = CL.codec(), {}, 0
        for i = 1, rn, 2 do
            local m = C.fromWire(raw[i + 1])
            if m then
                n = n + 1
                list[n] = { a = raw[i], m = m }
            end
        end
        CL.team[pn] = { n = n, list = list }
        CL.bump()
    end,
    clrTeamUpsert = function(pn, args)
        if type(args.a) ~= "string" then return end
        local marks, n = S.decodeList(args.marks)
        local C, t, keys = CL.codec(), S.team(pn), {}
        for i = 1, n do keys[C.key(marks[i])] = true end
        local gone, gn = S.teamRemove(t, args.a, keys)
        local changed, kept = false, 0
        for i = 1, n do
            t.n = t.n + 1
            t.list[t.n] = { a = args.a, m = marks[i] }
            if marks[i].ch > 0 then
                if gone[C.key(marks[i])] then kept = kept + 1 else changed = true end
            end
        end
        S.raw[pn] = nil
        S.teamChanged(changed or kept ~= gn)
    end,
    clrTeamRemove = function(pn, args)
        if type(args.a) ~= "string" then return end
        local C, t = CL.codec(), S.team(pn)
        local _, gn = nil, 0
        if args.keys == nil then
            _, gn = S.teamRemove(t, args.a, nil)
        elseif type(args.keys) == "table" then
            local keys = {}
            for _, key in pairs(args.keys) do
                local x, y, w, h = C.parseKey(key)
                if x then keys[C.key({ x = x, y = y, w = w, h = h })] = true end
            end
            _, gn = S.teamRemove(t, args.a, keys)
        end
        S.raw[pn] = nil
        S.teamChanged(gn > 0)
    end,
    clrPutFail = function(pn, args)
        local s = CL.slots[pn]
        if not s then return end
        if args.reason == "rate" then
            -- 用 id 找回被拒的那一包（同時好幾包在途也不會重送錯）；找不到（太舊）就交給下次同步的對帳
            local rec = type(args.id) == "number" and S.sent[pn] and S.sent[pn][args.id]
            if not rec then return S.requestSync(pn) end
            S.sent[pn][args.id] = nil
            if rec.cmd == "clrDrop" then
                for _, key in ipairs(rec.args.keys) do s.drops[key] = true end
                s.upload = true
            elseif rec.args.reset then
                -- 整份重傳的第一包被拒：從頭再來。照原樣重送會排在之後已收下的包後面，伺服器從那時才開始記
                -- 這次送到的，收到 done 時把先收下的那幾包當成沒送到刪掉
                S.reupload(pn, s)
            else
                local rq = S.retry[pn] or {}
                S.retry[pn] = rq
                rq[#rq + 1] = rec.args
            end
        elseif args.reason == "readonly" then
            S.srvRO[pn] = true
        else
            CL.warn("put", args.reason)
        end
    end,
}

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= S.MODULE or type(args) ~= "table" then return end
    local fn = S.handlers[command]
    local pn = fn and S.pnOf(args.to)
    if pn then fn(pn, args) end
end)

Events.OnCreatePlayer.Add(function(pn) S.requestSync(pn) end)
Events.SyncFaction.Add(function() S.requestSync() end)
Events.OnSafehousesChanged.Add(function() S.requestSync() end)
Events.OnTick.Add(S.tick)
Events.OnGameStart.Add(function()
    S.syncAt, S.syncSent, S.putAt, S.reset, S.sent, S.retry, S.resetting, S.srvRO, S.synced, S.snaps, S.raw =
        {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
    S.lastPolicy, S.lastShare = nil, nil
end)
