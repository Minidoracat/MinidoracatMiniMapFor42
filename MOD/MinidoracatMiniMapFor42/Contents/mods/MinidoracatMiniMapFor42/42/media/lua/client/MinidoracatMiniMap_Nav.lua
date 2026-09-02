-- MinidoracatMiniMap_Nav.lua
-- 本檔範圍：導航目標——右鍵選單「設定／清除／分享」、旗標與邊緣箭頭繪製、抵達清除、
-- 陣營分享（sendClientCommand 送出／OnServerCommand 接收）、addon nav gate API
-- （navApiVersion／registerNavGate／getNavTarget 與 Core.navSetTarget 唯一寫入口）；
-- 另含同區段的小地圖 inner 互動：座標列（drawPlayerCoords）、複製座標回呼、
-- 管理員檢視標記（drawAdminViewMarker）。路線引擎在 _NavRoute.lua，不在本檔。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore；本檔載入期只讀取其「一次性賦值」的穩定引用。本檔
-- 字母序在 _NavRoute／_Search／_Settings／_WorldMapNav／_Zones 之前——它們呼叫時查的
-- Core.nav*（navGetTarget／navGetShared／navShareColor／navGateAllows／navSetTarget…）
-- 由本檔載入期定義；_Dots／_FloatIcon／_Ghost／_Migrate／POI 載入在本檔之前，
-- 已審計皆不在載入期取用本檔成員（全部呼叫時查）。
-- 拆檔緣由（2026-09-03）：主檔主 chunk locvar 151→135（本段 16 個頂層 local），
-- 段內程式碼逐位元不變；navTargets 表仍由主檔持有（InitPlayer 載回 modData 寫入），
-- 經 Core.navTargets 共享同一實例。離線測試 test_nav_gate／test_admin_view_marker／
-- test_server_nav_share／test_livestock_visibility 改從本檔抽對應切片。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- 主檔共用成員（皆為主檔載入期一次性賦值的穩定引用）
local Policy = Core.policy -- nil＝舊版共用檔缺席／載入失敗，沿用原 nil 檢查（fail-closed）
local getBoolOption = Core.getBoolOption
local clipSegment = Core.clipSegment
local copyCoordsText = Core.copyCoordsText
local navTargets = Core.navTargets
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

--------------------------------------------------------------------------------
-- 導航目標：右鍵小地圖選單「設定/清除/分享導航目標」。目標在視窗內畫旗標、
-- 出視窗畫邊緣箭頭＋直線距離（確保方向感）；距目標 NAV_ARRIVE_DIST 格內自動
-- 抵達清除。自己的目標存 player modData 跨存檔持久；「分享給陣營」走
-- sendClientCommand → 伺服器端過濾同陣營逐一轉送
-- （media/lua/server/MinidoracatMiniMapServer.lua），對方以青旗＋名字顯示。
--------------------------------------------------------------------------------
-- navTargets（[playerNum] = {x=,y=}）由主檔持有（InitPlayer 載回 modData 寫入），本檔經 Core.navTargets 取同一實例
local navShared = {}       -- [playerNum] = true（處於分享狀態，清除/移動時須同步）
local sharedTargets = {}   -- [username] = {x=,y=}（同陣營成員分享來的，本場記憶）
local NAV_ARRIVE_DIST = 5  -- 抵達判定（世界格）

-- 沙盒關閉時清掉送、收兩側本機 cache；持續為 false 時也會清除延遲抵達的封包。
-- Events.OnTick.Add 原版用例 client/Chat/ISChat.lua:943。
-- ⚠ AllowNavShare 是「會影響其他玩家／需伺服器轉送」的功能閘，**永不**列入管理員
-- 旁路白名單；政策模組缺席時與伺服器端同樣 fail-closed，避免客戶端顯示可分享、
-- 伺服器卻拒絕的靜默不一致。匿名掛 Core，避免增加主 chunk local。
-- test:nav-share-policy:start
Core.navShareAllowed = function()
    if Policy then return Policy.readBool("AllowNavShare", true) == true end
    if not Core.navPolicyMissingLogged then
        Core.navPolicyMissingLogged = true
        log("policy facade missing; navigation sharing disabled")
    end
    return false
end
-- test:nav-share-policy:end
local lastAllowNavShare = Core.navShareAllowed()
-- test:nav-share-gate:start
local function navShareGateTick()
    local allowed = Core.navShareAllowed()
    if not allowed then
        -- 每 tick 跑：非空才重建表，避免持續 false 期間每 tick 配置兩張空表。
        -- 空表偵測用 pairs 探測（PZ Kahlua 無 next，見 getLoadedMapDirs 註解）
        local dirty = lastAllowNavShare
        if not dirty then
            for _ in pairs(navShared) do dirty = true; break end
        end
        if not dirty then
            for _ in pairs(sharedTargets) do dirty = true; break end
        end
        if dirty then
            navShared = {}
            sharedTargets = {}
        end
    end
    lastAllowNavShare = allowed
end

-- 關閉期間到達的舊封包直接丟棄，避免「最後一個 false tick 後收到、重開前未清」復活。
local function navAcceptShared(to, author, x, y)
    if not Core.navShareAllowed() then return end
    sharedTargets[to] = sharedTargets[to] or {}
    sharedTargets[to][author] = { x = x, y = y }
end
-- test:nav-share-gate:end
Events.OnTick.Add(navShareGateTick)

local function navSaveModData(playerObj, t)
    -- modData 隨角色存檔持久（IsoPlayer:getModData，Lua 泛用持久掛點）
    local md = playerObj:getModData()
    md.MinidoracatMiniMapTX = t and t.x or nil
    md.MinidoracatMiniMapTY = t and t.y or nil
    -- MP 的角色資料存在伺服器：本機改完要回傳，重連才載得到新值
    -- （transmitModData＝IsoPlayer.java:8716）
    if isClient() then playerObj:transmitModData() end
end

local function navClear(playerNum, playerObj)
    navTargets[playerNum] = nil
    navSaveModData(playerObj, nil)
    if navShared[playerNum] then
        navShared[playerNum] = nil
        if isClient() then
            sendClientCommand(playerObj, "MinidoracatMiniMap", "clearShared", {})
        end
    end
end

-- 導航動作共用實作（Core 匿名閉包＝零主 chunk locvar 成本，Kahlua 200 上限對策）：
-- 小地圖（ISMiniMapInner，本檔）與世界地圖（ISWorldMap，_WorldMapNav.lua）兩面
-- 共用同一批狀態與持久化路徑；世界地圖模組檔載入在後，經 Core 命名空間取用
Core.navGetTarget = function(pn) return navTargets[pn] end
-- NavRoute 分享路線用：回「給此玩家的分享目標桶」（[author]={x,y}）；沙盒
-- 閘門與旗標繪製同源——閘門關閉時旗與路線一起消失，不會旗滅線存
Core.navGetShared = function(pn)
    if not Core.navShareAllowed() then return nil end
    local playerObj = getSpecificPlayer(pn)
    return playerObj and sharedTargets[playerObj:getUsername()] or nil
end
-- 分享目標配色盤：首色紅（單一分享者＝紅，使用者回饋要與自己的青色路線
-- 明確區分）；多分享者以作者名穩定 hash 輪色——同人跨場恆同色。色盤避開
-- 自己的金旗與路線青色
local SHARE_COLORS = {
    { 1.0, 0.25, 0.25 }, -- 紅
    { 1.0, 0.62, 0.15 }, -- 橙
    { 0.75, 0.45, 1.0 }, -- 紫
    { 0.3, 0.95, 0.4 },  -- 綠
    { 1.0, 0.5, 0.8 },   -- 粉
    { 0.65, 0.9, 0.2 },  -- 黃綠
}
Core.navShareColor = function(author)
    local h = 0
    -- string.byte：Kahlua 有註冊但原版無用例（AGENTS.md）——pcall 降級為長度
    local ok = pcall(function()
        for i = 1, #author do h = h + author:byte(i) * i end
    end)
    if not ok then h = #author end
    local c = SHARE_COLORS[(h % #SHARE_COLORS) + 1]
    return c[1], c[2], c[3]
end
-- Addon 導航閘門（nav API；首個消費者＝MinidoracatAutoDriveFor42 的
-- 「GPS 導航儀道具」gating，見 docs/plan-autodrive-addon.md M1）：註冊表與
-- 錯誤旗標一律掛 Core／API 表——主檔主 chunk locvar 已頂 Kahlua 200 上限
-- （LexState actvar[200] 固定陣列、頂層 local 永不出 scope），本節不得增頂層 local。
-- 契約：gateFn(playerNum, context) → (allowed, reasonKey)，context＝"set"
-- （寫入目標前）／"draw"（路線與旗標繪製前）兩值。明確回 false 才擋，nil／
-- 其他值一律放行——addon 忘了 return 不該讓整組導航靜默死掉。第二回傳
-- reasonKey＝翻譯鍵字串（選填）：被擋時由 navSetTarget 拿去做 halo 提示，
-- 讓 addon 能說出「缺 GPS 導航儀」；缺省或非字串則退回主 MOD generic 鍵。
-- 多 gate 為 AND（任一擋即擋，回報第一個擋阻者的 reasonKey）。gateFn
-- 拋錯＝fail-open 並依 owner 每場只 log 一次（同 zoneProviderErrorOnce 慣例：
-- 外部程式碼壞掉不得讓核心功能連坐，更不得每幀刷屏）。零註冊時行為與加
-- API 前逐位元相同（addon 不裝零影響）。
-- test:nav-gate:start
-- v4：requestRoute／requestDetour 的參數與 v1-v3 route 欄位不變；route additive
-- 新增逐段 segSurface/segWidth（與 pts 段數嚴格對齊）、數值 cost/avoidPenalty、
-- approachSurface 與 patchState="applied"|"raw"。舊版消費者仍可只讀既有欄位。
-- v5（2026-09-02）：欄位與簽名全同 v4，只修 route.snapDist 語意——沿用快取時刷新成
-- 「玩家→路線最近點」的投影距離（＝偏航 d），不再是「玩家→pts[1]」；v4 在沿線前進後
-- 停車再查會把在線上的車報成起點百公尺外。消費者以 navApiVersion>=5 判定可否信任
-- snapDist 當「起點太遠」門檻（AutoDrive 對 v4 不套此門檻）。
MinidoracatMiniMapAPI.navApiVersion = 5
Core.navGates = {} -- { { owner=, fn=, errLogged= }, ... }
function MinidoracatMiniMapAPI.registerNavGate(ownerModId, gateFn)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(gateFn) ~= "function" then
        log("registerNavGate bad arguments (need ownerModId string, gateFn function)")
        return false
    end
    local gates = Core.navGates
    for i = 1, #gates do
        if gates[i].owner == ownerModId then
            -- 同 owner 重註冊＝覆蓋（addon 條件換實作/熱重載不留舊 gate 疊加）；
            -- 錯誤旗標一併重置——新 fn 的錯誤值得記一次新 log
            gates[i].fn = gateFn
            gates[i].errLogged = nil
            return true
        end
    end
    gates[#gates + 1] = { owner = ownerModId, fn = gateFn }
    return true
end
-- 閘門查詢（繪製路徑每幀呼叫：零註冊在 #gates 後即返回，無配置、無 pcall）
Core.navGateAllows = function(playerNum, context)
    local gates = Core.navGates
    local n = #gates
    if n == 0 then return true end
    for i = 1, n do
        local g = gates[i]
        -- 第三回傳位＝gateFn 的 reasonKey（pcall 成功時）；拋錯時第二位是錯誤訊息
        local ok, allowed, reasonKey = pcall(g.fn, playerNum, context)
        if not ok then
            if not g.errLogged then
                g.errLogged = true
                log("nav gate error (" .. tostring(g.owner) .. "): " .. tostring(allowed))
            end
        elseif allowed == false then
            return false, reasonKey
        end
    end
    return true
end
-- 回 (ok, reasonKey)：ok=true＝已寫入目標；false＝無玩家或被 gate 擋。
-- 被擋必須「看得見」：右鍵選單／搜尋視窗設目標是玩家主動操作，靜默失敗＝
-- 玩家以為功能壞掉（silent-failure review 指認）。走原版 halo 壞訊息通道
-- （HaloTextHelper.addBadText，原版用例 ISVehicleMenu.lua:1197 等），addon 的
-- reasonKey 優先（能明說「缺 GPS 導航儀」），缺省／非字串退回主 MOD generic
-- 鍵。第二回傳＝實際用掉的鍵（供呼叫端與測試判斷）；無玩家時無提示亦無鍵
Core.navSetTarget = function(pn, worldX, worldY)
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return false end
    local allowed, reasonKey = Core.navGateAllows(pn, "set")
    if not allowed then
        if type(reasonKey) ~= "string" or reasonKey == "" then
            reasonKey = "UI_MinidoracatMiniMap_NavBlocked"
        end
        HaloTextHelper.addBadText(playerObj, getText(reasonKey))
        return false, reasonKey
    end
    navTargets[pn] = { x = worldX, y = worldY }
    navSaveModData(playerObj, navTargets[pn])
    if navShared[pn] then Core.navShareTarget(pn) end -- 分享中：移動即重新廣播
    return true
end
-- 目前導航目標查詢（nav API v2；消費者＝MinidoracatAutoDriveFor42 M3 自駕核心，
-- 見 docs/plan-autodrive-addon.md §5）。回「兩個純量」而非內部 table 是刻意的：
-- navTargets[pn] 是主 MOD 的持久化狀態本體，交出參考等於讓 addon 能繞過
-- Core.navSetTarget（唯一含 gate＋modData 持久化的寫入口）改目標——而且改了
-- 還不會重播分享、不會存檔，是最難查的一類靜默不一致。複製一份 {x=,y=} 也不
-- 行：自駕迴路每幀查目標，每幀配置一個 table＝白送 Kahlua GC 壓力。
-- 回 (x, y)＝兩個 number；(nil, reason) 表無值，reason＝
--   "badargs"（playerNum 非 0-3 整數）／"notarget"（該槽位目前無導航目標）
-- badargs 從嚴同 requestRoute：非整數／越界槽位會靜靜讀到別人的（或不存在的）
-- 槽位，錯得無聲。本函式不查 player（純狀態讀取，槽位無人時 navTargets 自然
-- 是 nil＝notarget）、不寫任何狀態、零配置——自駕熱路徑可直接每幀呼叫。
function MinidoracatMiniMapAPI.getNavTarget(playerNum)
    -- 先擋 NaN（自比不等；範圍比較對 NaN 恆為 false 擋不住），再擋越界／非整數
    -- （±Infinity 由範圍比較擋下，故 % 1 只需處理有限值）
    if type(playerNum) ~= "number" or playerNum ~= playerNum
        or playerNum < 0 or playerNum > 3 or playerNum % 1 ~= 0
    then
        return nil, "badargs"
    end
    local t = navTargets[playerNum]
    if not t then return nil, "notarget" end
    return t.x, t.y
end
-- test:nav-gate:end
Core.navClearTarget = function(pn)
    local playerObj = getSpecificPlayer(pn)
    if playerObj then navClear(pn, playerObj) end
end
Core.navShareTarget = function(pn)
    local playerObj = getSpecificPlayer(pn)
    local t = navTargets[pn]
    if not (playerObj and t and isClient()) then return end
    if not Core.navShareAllowed() then return end -- 伺服器沙盒禁用／政策模組缺席
    navShared[pn] = true
    sendClientCommand(playerObj, "MinidoracatMiniMap", "shareTarget", { x = t.x, y = t.y })
end

-- 導航目標載回：掛 OnCreatePlayer（原版用例 ISPlayerData.lua:203、簽名同
-- ISPerkLog.logCreatePlayer(_player)＝playerIndex）而非只靠 ISMiniMap.InitPlayer
-- ——InitPlayer 受沙盒 AllowMiniMap 閘門（ISPlayerDataObject.lua:139-141），
-- 關閉時不跑，世界地圖側（_WorldMapNav.lua）會漏載持久目標、或讀到同槽位
-- 上一位角色的殘值（三 lane review 抓出）。InitPlayer 的載回段保留（Recreate
-- 重建路徑同步），兩處讀同一 modData、冪等
Events.OnCreatePlayer.Add(function(pn)
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    local md = playerObj:getModData()
    if md and md.MinidoracatMiniMapTX and md.MinidoracatMiniMapTY then
        navTargets[pn] = { x = md.MinidoracatMiniMapTX, y = md.MinidoracatMiniMapTY }
    else
        navTargets[pn] = nil -- 新角色/無目標：清同槽位舊角色殘值
    end
end)

-- 右鍵選單回呼（addOption 簽名同原版 debug 傳送項 ISMiniMap.lua:292）
function ISMiniMapInner:onMinidoracatSetTarget(worldX, worldY)
    Core.navSetTarget(self.playerNum or 0, worldX, worldY)
end

function ISMiniMapInner:onMinidoracatClearTarget()
    Core.navClearTarget(self.playerNum or 0)
end

function ISMiniMapInner:onMinidoracatShareTarget()
    Core.navShareTarget(self.playerNum or 0)
end

function ISMiniMapInner:onMinidoracatSearch()
    if Core.toggleSearchWindow then
        Core.toggleSearchWindow(self.playerNum or 0, self)
    end
end

-- 旗標：黑框桿＋色旗（drawRect 疊法同殭屍點描邊）；label（分享者名）與 dist
-- （距離公尺）分兩行掛旗上——同行擠在一起難讀（使用者回饋），名字上、距離下
local function drawNavFlag(inner, ux, uy, r, g, b, label, dist)
    inner:drawRect(ux - 2, uy - 14, 4, 15, 0.8, 0, 0, 0)
    inner:drawRect(ux - 1, uy - 13, 2, 13, 1, 1, 1, 1)
    inner:drawRect(ux, uy - 14, 11, 8, 0.8, 0, 0, 0)
    inner:drawRect(ux + 1, uy - 13, 9, 6, 1, r, g, b)
    -- 深色底墊字（同原版玩家名牌做法 UIWorldMap.java:509），淺色地圖上才清晰；
    -- 位置夾進視窗（長名字貼上/右緣時不外溢）。Medium 字級＋離旗 10/44px
    local w, h = inner.width, inner.height
    local lines = {}
    -- 作者名行用旗色（隊友 ID 與其路線/旗同色一眼對應，使用者回饋）；距離行
    -- 維持白色（讀數清晰）
    if label then lines[#lines + 1] = { t = label, cr = r, cg = g, cb = b } end
    if dist then lines[#lines + 1] = { t = tostring(dist) .. "m", cr = 1, cg = 1, cb = 1 } end
    local ly = uy - 44 - (#lines - 1) * 22 -- 多行往上長，最下行維持離旗 44px
    for i = 1, #lines do
        local ln = lines[i]
        local tw = getTextManager():MeasureStringX(UIFont.Medium, ln.t)
        local lx = ux + 10
        if lx < 2 then lx = 2 elseif lx > w - tw - 2 then lx = w - tw - 2 end
        local cy2 = ly + (i - 1) * 22
        if cy2 < 2 then cy2 = 2 elseif cy2 > h - 22 then cy2 = h - 22 end
        inner:drawRect(lx - 4, cy2 - 1, tw + 8, 22, 0.6, 0, 0, 0)
        inner:drawText(ln.t, lx, cy2, ln.cr, ln.cg, ln.cb, 0.95, UIFont.Medium) -- drawText＝ISUIElement.lua:1293
    end
end

-- 目標在視窗內＝旗標；出視窗＝中心→目標線段裁到內縮 12px 矩形（重用 clipSegment），
-- 交點畫 V 形箭頭（翼向量＝方向單位向量旋 ±25.8°，c=0.9/s=0.436，免 atan）
local function drawNavIndicator(inner, tx, ty, r, g, b, label, dist)
    local w, h = inner.width, inner.height
    if tx >= 8 and ty >= 16 and tx <= w - 14 and ty <= h - 4 then
        drawNavFlag(inner, tx, ty, r, g, b, label, dist) -- 名字/距離分行由旗標函式排版
        return
    end
    local cx, cy = w / 2, h / 2
    local m = 12
    local sx1, sy1, sx2, sy2 = clipSegment(cx - m, cy - m, tx - m, ty - m, w - 2 * m, h - 2 * m)
    if not sx1 then return end
    local tipx, tipy = sx2 + m, sy2 + m
    local ddx, ddy = tx - cx, ty - cy
    local len = math.sqrt(ddx * ddx + ddy * ddy)
    if len < 1 then return end
    local uxn, uyn = ddx / len, ddy / len
    local c, s = 0.9, 0.436
    local b1x, b1y = uxn * c - uyn * s, uxn * s + uyn * c
    local b2x, b2y = uxn * c + uyn * s, -uxn * s + uyn * c
    inner:drawLine(nil, tipx, tipy, tipx - b1x * 11, tipy - b1y * 11, 2, 0.95, r, g, b)
    inner:drawLine(nil, tipx, tipy, tipx - b2x * 11, tipy - b2y * 11, 2, 0.95, r, g, b)
    local txt = label
    if dist then txt = tostring(dist) .. "m" end
    if txt then
        -- MeasureStringX 用例 ISFactionUI.lua:238；Medium 字級同旗標 label
        local tw = getTextManager():MeasureStringX(UIFont.Medium, txt)
        local px = tipx - uxn * 28 - tw / 2
        local py = tipy - uyn * 28 - 10
        if px < 2 then px = 2 elseif px > w - tw - 2 then px = w - tw - 2 end
        if py < 2 then py = 2 elseif py > h - 22 then py = h - 22 end
        -- 深色底墊字（同原版玩家名牌做法 UIWorldMap.java:509），淺色地圖上才清晰
        inner:drawRect(px - 4, py - 1, tw + 8, 22, 0.6, 0, 0, 0)
        inner:drawText(txt, px, py, 1, 1, 1, 0.95, UIFont.Medium)
    end
end

-- test:nav-draw:start（scripts/test_nav_gate.lua 抽本區段跑 draw gate 整合測試）
local function drawNavTargets(inner)
    local pn = inner.playerNum or 0
    -- Addon 閘門（context="draw"）：只擋「導航目標層繪製與路線計算」——搜尋
    -- 落點 ping 不屬導航目標層（搜尋是獨立功能，不該被導航道具連坐），抵達
    -- 清除與狀態收尾亦照跑：那是狀態變更，擋掉會讓玩家走到目標後目標永久
    -- 黏著（同 navCheckArrival 註解的「早退不得連坐狀態更新」理由）
    local allowed = Core.navGateAllows(pn, "draw")
    -- 路線層（_NavRoute.lua 掛 Core.drawNavRoute）：先畫＝墊在旗標/箭頭/分享旗
    -- 之下。收 err＋實例旗標 log-once（同動物繪製/_WorldMapNav 慣例：主檔
    -- :4022-4027 明寫「持久錯誤首次記 log 免全靜默」——裸 pcall 吞錯會讓路線
    -- 靜默消失且每幀重試失敗熱路徑，三 review lanes 一致指認）
    if allowed and Core.drawNavRoute then
        local navOk, navErr = pcall(Core.drawNavRoute, inner)
        if not navOk and not inner._minidoracatNavRouteErrLogged then
            inner._minidoracatNavRouteErrLogged = true
            log("nav route draw failed: " .. tostring(navErr))
        end
    end
    local mapAPI = inner.mapAPI
    local playerObj = getSpecificPlayer(pn)
    -- 陣營分享來的：只畫「給這位玩家」的桶（青旗＋名字＋距離）；getUsername
    -- 原版用例 ISScoreboard.lua:108。已收到的目標仍受目前 AllowNavShare 閘門
    -- 即時控制（navGetShared 同源）
    local bucket = allowed and Core.navGetShared and Core.navGetShared(pn) or nil
    if bucket and playerObj then
        for author, t in pairs(bucket) do
            local sdx, sdy = t.x - playerObj:getX(), t.y - playerObj:getY()
            local cr, cg, cb = Core.navShareColor(author)
            drawNavIndicator(inner, mapAPI:worldToUIX(t.x, t.y), mapAPI:worldToUIY(t.x, t.y),
                cr, cg, cb, author, math.floor(math.sqrt(sdx * sdx + sdy * sdy) + 0.5))
        end
    end
    -- 搜尋落點 ping（本體在 _Search.lua 掛 Core.drawSearchPing——主 chunk locvar
    -- 已頂 Kahlua 200 上限（LexState actvar[200]），主檔不得再增頂層 local；
    -- 動態查同 :3924 Core.drawNavRoute 慣例）。無導航目標時也要畫，須在下行早退前
    if Core.drawSearchPing then Core.drawSearchPing(inner, mapAPI) end
    local t = navTargets[pn]
    if not t then return end
    if not playerObj then return end
    local ddx = t.x - playerObj:getX()
    local ddy = t.y - playerObj:getY()
    local dist = math.floor(math.sqrt(ddx * ddx + ddy * ddy) + 0.5)
    if dist <= NAV_ARRIVE_DIST then -- 抵達：自動清除（含分享清除通知）
        navClear(pn, playerObj)
        return
    end
    if not allowed then return end -- 被 gate 擋：狀態已收尾，只略過自身旗標繪製
    drawNavIndicator(inner, mapAPI:worldToUIX(t.x, t.y), mapAPI:worldToUIY(t.x, t.y),
        1.0, 0.85, 0.2, nil, dist) -- 自己＝金旗＋距離
end
-- test:nav-draw:end

-- 導航到達的「純狀態」判定（codex review：WM-1 早退不得連坐狀態更新）：
-- drawNavTargets 的抵達清除是狀態變更（清 modData＋分享中送 clearShared），
-- 不是繪製——世界地圖開啟期間小地圖加繪早退，但 MP 車輛乘客/外力位移仍可能
-- 在 M 開著時抵達，清除必須照跑。從繪製函式拆出，供 WM-1 早退「前」呼叫；
-- drawNavTargets 保留自己的抵達分支（正常路徑到達時同幀即清、不多等一幀）
local function navCheckArrival(inner)
    local pn = inner.playerNum or 0
    local t = navTargets[pn]
    if not t then return end
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    local ddx = t.x - playerObj:getX()
    local ddy = t.y - playerObj:getY()
    if ddx * ddx + ddy * ddy <= NAV_ARRIVE_DIST * NAV_ARRIVE_DIST then
        navClear(pn, playerObj)
    end
end

-- 玩家座標列（底部置中膠囊，freelook 提示同款樣式）：一律顯示 x, y, z（與複製值
-- 一致——顯示帶空格、剪貼簿無空格，值相同；上下樓層不跳版面）；剛複製 1.5 秒內改
-- 琥珀「已複製」回饋——回饋獨立於 ShowPlayerCoords 開關（關列後 XY 鈕/右鍵複製
-- 仍看得到成功提示，否則像按鈕壞掉）；freelook 膠囊佔底行時上移一行避讓。
-- 呼叫點在 drawNavTargets 之前＝導航距離標籤畫在其上（正南目標讀數不被膠囊吃掉）
local function drawPlayerCoords(inner)
    local copied = inner._minidoracatCopiedUntil
        and getTimestampMs() < inner._minidoracatCopiedUntil
    if not (copied or getBoolOption("ShowPlayerCoords", true)) then return end
    local playerObj = getSpecificPlayer(inner.playerNum or 0)
    if not playerObj then return end
    -- 座標文字快取（perf 稽核 MISC-3）：此路徑預設恆開、每幀跑，但字串與寬度
    -- 只在玩家跨越整數格（或 copied 切換）才變——以 (ix,iy,iz) 為 key 快取，
    -- 節掉每幀的 string.format＋MeasureStringX。
    -- ⚠ x-x%1 只對非負值等於 floor：Kahlua 的 % 商先轉 int（朝零截斷，
    -- KahluaThread.java:1060），-0.2%1 得 -0.2 而非 PUC Lua 的 0.8——x/y 恆正
    -- 可用，z 在地下室樓梯上是負小數，必須走 math.floor（桌面 Lua 測試抓不到
    -- 此差異，codex review 以反編譯源實證；複製路徑也用 math.floor，兩者須一致）
    local tm = getTextManager()
    local cc = inner._minidoracatCoordCache
    if not cc then
        cc = {}
        inner._minidoracatCoordCache = cc
    end
    local txt, cw
    if copied then
        txt = getText("UI_MinidoracatMiniMap_Copied")
        if cc.copiedTxt ~= txt then
            cc.copiedTxt = txt
            cc.copiedW = tm:MeasureStringX(UIFont.Small, txt)
        end
        cw = cc.copiedW
    else
        local px, py, pz = playerObj:getX(), playerObj:getY(), playerObj:getZ()
        local ix = px - px % 1
        local iy = py - py % 1
        local iz = math.floor(pz) -- z 可為負小數（見上方 Kahlua % 註解）
        if cc.x ~= ix or cc.y ~= iy or cc.z ~= iz then
            cc.x, cc.y, cc.z = ix, iy, iz
            cc.txt = string.format("%d, %d, %d", ix, iy, iz)
            cc.w = tm:MeasureStringX(UIFont.Small, cc.txt)
        end
        txt, cw = cc.txt, cc.w
    end
    local ch = tm:getFontHeight(UIFont.Small)
    local cx = (inner.width - cw) / 2
    cx = cx - cx % 1 -- 純 Lua floor（原 math.max+math.floor 兩次跨界）
    if cx < 0 then cx = 0 end
    local cy = inner.height - ch - 10
    if inner._minidoracatFreelook and getBoolOption("FreeLook", true) then
        cy = cy - ch - 10
    end
    inner:drawRect(cx - 8, cy - 3, cw + 16, ch + 6, 0.6, 0, 0, 0)
    if copied then
        inner:drawText(txt, cx, cy, 1, 0.85, 0.4, 1, UIFont.Small)
    else
        inner:drawText(txt, cx, cy, 1, 1, 1, 0.95, UIFont.Small)
    end
end

-- 管理員檢視常駐標記（左上角琥珀膠囊）：只要該玩家的戰術或隱私旁路正在生效
-- 就一直畫——管理員必須「看得出自己看到的不是普通玩家看到的」，否則會把旁路
-- 結果當成一般玩家可見資訊回報。零旁路＝首行即返回（普通玩家零成本）。
-- 文字與寬度以元件為單位 memo（同座標列 MISC-3 快取策略）：文字是常數字串，
-- 只在語系/字型倍率變動後首幀重量測，逐幀零配置、零跨界量測。
-- 皮膚（Core.Skin＝家族 UI 框架 adapter，載入序在本檔之後故動態查）缺席時退回
-- 原生直角 drawRect（同設定視窗 prerender 的退回紅線）
-- test:admin-view-marker:start
local function drawAdminMarkerSkin(Skin, inner, w, h)
    Skin.fill(inner, 6, 6, w + 12, h + 6, Skin.COLORS.BG_PANEL)
    Skin.border(inner, 6, 6, w + 12, h + 6, Skin.COLORS.ACCENT_AMBER)
end

local function drawAdminViewMarker(inner)
    if not Policy then return end
    local pn = inner.playerNum or 0
    if not (Policy.tacticalActive(pn) or Policy.privacyActive(pn)) then return end
    local mk = inner._minidoracatAdminMark
    local txt = getText("UI_MinidoracatMiniMap_AdminViewMarker")
    if not mk then
        mk = {}
        inner._minidoracatAdminMark = mk
    end
    if mk.txt ~= txt then
        -- 尺寸先在 pcall 內完整量完、驗型，再提交 cache。跨 Lua/Java bridge
        -- 若拋錯或回 nil，仍以保守尺寸畫出安全標記；不可先寫 txt 讓半成品
        -- cache 永久卡住、旁路生效卻沒有 ADMIN VIEW 提示。
        local ok, w, h = pcall(function()
            local tm = getTextManager()
            return tm:MeasureStringX(UIFont.Small, txt), tm:getFontHeight(UIFont.Small)
        end)
        if not ok or type(w) ~= "number" or w ~= w or w < 0
                or type(h) ~= "number" or h ~= h or h <= 0 then
            if not inner._minidoracatAdminMarkMeasureErrLogged then
                inner._minidoracatAdminMarkMeasureErrLogged = true
                log("admin view marker measurement failed, using fixed metrics: "
                    .. tostring(ok and "invalid metrics" or w))
            end
            w = math.min(240, math.max(60, type(txt) == "string" and #txt * 6 or 80))
            h = 14
        end
        mk.w, mk.h, mk.txt = w, h, txt
    end
    local Skin = Core.Skin
    local painted = false
    if Skin then
        local ok, err = pcall(drawAdminMarkerSkin, Skin, inner, mk.w, mk.h)
        painted = ok
        if not ok and not inner._minidoracatAdminMarkSkinErrLogged then
            inner._minidoracatAdminMarkSkinErrLogged = true
            log("admin view marker skin failed, using rectangular fallback: " .. tostring(err))
        end
    end
    if not painted then
        inner:drawRect(6, 6, mk.w + 12, mk.h + 6, 0.72, 0, 0, 0)
        inner:drawRectBorder(6, 6, mk.w + 12, mk.h + 6, 1, 1, 0.85, 0.4)
    end
    inner:drawText(mk.txt, 12, 9, 1, 0.85, 0.4, 1, UIFont.Small)
end
-- test:admin-view-marker:end

-- 複製選定點座標到剪貼簿（右鍵選單回呼）。z 固定 0＝地面層：小地圖是平面俯視、
-- 點擊格無樓層資訊，同原版 debug 傳送 /teleportto x,y,0 慣例。回饋沿用座標列琥珀提示
function ISMiniMapInner:onMinidoracatCopyCoords(wx, wy)
    copyCoordsText(self, string.format("%d,%d,0", wx, wy))
end

-- 右鍵選單追加導航選項：原版 onRightMouseUp 以 ISContextMenu.get 建選單
-- （ISMiniMap.lua:280-298），get 會 clear（ISContextMenu.lua:1166-1170）——
-- 故以 getPlayerContextMenu 取同一單例追加（用例 ISContextMenu.lua:1167），
-- 不重呼 get、保住 debug 傳送選項；空選單原版以 numOptions==1 判定隱藏
-- （:295-297），追加後 >1 重新顯示
if ISMiniMapInner and ISMiniMapInner.onRightMouseUp then
    local originalInnerRightMouseUp = ISMiniMapInner.onRightMouseUp
    function ISMiniMapInner:onRightMouseUp(x, y)
        local wasDown = self.rightMouseDown -- 原版會消耗此旗標，先快照
        originalInnerRightMouseUp(self, x, y)
        if not wasDown then return end
        local pn = self.playerNum or 0
        local playerObj = getSpecificPlayer(pn)
        if not playerObj then return end
        -- 取 player 0 的單例：原版 onRightMouseUp 硬編碼 ISContextMenu.get(0,...)
        -- （ISMiniMap.lua:284-287），追加必須跟它同一個 menu
        local context = getPlayerContextMenu(0)
        local worldX = self.mapAPI:uiToWorldX(x, y) -- uiToWorld 用例 ISMiniMap.lua:289-290
        local worldY = self.mapAPI:uiToWorldY(x, y)
        context:addOption(getText("UI_MinidoracatMiniMap_SetTarget"), self,
            self.onMinidoracatSetTarget, worldX, worldY)
        -- 複製此處座標：選項文字即時帶座標（先看到再決定點不點）
        local cwx, cwy = math.floor(worldX), math.floor(worldY)
        context:addOption(getText("UI_MinidoracatMiniMap_CopyHere",
            string.format("%d, %d, 0", cwx, cwy)), self, self.onMinidoracatCopyCoords, cwx, cwy)
        context:addOption(getText("UI_MinidoracatMiniMap_SearchMenu"), self,
            self.onMinidoracatSearch)
        if navTargets[pn] then
            context:addOption(getText("UI_MinidoracatMiniMap_ClearTarget"), self,
                self.onMinidoracatClearTarget)
            if isClient() and Faction and Faction.getPlayerFaction(playerObj)
                and Core.navShareAllowed() then
                -- Faction.getPlayerFaction 用例 ISFactionUI.lua:408
                context:addOption(getText("UI_MinidoracatMiniMap_ShareTarget"), self,
                    self.onMinidoracatShareTarget)
            end
        end
        if context.numOptions > 1 then context:setVisible(true) end
    end
end

-- 陣營分享接收（Events.OnServerCommand 用例 ServerCommands.lua:194）。
-- 以 args.to（收件角色名）分桶：同機分割畫面共用一條 connection，
-- 沒有 to 會讓非同陣營的本機玩家也看到座標
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "MinidoracatMiniMap" or not args then return end
    if command == "sharedTarget" and args.author and args.to and args.x and args.y then
        navAcceptShared(args.to, args.author, args.x, args.y)
    elseif command == "clearShared" and args.author and args.to then
        local bucket = sharedTargets[args.to]
        if bucket then bucket[args.author] = nil end
    end
end)

-- 跨檔匯出：主檔 ISMiniMapInner:prerender wrap 與 _WorldMapNav.lua 呼叫時查表
Core.drawNavTargets = drawNavTargets -- _WorldMapNav.lua：世界地圖側導航旗標/箭頭（共用繪製）
Core.navCheckArrival = navCheckArrival -- 主檔 prerender：世界地圖開著時的抵達純狀態判定
Core.drawPlayerCoords = drawPlayerCoords -- _WorldMapNav.lua：世界地圖側座標列（共用繪製）
Core.drawAdminViewMarker = drawAdminViewMarker -- _WorldMapNav.lua：世界地圖側同款標記
