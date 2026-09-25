-- MinidoracatMiniMap_Zones.lua
-- 本檔範圍：Zone 圖層繪製——fill／lines／icons 三 pass、距離閘（distGateParams／
-- zoneWithinDist）、視窗候選快取（zcCandidates）與 provider 錯誤隔離（safeDrawZone）。
-- 資料來源＝主檔 registerZoneProvider 的 registry（Core.registeredZoneProviders，
-- 共享同一實例）；本檔只渲染，不持有 registry、不碰 API 表（zone API 仍在主檔）。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore；本檔載入期只讀取其「一次性賦值」的穩定引用。主檔的
-- 兩個 prerender wrap 經 Core.drawZonePass 呼叫時查表（本檔缺席＝依 flagKey
-- log-once 可診斷，不炸 prerender）。
-- 拆檔緣由（2026-09-03）：主檔主 chunk locvar 175 貼 Kahlua 200 上限（verify 警戒
-- 190），本段 24 個頂層 local 拆出＝主檔回到 151；段內程式碼逐位元不變，
-- 離線測試 scripts/test_zone_render.lua 改從本檔抽 test:zone-render 切片。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- 主檔共用成員（皆為主檔載入期一次性賦值的穩定引用；modOptions 無 PZAPI 時為 nil，
-- 沿用原 nil 檢查。registeredZoneProviders 共享同一實例：主檔 registerZoneProvider
-- 的後續插入，本檔每幀讀到的即最新內容）
local modOptions = Core.modOptions
local getBoolOption = Core.getBoolOption
local getSliderValue = Core.getSliderValue
local displayDist = Core.displayDist
local unifiedCsvSet = Core.unifiedCsvSet
local deriveAffine = Core.deriveAffine
local registeredZoneProviders = Core.registeredZoneProviders
local hasExternalZoneProvider = Core.hasExternalZoneProvider
local visibleWorldAABB = Core.visibleWorldAABB
local drawClippedEdge = Core.drawClippedEdge
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

--------------------------------------------------------------------------------
-- Zone 圖層（資料由 registerZoneProvider 的 addon 提供；本 MOD 只渲染）：
-- 分兩段插入以對齊 z-order——fillPass 走最底層（base map 之上、框線之下），
-- linePass（框線＋名稱）與 drawMapBounds 同層。無 provider 或全空表＝dormant 零成本。
-- 閘門 per-provider：外部 addon provider 受 ZoneLayer 總開關（關則跳過該 provider、
-- 不呼叫）＋自訂區域顯示距離閘（ZoneDisplayDistance）；內部 provider（internal，
-- 如內建 POI）不受 ZoneLayer 連坐，由自家開關控制＋受 POI 顯示距離閘
-- （PoiDisplayDistance）。兩類距離閘同經 distGateParams/zoneWithinDist 合成。
--------------------------------------------------------------------------------

-- 填色：每 rect 四角 worldToUIX/Y 投影（等軸測下矩形成菱形）→ 投影後 AABB 出視窗即略過
-- （DrawPolygon 不裁切、不查 isVisible，角落小地圖會畫出視窗外，研究 §1）→ drawPolygon
-- 純色填（⚠ 參數序 r,g,b,a）。整段包 setStencilRect/clearStencilRect 硬裁到元件矩形，
-- 兜住投影誤差與貼齊視窗邊的溢出（真 GPU stencil，ISUIElement.lua:459/475）。
-- test:zone-render:start
-- Zone provider 繪製錯誤 log-once：provider 是外部 addon，個別隔離後壞的不得拖垮整個
-- pass；依 owner 各記一次（沿用動物圖標 log-once 策略），旗標存 inner 實例
local function zoneProviderErrorOnce(inner, owner, err)
    local logged = inner._minidoracatZoneProviderErr
    if not logged then
        logged = {}
        inner._minidoracatZoneProviderErr = logged
    end
    if not logged[owner] then
        logged[owner] = true
        log("Zone provider draw failed (" .. tostring(owner) .. "): " .. tostring(err))
    end
end

-- 繪製本體拆出：drawZoneFill 用 pcall(具名函式) 包起免每幀配置閉包；stencil 開啟狀態
-- 記在 inner 實例，跨 pcall 邊界回傳給呼叫端做無條件清除（見 drawZoneFill 的 A1 保護）
-- 區塊縮放 LOD 檔位（px/世界格，mapAPI:getWorldScale()；原版標記同機制
-- WorldMapGridSquareMarker.java:45）：帶 lodRect 的 zone（POI）在
-- < HIDE 整區塊不畫（此縮放下區塊已是色點，只留圖標）、< DETAIL 畫聯集框
-- （一棟一框，2~3px/格下與逐房間視覺無異、成本 1/3）、>= DETAIL 逐房間
-- 平面圖＋名稱。無 lodRect 的 zone 不參與、任何縮放照畫（Zones addon 自
-- 0.2.x 起對建物尺度區域〔聯集最長邊 ≤100 格〕自動附 lodRect 進 LOD，
-- 大範圍區域仍不附、維持全縮放可見——見其 attachLodRect；內建 POI 自
-- 0.14.1 起同判準豁免大型地標——見 MinidoracatMiniMapPOI.lua 的
-- POI_LOD_MAX_EDGE，177 格的地堡拉遠變色點前就被藏掉是誤傷）。
local ZONE_LOD_HIDE = 1.5
local ZONE_LOD_DETAIL = 6
-- 區塊底襯外擴量（螢幕 px；/scale 換算世界格後走同一仿射投影）：haloAlpha zone
-- 於細節檔在每 rect 填色下方先畫外擴此值的暗色 quad——無框線的區塊靠這圈暗色
-- 描邊與地圖及相鄰區塊分界。以螢幕 px 定義使縮放下描邊視覺粗細恆定
local ZONE_HALO_PX = 2
local lodSingle = {} -- 中距離檔重用的單元素 rect 清單（避免每 zone 每幀配置）
-- 圖標去重疊格（generation 標記免清表）：中/遠距下 lodRect zone 的圖標在同一
-- 「圖標尺寸」螢幕格內只畫第一顆——拉遠時數百顆互疊的圖標是遠距檔最大殘餘
-- 成本（每顆 1 次 drawTextureScaled Java 呼叫），疊在同格的視覺上也不可分辨
local iconGrid = {}
local iconGridGen = 0
-- zone 名稱寬度快取（ZR-4，lines pass 用）：key＝名稱字串。renderer 自有——
-- provider 回傳表是只讀契約，不得把快取寫進去
local zoneNameWidth = {}
-- 外部 zone 類別停用清單（ZoneCategoryFilter CSV；統一視窗「自訂區域」區塊的
-- 類別勾選寫入）：只作用於外部 provider 的 zone——內部 POI 有自己的 Cat_ 篩選，
-- 且其 category 欄與伺服器自訂類別是不同命名空間。無選項/空值＝全開。
-- raw 字串比對快取（同 adotsDisabledGroups 手法），選項未變不重解析
local zoneCatCache = { raw = nil, set = nil }
local function zoneDisabledCats()
    if not modOptions then return nil end
    local opt = modOptions:getOption("ZoneCategoryFilter")
    if not opt then return nil end
    local raw = tostring(opt:getValue() or "")
    if zoneCatCache.raw ~= raw then
        zoneCatCache.raw = raw
        zoneCatCache.set = unifiedCsvSet(raw)
    end
    return zoneCatCache.set
end

-- 顯示距離閘參數（沙盒＋全域上限 AllInfoDistance＋玩家自訂滑條，經 displayDist
-- 合成取最小正值）：internal provider（內建 POI）走 PoiDisplayDistance，外部
-- addon zone（自訂區域等）走 ZoneDisplayDistance——兩者獨立啟用。語意近安全
-- 屋距離閘——zone 矩形（distRects 或 rects）最近點距玩家 N 格內才顯示；二維、
-- 不計樓層。回傳 px, py, pdist², zdist²（各自未啟用＝nil＝該類全放行）與
-- poiBlocked/zoneBlocked（該類距離啟用但缺玩家：fail closed，該類 provider
-- 整段不畫——同 drawSafehouses 的缺玩家語意）。
local function distGateParams(inner)
    local pn = inner.playerNum or 0
    local pdist = displayDist("PoiDisplayDistance", pn)
    -- zdist 僅在有外部 provider 時求值：displayDist 內含 "Client"..name 字串
    -- 配置＋選項/沙盒查找，純本體（無 zone addon）每幀 3 pass×2 表面全屬浪費
    -- （三 lane review 同報）；hasExternalZoneProvider 是 ≤2 項純 Lua 迴圈
    local zdist = hasExternalZoneProvider() and displayDist("ZoneDisplayDistance", pn) or nil
    if not pdist and not zdist then return nil, nil, nil, nil, false, false end
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then
        return nil, nil, nil, nil, pdist ~= nil, zdist ~= nil
    end
    return playerObj:getX(), playerObj:getY(),
        pdist and pdist * pdist or nil, zdist and zdist * zdist or nil, false, false
end

-- 玩家點到矩形最近點的距離平方；夾限用純 Lua 比較而非 math.max/min——Kahlua
-- 下庫函式是 JavaFunction，每 zone 多次跨界呼叫在預裁前發生、全圖 ~1669 筆
-- ×1~3 pass 會積成可觀成本
local function rectDist2(rc, px, py)
    local dx = px < rc.x1 and (rc.x1 - px) or (px > rc.x2 and (px - rc.x2) or 0)
    local dy = py < rc.y1 and (rc.y1 - py) or (py > rc.y2 and (py - rc.y2) or 0)
    return dx * dx + dy * dy
end

-- zone 是否落在距離內：逐矩形判距，任一矩形最近點在 N 格內即顯示。量測對象
-- ＝distRects（有有效元素時）否則 rects——POI 整棟外框模式畫整棟框但仍量分類
-- 房間，使該外觀開關不改變可見距離。⚠ lodRect 不是整棟建築 bbox，逐房間模式
-- 下是分類房間聯集的 AABB（大型建物的分類房間可能只佔一角，AABB 也含無房間的
-- 空白區——codex review 以實資料證明兩者可差數十格），故僅作快速排除：點到
-- AABB 的距離是點到任一內含矩形距離的下界，AABB 超距＝全部超距，免逐矩形。
-- 快排的適用面（lodCovers＝呼叫端傳 provider.internal）：
--   · rects 路徑恆可快排——lodRect 契約保證涵蓋 rects；
--   · distRects 路徑僅 internal 快排——POI 建構保證 distRects ⊆ lodRect
--     （整棟模式 distRects＝原房間矩形、lodRect 由整棟框算出；且該模式
--     distRects 可達一棟 200+ 房間，無快排時超距 zone 無法提早跳出，會回退
--     0.16.0 壓掉的 1669-zone 鬆判熱點——claude lane review）；外部 addon 的
--     distRects 契約不要求含於 lodRect，快排會錯誤隱藏（codex review）。
-- distRects 型別防呆（iconRect 同款標準，但更深一層——codex lane review 兩輪
-- 論證：safeDrawZone 的 pcall 不是安全降級，provider 每幀回同一壞表＝整層
-- （含 POI）每幀重滅直到資料改，滅層防護值得付跨界檢查）：
--   · 表級：distRects 非 table（欄位型別搞錯）→ 視為未提供、回退 rects；
--     type() 是 JavaFunction 跨界，nil 先短路——無 distRects 的多數 zone 不付；
--   · 元素級：非 table 元素（平陣列 {42,43} 是現實失誤形態；number 索引在
--     Kahlua 拋錯）與缺欄元素一律跳過；成本＝每有效判定元素 +1 次 type()
--     跨界，僅距離閘啟用時發生、且 internal 由 lodRect 快排先擋超距 zone；
--   · 無任何有效元素（空表／全殘缺／全非 table）＝視為未提供、回退 rects
--     路徑（codex lane review：空表原本 n==0 放行＝繞過距離閘）；有有效元素
--     但全部超距＝隱藏——絕不回退 rects，那會讓整棟框替房間解鎖可見距離。
-- rects 路徑不驗欄位：rects 是繪製用硬性欄位，殘缺本就炸 pass（既有契約面）。
-- 無矩形者放行（後續本就無物可畫）。呼叫端以該 provider 的有效距離 gd2 短路
-- （閘未啟用零成本）；fill/lines/icons 三 pass 同一判定，整 zone 一致顯隱。
local function zoneWithinDist(z, px, py, dist2, lodCovers)
    local dr = z.distRects
    if dr ~= nil and type(dr) == "table" then
        if lodCovers then
            local lod = z.lodRect
            if lod and rectDist2(lod, px, py) > dist2 then return false end
        end
        local seen = false
        for i = 1, #dr do
            local rc = dr[i]
            if type(rc) == "table" and rc.x1 and rc.y1 and rc.x2 and rc.y2 then
                seen = true
                if rectDist2(rc, px, py) <= dist2 then return true end
            end
        end
        if seen then return false end
    end
    local lod = z.lodRect
    if lod and rectDist2(lod, px, py) > dist2 then return false end
    local rects = z.rects
    local n = rects and #rects or 0
    if n == 0 then return true end
    for i = 1, n do
        if rectDist2(rects[i], px, py) <= dist2 then return true end
    end
    return false
end

-- ═══ 三 pass 共用：視窗候選快取（ZC；2026-08-19 GameProfiler Y/W 輪定位） ═══
-- 熱點不是 draw call 而是 Kahlua 每 UI 幀 3 pass × 全量 zone（POI ~1669 筆）的
-- 篩選迴圈本身（無 JIT，每迴圈體 ~µs 級；W/Y 差分：Lua 疊繪 ~6.0ms/次中
-- POI/Zone 佔 ~5.6ms）。快取「與外擴視窗相交＋通過共通閘門」的候選索引，
-- 三 pass 共用同一份；pass 專屬條件（fillAlpha/border/icon/LOD/精確距離閘）
-- 仍逐候選判定——候選是精確集的超集，繪製結果逐像素不變。
-- 失效鍵：zones 表引用（POI 重建即換表）＋ disCats 集引用＋ 距離閘參數
-- （per-provider：internal 走 PoiDisplayDistance、外部走 ZoneDisplayDistance，
-- 由呼叫端選定後經 gate2 傳入；未啟用＝nil，候選集與玩家座標無關、不因
-- 玩家移動被迫重建）＋ 玩家移動 >16 格（僅距離閘生效時）＋
-- 視窗溢出外擴框（zoom/尺寸變化必溢出）＋ TTL 1s——registerZoneProvider 契約
-- 只要求回表，允許 addon 原地增刪同一表，identity 抓不到 mutate，TTL 兜底
-- （stale 顯示上限 1s；靜態 addon 零影響）。TTL 存建構時刻而非到期時刻：
-- 時鐘回撥（now < builtMs）視為到期，與玩家座標匯出的節流慣例一致。
-- provider.fn 每幀照呼（identity 鍵需要當前表引用）；每幀回新表的 addon 自然
-- 退化為每幀重建——即原全量掃描成本，外加每 zone 一次 zcZoneBBox 呼叫與
-- list 寫入（對該類 provider 是淨增；addon 回報 0.16.0 後變慢先查此），不錯繪。
local ZC_PAD = 64      -- 候選外擴（世界格）：站立零重建，移動每 ~PAD/4 格一次
local ZC_TTL_MS = 1000
local ZC_MOVE2 = 256   -- 距離閘生效時玩家移動平方閾值（16 格）

-- zone 可繪幾何的聯集 AABB：lodRect 或逐 rects，再併 iconRect——
-- lodRect 是 provider API 契約要求的 rects 涵蓋框（registerZoneProvider 文檔；
-- 內部 POI provider 由建構保證）：不合規（過小）的 lodRect 先前只影響 LOD
-- 檔位，本快取讓 detail zoom 也依它裁候選（信任契約與 lodSingle 一致）。
-- iconRect 是「rects 外」的合法圖標錨點（icons pass 契約：四欄齊備才採用），
-- 不併會讓「框在 A、圖標釘在 B」的合法 zone 被候選整個裁掉（codex/grok review）
local function zcZoneBBox(z)
    local x1, y1, x2, y2
    local lod = z.lodRect
    if lod then
        x1, y1, x2, y2 = lod.x1, lod.y1, lod.x2, lod.y2
    else
        local rects = z.rects
        local n = rects and #rects or 0
        if n > 0 then
            local rc = rects[1]
            x1, y1, x2, y2 = rc.x1, rc.y1, rc.x2, rc.y2
            for i = 2, n do
                rc = rects[i]
                if rc.x1 < x1 then x1 = rc.x1 end
                if rc.y1 < y1 then y1 = rc.y1 end
                if rc.x2 > x2 then x2 = rc.x2 end
                if rc.y2 > y2 then y2 = rc.y2 end
            end
        end
    end
    local ir = z.iconRect
    if ir and ir.x1 and ir.y1 and ir.x2 and ir.y2 then
        if x1 == nil then
            x1, y1, x2, y2 = ir.x1, ir.y1, ir.x2, ir.y2
        else
            if ir.x1 < x1 then x1 = ir.x1 end
            if ir.y1 < y1 then y1 = ir.y1 end
            if ir.x2 > x2 then x2 = ir.x2 end
            if ir.y2 > y2 then y2 = ir.y2 end
        end
    end
    return x1, y1, x2, y2
end

-- 消費端 stale-index sentinel：TTL 內同表被原地移除元素時 zones[cand[ci]] 為
-- nil——回這張凍結空表讓 pass 的既有條件（z.fill/z.border/z.icon 全 nil）自然
-- 跳過，不得拋錯——否則 safeDrawZone 中止＝整層圖層當幀消失（codex review）
local ZC_EMPTY = {}

local function zcCandidates(inner, provider, zones, disCats, scale,
                            vMinX, vMaxX, vMinY, vMaxY, ppx, ppy, gate2)
    local zc = inner._minidoracatZC
    if not zc then zc = {}; inner._minidoracatZC = zc end
    local e = zc[provider]
    local now = getTimestampMs()
    -- zones 表比較用 rawequal：外部 addon 的表帶 __eq metatable 時 `==` 會呼叫
    -- 它——誤判相等＝沿用錯候選、拋錯＝整個 pass 中止（codex review）。disCats
    -- 走 `==`（zoneDisabledCats 只回內部 cache 表或 nil，無 __eq 面）。rawequal/
    -- rawget 在 Kahlua BaseLib 有註冊——證據 scripts/tests/test_kahlua_globals.py
    -- 的 verified 白名單（勿「簡化」回 ==／[]，那正是要防的路徑）。
    -- 失效鍵：zones 表引用／disCats 集引用／距離閘參數 gate2（per-provider，
    -- 呼叫端選定：internal＝POI 距離、外部＝自訂區域距離）／scale
    -- （zoom 檔位；halo 世界尺寸依它）／TTL／containment 框／玩家移動（閘生效時）
    if e and rawequal(e.zones, zones) and e.disCats == disCats and e.gate2 == gate2
        and e.scale == scale -- zoom 檔位未必伴隨視窗溢出：獨立失效鍵（A14-11 鎖）
        -- TTL 只為「外部 addon 原地 mutate」兜底；internal POI provider 一律原子換表
        -- （MinidoracatMiniMapPOI.lua buildPoiConverted：poiZones = built），identity 鍵
        -- 已足以失效，站立時不再每秒全量重建 ~1670 個 zone bbox（正式服取樣
        -- zcZoneBBox 0.22-0.25%）。時鐘回撥仍重建（now < builtMs）
        and now >= e.builtMs and (provider.internal or now - e.builtMs < ZC_TTL_MS)
        and vMinX >= e.qMinX and vMaxX <= e.qMaxX
        and vMinY >= e.qMinY and vMaxY <= e.qMaxY then
        if not gate2 then return e.list end
        local dx, dy = ppx - e.ppx, ppy - e.ppy
        if dx * dx + dy * dy <= ZC_MOVE2 then return e.list end
    end
    if not e then
        e = {}
        zc[provider] = e
    end
    e.zones = zones
    e.disCats = disCats
    e.gate2 = gate2
    e.scale = scale
    e.ppx, e.ppy = ppx, ppy
    e.builtMs = now
    -- 兩層外擴框（codex review：halo 必須留在「containment 之外」的餘裕）——
    --   containment 框（qMin/qMax）＝視窗 ±ZC_PAD：命中時允許視窗平移的上限；
    --   建構篩選框（bMin/bMax）＝視窗 ±(ZC_PAD＋halo 世界尺寸)：zone bbox 相交
    --   測試用。如此「篩選框外的 zone」距任何允許的視窗恆 > halo，其 halo
    --   繪製外擴（ZONE_HALO_PX/scale）伸不進窗——超集在平移滿 PAD 時仍成立
    local haloPad = ZONE_HALO_PX / scale
    e.qMinX, e.qMaxX = vMinX - ZC_PAD, vMaxX + ZC_PAD
    e.qMinY, e.qMaxY = vMinY - ZC_PAD, vMaxY + ZC_PAD
    local bMinX, bMaxX = e.qMinX - haloPad, e.qMaxX + haloPad
    local bMinY, bMaxY = e.qMinY - haloPad, e.qMaxY + haloPad
    -- 距離閘鬆判上限：精確 zoneWithinDist 留在各 pass 內，這裡 +PAD+halo+16
    -- 保證「移動閾值內的任何精確通過者」都在候選中（精確判基準點與建構錨點
    -- 至多差 16 格，rect 距離差至多同值；PAD/halo 項涵蓋視窗重用餘裕）
    local loose2
    if gate2 then
        local r = math.sqrt(gate2) + ZC_PAD + haloPad + 16
        loose2 = r * r
    end
    local list = e.list
    if list then
        for i = #list, 1, -1 do list[i] = nil end
    else
        list = {}; e.list = list
    end
    -- bbox 每次現算：重建本就全清語意（TTL 兜 in-place mutate），跨呼叫 memo
    -- 是死路——留表只會每次重建配置 ~1670 個垃圾小表（claude review）
    local n = 0
    for zi = 1, #zones do
        -- z 可為 nil：`zones[i]=nil` 挖洞屬違約輸入（契約 C2 要求連續陣列）。
        -- guard 只保證不拋錯（與消費端 sentinel 對稱）；`#` 對洞表未定義，
        -- 洞後項目可能不掃＝漏畫（快取前的三 pass 同此語意，非本快取引入）
        local z = zones[zi]
        if z then
            local x1, y1, x2, y2 = zcZoneBBox(z)
            if not (disCats and z.category and disCats[z.category])
                and (not loose2 or zoneWithinDist(z, ppx, ppy, loose2, provider.internal))
                and (x1 == nil or (x2 >= bMinX and x1 <= bMaxX
                    and y2 >= bMinY and y1 <= bMaxY)) then
                n = n + 1
                list[n] = zi
            end
        end
    end
    return list
end

local function drawZoneFillBody(inner)
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local scale = mapAPI:getWorldScale()
    -- 視野預裁（同 drawZoneIcons，v3 後區塊模式數千矩形×8 次投影/幀會壓垮
    -- FPS）：世界座標 AABB 不相交者直接跳過，連投影都不做——外接框是視窗
    -- 超集，被裁者投影後必在窗外、原本的螢幕裁切也不會畫，逐像素不變。
    -- 退化行為：uiToWorld 未就緒回 0.0F 時外接框塌縮＝fill/line 也整幀全裁，
    -- 與圖標 pass 同退化（舊碼該情況同樣什麼都畫不出，見 icons pass 論證）
    local vMinX, vMaxX, vMinY, vMaxY = visibleWorldAABB(inner)
    local acx = math.floor((vMinX + vMaxX) / 2)
    local acy = math.floor((vMinY + vMaxY) / 2)
    local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
    local ppx, ppy, pdist2, zdist2, poiBlocked, zoneBlocked = distGateParams(inner)
    for pi = 1, #registeredZoneProviders do
        local provider = registeredZoneProviders[pi]
        -- 閘門：外部 provider 受 ZoneLayer 總閘（internal 不受）＋ per-provider 母開關
        -- （optionKey 有給才 gate）；距離閘 per-provider——internal 走 POI 距離
        -- （PoiDisplayDistance），外部走自訂區域距離（ZoneDisplayDistance），皆含
        -- 全域上限與玩家滑條（見 distGateParams；該類距離啟用但缺玩家＝fail closed
        -- 整段跳過）；任一關則 pok 留 nil、整段跳過
        local gd2, gBlocked
        if provider.internal then gd2, gBlocked = pdist2, poiBlocked
        else gd2, gBlocked = zdist2, zoneBlocked end
        local pok, zones
        if not gBlocked
            and (provider.internal or getBoolOption("ZoneLayer", true))
            and (not provider.optionKey or getBoolOption(provider.optionKey, true)) then
            -- A2：每個 provider 個別 pcall，壞的跳過續跑下一個（附 owner，log-once）
            pok, zones = pcall(provider.fn)
        end
        if pok == false then
            zoneProviderErrorOnce(inner, provider.owner, zones)
        -- hasFill 聚合旗標（perf 稽核 ZR-1）：false＝provider 聲明本 pass 無可畫
        -- 內容，整段跳過（預設純圖標模式下省每幀全 zone 空掃）；nil＝未聲明
        -- （外部 addon），照舊逐 zone 判斷
        elseif type(zones) == "table" and zones.hasFill ~= false then
            -- 外部 zone 類別篩選（內部 POI 走自家 Cat_，不受此清單影響）
            local disCats = not provider.internal and zoneDisabledCats() or nil
            local cand = zcCandidates(inner, provider, zones, disCats, scale,
                vMinX, vMaxX, vMinY, vMaxY, ppx, ppy, gd2)
            for ci = 1, #cand do
                local z = rawget(zones, cand[ci]) or ZC_EMPTY -- rawget: stale slot 不得觸發第三方 __index（codex review）
                local fill, rects = z.fill, z.rects
                local lod = z.lodRect
                -- fillAlpha==0（如 POI 圖標模式）早退，連投影都省；LOD 拉遠檔整區不畫；
                -- zone 另過該 provider 的顯示距離閘（not gd2 先行短路：閘未啟用
                -- ——絕大多數玩家的預設——不付逐 zone 函式呼叫）
                if fill and rects and z.fillAlpha ~= 0
                    and not (disCats and z.category and disCats[z.category])
                    and not (lod and scale < ZONE_LOD_HIDE)
                    and (not gd2 or zoneWithinDist(z, ppx, ppy, gd2, provider.internal)) then
                    local a = z.fillAlpha or 0.2
                    local rn = #rects
                    if lod and scale < ZONE_LOD_DETAIL then
                        lodSingle[1] = lod
                        rects, rn = lodSingle, 1
                    end
                    -- 底襯 pass（haloAlpha）：先畫全部外擴暗色 quad、再畫
                    -- 全部填色——分兩圈使同 zone 相鄰矩形（L 形建物）的內部接縫被後畫
                    -- 的填色蓋掉，暗邊只留在區塊外緣；跨 zone 的暗邊蓋在先畫的鄰棟填色
                    -- 上，正是要的分界。成本每 rect 1 次 drawPolygon（stencil 裁切、
                    -- 零 Lua 裁線），遠低於舊框線的 4 條 drawClippedEdge。
                    -- 檔位：lodRect zone 細節檔限定（城市尺度 fill 是效能熱點，中距檔
                    -- 維持純填色零新增成本）；無 lodRect 的地標/大範圍 zone 全檔位畫
                    -- ——地堡實測回饋：橄欖綠 0.2 alpha 融進迷彩地形，中距整棟剛好
                    -- 同框時沒有暗邊＝「有染色卻看不出區域」；拉近後框大於視窗、邊
                    -- 又在螢幕外。此類 zone 全圖僅 20 筆地標＋少數伺服器大區域，
                    -- 每 rect 多 1 次 drawPolygon 可忽略
                    local halo = z.haloAlpha
                    if halo and halo > 0 and (lod == nil or scale >= ZONE_LOD_DETAIL) then
                        local wpad = ZONE_HALO_PX / scale
                        for ri = 1, rn do
                            local rc = rects[ri]
                            local hx1, hy1 = rc.x1 - wpad, rc.y1 - wpad
                            local hx2, hy2 = rc.x2 + wpad, rc.y2 + wpad
                            if hx2 >= vMinX and hx1 <= vMaxX and hy2 >= vMinY and hy1 <= vMaxY then
                                local dx1, dy1 = hx1 - acx, hy1 - acy
                                local dx2, dy2 = hx2 - acx, hy2 - acy
                                local ux1, uy1 = p0x + dx1 * sxx + dy1 * syx, p0y + dx1 * sxy + dy1 * syy
                                local ux2, uy2 = p0x + dx2 * sxx + dy1 * syx, p0y + dx2 * sxy + dy1 * syy
                                local ux3, uy3 = p0x + dx2 * sxx + dy2 * syx, p0y + dx2 * sxy + dy2 * syy
                                local ux4, uy4 = p0x + dx1 * sxx + dy2 * syx, p0y + dx1 * sxy + dy2 * syy
                                -- 純 Lua min/max 比較鏈（ZR-2：math.* 在 Kahlua 是 JavaFunction
                                -- 跨界呼叫——rectDist2 既有先例；每個過預裁 rect 省 4 次跨界）
                                local minx, maxx = ux1, ux1
                                if ux2 < minx then minx = ux2 elseif ux2 > maxx then maxx = ux2 end
                                if ux3 < minx then minx = ux3 elseif ux3 > maxx then maxx = ux3 end
                                if ux4 < minx then minx = ux4 elseif ux4 > maxx then maxx = ux4 end
                                local miny, maxy = uy1, uy1
                                if uy2 < miny then miny = uy2 elseif uy2 > maxy then maxy = uy2 end
                                if uy3 < miny then miny = uy3 elseif uy3 > maxy then maxy = uy3 end
                                if uy4 < miny then miny = uy4 elseif uy4 > maxy then maxy = uy4 end
                                if maxx >= 0 and minx <= w and maxy >= 0 and miny <= h then
                                    if not inner._minidoracatZoneStencilOn then
                                        inner:setStencilRect(0, 0, w, h)
                                        inner._minidoracatZoneStencilOn = true
                                    end
                                    inner:drawPolygon(nil, ux1, uy1, ux2, uy2, ux3, uy3, ux4, uy4,
                                        0, 0, 0, halo)
                                end
                            end
                        end
                    end
                    for ri = 1, rn do
                        local rc = rects[ri]
                        if rc.x2 >= vMinX and rc.x1 <= vMaxX and rc.y2 >= vMinY and rc.y1 <= vMaxY then
                            local dx1, dy1 = rc.x1 - acx, rc.y1 - acy
                            local dx2, dy2 = rc.x2 - acx, rc.y2 - acy
                            local ux1, uy1 = p0x + dx1 * sxx + dy1 * syx, p0y + dx1 * sxy + dy1 * syy
                            local ux2, uy2 = p0x + dx2 * sxx + dy1 * syx, p0y + dx2 * sxy + dy1 * syy
                            local ux3, uy3 = p0x + dx2 * sxx + dy2 * syx, p0y + dx2 * sxy + dy2 * syy
                            local ux4, uy4 = p0x + dx1 * sxx + dy2 * syx, p0y + dx1 * sxy + dy2 * syy
                            -- 純 Lua min/max 比較鏈（ZR-2，同 halo 段註解）
                            local minx, maxx = ux1, ux1
                            if ux2 < minx then minx = ux2 elseif ux2 > maxx then maxx = ux2 end
                            if ux3 < minx then minx = ux3 elseif ux3 > maxx then maxx = ux3 end
                            if ux4 < minx then minx = ux4 elseif ux4 > maxx then maxx = ux4 end
                            local miny, maxy = uy1, uy1
                            if uy2 < miny then miny = uy2 elseif uy2 > maxy then maxy = uy2 end
                            if uy3 < miny then miny = uy3 elseif uy3 > maxy then maxy = uy3 end
                            if uy4 < miny then miny = uy4 elseif uy4 > maxy then maxy = uy4 end
                            if maxx >= 0 and minx <= w and maxy >= 0 and miny <= h then
                                if not inner._minidoracatZoneStencilOn then
                                    inner:setStencilRect(0, 0, w, h)
                                    inner._minidoracatZoneStencilOn = true
                                end
                                inner:drawPolygon(nil, ux1, uy1, ux2, uy2, ux3, uy3, ux4, uy4,
                                    fill.r, fill.g, fill.b, a)
                            end
                        end
                    end
                end
            end
        end
    end
end

local function drawZoneFill(inner)
    if #registeredZoneProviders == 0 then return end
    inner._minidoracatZoneStencilOn = false
    -- A1：繪製本體整段包 pcall，clearStencilRect 於其後無條件執行——setStencilRect 後
    -- 任何繪製/provider 錯誤都不得漏掉 clear，否則引擎全域 stencilLevel 洩漏（set 未配對
    -- clear）→ 當幀後續 UI 持續被小地圖矩形裁切
    local ok, err = pcall(drawZoneFillBody, inner)
    if inner._minidoracatZoneStencilOn then inner:clearStencilRect() end
    -- clear 已保證執行後，把繪製錯誤交回呼叫端 safeDrawZone 的 log-once（保留原行為）
    if not ok then error(err, 0) end
end

-- 框線＋名稱：複用 drawClippedEdge（Liang-Barsky Lua 裁切）畫每 rect 四邊；
-- 名稱仿 drawMapBounds 置中畫法（畫在第一個 rect 中心；⚠ drawRect 參數序 a,r,g,b）
local function drawZoneLines(inner)
    if #registeredZoneProviders == 0 then return end
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local tm = getTextManager()
    local th = tm:getFontHeight(UIFont.Small)
    local scale = mapAPI:getWorldScale()
    -- 視野預裁（同 drawZoneFillBody）：世界座標不相交者跳過投影
    local vMinX, vMaxX, vMinY, vMaxY = visibleWorldAABB(inner)
    local acx = math.floor((vMinX + vMaxX) / 2)
    local acy = math.floor((vMinY + vMaxY) / 2)
    local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
    local ppx, ppy, pdist2, zdist2, poiBlocked, zoneBlocked = distGateParams(inner)
    for pi = 1, #registeredZoneProviders do
        local provider = registeredZoneProviders[pi]
        -- 閘門（同 drawZoneFill）：外部受 ZoneLayer 總閘＋per-provider 母開關＋自訂
        -- 區域距離閘；internal 不受，但另受 POI 顯示距離閘（皆含全域上限＋玩家
        -- 滑條；該類距離啟用但缺玩家＝fail closed）
        local gd2, gBlocked
        if provider.internal then gd2, gBlocked = pdist2, poiBlocked
        else gd2, gBlocked = zdist2, zoneBlocked end
        local pok, zones
        if not gBlocked
            and (provider.internal or getBoolOption("ZoneLayer", true))
            and (not provider.optionKey or getBoolOption(provider.optionKey, true)) then
            -- A2：每個 provider 個別 pcall，壞的跳過續跑下一個（附 owner，log-once）
            pok, zones = pcall(provider.fn)
        end
        if pok == false then
            zoneProviderErrorOnce(inner, provider.owner, zones)
        elseif type(zones) == "table" and zones.hasLine ~= false then -- ZR-1（同 fill pass）
            local disCats = not provider.internal and zoneDisabledCats() or nil
            -- 外部自訂區域名稱總開關；internal POI 名稱不受影響。
            local namesOn = provider.internal or getBoolOption("ZoneNames", true)
            -- 名稱遠距顯示（ZoneNamesFar，預設開；僅外部 zone）：總開關關閉時
            -- 不再量測／繪製任何外部名稱，框線與圖標維持原狀。
            local nameFar = namesOn and not provider.internal
                and getBoolOption("ZoneNamesFar", true)
            local cand = zcCandidates(inner, provider, zones, disCats, scale,
                vMinX, vMaxX, vMinY, vMaxY, ppx, ppy, gd2)
            for ci = 1, #cand do
                local z = rawget(zones, cand[ci]) or ZC_EMPTY -- rawget: stale slot 不得觸發第三方 __index（codex review）
                local border, rects = z.border, z.rects
                local lod = z.lodRect
                -- 框線與名稱解耦：borderAlpha==0 只代表「不畫框」，不該連坐名稱——
                -- POI 區塊模式是純色塊＋名稱（無框線），Zones addon 也允許
                -- borderAlpha=0 而其 name 是必填欄位。本段兩件事各自的條件：
                --   框線 → drawEdges（有 border 且 alpha 非 0）
                --   名稱 → z.name（下方另有細節檔與螢幕裁切判定）
                -- 兩者皆無則整段跳過。LOD zone 的框線僅細節檔畫（中距的聯集框
                -- 純填色——該縮放下框線是雜訊）；名稱對內部（POI）僅細節檔防洗版，
                -- 外部 zone 依 nameFar（見上）可於任何縮放顯示；zone 另過該
                -- provider 的顯示距離閘（not gd2 先行短路，閘未啟用不付逐 zone 呼叫）
                -- 中/遠距檔（lodRect zone）：框線恆不畫；名稱僅 nameFar 時放行
                local midFar = lod ~= nil and scale < ZONE_LOD_DETAIL
                local drawEdges = border and z.borderAlpha ~= 0 and not midFar
                if rects and (drawEdges or (namesOn and z.name))
                    and not (disCats and z.category and disCats[z.category])
                    and (not midFar or (nameFar and z.name ~= nil))
                    and (not gd2 or zoneWithinDist(z, ppx, ppy, gd2, provider.internal)) then
                    local r, g, b, a
                    if drawEdges then r, g, b, a = border.r, border.g, border.b, z.borderAlpha end
                    local zoneVisible = false
                    -- name-only zone（POI 區塊模式）免整組 quad 投影（ZR-4）：名稱的
                    -- 繪製條件（標籤完整落窗內，見下方界檢）嚴格強於 zoneVisible，
                    -- 以 rects[1] 的世界預裁充當 zoneVisible 即可——輸出逐像素不變。
                    -- rects[1] 判 nil：空 rects（外部 addon 可給）靜默跳過，不得
                    -- nil 解參考打死整個 pass（codex review mutation probe 實證）。
                    -- 註：舊碼此處有 lod+中距→lodSingle 的分支，但上面的 gate 已排除
                    -- 「有 lod 且 scale < DETAIL」，該分支永不成立，隨改寫刪去
                    if not drawEdges then
                        local rc0 = rects[1]
                        zoneVisible = rc0 ~= nil and rc0.x2 >= vMinX and rc0.x1 <= vMaxX
                            and rc0.y2 >= vMinY and rc0.y1 <= vMaxY
                    end
                    local rn = drawEdges and #rects or 0
                    for ri = 1, rn do
                        local rc = rects[ri]
                        -- 世界座標預裁（被裁者投影後必在窗外，zoneVisible 語意不變）
                        if rc.x2 >= vMinX and rc.x1 <= vMaxX and rc.y2 >= vMinY and rc.y1 <= vMaxY then
                            local dx1, dy1 = rc.x1 - acx, rc.y1 - acy
                            local dx2, dy2 = rc.x2 - acx, rc.y2 - acy
                            local ux1, uy1 = p0x + dx1 * sxx + dy1 * syx, p0y + dx1 * sxy + dy1 * syy
                            local ux2, uy2 = p0x + dx2 * sxx + dy1 * syx, p0y + dx2 * sxy + dy1 * syy
                            local ux3, uy3 = p0x + dx2 * sxx + dy2 * syx, p0y + dx2 * sxy + dy2 * syy
                            local ux4, uy4 = p0x + dx1 * sxx + dy2 * syx, p0y + dx1 * sxy + dy2 * syy
                            -- A3：投影後 AABB 早退（同 drawZoneFill）——略過離屏 rect 的
                            -- clipSegment＋drawLine；zoneVisible 記住至少一 rect 落在視窗內
                            -- 純 Lua min/max 比較鏈（ZR-2，同 halo 段註解）
                            local minx, maxx = ux1, ux1
                            if ux2 < minx then minx = ux2 elseif ux2 > maxx then maxx = ux2 end
                            if ux3 < minx then minx = ux3 elseif ux3 > maxx then maxx = ux3 end
                            if ux4 < minx then minx = ux4 elseif ux4 > maxx then maxx = ux4 end
                            local miny, maxy = uy1, uy1
                            if uy2 < miny then miny = uy2 elseif uy2 > maxy then maxy = uy2 end
                            if uy3 < miny then miny = uy3 elseif uy3 > maxy then maxy = uy3 end
                            if uy4 < miny then miny = uy4 elseif uy4 > maxy then maxy = uy4 end
                            if maxx >= 0 and minx <= w and maxy >= 0 and miny <= h then
                                zoneVisible = true
                                if drawEdges then
                                    drawClippedEdge(inner, ux1, uy1, ux2, uy2, r, g, b, a)
                                    drawClippedEdge(inner, ux2, uy2, ux3, uy3, r, g, b, a)
                                    drawClippedEdge(inner, ux3, uy3, ux4, uy4, r, g, b, a)
                                    drawClippedEdge(inner, ux4, uy4, ux1, uy1, r, g, b, a)
                                end
                            end
                        end
                    end
                    -- 名稱畫在第一個 rect 的中心，僅中心落在視窗內才畫（同 drawMapBounds）；
                    -- 整區離屏（無 rect 在窗內）連名稱測量都省——名稱中心落在窗內必然使該
                    -- rect AABB 與視窗相交，故 zoneVisible 為真，不影響應畫的名稱
                    local name = namesOn and z.name or nil
                    local rc = rects[1]
                    -- 名稱檔位閘：內部（POI）僅細節檔（20 類全開時中/遠距洗版即此治）；
                    -- 外部 zone 由 nameFar 放行任何縮放（找區域的主要手段）
                    if name and rc and zoneVisible
                        and (not lod or scale >= ZONE_LOD_DETAIL or nameFar) then
                        -- 量測惰性快取（ZR-4）：renderer 自有、以名稱字串為 key——
                        -- 不得寫回 provider 的 zone 表（API 明定對回傳只讀不改；寫入
                        -- 會與 addon 同名欄位碰撞、對 __newindex 保護表拋錯，codex
                        -- review 抓出）。鍵集有界（POI 20 類名＋自訂區域名，隨
                        -- zone 總量上限）；addon 改 z.name 換字串＝新 key，自然正確；
                        -- 字型倍率改動 PZ 慣例需重啟
                        local tw = zoneNameWidth[name]
                        if not tw then
                            tw = tm:MeasureStringX(UIFont.Small, name)
                            zoneNameWidth[name] = tw
                        end
                        local cxw, cyw = (rc.x1 + rc.x2) / 2, (rc.y1 + rc.y2) / 2
                        local cx = p0x + (cxw - acx) * sxx + (cyw - acy) * syx - tw / 2
                        local cy = p0y + (cxw - acx) * sxy + (cyw - acy) * syy - th / 2
                        if cx >= 2 and cy >= 2 and cx + tw <= inner.width - 2 and cy + th <= inner.height - 2 then
                            inner:drawRect(cx - 3, cy - 1, tw + 6, th + 2, 0.6, 0, 0, 0)
                            inner:drawText(name, cx, cy, 1, 1, 1, 0.95, UIFont.Small)
                        end
                    end
                end
            end
        end
    end
end

-- Zone 繪製呼叫端共用：pcall 包裹＋首次錯誤記 log（同動物圖標 log-once 策略）——
-- provider 是外部 addon 程式碼，拋錯不得拖垮整張地圖 prerender；旗標記在 inner 實例上
local function safeDrawZone(inner, fn, flagKey)
    local ok, err = pcall(fn, inner)
    if not ok and not inner[flagKey] then
        inner[flagKey] = true
        log("Zone layer draw failed: " .. tostring(err))
    end
end

-- 圖標 pass（與 linePass 同層）：zone 帶 icon={tex,r,g,b} 時，每 rect 中心投影，
-- 中心點落在視窗內才畫 18px 染色圖標（DrawTextureScaled 引數序 tex,x,y,w,h,a,r,g,b——
-- 同 adotsDrawGlyph 的白剪影染色手法；tex 由 provider 於建快取時 getTexture 解好，
-- 未齊者 icon 留 nil，這裡自然跳過）。fill/line/icon 三 pass 對 ZoneLayer/per-provider
-- 母開關的閘門一致。
local function drawZoneIcons(inner)
    if #registeredZoneProviders == 0 then return end
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    -- 大小/透明度滑條每幀讀值（0.9.0；作用於所有 zone 圖標，POI 為主）；
    -- 18＝滑條預設（同 ESC 頁 addSlider 預設值）
    local s = getSliderValue("PoiIconSize", 18, 8, 48)
    local ia = getSliderValue("PoiIconAlpha", 100, 10, 100) / 100
    local half = s / 2
    -- 中/遠距（<細節檔）對 lodRect zone 啟用圖標去重疊；細節檔全畫
    local scale = mapAPI:getWorldScale()
    local declutter = scale < ZONE_LOD_DETAIL
    iconGridGen = iconGridGen + 1
    -- 視野預裁（POI 擴至 ~1700 筆後，逐 rect 先投影再裁會付 ~3.4k 次/幀的
    -- Kahlua→Java worldToUI 呼叫）：先取一次可視世界外接框，rect 與框不相交者
    -- 直接跳過。框是視窗四邊形的超集，被裁者其 rect 中心必在窗外，而下方螢幕
    -- 裁切要求中心深入視窗 half+1px 才畫——預裁純省投影、不改變畫面；此論證
    -- 依賴「繪製 ⇒ 中心在窗內」，若日後放寬成「圖標矩形相交即畫」預裁即失效。
    -- 兩表面相容依據：ISWorldMap.lua:268 與 ISMiniMap.lua:192 同走 getAPIv3()，
    -- V3⊂V2⊂V1，2 參 uiToWorldX/Y 是 UIWorldMapV1.java:286-296 同一份繼承實作；
    -- 資料未就緒時回 0.0F 不丟例外（與 worldToUI 同守衛），退化為全裁＝與舊碼
    -- 的全裁行為一致。回歸測試見 scripts/test_zone_render.lua A5。
    local vMinX, vMaxX, vMinY, vMaxY = visibleWorldAABB(inner)
    local acx = math.floor((vMinX + vMaxX) / 2)
    local acy = math.floor((vMinY + vMaxY) / 2)
    local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
    local ppx, ppy, pdist2, zdist2, poiBlocked, zoneBlocked = distGateParams(inner)
    for pi = 1, #registeredZoneProviders do
        local provider = registeredZoneProviders[pi]
        -- 閘門（同 drawZoneFill）：外部受 ZoneLayer 總閘＋per-provider 母開關＋自訂
        -- 區域距離閘；internal 不受，但另受 POI 顯示距離閘（皆含全域上限＋玩家
        -- 滑條；該類距離啟用但缺玩家＝fail closed）
        local gd2, gBlocked
        if provider.internal then gd2, gBlocked = pdist2, poiBlocked
        else gd2, gBlocked = zdist2, zoneBlocked end
        local pok, zones
        if not gBlocked
            and (provider.internal or getBoolOption("ZoneLayer", true))
            and (not provider.optionKey or getBoolOption(provider.optionKey, true)) then
            pok, zones = pcall(provider.fn)
        end
        if pok == false then
            zoneProviderErrorOnce(inner, provider.owner, zones)
        elseif type(zones) == "table" and zones.hasIcon ~= false then -- ZR-1（同 fill pass）
            local disCats = not provider.internal and zoneDisabledCats() or nil
            local cand = zcCandidates(inner, provider, zones, disCats, scale,
                vMinX, vMaxX, vMinY, vMaxY, ppx, ppy, gd2)
            for ci = 1, #cand do
                local z = rawget(zones, cand[ci]) or ZC_EMPTY -- rawget: stale slot 不得觸發第三方 __index（codex review）
                local icon, rects = z.icon, z.rects
                -- zone 過該 provider 的顯示距離閘（與 fill/lines 同判定，整棟一致
                -- 顯隱；not gd2 先行短路——閘未啟用不付逐 zone 呼叫）
                if icon and icon.tex and rects
                    and not (disCats and z.category and disCats[z.category])
                    and (not gd2 or zoneWithinDist(z, ppx, ppy, gd2, provider.internal)) then
                    -- iconOnce（POI v3 逐房間矩形）：圖標只畫在 rects[1]（provider
                    -- 保證是最大房間），避免一棟 200+ 房間疊 200 顆圖標；預裁與
                    -- 螢幕裁切照常作用於該矩形。選配 iconRect 覆寫第一顆的錨點
                    -- （POI 整棟外框模式：框是整棟、圖標仍釘在最大房間）
                    local rn = z.iconOnce and 1 or #rects
                    for ri = 1, rn do
                        -- iconRect 四欄齊備才採用，否則回退 rects[ri]：這是新公開的
                        -- 選配欄位，殘缺表（如 { x1 = 40 }）會在下方比較時 nil 比數字
                        -- 拋錯，而 safeDrawZone 包的是整個 pass——一個壞 addon 會讓當幀
                        -- 所有 provider 的圖標全滅（codex review）
                        local ir = ri == 1 and z.iconRect or nil
                        local rc = rects[ri]
                        if ir and ir.x1 and ir.y1 and ir.x2 and ir.y2 then rc = ir end
                        -- rc 判 nil：iconOnce＋空 rects（外部 addon 可給）時 rn=1 但
                        -- rects[1]=nil，缺守衛會 nil deref 打死整幀所有 provider 的圖標
                        if rc and rc.x2 >= vMinX and rc.x1 <= vMaxX and rc.y2 >= vMinY and rc.y1 <= vMaxY then
                            local cxw, cyw = (rc.x1 + rc.x2) / 2, (rc.y1 + rc.y2) / 2
                            local cx = p0x + (cxw - acx) * sxx + (cyw - acy) * syx
                            local cy = p0y + (cxw - acx) * sxy + (cyw - acy) * syy
                            -- 整矩形裁切（同動物圖標 :2670 手法，留 1px 邊）：只查中心會讓
                            -- 圖標半寬溢出地圖框（codex review 抓出）
                            local ix, iy = cx - half, cy - half
                            if ix >= 1 and iy >= 1 and ix + s <= w - 1 and iy + s <= h - 1 then
                                local ok = true
                                if declutter and z.lodRect then
                                    -- 同格已有圖標＝視覺不可分辨，跳過繪製；gen 標記
                                    -- 免逐幀清表。細節檔（declutter=false）全畫
                                    -- ZR-2 純 Lua floor（cx/cy 經螢幕界檢後恆正；s 為整數
                                    -- 滑條值，% 是 VM opcode 非跨界，恆等式對整數 s 精確）
                                    local gkey = ((cx - cx % s) / s) * 100000 + (cy - cy % s) / s
                                    if iconGrid[gkey] == iconGridGen then
                                        ok = false
                                    else
                                        iconGrid[gkey] = iconGridGen
                                    end
                                end
                                if ok then
                                    inner:drawTextureScaled(icon.tex, ix, iy, s, s,
                                        ia, icon.r, icon.g, icon.b)
                                    if z.basement then
                                        -- 地下條目「↓」角標（POI v3 basement 欄；幾何自
                                        -- 縮放不吃字型）：右下黑底小方塊＋白色下箭頭
                                        -- ＝「設施在地下層」，地上可能是別的建築
                                        -- 尺寸夾限（review：s=8 時固定 7px 塊蓋掉 77%
                                        -- 圖標面積、剪影不可辨）：0.45s 夾 [5,9]——
                                        -- s=8→5px（39%）、s=18→8px、s=48 封頂 9px
                                        local bs = math.floor(s * 0.45)
                                        if bs < 5 then bs = 5 end
                                        if bs > 9 then bs = 9 end
                                        local bx0, by0 = ix + s - bs, iy + s - bs
                                        inner:drawRect(bx0, by0, bs, bs, 0.8 * ia, 0, 0, 0)
                                        local mx = bx0 + bs / 2
                                        local byb = by0 + bs - 2
                                        inner:drawLine(nil, mx, by0 + 2, mx, byb, 1, ia, 1, 1, 1)
                                        inner:drawLine(nil, bx0 + 2, byb - 3, mx, byb, 1, ia, 1, 1, 1)
                                        inner:drawLine(nil, mx, byb, bx0 + bs - 2, byb - 3, 1, ia, 1, 1, 1)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
-- test:zone-render:end

-- 跨檔匯出：主檔 prerender wrap 經 Core.drawZonePass 呼叫時查表（載入序在本檔之後）
Core.safeDrawZone = safeDrawZone
Core.drawZoneFill = drawZoneFill
Core.drawZoneLines = drawZoneLines
Core.drawZoneIcons = drawZoneIcons
