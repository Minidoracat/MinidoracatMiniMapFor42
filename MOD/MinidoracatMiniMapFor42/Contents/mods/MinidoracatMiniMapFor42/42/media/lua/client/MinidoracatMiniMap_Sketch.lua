-- MinidoracatMiniMap_Sketch.lua — 手繪線資料層（每位本機玩家一份）與兩張地圖的繪製（Core.drawSketch）
-- 自己的手繪存在玩家電腦的帳號檔 Lua/MinidoracatMiniMap/sketch/<模式>/<世界>_p<pn>.txt（路徑與只讀規則同
-- _Roads.lua：檔在卻打不開或版本較新＝只讀；壞檔先讀 .bak.txt，備份也壞＝空清單可覆寫）。別人分享的手繪
-- 只在記憶體（_SketchShare.lua 從伺服器同步）。格式在 shared/MinidoracatMiniMap_SketchCodec.lua。
-- 載入：OnCreatePlayer 開始，OnTickEvenPaused 每 tick 限時 LOAD_BUDGET_MS 分批解碼與建抽點層（50,000 點一次做完會卡）。
-- 寫檔：每次改動延後 SAVE_DELAY_MS（停筆 2 秒）由 OnTickEvenPaused 寫（SP 開地圖暫停時照樣會跑），
-- 工具關掉時（deactivate → Core.sketchFlush）一定寫一次。記憶體先改；slot.dirty（還沒存）只在寫檔讀回成功才清，
-- 失敗只提示、SAVE_RETRY_MS 後再試，關工具照樣回 false。
-- 繪製：_Nav.lua drawNavTargets 在自訂道路之後、導航路線之前呼叫 Core.drawSketch（小地圖與世界地圖同一個入口）。
--   仿射與視野用同幀的 Core.zoneFrame；候選快取（視野外擴＋整數縮放＋資料版本當鍵）只在該重建時重建；
--   抽點層是 RoadDraw 的 RD.buildLevels；每幀 drawPolygon 上限 BUDGET（規劃見 SK.plan）；
--   畫面上不到 TINY_PX 的筆畫成一點，同一格只畫一點。整段包 stencil，出錯也一定 clear（drawPolygon 不裁切）。
local Core = MinidoracatMiniMapCore
local Codec = MinidoracatMiniMapSketchCodec
if not (Core and Core.ready and Codec) or Core.drawSketch then return end
local floor = math.floor

local SK = {
    slots = {}, revision = 0, warned = {},
    SAVE_DELAY_MS = 2000, SAVE_RETRY_MS = 10000,
    LOAD_BUDGET_MS = 4,  -- 每 tick 最多花幾毫秒；每筆都看時鐘（一筆 500 點的抽點層就要幾毫秒），超支最多一筆
    -- 畫的上限 Codec.DRAW_*（滿了拒畫）；擦除與復原只擋到檔案硬上限 Codec.MAX_*（擦除會切出新筆與交點）
    HARD_STROKES = Codec.MAX_STROKES, HARD_POINTS = Codec.MAX_POINTS,
    WPX = { 2, 4, 7 },                    -- 細／中／粗在「畫的那個縮放」的畫面寬度
    BUDGET = 600,                         -- 每幀 drawPolygon 上限
    TOL0 = 0.25,                          -- 抽點第 2 層的容差（格），之後逐層加倍
    VIEW_PAD = 0.5,                       -- 候選快取外擴：視野寬高的比例
    PLAN_PAD = 0.25,                      -- 規劃外擴：視野寬高的比例（只平移、還在這框內就沿用規劃）
    TINY_PX = 2,                          -- 外框在畫面上小於這麼多 px 的筆畫成一點
    -- 原版五色（ISWorldMapSymbols.lua:1098-1104 的順序：黑筆、鉛筆、紅、藍、綠）
    COLORS = { { r = 0.129, g = 0.129, b = 0.129 }, { r = 0.2, g = 0.2, b = 0.2 }, { r = 0.65, g = 0.054, b = 0.054 },
        { r = 0.156, g = 0.188, b = 0.49 }, { r = 0.06, g = 0.39, b = 0.17 } },
    ITEMS = { "Pen", "Pencil", "RedPen", "BluePen", "GreenPen" },
}
Core.Sketch = SK

local function RC() return MinidoracatMiniMapRoadCodec end

function SK.bump() SK.revision = SK.revision + 1 end
function SK.warn(pn, kind, err)
    local key = kind .. tostring(pn)
    if SK.warned[key] then return end
    SK.warned[key] = true
    print("[MinidoracatMiniMap] Sketch " .. kind .. ": " .. tostring(err))
end
function SK.say(pn, key, ...)
    if Core.navMessage then Core.navMessage(pn or 0, getText(key, ...), false) end
end
function SK.path(pn)
    local world = getWorld()
    return "MinidoracatMiniMap/sketch/" .. RC().fileKey(world:getGameMode()) .. "/"
        .. RC().fileKey(world:getWorld()) .. string.format("_p%d.txt", pn)
end

-- 一筆的外框、抽點層與檔案行（新增、讀檔、收到分享時算一次）
function SK.prepare(s)
    local pts, np = s.pts, s.np
    local minx, miny, maxx, maxy = pts[1], pts[2], pts[1], pts[2]
    for k = 2, np do
        local x, y = pts[k * 2 - 1], pts[k * 2]
        if x < minx then minx = x elseif x > maxx then maxx = x end
        if y < miny then miny = y elseif y > maxy then maxy = y end
    end
    s.minx, s.miny, s.maxx, s.maxy = minx, miny, maxx, maxy
    local RD = Core.RoadDraw
    if np >= 2 then
        if RD and RD.buildLevels then
            s.levels = RD.buildLevels(pts, np, nil, nil, SK.TOL0)
        else
            local all = { tol = 0 }
            for i = 1, np do all[i] = i end
            s.levels = { all }
        end
    end
end

--------------------------------------------------------------------------------
-- 槽位與背景載入
--------------------------------------------------------------------------------
function SK.ensure(pn)
    if type(pn) ~= "number" or pn < 0 or pn > 3 or pn % 1 ~= 0 then return nil end
    local player = getSpecificPlayer(pn)
    local slot = SK.slots[pn]
    if slot and slot.player == player then return slot end
    if not player then
        SK.slots[pn] = nil
        SK.bump()
        return nil
    end
    -- 換角色（死亡重生）是同一個檔：已讀好（或讀到一半）的資料與還沒存的改動沿用，不重讀（重讀會蓋掉沒存的筆）；
    -- 收到的分享留著（同帳號，_SketchShare 會再同步）
    local path = SK.path(pn)
    local old = slot
    slot = { pn = pn, player = player, path = path, recv = old and old.recv or {}, recvN = old and old.recvN or 0 }
    SK.slots[pn] = slot
    if old and old.path == path and (old.store or old.load) then
        slot.store, slot.load, slot.error = old.store, old.load, old.error
        slot.dirty, slot.saveAt, slot.recvLoad = old.dirty, old.saveAt, old.recvLoad
    else
        slot.load = { paths = { path, RC().backupPath(path) }, k = 0 }
        SK.nextFile(slot)
    end
    SK.bump()
    return slot
end

-- 依序試主檔、備份：沒有主檔＝空清單；主檔較新＝只讀（不退回備份）；主檔壞或打不開才讀備份，
-- 備份也不行：任一個打不開或版本較新＝只讀（不知道裡面有什麼），兩個都壞＝空清單可覆寫
function SK.nextFile(slot)
    local L = slot.load
    while true do
        L.k = L.k + 1
        local path = L.paths[L.k]
        if not path then return SK.finishLoad(slot, nil, L.lockErr or L.firstErr) end
        local ok, lines, n = pcall(Codec.readFile, path)
        local err
        if not ok then
            err = "unreadable"
        elseif lines then
            local st, why = Codec.decodeBegin(lines, n)
            if st then
                L.st, L.prepI = st, 0
                return
            end
            err = why
        elseif n then
            err = n
        elseif L.k == 1 then
            return SK.finishLoad(slot, nil, nil) -- 沒有檔
        end
        if (err == "unreadable" or err == "unsupported") and not L.lockErr then L.lockErr = err end
        if L.k == 1 then
            L.firstErr = err
            if err == "unsupported" then return SK.finishLoad(slot, nil, err) end
        end
    end
end

function SK.finishLoad(slot, store, err)
    local L = slot.load
    slot.load = nil
    if err then
        SK.warn(slot.pn, "load", err)
    elseif L and L.k > 1 and store then
        SK.warn(slot.pn, "load", tostring(L.firstErr) .. ", read backup")
    end
    slot.error = not store and err or nil
    if not store then
        store = Codec.emptyStore()
        store.origin = RC().newOrigin()
    end
    slot.store = store
    SK.bump()
end

function SK.stepLoad(slot)
    local L = slot.load
    local t0 = getTimestampMs()
    repeat
        local st = L.st
        if st.done then
            local store = st.store
            local k = L.prepI + 1
            if k <= store.count then SK.prepare(store.strokes[k]) end
            L.prepI = k
            if k >= store.count then return SK.finishLoad(slot, store, nil) end
        else
            local done, err = Codec.decodeStep(st, 1)
            if done == nil then
                if L.k == 1 then L.firstErr = err end
                L.st = nil
                SK.nextFile(slot)
                if not (slot.load and slot.load.st) then return end
            elseif done then
                st.done = true
            end
        end
    until getTimestampMs() - t0 >= SK.LOAD_BUDGET_MS
end

-- 可以改：回 slot 或 nil, 原因（noplayer／loading／readonly）
function SK.writable(pn)
    local slot = SK.ensure(pn)
    if not slot or slot.player:isDead() then return nil, "noplayer" end
    if slot.load then return nil, "loading" end
    if slot.error == "unreadable" or slot.error == "unsupported" then return nil, "readonly" end
    return slot
end

--------------------------------------------------------------------------------
-- 改動（工具呼叫）：strokes 依 id 遞增，畫的順序＝陣列順序
--------------------------------------------------------------------------------
function SK.indexOf(store, id)
    for i = 1, store.count do if store.strokes[i].id == id then return i end end
    return nil
end
function SK.removeAt(store, i)
    local list, n = store.strokes, store.count
    store.points = store.points - list[i].np
    for k = i, n - 1 do list[k] = list[k + 1] end
    list[n] = nil
    store.count = n - 1
end

-- 拿掉 rem、加回 add（復原、重做、擦除、新增、清除全部都走這裡）。超過硬上限整批不做，回 nil, "full"。
-- 一次建 id 表、一趟壓縮、一趟合併（5,000 筆清除全部與復原不能逐筆線性找＋搬移）
function SK.apply(pn, rem, nr, add, na)
    local slot, why = SK.writable(pn)
    if not slot then return nil, why end
    local store = slot.store
    local list, n = store.strokes, store.count
    local have = {}
    for i = 1, n do have[list[i].id] = true end
    local drop, count, points = {}, n, store.points
    for k = 1, nr do
        local s = rem[k]
        if have[s.id] and not drop[s.id] then
            drop[s.id] = true
            count, points = count - 1, points - s.np
        end
    end
    -- 要加的：去掉拿掉後仍在的與重複的，照 id 排（由下而上的合併排序，O(n log n)、不遞迴：復原紀錄是照擦到的
    -- 順序累積的，反向拖過去再復原就是完全反序）
    local ins, ni, seen = {}, 0, {}
    for k = 1, na do
        local s = add[k]
        if not seen[s.id] and (drop[s.id] or not have[s.id]) then
            seen[s.id] = true
            ni = ni + 1
            ins[ni] = s
            count, points = count + 1, points + s.np
        end
    end
    ins = SK.sortById(ins, ni)
    if ni > 0 and (count > SK.HARD_STROKES or points > SK.HARD_POINTS) then return nil, "full" end
    if nr > 0 or ni > 0 then
        local out, m, j = {}, 0, 1
        for i = 1, n do
            local s = list[i]
            if not drop[s.id] then
                while j <= ni and ins[j].id < s.id do
                    m = m + 1
                    out[m] = ins[j]
                    j = j + 1
                end
                m = m + 1
                out[m] = s
            end
        end
        for k = j, ni do
            m = m + 1
            out[m] = ins[k]
        end
        store.strokes, store.count, store.points = out, m, points
    end
    SK.markDirty(slot)
    SK.bump()
    if Core.sketchShareChanged then Core.sketchShareChanged(pn, store.origin, rem, nr, add, na) end
    return true
end
-- 依 id 遞增排序（由下而上合併，Kahlua 沒有 table.sort）；回排好的新陣列
function SK.sortById(a, n)
    local w = 1
    local src, dst = a, {}
    while w < n do
        local i = 1
        while i <= n do
            local mid, hi = math.min(i + w, n + 1), math.min(i + 2 * w, n + 1)
            local l, r, k = i, mid, i
            while l < mid and r < hi do
                if src[l].id <= src[r].id then
                    dst[k] = src[l]
                    l = l + 1
                else
                    dst[k] = src[r]
                    r = r + 1
                end
                k = k + 1
            end
            while l < mid do dst[k] = src[l]; l = l + 1; k = k + 1 end
            while r < hi do dst[k] = src[r]; r = r + 1; k = k + 1 end
            i = i + 2 * w
        end
        src, dst = dst, src
        w = w * 2
    end
    return src
end
function SK.markDirty(slot)
    slot.dirty = true
    slot.saveAt = getTimestampMs() + SK.SAVE_DELAY_MS
end

-- 伺服器因上限拒收的筆改成私人（_SketchShare.lua skFail limit）
Core.sketchMakePrivate = function(pn, ids, n)
    local slot = SK.slots[pn]
    local store = slot and slot.store
    if not store then return end
    local want = {}
    for i = 1, n do want[ids[i]] = true end
    local changed = false
    for i = 1, store.count do
        local s = store.strokes[i]
        if want[s.id] and s.share then
            s.share = false
            s.line = Codec.strokeLine(s)
            changed = true
        end
    end
    if changed then SK.markDirty(slot) end
end

-- 量化到 1/4 格、去掉相鄰重複點；回 新陣列, 點數
function SK.clean(pts, np)
    local out, n, q = {}, 0, Codec.quantize
    for i = 1, np do
        local x, y = q(pts[i * 2 - 1]), q(pts[i * 2])
        if n == 0 or out[n * 2 - 1] ~= x or out[n * 2] ~= y then
            n = n + 1
            out[n * 2 - 1], out[n * 2] = x, y
        end
    end
    return out, n
end

-- 建一筆新的（還沒套用）：attrs＝{ c, w, z, share }，pts＝世界座標。畫的上限滿了回 nil, "full"
function SK.newStroke(pn, attrs, pts, np)
    local slot, why = SK.writable(pn)
    if not slot then return nil, why end
    local store = slot.store
    local cp, n = SK.clean(pts, np)
    if n < 1 then return nil, "empty" end
    if store.count + 1 > Codec.DRAW_STROKES or store.points + n > Codec.DRAW_POINTS then return nil, "full" end
    local s = { id = store.nextId, c = attrs.c, w = attrs.w, z = attrs.z, share = attrs.share == true, pts = cp, np = n }
    store.nextId = store.nextId + 1
    s.line = Codec.strokeLine(s)
    SK.prepare(s)
    return s
end

-- 線段 a→b 在圓（cx, cy, r）內的參數區間 [t0, t1]（夾在 0..1）；沒碰到回 nil
function SK.segCircle(ax, ay, bx, by, cx, cy, r)
    local dx, dy, fx, fy = bx - ax, by - ay, ax - cx, ay - cy
    local A = dx * dx + dy * dy
    local C = fx * fx + fy * fy - r * r
    if A < 1e-12 then
        if C <= 0 then return 0, 1 end
        return nil
    end
    local B = 2 * (fx * dx + fy * dy)
    local disc = B * B - 4 * A * C
    if disc < 0 then return nil end
    local sq = math.sqrt(disc)
    local t0, t1 = (-B - sq) / (2 * A), (-B + sq) / (2 * A)
    if t1 < 0 or t0 > 1 then return nil end
    return t0 < 0 and 0 or t0, t1 > 1 and 1 or t1
end

-- 一筆被圓擦過後剩下的片段（格座標陣列的陣列）；沒碰到回 nil。片段少於 2 個不同的點就丟掉
function SK.cutStroke(s, cx, cy, r)
    local pts, np = s.pts, s.np
    if s.maxx < cx - r or s.minx > cx + r or s.maxy < cy - r or s.miny > cy + r then return nil end
    if np == 1 then
        local dx, dy = pts[1] - cx, pts[2] - cy
        if dx * dx + dy * dy <= r * r then return {}, 0 end
        return nil
    end
    local pieces, nPieces, cur, hit = {}, 0, nil, false
    local function close()
        if cur then
            local cp, n = SK.clean(cur, #cur / 2)
            if n >= 2 then
                nPieces = nPieces + 1
                pieces[nPieces] = { pts = cp, np = n }
            end
        end
        cur = nil
    end
    local function push(x, y)
        cur[#cur + 1] = x
        cur[#cur + 1] = y
    end
    do
        local dx, dy = pts[1] - cx, pts[2] - cy
        if dx * dx + dy * dy > r * r then cur = { pts[1], pts[2] } else hit = true end
    end
    for i = 2, np do
        local ax, ay, bx, by = pts[i * 2 - 3], pts[i * 2 - 2], pts[i * 2 - 1], pts[i * 2]
        local t0, t1 = SK.segCircle(ax, ay, bx, by, cx, cy, r)
        if not t0 then
            if not cur then cur = { ax, ay } end
            push(bx, by)
        else
            hit = true
            if t0 > 0 and cur then
                push(ax + (bx - ax) * t0, ay + (by - ay) * t0)
            end
            close()
            if t1 < 1 then
                cur = { ax + (bx - ax) * t1, ay + (by - ay) * t1 }
                push(bx, by)
            end
        end
    end
    if not hit then return nil end
    close()
    return pieces, nPieces
end

-- 擦掉圓內的自己的線（收到的別人的線不擦）：回 被擦的筆陣列, 筆數, 剩下的片段（新筆）, 筆數（都還沒套用）
function SK.eraseAt(pn, cx, cy, r)
    local slot, why = SK.writable(pn)
    if not slot then return nil, why end
    local store = slot.store
    local rem, nr, add, na = {}, 0, {}, 0
    -- 分享名額：拿掉的分享筆先退回，片段照順序佔名額，超過的片段改成私人（原筆照樣撤回）
    local sn, sp
    for i = 1, store.count do
        local s = store.strokes[i]
        local pieces, n = SK.cutStroke(s, cx, cy, r)
        if pieces then
            nr = nr + 1
            rem[nr] = s
            if s.share and not sn then
                sn, sp = 0, 0
                if Core.sketchSharedTotals then sn, sp = Core.sketchSharedTotals(pn) end
            end
            if s.share then sn, sp = sn - 1, sp - s.np end
            for k = 1, n do
                local p = pieces[k]
                local share = s.share
                if share then
                    if sn + 1 <= Codec.SHARE_MAX_STROKES and sp + p.np <= Codec.SHARE_MAX_POINTS then
                        sn, sp = sn + 1, sp + p.np
                    else
                        share = false
                    end
                end
                local piece = { id = store.nextId, c = s.c, w = s.w, z = s.z, share = share, pts = p.pts, np = p.np }
                store.nextId = store.nextId + 1
                piece.line = Codec.strokeLine(piece)
                SK.prepare(piece)
                na = na + 1
                add[na] = piece
            end
        end
    end
    return rem, nr, add, na
end

--------------------------------------------------------------------------------
-- 寫檔
--------------------------------------------------------------------------------
function SK.save(slot)
    local ok, saved = pcall(function() return RC().writeSafe(slot.path, Codec.encodeStore(slot.store)) end)
    if ok and saved then
        slot.dirty, slot.saveAt = nil, nil
        return true
    end
    slot.saveAt = getTimestampMs() + SK.SAVE_RETRY_MS
    SK.warn(slot.pn, "save", ok and "read-back mismatch" or saved)
    SK.say(slot.pn, "UI_MinidoracatMiniMap_SketchSaveFailed")
    return false
end
Core.sketchFlush = function(pn)
    local slot = SK.slots[pn]
    if slot and slot.dirty and slot.store then return SK.save(slot) end
    return true
end
function SK.tick()
    local now
    for pn = 0, 3 do
        local slot = SK.slots[pn]
        if slot then
            if slot.load then SK.stepLoad(slot) end
            if slot.recvLoad then SK.stepRecv(slot) end
            if slot.dirty and slot.saveAt then
                now = now or getTimestampMs()
                if now >= slot.saveAt then SK.save(slot) end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 收到的分享（_SketchShare.lua 呼叫）：recv[作者][lid]＝筆。只在記憶體
--------------------------------------------------------------------------------
local function recvSlot(pn)
    local slot = SK.slots[pn] or SK.ensure(pn)
    return slot
end
-- 收到的筆：同作者、同 lid、屬性與座標字串都和手上的一樣就沿用已算好的外框與抽點層，否則重算
local function recvPrepare(old, s)
    if old and old.wp == s.wp and s.wp ~= nil and old.c == s.c and old.w == s.w and old.z == s.z then
        s.minx, s.miny, s.maxx, s.maxy, s.levels = old.minx, old.miny, old.maxx, old.maxy, old.levels
    else
        SK.prepare(s)
    end
    s.recv = true
end
local function recvPut(slot, s)
    local byLid = slot.recv[s.a]
    if not byLid then
        byLid = {}
        slot.recv[s.a] = byLid
    end
    local old = byLid[s.lid]
    if not old then slot.recvN = slot.recvN + 1 end
    recvPrepare(old, s)
    byLid[s.lid] = s
end
-- 收齊的快照：整批替換。分 tick 做（每 tick LOAD_BUDGET_MS，同讀檔）；做完才換上，做的期間舊的照畫，
-- 收到的即時事件先排著、換上後照順序套（陣營、安全屋一變全服都會重新對帳，上千筆不能一幀算完）
Core.sketchRecvReplace = function(pn, list, n)
    local slot = recvSlot(pn)
    if not slot then return end
    slot.recvLoad = { list = list, n = n, i = 0, recv = {}, recvN = 0, live = {} }
    SK.stepRecv(slot)
end
function SK.stepRecv(slot)
    local R = slot.recvLoad
    local t0 = getTimestampMs()
    local list, old = R.list, slot.recv
    repeat
        local k = R.i + 1
        if k <= R.n then
            local s = list[k]
            local byLid = R.recv[s.a]
            if not byLid then
                byLid = {}
                R.recv[s.a] = byLid
            end
            local ob = old[s.a]
            if not byLid[s.lid] then R.recvN = R.recvN + 1 end
            recvPrepare(ob and ob[s.lid], s)
            byLid[s.lid] = s
        end
        R.i = k
        if k >= R.n then
            slot.recvLoad = nil
            slot.recv, slot.recvN = R.recv, R.recvN
            for k = 1, #R.live do
                local ev = R.live[k]
                if ev.add then Core.sketchRecvAdd(slot.pn, ev.list, ev.n) else Core.sketchRecvDel(slot.pn, ev.a, ev.ids, ev.n) end
            end
            SK.bump()
            return
        end
    until getTimestampMs() - t0 >= SK.LOAD_BUDGET_MS
end
Core.sketchRecvAdd = function(pn, list, n)
    local slot = recvSlot(pn)
    if not slot then return end
    if slot.recvLoad then
        local live = slot.recvLoad.live
        live[#live + 1] = { add = true, list = list, n = n }
        return
    end
    for i = 1, n do recvPut(slot, list[i]) end
    SK.bump()
end
Core.sketchRecvDel = function(pn, author, lids, n)
    local slot = recvSlot(pn)
    if slot and slot.recvLoad then
        local live = slot.recvLoad.live
        live[#live + 1] = { a = author, ids = lids, n = n }
        return
    end
    local byLid = slot and slot.recv[author]
    if not byLid then return end
    for i = 1, n do
        if byLid[lids[i]] then
            byLid[lids[i]] = nil
            slot.recvN = slot.recvN - 1
        end
    end
    SK.bump()
end

--------------------------------------------------------------------------------
-- 繪製
--------------------------------------------------------------------------------
-- 一段畫成寬 2·hw 的四邊形，兩端各外推 hw（方頭：相鄰兩段在轉角疊住，不露縫）
function SK.seg(jo, x1, y1, x2, y2, hw, c, a)
    local dx, dy = x2 - x1, y2 - y1
    local L = math.sqrt(dx * dx + dy * dy)
    local ux, uy
    if L < 1e-6 then ux, uy = 1, 0 else ux, uy = dx / L, dy / L end
    local ex, ey, ox, oy = ux * hw, uy * hw, -uy * hw, ux * hw
    x1, y1, x2, y2 = x1 - ex, y1 - ey, x2 + ex, y2 + ey
    jo:DrawPolygon(nil, x1 + ox, y1 + oy, x2 + ox, y2 + oy, x2 - ox, y2 - oy, x1 - ox, y1 - oy, c.r, c.g, c.b, a)
end

-- 畫的寬度（px）：粗細 × 2^(目前縮放 − 畫的縮放)，夾在 1 與 2 倍之間
function SK.widthPx(s, zoom)
    local base = SK.WPX[s.w] or 4
    local px = base * 2 ^ (zoom - s.z)
    if px < 1 then return 1 end
    if px > base * 2 then return base * 2 end
    return px
end

-- 候選快取：每位玩家、每張地圖一份。視野還在外擴框內、整數縮放與資料版本沒變就沿用
local caches = {}
SK.caches = caches
function SK.candidates(slot, key, fr, zoom, hide, recv)
    local vx1, vx2, vy1, vy2 = fr.vMinX, fr.vMaxX, fr.vMinY, fr.vMaxY
    local zi = floor(zoom)
    local c = caches[key]
    if c and c.rev == SK.revision and c.slot == slot and c.zi == zi and c.hide == hide and c.recv == recv
        and vx1 >= c.x1 and vx2 <= c.x2 and vy1 >= c.y1 and vy2 <= c.y2 then
        return c
    end
    if not c then
        c = {}
        caches[key] = c
    end
    SK.rebuilds = (SK.rebuilds or 0) + 1
    local pw, ph = (vx2 - vx1) * SK.VIEW_PAD, (vy2 - vy1) * SK.VIEW_PAD
    local x1, x2, y1, y2 = vx1 - pw, vx2 + pw, vy1 - ph, vy2 + ph
    local maxZ = zi + 1 + hide -- 縮放 zoom 畫得出來的筆：zoom ≥ z − hide
    local n = 0
    local function consider(s)
        if s.z <= maxZ and not (s.maxx < x1 or s.minx > x2 or s.maxy < y1 or s.miny > y2) then
            n = n + 1
            c[n] = s
        end
    end
    if recv then
        for _, byLid in pairs(slot.recv) do
            for _, s in pairs(byLid) do consider(s) end
        end
    end
    local store = slot.store
    if store then
        for i = 1, store.count do consider(store.strokes[i]) end
    end
    for i = n + 1, c.n or 0 do c[i] = nil end
    c.n, c.rev, c.slot, c.zi, c.hide, c.recv, c.stamp = n, SK.revision, slot, zi, hide, recv, SK.rebuilds
    c.x1, c.x2, c.y1, c.y2 = x1, x2, y1, y2
    return c
end

local function pickLevel(lv, tol)
    local k = 1
    while k < #lv and lv[k + 1].tol <= tol do k = k + 1 end
    return k
end

-- 規劃結果存在候選快取的 c.P（每位玩家、每張地圖一份）：vis[i]＝筆、L[i]＝要畫的抽點層（小筆為 0）、
-- K[i]＝實際畫法（層；0＝畫成一點；-1＝不畫（這格已有一點、或超過預算）；-2＝超過預算只畫頭尾一段）、
-- W[i]＝寬 px、E[i]＝外框在畫面上的大小 px、X／Y＝點的世界座標。
-- 規劃涵蓋視野外擴 PLAN_PAD 的框（box）：候選、縮放（含 getWorldScale）、畫面大小沒變，視野還在框內就整份沿用，
-- 只平移（小地圖跟著玩家走、世界地圖拖曳）不用每幀重算；位置在畫的時候才投影。預算照框內全部算（偏保守）

-- 外框小於 g px 的筆畫成一點、同一個世界座標格（g px 換成格）只畫一點，其餘畫 L[i] 那一層；回 呼叫數, 點數
local function dotPass(P, s, g)
    local vis, K, L, E, X, Y = P.vis, P.K, P.L, P.E, P.X, P.Y
    SK.dotPasses = (SK.dotPasses or 0) + 1
    local gw = g / s
    local seen = {}
    local prims, dots = 0, 0
    for i = 1, P.nv do
        local st = vis[i]
        if E[i] < g then
            local x, y = (st.minx + st.maxx) / 2, (st.miny + st.maxy) / 2
            local key = floor(x / gw) * 4194304 + floor(y / gw)
            if seen[key] then
                K[i] = -1
            else
                seen[key] = true
                K[i], X[i], Y[i] = 0, x, y
                dots = dots + 1
            end
        else
            local k = L[i]
            K[i] = k
            prims = prims + #st.levels[k] - 1
        end
    end
    return prims + dots, dots
end

-- 最後保險：照畫的順序累加，放不下整筆的只畫頭尾一段（-2），連一段都放不下的不畫（-1）。
-- 格子放到最大（2×(寬+高) px）後「最粗層段數＋格點」仍超過預算才走到；預算照規劃框（含畫面外的外擴）算，
-- 框裡畫面外的筆也佔預算
local function capPass(P)
    local vis, K, BUDGET = P.vis, P.K, SK.BUDGET
    local total = 0
    for i = 1, P.nv do
        local k = K[i]
        if k ~= -1 then
            local cost = k == 0 and 1 or #vis[i].levels[k] - 1
            if total + cost <= BUDGET then
                total = total + cost
            elseif total + 1 <= BUDGET then
                K[i] = -2
                total = total + 1
            else
                K[i] = -1
            end
        end
    end
    return total
end

-- 規劃：剔除、選層、算呼叫數。超過 BUDGET 而各筆換到最粗放得下：整批一層一層換粗（不丟整筆）；
-- 最粗也放不下（可見的筆比預算多）：各筆直接用最粗那層，小筆合成格點，格子從上一幀的一半起找最小放得下的；
-- 只平移出框時直接用上一幀的格子（放不下才加倍）；格子放到最大仍放不下才 capPass。回 筆數, 呼叫數
function SK.plan(c, fr, zoom, hide, w, h)
    local P = c.P
    if not P then
        P = { vis = {}, L = {}, K = {}, W = {}, E = {}, X = {}, Y = {}, nv = 0, prims = 0 }
        c.P = P
    end
    -- 規劃只用到 scale（getWorldScale，縮放一變就變）與世界座標的框，不用投影係數：sxx 等是兩次 worldToUI（引擎 float32）
    -- 相減得來，小地圖跟著玩家走時中心是小數，捨入差可到 scale 的 2e-4，拿來比會每隔幾幀就重新規劃
    -- （2026-11-08 實機：走路 4 格／秒 8 秒重算 29–70 次、5,000 筆時那幀 30–35 ms）。等軸測與否不影響規劃內容
    -- （格點、外框大小都在世界座標），切換後視野出框才重算
    local same = P.stamp == c.stamp and P.zoom == zoom and P.hide == hide and P.w == w and P.h == h and P.s == fr.scale
    if same and fr.vMinX >= P.bx1 and fr.vMaxX <= P.bx2 and fr.vMinY >= P.by1 and fr.vMaxY <= P.by2 then
        return P.nv, P.prims
    end
    SK.planBuilds = (SK.planBuilds or 0) + 1
    -- 只平移出框（縮放、畫面大小、候選都沒變）：格子沿用上一幀的，不從頭找
    local panOnly = P.grid ~= nil and same
    P.stamp, P.zoom, P.hide, P.w, P.h, P.s = c.stamp, zoom, hide, w, h, fr.scale
    local s, TINY, BUDGET = fr.scale, SK.TINY_PX, SK.BUDGET
    local tol = 1 / s
    local pw, ph = (fr.vMaxX - fr.vMinX) * SK.PLAN_PAD, (fr.vMaxY - fr.vMinY) * SK.PLAN_PAD
    P.bx1, P.bx2, P.by1, P.by2 = fr.vMinX - pw, fr.vMaxX + pw, fr.vMinY - ph, fr.vMaxY + ph
    local m = 16 / s
    local vx1, vx2, vy1, vy2 = P.bx1 - m, P.bx2 + m, P.by1 - m, P.by2 + m
    local vis, L, W, E = P.vis, P.L, P.W, P.E
    -- 線寬只看粗細與畫的縮放：同一個縮放下每種組合算一次
    local wc = P.wc
    if P.wcZoom ~= zoom then
        wc = {}
        P.wc, P.wcZoom = wc, zoom
    end
    local nv, minSegs = 0, 0
    for i = 1, c.n do
        local st = c[i]
        if zoom >= st.z - hide and not (st.maxx < vx1 or st.minx > vx2 or st.maxy < vy1 or st.miny > vy2) then
            nv = nv + 1
            local wk = st.w * 64 + st.z
            local wpx = wc[wk]
            if not wpx then
                wpx = SK.widthPx(st, zoom)
                wc[wk] = wpx
            end
            vis[nv], W[nv] = st, wpx
            local e = st.np == 1 and 0 or (st.maxx - st.minx + st.maxy - st.miny) * s
            E[nv] = e
            if e >= TINY then
                local lv = st.levels
                L[nv] = pickLevel(lv, tol)
                minSegs = minSegs + #lv[#lv] - 1
            else
                L[nv] = 0
            end
        end
    end
    for i = nv + 1, P.nv do vis[i] = nil end
    P.nv = nv
    local prims, dots = dotPass(P, s, TINY)
    local grid = nil
    if prims > BUDGET and minSegs + dots <= BUDGET then
        while prims > BUDGET do
            local p, moved = dots, false
            for i = 1, nv do
                local k = L[i]
                if k > 0 then
                    local lv = vis[i].levels
                    if k < #lv then
                        k = k + 1
                        L[i] = k
                        moved = true
                    end
                    p = p + #lv[k] - 1
                end
            end
            prims = p
            if not moved then break end
        end
        prims = dotPass(P, s, TINY)
    elseif prims > BUDGET then
        for i = 1, nv do
            if L[i] > 0 then L[i] = #vis[i].levels end
        end
        local g, gMax = TINY * 2, 2 * (w + h)
        if panOnly then
            -- 平移：先用上一幀的格子；放不下才加倍。格子減半點數約變 4 倍，所以不到預算 1/8 才試小一號
            g = P.grid
            prims = dotPass(P, s, g)
            if prims * 8 < BUDGET and g > TINY * 2 then
                local p2 = dotPass(P, s, g / 2)
                if p2 <= BUDGET then g, prims = g / 2, p2 else prims = dotPass(P, s, g) end
            end
        else
            if P.grid and P.grid >= g * 2 then g = P.grid / 2 end
            prims = dotPass(P, s, g)
            if prims <= BUDGET then
                -- 起點就放得下：往小試到放不下為止（拉近時格子要變小）
                while g > TINY * 2 do
                    local p2 = dotPass(P, s, g / 2)
                    if p2 > BUDGET then
                        prims = dotPass(P, s, g)
                        break
                    end
                    g, prims = g / 2, p2
                end
            end
        end
        while prims > BUDGET and g < gMax do
            g = g * 2
            prims = dotPass(P, s, g)
        end
        grid = g
        if prims > BUDGET then prims = capPass(P) end
    end
    P.prims, P.grid = prims, grid
    return nv, prims
end

function SK.drawPlanned(jo, fr, P, w, h)
    local acx, acy, p0x, p0y = fr.acx, fr.acy, fr.p0x, fr.p0y
    local sxx, sxy, syx, syy = fr.sxx, fr.sxy, fr.syx, fr.syy
    local COLORS, seg = SK.COLORS, SK.seg
    local vis, K, W, X, Y = P.vis, P.K, P.W, P.X, P.Y
    for i = 1, P.nv do
        local k = K[i]
        if k ~= -1 then
            local st, hw = vis[i], W[i] / 2
            local col = COLORS[st.c] or COLORS[1]
            if k == 0 then
                local dx, dy = X[i] - acx, Y[i] - acy
                local x, y = p0x + dx * sxx + dy * syx, p0y + dx * sxy + dy * syy
                if x > -hw and y > -hw and x < w + hw and y < h + hw then
                    seg(jo, x - hw, y, x + hw, y, hw, col, 1)
                end
            else
                local lv, pts = st.levels[k < 0 and #st.levels or k], st.pts
                local m = #lv
                local i0 = lv[1]
                local dx, dy = pts[i0 * 2 - 1] - acx, pts[i0 * 2] - acy
                local lx, ly = p0x + dx * sxx + dy * syx, p0y + dx * sxy + dy * syy
                for j = k < 0 and m or 2, m do
                    local q = lv[j]
                    dx, dy = pts[q * 2 - 1] - acx, pts[q * 2] - acy
                    local x, y = p0x + dx * sxx + dy * syx, p0y + dx * sxy + dy * syy
                    if not ((lx < -hw and x < -hw) or (lx > w + hw and x > w + hw)
                        or (ly < -hw and y < -hw) or (ly > h + hw and y > h + hw)) then
                        seg(jo, lx, ly, x, y, hw, col, 1)
                    end
                    lx, ly = x, y
                end
            end
        end
    end
end

-- 主入口：inner＝小地圖 inner 或 ISWorldMap。分割畫面只畫該 pn 的。手繪工具作用中的那張世界地圖：
-- 「顯示在」那格關著也畫（要看得到才畫得準、擦得到）
Core.drawSketch = function(inner)
    local pn = inner.playerNum or 0
    local slot = SK.slots[pn]
    if not slot then return end
    local world = inner == ISWorldMap_instance
    local tool = world and Core.sketchToolOf and Core.sketchToolOf(inner)
    if not tool and not Core.layerOn("sketch", world and "world" or "mini") then return end
    local recv = Core.getBoolOption("SketchReceived", true) == true
    local own = slot.store and slot.store.count or 0
    if own == 0 and not (recv and slot.recvN > 0) then return end
    local fr = Core.zoneFrame(inner)
    if not (fr.scale and fr.scale > 0) then return end
    local zoom = inner.mapAPI:getZoomF()
    local hide = Core.getSliderValue("SketchHideZoom", 3, 1, 6)
    local c = SK.candidates(slot, pn * 2 + (world and 1 or 0), fr, zoom, hide, recv)
    if c.n == 0 then return end
    local w, h = inner.width, inner.height
    local nv = SK.plan(c, fr, zoom, hide, w, h)
    if nv == 0 then return end
    inner:setStencilRect(0, 0, w, h)
    local ok, err = pcall(SK.drawPlanned, inner.javaObject, fr, c.P, w, h)
    inner:clearStencilRect()
    if not ok then error(err, 0) end
end

-- 換角色時先開始讀檔；換世界全部重置（同 _Roads.lua）
Events.OnCreatePlayer.Add(function(pn) SK.ensure(pn) end)
Events.OnGameStart.Add(function()
    for pn = 0, 3 do SK.slots[pn] = nil end
    for key in pairs(SK.warned) do SK.warned[key] = nil end
    for key in pairs(caches) do caches[key] = nil end
    for pn = 0, 3 do if getSpecificPlayer(pn) then SK.ensure(pn) end end
    SK.bump()
end)
Events.OnTickEvenPaused.Add(SK.tick)
