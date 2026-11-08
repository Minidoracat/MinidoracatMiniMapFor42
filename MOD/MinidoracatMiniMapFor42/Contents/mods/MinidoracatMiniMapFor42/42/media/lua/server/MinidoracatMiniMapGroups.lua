-- MinidoracatMiniMapGroups.lua — 分享的身分與收件人判斷（MP 伺服器端；自訂道路、已清空、手繪線、導航目標共用）
-- 同陣營：Faction.getPlayerFaction(String)＋比名稱（Faction.java:123）。同安全屋：SafeHouse.isInSameSafehouse(String,String)
-- （SafeHouse.java:795，只看 owner／players 名單，管理員不會因為能進所有安全屋而收到）。
-- 名單列舉：faction:getOwner()／getPlayers()（Faction.java:241、281）、SafeHouse.getSafehouseList()／
-- getOwner()／getPlayers()（SafeHouse.java:640-658）。安全屋 MOD 代管的屋，屋主與成員也在原生名單裡。
-- 檔名排序在部分分享檔之後：呼叫端一律在執行時才查 MinidoracatMiniMapGroups，不在載入時抓。
-- server 資料夾在 MP 客戶端也會載入（GameLoadingState.java:149），故閘 isClient。
if isClient() then return end

local G = {}
MinidoracatMiniMapGroups = G

-- 身分（家族 conventions.md「玩家身分」第 1 點前兩步）：伺服器上的 getUsername() 是客戶端送來的名字。
-- 分割畫面第 2～4 位玩家走 ConnectCoopPacket 自己填名字，伺服器只擋空字串與在線重名
-- （ConnectCoopPacket.java:72-97），再直接設成 username（GameServer.java:2848）；它和主玩家共用連線，
-- 無從驗證 → nil：不能分享、不收別人的分享。主座位的重生改名要改過的客戶端才做得到，這裡沒擋
-- （SteamID 綁定是第 1 點第 3～5 步，本 MOD 沒做）；原版陣營與安全屋同樣以名字判定。
function G.principal(player)
    if not player or player:getPlayerNum() ~= 0 then return nil end
    local name = player:getUsername()
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

function G.sameFaction(a, b)
    local fa, fb = Faction.getPlayerFaction(a), Faction.getPlayerFaction(b)
    return fa ~= nil and fb ~= nil and fa:getName() == fb:getName() -- 比名稱，不比物件
end

-- share = { faction = bool, safehouse = bool }；作者自己不算收件人
function G.canSee(author, share, name)
    if author == name then return false end
    return (share.faction and G.sameFaction(author, name))
        or (share.safehouse and SafeHouse.isInSameSafehouse(author, name)) or false
end

-- 可以使用的人數（含離線）：陣營 owner＋成員、作者所在每間安全屋的 owner＋成員，去重、不含作者
function G.memberCount(author, share)
    local seen, n = {}, 0
    local function add(name)
        if name and name ~= author and not seen[name] then
            seen[name] = true
            n = n + 1
        end
    end
    local function addList(owner, list)
        add(owner)
        for i = 0, list:size() - 1 do add(list:get(i)) end
    end
    if share.faction then
        local f = Faction.getPlayerFaction(author)
        if f then addList(f:getOwner(), f:getPlayers()) end
    end
    if share.safehouse then
        local houses = SafeHouse.getSafehouseList()
        for i = 0, houses:size() - 1 do
            local h = houses:get(i)
            if h:getOwner() == author or h:getPlayers():contains(author) then addList(h:getOwner(), h:getPlayers()) end
        end
    end
    return n
end
