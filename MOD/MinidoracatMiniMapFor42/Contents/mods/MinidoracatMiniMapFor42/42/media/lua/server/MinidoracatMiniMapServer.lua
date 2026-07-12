-- MinidoracatMiniMapServer.lua — 導航目標的陣營分享轉送（MP 伺服器端）
-- OnClientCommand 簽名（module, command, player, args）＝ClientCommands.lua:1246-1257；
-- 逐一轉送 sendServerCommand(player, module, command, args)＝ClientCommands.lua:453 用法；
-- getOnlinePlayers 用例 ClientCommands.lua:634；Faction.getPlayerFaction 用例 ISFactionUI.lua:408。
-- 伺服器端就過濾陣營＝非同陣營玩家根本收不到座標；陣營比對用名稱字串
-- （同一 Java 物件經 Kahlua 兩次包裝的 == 不可靠）。
-- SP 下 OnClientCommand 不觸發，本檔為 no-op。

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

local Commands = {}

-- payload 帶 to（收件角色名）：sendServerCommand(player,...) 定位的是該玩家的
-- connection（同機分割畫面共用一條），OnServerCommand 端收不到「給誰」——
-- 客戶端按 to 分桶，才不會讓同機的非同陣營玩家看到座標
function Commands.shareTarget(player, args)
    -- 沙盒閘門（伺服器端權威判定；客戶端 UI 亦有同步隱藏，這裡防繞過）
    local sb = SandboxVars and SandboxVars.MinidoracatMiniMap
    if sb and sb.AllowNavShare == false then return end
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
