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
-- 只讀快照（不寫入）：讀與寫分離——寫入中途拋錯時快照已在手上，restore 可救
-- （合併版的「邊讀邊寫」在多 stop 層寫到一半失敗會丟快照＝永久汙染，codex review）
local function snapLayerAlphas(layer)
    local stops = {}
    for si = 0, layer:getFillStops() - 1 do
        stops[si] = layer:getFillAlpha(si)
    end
    return stops
end
-- 寫入：stops[si] 為底值——帶 targetOf＝壓暗（寫 targetOf(原值)）、不帶＝還原（寫原值）
local function setLayerAlphas(layer, stops, targetOf)
    for si = 0, layer:getFillStops() - 1 do
        local a = stops[si]
        if a ~= nil then
            if targetOf then a = targetOf(a) end
            layer:setFillRGBA(si, layer:getFillRed(si), layer:getFillGreen(si),
                layer:getFillBlue(si), a)
        end
    end
end
local function dimHalf(a) return math.floor(a * ghostMapAlpha() + 0.5) end
local function dimZero() return 0 end
local ghostKindWarned -- 引擎改版把型別字串換掉時的一次性可觀測性（防無症狀退化）
local ghostDimWarned -- dim 拋錯級失敗的一次性可觀測性（pcall 吞錯＝不可診斷，實測回饋）
local ghostLayerWarned -- 逐層分類/快照/壓暗寫入失敗的一次性可觀測性（含 layer id/type）
local ghostRestoreWarned -- 還原寫入失敗獨立旗標：致命級（快照卡住）不可被上者靜音（review）
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
        -- 冪等：同值不重壓（多入口重複呼叫不得複利遞減）；滑條改動＝先還原再重壓。
        -- alphaUsed 語意：nil＝「未完整壓暗」sentinel（本輪 dimIncomplete、dim 中途
        -- 拋錯、還原失敗、或主檔防禦性重掛失效都是/設成 nil）——nil ~= curA 恆真，
        -- 走「先還原再以現值重壓」重試路徑；成功完整壓暗的尾端才寫入 curA。
        -- 還原以 getID 反查，重掛同 id 層寫回原值＝no-op
        local curA = ghostMapAlpha()
        if inner._minidoracatGhostSnap then
            if inner._minidoracatGhostSnap.alphaUsed == curA then return end
            dimMapBody(inner, false)
            -- 還原失敗（快照被保留）：放棄本次重壓——續走會以「半暗現值」蓋掉
            -- 舊快照＝永久汙染；ghostFrameTick 下幀重試（alphaUsed 已被清）
            if inner._minidoracatGhostSnap then return end
        end
        local n = st:getLayerCount()
        local kinds, pyramidFound, dimIncomplete = {}, false, false
        for li = 0, n - 1 do
            local ok, k = pcall(layerKind, st:getLayerByIndex(li))
            kinds[li] = ok and k or "skip"
            if not ok then
                -- 分類失敗（≠已識別的 skip 型別如 Line）：pyramid 誤 skip 會留 255、
                -- 且 pyramidFound 誤 false 讓 polygon 誤當內容——入重試旗標
                dimIncomplete = true
                if not ghostLayerWarned then
                    ghostLayerWarned = true
                    print("[MinidoracatMiniMap] ghost: classify layer failed (index=" .. li .. ")")
                end
            end
            if kinds[li] == "pyramid" then pyramidFound = true end
        end
        -- 快照「逐層先照後寫」：先 snapLayerAlphas 落快照、再寫入——寫到一半拋錯
        -- 也有整層還原憑證（邊讀邊寫版會丟快照＝永久汙染）。快照逐層即時掛上
        -- snap.layers：中途拋錯時已動的層仍可由退出路徑救回
        local snap = { layers = {} } -- alphaUsed 於完整壓暗成功的尾端才寫入（見 dimIncomplete 分支）
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
                local key = layerSnapKey(layer, li)
                local okSnap, stops = pcall(snapLayerAlphas, layer)
                if okSnap and stops then
                    snap.layers[key] = stops -- 寫入前先落快照：寫到一半拋錯也有還原憑證
                    if pcall(setLayerAlphas, layer, stops, target) then
                        touched = touched + 1
                    else
                        dimIncomplete = true
                        if not ghostLayerWarned then
                            ghostLayerWarned = true
                            print("[MinidoracatMiniMap] ghost: dim layer write failed (id="
                                .. tostring(key) .. " type=" .. tostring(k) .. ")")
                        end
                    end
                else
                    dimIncomplete = true -- 讀失敗＝該層未寫入、無需憑證，重試安全
                    if not ghostLayerWarned then
                        ghostLayerWarned = true
                        print("[MinidoracatMiniMap] ghost: snapshot layer fills failed (id="
                            .. tostring(key) .. " type=" .. tostring(k) .. ")")
                    end
                end
            end
        end
        -- not dimIncomplete：逐層失敗已有專屬 log-once，此警告專指「全層被分類
        -- 為 skip」（引擎型別字串改版的無症狀退化訊號），失敗情境下發它是誤導
        if touched == 0 and n > 0 and not dimIncomplete and not ghostKindWarned then
            ghostKindWarned = true
            print("[MinidoracatMiniMap] ghost: no style layers classified ("
                .. n .. " layers) — engine layer type strings changed?")
        end
        if dimIncomplete then
            -- 本輪未完整壓暗（分類失敗＝pyramid 可能誤 skip；寫失敗＝快照在手可還原；
            -- 讀失敗＝該層未動）：alphaUsed 保持 nil＝ghostFrameTick 走「先還原再重壓」
            -- 重試；retryAt 1s 節流擋持續性失敗的每幀重試風暴——每幀 2 趟全層跨界
            -- 寫入＋Kahlua 缺 method 的引擎 trace flush 刷屏（三 lane review 共識；
            -- give-up 計數器因滑條重置語意複雜而否決，1s 節流＝60x 降頻、修好後
            -- 1 秒內收斂）
            snap.retryAt = getTimestampMs() + 1000
        else
            snap.alphaUsed = curA -- 完整壓暗才落同值捷徑（中途拋錯時保持 nil＝必重試）
        end
        api:setBackgroundRGBA(BG_R, BG_G, BG_B, 0) -- 底紙 quad（per-instance；tick 每幀另重壓）
        -- 未探索遮罩：引擎 shader 硬編未探索區 alpha＝texel 積（恆 1）、頂點 col.a
        -- 不參與（media/shaders/worldMapVisited.frag:13 `vec4(col.rgb, texel.g*texel.r)`；
        -- 頂點色出處 WorldMapVisited.java:252/272）——setUnvisitedRGBA 的 alpha 是
        -- no-op，唯一可控是 rgb。穿透中 rgb×滑條值＝不透明暗化近似：暗景視覺等效
        -- 「同比例透明」（實測回饋 2026-08-19），亮景為暗霧（引擎限制，無法真透明；
        -- 關 HideUnvisited 會 setVisited(null)＝未探索 pyramid 全裸，洩漏，否決）。
        -- alpha 仍傳 curA：引擎未來若修 shader 即自動變真透明。
        -- 網格 shader 反而吃 col.a（worldMapGrid.frag:15），rgb 不需縮放
        api:setUnvisitedRGBA(BG_R * 0.915 * curA, BG_G * 0.915 * curA, BG_B * 0.915 * curA, curA)
        api:setUnvisitedGridRGBA(BG_R * 0.777, BG_G * 0.777, BG_B * 0.777, curA)
    else
        local snap = inner._minidoracatGhostSnap
        if not snap then return end
        if not st then
            -- styleAPI 缺席（反編譯上 getStyleAPI 惰性建構永不回 null——UIWorldMapV1
            -- .java:62-65，防禦性分支）：層還原無從執行，快照必須留下（清掉＝壓暗值
            -- 永久卡死、只剩 Recreate 能救），與壓暗側 st 早退對稱（review 抓出破口）
            snap.alphaUsed = nil
            return
        end
        local restoreFailed = false
        for li = 0, st:getLayerCount() - 1 do
            local layer = st:getLayerByIndex(li)
            local stops = snap.layers[layerSnapKey(layer, li)]
            if stops then
                if not pcall(setLayerAlphas, layer, stops) then
                    restoreFailed = true
                    if not ghostRestoreWarned then
                        ghostRestoreWarned = true
                        print("[MinidoracatMiniMap] ghost: restore layer failed (id="
                            .. tostring(layerSnapKey(layer, li)) .. ")")
                    end
                end
            end
        end
        -- 還原 vanilla 值（ISMapDefinitions.lua:163-166 同式；st 非 nil ⇒ api 非 nil）
        api:setBackgroundRGBA(BG_R, BG_G, BG_B, 1.0)
        api:setUnvisitedRGBA(BG_R * 0.915, BG_G * 0.915, BG_B * 0.915, 1.0)
        api:setUnvisitedGridRGBA(BG_R * 0.777, BG_G * 0.777, BG_B * 0.777, 1.0)
        if restoreFailed then
            snap.alphaUsed = nil -- 重入 dim 不得走「同值已壓」捷徑
            snap.retryAt = getTimestampMs() + 1000 -- 失敗重試節流（同壓暗側）
            return -- 快照留下：ghostFrameTick 依節流重試（清掉＝永久卡在壓暗值）
        end
        inner._minidoracatGhostSnap = nil -- 還原全數成功才丟憑證
    end
end
-- dim 的唯一入口（log-once）：pcall 吞錯＝不可診斷（實測回歸就是這樣藏起來的），
-- 失敗一律進 console.txt；拋錯時設重試節流——快照在手寫 snap.retryAt（alphaUsed
-- 延後寫入保證拋錯後必為 nil＝重試路徑），快照「前」拋錯（getLayerCount/分類迴圈
-- 的 getLayerByIndex）寫 inner._minidoracatGhostRetryAt（無快照時 tick 自癒分支的
-- 節流，codex review 抓出繞過）；回傳 pcall ok 供呼叫端判斷
local function dimSafely(inner, on)
    local ok, err = pcall(dimMapBody, inner, on)
    if not ok then
        if inner then
            local snap = inner._minidoracatGhostSnap
            if snap then snap.retryAt = getTimestampMs() + 1000
            else inner._minidoracatGhostRetryAt = getTimestampMs() + 1000 end
        end
        if not ghostDimWarned then
            ghostDimWarned = true
            print("[MinidoracatMiniMap] ghost: dim map body "
                .. (on and "apply" or "restore") .. " failed: " .. tostring(err))
        end
    end
    return ok
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
    dimSafely(mm.inner, on) -- 地圖本體半透明（快照/還原見上方註解）
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

-- 每幀維護（prerender 呼叫；離線測試 A9-A15）：穿透中「收斂」而非只靠一次性套用——
-- (1) 本實例沒有壓暗快照＝漏套（Recreate 重建後、dim 曾拋錯被吞、或 applyGhost
--     套到 stale 實例）→ 現場補壓。針對實測回歸「穿透開著卻整片不透明、影像層
--     看似消失」（2026-08-19；console 乾淨、確切觸發路徑未實證定位）的收斂防線：
--     不依賴根因假說——可見實例的 prerender 必然跑在可見實例上，上列任一候選
--     路徑都會在一幀內被補正；再發時 dimSafely/逐層 log-once 會落地診斷證據；
-- (2) 底紙 quad／未探索遮罩每幀重壓：未探索遮罩是 WorldMapVisited singleton，
--     開大地圖（M）的樣式初始化會重設回 a=1.0（ISMapDefinitions）；底紙 quad 屬
--     per-instance，42.20 無已知活重設路徑，防禦性一併重壓（成本＝三個 float setter）；
-- (3) alphaUsed ~= 滑條值＝滑條改動或「未完整壓暗」sentinel（nil）→ 先還原再重壓
--     （dimMapBody 內建）；retryAt 節流失敗重試（1s，見 dim 註解）；
-- (4) 穿透已關但本實例仍留快照（漏套退場路徑/還原失敗）→ 依節流還原（收斂性退場）。
local function ghostFrameTick(inner)
    if not (inner and inner.mapAPI) then return end
    if isGhost() then
        if not inner._minidoracatGhostSnap then
            -- 自癒補壓（失敗由 dimSafely log-once）；無快照的拋錯節流走 inner 欄位
            local ra = inner._minidoracatGhostRetryAt
            if not (ra and getTimestampMs() < ra) then
                dimSafely(inner, true)
                if inner._minidoracatGhostSnap then
                    inner._minidoracatGhostRetryAt = nil -- 建到快照＝節流交棒給 snap.retryAt
                end
            end
        end
        local snap = inner._minidoracatGhostSnap
        if not snap then return end
        local a = ghostMapAlpha()
        inner.mapAPI:setBackgroundRGBA(BG_R, BG_G, BG_B, 0)
        -- 未探索遮罩 rgb×滑條（shader 不吃 col.a，見 dim 註解）；grid 走真 alpha
        inner.mapAPI:setUnvisitedRGBA(BG_R * 0.915 * a, BG_G * 0.915 * a, BG_B * 0.915 * a, a)
        inner.mapAPI:setUnvisitedGridRGBA(BG_R * 0.777, BG_G * 0.777, BG_B * 0.777, a)
        if snap.alphaUsed ~= a
            and not (snap.retryAt and getTimestampMs() < snap.retryAt) then
            dimSafely(inner, true)
        end
    else
        local snap = inner._minidoracatGhostSnap
        if snap and not (snap.retryAt and getTimestampMs() < snap.retryAt) then
            dimSafely(inner, false)
        end
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
    PZAPI.ModOptions:save() -- 放尾端：save 異常也不留
    -- 「值已翻但未套用」的半套狀態；跨重啟保留、三設定面同值
end

-- 切換提示膠囊＋每幀維護：inner 頂部置中（底部已被玩家座標列／freelook 提示佔用）。
-- 本 wrap 在主檔 prerender wrap 之外層（載入序）：先跑主檔全部繪製再疊此提示。
-- 小地圖隱藏時提示無處可畫＝靜默（可接受：FloatIcon 琥珀 tint 仍指示狀態）
if ISMiniMapInner and ISMiniMapInner.prerender then
    local originalGhostPrerender = ISMiniMapInner.prerender
    function ISMiniMapInner:prerender()
        originalGhostPrerender(self)
        ghostFrameTick(self) -- 穿透收斂：自癒補壓/每幀重壓/滑條重壓/退場還原（見上）
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
