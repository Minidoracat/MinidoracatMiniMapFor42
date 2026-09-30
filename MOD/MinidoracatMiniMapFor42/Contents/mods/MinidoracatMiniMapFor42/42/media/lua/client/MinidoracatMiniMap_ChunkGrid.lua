-- MinidoracatMiniMap_ChunkGrid.lua
-- 本檔範圍：chunk 格線圖層（ChunkGrid，預設關）。B42 世界以 8×8 格為一個 chunk
-- （IsoChunk；存檔 map/<x/8>/<y/8>.bin），以 chunk 為單位運作的存檔／重置工具需要在
-- 地圖上對得出範圍：棋盤格底色、格線、所在 chunk 標示（編號＋含端點座標範圍）、逐格編號。
-- 小地圖與世界地圖共用（兩表面同走 getAPIv3：ISMiniMap.lua:192／ISWorldMap.lua:268），
-- 主檔兩個 prerender wrap 經 Core.drawChunkGrid 呼叫（本檔缺席＝pcall(nil) 回 false，
-- 主檔 log-once）。載入序：字母序 '.'(0x2E) < '_'(0x5F)，主檔先建好 Core。
-- 成本（實機 Debug 量測：每次 Kahlua→Java 呼叫約數 µs，呼叫數即成本）：
--   * chunk 在畫面上小於 MIN_PX：只付 getWorldScale 一次跨界。
--   * 投影走主檔 deriveAffine 係數（每幀 6 次跨界），格點為純 Lua 乘加。
--   * 棋盤格用 8×8 chunk 一張的貼圖鋪（每 64 個 chunk 一次 DrawTexture），不逐格畫四邊形。
--   * 格線與四邊形直接呼叫 javaObject（略過 ISUIElement 包裝），裁切交給元件矩形 stencil，
--     不在 Lua 逐線做 Liang-Barsky。
--   * 逐格編號依畫面內 chunk 數封頂。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

local getBoolOption = Core.getBoolOption
local visibleWorldAABB = Core.visibleWorldAABB
local deriveAffine = Core.deriveAffine
local mapTextZoom = Core.mapTextZoom

local CHUNK = 8               -- B42 chunk 邊長（格）
local BLOCK = 8               -- 棋盤格貼圖一張涵蓋 BLOCK×BLOCK 個 chunk
local CHECKER_TEX = "media/ui/minimap_chunk_checker.png" -- 256×256：8×8 格，(i+j) 奇數格不透明黑
-- LOD：chunk 在畫面上的邊長 px＝√(平行四邊形面積)；等軸測下面積為正交的一半
local MIN_PX = 12             -- 以下整層不畫：格線間距再小就糊成一片（同外部重置工具網格門檻）
local MAX_LINES = 500         -- 格線條數上限：高解析度全螢幕世界地圖拉遠時，超過就整層不畫
local FILL_MAX_CELLS = 8000   -- 底色：畫面內 chunk 數上限（≈ 125 張貼圖＋邊緣）
local LABEL_MAX_CELLS = 150   -- 逐格編號：畫面內 chunk 數上限（每格底墊＋文字兩次呼叫；字最貴）
local LABEL_CACHE_MAX = 4096  -- 編號字串快取筆數上限（超過整表清空，免長途移動無限累積）
local LINE_R, LINE_G, LINE_B, LINE_A = 0.62, 0.68, 0.76, 0.55 -- 石板灰：深淺底圖都看得到
local FILL_A = 0.14                                           -- 暗格：黑
local CUR_R, CUR_G, CUR_B = 1.0, 0.8, 0.25                    -- 所在 chunk：琥珀（本 MOD 高亮慣例）

local labelText, labelW, labelCount = {}, {}, 0 -- labelW：編號字寬（倍率 1），只在文字放大時量
-- 逐格編號底墊的代表寬（最長編號 "0000,0000"）與字高：首繪量測一次（同安全屋名稱字高）
local labelRefW, labelFontH
local checkerTex -- 棋盤格貼圖（載入成功才快取；缺檔時底色略過）
-- stencil 是否已開：外層包裝無條件配對清除
local stencilOn = false

local function quadVisible(ax, ay, bx, by, cx, cy, dx, dy, w, h)
    -- 純 Lua 比較鏈（math.* 在 Kahlua 是跨界呼叫，同 zone 填色 ZR-2）
    local minx, maxx = ax, ax
    if bx < minx then minx = bx elseif bx > maxx then maxx = bx end
    if cx < minx then minx = cx elseif cx > maxx then maxx = cx end
    if dx < minx then minx = dx elseif dx > maxx then maxx = dx end
    if maxx < 0 or minx > w then return false end
    local miny, maxy = ay, ay
    if by < miny then miny = by elseif by > maxy then maxy = by end
    if cy < miny then miny = cy elseif cy > maxy then maxy = cy end
    if dy < miny then miny = dy elseif dy > maxy then maxy = dy end
    return maxy >= 0 and miny <= h
end

local function drawChunkGridBody(inner)
    local jo = inner.javaObject
    local mapAPI = inner.mapAPI
    if not (jo and mapAPI) then return end
    -- 拉遠早退：chunk 邊長 ≤ CHUNK×worldScale（等軸測再乘 √½），一次跨界即可排除
    -- （getWorldScale＝px/格，UIWorldMapV1.java:274）
    if mapAPI:getWorldScale() * CHUNK < MIN_PX then return end
    local w, h = inner.width, inner.height
    local vMinX, vMaxX, vMinY, vMaxY = visibleWorldAABB(inner)
    local acx = math.floor((vMinX + vMaxX) / 2)
    local acy = math.floor((vMinY + vMaxY) / 2)
    local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
    -- 一個 chunk 的兩條邊（畫面 px 向量）：e＝世界 +x、f＝世界 +y
    local ex, ey, fx, fy = sxx * CHUNK, sxy * CHUNK, syx * CHUNK, syy * CHUNK
    local det = ex * fy - ey * fx
    local area = det < 0 and -det or det
    if area < MIN_PX * MIN_PX then return end
    local cells = w * h / area -- 畫面內約略 chunk 數
    -- 外接框（等軸測下是可見菱形的超集）覆蓋的 chunk 索引；負座標世界用 floor 才正確
    local i0, i1 = math.floor(vMinX / CHUNK), math.floor(vMaxX / CHUNK)
    local j0, j1 = math.floor(vMinY / CHUNK), math.floor(vMaxY / CHUNK)
    if (i1 - i0) + (j1 - j0) + 2 > MAX_LINES then return end
    -- 以下線段與四邊形都不在 Lua 裁切，一律靠元件矩形 stencil（ISUIElement.lua:459）
    inner:setStencilRect(0, 0, w, h)
    stencilOn = true

    -- 1) 棋盤格底色：8×8 chunk 一張貼圖，貼圖原點落在 chunk 索引為 8 的倍數處，
    -- 奇偶與全域 (i+j) 一致。四角版 DrawTexture 不加元件絕對座標（UIElement.java:304-336，
    -- 與 DrawLine／DrawPolygon 不同），這裡自己加
    if cells <= FILL_MAX_CELLS then
        -- 只快取成功（缺檔交引擎 nullTextures 負快取，同主檔 adotsTexture 策略）
        if not checkerTex then checkerTex = getTexture(CHECKER_TEX) end
        if checkerTex then
            local absX, absY = jo:getAbsoluteX(), jo:getAbsoluteY()
            local bex, bey, bfx, bfy = ex * BLOCK, ey * BLOCK, fx * BLOCK, fy * BLOCK
            local span = CHUNK * BLOCK
            local bi0, bi1 = math.floor(i0 / BLOCK), math.floor(i1 / BLOCK)
            for bj = math.floor(j0 / BLOCK), math.floor(j1 / BLOCK) do
                local dx, dy = bi0 * span - acx, bj * span - acy
                local ax, ay = p0x + dx * sxx + dy * syx, p0y + dx * sxy + dy * syy
                for _ = bi0, bi1 do
                    local bx, by = ax + bex, ay + bey
                    local cx, cy = bx + bfx, by + bfy
                    local qx, qy = ax + bfx, ay + bfy
                    if quadVisible(ax, ay, bx, by, cx, cy, qx, qy, w, h) then
                        jo:DrawTexture(checkerTex, ax + absX, ay + absY, bx + absX, by + absY,
                            cx + absX, cy + absY, qx + absX, qy + absY, 0, 0, 0, FILL_A)
                    end
                    ax, ay = bx, by
                end
            end
        end
    end

    -- 2) 所在 chunk（缺玩家＝不標示；世界地圖單例的 playerNum 隨擁有者切換）：琥珀底色，
    -- 外框與標籤在格線之後畫。四角 k1..k4＝(x,y)、(x+8,y)、(x+8,y+8)、(x,y+8)
    local pci, pcj
    local k1x, k1y, k2x, k2y, k3x, k3y, k4x, k4y
    local curVisible = false
    local playerObj = getSpecificPlayer(inner.playerNum or 0)
    if playerObj then
        pci = math.floor(playerObj:getX() / CHUNK)
        pcj = math.floor(playerObj:getY() / CHUNK)
        local dx, dy = pci * CHUNK - acx, pcj * CHUNK - acy
        k1x, k1y = p0x + dx * sxx + dy * syx, p0y + dx * sxy + dy * syy
        k2x, k2y = k1x + ex, k1y + ey
        k3x, k3y = k2x + fx, k2y + fy
        k4x, k4y = k1x + fx, k1y + fy
        curVisible = quadVisible(k1x, k1y, k2x, k2y, k3x, k3y, k4x, k4y, w, h)
        if curVisible then
            jo:DrawPolygon(nil, k1x, k1y, k2x, k2y, k3x, k3y, k4x, k4y, CUR_R, CUR_G, CUR_B, 0.22)
        end
    end

    -- 3) 格線：每條 chunk 邊界橫跨整個外接框；邊界 8k ≤ vMax 即 k ≤ i1，k 取 i0..i1 不漏。
    -- 外接框只比畫面多 2 格邊距，框內的線幾乎都穿過畫面，不另做 Lua 拒絕、交 stencil 裁
    -- （DrawLine 自加元件絕對座標，UIElement.java:509-512）
    local dyA, dyB = vMinY - acy, vMaxY - acy
    for i = i0, i1 do
        local dx = i * CHUNK - acx
        local bx, by = p0x + dx * sxx, p0y + dx * sxy
        jo:DrawLine(nil, bx + dyA * syx, by + dyA * syy, bx + dyB * syx, by + dyB * syy,
            1, LINE_R, LINE_G, LINE_B, LINE_A)
    end
    local dxA, dxB = vMinX - acx, vMaxX - acx
    for j = j0, j1 do
        local dy = j * CHUNK - acy
        local bx, by = p0x + dy * syx, p0y + dy * syy
        jo:DrawLine(nil, bx + dxA * sxx, by + dxA * sxy, bx + dxB * sxx, by + dxB * sxy,
            1, LINE_R, LINE_G, LINE_B, LINE_A)
    end

    -- 文字（逐格編號＋所在 chunk 標籤）另有開關 ChunkGridLabels（預設開），關掉只留底色、格線與琥珀框
    local wantText = getBoolOption("ChunkGridLabels", true)
    local tz = wantText and mapTextZoom() or 1 -- 地圖文字大小；1＝原 DrawTextCentre／DrawText 路徑

    -- 4) 逐格編號：畫面內 chunk 數封頂，且底墊整塊落在 chunk 平行四邊形內才畫——
    -- 底墊角點換回 chunk 局部座標 (u,v)，|u|、|v| ≤ ½ 即在內（正交與等軸測通用）
    if wantText and cells <= LABEL_MAX_CELLS then
        if not labelRefW then
            local tm = getTextManager()
            labelRefW = tm:MeasureStringX(UIFont.Small, "0000,0000") -- 用例 ISFactionUI.lua:238
            labelFontH = tm:getFontHeight(UIFont.Small)
        end
        -- 字放大後底墊跟著變大，塞不進 chunk 的縮放檔自然不畫編號（同一條 |u|,|v|≤½ 判定）
        local hw, hh = labelRefW * tz / 2 + 3, labelFontH * tz / 2 + 1
        local tm = tz ~= 1 and getTextManager() or nil
        local u1, v1 = (fy * hw - fx * hh) / det, (ex * hh - ey * hw) / det
        local u2, v2 = (fy * hw + fx * hh) / det, (-ex * hh - ey * hw) / det
        if u1 < 0 then u1 = -u1 end
        if v1 < 0 then v1 = -v1 end
        if u2 < 0 then u2 = -u2 end
        if v2 < 0 then v2 = -v2 end
        if u1 <= 0.5 and v1 <= 0.5 and u2 <= 0.5 and v2 <= 0.5 then
            for j = j0, j1 do
                local dx, dy = i0 * CHUNK + CHUNK / 2 - acx, j * CHUNK + CHUNK / 2 - acy
                local mx, my = p0x + dx * sxx + dy * syx, p0y + dx * sxy + dy * syy
                for i = i0, i1 do
                    -- 所在 chunk 改由下方琥珀標籤標示（中心常是玩家圖示，不再蓋一塊底墊）
                    if mx - hw >= 0 and mx + hw <= w and my - hh >= 0 and my + hh <= h
                        and not (i == pci and j == pcj) then
                        local key = i * 100000 + j -- |j| 遠小於 50000（B42 世界約 2500 chunk 寬）
                        local text = labelText[key]
                        if not text then
                            if labelCount >= LABEL_CACHE_MAX then labelText, labelW, labelCount = {}, {}, 0 end
                            text = i .. "," .. j
                            labelText[key] = text
                            labelCount = labelCount + 1
                        end
                        -- drawRect／drawTextCentre 的 Java 本體（ISUIElement.lua:1196／1286）
                        jo:DrawTextureScaledColor(nil, mx - hw, my - hh, hw * 2, hh * 2, 0, 0, 0, 0.45)
                        local ty = my - labelFontH * tz / 2 -- 上緣取整免點陣字模糊（座標已確認非負）
                        if tm then
                            -- 縮放版沒有置中多載：自己量字寬（依 chunk 快取）後走 DrawText(font, …, zoom, …)
                            -- （UIElement.java:178，ISUIElement.lua:1263 drawTextZoomed 的 Java 本體）
                            local lw = labelW[key]
                            if not lw then
                                lw = tm:MeasureStringX(UIFont.Small, text)
                                labelW[key] = lw
                            end
                            local tx = mx - lw * tz / 2
                            jo:DrawText(UIFont.Small, text, tx - tx % 1, ty - ty % 1, tz, 0.92, 0.92, 0.92, 0.9)
                        else
                            jo:DrawTextCentre(UIFont.Small, text, mx, ty - ty % 1, 0.92, 0.92, 0.92, 0.9)
                        end
                    end
                    mx, my = mx + ex, my + ey
                end
            end
        end
    end

    -- 5) 所在 chunk 外框＋標籤（編號與含端點座標範圍）：標籤掛在 chunk 下緣，出界改掛上緣。
    -- 文字與寬度依 chunk 快取在元件上（跨 chunk 才重算，同座標列 MISC-3 策略）
    if curVisible then
        jo:DrawLine(nil, k1x, k1y, k2x, k2y, 2, CUR_R, CUR_G, CUR_B, 0.95)
        jo:DrawLine(nil, k2x, k2y, k3x, k3y, 2, CUR_R, CUR_G, CUR_B, 0.95)
        jo:DrawLine(nil, k3x, k3y, k4x, k4y, 2, CUR_R, CUR_G, CUR_B, 0.95)
        jo:DrawLine(nil, k4x, k4y, k1x, k1y, 2, CUR_R, CUR_G, CUR_B, 0.95)
        if not wantText then return end
        local key = pci * 100000 + pcj
        if inner._minidoracatChunkKey ~= key then
            local x1, y1 = pci * CHUNK, pcj * CHUNK
            local text = getText("UI_MinidoracatMiniMap_ChunkInfo", pci, pcj,
                x1, x1 + CHUNK - 1, y1, y1 + CHUNK - 1)
            local tm = getTextManager()
            inner._minidoracatChunkKey = key
            inner._minidoracatChunkText = text
            inner._minidoracatChunkTextW = tm:MeasureStringX(UIFont.Small, text)
            inner._minidoracatChunkTextH = tm:getFontHeight(UIFont.Small)
        end
        local text = inner._minidoracatChunkText
        local tw, th = inner._minidoracatChunkTextW * tz, inner._minidoracatChunkTextH * tz
        local top, bottom = k1y, k1y
        if k2y < top then top = k2y elseif k2y > bottom then bottom = k2y end
        if k3y < top then top = k3y elseif k3y > bottom then bottom = k3y end
        if k4y < top then top = k4y elseif k4y > bottom then bottom = k4y end
        local lx = (k1x + k3x) / 2 - tw / 2 -- 平行四邊形中心＝對角中點
        local ly = bottom + 4
        if ly + th + 2 > h then ly = top - 4 - th end
        if lx + tw > w - 4 then lx = w - 4 - tw end
        if lx < 4 then lx = 4 end
        -- 取整免點陣字模糊；貼頂時 ly 可為負，Kahlua 的 % 朝零截斷只差 1px，stencil 已裁
        lx, ly = lx - lx % 1, ly - ly % 1
        jo:DrawTextureScaledColor(nil, lx - 4, ly - 2, tw + 8, th + 4, 0, 0, 0, 0.7)
        if tz == 1 then
            jo:DrawText(UIFont.Small, text, lx, ly, CUR_R, CUR_G, CUR_B, 1) -- ISUIElement.lua:1299
        else
            jo:DrawText(UIFont.Small, text, lx, ly, tz, CUR_R, CUR_G, CUR_B, 1) -- UIElement.java:178
        end
    end
end

-- 入口：選項關閉＝零成本；body 整段 pcall，stencil 無條件配對清除——漏 clear 會讓引擎
-- 全域 stencil 洩漏、當幀後續 UI 都被裁到地圖矩形（同 zone 填色 A1），錯誤再交回呼叫端 log-once
local function drawChunkGrid(inner)
    if not getBoolOption("ChunkGrid", false) then return end
    stencilOn = false
    local ok, err = pcall(drawChunkGridBody, inner)
    if stencilOn then
        stencilOn = false
        inner:clearStencilRect()
    end
    if not ok then error(err, 0) end
end

Core.drawChunkGrid = drawChunkGrid
