-- 資源點「去過／已清空」客戶端：資料格式、帳號檔、去過判定、容器掃描（預算、排除、整棟載入）、翻過、自動門檻、
-- 再走進去比對（B1）、單機 B2、手動標記、提示與圖標代碼。用真的 ClearedCodec、RoadCodec（記憶體假檔案系統）。
-- 用法：lua scripts/test_cleared.lua
local LUA = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/"

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
local function eq(a, b, label) check(a == b, label .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

-- 假 Java ------------------------------------------------------------------------------
local function jlist(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end
local files, unreadable = {}, {}
function cacheFileExists(path) return files[path] ~= nil end
function getFileReader(path)
    if unreadable[path] or files[path] == nil then return nil end
    local lines, i = {}, 0
    for line in (files[path] .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if files[path] == "" then lines = {} end
    return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
end
function getFileWriter(path)
    files[path] = ""
    return { write = function(_, text) files[path] = files[path] .. text end, close = function() end }
end

local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = {
        Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end,
        Remove = function(fn)
            local list = handlers[name] or {}
            for i = #list, 1, -1 do if list[i] == fn then table.remove(list, i) end end
        end,
    }
    rawset(t, name, e)
    return e
end })
local function fire(name, ...)
    local list = {}
    for i, fn in ipairs(handlers[name] or {}) do list[i] = fn end
    for _, fn in ipairs(list) do fn(...) end
end
local function hooked(name) return handlers[name] ~= nil and #handlers[name] > 0 end

local nowMs = 1000
function getTimestampMs() return nowMs end
local hours = 100
function getGameTime() return { getWorldAgeHours = function() return hours end } end
function getWorld() return { getGameMode = function() return "Sandbox" end, getWorld = function() return "w1" end } end
local client = false
function isClient() return client end
function isServer() return false end
-- Java 繼承：角色、載具、屍體都是 IsoMovingObject（BaseVehicle.java:182、IsoDeadBody.java:132）
local MOVING = { IsoPlayer = true, BaseVehicle = true, IsoDeadBody = true }
function instanceof(o, cls) return o._cls == cls or (cls == "IsoMovingObject" and MOVING[o._cls] == true) end
function getText(key, ...)
    local args = { ... }
    if #args == 0 then return key end
    return key .. "(" .. table.concat(args, "|") .. ")"
end
function getTexture() return { tex = true } end
function ZombRand() return 0 end

-- 世界：格子、物件、容器、房間、建築
local function container(ctype, items, looted)
    local list = {}
    for i = 1, items do list[i] = i end
    return { items = list, getType = function() return ctype end, getItems = function() return jlist(list) end,
        isHasBeenLooted = function() return looted end }
end
local loadedChunks = {}
local function loadChunks(x, y, w, h, on)
    for cx = math.floor(x / 8), math.floor((x + w - 1) / 8) do
        for cy = math.floor(y / 8), math.floor((y + h - 1) / 8) do loadedChunks[cx .. "," .. cy] = on end
    end
end
local squares = {}
local scanned = 0
local msPerSquare = 0
local function square(x, y, z, def)
    local sq = { objs = {} }
    sq.getX = function() return x end
    sq.getY = function() return y end
    sq.getZ = function() return z end
    sq.getBuildingDef = function() return def end
    sq.getObjects = function()
        scanned = scanned + 1
        nowMs = nowMs + msPerSquare
        return jlist(sq.objs)
    end
    squares[x .. "," .. y .. "," .. z] = sq
    return sq
end
local function object(sq, cls, conts)
    local o = { _cls = cls, conts = conts or {} }
    o.getContainerCount = function() return #o.conts end
    o.getContainerByIndex = function(_, i) return o.conts[i + 1] end
    o.getSquare = function() return sq end
    for _, c in ipairs(o.conts) do c.getParent = function() return o end end
    sq.objs[#sq.objs + 1] = o
    return o
end
local defId = 0
local function building(x, y, w, h)
    defId = defId + 1
    local def = { id = defId, rooms = {}, x = x, y = y, w = w, h = h }
    def.getID = function() return def.id end
    def.getX = function() return x end
    def.getY = function() return y end
    def.getW = function() return w end
    def.getH = function() return h end
    def.getRooms = function() return jlist(def.rooms) end
    return def
end
local function room(def, sqs, missing)
    local iso = { getSquares = function() return jlist(sqs) end }
    local rd = { getIsoRoom = function() return not missing and iso or nil end }
    def.rooms[#def.rooms + 1] = rd
    return rd
end
function getCell()
    return {
        getChunk = function(_, cx, cy) return loadedChunks[cx .. "," .. cy] and {} or nil end,
        getGridSquare = function(_, x, y, z) return squares[x .. "," .. y .. "," .. z] end,
    }
end

local players = {}
local function makePlayer(pn, name)
    local p = { def = nil, dead = false }
    p.getCurrentBuildingDef = function() return p.def end
    p.isDead = function() return p.dead end
    p.getUsername = function() return name end
    p.getOnlineID = function() return 1 end
    p.getPlayerNum = function() return pn end
    players[pn] = p
    return p
end
function getSpecificPlayer(pn) return players[pn] end

-- 資源點判定：只有 poiDefs 裡的建築算
local poiDefs = {}
MinidoracatMiniMapResourceAPI = { buildingCategories = function(def)
    return poiDefs[def.id] and { pharmacy = true } or nil
end }
MinidoracatMiniMapPOICategories = { ORDER = { "pharmacy" }, CATEGORIES = { pharmacy = { nameKey = "Cat_pharmacy" } } }

local opts = { ClearedAuto = true, ClearedAutoPct = 90 }
MinidoracatMiniMapCore = {
    ready = true,
    getBoolOption = function(id, d) if opts[id] == nil then return d end return opts[id] end,
    getSliderValue = function(id, d) return opts[id] or d end,
    mapSubMenu = function(context, _, title)
        local sub = { title = title, options = {} }
        sub.addOption = function(self, text, target, fn, ...)
            local o = { text = text, target = target, fn = fn, args = { ... } }
            self.options[#self.options + 1] = o
            return o
        end
        context.subs = context.subs or {}
        context.subs[#context.subs + 1] = sub
        return sub
    end,
}
local Core = MinidoracatMiniMapCore

dofile(LUA .. "shared/MinidoracatMiniMap_ClearedCodec.lua")
dofile(LUA .. "shared/MinidoracatMiniMap_RoadCodec.lua")
dofile(LUA .. "client/MinidoracatMiniMap_Cleared.lua")
dofile(LUA .. "client/MinidoracatMiniMap_ClearedUI.lua")
local C = MinidoracatMiniMapClearedCodec
local CL = Core.Cleared
check(CL ~= nil and Core.clearedTip ~= nil, "模組載入")

local function ticks(n)
    for _ = 1, n do
        fire("OnTick")
        fire("OnTickEvenPaused")
    end
end
local PATH0 = "MinidoracatMiniMap/cleared/Sandbox/w1_p0.txt"

-- C 資料格式 ----------------------------------------------------------------------------
do
    local m = C.newMark(100, 200, 10, 12)
    m.vh, m.ch, m.cs, m.n, m.s, m.l, m.i, m.oh, m.rh = 12.5, 30.25, "a", 14, 13, 2, 41, 31, 0
    local back = C.fromWire(C.toWire(m))
    check(back and back.x == 100 and back.ch == 30.25 and back.cs == "a" and back.n == 14 and back.i == 41, "C1 wire 來回")
    check(C.fromWire("1,2,3") == nil and C.fromWire("1,2,0,4,0,0,-,0,0,0,0,0,0,0,0") == nil, "C2 wire 欄數或邊長不合拒收")
    check(C.fromWire("1,2,3,4,0,5,-,0,0,0,0,0,0,0,0") == nil, "C3 清空時數與方式不一致拒收")
    local a, b = { x = 0, y = 0, w = 20, h = 20 }, { x = 2, y = 3, w = 18, h = 16 }
    check(C.same(a, b) and C.same(b, a), "C4 地上／地下兩筆外框互相包含中心＝同一棟")
    check(not C.same(a, { x = 15, y = 0, w = 20, h = 20 }), "C5 相鄰建築不算同一棟")
    local st = C.emptyStore()
    st.refreshSeq = 3
    st.origin = "abcd1234"
    m.keys, m.kn, m.ch, m.cs, m.u = { ["0,3,0,counter"] = true, ["2,7,0,fridge"] = true }, 2, 0, "-", true
    st.count, st.marks[1] = 1, m
    local text = C.encodeClient(st)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local back2 = C.decodeClient(lines, #lines)
    check(back2 and back2.refreshSeq == 3 and back2.count == 1 and back2.marks[1].kn == 2
        and back2.marks[1].keys["2,7,0,fridge"] and back2.marks[1].u == true, "C6 客戶端檔來回（含翻過的容器與待上傳）")
    lines[#lines] = "END\t2"
    local bad, why = C.decodeClient(lines, #lines)
    check(bad == nil and why == "invalid", "C7 END 筆數不符整份拒收")
    lines[#lines] = "END\t1"
    lines[1] = "MMCLEARED\t2\t0"
    bad, why = C.decodeClient(lines, #lines)
    check(bad == nil and why == "unsupported", "C8 版本較新＝unsupported")
    local hex = C.hex("a:b*c")
    check(#hex == 20 and C.unhex(hex) == "a:b*c", "C9 帳號十六進位無損")
    local keys, kn = C.chunkKeys({ x = 6, y = 8, w = 4, h = 1 })
    check(kn == 2 and keys[1] == "0,1" and keys[2] == "1,1", "C10 外框蓋到的 chunk")
    -- B1：外框邊長上限 512（香草最大 273）；chunk 數 O(1) 算，和展開的一樣
    check(C.fromWire("1,2,513,4,0,0,-,0,0,0,0,0,0,0,0") == nil and C.fromWire("1,2,512,4,0,0,-,0,0,0,0,0,0,0,0") ~= nil,
        "C11 外框邊長超過 512 拒收")
    local _, ekn = C.chunkKeys({ x = 15325, y = 2842, w = 273, h = 156 })
    check(C.chunkCost({ x = 15325, y = 2842, w = 273, h = 156 }) == ekn and ekn == 700, "C12 chunk 數 O(1)（香草最大 700）")
    -- B2：合併的另一個外框在左上方＝負的相對座標；寫得出去就要讀得回來
    local neg = C.newMark(100, 100, 10, 10)
    neg.vh, neg.s = 5, 1
    neg.keys, neg.kn = { [C.containerKey(neg, 97, 95, -1, "crate")] = true }, 1
    local st2 = C.emptyStore()
    st2.origin = "abcd1234"
    st2.count, st2.marks[1] = 1, neg
    local l2 = {}
    for line in (C.encodeClient(st2) .. "\n"):gmatch("([^\n]*)\n") do l2[#l2 + 1] = line end
    local back3 = C.decodeClient(l2, #l2)
    check(back3 and back3.marks[1].keys["-3,-5,-1,crate"], "C13 負的容器鍵寫入後讀得回來")
    -- N10：超過上限的數字寫出去前夾住，整份讀得回來
    local huge = C.newMark(0, 0, 4, 4)
    huge.vh, huge.n, huge.s, huge.l, huge.i = 1, C.MAX_COUNT + 5, 3, C.MAX_COUNT + 1, C.MAX_COUNT * 2
    local st3 = C.emptyStore()
    st3.origin = "abcd1234"
    st3.count, st3.marks[1] = 1, huge
    local l3 = {}
    for line in (C.encodeClient(st3) .. "\n"):gmatch("([^\n]*)\n") do l3[#l3 + 1] = line end
    local back4 = C.decodeClient(l3, #l3)
    check(back4 and back4.marks[1].n == C.MAX_COUNT and C.fromWire(C.toWire(huge)) ~= nil, "C14 超過上限的數寫檔後讀得回來")
    -- I11／N2：摘要含清空時數與方式（兩位小數正規化）、不含 l、i、oh
    local d1 = C.newMark(0, 0, 4, 4)
    d1.vh, d1.ch, d1.cs, d1.n, d1.s = 10, 20.004, "a", 5, 5
    local d2 = C.fromWire(C.toWire(d1))
    check(C.digest(d1) == C.digest(d2), "C15 線上格式來回摘要一樣")
    d2.ch = 20.5
    check(C.digest(d1) ~= C.digest(d2), "C16 只差清空時數：摘要不同")
    d2.ch, d2.cs = d1.ch, "m"
    check(C.digest(d1) ~= C.digest(d2), "C17 只差清空方式：摘要不同")
    d2.cs, d2.l, d2.i, d2.oh = "a", 7, 99, 123
    check(C.digest(d1) == C.digest(d2), "C18 l、i、oh 不進摘要（出門掃描不觸發重傳）")
    -- 拿過（t，2026-11-08 使用者裁定）：新欄位寫出後讀回一致、進摘要；上傳條件；刷新歸零；舊格式拒收
    d2.t = 1
    check(C.digest(d1) ~= C.digest(d2), "CT1 只差拿過：摘要不同（拿了東西一定上傳）")
    local tw = C.fromWire(C.toWire(d2))
    check(tw and tw.t == 1 and C.digest(tw) == C.digest(d2) and C.fromWire(C.toWire(d1)).t == 0, "CT2 wire 來回保留拿過")
    check(C.fromWire("1,2,3,4,0,0,-,0,0,0,0,0,0,0,2") == nil and C.fromWire("1,2,3,4,0,0,-,0,0,0,0,0,0,0,") == nil,
        "CT3 拿過只收 0／1")
    check(C.fromWire("1,2,3,4,0,0,-,0,0,0,0,0,0,0") == nil, "CT4 舊格式（14 欄，沒有拿過）拒收")
    local r = C.newMark(0, 0, 4, 4)
    r.vh, r.s, r.n = 1, 3, 5
    check(not C.relevant(r) and C.progress(r), "CT5 只翻過沒拿：不上傳，本機仍算有進度")
    r.t = 1
    check(C.relevant(r), "CT6 翻過而且拿過：上傳")
    r.s = 0
    check(not C.relevant(r), "CT7 拿過但沒有翻過進度：不上傳")
    r.t, r.ch, r.cs = 0, 5, "m"
    check(C.relevant(r), "CT8 已清空不論拿沒拿都上傳")
    r.ch, r.cs, r.s, r.t = 0, "-", 2, 1
    C.refresh(r, 7)
    check(r.t == 0 and r.rh == 7 and C.relevant(r), "CT9 刷新：拿過歸零（已刷新照樣上傳）")
    local tst = C.emptyStore()
    tst.origin = "abcd1234"
    local tm = C.newMark(50, 50, 8, 8)
    tm.vh, tm.s, tm.n, tm.t = 3, 1, 4, 1
    tst.count, tst.marks[1] = 1, tm
    local tl = {}
    for line in (C.encodeClient(tst) .. "\n"):gmatch("([^\n]*)\n") do tl[#tl + 1] = line end
    local tb = C.decodeClient(tl, #tl)
    check(tb and tb.marks[1].t == 1, "CT10 帳號檔來回保留拿過")
    -- 舊開發版（B 行少拿過那一欄）：照 invalid 規則整份拒收，不猜
    tl[2] = tl[2]:gsub("\t1\t0$", "\t0")
    local old, owhy = C.decodeClient(tl, #tl)
    check(old == nil and owhy == "invalid", "CT11 舊格式帳號檔（少拿過欄）＝invalid")
end

-- B2-L 讀檔進遊戲：玩家周圍的新 chunk 在帳號檔讀進來前就載完，slot 建立時補套（2026-11-08 E2E）；
-- 分割畫面晚加入的玩家也補套（I12）-----------------------------------------------------------------------
local p0 = makePlayer(0, "alice")
do
    local PATH1 = "MinidoracatMiniMap/cleared/Sandbox/w1_p1.txt"
    local st, m = C.emptyStore(), C.newMark(4000, 4000, 8, 8)
    st.origin = "abcd1234"
    m.vh, m.ch, m.cs = 50, 60, "m"
    st.marks[1], st.count = m, 1
    files[PATH0], files[PATH1] = C.encodeClient(st), C.encodeClient(st)
    fire("LoadChunk", { isNewChunk = function() return true end,
        getGridSquare = function(_, cx) return { getX = function() return 4000 + cx end, getY = function() return 4000 end } end })
    fire("OnGameStart")
    check(CL.slots[0] == nil and CL.newN == 1, "B2-L1 帳號檔還沒讀：先記下")
    ticks(30)
    local got = CL.find(CL.slots[0], m)
    check(got and got.ch == 0 and got.rh == hours, "B2-L2 第一次 tick 讀檔後補套＝已刷新")
    makePlayer(1, "p1")
    ticks(30)
    local got1 = CL.slots[1] and CL.find(CL.slots[1], m)
    check(got1 and got1.ch == 0 and got1.rh == hours, "B2-L3 分割畫面晚加入的玩家：slot 建立時也補套")
    check(CL.slots[0].store.origin == "abcd1234", "B2-L4 讀回來的來源碼照用")
    players[1] = nil
    files[PATH0], files[MinidoracatMiniMapRoadCodec.backupPath(PATH0)] = nil, nil
    files[PATH1], files[MinidoracatMiniMapRoadCodec.backupPath(PATH1)] = nil, nil
    CL.newChunks, CL.newN = {}, 0
    fire("OnGameStart")
    ticks(30)
    check(CL.slots[0] and C.validOrigin(CL.slots[0].store.origin), "B2-L5 新檔建立時配來源碼")
    local noOrigin = C.encodeClient({ refreshSeq = 0, count = 0, marks = {} })
    local nl = {}
    for line in (noOrigin .. "\n"):gmatch("([^\n]*)\n") do nl[#nl + 1] = line end
    check(C.decodeClient(nl, #nl) == nil, "B2-L6 沒有來源碼的檔頭不收（從未發布的舊格式，乾淨切換）")
end

-- V 去過 -------------------------------------------------------------------------------
local pharm = building(64, 64, 16, 16)
poiDefs[pharm.id] = true
local house = building(200, 200, 8, 8)
local sqs = {}
for x = 64, 79 do
    for y = 64, 79 do sqs[#sqs + 1] = square(x, y, 0, pharm) end
end
local counter = container("counter", 3, false)
local fridge = container("fridge", 0, true)
object(sqs[1], "IsoObject", { counter })
object(sqs[20], "IsoObject", { fridge })
for k = 1, 8 do object(sqs[40 + k], "IsoObject", { container("crate" .. k, 1, false) }) end
object(sqs[60], "IsoDeadBody", { container("corpse", 5, false) })
object(sqs[61], "IsoThumpable", { container("crate", 2, false) })
object(sqs[62], "IsoCompost", { container("composter", 2, false) })
room(pharm, sqs)
loadChunks(64, 64, 16, 16, true)
do
    local rev0 = Core.clearedRevision()
    p0.def = house
    ticks(30)
    eq(CL.slots[0].store.count, 0, "V1 一般房子不記去過")
    p0.def = pharm
    ticks(30)
    local st = CL.slots[0].store
    eq(st.count, 1, "V2 走進資源點建築記一筆")
    check(st.marks[1].vh == hours and st.marks[1].x == 64, "V3 去過時數與外框")
    check(Core.clearedRevision() > rev0, "V4 新去過一棟會遞增 revision")
    ticks(5)
    local m = st.marks[1]
    eq(m.n, 10, "S1 容器數排除屍體、玩家蓋的箱子、堆肥箱")
    eq(m.l, 1, "S2 被拿過的容器數")
    eq(m.i, 3 + 0 + 8, "S3 物品總數")
    check(not hooked("OnTickEvenPaused"), "S4 沒有工作就拆掉 OnTickEvenPaused")
end

-- T 翻過與自動已清空 -------------------------------------------------------------------
local function page(conts)
    local bp = {}
    for i, c in ipairs(conts) do bp[i] = { inventory = c } end
    return { player = 0, onCharacter = false, backpacks = bp }
end
local outside = container("counter", 1, false)
local outSq = square(300, 300, 0, house)
object(outSq, "IsoObject", { outside })
do
    local m = CL.slots[0].store.marks[1]
    local rev0 = Core.clearedRevision()
    fire("OnRefreshInventoryWindowContainers", page({ counter, fridge, outside }), "begin")
    eq(m.s, 0, "T1 只讀 end 階段")
    fire("OnRefreshInventoryWindowContainers", page({ counter, fridge, outside }), "end")
    eq(m.s, 2, "T2 搜刮視窗的容器在這棟才算翻過")
    fire("OnRefreshInventoryWindowContainers", page({ counter }), "end")
    eq(m.s, 2, "T3 同一個容器不重複算")
    local onChar = page({ counter })
    onChar.onCharacter = true
    fire("OnRefreshInventoryWindowContainers", onChar, "end")
    eq(m.s, 2, "T4 自己身上的背包頁不算")
    eq(Core.clearedRevision(), rev0 + 1, "T5 進度不觸發重建（只有第一次有進度那一次）")
    local list = {}
    for k = 1, 6 do list[k] = sqs[40 + k].objs[1].conts[1] end
    fire("OnRefreshInventoryWindowContainers", page(list), "end")
    eq(m.s, 8, "T6 翻到 8/10")
    eq(m.ch, 0, "T7 未達 90% 不自動清空")
    fire("OnRefreshInventoryWindowContainers", page({ sqs[47].objs[1].conts[1] }), "end")
    check(m.ch == hours and m.cs == "a" and m.keys == nil, "T8 達 90% 自動清空、丟掉容器清單")
end

-- F 帳號檔 -----------------------------------------------------------------------------
do
    nowMs = nowMs + 5000
    ticks(30)
    check(files[PATH0] ~= nil and files[PATH0]:find("^MMCLEARED\t1\t0") ~= nil, "F1 延遲寫檔")
    check(files[MinidoracatMiniMapRoadCodec.backupPath(PATH0)] ~= nil, "F2 先寫備份")
    CL.slots[0] = nil
    local s = CL.slot(0)
    check(s.store.count == 1 and s.store.marks[1].ch == hours and s.store.marks[1].n == 10, "F3 重新讀回")
    files[PATH0] = "MMCLEARED\t1\t0\nB\tbroken\nEND\t1"
    CL.slots[0] = nil
    s = CL.slot(0)
    check(s.store.count == 1 and not s.readOnly, "F4 主檔壞了讀備份")
    unreadable[PATH0] = true
    local bak = files[MinidoracatMiniMapRoadCodec.backupPath(PATH0)]
    files[MinidoracatMiniMapRoadCodec.backupPath(PATH0)] = nil
    CL.slots[0] = nil
    s = CL.slot(0)
    check(s.readOnly, "F5 檔在卻打不開、也沒有備份＝只讀")
    files[MinidoracatMiniMapRoadCodec.backupPath(PATH0)] = bak
    s.dirtyAt = 0
    local before = files[PATH0]
    CL.save(s)
    eq(files[PATH0], before, "F6 只讀不覆寫")
    unreadable[PATH0] = nil
    local keep, keepBak = files[PATH0], files[MinidoracatMiniMapRoadCodec.backupPath(PATH0)]
    files[PATH0] = "MMCLEARED\t9\t0\nEND\t0"
    CL.slots[0] = nil
    s = CL.slot(0)
    check(s.readOnly and s.store.count == 0, "F7 版本較新＝只讀（不退回備份、不降級抹資料）")
    files[PATH0], files[MinidoracatMiniMapRoadCodec.backupPath(PATH0)] = "junk", "MMCLEARED\t9\t0\nEND\t0"
    CL.slots[0] = nil
    s = CL.slot(0)
    check(s.readOnly, "F8 主檔壞、備份是較新版本＝只讀（不連備份一起覆寫）")
    files[PATH0], files[MinidoracatMiniMapRoadCodec.backupPath(PATH0)] = keep, keepBak
    CL.slots[0] = nil
    s = CL.slot(0)
    local realWrite = MinidoracatMiniMapRoadCodec.writeSafe
    MinidoracatMiniMapRoadCodec.writeSafe = function() return false end
    CL.save(s)
    MinidoracatMiniMapRoadCodec.writeSafe = realWrite
    check(s.dirtyAt ~= nil, "F9 寫檔失敗留著下次再寫")
    s.dirtyAt = nil
    -- I4：第一次存檔中斷（備份寫了、主檔還沒有）＝讀備份、可寫
    local Codec = MinidoracatMiniMapRoadCodec
    keep, keepBak = files[PATH0], files[Codec.backupPath(PATH0)]
    files[PATH0] = nil
    CL.slots[0] = nil
    s = CL.slot(0)
    check(s.store.count == 1 and not s.readOnly, "F10 主檔不存在、備份在＝讀備份、可寫")
    -- I5：主檔打不開、備份讀得到＝畫面用備份，但只讀（不拿備份覆寫內容不明的主檔）
    files[PATH0] = keep
    unreadable[PATH0] = true
    CL.slots[0] = nil
    s = CL.slot(0)
    check(s.store.count == 1 and s.readOnly, "F11 主檔打不開、備份讀得到＝只讀")
    unreadable[PATH0] = nil
    files[PATH0], files[Codec.backupPath(PATH0)] = keep, keepBak
    CL.slots[0] = nil
    s = CL.slot(0)
    p0.def = pharm
    CL.slots[0].lastDefId = pharm.id
    CL.slots[0].lastDef = pharm
    CL.slots[0].cur = CL.slots[0].store.marks[1]
end

-- B1 再走進去比對 ------------------------------------------------------------------------
local function rescanEnter()
    local s = CL.slots[0]
    CL.queue(0, s, s.cur, pharm, "enter")
    ticks(3)
end
do
    local m = CL.slots[0].store.marks[1]
    m.l, m.i = 5, 20 -- 上次出門時：5 個被拿過、20 件物品（這次 1 個、11 件）
    rescanEnter()
    check(m.ch > 0, "B1-1 被拿過的變少但物品也變少（搬走家具）不算刷新")
    m.l, m.i = 0, 30
    rescanEnter()
    check(m.ch > 0, "B1-2 被拿過的變多、物品變少（自己拿東西）不算刷新")
    m.l, m.i = 5, 2
    rescanEnter()
    check(m.ch == 0 and m.s == 0 and m.rh == hours and CL.code(0, m) == 4,
        "B1-3 被拿過的變少而且物品變多＝補過貨，標已刷新（同 B2、B3）")
end

-- S5 預算：4 萬格分好幾個 tick 掃完，每個 tick 不超過預算 ----------------------------------
do
    local mall = building(1000, 1000, 200, 200)
    poiDefs[mall.id] = true
    local big = {}
    for x = 1000, 1199 do
        for y = 1000, 1199 do big[#big + 1] = square(x, y, 0, mall) end
    end
    room(mall, big)
    loadChunks(1000, 1000, 200, 200, true)
    msPerSquare = 0.01
    p0.def = mall
    ticks(30)
    local tickCount, maxPerTick = 0, 0
    local s = CL.slots[0]
    while hooked("OnTickEvenPaused") and tickCount < 1000 do
        local before = scanned
        fire("OnTickEvenPaused")
        tickCount = tickCount + 1
        if scanned - before > maxPerTick then maxPerTick = scanned - before end
    end
    check(tickCount > 50, "S5 4 萬格分成多個 tick（" .. tickCount .. "）")
    check(maxPerTick <= CL.SCAN_BUDGET_MS / msPerSquare + CL.CHECK_EVERY, "S6 每 tick 不超過預算（" .. maxPerTick .. " 格）")
    eq(s.cur.n, 0, "S7 沒有容器的商場 n＝0")
    msPerSquare = 0
end

-- S8 整棟沒載入：不更新容器數、不自動清空、之後補掃 ---------------------------------------------
do
    local shop = building(400, 400, 16, 16)
    poiDefs[shop.id] = true
    local ss = {}
    for x = 400, 415 do ss[#ss + 1] = square(x, 400, 0, shop) end
    local c1 = container("shelf", 1, false)
    object(ss[1], "IsoObject", { c1 })
    room(shop, ss)
    loadChunks(400, 400, 16, 16, true)
    loadChunks(408, 408, 8, 8, false)
    p0.def = shop
    ticks(33)
    local s = CL.slots[0]
    local m = s.cur
    eq(m.n, 0, "S8 有 chunk 沒載入時不記容器總數")
    check(s.rescanAt ~= nil, "S9 排定之後補掃")
    fire("OnRefreshInventoryWindowContainers", page({ c1 }), "end")
    check(m.s == 1 and m.ch == 0, "S10 只顯示翻過幾個，不自動清空")
    loadChunks(400, 400, 16, 16, true)
    nowMs = nowMs + CL.RESCAN_MS + 1
    ticks(33)
    check(m.n == 1 and m.ch > 0, "S11 補掃到整棟後算出總數並自動清空")
end

-- S12 掃到一半，房間的格子清單變少（兩個 tick 之間 chunk 卸載，IsoRoom.removeSquare）：不丟錯、這次不算整棟、排定補掃 ----
do
    local hall = building(2000, 2000, 100, 10)
    poiDefs[hall.id] = true
    local hs = {}
    for x = 2000, 2099 do
        for y = 2000, 2009 do hs[#hs + 1] = square(x, y, 0, hall) end
    end
    -- 真的 ArrayList.get 超出範圍會丟例外（jlist 只回 nil）
    local live = { size = function() return #hs end, get = function(_, i)
        if i >= #hs then error("IndexOutOfBoundsException: Index " .. i .. " out of bounds for length " .. #hs) end
        return hs[i + 1]
    end }
    hall.rooms[1] = { getIsoRoom = function() return { getSquares = function() return live end } end }
    loadChunks(2000, 2000, 100, 10, true)
    local warns, warn = 0, CL.warn
    CL.warn = function(...) warns = warns + 1; return warn(...) end
    msPerSquare = 0.01
    p0.def = hall
    local before, n = scanned, 0
    while scanned == before and n < 100 do ticks(1); n = n + 1 end
    check(scanned > before and hooked("OnTickEvenPaused"), "S12-0 前提：掃描已開始、還沒掃完")
    for i = #hs, 401, -1 do hs[i] = nil end
    n = 0
    while hooked("OnTickEvenPaused") and n < 1000 do ticks(1); n = n + 1 end
    eq(warns, 0, "S12 清單變少不丟錯（沒有 Cleared scan 警告）")
    local s = CL.slots[0]
    check(s.cur and s.cur.n == 0 and s.rescanAt ~= nil, "S12 這次不算整棟：不記容器總數、排定補掃")
    CL.warn, msPerSquare = warn, 0
end

-- B2 單機：重新生成的 chunk 碰到已清空的建築＝已刷新 ---------------------------------------------
local function chunkAt(x, y, new)
    return { isNewChunk = function() return new end,
        getGridSquare = function(_, cx) return { getX = function() return x + cx end, getY = function() return y end } end }
end
do
    local s = CL.slots[0]
    local m = CL.find(s, { x = 400, y = 400, w = 16, h = 16 })
    check(m and m.ch > 0, "B2-0 前提：已清空")
    fire("LoadChunk", chunkAt(408, 400, false))
    check(m.ch > 0, "B2-1 不是新的 chunk 不動")
    fire("LoadChunk", chunkAt(800, 800, true))
    check(m.ch > 0, "B2-2 新 chunk 沒碰到不動")
    client = true
    fire("LoadChunk", chunkAt(408, 400, true))
    check(m.ch > 0, "B2-3 多人客戶端不做（伺服器做）")
    client = false
    hours = 150
    fire("LoadChunk", chunkAt(408, 400, true))
    check(m.ch == 0 and m.rh == 150 and m.s == 0, "B2-4 重新生成＝已刷新")
    local code = CL.code(0, { x = 400, y = 400, w = 16, h = 16 })
    eq(code, 4, "B2-5 圖標代碼＝已刷新")
    p0.def = house
    ticks(30)
    p0.def = building(400, 400, 16, 16)
    poiDefs[p0.def.id] = true
    ticks(30)
    check(m.rh == 0, "B2-6 再走進去變回去過")
end

-- M 手動標記、提示、圖標代碼 -------------------------------------------------------------------
do
    local box = { x = 600, y = 600, w = 10, h = 10 }
    local ctx = { options = {} }
    Core.clearedMenuFill(Core.mapSubMenu(ctx, nil, "t"), 0, box)
    local sub = ctx.subs[1]
    check(#sub.options == 1 and sub.options[1].text == "UI_MinidoracatMiniMap_ClearedSet", "M1 沒標記：只有標為已清空")
    sub.options[1].fn(sub.options[1].target)
    eq(CL.code(0, box), 2, "M2 沒去過也能標已清空")
    ctx = { options = {} }
    Core.clearedMenuFill(Core.mapSubMenu(ctx, nil, "t"), 0, box)
    sub = ctx.subs[1]
    check(#sub.options == 2 and sub.options[1].text == "UI_MinidoracatMiniMap_ClearedUnset"
        and sub.options[2].text == "UI_MinidoracatMiniMap_ClearedForget", "M3 已清空：取消、忘記這裡")
    sub.options[1].fn(sub.options[1].target)
    eq(CL.code(0, box), nil, "M4 沒去過的取消＝整筆刪掉")
    local visited = { x = 64, y = 64, w = 16, h = 16 }
    Core.clearedSet(0, visited, true)
    Core.clearedSet(0, visited, false)
    eq(CL.code(0, visited), 1, "M5 去過的取消＝退回去過")
    Core.clearedForget(0, visited)
    eq(CL.code(0, visited), nil, "M6 忘記這裡")
    -- 提示
    hours = 200
    Core.clearedSet(0, visited, true)
    local z = { bx = 64, by = 64, bw = 16, bh = 16 }
    eq(Core.clearedTip(0, z, "Pharmacy"), "UI_MinidoracatMiniMap_ClearedTip(Pharmacy|UI_MinidoracatMiniMap_ClearedStateCleared("
        .. "UI_MinidoracatMiniMap_ClearedByManual|UI_MinidoracatMiniMap_ClearedToday))", "M7 已清空提示")
    eq(Core.clearedTip(0, { bx = 5000, by = 5000, bw = 4, bh = 4 }, "Bar"), "Bar", "M8 沒標記的提示不變")
    -- 隊友
    CL.team[0] = { n = 1, list = { { a = "bob", m = (function()
        local tm = C.newMark(700, 700, 10, 10); tm.ch, tm.cs, tm.n, tm.s = 150, "a", 10, 9; return tm end)() } } }
    CL.bump()
    eq(CL.code(0, { x = 700, y = 700, w = 10, h = 10 }), 3, "M9 隊友已清空＝代碼 3")
    -- 圖標重建
    check(Core.clearedBuildStart(true), "M10 有資料就查")
    local mk, own = Core.clearedZoneMarks(64, 64, 16, 16)
    check(mk and mk[0] == 2 and not own, "M11 沒去過、只手動標已清空：有代碼，但不算去過（I8）")
    local mk2, own2 = Core.clearedZoneMarks(700, 700, 10, 10)
    check(mk2 and mk2[0] == 3 and not own2, "M12 隊友的不算自己去過")
    CL.find(CL.slots[0], visited).vh = 150 -- 去過、再取消已清空＝留下只有去過
    Core.clearedSet(0, visited, false)
    Core.clearedBuildStart(false)
    local mk3, own3 = Core.clearedZoneMarks(64, 64, 16, 16)
    check(mk3 == nil and own3, "M13 標示去過關：只有去過的不給代碼，但仍算去過（只顯示去過的照用）")
end

-- I6 容器數＝不同容器鍵：同一格兩個同類型的容器在搜刮視窗只算一個，分子分母同一集合 -----------------------
do
    local shop = building(2000, 2000, 8, 8)
    poiDefs[shop.id] = true
    local a1, a2 = square(2001, 2001, 0, shop), square(2003, 2001, 0, shop)
    local s1, s2, cr = container("shelf", 1, false), container("shelf", 1, false), container("crate", 1, false)
    object(a1, "IsoObject", { s1 })
    object(a1, "IsoObject", { s2 })
    object(a2, "IsoObject", { cr })
    room(shop, { a1, a2 })
    loadChunks(2000, 2000, 8, 8, true)
    p0.def = shop
    ticks(33)
    local s = CL.slots[0]
    local m = s.cur
    eq(m.n, 2, "I6-1 同一格同類型的兩個容器算一個")
    fire("OnRefreshInventoryWindowContainers", page({ s1, s2, cr }), "end")
    check(m.s == 2 and m.ch > 0, "I6-2 全部翻完＝100%，自動清空")
end

-- N1 一筆標記對到兩個 BuildingDef：容器數、翻過只算外框相同的那個 def --------------------------------------
do
    local up = building(3000, 3000, 16, 16)
    local down = building(3002, 3003, 14, 12) -- 中心互相落在對方框內＝同一筆
    poiDefs[up.id], poiDefs[down.id] = true, true
    local upSq, downSq, upC, downC = {}, {}, {}, {}
    for k = 1, 10 do
        upSq[k] = square(3000 + k, 3000, 0, up)
        upC[k] = container("crate", 5, false)
        object(upSq[k], "IsoObject", { upC[k] })
    end
    for k = 1, 5 do
        downSq[k] = square(3002 + k, 3004, -1, down)
        downC[k] = container("crate", 1, true)
        object(downSq[k], "IsoObject", { downC[k] })
    end
    room(up, upSq)
    room(down, downSq)
    loadChunks(3000, 3000, 16, 16, true)
    p0.def = up
    ticks(33)
    local s = CL.slots[0]
    local m = s.cur
    fire("OnRefreshInventoryWindowContainers", page({ upC[1], upC[2] }), "end")
    check(m.n == 10 and m.s == 2, "N1-0 前提：地上 10 個、翻過 2 個")
    p0.def = down
    ticks(33)
    check(s.cur == m and m.n == 10, "N1-1 走到另一個 def：同一筆，但容器數不被地下室的掃描蓋掉")
    fire("OnRefreshInventoryWindowContainers", page(downC), "end")
    check(m.s == 2 and m.ch == 0, "N1-2 地下室的容器不算翻過，不會沒翻就自動清空")
end

-- N2 出門掃描時才達到自動門檻：已清空要上傳（多人） --------------------------------------------------------
do
    local s = CL.slots[0]
    local m = C.newMark(3500, 3500, 8, 8)
    m.vh, m.n, m.s, m.t = 10, 10, 9, 1 -- 已經會上傳（拿過）：自動清空不改變上傳條件，靠 auto 才標待上傳
    s.store.count = s.store.count + 1
    s.store.marks[s.store.count] = m
    opts.ClearedAutoPct = 90
    client = true
    CL.finish({ mark = m, slot = s, pn = 0, phase = "exit", full = true, n = 10, l = 0, i = 0 })
    client = false
    check(m.ch > 0 and m.u == true, "N2-1 容器數沒變、在出門掃描才自動清空：照樣標待上傳")
    m.u = nil
    client = true
    CL.finish({ mark = m, slot = s, pn = 0, phase = "exit", full = true, n = 10, l = 3, i = 1 })
    client = false
    check(m.u == nil, "N2-2 只有 l、i 變了：不上傳（也不在對帳摘要裡）")
end

-- K 拿過（2026-11-08 使用者裁定）：原版 ISInventoryTransferAction:perform 做完、真的搬到東西、來源是這棟的計入容器才算 ----
do
    local performed = 0
    -- 假原版：單機 move 時從來源拿走一件；多人照原版把 transactionId 換成下一批的交易（:526）或清成 0（:509-510）
    local origPerform = function(self)
        performed = performed + 1
        if self.move then table.remove(self.srcContainer.items) end
        self.transactionId = self.nextTx or 0
        self.nextTx = nil
    end
    -- 同引擎（LuaManager.java:12149-12155）：0 與沒登記的 id 回 true；登記的照設定
    local txState = { [1] = true, [7] = false, [9] = false }
    function isItemTransactionDone(id)
        if id == 0 or txState[id] == nil then return true end
        return txState[id]
    end
    ISInventoryTransferAction = { perform = origPerform }
    local keepSlots = CL.slots
    fire("OnGameStart")
    CL.slots = keepSlots
    check(ISInventoryTransferAction.perform ~= origPerform, "K0 進遊戲時包上原版 perform")
    local kb = building(8000, 8000, 8, 8)
    poiDefs[kb.id] = true
    local k1, k2 = square(8001, 8001, 0, kb), square(8003, 8001, 0, kb)
    local kc1, kc2 = container("crate", 3, false), container("shelf", 2, false)
    object(k1, "IsoObject", { kc1 })
    object(k2, "IsoObject", { kc2 })
    for k = 1, 3 do object(square(8004 + k, 8005, 0, kb), "IsoObject", { container("drawer" .. k, 1, false) }) end
    room(kb, { k1, k2, squares["8005,8005,0"], squares["8006,8005,0"], squares["8007,8005,0"] })
    loadChunks(8000, 8000, 8, 8, true)
    client = true
    p0.def = kb
    ticks(33)
    local s = CL.slots[0]
    local m = s.cur
    check(m and m.n == 5 and m.t == 0, "K-0 前提：走進去、掃到 5 個容器")
    fire("OnRefreshInventoryWindowContainers", page({ kc1, kc2 }), "end")
    check(m.s == 2 and not C.relevant(m) and m.u == nil, "K1 只翻過沒拿：不標待上傳")
    -- tx：多人交易編號（預設 1＝已完成；0＝零時間路徑沒建交易），move：單機假原版真的搬走一件
    local function take(char, src, tx, move)
        local n0 = performed
        ISInventoryTransferAction.perform({ character = char, srcContainer = src, destContainer = {},
            transactionId = tx or 1, move = move })
        return performed == n0 + 1
    end
    local function holder(cls, sq)
        return { _cls = cls, getSquare = function() return sq end }
    end
    local function contOf(parent)
        local c = container("x", 1, false)
        c.getParent = function() return parent end
        return c
    end
    local ran = take(p0, contOf(holder("IsoPlayer", k1)))
    check(ran and m.t == 0, "K2a 從身上拿（來源是角色）不算；原版 perform 照常呼叫")
    take(p0, contOf(holder("BaseVehicle", k1)))
    check(m.t == 0, "K2b 從載具拿不算")
    take(p0, contOf(nil))
    check(m.t == 0, "K2c 背包裡、地上清單（沒有父物件）不算")
    take(p0, contOf(holder("IsoWorldInventoryObject", k1)))
    check(m.t == 0, "K2d 地上的物品不算")
    take(p0, outside)
    check(m.t == 0, "K2e 別棟的容器不算")
    take({ _cls = "IsoPlayer", getPlayerNum = function() return 0 end, isDead = function() return false end,
        getCurrentBuildingDef = function() return kb end }, kc1)
    check(m.t == 0 and m.u == nil, "K2f 別的玩家（不是本機 0 號）的動作不算")
    fire("OnRefreshInventoryWindowContainers", page({ contOf(holder("BaseVehicle", k1)) }), "end")
    check(m.s == 2, "K2g 搜刮視窗列出載具的容器（父物件是 BaseVehicle）不算翻過")
    ran = take(p0, kc1, 0)
    check(ran and m.t == 0 and m.u == nil, "K2h 零時間路徑（物品已不在、沒建交易就 perform）：不算拿過、不上傳")
    ran = take(p0, kc1, 7)
    check(ran and m.t == 0 and m.u == nil, "K2i 多人交易沒完成：不算拿過")
    local realOn, realBefore = CL.onTransfer, CL.transferBefore
    CL.onTransfer = function() error("boom") end
    ran = take(p0, kc1)
    CL.onTransfer = realOn
    check(ran and m.t == 0, "K2j 判斷丟錯：原版 perform 照常呼叫")
    CL.transferBefore = function() error("boom") end
    ran = take(p0, kc1)
    CL.transferBefore = realBefore
    check(ran and m.t == 0, "K2k 擷取成功證據丟錯：原版 perform 照常呼叫")
    -- 批次：這一批的交易完成、原版接著為下一批建新交易（:526）→ 這次記拿過；下一次 perform 讀到的是沒完成的新交易
    local batch = { character = p0, srcContainer = kc1, destContainer = {}, transactionId = 1, nextTx = 9 }
    ISInventoryTransferAction.perform(batch)
    check(m.t == 1 and batch.transactionId == 9, "K2l 批次：目前這批的交易完成就記拿過（先讀交易編號再呼叫原版）")
    m.t = 0
    ISInventoryTransferAction.perform(batch)
    check(m.t == 0, "K2m 批次：下一批的交易還沒完成，不因為讀到新編號而記拿過")
    local p1 = makePlayer(1, "p1")
    p1.def = kb
    ticks(30)
    local m1 = CL.slots[1] and CL.slots[1].cur
    take(p1, kc1)
    check(m1 and m1.t == 1 and m.t == 0, "K3 分割畫面依 playerNum 分開記")
    players[1] = nil
    take(p0, kc1)
    check(m.t == 1 and C.relevant(m) and m.u == true, "K4 從這棟的容器拿＝拿過，標待上傳")
    CL.save(s)
    CL.slots[0] = nil
    s = CL.slot(0)
    local back = CL.find(s, m)
    check(back and back.t == 1 and back.s == 2, "K5 帳號檔寫出後讀回一致（拿過、翻過數）")
    ticks(30)
    m = s.cur
    check(CL.applyRefresh(0, { x = 8000, y = 8000, w = 8, h = 8, rs = 5, rh = hours }) and m.t == 0 and m.rh == hours,
        "K6 伺服器刷新：拿過歸零")
    opts.ClearedAuto = false
    local function enter(mp, t, ji, jl, n)
        m.rh, m.s, m.t, m.ch, m.cs, m.n, m.l, m.i, m.u = 0, 2, t or 0, 0, "-", n or 5, 5, 2, nil
        m.keys, m.kn = { a = true, b = true }, 2
        client = mp
        CL.finish({ mark = m, slot = s, pn = 0, phase = "enter", full = true, n = n or 5, l = jl or 1, i = ji or 11,
            t = t or 0 })
        client = true
        return m.rh > 0
    end
    check(not enter(true), "K7 多人只翻過沒拿：B1 不標已刷新（已刷新會上傳）")
    check(m.s == 0 and m.kn == nil and m.keys == nil and m.rh == 0 and m.u == nil and not C.relevant(m),
        "K13 多人只翻過沒拿、物品變多：只清本機進度，不標已刷新、不上傳")
    check(not enter(true, 0, 2) and m.s == 2 and m.kn == 2, "K14 多人只翻過沒拿、物品沒變多：進度保留")
    check(not enter(true, 0, 1) and m.s == 0 and m.rh == 0, "K13b 多人只翻過沒拿、物品變少（重新生成重擲戰利品）：也清本機進度")
    check(not enter(false, 0, 11, 5) and m.s == 2, "K14b 單機物品有變但 B1 不成立（被拿過的沒變少）：進度保留")
    check(not enter(true, 0, 11, 1, 0) and m.s == 2, "K14c 多人容器數還沒掃過（n＝0）：進度保留")
    check(enter(true, 1) and m.t == 0, "K15 多人拿過的照 B1 規則標已刷新（拿過歸零）")
    check(not enter(true, 1, 11, 5) and m.s == 2 and m.t == 1, "K15b 多人拿過的、物品變多但被拿過的沒變少：照 B1 不動，進度保留")
    check(enter(false), "K8 單機只翻過沒拿：B1 照常比對")
    m.ch, m.cs, m.t, m.vh = 5, "m", 1, math.max(m.vh, 1)
    Core.clearedSet(0, m, false)
    check(m.ch == 0 and m.t == 0, "K16 取消已清空：拿過歸零")
    -- 搬移當下同步目前建築：剛進門、還沒到下一次 CHECK_TICKS 就拿完（F2）
    local kb3 = building(8400, 8400, 8, 8)
    poiDefs[kb3.id] = true
    local r1 = square(8401, 8401, 0, kb3)
    local rc = container("crate", 2, false)
    object(r1, "IsoObject", { rc })
    room(kb3, { r1 })
    loadChunks(8400, 8400, 8, 8, true)
    CL.tickN = 0
    p0.def = kb3
    take(p0, rc)
    local mr = s.cur
    check(mr and mr.t == 1 and s.lastDefId == kb3.id, "K10 進門後還沒輪詢就拿：當下認到這棟、記拿過")
    ticks(33)
    check(s.cur == mr and mr.t == 1 and mr.n == 1, "K10b 下一次輪詢與進門掃描之後仍是拿過")
    -- R1：進門掃描跨 tick，完成前的拿過與搜刮視窗不能繞過 F3 ------------------------------------
    local function house(x, counts)
        local def = building(x, 8400, 8, 8)
        poiDefs[def.id] = true
        local conts, sqs = {}, {}
        for k, cnt in ipairs(counts) do
            local sq = square(x + k, 8401, 0, def)
            conts[k] = container("box" .. k, cnt, false)
            object(sq, "IsoObject", { conts[k] })
            sqs[k] = sq
        end
        room(def, sqs)
        loadChunks(x, 8400, 8, 8, true)
        return def, conts
    end
    -- 走進去整棟掃過、翻過 looks 那幾個容器、再走出去（出門掃描記下物品數）
    local function visitOnce(def, looks)
        p0.def = def
        ticks(33)
        local mk = s.cur
        fire("OnRefreshInventoryWindowContainers", page(looks), "end")
        p0.def = nil
        ticks(33)
        return mk
    end
    local hb, hc = house(8600, { 2, 2, 2, 2 })
    local ma = visitOnce(hb, { hc[1] })
    table.insert(hc[2].items, 9) -- 別人動過／被重置：總數不同
    p0.def = hb
    CL.tickN = 0
    take(p0, hc[1])
    check(ma and s.cur == ma and s.entering == ma and ma.t == 1 and ma.s == 1 and ma.u == true,
        "R1a 前提：進門還沒掃完就拿，帶舊進度標待上傳")
    ticks(33)
    check(ma.s == 0 and ma.t == 1 and s.drops[C.key(ma)] == true and s.entering == nil,
        "R1a 進門前沒拿過、掃完物品數有變：清本機進度、送 drop 撤掉剛才的上傳，拿過留著")
    local hb2, hc2 = house(8650, { 2, 2 })
    local mb = visitOnce(hb2, { hc2[1] })
    table.insert(hc2[1].items, 9)
    opts.ClearedAuto = true
    p0.def = hb2
    CL.sync(0, s, p0, nowMs)
    fire("OnRefreshInventoryWindowContainers", page({ hc2[2] }), "end")
    check(mb.s == 2 and mb.ch == 0 and mb.u == nil, "R1b 掃描還沒完成：舊進度加新容器到門檻也不自動已清空、不上傳")
    ticks(1)
    check(mb.s == 0 and mb.ch == 0 and mb.u == nil, "R1b 掃完物品數有變：清本機進度，沒有自動已清空")
    opts.ClearedAuto = false
    local hb3, hc3 = house(8700, { 2, 2 })
    local mc = visitOnce(hb3, { hc3[1] })
    opts.ClearedAuto = true
    p0.def = hb3
    CL.sync(0, s, p0, nowMs)
    fire("OnRefreshInventoryWindowContainers", page({ hc3[2] }), "end")
    check(mc.ch == 0, "R1c 前提：掃描還沒完成時不自動判斷")
    ticks(1)
    check(mc.s == 2 and mc.ch > 0 and mc.cs == "a" and s.entering == nil, "R1c 掃完物品數沒變：進度保留，這時才自動已清空")
    local hb4, hc4 = house(8750, { 2, 2 })
    p0.def = hb4
    CL.sync(0, s, p0, nowMs)
    local md = s.cur
    p0.def = nil
    CL.sync(0, s, p0, nowMs)
    check(md and s.entering == nil, "R1d 進門掃描中途出門：狀態清掉")
    ticks(33)
    p0.def = hb4
    ticks(33)
    fire("OnRefreshInventoryWindowContainers", page({ hc4[1], hc4[2] }), "end")
    check(md.ch > 0 and md.cs == "a", "R1d 再進門掃完後，自動判斷照常")
    opts.ClearedAuto = false
    local hb5, hc5 = house(8800, { 2, 2 })
    local me = visitOnce(hb5, { hc5[1] })
    loadChunks(8800, 8400, 8, 8, false)
    opts.ClearedAuto = true
    p0.def = hb5
    CL.sync(0, s, p0, nowMs)
    fire("OnRefreshInventoryWindowContainers", page({ hc5[2] }), "end")
    check(me.ch == 0, "R1e 前提：掃描還沒完成時不自動判斷")
    ticks(1)
    check(me.ch > 0 and s.entering == nil, "R1e 沒整棟載入：finish 用上次的容器數補做自動判斷，不會永遠壓著")
    opts.ClearedAuto = false
    p0.def = nil
    ticks(33)
    -- 單機 B2：只翻過沒拿的本機進度照樣看（C.progress）
    client = false
    local kb2 = building(8200, 8200, 8, 8)
    poiDefs[kb2.id] = true
    local q1, q2 = square(8201, 8201, 0, kb2), square(8203, 8201, 0, kb2)
    local qc = container("crate", 1, false)
    object(q1, "IsoObject", { qc })
    object(q2, "IsoObject", { container("shelf", 1, false) })
    room(kb2, { q1, q2 })
    loadChunks(8200, 8200, 8, 8, true)
    p0.def = kb2
    ticks(33)
    local mq = s.cur
    CL.index(0)
    fire("OnRefreshInventoryWindowContainers", page({ qc }), "end")
    hours = hours + 1
    fire("LoadChunk", chunkAt(8200, 8200, true))
    check(mq and mq.s == 0 and mq.rh == hours, "K9 單機：只翻過沒拿的建築，重新生成的 chunk 照樣標已刷新")
    -- 單機看來源容器物品數（F1）
    take(p0, qc, 0)
    check(mq.t == 0 and #qc.items == 1, "K11 單機：perform 沒搬到東西（物品數沒變）不算拿過")
    take(p0, qc, 0, true)
    check(mq.t == 1 and #qc.items == 0, "K12 單機：來源物品數變少＝拿過")
    opts.ClearedAuto = true
end

-- E 上限：3000 筆，先刪最舊的「只有去過」 ------------------------------------------------------
do
    local s = CL.slot(0)
    local st = s.store
    while st.count < C.MAX_MARKS do
        local m = C.newMark(5000 + st.count * 20, 5000, 10, 10)
        m.vh = 300 + st.count
        st.count = st.count + 1
        st.marks[st.count] = m
    end
    local oldest = nil
    for i = 1, st.count do
        local m = st.marks[i]
        if not C.progress(m) and (not oldest or m.vh < oldest.vh) then oldest = m end
    end
    local added = CL.add(s, { x = 90000, y = 90000, w = 5, h = 5 })
    check(added and st.count == C.MAX_MARKS and oldest.dead, "E1 滿了刪最舊的只有去過")
    -- 只翻過沒拿的（不上傳）本機仍是有進度：滿了不先刪
    local looked = nil
    for i = 1, st.count do
        local m = st.marks[i]
        if not C.progress(m) and (not looked or m.vh < looked.vh) then looked = m end
    end
    looked.s = 1
    CL.add(s, { x = 91000, y = 91000, w = 5, h = 5 })
    check(not looked.dead, "E2 只翻過沒拿的不先刪")
end

print("cleared assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
