-- MinidoracatMiniMap_StreetI18n.lua
-- 本檔範圍：MOD 地圖街名多語化載入層——在 MapUtils.initDirectoryStreetData
-- 以替代 streets_{CH,CN,JP}.xml 取代上游英文檔。全程 add-only：只 addStreetData
-- 替代路徑，絕不 clearStreetData、不改非空 street set。
-- 與 LangFor42 MapStreets_Flx.lua 正交：它 wrap 迴圈層 initDefaultStreetData，
-- 本檔 wrap 目錄層 initDirectoryStreetData（vanilla 迴圈與 LangFor42 取代迴圈
-- 都動態呼叫本函式，兩環境自然命中；不疊 wrap 迴圈層＝後載者贏互踩）。
-- 不碰掛載／繪製／選項。語言每次呼叫時判：主選單切語言後新建地圖 UI 即生效。
-- 拆檔緣由：主檔 Kahlua 主 chunk locvar 上限；載入序＝同目錄字母序，本檔在
-- 主檔後（'.' < '_'），Core.ready 已設。
--
-- ## API 出處（42.20.3 snapshot；家規：每個 PZ 呼叫都要有出處）
-- - Translator.getLanguage():name()：vanilla MainOptions.lua:1828、ISLcdBar.lua:14
--   （實證值 CH／CN／JP；JP 非 JA）
-- - getActivatedMods()：LuaManager.java:7434-7440，回傳 ArrayList<String>
--   ＝ ZomboidFileSystem.getModIDs():861-863（this.mods，client runtime 目前
--   已載入的 mod id）。42.20.3 無 getActivatedModsProvider。
-- - fileExists：LuaManager.java:5553-5560 → ZomboidFileSystem.getString:322-338
--   （activeFileMap，跨 mod 可解析）
-- - mapUI.javaObject:getAPIv3()：UIWorldMap.java:103-105
-- - getStreetsAPI()：UIWorldMapV3.java:111-117
-- - addStreetData：WorldMapStreetsV1.java:27-29 → WorldMap.java:193-220
--   （isKnownFile:350-366 → activeFileMap；streetData.contains 冪等去重）
-- - 攔截點本體：ISMapDefinitions.lua:32-39
--
-- ## add-only 契約
-- 任何路徑不得呼叫 clearStreetData（WorldMap.java:241-248 會 combinedStreets.clear
-- 卻不清 StreetLookup，幽靈街名）。條件不成立＝呼叫原函式載英文，寧可英文不可丟街名。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- test:street-i18n:start
-- 可離線抽段：索引建構／路徑組合／候選解析（依賴由呼叫端注入）
local STREET_I18N_ID_RE = "^[%w._%-]+$"

local function composeStreetI18nPath(owner, id, lang)
    return "media/minimapstreets/" .. owner .. "/" .. id .. "/streets_" .. lang .. ".xml"
end

-- packs：與 registeredPacks 同形 { { owner=, entries= }, ... }
-- logFn：可選 function(msg)；違規條目忽略＋log（不拒收整包）
-- 回傳 byDir[mapDir] = { { id=, mapMod=, owner= }, ... }；同 mapDir+owner+id 去重
local function buildStreetI18nIndex(packs, logFn)
    local byDir = {}
    if type(packs) ~= "table" then return byDir end
    for i = 1, #packs do
        local pack = packs[i]
        if type(pack) == "table" and type(pack.owner) == "string" and type(pack.entries) == "table" then
            local entries = pack.entries
            for j = 1, #entries do
                local e = entries[j]
                if type(e) == "table" and type(e.streetI18n) == "string" then
                    local id, mapDir = e.streetI18n, e.mapDir
                    if id:match(STREET_I18N_ID_RE) and type(mapDir) == "string" and mapDir ~= "" then
                        local list = byDir[mapDir]
                        if not list then
                            list = {}
                            byDir[mapDir] = list
                        end
                        local dup = false
                        for k = 1, #list do
                            if list[k].owner == pack.owner and list[k].id == id then
                                dup = true
                                break
                            end
                        end
                        if not dup then
                            list[#list + 1] = { id = id, mapMod = e.mapMod, owner = pack.owner }
                        end
                    elseif logFn then
                        logFn("streetI18n ignored (bad id or empty mapDir): id="
                            .. tostring(id) .. " mapDir=" .. tostring(mapDir)
                            .. " owner=" .. pack.owner)
                    end
                end
            end
        end
    end
    return byDir
end

-- 候選 >1 才用啟用狀態篩；篩後同 owner+id 視為同一 dataset。
-- 恰一個 → 回傳該條；0 或仍 >1 → nil（呼叫端英文 fallback，不猜）
local function resolveStreetI18nCandidate(candidates, activeSet)
    if type(candidates) ~= "table" or #candidates == 0 then return nil end
    local pool = candidates
    if #candidates > 1 then
        pool = {}
        for i = 1, #candidates do
            local c = candidates[i]
            if c.mapMod == nil or (activeSet and activeSet[c.mapMod]) then
                pool[#pool + 1] = c
            end
        end
    end
    local uniq, n = {}, 0
    for i = 1, #pool do
        local c = pool[i]
        local key = tostring(c.owner) .. "/" .. tostring(c.id)
        if not uniq[key] then
            uniq[key] = c
            n = n + 1
        end
    end
    if n ~= 1 then return nil end
    for _, c in pairs(uniq) do return c end
end
-- test:street-i18n:end

-- 安裝閘門：MapUtils 由 vanilla client/ISUI/Maps/ISMapDefinitions.lua 定義，載入序在
-- client/ 根目錄本檔之前（子目錄先掃），正常情況必定存在。缺席＝載入序假設被打破，
-- wrapper 不會安裝、街名靜默退回英文——這是最貴的症狀（玩家只看到「還是英文」，
-- log 卻乾淨），故必須留痕。安裝成功也印一行，作為出貨驗收的可觀測訊號。
local origInit = MapUtils and MapUtils.initDirectoryStreetData
if type(origInit) ~= "function" then
    print("[MinidoracatMiniMap] StreetI18n DISABLED: MapUtils.initDirectoryStreetData"
        .. " unavailable at load time -- mod map street names stay English")
    return
end
print("[MinidoracatMiniMap] StreetI18n armed")

local byDirCache = nil
local logged = {} -- 成功／衝突／fallback 各 key 只印一次（避免 Recreate 刷屏）

local function log(msg)
    print("[MinidoracatMiniMap] " .. tostring(msg))
end

local function logOnce(key, msg)
    if logged[key] then return end
    logged[key] = true
    log(msg)
end

local function ensureIndex()
    if byDirCache then return byDirCache end
    local packs = Core.registeredPacks
    byDirCache = buildStreetI18nIndex(packs, log)
    return byDirCache
end

function MapUtils.initDirectoryStreetData(mapUI, directory)
    local replaced = false
    local ok, err = pcall(function()
        -- 每次呼叫時判語言：切語言後新建地圖 UI 即生效（成本＝一次 Java 取值）
        local lang = Translator.getLanguage():name() -- MainOptions.lua:1828、ISLcdBar.lua:14
        if lang ~= "CH" and lang ~= "CN" and lang ~= "JP" then return end
        if type(directory) ~= "string" then return end
        local dir = directory:match("^media/maps/(.+)$")
        if not dir then return end
        local candidates = ensureIndex()[dir]
        if not candidates then return end
        local active = nil
        if #candidates > 1 then
            -- getActivatedMods：LuaManager.java:7434-7440 → ArrayList；:size/:get 0-based
            local mods = getActivatedMods()
            active = {}
            for i = 1, mods:size() do
                active[mods:get(i - 1)] = true
            end
        end
        local chosen = resolveStreetI18nCandidate(candidates, active)
        if not chosen then
            logOnce("conflict:" .. dir,
                "streetI18n conflict for mapDir='" .. dir .. "'; using English streets.xml")
            return
        end
        local alt = composeStreetI18nPath(chosen.owner, chosen.id, lang)
        if not fileExists(alt) then -- LuaManager.java:5553-5560
            logOnce("missing:" .. alt,
                "streetI18n missing " .. alt .. "; using English streets.xml")
            return
        end
        -- getAPIv3：UIWorldMap.java:103-105；getStreetsAPI：UIWorldMapV3.java:111-117
        -- addStreetData：WorldMapStreetsV1.java:27-29 → WorldMap.java:193-220（冪等去重）
        mapUI.javaObject:getAPIv3():getStreetsAPI():addStreetData(alt)
        replaced = true
        logOnce("ok:" .. chosen.id,
            "streetI18n loaded " .. chosen.id .. " (" .. lang .. ") from " .. alt)
    end)
    if replaced then return end
    if not ok then
        logOnce("err", "streetI18n wrapper error: " .. tostring(err) .. "; using English streets.xml")
    end
    return origInit(mapUI, directory)
end
