-- MinidoracatMiniMap_ClearedCodec.lua — 資源點「去過／已清空」的資料格式（shared：客戶端、伺服器共用）
-- 一筆標記＝一棟建築（BuildingDef 外框 x,y,w,h）加上狀態：
--   vh 去過的遊戲時數、ch 清空時數（0＝沒清空）、cs 清空方式（m 手動／a 自動／- 無）、
--   n 容器數（0＝還沒整棟掃過；同一格同類型的容器算一個，和翻過的容器鍵同一套）、s 翻過數、
--   l 被拿過數、i 物品總數（l、i 只給客戶端「再走進去比對」用，不上對帳摘要）、
--   oh 最後一次整棟掃描時數、rh 刷新時數（0＝沒刷新）、
--   rs 伺服器刷新序號（伺服器發的、只增不減：max(現在 epoch 毫秒, 上一個＋1)，伺服器回滾也不會重複；
--   客戶端存「已處理過的最新刷新」，比 rs 判斷刷新是不是新的，不比遊戲時數——管理員可以把時鐘往回撥）、
--   t 拿過（1＝自己用原版搬移動作從這棟計入的容器拿過東西；刷新、取消已清空都歸零）。
-- 比對規則（same）：兩個外框的中心互相落在對方框內＝同一棟（地上／地下兩筆 BuildingDef、兩種標示方式的外框）。
--
-- 檔案（UTF-8，tab 分欄；數字自己格式化，Kahlua 與 Lua 5.4 的 tostring 不同）：
--   客戶端 MMCLEARED <版本> <refreshSeq> <來源碼>；每筆 B 行（15 欄＋u：1＝待上傳）；還沒清空的建築可接一行
--   K <翻過的容器>（每個「相對外框左上 dx,dy,z,類型」以 tab 分開；dx、dy 可以是負的：合併的另一個外框在左上方）；
--   最後 END <B 筆數>。來源碼＝這台電腦這個帳號檔固定的 8–12 位十六進位（同自訂道路），新檔建立時配。
--   伺服器 MMCLRSRV <版本> <share 0|1> <seq> <rms>；O <來源碼> <最後一次同步的 epoch 毫秒>；B 行（15 欄＋來源碼＋us），
--   沒有 K；END <B 筆數>。rms＝這位作者已套用的最新重置 RUN 的 epoch 毫秒（重播時跳過，見伺服器 B3）。
--   us＝伺服器最後一次改這筆狀態時發的序號（和 rs 同一個計數器 seq；跨來源碼合併取最新用它，不比遊戲時數）。
--   索引 MMCLRIDX <版本> <最後套用的重置 run id 或 -> <索引建立的 epoch 毫秒> <已套用的最新 RUN 毫秒>；
--   A <帳號十六進位> <筆數> <share>；END <A 筆數>。chunk → 作者不存檔（伺服器開服從作者檔重建）。
--   缺 END 或筆數不符＝invalid；版本較新＝unsupported（拒寫，防降級抹資料）。
-- 封包裡一筆標記是字串 "x,y,w,h,vh,ch,cs,n,s,l,i,oh,rh,rs,t"。
-- 檔案 IO 與檔名轉義借 MinidoracatMiniMapRoadCodec（字母序在本檔之後載入，所以一律執行時才查）。
if MinidoracatMiniMapClearedCodec then return end
local C = {}
C.SCHEMA = 1
C.CLIENT_TAG, C.SERVER_TAG, C.INDEX_TAG = "MMCLEARED", "MMCLRSRV", "MMCLRIDX"
C.MAX_MARKS = 3000   -- 每帳號檔上限；超過先刪最舊的「只有去過」
-- 外框邊長上限（格）：2026-11-08 量 shared/MinidoracatMiniMapPOIData.lua 1,669 棟資源點建築，最大 273×156
-- （15325,2842），單棟最多 700 個 chunk、中位數 6、p99 117，全部合計 22,993。512＝香草最大約 2 倍、留給 MOD 地圖，
-- 單筆最多 65×65＝4,225 個 chunk。這是網路與伺服器的上限（防濫用）：本機帳號檔收到 MAX_LOCAL_EDGE，
-- 超過 MAX_EDGE 的那筆只留在本機、不上傳不分享（uploadable）
C.MAX_EDGE = 512
C.MAX_LOCAL_EDGE = 4000
C.CHUNK_BUDGET = 50000 -- 伺服器每位作者（全部來源碼）外框蓋到的 chunk 總數上限，約全部香草資源點的 2 倍
C.MAX_COUNT = 100000 -- 容器、物品數上限（寫出去前夾住，讀回來才不會整份拒收）
C.MAX_HOURS = 10000000
C.CHUNK = 8          -- 存檔 map/{x//8}/{y//8}.bin

local function int(s, neg)
    if type(s) ~= "string" or #s > 12 then return nil end
    if s:match(neg and "^%-?%d+$" or "^%d+$") then return tonumber(s) end
    return nil
end
-- epoch 毫秒級的非負整數（13 位）
local function big(s)
    if type(s) ~= "string" or #s > 15 or not s:match("^%d+$") then return nil end
    return tonumber(s)
end
C.parseBig = big
local function hours(s)
    if type(s) ~= "string" or #s > 14 then return nil end
    if s:match("^%d+$") or s:match("^%d+%.%d%d?$") then
        local v = tonumber(s)
        if v <= C.MAX_HOURS then return v end
    end
    return nil
end
local function fmtH(v)
    if v <= 0 then return "0" end
    return string.format("%.2f", v)
end
local function fmtI(v) return string.format("%d", v) end
C.fmtHours, C.fmtInt = fmtH, fmtI

-- 以單一字元切開（保留空欄）；超過 max 欄回 nil
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
C.split = split

function C.newMark(x, y, w, h)
    return { x = x, y = y, w = w, h = h, vh = 0, ch = 0, cs = "-", n = 0, s = 0, l = 0, i = 0, oh = 0, rh = 0, rs = 0, t = 0 }
end

-- 外框中心互相落在對方框內（半開區間）
function C.same(a, b)
    local ax, ay = a.x + a.w / 2, a.y + a.h / 2
    local bx, by = b.x + b.w / 2, b.y + b.h / 2
    return ax >= b.x and ax < b.x + b.w and ay >= b.y and ay < b.y + b.h
        and bx >= a.x and bx < a.x + a.w and by >= a.y and by < a.y + a.h
end

function C.key(m)
    return fmtI(m.x) .. "," .. fmtI(m.y) .. "," .. fmtI(m.w) .. "," .. fmtI(m.h)
end
-- 對帳（clrSyncOk）：會存標記的雜湊，加總取模（與順序無關）。「伺服器存什麼、隊友讀什麼，就對什麼」，而且只放
-- 客戶端改了一定會上傳的欄位：外框、去過、清空時數與方式、容器數、翻過數、刷新時數、拿過。l、i、oh 是客戶端「再走進去
-- 比對」的簿記，出門掃描就會變、不上傳，放進來每次搜刮後都會整份重傳；rs 由伺服器發。時數照線上格式（兩位小數）
-- 正規化，兩邊算出來一樣
local P31 = 2147483647
local CS_CODE = { ["-"] = 0, m = 1, a = 2 }
local function mix(h, v) return (h * 31 + v) % P31 end
local function h100(v) return math.floor(tonumber(fmtH(v)) * 100 + 0.5) % P31 end
-- n、s 照線上格式夾 MAX_COUNT（本機掃描可以超過，送出去的是夾過的）
function C.digest(m)
    local h = mix(mix(mix(mix(m.x % P31, m.y % P31), m.w), m.h), h100(m.vh))
    h = mix(mix(mix(mix(h, h100(m.ch)), CS_CODE[m.cs] or 0), math.min(m.n, C.MAX_COUNT)), math.min(m.s, C.MAX_COUNT))
    return mix(mix(h, h100(m.rh)), m.t)
end
-- origin 給了就只算這個來源碼的（伺服器）；回 摘要, 筆數
function C.storeDigest(marks, count, origin)
    local d, n = 0, 0
    for i = 1, count do
        local m = marks[i]
        if C.uploadable(m) and (origin == nil or m.o == origin) then
            d = (d + C.digest(m)) % P31
            n = n + 1
        end
    end
    return d, n
end

-- "x,y,w,h" → x, y, w, h（格式或範圍不合回 nil）
function C.parseKey(s)
    if type(s) ~= "string" then return nil end
    local f, n = split(s, ",", 4)
    if not f or n ~= 4 then return nil end
    local x, y, w, h = int(f[1], true), int(f[2], true), int(f[3]), int(f[4])
    if not (x and y and w and h) or w < 1 or h < 1 or w > C.MAX_EDGE or h > C.MAX_EDGE then return nil end
    return x, y, w, h
end

-- "cleared" / "refreshed" / "visited"
function C.state(m)
    if m.ch > 0 then return "cleared" end
    if m.rh > 0 then return "refreshed" end
    return "visited"
end
-- 會存到伺服器、分享給隊友的標記：已清空、已刷新、有翻過進度而且拿過東西（2026-11-08 使用者裁定：原版搜刮視窗列出
-- 身邊 3×3 沒隔牆的容器，ISInventoryPage.lua:1667-1679，只看翻過的話路過的建築都會上傳＝分享行蹤）。
-- 只有去過、只翻過沒拿的不上傳。客戶端上傳、伺服器 clrPut 驗證、對帳的筆數與摘要都用這一條
function C.relevant(m)
    return m.ch > 0 or m.rh > 0 or (m.s > 0 and m.t > 0)
end
-- 本機有進度（自己的帳號檔：滿了不先刪、單機 B2 要看的 chunk）；比 relevant 寬：只翻過沒拿的也算
function C.progress(m)
    return m.ch > 0 or m.s > 0 or m.rh > 0
end
-- 會存而且能上傳的（外框在網路上限內）；對帳的筆數與摘要也只算這些
function C.uploadable(m)
    return C.relevant(m) and m.w <= C.MAX_EDGE and m.h <= C.MAX_EDGE
end

-- 刷新：清空、翻過進度與拿過歸零（只有去過的時數留著）
function C.refresh(m, now)
    m.ch, m.cs, m.s, m.rh, m.t = 0, "-", 0, now, 0
    m.keys, m.kn = nil, nil
end

-- 外框蓋到的 chunk 數（O(1)，伺服器預算用）
function C.chunkCost(m)
    local K, floor = C.CHUNK, math.floor
    return (floor((m.x + m.w - 1) / K) - floor(m.x / K) + 1) * (floor((m.y + m.h - 1) / K) - floor(m.y / K) + 1)
end

-- 15 欄 ----------------------------------------------------------------------------
local NF = 15
local function cnt(v) return fmtI(v < C.MAX_COUNT and v or C.MAX_COUNT) end
local function fields(m)
    return { fmtI(m.x), fmtI(m.y), fmtI(m.w), fmtI(m.h), fmtH(m.vh), fmtH(m.ch), m.cs, cnt(m.n), cnt(m.s),
        cnt(m.l), cnt(m.i), fmtH(m.oh), fmtH(m.rh), fmtI(m.rs or 0), m.t > 0 and "1" or "0" }
end
local CS = { m = true, a = true, ["-"] = true }
local function fromFields(f, at, maxEdge)
    local m = {
        x = int(f[at], true), y = int(f[at + 1], true), w = int(f[at + 2]), h = int(f[at + 3]),
        vh = hours(f[at + 4]), ch = hours(f[at + 5]), cs = f[at + 6], n = int(f[at + 7]), s = int(f[at + 8]),
        l = int(f[at + 9]), i = int(f[at + 10]), oh = hours(f[at + 11]), rh = hours(f[at + 12]), rs = big(f[at + 13]),
        t = f[at + 14] == "1" and 1 or f[at + 14] == "0" and 0 or nil,
    }
    if not (m.x and m.y and m.w and m.h and m.vh and m.ch and CS[m.cs] and m.n and m.s and m.l and m.i
        and m.oh and m.rh and m.rs and m.t) then return nil end
    if m.w < 1 or m.h < 1 or m.w > maxEdge or m.h > maxEdge or m.n > C.MAX_COUNT or m.s > C.MAX_COUNT
        or m.l > C.MAX_COUNT or m.i > C.MAX_COUNT or (m.ch > 0) == (m.cs == "-") then return nil end
    return m
end

function C.toWire(m)
    return table.concat(fields(m), ",", 1, NF)
end
function C.fromWire(s)
    if type(s) ~= "string" or #s > 180 then return nil end
    local f, n = split(s, ",", NF)
    if not f or n ~= NF then return nil end
    return fromFields(f, 1, C.MAX_EDGE)
end

-- 翻過的容器鍵："dx,dy,z,類型"（類型只收 %w _ -，其他字元的 MOD 容器記成 ?）。dx、dy 相對標記外框左上，可以是負的
function C.containerKey(m, sx, sy, z, ctype)
    if type(ctype) ~= "string" or not ctype:match("^[%w_%-]+$") or #ctype > 40 then ctype = "?" end
    return fmtI(sx - m.x) .. "," .. fmtI(sy - m.y) .. "," .. fmtI(z) .. "," .. ctype
end
local function validContainerKey(k)
    local f, n = split(k, ",", 4)
    return f and n == 4 and int(f[1], true) and int(f[2], true) and int(f[3], true)
        and (f[4] == "?" or f[4]:match("^[%w_%-]+$") ~= nil) and #f[4] <= 40
end

local function validOrigin(s)
    return type(s) == "string" and #s >= 8 and #s <= 12 and s:match("^%x+$") ~= nil
end
C.validOrigin = validOrigin

-- 客戶端檔 --------------------------------------------------------------------------
-- store＝{ refreshSeq, origin, count, marks = { mark…（u＝true 待上傳；keys＝{ [容器鍵]=true }, kn） } }
function C.emptyStore() return { refreshSeq = 0, count = 0, marks = {} } end

function C.encodeClient(store)
    local head = C.CLIENT_TAG .. "\t" .. C.SCHEMA .. "\t" .. fmtI(store.refreshSeq)
    if store.origin then head = head .. "\t" .. store.origin end
    local lines, n = { head }, 1
    for i = 1, store.count do
        local m = store.marks[i]
        local f = fields(m)
        f[NF + 1] = m.u and "1" or "0"
        n = n + 1
        lines[n] = "B\t" .. table.concat(f, "\t", 1, NF + 1)
        if m.ch == 0 and m.keys and (m.kn or 0) > 0 then
            local ks, k = {}, 0
            for key in pairs(m.keys) do
                if k >= C.MAX_COUNT then break end
                k = k + 1
                ks[k] = key
            end
            n = n + 1
            lines[n] = "K\t" .. table.concat(ks, "\t", 1, k)
        end
    end
    n = n + 1
    lines[n] = "END\t" .. store.count
    return table.concat(lines, "\n", 1, n)
end

local function headSchema(lines, n, tag)
    local head = n > 0 and lines[1] or ""
    local schema = tonumber(head:match("^" .. tag .. "\t(%d+)"))
    if not schema then return nil, "invalid" end
    if schema > C.SCHEMA then return nil, "unsupported" end
    if schema ~= C.SCHEMA or n < 2 or not lines[n]:match("^END\t%d+$") then return nil, "invalid" end
    return head
end

-- 回 store 或 nil, "invalid"|"unsupported"；任何一行不合即整份拒收
function C.decodeClient(lines, n)
    local head, err = headSchema(lines, n, C.CLIENT_TAG)
    if not head then return nil, err end
    local hf, hn = split(head, "\t", 4)
    local seq = hf and hn == 4 and big(hf[3])
    if not seq or not validOrigin(hf[4]) then return nil, "invalid" end
    local store = { refreshSeq = seq, origin = hf[4], count = 0, marks = {} }
    local last
    for li = 2, n - 1 do
        local line = lines[li]
        local tag = line:sub(1, 2)
        if tag == "B\t" then
            local f, fn = split(line:sub(3), "\t", NF + 1)
            local m = f and fn == NF + 1 and fromFields(f, 1, C.MAX_LOCAL_EDGE)
            if not m or (f[NF + 1] ~= "0" and f[NF + 1] ~= "1") then return nil, "invalid" end
            m.u = f[NF + 1] == "1" or nil
            store.count = store.count + 1
            store.marks[store.count] = m
            last = m
        elseif tag == "K\t" then
            if not last or last.keys or last.ch > 0 then return nil, "invalid" end
            local ks, kn = split(line:sub(3), "\t", C.MAX_COUNT)
            if not ks then return nil, "invalid" end
            last.keys, last.kn = {}, 0
            for k = 1, kn do
                if not validContainerKey(ks[k]) then return nil, "invalid" end
                if not last.keys[ks[k]] then
                    last.keys[ks[k]] = true
                    last.kn = last.kn + 1
                end
            end
        else
            return nil, "invalid"
        end
    end
    if lines[n] ~= "END\t" .. store.count or store.count > C.MAX_MARKS then return nil, "invalid" end
    return store
end

-- 伺服器作者檔 ----------------------------------------------------------------------
-- store＝{ share = bool, seq, rms, origins = { [來源碼] = 最後同步 epoch 毫秒 }, on（來源碼數）, count,
--          marks = { mark…（o＝來源碼；rs＝這筆被伺服器刷新時的序號，0＝沒有） } }
function C.emptyServer() return { share = false, seq = 0, rms = 0, origins = {}, on = 0, count = 0, marks = {} } end

function C.encodeServer(store)
    local lines, n = { C.SERVER_TAG .. "\t" .. C.SCHEMA .. "\t" .. (store.share and "1" or "0") .. "\t"
        .. fmtI(store.seq) .. "\t" .. fmtI(store.rms or 0) }, 1
    for o, seen in pairs(store.origins) do
        n = n + 1
        lines[n] = "O\t" .. o .. "\t" .. fmtI(seen)
    end
    for i = 1, store.count do
        local m = store.marks[i]
        local f = fields(m)
        f[NF + 1], f[NF + 2] = m.o, fmtI(m.us or 0)
        n = n + 1
        lines[n] = "B\t" .. table.concat(f, "\t", 1, NF + 2)
    end
    n = n + 1
    lines[n] = "END\t" .. store.count
    return table.concat(lines, "\n", 1, n)
end

function C.decodeServer(lines, n)
    local head, err = headSchema(lines, n, C.SERVER_TAG)
    if not head then return nil, err end
    local hf, hn = split(head, "\t", 5)
    local seq, rms = hf and hn == 5 and big(hf[4]), hf and hn == 5 and big(hf[5])
    if not (seq and rms) or (hf[3] ~= "0" and hf[3] ~= "1") then return nil, "invalid" end
    local store = C.emptyServer()
    store.share, store.seq, store.rms = hf[3] == "1", seq, rms
    local per = {}
    for li = 2, n - 1 do
        local line = lines[li]
        local f, fn = split(line, "\t", NF + 3)
        if f and fn == 3 and f[1] == "O" and validOrigin(f[2]) and big(f[3]) and not store.origins[f[2]] then
            store.origins[f[2]] = big(f[3])
            store.on = store.on + 1
        elseif f and fn == NF + 3 and f[1] == "B" then
            local m = fromFields(f, 2, C.MAX_EDGE)
            if m then m.us = big(f[NF + 3]) end
            if not (m and m.us) or m.rs > seq or m.us > seq or not store.origins[f[NF + 2]] then return nil, "invalid" end
            m.o = f[NF + 2]
            per[m.o] = (per[m.o] or 0) + 1
            if per[m.o] > C.MAX_MARKS then return nil, "invalid" end
            store.count = store.count + 1
            store.marks[store.count] = m
        else
            return nil, "invalid"
        end
    end
    if lines[n] ~= "END\t" .. store.count then return nil, "invalid" end
    return store
end

-- 伺服器索引 ------------------------------------------------------------------------
-- index＝{ run（最後套用的重置 run id，nil＝沒有）, since（索引建立的 epoch 毫秒）, ms（已套用的最新 RUN 毫秒，0＝沒有）,
--          authors = { [hex] = { count, share } }, an, chunks = { ["cx,cy"] = { [hex] = true } }（只在記憶體，不編進檔） }
function C.encodeIndex(index)
    local lines, n = { C.INDEX_TAG .. "\t" .. C.SCHEMA .. "\t" .. (index.run or "-") .. "\t" .. fmtI(index.since)
        .. "\t" .. fmtI(index.ms or 0) }, 1
    local an = 0
    for hex, a in pairs(index.authors) do
        an = an + 1
        n = n + 1
        lines[n] = "A\t" .. hex .. "\t" .. fmtI(a.count) .. "\t" .. (a.share and "1" or "0")
    end
    n = n + 1
    lines[n] = "END\t" .. an
    return table.concat(lines, "\n", 1, n)
end

local function validHex(s) return type(s) == "string" and #s >= 4 and #s <= 256 and #s % 4 == 0 and s:match("^%x+$") ~= nil end
local function validRun(s) return type(s) == "string" and #s >= 1 and #s <= 64 and s:match("^[%w_%-%.:]+$") ~= nil end
C.validRun = validRun

function C.decodeIndex(lines, n)
    local head, err = headSchema(lines, n, C.INDEX_TAG)
    if not head then return nil, err end
    local hf, hn = split(head, "\t", 5)
    local since, ms = hf and hn == 5 and big(hf[4]), hf and hn == 5 and big(hf[5])
    if not (since and ms and (hf[3] == "-" or validRun(hf[3]))) then return nil, "invalid" end
    local index = { run = hf[3] ~= "-" and hf[3] or nil, since = since, ms = ms, authors = {}, an = 0, chunks = {} }
    for li = 2, n - 1 do
        local f, fn = split(lines[li], "\t", 4)
        if f and fn == 4 and f[1] == "A" and validHex(f[2]) and int(f[3]) and (f[4] == "0" or f[4] == "1")
            and not index.authors[f[2]] then
            index.authors[f[2]] = { count = int(f[3]), share = f[4] == "1" }
            index.an = index.an + 1
        else
            return nil, "invalid"
        end
    end
    if lines[n] ~= "END\t" .. index.an then return nil, "invalid" end
    return index
end

-- 讀檔（客戶端帳號檔、伺服器作者檔與索引共用）：回 data, err, recovered
--   主檔好＝data；主檔沒有＝讀備份（寫檔先寫備份，第一次存檔中斷就是這樣），兩份都沒有＝nil（新檔）；
--   主檔壞了（invalid）＝讀備份，recovered＝"invalid"；主檔打不開（unreadable）＝照樣讀備份給畫面用，
--   但 err＝"unreadable"（內容不明，不能拿備份覆寫）；版本較新＝nil, "unsupported"。
--   主檔沒有或壞了、備份也讀不了＝nil 加備份的原因（沒有備份時是主檔的原因）。
function C.readSafe(path, decode)
    local Codec = MinidoracatMiniMapRoadCodec
    local function one(p)
        if not cacheFileExists(p) then return nil, "missing" end
        local lines, n = Codec.readLines(p)
        if not lines then return nil, "unreadable" end
        return decode(lines, n)
    end
    local data, err = one(path)
    if not err or err == "unsupported" then return data, err end
    local backup, berr = one(Codec.backupPath(path))
    if err == "unreadable" then return backup, err end
    if backup then return backup, nil, err end
    if err == "missing" then
        if berr == "missing" then return nil, nil end
        return nil, berr
    end
    return nil, berr == "missing" and err or berr
end

-- 帳號名轉十六進位（帳號可能含 Windows 檔名不允許的字元；無損、可逆）。每字 4 位：Kahlua 字串是 Java String，
-- string.byte 回 UTF-16 碼元（0–65535，StringLib.java:1496）。呼叫端用 pcall（原版沒有 string.byte 用例）
function C.hex(name)
    local out = {}
    for i = 1, #name do out[i] = string.format("%04x", string.byte(name, i)) end
    return table.concat(out, "", 1, #name)
end
function C.unhex(hex)
    local out = {}
    for i = 1, #hex / 4 do out[i] = string.char(tonumber(hex:sub(i * 4 - 3, i * 4), 16)) end
    return table.concat(out, "", 1, #hex / 4)
end

-- 外框蓋到的 chunk 鍵 "cx,cy"（存檔 map/{cx}/{cy}.bin），回陣列與筆數
function C.chunkKeys(m)
    local out, n = {}, 0
    local x1, y1 = math.floor(m.x / C.CHUNK), math.floor(m.y / C.CHUNK)
    local x2, y2 = math.floor((m.x + m.w - 1) / C.CHUNK), math.floor((m.y + m.h - 1) / C.CHUNK)
    for cx = x1, x2 do
        for cy = y1, y2 do
            n = n + 1
            out[n] = fmtI(cx) .. "," .. fmtI(cy)
        end
    end
    return out, n
end

-- 外框有沒有碰到 chunk (cx, cy)
function C.touchesChunk(m, cx, cy)
    local x1, y1 = cx * C.CHUNK, cy * C.CHUNK
    return m.x < x1 + C.CHUNK and x1 < m.x + m.w and m.y < y1 + C.CHUNK and y1 < m.y + m.h
end

MinidoracatMiniMapClearedCodec = C
