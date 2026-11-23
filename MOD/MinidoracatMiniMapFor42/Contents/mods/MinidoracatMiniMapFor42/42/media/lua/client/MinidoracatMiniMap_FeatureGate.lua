-- MinidoracatMiniMap_FeatureGate.lua
-- 通用功能閘門（featureApiVersion 3；v2 加 featureServerOff，v3 加 minimap 的 "hide"）：讓 addon（首個消費者＝地圖錶）依玩家狀態
-- 關掉小地圖或其中某項功能。沒有任何註冊時 Core.featureAllowed 在 # 判斷後直接
-- 回 true，所有掛點行為與加 API 前逐位元相同（hide 的輪詢在第一次註冊時才掛）。
-- 掛點（呼叫時查 Core.featureAllowed＋nil 防呆＝缺檔時放行）：
--   minimap  _Resize ToggleMiniMap／FocusMiniMap、togglePlayerMiniMap（主動開啟被擋＝不開＋halo）；
--            主檔 ISMiniMapInner:prerender（開著時被擋＝蓋掉底圖畫「無訊號」，不畫任何疊加層）；
--            _Nav 小地圖右鍵；本檔 OnPreUIDraw 輪詢（擋下＋"hide"＝整個視窗收起，見下方 hide 段）
--   arrow    _Nav drawNavTargets → drawNavIndicator 畫面外箭頭
--   poi      _Zones distGateParams（poiBlocked）、_Legend 世界地圖圖例；搜尋不閘
--   nav      _Nav Core.navGateAllows（與 registerNavGate 取 AND）；_Itinerary tickSlot 撤銷
--   share    _Nav 送出／選單／navGetShared、_WorldMapNav 選單；主檔 RemotePlayers 壓制
--   scan     _Dots drawAnimalDots（maxDist 併進 Animal/VehicleIconDistance）
--   zombie   _Dots drawZombieDotsOn（maxDist 併進 ZombieDotDistance）、主檔 ZombieIntensity
-- 載入序：字母序在 _Dots／_ChunkGrid 之後、其餘模組之前；所有呼叫都發生在繪製／事件期。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end
local API = MinidoracatMiniMapAPI
local Policy = Core.policy -- nil＝舊版共用檔缺席：沒有戰術檢視可旁路

local TTL_MS = 250
local NO_SURFACE = "-" -- surface=nil（非繪製呼叫）的快取鍵
local GENERIC_REASON = "UI_MinidoracatMiniMap_FeatureUnavailable"
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

-- 註冊表掛 Core（測試與診斷可讀）；快取為檔內 local，註冊變動時整張換新
Core.featureGates = {} -- { { owner=, fn=, errLogged= }, ... }
local cache = {} -- [feature][surface 或 NO_SURFACE][pn] = { at=, ok=, reason=, dist=, hide= }
local pollState, gatePoll -- hide 輪詢：nil＝還沒掛、true＝掛著、false＝出錯停用；gatePoll 定義在 hide 段

API.featureApiVersion = 3
-- gateFn(playerNum, feature, surface) --> allowed[, reasonKey[, maxDist[, presentation]]]
-- 只有明確回 false 才擋；同 owner 再註冊＝覆蓋（錯誤旗標重置）
-- v3：presentation == "hide" 只在 feature == "minimap" 且 allowed == false 時有效＝小地圖視窗整個收起
function API.registerFeatureGate(ownerModId, gateFn)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(gateFn) ~= "function" then
        log("registerFeatureGate bad arguments (need ownerModId string, gateFn function)")
        return false
    end
    local gates = Core.featureGates
    local found = false
    for i = 1, #gates do
        if gates[i].owner == ownerModId then
            gates[i].fn = gateFn
            gates[i].errLogged = nil
            found = true
            break
        end
    end
    if not found then gates[#gates + 1] = { owner = ownerModId, fn = gateFn } end
    if pollState == nil then -- hide 輪詢：第一次註冊才掛，零註冊不多一個每幀 callback
        pollState = true
        Events.OnPreUIDraw.Add(gatePoll)
    end
    cache = {} -- 新 gate 立即生效，不等 250ms 舊快取過期
    return true
end

-- 伺服器沙盒是不是把這項 feature 掛點控制的東西全關了（v2）：addon 拿來在自己的介面寫「伺服器未開放」，
-- 不必知道主 MOD 的沙盒鍵名。zombie＝殭屍點位與殭屍熱度都不允許；scan＝動物與載具圖標都不允許；
-- 其餘 feature 沒有對應的伺服器總開關，一律 false。不傳 pn＝不吃管理員戰術旁路：回答的是伺服器開放了沒。
function API.featureServerOff(feature)
    local gate = Core.sandboxGate
    if not gate then return false end
    if feature == "zombie" then
        return gate("AllowZombieDots", true) == false and gate("AllowZombieIntensity", true) == false
    end
    if feature == "scan" then
        return gate("AllowAnimalDots", true) == false and gate("AllowVehicleDots", true) == false
    end
    return false
end

-- 熱路徑（每幀多次）：零註冊在 # 後返回；有註冊時同 (pn, feature, surface) 250ms 內
-- 讀快取。快取條目首次建立後原地覆寫，穩態不配置 table。
-- 戰術檢視（Policy.tacticalActive）對 scan／zombie 放行且不帶 maxDist；share 永不旁路。
Core.featureAllowed = function(pn, feature, surface)
    local gates = Core.featureGates
    local n = #gates
    if n == 0 then return true end
    if (feature == "scan" or feature == "zombie") and Policy and Policy.tacticalActive(pn) then
        return true
    end
    local byFeature = cache[feature]
    if not byFeature then byFeature = {}; cache[feature] = byFeature end
    local sk = surface or NO_SURFACE
    local bySurface = byFeature[sk]
    if not bySurface then bySurface = {}; byFeature[sk] = bySurface end
    local e = bySurface[pn]
    local now = getTimestampMs()
    if e and now >= e.at and now - e.at < TTL_MS then return e.ok, e.reason, e.dist, e.hide end
    if not e then e = {}; bySurface[pn] = e end
    local ok, reason, dist, hide = true, nil, nil, false
    for i = 1, n do
        local g = gates[i]
        -- 拋錯過的 gate 停用（視為放行）到同 owner 再註冊：引擎對 pcall 接住的錯誤也會印整段堆疊並計入
        -- 錯誤數（家族 pitfalls），每 250ms 再問會洗版
        if not g.errLogged then
            local called, allowed, rk, md, pres = pcall(g.fn, pn, feature, surface)
            if not called then
                g.errLogged = true
                cache = {} -- 其他 (pn, feature, surface) 不必等 TTL 才不再問它
                log("feature gate error (" .. tostring(g.owner) .. "), disabled until re-registered: " .. tostring(allowed))
            elseif allowed == false then
                ok, dist = false, nil
                hide = feature == "minimap" and pres == "hide"
                if type(rk) == "string" and rk ~= "" then reason = rk end
                break
            elseif type(md) == "number" and md > 0 and (not dist or md < dist) then
                dist = md
            end
        end
    end
    e.at, e.ok, e.reason, e.dist, e.hide = now, ok, reason, dist, hide
    return ok, reason, dist, hide
end

-- 玩家主動開小地圖（快捷鍵、Dock、原版按鈕／輪盤）：被擋＝halo 提示原因、回 true。
-- 不碰 MiniMap.StartVisible——呼叫端在原版 Toggle 之前就返回。
Core.minimapOpenBlocked = function(pn)
    local ok, reason = Core.featureAllowed(pn, "minimap")
    if ok then return false end
    local player = getSpecificPlayer(pn)
    if player and HaloTextHelper then
        HaloTextHelper.addBadText(player, getText(reason or GENERIC_REASON))
    end
    return true
end

-- ===== v3 hide：閘門擋下＋presentation "hide"＝小地圖整個視窗收起，放行時回來 =====
-- 收起用 setVisible(false)＋實例旗標 _minidoracatGateHidden，不 removeFromUIManager：Java render 開頭查 isVisible、
-- 當幀就不畫（UIElement.java:1603-1605；不可見也不吃滑鼠鍵盤），remove 要等下一次 UIManager.update 才生效、
-- 當幀照畫一次無訊號，放回時 AddUI 還會排到最上層蓋住世界地圖（UIManager.java:112-123、:492-503）。
-- 原版從不對小地圖 outer setVisible（ISMiniMap.lua 的 setVisible 都是選項面板與標題列），旗標不會被原版清掉。
-- 收著時 isReallyVisible 為 false：開圖入口照舊走 minimapOpenBlocked（不開＋halo）、Dock 顯示未開、通知不避讓。
-- 輪詢掛 OnPreUIDraw（UIManager.render 內、逐元件 render 之前，UIManager.java:293、:310-327）：暫停時照跑；
-- 與 inner prerender 同一個快取鍵 ("minimap", "mini")，每幀都先在這裡問、快取過期後的重算落在 render 之前，不會先畫一幀無訊號；
-- 建立視窗當下 addon 多半還沒註冊（OnCreatePlayer 早於 OnGameStart，GameLoadingState.exit），
-- 新視窗進 UI 清單後的第一次繪製前就在這裡被收，不必在建立點另判。
-- 狀態 per pn：hid＝閘門要求收起中（值＝收起時視窗本來開著沒）；shown＝閘門解除時顯示的視窗，
-- 玩家自己關掉之前 Recreate 換出的新實例照樣顯示（StartVisible=false 時 InitPlayer 不會 addToUIManager）。
-- 離開存檔 Lua 整個重載，不需要 OnGameStart 重置。
local hid, shown = {}, {}

local function hideWindow(pn, mm)
    if Core.cancelResize then Core.cancelResize() end -- resizeState 是 _Resize 的 local，只能無條件取消
    -- 手勢殘留（同 _Ghost.lua applyGhostTo）：收起後收不到 mouse up，漏清＝放行後黏著游標
    local tb, inner, menu = mm.titleBar, mm.inner, mm._minidoracatMoreMenu
    if tb then
        tb.dragging = false
        if tb.setCapture then pcall(tb.setCapture, tb, false) end
    end
    if inner then
        inner.dragging = false
        inner.rightMouseDown = false
        if inner.setCapture then pcall(inner.setCapture, inner, false) end
    end
    -- 只關本 MOD 的「更多」選單（每位玩家共用單例，辨識式同主檔實例 prerender）
    if menu and menu:isVisible() and menu.options[1] and menu.options[1].onSelect == Core.toolbarMenuRun then
        menu:closeAll()
    end
    if mm.joyfocus then -- 同原版 ToggleMiniMap 關閉（ISMiniMap.lua:753-756）
        mm:clearJoypadFocus(mm.joyfocus)
        setJoypadFocus(pn, nil)
    end
    mm._minidoracatGateHidden = true
    mm:setVisible(false)
end

local function showWindow(pn, mm)
    -- 沒有視窗＝沙盒連世界地圖都關（autoCreateMiniMap 刻意不建）：不替伺服器主跳出地圖（2026-11-09 裁定），/ 照樣能開
    if not mm then return nil end
    mm._minidoracatGateHidden = nil
    mm:setVisible(true)
    if not mm:isReallyVisible() then mm:addToUIManager() end -- 玩家自己關掉的；不寫 StartVisible
    return mm
end

Core.minimapGateSync = function(pn)
    local _, _, _, hide = Core.featureAllowed(pn, "minimap", "mini")
    local mm = getPlayerMiniMap(pn)
    if hide then
        shown[pn] = nil
        if mm and mm:isReallyVisible() then
            hideWindow(pn, mm)
            hid[pn] = "open"
        elseif not hid[pn] then
            hid[pn] = "closed"
        end
        return
    end
    local was = hid[pn]
    if was then
        hid[pn] = nil
        -- 2026-11-24 地圖手錶 session 建議（待使用者確認）：hide 解除一律顯示，收著時玩家看不出小地圖算開或關，
        -- 「看錶」就是開關。改回「玩家自己關的不替他開」：show = was == "open"
        local show = true
        if show then shown[pn] = showWindow(pn, mm) end
    elseif shown[pn] and mm then
        if mm ~= shown[pn] then -- Recreate／重建 UI 換了實例
            shown[pn] = mm
            if not mm:isReallyVisible() then mm:addToUIManager() end
        elseif not mm:isReallyVisible() then
            shown[pn] = nil -- 放行期間玩家自己關了：照他的，到下一次 hide→放行才再開
        end
    end
end

local function pollPlayers()
    for pn = 0, 3 do
        local player = getSpecificPlayer(pn)
        if player and not player:isDead() then Core.minimapGateSync(pn) end
    end
end
-- 輪詢本身出錯：停用、log 一次（每幀重試會洗版，同 gate 拋錯的處理），收著的視窗放回＝退回 v2 的畫無訊號
gatePoll = function()
    local ok, err = pcall(pollPlayers)
    if ok then return end
    pollState = false
    Events.OnPreUIDraw.Remove(gatePoll)
    log("minimap gate hide failed, disabled: " .. tostring(err))
    for pn = 0, 3 do
        local mm = getPlayerMiniMap(pn)
        if mm and mm._minidoracatGateHidden then
            mm._minidoracatGateHidden = nil
            pcall(mm.setVisible, mm, true)
        end
    end
end

-- share 被擋：每幀把引擎隊友圖層（RemotePlayers）壓回關閉；放行時還原「玩家期望值」。
-- 實例旗標記「是本閘門壓的」才還原；壓制本身（直接 setBoolean）不改期望值。
-- renderRemotePlayers 只看這個布林（UIWorldMap.java:410-416），名字隨之消失。
-- 期望值來源：小地圖＝ModOptions RemotePlayers（齒輪面板勾選已回寫，同 applyToggleOptions）；
-- 世界地圖＝_minidoracatRPWant（下方兩個 hook 追蹤原版選項面板與 setShowRemotePlayers；
-- 原版面板 onTickBox 只 setValue、不更新 showRemotePlayers，ISWorldMap.lua:14-20），沒有才退 showRemotePlayers。
Core.gateRemotePlayers = function(el, pn, isWorld)
    if Core.featureAllowed(pn, "share") then
        if not el._minidoracatRPSuppressed then return end
        el._minidoracatRPSuppressed = nil
        local want
        if isWorld then
            want = el._minidoracatRPWant
            if want == nil then want = el.showRemotePlayers ~= false end
        else
            want = Core.modOptions == nil or Core.getBoolOption("RemotePlayers", true)
        end
        el.mapAPI:setBoolean("RemotePlayers", want and true or false)
    elseif el.mapAPI:getBoolean("RemotePlayers") then
        el._minidoracatRPSuppressed = true
        el.mapAPI:setBoolean("RemotePlayers", false)
    end
end
-- 世界地圖期望值：原版選項面板勾選（WorldMapOptions:new 存 o.map＝ISWorldMap 實例，ISWorldMap.lua:218-223；
-- 面板 tickbox 在建立時才取 self.onTickBox，本 hook 在開機載入期已就位）與 setShowRemotePlayers
-- （ShowWorldMap 每次開圖重套，ISWorldMap.lua:1147-1149／:1517）。壓制期間玩家改勾選也記得到
if WorldMapOptions and WorldMapOptions.onTickBox then
    local originalWMOptionsTick = WorldMapOptions.onTickBox
    function WorldMapOptions:onTickBox(index, selected, option)
        originalWMOptionsTick(self, index, selected, option)
        if self.map and option and option:getName() == "RemotePlayers" then
            self.map._minidoracatRPWant = selected and true or false
        end
    end
end
if ISWorldMap and ISWorldMap.setShowRemotePlayers then
    local originalSetShowRemote = ISWorldMap.setShowRemotePlayers
    function ISWorldMap:setShowRemotePlayers(show)
        originalSetShowRemote(self, show)
        self._minidoracatRPWant = show and true or false
    end
end

-- 「無訊號」畫面：UIWorldMap.render 先畫完底圖與引擎圖層（UIWorldMap.java:189-325）才經
-- super.render 進 Lua prerender（UIElement.java:1616），故在 inner prerender 蓋一層不透明
-- 底色即擋住底圖、玩家點、隊友、熱度與街名；呼叫端隨後 return、不畫任何 MOD 疊加層。
-- 文字寬度依 (reasonKey, 文字倍率) memo 在元件上，逐幀不重量測。
-- 裁切：UIWorldMap 的 stencil 在進 Lua prerender 前已清（UIWorldMap.java:259-262），DrawText
-- 也不按元件寬度裁——長原因或大文字倍率會畫出小地圖。故整段包 setStencilRect／clearStencilRect
-- （同 _Zones fill pass），繪製出錯也必定 clear，免得引擎全域 stencil 洩漏到當幀其餘 UI
local function drawNoSignalBody(inner, reasonKey)
    local w, h = inner.width, inner.height
    inner:drawRect(0, 0, w, h, 1, 0.04, 0.05, 0.06)
    local tz = Core.mapTextZoom()
    local key = reasonKey or GENERIC_REASON
    local m = inner._minidoracatNoSignal
    if not m or m.key ~= key or m.tz ~= tz then
        local tm = getTextManager()
        m = { key = key, tz = tz, title = getText("UI_MinidoracatMiniMap_NoSignal"), reason = getText(key) }
        m.titleW = tm:MeasureStringX(UIFont.Medium, m.title) * tz
        m.reasonW = tm:MeasureStringX(UIFont.Small, m.reason) * tz
        m.titleH = tm:getFontHeight(UIFont.Medium) * tz
        m.reasonH = tm:getFontHeight(UIFont.Small) * tz
        inner._minidoracatNoSignal = m
    end
    local y = (h - m.titleH - m.reasonH - 4) / 2
    local tx = (w - m.titleW) / 2
    local rx = (w - m.reasonW) / 2
    -- ponytail: 原因太長只置中不換行（超出部分由 stencil 裁掉），錶的鍵都是短句
    Core.drawMapText(inner, m.title, tx - tx % 1, y - y % 1, 1, 0.55, 0.3, 1, UIFont.Medium, tz)
    y = y + m.titleH + 4
    Core.drawMapText(inner, m.reason, rx - rx % 1, y - y % 1, 0.85, 0.85, 0.85, 1, UIFont.Small, tz)
end
Core.drawNoSignal = function(inner, reasonKey)
    inner:setStencilRect(0, 0, inner.width, inner.height)
    local ok, err = pcall(drawNoSignalBody, inner, reasonKey)
    inner:clearStencilRect()
    if not ok then error(err, 0) end
end
