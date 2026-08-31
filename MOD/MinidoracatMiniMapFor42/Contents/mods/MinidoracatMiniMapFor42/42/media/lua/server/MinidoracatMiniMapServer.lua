-- MinidoracatMiniMapServer.lua — 導航目標的陣營分享轉送（MP 伺服器端）
-- OnClientCommand 簽名（module, command, player, args）＝ClientCommands.lua:1246-1257；
-- 逐一轉送 sendServerCommand(player, module, command, args)＝ClientCommands.lua:453 用法；
-- getOnlinePlayers 用例 ClientCommands.lua:634；Faction.getPlayerFaction 用例 ISFactionUI.lua:408。
-- 伺服器端就過濾陣營＝非同陣營玩家根本收不到座標；陣營比對用名稱字串
-- （同一 Java 物件經 Kahlua 兩次包裝的 == 不可靠）。
-- B42 SP 走 spnetwork loopback，OnClientCommand 在單機也會觸發（非舊認知的 no-op）；
-- 本檔在 SP 下亦運作，只是單機無其他線上玩家＝陣營轉送對象為空。

local function sameFactionMembers(player)
    local faction = Faction.getPlayerFaction(player)
    if not faction then return nil end
    local myName = faction:getName()
    local members = {}
    local online = getOnlinePlayers()
    for i = 0, online:size() - 1 do
        local other = online:get(i)
        if other and other:getUsername() ~= player:getUsername() then
            local f = Faction.getPlayerFaction(other)
            if f and f:getName() == myName then
                table.insert(members, other)
            end
        end
    end
    return members
end

-- 全服政策一律走 shared facade（MinidoracatMiniMap_Policy.lua）：Java
-- SandboxOptions 是真相源，SandboxVars 只是任何 MOD 都能寫的鏡像表，權限判定
-- 不能建在它上面。facade 缺席＝安裝不完整（shared 檔沒載到），此時**拒收**而
-- 不是退回直讀鏡像表——本路徑會請伺服器代發座標給其他玩家，寧可停用。
-- 刻意不傳 playerNum：AllowNavShare 不在任何管理員旁路白名單上（見 facade
-- 檔頭「永不旁路」），連呼叫形式上都不給旁路的機會。
local policyWarned = false
local function navShareAllowed()
    local P = MinidoracatMiniMapPolicy
    if not P then
        if not policyWarned then
            policyWarned = true
            print("[MinidoracatMiniMap] policy facade missing, nav share refused")
        end
        return false
    end
    return P.readBool("AllowNavShare", true)
end

local Commands = {}

-- payload 帶 to（收件角色名）：sendServerCommand(player,...) 定位的是該玩家的
-- connection（同機分割畫面共用一條），OnServerCommand 端收不到「給誰」——
-- 客戶端按 to 分桶，才不會讓同機的非同陣營玩家看到座標
function Commands.shareTarget(player, args)
    -- 沙盒閘門（伺服器端權威判定；客戶端 UI 亦有同步隱藏，這裡防繞過）
    if not navShareAllowed() then return end
    if not (args and type(args.x) == "number" and type(args.y) == "number") then return end
    local members = sameFactionMembers(player)
    if not members then return end
    local author = player:getUsername()
    for i = 1, #members do
        sendServerCommand(members[i], "MinidoracatMiniMap", "sharedTarget",
            { author = author, x = args.x, y = args.y, to = members[i]:getUsername() })
    end
end

function Commands.clearShared(player, args)
    -- 清除同樣是跨玩家封包；政策缺席／關閉時不可讓手工 ClientCommand 繞過。
    if not navShareAllowed() then return end
    local members = sameFactionMembers(player)
    if not members then return end
    local author = player:getUsername()
    for i = 1, #members do
        sendServerCommand(members[i], "MinidoracatMiniMap", "clearShared",
            { author = author, to = members[i]:getUsername() })
    end
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "MinidoracatMiniMap" then return end
    local fn = Commands[command]
    if fn then fn(player, args) end
end)
