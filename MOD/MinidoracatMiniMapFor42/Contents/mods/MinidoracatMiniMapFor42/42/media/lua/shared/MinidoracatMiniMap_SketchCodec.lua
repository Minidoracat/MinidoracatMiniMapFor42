-- MinidoracatMiniMap_SketchCodec.lua — 手繪線的驗證、檔案與封包格式（shared：客戶端、伺服器共用）
-- 檔案 IO（fileKey／readLines／writeSafe／backupPath／newOrigin／validOrigin）一律在呼叫時查
-- MinidoracatMiniMapRoadCodec 的現成函式（同一套「先寫備份、讀回全等才算寫成」）。
--
-- 座標以 1/4 格為單位存整數（記憶體是格，乘 4 一定是整數：建立時已量化），|值| ≤ MAX_Q。
-- 客戶端帳號檔（tab 分欄）：
--   MMSKETCH 版本 nextId 來源碼
--   S id 色(1-5) 粗細(1-3) 縮放(1-24) 分享(-|fs) x,y,...（1–MAX_STROKE_PTS 點）
--   END 筆數
-- 伺服器作者檔（Lua/MinidoracatMiniMap/sketch/<世界>/<帳號>.txt，帳號在檔名、逐 UTF-16 單位轉 4 位十六進位）：
--   MMSKSRV 版本／S lid 色 粗細 縮放 x,y,...／END 筆數；索引檔 MMSKIDX 版本／A 十六進位 轉義帳號／END 筆數。
-- 缺 END 或筆數不符＝invalid；版本較新＝unsupported（只讀，防降級抹資料）；任何一筆壞＝整份 invalid。
-- 封包：每筆 { id = "來源碼:編號", c, w, z, p }（全字串；伺服器送出時另帶 a＝作者）。fromWire 只收白名單欄位、
-- 每欄有長度上限，再整筆重驗。table.concat 一律給範圍（Kahlua # 不可信）。
if MinidoracatMiniMapSketchCodec then return end
local Codec = {
    CLIENT_TAG = "MMSKETCH", SERVER_TAG = "MMSKSRV", INDEX_TAG = "MMSKIDX", SCHEMA = 1,
    MAX_STROKE_PTS = 500,
    -- 畫的上限（滿了拒畫）與檔案硬上限：擦除會把一筆切成兩筆、多出交點，畫滿了照樣能擦，所以檔案讀回認到硬上限
    DRAW_STROKES = 5000, DRAW_POINTS = 50000, MAX_STROKES = 6000, MAX_POINTS = 60000,
    SHARE_MAX_POINTS = 10000, SHARE_MAX_STROKES = 1000, -- 每位作者在伺服器上的上限
    COLORS = 5, WIDTHS = 3, MAX_Z = 24,
    MAX_Q = 40000000, MAX_ID = 999999999,
}
MinidoracatMiniMapSketchCodec = Codec

local function RC() return MinidoracatMiniMapRoadCodec end

-- 純量 ---------------------------------------------------------------------------
local function parseInt(s, lo, hi)
    if type(s) ~= "string" or #s > 10 or not s:match("^%d+$") then return nil end
    local v = tonumber(s)
    if v < lo or v > hi then return nil end
    return v
end
Codec.parseInt = parseInt
local function fmt(v) return string.format("%d", v) end

-- 以單一字元 sep 切開（保留空欄）；超過 max 欄回 nil
local function split(s, sep, max)
    local out, n, pos = {}, 0, 1
    while true do
        n = n + 1
        if n > max then return nil end
        local at = s:find(sep, pos, true)
        if not at then
            out[n] = s:sub(pos)
            return out, n
        end
        out[n] = s:sub(pos, at - 1)
        pos = at + 1
    end
end
Codec.split = split

-- "q,q,..."（1/4 格整數）→ 格座標陣列、點數；壞＝nil
function Codec.parsePts(s)
    if type(s) ~= "string" or #s > Codec.MAX_STROKE_PTS * 20 then return nil end
    local items, n = split(s, ",", Codec.MAX_STROKE_PTS * 2)
    if not items or n % 2 ~= 0 then return nil end
    local max = Codec.MAX_Q
    for i = 1, n do
        local t = items[i]
        if not t:match("^%-?%d+$") or #t > 9 then return nil end
        local v = tonumber(t)
        if v > max or v < -max then return nil end
        items[i] = v / 4
    end
    return items, n / 2
end
-- 格座標 → "q,q,..."（呼叫端保證已量化到 1/4 格）
function Codec.ptsText(pts, np)
    local parts = {}
    for i = 1, np * 2 do parts[i] = fmt(pts[i] * 4) end
    return table.concat(parts, ",", 1, np * 2)
end
function Codec.quantize(v)
    return math.floor(v * 4 + 0.5) / 4
end

-- 筆的屬性：c 1–COLORS、w 1–WIDTHS、z 1–MAX_Z
function Codec.validAttrs(c, w, z)
    return type(c) == "number" and c >= 1 and c <= Codec.COLORS and c % 1 == 0
        and type(w) == "number" and w >= 1 and w <= Codec.WIDTHS and w % 1 == 0
        and type(z) == "number" and z >= 1 and z <= Codec.MAX_Z and z % 1 == 0
end

-- lid＝「來源碼:編號」；回 編號, 來源碼（格式不合 nil）
function Codec.splitLid(s)
    if type(s) ~= "string" or #s > 32 then return nil end
    local origin, id = s:match("^(%x+):(%d+)$")
    if not (origin and RC().validOrigin(origin)) then return nil end
    id = parseInt(id, 1, Codec.MAX_ID)
    if not id then return nil end
    return id, origin
end
function Codec.lid(origin, id) return origin .. ":" .. fmt(id) end

-- 客戶端帳號檔 -----------------------------------------------------------------------
-- 一筆的檔案行（記憶體每筆快取這一行：寫檔只要把各行串起來）
function Codec.strokeLine(s)
    return table.concat({ "S", fmt(s.id), fmt(s.c), fmt(s.w), fmt(s.z), s.share and "fs" or "-",
        Codec.ptsText(s.pts, s.np) }, "\t", 1, 7)
end
function Codec.decodeStroke(line)
    local f, nf = split(line, "\t", 7)
    if not f or nf ~= 7 or f[1] ~= "S" then return nil end
    local id = parseInt(f[2], 1, Codec.MAX_ID)
    local c, w, z = parseInt(f[3], 1, Codec.COLORS), parseInt(f[4], 1, Codec.WIDTHS), parseInt(f[5], 1, Codec.MAX_Z)
    local share
    if f[6] == "fs" then share = true elseif f[6] == "-" then share = false end
    local pts, np = Codec.parsePts(f[7])
    if not (id and c and w and z and share ~= nil and pts and np >= 1) then return nil end
    return { id = id, c = c, w = w, z = z, share = share, pts = pts, np = np, line = line }
end

function Codec.emptyStore()
    return { nextId = 1, count = 0, strokes = {}, points = 0 }
end
-- store＝{ nextId, origin, count, strokes（依 id 遞增，每筆有 line） }
function Codec.encodeStore(store)
    local lines, n = { table.concat({ Codec.CLIENT_TAG, fmt(Codec.SCHEMA), fmt(store.nextId), store.origin }, "\t", 1, 4) }, 1
    for i = 1, store.count do
        n = n + 1
        local s = store.strokes[i]
        lines[n] = s.line or Codec.strokeLine(s)
    end
    n = n + 1
    lines[n] = "END\t" .. fmt(store.count)
    return table.concat(lines, "\n", 1, n)
end

-- 分批解碼（登入時背景載入，每 tick 限時）：begin 驗檔頭與檔尾，step 每次最多解 maxLines 行。
-- 回 state 或 nil, "invalid"|"unsupported"
function Codec.decodeBegin(lines, n)
    local head = n > 0 and lines[1] or ""
    local schema = tonumber(head:match("^" .. Codec.CLIENT_TAG .. "\t(%d+)"))
    if not schema then return nil, "invalid" end
    if schema > Codec.SCHEMA then return nil, "unsupported" end
    local hf, hn = split(head, "\t", 4)
    local nextId = hf and parseInt(hf[3], 1, Codec.MAX_ID + 1)
    local endN = n >= 2 and lines[n]:match("^END\t(%d+)$")
    if schema ~= Codec.SCHEMA or hn ~= 4 or not nextId or not RC().validOrigin(hf[4]) or not endN
        or tonumber(endN) ~= n - 2 or n - 2 > Codec.MAX_STROKES then
        return nil, "invalid"
    end
    return { lines = lines, n = n, i = 2, lastId = 0,
        store = { nextId = nextId, origin = hf[4], count = 0, strokes = {}, points = 0 } }
end
-- 回 true（解完）、false（還有）或 nil, "invalid"。id 必須遞增且小於 nextId（不重複）
function Codec.decodeStep(st, maxLines)
    local store, last = st.store, st.n - 1
    local stop = math.min(last, st.i + maxLines - 1)
    for i = st.i, stop do
        local s = Codec.decodeStroke(st.lines[i])
        if not s or s.id <= st.lastId or s.id >= store.nextId then return nil, "invalid" end
        store.points = store.points + s.np
        if store.points > Codec.MAX_POINTS then return nil, "invalid" end
        st.lastId = s.id
        store.count = store.count + 1
        store.strokes[store.count] = s
    end
    st.i = stop + 1
    return st.i > last
end
function Codec.decodeStore(lines, n)
    local st, err = Codec.decodeBegin(lines, n)
    if not st then return nil, err end
    local done, why = Codec.decodeStep(st, n)
    if not done then return nil, why or "invalid" end
    return st.store
end
-- 讀檔：回 lines, n／nil（沒有檔）／nil, "unreadable"（檔在卻打不開：不能當成沒有檔，否則下一次寫入會蓋掉它）
function Codec.readFile(path)
    if not cacheFileExists(path) then return nil end
    local lines, n = RC().readLines(path)
    if not lines then return nil, "unreadable" end
    return lines, n
end

-- 封包 ------------------------------------------------------------------------------
local WIRE_MAX = { id = 32, c = 2, w = 2, z = 2, p = Codec.MAX_STROKE_PTS * 20, a = 128 }
Codec.WIRE_MAX = WIRE_MAX
function Codec.toWire(origin, s)
    return { id = Codec.lid(origin, s.id), c = fmt(s.c), w = fmt(s.w), z = fmt(s.z), p = Codec.ptsText(s.pts, s.np) }
end
-- 回 { lid, id, origin, c, w, z, pts, np, a? } 或 nil, 欄位名
function Codec.fromWire(t)
    if type(t) ~= "table" then return nil, "stroke" end
    for key, v in pairs(t) do
        local max = WIRE_MAX[key]
        if not max or type(v) ~= "string" or #v > max then return nil, tostring(key) end
    end
    local id, origin = Codec.splitLid(t.id)
    if not id then return nil, "id" end
    local c, w, z = parseInt(t.c, 1, Codec.COLORS), parseInt(t.w, 1, Codec.WIDTHS), parseInt(t.z, 1, Codec.MAX_Z)
    if not (c and w and z) then return nil, "attrs" end
    local pts, np = Codec.parsePts(t.p)
    if not (pts and np >= 1) then return nil, "p" end
    if t.a ~= nil and t.a == "" then return nil, "a" end
    return { lid = t.id, id = id, origin = origin, c = c, w = w, z = z, pts = pts, np = np, a = t.a }
end

-- 伺服器作者檔與索引 -------------------------------------------------------------------
-- 帳號 → 檔名：逐字元（Kahlua 是 UTF-16 單位、標準 Lua 是 byte）轉 4 位十六進位，無損、可放進 Windows 檔名
-- （帳號可能含 : * ? | 與控制字元）。string.byte 原版無用例（api-sources.md），失敗回 nil＝不收這位作者
function Codec.hexName(s)
    if type(s) ~= "string" or s == "" or #s > 128 then return nil end
    local ok, out = pcall(function()
        local parts = {}
        for i = 1, #s do parts[i] = string.format("%04x", string.byte(s, i)) end
        return table.concat(parts, "", 1, #s)
    end)
    return ok and out or nil
end
-- 索引行的帳號轉義（同道路檔的 name：% tab CR LF）
local ESC = { ["%"] = "%25", ["\t"] = "%09", ["\r"] = "%0d", ["\n"] = "%0a" }
local UNESC = { ["%25"] = "%", ["%09"] = "\t", ["%0d"] = "\r", ["%0a"] = "\n" }
function Codec.esc(s) return (s:gsub("[%%\t\r\n]", ESC)) end
function Codec.unesc(s) return (s:gsub("%%%x%x", UNESC)) end

-- strokes＝wire 表陣列（伺服器記憶體就存 wire 形式，轉送不必重新編碼）
function Codec.encodeAuthor(count, strokes)
    local lines, n = { Codec.SERVER_TAG .. "\t" .. fmt(Codec.SCHEMA) }, 1
    for i = 1, count do
        local s = strokes[i]
        n = n + 1
        lines[n] = table.concat({ "S", s.id, s.c, s.w, s.z, s.p }, "\t", 1, 6)
    end
    n = n + 1
    lines[n] = "END\t" .. fmt(count)
    return table.concat(lines, "\n", 1, n)
end
-- 回 { count, strokes（wire 表＋np）, points } 或 nil, reason
function Codec.decodeAuthor(lines, n)
    local schema = tonumber((lines[1] or ""):match("^" .. Codec.SERVER_TAG .. "\t(%d+)$"))
    if not schema then return nil, "invalid" end
    if schema > Codec.SCHEMA then return nil, "unsupported" end
    if n < 2 or lines[n] ~= "END\t" .. fmt(n - 2) then return nil, "invalid" end
    local out, seen = { count = 0, strokes = {}, points = 0 }, {}
    for i = 2, n - 1 do
        local f, nf = split(lines[i], "\t", 6)
        if not f or nf ~= 6 or f[1] ~= "S" then return nil, "invalid" end
        local wire = { id = f[2], c = f[3], w = f[4], z = f[5], p = f[6] }
        local s = Codec.fromWire(wire)
        if not s or seen[wire.id] then return nil, "invalid" end
        seen[wire.id] = true
        wire.np = s.np
        out.points = out.points + s.np
        out.count = out.count + 1
        out.strokes[out.count] = wire
    end
    if out.count > Codec.SHARE_MAX_STROKES or out.points > Codec.SHARE_MAX_POINTS then return nil, "invalid" end
    return out
end
function Codec.encodeIndex(count, names)
    local lines, n = { Codec.INDEX_TAG .. "\t" .. fmt(Codec.SCHEMA) }, 1
    for i = 1, count do
        n = n + 1
        lines[n] = "A\t" .. Codec.hexName(names[i]) .. "\t" .. Codec.esc(names[i])
    end
    n = n + 1
    lines[n] = "END\t" .. fmt(count)
    return table.concat(lines, "\n", 1, n)
end
-- 回 帳號陣列, 筆數 或 nil, reason；每行的十六進位必須等於轉義帳號的十六進位
function Codec.decodeIndex(lines, n)
    local schema = tonumber((lines[1] or ""):match("^" .. Codec.INDEX_TAG .. "\t(%d+)$"))
    if not schema then return nil, "invalid" end
    if schema > Codec.SCHEMA then return nil, "unsupported" end
    if n < 2 or lines[n] ~= "END\t" .. fmt(n - 2) then return nil, "invalid" end
    local names, seen = {}, {}
    for i = 2, n - 1 do
        local f, nf = split(lines[i], "\t", 3)
        if not f or nf ~= 3 or f[1] ~= "A" then return nil, "invalid" end
        local name = Codec.unesc(f[3])
        if name == "" or Codec.hexName(name) ~= f[2] or seen[name] then return nil, "invalid" end
        seen[name] = true
        names[i - 1] = name
    end
    return names, n - 2
end
