-- 圖層尾端守恆（layersNeedRebuild）＋掛載/自癒執行段（mountPyramidLayers）
-- 離線回歸測試。仿 test_mapdir_gate.lua：抽主檔標記區段→補最小 stub→離線跑。
-- 用法：lua scripts/test_layer_tail.lua
local mainPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local file = assert(io.open(mainPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local tailBody = assert(source:match(
    "%-%- test:layer%-tail:start\n(.-)\n%-%- test:layer%-tail:end"),
    "找不到 layer-tail 測試區段")
local mountBody = assert(source:match(
    "%-%- test:layer%-mount:start\n(.-)\n%-%- test:layer%-mount:end"),
    "找不到 layer-mount 測試區段")

local compile = loadstring or load
local prelude = [=[
local mountedLayerIds = {}
local logs = {}
local function log(msg) logs[#logs + 1] = msg end
]=]
local suffix = [=[
return {
    layersNeedRebuild = layersNeedRebuild,
    mountPyramidLayers = mountPyramidLayers,
    mountedLayerIds = mountedLayerIds,
    logs = logs,
    clearLogs = function() for i = #logs, 1, -1 do logs[i] = nil end end,
}
]=]
local mod = assert(compile(
    prelude .. "\n" .. tailBody .. "\n" .. mountBody .. "\n" .. suffix, "layer-tail"))()

--------------------------------------------------------------------------------
-- 一、純決策 layersNeedRebuild
--------------------------------------------------------------------------------
local need = mod.layersNeedRebuild

-- 穩態：K 層以原順序連續佔據尾端（原版 10 層＋本 MOD 3 層）＝不動
assert(not need({ 10, 11, 12 }, 13), "穩態尾端不應重掛")
-- 單層穩態
assert(not need({ 12 }, 13), "單層尾端不應重掛")
-- 空集（呼叫端已擋 entries==0，防禦性語意＝不動）
assert(not need({}, 13), "空集不應重掛")

-- 全缺（初次掛載）：index 全 -1 ＝重掛（走建層路徑）
assert(need({ -1, -1, -1 }, 10), "初次掛載應建層")
-- 部分缺層
assert(need({ 10, -1, 12 }, 13), "缺層應重掛")
-- 被壓下：向量層 append 到本 MOD 之後（藍色遮蓋窗口本尊）
assert(need({ 10, 11, 12 }, 14), "被外來層壓下應重掛")
-- 亂序：層都在但順序被打散
assert(need({ 11, 10, 12 }, 13), "亂序應重掛")
-- 不連續：中間插入他層
assert(need({ 9, 11, 12 }, 13), "不連續應重掛")
-- 單層被壓下
assert(need({ 11 }, 13), "單層被壓下應重掛")
-- -1 哨兵撞值：layerCount 小到期望值恰為 -1 時，缺層不可被誤判就位
assert(need({ -1 }, 0), "空樣式缺層應重掛")
assert(need({ -1, 0, 1 }, 2), "首層缺失不應被哨兵算術吃掉")

--------------------------------------------------------------------------------
-- 二、掛載/自癒執行段 mountPyramidLayers（fake styleAPI 打樁）
--------------------------------------------------------------------------------
-- ids 陣列＝樣式層列（index 0 起算由 fake 換算）；failOnce 注入建層失敗
local function fakeStyle(ids, opts)
    opts = opts or {}
    local S = { ids = ids }
    function S:indexOfLayer(id)
        for i, v in ipairs(self.ids) do if v == id then return i - 1 end end
        return -1
    end
    function S:getLayerCount() return #self.ids end
    function S:getLayerByIndex(i)
        local id = self.ids[i + 1]
        return id and { getID = function() return id end } or nil
    end
    function S:removeLayerById(id)
        for i, v in ipairs(self.ids) do
            if v == id then table.remove(self.ids, i) return end
        end
    end
    function S:newPyramidLayer(id)
        for _, v in ipairs(self.ids) do
            assert(v ~= id, "重複 id 進到 newPyramidLayer：去重失效（" .. id .. "）")
        end
        self.ids[#self.ids + 1] = id
        local layer = {
            setPyramidFileName = function()
                if opts.failOnce then
                    opts.failOnce = false
                    error("injected setPyramidFileName failure")
                end
            end,
            addFill = function() end,
        }
        return layer
    end
    return S
end

local function entriesOf(zips)
    local t = {}
    for _, z in ipairs(zips) do t[#t + 1] = { zip = z, path = "fake/" .. z } end
    return t
end
local VANILLA = { "forest", "pyramid-forest", "text-place", "paper" }
local function vanillaStyle(extra)
    local ids = {}
    for _, v in ipairs(VANILLA) do ids[#ids + 1] = v end
    for _, v in ipairs(extra or {}) do ids[#ids + 1] = v end
    return fakeStyle(ids)
end
local function idsEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- (1) 初次掛載＋同 zip alias 去重（Chinatown 兩條同 zip）：只建一層、不撞 id、順序＝註冊序
local st = vanillaStyle()
mod.mountPyramidLayers(st, entriesOf({ "A.pyramid.zip", "B.pyramid.zip", "B.pyramid.zip", "C.pyramid.zip" }))
assert(idsEqual(st.ids, { "forest", "pyramid-forest", "text-place", "paper",
    "minidoracat_A", "minidoracat_B", "minidoracat_C" }), "初掛結果錯：" .. table.concat(st.ids, ","))

-- (2) 冪等：同 style 連跑兩次，第二次零動作（ids 逐位元不變、無新 log）
mod.clearLogs()
local before = { table.unpack(st.ids) }
mod.mountPyramidLayers(st, entriesOf({ "A.pyramid.zip", "B.pyramid.zip", "C.pyramid.zip" }))
assert(idsEqual(st.ids, before), "冪等重跑不應動層")
assert(#mod.logs == 0, "冪等重跑不應輸出 log")

-- (3) 被外來層壓下：自癒奪回尾端、外來層被擠下、自癒證據行指認兇手
st.ids[#st.ids + 1] = "foreign_overlay"
mod.clearLogs()
mod.mountPyramidLayers(st, entriesOf({ "A.pyramid.zip", "B.pyramid.zip", "C.pyramid.zip" }))
assert(idsEqual(st.ids, { "forest", "pyramid-forest", "text-place", "paper", "foreign_overlay",
    "minidoracat_A", "minidoracat_B", "minidoracat_C" }), "自癒後應奪回尾端：" .. table.concat(st.ids, ","))
assert(mod.logs[1] and mod.logs[1]:find("foreign_overlay", 1, true), "自癒證據行應指認最上層 id")

-- (4) stale 清掃：entries 縮集（如 MapPackLayers 關閉）→ 舊層從該 style 移除，
--     registry 保留（另一側 style 卸載仍需要）
mod.mountPyramidLayers(st, entriesOf({ "A.pyramid.zip", "C.pyramid.zip" }))
assert(idsEqual(st.ids, { "forest", "pyramid-forest", "text-place", "paper", "foreign_overlay",
    "minidoracat_A", "minidoracat_C" }), "縮集應清掉 stale 層：" .. table.concat(st.ids, ","))
assert(mod.mountedLayerIds["minidoracat_B"], "共用 registry 不可刪 key")

-- (5) 建層中途失敗：best-effort 全拆＋rethrow（不留「假穩態」殘層），重跑即自癒
local failOpts = { failOnce = true }
local st2 = fakeStyle({ "forest", "paper" }, failOpts)
local ok = pcall(mod.mountPyramidLayers, st2, entriesOf({ "A.pyramid.zip", "B.pyramid.zip" }))
assert(not ok, "注入失敗應 rethrow")
assert(idsEqual(st2.ids, { "forest", "paper" }), "失敗後不應殘留本 MOD 層：" .. table.concat(st2.ids, ","))
mod.mountPyramidLayers(st2, entriesOf({ "A.pyramid.zip", "B.pyramid.zip" }))
assert(idsEqual(st2.ids, { "forest", "paper", "minidoracat_A", "minidoracat_B" }), "失敗後重跑應自癒")

print("test_layer_tail: OK")
