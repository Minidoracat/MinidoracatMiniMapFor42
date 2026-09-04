-- 街道資料補載（ensureStreetData）離線回歸測試。仿 test_layer_tail.lua：
-- 抽主檔標記區段→補最小 stub→離線跑。
-- 守的是 2026-09-05 MP 回報的失效面：街道容器明確為空才補、狀態未知不補
-- （fail-closed，避免對已載入實例重 clear 踩幽靈街坑）、任何異常都留痕（每實例一次）。
-- 用法：lua scripts/test_street_backfill.lua
local mainPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local file = assert(io.open(mainPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local body = assert(source:match(
    "%-%- test:street%-backfill:start[^\n]*\n(.-)\n%-%- test:street%-backfill:end"),
    "找不到 street-backfill 測試區段")

local compile = loadstring or load
local prelude = "local logs = {}\nlocal function log(msg) logs[#logs + 1] = msg end\n"
local suffix = "return { ensureStreetData = ensureStreetData, logs = logs }\n"

-- 每案例各自載入一份（logs 是 prelude 內的 local）
local function newModule()
    return assert(compile(prelude .. body .. "\n" .. suffix, "street-backfill"))()
end

local calls, dirsSize = 0, 1

-- counts 逐次供給（模擬補載前／後兩次探測），耗盡沿用最後值；
-- countErr＝探測拋錯（getStreetsAPI 漂移面）、loaderErr＝載入函式自己拋錯、
-- dirsErr＝getLotDirectories 拋錯。回傳一個新的 mapUI 實例
local function install(counts, countErr, loaderErr, dirsErr)
    calls = 0
    local i = 0
    MapUtils = {
        initDefaultStreetData = function()
            calls = calls + 1
            if loaderErr then error("loader exploded", 0) end
        end,
    }
    getLotDirectories = function()
        if dirsErr then error("no dirs", 0) end
        return { size = function() return dirsSize end }
    end
    local streets = {
        getDataCount = function()
            if countErr then error("boom", 0) end
            i = i + 1
            return counts[i] or counts[#counts]
        end,
    }
    return {
        mapAPI = {
            getStreetsAPI = function()
                return { getStreetDataCount = streets.getDataCount }
            end,
        },
    }
end

local pass, fail = 0, 0
local function ok(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. msg) end
end
local function has(s, needle) return type(s) == "string" and s:find(needle, 1, true) ~= nil end

-- 1. 已有街道資料 ⇒ 絕不重載（幽靈街坑防線）、不留 log
local m = newModule()
m.ensureStreetData(install({ 3 }))
ok(calls == 0, "count>0 不得呼叫 initDefaultStreetData")
ok(#m.logs == 0, "count>0 不得 log")

-- 2. 空容器 ⇒ 補載一次；補載後有資料 ⇒ 不留 log
m = newModule()
m.ensureStreetData(install({ 0, 1 }))
ok(calls == 1, "空容器應補載一次")
ok(#m.logs == 0, "補載成功不得 log")

-- 3. 補載後仍空 ⇒ 補載一次＋log 一次，帶 lot dirs 數、load=ok 與 count
m = newModule()
dirsSize = 0
m.ensureStreetData(install({ 0, 0 }))
ok(calls == 1, "仍空時補載仍只跑一次")
ok(#m.logs == 1, "補載後仍空要留痕，實得 " .. #m.logs)
ok(has(m.logs[1], "lot dirs=0") and has(m.logs[1], "load=ok") and has(m.logs[1], "count=0"),
    "log 要帶 lot dirs／load／count：" .. tostring(m.logs[1]))

-- 4. 同一實例反覆失敗 ⇒ log 只一次（Recreate／重開圖每次重跑，不得刷屏），但仍重試；
--    新實例（新世界或 Recreate 後）可再 log 一次——旗標掛在 mapUI 上，不靠事件
m = newModule()
dirsSize = 2
local same = install({ 0, 0 })
m.ensureStreetData(same)
m.ensureStreetData(same)
ok(#m.logs == 1, "同實例重複失敗只 log 一次，實得 " .. #m.logs)
ok(calls == 2, "warned 之後仍要嘗試補載，實得 " .. calls)
m.ensureStreetData(install({ 0, 0 }))
ok(#m.logs == 2, "新實例失敗要再留痕一次，實得 " .. #m.logs)

-- 5. MapUtils 缺席（版本漂移）⇒ 直接返回，不炸、不 log
m = newModule()
local ui = install({ 0, 0 })
MapUtils = nil
ok(pcall(m.ensureStreetData, ui), "MapUtils 缺席不得拋錯")
ok(#m.logs == 0, "MapUtils 缺席不 log（另有 StreetI18n armed 那條診斷）")

-- 6. 探測拋錯＝狀態未知 ⇒ fail-closed：不得補載（補載第一步 clear 會毀掉可能
--    已載入的實例）、留痕且 load 標 skipped（不是 ok）
m = newModule()
m.ensureStreetData(install({ 0 }, true))
ok(calls == 0, "探測拋錯不得補載（fail-closed）")
ok(#m.logs == 1 and has(m.logs[1], "probe=error") and has(m.logs[1], "load=skipped"),
    "探測拋錯要留痕且 load=skipped：" .. tostring(m.logs[1]))

-- 7. 載入函式拋錯 ⇒ 不外傳（呼叫端後續不得中斷）＋留痕，且**不看 count**：
--    多目錄載到一半炸掉 count 已 >0，仍是部分路網
m = newModule()
ok(pcall(m.ensureStreetData, install({ 0, 5 }, false, true)),
    "initDefaultStreetData 拋錯不得外傳")
ok(#m.logs == 1 and has(m.logs[1], "load=error: loader exploded"),
    "載入拋錯要帶原因留痕，即使 count>0：" .. tostring(m.logs[1]))

-- 8. getLotDirectories 拋錯 ⇒ 用 "?" 佔位、不炸
m = newModule()
ok(pcall(m.ensureStreetData, install({ 0, 0 }, false, false, true)),
    "getLotDirectories 拋錯不得外傳")
ok(has(m.logs[1], "lot dirs=?"), "拿不到 lot dirs 要用 ? 佔位：" .. tostring(m.logs[1]))

if fail > 0 then
    print(string.format("test_street_backfill: %d passed, %d FAILED", pass, fail))
    os.exit(1)
end
print(string.format("test_street_backfill: OK（%d 斷言）", pass))
