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
local mapTextZoom = Core.mapTextZoom
local drawMapText = Core.drawMapText
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
-- 閘門與旗標繪製同源——閘門關閉時旗與路線一起消失，不會旗滅線存。
-- 功能閘門 share 被擋（錶沒有通訊）同樣回 nil；收到的封包照存，恢復即顯示
Core.navGetShared = function(pn)
    if not Core.navShareAllowed() then return nil end
    local fa = Core.featureAllowed
    if fa and not fa(pn, "share") then return nil end
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
-- 舊 addon 閘門查詢（只看 registerNavGate 的註冊表）：分享目標的繪製只吃這一層
-- ＋share，不吃功能閘門的 nav（沒有定位模組照樣看得到隊友分享）。
-- 繪製路徑每幀呼叫：零註冊在 #gates 後即返回，無配置、無 pcall
Core.navAddonGateAllows = function(playerNum, context)
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
-- 導航閘門＝舊 addon 閘門 AND 功能閘門 nav（_FeatureGate.lua；有快取，缺檔＝放行）。
-- set／draw／預覽三種 consumer 都經這裡；舊閘門先判，reasonKey 回第一個擋阻者
Core.navGateAllows = function(playerNum, context)
    local allowed, reasonKey = Core.navAddonGateAllows(playerNum, context)
    if not allowed then return false, reasonKey end
    local fa = Core.featureAllowed
    if fa then
        local ok, featureReason = fa(playerNum, "nav")
        if not ok then return false, featureReason end
    end
    return true
end
-- test:nav-gate:end
-- 雙地圖右鍵選單共用 helper。導航項鎖定（原版 notAvailable＋ISToolTip 慣例，同 _Places 未設家）：
-- 建選單時問一次 set 閘門，被擋回原因文字（同點下去被擋時的那句）、放行回 nil。
-- 閘門拋錯＝不鎖：點擊時 navSetTarget 的 set 檢查仍是安全網
-- test:nav-menu-lock:start
Core.navMenuBlocked = function(pn)
    local ok, allowed, reasonKey = pcall(Core.navGateAllows, pn, "set")
    if not ok or allowed then return nil end
    return Core.navErrorText("blocked", reasonKey)
end
-- text＝nil（放行）時不動 option
Core.navMenuLock = function(option, text)
    if not text then return end
    option.notAvailable = true
    local tip = ISToolTip:new()
    tip:initialise()
    tip:setVisible(false)
    tip.description = text
    option.toolTip = tip
end
-- 子選單：父項＋原版 getNew／addSubMenu（ISContextMenu.lua:1199／1075；getNew 走 player 單例的
-- subMenuPool，前手一定先呼叫過 ISContextMenu.get 才有那張池子）。第三方選單缺方法或不是 player
-- 單例時回 nil，呼叫端改平鋪，不讓別人的選單連坐壞掉。title＝已翻好的父項文字（省略＝getText(key)）
Core.mapSubMenu = function(context, key, title)
    if type(context.addSubMenu) ~= "function" or type(context.player) ~= "number"
        or type(context.subMenuPool) ~= "table" or not (ISContextMenu and ISContextMenu.getNew) then
        return nil
    end
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(context:addOption(title or getText(key)), sub)
    return sub
end
-- test:nav-menu-lock:end
Core.navShareTarget = function(pn)
    local playerObj = getSpecificPlayer(pn)
    local t = Core.navGetTarget(pn)
    if not (playerObj and t and isClient()) then return end
    if not Core.navShareAllowed() then return end -- 伺服器沙盒禁用／政策模組缺席
    local fa = Core.featureAllowed
    if fa and not fa(pn, "share") then return end -- 功能閘門（錶沒有通訊）
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
-- （距離公尺）分兩行掛旗上——同行擠在一起難讀（使用者回饋），名字上、距離下。
-- k＝標記大小倍率（滑條 px／16，預設 1＝原幾何）；tz＝地圖文字倍率
-- 標籤行高：原固定 22px（Medium 字的字形高＋留白），隨文字倍率等比放大（倍率 1＝原像素）
local function navLineH(tz)
    return 22 * tz
end

local function drawNavFlag(inner, ux, uy, r, g, b, label, dist, k, tz)
    inner:drawRect(ux - 2 * k, uy - 14 * k, 4 * k, 15 * k, 0.8, 0, 0, 0)
    inner:drawRect(ux - k, uy - 13 * k, 2 * k, 13 * k, 1, 1, 1, 1)
    inner:drawRect(ux, uy - 14 * k, 11 * k, 8 * k, 0.8, 0, 0, 0)
    inner:drawRect(ux + k, uy - 13 * k, 9 * k, 6 * k, 1, r, g, b)
    -- 深色底墊字（同原版玩家名牌做法 UIWorldMap.java:509），淺色地圖上才清晰；
    -- 位置夾進視窗（長名字貼上/右緣時不外溢）。Medium 字級，最下行離旗頂 8px
    local w, h = inner.width, inner.height
    local lines = {}
    -- 作者名行用旗色（隊友 ID 與其路線/旗同色一眼對應，使用者回饋）；距離行
    -- 維持白色（讀數清晰）
    if label then lines[#lines + 1] = { t = label, cr = r, cg = g, cb = b } end
    if dist then lines[#lines + 1] = { t = tostring(dist) .. "m", cr = 1, cg = 1, cb = 1 } end
    local lineH = navLineH(tz)
    local ly = uy - 14 * k - 8 - #lines * lineH -- 多行往上長，最下行維持離旗頂 8px
    for i = 1, #lines do
        local ln = lines[i]
        local tw = getTextManager():MeasureStringX(UIFont.Medium, ln.t) * tz
        local lx = ux + 10 * k
        if lx < 2 then lx = 2 elseif lx > w - tw - 2 then lx = w - tw - 2 end
        local cy2 = ly + (i - 1) * lineH
        if cy2 < 2 then cy2 = 2 elseif cy2 > h - lineH then cy2 = h - lineH end
        inner:drawRect(lx - 4, cy2 - 1, tw + 8, lineH, 0.6, 0, 0, 0)
        drawMapText(inner, ln.t, lx, cy2, ln.cr, ln.cg, ln.cb, 0.95, UIFont.Medium, tz) -- drawText＝ISUIElement.lua:1293
    end
end

-- 目標在視窗內＝旗標；出視窗＝中心→目標線段裁到內縮 12px 矩形（重用 clipSegment），
-- 交點畫 V 形箭頭（翼向量＝方向單位向量旋 ±25.8°，c=0.9/s=0.436，免 atan）
-- arrow＝功能閘門 arrow（呼叫端每表面算一次）；false 時畫面外不畫箭頭，畫面內旗標照畫
local function drawNavIndicator(inner, tx, ty, r, g, b, label, dist, k, tz, arrow)
    local w, h = inner.width, inner.height
    if tx >= 8 * k and ty >= 16 * k and tx <= w - 14 * k and ty <= h - 4 * k then
        drawNavFlag(inner, tx, ty, r, g, b, label, dist, k, tz) -- 名字/距離分行由旗標函式排版
        return
    end
    if arrow == false then return end
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
    local wing, lw = 11 * k, 2 * k
    inner:drawLine(nil, tipx, tipy, tipx - b1x * wing, tipy - b1y * wing, lw, 0.95, r, g, b)
    inner:drawLine(nil, tipx, tipy, tipx - b2x * wing, tipy - b2y * wing, lw, 0.95, r, g, b)
    local txt = label
    if dist then txt = tostring(dist) .. "m" end
    if txt then
        -- MeasureStringX 用例 ISFactionUI.lua:238；Medium 字級同旗標 label
        local tw = getTextManager():MeasureStringX(UIFont.Medium, txt) * tz
        local lineH = navLineH(tz)
        local px = tipx - uxn * 28 * k - tw / 2
        local py = tipy - uyn * 28 * k - (lineH / 2 - 1)
        if px < 2 then px = 2 elseif px > w - tw - 2 then px = w - tw - 2 end
        if py < 2 then py = 2 elseif py > h - lineH then py = h - lineH end
        -- 深色底墊字（同原版玩家名牌做法 UIWorldMap.java:509），淺色地圖上才清晰
        inner:drawRect(px - 4, py - 1, tw + 8, lineH, 0.6, 0, 0, 0)
        drawMapText(inner, txt, px, py, 1, 1, 1, 0.95, UIFont.Medium, tz)
    end
end

local tripLabels = {}
local TRIP_COLORS = {
    pending = { 0.05, 0.86, 1.0 }, arrived = { 0.3, 0.95, 0.4 }, skipped = { 0.5, 0.5, 0.5 },
}
local function drawTripTargets(inner, pn, playerObj, k, tz, arrow)
    local trip = Core.navItineraryState(pn)
    if not trip then tripLabels[pn] = nil; return end
    -- 走完的行程預設不畫（KeepFinishedTrip 關）：到站後站點不留在地圖上；行程頁照樣列出結果
    if trip.phase == "completed" and not getBoolOption("KeepFinishedTrip", false) then return end
    local tm = getTextManager()
    local fontH = tm:getFontHeight(UIFont.Small)
    local labels = tripLabels[pn]
    if not labels or labels.count ~= trip.count or labels.fontH ~= fontH then
        labels = { count = trip.count, fontH = fontH }
        for i = 1, trip.count do
            local text = tostring(i)
            labels[i] = { text = text, width = tm:MeasureStringX(UIFont.Small, text),
                current = text .. "/" .. tostring(trip.count) }
        end
        tripLabels[pn] = labels
    end
    -- 站點方塊：原 max(20, 字高+6)；邊長跟標記大小，但至少容得下放大後的站號
    local numH = fontH * tz
    local size = 20 * k
    if size < numH + 6 then size = numH + 6 end
    size = size - size % 1
    local mapAPI = inner.mapAPI
    local current = Core.navGetTarget(pn)
    local px, py = playerObj:getX(), playerObj:getY()
    for i = 1, trip.count do
        local stop = trip.stops[i]
        local ux, uy = mapAPI:worldToUIX(stop.x, stop.y), mapAPI:worldToUIY(stop.x, stop.y)
        if current and stop.id == current.id then
            local dx, dy = stop.x - px, stop.y - py
            drawNavIndicator(inner, ux, uy, 1, 0.85, 0.4, labels[i].current,
                math.floor(math.sqrt(dx * dx + dy * dy) + 0.5), k, tz, arrow)
        elseif ux >= 0 and uy >= 0 and ux <= inner.width and uy <= inner.height then
            local color = TRIP_COLORS[stop.status]
            inner:drawRect(ux - size / 2, uy - size / 2, size, size, 0.85, 0, 0, 0)
            inner:drawRectBorder(ux - size / 2, uy - size / 2, size, size, 1, color[1], color[2], color[3])
            drawMapText(inner, labels[i].text, ux - labels[i].width * tz / 2, uy - numH / 2,
                1, 1, 1, 1, UIFont.Small, tz)
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
    -- addonOk＝舊 addon 閘門（分享目標也吃）；allowed 再 AND 功能閘門 nav（自己的行程）；
    -- arrow＝功能閘門 arrow（畫面外箭頭）。零註冊三者皆 true
    local addonOk = Core.navAddonGateAllows(pn, "draw")
    local fa = Core.featureAllowed
    local allowed = addonOk and (not fa or fa(pn, "nav")) and true or false
    local surface = inner == ISWorldMap_instance and "world" or "mini"
    local arrow = not fa or fa(pn, "arrow", surface)
    -- 路線層（_NavRoute.lua 掛 Core.drawNavRoute）：先畫＝墊在旗標/箭頭/分享旗
    -- 之下；第二參＝自己的路線與預覽是否可畫（分享路線另經 navGetShared 判 share）。
    -- 收 err＋實例旗標 log-once（同動物繪製/_WorldMapNav 慣例：主檔
    -- :4022-4027 明寫「持久錯誤首次記 log 免全靜默」——裸 pcall 吞錯會讓路線
    -- 靜默消失且每幀重試失敗熱路徑，三 review lanes 一致指認）
    if addonOk and Core.drawNavRoute then
        local navOk, navErr = pcall(Core.drawNavRoute, inner, allowed)
        if not navOk and not inner._minidoracatNavRouteErrLogged then
            inner._minidoracatNavRouteErrLogged = true
            log("nav route draw failed: " .. tostring(navErr))
        end
    end
    local mapAPI = inner.mapAPI
    local playerObj = getSpecificPlayer(pn)
    -- 旗標／行程站跟「標記大小」（px，16＝原尺寸），標籤跟「地圖文字大小」；每幀讀值
    local k = Core.markerIconSize() / 16
    local tz = Core.mapTextZoom()
    -- 陣營分享來的：只畫「給這位玩家」的桶（青旗＋名字＋距離）；getUsername
    -- 原版用例 ISScoreboard.lua:108。已收到的目標仍受目前 AllowNavShare 閘門
    -- 與功能閘門 share 即時控制（navGetShared 同源）；「顯示在」這張地圖的格關（SharedTargets／
    -- WMSharedTargets）只是不畫，收到的分享照留（路線層 _NavRoute 讀同一組格）
    local bucket = addonOk and Core.layerOn("shared", surface)
        and Core.navGetShared and Core.navGetShared(pn) or nil
    if bucket and playerObj then
        for author, t in pairs(bucket) do
            local sdx, sdy = t.x - playerObj:getX(), t.y - playerObj:getY()
            local cr, cg, cb = Core.navShareColor(author)
            drawNavIndicator(inner, mapAPI:worldToUIX(t.x, t.y), mapAPI:worldToUIY(t.x, t.y),
                cr, cg, cb, author, math.floor(math.sqrt(sdx * sdx + sdy * sdy) + 0.5), k, tz, arrow)
        end
    end
    -- 搜尋落點 ping（本體在 _Search.lua 掛 Core.drawSearchPing——主 chunk locvar
    -- 已頂 Kahlua 200 上限（LexState actvar[200]），主檔不得再增頂層 local；
    -- 動態查同 :3924 Core.drawNavRoute 慣例）。無導航目標時也要畫，須在下行早退前
    if Core.drawSearchPing then Core.drawSearchPing(inner, mapAPI) end
    -- 家／收藏標記不是導航，不受 draw gate 限制；畫在行程旗標之下。錯誤 log-once
    if Core.drawPlaces then
        local placesOk, placesErr = pcall(Core.drawPlaces, inner)
        if not placesOk and not inner._minidoracatPlacesErrLogged then
            inner._minidoracatPlacesErrLogged = true
            log("places draw failed: " .. tostring(placesErr))
        end
    end
    if allowed and playerObj then drawTripTargets(inner, pn, playerObj, k, tz, arrow) end
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
    local tz = mapTextZoom()
    cw = cw * tz
    local ch = tm:getFontHeight(UIFont.Small) * tz
    local cx = (inner.width - cw) / 2
    cx = cx - cx % 1 -- 純 Lua floor（原 math.max+math.floor 兩次跨界）
    if cx < 0 then cx = 0 end
    local cy = inner.height - ch - 10
    if inner._minidoracatFreelook and getBoolOption("FreeLook", true) then
        cy = cy - ch - 10
    end
    cy = cy - cy % 1 -- 縮放後字高可為小數；點陣字落在整數列才不糊
    inner:drawRect(cx - 8, cy - 3, cw + 16, ch + 6, 0.6, 0, 0, 0)
    if copied then
        drawMapText(inner, txt, cx, cy, 1, 0.85, 0.4, 1, UIFont.Small, tz)
    else
        drawMapText(inner, txt, cx, cy, 1, 1, 1, 0.95, UIFont.Small, tz)
    end
end

-- 朝向箭頭與視野扇形（設計稿 minimap-facing-1018、minimap-team-facing-1019）：自己與附近其他玩家的
-- 箭頭蓋在引擎的 6×6 紅點上、畫在本 MOD 全部地圖圖層之上（呼叫端排在 drawNavTargets 之後）。引擎紅點
-- 在 Lua prerender 之前就畫完（UIWorldMap.render → super.render），站在家或坐車時會被家圖標、方向盤
-- 圖標整顆蓋住。方向＝「位置」與「前方一點」都經 mapAPI 投影後取畫面向量：俯視、等軸測與 175ms 切換
-- 過場同一條路徑。原版地圖引擎只有俯視／等軸測兩種矩陣，地圖本身不能跟著角色旋轉。
-- 全掛 Core、不開 chunk 層 local（Kahlua 主 chunk local 上限）。
-- test:player-facing:start
-- 鏢形：0＝尖、1＝右後、2＝凹口、3＝左後。單色 DrawPolygon 以第 0 點為扇心拆 (0,1,2)(0,2,3)
-- 兩個三角形，凹四邊形照樣畫對——頂點順序不可動。pad＝外擴（描邊層用）。走 ISUIElement 的
-- drawPolygon（元件相對座標，ISUIElement.lua:1254）：地圖與設定預覽元件都有
Core.drawFacingDart = function(el, cx, cy, ux, uy, len, wid, pad, r, g, b, a)
    local px, py = -uy, ux
    local f = 0.55 * len + pad * 1.8
    local back = 0.45 * len + pad
    local notch = 0.15 * len - pad * 0.4
    local hw = wid * 0.5 + pad
    el:drawPolygon(nil,
        cx + ux * f, cy + uy * f,
        cx - ux * back + px * hw, cy - uy * back + py * hw,
        cx - ux * notch, cy - uy * notch,
        cx - ux * back - px * hw, cy - uy * back - py * hw,
        r, g, b, a)
end
-- 兩層：黑色外框、彩色本體（預設原版紅點的紅；其他玩家的顏色見 FACING_COLORS）。2026-10-18 使用者
-- 在樣式比較頁選了 B（拿掉白邊）：對比在淺色地面與家圖標上較高，在草地、柏油路約 2.6–3.3:1
-- （白邊版至少 3.4:1）。地圖與設定預覽共用。a＝整支的不透明度（預設 1；BFH 式的樓下玩家用）
Core.drawFacingArrow = function(el, cx, cy, ux, uy, size, r, g, b, a)
    local len, wid = size * 1.25, size * 0.95
    local dart = Core.drawFacingDart
    a = a or 1
    dart(el, cx, cy, ux, uy, len, wid, 1.6, 0, 0, 0, 0.85 * a)
    dart(el, cx, cy, ux, uy, len, wid, 0, r or 0.92, g or 0.1, b or 0.1, a)
end
-- 別層標示（設計稿 minimap-floors-v2-1019；勾選 FloorMarks、下拉 FloorMarkStyle）：只改其他玩家，樓層以
-- 這張地圖的玩家（el.playerNum）為準，樓層＝z 取整數（地下室是負數，樓梯上算下面那層）。
-- 1＝BFH 式（2015 年 Battlefield Hardline 的小地圖）：別層 FLOOR_SIZE 倍大小、扇形跟著縮；樓上照原色、
-- 扇形 alpha FLOOR_CONE_UP；樓下顏色乘 FLOOR_DIM、箭頭 alpha FLOOR_DIM_A、扇形 alpha FLOOR_CONE_DOWN。
-- 2＝BF6 式：大小顏色不變，箭頭裡多一個畫面對齊的黑色小三角，尖端朝上＝樓上（drawFloorGlyph）
Core.FLOOR_SIZE, Core.FLOOR_DIM, Core.FLOOR_DIM_A = 0.65, 0.55, 0.8
Core.FLOOR_CONE_UP, Core.FLOOR_CONE_DOWN = 0.6, 0.3
-- 小三角放在鏢形實心的部分（中心往尖端 0.1 個標記大小）；第 4 點重複第 3 點＝單一三角形
Core.drawFloorGlyph = function(el, cx, cy, ux, uy, size, up)
    local gx, gy = cx + ux * 0.1 * size, cy + uy * 0.1 * size
    local w, h = size * 0.2, size * 0.16
    local s = up and -1 or 1
    el:drawPolygon(nil, gx, gy + s * h, gx + w, gy - s * h, gx - w, gy - s * h, gx - w, gy - s * h, 0, 0, 0, 0.9)
end
-- 一筆的大小、顏色倍率、箭頭 alpha、扇形 alpha：只有 BFH 式的別層玩家會變
Core.floorLook = function(e, style)
    if style ~= 1 or e.dz == 0 then return e.size, 1, 1, 0.85 end
    if e.dz > 0 then return e.size * Core.FLOOR_SIZE, 1, 1, Core.FLOOR_CONE_UP end
    return e.size * Core.FLOOR_SIZE, Core.FLOOR_DIM, Core.FLOOR_DIM_A, Core.FLOOR_CONE_DOWN
end
-- 畫的層：0 樓下、1 同層、2 樓上、3 本機玩家（永遠最上面）
Core.facingLayer = function(e)
    if e.kind == "self" then return 3 end
    if e.dz < 0 then return 0 end
    if e.dz > 0 then return 2 end
    return 1
end
-- 視野扇形（設計稿 minimap-team-facing-1019）：media/ui/minimap_facing_cone.png 是 128×128 白色漸層
-- （scripts/make_facing_cone.py 產生），頂點在左邊中間、半角 38°，畫的時候再上色。四角 DrawTexture
-- 收畫面絕對座標（UIElement.DrawTexture 不加元件位置，DrawPolygon 才加），所以這裡自己加。
-- 角順序 tl, tr, br, bl＝貼圖 (0,0) (1,0) (1,1) (0,1)：u 沿前方、v 沿側邊
Core.FACING_CONE_TEX = "media/ui/minimap_facing_cone.png"
Core.FACING_CONE_SIDE = 0.628 -- 側邊半寬／長度＝sin 38°，同貼圖產生器
Core.FACING_CONE_LEN = 4.5    -- 扇形長＝標記大小 × 4.5 px（預設 72 px，原型實拍的長度）
-- 每種人兩組 rgb：箭頭、扇形。隊友＝同陣營或同安全屋
Core.FACING_COLORS = {
    self = { 0.92, 0.1, 0.1, 1, 0.25, 0.2 },
    team = { 0.2, 0.78, 1, 0.3, 0.8, 1 },
    other = { 0.95, 0.95, 0.95, 1, 1, 1 },
}
Core.drawFacingConeQuad = function(el, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a)
    local tex = Core.adotsTexture(Core.FACING_CONE_TEX)
    if not tex then return end
    local ox, oy = el:getAbsoluteX(), el:getAbsoluteY()
    el:drawTextureAllPoint(tex, x1 + ox, y1 + oy, x2 + ox, y2 + oy, x3 + ox, y3 + oy, x4 + ox, y4 + oy, r, g, b, a)
end
-- 畫面座標版（設定預覽）：頂點 (cx, cy)、方向 (ux, uy) 是單位向量、長 len px
Core.drawFacingConeUI = function(el, cx, cy, ux, uy, len, r, g, b, a)
    local s = Core.FACING_CONE_SIDE * len
    local sx, sy = -uy * s, ux * s
    local ex, ey = cx + ux * len, cy + uy * len
    Core.drawFacingConeQuad(el, cx - sx, cy - sy, ex - sx, ey - sy, ex + sx, ey + sy, cx + sx, cy + sy, r, g, b, a)
end
-- 地圖版：四個角都先算世界座標再經 mapAPI 投影，俯視、等軸測與切換過場都貼在地面
Core.drawFacingCone = function(el, api, wx, wy, fx, fy, len, r, g, b, a)
    local scale = api:getWorldScale()
    local L = len / ((scale and scale > 0) and scale or 1)
    local s = Core.FACING_CONE_SIDE * L
    local sx, sy = -fy * s, fx * s
    local ex, ey = wx + fx * L, wy + fy * L
    Core.drawFacingConeQuad(el,
        api:worldToUIX(wx - sx, wy - sy), api:worldToUIY(wx - sx, wy - sy),
        api:worldToUIX(ex - sx, ey - sy), api:worldToUIY(ex - sx, ey - sy),
        api:worldToUIX(ex + sx, ey + sy), api:worldToUIY(ex + sx, ey + sy),
        api:worldToUIX(wx + sx, wy + sy), api:worldToUIY(wx + sx, wy + sy),
        r, g, b, a)
end
-- 位置與世界前向（+x 東、+y 南）：坐車看車（原版紅點也畫在車的位置；角色角度在車上
-- 不保證更新），車頭向量的 x、z＝世界 x、y；徒步看身體角度（跟著轉身動畫，不會八方向
-- 跳格）。車頭向量共用一個 Vector3f，每幀不配置
Core.playerFacing = function(p)
    local v = p:getVehicle()
    if v then
        local f = Core.facingVec
        if not f then
            f = Vector3f.new()
            Core.facingVec = f
        end
        v:getForwardVector(f)
        return v:getX(), v:getY(), f:x(), f:z()
    end
    local a = p:getAnimAngleRadians()
    return p:getX(), p:getY(), math.cos(a), math.sin(a)
end
-- 沙盒 RemoteFacingDisplay：1 關閉、2 只限陣營與安全屋成員（預設）、3 地圖上看得到的所有玩家；
-- 設定視窗「其他玩家顯示朝向」勾選在 1 時停用（offMode）
Core.remoteFacingLevel = function(pn)
    local v = Core.sandboxGate("RemoteFacingDisplay", 2, pn)
    if v == 1 or v == 3 then return v end
    return 2
end
-- 沙盒 AllowFloorMarks（預設開）：多人時伺服器可以關掉別層標示——玩家在哪一層也是 PVP 情報；單機沒有
-- 別的玩家，一律可用。回 1＝伺服器關閉（設定視窗「標示其他樓層」與樣式下拉停用，offMode）、2＝可用。
-- 其他玩家（drawPlayerFacing）與殭屍點（_Dots.lua drawZombieDotsOn）共用
Core.floorMarksMode = function(pn)
    if not isClient() or Core.sandboxGate("AllowFloorMarks", true, pn) == true then return 2 end
    return 1
end
-- 同隊＝同陣營或同安全屋（原版 UIWorldMap.shouldShowRemotePlayer 的同一組判斷，本機玩家任一位即可）。
-- 安全屋判斷會掃全部安全屋，所以每位玩家每秒才重算一次
Core.facingTeam, Core.facingTeamAt = {}, {}
Core.isFacingTeammate = function(other, now)
    local name = other:getUsername()
    if not name then return false end
    local at = Core.facingTeamAt[name]
    if at and now - at < 1000 then return Core.facingTeam[name] end
    local team = false
    for pn = 0, 3 do
        local p = getSpecificPlayer(pn)
        if p and (Faction.isInSameFaction(p, name) or SafeHouse.isInSameSafehouse(p:getUsername(), name)) then
            team = true
            break
        end
    end
    Core.facingTeam[name], Core.facingTeamAt[name] = team, now
    return team
end
-- 本機玩家任一位有 CanSeeAll（原版 isAdminSeeRemotePlayers 另比雙方的權限數，Lua 讀不到對方的；
-- 伺服器本來就只把看得到的隱形玩家同步給有權限的人）。Policy 讀角色要 pcall，每秒重算一次
Core.facingAdmin = function(now)
    if Core.facingAdminAt and now - Core.facingAdminAt < 1000 then return Core.facingAdminVal end
    local P, admin = MinidoracatMiniMapPolicy, false
    if P then
        for pn = 0, 3 do
            if getSpecificPlayer(pn) and P.hasCanSeeAll(pn) then
                admin = true
                break
            end
        end
    end
    Core.facingAdminAt, Core.facingAdminVal = now, admin
    return admin
end
-- 原版 UIWorldMap.shouldShowRemotePlayer 的 Lua 版：不會比原版地圖多顯示任何人。opt＝公開伺服器選項
-- MapRemotePlayerVisibility（登入時下發）：1 不顯示（原版預設）、2 只限陣營、3 陣營＋看得到的人、
-- 4 所有人。「對方看得見隱形玩家」讀不到，當作看不見（只會少畫）
Core.vanillaShowsRemote = function(other, team, admin, opt)
    if other:isInvisible() then return admin end
    if admin then return true end
    if opt == 2 then return team end
    if opt == 3 and team then return true end
    if opt ~= 3 and opt ~= 4 then return false end
    for pn = 0, 3 do
        local p = getSpecificPlayer(pn)
        if p then
            if opt == 4 then
                if not p:isInvisible() then return true end
            elseif p:checkCanSeeClient(other) then
                return true
            end
        end
    end
    return false
end
-- 每幀重用的繪製清單：先收齊，再畫全部扇形、最後畫全部箭頭（扇形不蓋箭頭）；兩趟都照 facingLayer 由下往上，
-- 本機玩家永遠最上面。中心離邊不到半個箭頭就不收，留給原版紅點（自由查看拖走時）。dz＝樓層差（別層標示關＝0）
Core.facingBuf = { n = 0 }
Core.facingPush = function(el, api, k, wx, wy, fx, fy, kind, size, arrow, dz)
    local half = size * 0.8
    local cx, cy = api:worldToUIX(wx, wy), api:worldToUIY(wx, wy)
    if cx < half or cy < half or cx > el.width - half or cy > el.height - half then return end
    local tx, ty = wx + fx * k, wy + fy * k
    local dx = api:worldToUIX(tx, ty) - cx
    local dy = api:worldToUIY(tx, ty) - cy
    local n = math.sqrt(dx * dx + dy * dy)
    if n <= 0 then return end
    local buf = Core.facingBuf
    local i = buf.n + 1
    local e = buf[i]
    if not e then
        e = {}
        buf[i] = e
    end
    e.cx, e.cy, e.ux, e.uy, e.wx, e.wy, e.fx, e.fy = cx, cy, dx / n, dy / n, wx, wy, fx, fy
    e.kind, e.size, e.arrow, e.dz = kind, size, arrow, dz or 0
    buf.n = i
end
-- 其他玩家（設計稿 minimap-team-facing-1019）：getOnlinePlayers＝伺服器有同步給這台客戶端的玩家
-- （約等於周圍載入範圍；遠處玩家引擎只送座標、沒有朝向，只剩原版紅點）。隊友青、其他人白，比自己小一號。
-- myFloor＝這張地圖的玩家所在樓層（別層標示關＝nil，樓層差一律 0）
Core.collectRemoteFacing = function(el, api, k, size, level, myFloor)
    local now = getTimestampMs()
    local admin = Core.facingAdmin(now)
    local opt = getServerOptions():getInteger("MapRemotePlayerVisibility") or 1
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local o = list:get(i)
        if o and not o:isLocalPlayer() and not o:isDead() then
            local team = Core.isFacingTeammate(o, now)
            if (team or level == 3) and Core.vanillaShowsRemote(o, team, admin, opt) then
                local wx, wy, fx, fy = Core.playerFacing(o)
                local dz = myFloor and math.floor(o:getZ()) - myFloor or 0
                Core.facingPush(el, api, k, wx, wy, fx, fy, team and "team" or "other", size, true, dz)
            end
        end
    end
end
-- style＝別層標示樣式（1 BFH、2 BF6；關＝nil）
Core.drawFacingBuf = function(el, api, cone, style)
    local buf, colors, layer = Core.facingBuf, Core.FACING_COLORS, Core.facingLayer
    if cone then
        for L = 0, 3 do
            for i = 1, buf.n do
                local e = buf[i]
                if layer(e) == L then
                    local c = colors[e.kind]
                    local size, dim, _, ca = Core.floorLook(e, style)
                    Core.drawFacingCone(el, api, e.wx, e.wy, e.fx, e.fy, size * Core.FACING_CONE_LEN,
                        c[4] * dim, c[5] * dim, c[6] * dim, ca)
                end
            end
        end
    end
    for L = 0, 3 do
        for i = 1, buf.n do
            local e = buf[i]
            if e.arrow and layer(e) == L then
                local c = colors[e.kind]
                local size, dim, a = Core.floorLook(e, style)
                Core.drawFacingArrow(el, e.cx, e.cy, e.ux, e.uy, size, c[1] * dim, c[2] * dim, c[3] * dim, a)
                if style == 2 and e.dz ~= 0 then Core.drawFloorGlyph(el, e.cx, e.cy, e.ux, e.uy, size, e.dz > 0) end
            end
        end
    end
end
-- el＝小地圖 inner 或世界地圖（都有 mapAPI／width／height／playerNum）。該地圖顯示自己圖標（引擎 Players：小地圖由
-- ModOptions Players 寫入、世界地圖由原版選項）才畫。勾選：PlayerFacing＝自己的箭頭、PlayerCone＝
-- 所有扇形、RemoteFacing＝其他玩家（另要該地圖的 RemotePlayers）、FloorMarks＝別層標示。同原版畫全部本機玩家。
-- 扇形會伸出元件邊，整段包 stencil（同 _Zones fill pass）；畫錯也必定 clear，免得裁切洩漏到同幀其他 UI
Core.drawPlayerFacing = function(el)
    local api = el.mapAPI
    if not (api and api:getBoolean("Players")) then return end
    local selfArrow = getBoolOption("PlayerFacing", true)
    local cone = getBoolOption("PlayerCone", true)
    local level = 1
    if isClient() and getBoolOption("RemoteFacing", true) and api:getBoolean("RemotePlayers") then
        level = Core.remoteFacingLevel()
    end
    if not (selfArrow or cone or level >= 2) then return end
    local size = Core.markerIconSize()
    local scale = api:getWorldScale()
    local k = 48 / ((scale and scale > 0) and scale or 1) -- 約 48 px 長的投影探針
    -- 別層標示只改其他玩家：伺服器開放、勾選開著才記樓層差（style＝樣式 1 BFH、2 BF6；不畫＝nil）
    local style
    Core.facingBuf.n = 0
    if level >= 2 then
        local pn = el.playerNum or 0
        if Core.floorMarksMode(pn) == 2 and getBoolOption("FloorMarks", true) then
            style = Core.getComboIndex("FloorMarkStyle", 1)
        end
        local owner = style and getSpecificPlayer(pn)
        Core.collectRemoteFacing(el, api, k, size * 0.8, level, owner and math.floor(owner:getZ()) or nil)
    end
    if selfArrow or cone then
        for pn = 0, 3 do
            local p = getSpecificPlayer(pn)
            if p and not p:isDead() then
                local wx, wy, fx, fy = Core.playerFacing(p)
                Core.facingPush(el, api, k, wx, wy, fx, fy, "self", size, selfArrow)
            end
        end
    end
    if Core.facingBuf.n == 0 then return end
    el:setStencilRect(0, 0, el.width, el.height)
    local ok, err = pcall(Core.drawFacingBuf, el, api, cone, style)
    el:clearStencilRect()
    if not ok then error(err, 0) end
end
-- test:player-facing:end

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
    local tz = Core.mapTextZoom()
    local bw, bh = mk.w * tz, mk.h * tz
    local Skin = Core.Skin
    local painted = false
    if Skin then
        local ok, err = pcall(drawAdminMarkerSkin, Skin, inner, bw, bh)
        painted = ok
        if not ok and not inner._minidoracatAdminMarkSkinErrLogged then
            inner._minidoracatAdminMarkSkinErrLogged = true
            log("admin view marker skin failed, using rectangular fallback: " .. tostring(err))
        end
    end
    if not painted then
        inner:drawRect(6, 6, bw + 12, bh + 6, 0.72, 0, 0, 0)
        inner:drawRectBorder(6, 6, bw + 12, bh + 6, 1, 1, 0.85, 0.4)
    end
    Core.drawMapText(inner, mk.txt, 12, 9, 1, 0.85, 0.4, 1, UIFont.Small, tz)
end
-- test:admin-view-marker:end

-- 複製選定點座標到剪貼簿（右鍵選單回呼）。z 固定 0＝地面層：小地圖是平面俯視、
-- 點擊格無樓層資訊，同原版 debug 傳送 /teleportto x,y,0 慣例。回饋沿用座標列琥珀提示
function ISMiniMapInner:onMinidoracatCopyCoords(wx, wy)
    copyCoordsText(self, string.format("%d,%d,0", wx, wy))
end

-- test:map-menu:start
-- 「分享目標給陣營」列不列（雙地圖右鍵「行程」子選單與行程頁「動作…」共用，兩處不得各寫一份）：
-- 有活動站＋MP＋陣營（Faction.getPlayerFaction 用例 ISFactionUI.lua:408）＋沙盒＋功能閘門 share
-- （_FeatureGate.lua；缺檔＝放行）。⚠ navShareAllowed 不傳 pn＝AllowNavShare 永不列入管理員旁路白名單
-- （會影響其他玩家、需伺服器轉送的功能閘；主檔 navShareGateTick 註解同義）。點下去的 navShareTarget 照樣再檢查
Core.navShareOk = function(pn, playerObj)
    local fa = Core.featureAllowed
    return playerObj ~= nil and Core.navGetTarget(pn) ~= nil and isClient() and Faction ~= nil
        and Faction.getPlayerFaction(playerObj) ~= nil and Core.navShareAllowed()
        and (not fa or fa(pn, "share"))
end
-- 雙地圖右鍵選單（兩張地圖共用；2026-10-11 設計稿 minimap-rightclick-1011 作答）。第一層依序：
-- 導航（有待前往站時叫「取代並導航」，點了照舊先確認）→加入行程（有待前往站才是子選單：先去這裡／
-- 插在第 N 站之前／加到行程最後，_Search.lua navInsertSubMenu）→收藏（回家／設為家／加入收藏；游標在收藏
-- 圖標上時父項是「收藏：名稱」、子選單換成那一筆，_Places.lua placeAt／placesAddMenu）→複製此處座標→
-- 行程（有行程或壞資料才有：行程規劃／停止導航／分享目標／
-- 清空行程，會刪資料的清空排最後）→搜尋地圖。set 閘門擋住時會設導航的項變紅＋原因（建選單只問一次）。
-- target＝地圖元件：回呼是它的 onMinidoracat* 方法，複製座標的回饋畫在該張地圖上
Core.mapMenuFill = function(context, target, pn, wx, wy, playerObj)
    local blocked, lock = Core.navMenuBlocked(pn), Core.navMenuLock
    local first = Core.navInsertAnchors(pn) > 0 and "UI_MinidoracatMiniMap_SearchSetTarget"
        or "UI_MinidoracatMiniMap_SetTarget"
    lock(context:addOption(getText(first), target, target.onMinidoracatSetTarget, wx, wy), blocked)
    if not Core.navInsertSubMenu(context, target, pn, wx, wy, nil, blocked) then
        lock(context:addOption(getText("UI_MinidoracatMiniMap_TripAdd"), target,
            target.onMinidoracatAddStop, wx, wy), blocked)
    end
    if Core.placesAddMenu then
        -- 游標下是收藏：父項帶名稱，子選單換成這一筆（_Places.lua placeAt；圖層關或沒點中＝nil）
        local place = Core.placeAt and Core.placeAt(target, wx, wy)
        local title = place and Core.placeMenuTitle(pn, place)
        Core.placesAddMenu(Core.mapSubMenu(context, "UI_MinidoracatMiniMap_PlaceMenu", title) or context,
            pn, wx, wy, blocked, place)
    end
    -- 複製此處座標：選項文字即時帶座標（先看到再決定點不點）
    local cx, cy = math.floor(wx), math.floor(wy)
    context:addOption(getText("UI_MinidoracatMiniMap_CopyHere", string.format("%d, %d, 0", cx, cy)),
        target, target.onMinidoracatCopyCoords, cx, cy)
    if Core.navItineraryState(pn) or Core.navItineraryError(pn) then
        local trip = Core.mapSubMenu(context, "UI_MinidoracatMiniMap_TripManage") or context
        trip:addOption(getText("UI_MinidoracatMiniMap_TripTitle"), target,
            target.onMinidoracatItinerary)
        if Core.navGetTarget(pn) then
            trip:addOption(getText("UI_MinidoracatMiniMap_TripPause"), target,
                target.onMinidoracatPauseNav)
        end
        if Core.navShareOk(pn, playerObj) then
            trip:addOption(getText("UI_MinidoracatMiniMap_ShareTarget"), target,
                target.onMinidoracatShareTarget)
        end
        trip:addOption(getText("UI_MinidoracatMiniMap_TripClear"), target,
            target.onMinidoracatClearTarget)
    end
    context:addOption(getText("UI_MinidoracatMiniMap_SearchMenu"), target, target.onMinidoracatSearch)
end
-- test:map-menu:end

-- 右鍵選單追加本 MOD 的地圖選單：原版 onRightMouseUp 以 ISContextMenu.get 建選單
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
        -- uiToWorld 用例 ISMiniMap.lua:289-290
        local wx, wy = self.mapAPI:uiToWorldX(x, y), self.mapAPI:uiToWorldY(x, y)
        -- 「傳送至此」：原版小地圖只在 debug 加（ISMiniMap.lua:291-293），世界地圖則連多人管理員也有
        -- （ISWorldMap.lua:911、941-943）。多人非 debug 時照伺服器 /teleportto 的權限
        -- （TeleportToCommand 的 RequiredCapability＝TeleportToCoordinates）補在最前面，和 debug 同位置；
        -- 回呼用原版 onTeleport（同原版，固定傳送 player 0）。管理員工具不看功能閘門
        local admin = getSpecificPlayer(0)
        local role = isClient() and not getDebug() and Capability and admin and admin:getRole()
        if role and role:hasCapability(Capability.TeleportToCoordinates)
                and getWorld():getMetaGrid():isValidChunk(wx / 10, wy / 10) then
            context:addOption(getText("IGUI_ZombiePopulation_TeleportHere"), self, self.onTeleport, wx, wy)
        end
        -- 功能閘門 minimap 被擋＝畫面是「無訊號」，不追加地圖選項；選單內容兩張地圖共用（Core.mapMenuFill）
        local fa = Core.featureAllowed
        if not fa or fa(pn, "minimap", "mini") then
            Core.mapMenuFill(context, self, pn, wx, wy, playerObj)
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
