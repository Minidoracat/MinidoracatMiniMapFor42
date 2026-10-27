-- 殭屍熱度的無地圖資料格防線（主檔 Core.heatViewUnsafe）離線回歸。
-- 引擎 renderZombieIntensity 畫到沒有 lotheader 的格子會 NPE，接著在顯示卡驅動裡閃退
-- （2026-10-28 Workshop 回報，E2E void-teleport-sp 重現），所以小地圖視野碰到這種格子就關熱度。
-- 取主檔標記區段的真實作（visible-aabb、heat-void），IsoLot.getHeader 換成假件：
-- 地圖格＝0..77 x 0..62（原版 lotheader 範圍），其餘都沒有地圖資料。
-- 驗：地圖內開、碰到虛空立刻關、離開後連續 4 幀才恢復（中間漏一幀重數）、拉遠到整張世界一律關、
-- 引擎 mult 格塊外擴到的格子也算、同一視野每幀不再查 IsoLot。
-- 用法：lua scripts/test_heat_void.lua [主檔路徑]
local MAIN = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end
local function slice(source, name)
    local tag = name:gsub("%-", "%%-")
    return assert(source:match("%-%- test:" .. tag .. ":start\n(.-)\n%-%- test:" .. tag .. ":end"),
        "找不到區段 " .. name)
end

local lotCalls = 0
local env = setmetatable({
    Core = {},
    IsoLot = {
        getHeader = function(cx, cy)
            lotCalls = lotCalls + 1
            if cx >= 0 and cx <= 77 and cy >= 0 and cy <= 62 then return { cx, cy } end
            return nil
        end,
    },
}, { __index = _G })
local main = readSource(MAIN)
local visibleWorldAABB = assert(load(slice(main, "visible-aabb") .. "\n" .. slice(main, "heat-void")
    .. "\nreturn visibleWorldAABB", "=heat-void", "t", env))()
local unsafeFn = assert(env.Core.heatViewUnsafe, "主檔未匯出 Core.heatViewUnsafe")

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print("FAIL " .. msg)
    end
end

-- 俯視仿射地圖假件：scale＝每格像素，center＝畫面中心的世界座標
local function newInner(scale, cx, cy, w, h)
    local api = {}
    function api:getWorldScale() return scale end
    function api:uiToWorldX(x) return cx + (x - w / 2) / scale end
    function api:uiToWorldY(_, y) return cy + (y - h / 2) / scale end
    return { mapAPI = api, width = w, height = h, _minidoracatFrame = 0 }
end
-- 照 prerender wrap 的順序：幀號先加一，再問
local function frame(inner)
    inner._minidoracatFrame = inner._minidoracatFrame + 1
    return unsafeFn(inner)
end
local function moveTo(inner, cx, cy, scale, w, h)
    local fresh = newInner(scale, cx, cy, w, h)
    inner.mapAPI, inner.width, inner.height = fresh.mapAPI, w, h
end

local HOME_X, HOME_Y = 11608.5, 9847.5   -- Muldraugh 火車站（回報者給的座標）
local VOID_X, VOID_Y = 20050.5, 2050.5   -- Railroader RV 的房間區（cell 78,8：程序生成區）

-- A. 地圖內：剛開始檢查要連續 4 幀安全才放行，之後一直放行
do
    local inner = newInner(4, HOME_X, HOME_Y, 300, 300)
    local got = {}
    for i = 1, 6 do got[i] = frame(inner) end
    check(got[1] and got[2] and got[3], "A 頭 3 幀仍要關（render thread 可能還有更早的 Drawer）")
    check(not got[4] and not got[5] and not got[6], "A 第 4 幀起放行")
end

-- B. 傳送到虛空：當幀就關；回到地圖內又要連續 4 幀才放行
do
    local inner = newInner(4, HOME_X, HOME_Y, 300, 300)
    for _ = 1, 5 do frame(inner) end
    moveTo(inner, VOID_X, VOID_Y, 4, 300, 300)
    check(frame(inner) == true, "B 視野在沒有 lotheader 的格子：當幀就關")
    check(frame(inner) == true, "B 停在虛空：持續關")
    moveTo(inner, HOME_X, HOME_Y, 4, 300, 300)
    local got = {}
    for i = 1, 4 do got[i] = frame(inner) end
    check(got[1] and got[2] and got[3] and not got[4], "B 回到地圖內：第 4 個安全幀才放行")
end

-- C. 中間漏一幀（熱度關著沒檢查）：安全幀重新數
do
    local inner = newInner(4, HOME_X, HOME_Y, 300, 300)
    frame(inner); frame(inner); frame(inner)
    inner._minidoracatFrame = inner._minidoracatFrame + 1 -- 這幀 prerender 沒呼叫
    local got = {}
    for i = 1, 4 do got[i] = frame(inner) end
    check(got[1] and got[2] and got[3] and not got[4], "C 漏掉一幀後要重新連續 4 幀")
end

-- D. 拉遠到引擎改畫整張世界（1/worldScale > 100）：一律關，不逐格查
do
    local inner = newInner(0.01, HOME_X, HOME_Y, 300, 300)
    local before = lotCalls
    for _ = 1, 6 do check(frame(inner) == true, "D 整張世界一定含程序生成格：關") end
    check(lotCalls == before, "D 整張世界不逐格查 IsoLot")
end

-- E. 視野外接框都在地圖格內，但引擎以 4x4 格塊點陣化時會畫到 78、79 欄（虛空）：要關
do
    -- 30x30 格（900 > 80*9 → mult 4），x 格 48..77、y 格 20..49；右緣落在 77 欄
    local scale = 0.25
    local w = 30 * 256 * scale - 8 * scale -- 扣掉 visibleWorldAABB 的 ±2 格邊距
    local cx = (48 * 256 + 77 * 256 + 255) / 2
    local cy = (20 * 256 + 49 * 256 + 255) / 2
    local inner = newInner(scale, cx, cy, w, w)
    local minX, maxX = visibleWorldAABB(inner)
    check(math.floor(minX / 256) >= 48 and math.floor(maxX / 256) == 77, "E 前提：外接框右緣在 77 欄")
    for _ = 1, 6 do check(frame(inner) == true, "E 引擎格塊外擴到虛空：關") end
    -- 同大小的視野放在地圖中間：放行
    local mid = newInner(scale, (20 * 256 + 49 * 256 + 255) / 2, cy, w, w)
    local got
    for _ = 1, 4 do got = frame(mid) end
    check(got == false, "E 對照：地圖中間同大小的視野放行")
end

-- F. 同一視野每幀是 O(1)：不呼叫 IsoLot、也不逐格翻快取（拉遠時視野可達上千格）
do
    local store, reads = {}, 0
    env.Core.lotCells = setmetatable({}, {
        __index = function(_, k) reads = reads + 1; return store[k] end,
        __newindex = function(_, k, v) store[k] = v end,
    })
    local inner = newInner(4, HOME_X + 300, HOME_Y + 300, 300, 300)
    frame(inner)
    local calls = lotCalls
    reads = 0
    for _ = 1, 10 do frame(inner) end
    check(lotCalls == calls, "F 視野不變：0 次 IsoLot")
    check(reads == 0, "F 視野不變：不逐格翻快取（reads=" .. reads .. "）")
    -- 平移到相鄰格：只查新進來的那一欄
    moveTo(inner, HOME_X + 300 + 256, HOME_Y + 300, 4, 300, 300)
    frame(inner)
    check(lotCalls - calls == 3, "F 平移一格：只查新的一欄 3 格（查了 " .. (lotCalls - calls) .. "）")
end

if failures > 0 then
    print(("heat void: %d check(s) failed"):format(failures))
    os.exit(1)
end
print("heat void: map/void/hysteresis/skipped-frame/far-zoom/mult-block/cache cases passed")
