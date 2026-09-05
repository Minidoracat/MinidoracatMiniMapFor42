-- MinidoracatMiniMap_WorldMapNav.lua
-- 本檔範圍：世界地圖（M）的導航與座標整合——(1) 底部置中玩家座標列（ShowPlayerCoords
-- 同一開關管小地圖與世界地圖）；(2) 右鍵選單「設定/清除/分享導航目標」＋「複製此處
-- 座標」；(3) 導航旗標/邊緣箭頭同步畫在世界地圖上（WM-1 早退期間小地圖加繪整段
-- 停用，世界地圖側自繪補位）。
-- 繪製與導航狀態全部共用主檔實作（Core.drawNavTargets/drawPlayerCoords/nav*），
-- 兩表面相容依據：ISWorldMap.lua:268 與 ISMiniMap.lua:192 同走 getAPIv3()，
-- 共用函式只依賴 mapAPI/width/height/playerNum 與 ISUIElement 繪製方法（主檔
-- zone/動物繪製共用同一組相容論證）。
-- 拆檔緣由：主檔 Kahlua 主 chunk locvar 貼 200 上限（同 _FloatIcon/_Ghost），
-- 新 wrap 的 upvalue 一律進本檔額度；載入序＝同目錄字母序，本檔最後載。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

--------------------------------------------------------------------------------
-- 右鍵選單回呼：與小地圖側同名方法（ISMiniMapInner:onMinidoracat*）鏡像，
-- 經 Core 閉包共用同一批導航狀態/持久化/分享路徑；self 只取 playerNum。
-- 複製回饋寫 self._minidoracatCopiedUntil＝座標列琥珀提示錨定世界地圖實例
--------------------------------------------------------------------------------
function ISWorldMap:onMinidoracatSetTarget(worldX, worldY)
    Core.navSetTarget(self.playerNum or 0, worldX, worldY)
end

function ISWorldMap:onMinidoracatClearTarget()
    Core.navClearTarget(self.playerNum or 0)
end

function ISWorldMap:onMinidoracatShareTarget()
    Core.navShareTarget(self.playerNum or 0)
end

-- z 固定 0＝地面層：地圖俯視點擊格無樓層資訊，同小地圖/原版 /teleportto x,y,0 慣例
function ISWorldMap:onMinidoracatCopyCoords(wx, wy)
    Core.copyCoordsText(self, string.format("%d,%d,0", wx, wy))
end

-- 搜尋視窗（本體 _Search.lua；引擎冷啟動由其 winRefresh 泵對 live 表面處理）
function ISWorldMap:onMinidoracatSearch()
    if Core.toggleSearchWindow then
        Core.toggleSearchWindow(self.playerNum or 0)
    end
end

--------------------------------------------------------------------------------
-- 右鍵選單：原版 onRightMouseUp（ISWorldMap.lua:907-982）三段——
--   (a) symbolsUI 工具取消（:908-910，ISWorldMapSymbols.lua:1597-1611）→ 原樣透傳；
--   (b) 非 debug/admin：return false（:911-913）→ 自建 ISContextMenu.get(playerNum,…)
--       （同原版 :917 座標式；playerNum 而非硬編 0＝分割畫面歸屬正確）；
--   (c) debug/admin：ISContextMenu.get(0, …) 建除錯選單回 true（:914-981）→ 追加同一單例。
-- 前手建沒建選單看 getPlayerContextMenu(pn) 的可見性，不信回傳值：DebugMenu 系建了選單
-- 回 nil（DebugMenuCore.lua:244-250），只看 handled 會走自建、get 的 clear
-- （ISContextMenu.lua:1166-1170）把它洗掉。呼叫前手前先藏殘留選單（原版 get 同樣先
-- hideAndChildren 再重顯，:1168），事後可見＝這一下建的。追加以「已有 SetTarget 項」冪等。
-- 開圖自癒：Cheat Menu Reborn 在 OnGameStart 整個覆寫且非 debug 不呼叫前手
-- （CMR_MapTeleport.lua:27-55）、DebugMenu 系載入期直接賦值（DebugMenuCore.lua:304）——
-- 後載即把本 wrap 踢掉；ShowWorldMap 是所有開圖路徑的匯合點（ISReadWorldMap.lua:25、
-- ISWorldMap.lua:1626），每次開圖不是我們的函式就把當下那個當前手重包。案例見 AGENTS 踩坑錄。
--------------------------------------------------------------------------------
-- test:wm-rightclick:start
local REHOOK_MAX = 8 -- ponytail: 兩個 MOD 都在開圖時重包會互踢成無限鏈，8 次後放手讓對方贏
local rehooks = 0
local navRightMouseUp -- 本 MOD 的 handler；重包時比對身分

local function installWMRightMouseUp()
    local prev = ISWorldMap.onRightMouseUp
    if not prev or prev == navRightMouseUp then return end
    if navRightMouseUp then
        if rehooks >= REHOOK_MAX then return end
        rehooks = rehooks + 1
        print("[MinidoracatMiniMap] worldmap right-click hook replaced by another mod; re-wrapping ("
            .. rehooks .. "/" .. REHOOK_MAX .. ")")
    end
    navRightMouseUp = function(self, x, y)
        local sym = self.symbolsUI
        if sym and (sym.currentTool ~= nil or sym.ignoreRightMouseUp) then
            return prev(self, x, y) -- 工具取消路徑，不動
        end
        local pn = self.playerNum or 0
        local own = getPlayerContextMenu(pn)
        if own and own:isVisible() then own:hideAndChildren() end
        local handled = prev(self, x, y)
        local playerObj = getSpecificPlayer(pn)
        if not playerObj then return handled end -- debug 主選單地圖：無玩家不加項
        local context
        if own and own:isVisible() then
            context = own -- 前手這一下建的（原版 debug／DebugMenu／CMR）
        elseif handled then
            context = getPlayerContextMenu(0) -- 原版 debug 硬編 0；分割畫面 pn≠0 由此接
        else
            context = ISContextMenu.get(pn, x + self:getAbsoluteX(), y + self:getAbsoluteY())
        end
        if not context then return handled end
        local setLabel = getText("UI_MinidoracatMiniMap_SetTarget")
        local opts = context.options
        if opts then
            for i = 1, #opts do
                if opts[i].name == setLabel then return true end -- 鏈裡兩層都是我們：已加過
            end
        end
        local worldX = self.mapAPI:uiToWorldX(x, y) -- 2 參 uiToWorld 用例 ISWorldMap.lua:939-940
        local worldY = self.mapAPI:uiToWorldY(x, y)
        context:addOption(setLabel, self, self.onMinidoracatSetTarget, worldX, worldY)
        -- 複製此處座標：選項文字即時帶座標（先看到再決定點不點，同小地圖）
        local cwx, cwy = math.floor(worldX), math.floor(worldY)
        context:addOption(getText("UI_MinidoracatMiniMap_CopyHere",
            string.format("%d, %d, 0", cwx, cwy)), self, self.onMinidoracatCopyCoords, cwx, cwy)
        context:addOption(getText("UI_MinidoracatMiniMap_SearchMenu"), self,
            self.onMinidoracatSearch)
        if Core.navGetTarget(pn) then
            context:addOption(getText("UI_MinidoracatMiniMap_ClearTarget"), self,
                self.onMinidoracatClearTarget)
            if isClient() and Faction and Faction.getPlayerFaction(playerObj)
                -- ⚠ 不傳 pn＝AllowNavShare 永不列入管理員旁路白名單（會影響其他
                -- 玩家、需伺服器轉送的功能閘；主檔 navShareGateTick 註解同義）
                and Core.navShareAllowed and Core.navShareAllowed() then
                -- Faction.getPlayerFaction 用例 ISFactionUI.lua:408
                context:addOption(getText("UI_MinidoracatMiniMap_ShareTarget"), self,
                    self.onMinidoracatShareTarget)
            end
        end
        return true
    end
    ISWorldMap.onRightMouseUp = navRightMouseUp
end

if ISWorldMap and ISWorldMap.onRightMouseUp then
    installWMRightMouseUp()
    if ISWorldMap.ShowWorldMap then
        local originalNavShowWorldMap = ISWorldMap.ShowWorldMap
        function ISWorldMap.ShowWorldMap(playerNum, centerX, centerY, zoom)
            originalNavShowWorldMap(playerNum, centerX, centerY, zoom)
            installWMRightMouseUp()
        end
    end
end
-- test:wm-rightclick:end

--------------------------------------------------------------------------------
-- 世界地圖加繪：座標列先畫、導航後畫（導航距離標籤可壓座標膠囊之上，同小地圖
-- 呼叫序）。prerender＝畫在子元件（按鈕列/圖例/符號面板）之下、引擎地圖與主檔
-- zone/動物加繪之上（本檔最後載＝wrap 最外層，原鏈先跑完才輪到本檔）。
-- drawNavTargets 內建抵達清除（狀態變更），世界地圖開著時亦即時判定；
-- pcall＋實例旗標 log-once（同主檔 WM 動物繪製慣例）
--------------------------------------------------------------------------------
-- test:wm-prerender:start
if ISWorldMap and ISWorldMap.prerender then
    local originalWMNavPrerender = ISWorldMap.prerender
    function ISWorldMap:prerender()
        originalWMNavPrerender(self)
        local ok, err = pcall(Core.drawPlayerCoords, self)
        if not ok and not self._minidoracatWMCoordsErrLogged then
            self._minidoracatWMCoordsErrLogged = true
            print("[MinidoracatMiniMap] worldmap coords draw failed: " .. tostring(err))
        end
        ok, err = pcall(Core.drawNavTargets, self)
        if not ok and not self._minidoracatWMNavErrLogged then
            self._minidoracatWMNavErrLogged = true
            print("[MinidoracatMiniMap] worldmap nav draw failed: " .. tostring(err))
        end
        -- 管理員檢視標記：本檔的 prerender wrap 是最外層，畫在全部世界地圖加繪
        -- 之上。缺函式／繪製錯誤都 log-once，避免旁路生效卻沒有安全提示。
        ok, err = pcall(Core.drawAdminViewMarker, self)
        if not ok and not self._minidoracatWMAdminMarkErrLogged then
            self._minidoracatWMAdminMarkErrLogged = true
            print("[MinidoracatMiniMap] worldmap admin marker draw failed: " .. tostring(err))
        end
    end
end
-- test:wm-prerender:end
