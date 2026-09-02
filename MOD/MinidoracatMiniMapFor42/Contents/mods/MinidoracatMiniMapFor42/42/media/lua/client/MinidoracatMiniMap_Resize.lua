-- MinidoracatMiniMap_Resize.lua
-- 本檔範圍：小地圖邊緣拖曳縮放（熱區判定／等比與單軸夾限／CustomSize 回寫／實例與
-- class hook 安裝）、HUD 視覺微調（外框調色 chromeTintBorder、角落括號與把手、
-- ISMiniMapOuter prerender/render wrap、標題列鎖定、-debug 警告的繪製呼叫）、
-- 自訂鍵位（OnGameBoot 註冊、開關小地圖與穿透熱鍵）。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore；本檔載入期只讀取其「一次性賦值」的穩定引用。
-- 例外：RESIZE_MIN 是**可變**值（主檔 raiseResizeMinForButtons／installMinidoracatButtons
-- 依字級抬高），故不取別名、每次讀 Core.RESIZE_MIN 取即時值。debugWarn 留在主檔
-- （_FloatIcon.lua 載入期取 Core.debugWarn 別名，而 _FloatIcon 先於本檔載入）。
-- 主檔用本檔的三個入口（InitPlayer 對 bottomPanel 實例補掛 installResizeHooks、
-- installMinidoracatButtons 實例 prerender 的 chromeTintBorder、_Ghost 的 cancelResize）
-- 一律呼叫時查 Core.*＋nil 防呆；_FloatIcon 的 onClick 於 ensureFloatIcon（事件時）取
-- Core.togglePlayerMiniMap。
-- 拆檔緣由（2026-09-03）：主檔主 chunk locvar 134→116，段內程式碼除 RESIZE_MIN→
-- Core.RESIZE_MIN 外逐位元不變。本段無離線測試切片。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- 主檔共用成員（皆為主檔載入期一次性賦值的穩定引用）
local modOptions = Core.modOptions -- 無 PZAPI 時為 nil：縮放不啟用（無處持久化）
local getBoolOption = Core.getBoolOption
local resizeMax = Core.resizeMax
local debugWarn = Core.debugWarn
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

local RESIZE_EDGE = 8         -- 邊緣熱區厚度（px）
-- 前置宣告（本體在下方；段內有先呼叫後定義的引用，沿用主檔原前置宣告語意）
local installResizeHooks
local cancelResize
local chromeTintBorder

--------------------------------------------------------------------------------
-- 邊緣拖曳縮放 + HUD 視覺微調
-- 事件路由（UIElement.java:1015 onMouseDown：1047-1057 先讓子元件消化、
-- 沒人消化才輪到自己的 Lua handler 1096）：RESIZE_EDGE=8 熱區與卡片外框
-- CHROME_BORDER=8 同寬，左右/上下熱區大多落在 outer 自己的邊框環上；但
-- adorned（滑鼠在圖上，正是會拖曳的時刻）時上緣是 titleBar、下緣熱區
-- 與 bottomPanel 相接，inner 亦可能吃到深入的角落熱區——三個 class 的
-- 滑鼠事件仍須全部 hook（歷史前提「2px 環」時代如此，8px 後同樣成立）。
-- 故共用一套熱區判定（outer 區域座標），hook ISMiniMapOuter / ISMiniMapInner /
-- ISMiniMapTitleBar 三個 class 的滑鼠事件（wrap 保留原行為；拖曳用 setCapture
-- 續收 Outside 事件，同 titleBar 做法 ISMiniMap.lua:367）。
-- 拖曳中只畫預覽外框，放開才以最終尺寸重建（走 InitPlayer wrapper 的
-- 自訂尺寸路徑），避免每幀重排版。
--------------------------------------------------------------------------------

local BRACKET_LEN = 14          -- 角落括號長度（px）
local BRACKET_THICK = 2         -- 角落括號粗細（px）
local HANDLE_ALPHA_IDLE = 0.35  -- 把手平時透明度（半透明白）
local HANDLE_ALPHA_HOVER = 0.9  -- 把手 hover／拖曳中透明度（PZ 改不了系統游標，靠這個給回饋）

local resizeState -- 進行中的拖曳（同時只會有一筆）：{ outer, edges, startMX, startMY, rect0, adornExtra, adorned, preview }

-- 外框邊色每幀調色（穿透琥珀＝主提示；hover/拖曳亮階）：抽成單一實作供
-- 兩處呼叫——class 層 prerender wrap（兜底：未走 installMinidoracatButtons
-- 的實例）與皮膚化實例 prerender（會遮蔽 class wrap，見 install 尾端註解）。
-- 皮膚 border 直讀 borderColor，調色先於繪製即生效
chromeTintBorder = function(outer)
    if getBoolOption("GhostMode", false) then
        -- 穿透中：琥珀邊框＝「看得到摸不到」主提示（mod 琥珀慣例），不做 hover 變化
        outer.borderColor.r, outer.borderColor.g, outer.borderColor.b = 1, 0.85, 0.4
    else
        local hover = outer:isMouseOver() or (resizeState ~= nil and resizeState.outer == outer)
        local v = hover and 0.55 or 0.4
        outer.borderColor.r, outer.borderColor.g, outer.borderColor.b = v, v, v
    end
end

-- 以 outer 區域座標判定邊緣熱區；回傳 {l,r,t,b} 布林表（角落＝兩者皆真），不在熱區回 nil
local function hitResizeEdge(outer, ox, oy)
    if getBoolOption("LockPosition", false) then return nil end -- 鎖定＝停用邊緣縮放
    if ox < 0 or oy < 0 or ox > outer.width or oy > outer.height then return nil end
    local e = {
        l = ox <= RESIZE_EDGE,
        r = ox >= outer.width - RESIZE_EDGE,
        t = oy <= RESIZE_EDGE,
        b = oy >= outer.height - RESIZE_EDGE,
    }
    if e.l or e.r or e.t or e.b then return e end
    return nil
end

local function startResize(outer, edges, el)
    -- 幾何全用拖曳起點快照＋全域滑鼠座標（getMouseX/getMouseY 全域，
    -- ISUIElement:getMouseX 內部同源 ISUIElement.lua:339-343），
    -- 不受拖曳中 adornments（titleBar/bottomPanel）掀開收合影響
    local adorned = outer.titleBar ~= nil and outer.titleBar:isVisible()
    resizeState = {
        outer = outer,
        edges = edges,
        el = el, -- 起始捕捉的元件（cancelResize 清 capture/旗標用）
        startMX = getMouseX(),
        startMY = getMouseY(),
        rect0 = { x = outer:getAbsoluteX(), y = outer:getAbsoluteY(), w = outer.width, h = outer.height },
        -- 展開狀態的外框比基準尺寸高 titleBar + 1px + bottomPanel
        -- （setAdornmentsVisible 幾何，ISMiniMap.lua:479-497）
        adornExtra = adorned and (outer.titleBar.height + 1 + outer.bottomPanel.height) or 0,
        adorned = adorned,
        preview = { x = 0, y = 0, w = 0, h = 0 },
    }
    local p, r = resizeState.preview, resizeState.rect0
    p.x, p.y, p.w, p.h = r.x, r.y, r.w, r.h
end

local function updateResize()
    local st = resizeState
    if not st then return end
    local dx = getMouseX() - st.startMX
    local dy = getMouseY() - st.startMY
    local r0, e = st.rect0, st.edges
    local maxWH = resizeMax(st.outer.playerNum)
    local x, y, w, h = r0.x, r0.y, r0.w, r0.h
    if (e.l or e.r) and (e.t or e.b) then
        -- 角落＝等比縮放（問題 B）：以拖曳起點外框長寬比為基準，取對角位移的
        -- 主導軸（往外拖為正的增量中 |絕對值| 較大者）算比例，兩軸同乘
        local dw = e.l and -dx or dx
        local dh = e.t and -dy or dy
        local s
        if math.abs(dw) >= math.abs(dh) then
            s = (r0.w + dw) / r0.w
        else
            s = (r0.h + dh) / r0.h
        end
        -- 夾限作用在「比例」而非個別軸，兩軸夾完仍保持等比
        -- （寬限 [Core.RESIZE_MIN, maxWH]；高含 adornments 增量再夾）
        local sMin = math.max(Core.RESIZE_MIN / r0.w, (Core.RESIZE_MIN + st.adornExtra) / r0.h)
        local sMax = math.min(maxWH / r0.w, (maxWH + st.adornExtra) / r0.h)
        s = math.max(sMin, math.min(sMax, s))
        w = r0.w * s
        h = r0.h * s
    else
        -- 單邊＝單軸自由縮放；拖哪邊動哪邊
        if e.l then w = w - dx elseif e.r then w = w + dx end
        if e.t then h = h - dy elseif e.b then h = h + dy end
        -- 夾限作用在「基準尺寸」（高度先扣 adornments 增量）
        w = math.max(Core.RESIZE_MIN, math.min(maxWH, w))
        h = math.max(Core.RESIZE_MIN + st.adornExtra, math.min(maxWH + st.adornExtra, h))
    end
    if e.l then x = r0.x + r0.w - w end -- 拖左緣：右緣錨定不動
    if e.t then y = r0.y + r0.h - h end -- 拖上緣：下緣錨定不動
    local p = st.preview
    p.x, p.y, p.w, p.h = x, y, w, h
end

local function endResize()
    local st = resizeState
    resizeState = nil
    if not st or not modOptions then return end
    local outer = st.outer
    local p = st.preview
    -- 取整：座標運算可能帶小數，寫入「寬x高」欄位須為整數（解析端只認 %d+）
    local baseW = math.floor(p.w + 0.5)
    local baseH = math.floor(p.h - st.adornExtra + 0.5)
    if baseW == st.rect0.w and baseH == st.rect0.h - st.adornExtra then return end -- 尺寸沒變，不重建
    if not getPlayerMiniMap(outer.playerNum) then return end -- Recreate 無 nil 防呆（AGENTS.md），先查
    local opt = modOptions:getOption("CustomSize")
    if not opt then return end
    -- 寫入自訂尺寸並立即落地 ModOptions.ini（PZAPI.ModOptions:save()＝ModOptions.lua:259）
    opt:setValue(baseW .. "x" .. baseH)
    PZAPI.ModOptions:save()
    -- 重建會重錨右下（AGENTS.md 已知行為）。若位置是使用者拖過的
    -- （userPosition 旗標，版面存讀同用 ISMiniMap.lua:660-670），重建後
    -- 還原成預覽框位置；baseY 是「收合狀態」的 y——收合時要加回 titleBar 高
    -- （展開時 setY(y - titleBar.height)，ISMiniMap.lua:487）。沒拖過就讓原版
    -- 重錨右下，視覺上與拖曳前一致（右下錨點本就不動）。
    local wasUserPosition = outer.userPosition
    local baseX = p.x
    local baseY = st.adorned and (p.y + outer.titleBar.height) or p.y
    ISMiniMap.Recreate(outer.playerNum) -- 走上方 hook 的 InitPlayer 自訂尺寸路徑
    local mm = getPlayerMiniMap(outer.playerNum)
    if mm and wasUserPosition then
        mm.userPosition = true
        mm:setX(baseX)
        -- 「永遠顯示」模式下重建後即是展開狀態，展開 y = 收合 y - titleBar 高
        if mm.titleBar and mm.titleBar:isVisible() then
            mm:setY(baseY - mm.titleBar.height)
        else
            mm:setY(baseY)
        end
    end
end

-- 取消進行中的拖曳並清理捕捉旗標（小地圖在拖曳中被移除——開關快捷鍵/輪盤選單
-- Toggle——時 mouse up 永遠不會送達，不清會殘留「沒按鍵也跟著滑鼠縮放」的幽靈狀態）
function cancelResize()
    local st = resizeState
    resizeState = nil
    if st and st.el then
        st.el._minidoracatResizing = nil
        pcall(function() st.el:setCapture(false) end)
    end
end

-- 在指定 class（或實例——bottomPanel 是裸 ISPanel 只能掛實例）上包 resize
-- 滑鼠處理；toOuter 從該元件取得 outer。非熱區／非拖曳時一律走原 handler。
function installResizeHooks(class, toOuter)
    local origDown = class.onMouseDown
    function class:onMouseDown(x, y)
        if modOptions and not resizeState then -- 無 PZAPI（無法持久化）就不啟用縮放
            local outer = toOuter(self)
            if outer then
                -- 換算成 outer 區域座標（getAbsoluteX 用例 ISMiniMap.lua:287）
                local ox = x + self:getAbsoluteX() - outer:getAbsoluteX()
                local oy = y + self:getAbsoluteY() - outer:getAbsoluteY()
                local edges = hitResizeEdge(outer, ox, oy)
                if edges then
                    startResize(outer, edges, self)
                    self._minidoracatResizing = true
                    self:setCapture(true) -- 拖出元件外仍收 Move/Up（setCapture＝ISUIElement.lua:588）
                    return true -- 消化事件：不進原版（inner 地圖拖曳／titleBar 移動）
                end
            end
        end
        if origDown then return origDown(self, x, y) end
    end

    local origMove = class.onMouseMove
    function class:onMouseMove(dx, dy)
        if self._minidoracatResizing then
            updateResize()
            return true
        end
        if origMove then return origMove(self, dx, dy) end
    end

    local origMoveOutside = class.onMouseMoveOutside
    function class:onMouseMoveOutside(dx, dy)
        if self._minidoracatResizing then
            updateResize()
            return true
        end
        if origMoveOutside then return origMoveOutside(self, dx, dy) end
    end

    local function finishResize(el)
        el._minidoracatResizing = nil
        el:setCapture(false)
        endResize() -- 內含 Recreate，舊元件（含 el）之後被丟棄
        return true
    end

    local origUp = class.onMouseUp
    function class:onMouseUp(x, y)
        if self._minidoracatResizing then return finishResize(self) end
        if origUp then return origUp(self, x, y) end
    end

    local origUpOutside = class.onMouseUpOutside
    function class:onMouseUpOutside(x, y)
        if self._minidoracatResizing then return finishResize(self) end
        if origUpOutside then return origUpOutside(self, x, y) end
    end
end

-- 鎖定位置：擋標題列拖曳移動（原版 onMouseDown 起拖，ISMiniMap.lua:363-369）；
-- 邊緣縮放由 hitResizeEdge 開頭的鎖定檢查一併停用。回 true 消化事件，
-- 避免點擊落到 outer 觸發別的行為。
if ISMiniMapTitleBar and ISMiniMapTitleBar.onMouseDown then
    local originalTitleBarMouseDown = ISMiniMapTitleBar.onMouseDown
    function ISMiniMapTitleBar:onMouseDown(x, y)
        if getBoolOption("LockPosition", false) then return true end
        return originalTitleBarMouseDown(self, x, y)
    end
end

-- 點擊小地圖不再開世界地圖（預設）：原版 onMouseUp 無拖曳＝ToggleWorldMap
-- （ISMiniMap.lua:239-245）。選項 ClickOpenWorldMap 開啟時走原版。
-- 必須放在 installResizeHooks 之前 wrap：縮放 hook 要包在最外層（先吃縮放收尾，
-- 非縮放路徑才會落到這裡）。onMouseUpOutside 原版轉呼叫 onMouseUp（:247-249），同受控。
if ISMiniMapInner and ISMiniMapInner.onMouseUp then
    local originalInnerMouseUp = ISMiniMapInner.onMouseUp
    function ISMiniMapInner:onMouseUp(x, y)
        -- 拖曳自由查看：拖過＝停留在拖到的位置（下方 prerenderHack wrap 據
        -- 此旗標暫停回中）；點擊（無拖曳）＝回到玩家。選項關閉＝原版放開即回中
        if self.dragging and getBoolOption("FreeLook", true) then
            self._minidoracatFreelook = self.dragMoved or nil
        end
        if getBoolOption("ClickOpenWorldMap", false) then
            return originalInnerMouseUp(self, x, y)
        end
        self.dragging = false -- 原版拖曳收尾（ISMiniMap.lua:240-241），僅略過 ToggleWorldMap
    end
end

-- 自由查看的「停留」本體：原版 prerenderHack 每幀把地圖回中到玩家/載具
-- （ISMiniMap.lua:214-225，拖曳中才暫停）——自由查看旗標亮著就整段跳過
if ISMiniMapInner and ISMiniMapInner.prerenderHack then
    local originalPrerenderHack = ISMiniMapInner.prerenderHack
    function ISMiniMapInner:prerenderHack()
        if self._minidoracatFreelook and getBoolOption("FreeLook", true) then return end
        originalPrerenderHack(self)
    end
end

if ISMiniMapOuter and ISMiniMapInner and ISMiniMapTitleBar then
    installResizeHooks(ISMiniMapOuter, function(el) return el end)
    installResizeHooks(ISMiniMapInner, function(el) return el.parent end)
    installResizeHooks(ISMiniMapTitleBar, function(el) return el.miniMap end)
    -- bottomPanel 是裸 ISPanel 實例，在 InitPlayer hook 內逐實例補掛（見上方）

    -- 拖曳中小地圖被 Toggle 移除（開關快捷鍵/世界地圖輪盤）→ mouse up 收不到，
    -- 先取消拖曳再走原版，避免幽靈縮放狀態
    if ISMiniMap and ISMiniMap.ToggleMiniMap then
        local originalToggleMiniMap = ISMiniMap.ToggleMiniMap
        function ISMiniMap.ToggleMiniMap(playerNum)
            if resizeState then cancelResize() end
            return originalToggleMiniMap(playerNum)
        end
    end
end

if ISMiniMapOuter and ISMiniMapOuter.prerender and ISMiniMapOuter.render then
    -- HUD 微調：整體 hover 時外框亮度 0.4→0.55（原版邊框色＝ISMiniMap.lua:676；
    -- prerender 以 borderColor 畫框＝ISMiniMap.lua:463）。不動背景、不加特效，
    -- 維持原版 OLED 深色高對比風格。
    local originalOuterPrerender = ISMiniMapOuter.prerender
    function ISMiniMapOuter:prerender()
        chromeTintBorder(self)
        originalOuterPrerender(self)
    end

    -- 角落括號＋邊緣亮條＋拖曳預覽框。掛 render：UIElement.java:1609 的 Lua render
    -- 在子元件（1604）之後呼叫，畫在整個小地圖最上層。
    local originalOuterRender = ISMiniMapOuter.render
    function ISMiniMapOuter:render()
        originalOuterRender(self)
        debugWarn.draw(self) -- -debug 專屬警告條（非 debug 一個布林即返回）
        if not modOptions then return end -- 縮放未啟用就不畫把手
        local st = (resizeState ~= nil and resizeState.outer == self) and resizeState or nil
        local hoverEdges = nil
        if st then
            hoverEdges = st.edges
        elseif self:isMouseOver() then
            hoverEdges = hitResizeEdge(self, self:getMouseX(), self:getMouseY())
        end
        -- 把手只在 adornments 展開（滑鼠在小地圖上）或拖曳中顯示，平常零干擾；
        -- 鎖定時縮放已停用（hitResizeEdge 回 nil），括號一併不畫免誤導
        if (st or (self.titleBar and self.titleBar:isVisible()))
            and not getBoolOption("LockPosition", false) then
            local w, h = self.width, self.height
            local L, T = BRACKET_LEN, BRACKET_THICK
            local aTL = (hoverEdges and (hoverEdges.l or hoverEdges.t)) and HANDLE_ALPHA_HOVER or HANDLE_ALPHA_IDLE
            local aTR = (hoverEdges and (hoverEdges.r or hoverEdges.t)) and HANDLE_ALPHA_HOVER or HANDLE_ALPHA_IDLE
            local aBL = (hoverEdges and (hoverEdges.l or hoverEdges.b)) and HANDLE_ALPHA_HOVER or HANDLE_ALPHA_IDLE
            local aBR = (hoverEdges and (hoverEdges.r or hoverEdges.b)) and HANDLE_ALPHA_HOVER or HANDLE_ALPHA_IDLE
            self:drawRect(0, 0, L, T, aTL, 1, 1, 1)         -- 左上括號
            self:drawRect(0, 0, T, L, aTL, 1, 1, 1)
            self:drawRect(w - L, 0, L, T, aTR, 1, 1, 1)     -- 右上括號
            self:drawRect(w - T, 0, T, L, aTR, 1, 1, 1)
            self:drawRect(0, h - T, L, T, aBL, 1, 1, 1)     -- 左下括號
            self:drawRect(0, h - L, T, L, aBL, 1, 1, 1)
            self:drawRect(w - L, h - T, L, T, aBR, 1, 1, 1) -- 右下括號
            self:drawRect(w - T, h - L, T, L, aBR, 1, 1, 1)
            if hoverEdges then -- hover 的邊畫亮條
                if hoverEdges.l then self:drawRect(0, 0, 2, h, HANDLE_ALPHA_HOVER, 1, 1, 1) end
                if hoverEdges.r then self:drawRect(w - 2, 0, 2, h, HANDLE_ALPHA_HOVER, 1, 1, 1) end
                if hoverEdges.t then self:drawRect(0, 0, w, 2, HANDLE_ALPHA_HOVER, 1, 1, 1) end
                if hoverEdges.b then self:drawRect(0, h - 2, w, 2, HANDLE_ALPHA_HOVER, 1, 1, 1) end
            end
        end
        if st then -- 拖曳中只畫預覽外框（drawRectBorder 用例 ISMiniMap.lua:474）
            local px = st.preview.x - self:getAbsoluteX()
            local py = st.preview.y - self:getAbsoluteY()
            self:drawRectBorder(px, py, st.preview.w, st.preview.h, HANDLE_ALPHA_HOVER, 1, 1, 1)
            self:drawRectBorder(px + 1, py + 1, st.preview.w - 2, st.preview.h - 2, 0.4, 1, 1, 1)
        end
    end
end

-- 快捷鍵：小地圖開關（選項 → 按鍵綁定 → [MinidoracatMiniMap] 可改鍵）。
-- 預設 /（SLASH，M 鍵右方——大地圖 M、小地圖 /）：原版 keyBinding.lua 未綁定
-- （含裸數字掃描）、引擎 Java 層無硬編碼、本機 213 個 Workshop MOD 與 keysB42.ini
-- 全綁定掃描空閒；顯示名稱走 glfwGetKeyName＝「/」無歧義；文字輸入期間引擎不派送
-- 綁定（GameKeyboard 以 isDoingTextEntry 抑制）；scancode 按實體位置、跨佈局穩定。
-- 否決紀錄：HOME＝debug 引擎隱藏熱鍵（IsoCell.render 切換
-- PerformanceSettings.fboRenderChunk，FPS 砍半＋積雪外觀變，見 debugWarn.draw）；
-- K＝原版「Display FPS」（keyBinding.lua:199 以裸數字 37 註冊，掃 KEY_* 常數抓不到）；
-- 0＝顯示字元在 UI 字型下似字母 o（實測回饋）；F7/F8/F9＝debug 裸鍵編輯器
-- （載具/世界地圖/接縫，IngameState.java:1398/1424/1431）；F12 撞 Steam 截圖；
-- N 撞 StartVehicleEngine；9 被 Bandits Week One 事件鍵使用。
-- ToggleMiniMap 自帶防呆：沙盒未開 AllowMiniMap 時 getPlayerMiniMap 為 nil、直接略過。
local function initBinds()
    table.insert(keyBinding, { value = "[MinidoracatMiniMap]" })
    table.insert(keyBinding, { value = "MinidoracatMiniMap_Toggle", key = Keyboard.KEY_SLASH })
    -- 穿透模式預設 '（APOSTROPHE）：同規格四關驗證全空閒——引擎 Java 硬編碼
    -- （KEY_APOSTROPHE 僅常數定義、裸 40 之 isKeyDown 系 0 命中）、本機 275 個
    -- Workshop MOD 6773 個 lua 零綁定、keysB42.ini 無 key:40/altCode:40、
    -- vanilla Lua 全樹零使用；glfwGetKeyName 顯示「'」無歧義
    table.insert(keyBinding, { value = "MinidoracatMiniMap_Ghost", key = Keyboard.KEY_APOSTROPHE })
end
Events.OnGameBoot.Add(initBinds)

-- 開關小地圖（快捷鍵與浮動圖標共用入口；ponytail: 只處理 player 0，同 modOptions:apply）
local function togglePlayerMiniMap()
    if not (ISMiniMap and ISMiniMap.ToggleMiniMap) then return end
    if not getSpecificPlayer(0) then return end -- 主選單等無玩家情境
    -- 不受沙盒 AllowMiniMap 限制：原版沒建小地圖時（getPlayerMiniMap 為 nil）
    -- 照 ISMiniMap.Recreate 的做法自己建（經過我們 hook 的 InitPlayer 會套 pyramid）。
    if not getPlayerMiniMap(0) then
        local ok, err = pcall(function()
            getPlayerData(0).miniMap = ISMiniMap.InitPlayer(0)
        end)
        if not ok then
            log("minimap creation failed: " .. tostring(err))
            return
        end
        -- InitPlayer 在 MiniMap.StartVisible=true 時已直接顯示，此時再 toggle 會關掉
        local mm = getPlayerMiniMap(0)
        if mm and mm:isReallyVisible() then return end
    end
    ISMiniMap.ToggleMiniMap(0)
end

local function onKeyPressed(key)
    if key == getCore():getKey("MinidoracatMiniMap_Toggle") then
        togglePlayerMiniMap()
    elseif key ~= 0 and key == getCore():getKey("MinidoracatMiniMap_Ghost")
        and Core.toggleGhost then -- 本體在 _Ghost.lua（載入序在後），事件時查表
        Core.toggleGhost()
    end
end
Events.OnKeyPressed.Add(onKeyPressed)

-- 跨檔匯出：主檔 InitPlayer／installMinidoracatButtons 與 _Ghost／_FloatIcon 呼叫時查表
Core.installResizeHooks = installResizeHooks -- 主檔 InitPlayer：對 bottomPanel 實例補掛
Core.chromeTintBorder = chromeTintBorder -- 主檔 installMinidoracatButtons：實例 prerender 每幀調色
Core.cancelResize = cancelResize -- _Ghost.lua 進穿透時取消進行中的邊緣縮放
Core.togglePlayerMiniMap = togglePlayerMiniMap -- _FloatIcon.lua：圖標點擊開關
