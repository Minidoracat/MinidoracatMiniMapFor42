-- MinidoracatMiniMap_Safehouse.lua
-- 本檔範圍：安全屋圖層——範圍框（Safehouses）、圖標（SafehouseIcons）、名稱（SafehouseNames）
-- 三件套的繪製與「伺服器模式 × 距離閘 × 玩家開關」合成。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore；本檔載入期只讀取其「一次性賦值」的穩定引用。主檔的
-- 小地圖 prerender wrap 經 Core.drawSafehouses 呼叫（本檔缺席＝pcall(nil) 回 false，
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
local adotsTexture = Core.adotsTexture
-- 政策 facade（主檔載入期快照）。nil＝舊版共用檔／載入失敗：退 SandboxVars 直讀
local Policy = Core.policy

--------------------------------------------------------------------------------
-- 安全屋範圍（Safehouses，預設開）：成員（含擁有者/受邀）＝綠框、同陣營＝青框、
-- 他人＝紅框。四角經 worldToUIX/Y 投影後以 drawLine2 連線（ISUIElement.lua:1229）
-- ——等軸測（Isometric）投影下矩形成菱形，畫線才不失真。
-- 資料源：SafeHouse.getSafehouseList()（用例 ISSafehousesList.lua:61-62）、
-- 範圍 getX/getY/getX2/getY2（SafeHouse.java:596-632）、成員判定
-- playerAllowed(String)（SafeHouse.java:288-290，只查 owner＋players）、
-- 名稱 getTitle()（SafeHouse.java:727，預設 "Safehouse"）、屋主 getOwner()（:656）。
-- 陣營判定：Faction.getPlayerFaction(username)（Faction.java:123，原版用例
-- ISFactionUI.lua:408 為 IsoPlayer 版）→ faction:isOwner/isMember(owner)（:150/:154）。
-- 每幀成本：幾何與成員身分走 1 秒快取（refreshSafehouseRows），距離閘與視野裁切先於成員判定——
-- 大型伺服器上安全屋可達數百，原本每幀每間 4 個座標 getter＋playerAllowed 都是跨界呼叫
-- （2026-09-25 正式服實測 drawSafehouses 佔客戶端 Lua 取樣 1.67%）。單機無安全屋＝零成本。
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
local SH_ICON_SIZE = 16 -- ponytail: 固定 16px；要可調再比照 PoiIconSize 加滑條
-- 名稱字寬 memo（title 逐幀 MeasureStringX 是跨界呼叫；title 少且 session 內罕變，
-- 改名後舊鍵殘留無害）；字高隨 UI 字型倍率變動，首繪量一次
local shNameW = {}
local shFontH

-- 模式判定純函式（三處共用：範圍／圖標走 SafehouseDisplay，名稱走 SafehouseNameDisplay）
local function safehouseModeAllows(mode, mine, ally)
    if mode == 1 then return false end
    if mode == 2 then return mine == true end
    if mode == 4 then return mine == true or ally == true end
    return true
end

-- 幾何／成員快取：清單內容罕變（認領、邀請、解除），每幀重讀全服安全屋的 Java getter 是純浪費。
-- 重建條件：逾 SH_CACHE_MS、清單筆數變、玩家帳號變、陣營物件變（含時鐘倒退）。
-- 容忍：同筆數的增刪、範圍或成員異動最多延遲 1 秒反映；列（row）持有的 SafeHouse
-- 參照在延遲窗內可能已被移除，仍是有效 Java 物件，最多多畫 1 秒。
-- 成員身分 lazy：只有通過距離閘的列才呼叫 playerAllowed／陣營判定，結果存到下次重建。
local SH_CACHE_MS = 1000
local shCache = { at = nil, size = -1, user = nil, faction = nil, rows = {} }

local function refreshSafehouseRows(list, size, username, faction)
    local c = shCache
    local now = getTimestampMs()
    if c.at and now >= c.at and now - c.at < SH_CACHE_MS and c.size == size
        and c.user == username and c.faction == faction then
        return c.rows
    end
    local rows = {}
    for i = 0, size - 1 do
        local sh = list:get(i)
        -- 安全屋幾何 getter＝SafeHouse.java:596-633；getX2/getY2 回 x+w/y+h
        rows[i + 1] = { sh = sh, x1 = sh:getX(), y1 = sh:getY(), x2 = sh:getX2(), y2 = sh:getY2() }
    end
    c.at, c.size, c.user, c.faction, c.rows = now, size, username, faction, rows
    return rows
end

local function drawSafehouses(inner)
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
    local rows = refreshSafehouseRows(list, size, username, faction)
    -- 視野裁切：只在某個已開圖層沒有距離閘時才需要（有距離閘時距離先行已篩掉遠處，
    -- 不為它多付每幀 8 次 uiToWorld 跨界）。visibleWorldAABB＝小地圖四角反投影的外接框
    -- （主檔，等軸測下是可見菱形的超集）：矩形與它不相交＝四邊、圖標、名稱都不可能在
    -- 視窗內，整列跳過。成本從「全服安全屋數」降為「畫面內安全屋數」
    local vMinX, vMaxX, vMinY, vMaxY
    if (((wantRect or wantIcon) and not dist2) or (wantName and not ndist2))
        and Core.visibleWorldAABB then
        vMinX, vMaxX, vMinY, vMaxY = Core.visibleWorldAABB(inner)
    end
    local mapAPI = inner.mapAPI
    local W, H = inner.width, inner.height
    for idx = 1, #rows do
        local row = rows[idx]
        local x1, y1, x2, y2 = row.x1, row.y1, row.x2, row.y2
        -- 距離先行：超出兩個距離閘的列不做成員判定（最近點＝玩家夾進矩形）。
        -- 夾值用比較式而非 math.max/min：Kahlua 的 math.* 每次都是跨界 Java 呼叫，
        -- 每幀×全服安全屋數就是本段熱點（x1<=x2、y1<=y2：SafeHouse w/h 非負）
        local nearRI, nearName = wantRect or wantIcon, wantName
        if vMinX and (x2 < vMinX or x1 > vMaxX or y2 < vMinY or y1 > vMaxY) then
            nearRI, nearName = false, false
        elseif dist2 or ndist2 then
            local nx = px < x1 and x1 or (px > x2 and x2 or px)
            local ny = py < y1 and y1 or (py > y2 and y2 or py)
            local dx, dy = px - nx, py - ny
            local d2 = dx * dx + dy * dy
            if dist2 and d2 > dist2 then nearRI = false end
            if ndist2 and d2 > ndist2 then nearName = false end
        end
        if nearRI or nearName then
            local sh = row.sh
            -- 成員判定走 String 版 playerAllowed（SafeHouse.java:288-290）——IsoPlayer 版
            -- （:282-285）含管理員 CanGoInsideSafehouses 後門，admin 測試會全判綠
            local mine = row.mine
            if mine == nil then
                mine = username ~= nil and sh:playerAllowed(username)
                row.mine = mine
            end
            local ally = false
            if faction and not mine then
                ally = row.ally
                if ally == nil then
                    local owner = sh:getOwner()
                    ally = owner ~= nil and (faction:isOwner(owner) or faction:isMember(owner))
                    row.ally = ally
                end
            end
            local showRect = nearRI and wantRect and safehouseModeAllows(shMode, mine, ally)
            local showIcon = nearRI and wantIcon and safehouseModeAllows(shMode, mine, ally)
            local showName = nearName and safehouseModeAllows(nameMode, mine, ally)
            if showRect or showIcon or showName then
                -- 四角投影（worldToUIX/Y 同殭屍點位；等軸測下矩形成菱形故逐邊畫線）
                local ux1, uy1 = mapAPI:worldToUIX(x1, y1), mapAPI:worldToUIY(x1, y1)
                local ux2, uy2 = mapAPI:worldToUIX(x2, y1), mapAPI:worldToUIY(x2, y1)
                local ux3, uy3 = mapAPI:worldToUIX(x2, y2), mapAPI:worldToUIY(x2, y2)
                local ux4, uy4 = mapAPI:worldToUIX(x1, y2), mapAPI:worldToUIY(x1, y2)
                local r, g, b = 1.0, 0.25, 0.2             -- 他人＝紅
                if mine then r, g, b = 0.25, 0.95, 0.35     -- 自己＝綠
                elseif ally then r, g, b = 0.35, 0.8, 1.0 end -- 同陣營＝青
                if showRect then
                    drawClippedEdge(inner, ux1, uy1, ux2, uy2, r, g, b)
                    drawClippedEdge(inner, ux2, uy2, ux3, uy3, r, g, b)
                    drawClippedEdge(inner, ux3, uy3, ux4, uy4, r, g, b)
                    drawClippedEdge(inner, ux4, uy4, ux1, uy1, r, g, b)
                end
                if showIcon or showName then
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
                        local ix, iy = cx - SH_ICON_SIZE / 2, cy - SH_ICON_SIZE / 2
                        if tex and drawGlyph and ix >= 0 and iy >= 0
                            and ix + SH_ICON_SIZE <= W and iy + SH_ICON_SIZE <= H then
                            drawGlyph(inner, tex, ix, iy, SH_ICON_SIZE, r, g, b)
                            iconDrawn = true
                        end
                    end
                    if showName then
                        local name = sh:getTitle()
                        if name and name ~= "" then
                            local tw = shNameW[name]
                            if not tw then
                                local tm = getTextManager()
                                tw = tm:MeasureStringX(UIFont.Small, name) -- 用例 ISFactionUI.lua:238
                                shNameW[name] = tw
                                if not shFontH then shFontH = tm:getFontHeight(UIFont.Small) end
                            end
                            local th = shFontH
                            local tx = cx - tw / 2
                            -- 有圖標時名稱掛圖標正下方，否則置中（同 MapBounds 名稱底墊畫法）
                            local ty = iconDrawn and (cy + SH_ICON_SIZE / 2 + 1) or (cy - th / 2)
                            if tx >= 2 and ty >= 2 and tx + tw <= W - 2 and ty + th <= H - 2 then
                                inner:drawRect(tx - 3, ty - 1, tw + 6, th + 2, 0.6, 0, 0, 0)
                                inner:drawText(name, tx, ty, r, g, b, 0.95, UIFont.Small)
                            end
                        end
                    end
                end
            end
        end
    end
end
-- test:safehouse-distance:end

-- 跨檔匯出：主檔小地圖 prerender wrap 經 Core.drawSafehouses 呼叫（載入序在本檔之後）；
-- 設定視窗（_Settings.lua，載入序在本檔之後）讀兩個模式做「伺服器已關閉」提示
Core.drawSafehouses = drawSafehouses
Core.safehouseDisplayMode = safehouseDisplayMode
Core.safehouseNameMode = safehouseNameMode
