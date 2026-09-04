-- 導航引擎冷啟動離線回歸測試：抽 _NavRoute.lua 的 nav-extract（真 beginExtract）
-- 與 nav-kick（kickEngine）兩個區段，以 stub mapAPI／getTimestampMs 驗狀態機。
-- 守 2026-09-05 MP 回報的根因修正：空容器（total==0）不得進 failed 終態、冷卻
-- per-inner（同幀多表面不互相飢餓）、其他失敗仍 failed 且不殘留 nodata。
-- 用法：lua scripts/test_nav_kick.lua
local navPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"

local file = assert(io.open(navPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local function slice(name)
    return assert(source:match(
        "%-%- test:" .. name .. ":start[^\n]*\n(.-)\n%-%- test:" .. name .. ":end"),
        "找不到 " .. name .. " 測試區段")
end

local compile = loadstring or load
local prelude = [=[
local engine = { state = "idle" }
local logs = {}
local function logf(key, msg) logs[#logs + 1] = key .. ": " .. msg end
local MAX_STREET_CONTAINERS = 1024
local clock = 0
local function getTimestampMs() return clock end
]=]
local suffix = [=[
return {
    kick = kickEngine, engine = engine, logs = logs,
    setClock = function(ms) clock = ms end,
    reset = function()
        engine.state, engine.extract, engine.nodata = "idle", nil, nil
        for i = #logs, 1, -1 do logs[i] = nil end
    end,
}
]=]
local m = assert(compile(prelude .. slice("nav%-extract") .. "\n" .. slice("nav%-kick") .. "\n" .. suffix, "nav-kick"))()

-- 全域 stub（beginExtract 直接引用）：getStreets 存在即可（不會走到抽取）、
-- lot dirs 給一個目錄
getStreets = function() return { size = function() return 0 end } end
getLotDirectories = function()
    return { size = function() return 1 end, get = function() return "Muldraugh, KY" end }
end

local probes = 0
-- inner stub：count 由閉包供給；countErr＝getStreetDataCount 拋錯；noApi＝getStreetsAPI 回 nil
local function inner(count, countErr, noApi)
    local api = {
        getStreetDataCount = function()
            probes = probes + 1
            if countErr then error("boom", 0) end
            return count()
        end,
        getStreetDataByRelativeFileName = function() return { tag = "data" } end,
        getStreetDataByIndex = function() return { tag = "data" } end,
    }
    return { mapAPI = { getStreetsAPI = function() return (not noApi) and api or nil end } }
end
local function fixed(n) return function() return n end end

local pass, fail = 0, 0
local function ok(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. msg) end
end

-- 1. 空容器（真 beginExtract total==0）⇒ 維持 idle、標 nodata、per-inner 冷卻；不進 failed
m.reset(); m.setClock(1000); probes = 0
local a = inner(fixed(0))
m.kick(a)
ok(m.engine.state == "idle", "total==0 不得進 failed，實為 " .. tostring(m.engine.state))
ok(m.engine.nodata == true, "total==0 要標 nodata")
ok(a._minidoracatNavRetryAt == 2000, "冷卻寫在 inner 上（now+1000），實為 " .. tostring(a._minidoracatNavRetryAt))
ok(#m.logs == 1 and m.logs[1]:find("nodata: ", 1, true) == 1, "total==0 只 log nodata（非 acquire）")

-- 2. 同 inner 冷卻內再 kick ⇒ 不探測
m.setClock(1500)
m.kick(a)
ok(probes == 1, "冷卻內同 inner 不得再探測，實得 " .. probes)

-- 3. 另一個 inner 同幀 kick、容器滿 ⇒ 不受 a 的冷卻影響，立即進 extracting、nodata 清
local b = inner(fixed(1))
m.kick(b)
ok(probes == 2, "不同 inner 不得被別人的冷卻擋住")
ok(m.engine.state == "extracting", "滿側應立即接手，實為 " .. tostring(m.engine.state))
ok(m.engine.nodata == nil, "成功後 nodata 要清掉")

-- 4. 非 idle ⇒ 早退不探測
m.kick(a); m.kick(b)
ok(probes == 2, "非 idle 不得探測")

-- 5. 冷卻到期、同 inner 仍空 ⇒ 再探測、再 arm、仍 idle
m.reset(); m.setClock(1000); probes = 0
local n = 0
a = inner(function() return n end)
m.kick(a)
m.setClock(2000)
m.kick(a)
ok(probes == 2 and m.engine.state == "idle" and a._minidoracatNavRetryAt == 3000,
    "到期仍空應再探測並重新 arm（idle），實為 state=" .. tostring(m.engine.state)
    .. " retryAt=" .. tostring(a._minidoracatNavRetryAt))

-- 6. 再到期、容器補上 ⇒ 進 extracting
n = 1
m.setClock(3000)
m.kick(a)
ok(m.engine.state == "extracting", "到期＋容器補上應進 extracting，實為 " .. tostring(m.engine.state))

-- 7. 先 nodata、之後 getStreetsAPI 回 nil（API 缺席）⇒ failed 且 nodata 必須清掉
m.reset(); m.setClock(1000)
m.kick(inner(fixed(0)))
ok(m.engine.nodata == true, "前置：nodata 已標")
m.kick(inner(fixed(0), false, true))
ok(m.engine.state == "failed", "getStreetsAPI 缺席應進 failed")
ok(m.engine.nodata == nil, "failed 不得殘留 nodata（否則 navEngineState 遮住終態）")

-- 8. getStreetDataCount 拋錯 ⇒ failed＋acquire log（pcall 失敗的第三回傳不得被當 retry）
m.reset()
m.kick(inner(fixed(0), true))
ok(m.engine.state == "failed", "探測拋錯應進 failed")
ok(#m.logs == 1 and m.logs[1]:find("acquire: street acquire failed", 1, true), "拋錯要 log acquire")

-- 9. inner 無 mapAPI ⇒ 早退
m.reset(); probes = 0
m.kick({})
ok(probes == 0 and m.engine.state == "idle", "無 mapAPI 早退")

-- 10. getStreets 全域缺失（PZ <42.20）⇒ failed＋api log，不是 retry
m.reset()
local saved = getStreets
getStreets = nil
m.kick(inner(fixed(1)))
getStreets = saved
ok(m.engine.state == "failed" and m.logs[1] and m.logs[1]:find("api: ", 1, true) == 1,
    "getStreets 缺失應進 failed 並 log api")

if fail > 0 then
    print(string.format("test_nav_kick: %d passed, %d FAILED", pass, fail))
    os.exit(1)
end
print(string.format("test_nav_kick: OK（%d 斷言）", pass))
