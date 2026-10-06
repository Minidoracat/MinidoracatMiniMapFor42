-- 功能閘門（_FeatureGate.lua：registerFeatureGate／Core.featureAllowed）離線回歸。
-- 載入真檔，只把 PZ 全域換成假物件。核心不變量：
--   * 零註冊＝直接放行，不讀時鐘、不建快取（掛點行為與加 API 前逐位元相同）
--   * 只有明確回 false 才擋；拋錯＝放行、每個 owner 只 log 一次並停用到同 owner 再註冊
--   * (pn, feature, surface) 快取 250ms；註冊變動立即生效
--   * 戰術檢視只旁路 scan／zombie（且不帶 maxDist），share／minimap 不旁路
--   * 多 gate 取 AND（reasonKey 取第一個擋阻者）、maxDist 取最小；同 owner 再註冊＝覆蓋
-- 用法：lua scripts/test_feature_gate.lua [_FeatureGate.lua]
local path = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_FeatureGate.lua"
local file = assert(io.open(path, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
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

local function fixture()
    local t = { now = 1000, clockReads = 0, printed = {}, halos = {}, tactical = {}, draws = {},
        textAt = {}, zoom = 1, opts = {} }
    local core = {
        ready = true,
        policy = { tacticalActive = function(pn) return t.tactical[pn] == true end },
        mapTextZoom = function() return t.zoom end,
        drawMapText = function(el, text, x, y)
            t.draws[#t.draws + 1] = text
            t.textAt[#t.textAt + 1] = { x = x, y = y, stencil = el._stencil == true }
            if t.textFail then error("injected text failure") end
        end,
        modOptions = {},
        getBoolOption = function(name, default)
            if t.opts[name] ~= nil then return t.opts[name] end
            return default
        end,
    }
    -- 原版世界地圖選項面板與 ISWorldMap 的最小殼（ISWorldMap.lua:14-20、:1147-1149）：
    -- FeatureGate 載入期 wrap 它們，追蹤 RemotePlayers 的玩家期望值
    local WorldMapOptions = {}
    function WorldMapOptions:onTickBox(_, selected, option) option:setValue(selected) end
    local ISWorldMap = {}
    function ISWorldMap:setShowRemotePlayers(show)
        self.showRemotePlayers = show
        self.mapAPI:setBoolean("RemotePlayers", show)
    end
    local api = {}
    local players = { [0] = { name = "p0" }, [1] = { name = "p1" } }
    local env = setmetatable({
        MinidoracatMiniMapCore = core, MinidoracatMiniMapAPI = api,
        WorldMapOptions = WorldMapOptions, ISWorldMap = ISWorldMap,
        getTimestampMs = function() t.clockReads = t.clockReads + 1; return t.now end,
        getSpecificPlayer = function(pn) return players[pn] end,
        getText = function(key) return "T:" .. tostring(key) end,
        getTextManager = function()
            return { MeasureStringX = function(_, _, s) return #s * 6 end,
                getFontHeight = function() return 12 end }
        end,
        UIFont = { Small = 1, Medium = 2 },
        HaloTextHelper = { addBadText = function(p, text) t.halos[#t.halos + 1] = p.name .. "|" .. text end },
        print = function(msg) t.printed[#t.printed + 1] = tostring(msg) end,
    }, { __index = _G })
    local chunk
    if setfenv then
        chunk = assert(compile(source, "featuregate")); setfenv(chunk, env)
    else
        chunk = assert(load(source, "featuregate", "t", env))
    end
    chunk()
    t.core, t.api, t.WorldMapOptions, t.ISWorldMap = core, api, WorldMapOptions, ISWorldMap
    return t
end

-- 一、零註冊：直接放行，不讀時鐘
do
    local t = fixture()
    local Core, API = t.core, t.api
    checkEq(API.featureApiVersion, 1, "Z1 featureApiVersion")
    local reads = t.clockReads
    local ok, reason, dist = Core.featureAllowed(0, "minimap", "mini")
    check(ok == true and reason == nil and dist == nil, "Z1 零註冊回 true、無原因、無距離")
    for _, f in ipairs({ "arrow", "poi", "nav", "share", "scan", "zombie" }) do
        check(Core.featureAllowed(0, f, "world") == true, "Z1 零註冊放行 " .. f)
    end
    checkEq(t.clockReads, reads, "Z2 零註冊不讀時鐘（# 判斷後即返回）")
    check(not Core.minimapOpenBlocked(0) and #t.halos == 0, "Z3 零註冊開小地圖不擋、不 halo")
end

-- 二、註冊參數與明確 false 才擋
do
    local t = fixture()
    local Core, API = t.core, t.api
    check(not API.registerFeatureGate(nil, function() end), "R1 owner 缺失拒收")
    check(not API.registerFeatureGate("", function() end), "R1 owner 空字串拒收")
    check(not API.registerFeatureGate("A", "fn"), "R1 非函式拒收")
    checkEq(#Core.featureGates, 0, "R1 壞引數不得進註冊表")
    check(#t.printed == 3, "R1 壞引數各 log 一次")
    local ret
    check(API.registerFeatureGate("A", function() end), "R2 合法註冊（忘了 return）")
    check(Core.featureAllowed(0, "poi") == true, "R2 回 nil 放行")
    for _, v in ipairs({ true, 0, "no", {} }) do
        ret = v
        API.registerFeatureGate("A", function() return ret end) -- 換值即清快取
        check(Core.featureAllowed(0, "poi") == true, "R2 非 false 回傳放行：" .. tostring(v))
    end
    API.registerFeatureGate("A", function() return false end)
    local ok, reason = Core.featureAllowed(0, "poi")
    check(ok == false and reason == nil, "R3 明確 false 擋、無 reasonKey 時回 nil")
    API.registerFeatureGate("A", function() return false, 42 end)
    ok, reason = Core.featureAllowed(0, "poi")
    check(ok == false and reason == nil, "R3 非字串 reasonKey 不外流")
    API.registerFeatureGate("A", function() return false, "UI_Watch_NoBattery" end)
    ok, reason = Core.featureAllowed(0, "poi")
    checkEq(reason, "UI_Watch_NoBattery", "R3 字串 reasonKey 原樣回傳")
end

-- 三、拋錯放行、只 log 一次並停用到再註冊；不吃掉其他 gate 的擋阻
do
    local t = fixture()
    local Core, API = t.core, t.api
    local boomCalls = 0
    API.registerFeatureGate("Boom", function() boomCalls = boomCalls + 1; error("injected") end)
    check(Core.featureAllowed(0, "nav") == true, "E1 拋錯＝放行")
    t.now = t.now + 1000
    Core.featureAllowed(0, "nav")
    Core.featureAllowed(1, "share", "mini")
    local logs = 0
    for i = 1, #t.printed do
        if t.printed[i]:find("feature gate error (Boom)", 1, true) then logs = logs + 1 end
    end
    checkEq(logs, 1, "E1 同 owner 錯誤只 log 一次")
    checkEq(boomCalls, 1, "E1b 拋錯後停用：其他 pn／feature／surface 與過期後都不再呼叫")
    local blockCalls = 0
    API.registerFeatureGate("Blocker", function() blockCalls = blockCalls + 1; return false end)
    check(Core.featureAllowed(0, "nav") == false and blockCalls == 1 and boomCalls == 1,
        "E2 壞 gate 停用不影響其他 owner 的擋阻")
    API.registerFeatureGate("Boom", function() boomCalls = boomCalls + 1; error("again") end)
    Core.featureAllowed(0, "nav")
    logs = 0
    for i = 1, #t.printed do
        if t.printed[i]:find("feature gate error (Boom)", 1, true) then logs = logs + 1 end
    end
    check(logs == 2 and boomCalls == 2, "E3 同 owner 再註冊恢復呼叫，新錯誤再記一次")
    API.registerFeatureGate("Boom", function() return false, "UI_Boom" end)
    local ok, rk = Core.featureAllowed(0, "nav")
    check(ok == false and rk == "UI_Boom", "E4 再註冊成正常 gate 後恢復擋阻")
end

-- 四、250ms 快取：鍵＝(pn, feature, surface)
do
    local t = fixture()
    local Core, API = t.core, t.api
    local calls, allow = 0, true
    API.registerFeatureGate("A", function(pn, feature, surface)
        calls = calls + 1
        return allow
    end)
    Core.featureAllowed(0, "scan", "mini")
    Core.featureAllowed(0, "scan", "mini")
    checkEq(calls, 1, "C1 同鍵 250ms 內只問一次")
    allow = false
    t.now = t.now + 249
    check(Core.featureAllowed(0, "scan", "mini") == true, "C2 快取窗內沿用舊結果")
    t.now = t.now + 1
    check(Core.featureAllowed(0, "scan", "mini") == false, "C2 滿 250ms 重問")
    checkEq(calls, 2, "C2 過期才重問一次")
    Core.featureAllowed(0, "scan", "world")
    Core.featureAllowed(0, "scan")
    Core.featureAllowed(1, "scan", "mini")
    Core.featureAllowed(0, "zombie", "mini")
    checkEq(calls, 6, "C3 pn／feature／surface 各自獨立快取")
    t.now = t.now - 5000
    Core.featureAllowed(0, "scan", "mini")
    checkEq(calls, 7, "C4 時鐘倒退視為過期")
    API.registerFeatureGate("B", function() return true end)
    Core.featureAllowed(0, "scan", "mini")
    checkEq(calls, 8, "C5 新註冊立即清快取")
end

-- 五、surface 傳遞
do
    local t = fixture()
    local Core, API = t.core, t.api
    local seen = {}
    API.registerFeatureGate("A", function(pn, feature, surface)
        seen[#seen + 1] = tostring(pn) .. ":" .. feature .. ":" .. tostring(surface)
        return surface ~= "world", "UI_OnlyMini"
    end)
    check(Core.featureAllowed(2, "zombie", "mini") == true, "S1 mini 放行")
    local ok, reason = Core.featureAllowed(2, "zombie", "world")
    check(ok == false and reason == "UI_OnlyMini", "S1 world 擋並帶原因")
    check(Core.featureAllowed(2, "zombie") == true, "S1 nil surface 原樣傳 nil")
    checkEq(table.concat(seen, ","), "2:zombie:mini,2:zombie:world,2:zombie:nil", "S2 gate 收到 pn／feature／surface")
end

-- 六、戰術檢視：只旁路 scan／zombie，且不帶 maxDist
do
    local t = fixture()
    local Core, API = t.core, t.api
    API.registerFeatureGate("A", function(_, feature)
        if feature == "scan" or feature == "zombie" then return true, nil, 50 end
        return false, "UI_No"
    end)
    local ok, _, dist = Core.featureAllowed(0, "scan", "mini")
    check(ok == true and dist == 50, "T1 一般玩家套 maxDist")
    t.tactical[0] = true
    ok, _, dist = Core.featureAllowed(0, "scan", "mini")
    check(ok == true and dist == nil, "T2 戰術檢視 scan 放行且不套 maxDist")
    ok, _, dist = Core.featureAllowed(0, "zombie", "world")
    check(ok == true and dist == nil, "T2 戰術檢視 zombie 放行且不套 maxDist")
    check(Core.featureAllowed(0, "share") == false, "T3 share 永不旁路")
    check(Core.featureAllowed(0, "minimap", "mini") == false, "T3 minimap 不旁路")
    check(Core.featureAllowed(0, "nav") == false, "T3 nav 不旁路")
    ok, _, dist = Core.featureAllowed(1, "zombie", "mini")
    check(ok == true and dist == 50, "T4 戰術只看該 slot")
end

-- 七、多 gate 取 AND、maxDist 取最小、同 owner 覆蓋
do
    local t = fixture()
    local Core, API = t.core, t.api
    API.registerFeatureGate("A", function() return true, nil, 120 end)
    API.registerFeatureGate("B", function() return true, nil, 80 end)
    API.registerFeatureGate("C", function() return true, nil, -5 end)
    local ok, _, dist = Core.featureAllowed(0, "scan", "mini")
    check(ok == true and dist == 80, "A1 maxDist 取最小正值（非正值忽略）")
    API.registerFeatureGate("B", function() return false, "UI_B" end)
    API.registerFeatureGate("C", function() return false, "UI_C" end)
    local reason
    ok, reason, dist = Core.featureAllowed(0, "scan", "mini")
    check(ok == false and reason == "UI_B" and dist == nil, "A2 任一 false 即擋、回第一個擋阻者、不帶距離")
    checkEq(#Core.featureGates, 3, "A3 同 owner 再註冊不疊加")
    API.registerFeatureGate("B", function() return true end)
    API.registerFeatureGate("C", function() return true end)
    ok, _, dist = Core.featureAllowed(0, "scan", "mini")
    check(ok == true and dist == 120, "A3 同 owner 覆蓋後舊 gate 不再生效")
end

-- 八、開小地圖被擋：halo（原因或通用鍵）；無訊號畫面
do
    local t = fixture()
    local Core, API = t.core, t.api
    API.registerFeatureGate("A", function(pn, feature)
        if feature ~= "minimap" then return true end
        if pn == 0 then return false, "UI_Watch_NoBattery" end
        return false
    end)
    check(Core.minimapOpenBlocked(0) and t.halos[1] == "p0|T:UI_Watch_NoBattery", "M1 被擋 halo 顯示 reasonKey")
    check(Core.minimapOpenBlocked(1) and t.halos[2] == "p1|T:UI_MinidoracatMiniMap_FeatureUnavailable",
        "M2 沒給原因用通用鍵")
    local rects, stencil = {}, {}
    local inner = { width = 200, height = 100,
        drawRect = function(_, x, y, w, h, a) rects[#rects + 1] = { x, y, w, h, a } end,
        setStencilRect = function(self, x, y, w, h)
            self._stencil = true
            stencil[#stencil + 1] = "set:" .. x .. "," .. y .. "," .. w .. "," .. h
        end,
        clearStencilRect = function(self) self._stencil = false; stencil[#stencil + 1] = "clear" end,
    }
    Core.drawNoSignal(inner, "UI_Watch_NoBattery")
    check(#rects == 1 and rects[1][1] == 0 and rects[1][2] == 0 and rects[1][3] == 200
        and rects[1][4] == 100 and rects[1][5] == 1, "M3 無訊號以不透明底色蓋滿整個 inner")
    check(t.draws[1] == "T:UI_MinidoracatMiniMap_NoSignal" and t.draws[2] == "T:UI_Watch_NoBattery",
        "M3 畫「無訊號」與原因")
    local memo = inner._minidoracatNoSignal
    Core.drawNoSignal(inner, "UI_Watch_NoBattery")
    check(inner._minidoracatNoSignal == memo, "M4 同原因逐幀不重建量測")

    -- M5 長原因＋文字 300%：置中 x 為負（字比小地圖寬），兩段文字都必須畫在 inner 矩形
    -- stencil 內——UIWorldMap 進 Lua prerender 前已清 stencil、DrawText 不裁，沒包就畫出小地圖
    t.zoom = 3
    for i = #stencil, 1, -1 do stencil[i] = nil end
    for i = #t.textAt, 1, -1 do t.textAt[i] = nil end
    Core.drawNoSignal(inner, "UI_Watch_ThisReasonIsDeliberatelyFarTooLongToFitInsideTheMiniMap")
    check(t.textAt[2].x < 0, "M5 前提：長原因大字的置中起點在 inner 左緣外")
    check(t.textAt[1].stencil and t.textAt[2].stencil, "M5 兩段文字都在 stencil 內繪製")
    check(table.concat(stencil, "|", 1, #stencil) == "set:0,0,200,100|clear",
        "M5 stencil 為 inner 整個矩形，畫完即清")
    -- M6 繪製出錯也必定 clear（否則引擎全域 stencil 洩漏到當幀其餘 UI），錯誤照拋給呼叫端
    t.textFail = true
    for i = #stencil, 1, -1 do stencil[i] = nil end
    local drew = pcall(Core.drawNoSignal, inner, "UI_Watch_NoBattery")
    check(not drew and stencil[#stencil] == "clear" and inner._stencil == false,
        "M6 文字繪製拋錯仍清 stencil 並把錯誤交回")
    t.textFail, t.zoom = nil, 1
end

-- 九、share 被擋時 RemotePlayers 壓制與「玩家期望值」還原
do
    local t = fixture()
    local Core, API = t.core, t.api
    local blocked = false
    local function setBlocked(v)
        blocked = v
        API.registerFeatureGate("Watch", function(_, feature) if feature == "share" and blocked then return false end end)
    end
    local function surface()
        local s = { values = { RemotePlayers = true } }
        s.mapAPI = {
            getBoolean = function(_, name) return s.values[name] end,
            setBoolean = function(_, name, v) s.values[name] = v end,
        }
        return s
    end
    -- 世界地圖：沿原版 setShowRemotePlayers 開圖，再經原版選項面板 tickbox 改值
    local wm = surface()
    setmetatable(wm, { __index = t.ISWorldMap })
    wm:setShowRemotePlayers(true)
    local panel = { map = wm }
    local option = { getName = function() return "RemotePlayers" end,
        setValue = function(_, v) wm.values.RemotePlayers = v end }
    setBlocked(false)
    Core.gateRemotePlayers(wm, 0, true)
    check(wm.values.RemotePlayers == true and not wm._minidoracatRPSuppressed, "W0 放行時不動隊友圖層")
    setBlocked(true)
    Core.gateRemotePlayers(wm, 0, true)
    check(wm.values.RemotePlayers == false and wm._minidoracatRPSuppressed, "W1 share 擋＝壓掉隊友圖層")
    check(wm._minidoracatRPWant == true, "W1 壓制本身不改玩家期望值")
    -- 壓制期間：玩家在原版世界地圖選項面板取消勾選（原版 onTickBox 只 setValue）
    t.WorldMapOptions.onTickBox(panel, 1, false, option)
    Core.gateRemotePlayers(wm, 0, true)
    setBlocked(false)
    Core.gateRemotePlayers(wm, 0, true)
    check(wm.values.RemotePlayers == false and not wm._minidoracatRPSuppressed,
        "W2 壓制期間取消勾選→放行後仍為 false")
    check(wm.showRemotePlayers == true, "W2 前提：showRemotePlayers 沒跟著面板改（不能拿它當真相）")
    -- 壓制期間勾回：放行後恢復 true（期間每幀照壓）
    t.WorldMapOptions.onTickBox(panel, 1, true, option)
    setBlocked(true)
    Core.gateRemotePlayers(wm, 0, true)
    t.WorldMapOptions.onTickBox(panel, 1, false, option)
    t.WorldMapOptions.onTickBox(panel, 1, true, option)
    Core.gateRemotePlayers(wm, 0, true)
    check(wm.values.RemotePlayers == false, "W3 壓制期間勾回仍每幀壓住")
    setBlocked(false)
    Core.gateRemotePlayers(wm, 0, true)
    check(wm.values.RemotePlayers == true, "W3 放行後恢復玩家最後的勾選 true")
    -- 小地圖：期望值＝ModOptions（齒輪面板勾選已回寫）
    local mm = surface()
    setBlocked(true)
    Core.gateRemotePlayers(mm, 0, false)
    t.opts.RemotePlayers = false
    setBlocked(false)
    Core.gateRemotePlayers(mm, 0, false)
    check(mm.values.RemotePlayers == false, "W4 小地圖放行後還原 ModOptions 的值")
    -- 本來就關著：share 擋不設旗標，放行也不寫
    local off = surface()
    off.values.RemotePlayers = false
    setBlocked(true)
    Core.gateRemotePlayers(off, 0, false)
    t.opts.RemotePlayers = true
    setBlocked(false)
    Core.gateRemotePlayers(off, 0, false)
    check(off.values.RemotePlayers == false and not off._minidoracatRPSuppressed, "W5 沒壓過就不還原")
end

-- 十、主檔接線：兩個表面都經 Core.gateRemotePlayers（世界地圖帶 isWorld=true），不再自行拿
-- showRemotePlayers 還原；無訊號走 Core.drawNoSignal（stencil 在其內）
do
    local mainPath = path:gsub("MinidoracatMiniMap_FeatureGate%.lua$", "MinidoracatMiniMap.lua")
    local fh = assert(io.open(mainPath, "rb"))
    local mainSource = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    check(mainSource:find("Core.gateRemotePlayers(self, self.playerNum or 0, true)", 1, true)
        and mainSource:find("Core.gateRemotePlayers(self, pn, false)", 1, true)
        and not mainSource:find("showRemotePlayers ~= false", 1, true),
        "主檔兩表面的隊友壓制都走 Core.gateRemotePlayers")
    check(mainSource:find("Core.drawNoSignal(self, mmReason)", 1, true), "主檔無訊號走 Core.drawNoSignal")
end

print("feature gate assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
