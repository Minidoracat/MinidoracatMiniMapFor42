-- 管理員政策 facade（shared/MinidoracatMiniMap_Policy.lua）離線回歸。
--
-- ══ 為什麼抽「整份原檔（除檔尾發布那行）」而不是只抽 test:admin-policy 區段 ══
--   權限洩漏面有一半在 PZ API 區：槽位驗證（借用 slot 0 就是越權）與
--   Capability 常數表缺席／拋錯。那幾條若在測試裡用自己寫的 stub 取代，
--   測的就是自己寫的 stub。故本檔抽「檔頭 → test:admin-policy:end」整段
--   （＝原檔除事件註冊與檔尾全域發布），只把 6 個 PZ 全域
--   （getTimestampMs／isClient／getSandboxOptions／getSpecificPlayer／
--   SandboxVars／Capability）換成可控假物件，再於尾端把 facade、seam
--   函式與內部 origin 一起 return 出來。
--   每呼叫一次 factory() 就是一份全新的 snapshot/snapMs/revision（Lua 的 local
--   逐次呼叫各自一份），所以每個情境拿到的都是乾淨 facade，不必反解內部狀態。
--
-- ══ 假世界的切換規則 ══
--   PZ 全域一律讀「當前世界」W；activate(w) 另把 SandboxVars／Capability 兩個
--   *表*型全域指到該世界（那兩個不是函式，沒法延後解參考）。因此同時只有一個
--   世界是活的——每個群組建自己的 instance 並在群組內用完，不跨群組回頭用。
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/shared/MinidoracatMiniMap_Policy.lua"
local sandboxPath = arg[2]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/sandbox-options.txt"

local function readAll(path)
    local fh = assert(io.open(path, "rb"), "開不了 " .. path)
    local text = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    return text
end

local source = readAll(sourcePath)
local sandboxSrc = readAll(sandboxPath)
local compile = loadstring or load

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected)
        .. ", actual=" .. tostring(actual) .. ")")
end

--------------------------------------------------------------------------------
-- 原檔抽取
--------------------------------------------------------------------------------
local prefix = assert(source:match("^(.-)\n%-%- test:admin%-policy:start\n"),
    "找不到 test:admin-policy:start（PZ API 區邊界）")
local body = assert(source:match(
    "\n%-%- test:admin%-policy:start\n(.-)\n%-%- test:admin%-policy:end"),
    "找不到 test:admin-policy 區段")

-- 尾端把內部狀態一起導出：origin 讓「Java 優先 → SandboxVars → 預設」可以直接
-- 斷言來源（只比值會被同值巧合蓋過去），seams 讓 PZ API 區的韌性可以逐條測。
local TAIL = [=[
return {
    policy = Policy,
    origin = origin,
    schema = SCHEMA,
    schemaN = SCHEMA_N,
    ttlMs = TTL_MS,
    numLimit = NUM_LIMIT,
    tacticalKeys = TACTICAL_KEYS,
    privacyKeys = PRIVACY_KEYS,
    seams = {
        nowMs = nowMs,
        isMpClient = isMpClient,
        readJavaOption = readJavaOption,
        sandboxTable = sandboxTable,
        playerOf = playerOf,
        clearLocalSlot = clearLocalSlot,
        clearLocalFlags = clearLocalFlags,
    },
}
]=]
local factory, compileErr = compile(prefix .. "\n" .. body .. "\n" .. TAIL, "@policy-under-test")
assert(factory, compileErr)

--------------------------------------------------------------------------------
-- 假 PZ 世界
--------------------------------------------------------------------------------
local CAP_TOKEN = "CAP:CanSeeAll" -- Capability.CanSeeAll 的值（刻意不是可猜的字串）
local FLAG_T = "MinidoracatMiniMapAdminTacticalView"
local FLAG_P = "MinidoracatMiniMapAdminPrivacyView"

local W -- 當前世界

local function activate(w)
    W = w
    SandboxVars = w.sandboxVars
    Capability = w.capability
end

function getTimestampMs()
    W.clockCalls = (W.clockCalls or 0) + 1
    if W.clockThrow then error("getTimestampMs boom") end
    return W.now
end

function isClient()
    if W.clientThrow then error("isClient boom") end
    return W.mpClient
end

function getSandboxOptions()
    if W.optsThrow then error("getSandboxOptions boom") end
    if W.noOpts then return nil end
    return W.opts
end

function getSpecificPlayer(pn)
    if W.playerThrow then error("getSpecificPlayer boom") end
    return W.players[pn]
end

-- 假玩家：cfg 掛在物件上，測試可即時翻轉權限（模擬 Role 被改）。
local function newPlayer(cfg)
    cfg = cfg or {}
    local p = { cfg = cfg, md = cfg.md or {} }
    p.getRole = function()
        if cfg.roleThrow then error("getRole boom") end
        if cfg.roleNil then return nil end
        return {
            hasCapability = function(_, cap)
                if cfg.capThrow then error("hasCapability boom") end
                if cfg.capTruthy then return "yes" end -- 真值但不是 true
                return cap == CAP_TOKEN and cfg.canSeeAll == true
            end,
        }
    end
    p.getModData = function()
        if cfg.mdThrow then error("getModData boom") end
        if cfg.mdBad then return "not-a-table" end
        return p.md
    end
    return p
end

local function newWorld(cfg)
    cfg = cfg or {}
    local w = {
        now = cfg.now,
        clockCalls = 0,
        mpClient = cfg.mpClient == true,
        java = cfg.java or {},        -- 短鍵名 → Java getValue() 回傳值
        players = cfg.players or {},
        capability = cfg.capability,
        sandboxVars = cfg.sandboxVars,
        asked = {},                   -- 被查詢過的完整選項名（驗前綴）
        noOpts = cfg.noOpts,
        optsThrow = cfg.optsThrow,
        javaThrow = cfg.javaThrow,
        clockThrow = cfg.clockThrow,
        clientThrow = cfg.clientThrow,
        playerThrow = cfg.playerThrow,
    }
    if cfg.now == nil and not cfg.noClock then w.now = 1000 end
    if cfg.capability == nil and not cfg.noCapability then
        w.capability = { CanSeeAll = CAP_TOKEN }
    end
    if cfg.sandbox ~= nil then w.sandboxVars = { MinidoracatMiniMap = cfg.sandbox } end
    w.opts = {
        getOptionByName = function(_, full)
            w.asked[full] = (w.asked[full] or 0) + 1
            if w.javaThrow then error("getOptionByName boom") end
            -- 只認帶 MOD 前綴的名稱：讀值路徑漏掉前綴就會全鍵落空
            local short = full and full:match("^MinidoracatMiniMap%.(.+)$")
            if short == nil then return nil end
            local v = w.java[short]
            if v == nil then return nil end
            return { getValue = function() return v end }
        end,
    }
    return w
end

local function newPolicy(cfg)
    local w = newWorld(cfg)
    activate(w)
    local inst = factory()
    inst.world = w
    return inst
end

--------------------------------------------------------------------------------
-- 1. 來源優先序：Java（真相源）→ SandboxVars（鏡像）→ SCHEMA 預設
--------------------------------------------------------------------------------
local A = newPolicy{
    java = { AllowZombieDots = false, AllInfoDistance = 100 },
    sandbox = { AllowZombieDots = true, AllInfoDistance = 50, AllowVehicleDots = false },
}
checkEq(A.policy.read("AllowZombieDots"), false, "Java 值蓋過 SandboxVars（boolean）")
checkEq(A.origin.AllowZombieDots, "java", "來源標記＝java")
checkEq(A.policy.read("AllInfoDistance"), 100, "Java 值蓋過 SandboxVars（number）")
checkEq(A.policy.read("AllowVehicleDots"), false, "Java 缺鍵時退到 SandboxVars")
checkEq(A.origin.AllowVehicleDots, "sandboxvars", "來源標記＝sandboxvars")
checkEq(A.policy.read("AllowAnimalDots"), true, "兩層皆缺時用 SCHEMA 預設")
checkEq(A.origin.AllowAnimalDots, "default", "來源標記＝default")
local unprefixed = 0
for name in pairs(A.world.asked) do
    if not name:match("^MinidoracatMiniMap%.") then unprefixed = unprefixed + 1 end
end
check(A.world.asked["MinidoracatMiniMap.AllowZombieDots"], "Java 查詢帶 MOD 前綴")
checkEq(unprefixed, 0, "沒有任何一次查詢漏掉 MOD 前綴")

-- 呼叫端 default 的語意：只有「值來自 SCHEMA 預設」時才讓位（伺服器端的權限鍵
-- 一律傳 false＝缺政策就 fail-closed）；來自兩層來源的實值不被 default 蓋掉。
checkEq(A.policy.read("AllowAnimalDots", false), false, "SCHEMA 預設時呼叫端 default 優先（fail-closed）")
checkEq(A.policy.read("AllowVehicleDots", true), false, "SandboxVars 實值不被呼叫端 default 蓋掉")
checkEq(A.policy.read("BogusKey", 42), 42, "未知鍵回呼叫端 default")
checkEq(A.policy.read(nil, 42), 42, "非字串鍵回呼叫端 default（不拋錯）")
checkEq(A.policy.readBool("AllInfoDistance", true), true, "readBool 遇非布林＝退回布林 default")
checkEq(A.policy.readBool("AllInfoDistance"), false, "readBool 無布林 default 回 false")
checkEq(A.policy.readNumber("AllowZombieDots", 9), 9, "readNumber 遇非數字＝退回數字 default")
checkEq(A.policy.readNumber("AllowZombieDots"), 0, "readNumber 無數字 default 回 0")
checkEq(A.policy.readNumber("AllInfoDistance", 7), 100, "readNumber 直出數字值")

--------------------------------------------------------------------------------
-- 2. 型別淨化：型別不符／NaN／inf／離譜值域一律視為「這個來源沒有合法值」
--    （非法值進到距離比較會讓閘門行為無法預測，且不能被 or 判成放行）
--------------------------------------------------------------------------------
local B = newPolicy{
    java = {
        AllowZombieDots = "true",          -- 字串不是布林
        AllowAnimalDots = 1,               -- 數字不是布林
        AllInfoDistance = 0 / 0,           -- NaN
        ZombieDotDistance = math.huge,     -- +inf
        AnimalIconDistance = -math.huge,   -- -inf
        VehicleIconDistance = 2000000000,  -- 超出 ±1e9
        PoiDisplayDistance = "500",        -- 字串不是數字
        PlayerExportInterval = 1000000000, -- 恰在界內（邊界值必須被接受）
    },
    sandbox = { AllowZombieDots = true, AllInfoDistance = 250, SafehouseDisplay = "3" },
}
checkEq(B.policy.read("AllowZombieDots"), true, "布林鍵收到字串＝退到 SandboxVars")
checkEq(B.origin.AllowZombieDots, "sandboxvars", "字串沒被當成合法 Java 布林值")
checkEq(B.policy.read("AllowAnimalDots"), true, "布林鍵收到數字＝退到 SCHEMA 預設")
checkEq(B.policy.read("AllInfoDistance"), 250, "NaN 被丟棄＝退到 SandboxVars")
checkEq(B.policy.read("ZombieDotDistance"), 0, "+inf 被丟棄＝退到 SCHEMA 預設")
checkEq(B.policy.read("AnimalIconDistance"), 0, "-inf 被丟棄")
checkEq(B.policy.read("VehicleIconDistance"), 0, "超出 ±1e9 被丟棄")
checkEq(B.policy.read("PoiDisplayDistance"), 0, "數字鍵收到字串被丟棄（不做隱式轉型）")
checkEq(B.policy.read("PlayerExportInterval"), 1000000000, "±1e9 邊界值被接受")
checkEq(B.policy.read("SafehouseDisplay"), 3, "鏡像表的非法值也被丟棄")
checkEq(B.origin.SafehouseDisplay, "default", "鏡像表非法值不算來源")

--------------------------------------------------------------------------------
-- 3. 鏡像回寫：單機／伺服器端補齊 SandboxVars 自家鍵，MP 客戶端一律不寫
--    （客戶端那張表是伺服器同步下來的，本機改它只會製造「我以為政策變了」）
--------------------------------------------------------------------------------
local sbSP = { AllowZombieDots = false }
local C = newPolicy{ mpClient = false, java = { AllowZombieDots = true }, sandbox = sbSP }
checkEq(C.policy.refresh(true), true, "首次解析回報變動")
checkEq(sbSP.AllowZombieDots, true, "SP：Java 值回寫鏡像表（舊程式碼看到同一份值）")
checkEq(sbSP.AllowAdminTacticalView, false, "SP：缺鍵補成 SCHEMA 預設（旁路預設關閉）")
C.world.clientThrow = true
checkEq(C.seams.isMpClient(), false, "isClient 拋錯＝視為非 MP 客戶端")
C.world.clientThrow = false

local sbMP = { AllowZombieDots = false }
local D = newPolicy{ mpClient = true, java = { AllowZombieDots = true }, sandbox = sbMP }
D.policy.refresh(true)
checkEq(sbMP.AllowZombieDots, false, "MP 客戶端不回寫鏡像表")
checkEq(sbMP.AllowAdminTacticalView, nil, "MP 客戶端不補鍵")
checkEq(D.policy.read("AllowZombieDots"), true, "MP 客戶端仍以 Java 值為準")

local E = newPolicy{ java = { AllowZombieDots = false } } -- SandboxVars 全域不存在
checkEq(E.seams.sandboxTable(), nil, "SandboxVars 缺席＝seam 回 nil（不憑空建表）")
checkEq(E.policy.refresh(true), true, "無鏡像表也能解析（不拋錯）")
checkEq(E.policy.read("AllowZombieDots"), false, "無鏡像表時 Java 值仍生效")
E.world.sandboxVars = {}; activate(E.world) -- 有 SandboxVars 但沒有本 MOD 的子表
checkEq(E.seams.sandboxTable(), nil, "沒有 MinidoracatMiniMap 子表＝回 nil")

--------------------------------------------------------------------------------
-- 4. 250ms 快照：TTL／force／revision／時鐘異常
--------------------------------------------------------------------------------
local F = newPolicy{ now = 1000, java = { AllowZombieDots = true } }
checkEq(F.ttlMs, 250, "TTL 契約＝250ms")
checkEq(F.numLimit, 1000000000, "數字值域契約＝±1e9")
checkEq(F.policy.read("AllowZombieDots"), true, "首讀建立快照")
local rev0 = F.policy.getRevision()
check(rev0 >= 1, "首次解析推進 revision")
F.world.java.AllowZombieDots = false
F.world.now = 1249
checkEq(F.policy.refresh(false), false, "TTL 內不重讀")
checkEq(F.policy.read("AllowZombieDots"), true, "TTL 內沿用舊快照")
checkEq(F.policy.getRevision(), rev0, "沒重讀就不推進 revision")
F.world.now = 1250
checkEq(F.policy.refresh(false), true, "TTL 到期重讀並回報變動")
checkEq(F.policy.read("AllowZombieDots"), false, "重讀後拿到新值")
checkEq(F.policy.getRevision(), rev0 + 1, "值變動推進 revision（UI 重建訊號）")
F.world.now = 1500
checkEq(F.policy.refresh(false), false, "值沒變的重讀不回報變動")
checkEq(F.policy.getRevision(), rev0 + 1, "值沒變不推進 revision")
F.world.java.AllowZombieDots = true
checkEq(F.policy.refresh(true), true, "force 忽略 TTL（設定視窗開窗用）")
checkEq(F.policy.getRevision(), rev0 + 2, "force 讀到新值才推進 revision")
F.world.java.AllowZombieDots = false
checkEq(F.policy.refresh("yes"), false, "非 true 的參數不算 force")
checkEq(F.policy.read("AllowZombieDots"), true, "非 force 且 TTL 內＝值不動")
F.world.now = 500 -- 時鐘倒退（系統時間跳動／存檔載入）
checkEq(F.policy.refresh(false), true, "時鐘倒退時重讀，不把快照凍結在舊值上")

local G = newPolicy{ noClock = true, java = { AllowZombieDots = true } }
checkEq(G.seams.nowMs(), nil, "getTimestampMs 回 nil＝seam 回 nil")
checkEq(G.policy.read("AllowZombieDots"), true, "無時鐘仍能解析")
G.world.java.AllowZombieDots = false
checkEq(G.policy.refresh(false), true, "取不到時間＝每次都重讀（寧可多花成本）")
G.world.now = 0 / 0
checkEq(G.seams.nowMs(), nil, "getTimestampMs 回 NaN＝視為取不到")
G.world.now = nil
G.world.clockThrow = true
checkEq(G.seams.nowMs(), nil, "getTimestampMs 拋錯＝視為取不到")
G.world.clockThrow = false

--------------------------------------------------------------------------------
-- 5. Java seam 韌性：任何一環缺席／拋錯都必須是「無值」，不能把讀值路徑炸掉
--------------------------------------------------------------------------------
local H = newPolicy{ java = { AllowZombieDots = false }, sandbox = { AllowZombieDots = true } }
checkEq(H.seams.readJavaOption("MinidoracatMiniMap.AllowZombieDots"), false, "seam 讀得到 Java 值")
checkEq(H.seams.readJavaOption("MinidoracatMiniMap.Bogus"), nil, "未知選項回 nil")
checkEq(H.seams.readJavaOption("AllowZombieDots"), nil, "沒有前綴的名稱不會誤命中")
H.world.javaThrow = true
checkEq(H.seams.readJavaOption("MinidoracatMiniMap.AllowZombieDots"), nil, "getOptionByName 拋錯回 nil")
H.policy.refresh(true)
checkEq(H.policy.read("AllowZombieDots"), true, "Java 拋錯時退到 SandboxVars")
H.world.javaThrow = false
H.world.noOpts = true
H.policy.refresh(true)
checkEq(H.policy.read("AllowZombieDots"), true, "getSandboxOptions 回 nil 時退到 SandboxVars")
H.world.noOpts = false
H.world.optsThrow = true
H.policy.refresh(true)
checkEq(H.policy.read("AllowZombieDots"), true, "getSandboxOptions 拋錯時退到 SandboxVars")
H.world.optsThrow = false
H.policy.refresh(true)
checkEq(H.policy.read("AllowZombieDots"), false, "Java 恢復後值回到真相源")

--------------------------------------------------------------------------------
-- 6. 槽位驗證從嚴：非整數／越界一律 nil，絕不退回 slot 0（借用權限＝洩漏）
--------------------------------------------------------------------------------
local pAdmin = newPlayer{ canSeeAll = true }
local I = newPolicy{
    players = { [0] = pAdmin, [1] = newPlayer{ canSeeAll = true },
                [4] = pAdmin, [-1] = pAdmin, [1.5] = pAdmin },
}
check(I.seams.playerOf(0) == pAdmin, "slot 0 取得玩家")
checkEq(I.seams.playerOf(4), nil, "slot 4 越界＝nil（即使該索引真有玩家）")
checkEq(I.seams.playerOf(-1), nil, "負 slot＝nil")
checkEq(I.seams.playerOf(1.5), nil, "非整數 slot＝nil")
checkEq(I.seams.playerOf(0 / 0), nil, "NaN slot＝nil（範圍比較擋不住，需自比）")
checkEq(I.seams.playerOf("0"), nil, "字串 slot＝nil")
checkEq(I.seams.playerOf(nil), nil, "nil slot＝nil")
checkEq(I.policy.hasCanSeeAll(4), false, "越界 slot 沒有權限")
checkEq(I.policy.hasCanSeeAll(2), false, "空 slot 沒有權限")
checkEq(I.policy.hasCanSeeAll(0), true, "有 CanSeeAll 的 slot 回 true")
I.world.playerThrow = true
checkEq(I.policy.hasCanSeeAll(0), false, "取不到玩家＝無權限")
I.world.playerThrow = false

--------------------------------------------------------------------------------
-- 7. Role／Capability 韌性：缺席一律視為無權限；私有旗標不碰 player modData
--------------------------------------------------------------------------------
local J = newPolicy{
    players = { [0] = newPlayer{ canSeeAll = true },
                [1] = newPlayer{ roleNil = true, canSeeAll = true },
                [2] = newPlayer{ roleThrow = true, canSeeAll = true },
                [3] = newPlayer{ capThrow = true, canSeeAll = true } },
}
checkEq(J.policy.hasCanSeeAll(0), true, "Role 有 CanSeeAll＝true")
checkEq(J.policy.hasCanSeeAll(1), false, "getRole 回 nil＝無權限")
checkEq(J.policy.hasCanSeeAll(2), false, "getRole 拋錯＝無權限")
checkEq(J.policy.hasCanSeeAll(3), false, "hasCapability 拋錯＝無權限")
J.world.capability = nil; activate(J.world)
checkEq(J.policy.hasCanSeeAll(0), false, "Capability 常數表缺席（單機／舊版）＝無權限")
J.world.capability = {}; activate(J.world)
checkEq(J.policy.hasCanSeeAll(0), false, "Capability.CanSeeAll 缺席＝無權限")
J.world.capability = { CanSeeAll = CAP_TOKEN }; activate(J.world)
checkEq(J.policy.hasCanSeeAll(0), true, "Capability 回復後權限恢復")
local J2 = newPolicy{ players = { [0] = newPlayer{ capTruthy = true } } }
checkEq(J2.policy.hasCanSeeAll(0), false, "hasCapability 回非 true 的真值＝無權限")

local K = newPolicy{
    java = { AllowAdminTacticalView = true },
    players = { [0] = newPlayer{ canSeeAll = true, mdBad = true },
                [1] = newPlayer{ canSeeAll = true, mdThrow = true } },
}
checkEq(K.policy.setLocalTactical(0, true), true,
    "getModData 回非表不影響 facade 私有旗標")
checkEq(K.policy.tacticalActive(0), true, "私有旗標仍可生效")
checkEq(K.world.players[0].md[FLAG_T], nil, "私有旗標不寫 player modData")
checkEq(K.policy.setLocalTactical(1, true), true,
    "getModData 拋錯不影響 facade 私有旗標")
checkEq(K.world.players[1].md[FLAG_T], nil, "拋錯的 modData 同樣完全不接觸")

--------------------------------------------------------------------------------
-- 8. 三把鑰匙（全服政策＋引擎權限＋本機旗標）與戰術／隱私分層
--------------------------------------------------------------------------------
local L = newPolicy{
    java = { AllowAdminTacticalView = true, AllowAdminPrivacyView = true },
    players = { [0] = newPlayer{ canSeeAll = true } },
}
local L0 = L.world.players[0]
checkEq(L0.md[FLAG_T], nil, "啟用前沒有舊 tactical modData 鍵")
checkEq(L0.md[FLAG_P], nil, "啟用前沒有舊 privacy modData 鍵")
checkEq(L.policy.tacticalActive(0), false, "政策＋權限俱備但旗標未開＝不生效")
checkEq(L.policy.setLocalTactical(0, true), true, "政策＋權限俱備＝可開旗標")
checkEq(L.policy.localTactical(0), true, "旗標已存下")
checkEq(L0.md[FLAG_T], nil, "旗標只存在 facade 私有 table，不寫 player modData")
checkEq(L.policy.tacticalActive(0), true, "三把鑰匙齊備＝戰術層生效")
L.world.java.AllowAdminTacticalView = false
L.policy.refresh(true)
checkEq(L.policy.tacticalActive(0), false, "政策關閉＝旁路立即失效（殘留旗標無效）")
checkEq(L.policy.localTactical(0), true, "旗標本身還在（政策是另一把鑰匙）")
checkEq(L.policy.setLocalTactical(0, true), false, "政策不允許時 setter 回實際值 false")
L.world.java.AllowAdminTacticalView = true
L.policy.refresh(true)
checkEq(L.policy.tacticalActive(0), true, "政策回開＝恢復")
L0.cfg.canSeeAll = false
checkEq(L.policy.tacticalActive(0), false, "失去 CanSeeAll＝旁路失效（role eligibility 即時）")
checkEq(L.policy.setLocalTactical(0, true), false, "沒有 CanSeeAll 時 setter 回 false")
L0.cfg.canSeeAll = true

checkEq(L.policy.privacyActive(0), false, "隱私旗標未開＝隱私層不生效")
checkEq(L.policy.setLocalPrivacy(0, true), true, "戰術層生效時可開隱私旗標")
checkEq(L.policy.privacyActive(0), true, "隱私政策＋隱私旗標＋戰術層＝生效")
L0.cfg.canSeeAll = false
checkEq(L.policy.tacticalActive(0), false, "隱私旗標仍開時，失去 CanSeeAll 也關閉戰術層")
checkEq(L.policy.privacyActive(0), false, "隱私旗標仍開時，失去 CanSeeAll 也關閉隱私層")
checkEq(L.policy.localPrivacy(0), true, "權限撤回不竄改本機隱私偏好")
L0.cfg.canSeeAll = true
checkEq(L.policy.privacyActive(0), true, "CanSeeAll 恢復後三把鑰匙重新生效")
L.world.java.AllowAdminTacticalView = false
L.policy.refresh(true)
checkEq(L.policy.privacyActive(0), false, "戰術政策撤回時隱私旗標不能單獨旁路")
L.world.java.AllowAdminTacticalView = true
L.policy.refresh(true)
checkEq(L.policy.privacyActive(0), true, "戰術政策恢復後既有隱私偏好重新生效")
L.world.java.AllowAdminPrivacyView = false
L.policy.refresh(true)
checkEq(L.policy.privacyActive(0), false, "隱私政策關閉＝隱私層失效")
checkEq(L.policy.tacticalActive(0), true, "隱私政策關閉不影響戰術層")
checkEq(L.policy.setLocalPrivacy(0, true), false, "隱私政策不允許時 setter 回 false")
L.world.java.AllowAdminPrivacyView = true
L.policy.refresh(true)
checkEq(L.policy.privacyActive(0), true, "隱私政策回開＝恢復")

local revBefore = L.policy.getRevision()
checkEq(L.policy.setLocalTactical(0, false), false, "關閉一律成功，回實際值 false")
checkEq(L.policy.localTactical(0), false, "戰術旗標已關")
checkEq(L.policy.localPrivacy(0), false, "關戰術層連帶清掉隱私旗標（不留看不見的開關）")
checkEq(L.policy.privacyActive(0), false, "戰術層關掉＝隱私層一律無效")
check(L.policy.getRevision() > revBefore, "旗標變動推進 revision")
checkEq(L.policy.setLocalPrivacy(0, true), false, "戰術層未生效時開不了隱私層")
checkEq(L.policy.localPrivacy(0), false, "被拒的隱私 setter 沒有寫入")
checkEq(L.policy.setLocalTactical(0, true), true, "重新開啟")
local revStable = L.policy.getRevision()
checkEq(L.policy.setLocalTactical(0, true), true, "重複開啟仍回 true")
checkEq(L.policy.getRevision(), revStable, "同值寫入不推進 revision（免無效重建）")

-- 逐 slot 獨立（分割畫面四人各有自己的旗標，不共用、不借用 slot 0）
local M = newPolicy{
    java = { AllowAdminTacticalView = true, AllowAdminPrivacyView = true },
    players = { [0] = newPlayer{ canSeeAll = true }, [1] = newPlayer{ canSeeAll = true },
                [2] = newPlayer{ canSeeAll = false } },
}
checkEq(M.policy.setLocalTactical(0, true), true, "slot 0 開啟")
checkEq(M.policy.tacticalActive(0), true, "slot 0 生效")
checkEq(M.policy.localTactical(1), false, "slot 1 旗標獨立")
checkEq(M.policy.tacticalActive(1), false, "slot 1 不受益於 slot 0 的旗標")
checkEq(M.world.players[1].md[FLAG_T], nil, "沒開的 slot 連鍵都沒寫進 modData")
checkEq(M.policy.setLocalTactical(2, true), false, "沒有 CanSeeAll 的 slot 開不了")
checkEq(M.policy.tacticalActive(2), false, "沒權限的 slot 無旁路")
M.policy.setLocalTactical(1, true)
M.policy.setLocalTactical(0, false)
checkEq(M.policy.localTactical(1), true, "關 slot 0 不動 slot 1")
local invalidClearRev = M.policy.getRevision()
local invalidNilOk = pcall(M.seams.clearLocalSlot, nil)
local invalidNanOk = pcall(M.seams.clearLocalSlot, 0 / 0)
check(invalidNilOk and invalidNanOk, "非法 slot 清除不拋錯")
checkEq(M.policy.getRevision(), invalidClearRev, "非法 slot 不清旗標也不推 revision")

local slotResetRev = M.policy.getRevision()
M.seams.clearLocalSlot(1)
checkEq(M.policy.localTactical(1), false, "OnCreatePlayer 清掉該 slot 的本機旗標")
check(M.policy.getRevision() > slotResetRev, "清掉已開旗標會推進 revision")
M.policy.setLocalTactical(0, true)
M.policy.setLocalTactical(1, true)
local allResetRev = M.policy.getRevision()
M.seams.clearLocalFlags()
check(not M.policy.localTactical(0) and not M.policy.localTactical(1),
    "OnGameStart／OnDisconnect 清掉全部 slot")
check(M.policy.getRevision() > allResetRev, "全清已開旗標會推進 revision")

--------------------------------------------------------------------------------
-- 9. 布林閘門與白名單（名單外的鍵沒有任何路徑可以旁路）
--------------------------------------------------------------------------------
local N = newPolicy{
    java = { AllowAdminTacticalView = true, AllowAdminPrivacyView = true,
             AllowZombieDots = false, AllowZombieIntensity = false,
             AllowAnimalDots = false, AllowVehicleDots = false,
             AllowNavShare = false, ExportPlayerPositions = false,
             ExportOfflinePlayers = false, ZombieDotDistance = 50 },
    players = { [0] = newPlayer{ canSeeAll = true } },
}
checkEq(N.policy.gate("AllowZombieDots", true, 0), false, "旁路未開＝gate 回政策值")
checkEq(N.policy.setLocalTactical(0, true), true, "開啟戰術層")
checkEq(N.policy.gate("AllowZombieDots", true, 0), true, "戰術層生效＝白名單布林鍵強制放行")
checkEq(N.policy.gate("AllowZombieIntensity", true, 0), true, "殭屍密度同屬戰術白名單")
checkEq(N.policy.gate("AllowAnimalDots", true, 0), true, "動物點同屬戰術白名單")
checkEq(N.policy.gate("AllowVehicleDots", true, 0), true, "載具點同屬戰術白名單")
checkEq(N.policy.gate("AllowNavShare", true, 0), false, "AllowNavShare 永不旁路（通訊非檢視）")
checkEq(N.policy.gate("ExportPlayerPositions", true, 0), false, "座標匯出永不旁路（I/O 政策）")
checkEq(N.policy.gate("ExportOfflinePlayers", true, 0), false, "離線匯出永不旁路")
N.world.java.AllowAdminPrivacyView = false
N.policy.refresh(true)
checkEq(N.policy.gate("AllowAdminPrivacyView", true, 0), false, "旁路開關自身永不旁路（不能自我授權）")
checkEq(N.policy.tacticalActive(0), true, "隱私政策關閉後戰術層仍生效")
checkEq(N.policy.gate("ZombieDotDistance", 0, 0), 50, "距離鍵誤傳 gate 也只回政策值（不會變 true）")
checkEq(N.policy.gate("BogusKey", "fallback", 0), "fallback", "未知鍵回呼叫端 default")
checkEq(N.policy.gate("AllowZombieDots", true, 1), false, "旁路逐 slot：別的 slot 不受益")

local kinds = {}
for i = 1, N.schemaN do
    kinds[N.schema[i][1]] = N.schema[i][2]
end
local NEVER_BYPASS = { "AllowNavShare", "ExportPlayerPositions", "PlayerExportInterval",
    "ExportOfflinePlayers", "AllowAdminTacticalView", "AllowAdminPrivacyView" }
for i = 1, 6 do
    checkEq(N.tacticalKeys[NEVER_BYPASS[i]], nil,
        "永不旁路鍵不在戰術白名單：" .. NEVER_BYPASS[i])
    checkEq(N.privacyKeys[NEVER_BYPASS[i]], nil,
        "永不旁路鍵不在隱私白名單：" .. NEVER_BYPASS[i])
end
local tacticalCount, privacyCount, overlap, unknownWhitelisted = 0, 0, 0, 0
for key in pairs(N.tacticalKeys) do
    tacticalCount = tacticalCount + 1
    if N.privacyKeys[key] then overlap = overlap + 1 end
    if kinds[key] == nil then unknownWhitelisted = unknownWhitelisted + 1 end
end
for key in pairs(N.privacyKeys) do
    privacyCount = privacyCount + 1
    if kinds[key] == nil then unknownWhitelisted = unknownWhitelisted + 1 end
end
checkEq(tacticalCount, 10, "戰術白名單成員數（4 布林＋6 距離）")
checkEq(privacyCount, 1,
    "隱私白名單只含距離鍵（模式鍵的旁路在 safehouseMode／livestockMode 內判）")
checkEq(overlap, 0, "兩張白名單不重疊")
checkEq(unknownWhitelisted, 0, "白名單沒有 schema 外的鍵（打錯字＝永遠不命中）")

--------------------------------------------------------------------------------
-- 10. 距離閘門：nil＝不限；0／負值＝不限；AllInfoDistance 為全域上限
--------------------------------------------------------------------------------
local O = newPolicy{
    java = { AllInfoDistance = 100, ZombieDotDistance = 500, AnimalIconDistance = 50,
             VehicleIconDistance = 0, PoiDisplayDistance = -20,
             SafehouseDisplayDistance = 500,
             AllowAdminTacticalView = true, AllowAdminPrivacyView = true },
    players = { [0] = newPlayer{ canSeeAll = true } },
}
checkEq(O.policy.sandboxDistance("ZombieDotDistance", 0), 100, "個別值大於全域上限＝取上限")
checkEq(O.policy.sandboxDistance("AnimalIconDistance", 0), 50, "個別值更嚴＝取個別值")
checkEq(O.policy.sandboxDistance("VehicleIconDistance", 0), 100, "個別值 0（不限）仍受全域上限")
checkEq(O.policy.sandboxDistance("PoiDisplayDistance", 0), 100, "負值視為不限，仍受全域上限")
checkEq(O.policy.sandboxDistance("SafehouseDisplayDistance", 0), 100, "安全屋距離也受全域上限")
O.world.java.AllInfoDistance = 0
O.policy.refresh(true)
checkEq(O.policy.sandboxDistance("ZombieDotDistance", 0), 500, "無全域上限＝個別值直出")
checkEq(O.policy.sandboxDistance("VehicleIconDistance", 0), nil, "0＝不限距離（nil）")
checkEq(O.policy.sandboxDistance("PoiDisplayDistance", 0), nil, "負值＝不限距離（nil）")
O.world.java.AllInfoDistance = 100
O.policy.refresh(true)
checkEq(O.policy.setLocalTactical(0, true), true, "開啟戰術層")
checkEq(O.policy.sandboxDistance("ZombieDotDistance", 0), nil, "戰術層生效＝白名單距離鍵不限")
checkEq(O.policy.sandboxDistance("AnimalIconDistance", 0), nil, "更嚴的個別值也一併解除")
checkEq(O.policy.sandboxDistance("SafehouseDisplayDistance", 0), 100,
    "僅開戰術層時，安全屋距離仍受 AllInfoDistance 隱私上限")
checkEq(O.policy.sandboxDistance("ZombieDotDistance", 1), 100, "旁路逐 slot：其他 slot 照舊受限")
checkEq(O.policy.setLocalPrivacy(0, true), true, "開啟隱私層")
checkEq(O.policy.sandboxDistance("SafehouseDisplayDistance", 0), nil, "隱私層生效＝安全屋距離不限")
checkEq(O.policy.sandboxDistance("SafehouseDisplayDistance", 2), 100, "其他 slot 的安全屋距離照舊")
O.world.clockCalls = 0
O.policy.sandboxDistance("SafehouseDisplayDistance", 2)
checkEq(O.world.clockCalls, 1, "單次 distance 公開查詢只跨一次時間橋接")
O.world.clockCalls = 0
O.policy.privacyActive(0)
checkEq(O.world.clockCalls, 1, "單次 privacy 公開查詢只跨一次時間橋接")

--------------------------------------------------------------------------------
-- 11. enum 模式：牲畜可見性（含單機收斂）與安全屋範圍顯示
--------------------------------------------------------------------------------
local P = newPolicy{
    mpClient = true,
    java = { LivestockVisibility = 3, SafehouseDisplay = 2,
             AllowAdminTacticalView = true, AllowAdminPrivacyView = true },
    players = { [0] = newPlayer{ canSeeAll = true } },
}
checkEq(P.policy.livestockMode(0), 3, "MP：牲畜模式直出政策值")
checkEq(P.policy.safehouseMode(0), 2, "安全屋模式直出政策值")
P.world.java.LivestockVisibility = 9
P.world.java.SafehouseDisplay = 4
P.policy.refresh(true)
checkEq(P.policy.livestockMode(0), 2, "牲畜模式越界＝回 SCHEMA 預設 2")
checkEq(P.policy.safehouseMode(0), 3, "安全屋模式越界＝回 3（全部顯示）")
P.world.java.LivestockVisibility = 4
P.world.java.SafehouseDisplay = 1
P.policy.refresh(true)
checkEq(P.policy.livestockMode(0), 4, "隱私未開＝牲畜隱藏政策照舊")
checkEq(P.policy.safehouseMode(0), 1, "隱私未開＝安全屋關閉政策照舊")
checkEq(P.policy.setLocalTactical(0, true), true, "開啟戰術層")
checkEq(P.policy.livestockMode(0), 4, "只有戰術層＝隱私選項不解除")
checkEq(P.policy.safehouseMode(0), 1, "只有戰術層＝安全屋顯示不解除")
checkEq(P.policy.setLocalPrivacy(0, true), true, "開啟隱私層")
checkEq(P.policy.livestockMode(0), 1, "隱私層生效＝牲畜全部可見")
checkEq(P.policy.safehouseMode(0), 3, "隱私層生效＝安全屋全部可見")
checkEq(P.policy.livestockMode(1), 4, "旁路逐 slot：其他 slot 照舊被隱藏")
checkEq(P.policy.safehouseMode(1), 1, "旁路逐 slot：其他 slot 安全屋照舊")

local Q = newPolicy{ mpClient = false, java = { LivestockVisibility = 2 } }
checkEq(Q.policy.livestockMode(0), 1, "SP：模式 2 無玩家間歸屬語意＝等同全部顯示")
Q.world.java.LivestockVisibility = 3
Q.policy.refresh(true)
checkEq(Q.policy.livestockMode(0), 1, "SP：模式 3 同樣收斂為全部顯示")
Q.world.java.LivestockVisibility = 4
Q.policy.refresh(true)
checkEq(Q.policy.livestockMode(0), 4, "SP：模式 4（全部隱藏）仍有效")

--------------------------------------------------------------------------------
-- 12. 舊伺服器（沒有 0.23 新鍵）＝旁路一律關閉（fail-closed）
--------------------------------------------------------------------------------
local legacySb = {
    AllInfoDistance = 0, AllowZombieDots = true, ZombieDotDistance = 0,
    AllowZombieIntensity = true, AllowAnimalDots = true, AnimalIconDistance = 0,
    LivestockVisibility = 2, AllowVehicleDots = true, VehicleIconDistance = 0,
    PoiDisplayDistance = 0, ZoneDisplayDistance = 0, SafehouseDisplay = 3,
    SafehouseDisplayDistance = 0, AllowNavShare = true, ExportPlayerPositions = false,
    PlayerExportInterval = 5, ExportOfflinePlayers = true,
} -- 0.22 的 17 把鍵，刻意不含 AllowAdminTacticalView／AllowAdminPrivacyView
local R = newPolicy{
    mpClient = true, sandbox = legacySb,
    players = { [0] = newPlayer{ canSeeAll = true,
        md = { [FLAG_T] = true, [FLAG_P] = true } } }, -- 舊存檔殘留的旗標
}
checkEq(R.policy.read("AllowAdminTacticalView", false), false, "舊伺服器缺鍵＝旁路政策 false")
checkEq(R.origin.AllowAdminTacticalView, "default", "缺鍵來源＝SCHEMA 預設（不是 nil 被 or 判成放行）")
checkEq(R.policy.hasCanSeeAll(0), true, "該玩家確實有 CanSeeAll")
checkEq(R.policy.localTactical(0), false, "舊 modData 殘留旗標不會復活")
checkEq(R.policy.tacticalActive(0), false, "缺鍵＋有權限＋旗標殘留＝仍不生效")
checkEq(R.policy.privacyActive(0), false, "隱私層同樣不生效")
checkEq(R.policy.setLocalTactical(0, true), false, "缺鍵時 setter 一律被拒")
checkEq(R.policy.gate("AllowZombieDots", false, 0), true, "舊伺服器的既有政策照常生效")
checkEq(R.policy.sandboxDistance("ZombieDotDistance", 0), nil, "既有距離語意不變（0＝不限）")
checkEq(R.policy.livestockMode(0), 2, "既有牲畜政策不受影響")
checkEq(R.policy.safehouseMode(0), 3, "既有安全屋政策不受影響")

--------------------------------------------------------------------------------
-- 13. 19 鍵 schema 與 sandbox-options.txt 逐鍵對齊
--     SCHEMA 預設＝「舊伺服器缺鍵」時的實際生效值，寫錯會讓缺鍵伺服器的行為與
--     有鍵的不同，而且不會有任何錯誤訊息。
--------------------------------------------------------------------------------
local S = newPolicy{} -- 空世界：無 Java、無鏡像表＝只剩 SCHEMA 預設
checkEq(S.policy.apiVersion, 1, "facade apiVersion＝1")
local sbDeclared, sbCount = {}, 0
for name, decl in sandboxSrc:gmatch("option%s+MinidoracatMiniMap%.([%w_]+)%s*\n%s*{([^}]*)}") do
    local kind = decl:match("type%s*=%s*(%w+)")
    local raw = decl:match("default%s*=%s*([%w%.%-]+)")
    local entry
    if kind == "boolean" then
        entry = "boolean|" .. tostring(raw == "true")
    elseif kind == "integer" or kind == "enum" then
        entry = "number|" .. tostring(tonumber(raw))
    else
        entry = "unsupported-type|" .. tostring(kind)
    end
    sbDeclared[name] = entry
    sbCount = sbCount + 1
end
local missingInSchema = 0
for name in pairs(sbDeclared) do
    if kinds[name] == nil then missingInSchema = missingInSchema + 1 end
end
checkEq(sbCount, 19, "sandbox-options.txt 有 19 個選項")
checkEq(S.schemaN, 19, "SCHEMA_N 顯式筆數＝19")
checkEq(#S.schema, S.schemaN, "SCHEMA 列數與 SCHEMA_N 一致（漏改就靜默少載一把鍵）")
checkEq(missingInSchema, 0, "沙盒選項全部在 SCHEMA 內（漏一把＝該鍵永遠讀不到）")
for i = 1, S.schemaN do
    local row = S.schema[i]
    checkEq(row[2] .. "|" .. tostring(row[3]), sbDeclared[row[1]] or "missing",
        "SCHEMA 與 sandbox-options 對齊：" .. row[1])
    -- 缺鍵時的實際生效值必須就是 SCHEMA 預設；這同時證明 KIND/DEFAULTS 建表
    -- 迴圈確實走完 19 列（少一列＝該鍵變未知鍵，read 會回 nil）。
    checkEq(S.policy.read(row[1]), row[3], "缺鍵時實際生效值＝SCHEMA 預設：" .. row[1])
end

--------------------------------------------------------------------------------
-- 14. 原始碼防線（判定邏輯只能經 seam 碰 PZ；旁路不能改走別的通道）
--     註解裡刻意寫了 getAccessLevel／toLua／ClientCommand 等反例字樣，故掃描前
--     先剝註解——本檔沒有長註解、也沒有含 "--" 的字串（下方前兩條斷言守住）。
--------------------------------------------------------------------------------
check(not source:find("--[[", 1, true), "原檔沒有長註解（剝註解的前提）")
local function stripComments(text)
    local out, n = {}, 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cut = line:find("%-%-")
        if cut then line = line:sub(1, cut - 1) end
        n = n + 1
        out[n] = line
    end
    return table.concat(out, "\n")
end
local codeAll = stripComments(source)
local codeBody = stripComments(body)
check(codeAll:find("MinidoracatMiniMapPolicy", 1, true), "剝註解後仍有程式碼（剝法沒把檔案清空）")
check(not codeAll:find("getAccessLevel", 1, true), "不用已 deprecated 的 getAccessLevel")
check(not codeAll:find("isAdmin", 1, true), "不用 isAdmin（B42 權限是 Role＋Capability）")
check(not codeAll:find("toLua", 1, true), "不呼叫 SandboxOptions:toLua()（會重建整張 SandboxVars）")
check(not codeAll:find("transmitModData", 1, true), "不同步本機檢視旗標（MP 重連回 false＝fail-closed）")
check(not codeAll:find("ClientCommand", 1, true), "不用 ClientCommand 當權威寫入（客戶端自報可偽造）")
check(not codeBody:find("SandboxVars", 1, true), "判定區不直讀 SandboxVars（一律經 sandboxTable seam）")
check(not codeBody:find("getSandboxOptions", 1, true), "判定區不直呼 getSandboxOptions")
check(not codeBody:find("getSpecificPlayer", 1, true), "判定區不直取玩家（槽位驗證只有一處）")
check(not codeBody:find("Capability", 1, true), "判定區不直碰 Capability")
check(not codeBody:find("getModData", 1, true), "判定區不直呼 getModData")
check(not codeBody:find("pcall", 1, true), "判定區是純邏輯（PZ 呼叫全在 seam，無需 pcall）")
check(not codeBody:find("#SCHEMA", 1, true), "不用 # 取 SCHEMA 長度（家規：顯式筆數）")
check(not codeBody:find("MinidoracatMiniMapPolicy", 1, true), "判定區不自行發布全域 facade")
checkEq(select(2, codeAll:gsub("MinidoracatMiniMapPolicy%s*=", "")), 1, "全域 facade 只發布一次")
local lastCode
for line in codeAll:gmatch("[^\n]+") do
    if line:match("%S") then lastCode = line end
end
checkEq((lastCode or ""):match("^%s*(.-)%s*$"), "MinidoracatMiniMapPolicy = Policy",
    "全域 facade 在檔尾發布（整份邏輯就緒後才可見）")
check(source:find("Events%.OnCreatePlayer%.Add%(clearLocalSlot%)") ~= nil
    and source:find("Events%.OnGameStart%.Add%(clearLocalFlags%)") ~= nil
    and source:find("Events%.OnDisconnect%.Add%(clearLocalFlags%)") ~= nil,
    "本機旗標在建立玩家／新局／斷線時 fail-closed 清除")

--------------------------------------------------------------------------------
-- 斷言條數守門：新增／刪除斷言必須同步改這個數字，否則整批被靜默略過也不會
-- 有人發現；schema 與 never-bypass 迴圈產生的動態斷言亦計入總數。
local EXPECTED_ASSERTIONS = 281
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS
        .. ", actual " .. assertions)
    os.exit(1)
end
print("admin policy assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
