-- Server-side AllowNavShare authority regression: Policy facade is mandatory and never bypassed.
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/server/MinidoracatMiniMapServer.lua"
local fh = assert(io.open(sourcePath, "rb"))
local source = fh:read("*a"):gsub("\r\n", "\n")
fh:close()
local compile = loadstring or load

local clientPath = arg[2] -- nav-share-policy 切片自 2026-09-03 起在 _Nav.lua
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Nav.lua"
local clientFile = assert(io.open(clientPath, "rb"))
local clientSource = clientFile:read("*a"):gsub("\r\n", "\n")
clientFile:close()
local clientPolicyBody = assert(clientSource:match(
    "%-%- test:nav%-share%-policy:start\n(.-)\n%-%- test:nav%-share%-policy:end"),
    "missing client nav-share policy test block")

local prefix = [==[
local sent, logs = {}, {}
local handler
local policyValue = true
local policyAvailable = false
local mirrorValue = true
local MinidoracatMiniMapPolicy = nil
local SandboxVars = { MinidoracatMiniMap = { AllowNavShare = mirrorValue } }
local Events = { OnClientCommand = { Add = function(fn) handler = fn end } }
local function print(message) logs[#logs + 1] = message end
local function player(name)
    return { getUsername = function() return name end }
end
local actor, ally, outsider = player("actor"), player("ally"), player("outsider")
local factionNames = { actor = "blue", ally = "blue", outsider = "red" }
local Faction = { getPlayerFaction = function(p)
    local name = factionNames[p:getUsername()]
    if not name then return nil end
    return { getName = function() return name end }
end }
local online = { actor, ally, outsider }
local function getOnlinePlayers()
    return {
        size = function() return #online end,
        get = function(_, index) return online[index + 1] end,
    }
end
local function sendServerCommand(target, module, command, args)
    sent[#sent + 1] = { target = target:getUsername(), module = module,
        command = command, args = args }
end
local policyObject = { readBool = function(name, default)
    if name == "AllowNavShare" then return policyValue end
    return default
end }
]==]

local tail = [==[
return {
    fire = function(command, args)
        handler("MinidoracatMiniMap", command or "shareTarget", actor,
            args or { x = 10, y = 20 })
    end,
    setPolicy = function(available, value)
        policyAvailable, policyValue = available, value
        MinidoracatMiniMapPolicy = available and policyObject or nil
    end,
    setMirror = function(value)
        mirrorValue = value
        SandboxVars.MinidoracatMiniMap.AllowNavShare = value
    end,
    sent = sent,
    logs = logs,
}
]==]

local chunk, err = compile(prefix .. "\n" .. source .. "\n" .. tail, "@server-nav-share")
assert(chunk, err)
local h = chunk()
local clientChunk, clientErr = compile([==[
local Core, Policy, logs = {}, nil, {}
local function log(message) logs[#logs + 1] = message end
local policyValue = true
local policyObject = { readBool = function(name, default)
    if name == "AllowNavShare" then return policyValue end
    return default
end }
]==] .. clientPolicyBody .. "\n" .. [==[
return {
    allowed = function() return Core.navShareAllowed() end,
    setPolicy = function(available, value)
        policyValue = value
        Policy = available and policyObject or nil
    end,
    logs = logs,
}
]==], "@client-nav-share-policy")
assert(clientChunk, clientErr)
local client = clientChunk()

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end

h.setPolicy(false, true)
h.fire(); h.fire(); h.fire("clearShared", {})
check(#h.sent == 0, "facade missing refuses share and clear")
local missingLogs = 0
for i = 1, #h.logs do
    if h.logs[i]:find("policy facade missing", 1, true) then missingLogs = missingLogs + 1 end
end
check(missingLogs == 1, "facade missing logs once")

client.setPolicy(false, true)
check(client.allowed() == false and client.allowed() == false,
    "client facade missing refuses nav share")
check(#client.logs == 1, "client facade missing logs once")
client.setPolicy(true, false)
check(client.allowed() == false, "client honors Policy false")
client.setPolicy(true, true)
check(client.allowed() == true, "client honors Policy true")

h.setPolicy(true, false)
h.setMirror(true)
h.fire()
h.fire("clearShared", {})
check(#h.sent == 0, "Policy false beats forged SandboxVars true for share and clear")

h.setPolicy(true, true)
h.fire()
check(#h.sent == 1 and h.sent[1].target == "ally"
    and h.sent[1].module == "MinidoracatMiniMap"
    and h.sent[1].command == "sharedTarget", "Policy true relays only to same faction")
check(h.sent[1].args.author == "actor" and h.sent[1].args.x == 10
    and h.sent[1].args.y == 20 and h.sent[1].args.to == "ally",
    "relay payload preserves author coordinates and recipient")

h.fire("clearShared", {})
check(#h.sent == 2 and h.sent[2].target == "ally"
    and h.sent[2].command == "clearShared", "Policy true relays clear only to same faction")
check(h.sent[2].args.author == "actor" and h.sent[2].args.to == "ally",
    "clear payload preserves author and recipient")

h.fire("shareTarget", { x = "bad", y = 20 })
check(#h.sent == 2, "invalid coordinates do not relay")

local EXPECTED_ASSERTIONS = 12
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS
        .. ", actual " .. assertions)
    os.exit(1)
end
print("server nav share assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
