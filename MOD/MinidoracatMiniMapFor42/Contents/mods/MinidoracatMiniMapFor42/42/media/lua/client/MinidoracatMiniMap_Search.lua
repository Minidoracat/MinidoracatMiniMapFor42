-- MinidoracatMiniMap_Search.lua
-- 本檔範圍：地圖搜尋視窗（0.17.0）——輸入自動判別「座標 or 關鍵字」：
--   - 座標：整串只含數字與分隔符（, - 空白 . 與全形逗號）且抓得到 ≥2 個數字
--     ＝座標（支援 "12895,3499"、"12895 - 3499 - 0"、"10980,9679,0"；z 容忍
--     但忽略——地圖是 2D。負號當分隔符：世界座標恆正，同主檔 XY 鈕註記的
--     原版 teleport UI 慣例）
--   - 關鍵字：比對街道名（NavRoute 引擎抽取的翻譯後街名——LangFor42 中文街名
--     直接可搜；"KY-841" 含字母走關鍵字不會誤判座標）＋POI 類別名（20 類翻譯
--     名，命中即展開該類設施、依距玩家有界最近-N 選擇）
-- 結果動作：在大地圖顯示（ShowWorldMap 帶座標開圖，ISWorldMap.lua:1500，並落
-- Core.searchPing 由雙表面畫脈動標記）／設為導航目標（Core.navSetTarget→路線
-- 自動規劃）。
-- UI：ISPanel 自組＋家族圓角皮膚（Core.Skin，移植自 NoticeBoard 的 NBSkin；
-- moveWithMouse＝ISPanel 內建拖曳，ISPanel.lua:26-113）。載入序註記：本檔
-- 字母序在 _Skin.lua 之前——Core.Skin 一律於事件期（開窗/繪製）動態取用，
-- 缺席（貼圖壞/測試環境）時 Skin 自身退回直角、本檔另有 nil 防呆。
-- 效能紀律（review 定案）：doSearch 只在輸入/引擎狀態變化時跑（雙欄位 cache
-- key，零每幀配置）；結果列的右欄文字/寬度/類型標籤全在 doSearch 一次性預格式
-- 化，listDrawItem 每幀零配置、視窗外列早退。
-- 分割畫面（codex review）：視窗單例採 owner-transfer（同 _Settings 慣例）——
-- 他人開窗時轉移擁有者並重刷，不誤關；searchPing 帶 pn，僅擁有者的表面繪製。
-- 拆檔緣由：同 _Settings/_NavRoute（主檔 Kahlua 主 chunk locvar 上限）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

local MAX_STREET_RESULTS = 40
local MAX_POI_RESULTS = 30
local PING_MS = 12000

--------------------------------------------------------------------------------
-- 解析與搜尋（純函式）
--------------------------------------------------------------------------------
-- 座標判別：全串僅由數字/小數點/分隔符組成才視為座標（"1394號公路" 含中文、
-- "KY-841" 含字母→關鍵字）。回 x, y（floor 後整數）或 nil。
-- 全形逗號（U+FF0C）以碼位 65292 比對：Lua 字面量禁非 ASCII（AGENTS.md——
-- linked-mod fallback 讀檔走平台編碼，非 ASCII 字面量會炸成 U+FFFD）；
-- Kahlua 字串為 Java String（UTF-16 unit），string.byte 回 charAt 碼值，
-- BMP 內全形逗號恰為單 unit。string.byte 家規需 pcall 降級（原版無用例）
local SEP_CODES = { [9] = true, [32] = true, [44] = true, [45] = true, [46] = true, [65292] = true }

local COORD_MAX = 1e9 -- 世界座標合理上限（PZ 地圖座標 <10^5 量級；防 Infinity）

local function extractNums(text)
    local nums = {}
    for n in text:gmatch("%d+%.?%d*") do
        -- floor：家規慣例 %d 只餵整數（Kahlua %d 對真小數行為未實測；座標本為整數格）。
        -- 有限值檢查（codex review blocking）：超長數字串經 Double.parseDouble 會回
        -- Infinity，floor 不除——不擋會寫進持久 modData／分享封包並讓座標轉換出 NaN；
        -- v~=v 防 NaN、>=COORD_MAX 防 Infinity 與離譜值，命中即整串當關鍵字（回 nil）
        local v = math.floor(tonumber(n))
        if v ~= v or v >= COORD_MAX then return nil end
        nums[#nums + 1] = v
        if #nums >= 3 then break end
    end
    if #nums < 2 then return nil end
    return nums[1], nums[2]
end

local function parseCoords(text)
    if text:match("^[%d%s,%.%-]+$") then return extractNums(text) end -- ASCII 快路徑
    local ok, pass = pcall(function() -- 非純 ASCII：逐碼位驗證（數字 48-57 或分隔符白名單）
        for i = 1, #text do
            local b = string.byte(text, i)
            if not ((b >= 48 and b <= 57) or SEP_CODES[b]) then return false end
        end
        return true
    end)
    if not ok or not pass then return nil end
    return extractNums(text)
end

local function dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end

local function fmtDist(d)
    if d >= 1000 then return string.format("%.1fkm", d / 1000) end
    return string.format("%dm", math.floor(d + 0.5))
end

local function kindTag(kind)
    if kind == "coord" then return getText("UI_MinidoracatMiniMap_SearchKindCoord") end
    if kind == "street" then return getText("UI_MinidoracatMiniMap_SearchKindStreet") end
    return getText("UI_MinidoracatMiniMap_SearchKindPoi")
end

-- 有界最近-N 插入：維持 arr 依 d 升冪、長度 ≤ cap；比末位遠直接丟（剪枝）。
-- review 定案：先全配置再 O(n²) 全排序在大命中集（單字母命中多類、上千筆）
-- 會同步卡 UI 執行緒數十 ms；此法每筆 O(cap) 上限、無多餘配置
local function boundedInsert(arr, cap, entry)
    local n = #arr
    if n >= cap and entry.d >= arr[n].d then return end
    local i = n
    while i >= 1 and arr[i].d > entry.d do i = i - 1 end
    local last = n + 1
    if last > cap then last = cap end
    for j = last, i + 2, -1 do arr[j] = arr[j - 1] end
    if i + 1 <= cap then arr[i + 1] = entry end
end

-- 結果列最終化：座標取整＋右欄文字/寬度/類型標籤一次性預格式化
-- （listDrawItem 每幀直用，零配置）
local function finalizeItem(it)
    it.x = math.floor(it.x)
    it.y = math.floor(it.y)
    it.tag = kindTag(it.kind)
    it.right = string.format("(%d, %d)  %s", it.x, it.y, fmtDist(it.d))
    local tm = getTextManager()
    it.tagW = tm:MeasureStringX(UIFont.Small, it.tag)
    it.rightW = tm:MeasureStringX(UIFont.Small, it.right)
    return it
end

-- 結果收集：回陣列 { { kind="coord|street|poi", label=, x=, y=, d=, tag=, right=, ... } }
local function doSearch(text, px, py)
    local results = {}
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" then return results end
    local cx, cy = parseCoords(text)
    if cx then
        results[1] = finalizeItem({ kind = "coord",
            label = string.format("%d, %d", cx, cy),
            x = cx, y = cy, d = math.sqrt(dist2(px, py, cx, cy)) })
        return results
    end
    local q = text:lower()
    -- 街道名：有界最近-N（review：同名街跨城大量重複——抽取序截斷會把「離玩家
    -- 最近的那段」擠出清單，且介面右欄顯示距離、必須按距離組織）。
    -- st.low＝索引建立時預小寫（NavRoute 攤平，免每鍵 1100 次配置）
    local streets = Core.navStreetIndex and Core.navStreetIndex() or nil
    if streets then
        local hits = {}
        local seen = nil -- 首點精確鍵（引擎命中的街，烘焙英文項去重用；lazy 建）
        for i = 1, #streets do
            local st = streets[i]
            if st.low ~= "" and st.low:find(q, 1, true) then
                local d = math.sqrt(dist2(px, py, st.x, st.y))
                -- 剪枝早退：滿載且比末位遠→不配置 entry table（與 POI 分支對稱）
                if #hits < MAX_STREET_RESULTS or d < hits[#hits].d then
                    boundedInsert(hits, MAX_STREET_RESULTS, { kind = "street",
                        label = st.name, x = st.x, y = st.y, d = d })
                    seen = seen or {}
                    seen[math.floor(st.x) * 100000 + math.floor(st.y)] = true
                end
            end
        end
        -- 英文原名補充（2026-08-20 使用者回報搜 "will" 無結果）：LangFor42 等
        -- 翻譯 MOD 整份取代官方 streets.xml → 引擎索引只剩譯名；官方英文原名
        -- 由 gen_street_names.py 烘焙進 MinidoracatMiniMapStreetNames（shared
        -- 資料檔，首點與引擎索引同源）。譯名/原名天然互補（中文查引擎、英文查
        -- 本表）；無翻譯 MOD 環境兩邊同時命中同一條→首點精確鍵去重，引擎項
        -- 優先。表缺席（生成器沒跑）＝純引擎行為
        local en = MinidoracatMiniMapStreetNames
        if type(en) == "table" then
            for i = 1, #en do
                local e = en[i]
                if e.l:find(q, 1, true)
                    and not (seen and seen[e.x * 100000 + e.y]) then
                    local d = math.sqrt(dist2(px, py, e.x, e.y))
                    if #hits < MAX_STREET_RESULTS or d < hits[#hits].d then
                        boundedInsert(hits, MAX_STREET_RESULTS, { kind = "street",
                            label = e.n, x = e.x, y = e.y, d = d })
                    end
                end
            end
        end
        for i = 1, #hits do
            results[#results + 1] = finalizeItem(hits[i])
        end
    end
    -- POI 類別名：命中類別→有界最近-N 展開該類設施。錨點＝r[1] 矩形中心
    -- （MinidoracatMiniMapPOIData 消費契約：r 按面積排序、r[1] 為圖標錨點）
    local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    local data = MinidoracatMiniMapPOIData
    if type(cats) == "table" and type(data) == "table" then
        local allNames = {} -- 全類別譯名（地下關鍵字命中時查名用）
        local hitCats = {}
        local anyCat = false
        for key, def in pairs(cats) do
            local nm = def.nameKey and getText(def.nameKey) or key
            allNames[key] = nm
            if nm:lower():find(q, 1, true) then
                hitCats[key] = nm
                anyCat = true
            end
        end
        -- 「地下」關鍵字（2026-08-20 實測需求：搜「地下」應列出全部地下室設施）：
        -- 比對走**專用匹配鍵**（SearchBasementKey＝無標點核心詞「地下室」/
        -- "basement"）的**前綴語義**＋最小長度 2 unit——初版拿顯示後綴
        -- 「（地下室）」做反向子串，EN 搜街名的常見前綴 "st"/"b" 必誤觸灑出
        -- 62 筆地下設施（三 lane review 一致抓出）；前綴匹配「地下」「bas」
        -- 命中、"st"/"as"/單字元/括號全擋
        local baseCore = getText("UI_MinidoracatMiniMap_SearchBasementKey"):lower()
        local baseHit = #q >= 2 and baseCore:sub(1, #q) == q
        if anyCat or baseHit then
            local hits = {}
            for i = 1, #data do
                local e = data[i]
                local nm = hitCats[e.cat]
                    or (baseHit and e.u == 1 and allNames[e.cat] or nil)
                if nm and e.rn and e.rn >= 1 then
                    local r1 = e.r[1]
                    local ex, ey = r1.x + r1.w / 2, r1.y + r1.h / 2
                    local d = math.sqrt(dist2(px, py, ex, ey))
                    -- 剪枝早退：滿載且比末位遠→不配置 entry table 直接丟
                    if #hits < MAX_POI_RESULTS or d < hits[#hits].d then
                        -- 地下條目後綴（資料 u=1＝B42 basement）：地上是別的建築，
                        -- 不標會被當標錯（同圖標「↓」角標語義）
                        local label = (e.u == 1)
                            and (nm .. getText("UI_MinidoracatMiniMap_SearchBasement")) or nm
                        boundedInsert(hits, MAX_POI_RESULTS,
                            { kind = "poi", label = label, x = ex, y = ey, d = d })
                    end
                end
            end
            for i = 1, #hits do
                results[#results + 1] = finalizeItem(hits[i])
            end
        end
    end
    return results
end

--------------------------------------------------------------------------------
-- 搜尋視窗（單例＋owner-transfer；ISPanel 自組＋圓角皮膚）
--------------------------------------------------------------------------------
local searchWin = nil

local KIND_COLORS = {
    coord = { r = 1, g = 0.85, b = 0.4 },     -- 琥珀（同皮膚 ACCENT）
    street = { r = 0.05, g = 0.86, b = 1.0 }, -- 青（同路線色語）
    poi = { r = 0.3, g = 0.95, b = 0.4 },     -- 綠
}

-- 選中項防呆（review blocking：list:clear() 會把 selected 重設 1，而「載入中/
-- 無結果」info 列正好落在索引 1——不擋會把 nil 座標寫進 searchPing/navSetTarget，
-- 前者讓 drawSearchPing 每幀丟錯 12 秒、後者讓導航層靜默壞到手動清除）
local function winSelectedItem(win)
    local sel = win.list.selected
    local row = win.list.items and win.list.items[sel]
    local it = row and row.item or nil
    if not it or it.kind == "info" then return nil end
    if type(it.x) ~= "number" or type(it.y) ~= "number" then return nil end
    return it
end

-- 關窗統一走這裡（codex review blocking：只 hide/remove 不 unfocus 會讓
-- Core.currentTextEntryBox 殘留——UITextBox2.java:652 只有 unfocus() 清它、
-- UIManager.RemoveElement 不清——關窗後不可見輸入框仍攔截遊戲鍵盤）
local function closeWindow(win)
    if win.entry and win.entry.unfocus then win.entry:unfocus() end
    win:setVisible(false)
    win:removeFromUIManager()
end

local function winGoto(win)
    local it = winSelectedItem(win)
    if not it then return end
    -- 帶座標開大地圖（原版簽名 ShowWorldMap(playerNum, centerX, centerY, zoom)，
    -- ISWorldMap.lua:1500）；zoom 16＝街區級視野。落 ping＝雙表面脈動標記
    -- （繪製在主檔 drawNavTargets 尾，12 秒自動消失；pn＝僅擁有者表面畫）。
    -- 決策註記：直呼 ShowWorldMap 繞過原版 ToggleWorldMap 的 tooDarkToRead
    -- 閘門（ISWorldMap.lua:1585-1596）——刻意：搜尋跳圖屬 UI 導航動作，與本
    -- MOD XY 鈕/世界地圖入口同性質，不受黑暗閱讀判定限制
    local pn = win.playerNum or 0
    Core.searchPing = { pn = pn, x = it.x, y = it.y, untilMs = getTimestampMs() + PING_MS }
    ISWorldMap.ShowWorldMap(pn, it.x, it.y, 16)
end

local function winSetTarget(win)
    local it = winSelectedItem(win)
    if not it then return end
    if Core.navSetTarget then Core.navSetTarget(win.playerNum or 0, it.x, it.y) end
end

local function winRefresh(win, force)
    -- 引擎冷啟動／nodata 重試泵（每幀，prerender 呼叫）：沒設導航目標時 drawNavRoute
    -- 在 kick 前就 return，搜尋是唯一入口（codex review）。對**現行** live 表面各 kick 一次——小地圖以
    -- getPlayerMiniMap 取當下實例（Recreate 會換 inner，存快照會抱著死容器；原版
    -- 用例 ISMiniMap.lua:749）＋世界地圖單例；kickEngine 非 idle O(1) 早退、nodata
    -- per-inner 節流 1 秒，兩側都會被提交，滿側一補上即接手
    if Core.navKickEngine then
        local mm = getPlayerMiniMap(win.playerNum or 0)
        if mm and mm.inner then Core.navKickEngine(mm.inner) end
        if ISWorldMap_instance then Core.navKickEngine(ISWorldMap_instance) end
    end
    local text = win.entry:getInternalText() or ""
    -- cache key＝文字＋引擎狀態雙欄位（review：索引屬非同步建置，只鍵文字會在
    -- ready 後永遠停在「載入中」；欄位比較零每幀字串配置）
    local st = Core.navEngineState and Core.navEngineState() or "unknown"
    if not force and text == win._lastText and st == win._lastState then return end
    local playerObj = getSpecificPlayer(win.playerNum or 0)
    if not playerObj then return end -- 不寫 key：玩家回來後同 key 仍要能刷（review）
    win._lastText = text
    win._lastState = st
    win.list:clear()
    local results = doSearch(text, playerObj:getX(), playerObj:getY())
    if #results == 0 then
        if text ~= "" then
            -- failed／nodata＝不會自己變好（failed 終態；nodata 靠上方泵重試、
            -- 成功會換 state 觸發重刷）：顯示「無結果」而非永久裝載入中；
            -- 索引已到手（building 期即有）但查無同樣「無結果」
            local pending = (Core.navStreetIndex and Core.navStreetIndex() == nil)
                and (st == "idle" or st == "extracting" or st == "building")
            local msg = pending and getText("UI_MinidoracatMiniMap_SearchLoading")
                or getText("UI_MinidoracatMiniMap_SearchNoResult")
            win.list:addItem(msg, { kind = "info", label = msg })
        end
        return
    end
    for i = 1, #results do
        win.list:addItem(results[i].label, results[i])
    end
end

-- 清單項自繪：hover/選中圓角填色＋kind 徽章色點＋名稱＋右對齊座標與距離。
-- 每幀熱路徑：文字/寬度全用 doSearch 預格式化欄位，零配置；視窗外列早退
local function listDrawItem(self, y, item, alt)
    local hgt = self.itemheight
    -- 可見性早退（stencil 之外自己也省：捲出視窗的列不畫不量）
    local ys = self:getYScroll()
    if y + hgt < -ys or y > self.height - ys then return y + hgt end
    local it = item.item
    local Skin = Core.Skin
    -- hover 判定補原版兩道保護（ISScrollingListBox.lua:316——mouseoverselected
    -- 滑到捲軸/失焦時殘留，原版靠 isMouseOver 消殘影）
    local hovered = self.mouseoverselected == item.index and self:isMouseOver()
        and not self:isMouseOverScrollBar()
    local selected = self.selected == item.index
    if Skin then
        if selected then
            Skin.fill(self, 2, y + 1, self.width - 4, hgt - 2, Skin.COLORS.ROW_SELECTED)
        elseif hovered then
            Skin.fill(self, 2, y + 1, self.width - 4, hgt - 2, Skin.COLORS.ROW_HOVER)
        end
        if selected then -- 左緣琥珀選中條
            self:drawRect(2, y + 3, 3, hgt - 6, 0.9, 1, 0.85, 0.4)
        end
    elseif selected then
        self:drawRect(0, y, self.width, hgt, 0.15, 1, 1, 1)
    end
    local tx = 12
    local ty = y + self._minidoracatTextY -- 垂直置中偏移（建構時按字高算）
    if it and it.kind and it.kind ~= "info" then
        local kc = KIND_COLORS[it.kind] or KIND_COLORS.coord
        self:drawRect(tx, y + math.floor(hgt / 2) - 3, 6, 6, 1, kc.r, kc.g, kc.b)
        self:drawText(it.tag, tx + 12, ty, kc.r, kc.g, kc.b, 1, UIFont.Small)
        self:drawText(it.label, tx + 12 + it.tagW + 10, ty, 1, 1, 1, 1, UIFont.Small)
        self:drawText(it.right, self.width - it.rightW - 14, ty,
            0.62, 0.62, 0.62, 1, UIFont.Small)
    else
        self:drawText(item.text, tx, ty, 0.62, 0.62, 0.62, 1, UIFont.Small)
    end
    return y + hgt
end

local function styleButton(btn)
    btn.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
    btn.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.12 }
    btn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
end

local function createSearchWindow(pn)
    -- 尺寸隨 UI 字級（codex review：固定 px 在 1440p Auto 字級（2x 字型，
    -- Small/Medium 行高 26/33）必裁切；getFontHeight 同主檔 BUTTON_HGT 先例）
    local tm = getTextManager()
    local fhS = tm:getFontHeight(UIFont.Small)
    local fhM = tm:getFontHeight(UIFont.Medium)
    local titleH = math.max(30, fhM + 10)
    local entryH = math.max(24, fhS + 8)
    local rowH = math.max(24, fhS + 8)
    local btnH = math.max(28, fhS + 10)
    local pad = 10
    local w = math.max(420, 24 * fhS) -- 字級放大時等比加寬，右欄不擠壓名稱
    local h = 430 + (rowH - 24) * 4   -- 大字級補回部分清單可視列數
    local win = ISPanel:new(0, 0, w, h) -- 位置由 centerToPlayer 依 viewport 定
    win:initialise()
    win:instantiate()
    win.background = false      -- 背板由皮膚 prerender 自畫（圓角）
    win.moveWithMouse = true    -- ISPanel 內建拖曳（ISPanel.lua:26-113）
    win.playerNum = pn
    win._titleH = titleH
    -- 關閉鈕（右上，貼齊標題列高）
    win.closeBtn = ISButton:new(w - titleH + 4, 5, titleH - 10, titleH - 10, "X",
        win, closeWindow)
    win.closeBtn:initialise()
    styleButton(win.closeBtn)
    win:addChild(win.closeBtn)
    -- 輸入框（原版 ISTextEntryBox；setClearButton/getInternalText 原版用例
    -- ObjectViewer.lua:254/571；placeholder 走官方 API（ISTextEntryBox.lua:121-127，
    -- javaObject 未建時暫存、instantiate 後套用）——比自畫穩：不與元件自繪底板疊層）
    win.entry = ISTextEntryBox:new("", pad, titleH + pad, w - pad * 2, entryH)
    win.entry:initialise()
    win.entry:instantiate()
    if win.entry.setClearButton then win.entry:setClearButton(true) end
    if win.entry.setPlaceholderText then
        win.entry:setPlaceholderText(getText("UI_MinidoracatMiniMap_SearchHint"))
    end
    win.entry.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
    win.entry.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    win:addChild(win.entry)
    -- 結果清單
    local listY = titleH + pad + entryH + 8
    win.list = ISScrollingListBox:new(pad, listY, w - pad * 2, h - listY - btnH - pad * 2)
    win.list:initialise()
    win.list:instantiate()
    win.list.itemheight = rowH
    win.list.font = UIFont.Small
    win.list.drawBorder = false
    win.list.backgroundColor = { r = 0, g = 0, b = 0, a = 0.25 }
    win.list._minidoracatTextY = math.floor((rowH - fhS) / 2) -- 文字垂直置中
    win.list.doDrawItem = listDrawItem
    win:addChild(win.list)
    win.list:setOnMouseDoubleClick(win, function(target)
        winGoto(target)
    end)
    -- 動作鈕：在大地圖顯示／設為導航目標
    local btnW = math.floor((w - pad * 3) / 2)
    win.gotoBtn = ISButton:new(pad, h - btnH - pad, btnW, btnH,
        getText("UI_MinidoracatMiniMap_SearchGoto"), win, winGoto)
    win.gotoBtn:initialise()
    styleButton(win.gotoBtn)
    win:addChild(win.gotoBtn)
    win.targetBtn = ISButton:new(pad * 2 + btnW, h - btnH - pad, btnW, btnH,
        getText("UI_MinidoracatMiniMap_SearchSetTarget"), win, winSetTarget)
    win.targetBtn:initialise()
    styleButton(win.targetBtn)
    win:addChild(win.targetBtn)
    win._lastText = nil
    win._lastState = nil
    -- 皮膚 prerender：圓角底板＋邊框＋上圓角標題列＋標題字
    win.prerender = function(self)
        local Skin = Core.Skin
        if Skin then
            Skin.fill(self, 0, 0, self.width, self.height, Skin.COLORS.BG_PANEL)
            Skin.fill(self, 0, 0, self.width, self._titleH, Skin.COLORS.TITLEBAR_FILL, true)
            Skin.border(self, 0, 0, self.width, self.height, Skin.COLORS.BORDER)
        else
            self:drawRect(0, 0, self.width, self.height, 0.8, 0, 0, 0)
            self:drawRectBorder(0, 0, self.width, self.height, 1, 0.4, 0.4, 0.4)
        end
        local title = getText("UI_MinidoracatMiniMap_SearchTitle")
        local tw = getTextManager():MeasureStringX(UIFont.Medium, title)
        self:drawText(title, math.floor((self.width - tw) / 2), 6, 1, 1, 1, 1, UIFont.Medium)
        winRefresh(self, false)
    end
    return win
end

-- 置中到該玩家的 viewport（分割畫面各半邊；單人＝全螢幕。API 出處：
-- getPlayerScreenLeft/Top/Width/Height 原版用例 ISMiniMap.lua:701-702、
-- 本 repo _Settings.lua:1266-1267 同慣例）
local function centerToPlayer(win, pn)
    local sx = getPlayerScreenLeft(pn) or 0
    local sy = getPlayerScreenTop(pn) or 0
    local sw = getPlayerScreenWidth(pn) or getCore():getScreenWidth()
    local sh = getPlayerScreenHeight(pn) or getCore():getScreenHeight()
    win:setX(sx + math.floor((sw - win.width) / 2))
    win:setY(sy + math.floor((sh - win.height) / 2))
end

-- 開關搜尋視窗（按鈕/右鍵選單入口共用）。引擎冷啟動由 winRefresh 的 live 表面泵
-- 負責（開窗後首個 prerender 即 kick），本函式不再收 inner。
-- 分割畫面：同人再按＝關；他人按＝owner-transfer 重刷（同 _Settings 慣例），
-- 不誤關別人的視窗
Core.toggleSearchWindow = function(pn)
    pn = pn or 0
    if searchWin and searchWin:isVisible() then
        if (searchWin.playerNum or 0) == pn then
            closeWindow(searchWin)
        else
            -- 轉移擁有者（grok review：只換 pn 不重定位會停在原主半邊，新主
            -- 看似沒反應）：距離/結果按新主重算＋搬到新主 viewport＋置頂
            searchWin.playerNum = pn
            searchWin._lastText = nil
            searchWin._lastState = nil
            centerToPlayer(searchWin, pn)
            searchWin:bringToTop()
            if searchWin.entry and searchWin.entry.focus then
                searchWin.entry:focus() -- 轉移即聚焦（同開窗路徑；點鈕時引擎已 unfocus）
            end
        end
        return
    end
    if not searchWin then
        searchWin = createSearchWindow(pn)
    end
    searchWin.playerNum = pn
    centerToPlayer(searchWin, pn) -- 每次開窗回到該玩家 viewport 中央
    searchWin._lastText = nil -- 重開必刷新（玩家位置/引擎狀態可能已變）
    searchWin._lastState = nil
    searchWin:addToUIManager()
    searchWin:setVisible(true)
    if searchWin.entry and searchWin.entry.focus then
        searchWin.entry:focus()
    end
end

-- 搜尋 ping 繪製（主檔 drawNavTargets 內動態呼叫——ping 落點與繪製同住本檔：
-- 主檔主 chunk locvar 已頂 Kahlua 200 上限（LexState actvar[200] 固定陣列、
-- 頂層 local 永不出 scope），不得再增頂層 local，遊戲內實爆記錄 2026-08-20）。
-- 雙相位擴散菱形＋中心準星，12 秒自動失效；菱形（4 線）代圓：引擎無圓弧 API；
-- 金色同自己目標旗。小地圖與世界地圖（Core.drawNavTargets 共用）雙表面同畫
Core.drawSearchPing = function(inner, mapAPI)
    local ping = Core.searchPing
    if not ping then return end
    -- 載荷防呆（review：info 列誤選曾可寫入 nil 座標——來源已擋，此為第二道；
    -- 壞載荷直接清除免每幀重驗）
    if type(ping.x) ~= "number" or type(ping.y) ~= "number"
        or type(ping.untilMs) ~= "number" then
        Core.searchPing = nil
        return
    end
    -- 分割畫面：僅擁有者（發起搜尋的 pn）的小地圖/世界地圖畫（codex review：
    -- 全域單載荷不過濾會畫到別人表面）
    if (ping.pn or 0) ~= (inner.playerNum or 0) then return end
    local now = getTimestampMs()
    if now >= ping.untilMs then
        Core.searchPing = nil
        return
    end
    local ux = mapAPI:worldToUIX(ping.x, ping.y)
    local uy = mapAPI:worldToUIY(ping.x, ping.y)
    -- 視野外整組跳過（菱形半徑上限 28，留 40px 緩衝）
    if ux < -40 or uy < -40 or ux > inner.width + 40 or uy > inner.height + 40 then return end
    for k = 0, 1 do
        local phase = ((now / 1100) + k * 0.5) % 1
        local rad = 6 + phase * 22
        local a = 0.85 * (1 - phase)
        inner:drawLine(nil, ux - rad, uy, ux, uy - rad, 2, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux, uy - rad, ux + rad, uy, 2, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux + rad, uy, ux, uy + rad, 2, a, 1, 0.85, 0.2)
        inner:drawLine(nil, ux, uy + rad, ux - rad, uy, 2, a, 1, 0.85, 0.2)
    end
    inner:drawRect(ux - 2, uy - 2, 4, 4, 1, 1, 0.85, 0.2)
    inner:drawLine(nil, ux - 9, uy, ux - 4, uy, 2, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux + 4, uy, ux + 9, uy, 2, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux, uy - 9, ux, uy - 4, 2, 0.9, 1, 0.85, 0.2)
    inner:drawLine(nil, ux, uy + 4, ux, uy + 9, 2, 0.9, 1, 0.85, 0.2)
end

Events.OnGameStart.Add(function()
    -- PZ 同程序回主選單再進另一存檔 client Lua 不重載（同 _NavRoute 引擎重置
    -- 慣例）：舊 searchWin 掛在已清空的 UIManager 上、isVisible 殘 true，會讓
    -- 新世界首次 toggle 走關閉分支（按鈕看似壞掉）；直接棄置由 GC 收、再開重建。
    -- searchPing 一併清（12 秒牆鐘雖會自然過期，跨檔殘留座標無意義）
    -- 棄置前先解焦（codex/claude review：entry 若仍聚焦，Core.currentTextEntryBox
    -- 指向死輸入框、跨存檔攔鍵盤——UITextBox2.java:652 只有 unfocus() 清它）；
    -- 不走 closeWindow：對已清空的 UIManager 呼 removeFromUIManager 風險較高
    if searchWin and searchWin.entry and searchWin.entry.unfocus then
        pcall(function() searchWin.entry:unfocus() end)
    end
    searchWin = nil
    Core.searchPing = nil
end)
