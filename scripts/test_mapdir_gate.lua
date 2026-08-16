-- mapDir 閘門（一 mod 多地圖：SecretZ 類）離線回歸測試。
-- 仿 test_key_migration.lua：抽主檔標記區段→補最小 stub→離線跑。
-- 用法：lua scripts/test_mapdir_gate.lua
local mainPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local file = assert(io.open(mainPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local body = assert(source:match(
    "%-%- test:mapdir%-gate:start\n(.-)\n%-%- test:mapdir%-gate:end"),
    "找不到 mapdir-gate 測試區段")

local rebuildBody = assert(source:match(
    "%-%- test:rebuild%-overlays:start\n(.-)\n%-%- test:rebuild%-overlays:end"),
    "找不到 rebuild-overlays 測試區段")

local priorityBody = assert(source:match(
    "%-%- test:map%-priority:start\n(.-)\n%-%- test:map%-priority:end"),
    "找不到 map-priority 測試區段")

local resolveBody = assert(source:match(
    "%-%- test:resolve%-mapdir:start\n(.-)\n%-%- test:resolve%-mapdir:end"),
    "找不到 resolve-mapdir 測試區段")

local collectBody = assert(source:match(
    "%-%- test:collect%-pyramids:start\n(.-)\n%-%- test:collect%-pyramids:end"),
    "找不到 collect-pyramids 測試區段")

local mapsBody = assert(source:match(
    "%-%- test:maps:start\n(.-)\n%-%- test:maps:end"),
    "找不到 maps 測試區段")

local registerBody = assert(source:match(
    "%-%- test:register%-maps:start\n(.-)\n%-%- test:register%-maps:end"),
    "找不到 register-maps 測試區段")

local compile = loadstring or load
local prelude = [=[
local mapStr          -- getWorld():getMap() 回傳值（nil＝world 為 nil）
local worldError = false
local activeMods = {} -- getActivatedMods 的內容（陣列）
local mapOverlays = {}
local registeredPacks = {}
local logs = {}
local function log(msg) logs[#logs + 1] = msg end
-- registerMaps 用 print 而非 log：攔進 logs 以便斷言（local 遮蔽全域 print）
local print = function(msg) logs[#logs + 1] = msg end
MinidoracatMiniMapAPI = {}
-- modID -> 該 mod 提供的地圖資料夾名陣列（nil＝mod 不存在或沒有地圖，引擎回 null）。
-- 引擎會把 commonDir 與 versionDir 兩段各自 add，同名資料夾可能出現兩次
local mapFolders = {}
local function getMapFoldersForMod(id)
    local list = mapFolders[id]
    if list == nil then return nil end
    return {
        size = function(_) return #list end,
        get = function(_, i) return list[i + 1] end,
    }
end
-- collectPyramids 的引擎依賴 stub
local MAPS = {}                 -- 本 MOD manifest（基底全圖）
local OWN_MOD_ID = "OwnMod"
local LEGACY_CANONICAL = "minidoracat_minimap.pyramid.zip"
local boolOptions = {}          -- MOD 選項
local knownMods = {}            -- modID -> true（getModInfoByID 回非 nil）
local zipFiles = {}             -- "modID|zip" -> true（哪些 zip 真的存在）
local function getFileSeparator() return "/" end
local function getBoolOption(key, default)
    local v = boolOptions[key]
    if v == nil then return default end
    return v
end
local function getModInfoByID(id)
    if not knownMods[id] then return nil end
    return { id = id }
end
local function findZip(modInfo, sep, zip)
    if zipFiles[modInfo.id .. "|" .. zip] then
        return "/mods" .. sep .. modInfo.id .. sep .. "media" .. sep .. "minimap" .. sep .. zip
    end
    return nil
end
local function getWorld()
    if worldError then error("boom") end
    if mapStr == nil then return nil end
    return { getMap = function(_) return mapStr end }
end
local function getActivatedMods()
    return {
        size = function(_) return #activeMods end,
        get = function(_, i) return activeMods[i + 1] end,
    }
end
]=]
local suffix = [=[
return {
    getLoadedMapDirs = getLoadedMapDirs,
    passesMapDir = passesMapDir,
    rebuildMapOverlays = rebuildMapOverlays,
    overlays = mapOverlays,
    logs = logs,
    orderByMapPriority = orderByMapPriority,
    resolveMapDirByMod = resolveMapDirByMod,
    collectPyramids = collectPyramids,
    registerMaps = MinidoracatMiniMapAPI.registerMaps,
    getPacks = function() return registeredPacks end, -- setup 會重新賦值，必須用 getter
    setup = function(opts)
        mapStr = opts.mapStr
        worldError = opts.worldError or false
        activeMods = opts.activeMods or {}
        registeredPacks = opts.packs and { { owner = "test", entries = opts.packs } } or {}
        mapFolders = opts.mapFolders or {}
        MAPS = opts.maps or {}
        knownMods = opts.knownMods or {}
        zipFiles = opts.zipFiles or {}
        boolOptions = opts.boolOptions or {}
        for i = #logs, 1, -1 do logs[i] = nil end -- 每次 setup 歸零：log 斷言只看本案例
    end,
}
]=]
local mod = assert(compile(
    prelude .. "\n" .. body .. "\n" .. resolveBody .. "\n" .. priorityBody .. "\n"
        .. rebuildBody .. "\n" .. collectBody .. "\n" .. registerBody .. "\n" .. suffix,
    "mapdir-gate"))()

-- 正常 MP/SP：分號串列→集合，含空白修剪、空段忽略
mod.setup({ mapStr = "SZ_The_Mall; New Ellroy ;;Muldraugh, KY" })
local dirs = mod.getLoadedMapDirs()
assert(dirs["SZ_The_Mall"] and dirs["New Ellroy"] and dirs["Muldraugh, KY"], "串列解析失敗")
-- 值＝引擎優先序（1 最高），疊層順序靠它；順序在 0.11.0 前被丟成 true
assert(dirs["SZ_The_Mall"] == 1 and dirs["New Ellroy"] == 2 and dirs["Muldraugh, KY"] == 3,
    "優先序 index 錯誤")
assert(dirs["SZ_Bunker_3"] == nil, "不該有未列目錄")
assert(mod.passesMapDir({ mapDir = "SZ_The_Mall" }, dirs), "已載入據點應通過")
assert(not mod.passesMapDir({ mapDir = "SZ_Bunker_3" }, dirs), "未載入據點應擋下")
assert(mod.passesMapDir({}, dirs), "無 mapDir 條目應通過")
assert(mod.passesMapDir({ mapDir = "" }, dirs), "空字串 mapDir 應視同未指定")

-- 單一目錄（無分號）也要能解析
mod.setup({ mapStr = "Muldraugh, KY" })
dirs = mod.getLoadedMapDirs()
assert(dirs and dirs["Muldraugh, KY"], "單目錄解析失敗")

-- fail-open：拿不到清單（DEFAULT／空字串／拆完空集／world nil／getWorld 拋錯）
-- ＝回退 mod ID 閘門
for _, opts in ipairs({ { mapStr = "DEFAULT" }, { mapStr = "" }, { mapStr = ";;; " },
    { mapStr = nil }, { worldError = true } }) do
    mod.setup(opts)
    assert(mod.getLoadedMapDirs() == nil, "應回 nil（fail-open）")
    assert(mod.passesMapDir({ mapDir = "SZ_The_Mall" }, nil), "fail-open 應通過")
end

-- 整合點：rebuildMapOverlays 有套 mapDir 閘門（防日後改壞/漏套）
local entries = {
    { mapMod = "Secretz42", mapDir = "SZ_The_Mall", bounds = { 1, 1, 2, 2 } },   -- 已載入
    { mapMod = "Secretz42", mapDir = "SZ_Bunker_3", bounds = { 1, 1, 2, 2 } },   -- 未載入
    { mapMod = "Secretz42", bounds = { 1, 1, 2, 2 } },                            -- 無 mapDir
    { mapMod = "NotActive", mapDir = "SZ_The_Mall", bounds = { 1, 1, 2, 2 } },    -- mod 未啟用
}
mod.setup({ mapStr = "SZ_The_Mall;Muldraugh, KY", activeMods = { "Secretz42" }, packs = entries })
mod.rebuildMapOverlays()
assert(#mod.overlays == 2, "應只剩已載入＋無 mapDir 兩條，實得 " .. #mod.overlays)
assert(mod.overlays[1] == entries[1] and mod.overlays[2] == entries[3], "整合過濾結果錯位")

-- 整合點 fail-open：拿不到清單時 mapDir 不擋，僅 mod ID 閘門生效
mod.setup({ worldError = true, activeMods = { "Secretz42" }, packs = entries })
mod.rebuildMapOverlays()
assert(#mod.overlays == 3, "fail-open 應回 3 條（僅擋未啟用 mod），實得 " .. #mod.overlays)

-- ═══ orderByMapPriority：影像疊層跟隨引擎地圖優先序 ═══
-- 回歸案例（2026-08-17 地圖包留言）：Grapeseed 北緣 3 cell 與 Greenleaf 重疊，
-- 舊字母序讓後建的 Greenleaf（該帶是空草地）蓋掉 Grapeseed 城區。
-- 建層順序＝清單順序、後建在上 ⇒ 引擎優先者必須排在最後
local function zips(list)
    local out = {}
    for i = 1, #list do out[i] = list[i].zip end
    return table.concat(out, ",")
end
local base = { zip = "Muldraugh_KY.pyramid.zip" }           -- 基底：zip 名對不到目錄
local grape = { zip = "Grapeseed.pyramid.zip" }
local green = { zip = "Greenleaf.pyramid.zip" }
local legacy = { zip = "minidoracat_minimap.pyramid.zip" }  -- 第三方 addon 約定名

-- Grapeseed 優先（玩家實測的世界內容）→ 它要畫最上
mod.setup({ mapStr = "Grapeseed;Greenleaf;Muldraugh, KY" })
local out = mod.orderByMapPriority({ base, grape, green, legacy }, mod.getLoadedMapDirs())
assert(zips(out) == "Muldraugh_KY.pyramid.zip,Greenleaf.pyramid.zip,"
    .. "Grapeseed.pyramid.zip,minidoracat_minimap.pyramid.zip",
    "Grapeseed 優先時應排在 Greenleaf 之後，實得 " .. zips(out))

-- 反向 map order → 同樣跟隨引擎，Greenleaf 畫最上
mod.setup({ mapStr = "Greenleaf;Grapeseed;Muldraugh, KY" })
out = mod.orderByMapPriority({ base, grape, green, legacy }, mod.getLoadedMapDirs())
assert(zips(out) == "Muldraugh_KY.pyramid.zip,Grapeseed.pyramid.zip,"
    .. "Greenleaf.pyramid.zip,minidoracat_minimap.pyramid.zip",
    "Greenleaf 優先時應排在 Grapeseed 之後，實得 " .. zips(out))

-- 對不到目錄者維持原位：基底恆在最底、legacy 恆在最上（語意不可被排序破壞）
mod.setup({ mapStr = "Greenleaf;Grapeseed;Muldraugh, KY" })
out = mod.orderByMapPriority({ base, grape, legacy, green }, mod.getLoadedMapDirs())
assert(out[1] == base and out[3] == legacy, "unknown 條目應留在原位置")
assert(out[2] == grape and out[4] == green, "known 條目只能在自己的槽位間重排")

-- legacy 的隔離必須是顯式的 sortable=false，不能只靠「zip basename 對不上目錄」：
-- 若真有地圖目錄叫 minidoracat_minimap，隱含隔離會破功、legacy 離開最上層
-- （codex review 第三輪抓出）
mod.setup({ mapStr = "High;minidoracat_minimap;Muldraugh, KY" })
local legacySafe = { zip = "minidoracat_minimap.pyramid.zip", sortable = false }
local highPri = { zip = "High.pyramid.zip" }
out = mod.orderByMapPriority({ base, highPri, legacySafe }, mod.getLoadedMapDirs())
assert(out[3] == legacySafe, "sortable=false 的 legacy 必須留在最上層，實得 " .. zips(out))
assert(out[2] == highPri, "其餘條目照常吃優先序")

-- mapDir 欄位優先於 zip basename：alias 條目必須真的被移動（否則本案例是空斷言——
-- 忽略 mapDir 時它同樣留在原位）。ActualDir 優先序高於 Other ⇒ alias 要排到最後
mod.setup({ mapStr = "ActualDir;Other" })
local aliased = { zip = "renamed.pyramid.zip", mapDir = "ActualDir" }
local other = { zip = "Other.pyramid.zip" }
out = mod.orderByMapPriority({ aliased, other }, mod.getLoadedMapDirs())
assert(out[1] == other and out[2] == aliased, "mapDir 應對上目錄並依優先序移動")

-- 明示 mapDir 未載入時不得偷偷退回 zip basename（basename 恰好是別的已載入目錄）：
-- 該條目視為 unresolved、固定原位，否則會被當成別人的優先序搬走
mod.setup({ mapStr = "High;Low;ZipClaim" })
local high = { zip = "High.pyramid.zip" }
local low = { zip = "Low.pyramid.zip" }
local misdirected = { zip = "ZipClaim.pyramid.zip", mapDir = "NotLoaded" }
out = mod.orderByMapPriority({ high, misdirected, low }, mod.getLoadedMapDirs())
assert(out[1] == low and out[2] == misdirected and out[3] == high,
    "明示但未載入的 mapDir 應維持原位、不得 fallback 到 zip basename")

-- 3 筆全可解析、輸入既非正序也非反序：證明是完整排序而非單次 swap
mod.setup({ mapStr = "A;B;C" })
local A, B, C = { zip = "A.pyramid.zip" }, { zip = "B.pyramid.zip" }, { zip = "C.pyramid.zip" }
out = mod.orderByMapPriority({ B, A, C }, mod.getLoadedMapDirs())
assert(zips(out) == "C.pyramid.zip,B.pyramid.zip,A.pyramid.zip",
    "3 筆應完整依優先序遞減，實得 " .. zips(out))

-- 同一目錄的兩個 zip（registry 別名條目）＝相同 pri：必須保留原相對序。
-- 插入排序的位移條件若從嚴格 < 放寬成 <=，這條會翻轉而失敗
mod.setup({ mapStr = "High;Shared;Low" })
local shared1 = { zip = "s1.pyramid.zip", mapDir = "Shared" }
local shared2 = { zip = "s2.pyramid.zip", mapDir = "Shared" }
local hi = { zip = "High.pyramid.zip" }
local lo = { zip = "Low.pyramid.zip" }
out = mod.orderByMapPriority({ shared1, hi, shared2, lo }, mod.getLoadedMapDirs())
assert(zips(out) == "Low.pyramid.zip,s1.pyramid.zip,s2.pyramid.zip,High.pyramid.zip",
    "相同優先序必須穩定保留原序，實得 " .. zips(out))

-- mapDir 空字串＝視同未指定（與 passesMapDir 語意一致），仍走 zip basename
mod.setup({ mapStr = "Grapeseed;Greenleaf" })
out = mod.orderByMapPriority({ { zip = "Grapeseed.pyramid.zip", mapDir = "" }, green },
    mod.getLoadedMapDirs())
assert(out[1] == green, "空字串 mapDir 應退回 zip basename 並依優先序移動")

-- fail-open：拿不到清單時原樣返回（不得亂序）
mod.setup({ worldError = true })
out = mod.orderByMapPriority({ base, grape, green }, mod.getLoadedMapDirs())
assert(zips(out) == "Muldraugh_KY.pyramid.zip,Grapeseed.pyramid.zip,Greenleaf.pyramid.zip",
    "fail-open 應保持原順序")

-- 全部對不到目錄：零動作
mod.setup({ mapStr = "Muldraugh, KY" })
out = mod.orderByMapPriority({ base, legacy }, mod.getLoadedMapDirs())
assert(out[1] == base and out[2] == legacy, "無可排序條目時應原樣")

-- 重複目錄：首見優先序不得被後出現的同名覆寫（引擎同樣去重）
mod.setup({ mapStr = "Grapeseed;Greenleaf;Grapeseed" })
dirs = mod.getLoadedMapDirs()
assert(dirs["Grapeseed"] == 1 and dirs["Greenleaf"] == 2, "重複目錄應保留首見優先序")
out = mod.orderByMapPriority({ grape, green }, dirs)
assert(out[1] == green and out[2] == grape, "重複目錄不應改變疊層結果")

-- pcall 例外才留 log；DEFAULT／空串是世界未 init 的正常路徑，必須靜默（避免刷屏）
mod.setup({ worldError = true })
mod.getLoadedMapDirs()
assert(#mod.logs == 1, "getMap 拋例外應留一行診斷，實得 " .. #mod.logs)
for _, opts in ipairs({ { mapStr = "DEFAULT" }, { mapStr = "" }, { mapStr = ";;; " },
    { mapStr = nil } }) do
    mod.setup(opts) -- setup 歸零 logs
    mod.getLoadedMapDirs()
    assert(#mod.logs == 0, "世界未 init 的路徑不得 log，實得 " .. #mod.logs)
end

-- ═══ resolveMapDirByMod：zip 名對不上時，問引擎該 mod 提供哪些地圖資料夾 ═══
-- 形狀取自本機實測（codex review 抓出的正式資料反例）：地圖包 3 筆 zip 名 ≠ 目錄名，
-- 其中 Atlanta - Safe Zone 與 EdsAutoSalvageB42 真的共用 3 格 cell
local ATL_MOD = "Atlanta - Safe Zone-Chinese Survivors’ Community"
local ATL_DIR = "Atlanta - Safe Zone-Chinese Survivors’ Community"  -- zip 名只有 "Atlanta - Safe Zone"
local EDS_DIR = "EdsAutoSalvageB42"

mod.setup({
    mapStr = ATL_MOD .. ";" .. EDS_DIR .. ";Muldraugh, KY",
    mapFolders = { [ATL_MOD] = { ATL_DIR } },
})
dirs = mod.getLoadedMapDirs()
assert(mod.resolveMapDirByMod(ATL_MOD, dirs) == ATL_DIR, "唯一命中應回該目錄名")

-- 端到端：補齊 identity 後，引擎高優先的 Atlanta 必須排到最後（畫最上）。
-- 未補時它對不上 zip 名＝unresolved 留原位，Eds 後建仍蓋在上面（回報中的錯序）
local atl = { zip = "Atlanta - Safe Zone.pyramid.zip", mapMod = ATL_MOD }
local eds = { zip = "EdsAutoSalvageB42.pyramid.zip" }
out = mod.orderByMapPriority({ atl, eds }, dirs)
assert(out[1] == atl and out[2] == eds, "未補 identity 時 Atlanta 應維持原位（舊錯序）")
atl.mapDir = mod.resolveMapDirByMod(atl.mapMod, dirs)
out = mod.orderByMapPriority({ atl, eds }, dirs)
assert(out[1] == eds and out[2] == atl, "補齊 identity 後 Atlanta 應排到最後、畫最上")

-- Kardinal 形狀：mod id 與 zip 名都不等於目錄名（目錄其實叫 Raven Creek B42）
mod.setup({
    mapStr = "Raven Creek B42;Muldraugh, KY",
    mapFolders = { kardinal_ravencreek_B42 = { "Raven Creek B42" } },
})
assert(mod.resolveMapDirByMod("kardinal_ravencreek_B42", mod.getLoadedMapDirs())
    == "Raven Creek B42", "應回實際目錄名而非 mod id／zip 名")

-- ═══ collectPyramids 整合：真的走完蒐集 → identity 補齊 → 疊層排序 ═══
-- 這段不手動塞 mapDir，證明接線正確（前面的 orderByMapPriority 案例只驗決策）
local BASE_ZIP = "Muldraugh_KY.pyramid.zip"
local EDS_MOD = "EdsAutoSalvage"
local function collectSetup(extra)
    local opts = {
        mapStr = ATL_MOD .. ";" .. EDS_DIR .. ";Muldraugh, KY",
        activeMods = { ATL_MOD, EDS_MOD },
        maps = { { zip = BASE_ZIP, sortable = false } }, -- 同正式 MAPS
        knownMods = { OwnMod = true, test = true, [ATL_MOD] = true, [EDS_MOD] = true },
        zipFiles = {
            ["OwnMod|" .. BASE_ZIP] = true,
            ["test|Atlanta - Safe Zone.pyramid.zip"] = true,
            ["test|EdsAutoSalvageB42.pyramid.zip"] = true,
        },
        mapFolders = { [ATL_MOD] = { ATL_DIR }, [EDS_MOD] = { EDS_DIR } },
        packs = {
            { zip = "Atlanta - Safe Zone.pyramid.zip", mapMod = ATL_MOD },
            { zip = "EdsAutoSalvageB42.pyramid.zip", mapMod = EDS_MOD },
        },
    }
    for k, v in pairs(extra or {}) do opts[k] = v end
    mod.setup(opts)
end

-- Atlanta（引擎優先序 1）的 zip 名對不上資料夾名，靠 getMapFoldersForMod 反查後
-- 必須排到最後＝畫最上；基底全圖沒有 mapMod 可問，恆在最底
collectSetup()
local got = mod.collectPyramids()
assert(zips(got) == BASE_ZIP .. ",EdsAutoSalvageB42.pyramid.zip,"
    .. "Atlanta - Safe Zone.pyramid.zip",
    "整合結果應為 基底 → Eds → Atlanta，實得 " .. zips(got))
assert(got[3].mapDir == ATL_DIR, "Atlanta 的 mapDir 應由反查補齊")
assert(#mod.logs == 0, "全部解析成功不該有 log，實得 " .. table.concat(mod.logs, " | "))

-- 基底「恆在最底」也必須是顯式 sortable=false：若真有地圖 MOD 把資料夾命名成
-- Muldraugh_KY，靠「zip basename 對不上目錄」的隱含隔離會破功，基底會被優先序
-- 搬到 MOD 地圖上面（code review 抓出）。撞名目錄放中間優先才有鑑別力
collectSetup({ mapStr = ATL_MOD .. ";Muldraugh_KY;" .. EDS_DIR .. ";Muldraugh, KY" })
got = mod.collectPyramids()
assert(got[1].zip == BASE_ZIP, "基底必須留在最底，實得 " .. zips(got))
assert(got[1].sortable == false, "manifest 的 sortable 旗標必須傳進待掛載清單")
assert(zips(got) == BASE_ZIP .. ",EdsAutoSalvageB42.pyramid.zip,"
    .. "Atlanta - Safe Zone.pyramid.zip", "其餘條目照常吃優先序，實得 " .. zips(got))

-- 產品資料本身的契約（fixture 會覆寫 MAPS，所以要直接讀正式清單）：
-- 沒有 mapMod 的條目＝基底全圖，必須顯式 sortable=false
local prodMaps = assert(compile(mapsBody .. "\nreturn MAPS", "maps"))()
assert(#prodMaps > 0, "正式 MAPS 不該是空的")
for i = 1, #prodMaps do
    local e = prodMaps[i]
    if e.mapMod == nil then
        assert(e.sortable == false,
            "正式 MAPS 的基底條目必須 sortable=false（否則資料夾撞名時會被優先序搬走）："
            .. tostring(e.zip))
    end
end

-- 反轉引擎優先序：影像跟著換邊（Eds 變最上）
collectSetup({ mapStr = EDS_DIR .. ";" .. ATL_MOD .. ";Muldraugh, KY" })
got = mod.collectPyramids()
assert(zips(got) == BASE_ZIP .. ",Atlanta - Safe Zone.pyramid.zip,"
    .. "EdsAutoSalvageB42.pyramid.zip",
    "優先序反轉後應為 基底 → Atlanta → Eds，實得 " .. zips(got))

-- 真資料缺口：該 mod 有多張地圖、registry 又沒寫 mapDir ⇒ 解析不到，log 一行提示補
collectSetup({ mapFolders = { [ATL_MOD] = { ATL_DIR, "Atlanta - Extra" },
    [EDS_MOD] = { EDS_DIR } } })
got = mod.collectPyramids()
assert(got[2].mapDir == nil, "含糊時不得亂填 mapDir")
assert(#mod.logs == 1 and string.find(mod.logs[1], "Atlanta - Safe Zone.pyramid.zip", 1, true),
    "解析不到應提示補 mapDir，實得 " .. table.concat(mod.logs, " | "))

-- 引擎完全問不到地圖資料夾時：只有「zip 名也對不上」的條目會提示（Atlanta），
-- Eds 的 zip basename 本身就是資料夾名、不進反查路徑；基底沒有 mapMod 也不進
collectSetup({ mapFolders = {} })
got = mod.collectPyramids()
assert(#mod.logs == 1 and string.find(mod.logs[1], "Atlanta", 1, true),
    "只該有 Atlanta 一行提示，實得 " .. table.concat(mod.logs, " | "))
assert(got[2].mapDir == nil and got[3].mapDir == nil, "解析失敗不得亂填")

-- 「顯示 MOD 地圖區塊」關閉：只剩基底，排序不動它
collectSetup({ boolOptions = { MapPackLayers = false } })
got = mod.collectPyramids()
assert(zips(got) == BASE_ZIP, "關閉地圖包圖層後只該有基底，實得 " .. zips(got))

-- collectPyramids 必須把 legacy 標成 sortable=false：連「地圖目錄剛好叫
-- minidoracat_minimap」這種撞名情境都要留在最上層。撞名目錄刻意放中間優先——
-- 若 legacy 參與排序，它會被移到 Eds 之後、Atlanta 之前，最後一位就不是它了
collectSetup({
    mapStr = ATL_MOD .. ";minidoracat_minimap;" .. EDS_DIR .. ";Muldraugh, KY",
    activeMods = { ATL_MOD, EDS_MOD, "SelfHostedMap" },
    knownMods = { OwnMod = true, test = true, [ATL_MOD] = true, [EDS_MOD] = true,
        SelfHostedMap = true },
    zipFiles = {
        ["OwnMod|" .. BASE_ZIP] = true,
        ["test|Atlanta - Safe Zone.pyramid.zip"] = true,
        ["test|EdsAutoSalvageB42.pyramid.zip"] = true,
        ["SelfHostedMap|minidoracat_minimap.pyramid.zip"] = true,
    },
})
got = mod.collectPyramids()
assert(got[#got].zip == "minidoracat_minimap.pyramid.zip",
    "legacy 應維持最上層，實得 " .. zips(got))
assert(got[#got].sortable == false, "collectPyramids 必須顯式標記 legacy 不可排序")

-- 同名資料夾在 common 與版本目錄各出現一次（引擎兩段各自 add）：不算歸屬含糊
mod.setup({
    mapStr = "DualRoot;Muldraugh, KY",
    mapFolders = { dual = { "DualRoot", "DualRoot" } },
})
assert(mod.resolveMapDirByMod("dual", mod.getLoadedMapDirs()) == "DualRoot",
    "同名資料夾重複回報不算含糊")

-- 一 mod 多地圖（SecretZ 類）：無論載入幾張都不得反推——mod ID → 資料夾是多對一，
-- zip 可能屬於未載入的那張，猜錯會把它標成別張的 identity（codex review 抓出）
for _, ms in ipairs({ "SZ_The_Mall;SZ_Bunker_3;Muldraugh, KY", "SZ_The_Mall;Muldraugh, KY" }) do
    mod.setup({ mapStr = ms, mapFolders = { Secretz42 = { "SZ_The_Mall", "SZ_Bunker_3" } } })
    assert(mod.resolveMapDirByMod("Secretz42", mod.getLoadedMapDirs()) == nil,
        "一 mod 多地圖不得亂猜（mapStr=" .. ms .. "）")
end

-- mod 不存在（引擎回 nil）／該 mod 的地圖都未載入 → nil
mod.setup({ mapStr = "Other;Muldraugh, KY",
    mapFolders = { lonely = { "NotLoaded" } } })
dirs = mod.getLoadedMapDirs()
assert(mod.resolveMapDirByMod("nosuchmod", dirs) == nil, "mod 不存在應回 nil")
assert(mod.resolveMapDirByMod("lonely", dirs) == nil, "目錄未載入應回 nil")

-- ═══ registerMaps：canonical 檔名是自動掃描 lane 的保留名 ═══
-- 兩條 lane 同時產出同檔名條目時，registerMaps 那份較早被蒐集、會吃疊層優先序被搬走，
-- 而 mount 又以第一個同 layerId 為準去重＝把固定尾端的 legacy 那份丟掉，canonical
-- 層可能被壓到其他地圖層下面（codex review 第四輪以 probe 重現）。單點拒收
mod.setup({})
mod.registerMaps("SomeAddon", {
    { zip = "minidoracat_minimap.pyramid.zip", mapMod = "SomeAddon" }, -- 保留名，該被拒
    { zip = "RealMap.pyramid.zip", mapMod = "SomeAddon" },             -- 正常條目
})
local packs = mod.getPacks()
assert(#packs == 1 and #packs[1].entries == 1, "保留名條目應被拒、其餘照收")
assert(packs[1].entries[1].zip == "RealMap.pyramid.zip", "收下的應是正常條目")
assert(#mod.logs == 1 and string.find(mod.logs[1], "reserved", 1, true),
    "應說明是保留名，實得 " .. table.concat(mod.logs, " | "))

-- 整包都是保留名 ⇒ 空包不註冊（地圖包選項不該因空資料出現）
mod.setup({})
mod.registerMaps("SomeAddon", { { zip = "minidoracat_minimap.pyramid.zip" } })
assert(#mod.getPacks() == 0, "整包無效時不該註冊")

print("test_mapdir_gate: OK")
