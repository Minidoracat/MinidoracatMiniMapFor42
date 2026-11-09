-- MinidoracatMiniMap_Cleared.lua — 資源點「去過／已清空」的資料與偵測（客戶端；2026-11-08 設計稿 cleared 作答）
-- 帳號檔 Lua/MinidoracatMiniMap/cleared/<模式>/<世界>_p<pn>.txt（路徑規則同收藏檔 _Places.lua placesPath；
-- 格式在 shared/MinidoracatMiniMap_ClearedCodec.lua）。先寫 .bak.txt 再寫主檔（RoadCodec.writeSafe），讀檔規則見 C.readSafe。
--
-- 去過：OnTick 每 CHECK_TICKS 查一次 player:getCurrentBuildingDef()（IsoGameCharacter.java:4123，站在室內格才有），
--   換了建築才問 MinidoracatMiniMapResourceAPI.buildingCategories（房間資料版判定，同步；有類別＝資源點，兩種標示方式都算），
--   結果依 BuildingDef id 快取。
-- 容器掃描：只掃玩家正在裡面（進門、出門；沒整棟載入時每 RESCAN_MS 補一次）的那棟：getRooms → RoomDef:getIsoRoom
--   （RoomDef.java:191）→ IsoRoom:getSquares（只有已載入的格子，IsoRoom.java:318）→ 物件的容器。排除屍體、
--   玩家蓋的箱子（IsoThumpable）、堆肥箱、地上物品（同 LootRespawn.java:131-133 的排除）。有工作才掛 OnTickEvenPaused，
--   每 tick 最多 SCAN_BUDGET_MS、每 CHECK_EVERY 格看一次時鐘（同 shared/MinidoracatMiniMapResources.lua）。
--   整棟載入＝外框蓋到的每個 chunk 都在 IsoCell:getChunk（IsoCell.java:359）；沒整棟載入不更新容器數（n 留舊值或 0）。
-- 翻過：原版事件 OnRefreshInventoryWindowContainers 的 "end"（ISInventoryPage.lua:1906）讀搜刮視窗的容器按鈕
--   （周圍 3×3、同層、碰得到，ISInventoryPage.lua:1670-1690），容器在目前這棟才記。
-- 自動已清空：翻過數 ≥ 門檻（ClearedAutoPct）×容器數，而且容器數來自整棟掃描（n>0）。進門掃描排了還沒完成時
--   （s.entering）搜刮視窗照樣記翻過、不判門檻，留給 CL.finish（不然重置前的舊進度加上新列出的容器，會在 F3 判之前
--   就自動已清空並上傳）；出門、換建築清掉，沒整棟載入時 finish 照舊用上次的容器數判。
-- 拿過：原版搬移動作 ISInventoryTransferAction:perform 做完、而且真的搬到東西（「拿全部」與拖曳都經
--   ISInventoryPane:transferItemsByWeight → ISInventoryTransferUtil.newInventoryTransferAction，ISInventoryPane.lua:655、:709、:1248）。
--   物品已不在來源時 isValid 設 dontAdd、start 直接 setTime(0) 不建交易（ISInventoryTransferAction.lua:36-41、:258-269），
--   引擎照樣呼叫 perform，所以要看成功的證據，而且要在呼叫原版之前取：多人＝這次的交易
--   （start 建 transactionId，:313）已完成（全域 isItemTransactionDone，LuaManager.java:12149-12155；原版 perform 會把
--   transactionId 清成 0，:509-510；被拒走 forceStop 不會到 perform，:161-166）；單機＝來源容器物品數變少（perform 裡
--   transferItem，:501-503）。搬移當下先同步目前建築（CL.sync），不等下一次 CHECK_TICKS。
--   來源要是目前這棟的計入容器（CL.counted，同翻過）；身上、背包、載具、屍體、地上的不算。多人只有「拿過」或已清空、
--   已刷新的才上傳（C.relevant；2026-11-08 使用者裁定）。
-- 再走進去比對（B1）：進門的整棟掃描「被拿過的容器數變少、物品總數變多」＝補過貨（LootRespawn.java:156-161 會把
--   hasBeenLooted 改回 false），標「已刷新」（同 B2、B3，留到下次走進去）。自己拿東西、搬走家具都是反方向。
--   多人客戶端的 hasBeenLooted 只在 chunk 從伺服器載入時更新（RemoveInventoryItemFromContainerPacket.processClient
--   不設、Transaction 只在伺服器 update，42.21 反編譯），出門掃描記到的 l 偏低：多人時 B1 只會漏判、不會誤判。
--   多人、進門前沒拿過（排程當下的 t＝0）的標記不上傳，伺服器 B2／B3 碰不到、B1 也不比：進門整棟掃描物品總數和上次
--   不同（不看 l；重新生成時沒探索過的容器重擲戰利品，LoadGridsquarePerformanceWorkaround.java:65-69，總數可能變少；
--   LootRespawn 只補被拿過的，LootRespawn.java:138）＝別人動過或被重置，只清本機翻過進度（不標已刷新）；掃描期間剛拿、
--   已上傳的舊進度經 CL.touch 送 drop 撤掉，拿過留著。誤判（別人動過容器）的代價只是清掉本機進度。
-- 一筆標記可能對到兩個 BuildingDef（地上／地下、兩種外框，C.same）：容器數、被拿過、物品數、翻過的容器只算
--   外框和標記相同的那個 def（curOwn），合併只用在顯示與查找；否則換 def 時 n 被另一棟的掃描蓋掉、翻過數卻跨 def 累加。
-- 單機的 B2：LoadChunk（IsoChunk.java:3969）時 chunk:isNewChunk()（IsoChunk.java:5170，存檔不存在而重新生成才為真）
--   ＝那個 chunk 被重置，碰到它的已清空／有進度標記改「已刷新」。多人由伺服器做（server/MinidoracatMiniMapClearedShare.lua）。
-- 狀態改變（新去過、清空、刷新、隊友資料）才遞增 revision，圖標依它重建（MinidoracatMiniMapPOI.lua currentSig）；
-- 翻過的進度只在第一次有進度（和清掉本機進度）時 bump（單機 B2 的 chunk 索引看它，CL.index），
-- 提示文字在停留時現查。helper 全掛 CL（主 chunk local 上限）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.Cleared then return end

local CL = {
    CHECK_TICKS = 30,
    SCAN_BUDGET_MS = 2,
    CHECK_EVERY = 16,
    RESCAN_MS = 30000,
    SAVE_DELAY_MS = 2000,
    GRID = 64,          -- 比對用的格子邊長（世界格）
    slots = {},         -- [pn] = { path, store, readOnly, dirtyAt, lastDef, lastDefId, cur, rescanAt, drops }
    team = {},          -- [pn] = { n, list = { { a = 作者, m = 標記 } } }（_ClearedShare.lua 寫）
    poiCache = {},      -- [BuildingDef id] = true|false
    jobs = {}, jobN = 0,
    hooked = false,
    rev = 0,
    tickN = 0,
    idx = {},           -- [pn] = { rev, teamRev, own = 格子索引, team = 格子索引, chunks = { ["cx,cy"] = true } }
    teamRev = 0,        -- 隊友資料改了但已清空集合沒變（不必重建圖標，只讓查找索引重建）
    dataRev = 0,        -- 自己的帳號檔資料改了（CL.dirty；搜尋清單的快取鍵用）
    warned = {},
    newChunks = {}, newN = 0, -- 單機這次遊戲載入過的新 chunk { cx, cy }：每個 slot 建立時補套一次（帳號檔讀進來前就載完的）
    adopted = false,    -- 新 chunk 記滿時已把有帳號檔的玩家都建了 slot（CL.adopt）
}
Core.Cleared = CL

function CL.codec() return MinidoracatMiniMapClearedCodec end
function CL.warn(key, msg)
    if CL.warned[key] then return end
    CL.warned[key] = true
    print("[MinidoracatMiniMap] Cleared " .. key .. ": " .. tostring(msg))
end
function CL.now()
    local gt = getGameTime()
    return gt and gt:getWorldAgeHours() or 0
end
function CL.bump() CL.rev = CL.rev + 1 end
Core.clearedRevision = function() return CL.rev end
-- 資料版本（搜尋清單用）：圖標版本＋隊友進度＋自己的進度，任何一個變就變（三個都只增不減）
Core.clearedDataRevision = function() return CL.rev + CL.teamRev + CL.dataRev end

-- 帳號檔 ------------------------------------------------------------------------------
function CL.path(pn)
    local Codec, w = MinidoracatMiniMapRoadCodec, getWorld()
    return "MinidoracatMiniMap/cleared/" .. Codec.fileKey(w:getGameMode()) .. "/" .. Codec.fileKey(w:getWorld())
        .. string.format("_p%d.txt", pn)
end

-- 讀檔規則見 C.readSafe：主檔打不開或版本較新＝只讀（讀不懂的檔不覆寫）；主檔與備份都壞＝空、可寫
function CL.read(path)
    local C = CL.codec()
    local store, err, recovered = C.readSafe(path, C.decodeClient)
    if err then CL.warn("load:" .. path, err) end
    if recovered then CL.warn("load:" .. path, recovered .. ", read backup") end
    return store or C.emptyStore(), err == "unreadable" or err == "unsupported"
end

function CL.slot(pn)
    if not (MinidoracatMiniMapRoadCodec and CL.codec()) then return nil end
    local ok, path = pcall(CL.path, pn)
    if not ok then return nil end
    local s = CL.slots[pn]
    if s and s.path == path then return s end
    local okRead, store, readOnly = pcall(CL.read, path)
    if not okRead then
        CL.warn("load:" .. path, tostring(store))
        store, readOnly = CL.codec().emptyStore(), true
    end
    s = { path = path, store = store, readOnly = readOnly, drops = {} }
    CL.slots[pn] = s
    -- 來源碼：這台電腦這個帳號檔固定（同自訂道路），伺服器以（來源碼, 建築）存，兩台電腦不互刪
    if not store.origin then
        store.origin = MinidoracatMiniMapRoadCodec.newOrigin()
        CL.dirty(s)
    end
    CL.catchUp(pn, s)
    CL.bump()
    return s
end

function CL.dirty(s)
    CL.dataRev = CL.dataRev + 1
    if not s.dirtyAt then s.dirtyAt = getTimestampMs() + CL.SAVE_DELAY_MS end
end

function CL.save(s)
    s.dirtyAt = nil
    if s.readOnly then return false end
    local ok, saved = pcall(MinidoracatMiniMapRoadCodec.writeSafe, s.path, CL.codec().encodeClient(s.store))
    if not (ok and saved) then
        CL.warn("save:" .. s.path, ok and "read-back mismatch" or tostring(saved))
        CL.dirty(s) -- 留著下次再寫
    end
    return ok and saved
end

function CL.flush()
    for pn = 0, 3 do
        local s = CL.slots[pn]
        if s and s.dirtyAt then CL.save(s) end
    end
end

-- 多人：會存到伺服器的標記改了就標待上傳；從「會存」變「不存」記待刪（_ClearedShare.lua 送 clrDrop）。
-- 外框超過網路上限（C.MAX_EDGE）的只留在本機
function CL.touch(s, m, wasRelevant)
    local C = CL.codec()
    local now = C.relevant(m)
    if isClient() and m.w <= C.MAX_EDGE and m.h <= C.MAX_EDGE then
        if now then
            m.u = true
            s.upload = true
        elseif wasRelevant then
            s.drops[C.key(m)] = true
            s.upload = true
        end
    end
    if now ~= wasRelevant then CL.bump() end
    CL.dirty(s)
end

-- 標記查找 ----------------------------------------------------------------------------
function CL.find(s, box)
    local C, st = CL.codec(), s.store
    for i = 1, st.count do
        if C.same(st.marks[i], box) then return st.marks[i], i end
    end
    return nil
end

function CL.remove(s, at)
    local st = s.store
    st.marks[at].dead = true
    for i = at, st.count - 1 do st.marks[i] = st.marks[i + 1] end
    st.marks[st.count] = nil
    st.count = st.count - 1
end

-- 上限滿了先刪最舊的「只有去過」；全部都有進度就不新增。外框超過本機上限的不記（讀檔會整份拒收）
function CL.add(s, box)
    local C, st = CL.codec(), s.store
    if box.w > C.MAX_LOCAL_EDGE or box.h > C.MAX_LOCAL_EDGE then return nil end
    if st.count >= C.MAX_MARKS then
        local oldest, at = nil, nil
        for i = 1, st.count do
            local m = st.marks[i]
            if not C.progress(m) and (not oldest or m.vh < oldest.vh) then oldest, at = m, i end
        end
        if not at then return nil end
        CL.remove(s, at)
    end
    local m = C.newMark(box.x, box.y, box.w, box.h)
    st.count = st.count + 1
    st.marks[st.count] = m
    return m
end

-- 格子索引（重建圖標、提示、搜尋用；依 revision 快取）：key＝中心所在格
function CL.gridAdd(grid, m, v)
    local g = CL.GRID
    local k = math.floor((m.x + m.w / 2) / g) * 100000 + math.floor((m.y + m.h / 2) / g)
    local list = grid[k]
    if not list then
        list = {}
        grid[k] = list
    end
    list[#list + 1] = v
end
-- 中心落在 box 裡的候選才可能 same()：只掃 box 蓋到的格子
function CL.gridFind(grid, box, getMark)
    local g, C = CL.GRID, CL.codec()
    for gx = math.floor(box.x / g), math.floor((box.x + box.w) / g) do
        for gy = math.floor(box.y / g), math.floor((box.y + box.h) / g) do
            local list = grid[gx * 100000 + gy]
            if list then
                for i = 1, #list do
                    local v = list[i]
                    if C.same(getMark(v), box) then return v end
                end
            end
        end
    end
    return nil
end
function CL.markOf(v) return v end
function CL.teamMarkOf(v) return v.m end

function CL.index(pn)
    local s = CL.slots[pn]
    if not s then return nil end
    local ix = CL.idx[pn]
    if ix and ix.rev == CL.rev and ix.teamRev == CL.teamRev and ix.store == s.store then return ix end
    local C = CL.codec()
    ix = { rev = CL.rev, teamRev = CL.teamRev, store = s.store, own = {}, team = {}, chunks = {} }
    local st = s.store
    for i = 1, st.count do
        local m = st.marks[i]
        CL.gridAdd(ix.own, m, m)
        if C.progress(m) then
            local keys, kn = C.chunkKeys(m)
            for k = 1, kn do ix.chunks[keys[k]] = true end
        end
    end
    local t = CL.team[pn]
    for i = 1, t and t.n or 0 do CL.gridAdd(ix.team, t.list[i].m, t.list[i]) end
    CL.idx[pn] = ix
    return ix
end

-- 這棟的自己標記、隊友標記（隊友先找已清空的，沒有再找有進度的）
function CL.lookup(pn, box)
    local ix = CL.index(pn)
    if not ix then return nil, nil end
    local own = CL.gridFind(ix.own, box, CL.markOf)
    local team = CL.gridFind(ix.team, box, CL.teamMarkOf)
    if team and team.m.ch <= 0 then
        -- 同一棟可能有好幾位隊友：優先已清空的
        local t = CL.team[pn]
        local C = CL.codec()
        for i = 1, t.n do
            local e = t.list[i]
            if e.m.ch > 0 and C.same(e.m, box) then return own, e end
        end
    end
    return own, team
end

-- 地圖代碼：1 去過、2 已清空、3 隊友已清空、4 已刷新（nil＝沒有標記）；第二值＝自己真的走進去過（vh>0；
-- 沒去過就手動標已清空的那筆不算，「只顯示去過的資源點」與搜尋「只看沒去過」都用它）
function CL.code(pn, box)
    local own, team = CL.lookup(pn, box)
    local code
    if own then
        if own.ch > 0 then code = 2 elseif own.rh > 0 then code = 4 else code = 1 end
    end
    if (not code or code == 1) and team and team.m.ch > 0 then code = 3 end
    return code, own ~= nil and own.vh > 0, own, team
end
Core.clearedCode = CL.code
-- 圖標重建（MinidoracatMiniMapPOI.lua）：先 clearedBuildStart 一次（記下有資料的本機玩家；回 false＝沒有任何
-- 標記，整次重建不必查），再每筆 clearedZoneMarks：每位本機玩家的代碼表，沒有標記回 nil；第二值＝有本機玩家
-- 自己的標記（「只顯示去過的資源點」）。visitMarks＝PoiVisitMarks：關＝只有去過的不給代碼
Core.clearedBuildStart = function(visitMarks)
    local pns, n = {}, 0
    for pn = 0, 3 do
        local s = CL.slots[pn]
        local t = CL.team[pn]
        if s and getSpecificPlayer(pn) and (s.store.count > 0 or (t and t.n > 0)) then
            n = n + 1
            pns[n] = pn
        end
    end
    CL.build = { pns = pns, n = n, visitMarks = visitMarks, box = {} }
    return n > 0
end
Core.clearedZoneMarks = function(x, y, w, h)
    local b = CL.build
    if not b or b.n == 0 then return nil, false end
    local box = b.box
    box.x, box.y, box.w, box.h = x, y, w, h
    local out, own = nil, false
    for k = 1, b.n do
        local pn = b.pns[k]
        local code, mine = CL.code(pn, box)
        own = own or mine
        if code == 1 and not b.visitMarks then code = nil end
        if code then
            out = out or {}
            out[pn] = code
        end
    end
    return out, own
end

-- 去過 ------------------------------------------------------------------------------
function CL.isPoi(def)
    local ok, id = pcall(def.getID, def)
    if not ok then return false end
    local hit = CL.poiCache[id]
    if hit == nil then
        local API = MinidoracatMiniMapResourceAPI
        hit = API and API.buildingCategories and API.buildingCategories(def) ~= nil or false
        CL.poiCache[id] = hit
    end
    return hit
end

function CL.defBox(def)
    return { x = def:getX(), y = def:getY(), w = def:getW(), h = def:getH() }
end

function CL.visit(pn, s, def)
    local box = CL.defBox(def)
    if box.w < 1 or box.h < 1 then return nil end
    local C = CL.codec()
    local m = CL.find(s, box)
    local isNew = m == nil
    if isNew then
        m = CL.add(s, box)
        if not m then return nil end
    end
    local was, first = C.relevant(m), m.vh == 0
    m.vh = CL.now()
    if m.rh > 0 then m.rh = 0 end -- 已刷新留到下次走進去，之後變回去過
    CL.touch(s, m, was)
    -- 第一次真的走進去（手動標過的建築原本不算去過，CL.code）：圖標與搜尋要重建
    if isNew or first then CL.bump() end
    return m
end

-- 搜刮視窗事件與世界右鍵用：目前這棟（玩家站在室內格的那棟資源點）的標記
function CL.current(pn)
    local s = CL.slots[pn]
    return s and s.cur, s
end

-- 容器掃描 ----------------------------------------------------------------------------
function CL.excluded(o)
    return instanceof(o, "IsoDeadBody") or instanceof(o, "IsoThumpable") or instanceof(o, "IsoCompost")
        or instanceof(o, "IsoWorldInventoryObject")
end

-- 外框蓋到的每個 chunk 都已載入
function CL.loaded(m)
    local cell = getCell()
    if not cell then return false end
    local C = CL.codec()
    for cx = math.floor(m.x / C.CHUNK), math.floor((m.x + m.w - 1) / C.CHUNK) do
        for cy = math.floor(m.y / C.CHUNK), math.floor((m.y + m.h - 1) / C.CHUNK) do
            if not cell:getChunk(cx, cy) then return false end
        end
    end
    return true
end

-- 進門掃描排了還沒完成（s.entering，只在記憶體）：搜刮視窗照樣記翻過，但自動判斷等 finish（見 CL.onInventory）。
-- job.t＝排程當下的拿過（F3 看的是進門前有沒有拿過，不看掃描期間剛拿的）
function CL.queue(pn, s, m, def, phase)
    if phase == "enter" then s.entering = m end
    for i = 1, CL.jobN do
        local j = CL.jobs[i]
        if j.mark == m and j.phase == phase then return end
    end
    local rooms = def:getRooms()
    local job = { pn = pn, slot = s, mark = m, phase = phase, rooms = rooms, rn = rooms and rooms:size() or 0,
        ri = 0, n = 0, l = 0, i = 0, seen = {}, full = CL.loaded(m), t = m.t }
    CL.jobN = CL.jobN + 1
    CL.jobs[CL.jobN] = job
    if not CL.hooked then
        CL.hooked = true
        Events.OnTickEvenPaused.Add(CL.step)
    end
end

-- 容器數＝不同容器鍵的數目（和翻過的同一個鍵函式：同一格同類型的兩個容器在搜刮視窗算一個，分子分母要同一集合，
-- 否則全部翻完也到不了 100%）；l、i 逐容器算（只給 B1 比對）
function CL.scanSquare(job, sq)
    local C = CL.codec()
    local objs = sq:getObjects()
    for k = 0, objs:size() - 1 do
        local o = objs:get(k)
        local cc = o and o:getContainerCount() or 0
        if cc > 0 and not CL.excluded(o) then
            for c = 0, cc - 1 do
                local cont = o:getContainerByIndex(c)
                if cont then
                    local key = C.containerKey(job.mark, sq:getX(), sq:getY(), sq:getZ(), cont:getType())
                    if not job.seen[key] then
                        job.seen[key] = true
                        job.n = job.n + 1
                    end
                    if cont:isHasBeenLooted() then job.l = job.l + 1 end
                    job.i = job.i + cont:getItems():size()
                end
            end
        end
    end
end

-- 回 true＝做完；false＝預算用完，下個 tick 接著做
function CL.stepJob(job, t0)
    -- IsoRoom:getSquares() 是活的 ArrayList：兩個 tick 之間 chunk 卸載或載入（IsoChunk.removeFromWorld →
    -- IsoRoom.removeSquare）會改它，接著用舊索引會丟 IndexOutOfBounds（2026-11-09 玩家回報：Index 519 out of
    -- bounds for length 451）。清單變了＝這次沒掃到整棟，收工交給 finish 排補掃
    if job.sqs and job.sqs:size() ~= job.sn then
        job.full = false
        return true
    end
    local k = 0
    while true do
        if not job.sqs then
            if job.ri >= job.rn then return true end
            local rd = job.rooms:get(job.ri)
            job.ri = job.ri + 1
            local room = rd and rd:getIsoRoom()
            if room then
                job.sqs = room:getSquares()
                job.sn, job.si = job.sqs:size(), 0
            else
                job.full = false
            end
        elseif job.si >= job.sn then
            job.sqs = nil
        else
            local sq = job.sqs:get(job.si)
            job.si = job.si + 1
            if sq then CL.scanSquare(job, sq) end
            k = k + 1
            if k % CL.CHECK_EVERY == 0 and getTimestampMs() - t0 >= CL.SCAN_BUDGET_MS then return false end
        end
    end
end

function CL.step()
    local t0 = getTimestampMs()
    while CL.jobN > 0 do
        local job = CL.jobs[1]
        local ok, done = pcall(CL.stepJob, job, t0)
        if not ok then
            CL.warn("scan", done)
            job.full, done = false, true
        end
        if not done then return end
        for i = 1, CL.jobN - 1 do CL.jobs[i] = CL.jobs[i + 1] end
        CL.jobs[CL.jobN] = nil
        CL.jobN = CL.jobN - 1
        CL.finish(job)
        if getTimestampMs() - t0 >= CL.SCAN_BUDGET_MS then return end
    end
    CL.hooked = false
    Events.OnTickEvenPaused.Remove(CL.step)
end

function CL.finish(job)
    local m, s = job.mark, job.slot
    local held = job.phase == "enter" and s.entering == m
    if held then s.entering = nil end
    if m.dead or CL.slots[job.pn] ~= s then return end
    local C = CL.codec()
    if not job.full then
        if s.cur == m then s.rescanAt = getTimestampMs() + CL.RESCAN_MS end
        -- 掃描期間壓著的自動判斷：沒整棟載入，照舊用上次的容器數判
        if held and s.cur == m then
            local was = C.relevant(m)
            if CL.autoCheck(m) then
                CL.bump()
                CL.touch(s, m, was)
            end
        end
        return
    end
    if s.cur == m then s.rescanAt = nil end
    local was = C.relevant(m)
    -- B1：被拿過的變少、物品變多＝補過貨，標已刷新（留到下次走進去）。多人只翻過沒拿的不比：已刷新會上傳，
    -- 等於把沒拿東西的建築分享出去（C.relevant 的裁定）
    local had = m.ch > 0 or m.s > 0 and (m.t > 0 or not isClient())
    local refilled = job.phase == "enter" and m.n > 0 and had and job.l < m.l and job.i > m.i
    if refilled then
        C.refresh(m, CL.now())
        CL.bump()
    end
    -- 多人、進門前沒拿過的：物品總數有變＝別人動過或被重置，只清本機進度（見檔頭）。掃描期間剛拿、已經上傳的
    -- 舊進度，下面 C.relevant 變了會經 CL.touch 送 drop 撤掉
    if job.phase == "enter" and isClient() and m.ch == 0 and m.rh == 0 and job.t == 0 and m.s > 0 and m.n > 0
        and job.i ~= m.i then
        m.s, m.keys, m.kn = 0, nil, nil
        CL.bump()
    end
    local changed = m.n ~= job.n
    m.n, m.l, m.i, m.oh = job.n, job.l, job.i, CL.now()
    local auto = CL.autoCheck(m)
    if auto then CL.bump() end
    -- 對帳摘要裡的欄位（n、ch、rh）變了一定要上傳；l、i、oh 只寫本機
    if changed or auto or refilled or C.relevant(m) ~= was then CL.touch(s, m, was) else CL.dirty(s) end
end

-- 自動已清空：門檻 ClearedAutoPct（50–100），容器數要來自整棟掃描
function CL.autoCheck(m)
    if m.ch > 0 or m.n <= 0 or not Core.getBoolOption("ClearedAuto", true) then return false end
    local pct = Core.getSliderValue("ClearedAutoPct", 90, 50, 100)
    if m.s * 100 < pct * m.n then return false end
    m.ch, m.cs, m.keys, m.kn = CL.now(), "a", nil, nil
    return true
end

-- 計入的容器（翻過、拿過共用；同整棟掃描：格子上的物件，不算屍體、玩家蓋的箱子、堆肥箱、地上物品，
-- 也不算角色身上與載具——它們是 IsoMovingObject，不在 sq:getObjects 裡）：回容器所在的格子
function CL.counted(cont)
    local o = cont and cont:getParent()
    if not o or CL.excluded(o) or instanceof(o, "IsoMovingObject") then return nil end
    return o:getSquare()
end

-- 翻過：搜刮視窗列出的容器，在目前這棟才記 --------------------------------------------
function CL.onInventory(page, state)
    if state ~= "end" or page.onCharacter then return end
    local pn = page.player
    local s = type(pn) == "number" and CL.slots[pn]
    local m = s and s.cur
    if not m or not s.curOwn or m.ch > 0 or not page.backpacks then return end
    local C = CL.codec()
    local was, first, added = C.relevant(m), m.s == 0, false
    for b = 1, #page.backpacks do
        local cont = page.backpacks[b].inventory
        local sq = CL.counted(cont)
        local bd = sq and sq:getBuildingDef()
        if bd and bd:getID() == s.lastDefId then
            local key = C.containerKey(m, sq:getX(), sq:getY(), sq:getZ(), cont:getType())
            m.keys = m.keys or {}
            if not m.keys[key] and (m.kn or 0) < C.MAX_COUNT then
                m.keys[key] = true
                m.kn = (m.kn or 0) + 1
                m.s = m.s + 1
                added = true
            end
        end
    end
    if not added then return end
    -- 進門掃描還沒完成：容器數、F3 都還沒判，自動判斷留給 CL.finish
    local auto = s.entering ~= m and CL.autoCheck(m)
    if auto or first then CL.bump() end -- 第一次有進度：單機 B2 要看的 chunk 變了（CL.index）
    CL.touch(s, m, was)
end

-- 拿過：本機玩家的原版搬移動作做完（見檔頭）。分割畫面依 playerNum 各記各的
function CL.onTransfer(action)
    local p = action.character
    local pn = p and p:getPlayerNum()
    local s = pn and getSpecificPlayer(pn) == p and CL.slots[pn]
    if not s or p:isDead() then return end
    CL.sync(pn, s, p, getTimestampMs()) -- 剛進門、還沒到下一次 CHECK_TICKS 就拿完
    local m = s.cur
    if not m or not s.curOwn or m.dead or m.ch > 0 or m.t > 0 then return end
    local sq = CL.counted(action.srcContainer)
    local bd = sq and sq:getBuildingDef()
    if not (bd and bd:getID() == s.lastDefId) then return end
    local was = CL.codec().relevant(m)
    m.t = 1
    CL.touch(s, m, was)
end
-- 成功的證據（呼叫原版之前取，見檔頭）：多人 true／false，單機來源容器的物品數
function CL.transferBefore(action)
    if isClient() then
        local tid = action.transactionId
        return tid ~= nil and tid ~= 0 and isItemTransactionDone(tid) == true
    end
    local src = action.srcContainer
    return src and src:getItems():size() or false
end
function CL.transferAfter(action, before)
    if isClient() then
        if before ~= true then return end
    elseif type(before) ~= "number" or action.srcContainer:getItems():size() >= before then
        return
    end
    CL.onTransfer(action)
end
function CL.hookTransfer()
    if CL.transferHooked or not ISInventoryTransferAction then return end
    CL.transferHooked = true
    local perform = ISInventoryTransferAction.perform
    ISInventoryTransferAction.perform = function(self)
        -- 原版 perform 一定要呼叫：我們的擷取與判斷丟錯都只記 log
        local ok, before = pcall(CL.transferBefore, self)
        if not ok then
            CL.warn("transfer:before", before)
            before = nil
        end
        local r = perform(self)
        if before ~= nil then
            local ok2, err = pcall(CL.transferAfter, self, before)
            if not ok2 then CL.warn("transfer:after", err) end
        end
        return r
    end
end

-- 手動標記、取消、忘記（地圖右鍵、世界右鍵、搜尋「動作…」）-------------------------------
-- 標為已清空：沒去過的也可以標（建立一筆 vh＝0 的紀錄）；取消：退回去過、進度歸零（從沒去過的整筆刪掉）
Core.clearedSet = function(pn, box, on)
    local s = CL.slot(pn)
    if not s then return false end
    local C = CL.codec()
    local m, at = CL.find(s, box)
    if on then
        if not m then
            m = CL.add(s, box)
            if not m then return false end
        end
        if m.ch > 0 then return true end
        local was = C.relevant(m)
        m.ch, m.cs, m.rh, m.keys, m.kn = CL.now(), "m", 0, nil, nil
        CL.touch(s, m, was)
    else
        if not m or m.ch <= 0 then return true end
        local was = C.relevant(m)
        m.ch, m.cs, m.s, m.t, m.keys, m.kn = 0, "-", 0, 0, nil, nil
        if m.vh <= 0 then
            CL.remove(s, at)
            if was and isClient() then
                s.drops[C.key(m)] = true
                s.upload = true
            end
            CL.dirty(s)
        else
            CL.touch(s, m, was)
        end
    end
    CL.bump()
    return true
end

-- 忘記這裡：整筆刪掉（伺服器上的副本一起刪）
Core.clearedForget = function(pn, box)
    local s = CL.slot(pn)
    if not s then return false end
    local m, at = CL.find(s, box)
    if not m then return false end
    local C = CL.codec()
    if C.relevant(m) and isClient() then
        s.drops[C.key(m)] = true
        s.upload = true
    end
    CL.remove(s, at)
    if s.cur == m then s.cur = nil end
    CL.dirty(s)
    CL.bump()
    return true
end

-- 伺服器刷新（_ClearedShare.lua）：伺服器刷新序號 rs 比本機處理過的新才算（不比遊戲時數：管理員可以把時鐘往回撥，
-- 刷新時數就會早於本機最後一次掃描）。伺服器那筆現在不是已刷新（之後又清空過）只記下序號
function CL.applyRefresh(pn, srv)
    local s = CL.slots[pn]
    local m = s and CL.find(s, srv)
    if not m or srv.rs <= (m.rs or 0) then return false end
    m.rs = srv.rs
    CL.dirty(s)
    if srv.rh <= 0 then return false end
    local C = CL.codec()
    C.refresh(m, srv.rh)
    m.u = nil -- 伺服器那份已經是刷新後的狀態
    CL.bump()
    return true
end

-- 單機 B2 ----------------------------------------------------------------------------
function CL.chunkXY(chunk)
    for x = 0, 7 do
        local sq = chunk:getGridSquare(x, 0, 0)
        if sq then return math.floor(sq:getX() / 8), math.floor(sq:getY() / 8) end
    end
    return nil
end

-- 這個 chunk 重新生成：碰到它的已清空／有進度標記改已刷新
function CL.refreshChunk(s, cx, cy)
    local C, now = CL.codec(), CL.now()
    for i = 1, s.store.count do
        local m = s.store.marks[i]
        -- 沒走進去過的（vh＝0，手動標的）不算：isNewChunk 第一次生成也是真（IsoChunk.java:2260、:5170）
        if (m.ch > 0 or m.s > 0) and m.vh > 0 and C.touchesChunk(m, cx, cy) then
            C.refresh(m, now)
            CL.dirty(s)
            CL.bump()
        end
    end
end

-- 讀檔進遊戲時玩家周圍的 chunk 在帳號檔讀進來之前就載完了（2026-11-08 E2E：已清空建築在出生點旁、離線被重置，
-- 讀檔後沒變已刷新），分割畫面的玩家也可能晚加入：這次遊戲載入過的新 chunk 都記在 CL.newChunks，
-- 每個 slot 建立時（CL.slot）補套一次，之後載入的當下套給已有的 slot。
-- 超過 NEW_MAX 要丟之前，先把有帳號檔、還沒建 slot 的玩家的 slot 建起來（CL.adopt：讀檔＋補套已記的），
-- 之後載入的當下就套給它們；沒有帳號檔的玩家沒有標記，不會漏
CL.NEW_MAX = 4096
function CL.adopt()
    local C = CL.codec()
    for pn = 0, 3 do
        if not CL.slots[pn] then
            local ok, path = pcall(CL.path, pn)
            local data, err
            if ok then data, err = C.readSafe(path, C.decodeClient) end
            if data ~= nil or err ~= nil then CL.slot(pn) end -- 有檔（讀得懂或讀不懂）就建；兩份都沒有＝沒有標記
        end
    end
end
function CL.onLoadChunk(chunk)
    if isClient() or isServer() or not chunk:isNewChunk() then return end
    local cx, cy = CL.chunkXY(chunk)
    if not cx then return end
    if CL.newN < CL.NEW_MAX then
        CL.newN = CL.newN + 1
        CL.newChunks[CL.newN] = { cx, cy }
    elseif not CL.adopted then
        CL.adopted = true
        CL.adopt()
    end
    local key = CL.codec().fmtInt(cx) .. "," .. CL.codec().fmtInt(cy)
    for pn = 0, 3 do
        local ix = CL.slots[pn] and CL.index(pn)
        if ix and ix.chunks[key] then CL.refreshChunk(CL.slots[pn], cx, cy) end
    end
end

-- slot 剛建立：補套這次遊戲已載入的新 chunk（只看這個帳號檔有標記的 chunk）
function CL.catchUp(pn, s)
    if CL.newN == 0 then return end
    local ix, C = CL.index(pn), CL.codec()
    for i = 1, CL.newN do
        local c = CL.newChunks[i]
        if ix.chunks[C.fmtInt(c[1]) .. "," .. C.fmtInt(c[2])] then CL.refreshChunk(s, c[1], c[2]) end
    end
end

-- 換建築：去過判定、進門／出門掃描；同一棟時到期補掃（CL.tick 每 CHECK_TICKS、CL.onTransfer 搬移當下）
function CL.sync(pn, s, p, nowMs)
    local def = p:getCurrentBuildingDef()
    local id = def and def:getID() or nil
    if id ~= s.lastDefId then
        if s.cur and s.curOwn and s.lastDef and not s.cur.dead then
            CL.queue(pn, s, s.cur, s.lastDef, "exit")
        end
        s.lastDef, s.lastDefId, s.cur, s.curOwn, s.rescanAt, s.entering = def, id, nil, false, nil, nil
        if def and CL.isPoi(def) then
            s.cur = CL.visit(pn, s, def)
            -- 標記外框和這個 def 一樣才掃描、記翻過（另一個 def 只算去過；見檔頭）
            s.curOwn = s.cur ~= nil and CL.codec().key(s.cur) == CL.codec().key(CL.defBox(def))
            if s.curOwn then CL.queue(pn, s, s.cur, def, "enter") end
        end
    elseif s.cur and s.rescanAt and nowMs >= s.rescanAt then
        s.rescanAt = nil
        CL.queue(pn, s, s.cur, def, "rescan")
    end
end

-- 每 CHECK_TICKS：去過判定、補掃、延遲寫檔 -----------------------------------------------
function CL.tick()
    CL.tickN = CL.tickN + 1
    if CL.tickN < CL.CHECK_TICKS then return end
    CL.tickN = 0
    local nowMs = getTimestampMs()
    for pn = 0, 3 do
        local p = getSpecificPlayer(pn)
        local s = p and not p:isDead() and CL.slot(pn)
        if s then CL.sync(pn, s, p, nowMs) end
        s = CL.slots[pn]
        if s and s.dirtyAt and nowMs >= s.dirtyAt then CL.save(s) end
    end
end

Events.OnTick.Add(CL.tick)
Events.OnRefreshInventoryWindowContainers.Add(CL.onInventory)
Events.LoadChunk.Add(CL.onLoadChunk)
Events.OnSave.Add(CL.flush)
Events.OnCreatePlayer.Add(function(pn)
    local s = CL.slots[pn]
    if s then s.lastDef, s.lastDefId, s.cur, s.curOwn, s.entering = nil, nil, nil, false, nil end
end)
Events.OnGameStart.Add(function()
    CL.slots, CL.team, CL.idx, CL.poiCache = {}, {}, {}, {}
    CL.hookTransfer() -- 進遊戲才包，不靠 client 檔的載入順序（同 ItemCleaner 包 ISInventoryTransferAction.perform）
    CL.bump()
end)
