-- MinidoracatMiniMap_Safehouse.lua
-- 本檔範圍：安全屋圖層——範圍框（Safehouses）、圖標（SafehouseIcons）、名稱（SafehouseNames）
-- 三件套的繪製與「伺服器模式 × 距離閘 × 玩家開關」合成。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore；本檔載入期只讀取其「一次性賦值」的穩定引用。主檔的
-- 小地圖與世界地圖 prerender wrap 都經 Core.drawSafehouses 呼叫（本檔缺席＝pcall(nil) 回 false，
-- 主檔 log-once 可診斷，不炸 prerender）。
-- 拆檔緣由（2026-09-03）：安全屋分類獨立（圖標／名稱／陣營模式）讓本段從主檔的
-- 一個函式長成一組，主檔主 chunk locvar 貼 Kahlua 200 上限（verify 警戒 190）；
-- 離線測試 scripts/test_livestock_visibility.lua 改從本檔抽 test:safehouse-distance 切片。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

local getBoolOption = Core.getBoolOption
local displayDist = Core.displayDist
local sandboxGate = Core.sandboxGate
local drawClippedEdge = Core.drawClippedEdge
local SH_EDGE_A = Core.edgeAlpha
local deriveAffine = Core.deriveAffine
local adotsTexture = Core.adotsTexture
local getSliderValue = Core.getSliderValue
local mapTextZoom = Core.mapTextZoom
local drawMapText = Core.drawMapText
-- 政策 facade（主檔載入期快照）。nil＝舊版共用檔／載入失敗：退 SandboxVars 直讀
local Policy = Core.policy

--------------------------------------------------------------------------------
-- 安全屋範圍（Safehouses，預設開）：成員（含擁有者/受邀）＝綠框、同陣營＝青框、
-- 他人＝紅框。四角經 worldToUIX/Y 投影後以 drawLine2 連線（ISUIElement.lua:1229）
-- ——等軸測（Isometric）投影下矩形成菱形，畫線才不失真。
-- 資料源：SafeHouse.getSafehouseList()（用例 ISSafehousesList.lua:61-62）、
-- 範圍 getX/getY/getX2/getY2（SafeHouse.java:596-632）、成員判定
-- playerAllowed(String)（SafeHouse.java:288-290，只查 owner＋players）、
-- 名稱 getTitle()（SafeHouse.java:727，預設 "Safehouse"）、屋主 getOwner()（:656，安全屋 MOD
-- 代管的屋換成真正屋主：safehouseOwner）；名稱與屋主帳號不同時附上「(屋主)」（safehouseLabel）。
-- 陣營判定：Faction.getPlayerFaction(username)（Faction.java:123，原版用例
-- ISFactionUI.lua:408 為 IsoPlayer 版）→ faction:isOwner/isMember(屋主)（:150/:154）。
-- 每幀成本：幾何與成員身分走 1 秒快取（refreshSafehouseRows），距離閘與視野裁切先於陣營判定——
-- 大型伺服器上安全屋可達數百，原本每幀每間 4 個座標 getter＋playerAllowed 都是跨界呼叫
-- （2026-09-25 正式服實測 drawSafehouses 佔客戶端 Lua 取樣 1.67%）。單機無安全屋＝零成本。
-- 自己的屋（屋主或成員）不受距離閘（雙地圖同一條）：距離閘擋的是別人的屋（Policy 把安全屋距離
-- 歸隱私層）與遠處雜訊，自己家兩者都不是；正式服距離 20 格時，玩家離家稍遠就在世界地圖找不到
-- 自己家（2026-10-14 Safehouse 交辦，Discord 回報）。小地圖拉遠同理，兩張地圖看到的才一致。
--------------------------------------------------------------------------------
-- 沙盒模式：1=關閉、2=僅自己的、3=全部（預設；缺表視為 3）、4=自己與陣營。
-- 管理員隱私檢視生效時 Policy 回 3 且距離閘一併放行——旁路只影響「這台客戶端畫什麼」
local function safehouseDisplayMode(pn)
    if Policy then return Policy.safehouseMode(pn) end
    return sandboxGate("SafehouseDisplay", 3)
end
local function safehouseNameMode(pn)
    if Policy then return Policy.safehouseNameMode(pn) end
    return sandboxGate("SafehouseNameDisplay", 3)
end

-- test:safehouse-distance:start
local SH_ICON = "media/ui/LootableMaps/map_house.png" -- 原版地圖符號（框架缺席時的退回）
-- 名稱字寬 memo（標籤逐幀 MeasureStringX 是跨界呼叫；標籤少且 session 內罕變，
-- 改名後舊鍵殘留無害）；字高隨 UI 字型倍率變動，首繪量一次
local shNameW = {}
local shFontH

-- 名稱標籤：原版右鍵認領以認領者帳號當標題（ISWorldObjectContextMenu.lua:517-519
-- sendSafehouseClaim(..., playerObj:getUsername())），標題＝屋主即未自訂、照原樣顯示；
-- 標題≠屋主（玩家改名、管理員建立或轉移屋主後留下的舊名）在後面括號附屋主帳號。
-- 空標題維持不畫（改名封包拒收空字串，SafehouseChangeTitlePacket.java:53）
local function safehouseLabel(title, owner)
    if title and title ~= "" and owner and owner ~= "" and title ~= owner then
        return title .. " (" .. owner .. ")"
    end
    return title or ""
end

-- 屋主帳號：安全屋 MOD（選用、不在 require=）代管的屋，原生屋主是服務帳號 "@MSH:<claimId>"
-- （"@" 不是合法帳號字元），真正屋主與成員都在 players；真正屋主查它的客戶端 API
-- MinidoracatSafehouse.v1.ownerName（不配置、不丟錯；資料未到回 nil，並在背景向伺服器要一次）。
-- 拿不到回 nil：標籤只顯示名稱、不算同陣營；列快取 1 秒重建時再查，資料到了就更新。
-- 載入序不保證，呼叫期才讀全域
local function safehouseOwner(owner)
    if not (owner and string.find(owner, "^@MSH:")) then return owner end
    local SH = MinidoracatSafehouse and MinidoracatSafehouse.v1
    if SH and SH.API_MAJOR == 1 and SH.CAPABILITIES and SH.CAPABILITIES.ownerName then
        return SH.ownerName(owner)
    end
    return nil
end

-- 模式判定純函式（三處共用：範圍／圖標走 SafehouseDisplay，名稱走 SafehouseNameDisplay）
local function safehouseModeAllows(mode, mine, ally)
    if mode == 1 then return false end
    if mode == 2 then return mine == true end
    if mode == 4 then return mine == true or ally == true end
    return true
end

-- 幾何／成員快取：清單內容罕變（認領、邀請、解除），每幀重讀全服安全屋的 Java getter 是純浪費。
-- 重建條件：逾 SH_CACHE_MS、清單筆數變、玩家帳號變、陣營物件變（含時鐘倒退）。
-- 容忍：同筆數的增刪、範圍、成員或名稱異動最多延遲 1 秒反映；列（row）持有的 SafeHouse
-- 參照在延遲窗內可能已被移除，仍是有效 Java 物件，最多多畫 1 秒。
-- 成員身分（row.mine）在重建時每列查一次：自己的屋要穿過距離閘與候選列，得先知道哪幾列是自己的。
-- 陣營判定與名稱標籤 lazy：只有通過距離閘的列才判、才組標籤，結果存到下次重建。
-- 每位本機玩家（pn）各一份：分割畫面兩位玩家帳號、陣營不同，共用一份會每幀互相觸發重建
local SH_CACHE_MS = 1000
local shCaches = {}

-- 一段區間 [s, e) 的扁平清單扣掉 [c, d)；沒交集原樣保留
local function subtractSpan(spans, c, d)
    local out, n = {}, 0
    for k = 1, #spans, 2 do
        local s, e = spans[k], spans[k + 1]
        if d <= s or c >= e then
            out[n + 1], out[n + 2], n = s, e, n + 2
        else
            if c > s then out[n + 1], out[n + 2], n = s, c, n + 2 end
            if d < e then out[n + 1], out[n + 2], n = d, e, n + 2 end
        end
    end
    return out
end

-- row 的一條邊（horizontal：y＝at、x 從 a 到 b；否則 x＝at、y 從 a 到 b）扣掉同一間別塊從外側貼著的部分，
-- 剩下的段照 x1, y1, x2, y2 接到 segs。side＝-1 是上緣／左緣，+1 是下緣／右緣
local function outerEdge(segs, row, group, horizontal, at, a, b, side)
    local spans = { a, b }
    for i = 1, #group do
        local o = group[i]
        if o ~= row then
            if horizontal then
                if (side < 0 and o.y2 == at) or (side > 0 and o.y1 == at) then spans = subtractSpan(spans, o.x1, o.x2) end
            elseif (side < 0 and o.x2 == at) or (side > 0 and o.x1 == at) then
                spans = subtractSpan(spans, o.y1, o.y2)
            end
        end
    end
    for k = 1, #spans, 2 do
        local n = #segs
        if horizontal then
            segs[n + 1], segs[n + 2], segs[n + 3], segs[n + 4] = spans[k], at, spans[k + 1], at
        else
            segs[n + 1], segs[n + 2], segs[n + 3], segs[n + 4] = at, spans[k], at, spans[k + 1]
        end
    end
end

-- 安全屋 MOD 的一間可以有多塊（每塊一個原生，屋主同為 "@MSH:<id>"，不重疊、塊與塊共用邊）：同一間只畫外緣
-- （row.segs），圖標與名稱只標在最大的那塊（其他塊 row.noMark）。原版屋主（同一人的多間）照舊各畫各的
local function mergeSafehousePieces(groups)
    for _, group in pairs(groups) do
        if #group > 1 then
            local main, best = nil, -1
            for i = 1, #group do
                local row = group[i]
                local segs = {}
                outerEdge(segs, row, group, true, row.y1, row.x1, row.x2, -1)
                outerEdge(segs, row, group, false, row.x2, row.y1, row.y2, 1)
                outerEdge(segs, row, group, true, row.y2, row.x1, row.x2, 1)
                outerEdge(segs, row, group, false, row.x1, row.y1, row.y2, -1)
                row.segs, row.noMark = segs, true
                local area = (row.x2 - row.x1) * (row.y2 - row.y1)
                if area > best then main, best = row, area end
            end
            main.noMark = nil
        end
    end
end

local function refreshSafehouseRows(pn, list, size, username, faction)
    local c = shCaches[pn]
    if not c then
        c = { at = nil, size = -1 }
        shCaches[pn] = c
    end
    local now = getTimestampMs()
    if c.at and now >= c.at and now - c.at < SH_CACHE_MS and c.size == size
        and c.user == username and c.faction == faction then
        return c.rows
    end
    local rows, groups = {}, nil
    for i = 0, size - 1 do
        local sh = list:get(i)
        -- 安全屋幾何 getter＝SafeHouse.java:596-633；getX2/getY2 回 x+w/y+h
        -- 成員判定走 String 版 playerAllowed（SafeHouse.java:288-290）——IsoPlayer 版
        -- （:282-285）含管理員 CanGoInsideSafehouses 後門，admin 測試會全判綠
        local row = { sh = sh, x1 = sh:getX(), y1 = sh:getY(), x2 = sh:getX2(), y2 = sh:getY2(),
            mine = username ~= nil and sh:playerAllowed(username) }
        rows[i + 1] = row
        local owner = sh:getOwner()
        if owner and string.find(owner, "^@MSH:") then
            groups = groups or {}
            local group = groups[owner]
            if group then group[#group + 1] = row else groups[owner] = { row } end
        end
    end
    if groups then mergeSafehousePieces(groups) end
    c.at, c.size, c.user, c.faction, c.rows = now, size, username, faction, rows
    return rows
end

-- 候選列（2026-10-07 正式服複本 DevProfiler：數百間安全屋時，逐幀把每一列都判一次視窗／距離，
-- 本身就是每幀 0.2-0.5ms）：只走可能通過下方逐列判定的列，順序照 rows＝繪製呼叫序列不變。
--   有視野裁切（vMinX）：候選＝與「建構時視窗 ±SH_VIEW_PAD」相交的列，視窗仍在框內就沿用；
--   全由距離閘決定（reach＝各已開圖層的距離取大）：候選＝與「建構時玩家 ±(reach＋SH_MOVE_PAD)」
--     相交的列，玩家移動不超過 SH_MOVE_PAD、reach 不變就沿用——最近點距離 ≤ reach ⇒ 矩形與
--     玩家 ±reach 方框相交，故候選是逐列判定通過者的超集。
--   自己的屋（row.mine）不看距離，一律在候選裡；視野外的照樣在逐列判定被裁掉。
-- rows 每次重建（1 秒快取）都重篩。
local SH_VIEW_PAD = 64
local SH_MOVE_PAD = 16
local function shCandidates(inner, rows, vMinX, vMaxX, vMinY, vMaxY, px, py, reach)
    local c = inner._minidoracatShCand
    if not c then
        c = { list = {} }
        inner._minidoracatShCand = c
    end
    if c.rows == rows then
        if vMinX then
            if c.reach == nil and vMinX >= c.minX and vMaxX <= c.maxX
                and vMinY >= c.minY and vMaxY <= c.maxY then
                return c.list, c.n
            end
        elseif c.reach == reach and px - c.px <= SH_MOVE_PAD and c.px - px <= SH_MOVE_PAD
            and py - c.py <= SH_MOVE_PAD and c.py - py <= SH_MOVE_PAD then
            return c.list, c.n
        end
    end
    c.rows = rows
    local minX, maxX, minY, maxY
    if vMinX then
        c.reach = nil
        minX, maxX = vMinX - SH_VIEW_PAD, vMaxX + SH_VIEW_PAD
        minY, maxY = vMinY - SH_VIEW_PAD, vMaxY + SH_VIEW_PAD
    else
        c.reach, c.px, c.py = reach, px, py
        local r = reach + SH_MOVE_PAD
        minX, maxX, minY, maxY = px - r, px + r, py - r, py + r
    end
    c.minX, c.maxX, c.minY, c.maxY = minX, maxX, minY, maxY
    local list, n = c.list, 0
    for i = 1, #rows do
        local row = rows[i]
        if row.mine or (row.x2 >= minX and row.x1 <= maxX and row.y2 >= minY and row.y1 <= maxY) then
            n = n + 1
            list[n] = i
        end
    end
    c.n = n -- list 尾端的舊索引不清：只讀到 n
    return list, n
end

-- 一間安全屋的框、圖標與名稱（地圖與設定視窗預覽共用）：四角＝UI 座標（等軸測下是菱形），
-- r/g/b＝身分色；name＝已解析的標籤（nil／""＝不畫），名稱寬度依字串快取
local function drawSafehouseAt(inner, ux1, uy1, ux2, uy2, ux3, uy3, ux4, uy4, r, g, b,
        showRect, showIcon, name, iconSize, tz)
    local W, H = inner.width, inner.height
    if showRect then
        drawClippedEdge(inner, ux1, uy1, ux2, uy2, r, g, b)
        drawClippedEdge(inner, ux2, uy2, ux3, uy3, r, g, b)
        drawClippedEdge(inner, ux3, uy3, ux4, uy4, r, g, b)
        drawClippedEdge(inner, ux4, uy4, ux1, uy1, r, g, b)
    end
    if not (showIcon or (name and name ~= "")) then return end
    local cx = (ux1 + ux3) / 2 -- 菱形中心＝對角中點
    local cy = (uy1 + uy3) / 2
    local iconDrawn = false
    if showIcon then
        -- 白 glyph 染色畫法與動物／載具符號共用（_Dots.lua adotsDrawGlyph；
        -- 模組缺席＝不畫圖標，其餘照常）；只在整顆落在視窗內時畫
        -- UI 框架 rev 4 art 圖示優先（呼叫時查 Core.Skin），缺則退原版 map_house
        local Skin = Core.Skin
        local tex = Skin and Skin.iconTexture and Skin.iconTexture("house")
            or (adotsTexture and adotsTexture(SH_ICON))
        local drawGlyph = Core.adotsDrawGlyph
        local ix, iy = cx - iconSize / 2, cy - iconSize / 2
        if tex and drawGlyph and ix >= 0 and iy >= 0
            and ix + iconSize <= W and iy + iconSize <= H then
            drawGlyph(inner, tex, ix, iy, iconSize, r, g, b)
            iconDrawn = true
        end
    end
    if name and name ~= "" then
        local tw = shNameW[name]
        if not tw then
            local tm = getTextManager()
            tw = tm:MeasureStringX(UIFont.Small, name) -- 用例 ISFactionUI.lua:238
            shNameW[name] = tw
            if not shFontH then shFontH = tm:getFontHeight(UIFont.Small) end
        end
        tw = tw * tz
        local th = shFontH * tz
        local tx = cx - tw / 2
        -- 有圖標時名稱掛圖標正下方，否則置中（同 MapBounds 名稱底墊畫法）
        local ty = iconDrawn and (cy + iconSize / 2 + 1) or (cy - th / 2)
        if tx >= 2 and ty >= 2 and tx + tw <= W - 2 and ty + th <= H - 2 then
            inner:drawRect(tx - 3, ty - 1, tw + 6, th + 2, 0.6, 0, 0, 0)
            drawMapText(inner, name, tx, ty, r, g, b, 0.95, UIFont.Small, tz)
        end
    end
end

-- 拉遠 LOD（只管別人的屋，自己的屋一律全畫）：畫面上最長邊比圖標小＝只畫框，不標圖標與名稱；
-- 小於 SH_LOD_HIDE_PX＝整間不畫（框也只剩一個色點）。2026-10-14 實機：世界地圖整張入鏡、305 間、
-- 不限距離時逐間投影＋圖標＋名稱每幀 11.7ms（-debug），那時每間只有 1-2px，名稱全疊在一起
local SH_LOD_HIDE_PX = 4

-- 地圖上的框線直接呼叫 javaObject:DrawLine（chunk 格線同法），裁切交給整層 stencil（ISUIElement.lua:459）：
-- 舊路徑每條邊經 drawClippedEdge→clipSegment→ISUIElement.drawLine→checkGetTexture 四層 Lua，
-- 2026-10-15 實機同畫面 300 間只畫框時每間約 12µs（非 debug）；改直畫＋下方仿射投影後約 5µs。整條在畫面外的邊不呼叫。
-- 設定視窗預覽仍走 drawSafehouseAt 的 drawClippedEdge（預覽沒有 stencil 配對）。DrawLine 自加元件絕對座標
-- （UIElement.java:509-512），參數順序 r, g, b, a（同 ISUIElement.drawLine 的 Java 本體）
local stencilOn = false -- 本幀已開 stencil：外層 drawSafehouses 無條件配對清除
local function shEdge(inner, x1, y1, x2, y2, r, g, b)
    local w, h = inner.width, inner.height
    if (x1 < 0 and x2 < 0) or (x1 > w and x2 > w) or (y1 < 0 and y2 < 0) or (y1 > h and y2 > h) then return end
    if not stencilOn then
        inner:setStencilRect(0, 0, w, h)
        stencilOn = true
    end
    inner.javaObject:DrawLine(nil, x1, y1, x2, y2, 1, r, g, b, SH_EDGE_A)
end

local function drawSafehousesBody(inner)
    if not (SafeHouse and SafeHouse.getSafehouseList) then return end
    local wantRect = getBoolOption("Safehouses", true)
    local wantIcon = getBoolOption("SafehouseIcons", true)
    local wantName = getBoolOption("SafehouseNames", true)
    if not (wantRect or wantIcon or wantName) then return end
    local pn = inner.playerNum or 0
    local shMode = safehouseDisplayMode(pn)
    local nameMode = safehouseNameMode(pn)
    if shMode == 1 then wantRect, wantIcon = false, false end
    if nameMode == 1 then wantName = false end
    if not (wantRect or wantIcon or wantName) then return end
    local list = SafeHouse.getSafehouseList()
    local size = list and list:size() or 0
    if size == 0 then return end
    -- 距離閘：範圍框與圖標共用 SafehouseDisplayDistance，名稱獨立 SafehouseNameDistance
    local dist = (wantRect or wantIcon) and displayDist("SafehouseDisplayDistance", pn) or nil
    local ndist = wantName and displayDist("SafehouseNameDistance", pn) or nil
    -- getSpecificPlayer/getX/getY 原版用例 ISMiniMap.lua:216-222；getUsername 原版用例
    -- ISScoreboard.lua:108。距離啟用但缺玩家時全部 fail closed
    local playerObj = getSpecificPlayer(pn)
    if (dist or ndist) and not playerObj then return end
    local px = playerObj and playerObj:getX()
    local py = playerObj and playerObj:getY()
    local username = playerObj and playerObj:getUsername()
    local dist2 = dist and dist * dist
    local ndist2 = ndist and ndist * ndist
    -- 陣營只在任一模式為 4 時查（單機／無陣營＝nil，模式 4 退化成「僅自己的」）
    local faction = nil
    if (shMode == 4 or nameMode == 4) and username and Faction and Faction.getPlayerFaction then
        faction = Faction.getPlayerFaction(username)
    end
    local rows = refreshSafehouseRows(pn, list, size, username, faction)
    -- 視野裁切：只在某個已開圖層沒有距離閘時才需要（有距離閘時距離先行已篩掉遠處的別人的屋，
    -- 不為它多付每幀 8 次 uiToWorld 跨界）。visibleWorldAABB＝地圖元件四角反投影的外接框
    -- （主檔，等軸測下是可見菱形的超集）：矩形與它不相交＝四邊、圖標、名稱都不可能在
    -- 視窗內，整列跳過。成本從「全服安全屋數」降為「畫面內安全屋數」
    local vMinX, vMaxX, vMinY, vMaxY
    if (((wantRect or wantIcon) and not dist2) or (wantName and not ndist2))
        and Core.visibleWorldAABB then
        vMinX, vMaxX, vMinY, vMaxY = Core.visibleWorldAABB(inner)
    end
    local mapAPI = inner.mapAPI
    -- 圖標大小（px，滑條 SafehouseIconSize）與地圖文字倍率：每幀讀值，拖動即時生效
    local iconSize = getSliderValue("SafehouseIconSize", 16, 8, 48)
    local tz = mapTextZoom()
    -- 拉遠 LOD 用：getWorldScale＝px/格（UIWorldMapV1.java:274），每幀一次跨界
    local scale = mapAPI:getWorldScale()
    -- 候選列（shCandidates）：有視野裁切，或全部已開圖層都有距離閘時才篩；
    -- 兩者皆無（缺 visibleWorldAABB）＝逐列全走
    local reach
    if not vMinX and not (((wantRect or wantIcon) and not dist2) or (wantName and not ndist2)) then
        reach = 0
        if (wantRect or wantIcon) and dist > reach then reach = dist end
        if wantName and ndist > reach then reach = ndist end
    end
    local cand, cn
    if vMinX or reach then
        cand, cn = shCandidates(inner, rows, vMinX, vMaxX, vMinY, vMaxY, px, py, reach)
    end
    local acx, acy, p0x, p0y, sxx, sxy, syx, syy -- 仿射投影：本幀第一間要畫時才導出（見下方）
    for ci = 1, cn or #rows do
        local row = rows[cand and cand[ci] or ci]
        local x1, y1, x2, y2 = row.x1, row.y1, row.x2, row.y2
        local mine = row.mine
        -- 距離先行：超出兩個距離閘的列不做陣營判定（最近點＝玩家夾進矩形）；自己的屋不看距離。
        -- 夾值用比較式而非 math.max/min：Kahlua 的 math.* 每次都是跨界 Java 呼叫，
        -- 每幀×全服安全屋數就是本段熱點（x1<=x2、y1<=y2：SafeHouse w/h 非負）
        local nearRI, nearName = wantRect or wantIcon, wantName
        if vMinX and (x2 < vMinX or x1 > vMaxX or y2 < vMinY or y1 > vMaxY) then
            nearRI, nearName = false, false
        elseif (dist2 or ndist2) and not mine then
            local nx = px < x1 and x1 or (px > x2 and x2 or px)
            local ny = py < y1 and y1 or (py > y2 and y2 or py)
            local dx, dy = px - nx, py - ny
            local d2 = dx * dx + dy * dy
            if dist2 and d2 > dist2 then nearRI = false end
            if ndist2 and d2 > ndist2 then nearName = false end
        end
        -- 拉遠 LOD（別人的屋）：最長邊換成畫面 px，太小整間不畫、比圖標小只畫框（small）
        local small = false
        if (nearRI or nearName) and not mine then
            local ext = (x2 - x1 > y2 - y1 and x2 - x1 or y2 - y1) * scale
            if ext < SH_LOD_HIDE_PX then
                nearRI, nearName = false, false
            elseif ext < iconSize then
                small = true
            end
        end
        if nearRI or nearName then
            local sh = row.sh
            local ally = false
            if faction and not mine then
                ally = row.ally
                if ally == nil then
                    local owner = safehouseOwner(sh:getOwner())
                    ally = owner ~= nil and (faction:isOwner(owner) or faction:isMember(owner))
                    row.ally = ally
                end
            end
            local showRect = nearRI and wantRect and safehouseModeAllows(shMode, mine, ally)
            local showIcon = nearRI and wantIcon and not (row.noMark or small) and safehouseModeAllows(shMode, mine, ally)
            local showName = nearName and not (row.noMark or small) and safehouseModeAllows(nameMode, mine, ally)
            if showRect or showIcon or showName then
                -- 四角投影：仿射係數（主檔 deriveAffine，錨在畫面中心避開 float32 遠錨消去）本幀第一間要畫時
                -- 才導出（2＋6 次跨界），之後每間純 Lua 乘加，不逐角 worldToUIX/Y。等軸測下矩形成菱形
                if not acx then
                    local cx, cy = inner.width / 2, inner.height / 2
                    acx, acy = mapAPI:uiToWorldX(cx, cy), mapAPI:uiToWorldY(cx, cy)
                    acx, acy = acx - acx % 1, acy - acy % 1
                    p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
                end
                local ax1, ay1, ax2, ay2 = x1 - acx, y1 - acy, x2 - acx, y2 - acy
                local ux1, uy1 = p0x + ax1 * sxx + ay1 * syx, p0y + ax1 * sxy + ay1 * syy
                local ux2, uy2 = p0x + ax2 * sxx + ay1 * syx, p0y + ax2 * sxy + ay1 * syy
                local ux3, uy3 = p0x + ax2 * sxx + ay2 * syx, p0y + ax2 * sxy + ay2 * syy
                local ux4, uy4 = p0x + ax1 * sxx + ay2 * syx, p0y + ax1 * sxy + ay2 * syy
                local r, g, b = 1.0, 0.25, 0.2             -- 他人＝紅
                if mine then r, g, b = 0.25, 0.95, 0.35     -- 自己＝綠
                elseif ally then r, g, b = 0.35, 0.8, 1.0 end -- 同陣營＝青
                -- 多塊安全屋的一塊：只畫外緣那幾段（mergeSafehousePieces），不畫四條完整的邊
                local segs = row.segs
                if segs and showRect then
                    for k = 1, #segs, 4 do
                        local ax, ay, bx, by = segs[k] - acx, segs[k + 1] - acy, segs[k + 2] - acx, segs[k + 3] - acy
                        shEdge(inner, p0x + ax * sxx + ay * syx, p0y + ax * sxy + ay * syy,
                            p0x + bx * sxx + by * syx, p0y + bx * sxy + by * syy, r, g, b)
                    end
                elseif showRect then
                    shEdge(inner, ux1, uy1, ux2, uy2, r, g, b)
                    shEdge(inner, ux2, uy2, ux3, uy3, r, g, b)
                    shEdge(inner, ux3, uy3, ux4, uy4, r, g, b)
                    shEdge(inner, ux4, uy4, ux1, uy1, r, g, b)
                end
                -- 標籤隨列快取（1 秒重建）：省每幀 getTitle／getOwner 跨界與字串串接
                local name = nil
                if showName then
                    name = row.label
                    if name == nil then
                        name = safehouseLabel(sh:getTitle(), safehouseOwner(sh:getOwner()))
                        row.label = name
                    end
                end
                if showIcon or (name and name ~= "") then
                    drawSafehouseAt(inner, ux1, uy1, ux2, uy2, ux3, uy3, ux4, uy4, r, g, b,
                        false, showIcon, name, iconSize, tz)
                end
            end
        end
    end
end

-- 入口：body 整段 pcall，stencil 無條件配對清除——漏 clear 會讓引擎全域 stencil 洩漏、當幀後續 UI
-- 都被裁到地圖矩形（同 chunk 格線、zone 填色 A1），錯誤再交回呼叫端 log-once
local function drawSafehouses(inner)
    stencilOn = false
    local ok, err = pcall(drawSafehousesBody, inner)
    if stencilOn then
        stencilOn = false
        inner:clearStencilRect()
    end
    if not ok then error(err, 0) end
end
-- test:safehouse-distance:end

-- 跨檔匯出：主檔小地圖與世界地圖 prerender wrap 經 Core.drawSafehouses 呼叫（載入序在本檔之後）；
-- 設定視窗（_Settings.lua，載入序在本檔之後）讀兩個模式做「伺服器已關閉」提示
Core.drawSafehouses = drawSafehouses
Core.safehouseDisplayMode = safehouseDisplayMode
Core.safehouseNameMode = safehouseNameMode
Core.drawSafehouseAt = drawSafehouseAt -- 設定視窗效果預覽與地圖同一份畫法
