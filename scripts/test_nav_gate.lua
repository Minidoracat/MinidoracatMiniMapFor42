-- Addon 導航 API（registerNavGate / navGateAllows / navSetTarget / getNavTarget /
-- drawNavTargets）
-- 離線回歸測試。仿 test_ghost_gate.lua：抽主檔標記區段→補最小 stub→組裝離線跑；
-- nav-gate 與 nav-draw 兩區段拼在同一 chunk＝判定與繪製都跑真正的 production 碼。
-- 核心不變量（addon 是外部程式碼，錯得起但不能拖垮導航）：
--   * 零註冊＝放行（addon 不裝零影響）
--   * 多 gate 為 AND，且「明確回 false」才擋——忘了 return 不該讓導航靜默死掉
--   * gate 拋錯＝fail-open，且依 owner 每場只 log 一次（不得每幀刷屏）
--   * set 被擋時不得寫入 navTargets／不得動 modData，且回 false（非 nil）
--   * set 被擋必須有 halo 提示：addon 的 reasonKey 優先、缺省退回 generic 鍵，
--     且 gate 拋錯的錯誤訊息不得被當成 reasonKey 洩漏給玩家
--   * draw 被擋只擋導航目標層（路線／分享旗／自身旗）：搜尋 ping 照畫、抵達
--     清除照跑——狀態變更不得被繪製閘門連坐（否則走到目標後目標永久黏著）
--   * getNavTarget 是純狀態讀取：槽位驗證從嚴（非 0-3 整數＝badargs）、無目標
--     回 "notarget"，且只交出兩個純量——不得洩漏 navTargets 內部 table（交出
--     參考＝addon 能繞過 navSetTarget 改目標，不重播分享也不存檔）
-- 用法：lua scripts/test_nav_gate.lua
local mainPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end
local source = readSource(mainPath)
local compile = loadstring or load

local gateBody = assert(source:match(
    "%-%- test:nav%-gate:start\n(.-)\n%-%- test:nav%-gate:end"),
    "找不到 nav-gate 測試區段")
-- drawNavTargets 本體：production 版經標記抽取＝單一事實來源，測試裡不複製一份
-- 繪製流程（同 test_zone_render 抽 zone-render 區段的慣例）
local drawBody = assert(source:match(
    "%-%- test:nav%-draw:start[^\n]*\n(.-)\n%-%- test:nav%-draw:end"),
    "找不到 nav-draw 測試區段")

-- prelude 提供兩區段於主檔「之前」已存在的環境：
--   gate 面：log／getSpecificPlayer／navTargets／navShared／navSaveModData／
--            Core.navShareTarget／HaloTextHelper／getText
--   draw 面：NAV_ARRIVE_DIST／navClear／drawNavIndicator／Core.drawNavRoute／
--            Core.navGetShared／Core.drawSearchPing／Core.navShareColor
-- 注意：長字串 [=[ 後的首個換行會被 Lua 吃掉，body 與 suffix 之間須補顯式 "\n"
local prelude = [=[
local printed, saved, shares, halos = {}, {}, {}, {}
local cleared, flags, routeDraws, pings = {}, {}, {}, {}
local function log(msg) printed[#printed + 1] = tostring(msg) end
local MinidoracatMiniMapAPI = {}
local Core = {}
local navTargets, navShared = {}, {}
local players = {}
local function getSpecificPlayer(pn) return players[pn] end
local function navSaveModData(playerObj, t)
    saved[#saved + 1] = t and (t.x .. "," .. t.y) or "nil"
end
Core.navShareTarget = function(pn) shares[#shares + 1] = pn end
-- 原版 halo 壞訊息通道＋getText：只記文字（addBadText 的 playerObj 不參與判定）
local HaloTextHelper = {
    addBadText = function(_, text) halos[#halos + 1] = tostring(text) end,
}
local function getText(key) return "T:" .. tostring(key) end
-- draw 面 stub：抵達距離同主檔 NAV_ARRIVE_DIST=5（本測試只用 dist=0／1000 兩
-- 極端，常數漂移不影響判定）；navClear 兼作「狀態真的被清掉」的可觀測記錄
local NAV_ARRIVE_DIST = 5
local function navClear(pn, playerObj)
    cleared[#cleared + 1] = pn
    navTargets[pn] = nil
end
local function drawNavIndicator(inner, tx, ty, r, g, b, label, dist)
    flags[#flags + 1] = { label = label, dist = dist, r = r, g = g, b = b }
end
local routeFail, sharedBucket = false, nil
Core.drawNavRoute = function(inner)
    routeDraws[#routeDraws + 1] = true
    if routeFail then error("injected route failure") end
end
Core.drawSearchPing = function(inner, mapAPI) pings[#pings + 1] = true end
Core.navGetShared = function(pn) return sharedBucket end
Core.navShareColor = function(author) return 0.2, 0.9, 0.9 end
]=]
local suffix = [=[
return { API = MinidoracatMiniMapAPI, Core = Core, printed = printed,
    navTargets = navTargets, navShared = navShared, saved = saved,
    players = players, shares = shares, halos = halos,
    cleared = cleared, flags = flags, routeDraws = routeDraws, pings = pings,
    drawNavTargets = drawNavTargets,
    setRouteFail = function(v) routeFail = v end,
    setSharedBucket = function(v) sharedBucket = v end }
]=]
local T = assert(compile(
    prelude .. gateBody .. "\n" .. drawBody .. "\n" .. suffix, "nav-gate"))()
local API, Core = T.API, T.Core

-- 每個案例重置註冊表（Core.navGates 是模組級單例）
local function resetGates() Core.navGates = {} end

--------------------------------------------------------------------------------
-- 註冊面
--------------------------------------------------------------------------------
-- N0: API 版本號存在（addon 以此判相容）；v4＝route segment surface/width metadata
assert(API.navApiVersion == 5, "N0: navApiVersion 須為 5")

-- N1: 零註冊＝放行（addon 不裝零影響）
resetGates()
assert(Core.navGateAllows(0, "set") == true, "N1: 零 gate 須放行")
assert(Core.navGateAllows(0, "draw") == true, "N1: 零 gate 須放行（draw）")

-- N2: 引數驗證——owner 非空字串、gateFn 是 function；回 false 且不進註冊表
resetGates()
local badCases = {
    { nil, function() end }, { "", function() end }, { 42, function() end },
    { "A", nil }, { "A", "nope" },
}
for i = 1, #badCases do
    local c = badCases[i]
    assert(API.registerNavGate(c[1], c[2]) == false,
        "N2: 壞引數須回 false（case " .. i .. "）")
end
assert(#Core.navGates == 0, "N2: 壞引數不得進註冊表")
assert(#T.printed == #badCases, "N2: 每次壞引數須各記一次 log")

-- N3: 合法註冊回 true；同 owner 重註冊＝覆蓋（不疊加）
resetGates()
local hits = {}
assert(API.registerNavGate("A", function() hits[#hits + 1] = "old"; return true end) == true,
    "N3: 合法註冊須回 true")
assert(API.registerNavGate("A", function() hits[#hits + 1] = "new"; return true end) == true,
    "N3: 重註冊須回 true")
assert(#Core.navGates == 1, "N3: 同 owner 重註冊須覆蓋、不得疊加")
Core.navGateAllows(0, "set")
assert(#hits == 1 and hits[1] == "new", "N3: 覆蓋後只跑新 fn")

--------------------------------------------------------------------------------
-- 判定面
--------------------------------------------------------------------------------
-- N4: 多 gate AND——全放行才放行；任一明確 false 即擋
resetGates()
API.registerNavGate("A", function() return true end)
API.registerNavGate("B", function() return true end)
assert(Core.navGateAllows(0, "set") == true, "N4: 兩 gate 皆放行須放行")
API.registerNavGate("B", function() return false end)
assert(Core.navGateAllows(0, "set") == false, "N4: 任一 gate 回 false 即擋")

-- N5: 只有「明確 false」才擋——nil／其他真值一律放行（addon 忘了 return 不得
--     讓導航靜默死掉）
resetGates()
API.registerNavGate("A", function() end) -- 無 return
assert(Core.navGateAllows(0, "set") == true, "N5: gate 回 nil 須放行")
API.registerNavGate("A", function() return 0 end) -- Lua 的 0 為真值
assert(Core.navGateAllows(0, "set") == true, "N5: gate 回非 false 值須放行")

-- N6: context 與 playerNum 原樣傳入（addon 靠 context 區分「設目標」與「繪製」）
resetGates()
local seen = {}
API.registerNavGate("A", function(pn, ctx) seen[#seen + 1] = tostring(pn) .. ":" .. tostring(ctx) end)
Core.navGateAllows(2, "draw")
Core.navGateAllows(0, "set")
assert(seen[1] == "2:draw" and seen[2] == "0:set", "N6: playerNum/context 須原樣傳入")

-- N7: gate 拋錯＝fail-open，依 owner 只 log 一次；其餘 gate 照常判定
resetGates()
local before = #T.printed
API.registerNavGate("Boom", function() error("injected gate failure") end)
assert(Core.navGateAllows(0, "set") == true, "N7: gate 拋錯須 fail-open（放行）")
Core.navGateAllows(0, "set")
Core.navGateAllows(0, "draw")
assert(#T.printed == before + 1, "N7: 拋錯須 log-once（實得 " .. (#T.printed - before) .. " 筆）")
assert(T.printed[#T.printed]:find("nav gate error", 1, true)
    and T.printed[#T.printed]:find("Boom", 1, true), "N7: log 須含 owner 與訊息")
API.registerNavGate("Blocker", function() return false end)
assert(Core.navGateAllows(0, "set") == false, "N7: 壞 gate 不得吃掉其他 gate 的擋阻")

-- N8: 同 owner 重註冊須重置錯誤旗標（新 fn 的錯誤值得記一次新 log）
before = #T.printed
API.registerNavGate("Boom", function() error("second failure") end)
Core.navGateAllows(0, "set")
assert(#T.printed == before + 1, "N8: 重註冊後新 fn 的錯誤須再記一次")

--------------------------------------------------------------------------------
-- navSetTarget 接入面
--------------------------------------------------------------------------------
local playerObj = { x = 0, y = 0 }
T.players[0] = playerObj

-- N9: 無 gate → 寫入目標、存 modData、回 true
resetGates()
assert(Core.navSetTarget(0, 100, 200) == true, "N9: 成功須回 true")
assert(T.navTargets[0].x == 100 and T.navTargets[0].y == 200, "N9: 目標須寫入")
assert(T.saved[#T.saved] == "100,200", "N9: 須存 modData")

-- N10: set 被擋 → 回 false，且不覆蓋既有目標、不動 modData、不重播分享
resetGates()
API.registerNavGate("A", function(pn, ctx) return ctx ~= "set" end)
local savedN = #T.saved
T.navShared[0] = true
local sharesN = #T.shares
assert(Core.navSetTarget(0, 777, 888) == false, "N10: 被擋須回 false（不得回 nil）")
assert(T.navTargets[0].x == 100 and T.navTargets[0].y == 200,
    "N10: 被擋不得覆蓋既有目標")
assert(#T.saved == savedN, "N10: 被擋不得動 modData")
assert(#T.shares == sharesN, "N10: 被擋不得重播分享")

-- N11: draw context 放行時 set 仍被擋（context 判定真的有分流，非一律擋）
assert(Core.navGateAllows(0, "draw") == true, "N11: 該 gate 只擋 set")

-- N12: 無玩家 → 回 false 且不查 gate（沿舊早退語意，只是回傳值明確化）
resetGates()
local probed = 0
API.registerNavGate("A", function() probed = probed + 1; return true end)
assert(Core.navSetTarget(3, 1, 2) == false, "N12: 無玩家須回 false")
assert(probed == 0, "N12: 無玩家不得呼叫 gate")
assert(T.navTargets[3] == nil, "N12: 無玩家不得寫入目標")

-- N13: gate 放行 → 分享中會重播（既有行為未被 gate 改動）
resetGates()
API.registerNavGate("A", function() return true end)
T.navShared[0] = true
sharesN = #T.shares
assert(Core.navSetTarget(0, 5, 6) == true, "N13: 放行須回 true")
assert(#T.shares == sharesN + 1, "N13: 分享中須重播")

--------------------------------------------------------------------------------
-- 被擋回饋面（silent-failure review：拒絕必須看得見，否則玩家以為選單壞了）
--------------------------------------------------------------------------------
local GENERIC = "UI_MinidoracatMiniMap_NavBlocked"

-- N14: addon 給 reasonKey → halo 用該鍵；第二回傳＝實際用掉的鍵
resetGates()
API.registerNavGate("A", function(pn, ctx)
    if ctx == "set" then return false, "UI_Addon_NeedGPS" end
    return true
end)
local halosN = #T.halos
local okSet, usedKey = Core.navSetTarget(0, 11, 22)
assert(okSet == false, "N14: 被擋須回 false")
assert(usedKey == "UI_Addon_NeedGPS", "N14: 須回 addon 給的 reasonKey")
assert(#T.halos == halosN + 1, "N14: 被擋須送一則 halo 提示")
assert(T.halos[#T.halos] == "T:UI_Addon_NeedGPS", "N14: halo 文字須取 addon 的鍵")

-- N15: 未給／非字串／空字串 reasonKey → 一律退回主 MOD generic 鍵，且仍有提示
resetGates()
halosN = #T.halos
API.registerNavGate("A", function() return false end)
local _, k1 = Core.navSetTarget(0, 1, 1)
API.registerNavGate("A", function() return false, 123 end)
local _, k2 = Core.navSetTarget(0, 1, 1)
API.registerNavGate("A", function() return false, "" end)
local _, k3 = Core.navSetTarget(0, 1, 1)
assert(k1 == GENERIC and k2 == GENERIC and k3 == GENERIC,
    "N15: 缺省／非字串／空字串 reasonKey 須退回 generic 鍵")
assert(#T.halos == halosN + 3, "N15: 三次被擋須各送一則提示")
assert(T.halos[#T.halos] == "T:" .. GENERIC, "N15: halo 文字須取 generic 鍵")

-- N16: navGateAllows 第二回傳＝擋阻者的 reasonKey；放行時不得回髒值
resetGates()
API.registerNavGate("A", function() return false, "K1" end)
local allowed, reason = Core.navGateAllows(0, "draw")
assert(allowed == false and reason == "K1", "N16: 擋阻須帶回 reasonKey")
resetGates()
API.registerNavGate("A", function() return true, "K1" end)
allowed, reason = Core.navGateAllows(0, "draw")
assert(allowed == true and reason == nil, "N16: 放行不得回 reasonKey")

-- N17: 多 gate 短路——回報第一個擋阻者的鍵
resetGates()
API.registerNavGate("A", function() return true end)
API.registerNavGate("B", function() return false, "KB" end)
API.registerNavGate("C", function() return false, "KC" end)
local _, firstKey = Core.navGateAllows(0, "set")
assert(firstKey == "KB", "N17: 須回第一個擋阻者的鍵，實得 " .. tostring(firstKey))

-- N18: gate 拋錯的錯誤訊息不得被當成 reasonKey 洩漏給玩家（pcall 的第二回傳位）
resetGates()
API.registerNavGate("Boom", function() error("secret failure text") end)
API.registerNavGate("Blocker", function() return false end)
local _, errKey = Core.navSetTarget(0, 3, 4)
assert(errKey == GENERIC, "N18: 錯誤訊息不得成為 reasonKey，實得 " .. tostring(errKey))
assert(T.halos[#T.halos] == "T:" .. GENERIC, "N18: halo 須顯示 generic 鍵、非錯誤訊息")

-- N19: 無玩家＝無提示（沒有 playerObj 可送 halo，且不得偽造鍵）
resetGates()
API.registerNavGate("A", function() return false, "K" end)
halosN = #T.halos
local okNo, keyNo = Core.navSetTarget(3, 1, 2)
assert(okNo == false and keyNo == nil, "N19: 無玩家須回 false 且無 reasonKey")
assert(#T.halos == halosN, "N19: 無玩家不得送 halo")

-- N20: 放行成功不得送任何提示（halo 只在被擋時出現）
resetGates()
halosN = #T.halos
T.navShared[0] = nil
assert(Core.navSetTarget(0, 42, 43) == true, "N20: 放行須回 true")
assert(#T.halos == halosN, "N20: 成功不得送 halo")

--------------------------------------------------------------------------------
-- drawNavTargets 整合面（review：draw 閘門分支從未被任何測試碰到）
--------------------------------------------------------------------------------
local draw = T.drawNavTargets
assert(type(draw) == "function", "D0: 須抽到 production 的 drawNavTargets")

-- 繪製表面 stub：drawNavTargets 只要求 mapAPI 做世界→UI 轉換（此處恆等）
local function newInner()
    return {
        playerNum = 0, width = 200, height = 200,
        mapAPI = {
            worldToUIX = function(_, wx, wy) return wx end,
            worldToUIY = function(_, wx, wy) return wy end,
        },
    }
end
T.players[0] = { getX = function() return 0 end, getY = function() return 0 end }

local function clear(t) for i = #t, 1, -1 do t[i] = nil end end
local function resetDraw()
    resetGates()
    T.setRouteFail(false)
    T.setSharedBucket(nil)
    clear(T.flags); clear(T.routeDraws); clear(T.pings); clear(T.cleared)
end

-- D1: 放行＝全畫（路線層、分享旗、搜尋 ping、自身旗），遠距不清除
resetDraw()
T.navTargets[0] = { x = 1000, y = 0 }
T.setSharedBucket({ Bob = { x = 300, y = 0 } })
draw(newInner())
assert(#T.routeDraws == 1, "D1: 放行須畫路線層")
assert(#T.pings == 1, "D1: 須畫搜尋 ping")
assert(#T.cleared == 0, "D1: 遠距不得清除目標")
assert(#T.flags == 2, "D1: 須畫分享旗＋自身旗，實得 " .. #T.flags)
assert(T.flags[1].label == "Bob" and T.flags[1].dist == 300,
    "D1: 第一支＝分享旗（作者名＋距離）")
assert(T.flags[2].label == nil and T.flags[2].dist == 1000,
    "D1: 第二支＝自身金旗＋距離")

-- D2: draw 被擋＝導航目標層全不畫（路線／分享旗／自身旗），搜尋 ping 照畫
resetDraw()
T.navTargets[0] = { x = 1000, y = 0 }
T.setSharedBucket({ Bob = { x = 300, y = 0 } })
local seenCtx = {}
API.registerNavGate("A", function(pn, ctx) seenCtx[#seenCtx + 1] = ctx; return false end)
draw(newInner())
assert(seenCtx[1] == "draw", "D2: 繪製路徑須以 context=draw 問閘門")
assert(#T.routeDraws == 0, "D2: 被擋不得畫路線層（連 A* 都不該算）")
assert(#T.flags == 0, "D2: 被擋不得畫分享旗／自身旗")
assert(#T.pings == 1, "D2: 搜尋 ping 不屬導航目標層，被擋仍須畫")
assert(T.navTargets[0] ~= nil, "D2: 遠距被擋不得動狀態")

-- D3: draw 被擋＋已抵達＝清除照跑（否則走到目標後目標永久黏著）
resetDraw()
T.navTargets[0] = { x = 0, y = 0 }
API.registerNavGate("A", function() return false end)
draw(newInner())
assert(#T.cleared == 1 and T.cleared[1] == 0, "D3: 被擋仍須執行抵達清除")
assert(T.navTargets[0] == nil, "D3: 抵達後目標須清空")
assert(#T.flags == 0, "D3: 被擋不得畫旗標")

-- D4: 被擋＋無導航目標＝搜尋 ping 仍畫（無目標早退不得吃掉 ping）
resetDraw()
T.navTargets[0] = nil
API.registerNavGate("A", function() return false end)
draw(newInner())
assert(#T.pings == 1, "D4: 無目標時搜尋 ping 仍須畫")
assert(#T.flags == 0, "D4: 無目標不得畫旗標")

-- D5: 放行＋路線層拋錯＝fail-open 續畫旗標，且依實例 log-once（不得每幀刷屏）
resetDraw()
T.navTargets[0] = { x = 1000, y = 0 }
T.setRouteFail(true)
local inner = newInner()
local printedN = #T.printed
draw(inner)
draw(inner)
assert(#T.printed == printedN + 1,
    "D5: 路線錯誤須 log-once，實得 " .. (#T.printed - printedN))
assert(T.printed[#T.printed]:find("nav route draw failed", 1, true),
    "D5: log 須指名路線繪製失敗")
assert(#T.flags == 2, "D5: 路線壞掉不得連坐旗標（兩幀各一支自身旗），實得 " .. #T.flags)

-- D6: 抵達清除後同幀不再畫自身旗（既有早退契約）
resetDraw()
T.navTargets[0] = { x = 0, y = 0 }
draw(newInner())
assert(#T.routeDraws == 1, "D6: 放行時路線層仍先畫（抵達判定在其後）")
assert(#T.cleared == 1, "D6: 抵達須清除")
assert(#T.flags == 0, "D6: 抵達同幀不得再畫自身旗")

--------------------------------------------------------------------------------
-- getNavTarget 查詢面（nav API v2）
--------------------------------------------------------------------------------
-- G0: 槽位邊界——0-3 皆為合法槽位（分割畫面四人），越界回 badargs
for pn = 0, 3 do
    T.navTargets[pn] = { x = pn * 10, y = pn * 10 + 1 }
    local gx, gy = API.getNavTarget(pn)
    assert(gx == pn * 10 and gy == pn * 10 + 1,
        "G0: 槽位 " .. pn .. " 須回該槽目標，實得 " .. tostring(gx) .. "," .. tostring(gy))
end
local outOfRange = { -1, 4, 100 }
for i = 1, #outOfRange do
    local gx, why = API.getNavTarget(outOfRange[i])
    assert(gx == nil and why == "badargs",
        "G0: 越界槽位須回 badargs（case " .. i .. "），實得 " .. tostring(why))
end

-- G1: 型別／NaN／±Infinity／非整數一律 badargs（從嚴同 requestRoute：壞槽位會
--     靜靜讀到別人的槽位，錯得無聲）
local badPn = { nil, "0", true, {}, function() end,
    0 / 0, math.huge, -math.huge, 1.5, -0.5 }
for i = 1, 10 do
    local gx, why = API.getNavTarget(badPn[i])
    assert(gx == nil and why == "badargs",
        "G1: 壞 playerNum 須回 badargs（case " .. i .. "），實得 "
        .. tostring(gx) .. "," .. tostring(why))
end

-- G2: 無目標＝(nil, "notarget")，且查詢不得憑空建出槽位條目（純讀取）
T.navTargets[2] = nil
local gx2, why2 = API.getNavTarget(2)
assert(gx2 == nil and why2 == "notarget",
    "G2: 無目標須回 notarget，實得 " .. tostring(why2))
assert(T.navTargets[2] == nil, "G2: 查詢不得建出槽位條目")

-- G3: 不查 player、不寫任何狀態（無 playerObj 的槽位仍讀得到目標；modData 與
--     分享通道不得被碰）
T.players[1] = nil
T.navTargets[1] = { x = 7, y = 8 }
local savedG, sharesG, halosG = #T.saved, #T.shares, #T.halos
local px, py = API.getNavTarget(1)
assert(px == 7 and py == 8, "G3: 不得查 player（無玩家的槽位仍須回目標）")
assert(#T.saved == savedG and #T.shares == sharesG and #T.halos == halosG,
    "G3: 查詢不得寫 modData／重播分享／送 halo")

-- G4: identity protection——只交出純量，addon 拿不到內部 table 的參考，改回傳
--     值不可能影響主 MOD 狀態（未來若有人改回傳 table，此段會炸）
T.navTargets[0] = { x = 12, y = 34 }
local ix, iy = API.getNavTarget(0)
assert(type(ix) == "number" and type(iy) == "number", "G4: 兩回傳須皆為 number")
assert(ix ~= T.navTargets[0] and iy ~= T.navTargets[0],
    "G4: 不得交出 navTargets 內部 table 本體")
ix, iy = -999, -888 -- 純量指派只動本地變數
assert(T.navTargets[0].x == 12 and T.navTargets[0].y == 34,
    "G4: 改動回傳值不得影響內部狀態")

-- G5: 即時讀取（非快照）——內部狀態改了，下次查詢須跟上；navSetTarget 寫入後
--     亦立刻可見（API 與主線讀同一份狀態）
T.navTargets[0].x = 56
assert(API.getNavTarget(0) == 56, "G5: 須即時反映內部狀態變更")
resetGates()
T.players[0] = { getX = function() return 0 end, getY = function() return 0 end }
assert(Core.navSetTarget(0, 321, 654) == true, "G5: 前置寫入須成功")
local sx, sy = API.getNavTarget(0)
assert(sx == 321 and sy == 654, "G5: navSetTarget 寫入須立刻可查")

print("test_nav_gate: OK（註冊 N0-N3＋判定 N4-N8＋navSetTarget 接入 N9-N13"
    .. "＋被擋回饋 N14-N20＋draw 整合 D0-D6＋getNavTarget G0-G5）")
