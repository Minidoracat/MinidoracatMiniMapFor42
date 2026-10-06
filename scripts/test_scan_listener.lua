-- 掃描更新通知（_Dots.lua：scanApiVersion／registerScanListener）離線回歸。
-- 抽 _Dots.lua 的 scan-listener／zombie-sampling／animal-sampling 三段真程式，只把 PZ 全域換成假物件
-- （Policy 樁供真 scanIntervalMs 讀沙盒秒數與戰術檢視）。核心不變量：
--   * 只有定時模式（間隔 > 0）真的重新取樣才通知；即時模式、戰術檢視、節流命中、缺玩家、取樣失敗都不通知
--   * kind＝"zombie"／"vehicleAnimal"，各自計時
--   * 同一玩家兩個表面（小地圖＋世界地圖）一個間隔只通知一次；不同玩家各自通知
--   * fn 拋錯＝log 一次並停用到同 owner 再註冊；fn=nil＝取消註冊；壞參數回 false
--   * 零註冊＝取樣器不呼叫通知（不建任何狀態）
-- 用法：lua scripts/test_scan_listener.lua [_Dots.lua]
local path = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Dots.lua"
local file = assert(io.open(path, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local compile = loadstring or load

local function section(name)
    local pat = "%-%- test:" .. name:gsub("%-", "%%-") .. ":start\n(.-)\n%-%- test:"
        .. name:gsub("%-", "%%-") .. ":end"
    return assert(source:match(pat), "找不到 " .. name .. " 測試區段")
end
local scanBody = section("scan-listener")
local zombieBody = section("zombie-sampling")
local animalBody = section("animal-sampling")

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected)
        .. ", actual=" .. tostring(actual) .. ")")
end

local prelude = [=[
local now, seconds, tactical, playerPresent = 1000, {}, false, true
local zombies, vehicles, logs = {}, {}, {}
local function log(msg) logs[#logs + 1] = msg end
local Core = { policy = {
    readNumber = function(name, default) return seconds[name] or default end,
    tacticalActive = function() return tactical end,
} }
MinidoracatMiniMapAPI = {}
local function getTimestampMs() return now end
local function displayDist() return nil end
local function getComboIndex() return 1 end
local function visibleWorldAABB() return -100, 100, -100, 100 end
local player = {
    getX = function() return 0 end,
    getY = function() return 0 end,
    getUsername = function() return "A" end,
}
local function getSpecificPlayer() return playerPresent and player or nil end
local function javaList(values)
    return { size = function() return #values end, get = function(_, i) return values[i + 1] end }
end
local cell = {
    getZombieList = function() return javaList(zombies) end,
    getAnimals = function() return javaList({}) end,
    getVehicles = function() return { toArray = function() return vehicles end } end,
}
local function getCell() return cell end
local ZDOTS_INTERVAL_MS, ZDOTS_MAX, ZDOTS_SCAN_MAX, SCAN_ALL = 300, 10, 100, 1e9
local ZDOTS_NEAR, ZDOTS_MID, ZDOTS_MAXES = 20, 50, { 10 }
local function zdotsStateFor(inner)
    if not inner._state then
        inner._state = { near = {}, mid = {}, far = {}, dots = {}, count = 0, nextMs = 0 }
    end
    return inner._state
end
local ADOTS_INTERVAL_MS, ADOTS_MAX, ADOTS_SCAN_MAX = 500, 100, 500
local ADOTS_SPECIES_UI, ADOTS_VEHCAT_UI = {}, {}
local function livestockVisibilityMode() return 1 end
local function adotsDisabledGroups() return nil, "-" end
local function adotsSafehouseRects() return nil end
local function adotsLivestockVisible() return true end
local function adotsGroup() return "cow" end
local function adotsVehCategory() return "standard" end
]=]
local suffix = [=[
return {
    api = MinidoracatMiniMapAPI,
    zombie = function(inner) return sampleZombieDots(inner, nil, "ZombieScanInterval") end,
    vehicle = function(inner)
        return sampleAnimalDots(inner, false, false, true, false, nil, "VehicleAnimalScanInterval")
    end,
    setNow = function(v) now = v end,
    setSeconds = function(name, v) seconds[name] = v end,
    setTactical = function(v) tactical = v end,
    setPlayerPresent = function(v) playerPresent = v end,
    setZombies = function(v) zombies = v end,
    setVehicles = function(v) vehicles = v end,
    nextAt = function() return scanNextAt end,
    logs = logs,
}
]=]

local function fixture()
    local chunk, err = compile(prelude .. scanBody .. "\n" .. zombieBody .. "\n" .. animalBody .. "\n" .. suffix)
    assert(chunk, err)
    local h = chunk()
    h.calls = {}
    h.listen = function(owner)
        return h.api.registerScanListener(owner or "Watch", function(pn, kind)
            h.calls[#h.calls + 1] = { pn = pn, kind = kind }
        end)
    end
    h.setZombies({ { getX = function() return 1 end, getY = function() return 1 end } })
    h.setVehicles({ { getX = function() return 2 end, getY = function() return 2 end } })
    return h
end
local function count(h, kind)
    local n = 0
    for i = 1, #h.calls do if not kind or h.calls[i].kind == kind then n = n + 1 end end
    return n
end
local ZK, VK = "ZombieScanInterval", "VehicleAnimalScanInterval"

-- S0 版本欄位
local h = fixture()
checkEq(h.api.scanApiVersion, 1, "S0 scanApiVersion")

-- S1 零註冊：定時取樣照常取點，但通知函式一次都沒進（不建 (kind, pn) 狀態）
h.setSeconds(ZK, 5)
h.setSeconds(VK, 5)
local mini = { playerNum = 0 }
for t = 1000, 21000, 1000 do
    h.setNow(t)
    h.zombie(mini)
    h.vehicle(mini)
end
checkEq(mini._state.count, 1, "S1 零註冊仍取樣")
local hasState = false
for _ in pairs(h.nextAt()) do hasState = true end
check(not hasState, "S1 零註冊不呼叫通知（scanNextAt 無任何 kind）")
checkEq(#h.logs, 0, "S1 零註冊無 log")

-- S2 定時：首次取樣通知、間隔內節流不通知、到期再通知；kind 與 pn 正確
h = fixture()
check(h.listen() == true, "S2 註冊回 true")
h.setSeconds(ZK, 5)
local z = { playerNum = 0 }
h.setNow(1000); h.zombie(z)
checkEq(count(h, "zombie"), 1, "S2 首次定時取樣通知一次")
checkEq(h.calls[1].pn, 0, "S2 pn")
checkEq(h.calls[1].kind, "zombie", "S2 kind")
for t = 1300, 5900, 300 do h.setNow(t); h.zombie(z) end
checkEq(count(h), 1, "S2 間隔內節流命中不通知")
h.setNow(6000); h.zombie(z)
checkEq(count(h, "zombie"), 2, "S2 間隔到期重新取樣再通知")

-- S3 即時模式（0）：每 300ms 都重新取樣，但不通知
h = fixture()
h.listen()
h.setSeconds(ZK, 0)
h.setSeconds(VK, 0)
local live = { playerNum = 0 }
for t = 1000, 10000, 100 do h.setNow(t); h.zombie(live); h.vehicle(live) end
checkEq(count(h), 0, "S3 即時模式不通知")

-- S4 戰術檢視：沙盒定時也一律即時，不通知
h = fixture()
h.listen()
h.setSeconds(ZK, 5)
h.setSeconds(VK, 5)
h.setTactical(true)
local tac = { playerNum = 0 }
for t = 1000, 21000, 500 do h.setNow(t); h.zombie(tac); h.vehicle(tac) end
checkEq(count(h), 0, "S4 戰術檢視不通知")
-- 戰術檢視關掉（下一個即時節流窗重讀設定）→ 恢復定時通知
h.setTactical(false)
h.setNow(22000); h.zombie(tac); h.vehicle(tac)
checkEq(count(h, "zombie"), 1, "S4 關閉戰術檢視後殭屍恢復通知")
checkEq(count(h, "vehicleAnimal"), 1, "S4 關閉戰術檢視後載具動物恢復通知")

-- S5 vehicleAnimal：各自計時，不與 zombie 互相去重
h = fixture()
h.listen()
h.setSeconds(ZK, 5)
h.setSeconds(VK, 10)
local s5 = { playerNum = 0 }
h.setNow(1000); h.zombie(s5); h.vehicle(s5)
checkEq(count(h, "zombie"), 1, "S5 zombie 通知")
checkEq(count(h, "vehicleAnimal"), 1, "S5 vehicleAnimal 通知")
check(h.calls[2].kind == "vehicleAnimal" and h.calls[2].pn == 0, "S5 vehicleAnimal kind/pn")
for t = 1500, 10500, 500 do h.setNow(t); h.zombie(s5); h.vehicle(s5) end
checkEq(count(h, "zombie"), 2, "S5 zombie 依 5 秒")
checkEq(count(h, "vehicleAnimal"), 1, "S5 vehicleAnimal 依 10 秒")
h.setNow(11000); h.vehicle(s5)
checkEq(count(h, "vehicleAnimal"), 2, "S5 vehicleAnimal 到期再通知")

-- S6 同一玩家兩個表面（小地圖＋世界地圖各自計時）：一個間隔只通知一次；不同玩家各自通知
h = fixture()
h.listen()
h.setSeconds(ZK, 5)
local miniA, worldA, miniB = { playerNum = 0 }, { playerNum = 0 }, { playerNum = 1 }
h.setNow(1000); h.zombie(miniA)
h.setNow(2000); h.zombie(worldA) -- 世界地圖晚 1 秒開：真的取樣了，但同玩家本間隔已通知
check(worldA._state.count == 1, "S6 第二表面確實取樣")
checkEq(count(h), 1, "S6 同玩家第二表面不重複通知")
h.setNow(2000); h.zombie(miniB)
checkEq(count(h), 2, "S6 分割畫面另一玩家各自通知")
checkEq(h.calls[2].pn, 1, "S6 另一玩家 pn")
local function countPn0()
    local n = 0
    for i = 1, #h.calls do if h.calls[i].pn == 0 then n = n + 1 end end
    return n
end
for t = 2100, 15900, 100 do h.setNow(t); h.zombie(miniA); h.zombie(worldA) end
-- 15.9 秒內 miniA 於 6000/11000 到期（world 晚 1 秒、被去重）＝pn0 共 3 次
checkEq(countPn0(), 3, "S6 兩表面同時開著，pn0 依間隔通知")
-- 小地圖關掉（不再繪製取樣）：世界地圖在自己的下一次取樣（17000）接手，間隔不到兩倍
for t = 16000, 16900, 100 do h.setNow(t); h.zombie(worldA) end
checkEq(countPn0(), 3, "S6 世界地圖節流窗內不通知")
h.setNow(17000); h.zombie(worldA)
checkEq(countPn0(), 4, "S6 剩一個表面時由它接手通知")

-- S7 不通知：缺玩家、取樣失敗
h = fixture()
h.listen()
h.setSeconds(ZK, 5)
h.setSeconds(VK, 5)
h.setPlayerPresent(false)
local s7 = { playerNum = 0 }
h.setNow(1000); h.zombie(s7); h.vehicle(s7)
checkEq(count(h), 0, "S7 缺玩家不通知")
h.setPlayerPresent(true)
h.setZombies({ { getX = function() error("race") end, getY = function() return 0 end } })
h.setNow(7000); h.zombie(s7)
checkEq(count(h, "zombie"), 0, "S7 殭屍取樣失敗不通知")

-- S8 拋錯：log 一次、停用；其他 listener 照常；同 owner 再註冊恢復
h = fixture()
local bad = 0
h.api.registerScanListener("Bad", function() bad = bad + 1; error("boom") end)
h.listen("Good")
h.setSeconds(ZK, 5)
local s8 = { playerNum = 0 }
for t = 1000, 21000, 5000 do h.setNow(t); h.zombie(s8) end
checkEq(bad, 1, "S8 拋錯後停用、不再呼叫")
checkEq(count(h), 5, "S8 其他 listener 照常")
local errLogs = 0
for i = 1, #h.logs do if h.logs[i]:find("scan listener error (Bad)", 1, true) then errLogs = errLogs + 1 end end
checkEq(errLogs, 1, "S8 拋錯只 log 一次")
local okAgain = 0
check(h.api.registerScanListener("Bad", function() okAgain = okAgain + 1 end) == true, "S8 再註冊回 true")
h.setNow(26000); h.zombie(s8)
checkEq(okAgain, 1, "S8 同 owner 再註冊恢復")

-- S9 fn=nil 取消、覆蓋、壞參數、callback 內取消不炸
h = fixture()
h.listen()
h.setSeconds(ZK, 5)
local s9 = { playerNum = 0 }
check(h.api.registerScanListener("Watch", nil) == true, "S9 fn=nil 回 true")
check(h.api.registerScanListener("Nobody", nil) == true, "S9 取消不存在的 owner 回 true")
h.setNow(1000); h.zombie(s9)
checkEq(count(h), 0, "S9 取消後不通知")
local logsBefore = #h.logs
check(h.api.registerScanListener("", function() end) == false, "S9 空 owner 回 false")
check(h.api.registerScanListener("X", "fn") == false, "S9 非 function 回 false")
check(h.api.registerScanListener(nil, function() end) == false, "S9 nil owner 回 false")
checkEq(#h.logs, logsBefore + 3, "S9 壞參數各 log 一則")
local first, second = 0, 0
h.api.registerScanListener("A", function() first = first + 1 end)
h.api.registerScanListener("A", function() second = second + 1 end)
h.setNow(6000); h.zombie(s9)
check(first == 0 and second == 1, "S9 同 owner 再註冊＝覆蓋")
local tail = 0
h.api.registerScanListener("Self", function() h.api.registerScanListener("Self", nil) end)
h.api.registerScanListener("Tail", function() tail = tail + 1 end)
h.setNow(11000)
check(pcall(h.zombie, s9), "S9 callback 內取消註冊不炸")
h.setNow(16000); h.zombie(s9)
check(tail >= 1, "S9 取消後其餘 listener 照常")

if failures > 0 then
    print("scan listener assertions " .. assertions .. ", failures " .. failures)
    os.exit(1)
end
print("scan listener assertions " .. assertions .. ", failures " .. failures)
