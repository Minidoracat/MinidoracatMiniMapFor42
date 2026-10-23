-- MinidoracatMiniMap_Roads.lua — 自訂道路資料層（每位本機玩家一份）
-- 自己的道路存在玩家電腦的帳號檔 Lua/MinidoracatMiniMap/roads/<模式>/<世界>_p<pn>.txt（路徑規則、只讀規則
-- 同 _Places.lua 收藏檔：2026-10-14 裁定存玩家電腦；檔在卻打不開或版本較新＝只讀，壞檔當空清單可覆寫）。
-- 收到的分享道路只在記憶體（RoadShare 從伺服器同步）；自己對它們的停用存成本機檔的 OFF 行。草稿只在記憶體。
-- 寫檔先寫備份（Codec.writeSafe），主檔壞了讀備份；檔頭存這個檔固定的來源碼（分享時 lid＝來源碼:r編號）；
-- 刪掉的分享道路 sid 存成 DROP 行（待撤回），RoadShare 收到 roadDropped 才清。
-- 格式與驗證在 shared/MinidoracatMiniMap_RoadCodec.lua。每次變動：寫檔讀回成功才換上記憶體，
-- 之後 roadsRevision +1、通知路網 Core.navCustomRoadsChanged、有分享旗時 Core.roadSharePut。
-- PZ API：getWorld():getGameMode()／getWorld()（IsoWorld.java:541、3208）；getText 帶參數（Translator）。
local Core = MinidoracatMiniMapCore
local Codec = MinidoracatMiniMapRoadCodec
if not (Core and Core.ready and Codec) or Core.roadsList then return end

local M = { slots = {}, received = {}, drafts = {}, warned = {}, visible = {}, revision = 0 }
local BIT = { [0] = 1, 2, 4, 8 }
local BUDGET = 6000

function M.bump()
    M.revision = M.revision + 1
end
function M.validPn(pn)
    return type(pn) == "number" and pn >= 0 and pn <= 3 and pn % 1 == 0
end
function M.warn(pn, kind, err)
    local key = kind .. tostring(pn)
    if M.warned[key] then return end
    M.warned[key] = true
    print("[MinidoracatMiniMap] Roads " .. kind .. ": " .. tostring(err))
end
function M.path(pn)
    local world = getWorld()
    return "MinidoracatMiniMap/roads/" .. Codec.fileKey(world:getGameMode()) .. "/"
        .. Codec.fileKey(world:getWorld()) .. string.format("_p%d.txt", pn)
end
function M.copyList(t, n)
    local out = {}
    for i = 1, n do out[i] = t[i] end
    return out
end
-- 淺複本（保留原本的鍵與筆數，壞形狀留給 validateRoad 判）；非表回 nil
function M.copyTable(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end
-- 一條路的深複本（給呼叫端的「唯讀副本」與變更前的草稿）
function M.copyRoad(r)
    local out = M.copyTable(r)
    out.pts, out.segWidth, out.segSurface = M.copyTable(r.pts), M.copyTable(r.segWidth), M.copyTable(r.segSurface)
    out.ends, out.share = M.copyTable(r.ends), M.copyTable(r.share)
    return out
end
-- 檔案層複本：陣列換新、道路物件共用（道路一律整條換掉，不就地改）
function M.copyStore(s)
    return { nextId = s.nextId, origin = s.origin, count = s.count, roads = M.copyList(s.roads, s.count),
        offCount = s.offCount, off = M.copyList(s.off, s.offCount),
        dropCount = s.dropCount, drops = M.copyList(s.drops, s.dropCount) }
end
function M.indexOf(store, id)
    for i = 1, store.count do if store.roads[i].id == id then return i end end
    return nil
end
function M.offIndex(store, sid)
    for i = 1, store.offCount do if store.off[i] == sid then return i end end
    return nil
end
function M.dropIndex(store, sid)
    for i = 1, store.dropCount do if store.drops[i] == sid then return i end end
    return nil
end

-- 讀檔：unreadable／unsupported＝只讀（不能蓋掉讀不到或讀不懂的檔）；例外一律當 unreadable。
-- 主檔壞了讀備份（Codec.readStoreSafe）。沒有來源碼（新檔、舊檔）就配一個，下一次寫檔時存進去
function M.reload(slot)
    local ok, store, reason, recovered = pcall(Codec.readStoreSafe, M.path(slot.pn))
    if not ok then
        M.warn(slot.pn, "load", store)
        store, reason = nil, "unreadable"
    elseif reason then
        M.warn(slot.pn, "load", reason)
    elseif recovered then
        M.warn(slot.pn, "load", recovered .. ", read backup")
    end
    slot.error = reason
    slot.store = store or Codec.emptyStore()
    if not slot.store.origin then slot.store.origin = Codec.newOrigin() end
    M.bump()
end
-- 角色生命週期同 _Places.lua ensure：同槽位換角色（死亡重生、換世界）就重讀；同帳號／存檔讀同一個檔
function M.ensure(pn)
    if not M.validPn(pn) then return nil end
    local player = getSpecificPlayer(pn)
    local slot = M.slots[pn]
    if slot and slot.player == player then return slot end
    if not player then
        M.slots[pn] = nil
        return nil
    end
    slot = { pn = pn, player = player }
    M.slots[pn] = slot
    M.reload(slot)
    return slot
end
function M.writable(pn)
    if not M.validPn(pn) then return nil, "badargs" end
    local slot = M.ensure(pn)
    if not slot or slot.player:isDead() then return nil, "noplayer" end
    if slot.error == "unreadable" then M.reload(slot) end
    if slot.error == "unreadable" or slot.error == "unsupported" then return nil, "readonly" end
    return slot
end
-- 單筆原子變更：在複本上改、寫檔讀回成功才換上。change(store) 回 結果, 原因（結果 nil＝不寫）
function M.commit(pn, change)
    local slot, reason = M.writable(pn)
    if not slot then return nil, reason end
    local draft = M.copyStore(slot.store)
    local result, why = change(draft)
    if result == nil then return nil, why end
    local ok, saved = pcall(function() return Codec.writeSafe(M.path(pn), Codec.encodeStore(draft)) end)
    if not (ok and saved) then
        M.warn(pn, "save", ok and "read-back mismatch" or saved)
        return nil, "failed"
    end
    slot.store, slot.error = draft, nil
    M.bump()
    return result
end
function M.navChanged()
    if Core.navCustomRoadsChanged then Core.navCustomRoadsChanged() end
end
-- 分享同步：有任一旗＝送（已 rev+1，伺服器只收較新版本）；兩旗都關但還有 sid＝收回。
-- 送出的副本帶這個道路檔的來源碼：伺服器以 (作者, 來源碼:r編號) 認路，兩台電腦同帳號不互蓋
function M.syncShare(pn, road)
    if road.share.faction or road.share.safehouse then
        local copy = M.copyRoad(road)
        copy.origin = M.slots[pn] and M.slots[pn].store.origin
        if Core.roadSharePut then Core.roadSharePut(pn, copy) end
    elseif road.sid and Core.roadShareDrop then
        Core.roadShareDrop(pn, road.sid)
    end
end
-- 改一條自己的路（rev+1、重驗）；回 新的 road 或 nil, reason
function M.update(pn, id, edit)
    local road
    local done, why = M.commit(pn, function(store)
        local i = M.indexOf(store, id)
        if not i then return nil, "notfound" end
        road = M.copyRoad(store.roads[i])
        local err = edit(road)
        if err then return nil, err end
        road.rev = road.rev + 1
        road.overBudget = nil
        if not Codec.validateRoad(road) then return nil, "invalid" end
        store.roads[i] = road
        return true
    end)
    if not done then return nil, why end
    return road
end
-- 名稱：清理後空白＝預設名「自訂道路 N」（N＝本機編號）；超長回 nil
function M.nameFor(name, id)
    local clean, ok = Codec.cleanName(name)
    if not ok then return nil end
    -- 數字先格式化：Kahlua 把 double 參數傳進 Translator 會變 "1.0"
    return clean or getText("UI_MinidoracatMiniMap_RoadDefaultName", string.format("%d", Codec.idNumber(id)))
end

function M.save(pn, input)
    if type(input) ~= "table" then return false, "badargs" end
    local saved
    local done, why = M.commit(pn, function(store)
        local road = M.copyRoad({ pts = type(input.pts) == "table" and input.pts or {},
            segWidth = type(input.segWidth) == "table" and input.segWidth or {},
            segSurface = type(input.segSurface) == "table" and input.segSurface or {},
            ends = type(input.ends) == "table" and input.ends or {},
            share = type(input.share) == "table" and input.share or {} })
        road.source = input.source
        road.enabled = input.enabled ~= false
        if input.id == nil then
            road.id = "r" .. store.nextId
            road.rev = 1
            store.nextId = store.nextId + 1
            store.count = store.count + 1
            store.roads[store.count] = road
        else
            local i = M.indexOf(store, input.id)
            if not i then return nil, "notfound" end
            local old = store.roads[i]
            road.id, road.sid, road.rev = old.id, old.sid, old.rev + 1
            store.roads[i] = road
        end
        road.name = M.nameFor(input.name, road.id)
        if not road.name then return nil, "invalid" end
        if not Codec.validateRoad(road) then return nil, "invalid" end
        saved = road
        return road.id
    end)
    if not done then return false, why end
    M.navChanged()
    M.syncShare(pn, saved)
    return true, done
end

-- 收到的分享道路（記憶體）---------------------------------------------------------
function M.recv(pn)
    local r = M.received[pn]
    if not r then
        r = { count = 0, list = {} }
        M.received[pn] = r
    end
    return r
end
-- RoadShare 交來的路要有 sid 與 author，且通過驗證
function M.acceptable(road)
    return type(road) == "table" and Codec.sidNumber(road.sid) ~= nil and road.author ~= nil
        and Codec.validateRoad(road)
end
function M.recvIndex(r, sid)
    for i = 1, r.count do if r.list[i].sid == sid then return i end end
    return nil
end
function M.recvChanged()
    M.bump()
    M.navChanged()
end
-- 伺服器也會把作者自己的路送回來：同 pn 已有這個 sid 的自己的路就不算收到的（停用、清單、命中都以自己的為準）
function M.mine(store, sid)
    for i = 1, store.count do if store.roads[i].sid == sid then return true end end
    return false
end

-- 路網用：所有本機玩家啟用的自己的路＋收到且沒停用的路 --------------------------------
-- 依 sid 號碼插入排序（家規不用 table.sort）。ponytail: O(n^2)，收到的路上百條以後再換
function M.sortBySid(list, n)
    for i = 2, n do
        local item, key = list[i], Codec.sidNumber(list[i].road.sid)
        local j = i - 1
        while j >= 1 and Codec.sidNumber(list[j].road.sid) > key do
            list[j + 1] = list[j]
            j = j - 1
        end
        list[j + 1] = item
    end
end
function M.active(maxSegments)
    local entries, n, bySid, recv, rn, all, an = {}, 0, {}, {}, 0, {}, 0
    local function add(road, pn, own)
        all[an + 1] = road
        an = an + 1
        local e = road.sid and bySid[road.sid]
        if e then
            if e.usableBy % (BIT[pn] * 2) < BIT[pn] then e.usableBy = e.usableBy + BIT[pn] end
            return
        end
        e = { road = road, usableBy = BIT[pn] }
        -- 自己的路帶擁有者與本機 id（NavCore 吸附時排除正在編輯的那條）；自己的路先加，同 sid 合併保留這兩欄
        if own then e.ownerPn, e.roadId = pn, road.id end
        if road.sid then bySid[road.sid] = e end
        return e
    end
    for pn = 0, 3 do
        local slot = M.ensure(pn)
        if slot then
            local store = slot.store
            for i = 1, store.count do
                local road = store.roads[i]
                road.overBudget = nil
                if road.enabled then
                    local e = add(road, pn, true)
                    if e then n = n + 1; entries[n] = e end
                end
            end
        end
    end
    for pn = 0, 3 do
        local slot, r = M.slots[pn], M.received[pn]
        if slot and r then
            for i = 1, r.count do
                local road = r.list[i]
                road.overBudget = nil
                if not M.offIndex(slot.store, road.sid) and not M.mine(slot.store, road.sid) then
                    local e = add(road, pn)
                    if e then rn = rn + 1; recv[rn] = e end
                end
            end
        end
    end
    M.sortBySid(recv, rn)
    for i = 1, rn do entries[n + i] = recv[i] end
    n = n + rn
    local limit = math.min(BUDGET, math.max(0, tonumber(maxSegments) or BUDGET))
    local out, on, used, cut = {}, 0, 0, {}
    for i = 1, n do
        local e = entries[i]
        local segs = 0
        for _ in pairs(e.road.segWidth) do segs = segs + 1 end
        if on < i - 1 or used + segs > limit then
            cut[e.road] = true
            if e.road.sid then cut[e.road.sid] = true end
        else
            used = used + segs
            on = on + 1
            out[on] = e
        end
    end
    for i = 1, an do
        local road = all[i]
        if cut[road] or (road.sid and cut[road.sid]) then road.overBudget = true end
    end
    return out, on
end

-- 點到線段最近點
function M.nearest(road, wx, wy)
    local pts = road.pts
    local best, bi, bx, by
    local i = 1
    while pts[i + 3] do
        local ax, ay, bxx, byy = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        local dx, dy = bxx - ax, byy - ay
        local t = ((wx - ax) * dx + (wy - ay) * dy) / (dx * dx + dy * dy)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local px, py = ax + t * dx, ay + t * dy
        local d = (wx - px) * (wx - px) + (wy - py) * (wy - py)
        if not best or d < best then best, bi, bx, by = d, (i + 1) / 2, px, py end
        i = i + 2
    end
    return best, bi, bx, by
end

local ERROR_KEYS = { readonly = "UI_MinidoracatMiniMap_RoadError_readonly",
    failed = "UI_MinidoracatMiniMap_RoadError_failed", invalid = "UI_MinidoracatMiniMap_RoadError_invalid",
    notfound = "UI_MinidoracatMiniMap_RoadError_notfound", noplayer = "UI_MinidoracatMiniMap_RoadError_noplayer" }

-- 公開（Core）----------------------------------------------------------------------
Core.roadsRevision = function() return M.revision end
Core.roadsErrorText = function(reason)
    return getText(ERROR_KEYS[reason] or "UI_MinidoracatMiniMap_RoadError_failed")
end
Core.roadsList = function(pn)
    local slot = M.ensure(pn)
    if not slot then return {} end
    local out = {}
    for i = 1, slot.store.count do out[i] = M.copyRoad(slot.store.roads[i]) end
    local err = slot.error
    return out, (err == "unreadable" or err == "unsupported") and err or nil
end
Core.roadsReceived = function(pn)
    local slot = M.ensure(pn)
    local r = M.received[pn]
    if not slot or not r then return {} end
    local out, n = {}, 0
    for i = 1, r.count do
        if not M.mine(slot.store, r.list[i].sid) then
            local road = M.copyRoad(r.list[i])
            road.off = M.offIndex(slot.store, road.sid) ~= nil
            n = n + 1
            out[n] = road
        end
    end
    return out
end
Core.roadsGet = function(pn, id)
    local slot = M.ensure(pn)
    local i = slot and M.indexOf(slot.store, id)
    return i and M.copyRoad(slot.store.roads[i]) or nil
end
Core.roadsSave = M.save
-- 刪除有 sid：sid 記進待撤回（DROP 行，跟刪除同一次寫檔），收到伺服器 roadDropped 才清；連線同步時重送
Core.roadsDelete = function(pn, id)
    local sid
    local done, why = M.commit(pn, function(store)
        local i = M.indexOf(store, id)
        if not i then return nil, "notfound" end
        sid = store.roads[i].sid
        for j = i, store.count - 1 do store.roads[j] = store.roads[j + 1] end
        store.roads[store.count] = nil
        store.count = store.count - 1
        if sid and not M.dropIndex(store, sid) then
            store.dropCount = store.dropCount + 1
            store.drops[store.dropCount] = sid
        end
        return true
    end)
    if not done then return false, why end
    M.navChanged()
    if sid and Core.roadShareDrop then Core.roadShareDrop(pn, sid) end
    return true
end
Core.roadsPendingDrops = function(pn)
    local slot = M.ensure(pn)
    if not slot then return {} end
    return M.copyList(slot.store.drops, slot.store.dropCount)
end
-- 不在清單＝已清（不寫檔）
Core.roadsClearPendingDrop = function(pn, sid)
    local slot = M.ensure(pn)
    if not (slot and M.dropIndex(slot.store, sid)) then return true end
    local done, why = M.commit(pn, function(store)
        local i = M.dropIndex(store, sid)
        for j = i, store.dropCount - 1 do store.drops[j] = store.drops[j + 1] end
        store.drops[store.dropCount] = nil
        store.dropCount = store.dropCount - 1
        return true
    end)
    if not done then return false, why end
    return true
end
-- 停用只影響本機導航，不改 rev、不重送分享
Core.roadsSetEnabled = function(pn, id, on)
    local done, why = M.commit(pn, function(store)
        local i = M.indexOf(store, id)
        if not i then return nil, "notfound" end
        local road = M.copyRoad(store.roads[i])
        road.enabled = on == true
        store.roads[i] = road
        return true
    end)
    if not done then return false, why end
    M.navChanged()
    return true
end
Core.roadsRename = function(pn, id, name)
    local road, why = M.update(pn, id, function(r)
        r.name = M.nameFor(name, r.id)
        if not r.name then return "invalid" end
    end)
    if not road then return false, why end
    M.navChanged()
    M.syncShare(pn, road)
    return true
end
-- 分享旗（rev+1）：之後依 syncShare 送出或收回
Core.roadsSetShareFlags = function(pn, id, flags)
    if type(flags) ~= "table" then return false, "badargs" end
    local road, why = M.update(pn, id, function(r)
        r.share = { faction = flags.faction == true, safehouse = flags.safehouse == true }
    end)
    if not road then return false, why end
    M.syncShare(pn, road)
    return true
end
-- RoadShare 回報伺服器編號（收回成功傳 nil）；不改 rev
Core.roadsSetSid = function(pn, id, sid)
    if sid ~= nil and not Codec.sidNumber(sid) then return false, "badargs" end
    local done, why = M.commit(pn, function(store)
        local i = M.indexOf(store, id)
        if not i then return nil, "notfound" end
        local road = M.copyRoad(store.roads[i])
        road.sid = sid
        store.roads[i] = road
        return true
    end)
    if not done then return false, why end
    M.navChanged()
    return true
end
Core.roadsSetReceivedOff = function(pn, sid, off)
    if not Codec.sidNumber(sid) then return false, "badargs" end
    local done, why = M.commit(pn, function(store)
        local i = M.offIndex(store, sid)
        if off and not i then
            store.offCount = store.offCount + 1
            store.off[store.offCount] = sid
        elseif not off and i then
            for j = i, store.offCount - 1 do store.off[j] = store.off[j + 1] end
            store.off[store.offCount] = nil
            store.offCount = store.offCount - 1
        end
        return true
    end)
    if not done then return false, why end
    M.navChanged()
    return true
end
-- 收到的路複製成自己的新路（沒有 sid、作者、分享旗）
Core.roadsCopyReceived = function(pn, sid)
    local r = M.received[pn]
    local i = r and M.recvIndex(r, sid)
    if not i then return nil, "notfound" end
    local src = r.list[i]
    local ok, id = M.save(pn, { name = src.name, pts = src.pts, segWidth = src.segWidth,
        segSurface = src.segSurface, ends = src.ends, source = src.source })
    if not ok then return nil, id end
    return id
end
Core.roadsReplaceReceived = function(pn, list)
    if not M.validPn(pn) or type(list) ~= "table" then return 0 end
    local r = { count = 0, list = {} }
    local i = 1
    while list[i] ~= nil do
        local road = list[i]
        if M.acceptable(road) then
            local j = M.recvIndex(r, road.sid)
            if not j then
                r.count = r.count + 1
                j = r.count
            end
            r.list[j] = M.copyRoad(road)
        else
            M.warn(pn, "received", "rejected road")
        end
        i = i + 1
    end
    M.received[pn] = r
    M.recvChanged()
    return r.count
end
Core.roadsUpsertReceived = function(pn, road)
    if not M.validPn(pn) or not M.acceptable(road) then return false, "invalid" end
    local r = M.recv(pn)
    local i = M.recvIndex(r, road.sid)
    if not i then
        r.count = r.count + 1
        i = r.count
    end
    r.list[i] = M.copyRoad(road)
    M.recvChanged()
    return true
end
Core.roadsRemoveReceived = function(pn, sid)
    local r = M.validPn(pn) and M.received[pn]
    local i = r and M.recvIndex(r, sid)
    if not i then return false end
    for j = i, r.count - 1 do r.list[j] = r.list[j + 1] end
    r.list[r.count] = nil
    r.count = r.count - 1
    M.recvChanged()
    return true
end
Core.roadsDraft = function(pn) return M.drafts[pn] end
Core.roadsSetDraft = function(pn, draft)
    if not M.validPn(pn) or type(draft) ~= "table" then return false end
    M.drafts[pn] = draft
    M.bump()
    return true
end
Core.roadsClearDraft = function(pn)
    if not M.validPn(pn) or M.drafts[pn] == nil then return end
    M.drafts[pn] = nil
    M.bump()
end
Core.roadsActive = M.active
Core.roadsAt = function(pn, wx, wy, radius)
    local slot = M.ensure(pn)
    if not slot or type(wx) ~= "number" or type(wy) ~= "number" or type(radius) ~= "number" then return nil end
    local best, hit = radius * radius, nil
    local function try(road, kind)
        local d, seg, px, py = M.nearest(road, wx, wy)
        if d <= best and (not hit or d < best) then
            best = d
            hit = { road = road, kind = kind, seg = seg, px = px, py = py }
        end
    end
    for i = 1, slot.store.count do try(slot.store.roads[i], "own") end
    local r = M.received[pn]
    for i = 1, r and r.count or 0 do
        local road = r.list[i]
        if not M.mine(slot.store, road.sid) then
            try(road, "received")
            if hit and hit.road == road then hit.off = M.offIndex(slot.store, road.sid) ~= nil end
        end
    end
    if hit then hit.dist = math.sqrt(best) end
    return hit
end
-- 畫圖用：依 revision 快取（每幀呼叫）；road 是共用物件，唯讀
Core.roadsVisible = function(pn)
    local slot = M.ensure(pn)
    if not slot then return {} end
    local cache = M.visible[pn]
    if cache and cache.revision == M.revision then return cache.list end
    local out, n = {}, 0
    for i = 1, slot.store.count do
        local road = slot.store.roads[i]
        n = n + 1
        out[n] = { road = road, kind = "own", enabled = road.enabled }
    end
    local r = M.received[pn]
    for i = 1, r and r.count or 0 do
        local road = r.list[i]
        if not M.mine(slot.store, road.sid) then
            n = n + 1
            out[n] = { road = road, kind = "received", enabled = not M.offIndex(slot.store, road.sid),
                author = road.author }
        end
    end
    M.visible[pn] = { revision = M.revision, list = out }
    return out
end

-- 換角色時先讀檔，讓分割畫面新玩家的路進路網；換世界全部重置（同 _Places.lua OnGameStart）
Events.OnCreatePlayer.Add(function(pn)
    local before = M.slots[pn]
    local slot = M.ensure(pn)
    if slot and slot ~= before and (slot.store.count > 0 or (before and before.store.count > 0)) then
        M.navChanged()
    end
end)
Events.OnGameStart.Add(function()
    for pn = 0, 3 do M.slots[pn], M.received[pn], M.drafts[pn], M.visible[pn] = nil, nil, nil, nil end
    for key in pairs(M.warned) do M.warned[key] = nil end
    M.bump()
end)
