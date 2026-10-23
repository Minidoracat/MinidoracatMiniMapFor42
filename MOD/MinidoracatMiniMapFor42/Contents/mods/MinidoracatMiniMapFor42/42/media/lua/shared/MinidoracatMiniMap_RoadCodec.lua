-- MinidoracatMiniMap_RoadCodec.lua — 自訂道路的驗證、檔案格式與封包格式（shared：客戶端、伺服器共用）
-- 也放收藏檔與道路檔共用的檔案 IO（fileKey／readLines／writeVerified，自 _Places.lua 搬來，行為不變）。
-- PZ API：cacheFileExists／getFileReader／getFileWriter（LuaManager.java:5544-5550、5936-5964、6727-6763）。
--
-- 檔案格式（UTF-8，tab 分欄；客戶端 MMROADS、伺服器 MMROADSRV，同一套）：
--   第一行 <tag>、版本、nextId（客戶端＝下一個 r 編號；伺服器＝下一個 s 編號），客戶端再加來源碼（這台電腦
--   這個道路檔固定的 8–12 位十六進位，讓兩台電腦同帳號的 r 編號在伺服器不撞；舊檔沒有就補，寫回時存）
--   每條路四行：ROAD id sid author name source on|off rev share ends（缺值留空；name／author 的
--   % tab CR LF 寫成 %25 %09 %0d %0a，同收藏檔；伺服器檔的 id 是「來源碼:r編號」）；PTS x,y,...；W 路寬,...；S 路面,...
--   OFF sid（只有客戶端：收到的分享道路被自己停用）；DROP sid（只有客戶端：刪掉、還沒確認收回的分享）；
--   最後一行 END 與 ROAD 筆數。寫檔先寫 <檔名>.bak.txt 再寫主檔（writeSafe），主檔壞了讀備份（readStoreSafe）。
--   缺 END 或筆數不符（寫到一半）＝invalid；版本較新只看第一行＝unsupported（拒寫，防降級抹資料）。
-- 數字自己格式化（Lua 5.4 tostring(3.0)＝"3.0"、Kahlua＝"3"）：座標 0.5 格為單位，整數印整數、半格印 .5；
-- 讀回只收這兩種寫法。table.concat 一律給範圍（Kahlua # 不可信）。
if MinidoracatMiniMapRoadCodec then return end
local Codec = {}
Codec.MAX_POINTS, Codec.MIN_WIDTH, Codec.MAX_WIDTH, Codec.MAX_NAME = 300, 3, 16, 128
Codec.CLIENT_TAG, Codec.SERVER_TAG, Codec.SCHEMA = "MMROADS", "MMROADSRV", 1
local MAX_COORD, MAX_INTEGER = 1e7, 9007199254740991
local SURFACES = { paved = true, gravel = true, dirt = true, unknown = true }
local ENDS = { snap = true, free = true }
local SOURCES = { draw = true, record = true }

-- 帳號檔名轉義：getFileReader／getFileWriter 把 \ 也當分隔、路徑含 ".." 就回 nil（LuaManager.java:5937-5942、
-- 6728-6731）：先轉 %，再轉 / \ 與 ".."，可逆＝不同存檔不會撞名。
local KEY_ESC = { ["%"] = "%25", ["/"] = "%2f", ["\\"] = "%5c" }
function Codec.fileKey(s)
    return (tostring(s):gsub("[%%/\\]", KEY_ESC):gsub("%.%.", ".%%2e"))
end
-- 逐行讀回（getFileReader 對「不存在」與 IOException 都回 nil；readLine 剝行尾，同 POIExport
-- readBackMatches）；pcall 確保讀到一半拋錯也會 close
function Codec.readLines(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local lines, n = {}, 0
    local ok = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            n = n + 1
            lines[n] = line
            line = reader:readLine()
        end
    end)
    reader:close()
    if ok then return lines, n end
    return nil
end
-- 讀回全等才算寫成：LuaFileWriter 走 PrintWriter，磁碟錯誤不拋例外（同 POIExport）
function Codec.writeVerified(path, text)
    local writer = getFileWriter(path, true, false)
    if not writer then return false end
    if not pcall(function() writer:write(text); writer:close() end) then
        pcall(function() writer:close() end)
    end
    local lines, n = Codec.readLines(path)
    return lines ~= nil and table.concat(lines, "\n", 1, n) == text
end
-- 先寫備份、成功才寫主檔：主檔寫到一半壞掉時 readStoreSafe 改讀備份；備份寫不成＝主檔不動。
-- 備份叫 .bak.txt 不叫 .txt.bak：getFileWriter 只收 ini/cfg/txt/log/json（LuaManager.java:1035、6728）
function Codec.backupPath(path)
    return (path:gsub("%.txt$", "")) .. ".bak.txt"
end
function Codec.writeSafe(path, text)
    return Codec.writeVerified(Codec.backupPath(path), text) and Codec.writeVerified(path, text)
end

-- 名稱清理同收藏 cleanLabel：去頭尾空白；空白回 nil, true；長度以 Kahlua String.len 計
function Codec.cleanName(name)
    if name == nil then return nil, true end
    if type(name) ~= "string" then return nil, false end
    name = name:match("^%s*(.-)%s*$")
    if name == "" then return nil, true end
    return name, #name <= Codec.MAX_NAME
end
local function integer(v)
    return type(v) == "number" and v == v and v >= 1 and v < MAX_INTEGER and v % 1 == 0
end
local function half(v)
    return type(v) == "number" and v == v and v >= -MAX_COORD and v <= MAX_COORD and (v * 2) % 1 == 0
end
-- 純陣列筆數（有洞或非整數鍵回 nil）
local function arrayLen(t)
    if type(t) ~= "table" then return nil end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    for i = 1, n do if t[i] == nil then return nil end end
    return n
end
local function idNum(s, prefix)
    if type(s) ~= "string" or #s > 16 then return nil end
    return tonumber(s:match("^" .. prefix .. "(%d+)$"))
end
Codec.idNumber = function(s) return idNum(s, "r") end
Codec.sidNumber = function(s) return idNum(s, "s") end
function Codec.validOrigin(s)
    return type(s) == "string" and #s >= 8 and #s <= 12 and s:match("^%x+$") ~= nil
end
-- 來源碼：毫秒時間低 32 位＋亂數（getTimestampMs＝LuaManager.java:9267、ZombRand 原版 Lua 通用）
function Codec.newOrigin()
    return string.format("%08x%04x", math.floor(getTimestampMs() % 4294967296), ZombRand(65536))
end
-- 封包與伺服器檔用的 lid＝「來源碼:r編號」；沒有來源碼就是 r 編號本身
function Codec.lid(road)
    return road.origin and (road.origin .. ":" .. road.id) or road.id
end
-- lid → r 編號, 來源碼。沒有冒號原樣回；有冒號但格式不合回原字串（validateRoad 會擋）
function Codec.splitLid(s)
    if type(s) ~= "string" or not s:find(":", 1, true) then return s, nil end
    local origin, id = s:match("^(%x+):(r%d+)$")
    if not (origin and Codec.validOrigin(origin)) then return s, nil end
    return id, origin
end
local function text(s)
    local clean, ok = Codec.cleanName(s)
    return clean ~= nil and ok and clean == s
end

-- 回 true 或 false, 欄位名。不改 road；名稱必須已清理（呼叫端先 cleanName／補預設名）
function Codec.validateRoad(road)
    if type(road) ~= "table" then return false, "road" end
    local pts = road.pts
    local k = arrayLen(pts)
    if not k or k % 2 ~= 0 or k < 4 or k > Codec.MAX_POINTS * 2 then return false, "pts" end
    for i = 1, k do if not half(pts[i]) then return false, "pts" end end
    -- 零長度段（相鄰兩點重合）：路網算方向會除以 0
    for i = 3, k, 2 do
        if pts[i] == pts[i - 2] and pts[i + 1] == pts[i - 1] then return false, "pts" end
    end
    local segs = k / 2 - 1
    local w, s = road.segWidth, road.segSurface
    if arrayLen(w) ~= segs then return false, "segWidth" end
    if arrayLen(s) ~= segs then return false, "segSurface" end
    for i = 1, segs do
        local v = w[i]
        if type(v) ~= "number" or v % 1 ~= 0 or v < Codec.MIN_WIDTH or v > Codec.MAX_WIDTH then
            return false, "segWidth"
        end
        if not SURFACES[s[i]] then return false, "segSurface" end
    end
    local ends = road.ends
    if arrayLen(ends) ~= 2 or not ENDS[ends[1]] or not ENDS[ends[2]] then return false, "ends" end
    if not SOURCES[road.source] then return false, "source" end
    if type(road.enabled) ~= "boolean" then return false, "enabled" end
    local share = road.share
    if type(share) ~= "table" or type(share.faction or false) ~= "boolean"
        or type(share.safehouse or false) ~= "boolean" then return false, "share" end
    if not text(road.name) then return false, "name" end
    if road.author ~= nil and not text(road.author) then return false, "author" end
    if road.id ~= nil and not Codec.idNumber(road.id) then return false, "id" end
    if road.origin ~= nil and not Codec.validOrigin(road.origin) then return false, "origin" end
    if road.sid ~= nil and not Codec.sidNumber(road.sid) then return false, "sid" end
    if road.id == nil and road.sid == nil then return false, "id" end
    if not integer(road.rev) then return false, "rev" end
    return true
end

-- 數字與清單 ------------------------------------------------------------------
local function fmtHalf(v)
    if v % 1 == 0 then return string.format("%d", v) end
    return string.format("%s%d.5", v < 0 and "-" or "", math.floor(math.abs(v)))
end
local function parseHalf(s)
    if s:match("^%-?%d+$") or s:match("^%-?%d+%.5$") then return tonumber(s) end
    return nil
end
local function parseInt(s)
    if #s <= 15 and s:match("^%d+$") then return tonumber(s) end
    return nil
end
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
local function joinNums(t, n, fmt)
    local parts = {}
    for i = 1, n do parts[i] = fmt(t[i]) end
    return table.concat(parts, ",", 1, n)
end
local function fmtInt(v) return string.format("%d", v) end
local function fmtStr(v) return v end
-- 逗號清單 → 陣列；parse 回 nil 即整份不收
local function parseList(s, max, parse)
    local items, n = split(s, ",", max)
    if not items then return nil end
    for i = 1, n do
        local v = parse(items[i])
        if v == nil then return nil end
        items[i] = v
    end
    return items, n
end
local function parseWord(s) return s ~= "" and s or nil end
local function shareText(share)
    if share.faction and share.safehouse then return "faction,safehouse" end
    return share.faction and "faction" or share.safehouse and "safehouse" or ""
end
local SHARE = { [""] = { false, false }, faction = { true, false }, safehouse = { false, true },
    ["faction,safehouse"] = { true, true } }
local function parseShare(s)
    local f = SHARE[s]
    return f and { faction = f[1], safehouse = f[2] } or nil
end
local function parseEnds(s)
    local t, n = split(s, ",", 2)
    return t and n == 2 and t or nil
end
local function pointsText(road)
    return joinNums(road.pts, arrayLen(road.pts), fmtHalf)
end
-- 選填字串欄（id／sid／author／name）：空字串＝nil
local function opt(s) return s ~= "" and s or nil end

-- 檔案 ------------------------------------------------------------------------
local ESC = { ["%"] = "%25", ["\t"] = "%09", ["\r"] = "%0d", ["\n"] = "%0a" }
local UNESC = { ["%25"] = "%", ["%09"] = "\t", ["%0d"] = "\r", ["%0a"] = "\n" }
local function esc(s) return s and (s:gsub("[%%\t\r\n]", ESC)) or "" end
local function unesc(s) return s ~= "" and (s:gsub("%%%x%x", UNESC)) or nil end

function Codec.emptyStore()
    return { nextId = 1, count = 0, roads = {}, offCount = 0, off = {}, dropCount = 0, drops = {} }
end
-- store＝{ nextId, origin?, count, roads, offCount, off（sid 陣列）, dropCount, drops（sid 陣列） }；tag 省略＝客戶端檔
function Codec.encodeStore(store, tag)
    tag = tag or Codec.CLIENT_TAG
    local head = tag .. "\t" .. Codec.SCHEMA .. "\t" .. fmtInt(store.nextId)
    if store.origin then head = head .. "\t" .. store.origin end
    local lines, n = { head }, 1
    for i = 1, store.count do
        local r = store.roads[i]
        local segs = arrayLen(r.segWidth)
        lines[n + 1] = table.concat({ "ROAD", Codec.lid(r) or "", r.sid or "", esc(r.author), esc(r.name), r.source,
            r.enabled and "on" or "off", fmtInt(r.rev), shareText(r.share), r.ends[1] .. "," .. r.ends[2] },
            "\t", 1, 10)
        lines[n + 2] = "PTS\t" .. pointsText(r)
        lines[n + 3] = "W\t" .. joinNums(r.segWidth, segs, fmtInt)
        lines[n + 4] = "S\t" .. joinNums(r.segSurface, segs, fmtStr)
        n = n + 4
    end
    for i = 1, store.offCount or 0 do
        n = n + 1
        lines[n] = "OFF\t" .. store.off[i]
    end
    for i = 1, store.dropCount or 0 do
        n = n + 1
        lines[n] = "DROP\t" .. store.drops[i]
    end
    n = n + 1
    lines[n] = "END\t" .. store.count
    return table.concat(lines, "\n", 1, n)
end

local MAX_NUMS = Codec.MAX_POINTS * 2
-- ROAD／PTS／W／S 四行 → road（未驗證）；格式不合回 nil
local function decodeRoad(head, ptsLine, wLine, sLine)
    local f, nf = split(head, "\t", 10)
    if not f or nf ~= 10 or f[1] ~= "ROAD" then return nil end
    local pts = ptsLine and ptsLine:sub(1, 4) == "PTS\t" and parseList(ptsLine:sub(5), MAX_NUMS, parseHalf)
    local w = wLine and wLine:sub(1, 2) == "W\t" and parseList(wLine:sub(3), MAX_NUMS, parseInt)
    local s = sLine and sLine:sub(1, 2) == "S\t" and parseList(sLine:sub(3), MAX_NUMS, parseWord)
    local share, ends, rev = parseShare(f[9]), parseEnds(f[10]), parseInt(f[8])
    if not (pts and w and s and share and ends and rev) or (f[7] ~= "on" and f[7] ~= "off") then return nil end
    local id, origin = Codec.splitLid(opt(f[2]))
    return { id = id, origin = origin, sid = opt(f[3]), author = unesc(f[4]), name = unesc(f[5]), source = f[6],
        enabled = f[7] == "on", rev = rev, share = share, ends = ends, pts = pts, segWidth = w, segSurface = s }
end

-- 回 store 或 nil, "invalid"|"unsupported"。客戶端每筆要有 id、不能有 author 與來源碼（來源碼在檔頭）；
-- 伺服器每筆要有 sid 與 author、檔頭沒有來源碼。
-- 編號（客戶端 id、伺服器 sid）不重複且小於 nextId；任何一筆不合即整份拒收（不偷偷裁掉壞筆）
function Codec.decodeStore(lines, n, tag)
    tag = tag or Codec.CLIENT_TAG
    local server = tag == Codec.SERVER_TAG
    local head = n > 0 and lines[1] or ""
    local schema = tonumber(head:match("^" .. tag .. "\t(%d+)"))
    if not schema then return nil, "invalid" end
    if schema > Codec.SCHEMA then return nil, "unsupported" end
    local hf, hn = split(head, "\t", 4)
    local nextId = hf and parseInt(hf[3] or "")
    local origin = hn == 4 and hf[4] or nil
    if schema ~= Codec.SCHEMA or not integer(nextId) or n < 2 or not lines[n]:match("^END\t%d+$")
        or (hn == 4 and (server or not Codec.validOrigin(origin))) then
        return nil, "invalid"
    end
    local store = { nextId = nextId, origin = origin, count = 0, roads = {}, offCount = 0, off = {},
        dropCount = 0, drops = {} }
    local seenNum, seenSid, seenOff, seenDrop = {}, {}, {}, {}
    local i = 2
    while i < n do
        local line = lines[i]
        if line:sub(1, 4) == "OFF\t" then
            local sid = line:sub(5)
            if server or not Codec.sidNumber(sid) or seenOff[sid] then return nil, "invalid" end
            seenOff[sid] = true
            store.offCount = store.offCount + 1
            store.off[store.offCount] = sid
            i = i + 1
        elseif line:sub(1, 5) == "DROP\t" then
            local sid = line:sub(6)
            if server or not Codec.sidNumber(sid) or seenDrop[sid] then return nil, "invalid" end
            seenDrop[sid] = true
            store.dropCount = store.dropCount + 1
            store.drops[store.dropCount] = sid
            i = i + 1
        else
            local road = decodeRoad(line, lines[i + 1], lines[i + 2], lines[i + 3])
            if not road or i + 3 >= n or not Codec.validateRoad(road) then return nil, "invalid" end
            local num
            if server then
                num = road.author and Codec.sidNumber(road.sid)
            else
                num = road.author == nil and road.origin == nil and Codec.idNumber(road.id)
            end
            if not num or num >= nextId or seenNum[num] or (road.sid and seenSid[road.sid]) then
                return nil, "invalid"
            end
            seenNum[num] = true
            if road.sid then seenSid[road.sid] = true end
            store.count = store.count + 1
            store.roads[store.count] = road
            i = i + 4
        end
    end
    if lines[n] ~= "END\t" .. store.count then return nil, "invalid" end
    return store
end
-- 回 store／nil（沒有檔）／nil, reason：invalid、unsupported，或 unreadable（檔在卻打不開：
-- 不能當成沒有檔，否則下一次寫入會蓋掉它；cacheFileExists 只看 File.exists）
function Codec.readStore(path, tag)
    if not cacheFileExists(path) then return nil end
    local lines, n = Codec.readLines(path)
    if not lines then return nil, "unreadable" end
    return Codec.decodeStore(lines, n, tag)
end
-- 同 readStore；主檔 invalid／unreadable 時改讀備份（unsupported 不退回：較新的檔照舊只讀）。
-- 讀到備份回 store, nil, 主檔的原因（給呼叫端記 log）
function Codec.readStoreSafe(path, tag)
    local store, err = Codec.readStore(path, tag)
    if err ~= "invalid" and err ~= "unreadable" then return store, err end
    local backup = Codec.readStore(Codec.backupPath(path), tag)
    if backup then return backup, nil, err end
    return store, err
end

-- 封包（sendClientCommand／sendServerCommand 的表）：全部字串欄；enabled 不上 wire（收到的路一律 true，
-- 停用是收件人自己的 OFF）。fromWire 只收白名單欄位、每欄有長度上限，再整條重驗
local WIRE_MAX = { id = 32, sid = 16, author = Codec.MAX_NAME, name = Codec.MAX_NAME, source = 8, rev = 15,
    share = 17, ends = 9, pts = MAX_NUMS * 12, w = MAX_NUMS * 3, s = MAX_NUMS * 8 }
function Codec.toWire(road)
    local segs = arrayLen(road.segWidth)
    return { id = Codec.lid(road), sid = road.sid, author = road.author, name = road.name, source = road.source,
        rev = fmtInt(road.rev), share = shareText(road.share), ends = road.ends[1] .. "," .. road.ends[2],
        pts = pointsText(road), w = joinNums(road.segWidth, segs, fmtInt),
        s = joinNums(road.segSurface, segs, fmtStr) }
end
function Codec.fromWire(t)
    if type(t) ~= "table" then return nil, "road" end
    for key, v in pairs(t) do
        local max = WIRE_MAX[key]
        if not max or type(v) ~= "string" or #v > max then return nil, tostring(key) end
    end
    if not (t.name and t.source and t.rev and t.share and t.ends and t.pts and t.w and t.s) then
        return nil, "road"
    end
    local id, origin = Codec.splitLid(t.id)
    local road = { id = id, origin = origin, sid = t.sid, author = t.author, name = t.name, source = t.source, enabled = true,
        rev = parseInt(t.rev), share = parseShare(t.share), ends = parseEnds(t.ends),
        pts = parseList(t.pts, MAX_NUMS, parseHalf), segWidth = parseList(t.w, MAX_NUMS, parseInt),
        segSurface = parseList(t.s, MAX_NUMS, parseWord) }
    local ok, err = Codec.validateRoad(road)
    if not ok then return nil, err end
    return road
end

MinidoracatMiniMapRoadCodec = Codec
