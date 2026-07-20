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

local compile = loadstring or load
local prelude = [=[
local mapStr          -- getWorld():getMap() 回傳值（nil＝world 為 nil）
local worldError = false
local activeMods = {} -- getActivatedMods 的內容（陣列）
local mapOverlays = {}
local registeredPacks = {}
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
    setup = function(opts)
        mapStr = opts.mapStr
        worldError = opts.worldError or false
        activeMods = opts.activeMods or {}
        registeredPacks = opts.packs and { { owner = "test", entries = opts.packs } } or {}
    end,
}
]=]
local mod = assert(compile(
    prelude .. "\n" .. body .. "\n" .. rebuildBody .. "\n" .. suffix, "mapdir-gate"))()

-- 正常 MP/SP：分號串列→集合，含空白修剪、空段忽略
mod.setup({ mapStr = "SZ_The_Mall; New Ellroy ;;Muldraugh, KY" })
local dirs = mod.getLoadedMapDirs()
assert(dirs["SZ_The_Mall"] and dirs["New Ellroy"] and dirs["Muldraugh, KY"], "串列解析失敗")
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

print("test_mapdir_gate: OK")
