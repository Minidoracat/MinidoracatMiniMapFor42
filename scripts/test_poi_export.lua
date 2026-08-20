-- 資源點區塊 JSON 匯出（poi_blocks.json）離線測試。
-- 三段：(1) 抽 test:poi-export 區段（純字串組裝）打黃金字串鎖格式；
-- (2) 真實 POIData 結構煙霧測試；(3) production boundary——整檔 stub 載入，
-- 覆蓋事件掛點／isClient 閘／writer 生命週期／缺席／資料缺失／寫入失敗讀回驗證。
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
-- 黃金字串：跨類別分組、同類逗號續行、缺 b 條目省略欄位、多矩形 r、modversion、
-- u=1 地下欄（b 之後 r 之前；僅地下時輸出——additive 契約鎖位）
--------------------------------------------------------------------------------
local fixture = {
    { cat = "books", rn = 2, b = { x = 9, y = 19, w = 8, h = 6 },
      r = { { x = 10, y = 20, w = 5, h = 4 }, { x = 15, y = 20, w = 2, h = 2 } } },
    { cat = "books", rn = 1,
      r = { { x = 100, y = 200, w = 3, h = 3 } } },
    { cat = "food", rn = 1, b = { x = 70, y = 80, w = 6, h = 11 }, u = 1,
      r = { { x = 71, y = 83, w = 6, h = 5 } } },
    { cat = "police", rn = 1, b = { x = 50, y = 60, w = 7, h = 8 },
      r = { { x = 50, y = 60, w = 7, h = 8 } } },
    count = 4,
}
local golden = table.concat({
    '{"v":1,"modversion":"42.20.0-0.13.0","count":4,"categories":{',
    '"books":[{"b":[9,19,8,6],"r":[[10,20,5,4],[15,20,2,2]]}',
    ',{"r":[[100,200,3,3]]}',
    '],"food":[{"b":[70,80,6,11],"u":1,"r":[[71,83,6,5]]}',
    '],"police":[{"b":[50,60,7,8],"r":[[50,60,7,8]]}',
    ']}}',
}, "\n")
local got = buildPoiBlocksJson(fixture, "42.20.0-0.13.0")
check("黃金字串全等", got == golden,
    "got:\n" .. got .. "\nwant:\n" .. golden)

-- modversion 防禦：nil/空字串→unknown；JSON 危險字元被消毒（引號/反斜線/控制字元
-- 進不了字串字面值）、消毒後空→unknown
check("modversion nil→unknown", buildPoiBlocksJson({ count = 0 })
    == '{"v":1,"modversion":"unknown","count":0,"categories":{\n}}')
check("modversion 空→unknown", buildPoiBlocksJson({ count = 0 }, "")
    == '{"v":1,"modversion":"unknown","count":0,"categories":{\n}}')
check("modversion 消毒", buildPoiBlocksJson({ count = 0 }, 'a"b\\c 1.2-3')
    == '{"v":1,"modversion":"abc1.2-3","count":0,"categories":{\n}}')
check("modversion 全異常→unknown", buildPoiBlocksJson({ count = 0 }, '"\\"')
    == '{"v":1,"modversion":"unknown","count":0,"categories":{\n}}')

--------------------------------------------------------------------------------
-- 真實 POIData 煙霧測試：頭尾、逐條目結構數、括號守恆、座標整數性
--------------------------------------------------------------------------------
dofile(dataPath)
local data = MinidoracatMiniMapPOIData
check("POIData 載入", type(data) == "table" and type(data.count) == "number"
    and data.count > 0)
local real = buildPoiBlocksJson(data, "9.9.9-t")
local prefix = '{"v":1,"modversion":"9.9.9-t","count":' .. data.count
    .. ',"categories":{'
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
-- 類別開頭必在行首：首類別 \n"cat":[、其餘 \n],"cat":[（條目內的 ],"r":[
-- 永遠在行中，不會被行首錨定誤數）
local cats, catCount = {}, 0
for i = 1, data.count do
    local c = data[i].cat
    if not cats[c] then
        cats[c] = true
        catCount = catCount + 1
    end
end
check("類別段數", countPat(real, '\n"%a+":%[') == 1
    and countPat(real, '\n%],"%a+":%[') == catCount - 1)
-- 括號守恆（配對數相等；黃金測試已鎖排列正確性）
check("[] 守恆", countPat(real, "%[") == countPat(real, "%]"))
check("{} 守恆", countPat(real, "{") == countPat(real, "}"))
-- 座標整數性：header（modversion 帶點）之後不得出現小數點——未來 poi_raw 重生
-- 若滲入浮點字面值（Python 會寫 12.0），JSON 雖合法但破壞 determinism 且
-- Kahlua/桌面 Lua 格式化不一致，這裡鎖死
local headerEnd = real:find("\n", 1, true)
check("座標無小數點", headerEnd ~= nil
    and real:find(".", headerEnd, true) == nil)

--------------------------------------------------------------------------------
-- Production boundary（codex review 缺口）：整檔 stub 載入，覆蓋 writer 生命週期、
-- 事件掛點、isClient 閘、writer 缺席、資料缺失、寫入失敗（讀回驗證擋撕裂）。
-- 仿 test_key_migration.lua：stub 以 prelude local 遮蔽引擎全域，串接整份原始碼。
--------------------------------------------------------------------------------
local FIXTURE_SRC = [[{
    { cat = "books", rn = 1, b = { x = 1, y = 2, w = 3, h = 4 },
      r = { { x = 1, y = 2, w = 3, h = 4 } } },
    { cat = "police", rn = 1, b = { x = 9, y = 8, w = 7, h = 6 },
      r = { { x = 9, y = 8, w = 7, h = 6 } } },
    count = 2,
}]]
local bootFixture = assert(compile("return " .. FIXTURE_SRC))()
local expectedBoot = buildPoiBlocksJson(bootFixture, "42.20.1-9.9.9")
local EXPORT_PATH = "MinidoracatMiniMap/poi_blocks.json"

local fullSource = readSource(exportPath)
local PRELUDE = [==[
local written = {}
local writerAvailable = true
local writeShouldFail = false
local logs = {}
local isClientVal = false
local onServerStarted, onGameStart = {}, {}
local Events = {
    OnServerStarted = { Add = function(f) onServerStarted[#onServerStarted + 1] = f end },
    OnGameStart = { Add = function(f) onGameStart[#onGameStart + 1] = f end },
}
local function isClient() return isClientVal end
local function print(s) logs[#logs + 1] = tostring(s) end
local function getModInfoByID(id)
    if id ~= "MinidoracatMiniMapFor42" then return nil end
    return { getModVersion = function() return "42.20.1-9.9.9" end }
end
local function getFileWriter(path, createIfNull, append)
    if not writerAvailable then return nil end
    local buf = {}
    return {
        -- 模擬真實 LuaFileWriter：write 失敗＝內容沒進去；close 永遠落檔
        -- （截斷檔就是這樣產生的）
        write = function(_, s)
            if writeShouldFail then error("disk full") end
            buf[#buf + 1] = s
        end,
        close = function(_) written[path] = table.concat(buf) end,
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
local MinidoracatMiniMapPOIData = ]==] .. FIXTURE_SRC .. "\n"
local CONTROLS = [==[
return {
    fireServer = function()
        for i = 1, #onServerStarted do onServerStarted[i]() end
    end,
    fireGame = function()
        for i = 1, #onGameStart do onGameStart[i]() end
    end,
    written = written,
    logs = logs,
    set = function(k, v)
        if k == "isClient" then isClientVal = v
        elseif k == "writer" then writerAvailable = v
        elseif k == "writeFail" then writeShouldFail = v
        elseif k == "data" then MinidoracatMiniMapPOIData = v end
    end,
}
]==]
local function makeHarness()
    return assert(compile(PRELUDE .. fullSource .. "\n" .. CONTROLS,
        "poi-export-boundary"))()
end
local function hasLog(h, needle)
    for i = 1, #h.logs do
        if h.logs[i]:find(needle, 1, true) then return true end
    end
    return false
end

-- S1 單機（isClient=false）：OnGameStart 寫檔、內容逐 byte 等於 builder 輸出、成功 log
local h = makeHarness()
h.fireGame()
check("S1 單機寫檔內容全等", h.written[EXPORT_PATH] == expectedBoot,
    "got:\n" .. tostring(h.written[EXPORT_PATH]))
check("S1 成功 log", hasLog(h, "exported (2 buildings"))

-- S2 MP 純 client：不寫、不出聲
h = makeHarness()
h.set("isClient", true)
h.fireGame()
check("S2 client 不寫", h.written[EXPORT_PATH] == nil)
check("S2 無 log", #h.logs == 0)

-- S3 專用伺服器：OnServerStarted 寫檔
h = makeHarness()
h.fireServer()
check("S3 伺服器寫檔", h.written[EXPORT_PATH] == expectedBoot)

-- S4 writer 缺席（42.20.0 白名單情境）：不寫、STALE 警告、無成功 log
h = makeHarness()
h.set("writer", false)
h.fireGame()
check("S4 不寫", h.written[EXPORT_PATH] == nil)
check("S4 STALE 警告", hasLog(h, "STALE"))
check("S4 無成功 log", not hasLog(h, "exported ("))

-- S5 資料缺失：count=0 空文件覆寫（中和既有舊檔）、中和 log＋空文件成功 log
h = makeHarness()
h.written[EXPORT_PATH] = "OLD-STALE-CONTENT"
h.set("data", nil)
h.fireGame()
local emptyDoc = h.written[EXPORT_PATH]
check("S5 空文件覆寫舊檔", emptyDoc ~= nil
    and emptyDoc:find('"count":0', 1, true) ~= nil
    and emptyDoc:find("OLD-STALE-CONTENT", 1, true) == nil)
check("S5 中和 log", hasLog(h, "EMPTY document"))
check("S5 空文件成功 log", hasLog(h, "exported (0 buildings"))

-- S6 寫入失敗→截斷檔：讀回驗證抓到、TORN 警告、無成功 log
h = makeHarness()
h.set("writeFail", true)
h.fireGame()
check("S6 讀回驗證失敗警告", hasLog(h, "verify FAILED"))
check("S6 無成功 log", not hasLog(h, "exported ("))

print(string.format("poi-export tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
