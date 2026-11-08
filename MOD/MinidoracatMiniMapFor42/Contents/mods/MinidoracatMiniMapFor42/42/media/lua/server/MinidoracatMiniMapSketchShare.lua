-- MinidoracatMiniMapSketchShare.lua — 手繪線分享（MP 伺服器端：指令、存檔、收件人、同步）
-- 每位作者一個檔 Lua/MinidoracatMiniMap/sketch/<世界>/<帳號十六進位>.txt，另有 index.txt 列出作者
-- （帳號可能含 : * ? | 與控制字元，Windows 檔名放不下；照鐵則無損轉義，不消毒、不截斷）。每次改動只重寫
-- 該作者自己的檔（≤ SHARE_MAX_POINTS 點），寫檔讀回成功才換上、才轉送。不用全域 ModData（同道路分享）。
-- 作者與收件人＝MinidoracatMiniMapGroups.principal(player)（分割畫面第 2～4 位沒有身分：不能分享、不收），不信封包。
-- 收件人每次在伺服器當下判斷：MinidoracatMiniMapGroups.canSee（陣營＋安全屋成員；作者自己、管理員不因此收到）。
-- 檔名排序：ClearedShare 等比 Groups 早載入，一律在執行時才查。
-- 指令（module MinidoracatMiniMapSketch；封包都帶 to＝收件角色名，分割畫面共用一條連線）：
--   skPush { adds = { wire... }, dels = { lid... } }：先刪後加，每人每 RATE_MS 一次；沙盒關閉時只做刪除（撤回不外流）
--   skSync { origin, ids }：比對這台電腦（來源碼）分享的筆：伺服器有、清單沒有的刪掉（作者離線時擦掉的），
--     清單有、伺服器沒有的回 skNeed 要回來；接著把看得到的別人的手繪排進 skSnap，跨 tick 一次一批送
--   伺服器 → 客戶端：skSnap { seq, part, parts, groups = { { a, s = { wire... } } } }、skAdd { a, s }、skDel { a, ids }、
--     skNeed { ids }、skFail { reason, ids＝因上限被拒的 lid（reason＝limit 時） }
-- OnClientCommand 簽名、sendServerCommand 用法同 MinidoracatMiniMapRoadShare.lua；args 是 nil 時當空表
-- （空表不上線，GameClient.java:1837、GameServer.java:2267-2278）。server 資料夾在 MP 客戶端也會載入
-- （GameLoadingState.java:149），故閘 isClient。
if isClient() then return end

local SS = {
    MODULE = "MinidoracatMiniMapSketch",
    RATE_MS = 1000, SYNC_RATE_MS = 1000,
    MAX_ADDS = 200, MAX_DELS = 2000, MAX_PUSH_CHARS = 32000,
    -- 對帳清單字數上限：網路上表裡的字串用 short 記長度（GameWindow.java:1266-1277），單一字串 ≤ 32,767 位元組。
    -- 客戶端清單超過就不帶清單（伺服器只送快照、不刪），筆數上限照檔案硬上限 MAX_STROKES 拆
    MAX_IDS_CHARS = 32000,
    SNAP_CHARS = 24000, -- 每批 skSnap 的座標字數上限（每 tick 每人送一批）
    MAX_NAME = 50,      -- 帳號長度上限（十六進位檔名 4 倍長，Windows 路徑放得下）
    dir = nil, authors = {}, names = {}, nNames = 0, indexRo = false,
    lastPush = {}, lastSync = {}, seq = 0, queue = {},
    warned = {},
}
SS.SHARE = { faction = true, safehouse = true } -- 手繪只有一種分享：陣營與安全屋成員

local function RC() return MinidoracatMiniMapRoadCodec end
local function C() return MinidoracatMiniMapSketchCodec end

function SS.warn(key, msg)
    if SS.warned[key] then return end
    SS.warned[key] = true
    print("[MinidoracatMiniMap] SketchShare " .. key .. ": " .. tostring(msg))
end

-- 政策缺席＝拒收；AllowSketchShare 不在任何旁路名單，故不傳 playerNum
function SS.allowed()
    local P = MinidoracatMiniMapPolicy
    if not P then
        SS.warn("policy", "policy facade missing, sketch share refused")
        return false
    end
    return P.readBool("AllowSketchShare", true) == true
end

function SS.canSee(author, name)
    return MinidoracatMiniMapGroups.canSee(author, SS.SHARE, name)
end
function SS.principal(player) return MinidoracatMiniMapGroups.principal(player) end

-- 純陣列筆數（有洞或非整數鍵回 nil）
function SS.arrayLen(t)
    if t == nil then return 0 end
    if type(t) ~= "table" then return nil end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    for i = 1, n do if t[i] == nil then return nil end end
    return n
end

-- 讀檔（主檔壞了讀備份）：回 lines, n／nil（沒有檔）／nil, reason。主檔 unsupported 不退回備份；
-- 主檔或備份任一個回 unreadable／unsupported 就回那個原因（呼叫端當只讀：不知道裡面有什麼，不能覆寫）
function SS.lockReason(r) return r == "unreadable" or r == "unsupported" end
function SS.readSafe(path, decode)
    local function one(p)
        local ok, lines, n = pcall(C().readFile, p)
        if not ok then return nil, "unreadable" end
        if not lines then return nil, n end
        return decode(lines, n)
    end
    local a, b = one(path)
    if a then return a, b end
    if b == nil and not cacheFileExists(path) then return nil end
    if b == "unsupported" then return nil, b end
    local x, y = one(RC().backupPath(path))
    if x then
        SS.warn("load " .. path, tostring(b) .. ", read backup")
        return x, y
    end
    if SS.lockReason(y) and not SS.lockReason(b) then return nil, y end
    return nil, b
end

function SS.authorPath(hex) return SS.dir .. hex .. ".txt" end
function SS.indexPath() return SS.dir .. "index.txt" end

-- 換世界才重讀；作者檔讀不懂或打不開＝這位作者只讀（不覆寫），主檔與備份都壞＝空、可覆寫。
-- 索引除了「沒有這個檔」以外讀不出來都只讀（覆寫會把名單變成只剩新作者）
function SS.ensure()
    local dir = "MinidoracatMiniMap/sketch/" .. RC().fileKey(getWorld():getWorld()) .. "/"
    if SS.dir == dir then return end
    SS.dir, SS.authors, SS.names, SS.nNames, SS.indexRo = dir, {}, {}, 0, false
    local names, n = SS.readSafe(SS.indexPath(), C().decodeIndex)
    if not names then
        if n then SS.warn("index", n) end
        SS.indexRo = n ~= nil
        return
    end
    for i = 1, n do
        local name = names[i]
        local hex = C().hexName(name)
        local rec = { hex = hex, count = 0, wires = {}, nps = {}, points = 0 }
        local data, err = SS.readSafe(SS.authorPath(hex), C().decodeAuthor)
        if data then
            for k = 1, data.count do
                local w = data.strokes[k]
                rec.nps[k] = w.np
                w.np = nil
                rec.wires[k] = w
            end
            rec.count, rec.points = data.count, data.points
        elseif err then
            SS.warn("author " .. hex, err)
            rec.ro = SS.lockReason(err)
        end
        SS.authors[name] = rec
        SS.nNames = SS.nNames + 1
        SS.names[SS.nNames] = name
    end
end

-- lid → 位置表（每次處理建一次，不逐筆線性找）
function SS.posMap(rec)
    local m = {}
    for i = 1, rec.count do m[rec.wires[i].id] = i end
    return m
end
-- 一趟壓縮拿掉 drop[lid] 為真的筆；回 拿掉的 lid 陣列, 筆數
function SS.compact(rec, drop)
    local wires, nps, j, out, n = rec.wires, rec.nps, 0, {}, 0
    for i = 1, rec.count do
        local w = wires[i]
        if drop[w.id] then
            rec.points = rec.points - nps[i]
            n = n + 1
            out[n] = w.id
        else
            j = j + 1
            wires[j], nps[j] = w, nps[i]
        end
    end
    for i = j + 1, rec.count do wires[i], nps[i] = nil, nil end
    rec.count = j
    return out, n
end
function SS.copyRec(rec)
    local out = { hex = rec.hex, count = rec.count, wires = {}, nps = {}, points = rec.points }
    for i = 1, rec.count do out.wires[i], out.nps[i] = rec.wires[i], rec.nps[i] end
    return out
end

-- 寫作者檔讀回成功才換上；回錯誤原因或 nil。新作者先寫索引、登記成空的再寫作者檔（作者檔寫失敗時索引裡
-- 有名字、檔不存在＝下次讀成空，不會卡死）；索引裡沒有、磁碟上卻已有這位作者的檔（索引曾經壞過、被手動改過）
-- 不覆寫：不知道裡面有什麼
function SS.commit(author, draft, isNew)
    if isNew then
        if SS.indexRo then return "readonly" end
        local path = SS.authorPath(draft.hex)
        if cacheFileExists(path) or cacheFileExists(RC().backupPath(path)) then
            SS.warn("orphan " .. draft.hex, "author file exists but not in index, not overwritten")
            return "readonly"
        end
        local names = {}
        for i = 1, SS.nNames do names[i] = SS.names[i] end
        names[SS.nNames + 1] = author
        local ok, saved = pcall(RC().writeSafe, SS.indexPath(), C().encodeIndex(SS.nNames + 1, names))
        if not (ok and saved) then
            SS.warn("save index", ok and "read-back mismatch" or saved)
            return "savefailed"
        end
        SS.nNames = SS.nNames + 1
        SS.names[SS.nNames] = author
        SS.authors[author] = { hex = draft.hex, count = 0, wires = {}, nps = {}, points = 0 }
    end
    local ok, saved = pcall(RC().writeSafe, SS.authorPath(draft.hex), C().encodeAuthor(draft.count, draft.wires))
    if not (ok and saved) then
        SS.warn("save", ok and "read-back mismatch" or saved)
        return "savefailed"
    end
    SS.authors[author] = draft
    return nil
end

-- 轉送給線上看得到這位作者的人（不含作者、沒有身分的座位）。順序同伺服器處理：先刪後加
-- （同一包同一個 lid 既刪又加＝換成新的那筆）
function SS.broadcast(author, adds, na, dels, nd)
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local name = SS.principal(p)
        if name and name ~= author and SS.canSee(author, name) then
            if nd > 0 then sendServerCommand(p, SS.MODULE, "skDel", { to = name, a = author, ids = dels }) end
            if na > 0 then sendServerCommand(p, SS.MODULE, "skAdd", { to = name, a = author, s = adds }) end
        end
    end
end

local Commands = {}

function Commands.skPush(player, args, author)
    local function fail(reason, ids)
        sendServerCommand(player, SS.MODULE, "skFail", { to = author, reason = reason, ids = ids })
    end
    local now = getTimestampMs()
    local last = SS.lastPush[author]
    if last and now - last < SS.RATE_MS then return fail("rate") end
    SS.lastPush[author] = now
    local na, nd = SS.arrayLen(args.adds), SS.arrayLen(args.dels)
    if not (na and nd) or na > SS.MAX_ADDS or nd > SS.MAX_DELS then return fail("invalid") end
    local hex = #author <= SS.MAX_NAME and C().hexName(author)
    if not hex then return fail("invalid") end
    SS.ensure()
    local allowed = SS.allowed()
    local rec = SS.authors[author]
    if rec and rec.ro then return fail("readonly") end
    local isNew = rec == nil
    local draft = rec and SS.copyRec(rec) or { hex = hex, count = 0, wires = {}, nps = {}, points = 0 }
    -- 刪除：只刪作者自己的（本來就只查這位作者的檔）；去重後一趟壓縮
    local drop = {}
    for i = 1, nd do
        local lid = args.dels[i]
        if type(lid) ~= "string" or #lid > 32 then return fail("invalid") end
        drop[lid] = true
    end
    local dels, nDel = {}, 0
    if nd > 0 then dels, nDel = SS.compact(draft, drop) end
    -- 新增：沙盒關閉整批不收；超過每位作者上限（新筆或同 lid 換成更長的筆）跳過那幾筆，lid 回給作者
    local adds, nAdd, chars, why = {}, 0, 0, nil
    local refused, nRef = {}, 0
    if na > 0 and not allowed then
        why = "disabled"
    else
        local pos = SS.posMap(draft)
        for i = 1, na do
            local w = args.adds[i]
            local s = C().fromWire(w)
            if not s or s.a ~= nil then return fail("invalid") end
            chars = chars + #w.p
            if chars > SS.MAX_PUSH_CHARS then return fail("invalid") end
            local wire = { id = w.id, c = w.c, w = w.w, z = w.z, p = w.p }
            local at = pos[wire.id]
            local points = draft.points + s.np - (at and draft.nps[at] or 0)
            if points > C().SHARE_MAX_POINTS or (not at and draft.count + 1 > C().SHARE_MAX_STROKES) then
                why = "limit"
                nRef = nRef + 1
                refused[nRef] = wire.id
            else
                if not at then
                    at = draft.count + 1
                    draft.count = at
                    pos[wire.id] = at
                end
                draft.wires[at], draft.nps[at], draft.points = wire, s.np, points
                nAdd = nAdd + 1
                adds[nAdd] = wire
            end
        end
    end
    if nAdd > 0 or nDel > 0 then
        local err = SS.commit(author, draft, isNew)
        if err then return fail(err) end
        SS.broadcast(author, adds, nAdd, dels, nDel)
    end
    if why then fail(why, nRef > 0 and refused or nil) end
end

-- 把看得到的別人的手繪切成每批 ≤ SNAP_CHARS 座標字數的 groups 陣列
function SS.snapshotParts(name)
    local parts, cur, chars = {}, {}, 0
    local function flush()
        parts[#parts + 1] = cur
        cur, chars = {}, 0
    end
    if SS.allowed() then
        for i = 1, SS.nNames do
            local author = SS.names[i]
            local rec = SS.authors[author]
            if author ~= name and rec.count > 0 and SS.canSee(author, name) then
                local g
                for k = 1, rec.count do
                    local w = rec.wires[k]
                    if chars > 0 and chars + #w.p > SS.SNAP_CHARS then
                        flush()
                        g = nil
                    end
                    if not g then
                        g = { a = author, s = {} }
                        cur[#cur + 1] = g
                    end
                    g.s[#g.s + 1] = w
                    chars = chars + #w.p
                end
            end
        end
    end
    if #cur > 0 or #parts == 0 then flush() end
    return parts
end

-- 每批送出前重查：沙盒、收件人身分、每組作者現在還看得到；有一項變了回 false（整個佇列取消，
-- 權限變動本來就會觸發客戶端重新對帳，拿到新的快照）
function SS.sendPart(q)
    local k = q.next
    local groups = q.parts[k]
    if not SS.allowed() and #groups > 0 then return false end
    if SS.principal(q.player) ~= q.name then return false end
    for i = 1, #groups do
        if not SS.canSee(groups[i].a, q.name) then return false end
    end
    sendServerCommand(q.player, SS.MODULE, "skSnap", { to = q.name, seq = q.seq, part = k, parts = #q.parts,
        groups = groups })
    q.next = k + 1
    return true
end

function Commands.skSync(player, args, name)
    local now = getTimestampMs()
    local last = SS.lastSync[name]
    if last and now - last < SS.SYNC_RATE_MS then return end
    SS.lastSync[name] = now
    SS.ensure()
    -- 這台電腦分享的筆對帳
    local origin, ids = args.origin, args.ids
    local rec = SS.authors[name]
    if type(origin) == "string" and RC().validOrigin(origin) and type(ids) == "string" and #ids <= SS.MAX_IDS_CHARS then
        local want, list, n = {}, nil, 0
        if ids ~= "" then
            list, n = C().split(ids, ",", C().MAX_STROKES)
            if not list then
                sendServerCommand(player, SS.MODULE, "skFail", { to = name, reason = "invalid" })
            end
        end
        if list or ids == "" then
            for i = 1, n do
                local id = C().parseInt(list[i], 1, C().MAX_ID)
                if id then want[C().lid(origin, id)] = true end
            end
            local prefix = origin .. ":"
            local dels, nDel = {}, 0
            local draft = rec and not rec.ro and SS.copyRec(rec) or nil
            if draft then
                local drop = {}
                for i = 1, draft.count do
                    local lid = draft.wires[i].id
                    if lid:sub(1, #prefix) == prefix and not want[lid] then drop[lid] = true end
                end
                dels, nDel = SS.compact(draft, drop)
                if nDel > 0 and not SS.commit(name, draft, false) then
                    SS.broadcast(name, {}, 0, dels, nDel)
                    rec = draft
                end
            end
            if SS.allowed() then
                local need, nNeed = {}, 0
                local pos = rec and SS.posMap(rec) or {}
                for i = 1, n do
                    local id = C().parseInt(list[i], 1, C().MAX_ID)
                    if id and not pos[C().lid(origin, id)] then
                        nNeed = nNeed + 1
                        need[nNeed] = list[i]
                    end
                end
                if nNeed > 0 then
                    sendServerCommand(player, SS.MODULE, "skNeed", { to = name,
                        ids = table.concat(need, ",", 1, nNeed) })
                end
            end
        end
    end
    -- 看得到的別人的手繪：第一批當場送（之後的即時 skAdd／skDel 一定排在它後面），其餘每 tick 一批
    SS.seq = SS.seq + 1
    local q = { player = player, name = name, seq = SS.seq, parts = SS.snapshotParts(name), next = 1 }
    SS.queue[name] = SS.sendPart(q) and q.next <= #q.parts and q or nil
end

function SS.tick()
    for name, q in pairs(SS.queue) do
        local ok, sent = pcall(SS.sendPart, q)
        if not (ok and sent) or q.next > #q.parts then SS.queue[name] = nil end
    end
end

SS.Commands = Commands
Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= SS.MODULE then return end
    local fn = Commands[command]
    if not (fn and player) or not (args == nil or type(args) == "table") then return end
    local name = SS.principal(player)
    if name then return fn(player, args or {}, name) end
    -- 沒有身分（分割畫面第 2～4 位）：分享回 identity，對帳不回（不收別人的分享）
    if command == "skPush" then
        sendServerCommand(player, SS.MODULE, "skFail", { to = player:getUsername(), reason = "identity" })
    end
end)
Events.OnTickEvenPaused.Add(SS.tick)
