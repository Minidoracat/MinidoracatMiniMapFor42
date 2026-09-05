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
-- 已知載體表與官方檔常數在切片外（頂層 local），抽真值：測試不得自帶第二份資料
local vanilla = assert(source:match("\n(local VANILLA_STREETS = [^\n]+)"), "找不到 VANILLA_STREETS")
local carriers = assert(source:match("\n(local CARRIER_STREETS = %b{})"), "找不到 CARRIER_STREETS")

local compile = loadstring or load
local prelude = "local logs = {}\nlocal function log(msg) logs[#logs + 1] = msg end\n"
    .. vanilla .. "\n" .. carriers .. "\n"
local suffix = "return { ensureStreetData = ensureStreetData, logs = logs }\n"

-- 每案例各自載入一份（logs 是 prelude 內的 local）
local function newModule()
    return assert(compile(prelude .. body .. "\n" .. suffix, "street-backfill"))()
end

local calls, dirsSize = 0, 1
local activeMods, existingFiles, added = {}, {}, {}
local uiLang = "CN"
Translator = { getLanguage = function() return { name = function() return uiLang end } end }

-- counts 逐次供給（模擬補載前／後探測），耗盡沿用最後值，另加上兜底 addStreetData
-- 進來的條數；countErr＝探測拋錯、loaderErr＝載入函式自己拋錯、dirsErr＝
-- getLotDirectories 拋錯。回傳一個新的 mapUI 實例
local function install(counts, countErr, loaderErr, dirsErr)
    calls = 0
    for k in pairs(added) do added[k] = nil end
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
    getActivatedMods = function()
        return { size = function() return #activeMods end, get = function(_, idx) return activeMods[idx + 1] end }
    end
    fileExists = function(p) return existingFiles[p] == true end
    local api = {
        getStreetDataCount = function()
            if countErr then error("boom", 0) end
            i = i + 1
            return (counts[i] or counts[#counts]) + #added
        end,
        addStreetData = function(_, p) added[#added + 1] = p end,
    }
    return { mapAPI = { getStreetsAPI = function() return api end } }
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

-- 9. 已知載體兜底（B42Trans_CN 在 MP 攔掉 Muldraugh、Riverside 不進迴圈 ⇒ 正規補載 0 條）：
--    該 MOD 啟用＋檔案存在 ⇒ 直接 addStreetData 它的檔、count>0、留一行 carrier log
m = newModule()
activeMods = { "B42Trans_CN" }
existingFiles = { ["media/maps/Riverside, KY/streets.xml"] = true }
m.ensureStreetData(install({ 0, 0 }))
ok(calls == 1, "兜底前正規補載仍要先跑一次")
ok(#added == 1 and added[1] == "media/maps/Riverside, KY/streets.xml",
    "兜底應直接載該 MOD 自己的中文檔，實得 " .. tostring(added[1]))
ok(#m.logs == 1 and has(m.logs[1], "carrier fallback (B42Trans_CN/own)"),
    "兜底命中要留痕：" .. tostring(m.logs[1]))

-- 9b. 介面語言非 CH/CN（EN／JP／取不到）⇒ 兜底改載官方英文，不載中文檔
--     （中文在無 CJK 字形的地圖字型下整張 `???`，2026-09-05 EN 實測）
for _, lang in ipairs({ "EN", "JP" }) do
    m = newModule()
    uiLang = lang
    existingFiles = { ["media/maps/Riverside, KY/streets.xml"] = true, ["media/maps/Muldraugh, KY/streets.xml"] = true }
    m.ensureStreetData(install({ 0, 0 }))
    ok(#added == 1 and added[1] == "media/maps/Muldraugh, KY/streets.xml",
        lang .. " 介面應載官方英文，實得 " .. tostring(added[1]))
    ok(has(m.logs[1], "carrier fallback (B42Trans_CN/vanilla)"), lang .. " 留痕應標 vanilla：" .. tostring(m.logs[1]))
end
-- 9c. CH 介面照載中文檔
m = newModule()
uiLang = "CH"
m.ensureStreetData(install({ 0, 0 }))
ok(#added == 1 and added[1] == "media/maps/Riverside, KY/streets.xml", "CH 介面應載中文檔")
-- 9d. Translator 取不到（拋錯）⇒ 保守走官方英文
m = newModule()
local savedTranslator = Translator
Translator = nil
m.ensureStreetData(install({ 0, 0 }))
Translator = savedTranslator
ok(#added == 1 and added[1] == "media/maps/Muldraugh, KY/streets.xml", "語言取不到應載官方英文")
uiLang = "CN"

-- 10. 未啟用該 MOD ⇒ 完全不進兜底（沒裝的人零行為差異）
m = newModule()
activeMods = {}
m.ensureStreetData(install({ 0, 0 }))
ok(#added == 0, "未啟用不得 addStreetData")
ok(#m.logs == 1 and has(m.logs[1], "count=0") and not has(m.logs[1], "carrier"),
    "未啟用走一般空容器 log：" .. tostring(m.logs[1]))

-- 11. 啟用但檔案不在（該 MOD 改版搬路徑）⇒ 不載、不炸
m = newModule()
activeMods = { "B42Trans_CN" }
existingFiles = {}
m.ensureStreetData(install({ 0, 0 }))
ok(#added == 0, "檔案不存在不得 addStreetData")

-- 12. 正規補載已有資料 ⇒ 兜底不介入（LangFor42／英文玩家／單機 B42Trans_CN）
m = newModule()
existingFiles = { ["media/maps/Riverside, KY/streets.xml"] = true }
m.ensureStreetData(install({ 0, 7 }))
ok(#added == 0 and #m.logs == 0, "有資料時兜底不得介入")

-- 13. 正規補載拋錯 ⇒ 不兜底（狀態未知，不疊加）
m = newModule()
m.ensureStreetData(install({ 0, 0 }, false, true))
ok(#added == 0 and has(m.logs[1], "load=error"), "載入拋錯不得兜底")
activeMods, existingFiles = {}, {}

if fail > 0 then
    print(string.format("test_street_backfill: %d passed, %d FAILED", pass, fail))
    os.exit(1)
end
print(string.format("test_street_backfill: OK（%d 斷言）", pass))
