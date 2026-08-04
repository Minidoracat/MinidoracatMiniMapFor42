-- MinidoracatMiniMap_Ghost.lua
-- 本檔範圍：穿透模式（GhostMode）——小地圖點擊/滾輪/右鍵點擊穿透到遊戲世界、
-- 地圖本體半透明（GhostAlpha 滑條）＋外框變淡＋琥珀提示，可拉大當常駐佈局
-- 而不擋操作、不擋視線（玩家回報需求）。
-- 機制依據 .omc/autoresearch/minimap-clickthrough-alpha/ 對抗式查證（confirmed）：
-- 穿透＝UIElement.consumeMouseEvents（vanilla 先例 ISWorldMap AnnotatedMapOverlay）
-- ＋Lua 端事件 gate。載入序：同目錄字母序，本檔在主檔之後——在本 MOD 內此處的
-- 事件 wrap 是最外層、ghost gate 先於既有 wrap（含 LockPosition 的 return true）
-- 執行；後載的第三方 MOD 仍可再包，「最外層」非全域保證。
-- 拆檔緣由：主檔 Kahlua locvar 上限 200 已貼頂（同 _FloatIcon）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

local modOptions = Core.modOptions -- 無 PZAPI（版本過舊）時為 nil：穿透模式整組停用
local getBoolOption = Core.getBoolOption
local getSliderValue = Core.getSliderValue

local function isGhost() return getBoolOption("GhostMode", false) end

-- 事件穿透 gate（本 MOD 最外層 wrap）：明確 return false＝不消費，UIManager 繼續
-- 往下層元件/世界層送（滾輪落到引擎 getCore():doZoomScroll＝世界縮放照常）。
-- 右鍵系「必須」明確回 false——UIElement.java 右鍵收尾在 Lua handler 回 nil 時
-- 直接消費、不看 consumeMouseEvents（ISUIElement:onRightMouseDown 是空函式回 nil
-- ＝每個 ISUIElement 天生消費右鍵）。原 handler 不存在時回 false＝與未定義同義
-- （五條 Java 事件路徑逐一核過）。
-- 覆蓋面＝查證結論全清單：子元件消費會往上冒泡（父無條件回 TRUE），只設 outer
-- 無效；inner 的三個主動消費 handler（onMouseDown/onMouseWheel return true、
-- onRightMouseDown 有定義即消費）都在此被蓋掉。onMouseMove 不 gate——它不消費
-- 點擊，穿透靠 consume 旗標（applyGhostTo）。bottomPanel 不 gate：穿透中
-- setAdornmentsVisible 強制收合（主檔 wrap），invisible 元件事件路由提早回
-- FALSE，一次解掉整組 ISButton。
-- 已知引擎級殘留（不修）：右鍵「按住」期間 UIManager 只憑 bounds 消費
-- consumedRClick——可見 UI 本就如此，穿透模式無退化亦無法改善（點擊穿透不受影響）。
-- test:ghost-gate:start
local function gate(class, name)
    if not class then return end
    local orig = class[name]
    class[name] = function(self, ...)
        if isGhost() then return false end
        if orig then return orig(self, ...) end
        return false
    end
end

local GATED = { "onMouseDown", "onMouseUp", "onMouseWheel",
    "onRightMouseDown", "onRightMouseUp" }
for i = 1, #GATED do
    gate(ISMiniMapInner, GATED[i])
    gate(ISMiniMapOuter, GATED[i])
    gate(ISMiniMapTitleBar, GATED[i])
end
-- test:ghost-gate:end

-- 非事件面套用（單一收斂點：toggleGhost／主檔 modOptions:apply／齒輪面板 apply／
-- 主檔 InitPlayer 四個入口都必經）。
-- test:ghost-apply:start
-- ═══ 地圖本體半透明 ═══
-- 疊層不透明度會相乘累積（每層 50% 疊四層≈94% 不透明＝實測「奶霧感」而非透明），
-- 故不可均勻壓暗：只留「內容層」半透明、其下全部歸零，總透明度才是真的滑條值。
-- 地圖不透明度＝GhostAlpha 滑條（%→0..1，實測 50% 固定值不夠透故做成可調），
-- 事件端每幀比對即時生效（prerender wrap）。
local function ghostMapAlpha()
    return getSliderValue("GhostAlpha", 40, 10, 90) / 100
end
-- vanilla 底紙色（ISMapDefinitions.lua:163 的 219/215/192）。實測第一死點＝
-- UIWorldMap.render 先用 this.color（預設此色、a=1.0）畫全尺寸不透明底紙 quad，
-- 把該區 FBO alpha 寫成 1——圖層 alpha 壓再低都救不回；Lua 入口
-- mapAPI:setBackgroundRGBA（UIWorldMapV1:366，直寫 this.color，per-instance）。
-- 還原用常數：Lua 無 getter 可讀 this.color，第三方自訂背景色的極端情境會被
-- 還原成 vanilla 值（可接受）。未探索遮罩（WorldMapVisited singleton，vanilla
-- a=1.0）同為不透明來源、一併壓——singleton 與大地圖共用（穿透中大地圖未探索區
-- 同變淡），且大地圖樣式初始化會把它重設回 1.0，故 prerender 每幀重壓、退出還原
local BG_R, BG_G, BG_B = 219 / 255, 215 / 255, 192 / 255
-- 分類＝layer:getTypeString()（wrapper 基底方法 WorldMapStyleV1.java:353 委派
-- 引擎層，回 "Pyramid"/"Texture"/"Text"/"Polygon"/"Line"）——穩定型別字串，
-- 免呼叫可能缺失的 method（Kahlua 對缺失 Java method 連 pcall 都會
-- flushErrorMessage 刷整條 trace，探測法不可用，實測 90 連發）。
--   Pyramid（圖磚）＝內容 → ×滑條值；Text（地名/街名）＝資訊 → ×滑條值
--   Polygon（向量填色）：圖片模式下被 pyramid 蓋住本就不可見 → 0；
--     向量模式（無 pyramid）它就是內容 → ×滑條值
--   Texture（底紙/背景）→ 0；Line（無 fill 存取器）與未知型別 → skip 完全不碰
local KIND_MAP = { Pyramid = "pyramid", Texture = "texture",
    Text = "text", Polygon = "polygon" }
local function layerKind(layer)
    return KIND_MAP[layer:getTypeString()] or "skip"
end
local function setLayerAlphas(layer, snapStops, targetOf)
    if snapStops then -- 還原路徑
        for si = 0, layer:getFillStops() - 1 do
            if snapStops[si] then
                layer:setFillRGBA(si, layer:getFillRed(si), layer:getFillGreen(si),
                    layer:getFillBlue(si), snapStops[si])
            end
        end
        return
    end
    local stops = {}
    for si = 0, layer:getFillStops() - 1 do
        local a = layer:getFillAlpha(si)
        stops[si] = a
        layer:setFillRGBA(si, layer:getFillRed(si), layer:getFillGreen(si),
            layer:getFillBlue(si), targetOf(a))
    end
    return stops
end
local function dimHalf(a) return math.floor(a * ghostMapAlpha() + 0.5) end
local function dimZero() return 0 end
local ghostKindWarned -- 引擎改版把型別字串換掉時的一次性可觀測性（防無症狀退化）
local function layerSnapKey(layer, li)
    -- 快照鍵＝layer:getID()（index 在 in-place 重掛後會漂移、id 不會；還原以 id
    -- 反查、查無此層即跳過，不會把 A 層 alpha 寫進 B 層）；getID 異常退回 index 鍵
    local ok, id = pcall(function() return layer:getID() end)
    if ok and id then return id end
    return "#" .. li
end
local function dimMapBody(inner, on)
    if not inner then return end
    local api = inner.mapAPI
    local st = api and api:getStyleAPI()
    if on then
        if not st then return end
        -- 冪等：同值不重壓（多入口重複呼叫不得複利遞減）；滑條改動＝先還原再重壓
        local curA = ghostMapAlpha()
        if inner._minidoracatGhostSnap then
            if inner._minidoracatGhostSnap.alphaUsed == curA then return end
            dimMapBody(inner, false)
        end
        local n = st:getLayerCount()
        local kinds, pyramidFound = {}, false
        for li = 0, n - 1 do
            local ok, k = pcall(layerKind, st:getLayerByIndex(li))
            kinds[li] = ok and k or "skip"
            if kinds[li] == "pyramid" then pyramidFound = true end
        end
        -- 快照「先掛再改、邊套邊記」：中途拋錯時已動的層仍有還原憑證，退出路徑
        -- 可救回——不得在迴圈後才落快照（部分壓暗＋無快照＝下次重套把暗值當
        -- 原值＝永久汙染，只剩 Recreate 能救）
        local snap = { layers = {}, alphaUsed = curA }
        inner._minidoracatGhostSnap = snap
        local touched = 0
        for li = 0, n - 1 do
            local k = kinds[li]
            if k ~= "skip" then -- 只碰已識別、確定有 fill 存取器的四種型別
                local target = dimZero
                if k == "pyramid" or k == "text"
                    or (k == "polygon" and not pyramidFound) then
                    target = dimHalf
                end
                local layer = st:getLayerByIndex(li)
                local ok, stops = pcall(setLayerAlphas, layer, nil, target)
                if ok and stops then
                    snap.layers[layerSnapKey(layer, li)] = stops
                    touched = touched + 1
                end
            end
        end
        if touched == 0 and n > 0 and not ghostKindWarned then
            ghostKindWarned = true
            print("[MinidoracatMiniMap] ghost: no style layers classified ("
                .. n .. " layers) — engine layer type strings changed?")
        end
        api:setBackgroundRGBA(BG_R, BG_G, BG_B, 0) -- 底紙 quad（per-instance，一次性）
        api:setUnvisitedRGBA(BG_R * 0.915, BG_G * 0.915, BG_B * 0.915, curA)
        api:setUnvisitedGridRGBA(BG_R * 0.777, BG_G * 0.777, BG_B * 0.777, curA)
    else
        local snap = inner._minidoracatGhostSnap
        if not snap then return end
        if st then
            for li = 0, st:getLayerCount() - 1 do
                local layer = st:getLayerByIndex(li)
                local stops = snap.layers[layerSnapKey(layer, li)]
                if stops then pcall(setLayerAlphas, layer, stops) end
            end
        end
        if api then -- 還原 vanilla 值（ISMapDefinitions.lua:163-166 同式）
            api:setBackgroundRGBA(BG_R, BG_G, BG_B, 1.0)
            api:setUnvisitedRGBA(BG_R * 0.915, BG_G * 0.915, BG_B * 0.915, 1.0)
            api:setUnvisitedGridRGBA(BG_R * 0.777, BG_G * 0.777, BG_B * 0.777, 1.0)
        end
        inner._minidoracatGhostSnap = nil -- 還原跑完才丟憑證（中途異常可重試）
    end
end
local function applyGhostTo(mm)
    if not mm then return end
    local on = isGhost()
    -- consume 旗標：全組（outer/inner/titleBar/bottomPanel）都要放行——僅設 inner
    -- 時 outer 仍消費 mouse-move（ISUIElement:new 預設 wantMouseEvents=true，
    -- ISUIElement.lua:1998），UIManager 會跳過 ContextPick/setPickedTile＝穿透
    -- 點擊命中「舊的」世界指向目標（stale picker）。vanilla 值以快照還原：
    -- 進穿透時記下各元件原值、退出寫回快照而非硬編 true
    local parts = { mm, mm.inner, mm.titleBar, mm.bottomPanel }
    for i = 1, #parts do
        local el = parts[i]
        if el and el.setWantMouseEvents then
            if on then
                if el._minidoracatWantMouse == nil then
                    el._minidoracatWantMouse =
                        (el.isWantMouseEvents and el:isWantMouseEvents()) and true or false
                end
                el:setWantMouseEvents(false)
            elseif el._minidoracatWantMouse ~= nil then
                el:setWantMouseEvents(el._minidoracatWantMouse)
                el._minidoracatWantMouse = nil
            end
        end
    end
    pcall(dimMapBody, mm.inner, on) -- 地圖本體半透明（快照/還原見上方註解）
    if on then
        -- 進穿透的手勢殘留清理。titleBar 拖曳必須清：原版 onMouseDown 設
        -- dragging＋capture、清理在 onMouseUp——已被 gate 攔掉，漏清＝小地圖
        -- 永久黏著游標（onMouseMove 不在 gate 清單、會持續 setX/setY）。
        -- inner.rightMouseDown 同理：gate 攔掉原版 right-up 收尾的 stale 旗標
        local inner, tb = mm.inner, mm.titleBar
        if inner then
            inner._minidoracatFreelook = nil -- 穿透＝被動跟隨顯示：清停留、回中
            inner.dragging = false
            inner.rightMouseDown = false
            if inner.setCapture then pcall(inner.setCapture, inner, false) end
        end
        if tb then
            tb.dragging = false
            if tb.setCapture then pcall(tb.setCapture, tb, false) end
        end
    end
    if Core.applyChromeOpacity then pcall(Core.applyChromeOpacity, mm) end
end

-- 全玩家套用：事件 gate 是 class 層＝分割畫面全玩家生效，非事件面（旗標/變淡/
-- 清理）也必須全玩家收斂，否則 P2+ 只有行為沒有視覺、旗標半套。
-- mm 給定＝只套該實例（InitPlayer 逐玩家建立時）；nil＝套所有現存小地圖。
-- pcall 逐實例隔離：單一實例異常不拖垮其餘玩家與後續 save
local function applyGhost(mm)
    if mm then return (pcall(applyGhostTo, mm)) end
    if isGhost() and Core.cancelResize then pcall(Core.cancelResize) end
    for pn = 0, 3 do
        local m = getPlayerMiniMap and getPlayerMiniMap(pn)
        if m then pcall(applyGhostTo, m) end
    end
end
-- test:ghost-apply:end

local ghostHintUntil -- 切換瞬間膠囊提示（1.5 秒，同「已複製」時長慣例）

local function toggleGhost()
    local opt = modOptions and modOptions:getOption("GhostMode")
    if not opt then return end -- 匯出已依 modOptions 閘門，此路實務不可達
    opt:setValue(not opt:getValue())
    ghostHintUntil = getTimestampMs() + 1500
    applyGhost()
    PZAPI.ModOptions:save() -- 放尾端（FloatIconPos 慣例）：save 異常也不留
    -- 「值已翻但未套用」的半套狀態；跨重啟保留、三設定面同值
end

-- 切換提示膠囊＋每幀維護：inner 頂部置中（底部已被玩家座標列／freelook 提示佔用）。
-- 本 wrap 在主檔 prerender wrap 之外層（載入序）：先跑主檔全部繪製再疊此提示。
-- 小地圖隱藏時提示無處可畫＝靜默（可接受：FloatIcon 琥珀 tint 仍指示狀態）
if ISMiniMapInner and ISMiniMapInner.prerender then
    local originalGhostPrerender = ISMiniMapInner.prerender
    function ISMiniMapInner:prerender()
        originalGhostPrerender(self)
        if self._minidoracatGhostSnap and self.mapAPI and isGhost() then
            -- 未探索遮罩＝WorldMapVisited singleton：開大地圖（M）的樣式初始化會
            -- 把它重設回 a=1.0（ISMapDefinitions），每幀重壓（兩個 float setter，
            -- 成本可忽略）。底紙 quad 是 per-instance、42.20 無活路徑會重設
            -- （TERRAIN_IMAGE 死碼），dimMapBody 一次性設定即可、不需每幀補
            local a = ghostMapAlpha()
            self.mapAPI:setUnvisitedRGBA(BG_R * 0.915, BG_G * 0.915, BG_B * 0.915, a)
            self.mapAPI:setUnvisitedGridRGBA(BG_R * 0.777, BG_G * 0.777, BG_B * 0.777, a)
            -- 滑條每幀比對（mod 滑條慣例＝繪製端讀值即時生效；統一視窗滑條 handler
            -- 只寫值不觸發 apply）：值變了就還原→以新值重壓（dimMapBody 內建）
            if self._minidoracatGhostSnap.alphaUsed ~= a then
                pcall(dimMapBody, self, true)
            end
        end
        if not ghostHintUntil then return end
        if getTimestampMs() >= ghostHintUntil then
            ghostHintUntil = nil
            return
        end
        local txt = getText(isGhost() and "UI_MinidoracatMiniMap_GhostOn"
            or "UI_MinidoracatMiniMap_GhostOff")
        local tm = getTextManager()
        local tw = tm:MeasureStringX(UIFont.Small, txt)
        local fh = tm:getFontHeight(UIFont.Small)
        local x = math.max(8, math.floor((self.width - tw) / 2)) -- 底框 x-8 不出左緣
        self:drawRect(x - 8, 5, tw + 16, fh + 6, 0.72, 0, 0, 0)
        self:drawText(txt, x, 8, 1, 0.85, 0.4, 1, UIFont.Small)
    end
end

Core.isGhost = isGhost
Core.applyGhost = applyGhost
-- 無 PZAPI＝選項無處持久化、穿透整組停用：不匯出 toggleGhost。FloatIcon 的
-- tooltip/右鍵與主檔熱鍵分支都以 Core.toggleGhost 存在與否判斷——一閘全通，
-- 不會出現「tooltip 廣告但按了沒反應」
if modOptions then Core.toggleGhost = toggleGhost end
