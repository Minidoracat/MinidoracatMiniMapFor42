-- 手繪線格式（shared/MinidoracatMiniMap_SketchCodec.lua）離線回歸：帳號檔來回、1/4 格整數、上限、
-- 任一筆壞就整份拒收、較新版本只讀、分批解碼、封包白名單與長度上限、伺服器作者檔與索引（帳號十六進位無損）。
-- 用法：lua scripts/test_sketch_codec.lua
local H = dofile("scripts/sketch_harness.lua")
H.boot()
local C = MinidoracatMiniMapSketchCodec
local check = H.check

local function stroke(id, n, share)
    local pts = {}
    for i = 0, n - 1 do pts[#pts + 1] = 100 + i * 0.25; pts[#pts + 1] = -50.75 + i end
    return { id = id, c = 3, w = 2, z = 17, share = share or false, pts = pts, np = n }
end
local function lines(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
    return out, #out
end

-- 來回：座標以 1/4 格整數存、讀回原值
local store = { nextId = 5, origin = "3fa2c41b09d1", count = 2, strokes = { stroke(2, 3, true), stroke(4, 1) } }
local text = C.encodeStore(store)
check(text:match("^MMSKETCH\t1\t5\t3fa2c41b09d1\n"), "C1 檔頭")
check(text:find("S\t2\t3\t2\t17\tfs\t400,-203,401,-199,402,-195", 1, true), "C2 1/4 格整數（100→400、-50.75→-203）")
check(text:match("\nEND\t2$"), "C3 END 筆數")
local back = C.decodeStore(lines(text))
check(back and back.count == 2 and back.strokes[1].pts[3] == 100.25 and back.strokes[1].pts[2] == -50.75
    and back.strokes[1].share == true and back.strokes[2].np == 1 and back.points == 4, "C4 讀回原值（含單點筆）")
check(back and back.strokes[1].line == "S\t2\t3\t2\t17\tfs\t400,-203,401,-199,402,-195", "C5 每筆快取檔案行")

-- 任一筆壞＝整份 invalid；缺 END／筆數不符；id 重複或不遞增；較新版本 unsupported
local function bad(t, why)
    local s, err = C.decodeStore(lines(t))
    check(s == nil and err == (why or "invalid"), "C6 拒收：" .. t:gsub("\n", "|"):sub(1, 60))
end
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t3\t2\t17\tfs\t400,-203,401\nEND\t1") -- 奇數個座標
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t6\t2\t17\t-\t400,1\nEND\t1") -- 色超過 5
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t1\t4\t17\t-\t400,1\nEND\t1") -- 粗細超過 3
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t1\t1\t25\t-\t400,1\nEND\t1") -- 縮放超過 24
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t1\t1\t17\tx\t400,1\nEND\t1") -- 分享欄
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t1\t1\t17\t-\t400.5,1\nEND\t1") -- 不是整數
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t1\t1\t17\t-\t400000000,1\nEND\t1") -- 超出座標範圍
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t1\t1\t17\t-\t4,1") -- 缺 END
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t1\t1\t17\t-\t4,1\nEND\t2") -- 筆數不符
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t2\t1\t1\t17\t-\t4,1\nS\t2\t1\t1\t17\t-\t4,1\nEND\t2") -- id 重複
bad("MMSKETCH\t1\t5\t3fa2c41b09d1\nS\t5\t1\t1\t17\t-\t4,1\nEND\t1") -- id 不小於 nextId
bad("MMSKETCH\t1\t5\tzz\nS\t2\t1\t1\t17\t-\t4,1\nEND\t1") -- 來源碼
bad("MMSKETCH\t2\t5\t3fa2c41b09d1\nwhatever", "unsupported")

-- 上限：每筆 500 點（多一點就拒收）、整份 MAX_STROKES 筆
local big = stroke(1, C.MAX_STROKE_PTS)
local ok = C.decodeStore(lines(C.encodeStore({ nextId = 2, origin = "abcdef12", count = 1, strokes = { big } })))
check(ok and ok.strokes[1].np == C.MAX_STROKE_PTS, "C7 500 點一筆收得下")
local over = stroke(1, C.MAX_STROKE_PTS + 1)
check(C.decodeStore(lines(C.encodeStore({ nextId = 2, origin = "abcdef12", count = 1, strokes = { over } }))) == nil,
    "C8 501 點一筆拒收")
check(C.DRAW_STROKES == 5000 and C.DRAW_POINTS == 50000 and C.MAX_STROKES > C.DRAW_STROKES
    and C.MAX_POINTS > C.DRAW_POINTS, "C9 畫的上限 5,000 筆／50,000 點，檔案硬上限更高（擦除切出的筆讀得回）")
do
    local many = { nextId = C.MAX_STROKES + 2, origin = "abcdef12", count = C.MAX_STROKES + 1, strokes = {} }
    for i = 1, many.count do many.strokes[i] = stroke(i, 1) end
    check(C.decodeStore(lines(C.encodeStore(many))) == nil, "C10 超過硬上限筆數拒收")
    local pts = { nextId = 200, origin = "abcdef12", count = 0, strokes = {} }
    for i = 1, math.ceil(C.MAX_POINTS / C.MAX_STROKE_PTS) + 1 do
        pts.count = i
        pts.strokes[i] = stroke(i, C.MAX_STROKE_PTS)
    end
    check(C.decodeStore(lines(C.encodeStore(pts))) == nil, "C11 超過硬上限點數拒收")
end

-- 分批解碼：每次只解 maxLines 行，結果與一次解完相同
do
    local s = { nextId = 30, origin = "abcdef12", count = 25, strokes = {} }
    for i = 1, 25 do s.strokes[i] = stroke(i, 3) end
    local ls, n = lines(C.encodeStore(s))
    local st = assert(C.decodeBegin(ls, n))
    local steps, done = 0, false
    repeat
        steps = steps + 1
        done = C.decodeStep(st, 4)
    until done ~= false
    check(done == true and steps == 7 and st.store.count == 25 and st.store.points == 75, "C12 分批解碼 7 次（每次 4 行）")
end

-- 封包：白名單、長度上限、lid 格式
local w = C.toWire("3fa2c41b09d1", stroke(12, 2))
check(w.id == "3fa2c41b09d1:12" and w.c == "3" and w.p == "400,-203,401,-199", "W1 toWire")
local s1 = C.fromWire(w)
check(s1 and s1.id == 12 and s1.origin == "3fa2c41b09d1" and s1.np == 2 and s1.pts[3] == 100.25, "W2 fromWire")
local function wireBad(mut, label)
    local t = C.toWire("3fa2c41b09d1", stroke(12, 2))
    mut(t)
    check(C.fromWire(t) == nil, "W3 拒收：" .. label)
end
wireBad(function(t) t.extra = "x" end, "不在白名單的欄位")
wireBad(function(t) t.c = 3 end, "非字串")
wireBad(function(t) t.id = "12" end, "沒有來源碼")
wireBad(function(t) t.id = "zz:12" end, "來源碼不是十六進位")
wireBad(function(t) t.p = string.rep("1,", C.MAX_STROKE_PTS * 10) .. "1" end, "座標字數超過上限")
wireBad(function(t) t.p = "1,2,3" end, "奇數個座標")
wireBad(function(t) t.w = "0" end, "粗細 0")
wireBad(function(t) t.a = "" end, "空作者")
check(C.fromWire("x") == nil and C.fromWire(nil) == nil, "W4 非表")

-- 伺服器作者檔與索引：帳號無損轉成十六進位（控制字元、冒號、%）
local weird = "a:b*?|\t%\1z"
local hex = C.hexName(weird)
check(hex and hex:match("^%x+$") and #hex == #weird * 4, "S1 十六進位檔名只有 0-9a-f、每字 4 位")
check(C.hexName("a:b") ~= C.hexName("a_b") and C.hexName("ab") ~= C.hexName("a") , "S2 不同帳號不撞名")
local idx = C.encodeIndex(2, { weird, "bob" })
local names, n = C.decodeIndex(lines(idx))
check(n == 2 and names[1] == weird and names[2] == "bob", "S3 索引來回（含 tab、%、控制字元）")
local badIdx = idx:gsub(hex, "0061") -- 十六進位與帳號不符
check(C.decodeIndex(lines(badIdx)) == nil, "S4 索引十六進位與帳號不符就拒收")
local wires = { C.toWire("abcdef12", stroke(1, 2)), C.toWire("abcdef12", stroke(2, 3)) }
local au = C.decodeAuthor(lines(C.encodeAuthor(2, wires)))
check(au and au.count == 2 and au.points == 5 and au.strokes[2].id == "abcdef12:2" and au.strokes[2].np == 3,
    "S5 作者檔來回")
check(C.decodeAuthor(lines("MMSKSRV\t9\nEND\t0")) == nil and select(2, C.decodeAuthor(lines("MMSKSRV\t9\nEND\t0")))
    == "unsupported", "S6 作者檔較新版本 unsupported")
check(C.decodeAuthor(lines("MMSKSRV\t1\nS\tabcdef12:1\t1\t1\t17\t4,4\nS\tabcdef12:1\t1\t1\t17\t4,4\nEND\t2")) == nil,
    "S7 作者檔 lid 重複拒收")

H.finish("test_sketch_codec")
