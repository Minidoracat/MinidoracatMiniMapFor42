-- test_room_resources.lua — 資源點兩種版本與公開查詢 API（shared/MinidoracatMiniMapResources.lua）
-- 以及小地圖的房間資料版繪製資料（client/MinidoracatMiniMapPOI.lua 的 test:poi-convert 區段）。
-- 用假 IsoMetaGrid／BuildingDef／RoomDef（0 起索引的 ArrayList 介面，同 Java）跑整份 shared 檔。
--   lua scripts/test_room_resources.lua

local ROOT = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/"
local resPath = arg[1] or (ROOT .. "shared/MinidoracatMiniMapResources.lua")
local poiPath = arg[2] or (ROOT .. "client/MinidoracatMiniMapPOI.lua")

local checks, failures = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL " .. msg)
    end
end
local function eq(a, b, msg) check(a == b, msg .. "（得 " .. tostring(a) .. "，應為 " .. tostring(b) .. "）") end

--------------------------------------------------------------------------------
-- 假引擎物件
--------------------------------------------------------------------------------
local function jlist(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local function rect(x, y, w, h)
    return { getX = function() return x end, getY = function() return y end,
        getW = function() return w end, getH = function() return h end }
end
local function room(name, z, rects)
    local rs = {}
    for i = 1, #rects do rs[i] = rect(rects[i][1], rects[i][2], rects[i][3], rects[i][4]) end
    return { getName = function() return name end, getZ = function() return z end,
        getRects = function() return jlist(rs) end }
end
local function building(x, y, w, h, rooms)
    return { getX = function() return x end, getY = function() return y end,
        getW = function() return w end, getH = function() return h end,
        getRooms = function() return jlist(rooms) end }
end

local clock = 0
function getTimestampMs() return clock end

local tickFns = {}
local removed = 0
Events = { OnTickEvenPaused = {
    Add = function(fn) tickFns[#tickFns + 1] = fn end,
    Remove = function(fn)
        for i = #tickFns, 1, -1 do
            if tickFns[i] == fn then table.remove(tickFns, i); removed = removed + 1 end
        end
    end,
} }
local function runTicks(max)
    local n = 0
    while #tickFns > 0 and n < max do
        local fns = { table.unpack and table.unpack(tickFns) or unpack(tickFns) }
        for i = 1, #fns do fns[i]() end
        n = n + 1
    end
    return n
end

local grid = nil
local worldErr = false
function getWorld()
    if worldErr then error("world not loaded") end
    return { getMetaGrid = function() return grid end }
end
local function newGrid(defs)
    return { getBuildings = function() return jlist(defs) end }
end

MinidoracatMiniMapPOICategories = {
    CATEGORIES = {
        police = { nameKey = "K_Police", rooms = { "policeoffice", "policestorage" }, color = { r = 0.2, g = 0.4, b = 0.8 } },
        prison = { nameKey = "K_Prison", rooms = { "prisoncells" }, color = { r = 0.5, g = 0.5, b = 0.6 } },
        medical = { nameKey = "K_Medical", rooms = { "medical", "morgue" }, color = { r = 0.9, g = 0.2, b = 0.3 } },
    },
    ORDER = { "police", "medical", "prison" },
}

local printed = {}
local realPrint = print
print = function(s) printed[#printed + 1] = tostring(s) end
local chunk = assert(loadfile(resPath))
chunk()
print = realPrint
local R = MinidoracatMiniMapResourceAPI
check(type(R) == "table", "R0 MinidoracatMiniMapResourceAPI 在檔尾發布")
eq(R.resourceApiVersion, 2, "R0 resourceApiVersion")

--------------------------------------------------------------------------------
-- R1-R4 房間資料：分類、落點、外框、大小寫、世界還沒載入
--------------------------------------------------------------------------------
local station = building(100, 200, 40, 30, {
    room("policeoffice", 0, { { 100, 200, 10, 10 } }),
    room("policestorage", 1, { { 120, 200, 4, 4 }, { 124, 200, 12, 10 } }),
    room("prisoncells", 0, { { 110, 220, 6, 5 } }),
    room("bathroom", 0, { { 130, 220, 3, 3 } }),
})
local bunker = building(500, 500, 8, 8, { room("morgue", -1, { { 501, 501, 3, 3 } }) })
local house = building(300, 300, 10, 10, { room("bedroom", 0, { { 300, 300, 5, 5 } }),
    room("Policeoffice", 0, { { 305, 300, 5, 5 } }) }) -- 大小寫不同不算
local nameless = building(700, 700, 5, 5, { room(nil, 0, { { 700, 700, 2, 2 } }) })

local cats = R.buildingCategories(station)
check(cats and cats.police and cats.prison and not cats.medical, "R1 一間房在清單裡就算那一類，一筆可以多類")
eq(R.buildingCategories(house), nil, "R2 房名照原字串比對：Policeoffice 不算 police")
eq(R.buildingCategories(nameless), nil, "R2b 沒有房名的房間不算、不拋錯")
eq(R.buildingCategories({}), nil, "R2c 不是 BuildingDef 回 nil、不拋錯")

worldErr = true
eq(R.prepare("rooms"), false, "R3 世界還沒載入：prepare 回 false")
eq(#tickFns, 0, "R3 世界還沒載入：不掛 tick")
worldErr = false
grid = newGrid({})
eq(R.prepare("rooms"), false, "R3b metagrid 沒有建築：當成還沒載入")
eq(#tickFns, 0, "R3b 沒有建築：不掛 tick")

local defs = { station, house, bunker, nameless }
for i = 1, 200 do defs[#defs + 1] = building(1000 + i * 20, 1000, 10, 10, { room("kitchen", 0, { { 1000 + i * 20, 1000, 4, 4 } }) }) end
grid = newGrid(defs)
local list, why = R.buildingsIn(0, 0, 10000, 10000, "rooms")
eq(list, nil, "R4 還沒掃完：buildingsIn 回 nil")
eq(why, "pending", "R4 還沒掃完：原因 pending")
eq(#tickFns, 1, "R4 第一次查詢就開始背景掃描（掛一個 tick）")
eq(R.prepare("rooms"), false, "R4 掃描中 prepare 回 false、不重掛")
eq(#tickFns, 1, "R4 掃描中不重複掛 tick")

-- 分批：時鐘每讀一次走 1ms，預算 4ms＝每 tick 只掃一部分
local realNow = getTimestampMs
getTimestampMs = function() clock = clock + 1; return clock end
print = function(s) printed[#printed + 1] = tostring(s) end
local ticks = runTicks(100)
print = realPrint
getTimestampMs = realNow
check(ticks > 1, "R5 掃描分好幾個 tick 做完（得 " .. ticks .. " 個 tick）")
eq(#tickFns, 0, "R5 掃完摘掉 tick")
eq(R.prepare("rooms"), true, "R5 掃完 prepare 回 true")
local logged = false
for i = 1, #printed do if printed[i]:find("room resources scanned: 204 buildings, 2 with categories", 1, true) then logged = true end end
check(logged, "R5 掃完印一行統計（總筆數、有類別筆數）")

list, why = R.buildingsIn(0, 0, 10000, 10000, "rooms")
eq(why, 2, "R6 全圖查詢：兩筆有類別")
local s, b2
for i = 1, why do
    if list[i].x == 100 then s = list[i] end
    if list[i].x == 500 then b2 = list[i] end
end
check(s and s.y == 200 and s.w == 40 and s.h == 30, "R6 外框＝BuildingDef getX/getY/getW/getH")
check(s and s.anchors.police.x == 124 and s.anchors.police.w == 12 and s.anchors.police.h == 10,
    "R6 落點＝該類面積最大的房間矩形（跨房間、跨矩形比面積）")
check(s and s.anchors.police.basement == false, "R6 地上落點 basement=false")
check(b2 and b2.cats.medical and b2.anchors.medical.basement == true, "R6 落點在地下（getZ<0）標 basement")

-- 半開區間
list, why = R.buildingsIn(140, 200, 10, 10, "rooms")
eq(why, 0, "R7 矩形從外框右緣開始（x+w 是開區間）不相交")
list, why = R.buildingsIn(139, 229, 10, 10, "rooms")
eq(why, 1, "R7 重疊一格就相交")
list[1].cats.police = nil
list[1].anchors.prison.x = -1
local again = R.buildingsIn(139, 229, 10, 10, "rooms")
check(again[1].cats.police == true and again[1].anchors.prison.x == 110, "R8 回傳的是副本，改了不影響下次查詢")

-- 參數
eq(select(2, R.buildingsIn(nil, 0, 1, 1, "rooms")), "badrect", "R9 x 不是數字＝badrect")
eq(select(2, R.buildingsIn(0, 0, 0, 1, "rooms")), "badrect", "R9 寬度 0＝badrect")
eq(select(2, R.buildingsIn(0, 0, 0 / 0, 1, "rooms")), "badrect", "R9 NaN＝badrect")
eq(select(2, R.buildingsIn(0, 0, 1, 1, "Rooms")), "badversion", "R9 版本字串分大小寫，未知＝badversion")
eq(R.prepare("nope"), false, "R9 未知版本 prepare 回 false")

-- 換存檔：metagrid 換成另一個物件就重掃
grid = newGrid({ bunker })
eq(R.prepare("rooms"), false, "R10 metagrid 換了：重新開始掃描")
runTicks(10)
list, why = R.buildingsIn(0, 0, 10000, 10000, "rooms")
eq(why, 1, "R10 重掃後只剩新世界的建築")

--------------------------------------------------------------------------------
-- R11 小地圖資源版：烘焙資料的外框、落點與地下旗標
--------------------------------------------------------------------------------
MinidoracatMiniMapPOIData = {
    { cat = "police", rn = 2, r = { { x = 10, y = 20, w = 5, h = 4 }, { x = 30, y = 20, w = 2, h = 2 } },
        b = { x = 0, y = 0, w = 100, h = 80 } },
    { cat = "medical", rn = 2, r = { { x = 200, y = 200, w = 4, h = 4 }, { x = 210, y = 190, w = 2, h = 2 } }, u = 1 },
    { cat = "medical", rn = 1, r = { { x = 1, y = 1, w = 0, h = 1 } } }, -- 無效矩形整筆略過
    count = 3,
}
eq(R.prepare("minimap"), true, "R11 小地圖資源版永遠可查")
list, why = R.buildingsIn(-1000, -1000, 5000, 5000, "minimap")
eq(why, 2, "R11 無效條目略過")
check(list[1].x == 0 and list[1].w == 100 and list[1].cats.police and list[1].anchors.police.x == 10,
    "R11 外框＝b，落點＝r[1]，類別只有一個")
check(list[2].x == 200 and list[2].y == 190 and list[2].w == 12 and list[2].h == 14,
    "R11 缺 b 時外框＝r 的聯集")
check(list[2].anchors.medical.basement == true and list[1].anchors.police.basement == false, "R11 u=1 標 basement")
list, why = R.buildingsIn(99, 79, 5, 5, "minimap")
eq(why, 1, "R11 外框角落重疊一格就算（安全屋用整棟外框比對）")

-- categories()
local cl, cn = R.categories()
eq(cn, 3, "R12 categories 筆數")
check(cl[1].key == "police" and cl[2].key == "medical" and cl[3].key == "prison", "R12 照 ORDER 顯示順序")
check(cl[1].nameKey == "K_Police" and cl[1].color.b == 0.8 and cl[1].rooms[2] == "policestorage", "R12 欄位")
cl[1].rooms[1] = "x"
check(MinidoracatMiniMapPOICategories.CATEGORIES.police.rooms[1] == "policeoffice", "R12 回傳的是副本")

--------------------------------------------------------------------------------
-- P 小地圖的房間資料版繪製資料（MinidoracatMiniMapPOI.lua test:poi-convert 區段）
--------------------------------------------------------------------------------
local fh = assert(io.open(poiPath, "rb"))
local poiSource = fh:read("*a"):gsub("\r\n", "\n")
fh:close()
local body = assert(poiSource:match("%-%- test:poi%-convert:start\n(.-)\n%-%- test:poi%-convert:end"),
    "找不到 poi-convert 測試區段")
local prelude = [=[
local opts = { PoiIcons = true, PoiBlocks = true, PoiColorIcons = false }
local function getBoolOption(id, default)
    local v = opts[id]
    if v == nil then return default end
    return v
end
local function iconTexture(cat, colorMode) return "TEX_" .. cat, colorMode end
local function getText(key) return key end
local POI_FILL_ALPHA = 0.28
local POI_HALO_ALPHA = 0.5
local POI_LOD_MAX_EDGE = 100
]=]
local suffix = [=[
return {
    build = buildPoiConverted,
    zones = function() return poiZones end,
    legend = function() return poiLegend end,
    rooms = function() return roomList, roomCount end,
    setOpt = function(k, v) opts[k] = v end,
}
]=]
local conv = assert((loadstring or load)(prelude .. "\n" .. body .. "\n" .. suffix))()

local fixture = {
    { x = 0, y = 0, w = 40, h = 30, cats = { police = true, prison = true },
        anchors = { police = { x = 5, y = 5, w = 10, h = 8, basement = false },
            prison = { x = 20, y = 20, w = 4, h = 4, basement = true } } },
    { x = 500, y = 500, w = 150, h = 20, cats = { medical = true },
        anchors = { medical = { x = 510, y = 505, w = 6, h = 6, basement = false } } },
}
local apiState = "ready"
local queried
MinidoracatMiniMapResourceAPI = { buildingsIn = function(x, y, w, h, version)
    queried = version
    if apiState ~= "ready" then return nil, "pending" end
    return fixture, 2
end }

conv.build("rooms")
eq(queried, "rooms", "P1 房間資料版查 rooms")
local z = conv.zones()
eq(#z, 3, "P1 兩類的建築兩個 zone＋單類一個")
local pol, pri, med = z[1], z[2], z[3]
check(pol.category == "police" and pri.category == "prison", "P1 依 ORDER：police 先、prison 後")
check(pol.rects[1].x1 == 0 and pol.rects[1].x2 == 40 and pri.rects[1].y2 == 30, "P2 區塊一律整棟外框（x2＝x+w）")
check(pol.fillAlpha == 0.28 and pol.haloAlpha == 0.5 and pol.name == "K_Police / K_Prison",
    "P2 一筆只畫一塊：填色、底襯、名稱放在第一個類別")
check(pri.fillAlpha == 0 and pri.haloAlpha == nil and pri.name == nil, "P2 其餘類別只帶圖標，不重疊填色與名稱")
check(pol.icon.tex == "TEX_police" and pri.icon.tex == "TEX_prison", "P3 每類一顆圖標")
check(pol.iconRect.x1 == 5 and pol.iconRect.x2 == 15 and pri.iconRect.x1 == 20, "P3 圖標釘在該類最大的房間")
check(pri.basement == true and pol.basement == nil, "P3 地下落點帶 basement（↓ 角標）")
check(pol.tip == "K_Police / K_Prison" and pri.tip == pol.tip, "P4 多類時停留提示列出整棟的類別")
eq(med.tip, nil, "P4 單類不帶 tip（照類別名＋地下室後綴）")
check(pol.distRects == pri.distRects and #pol.distRects == 2 and pol.distRects[2].x1 == 20,
    "P5 距離閘量這筆所有顯示中類別的落點")
check(pol.lodRect and pol.lodRect.x2 == 40, "P5 一般建築附 lodRect＝整棟外框")
eq(med.lodRect, nil, "P5 最長邊超過 100 的地標不附 lodRect")
check(z.hasFill == true and z.hasLine == true and z.hasIcon == true, "P6 聚合旗標照開關")
local rl, rn = conv.rooms()
check(rl == fixture and rn == 2, "P6 搜尋讀同一份建築清單")
check(conv.legend().basement == true and conv.legend().count == 3, "P6 圖例列出勾選中的類別並帶地下標記")

-- 第一個類別沒勾：區塊移到下一個勾選中的類別
conv.setOpt("Cat_police", false)
conv.build("rooms")
z = conv.zones()
eq(#z, 2, "P7 police 沒勾：少一個 zone")
check(z[1].category == "prison" and z[1].fillAlpha == 0.28 and z[1].name == "K_Prison", "P7 區塊與名稱改放在 prison")
eq(z[1].tip, nil, "P7 只剩一類就不帶 tip")
conv.setOpt("Cat_police", nil)

-- 區塊關：只有圖標，不帶填色與名稱
conv.setOpt("PoiBlocks", false)
conv.build("rooms")
z = conv.zones()
check(#z == 3 and z[1].fillAlpha == 0 and z[1].name == nil and z.hasFill == false, "P8 區塊關：只有圖標")
-- 圖標也關：沒有 zone
conv.setOpt("PoiIcons", false)
conv.build("rooms")
eq(#conv.zones(), 0, "P8 圖標與區塊都關：沒有 zone")
conv.setOpt("PoiIcons", nil)
conv.setOpt("PoiBlocks", true)

-- 還沒掃完：空白、不拋錯
apiState = "pending"
conv.build("rooms")
eq(#conv.zones(), 0, "P9 還沒掃完：這次空白")
rl, rn = conv.rooms()
check(rl == nil and rn == 0, "P9 還沒掃完：搜尋清單也是空的")

-- 小地圖資源版照舊走烘焙資料，不查 rooms
queried = nil
conv.build("minimap")
eq(queried, nil, "P10 小地圖資源版不查房間資料")
check(#conv.zones() == 2 and conv.zones()[1].category == "police", "P10 小地圖資源版畫烘焙資料")

--------------------------------------------------------------------------------
-- M 地圖資源（v2）：registerMapResources、照地圖優先序過濾、別名
--------------------------------------------------------------------------------
local Res = MinidoracatMiniMapResources
check(type(Res) == "table" and type(Res.minimapEntries) == "function", "M0 內部合併清單在檔尾發布")
check(type(R.registerMapResources) == "function", "M0 registerMapResources")

printed = {}
print = function(s) printed[#printed + 1] = tostring(s) end
local okA, whyA = R.registerMapResources("", { mapMod = "A", mapDir = "A", cells300 = {} })
local okB, whyB = R.registerMapResources("Pack", { mapMod = "A", cells300 = {} })
local okC, whyC = R.registerMapResources("Pack", { mapMod = "A", mapDir = "A", cells300 = {}, poi = 5 })
print = realPrint
check(okA == false and whyA == "badowner", "M1 owner 是空字串：false, badowner")
check(okB == false and whyB == "badspec", "M1 缺 mapDir：false, badspec")
check(okC == false and whyC == "badspec", "M1 poi 不是表：false, badspec")
eq(#printed, 2, "M1 參數錯只 log、不丟錯；同一個 owner 的 badspec 只印一次")

-- 原版：(0,0)、(1,0) 兩格；(2,0) 原版不擁有（地圖邊緣），但沒有別的地圖擁有時引擎照樣留下
MinidoracatMiniMapPOIData = {
    { cat = "police", rn = 1, r = { { x = 110, y = 110, w = 4, h = 4 } }, b = { x = 100, y = 100, w = 20, h = 20 } },
    { cat = "medical", rn = 1, r = { { x = 410, y = 110, w = 4, h = 4 } }, b = { x = 400, y = 100, w = 20, h = 20 } },
    { cat = "police", rn = 1, r = { { x = 710, y = 110, w = 4, h = 4 } } },
    count = 3, mapDir = "Muldraugh, KY", cells300 = { 0, 0, 1, 0 },
}
check(R.registerMapResources("Pack", { mapMod = "Frogtown", mapDir = "Frogtown", cells300 = { 1, 0 },
    poi = {
        { cat = "prison", rn = 1, r = { { x = 355, y = 55, w = 3, h = 3 } }, b = { x = 350, y = 50, w = 10, h = 10 } },
        { cat = "medical", rn = 1, r = { { x = 1005, y = 55, w = 3, h = 3 } }, b = { x = 1000, y = 50, w = 10, h = 10 } },
        count = 2,
    },
    aliases = { Teshuyaopin = "medical", policeoffice = "prisoncells", Foo = "nothere" },
}) == true, "M2 合法 spec 註冊成功")
R.registerMapResources("Pack", { mapMod = "OtherMod", mapDir = "OtherMap", cells300 = { 0, 0 },
    poi = { { cat = "police", rn = 1, r = { { x = 55, y = 55, w = 3, h = 3 } } }, count = 1 } })
R.registerMapResources("Pack", { mapMod = "DupA", mapDir = "Dup", cells300 = { 0, 0 }, poi = { count = 0 } })
R.registerMapResources("Pack", { mapMod = "DupB", mapDir = "Dup", cells300 = { 0, 0 }, poi = { count = 0 } })

local dirs, mods = {}, {}
function getLotDirectories() return jlist(dirs) end
function getActivatedMods() return jlist(mods) end
local function entryXs()
    local data = Res.minimapEntries()
    local xs = {}
    for i = 1, data.count do xs[i] = (data[i].b or data[i].r[1]).x end
    return table.concat(xs, ",")
end
local function newWorld(d, m)
    dirs, mods = d, m
    grid = newGrid({})
end

printed = {}
print = function(s) printed[#printed + 1] = tostring(s) end
newWorld({ "Frogtown", "Muldraugh, KY" }, { "Frogtown" })
local xsM3 = entryXs()
print = realPrint
eq(xsM3, "350,1000,100,710", "M3 Frogtown 排前面：它擁有的 (1,0) 藏掉原版那筆；沒人擁有的格子兩邊都留")
local reportLine, aliasWarn = false, 0
for i = 1, #printed do
    if printed[i]:find("Frogtown 2; Muldraugh, KY 2 (1 hidden by map priority)", 1, true) then reportLine = true end
    if printed[i]:find("of map dir 'Frogtown' ignored", 1, true) then aliasWarn = aliasWarn + 1 end
end
check(reportLine, "M3 建好時印一行各地圖筆數與被藏的筆數")
eq(aliasWarn, 2, "M3 兩個不能用的別名（鍵是 20 類房名、目標不是）各警告一次")
list, why = R.buildingsIn(0, 0, 2000, 2000, "minimap")
eq(why, 4, "M3 buildingsIn(minimap) 也讀合併清單")
check(list[1].x == 350 and list[1].cats.prison and list[1].anchors.prison.x == 355, "M3 地圖包條目：外框＝b、落點＝r[1]")

newWorld({ "Muldraugh, KY", "Frogtown" }, { "Frogtown" })
eq(entryXs(), "100,400,710,1000", "M4 原版排前面：原版擁有的 (1,0) 藏掉 Frogtown 那筆")
newWorld({ "Frogtown", "Muldraugh, KY" }, {})
eq(entryXs(), "100,400,710", "M5 Frogtown 的 MOD 沒啟用：不用它的資料，也不藏原版")
newWorld({ "Muldraugh, KY" }, { "Frogtown" })
eq(entryXs(), "100,400,710", "M5 Frogtown 的地圖目錄沒載入：不用它的資料")
newWorld({ "OtherMap", "Muldraugh, KY" }, {})
eq(entryXs(), "100,400,710", "M5 OtherMod 沒啟用：同上")
newWorld({ "Frogtown" }, { "Frogtown" })
eq(entryXs(), "350,1000", "M6 世界沒有原版目錄：原版資料全部不顯示")
printed = {}
print = function(s) printed[#printed + 1] = tostring(s) end
newWorld({ "Dup", "Muldraugh, KY" }, { "DupA", "DupB" })
local xsM7 = entryXs()
entryXs()
print = realPrint
eq(xsM7, "100,400,710", "M7 同一個目錄有兩個啟用中的註冊：兩個都不用")
local dupLines = 0
for i = 1, #printed do if printed[i]:find("more than one active registration", 1, true) then dupLines = dupLines + 1 end end
eq(dupLines, 1, "M7 重複註冊只警告一次")
getLotDirectories = nil
newWorld({}, { "Frogtown" })
getLotDirectories = nil
eq(entryXs(), "100,400,710", "M8 拿不到地圖目錄：照舊只有原版、全部保留")
function getLotDirectories() return jlist(dirs) end

-- 別名：只在 Frogtown 擁有的格子；鍵是 20 類房名、目標不是 20 類房名的別名都不用
local inFrog = building(320, 10, 20, 20, { room("Teshuyaopin", 0, { { 320, 10, 5, 5 } }),
    room("policeoffice", 0, { { 330, 10, 4, 4 } }) })
local inVanilla = building(10, 10, 20, 20, { room("Teshuyaopin", 0, { { 10, 10, 5, 5 } }) })
local badTarget = building(330, 40, 10, 10, { room("Foo", 0, { { 330, 40, 5, 5 } }) })
printed = {}
print = function(s) printed[#printed + 1] = tostring(s) end
newWorld({ "Frogtown", "Muldraugh, KY" }, { "Frogtown" })
grid = newGrid({ inFrog, inVanilla, badTarget })
local fc = R.buildingCategories(inFrog)
local vc = R.buildingCategories(inVanilla)
local bc = R.buildingCategories(badTarget)
R.prepare("rooms")
runTicks(10)
print = realPrint
check(fc and fc.medical and fc.police and not fc.prison,
    "M9 Frogtown 格子裡：Teshuyaopin 照別名算醫療；policeoffice 是 20 類房名，別名不能改它")
eq(vc, nil, "M9 原版格子裡同名的房間不套 Frogtown 的別名")
eq(bc, nil, "M9 目標不是 20 類房名的別名不用")
list, why = R.buildingsIn(0, 0, 2000, 2000, "rooms")
check(why == 1 and list[1].x == 320 and list[1].anchors.medical.x == 320, "M10 房間資料掃描也套別名，落點是別名房間")

-- 掃完之後才註冊（別的 addon 晚註冊）：房間資料用新的別名重掃
R.registerMapResources("Pack2", { mapMod = "Frogtown2", mapDir = "Frogtown2", cells300 = { 9, 9 } })
eq(R.prepare("rooms"), false, "M11 註冊後房間資料重新掃描")
runTicks(10)
eq(R.prepare("rooms"), true, "M11 重掃完成")

MinidoracatMiniMapPOIData = nil
getLotDirectories, getActivatedMods = nil, nil

--------------------------------------------------------------------------------
-- S 生效的資源版本（MinidoracatMiniMapPOI.lua test:poi-source 區段）：玩家選擇、沙盒預設、伺服器鎖定
--------------------------------------------------------------------------------
local srcBody = assert(poiSource:match("%-%- test:poi%-source:start\n(.-)\n%-%- test:poi%-source:end"),
    "找不到 poi-source 測試區段")
local choice = 1
local sb = { PoiSourceDefault = 1, PoiSourceLock = false }
local resolve = assert((loadstring or load)("local function getComboOption(id, default) return GET_CHOICE() end\n"
    .. srcBody .. "\nreturn effectiveSource"))()
GET_CHOICE = function() return choice end
MinidoracatMiniMapPolicy = {
    readBool = function(k, d) local v = sb[k]; if v == nil then return d end; return v end,
    readNumber = function(k, d) local v = sb[k]; if v == nil then return d end; return v end,
}
local function pick(c, default, lock)
    choice, sb.PoiSourceDefault, sb.PoiSourceLock = c, default, lock
    local s, locked = resolve()
    return s .. (locked and "+lock" or "")
end
eq(pick(1, 2, false), "rooms", "S1 依伺服器設定＝沙盒預設")
eq(pick(3, 1, false), "rooms", "S2 沒鎖定時玩家自己的選擇優先")
eq(pick(3, 1, true), "minimap+lock", "S3 鎖定時忽略玩家的選擇，用沙盒預設")
eq(pick(2, 2, true), "rooms+lock", "S3 鎖定時兩種預設都照沙盒")
eq(pick(3, 1, nil), "rooms", "S4 舊伺服器沒有鎖定鍵＝不鎖")
MinidoracatMiniMapPolicy = nil
eq(pick(3, 1, true), "rooms", "S5 沒有 Policy 時照玩家的選擇")
eq(pick(1, 2, true), "minimap", "S5 沒有 Policy 時依伺服器設定＝小地圖資源")
GET_CHOICE = nil
print("room resources: " .. checks .. " checks, " .. failures .. " failures")
if failures > 0 then os.exit(1) end
