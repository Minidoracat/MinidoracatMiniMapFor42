-- 玩家座標 JSON 匯出（players_<save>.json）離線測試。
-- 兩段：(1) 抽 test:player-export 區段（純字串／表邏輯）打黃金字串與邊界；
-- (2) production boundary——整檔 stub 載入，覆蓋事件掛點／isClient 閘／沙盒閘／
-- 節流／離線差集推導／死亡剔除／同名多角色／讀回繼承與拒絕／寫入靜默失敗抽驗。
-- 保真度限制：本檔跑在本機 Lua（5.4，有 integer 子型別），遊戲跑在 Kahlua（純
-- double，tonumber 走 Double.parseDouble）。差異只影響 Steam64 的一致性檢查——
-- 見下方 S23 的說明；其餘邏輯（字串組裝、pattern、排序、節流）兩邊語意相同。
-- 用法：lua scripts/test_player_export.lua
local exportPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/server/MinidoracatMiniMapPlayerExport.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end

local compile = loadstring or load
local fullSource = readSource(exportPath)
local body = assert(fullSource:match(
    "%-%- test:player%-export:start\n(.-)\n%-%- test:player%-export:end"),
    "找不到 player-export 測試區段")
local seg = assert(compile(body .. [[

return {
    escapeJson = escapeJson,
    numIn = numIn,
    isEscapedJsonBody = isEscapedJsonBody,
    isSteam64 = isSteam64,
    sanitizeVersion = sanitizeVersion,
    buildExportPath = buildExportPath,
    regKey = regKey,
    buildPlayersJson = buildPlayersJson,
    parseHeaderLine = parseHeaderLine,
    parseEntryLine = parseEntryLine,
    parseExportLines = parseExportLines,
    sortSafe = sortSafe,
    pruneRegistry = pruneRegistry,
    mergeEntries = mergeEntries,
    REG_MAX = REG_MAX,
    REG_KEEP = REG_KEEP,
}]], "player-export"))()

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and ("\n  " .. detail) or ""))
    end
end

local function splitLines(s)
    local out, n = {}, 0
    local rest = s
    while true do
        local nl = string.find(rest, "\n", 1, true)
        if not nl then
            n = n + 1
            out[n] = rest
            break
        end
        n = n + 1
        out[n] = string.sub(rest, 1, nl - 1)
        rest = string.sub(rest, nl + 1)
    end
    return out, n
end

--------------------------------------------------------------------------------
-- 黃金字串：在線＋離線混排、行首逗號、末行閉合、負座標、idx、離線完整性欄位
--------------------------------------------------------------------------------
local META = { modversion = "42.20.1-9.9.9", save = "servertest",
    ts = 1755400000000, interval = 5, offlineIncluded = true,
    offlineSince = 1755300000000, offlineTruncated = false }
local entries = {
    { name = "alice", idx = 0, steamId = "76561198012345678", online = true,
      x = 10700, y = 9800, z = 0, seen = 1755400000000 },
    { name = "bob", idx = 1, online = false, x = -5, y = 12, z = -1,
      seen = 1755399000000 },
}
local HEAD_GOLDEN = '{"v":1,"modversion":"42.20.1-9.9.9","save":"servertest",'
    .. '"ts":1755400000000,"interval":5,"offlineAuthority":"observed-subset",'
    .. '"offlineIncluded":true,'
    .. '"offlineSince":1755300000000,"offlineTruncated":false,'
    .. '"online":1,"count":2,"players":['
local golden = table.concat({
    HEAD_GOLDEN,
    '{"name":"alice","idx":0,"steamId":"76561198012345678","online":true,"x":10700,"y":9800,"z":0,"seen":1755400000000}',
    ',{"name":"bob","idx":1,"steamId":"","online":false,"x":-5,"y":12,"z":-1,"seen":1755399000000}',
    ']}',
}, "\n")
local got = seg.buildPlayersJson(entries, 2, 1, META)
check("黃金字串全等", got == golden, "got:\n" .. got .. "\nwant:\n" .. golden)

-- 空清單：header count=0＋末行閉合（工具端讀到空集也能嚴格解析）
check("空清單", seg.buildPlayersJson({}, 0, 0, META) == table.concat({
    (HEAD_GOLDEN:gsub('"online":1,"count":2', '"online":0,"count":0')),
    ']}',
}, "\n"))

-- 離線完整性欄位：關閉離線匯出／曾裁切都要如實反映（消費端據此判斷可信度）
check("offlineIncluded=false", seg.buildPlayersJson({}, 0, 0,
    { modversion = "1.0", save = "s", ts = 1, interval = 5,
      offlineIncluded = false, offlineSince = 2, offlineTruncated = false })
    :find('"offlineIncluded":false,"offlineSince":2,"offlineTruncated":false', 1, true) ~= nil)
check("offlineTruncated=true", seg.buildPlayersJson({}, 0, 0,
    { modversion = "1.0", save = "s", ts = 1, interval = 5,
      offlineIncluded = true, offlineSince = 2, offlineTruncated = true })
    :find('"offlineTruncated":true', 1, true) ~= nil)
-- meta 缺 offlineIncluded 時預設 true（只有顯式 false 才是關閉）
check("offlineIncluded 預設 true", seg.buildPlayersJson({}, 0, 0,
    { modversion = "1.0", save = "s", ts = 1, interval = 5 })
    :find('"offlineIncluded":true,"offlineSince":0,"offlineTruncated":false', 1, true) ~= nil)

-- float 座標／時間戳一律落成整數（Kahlua 印 1.0 會汙染整數語意）
check("float 欄位取整", seg.buildPlayersJson(
    { { name = "a", idx = 1.9, online = true, x = 10.9, y = -3.2, z = 1.5, seen = 5.7 } },
    1, 1, { modversion = "1.0", save = "s", ts = 9.9, interval = 5.5,
            offlineSince = 3.9 })
    :find('{"name":"a","idx":1,"steamId":"","online":true,"x":10,"y":-4,"z":1,"seen":5}', 1, true) ~= nil)

-- builder 不再 escape（呼叫端已轉義）：帶轉義引號的 name 原樣輸出，不變成 \\"
check("builder 不二次轉義", seg.buildPlayersJson(
    { { name = 'a\\"b', idx = 0, online = true, x = 1, y = 2, z = 0, seen = 3 } },
    1, 1, META):find('"name":"a\\"b"', 1, true) ~= nil)

--------------------------------------------------------------------------------
-- escapeJson（無損轉義）／isEscapedJsonBody／numIn／sanitizeVersion／regKey
--------------------------------------------------------------------------------
local function esc(s)
    local out, ok = seg.escapeJson(s)
    return out, ok
end
local ev, eo = esc("alice")
check("escapeJson 正常名不變", ev == "alice" and eo == true)
ev, eo = esc("Minidoracat_01")
check("escapeJson 底線數字不變", ev == "Minidoracat_01" and eo == true)
ev, eo = esc("a\\b")
check("escapeJson 反斜線", ev == "a\\\\b" and eo == true)
ev, eo = esc('a"b')
check("escapeJson 引號", ev == 'a\\"b' and eo == true)
ev, eo = esc('a\\"b')
check("escapeJson 反斜線+引號", ev == 'a\\\\\\"b' and eo == true)
-- 控制字元必須**無損**轉成 \u00xx（舊版直接刪除，會讓在線玩家憑空消失或撞鍵）
ev, eo = esc("a\nb")
check("escapeJson LF→\\u000a", ev == "a\\u000ab" and eo == true, "got " .. tostring(ev))
ev, eo = esc("a\tb")
check("escapeJson TAB→\\u0009", ev == "a\\u0009b" and eo == true, "got " .. tostring(ev))
ev, eo = esc("a\rb")
check("escapeJson CR→\\u000d", ev == "a\\u000db" and eo == true, "got " .. tostring(ev))
ev, eo = esc(string.char(0) .. "x")
check("escapeJson NUL→\\u0000", ev == "\\u0000x" and eo == true, "got " .. tostring(ev))
ev, eo = esc(string.char(31))
check("escapeJson 0x1f→\\u001f", ev == "\\u001f" and eo == true, "got " .. tostring(ev))
ev, eo = esc(string.char(127))
check("escapeJson DEL→\\u007f", ev == "\\u007f" and eo == true, "got " .. tostring(ev))
-- 關鍵回歸：不同的合法 username 轉義後必須仍然不同（舊版刪控制字元會讓
-- "ab\nc" 與 "abc" 撞成同一個 registry 鍵、丟掉一個真實在線玩家）
local c1 = esc("ab\nc")
local c2 = esc("abc")
check("escapeJson 不同名不碰撞", c1 ~= c2, c1 .. " vs " .. c2)
-- 不可表示 → ok=false，呼叫端必須整輪 fail-closed（不是略過那個玩家）
ev, eo = esc("")
check("escapeJson 空字串→ok=false", eo == false)
ev, eo = esc(nil)
check("escapeJson nil→ok=false", eo == false)
ev, eo = esc(42)
check("escapeJson 非字串→ok=false", eo == false)
ev, eo = esc(string.rep("x", 65))
check("escapeJson 超長→ok=false（不截斷）", eo == false)
ev, eo = esc(string.rep("x", 64))
check("escapeJson 剛好上限→ok", eo == true and ev == string.rep("x", 64))
-- 全引號極端：長度翻倍但完全可逆
ev, eo = esc(string.rep('"', 64))
check("escapeJson 全引號", eo == true and ev == string.rep('\\"', 64))
-- 中文（BMP）原樣通過
ev, eo = esc("小明")
check("escapeJson 中文原樣", eo == true and ev == "小明")
-- escapeJson 的輸出恆為合法 JSON 字串內容（同一不變量的兩面）
check("escapeJson 輸出恆通過文法驗證",
    seg.isEscapedJsonBody((esc('a"b\\c')))
    and seg.isEscapedJsonBody((esc(string.rep('"', 64))))
    and seg.isEscapedJsonBody((esc("a\nb")))
    and seg.isEscapedJsonBody((esc(string.char(0)))))

check("文法驗證 純文字", seg.isEscapedJsonBody("alice") == true)
check("文法驗證 轉義引號", seg.isEscapedJsonBody('a\\"b') == true)
check("文法驗證 轉義反斜線", seg.isEscapedJsonBody("a\\\\b") == true)
check("文法驗證 \\uXXXX", seg.isEscapedJsonBody("a\\u000ab") == true)
check("文法驗證 \\u 位數不足→拒", seg.isEscapedJsonBody("a\\u00") == false)
check("文法驗證 \\u 非十六進位→拒", seg.isEscapedJsonBody("a\\uZZZZb") == false)
check("文法驗證 未知轉義→拒", seg.isEscapedJsonBody("a\\xb") == false)
check("文法驗證 裸引號→拒", seg.isEscapedJsonBody('a"b') == false)
check("文法驗證 孤立反斜線→拒", seg.isEscapedJsonBody("a\\b") == false)
check("文法驗證 尾端孤立反斜線→拒", seg.isEscapedJsonBody("ab\\") == false)
check("文法驗證 控制字元→拒", seg.isEscapedJsonBody("a\nb") == false)
check("文法驗證 非字串→拒", seg.isEscapedJsonBody(nil) == false)

-- numIn：位數上限擋掉「400 位數經 tonumber 變 inf、再被寫成 \"x\":inf」
check("numIn 正常", seg.numIn("123", 0, 1000, 4) == 123)
check("numIn 負數", seg.numIn("-5", -32, 31, 2) == -5)
check("numIn 位數超限→nil", seg.numIn(string.rep("9", 400), 0, 4000000000000, 13) == nil)
check("numIn 值域外→nil", seg.numIn("400", 1, 300, 3) == nil
    and seg.numIn("-1", 0, 3, 1) == nil)
check("numIn 非數字→nil", seg.numIn("1e5", 0, 1e9, 8) == nil
    and seg.numIn("abc", 0, 10, 3) == nil
    and seg.numIn("1.5", 0, 10, 3) == nil)
check("numIn 空/非字串→nil", seg.numIn("", 0, 10, 3) == nil
    and seg.numIn(nil, 0, 10, 3) == nil
    and seg.numIn("-", -10, 10, 3) == nil)

check("version nil→unknown", seg.sanitizeVersion(nil) == "unknown")
check("version 空→unknown", seg.sanitizeVersion("") == "unknown")
check("version 消毒", seg.sanitizeVersion('a"b\\c 1.2-3') == "abc1.2-3")
check("version 全異常→unknown", seg.sanitizeVersion('"\\"') == "unknown")

check("regKey 組合", seg.regKey("alice", 0) == "alice#0")
check("regKey idx 取整", seg.regKey("alice", 2.9) == "alice#2")
check("regKey 不碰撞", seg.regKey("a#1", 0) ~= seg.regKey("a", 10)
    and seg.regKey("a#1", 0) == "a#1#0")

--------------------------------------------------------------------------------
-- buildExportPath：存檔名綁檔名、路徑注入防護
--------------------------------------------------------------------------------
check("path 正常", seg.buildExportPath("servertest")
    == "MinidoracatMiniMap/players_servertest.json")
check("path 空→無後綴", seg.buildExportPath("")
    == "MinidoracatMiniMap/players.json")
check("path 非字串→無後綴", seg.buildExportPath(nil)
    == "MinidoracatMiniMap/players.json")
-- 點必須被轉掉：含 .. 的路徑會被 getFileWriter 的 hasRelativePath 拒絕
check("path 點轉底線", seg.buildExportPath("my..save")
    == "MinidoracatMiniMap/players_my__save.json")
check("path 分隔符轉底線", seg.buildExportPath("a/b\\c")
    == "MinidoracatMiniMap/players_a_b_c.json")
check("path 空白轉底線", seg.buildExportPath("My Save")
    == "MinidoracatMiniMap/players_My_Save.json")
check("path 全特殊字元→無後綴", seg.buildExportPath("///")
    == "MinidoracatMiniMap/players.json")
check("path 截斷 48", seg.buildExportPath(string.rep("s", 80))
    == "MinidoracatMiniMap/players_" .. string.rep("s", 48) .. ".json")

--------------------------------------------------------------------------------
-- parse：逐行解析與整份嚴格驗證（round-trip）
--------------------------------------------------------------------------------
local head = seg.parseHeaderLine(splitLines(golden)[1])
check("header 解析", head ~= nil and head.v == 1 and head.save == "servertest"
    and head.ts == 1755400000000 and head.interval == 5 and head.online == 1
    and head.count == 2 and head.modversion == "42.20.1-9.9.9"
    and head.offlineIncluded == true and head.offlineSince == 1755300000000
    and head.offlineTruncated == false)
check("header 壞行→nil", seg.parseHeaderLine('{"v":1}') == nil
    and seg.parseHeaderLine(nil) == nil)
-- 舊格式（無離線完整性欄位）必須被拒：不能讓沒有可信度資訊的檔案偷偷繼承
check("header 舊格式→nil", seg.parseHeaderLine(
    '{"v":1,"modversion":"x","save":"s","ts":1,"interval":5,"online":0,"count":0,"players":[')
    == nil)
check("header 布林欄位非法→nil", seg.parseHeaderLine(
    (HEAD_GOLDEN:gsub('"offlineIncluded":true', '"offlineIncluded":yes'))) == nil)
check("header save 裸引號→nil", seg.parseHeaderLine(
    (HEAD_GOLDEN:gsub('"save":"servertest"', '"save":"ser"vertest"'))) == nil)

local e1 = seg.parseEntryLine(
    '{"name":"alice","idx":0,"steamId":"","online":true,"x":10700,"y":9800,"z":0,"seen":1755400000000}')
check("entry 解析在線", e1 ~= nil and e1.name == "alice" and e1.idx == 0
    and e1.online == true and e1.x == 10700 and e1.y == 9800 and e1.z == 0
    and e1.seen == 1755400000000)
local e2 = seg.parseEntryLine(
    ',{"name":"bob","idx":3,"steamId":"","online":false,"x":-5,"y":12,"z":-1,"seen":9}')
check("entry 解析離線負座標", e2 ~= nil and e2.online == false and e2.x == -5
    and e2.z == -1 and e2.idx == 3)
check("entry 帶轉義引號的名字", seg.parseEntryLine(
    '{"name":"a\\"b","idx":0,"steamId":"","online":true,"x":1,"y":2,"z":0,"seen":3}').name == 'a\\"b')
-- 裸引號的 name 能過欄位錨點，但會讓下一輪寫出非法 JSON ⇒ 必須在讀回時就拒絕
check("entry 裸引號 name→nil", seg.parseEntryLine(
    '{"name":"bad"raw","idx":0,"online":true,"x":1,"y":2,"z":0,"seen":3}') == nil)
check("entry 孤立反斜線 name→nil", seg.parseEntryLine(
    '{"name":"bad\\raw","idx":0,"steamId":"","online":true,"x":1,"y":2,"z":0,"seen":3}') == nil)
check("entry 缺 idx→nil", seg.parseEntryLine(
    '{"name":"a","online":true,"x":1,"y":2,"z":0,"seen":3}') == nil)
check("entry 負 idx→nil", seg.parseEntryLine(
    '{"name":"a","idx":-1,"steamId":"","online":true,"x":1,"y":2,"z":0,"seen":3}') == nil)
check("entry 壞行→nil",
    seg.parseEntryLine('{"name":"a","idx":0,"steamId":"","online":yes,"x":1,"y":2,"z":0,"seen":3}') == nil
    and seg.parseEntryLine('{"name":"","idx":0,"steamId":"","online":true,"x":1,"y":2,"z":0,"seen":3}') == nil
    and seg.parseEntryLine("garbage") == nil)

local gl, gn = splitLines(golden)
local reg, count, rhead = seg.parseExportLines(gl, gn, "servertest")
check("round-trip 繼承筆數", reg ~= nil and count == 2)
check("round-trip 座標與 idx", reg ~= nil and reg["alice#0"].x == 10700
    and reg["bob#1"].z == -1 and reg["bob#1"].seen == 1755399000000
    and reg["bob#1"].idx == 1 and reg["bob#1"].name == "bob")
check("round-trip 回傳 header（供繼承 offlineSince/Truncated）",
    rhead ~= nil and rhead.offlineSince == 1755300000000
    and rhead.offlineTruncated == false)

local badSave = { seg.parseExportLines(gl, gn, "otherworld") }
check("save 不符→拒絕", badSave[1] == nil and badSave[2] == "save mismatch")
check("save 不指定→接受", seg.parseExportLines(gl, gn, nil) ~= nil)

local truncated = { seg.parseExportLines(gl, gn - 1, "servertest") }
check("末行缺失→拒絕", truncated[1] == nil and truncated[2] == "unterminated")

local wrongCount = splitLines((golden:gsub('"count":2', '"count":3')))
check("count 不符→拒絕",
    seg.parseExportLines(wrongCount, #wrongCount, "servertest") == nil)

local badV = splitLines((golden:gsub('"v":1', '"v":2')))
check("v 不符→拒絕", seg.parseExportLines(badV, #badV, "servertest") == nil)

local badEntry = { gl[1], "garbage", gl[3], gl[4] }
check("壞條目→整份拒絕",
    seg.parseExportLines(badEntry, 4, "servertest") == nil)
check("太短→拒絕", seg.parseExportLines({ gl[1] }, 1, "servertest") == nil)

-- 同一 username 不同 idx 是**兩個角色**，讀回不可塌成一筆（塌縮＝丟座標＝漏報）
local twinLines = {
    HEAD_GOLDEN,
    '{"name":"twin","idx":0,"steamId":"","online":false,"x":100,"y":200,"z":0,"seen":5}',
    ',{"name":"twin","idx":1,"steamId":"","online":false,"x":900,"y":800,"z":1,"seen":6}',
    ']}',
}
local twinReg, twinN = seg.parseExportLines(twinLines, 4, "servertest")
check("同名不同 idx 不塌縮", twinReg ~= nil and twinN == 2
    and twinReg["twin#0"] ~= nil and twinReg["twin#1"] ~= nil
    and twinReg["twin#0"].x == 100 and twinReg["twin#1"].x == 900)

--------------------------------------------------------------------------------
-- sortSafe：迭代 merge sort（家規禁 table.sort——Kahlua 的遞迴 quicksort 在
-- 已排序輸入上退化 O(n) 深度、數百筆即撞 coroutine 堆疊上限）
--------------------------------------------------------------------------------
local function keys(t, n)
    local o = {}
    for i = 1, n do o[i] = tostring(t[i].k) end
    return table.concat(o, ",")
end
local asc = function(a, b) return a.k < b.k end

local one = { { k = 1 } }
seg.sortSafe(one, 1, asc)
check("sortSafe 單筆不動", keys(one, 1) == "1")
seg.sortSafe({}, 0, asc)
check("sortSafe 空不炸", true)

local rev = {}
for i = 10, 1, -1 do rev[11 - i] = { k = i } end
seg.sortSafe(rev, 10, asc)
check("sortSafe 反序", keys(rev, 10) == "1,2,3,4,5,6,7,8,9,10")

local odd = { { k = 3 }, { k = 1 }, { k = 2 }, { k = 5 }, { k = 4 }, { k = 7 }, { k = 6 } }
seg.sortSafe(odd, 7, asc)
check("sortSafe 奇數長度（width 邊界）", keys(odd, 7) == "1,2,3,4,5,6,7")

-- 已排序 2000 筆＝Kahlua quicksort 的退化／溢位情境，正是本功能 registry 上限
local pre, preOk = {}, true
for i = 1, 2000 do pre[i] = { k = i } end
seg.sortSafe(pre, 2000, asc)
for i = 1, 2000 do
    if pre[i].k ~= i then preOk = false end
end
check("sortSafe 2000 筆已排序輸入", preOk)

-- 穩定性：等價元素保留原序（輸出逐 byte 穩定的前提）
local stable = { { k = 1, id = "a" }, { k = 1, id = "b" }, { k = 0, id = "c" },
    { k = 1, id = "d" } }
seg.sortSafe(stable, 4, asc)
check("sortSafe 穩定（同鍵保留原序）", stable[1].id == "c" and stable[2].id == "a"
    and stable[3].id == "b" and stable[4].id == "d")

--------------------------------------------------------------------------------
-- pruneRegistry：未超限不動、超限保留 seen 最新的 keep 筆並回報裁切
--------------------------------------------------------------------------------
local small = { ["a#0"] = { seen = 1 }, ["b#0"] = { seen = 2 } }
local smallN, smallTrunc = seg.pruneRegistry(small, 2, 1)
check("prune 未超限不動", smallN == 2 and smallTrunc == false
    and small["a#0"] ~= nil and small["b#0"] ~= nil)

local big, bigN = {}, 0
for i = 1, seg.REG_MAX + 5 do
    bigN = bigN + 1
    big["p" .. i .. "#0"] = { name = "p" .. i, idx = 0, x = i, y = i, z = 0, seen = i }
end
local kept, trunc = seg.pruneRegistry(big, bigN, seg.REG_KEEP)
local remain = 0
for _ in pairs(big) do remain = remain + 1 end
check("prune 超限裁到 keep", kept == seg.REG_KEEP and remain == seg.REG_KEEP)
check("prune 回報裁切（供 offlineTruncated）", trunc == true)
check("prune 保留最新", big["p" .. (seg.REG_MAX + 5) .. "#0"] ~= nil
    and big["p1#0"] == nil)

--------------------------------------------------------------------------------
-- mergeEntries：在線覆蓋 registry、離線納入／排除、(name, idx) 排序
--------------------------------------------------------------------------------
local mreg = {
    ["alice#0"] = { name = "alice", idx = 0, x = 1, y = 1, z = 0, seen = 100 },
    ["zed#0"] = { name = "zed", idx = 0, x = 7, y = 7, z = 2, seen = 200 },
    ["bob#0"] = { name = "bob", idx = 0, x = 3, y = 4, z = 1, seen = 300 },
    ["bob#1"] = { name = "bob", idx = 1, x = 55, y = 66, z = 0, seen = 310 },
}
local mOnline = { { name = "alice", idx = 0, x = 50, y = 60, z = 3 } }
local me, mn, mo = seg.mergeEntries(mOnline, 1, mreg, true, 999)
check("merge 筆數", mn == 4 and mo == 1)
check("merge (name, idx) 升序", me[1].name == "alice" and me[2].name == "bob"
    and me[2].idx == 0 and me[3].name == "bob" and me[3].idx == 1
    and me[4].name == "zed")
check("merge 在線用即時座標與 now", me[1].online == true and me[1].x == 50
    and me[1].seen == 999)
check("merge 離線用 registry 座標與舊 seen", me[2].online == false
    and me[2].x == 3 and me[2].seen == 300)
check("merge 同名不同 idx 都保留", me[3].x == 55 and me[3].seen == 310)
local oe, on, oo = seg.mergeEntries(mOnline, 1, mreg, false, 999)
check("merge 關閉離線只留在線", on == 1 and oo == 1 and oe[1].name == "alice")
-- 在線筆與 registry 同鍵時不得重複輸出（否則 count 會膨脹、消費端 count 檢查失敗）
local dupOnline = { { name = "bob", idx = 1, x = 11, y = 22, z = 0 } }
local de, dn = seg.mergeEntries(dupOnline, 1, mreg, true, 999)
check("merge 在線覆蓋同鍵離線筆", dn == 4)

--------------------------------------------------------------------------------
-- isSteam64：格式閘門（17 位、不小於 individual account 區段起點）。
-- 固定長度所以用字串比較，不轉數字——Steam64 約 7.66e16，Kahlua/Lua 的 number 是
-- double，該量級 ULP 是 16，轉了就失精。
--------------------------------------------------------------------------------
check("steam64 合法", seg.isSteam64("76561198012345678") == true)
check("steam64 區段下界", seg.isSteam64("76561197960265728") == true)
check("steam64 低於下界→拒", seg.isSteam64("76561197960265727") == false)
check("steam64 16 位→拒", seg.isSteam64("7656119801234567") == false)
check("steam64 18 位→拒", seg.isSteam64("765611980123456789") == false)
check("steam64 含非數字→拒", seg.isSteam64("7656119801234567a") == false)
check("steam64 空/非字串→拒", seg.isSteam64("") == false
    and seg.isSteam64(nil) == false and seg.isSteam64(76561198012345678) == false)

-- builder：非法或缺席的 steamId 一律輸出空字串，不會把垃圾寫進檔案
check("builder steamId 非法→空", seg.buildPlayersJson(
    { { name = "a", idx = 0, steamId = "123", online = true, x = 1, y = 2, z = 0, seen = 3 } },
    1, 1, META):find('"steamId":""', 1, true) ~= nil)
check("builder steamId 缺席→空", seg.buildPlayersJson(
    { { name = "a", idx = 0, online = true, x = 1, y = 2, z = 0, seen = 3 } },
    1, 1, META):find('"steamId":""', 1, true) ~= nil)

-- parseEntryLine：空字串合法（非 Steam 伺服器／沒回報過），非法值整份拒絕
local se = seg.parseEntryLine(
    '{"name":"a","idx":0,"steamId":"76561198012345678","online":true,"x":1,"y":2,"z":0,"seen":3}')
check("entry 解析 steamId", se ~= nil and se.steamId == "76561198012345678")
local se2 = seg.parseEntryLine(
    '{"name":"a","idx":0,"steamId":"","online":true,"x":1,"y":2,"z":0,"seen":3}')
check("entry steamId 空合法", se2 ~= nil and se2.steamId == "")
check("entry steamId 非法→nil", seg.parseEntryLine(
    '{"name":"a","idx":0,"steamId":"123","online":true,"x":1,"y":2,"z":0,"seen":3}') == nil)
check("entry steamId 缺欄位→nil", seg.parseEntryLine(
    '{"name":"a","idx":0,"online":true,"x":1,"y":2,"z":0,"seen":3}') == nil)

-- merge 要把 steamId 一路帶到輸出（在線用本輪值、離線用 registry 存的值）
local sreg = { ["off#0"] = { name = "off", idx = 0, steamId = "76561198000000002",
    x = 1, y = 1, z = 0, seen = 5 } }
local son = { { name = "on", idx = 0, steamId = "76561198000000001", x = 2, y = 2, z = 0 } }
local sme, smn = seg.mergeEntries(son, 1, sreg, true, 99)
check("merge 帶 steamId", smn == 2
    and sme[1].name == "off" and sme[1].steamId == "76561198000000002"
    and sme[2].name == "on" and sme[2].steamId == "76561198000000001")

--------------------------------------------------------------------------------
-- production boundary：整檔 stub 載入
--------------------------------------------------------------------------------
local PRELUDE = [==[
local written, writeCount = {}, 0
local writerAvailable, writeShouldFail, writeSilentFail = true, false, false
local writePartial = false
local logs = {}
local isClientVal, isServerVal = false, true
local nowVal = 1000000
local saveVal = "servertest"
local playersList = {}
local sandbox = { ExportPlayerPositions = true, PlayerExportInterval = 5,
    ExportOfflinePlayers = true }
local SandboxVars = { MinidoracatMiniMap = sandbox }
local onServerStarted, onGameStart, onTick, onClientCmd = {}, {}, {}, {}
local serverCommands = {}
local Events = {
    OnServerStarted = { Add = function(f) onServerStarted[#onServerStarted + 1] = f end },
    OnGameStart = { Add = function(f) onGameStart[#onGameStart + 1] = f end },
    OnTickEvenPaused = { Add = function(f) onTick[#onTick + 1] = f end },
    OnClientCommand = { Add = function(f) onClientCmd[#onClientCmd + 1] = f end },
}
local function sendServerCommand(player, module, command, args)
    serverCommands[#serverCommands + 1] = { module = module, command = command,
        idx = args and args.idx }
end
local function isClient() return isClientVal end
local function isServer() return isServerVal end
local function getTimestampMs() return nowVal end
local function print(s) logs[#logs + 1] = tostring(s) end
local function getWorld() return { getWorld = function() return saveVal end } end
local function getModInfoByID(id)
    if id ~= "MinidoracatMiniMapFor42" then return nil end
    return { getModVersion = function() return "42.20.1-9.9.9" end }
end
local function mkPlayer(p)
    return {
        getUsername = function() return p.name end,
        getPlayerNum = function() return p.idx or 0 end,
        -- 真實引擎回 Java long，經 Kahlua 必成 double；標準 Lua 的 number 同樣是
        -- double，所以這個 stub 的精度行為與遊戲內一致
        getSteamID = function()
            if p.steam64 == nil then return 0 end
            return tonumber(p.steam64)
        end,
        getX = function() return p.x end,
        getY = function() return p.y end,
        getZ = function() return p.z or 0 end,
        isDead = function() return p.dead == true end,
    }
end
local function getOnlinePlayers()
    local arr = {}
    for i = 1, #playersList do arr[i] = mkPlayer(playersList[i]) end
    return {
        size = function() return #arr end,
        get = function(_, i) return arr[i + 1] end,
    }
end
local function getNumActivePlayers() return #playersList end
local function getSpecificPlayer(i)
    local p = playersList[i + 1]
    if not p then return nil end
    return mkPlayer(p)
end
local function getFileWriter(path, createIfNull, append)
    if not writerAvailable then return nil end
    local buf = {}
    return {
        -- 模擬真實 LuaFileWriter：write 失敗＝內容沒進去；close 永遠落檔。
        -- writeSilentFail 模擬 PrintWriter 內吞 IO 錯誤（磁碟滿／唯讀）：
        -- 兩個呼叫都不拋，但檔案內容完全沒有更新。
        write = function(_, s)
            if writeShouldFail then error("disk full") end
            if writePartial then
                -- 磁碟滿在中途：只有第一行（header）落檔，後續條目與 ]} 全丟
                local nl = string.find(s, "\n", 1, true)
                buf[#buf + 1] = nl and string.sub(s, 1, nl - 1) or s
                return
            end
            buf[#buf + 1] = s
        end,
        close = function(_)
            if writeSilentFail then return end
            written[path] = table.concat(buf)
            writeCount = writeCount + 1
        end,
    }
end
local function getFileReader(path, createIfNull)
    local content = written[path]
    if content == nil then return nil end
    local rest = content
    if rest == "" then rest = nil end
    return {
        readLine = function(_)
            if rest == nil then return nil end
            local nl = string.find(rest, "\n", 1, true)
            if nl then
                local line = string.sub(rest, 1, nl - 1)
                rest = string.sub(rest, nl + 1)
                return line
            end
            local line = rest
            rest = nil
            return line
        end,
        close = function(_) end,
    }
end
]==]
local CONTROLS = [==[
return {
    fireServer = function()
        for i = 1, #onServerStarted do onServerStarted[i]() end
    end,
    fireGame = function()
        for i = 1, #onGameStart do onGameStart[i]() end
    end,
    tick = function()
        for i = 1, #onTick do onTick[i]() end
    end,
    clientCmd = function(playerIdx, command, args)
        local p = playersList[playerIdx + 1]
        local obj = p and mkPlayer(p) or nil
        for i = 1, #onClientCmd do
            onClientCmd[i]("MinidoracatMiniMap", command, obj, args)
        end
    end,
    serverCommands = serverCommands,
    written = written,
    logs = logs,
    tickCount = function() return #onTick end,
    writeCount = function() return writeCount end,
    set = function(k, v)
        if k == "isClient" then isClientVal = v
        elseif k == "isServer" then isServerVal = v
        elseif k == "now" then nowVal = v
        elseif k == "save" then saveVal = v
        elseif k == "players" then playersList = v
        elseif k == "writer" then writerAvailable = v
        elseif k == "writeFail" then writeShouldFail = v
        elseif k == "writeSilentFail" then writeSilentFail = v
        elseif k == "writePartial" then writePartial = v
        elseif k == "sandbox" then
            for kk, vv in pairs(v) do sandbox[kk] = vv end
        end
    end,
}
]==]
local function makeHarness()
    return assert(compile(PRELUDE .. fullSource .. "\n" .. CONTROLS,
        "player-export-boundary"))()
end
local function hasLog(h, needle)
    for i = 1, #h.logs do
        if h.logs[i]:find(needle, 1, true) then return true end
    end
    return false
end
local function countLog(h, needle)
    local c = 0
    for i = 1, #h.logs do
        if h.logs[i]:find(needle, 1, true) then c = c + 1 end
    end
    return c
end
local PATH = "MinidoracatMiniMap/players_servertest.json"
-- 以 (name, idx) 為鍵——刻意不用 name，否則同名多角色會被測試自己遮掉
local function parseOut(h, path)
    local text = h.written[path or PATH]
    if not text then return nil end
    local lines, n = splitLines(text)
    local hd = seg.parseHeaderLine(lines[1])
    local byKey, rows = {}, 0
    for i = 2, n - 1 do
        local e = seg.parseEntryLine(lines[i])
        if e then
            rows = rows + 1
            byKey[seg.regKey(e.name, e.idx)] = e
        end
    end
    return hd, byKey, text, rows
end

-- S1 dedicated：OnServerStarted 掛 tick、寫檔路徑帶存檔名、內容含在線玩家
local h = makeHarness()
h.set("players", { { name = "alice", idx = 0, x = 10700.7, y = 9800.2, z = 0 } })
h.fireServer()
check("S1 掛上 tick", h.tickCount() == 1)
check("S1 尚未寫檔（tick 前）", h.written[PATH] == nil)
h.tick()
local hd, byKey = parseOut(h)
check("S1 檔名帶存檔名", hd ~= nil)
check("S1 metadata", hd ~= nil and hd.v == 1 and hd.save == "servertest"
    and hd.modversion == "42.20.1-9.9.9" and hd.interval == 5
    and hd.ts == 1000000 and hd.online == 1 and hd.count == 1)
check("S1 首次啟用 offlineSince＝當下、未截斷、含離線",
    hd.offlineSince == 1000000 and hd.offlineTruncated == false
    and hd.offlineIncluded == true)
check("S1 座標取整", byKey and byKey["alice#0"] ~= nil
    and byKey["alice#0"].x == 10700 and byKey["alice#0"].y == 9800
    and byKey["alice#0"].online == true and byKey["alice#0"].seen == 1000000)
check("S1 armed log", hasLog(h, "player position export armed"))
check("S1 無舊檔 log", hasLog(h, "no previous players file"))

-- S2 沙盒關閉：掛了 tick 但不寫任何東西
h = makeHarness()
h.set("sandbox", { ExportPlayerPositions = false })
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
check("S2 沙盒關閉不寫", h.written[PATH] == nil and h.writeCount() == 0)
-- 開啟後立刻補寫（節流器不因關閉期間空轉而延後）
h.set("sandbox", { ExportPlayerPositions = true })
h.tick()
check("S2 開啟後立即寫", h.written[PATH] ~= nil)

-- S3 MP 純 client：OnGameStart 不啟動、完全不掛 tick
h = makeHarness()
h.set("isClient", true)
h.set("isServer", false)
h.fireGame()
check("S3 client 不掛 tick", h.tickCount() == 0)
check("S3 client 無 log", #h.logs == 0)

-- S4 節流：interval 內重複 tick 不重寫；跨過 interval 才寫
h = makeHarness()
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
check("S4 首次寫", h.writeCount() == 1)
h.set("now", 1000000 + 4999)
h.tick()
check("S4 未到期不寫", h.writeCount() == 1)
h.set("now", 1000000 + 5000)
h.tick()
check("S4 到期寫", h.writeCount() == 2)
-- interval 改動即時生效
h.set("sandbox", { PlayerExportInterval = 1 })
h.set("now", 1000000 + 6000)
h.tick()
local hd4 = parseOut(h)
check("S4 interval 即時生效", h.writeCount() == 3 and hd4.interval == 1)
-- 沙盒被塞進值域外的值時夾回 1-300（契約要求 interval 一定落在值域內）
h.set("sandbox", { PlayerExportInterval = 9999 })
h.set("now", 1000000 + 400000)
h.tick()
check("S4 interval 上限夾住", parseOut(h).interval == 300)
-- 下限同樣要夾（0 或負值會讓節流失效、變成每 tick 寫檔）
h.set("sandbox", { PlayerExportInterval = 0 })
h.set("now", 1000000 + 800000)
h.tick()
check("S4 interval 下限夾住", parseOut(h).interval == 1)

-- S4b 系統時鐘被往回調：不能卡死到真實時間追上為止
h = makeHarness()
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
h.set("now", 1000000 - 60000)
h.tick()
check("S4b 時鐘回跳仍匯出", h.writeCount() == 2)

-- S5 離線差集推導：玩家離線後保留最後座標與觀測時間
h = makeHarness()
h.set("players", { { name = "alice", idx = 0, x = 100, y = 200, z = 1 },
    { name = "bob", idx = 0, x = 300, y = 400, z = 0 } })
h.fireServer()
h.tick()
h.set("players", { { name = "bob", idx = 0, x = 333, y = 444, z = 0 } })
h.set("now", 1000000 + 9000)
h.tick()
local hd5, by5 = parseOut(h)
check("S5 離線筆保留舊座標與 seen", by5["alice#0"] ~= nil
    and by5["alice#0"].online == false
    and by5["alice#0"].x == 100 and by5["alice#0"].y == 200
    and by5["alice#0"].z == 1 and by5["alice#0"].seen == 1000000)
check("S5 在線筆更新", by5["bob#0"].online == true and by5["bob#0"].x == 333
    and by5["bob#0"].seen == 1000000 + 9000)
check("S5 計數", hd5.count == 2 and hd5.online == 1)

-- S6 死亡玩家：不列入，且從 registry 移除（不會以離線身分復活）
h = makeHarness()
h.set("players", { { name = "alice", idx = 0, x = 10, y = 20, z = 0 } })
h.fireServer()
h.tick()
h.set("players", { { name = "alice", idx = 0, x = 10, y = 20, z = 0, dead = true } })
h.set("now", 1000000 + 9000)
h.tick()
local hd6, by6 = parseOut(h)
check("S6 死亡剔除", hd6.count == 0 and hd6.online == 0 and by6["alice#0"] == nil)

-- S7 讀回繼承：啟動前已有合法檔（save 相符）→ 離線歷史與 offlineSince 延續
h = makeHarness()
h.written[PATH] = seg.buildPlayersJson(
    { { name = "carol", idx = 0, online = false, x = 77, y = 88, z = 2, seen = 500 } },
    1, 0, { modversion = "42.20.1-9.9.9", save = "servertest", ts = 500,
            interval = 5, offlineIncluded = true, offlineSince = 400,
            offlineTruncated = false })
h.fireServer()
check("S7 讀回成功 log", hasLog(h, "read-back ok (1 known players"))
h.tick()
local hd7, by7 = parseOut(h)
check("S7 繼承的離線玩家仍在", by7["carol#0"] ~= nil
    and by7["carol#0"].online == false and by7["carol#0"].x == 77
    and by7["carol#0"].seen == 500 and hd7.count == 1)
check("S7 offlineSince 延續（不被重設成當下）", hd7.offlineSince == 400)

-- S7b 讀回繼承 offlineTruncated：一旦截過就永久標記，不因重啟洗白
h = makeHarness()
h.written[PATH] = seg.buildPlayersJson({}, 0, 0,
    { modversion = "42.20.1-9.9.9", save = "servertest", ts = 500, interval = 5,
      offlineIncluded = true, offlineSince = 400, offlineTruncated = true })
h.fireServer()
h.tick()
check("S7b offlineTruncated 延續", parseOut(h).offlineTruncated == true)

-- S8 讀回拒絕：save 不符／撕裂檔／裸引號一律不繼承，且 offlineSince 重設成當下
-- （＝告訴消費端「早於此刻登出的角色不在清單裡」，這是唯一誠實的降級標記）
h = makeHarness()
h.written[PATH] = seg.buildPlayersJson(
    { { name = "carol", idx = 0, online = false, x = 77, y = 88, z = 2, seen = 500 } },
    1, 0, { modversion = "42.20.1-9.9.9", save = "otherworld", ts = 500,
            interval = 5, offlineIncluded = true, offlineSince = 400,
            offlineTruncated = false })
h.fireServer()
check("S8 save 不符→拒絕", hasLog(h, "read-back rejected"))
check("S8 拒絕時明示離線歷史重啟", hasLog(h, "offline history RESTARTS"))
h.tick()
local hd8, by8 = parseOut(h)
check("S8 不繼承", hd8.count == 0 and by8["carol#0"] == nil)
check("S8 offlineSince 重設成當下（消費端可辨識歷史斷裂）",
    hd8.offlineSince == 1000000)

h = makeHarness()
h.written[PATH] = HEAD_GOLDEN .. '\n{"name":"carol","idx":0,"steamId":"","online":false,"x":77,"y":88,"z":2,"seen":500}'
h.fireServer()
check("S8b 撕裂檔→拒絕", hasLog(h, "read-back rejected"))

h = makeHarness()
h.written[PATH] = table.concat({
    (HEAD_GOLDEN:gsub('"online":1,"count":2', '"online":0,"count":1')),
    '{"name":"bad"raw","idx":0,"online":false,"x":1,"y":2,"z":0,"seen":5}',
    ']}',
}, "\n")
h.fireServer()
check("S8c 裸引號 name→整份拒絕（不會再寫出非法 JSON）",
    hasLog(h, "read-back rejected"))
h.tick()
local _, _, text8c = parseOut(h)
check("S8c 下一輪輸出仍是合法 JSON",
    text8c ~= nil and text8c:find('bad"raw', 1, true) == nil)

-- S9 writer 缺席：STALE 警告只出現一次（不 spam log），恢復後出 recovered
h = makeHarness()
h.set("writer", false)
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
h.set("now", 1000000 + 9000)
h.tick()
check("S9 STALE 只 log 一次", countLog(h, "STALE") == 1)
check("S9 未寫檔", h.written[PATH] == nil)
h.set("writer", true)
h.set("now", 1000000 + 18000)
h.tick()
check("S9 恢復 log", hasLog(h, "players export recovered"))
check("S9 恢復後有檔", h.written[PATH] ~= nil)

-- S10 寫入中途拋錯（截斷檔）：不炸 tick、留下 TORN 警告
h = makeHarness()
h.set("writeFail", true)
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
check("S10 寫入失敗警告", hasLog(h, "TORN"))

-- S10b 靜默寫入失敗（PrintWriter 吞 IO）：低頻抽驗必須抓到並大聲說
h = makeHarness()
h.set("writeSilentFail", true)
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
check("S10b 靜默失敗被抽驗抓到", hasLog(h, "write-back verify FAILED"))
check("S10b 確實沒落檔", h.written[PATH] == nil)
check("S10b 只 log 一次", countLog(h, "write-back verify FAILED") == 1)
-- 恢復後（下一次抽驗到期）要回報 recovered
h.set("writeSilentFail", false)
h.set("now", 1000000 + 300000)
h.tick()
check("S10b 恢復後 verified log", hasLog(h, "recovered (write verified)"))

-- S11 關閉離線匯出：只剩在線筆，且 offlineIncluded 標成 false
h = makeHarness()
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 },
    { name = "bob", idx = 0, x = 3, y = 4, z = 0 } })
h.fireServer()
h.tick()
h.set("sandbox", { ExportOfflinePlayers = false })
h.set("players", { { name = "bob", idx = 0, x = 3, y = 4, z = 0 } })
h.set("now", 1000000 + 9000)
h.tick()
local hd11, by11 = parseOut(h)
check("S11 只匯出在線", hd11.count == 1 and hd11.online == 1
    and by11["bob#0"] ~= nil and by11["alice#0"] == nil)
check("S11 offlineIncluded=false（消費端知道離線筆被關掉）",
    hd11.offlineIncluded == false)

-- S12 單機（isServer=false，OnGameStart）：走 getNumActivePlayers/getSpecificPlayer
h = makeHarness()
h.set("isServer", false)
h.set("players", { { name = "Bob Smith", idx = 0, x = 55.9, y = 66.1, z = 0 } })
h.fireGame()
check("S12 單機掛 tick", h.tickCount() == 1)
h.tick()
local hd12, by12 = parseOut(h)
check("S12 單機寫檔", hd12 ~= nil and hd12.count == 1
    and by12["Bob Smith#0"] ~= nil and by12["Bob Smith#0"].x == 55)

-- S13 存檔名取不到／異常：檔名退回無後綴、save 欄位為空（工具端比對必失敗）
h = makeHarness()
h.set("save", "")
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
local hd13 = parseOut(h, "MinidoracatMiniMap/players.json")
check("S13 退回無後綴檔名", hd13 ~= nil and hd13.save == "")

-- S14 存檔名含危險字元：檔名消毒、save 欄位保留原名的轉義形式
h = makeHarness()
h.set("save", "my..save")
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
local hd14 = parseOut(h, "MinidoracatMiniMap/players_my__save.json")
check("S14 檔名消毒", hd14 ~= nil and hd14.save == "my..save")

-- S15 username 含 JSON 危險字元：轉義後仍是合法單行，解析回得同一鍵
h = makeHarness()
h.set("players", { { name = 'ev"il\\', idx = 0, x = 9, y = 9, z = 0 } })
h.fireServer()
h.tick()
local hd15, by15, text15 = parseOut(h)
check("S15 危險名不破壞結構", hd15 ~= nil and hd15.count == 1
    and by15['ev\\"il\\\\#0'] ~= nil,
    "text:\n" .. tostring(text15))

-- S16 同機分屏同名多角色：兩個 slot 分處兩地，在線／離線／跨重啟都不可塌成一筆
-- （塌縮＝丟掉一個真實玩家座標＝對破壞性消費端是漏報，最危險的方向）
h = makeHarness()
h.set("players", { { name = "twin", idx = 0, x = 100, y = 200, z = 0 },
    { name = "twin", idx = 1, x = 900, y = 800, z = 1 } })
h.fireServer()
h.tick()
local hd16, by16, _, rows16 = parseOut(h)
check("S16 在線同名兩筆都在", hd16.count == 2 and hd16.online == 2 and rows16 == 2
    and by16["twin#0"].x == 100 and by16["twin#1"].x == 900)
-- 兩人都離線後仍是兩筆
h.set("players", {})
h.set("now", 1000000 + 9000)
h.tick()
local hd16b, by16b, _, rows16b = parseOut(h)
check("S16 離線後同名仍兩筆", hd16b.count == 2 and hd16b.online == 0
    and rows16b == 2 and by16b["twin#0"].x == 100 and by16b["twin#1"].x == 900
    and by16b["twin#0"].online == false)
-- 跨重啟讀回仍是兩筆（registry 鍵含 idx 的完整驗證）
local carry = h.written[PATH]
h = makeHarness()
h.written[PATH] = carry
h.fireServer()
check("S16 重啟讀回兩筆", hasLog(h, "read-back ok (2 known players"))
h.set("now", 2000000)
h.tick()
local hd16c, by16c = parseOut(h)
check("S16 重啟後座標未混淆", hd16c.count == 2
    and by16c["twin#0"].x == 100 and by16c["twin#1"].x == 900)


-- S17 在線玩家的 username 無法無損寫出（控制字元 ＋ CTRL_ESCAPE 建表失敗的極端）：
-- 必須 abort 整輪、保留舊檔（讓工具靠 ts 過期擋下），絕不寫出少一個人的清單
h = makeHarness()
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
local before17 = h.written[PATH]
check("S17 前置：正常寫出", before17 ~= nil)
-- 超長 username（>64）在 escapeJson 是「不可表示」
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 },
    { name = string.rep("L", 65), idx = 0, x = 9, y = 9, z = 0 } })
h.set("now", 1000000 + 9000)
h.tick()
check("S17 abort：檔案未被覆寫", h.written[PATH] == before17)
check("S17 abort log", hasLog(h, "players export ABORTED"))
check("S17 abort 原因含 not representable",
    hasLog(h, "username not representable"))
-- 玩家離開後恢復正常寫出
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.set("now", 1000000 + 20000)
h.tick()
check("S17 恢復後寫出", h.written[PATH] ~= before17)

-- S17b 控制字元 username 是引擎允許的（primary 只擋 " \\ / . ? 等、coop 更寬），
-- 必須無損寫出、不得消失也不得與別人撞鍵
h = makeHarness()
h.set("players", { { name = "ab\nc", idx = 0, x = 11, y = 22, z = 0 },
    { name = "abc", idx = 0, x = 33, y = 44, z = 0 } })
h.fireServer()
h.tick()
local hd17, by17, text17, rows17 = parseOut(h)
check("S17b 兩人都在（無損、不碰撞）", hd17 ~= nil and hd17.count == 2
    and hd17.online == 2 and rows17 == 2, "text:\n" .. tostring(text17))
check("S17b 控制字元寫成 \\u000a",
    text17 ~= nil and text17:find('"name":"ab\\u000ac"', 1, true) ~= nil)

-- S18 partial write（header 落檔、條目與 ]} 被截斷）：只驗首行的抽驗會誤判成功，
-- 整份重新解析才抓得到
h = makeHarness()
h.set("writePartial", true)
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
check("S18 partial 檔已落地但不完整",
    h.written[PATH] ~= nil and h.written[PATH]:find("]}", 1, true) == nil)
check("S18 抽驗抓到 partial write", hasLog(h, "write-back verify FAILED"))

-- S19 讀回的檔案本身 offlineIncluded=false：不可延續它的 offlineSince
-- （那份檔沒有離線筆，延續起點等於假裝歷史完整）
h = makeHarness()
h.written[PATH] = seg.buildPlayersJson({}, 0, 0,
    { modversion = "42.20.1-9.9.9", save = "servertest", ts = 500, interval = 5,
      offlineIncluded = false, offlineSince = 400, offlineTruncated = false })
h.fireServer()
h.tick()
local hd19 = parseOut(h)
check("S19 offlineSince 不延續（重設為當下）", hd19.offlineSince == 1000000)

-- S20 在線清單出現重複 (name, idx)：資料不可信，abort 整輪而不是靜默去重
h = makeHarness()
h.set("players", { { name = "dup", idx = 0, x = 1, y = 2, z = 0 },
    { name = "dup", idx = 0, x = 500, y = 600, z = 0 } })
h.fireServer()
h.tick()
check("S20 重複鍵 abort", h.written[PATH] == nil
    and hasLog(h, "duplicate (name, idx) key"))

-- S21 讀回檔案含重複 (name, idx)：整份拒絕（不可靜默去重）
h = makeHarness()
h.written[PATH] = table.concat({
    (HEAD_GOLDEN:gsub('"online":1,"count":2', '"online":0,"count":2')),
    '{"name":"dup","idx":0,"steamId":"","online":false,"x":1,"y":2,"z":0,"seen":5}',
    ',{"name":"dup","idx":0,"steamId":"","online":false,"x":9,"y":9,"z":0,"seen":6}',
    ']}',
}, "\n")
h.fireServer()
check("S21 讀回重複鍵→拒絕", hasLog(h, "read-back rejected"))


-- S22 Steam64 回報：伺服器做格式＋一致性檢查（把回報字串 tonumber 後與
-- p:getSteamID() 比對——兩邊都是同一個 long 的 double 投影）
h = makeHarness()
h.set("players", { { name = "alice", idx = 0, x = 1, y = 2, z = 0,
    steam64 = "76561198012345678" } })
h.fireServer()
h.tick()
check("S22 尚未回報時 steamId 為空",
    (select(2, parseOut(h)))["alice#0"].steamId == "")
-- 正確回報 → 接受、寫進檔案、並回 ack
h.clientCmd(0, "reportSteamId", { steamId = "76561198012345678" })
check("S22 accepted log", hasLog(h, "steamId accepted for alice#0"))
check("S22 成功才回 ack，且帶 slot", #h.serverCommands == 1
    and h.serverCommands[1].command == "steamIdAck"
    and h.serverCommands[1].idx == 0)
h.set("now", 1000000 + 9000)
h.tick()
local hd22, by22 = parseOut(h)
check("S22 steamId 寫進檔案",
    by22["alice#0"].steamId == "76561198012345678")

-- 回報「別人的」ID（不同 double bucket）→ 拒絕，欄位不被汙染
h = makeHarness()
h.set("players", { { name = "bob", idx = 0, x = 1, y = 2, z = 0,
    steam64 = "76561198012345678" } })
h.fireServer()
h.tick()
h.clientCmd(0, "reportSteamId", { steamId = "76561198099999999" })
check("S22 不符→拒絕 log", hasLog(h, "steamId report rejected"))
h.set("now", 1000000 + 9000)
h.tick()
check("S22 拒絕後仍為空",
    (select(2, parseOut(h)))["bob#0"].steamId == "")
check("S22 不符時不回 ack", #h.serverCommands == 0)

-- 格式非法（16 位）→ 直接無聲丟棄（連 rejected log 都不需要，格式閘門先擋）
h = makeHarness()
h.set("players", { { name = "carol", idx = 0, x = 1, y = 2, z = 0,
    steam64 = "76561198012345678" } })
h.fireServer()
h.tick()
h.clientCmd(0, "reportSteamId", { steamId = "7656119801234567" })
h.set("now", 1000000 + 9000)
h.tick()
check("S22 格式非法不寫入",
    (select(2, parseOut(h)))["carol#0"].steamId == "")
check("S22 格式非法不留 accepted log", not hasLog(h, "steamId accepted"))
check("S22 格式非法不回 ack", #h.serverCommands == 0)
-- 非 Steam 伺服器（getSteamID()==0）：任何回報都不接受
h = makeHarness()
h.set("players", { { name = "dave", idx = 0, x = 1, y = 2, z = 0 } })
h.fireServer()
h.tick()
h.clientCmd(0, "reportSteamId", { steamId = "76561198012345678" })
check("S22 非 Steam 伺服器不接受", not hasLog(h, "steamId accepted"))
check("S22 非 Steam 伺服器不回 ack", #h.serverCommands == 0)

-- S23（無法在此驗證的已知限制，只能記錄）：遊戲的 Kahlua 沒有 integer 子型別，
-- tonumber 走 Double.parseDouble（KahluaUtil.java:290-293），所以一致性檢查是在
-- double 語意下比較——同一個 double bucket 裡約有 15-16 個相鄰 Steam64（實測
-- 76561198012345678 的 bucket 是 ...673~...687，共 15 個，全部通過格式閘門），
-- 惡意客戶端可以挑其中任一個通過檢查。這就是該欄位只能標成
-- client-reported, consistency-checked、不可作授權／封鎖依據的原因。
-- 本測試跑在 Lua 5.4（有 integer，tonumber 對 17 位數字回精確整數），比較會是精確
-- 的，因此**測不出**上述 double bucket 行為；硬要模擬得覆寫 harness 的 tonumber，
-- 那又會讓 builder 的整數欄位印成 1.0 而汙染其他所有斷言。取捨是：S22 驗證
-- 「正確回報通過／明顯不符拒絕」（兩種語意下結論相同），bucket 行為只留文件。

-- S24 steamId 跟著離線筆保留，且跨重啟繼承
h = makeHarness()
h.set("players", { { name = "frank", idx = 0, x = 10, y = 20, z = 0,
    steam64 = "76561198012345678" } })
h.fireServer()
h.tick()
h.clientCmd(0, "reportSteamId", { steamId = "76561198012345678" })
h.set("players", {})
h.set("now", 1000000 + 9000)
h.tick()
local hd24, by24 = parseOut(h)
check("S24 離線筆保留 steamId", by24["frank#0"] ~= nil
    and by24["frank#0"].online == false
    and by24["frank#0"].steamId == "76561198012345678")
local carry24 = h.written[PATH]
h = makeHarness()
h.written[PATH] = carry24
h.fireServer()
h.set("now", 2000000)
h.tick()
check("S24 跨重啟繼承 steamId",
    (select(2, parseOut(h)))["frank#0"].steamId == "76561198012345678")

-- S25 主開關關掉再開：停用期間完全不觀測，離線歷史有空窗，所以 offlineSince
-- 必須重設成當下——否則檔案會宣稱空窗期登出的角色也在清單裡（消費端就是靠這個
-- 欄位決定要多保守）
h = makeHarness()
h.written[PATH] = seg.buildPlayersJson(
    { { name = "old", idx = 0, steamId = "", online = false, x = 5, y = 6, z = 0,
        seen = 400 } }, 1, 0,
    { modversion = "42.20.1-9.9.9", save = "servertest", ts = 500, interval = 5,
      offlineIncluded = true, offlineSince = 400, offlineTruncated = false })
h.fireServer()
h.tick()
check("S25 啟動時開著＝沿用繼承的起點", parseOut(h).offlineSince == 400)
-- 關掉再開，而且**刻意都發生在一個 interval（5 秒）之內**：重設 offlineSince 若只
-- 改記憶體、被節流擋下不寫檔，檔案就會在最長一個 interval 內同時帶著舊起點與還算
-- 新鮮的 ts，工具會以為歷史沒斷過。所以重新啟用必須強制立刻寫一次。
h.set("sandbox", { ExportPlayerPositions = false })
h.set("now", 1000000 + 1000)
h.tick()
h.set("sandbox", { ExportPlayerPositions = true })
h.set("now", 1000000 + 2000)
h.tick()
local hd25 = parseOut(h)
check("S25 重新開啟後立刻寫出新的 offlineSince（不被節流擋）",
    hd25.offlineSince == 1000000 + 2000 and hd25.ts == 1000000 + 2000)
check("S25 有 log 說明歷史重啟",
    hasLog(h, "re-enabled; offline history RESTARTS"))

print(string.format("player-export tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
