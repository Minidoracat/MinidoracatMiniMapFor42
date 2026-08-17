-- Steam64 客戶端回報（client/MinidoracatMiniMapSteamIdReport.lua）離線測試。
-- 整檔 stub 載入，重點是釘住「暫時性未就緒不可永久放棄」——OnTick 從進遊戲第一個
-- tick 就跑，那時 Steam API 可能還沒初始化、IsoPlayer 還沒建立、onlineID 還是 -1；
-- 在那個窗口 giveUp 會讓整個 steamId 功能靜默失效，而且在非 Steam 環境下與「本來
-- 就沒有 Steam ID」完全無法區分（兩者都是安靜地什麼都沒發生），實機極難察覺。
-- 用法：lua scripts/test_steamid_report.lua
local srcPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMapSteamIdReport.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end

local compile = loadstring or load
local fullSource = readSource(srcPath)

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and ("\n  " .. detail) or ""))
    end
end

local PRELUDE = [==[
local logs = {}
local sentCmds = {}
local isClientVal = true
local nowVal = 1000000
local steamIdVal = "76561198012345678"   -- nil＝getCurrentUserSteamID 取不到
local playersList = {}                   -- { {onlineId = 5} , ... }；nil 元素＝物件還沒建立
local onTick, onServerCmd = {}, {}
local Events = {
    OnTick = { Add = function(f) onTick[#onTick + 1] = f end },
    OnServerCommand = { Add = function(f) onServerCmd[#onServerCmd + 1] = f end },
}
local function isClient() return isClientVal end
local function getTimestampMs() return nowVal end
local function print(s) logs[#logs + 1] = tostring(s) end
local function getCurrentUserSteamID() return steamIdVal end
local function getNumActivePlayers() return playersList.n or 0 end
local function getSpecificPlayer(i)
    local p = playersList[i + 1]
    if p == nil then return nil end
    return { getOnlineID = function() return p.onlineId end }
end
local function sendClientCommand(player, module, command, args)
    sentCmds[#sentCmds + 1] = { module = module, command = command,
        steamId = args and args.steamId }
end
]==]
local CONTROLS = [==[
return {
    tick = function() for i = 1, #onTick do onTick[i]() end end,
    ack = function(idx)
        for i = 1, #onServerCmd do
            onServerCmd[i]("MinidoracatMiniMap", "steamIdAck", { idx = idx })
        end
    end,
    logs = logs,
    sent = sentCmds,
    sentCount = function() return #sentCmds end,
    set = function(k, v)
        if k == "isClient" then isClientVal = v
        elseif k == "now" then nowVal = v
        elseif k == "steamId" then steamIdVal = v
        elseif k == "players" then playersList = v end
    end,
}
]==]
local function makeHarness()
    return assert(compile(PRELUDE .. fullSource .. "\n" .. CONTROLS,
        "steamid-report"))()
end
local function hasLog(h, needle)
    for i = 1, #h.logs do
        if h.logs[i]:find(needle, 1, true) then return true end
    end
    return false
end
-- playersList 用顯式 n（模擬 getNumActivePlayers 與 getSpecificPlayer 不同步的窗口）
local function plist(n, ...)
    local t = { n = n }
    local args = { ... }
    for i = 1, #args do t[i] = args[i] end
    return t
end

--------------------------------------------------------------------------------
-- A. 正常路徑：就緒後送出、收到 ack 後停止
--------------------------------------------------------------------------------
local h = makeHarness()
h.set("players", plist(1, { onlineId = 7 }))
h.tick()
check("A1 就緒即送出", h.sentCount() == 1
    and h.sent[1].command == "reportSteamId"
    and h.sent[1].steamId == "76561198012345678")
-- 節流：未到期不重送
h.set("now", 1000000 + 5000)
h.tick()
check("A2 節流內不重送", h.sentCount() == 1)
-- 到期重送（還沒 ack）
h.set("now", 1000000 + 10000)
h.tick()
check("A3 到期重送", h.sentCount() == 2)
-- ack 後停止
h.ack(0)
h.set("now", 1000000 + 30000)
h.tick()
check("A4 ack 後不再送", h.sentCount() == 2)
check("A4 停止有 log", hasLog(h, "all slots acknowledged or exhausted"))

--------------------------------------------------------------------------------
-- B. 暫時性未就緒**不可**永久放棄（本檔的核心）
--------------------------------------------------------------------------------
-- B1 getNumActivePlayers 還回 0（玩家物件未建立）→ 不可放棄，之後要能補送
h = makeHarness()
h.set("players", plist(0))
h.tick()
check("B1 沒有玩家時不送、也不放棄", h.sentCount() == 0
    and not hasLog(h, "stopped"))
h.set("players", plist(1, { onlineId = 7 }))
h.set("now", 1000000 + 2000)
h.tick()
check("B1 玩家出現後補送", h.sentCount() == 1)

-- B2 getSpecificPlayer 還回 nil（計數有了但物件還沒建立）→ 不可放棄
h = makeHarness()
h.set("players", plist(1))          -- n=1 但 [1] 是 nil
h.tick()
check("B2 物件未建立時不放棄", h.sentCount() == 0
    and not hasLog(h, "stopped"))
h.set("players", plist(1, { onlineId = 3 }))
h.set("now", 1000000 + 2000)
h.tick()
check("B2 物件建立後補送", h.sentCount() == 1)

-- B3 onlineID 還是 -1（連線還沒指派）→ 不可放棄
h = makeHarness()
h.set("players", plist(1, { onlineId = -1 }))
h.tick()
check("B3 onlineID=-1 時不送也不放棄", h.sentCount() == 0
    and not hasLog(h, "stopped"))
h.set("players", plist(1, { onlineId = 9 }))
h.set("now", 1000000 + 2000)
h.tick()
check("B3 指派後補送", h.sentCount() == 1)

-- B4 Steam ID 一開始取不到（Steam 尚未初始化）→ 有限重試，之後要能補送
h = makeHarness()
h.set("steamId", nil)
h.set("players", plist(1, { onlineId = 7 }))
h.tick()
check("B4 取不到 ID 時不送、不立即放棄", h.sentCount() == 0
    and not hasLog(h, "stopped"))
h.set("steamId", "76561198012345678")
h.set("now", 1000000 + 2000)
h.tick()
check("B4 ID 就緒後補送", h.sentCount() == 1)

--------------------------------------------------------------------------------
-- C. 真的沒有進展時才停，而且一定 log（否則管理員分不出「非 Steam」與「壞掉」）
--------------------------------------------------------------------------------
-- C1 一直取不到 Steam ID（真的是 -nosteam 客戶端）→ 用盡重試後停並 log
h = makeHarness()
h.set("steamId", nil)
h.set("players", plist(1, { onlineId = 7 }))
local t = 1000000
for _ = 1, 40 do
    h.tick()
    t = t + 1000
    h.set("now", t)
end
check("C1 用盡 ID 重試後停止", hasLog(h, "no Steam ID available"))
check("C1 停止後不再送", h.sentCount() == 0)

-- C2 送到上限（伺服器一直不 ack，例如非 Steam 伺服器）→ 停並 log
h = makeHarness()
h.set("players", plist(1, { onlineId = 7 }))
t = 1000000
for _ = 1, 20 do
    h.tick()
    t = t + 10000
    h.set("now", t)
end
check("C2 送出次數有上限", h.sentCount() == 12)
check("C2 用盡後停止並 log", hasLog(h, "all slots acknowledged or exhausted"))

--------------------------------------------------------------------------------
-- D. 分屏：逐 slot 記帳，一個 slot 的 ack 不能把其他 slot 停掉
--------------------------------------------------------------------------------
h = makeHarness()
h.set("players", plist(2, { onlineId = 7 }, { onlineId = 8 }))
h.tick()
check("D1 兩個 slot 各送一次", h.sentCount() == 2)
h.ack(0)                              -- 只 ack slot 0
h.set("now", 1000000 + 10000)
h.tick()
check("D1 只有未 ack 的 slot 重送", h.sentCount() == 3)
h.ack(1)
h.set("now", 1000000 + 30000)
h.tick()
check("D1 兩個都 ack 後停止", h.sentCount() == 3)

-- D2 非 MP 客戶端（單機）完全不動作
h = makeHarness()
h.set("isClient", false)
h.set("players", plist(1, { onlineId = 7 }))
h.tick()
check("D2 非客戶端不送", h.sentCount() == 0 and #h.logs == 0)

print(string.format("steamid-report tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
