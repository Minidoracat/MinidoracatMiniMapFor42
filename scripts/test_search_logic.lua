-- 搜尋純函式離線測試（座標判別＋有界最近-N 插入）。
-- 用法：lua scripts/test_search_logic.lua
-- 抽段執行 _Search.lua 的「解析與搜尋」區（同 test_layer_tail 抽段模式）。
-- 注意：desktop Lua 字串是 byte 語義，全形逗號（U+FF0C=3 bytes）在 desktop
-- 走 byte 白名單失敗→nil（當關鍵字）；遊戲內 Kahlua 是 UTF-16 unit 語義、
-- 碼位 65292 命中白名單→座標。此差異僅影響全形路徑，ASCII 路徑兩端同義，
-- 本測試只斷言 ASCII 路徑與 boundedInsert。
local mainPath = arg[1] or
    "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Search.lua"
local f = assert(io.open(mainPath, "rb"))
local source = f:read("*a"):gsub("\r\n", "\n")
f:close()

-- 抽段：SEP_CODES 起、到「結果列最終化」註解前（含 extractNums/parseCoords/
-- dist2/fmtDist/kindTag/boundedInsert 定義；kindTag 引用 getText 但不執行）
local seg = source:match("(local SEP_CODES.-)\n%-%- 結果列最終化")
assert(seg, "找不到解析區段（_Search.lua 結構變了？同步更新本測試錨點）")
-- 抽段 2：winSelectedItem（純表操作防呆——info 列/nil 座標拒絕；review blocking 回歸鎖）
local seg2 = source:match("(local function winSelectedItem.-\nend)\n")
assert(seg2, "找不到 winSelectedItem 區段")
seg = seg .. "\n" .. seg2
    .. "\nreturn { parseCoords = parseCoords, boundedInsert = boundedInsert, winSelectedItem = winSelectedItem }"
local chunk = assert((loadstring or load)(seg, "search-logic"))
local M = chunk()

local function eq(a, b, msg)
    if a ~= b then error(msg .. "：期望 " .. tostring(b) .. " 得到 " .. tostring(a), 2) end
end

-- 座標判別：三種支援格式
local x, y = M.parseCoords("12895,3499")
eq(x, 12895, "逗號格式 x"); eq(y, 3499, "逗號格式 y")
x, y = M.parseCoords("12895 - 3499 - 0")
eq(x, 12895, "破折號格式 x"); eq(y, 3499, "破折號格式 y")
x, y = M.parseCoords("10980,9679,0")
eq(x, 10980, "三元組 x"); eq(y, 9679, "三元組 y")
-- 小數 floor（家規：%d 只餵整數）
x, y = M.parseCoords("12895.5, 3499.9")
eq(x, 12895, "小數 floor x"); eq(y, 3499, "小數 floor y")
-- 拒絕：含字母/中文→關鍵字
eq(M.parseCoords("KY-841"), nil, "字母拒絕")
eq(M.parseCoords("1394\229\143\183\229\133\172\232\183\175"), nil, "中文拒絕") -- "1394號公路" UTF-8 bytes
eq(M.parseCoords("12895"), nil, "單一數字拒絕")
eq(M.parseCoords(""), nil, "空字串拒絕")
-- 有限值防線（codex review blocking：超長數字串 Double.parseDouble→Infinity，
-- floor 不除，會寫進持久 modData／分享封包）
eq(M.parseCoords(string.rep("9", 400) .. ",3499"), nil, "Infinity 拒絕")
eq(M.parseCoords("2000000000, 3499"), nil, "超上限拒絕")

-- boundedInsert：升冪有界
local arr = {}
local ds = { 50, 10, 90, 30, 70, 20, 80, 40, 60, 5 }
for i = 1, #ds do
    M.boundedInsert(arr, 5, { d = ds[i], tag = ds[i] })
end
eq(#arr, 5, "容量上限")
local expect = { 5, 10, 20, 30, 40 }
for i = 1, 5 do
    eq(arr[i].d, expect[i], "升冪第 " .. i .. " 位")
end
-- 剪枝：滿載插更遠不變
M.boundedInsert(arr, 5, { d = 999, tag = 999 })
eq(#arr, 5, "剪枝後容量")
eq(arr[5].d, 40, "剪枝不改末位")
-- 滿載插更近：擠掉末位
M.boundedInsert(arr, 5, { d = 1, tag = 1 })
eq(arr[1].d, 1, "近點插頭")
eq(arr[5].d, 30, "末位被擠出")

-- winSelectedItem：info 列/壞座標拒絕（review blocking 回歸鎖——clear() 後
-- selected=1 正好是 info 列）
local function fakeWin(item)
    return { list = { selected = 1, items = { { item = item } } } }
end
eq(M.winSelectedItem(fakeWin({ kind = "info", label = "載入中" })), nil, "info 列拒絕")
eq(M.winSelectedItem(fakeWin({ kind = "street", label = "Oak St" })), nil, "缺座標拒絕")
eq(M.winSelectedItem(fakeWin({ kind = "street", x = "12", y = 3 })), nil, "字串座標拒絕")
eq(M.winSelectedItem(fakeWin(nil)), nil, "空 item 拒絕")
eq(M.winSelectedItem({ list = { selected = 99, items = {} } }), nil, "越界選取拒絕")
local okItem = { kind = "poi", label = "藥局", x = 12895, y = 3499 }
eq(M.winSelectedItem(fakeWin(okItem)), okItem, "正常項通過")

-- doSearch 行為鎖（三 lane review 共識缺口：baseHit 前綴語義／地下後綴 label／
-- 短 query 不誤觸）。抽段「結果收集」到 doSearch end＋stub 環境（getText/
-- getTextManager/Core/資料表；desktop lua #字串=bytes、CJK 2 字=6——與 Kahlua
-- 2 units 語義不同，但前綴 sub 比對兩端同義，最小長度斷言用 EN 案例鎖）
do
    local seg3 = source:match("(local function doSearch.-\nend)\n\n%-%-%-")
    assert(seg3, "找不到 doSearch 區段（結構變了？同步更新錨點）")
    local prelude = [[
local function dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end
local function parseCoords() return nil end -- 本測試只走關鍵字路徑
local MAX_STREET_RESULTS, MAX_POI_RESULTS = 40, 30
local function boundedInsert(arr, cap, entry)
    local n = #arr
    if n >= cap and entry.d >= arr[n].d then return end
    local i = n
    while i >= 1 and arr[i].d > entry.d do i = i - 1 end
    local last = n + 1
    if last > cap then last = cap end
    for j = last, i + 2, -1 do arr[j] = arr[j - 1] end
    if i + 1 <= cap then arr[i + 1] = entry end
end
local TEXTS = {
    UI_MinidoracatMiniMap_SearchBasement = " (basement)",
    UI_MinidoracatMiniMap_SearchBasementKey = "basement",
    UI_MinidoracatMiniMap_SearchKindCoord = "Coord",
    UI_MinidoracatMiniMap_SearchKindStreet = "Street",
    UI_MinidoracatMiniMap_SearchKindPoi = "Place",
    Cat_food = "Food", Cat_gun = "Armory",
}
local function getText(k) return TEXTS[k] or k end
local function getTextManager()
    return { MeasureStringX = function(_, _, s) return #s * 6 end }
end
local UIFont = { Small = 1 }
local string = string
local math = math
local function kindTag(kind) return getText("UI_MinidoracatMiniMap_SearchKind"
    .. (kind == "coord" and "Coord" or kind == "street" and "Street" or "Poi")) end
local function fmtDist(d) return tostring(math.floor(d)) .. "m" end
local function finalizeItem(it)
    it.x = math.floor(it.x); it.y = math.floor(it.y)
    it.tag = kindTag(it.kind)
    it.right = ""
    it.tagW, it.rightW = 0, 0
    return it
end
local Core = { navStreetIndex = function()
    return { { name = "Oak St", low = "oak st", x = 100, y = 100 } }
end }
MinidoracatMiniMapPOICategories = { CATEGORIES = {
    food = { nameKey = "Cat_food" },
    gun = { nameKey = "Cat_gun" },
} }
MinidoracatMiniMapPOIData = {
    { cat = "food", rn = 1, r = { { x = 10, y = 10, w = 4, h = 4 } }, u = 1 },
    { cat = "food", rn = 1, r = { { x = 50, y = 50, w = 4, h = 4 } } },
    { cat = "gun", rn = 1, r = { { x = 90, y = 90, w = 4, h = 4 } }, u = 1 },
}
]]
    local chunk3 = assert((loadstring or load)(prelude .. seg3
        .. "\nreturn doSearch", "search-dosearch"))
    local doSearch = chunk3()
    -- 「basement」前綴：地下條目全類別命中（2 筆 u=1），label 帶後綴
    local r = doSearch("base", 0, 0)
    eq(#r, 2, "basement 前綴：恰 2 筆地下條目")
    eq(r[1].label, "Food (basement)", "地下 label 帶類別名＋後綴")
    eq(r[2].label, "Armory (basement)", "第二筆同語義")
    -- 類別名命中：food 兩筆（含地下、地下帶後綴）
    r = doSearch("food", 0, 0)
    eq(#r, 2, "類別命中：food 全部條目")
    eq(r[1].label, "Food (basement)", "近的地下 food 帶後綴")
    eq(r[2].label, "Food", "地上 food 無後綴")
    -- 短 query／非前綴子串：不得誤觸 baseHit（三 lane 抓出的 st/b 誤觸回歸鎖）
    eq(#doSearch("b", 0, 0), 0, "單字元不觸發 baseHit")
    eq(#doSearch("st", 0, 0), 1, "st 只命中街名（Oak St），不灑地下條目")
    eq(doSearch("st", 0, 0)[1].kind, "street", "st 命中的是街道")
    eq(#doSearch("as", 0, 0), 0, "中段子串 as 不觸發（前綴語義）")
    eq(#doSearch("(", 0, 0), 0, "括號不觸發（匹配鍵無標點）")
end

print("test_search_logic: 全數通過")
