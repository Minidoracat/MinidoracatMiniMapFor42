-- MinidoracatMiniMap_SketchShare.lua
-- 手繪線分享（客戶端）：把分享的筆排隊送上伺服器、登入與換陣營／安全屋後對帳、接收別人分享的手繪。
-- 伺服器端在 server/MinidoracatMiniMapSketchShare.lua（每位作者一個檔、收件人判斷、離線成員上線補收）；
-- 資料在 _Sketch.lua（Core.Sketch；SK.apply 每次改動呼叫 Core.sketchShareChanged）。
-- 每筆的分享（私人或陣營與安全屋成員）在畫的時候決定（工具列「分享」，2026-11-08 使用者裁定照道路分享）。
-- 送出：每位玩家一個佇列，每 PUSH_MS 最多送一包（先刪後加，每包座標 ≤ PUSH_CHARS 字）。
-- 對帳：OnCreatePlayer、SyncFaction、OnSafehousesChanged、沙盒或分享能不能用變了 → 防抖 SYNC_DELAY_MS 送
-- skSync { 來源碼, 這台電腦分享的筆 id }；帳號檔還在載入就等載完（清單不完整會讓伺服器刪掉還在的筆）。
-- 功能閘門 share（addon 例：錶沒有通訊）只擋送出新的筆；撤回照送、收到的照常顯示。單機沒有分享。
-- 伺服器回覆都帶 to（收件角色名），照 to 分到對應的 pn（同 _RoadShare.lua）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.sketchShareAvailable then return end

local SH = {
    MODULE = "MinidoracatMiniMapSketch",
    PUSH_MS = 2000, SYNC_DELAY_MS = 1000, SYNC_IDS_CHARS = 32000, PUSH_CHARS = 24000, PUSH_MAX_ADDS = 200, PUSH_MAX_DELS = 2000,
    SAY_MS = 10000, -- 同一種失敗提示至少隔這麼久
    q = {},        -- [pn] = { adds = { [lid] = 筆 }, dels = { [lid] = true }, last = 上次送的毫秒 }
    snaps = {},    -- [pn] = { seq, parts, got, have = { [part] = 筆陣列 }, live = 收齊前收到的即時事件 }
    syncAt = {}, avail = {}, said = {},
}
Core.SketchShare = SH
local function C() return MinidoracatMiniMapSketchCodec end

function SH.pnOf(to)
    if type(to) ~= "string" then return nil end
    for pn = 0, 3 do
        local p = getSpecificPlayer(pn)
        if p and p:getUsername() == to then return pn end
    end
    return nil
end

function SH.say(pn, key)
    local now = getTimestampMs()
    local k = key .. tostring(pn)
    if SH.said[k] and now - SH.said[k] < SH.SAY_MS then return end
    SH.said[k] = now
    if Core.navMessage then Core.navMessage(pn, getText(key), false) end
end

function SH.policyOn()
    local P = Core.policy
    return P ~= nil and P.readBool("AllowSketchShare", true) == true
end

-- 能不能分享新的筆：回 true 或 false, 原因翻譯鍵
Core.sketchShareAvailable = function(pn)
    if not isClient() then return false, "UI_MinidoracatMiniMap_SketchShareNoSP" end
    -- 分割畫面第 2～4 位在伺服器沒有身分（MinidoracatMiniMapGroups.principal），送了也會被拒
    if pn ~= 0 then return false, "UI_MinidoracatMiniMap_SketchShareWhy_identity" end
    if not SH.policyOn() then return false, "UI_MinidoracatMiniMap_SketchShareWhy_disabled" end
    local fa = Core.featureAllowed
    if fa then
        local allowed, key = fa(pn, "share")
        if allowed == false then
            return false, type(key) == "string" and key or "UI_MinidoracatMiniMap_FeatureUnavailable"
        end
    end
    return true
end

-- 這位玩家已分享的筆數與點數（本機；伺服器另有同樣的上限）。擦除切段時 _Sketch.lua 也用它決定片段還能不能分享
function SH.sharedTotals(pn)
    local slot = Core.Sketch and Core.Sketch.slots[pn]
    local store = slot and slot.store
    local n, pts = 0, 0
    for i = 1, store and store.count or 0 do
        local s = store.strokes[i]
        if s.share then n, pts = n + 1, pts + s.np end
    end
    return n, pts
end
Core.sketchSharedTotals = SH.sharedTotals
Core.sketchShareRoom = function(pn, np)
    local n, pts = SH.sharedTotals(pn)
    return n + 1 <= C().SHARE_MAX_STROKES and pts + np <= C().SHARE_MAX_POINTS
end

function SH.queueOf(pn)
    local q = SH.q[pn]
    if not q then
        q = { adds = {}, dels = {}, last = 0 }
        SH.q[pn] = q
    end
    return q
end

-- SK.apply 每次改動呼叫：分享的筆被拿掉＝撤回、加上＝送出（同一個 lid 先刪後加＝復原擦除時放回原筆）
Core.sketchShareChanged = function(pn, origin, rem, nr, add, na)
    if not isClient() then return end
    local q
    for k = 1, nr do
        local s = rem[k]
        if s.share then
            q = q or SH.queueOf(pn)
            local lid = C().lid(origin, s.id)
            q.adds[lid] = nil
            q.dels[lid] = true
        end
    end
    for k = 1, na do
        local s = add[k]
        if s.share then
            q = q or SH.queueOf(pn)
            q.adds[C().lid(origin, s.id)] = s
        end
    end
end

-- 送一包：撤回全部（上限 PUSH_MAX_DELS），新增到座標字數上限為止；沒送完的留到下一包
function SH.flush(pn, p, q, origin, canAdd)
    local dels, nd = {}, 0
    for lid in pairs(q.dels) do
        if nd >= SH.PUSH_MAX_DELS then break end
        nd = nd + 1
        dels[nd] = lid
    end
    for i = 1, nd do q.dels[dels[i]] = nil end
    local adds, na, chars = {}, 0, 0
    if canAdd then
        for lid, s in pairs(q.adds) do
            local w = C().toWire(origin, s)
            if na >= SH.PUSH_MAX_ADDS or (na > 0 and chars + #w.p > SH.PUSH_CHARS) then break end
            na = na + 1
            adds[na] = w
            chars = chars + #w.p
        end
        for i = 1, na do q.adds[adds[i].id] = nil end
    else
        -- 不能分享（沙盒關、功能閘門擋）：丟掉待送的新增，之後能用時對帳（skSync）會把缺的要回去
        q.adds = {}
    end
    if nd == 0 and na == 0 then return false end
    local args = {}
    if na > 0 then args.adds = adds end
    if nd > 0 then args.dels = dels end
    sendClientCommand(p, SH.MODULE, "skPush", args)
    return true
end

-- 對帳：這台電腦（來源碼）分享的筆 id；帳號檔讀不到（只讀）時不帶清單，伺服器只送快照、不刪
function SH.sendSync(pn, p)
    local slot = Core.Sketch and Core.Sketch.slots[pn]
    local store = slot and slot.store
    local args = {}
    if store and not slot.error then
        local ids, n = {}, 0
        for i = 1, store.count do
            local s = store.strokes[i]
            if s.share then
                n = n + 1
                ids[n] = string.format("%d", s.id)
            end
        end
        local text = table.concat(ids, ",", 1, n)
        -- 網路上單一字串 ≤ 32,767 位元組（GameWindow.java:1266）；超過就不帶清單：伺服器只送快照、不刪任何東西
        if #text <= SH.SYNC_IDS_CHARS then
            args.origin = store.origin
            args.ids = text
        end
    end
    sendClientCommand(p, SH.MODULE, "skSync", args)
end

function SH.requestSync(pn)
    local due = getTimestampMs() + SH.SYNC_DELAY_MS
    for p = 0, 3 do
        if pn == nil or pn == p then SH.syncAt[p] = due end
    end
end

function SH.tick()
    if not isClient() then return end
    local now = getTimestampMs()
    for pn = 0, 3 do
        local p = getSpecificPlayer(pn)
        if p and p:getOnlineID() >= 0 then -- 登入初期還沒有 onlineID（同 _RoadShare.lua）
            local avail = Core.sketchShareAvailable(pn) == true
            -- 沙盒或閘門變了就對帳：關掉時伺服器回空快照（收到的清掉），打開時把缺的筆要回去。
            -- 沙盒另外看（不能分享的座位照樣要知道收到的該清掉）
            local state = (SH.policyOn() and 1 or 0) + (avail and 2 or 0)
            if state ~= SH.avail[pn] then
                if SH.avail[pn] ~= nil then SH.requestSync(pn) end
                SH.avail[pn] = state
            end
            local slot = Core.Sketch and Core.Sketch.slots[pn]
            local loaded = slot and slot.store ~= nil
            local due = SH.syncAt[pn]
            if due and now >= due and loaded then
                SH.syncAt[pn] = nil
                SH.sendSync(pn, p)
            end
            local q = SH.q[pn]
            if q and loaded and now - q.last >= SH.PUSH_MS then
                if SH.flush(pn, p, q, slot.store.origin, avail) then q.last = now end
            end
        elseif not p then
            SH.syncAt[pn], SH.q[pn], SH.avail[pn] = nil, nil, nil
        end
    end
end

-- 伺服器回覆 ---------------------------------------------------------------------------
-- 一組 wire → 筆陣列（a＝作者；壞的整筆丟掉）
function SH.decode(author, wires, out, n)
    if type(author) ~= "string" or author == "" or #author > 128 or type(wires) ~= "table" then return n end
    local i = 1
    while wires[i] ~= nil do
        local s = C().fromWire(wires[i])
        if s and s.a == nil then
            s.a, s.wp = author, wires[i].p -- wp：座標原字串，收快照時和舊的比對、沒變就沿用已算好的外框與抽點層
            n = n + 1
            out[n] = s
        end
        i = i + 1
    end
    return n
end

function SH.applyLive(pn, ev)
    if ev.kind == "add" then
        if Core.sketchRecvAdd then Core.sketchRecvAdd(pn, ev.list, ev.n) end
    elseif Core.sketchRecvDel then
        Core.sketchRecvDel(pn, ev.a, ev.ids, ev.n)
    end
end

-- 即時事件：快照收齊前先存起來，收齊替換之後再套（伺服器先送第一批快照才轉送之後的改動，順序有保證）
function SH.live(pn, ev)
    local b = SH.snaps[pn]
    if b then
        b.live[#b.live + 1] = ev
    else
        SH.applyLive(pn, ev)
    end
end

-- 分批的快照：同一個 seq 收齊才整批替換；換 seq＝丟掉舊的半批和它收到的即時事件（新的一批是伺服器在那些
-- 事件之後才產生的，已經包含它們）
function SH.onSnap(pn, args)
    local seq, part, parts = args.seq, args.part, args.parts
    if type(seq) ~= "number" or type(part) ~= "number" or type(parts) ~= "number"
        or part < 1 or part > parts or parts > 100000 or part % 1 ~= 0 or parts % 1 ~= 0 then return end
    local b = SH.snaps[pn]
    if not b or b.seq ~= seq then
        b = { seq = seq, parts = parts, got = 0, have = {}, live = {} }
        SH.snaps[pn] = b
    end
    if b.parts ~= parts or b.have[part] then return end
    local list, n = {}, 0
    local groups = type(args.groups) == "table" and args.groups or {}
    local i = 1
    while groups[i] ~= nil do
        local g = groups[i]
        if type(g) == "table" then n = SH.decode(g.a, g.s, list, n) end
        i = i + 1
    end
    b.have[part] = { list = list, n = n }
    b.got = b.got + 1
    if b.got < parts then return end
    SH.snaps[pn] = nil
    local all, total = {}, 0
    for k = 1, parts do
        local h = b.have[k]
        for j = 1, h.n do
            total = total + 1
            all[total] = h.list[j]
        end
    end
    if Core.sketchRecvReplace then Core.sketchRecvReplace(pn, all, total) end
    for k = 1, #b.live do SH.applyLive(pn, b.live[k]) end
end

SH.handlers = {
    skSnap = SH.onSnap,
    skAdd = function(pn, args)
        local list = {}
        local n = SH.decode(args.a, args.s, list, 0)
        if n > 0 then SH.live(pn, { kind = "add", list = list, n = n }) end
    end,
    skDel = function(pn, args)
        if type(args.a) ~= "string" or type(args.ids) ~= "table" then return end
        local ids, n = {}, 0
        while type(args.ids[n + 1]) == "string" do
            n = n + 1
            ids[n] = args.ids[n]
        end
        if n > 0 then SH.live(pn, { kind = "del", a = args.a, ids = ids, n = n }) end
    end,
    -- 伺服器缺的筆（作者離線時畫的、上一包沒送到的）：還是分享的就排進佇列
    skNeed = function(pn, args)
        local slot = Core.Sketch and Core.Sketch.slots[pn]
        local store = slot and slot.store
        if not (store and type(args.ids) == "string") then return end
        local want = {}
        -- 上限同伺服器 skSync 拆清單（檔案硬上限）；超過分享名額的照樣排進佇列，伺服器回 limit 後轉私人
        local list, n = C().split(args.ids, ",", C().MAX_STROKES)
        for i = 1, list and n or 0 do
            local id = C().parseInt(list[i], 1, C().MAX_ID)
            if id then want[id] = true end
        end
        local q = SH.queueOf(pn)
        for i = 1, store.count do
            local s = store.strokes[i]
            if s.share and want[s.id] then q.adds[C().lid(store.origin, s.id)] = s end
        end
    end,
    skFail = function(pn, args)
        local reason = tostring(args.reason)
        if reason == "rate" then
            SH.requestSync(pn) -- 這一包被丟掉：對帳一次就補齊
            return
        end
        -- 因上限被拒的筆改成私人（本機仍標分享會讓工具與對帳以為已經送上去了）
        if reason == "limit" and type(args.ids) == "table" and Core.sketchMakePrivate then
            local slot = Core.Sketch and Core.Sketch.slots[pn]
            local store = slot and slot.store
            local ids, n = {}, 0
            local prefix = store and store.origin .. ":"
            while store and type(args.ids[n + 1]) == "string" do
                local lid = args.ids[n + 1]
                n = n + 1
                if lid:sub(1, #prefix) == prefix then
                    ids[#ids + 1] = C().parseInt(lid:sub(#prefix + 1), 1, C().MAX_ID)
                end
            end
            if #ids > 0 then
                Core.sketchMakePrivate(pn, ids, #ids)
                -- 伺服器上可能還有這個 lid 的舊版（同 lid 換長被拒時伺服器保留舊的）：撤回，也不再送新增
                local q = SH.queueOf(pn)
                for k = 1, n do
                    local lid = args.ids[k]
                    if lid:sub(1, #prefix) == prefix then
                        q.adds[lid] = nil
                        q.dels[lid] = true
                    end
                end
            end
        end
        local key = "UI_MinidoracatMiniMap_SketchShareWhy_" .. reason
        SH.say(pn, getTextOrNull(key) and key or "UI_MinidoracatMiniMap_SketchShareWhy_invalid")
    end,
}

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SH.MODULE or type(args) ~= "table" then return end
    local fn = SH.handlers[command]
    local pn = fn and SH.pnOf(args.to)
    if pn then fn(pn, args) end
end)
Events.OnCreatePlayer.Add(function(pn) SH.requestSync(pn) end)
Events.SyncFaction.Add(function() SH.requestSync() end)
Events.OnSafehousesChanged.Add(function() SH.requestSync() end)
Events.OnTick.Add(SH.tick)
-- 引擎先觸發 OnCreatePlayer(0)（GameLoadingState.java:429）、進遊戲才 OnGameStart（IngameState.java:766）：
-- 這裡清掉上一局的狀態後要自己補要一次對帳，否則登入那次的 requestSync 被清掉，離線時的分享收不到
-- （2026-11-08 share-sketch-mp 場 3 實機：重開伺服器後登入沒有任何快照）
Events.OnGameStart.Add(function()
    SH.q, SH.snaps, SH.syncAt, SH.avail, SH.said = {}, {}, {}, {}, {}
    SH.requestSync()
end)
