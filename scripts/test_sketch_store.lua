-- 手繪線資料層（client/MinidoracatMiniMap_Sketch.lua）離線回歸：背景載入（每 tick 限時、壞檔讀備份、
-- 較新版本與打不開只讀）、新增與上限、局部擦除（直線擦中間、擦端點、整筆擦光、單點筆）、復原式套用、
-- 停筆防抖只寫一次、每個 pn 一個路徑、收到的別人的線擦不到。
-- 用法：lua scripts/test_sketch_store.lua
local H = dofile("scripts/sketch_harness.lua")
local Core = H.boot()
local SK, C, check = H.SK, MinidoracatMiniMapSketchCodec, H.check
local P0 = "MinidoracatMiniMap/sketch/Sandbox/w1_p0.txt"
local P1 = "MinidoracatMiniMap/sketch/Sandbox/w1_p1.txt"
H.players[0] = H.player("alice", 0)
H.players[1] = H.player("bob", 1)

local function attrs(share) return { c = 1, w = 2, z = 17, share = share or false } end
local function add(pn, pts, share)
    local s = assert(SK.newStroke(pn, attrs(share), pts, #pts / 2))
    assert(SK.apply(pn, {}, 0, { s }, 1))
    return s
end

-- 路徑：每個 pn 一個檔
check(SK.path(0) == P0 and SK.path(1) == P1, "P1 每個 pn 一個帳號檔路徑")

-- 沒有檔＝空清單、可寫；載入前不能畫
H.fire("OnCreatePlayer", 0)
local slot = SK.slots[0]
check(slot and slot.load == nil, "L1 沒有檔：當場就好，不必等 tick")
check(slot.store and slot.store.count == 0 and slot.error == nil and C.parseInt and slot.store.origin, "L2 沒有檔＝空清單＋新來源碼")

-- 新增：量化到 1/4 格、相鄰重複點去掉；停筆 2 秒才寫、只寫一次
H.writes = {}
local s1 = add(0, { 10.1, 20.1, 10.12, 20.12, 30, 20 })
check(s1.np == 2 and s1.pts[1] == 10 and s1.pts[2] == 20 and s1.pts[3] == 30, "A1 量化到 1/4 格並去掉重複點")
add(0, { 50, 50 })
H.fire("OnTickEvenPaused")
check(#H.writes == 0, "A2 停筆不到 2 秒不寫")
H.now = H.now + SK.SAVE_DELAY_MS
H.fire("OnTickEvenPaused")
H.fire("OnTickEvenPaused")
check(#H.writes == 2 and H.writes[1]:match("%.bak%.txt$") and H.writes[2] == P0, "A3 防抖後寫一次（備份＋主檔）")
check(H.files[P0]:match("\nEND\t2$"), "A4 帳號檔兩筆")
H.writes = {}
check(H.Core.sketchFlush(0) == true and #H.writes == 0, "A5 沒有改動時 flush 不寫")

-- 局部擦除：直線兩點擦中間 → 兩段；擦端點 → 一段；整筆擦光；單點筆
local function erase(pn, x, y, r)
    local rem, nr, ad, na = SK.eraseAt(pn, x, y, r)
    SK.apply(pn, rem, nr, ad, na)
    return nr, na, ad
end
local nr, na, pieces = erase(0, 20, 20, 2)
check(nr == 1 and na == 2 and pieces[1].pts[3] == 18 and pieces[2].pts[1] == 22 and pieces[2].pts[3] == 30,
    "E1 直線擦中間 → 兩段（10..18、22..30）")
check(slot.store.count == 3 and SK.indexOf(slot.store, s1.id) == nil, "E2 原筆拿掉、兩段加上")
nr, na, pieces = erase(0, 10, 20, 3)
check(nr == 1 and na == 1 and pieces[1].pts[1] == 13 and pieces[1].pts[3] == 18, "E3 擦端點 → 剩一段（13..18）")
nr, na = erase(0, 15.5, 20, 4)
check(nr == 1 and na == 0, "E4 整筆擦光")
nr, na = erase(0, 50, 50, 0.5)
check(nr == 1 and na == 0, "E5 單點筆被擦掉")
nr, na = erase(0, 500, 500, 3)
check(nr == 0 and na == 0, "E6 擦不到東西")
-- 折線擦中間的頂點：兩側各留一段，交點在圓上
local poly = add(0, { 0, 0, 10, 0, 10, 10 })
nr, na, pieces = erase(0, 10, 0, 2)
check(nr == 1 and na == 2 and pieces[1].pts[3] == 8 and pieces[2].pts[1] == 10 and pieces[2].pts[2] == 2,
    "E7 折線擦轉角：兩段，交點在圓上")

-- 復原式套用：拿掉片段、加回原筆（同 id）
local ok = SK.apply(0, pieces, 2, { poly }, 1)
check(ok and SK.indexOf(slot.store, poly.id) and slot.store.count == 3 - 1, "U1 復原把原筆放回、片段拿掉")
local order = {}
for i = 1, slot.store.count do order[i] = slot.store.strokes[i].id end
local sorted = true
for i = 2, #order do if order[i] < order[i - 1] then sorted = false end end
check(sorted, "U2 加回的筆依 id 排好（畫的順序不亂）")

-- 收到的別人的線：擦不到
H.Core.sketchRecvReplace(0, { { lid = "aaaaaaaa:1", a = "bob", c = 1, w = 2, z = 17, pts = { 200, 200, 210, 200 }, np = 2 } }, 1)
nr = erase(0, 205, 200, 3)
check(nr == 0 and slot.recvN == 1, "R1 收到的別人的線擦不到")
H.Core.sketchRecvDel(0, "bob", { "aaaaaaaa:1" }, 1)
check(slot.recvN == 0, "R2 作者收回後就不見")

-- 上限：畫的上限滿了拒畫（提示交給工具），擦除照常
do
    local store = slot.store
    local savedPoints = store.points
    store.points = C.DRAW_POINTS
    local s, why = SK.newStroke(0, attrs(), { 1, 1, 2, 2 }, 2)
    check(s == nil and why == "full", "F1 點數滿了拒畫")
    store.points = savedPoints
end

-- 背景載入：大檔分好幾個 tick 做完、每 tick 限時
do
    local big = { nextId = 2001, origin = "abcdef12", count = 2000, strokes = {} }
    for i = 1, 2000 do
        local pts = {}
        for k = 0, 9 do pts[#pts + 1] = i + k; pts[#pts + 1] = k * 0.5 end
        big.strokes[i] = { id = i, c = 1, w = 1, z = 17, share = false, pts = pts, np = 10 }
    end
    H.files[P1] = C.encodeStore(big)
    H.autoMs = 1 -- 每讀一次時鐘過 1 ms：LOAD_BUDGET_MS 內只做一部分
    H.fire("OnCreatePlayer", 1)
    check(select(2, SK.writable(1)) == "loading", "B0 載入完成前回 loading（不能畫）")
    local ticks = 0
    while SK.slots[1].load and ticks < 10000 do
        ticks = ticks + 1
        H.fire("OnTickEvenPaused")
    end
    H.autoMs = 0
    local s = SK.slots[1]
    check(ticks > 5 and s.store.count == 2000 and s.store.points == 20000 and s.store.strokes[2000].levels,
        "B1 2000 筆分 " .. ticks .. " 個 tick 載完，每筆有抽點層")
end

-- 大筆：解碼與 prepare 每筆都要好幾毫秒時，每 tick 最多超支一筆（2026-11-08 審查第 10 條：舊寫法每 40 筆才看一次時鐘）
do
    local big = { nextId = 201, origin = "abcdef12", count = 200, strokes = {} }
    for i = 1, 200 do
        big.strokes[i] = { id = i, c = 1, w = 1, z = 17, share = false, pts = { i, 0, i + 1, 0 }, np = 2 }
    end
    H.files[P1] = C.encodeStore(big)
    local realPrep, realDec, per, maxPer, ticks = SK.prepare, C.decodeStroke, 0, 0, 0
    SK.prepare = function(st) per = per + 1; H.now = H.now + 1; return realPrep(st) end
    C.decodeStroke = function(line) per = per + 1; H.now = H.now + 1; return realDec(line) end
    SK.slots[1] = nil
    H.fire("OnCreatePlayer", 1)
    maxPer = per
    while SK.slots[1].load and ticks < 10000 do
        per = 0
        ticks = ticks + 1
        H.fire("OnTickEvenPaused")
        if per > maxPer then maxPer = per end
    end
    SK.prepare, C.decodeStroke = realPrep, realDec
    check(SK.slots[1].store.count == 200 and maxPer <= SK.LOAD_BUDGET_MS + 1,
        "B2 大筆載入每 tick 最多超支一筆（單 tick 最多 " .. maxPer .. " 筆、" .. ticks .. " 個 tick）")
end

-- 壞檔讀備份；備份也壞＝空、可寫；較新版本只讀（不退回備份）；打不開只讀
local function reload(main, bak, unreadable)
    H.files[P1], H.files[(P1:gsub("%.txt$", ".bak.txt"))] = main, bak
    H.unreadable[P1] = unreadable
    SK.slots[1] = nil
    H.fire("OnCreatePlayer", 1)
    return H.loadSlot(1)
end
local good = C.encodeStore({ nextId = 3, origin = "abcdef12", count = 1,
    strokes = { { id = 1, c = 2, w = 1, z = 18, share = false, pts = { 1, 2 }, np = 1 } } })
local s = reload("MMSKETCH\t1\t3\tabcdef12\nS\t1\tbroken\nEND\t1", good)
check(s.store.count == 1 and s.store.strokes[1].c == 2 and s.error == nil, "K1 主檔壞讀備份（可寫）")
s = reload("garbage", nil)
check(s.store.count == 0 and s.error == "invalid" and SK.writable(1) ~= nil, "K2 主檔壞、沒備份＝空清單可覆寫")
s = reload("MMSKETCH\t2\t3\tabcdef12\nEND\t0", good)
check(s.store.count == 0 and s.error == "unsupported" and select(2, SK.writable(1)) == "readonly",
    "K3 較新版本只讀、不退回備份")
s = reload("MMSKETCH\t1\t1\tabcdef12\nEND\t0", nil, true)
check(s.error == "unreadable" and select(2, SK.writable(1)) == "readonly", "K4 打不開＝只讀")
H.unreadable[P1] = nil
-- 主檔壞、備份是較新版本：不知道備份裡有什麼，只讀（2026-11-08 審查：原本會當空清單、下次存檔把兩份都蓋掉）
do
    local newer = "MMSKETCH\t2\t3\tabcdef12\nEND\t0"
    s = reload("garbage", newer)
    local nw = #H.writes
    check(s.error == "unsupported" and select(2, SK.writable(1)) == "readonly" and #H.writes == nw
        and H.files[P1] == "garbage" and H.files[(P1:gsub("%.txt$", ".bak.txt"))] == newer,
        "K5 主檔壞＋備份較新＝只讀，兩份原樣")
end

-- 寫檔失敗：提示一次，資料留在記憶體
H.writeBroken = true
add(0, { 300, 300 })
H.messages = {}
H.now = H.now + SK.SAVE_DELAY_MS
H.fire("OnTickEvenPaused")
check(#H.messages == 1 and H.messages[1] == "UI_MinidoracatMiniMap_SketchSaveFailed"
    and SK.indexOf(slot.store, slot.store.strokes[slot.store.count].id), "W1 寫檔失敗提示、線留著")
-- 失敗後仍算「還沒存」：關工具（sketchFlush）回 false；死亡重生不重讀檔（會蓋掉沒存的筆）；之後寫得進去就存
check(Core.sketchFlush(0) == false and slot.dirty == true, "W2 寫檔失敗後關工具照樣回 false")
local unsaved = slot.store.count
H.players[0] = H.player("alice", 0)
H.fire("OnCreatePlayer", 0)
check(SK.slots[0].store.count == unsaved and SK.slots[0].dirty == true, "W3 死亡重生沿用沒存的筆")
slot = SK.slots[0]
H.writeBroken = false
H.now = H.now + SK.SAVE_RETRY_MS
H.fire("OnTickEvenPaused")
check(slot.dirty == nil and Core.sketchFlush(0) == true, "W4 之後寫得進去就存、清掉未存")

-- 5,000 筆清除全部再復原：一次建表＋一趟壓縮／合併（逐筆線性找＋搬移在 Kahlua 推估單幀 1–3 秒）
do
    local rem = {}
    for i = 1, slot.store.count do rem[i] = slot.store.strokes[i] end
    assert(SK.apply(0, rem, slot.store.count, {}, 0))
    local many = {}
    for i = 1, 5000 do many[i] = assert(SK.newStroke(0, attrs(), { i, 0 }, 1)) end
    assert(SK.apply(0, {}, 0, many, 5000))
    local list = {}
    for i = 1, 5000 do list[i] = slot.store.strokes[i] end
    local t0 = os.clock()
    assert(SK.apply(0, list, 5000, {}, 0))
    assert(SK.apply(0, {}, 0, list, 5000))
    local dt = os.clock() - t0
    local sorted = true
    for i = 2, slot.store.count do if slot.store.strokes[i - 1].id >= slot.store.strokes[i].id then sorted = false end end
    check(slot.store.count == 5000 and slot.store.points == 5000 and sorted, "X1 清除全部再復原：5000 筆照 id 排回")
    check(dt < 0.25, string.format("X2 5000 筆清除＋復原 %.3f 秒（< 0.25）", dt))
    -- 反序放回（反向拖過去擦掉再復原，復原紀錄照擦到的順序累積）：也不能是 O(n²)
    assert(SK.apply(0, list, 5000, {}, 0))
    local rev = {}
    for i = 1, 5000 do rev[i] = list[5001 - i] end
    t0 = os.clock()
    assert(SK.apply(0, {}, 0, rev, 5000))
    dt = os.clock() - t0
    sorted = true
    for i = 2, slot.store.count do if slot.store.strokes[i - 1].id >= slot.store.strokes[i].id then sorted = false end end
    check(slot.store.count == 5000 and sorted and dt < 0.15, string.format("X3 反序放回 5000 筆照 id 排、%.3f 秒（< 0.15）", dt))
end

H.finish("test_sketch_store")
