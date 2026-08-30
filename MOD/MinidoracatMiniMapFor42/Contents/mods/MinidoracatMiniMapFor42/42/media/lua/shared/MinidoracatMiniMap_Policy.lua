-- MinidoracatMiniMap_Policy.lua — 全服政策讀取 ＋ 管理員個人旁路（shared 單一事實來源）
--
-- 本檔把「這台伺服器允許什麼」與「這個管理員此刻要不要用旁路」拆成兩層，並且
-- 只用一個 facade 交給 client／server 兩側消費（全域 MinidoracatMiniMapPolicy，
-- 檔尾發布）。原本 client 與 server 各自 `SandboxVars.MinidoracatMiniMap[name]`
-- 直讀，三份實作三種缺鍵語意；新增管理員旁路後，任何一處漏判就是權限洩漏，
-- 故統一收斂於此。
--
-- ══ 為什麼真相源是 Java SandboxOptions，而 SandboxVars 只是 fallback ══
--   · `getSandboxOptions()`（Lua 全域）→ `:getOptionByName("MinidoracatMiniMap.X")`
--     → `:getValue()` 讀的是引擎當下持有的沙盒物件，管理員在伺服器設定頁按下
--     套用後即時反映。
--   · `SandboxVars` 是引擎把該物件展開到 Lua 的鏡像表。它「通常」同步，但它是
--     一張普通 Lua 表：任何 MOD（含第三方）都能寫它，寫了之後所有直讀
--     SandboxVars 的程式碼就被靜默改權限。權限判定不能建立在可被任意改寫的表上。
--   · 刻意不呼叫 `SandboxOptions:toLua()`：那是引擎在載入流程裡「重建整張
--     SandboxVars」的動作（會覆寫所有 MOD 的沙盒鏡像），由讀值路徑呼叫等於
--     每 250ms 對全服沙盒狀態做一次全量寫入，副作用遠超讀一個值的需求。
--   · 兩者都拿不到合法值時，退回本檔 SCHEMA 的預設——與 sandbox-options.txt
--     的 default 逐鍵對齊（見 SCHEMA 註解），所以「舊伺服器沒有新鍵」＝拿到
--     `false`＝旁路一律關閉（fail-closed），而不是拿到 nil 後被 `or` 判成放行。
--
-- ══ 250ms 快照 ══
--   讀值點在每幀繪製路徑上（點雲／距離閘門逐點問），而 `getOptionByName` 是
--   字串查表＋Kahlua 過橋，逐幀逐鍵問 19 把是白花的成本。故一次解析全部 19 鍵
--   成快照，250ms 內重用；管理員按套用後最多 250ms 生效（人類感知不到，且
--   原本 SandboxVars 直讀也要等網路同步）。`refresh(true)` 可強制重讀（設定
--   視窗開窗時用）。取不到真實時間（`getTimestampMs` 不可用）時每次都重讀——
--   寧可多花成本，也不要把快照凍結在舊值上。
--
-- ══ 三把鑰匙（戰術層／隱私層分離）══
--   `tacticalActive(pn)` ＝ 三者同時成立：
--     1. 全服政策 `AllowAdminTacticalView` 為 true（伺服器主人開放）
--     2. 該玩家 `Role:hasCapability(Capability.CanSeeAll)`（引擎的權限模型）
--     3. 該玩家自己把本機旗標打開（管理員多半不想一直看穿全圖）
--   `privacyActive(pn)` ＝ `tacticalActive(pn)` ＋ `AllowAdminPrivacyView`
--   ＋ 該玩家的隱私旗標。隱私層**依賴**戰術層：戰術關掉時隱私一律無效，
--   且 `setLocalTactical(pn, false)` 會連帶把隱私旗標清成 false——否則管理員
--   關掉「看穿」後，隱私旁路仍留著一個看不見的開關。
--   權限用 `Role:hasCapability`，不用已 deprecated 的 `getAccessLevel()`／
--   `isAdmin()`：B42 的權限是 Role＋Capability，自訂 Role 可以有 CanSeeAll 而
--   不是 admin，反之亦然。取不到 player／Role／Capability 一律回 false。
--
-- ══ 旁路白名單（不在名單上的鍵永遠不旁路）══
--   戰術層 TACTICAL_KEYS（「我要看敵情」，不涉及他人隱私）：
--     AllowZombieDots／AllowZombieIntensity／AllowAnimalDots／AllowVehicleDots
--     ＋ ZombieDotDistance／AnimalIconDistance／VehicleIconDistance／
--        PoiDisplayDistance／ZoneDisplayDistance／AllInfoDistance
--   隱私層 PRIVACY_KEYS（會看到別的玩家藏起來的東西，故獨立第二把鑰匙）：
--     SafehouseDisplay／SafehouseDisplayDistance／LivestockVisibility
--   **永不旁路**：AllowNavShare（會讓伺服器代發座標給別人，是通訊而非檢視）、
--   ExportPlayerPositions／PlayerExportInterval／ExportOfflinePlayers（落地成
--   檔案，是 I/O 政策而非檢視），以及 AllowAdminTacticalView／
--   AllowAdminPrivacyView 自身（旁路不能自我授權）。名單以「鍵名 → true」的
--   表表示，`gate()` 另要求該鍵是 boolean 型才會強制放行，距離鍵一律走
--   `sandboxDistance()`——避免哪天有人把距離鍵餵進 gate() 就拿到 `true`。
--
-- ══ 玩家偏好存哪裡 ══
--   本機旗標只存 facade 私有的 0-3 slot table；**不**放 `IsoPlayer:getModData()`。
--   原因：導航目標持久化會呼叫 `transmitModData()`，引擎傳的是整張 modData，
--   若旗標混在其中就會被送到伺服器／其他客戶端，違反「本機偏好」。每次
--   OnCreatePlayer／OnGameStart／OnDisconnect 都清掉，MP 重連後回 false，
--   正好符合 fail-closed（要再看穿就再開一次）。也刻意**不**寫進 SandboxVars——
--   那是全服政策，把個人偏好塞進去等於一個人的設定改動全服。
--   授權判定一律在本機用引擎 Role 判，**不**用 ClientCommand 當權威寫入：
--   ClientCommand 是客戶端自報，伺服器要嘛信（可被偽造）要嘛要另做一套回傳
--   通道；而檢視旁路的效果全在客戶端渲染，伺服器端沒有可強制的東西——真正
--   需要伺服器權威的兩件事（導航轉送、座標匯出）就在 server 端讀本 facade，
--   且那兩把鍵不在任何白名單上。
--
-- ══ 消費端契約 ══
--   read(name, default)          → 全服政策值（無旁路）。未知鍵／兩層來源皆
--                                  無合法值時回呼叫端 default
--   readBool / readNumber        → 同上，另保證回傳型別
--   refresh(force)               → 重讀快照；回 true＝有值變動
--   getRevision()                → 單調計數器，值變動或本機旗標變動才增；
--                                  UI 用它決定要不要重建（不是 per-player）
--   hasCanSeeAll(pn)             → 該 slot 的引擎權限（nil-safe）
--   localTactical/localPrivacy   → 該 slot 的本機旗標
--   setLocalTactical/Privacy     → 回「實際存下的布林」（被拒＝false）
--   tacticalActive/privacyActive  → 三把鑰匙的合成結果
--   gate(name, default, pn)      → 政策值；白名單 boolean 鍵在戰術生效時回 true
--   sandboxDistance(name, pn)    → nil＝不限距離，否則正數（沿用既有語意：
--                                  0／缺值／非數字＝不限；AllInfoDistance 為
--                                  全域上限，與個別值取較小的正值）
--   livestockMode(pn)            → 1-4（已套用單機收斂；隱私生效時回 1）
--   safehouseMode(pn)            → 1-3（隱私生效時回 3）
--   玩家自己「再收緊」的偏好（ModOptions 滑條等）不在本檔——那是 client 層在
--   本 facade 的輸出之上取較小值，伺服器上限永遠是天花板。

--------------------------------------------------------------------------------
-- PZ API 區（標記區段之外＝離線測試以同名 stub 注入；本區不含判定邏輯）
--------------------------------------------------------------------------------

-- 真實時間毫秒。getTimestampMs＝LuaManager.java:9267-9274（家族用例
-- MinidoracatMiniMapPlayerExport.lua）。取不到回 nil＝呼叫端視為快照永遠過期。
local function nowMs()
    local ok, v = pcall(getTimestampMs)
    if ok and type(v) == "number" and v == v then return v end
    return nil
end

-- 是否為 MP 客戶端行程（含 Host 的 client 行程）。SP／dedicated server 為 false。
local function isMpClient()
    local ok, v = pcall(isClient)
    if ok then return v == true end
    return false
end

-- Java 沙盒物件逐鍵讀值（真相源）。任何一環缺席／拋錯回 nil＝讓呼叫端退到
-- SandboxVars 或 SCHEMA 預設。整段包 pcall：getOptionByName 對未知名稱的行為
-- 依版本可能是回 null 也可能拋錯，兩者都必須是「無值」而不是把讀值路徑炸掉。
local javaReadErrLogged = false
local roleReadErrLogged = false

local function readJavaOption(fullName)
    local ok, v = pcall(function()
        local opts = getSandboxOptions()
        if not opts then return nil end
        local opt = opts:getOptionByName(fullName)
        if not opt then return nil end
        return opt:getValue()
    end)
    if ok then return v end
    if not javaReadErrLogged then
        javaReadErrLogged = true
        print("[MinidoracatMiniMap] policy Java read failed, using fallback: " .. tostring(v))
    end
    return nil
end

-- SandboxVars 鏡像表（fallback 讀取 ＋ 單機/伺服器端回寫對齊用）。
-- 刻意不在此建表：表不存在＝本 MOD 的沙盒選項沒被載入，此時憑空造一張
-- 會讓其他直讀 SandboxVars 的程式碼以為政策存在。
local function sandboxTable()
    return SandboxVars and SandboxVars.MinidoracatMiniMap
end

-- 逐 slot 取玩家（分割畫面 0-3）。槽位驗證從嚴：非整數／越界一律 nil，
-- 絕不退回 slot 0——借用別人的權限就是權限洩漏。
local function playerOf(pn)
    if type(pn) ~= "number" or pn ~= pn then return nil end
    if pn < 0 or pn > 3 then return nil end
    if pn ~= math.floor(pn) then return nil end
    local ok, p = pcall(getSpecificPlayer, pn)
    if ok and p then return p end
    return nil
end

-- 引擎權限：Role:hasCapability(Capability.CanSeeAll)。Capability 常數表缺席
-- （單機／舊版）＝視為無權限，而不是視為放行。
local function roleCanSeeAll(player)
    local ok, v = pcall(function()
        local role = player:getRole()
        if not role then return false end
        local cap = Capability and Capability.CanSeeAll
        if cap == nil then return false end
        return role:hasCapability(cap) == true
    end)
    if ok then return v == true end
    if not roleReadErrLogged then
        roleReadErrLogged = true
        print("[MinidoracatMiniMap] role capability read failed, admin view denied: "
            .. tostring(v))
    end
    return false
end


--------------------------------------------------------------------------------
-- 政策判定區（純邏輯：只透過上方 7 個 seam 碰 PZ；離線測試抽本區段）
--------------------------------------------------------------------------------
-- test:admin-policy:start
local OPTION_PREFIX = "MinidoracatMiniMap."
local TTL_MS = 250
local NUM_LIMIT = 1000000000 -- 數字合理值域（±1e9）：順手把 inf 一併排除

-- 19 鍵 schema：{ 沙盒鍵名, 型別, 預設值 }。預設值必須與
-- media/sandbox-options.txt 的 default 逐鍵一致——這是「舊伺服器缺鍵」時的
-- 實際生效值，寫錯會讓缺鍵的伺服器行為與有鍵的不同。enum 以 number 表示
-- （Java 端 getValue 回選項索引）。
local SCHEMA = {
    { "AllInfoDistance", "number", 0 },
    { "AllowZombieDots", "boolean", true },
    { "ZombieDotDistance", "number", 0 },
    { "AllowZombieIntensity", "boolean", true },
    { "AllowAnimalDots", "boolean", true },
    { "AnimalIconDistance", "number", 0 },
    { "LivestockVisibility", "number", 2 },
    { "AllowVehicleDots", "boolean", true },
    { "VehicleIconDistance", "number", 0 },
    { "PoiDisplayDistance", "number", 0 },
    { "ZoneDisplayDistance", "number", 0 },
    { "SafehouseDisplay", "number", 3 },
    { "SafehouseDisplayDistance", "number", 0 },
    { "AllowNavShare", "boolean", true },
    { "ExportPlayerPositions", "boolean", false },
    { "PlayerExportInterval", "number", 5 },
    { "ExportOfflinePlayers", "boolean", true },
    { "AllowAdminTacticalView", "boolean", false },
    { "AllowAdminPrivacyView", "boolean", false },
}
local SCHEMA_N = 19 -- 顯式筆數（家規：不用 # 依賴隱性長度）

local KIND = {}
local DEFAULTS = {}
for i = 1, SCHEMA_N do
    local row = SCHEMA[i]
    KIND[row[1]] = row[2]
    DEFAULTS[row[1]] = row[3]
end

-- 旁路白名單（見檔頭）。名單外的鍵沒有任何路徑可以旁路。
local TACTICAL_KEYS = {
    AllowZombieDots = true,
    AllowZombieIntensity = true,
    AllowAnimalDots = true,
    AllowVehicleDots = true,
    ZombieDotDistance = true,
    AnimalIconDistance = true,
    VehicleIconDistance = true,
    PoiDisplayDistance = true,
    ZoneDisplayDistance = true,
    AllInfoDistance = true,
}
local PRIVACY_KEYS = {
    SafehouseDisplay = true,
    SafehouseDisplayDistance = true,
    LivestockVisibility = true,
}

-- 本機檢視旗標只存在此 closure；不進 player modData（任何導航存檔同步都碰不到）。
local FLAG_TACTICAL = "tactical"
local FLAG_PRIVACY = "privacy"
local localFlags = {} -- [playerNum] = { tactical=bool, privacy=bool }

local snapshot = {}   -- 鍵 → 已驗型的政策值
local origin = {}     -- 鍵 → "java" / "sandboxvars" / "default"
local snapMs = nil    -- 快照時刻（nil＝還沒讀過）
local revision = 0    -- 政策值或本機旗標的變動計數（UI 重建訊號）

-- 型別驗證＋淨化。回 nil＝這個來源沒有合法值（不是「值是 nil」）。
-- 數字擋 NaN／inf／離譜大小：非法值進到距離比較會讓閘門行為無法預測。
local function coerce(kind, v)
    if kind == "boolean" then
        if type(v) == "boolean" then return v end
        return nil
    end
    if type(v) ~= "number" then return nil end
    if v ~= v then return nil end
    if v > NUM_LIMIT or v < -NUM_LIMIT then return nil end
    return v
end

-- 單鍵解析：Java 優先 → SandboxVars → SCHEMA 預設。回 (值, 來源)。
local function resolveValue(name, kind, default, sb)
    local v = coerce(kind, readJavaOption(OPTION_PREFIX .. name))
    if v ~= nil then return v, "java" end
    if sb then
        v = coerce(kind, sb[name])
        if v ~= nil then return v, "sandboxvars" end
    end
    return default, "default"
end

-- 重讀快照。force＝忽略 TTL（設定視窗開窗、管理員剛改完政策時用）。
-- 回 true＝至少一個鍵的值變了（同時已把 revision 往前推）。
-- 單機／伺服器端（非 MP 客戶端）另把解析結果回寫 SandboxVars 的**自家鍵**，
-- 讓仍直讀鏡像表的舊程式碼與第三方 addon 看到同一份值；MP 客戶端不回寫——
-- 那張表在客戶端是伺服器同步下來的，本機改它只會製造「我以為政策變了」的假象。
local function refreshPolicy(force)
    local now = nowMs()
    if not force and snapMs and now and now >= snapMs and (now - snapMs) < TTL_MS then
        return false
    end
    local sb = sandboxTable()
    local mirror = not isMpClient()
    local changed = false
    for i = 1, SCHEMA_N do
        local row = SCHEMA[i]
        local name = row[1]
        local v, src = resolveValue(name, row[2], row[3], sb)
        if snapshot[name] ~= v then changed = true end
        snapshot[name] = v
        origin[name] = src
        if mirror and sb and sb[name] ~= v then sb[name] = v end
    end
    snapMs = now
    if changed then revision = revision + 1 end
    return changed
end

-- 快照純讀：複合查詢先 refresh 一次，再以本函式讀多鍵，避免每鍵重過
-- getTimestampMs/Kahlua bridge。只有 public policyRead 自行 refresh。
local function snapshotRead(name, default)
    if type(name) ~= "string" or KIND[name] == nil then return default end
    if origin[name] == "default" and default ~= nil then return default end
    local v = snapshot[name]
    if v == nil then return default end
    return v
end

-- 全服政策讀取（無任何旁路）。
local function policyRead(name, default)
    refreshPolicy(false)
    return snapshotRead(name, default)
end

local function policyReadBool(name, default)
    local v = policyRead(name, default)
    if type(v) == "boolean" then return v end
    if type(default) == "boolean" then return default end
    return false
end

local function policyReadNumber(name, default)
    local v = policyRead(name, default)
    if type(v) == "number" and v == v then return v end
    if type(default) == "number" and default == default then return default end
    return 0
end

-- 引擎權限（逐 slot）。無玩家／無 Role／無 Capability 一律 false。
local function hasCanSeeAll(pn)
    local p = playerOf(pn)
    if not p then return false end
    return roleCanSeeAll(p)
end

local function readFlag(pn, key)
    if not playerOf(pn) then return false end
    local state = localFlags[pn]
    return state ~= nil and state[key] == true
end

-- 寫本機旗標。回實際存下的布林（無玩家＝false）；false 不為空 slot 配置 table。
local function writeFlag(pn, key, v)
    if not playerOf(pn) then return false end
    local want = (v == true)
    local state = localFlags[pn]
    if not state then
        if not want then return false end
        state = { tactical = false, privacy = false }
        localFlags[pn] = state
    end
    if state[key] ~= want then
        state[key] = want
        revision = revision + 1
    end
    return want
end

-- 玩家建立／換角時清該 slot；離線／新局時清全部。只有真值被撤銷才推 revision。
local function clearLocalSlot(pn)
    if type(pn) ~= "number" or pn ~= pn or pn < 0 or pn > 3
            or pn ~= math.floor(pn) then return end
    local state = localFlags[pn]
    if state and (state.tactical == true or state.privacy == true) then
        revision = revision + 1
    end
    localFlags[pn] = nil
end

local function clearLocalFlags()
    local dirty = false
    for pn = 0, 3 do
        local state = localFlags[pn]
        if state and (state.tactical == true or state.privacy == true) then dirty = true end
        localFlags[pn] = nil
    end
    if dirty then revision = revision + 1 end
end

local function localTactical(pn)
    return readFlag(pn, FLAG_TACTICAL)
end

local function localPrivacy(pn)
    return readFlag(pn, FLAG_PRIVACY)
end

-- 三把鑰匙的快照版：呼叫端須先 refreshPolicy。複合查詢共用它，避免重複時鐘橋接。
local function tacticalActiveCached(pn)
    if snapshotRead("AllowAdminTacticalView", false) ~= true then return false end
    if not readFlag(pn, FLAG_TACTICAL) then return false end
    return hasCanSeeAll(pn)
end

local function privacyActiveCached(pn, tactical)
    if snapshotRead("AllowAdminPrivacyView", false) ~= true then return false end
    if not readFlag(pn, FLAG_PRIVACY) then return false end
    if tactical ~= nil then return tactical end
    return tacticalActiveCached(pn)
end

local function tacticalActive(pn)
    refreshPolicy(false)
    return tacticalActiveCached(pn)
end

local function privacyActive(pn)
    refreshPolicy(false)
    return privacyActiveCached(pn)
end

-- 開啟需要「政策允許＋有 CanSeeAll」；關閉永遠允許，且連帶關掉隱私旗標
-- （否則關掉戰術層後，隱私層留著一個看不見的開關，日後戰術層重開就意外生效）。
local function setLocalTactical(pn, v)
    if v == true then
        refreshPolicy(false)
        if snapshotRead("AllowAdminTacticalView", false) ~= true then return false end
        if not hasCanSeeAll(pn) then return false end
        return writeFlag(pn, FLAG_TACTICAL, true)
    end
    writeFlag(pn, FLAG_TACTICAL, false)
    writeFlag(pn, FLAG_PRIVACY, false)
    return false
end

-- 開啟需要「政策允許＋戰術層已生效」。關閉永遠允許。
local function setLocalPrivacy(pn, v)
    if v == true then
        refreshPolicy(false)
        if snapshotRead("AllowAdminPrivacyView", false) ~= true then return false end
        if not tacticalActiveCached(pn) then return false end
        return writeFlag(pn, FLAG_PRIVACY, true)
    end
    writeFlag(pn, FLAG_PRIVACY, false)
    return false
end

-- 布林閘門：政策值；白名單內的 boolean 鍵在戰術層生效時強制放行。
-- 另要求 KIND 為 boolean＝距離鍵誤傳進來也不會拿到 true（必須走 sandboxDistance）。
local function policyGate(name, default, pn)
    refreshPolicy(false)
    if TACTICAL_KEYS[name] and KIND[name] == "boolean" and tacticalActiveCached(pn) then
        return true
    end
    return snapshotRead(name, default)
end

-- 距離閘門：nil＝不限距離，否則正數。
--   · 0／缺值／非數字＝不限（沿用既有 sandboxDist 語意）
--   · AllInfoDistance＝全域上限，與個別值取較小的正值（個別值只能更嚴）
--   · 戰術層生效時：只讓戰術白名單距離鍵回 nil；安全屋距離仍受自己的政策值
--     與 AllInfoDistance，直到隱私層也生效
local function policyDistance(name, pn)
    refreshPolicy(false)
    local tactical = tacticalActiveCached(pn)
    if TACTICAL_KEYS[name] and tactical then return nil end
    if PRIVACY_KEYS[name] and privacyActiveCached(pn, tactical) then return nil end
    local v = snapshotRead(name, 0)
    if type(v) ~= "number" or v <= 0 then v = nil end
    local cap = snapshotRead("AllInfoDistance", 0)
    if type(cap) ~= "number" or cap <= 0 then cap = nil end
    if cap and (not v or cap < v) then return cap end
    return v
end

-- 牲畜可見性：1=全部、2=隱藏其他安全屋內、3=僅我方安全屋內、4=全部隱藏。
-- 單機沒有玩家間安全屋歸屬語意，前 3 檔等同全部顯示；第 4 檔仍有效。
-- 整個選項屬隱私層（模式 2/3 直接是「別人藏起來的牲畜」），故隱私生效時回 1。
local function livestockMode(pn)
    refreshPolicy(false)
    if privacyActiveCached(pn) then return 1 end
    local mode = snapshotRead("LivestockVisibility", 2)
    if type(mode) ~= "number" or mode < 1 or mode > 4 then mode = 2 end
    if isMpClient() then return mode end
    if mode ~= 4 then return 1 end
    return mode
end

-- 安全屋範圍顯示：1=關閉、2=僅自己的、3=全部。隱私生效時回 3。
local function safehouseMode(pn)
    refreshPolicy(false)
    if privacyActiveCached(pn) then return 3 end
    local mode = snapshotRead("SafehouseDisplay", 3)
    if type(mode) ~= "number" or mode < 1 or mode > 3 then mode = 3 end
    return mode
end

local Policy = {
    apiVersion = 1,
    read = policyRead,
    readBool = policyReadBool,
    readNumber = policyReadNumber,
    refresh = function(force) return refreshPolicy(force == true) end,
    getRevision = function() return revision end,
    hasCanSeeAll = hasCanSeeAll,
    localTactical = localTactical,
    setLocalTactical = setLocalTactical,
    localPrivacy = localPrivacy,
    setLocalPrivacy = setLocalPrivacy,
    tacticalActive = tacticalActive,
    privacyActive = privacyActive,
    gate = policyGate,
    sandboxDistance = policyDistance,
    livestockMode = livestockMode,
    safehouseMode = safehouseMode,
}
-- test:admin-policy:end

-- 原版用例：OnCreatePlayer callback 收 playerNum（ISSearchManager.createUI）；
-- OnGameStart／OnDisconnect 無需參數。shared 在 dedicated 也載入，故逐事件守衛。
if Events and Events.OnCreatePlayer then Events.OnCreatePlayer.Add(clearLocalSlot) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(clearLocalFlags) end
if Events and Events.OnDisconnect then Events.OnDisconnect.Add(clearLocalFlags) end

-- 全域 facade：**只在檔尾發布一次**（發布即代表整份邏輯已就緒；中途發布會讓
-- 先載入的 client 檔在半成品狀態下取到殘缺的表）
MinidoracatMiniMapPolicy = Policy
