-- MinidoracatMiniMap_FloatIcon.lua
-- 本檔範圍：浮動開關圖標整節（自主檔 MinidoracatMiniMap.lua 拆出，內容原樣搬遷）——
-- 常駐頂層小圖標、點擊開關小地圖、拖曳移動、位置持久化與 hover 提示。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore 命名空間；本檔載入期只讀取其「一次性賦值」的穩定引用
-- 並定義函式/掛事件，跨檔「函式呼叫」一律發生在事件/呼叫時。
-- 拆檔緣由：Kahlua 編譯器每個函式原型（含每檔主 chunk）locvar 上限 200
-- （LexState.new_localvar 固定陣列，超過＝整檔拒載），主檔已貼頂——拆檔＝獨立額度。
local Core = MinidoracatMiniMapCore
-- ready＝主檔完整走完（版本檢查通過）才為真：拆分前本節位於主檔版本檢查之後，
-- 版本不符時整節不存在——此閘門維持同義行為
if not (Core and Core.ready) then return end

local modOptions = Core.modOptions -- 無 PZAPI（版本過舊）時為 nil，沿用原 nil 檢查
local getBoolOption = Core.getBoolOption
local debugWarn = Core.debugWarn -- -debug 渲染警告（tooltip 顯示 text/renderMode）
-- 開關小地圖本體在主檔（快捷鍵 OnKeyPressed 共用同一入口）；此處以裸名薄分派——
-- test:float-drag 區段的離線測試（scripts/test_key_migration.lua）以同名 local stub 注入
local function togglePlayerMiniMap() Core.togglePlayerMiniMap() end

-- ═══ 浮動開關圖標 ═══
-- 常駐頂層小圖標：點擊＝開關小地圖（滑鼠玩家不依賴快捷鍵）、拖曳＝移動、
-- 位置存 ModOptions FloatIconPos（"x,y"，同 CustomSize "WxH" 先例）。
-- 獨立於小地圖視窗（Toggle 移除視窗時圖標仍在——這正是它存在的意義），
-- 掛 UIManager 頂層（同 settingsUI 單例模式）。
local floatIcon -- 單例
local FLOAT_ICON_SIZE = 32
local FLOAT_DRAG_THRESHOLD = 4 -- 位移門檻：≦門檻＝點擊，超過＝拖曳（仿原版 inner dragMoved 語意）

local function floatIconSavePos(x, y)
    if not modOptions then return end
    local opt = modOptions:getOption("FloatIconPos")
    if not opt then return end
    opt:setValue(math.floor(x) .. "," .. math.floor(y))
    PZAPI.ModOptions:save() -- 立即落地 ModOptions.ini（同 CustomSize 拖曳縮放做法）
end

local function floatIconLoadPos()
    if not modOptions then return nil end
    local opt = modOptions:getOption("FloatIconPos")
    -- ""/"nil"/"-" 皆視為未設定（PZAPI textentry 空字串髒化問題，見主檔 unifiedCsvSet）
    local raw = opt and tostring(opt:getValue() or "") or ""
    local sx, sy = string.match(raw, "^%s*(%d+)%s*,%s*(%d+)%s*$")
    if sx then return tonumber(sx), tonumber(sy) end
    return nil
end

-- 夾回螢幕內（解析度改變/存檔位置超界）；prerender 每幀呼叫，純數值比較成本可忽略
local function floatIconClamp(el)
    local x = math.max(0, math.min(el:getX(), getCore():getScreenWidth() - el:getWidth()))
    local y = math.max(0, math.min(el:getY(), getCore():getScreenHeight() - el:getHeight()))
    if x ~= el:getX() then el:setX(x) end
    if y ~= el:getY() then el:setY(y) end
end

-- 套用存檔位置（未設定＝預設右緣偏上：避開右下角小地圖預設錨位與右上系統 HUD）。
-- 建立時與 modOptions:apply 皆呼叫——ESC 改動位置欄（含清空還原預設）即時生效
local function floatIconApplyPos(el)
    local x, y = floatIconLoadPos()
    if not x then
        x = getCore():getScreenWidth() - FLOAT_ICON_SIZE - 6
        y = math.floor(getCore():getScreenHeight() * 0.35)
    end
    el:setX(x)
    el:setY(y)
end

-- 指定綁定的目前顯示文字（含修飾鍵前綴）：優先讀選項畫面 keyText（結構同遷移一節），
-- 未就緒時退 Core 基本鍵名。hover 時現算——玩家改鍵後 tip 即時反映
local function currentBindKeyText(bindName)
    if MainOptions and type(MainOptions.keyText) == "table" then
        for _, v in ipairs(MainOptions.keyText) do
            if not v.value and v.txt and v.txt:getName() == bindName then
                local prefix = MainOptions.getKeyPrefix and MainOptions.getKeyPrefix(v) or ""
                return prefix .. getKeyName(v.keyCode)
            end
        end
    end
    return getKeyName(getCore():getKey(bindName))
end
local function currentToggleKeyText() return currentBindKeyText("MinidoracatMiniMap_Toggle") end

local function ensureFloatIcon()
    if floatIcon then return floatIcon end
    if not ISPanel then return nil end
    local ui = ISPanel:new(0, 0, FLOAT_ICON_SIZE, FLOAT_ICON_SIZE)
    ui.backgroundColor = { r = 0, g = 0, b = 0, a = 0.7 }
    ui.borderColor = { r = 1, g = 1, b = 1, a = 0.35 }
    ui:initialise()
    ui:instantiate()
    ui.tex = getTexture("media/ui/minimap_toggle.png")
    -- hover 提示（照抄 ISButton:updateTooltip，ISButton.lua:316-345）：顯示動作＋
    -- 當前快捷鍵。按住（點擊/拖曳中）不顯示
    function ui:updateFloatTooltip()
        if self:isMouseOver() and not self._down then
            if not self.tooltipUI then
                self.tooltipUI = ISToolTip:new()
                self.tooltipUI:setOwner(self)
                self.tooltipUI:setVisible(false)
                self.tooltipUI:setAlwaysOnTop(true)
            end
            if not self.tooltipUI:getIsVisible() then
                self.tooltipUI:addToUIManager()
                self.tooltipUI:setVisible(true)
            end
            local desc = getText("UI_MinidoracatMiniMap_FloatIcon_tip", currentToggleKeyText())
            if Core.toggleGhost then -- 穿透模式入口標註（_Ghost.lua 載入才顯示）；
                -- 帶目前熱鍵名（玩家回饋：不顯示按鍵不知道怎麼按）
                desc = desc .. " \n" .. getText("UI_MinidoracatMiniMap_FloatIcon_ghost_tip",
                    currentBindKeyText("MinidoracatMiniMap_Ghost"))
            end
            local mode = debugWarn.renderMode() -- -debug 限定：目前渲染管線狀態
            if mode then desc = desc .. " \n" .. mode end
            local warn = debugWarn.text()
            if warn then desc = desc .. " \n" .. warn end
            -- 多行不自動換行（同 ISButton.lua:326-330 的 maxLineWidth 切換）
            self.tooltipUI.maxLineWidth = (mode or warn) and 1000 or 300
            self.tooltipUI.description = desc
            self.tooltipUI:setDesiredPosition(getMouseX(), self:getAbsoluteY() + self:getHeight() + 8)
        elseif self.tooltipUI and self.tooltipUI:getIsVisible() then
            self.tooltipUI:setVisible(false)
            self.tooltipUI:removeFromUIManager()
        end
    end
    function ui:hideFloatTooltip()
        if self.tooltipUI and self.tooltipUI:getIsVisible() then
            self.tooltipUI:setVisible(false)
            self.tooltipUI:removeFromUIManager()
        end
    end
    function ui:prerender()
        -- 回主選單後 UIManager 元件仍存活：無玩家即自我隱藏（OnGameStart 再開回）
        if not getSpecificPlayer(0) then
            self:hideFloatTooltip() -- 隱藏後 prerender 不再執行，tip 須同步收掉
            self:setVisible(false)
            return
        end
        ISPanel.prerender(self)
        floatIconClamp(self)
        self:updateFloatTooltip()
        local a = self:isMouseOver() and 1.0 or 0.75
        -- 穿透模式中：邊框＋圖標染琥珀（小地圖琥珀邊框的次要提示，同 C 鈕雙件套慣例）
        local ghost = Core.isGhost and Core.isGhost()
        local bc = self.borderColor
        if ghost then
            bc.r, bc.g, bc.b = 1, 0.85, 0.4
        else
            bc.r, bc.g, bc.b = 1, 1, 1
        end
        if self.tex then
            self:drawTextureScaled(self.tex, 3, 3, self.width - 6, self.height - 6, a,
                1, ghost and 0.85 or 1, ghost and 0.4 or 1)
        else
            -- 材質缺漏 nil-safe（同 POI 圖標慣例）：畫「M」替代
            local fh = getTextManager():getFontHeight(UIFont.Small)
            self:drawTextCentre("M", self.width / 2, (self.height - fh) / 2, 1, 1, 1, a, UIFont.Small)
        end
    end
    -- 拖曳：setCapture 五件套（同 installResizeHooks 模式——拖出元件外仍收 Move/Up）
    -- test:float-drag:start
    local function moveIcon(self)
        if not self._down then return false end
        local mx, my = getMouseX(), getMouseY()
        if not self._dragged then
            if math.abs(mx - self._downX) <= FLOAT_DRAG_THRESHOLD
                and math.abs(my - self._downY) <= FLOAT_DRAG_THRESHOLD then
                return true
            end
            self._dragged = true
        end
        self:setX(self._origX + (mx - self._downX))
        self:setY(self._origY + (my - self._downY))
        return true
    end
    local function releaseIcon(self)
        if not self._down then return false end
        self._down = nil
        self:setCapture(false)
        if self._dragged then
            self._dragged = nil
            floatIconClamp(self)
            floatIconSavePos(self:getX(), self:getY())
        else
            togglePlayerMiniMap()
        end
        return true
    end
    -- test:float-drag:end
    function ui:onMouseDown(px, py)
        self._down = true
        self._dragged = nil
        self._downX, self._downY = getMouseX(), getMouseY()
        self._origX, self._origY = self:getX(), self:getY()
        self:setCapture(true)
        return true
    end
    function ui:onMouseMove(dx, dy) return moveIcon(self) end
    function ui:onMouseMoveOutside(dx, dy) return moveIcon(self) end
    function ui:onMouseUp(px, py) return releaseIcon(self) end
    function ui:onMouseUpOutside(px, py) return releaseIcon(self) end
    -- 右鍵＝穿透模式開關（本體在 _Ghost.lua，載入序在後——事件時查表）。
    -- FloatIcon 是 UIManager 頂層獨立元件、不隨小地圖穿透失效＝穿透中保證存在的
    -- 滑鼠回頭路（防鎖死鏈第二層；第一層熱鍵、第三層 ESC 選項頁——統一設定視窗
    -- 的入口齒輪在穿透中已收合，僅穿透前開著才可用；FloatIcon 本身可被選項關閉，
    -- 故 ESC 是恆在的保底）。down/up 配對：Java right-up 依放開位置派送、不追蹤
    -- press owner——無配對會讓「別處按住右鍵移入圖標放開」誤切換（原版 inner 以
    -- rightMouseDown 旗標防的同型問題）；左鍵拖曳中（_down）不接右鍵
    -- 時限守衛：UIManager 釋放派送「消費即中斷」，z-order 較高元件先吃掉右鍵
    -- 放開時本圖標收不到 Outside、旗標會殘留——800ms 內未配對即視為過期
    function ui:onRightMouseDown(px, py)
        if not self._down then
            self._rDown = true
            self._rDownAt = getTimestampMs()
        end
        return true
    end
    function ui:onRightMouseUp(px, py)
        if self._rDown and getTimestampMs() - (self._rDownAt or 0) < 800 then
            self._rDown = nil
            if Core.toggleGhost then Core.toggleGhost() end
        end
        self._rDown = nil
        return true
    end
    function ui:onRightMouseUpOutside(px, py) self._rDown = nil end
    floatIconApplyPos(ui)
    ui:addToUIManager()
    floatIcon = ui
    return ui
end

-- OnGameStart 與主檔 modOptions:apply()（ESC 選項頁與統一視窗勾選共同收斂點）呼叫；
-- 懶建立，選項關閉且從未建立時零成本。主檔經 Core.updateFloatIconVisibility
-- 呼叫時查表＋nil 防呆（本檔載入序在主檔之後）
local function updateFloatIconVisibility()
    if not getSpecificPlayer(0) then return end
    if getBoolOption("FloatIcon", true) then
        local ui = ensureFloatIcon()
        if ui then
            floatIconApplyPos(ui) -- 重讀位置欄：ESC 改動/清空即時生效（拖曳存檔＝同值冪等）
            ui:setVisible(true)
            ui:bringToTop()
        end
    elseif floatIcon then
        floatIcon:hideFloatTooltip() -- 隱藏後 prerender 停跑，tip 須在此收掉
        floatIcon:setVisible(false)
    end
end
Core.updateFloatIconVisibility = updateFloatIconVisibility
Events.OnGameStart.Add(updateFloatIconVisibility)
