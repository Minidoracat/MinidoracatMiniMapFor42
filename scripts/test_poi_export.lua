-- 資源點區塊 JSON 匯出（poi_blocks.json）離線測試。
-- 抽 shared/MinidoracatMiniMapPOIExport.lua 的 test:poi-export 區段（純字串
-- 組裝、無 PZ API），fixture 黃金字串鎖格式，另用真實 POIData 做結構煙霧測試。
-- 用法：lua scripts/test_poi_export.lua
local exportPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/shared/MinidoracatMiniMapPOIExport.lua"
local dataPath = arg[2]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/shared/MinidoracatMiniMapPOIData.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end

local compile = loadstring or load
local body = assert(readSource(exportPath):match(
    "%-%- test:poi%-export:start\n(.-)\n%-%- test:poi%-export:end"),
    "找不到 poi-export 測試區段")
local buildPoiBlocksJson = assert(compile(
    body .. "\nreturn buildPoiBlocksJson", "poi-export"))()

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and ("\n  " .. detail) or ""))
    end
end

--------------------------------------------------------------------------------
-- 黃金字串：跨類別分組、同類逗號續行、缺 b 條目省略欄位、多矩形 r
--------------------------------------------------------------------------------
local fixture = {
    { cat = "books", rn = 2, b = { x = 9, y = 19, w = 8, h = 6 },
      r = { { x = 10, y = 20, w = 5, h = 4 }, { x = 15, y = 20, w = 2, h = 2 } } },
    { cat = "books", rn = 1,
      r = { { x = 100, y = 200, w = 3, h = 3 } } },
    { cat = "police", rn = 1, b = { x = 50, y = 60, w = 7, h = 8 },
      r = { { x = 50, y = 60, w = 7, h = 8 } } },
    count = 3,
}
local golden = table.concat({
    '{"v":1,"count":3,"categories":{',
    '"books":[{"b":[9,19,8,6],"r":[[10,20,5,4],[15,20,2,2]]}',
    ',{"r":[[100,200,3,3]]}',
    '],"police":[{"b":[50,60,7,8],"r":[[50,60,7,8]]}',
    ']}}',
}, "\n")
local got = buildPoiBlocksJson(fixture)
check("黃金字串全等", got == golden,
    "got:\n" .. got .. "\nwant:\n" .. golden)

-- 空資料（count=0）也要是合法 JSON（防禦路徑；正式呼叫端 count<1 直接略過）
check("空資料輸出", buildPoiBlocksJson({ count = 0 })
    == '{"v":1,"count":0,"categories":{\n}}')

--------------------------------------------------------------------------------
-- 真實 POIData 煙霧測試：頭尾、逐條目結構數、括號守恆
--------------------------------------------------------------------------------
dofile(dataPath)
local data = MinidoracatMiniMapPOIData
check("POIData 載入", type(data) == "table" and type(data.count) == "number"
    and data.count > 0)
local real = buildPoiBlocksJson(data)
local prefix = '{"v":1,"count":' .. data.count .. ',"categories":{'
check("真實資料頭", real:sub(1, #prefix) == prefix)
check("真實資料尾", real:sub(-3) == "]}}")

local function countPat(s, pat)
    local n = 0
    for _ in s:gmatch(pat) do n = n + 1 end
    return n
end
-- 每條目恰好一個 "r":[ 與一個 "b":[（真實資料全帶外框）
check('條目數（"r":[）', countPat(real, '"r":%[') == data.count)
check('外框數（"b":[）', countPat(real, '"b":%[') == data.count)
-- 類別段數＝資料中的相異 cat 數
local cats, catCount = {}, 0
for i = 1, data.count do
    local c = data[i].cat
    if not cats[c] then
        cats[c] = true
        catCount = catCount + 1
    end
end
-- 類別開頭必在行首：首類別 \n"cat":[、其餘 \n],"cat":[（條目內的 ],"r":[
-- 永遠在行中，不會被行首錨定誤數）
check("類別段數", countPat(real, '\n"%a+":%[') == 1
    and countPat(real, '\n%],"%a+":%[') == catCount - 1)
-- 括號守恆（配對數相等；黃金測試已鎖排列正確性）
check("[] 守恆", countPat(real, "%[") == countPat(real, "%]"))
check("{} 守恆", countPat(real, "{") == countPat(real, "}"))

print(string.format("poi-export tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
