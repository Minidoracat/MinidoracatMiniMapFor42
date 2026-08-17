-- MinidoracatMiniMapSteamIdReport.lua — 把本機 Steam64 回報給伺服器，讓玩家座標
-- 匯出檔（players_<存檔名>.json）能帶上 steamId 欄位。
--
-- 為什麼要客戶端做：伺服器端拿不到精確的 Steam64。`IsoPlayer.getSteamID()` 回
-- Java long（IsoPlayer.java:6412-6414），經 Kahlua 的 NumberToLuaConverter 一律
-- 轉成 Double（KahluaNumberConverter.java:141-142）——Steam64 約 7.66e16，該量級
-- double 的 ULP 是 16，末一兩位直接被捨去。引擎會把 SteamID 字串化的 Lua 入口
-- 全都擋在客戶端：`getCurrentUserSteamID()` 條件含 `!GameServer.server`
-- （LuaManager.java:9366-9372，回 SteamUser.GetSteamIDString()）、
-- `getSteamIDFromUsername()` 條件含 `GameClient.client`（:9470-9479）。
--
-- 伺服器收到後會做格式與一致性檢查（把字串 tonumber 後與自己的
-- `p:getSteamID()` 比對，兩邊都是同一個 long 的 double 投影），亂填會被擋下；
-- 但同一個 double bucket 裡有 15-16 個相鄰 Steam64，所以這個欄位只能算
-- client-reported, consistency-checked，不是權威值——完整說明見
-- server/MinidoracatMiniMapPlayerExport.lua 的 rememberSteamId 檔頭。
--
-- 只在 MP 客戶端且 Steam 模式下有值：單機、-nosteam 客戶端、非 Steam 伺服器一律
-- 取不到，此時整個檔案什麼都不做（匯出檔的 steamId 就留空字串）。
--
-- 送出時機：`OnGameStart`（IngameState.java:761）時 MP 連線還沒完全就緒——
-- sendPlayerConnect／onlineId 等待在 :764-767，`GameClient.ingame` 要到
-- UpdateStuff()（:563）才 true，此時 sendClientCommand 可能是 no-op。所以改成掛
-- OnTick 輪詢：等該 slot 的 `getOnlineID() ~= -1` 才送，並且每 RETRY_MS 重送一次，
-- 直到伺服器回 steamIdAck 或該 slot 送到上限次數為止。
--
-- 逐 slot 記帳（acked/tries 以 playerIndex 為鍵）：分屏時每個 slot 在伺服器上是
-- 獨立的 (username, playerIndex) 身分，各自要回報一次；伺服器的 ack 會帶 idx，
-- 不能讓第一個 slot 的 ack 把其他 slot 一起停掉。伺服器**只在驗證通過時才 ack**，
-- 所以收到 ack 就等於「這個 slot 確定寫進去了」。
-- sendClientCommand／OnServerCommand 的用法與本 MOD 導航分享同款
-- （原版 ClientCommands.lua:453、InvContextMedia.lua:36）。
local RETRY_MS = 10000   -- 送出後的重試間隔
local WAIT_MS = 1000     -- 尚未就緒時的檢查間隔（別每個 tick 都試）
local MAX_TRIES = 12     -- 每個 slot 的送出上限（約 2 分鐘）
local MAX_ID_TRIES = 30  -- 取本機 Steam ID 的重試上限（約 30 秒）

local acked = {}         -- playerIndex → true（伺服器已確認接受）
local tries = {}         -- playerIndex → 已送出次數
local nextMs = 0
local steamId = nil      -- 本機 Steam64 字串
local idTries = 0
local stopped = false

-- 只有「確定不會再有進展」才停：全部 slot 都 ack 或都用盡次數、或重試夠久仍拿不到
-- 本機 Steam ID。**暫時性的未就緒一律不能停**——OnTick 從進遊戲第一個 tick 就跑，
-- 那時 Steam API 可能還沒初始化、IsoPlayer 可能還沒建立、onlineID 還是 -1；
-- 在那個窗口放棄會讓整個 steamId 功能靜默失效，而且在非 Steam 環境下與「本來就
-- 沒有 Steam ID」完全無法區分（兩者都是安靜地什麼都沒發生）。所以停止一定要 log。
local function stop(reason)
    stopped = true
    print("[MinidoracatMiniMap] steamId report stopped: " .. reason)
end

local function readSteamId()
    local ok, s = pcall(getCurrentUserSteamID)
    if ok and type(s) == "string" and s ~= "" then return s end
    return nil
end

local function reportTick()
    if stopped then return end
    if not isClient() then return end
    local now = getTimestampMs()
    if now < nextMs then return end
    if steamId == nil then
        steamId = readSteamId()
        if steamId == nil then
            -- 可能是 Steam 還沒初始化，也可能根本是 -nosteam 客戶端；此處無法區分，
            -- 所以先有限重試，用盡才停（並 log 讓管理員分辨）
            idTries = idTries + 1
            nextMs = now + WAIT_MS
            if idTries >= MAX_ID_TRIES then
                stop("no Steam ID available after " .. idTries
                    .. " tries (non-Steam client?)")
            end
            return
        end
    end
    local last = getNumActivePlayers() - 1
    if last < 0 then
        -- 玩家物件還沒建立：等下一輪，不是放棄的理由
        nextMs = now + WAIT_MS
        return
    end
    local sent, pending = false, false
    for i = 0, last do
        if not acked[i] and (tries[i] or 0) < MAX_TRIES then
            -- 這個 slot 還沒完成——不論下面拿不拿到 player 物件都算 pending，
            -- 否則「物件還沒建立」會被誤判成「沒事可做」而永久放棄
            pending = true
            local p = getSpecificPlayer(i)
            if p then
                local okId, onlineId = pcall(function() return p:getOnlineID() end)
                if okId and type(onlineId) == "number" and onlineId ~= -1 then
                    sendClientCommand(p, "MinidoracatMiniMap", "reportSteamId",
                        { steamId = steamId })
                    tries[i] = (tries[i] or 0) + 1
                    sent = true
                end
            end
        end
    end
    nextMs = now + (sent and RETRY_MS or WAIT_MS)
    if not pending then stop("all slots acknowledged or exhausted") end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "MinidoracatMiniMap" or command ~= "steamIdAck" then return end
    local idx = args and args.idx
    if type(idx) == "number" then
        acked[math.floor(idx)] = true
    end
end)

Events.OnTick.Add(reportTick)
