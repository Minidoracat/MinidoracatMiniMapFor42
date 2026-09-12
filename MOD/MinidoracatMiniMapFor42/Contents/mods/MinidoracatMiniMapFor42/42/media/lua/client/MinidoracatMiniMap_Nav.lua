-- MinidoracatMiniMap_Nav.lua
-- 導航顯示、雙地圖選單、陣營分享與 addon gate。
-- 行程、持久化、到站與 nav API v6 由先載入的 _Itinerary.lua 統一管理；
-- 本檔繪製只讀行程，不清目標或推進站點。_NavRoute.lua 負責活動路線與預覽。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- 主檔共用成員（皆為主檔載入期一次性賦值的穩定引用）
local Policy = Core.policy -- nil＝舊版共用檔缺席／載入失敗，沿用原 nil 檢查（fail-closed）
local getBoolOption = Core.getBoolOption
local clipSegment = Core.clipSegment
local copyCoordsText = Core.copyCoordsText
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

--------------------------------------------------------------------------------
-- 目前活動站可分享給陣營；站點更換、完成或暫停即撤回，下一站須重新授權。
-- 封包仍只包含當前座標，不傳整份行程。
--------------------------------------------------------------------------------
local navShared = {}       -- [playerNum] = true（處於分享狀態，清除/移動時須同步）
local sharedTargets = {}   -- [username] = {x=,y=}（同陣營成員分享來的，本場記憶）

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

Core.navTargetChanged = function(pn, playerObj)
    if not navShared[pn] then return end
    navShared[pn] = nil
    playerObj = playerObj or getSpecificPlayer(pn)
    if isClient() and playerObj and getSpecificPlayer(pn) == playerObj
        and playerObj:getOnlineID() >= 0 then
        sendClientCommand(playerObj, "MinidoracatMiniMap", "clearShared", {})
    end
end

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
-- test:nav-gate:end
Core.navShareTarget = function(pn)
    local playerObj = getSpecificPlayer(pn)
    local t = Core.navGetTarget(pn)
    if not (playerObj and t and isClient()) then return end
    if not Core.navShareAllowed() then return end -- 伺服器沙盒禁用／政策模組缺席
    navShared[pn] = true
    sendClientCommand(playerObj, "MinidoracatMiniMap", "shareTarget", { x = t.x, y = t.y })
end


-- 右鍵選單回呼（addOption 簽名同原版 debug 傳送項 ISMiniMap.lua:292）
function ISMiniMapInner:onMinidoracatSetTarget(worldX, worldY)
    Core.navPromptTarget(self.playerNum or 0, worldX, worldY, nil, "replace")
end

function ISMiniMapInner:onMinidoracatClearTarget()
    Core.navPromptClear(self.playerNum or 0)
end

function ISMiniMapInner:onMinidoracatShareTarget()
    Core.navShareTarget(self.playerNum or 0)
end

function ISMiniMapInner:onMinidoracatSearch()
    if Core.toggleSearchWindow then
        Core.toggleSearchWindow(self.playerNum or 0)
    end
end

function ISMiniMapInner:onMinidoracatAddStop(worldX, worldY)
    Core.navPromptTarget(self.playerNum or 0, worldX, worldY, nil, "append")
end
-- 先去這裡：插在第一個待前往站之前並明確開始導航（不啟自駕）。取代舊的
-- 「設為下一站」（op=next）——沒有別名，也沒有留舊語意入口
function ISMiniMapInner:onMinidoracatPriorityStop(worldX, worldY)
    Core.navPromptTarget(self.playerNum or 0, worldX, worldY, nil, "priority")
end
function ISMiniMapInner:onMinidoracatItinerary()
    Core.toggleSearchWindow(self.playerNum or 0, "itinerary")
end
function ISMiniMapInner:onMinidoracatPauseNav()
    Core.navPauseItinerary(self.playerNum or 0, "cancelled")
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

local tripLabels = {}
local TRIP_COLORS = {
    pending = { 0.05, 0.86, 1.0 }, arrived = { 0.3, 0.95, 0.4 }, skipped = { 0.5, 0.5, 0.5 },
}
local function drawTripTargets(inner, pn, playerObj)
    local trip = Core.navItineraryState(pn)
    if not trip then tripLabels[pn] = nil; return end
    local tm = getTextManager()
    local fontH = tm:getFontHeight(UIFont.Small)
    local labels = tripLabels[pn]
    if not labels or labels.count ~= trip.count or labels.fontH ~= fontH then
        labels = { count = trip.count, fontH = fontH, size = math.max(20, fontH + 6) }
        for i = 1, trip.count do
            local text = tostring(i)
            labels[i] = { text = text, width = tm:MeasureStringX(UIFont.Small, text),
                current = text .. "/" .. tostring(trip.count) }
        end
        tripLabels[pn] = labels
    end
    local mapAPI = inner.mapAPI
    local current = Core.navGetTarget(pn)
    local px, py = playerObj:getX(), playerObj:getY()
    for i = 1, trip.count do
        local stop = trip.stops[i]
        local ux, uy = mapAPI:worldToUIX(stop.x, stop.y), mapAPI:worldToUIY(stop.x, stop.y)
        if current and stop.id == current.id then
            local dx, dy = stop.x - px, stop.y - py
            drawNavIndicator(inner, ux, uy, 1, 0.85, 0.4, labels[i].current,
                math.floor(math.sqrt(dx * dx + dy * dy) + 0.5))
        elseif ux >= 0 and uy >= 0 and ux <= inner.width and uy <= inner.height then
            local color = TRIP_COLORS[stop.status]
            local size = labels.size
            inner:drawRect(ux - size / 2, uy - size / 2, size, size, 0.85, 0, 0, 0)
            inner:drawRectBorder(ux - size / 2, uy - size / 2, size, size, 1, color[1], color[2], color[3])
            inner:drawText(labels[i].text, ux - labels[i].width / 2, uy - fontH / 2, 1, 1, 1, 1, UIFont.Small)
            -- 完成與略過保留形狀線索，不只以顏色區別。
            if stop.status == "arrived" then
                inner:drawLine(nil, ux + size / 2 - 5, uy + size / 2 - 3,
                    ux + size / 2 - 2, uy + size / 2, 2, 1, 1, 1, 1)
                inner:drawLine(nil, ux + size / 2 - 2, uy + size / 2,
                    ux + size / 2 + 4, uy + size / 2 - 6, 2, 1, 1, 1, 1)
            elseif stop.status == "skipped" then
                inner:drawLine(nil, ux - size / 2, uy + size / 2,
                    ux + size / 2, uy - size / 2, 2, 1, 1, 1, 1)
            end
        end
    end
end

-- test:nav-draw:start（scripts/test_nav_gate.lua 抽本區段跑 draw gate 整合測試）
local function drawNavTargets(inner)
    local pn = inner.playerNum or 0
    -- gate 只限制顯示；到站更新在 _Itinerary.lua 的非繪製事件內。
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
    if allowed and playerObj then drawTripTargets(inner, pn, playerObj) end
end
-- test:nav-draw:end


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
        -- 加點入口順序（兩張地圖一致）：加到行程最後（主要）→插在指定停靠點之前
        -- （子選單列出待前往站，Core.navInsertSubMenu 共用同一份錨點防線）→
        -- 先去這裡→取代整趟（會立刻出發，故排在後面且一律先確認）→行程管理
        context:addOption(getText("UI_MinidoracatMiniMap_TripAdd"), self,
            self.onMinidoracatAddStop, worldX, worldY)
        Core.navInsertSubMenu(context, self, pn, worldX, worldY)
        context:addOption(getText("UI_MinidoracatMiniMap_TripPriority"), self,
            self.onMinidoracatPriorityStop, worldX, worldY)
        context:addOption(getText("UI_MinidoracatMiniMap_SetTarget"), self,
            self.onMinidoracatSetTarget, worldX, worldY)
        context:addOption(getText("UI_MinidoracatMiniMap_TripManage"), self,
            self.onMinidoracatItinerary)
        -- 複製此處座標：選項文字即時帶座標（先看到再決定點不點）
        local cwx, cwy = math.floor(worldX), math.floor(worldY)
        context:addOption(getText("UI_MinidoracatMiniMap_CopyHere",
            string.format("%d, %d, 0", cwx, cwy)), self, self.onMinidoracatCopyCoords, cwx, cwy)
        context:addOption(getText("UI_MinidoracatMiniMap_SearchMenu"), self,
            self.onMinidoracatSearch)
        if Core.navItineraryState(pn) or Core.navItineraryError(pn) then
            context:addOption(getText("UI_MinidoracatMiniMap_TripClear"), self,
                self.onMinidoracatClearTarget)
        end
        if Core.navGetTarget(pn) then
            context:addOption(getText("UI_MinidoracatMiniMap_TripPause"), self,
                self.onMinidoracatPauseNav)
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

Events.OnGameStart.Add(function()
    for key in pairs(navShared) do navShared[key] = nil end
    for key in pairs(sharedTargets) do sharedTargets[key] = nil end
    for key in pairs(tripLabels) do tripLabels[key] = nil end
end)

-- 跨檔匯出：主檔 ISMiniMapInner:prerender wrap 與 _WorldMapNav.lua 呼叫時查表
Core.drawNavTargets = drawNavTargets -- _WorldMapNav.lua：世界地圖側導航旗標/箭頭（共用繪製）
Core.drawPlayerCoords = drawPlayerCoords -- _WorldMapNav.lua：世界地圖側座標列（共用繪製）
Core.drawAdminViewMarker = drawAdminViewMarker -- _WorldMapNav.lua：世界地圖側同款標記
