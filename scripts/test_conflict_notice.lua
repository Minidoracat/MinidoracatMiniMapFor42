-- 換掉原版小地圖的 MOD（TwisTonFire - Minimap）開著時，進遊戲通知一次的離線測試。
-- 抽主檔 test:conflict-notice 區段，補最小 stub 後跑 OnGameStart。
-- 用法：lua scripts/test_conflict_notice.lua [主檔路徑]
local mainPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local file = assert(io.open(mainPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local body = assert(source:match(
    "%-%- test:conflict%-notice:start\n(.-)\n%-%- test:conflict%-notice:end"),
    "找不到 conflict-notice 測試區段")

local compile = loadstring or load
local failures, checks = 0, 0
local function check(cond, label)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

-- 每個案例重新載入區段：回傳收到的 Toast、頭上提示字與 log
local function run(modIds, opts)
    opts = opts or {}
    local handler
    local toasts, halos, logs = {}, {}, {}
    Events = { OnGameStart = { Add = function(fn) handler = fn end } }
    getActivatedMods = function()
        if opts.throws then error("boom") end
        return { size = function() return #modIds end, get = function(_, i) return modIds[i + 1] end }
    end
    getText = function(key, a) return a and (key .. "|" .. a) or key end
    log = function(msg) logs[#logs + 1] = msg end
    if opts.noFramework then
        MinidoracatUI = nil
    else
        MinidoracatUI = { v1 = { CAPABILITIES = { toast = true }, Toast = {
            show = function(spec) toasts[#toasts + 1] = spec end } } }
    end
    getSpecificPlayer = function() return {} end
    HaloTextHelper = { addBadText = function(_, text) halos[#halos + 1] = text end }
    assert(compile(body))()
    check(type(handler) == "function", "registers an OnGameStart handler")
    handler()
    return toasts, halos, logs
end

-- C1：沒有衝突的 MOD，不通知
local t, h, l = run({ "MinidoracatUIFor42", "MinidoracatMiniMapFor42" })
check(#t == 0 and #h == 0 and #l == 0, "C1 no conflicting mod: no notice")

-- C2：TwisTonFire - Minimap 開著，跳一次 Toast（含 MOD 名）並寫 log
t, h, l = run({ "MinidoracatUIFor42", "twistminimap", "MinidoracatMiniMapFor42" })
check(#t == 1, "C2 one toast")
check(t[1] and t[1].message == "UI_MinidoracatMiniMap_ConflictMiniMap|TwisTonFire - Minimap", "C2 toast names the mod")
check(t[1] and t[1].title == "UI_MinidoracatMiniMap_DockLabel", "C2 toast title is the mod name")
check(#h == 0, "C2 no halo when toast works")
check(#l == 1 and l[1]:find("TwisTonFire - Minimap", 1, true) ~= nil, "C2 one log line")

-- C3：模組清單帶「\」前綴也認得
t = run({ "\\twistminimap" })
check(#t == 1, "C3 backslash-prefixed id detected")

-- C4：同作者另一個相容的 MOD（Map Improvements）不算衝突
t, h = run({ "twistmapimprovements" })
check(#t == 0 and #h == 0, "C4 TwisTonFire - MapImprovements is not a conflict")

-- C5：沒有框架 Toast 時退回玩家頭上的提示字
t, h = run({ "twistminimap" }, { noFramework = true })
check(#t == 0 and #h == 1 and h[1] == "UI_MinidoracatMiniMap_ConflictMiniMap|TwisTonFire - Minimap",
    "C5 halo fallback without framework")

-- C6：getActivatedMods 拋錯時不中斷、不通知
t, h, l = run({ "twistminimap" }, { throws = true })
check(#t == 0 and #h == 0 and #l == 0, "C6 getActivatedMods error is swallowed")

if failures > 0 then
    print(string.format("test_conflict_notice: %d checks, %d failures", checks, failures))
    os.exit(1)
end
print(string.format("test_conflict_notice: %d checks, 0 failures", checks))
