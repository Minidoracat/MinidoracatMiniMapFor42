-- MinidoracatMiniMapPOI.lua
-- 主 MOD 內建 POI 的 client 層：把 MinidoracatMiniMapPOIData（1692 筆 20 類，
-- v3 逐房間矩形：r[1]=最大合併矩形為圖標錨點、區塊畫主樓層各房間）轉成
-- 主 MOD zone renderer 的 schema，並以「內部 provider」註冊
-- （registerZoneProvider("MinidoracatMiniMapFor42.POI", fn, nil, internal=true)——POI 有自己的
-- PoiIcons/PoiBlocks/類別勾選，不走 per-provider 母開關，且 internal 使其不受 ZoneLayer 總閘連坐）。
--
-- 檔名字母序在 MinidoracatMiniMap.lua 之後載入，故 registerZoneProvider 已就緒，
-- ModOptions（PoiIcons/PoiBlocks/Cat_*）也已由主檔在 MinidoracatMiniMap 命名空間註冊。
--
-- 顯示模式（兩顆開關獨立）：
--   PoiIcons（預設開）→ zone 帶 icon = { tex, r, g, b }（圖標即識別，主檔 iconPass 繪）
--   PoiBlocks（預設關）→ zone 帶 fillAlpha（類別色半透明填色，無框線）＋
--     name（getText(nameKey)）
--   兩者皆關 or 該類別未勾 → 該 zone 不納入
-- 區塊形狀（PoiWholeBuilding，預設關）：關＝逐房間矩形（現行）、開＝整棟一框（資料
-- 的 e.b）。缺 b 或 b 尺寸非正的條目自動退回逐房間。
-- 嚴格限定為「區塊模式的外觀選項」，三個隔離缺一即違反 UI 承諾：
--   1. 需 blocksOn 才換幾何——區塊沒畫時（alpha=0 早退）換幾何是零視覺效果卻連帶
--      改掉距離閘，玩家會看到圖標無故提早出現
--   2. 圖標走 iconRect 錨在最大房間，不跑到整棟框中心（實測商場藥局房間 17x12
--      vs 整棟 273x156，中心離實際店面可差上百格）
--   3. 距離閘走 distRects＝原房間矩形，可見距離完全不受此開關影響
-- 圖標模式不帶 name：1692 個標籤會爆地圖。fillAlpha 於非區塊模式為 0，主檔 fill
-- pass 對 alpha==0 早退；zone 一律不帶 border，line pass 只為名稱而跑。
--
-- 快取契約（沿主檔 zone provider C2）：providerFn 只回快取參照、絕不重建；快取僅在
-- OnGameStart 首建、以及 OnTick 偵測到開關/類別勾選簽章變動時重建（三時點）。

local MODULE = "MinidoracatMiniMapPOI"
local OWN_PROVIDER_ID = "MinidoracatMiniMapFor42.POI"
local OPTIONS_NAMESPACE = "MinidoracatMiniMap" -- 主 MOD 的 ModOptions 命名空間（見主檔）

-- 區塊模式＝半透明色塊＋暗色底襯描邊＋名稱，不畫框線（2026-08-13 使用者決定）：
-- 框線是 line pass 最貴的部分（每矩形 4 條 drawClippedEdge＝Liang-Barsky 裁切＋
-- Java drawLine，全圖細節檔逐房間 18940 條／整棟 6768 條），移除後該成本歸零。
-- 邊界辨識改由 haloAlpha 底襯提供（實機回饋：純色塊難辨識）——主檔 fill pass 於
-- 細節檔在每 rect 下方先畫外擴 2px 的黑色 quad，視覺即一圈描邊，成本每 rect 僅
-- 1 次 drawPolygon（舊框線的 1/4 且零 Lua 裁線）；中距檔不畫（城市尺度熱點零新增）。
local POI_FILL_ALPHA = 0.20
local POI_HALO_ALPHA = 0.55

-- 版本守衛：同 MOD 內兩檔，理論上恆成立；仍防呆——無 registerZoneProvider 直接降級。
if not (MinidoracatMiniMapAPI and MinidoracatMiniMapAPI.registerZoneProvider) then
    print("[" .. MODULE .. "] no registerZoneProvider, POI disabled")
    return
end

--------------------------------------------------------------------------------
-- 狀態（module-level upvalue；closure 以參照捕捉）
--------------------------------------------------------------------------------
local poiZones = {}   -- 轉好的 zone 陣列（provider 每幀回傳此參照）
local lastSig = nil   -- 上次建置時的開關/類別簽章；OnTick 比對變動才重建

local function log(msg)
    print("[" .. MODULE .. "] " .. tostring(msg))
end

-- 讀主 MOD 的 ModOptions（主檔以 PZAPI.ModOptions:create 建於 MinidoracatMiniMap 命名空間，
-- getOptions 取回同一實例）。PZAPI 不存在時回 nil → 一律回預設。
-- optsCache（perf 稽核 ZR-5）：getOptions 實例快取成 upvalue——重建路徑 ~5k 次
-- 讀取與每次簽章比對都省一層 namespace 查找；PZAPI 實例於 session 內穩定
local optsCache
local function getBoolOption(id, default)
    local opts = optsCache
    if not opts then
        opts = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions(OPTIONS_NAMESPACE)
        if not opts then return default end
        optsCache = opts
    end
    local opt = opts:getOption(id)
    if opt == nil then return default end
    return opt:getValue()
end

-- 類別圖標材質快取：只快取成功（miss 交引擎 nullTextures 負快取，同主檔 adotsTexture 策略）。
-- 路徑＝完整 media/ 相對 + 副檔名（原版慣例，佐證 getTexture("media/ui/Animals/ChickenSlot_empty.png")
-- 等大量原版 ISUI 用例）。素材缺漏時 getTexture 回 nil、icon 欄位留 nil、主檔 iconPass 跳過。
-- 兩套材質惰性載入：mono＝poi_<cat>.png（呼叫端染類別色）、color＝color/poi_<cat>.png
-- （全彩、呼叫端染白不變色）。彩色檔缺 → 回退 mono，並全域 log-once 提示一次
-- （彩色素材可能尚未全落地）。
-- test:poi-icon:start
local monoTexCache = {}
local colorTexCache = {}
local colorMissingWarned = false
-- 回傳 tex, isColor。colorMode=true 先試 color/ 版；缺檔回退 mono（isColor=false）。
-- 只快取成功，未齊者下輪重建可重試。
local function iconTexture(cat, colorMode)
    if colorMode then
        local c = colorTexCache[cat]
        if c == nil then
            c = getTexture("media/ui/poi_icons/color/poi_" .. cat .. ".png")
            if c then colorTexCache[cat] = c end
        end
        if c then return c, true end
        if not colorMissingWarned then
            colorMissingWarned = true
            log("color POI icon assets missing; using mono fallback")
        end
    end
    local m = monoTexCache[cat]
    if m == nil then
        m = getTexture("media/ui/poi_icons/poi_" .. cat .. ".png")
        if m then monoTexCache[cat] = m end
    end
    return m, false
end
-- test:poi-icon:end

--------------------------------------------------------------------------------
-- POIData → renderer schema（OnGameStart 建一次；翻譯此時已載入，getText 可用）。
-- 消費契約（v3 逐房間矩形）：MinidoracatMiniMapPOIData 為陣列，每項
-- { cat, rn, r={ {x,y,w,h},.. }, b={x,y,w,h}|nil }（世界 square 座標；r 按面積
-- 大→小、r[1] 為圖標/名稱錨點——注意是「最大合併後矩形」，相鄰房間已在烘焙端
-- 併塊；b＝整棟建築外框，非 r 的聯集；迭代用 rn，Kahlua # 不可信）。未知類別
-- key、rn 非正、或某矩形欄位非 number/尺寸非正 → 略過該矩形；整筆無合法矩形 →
-- 略過該項。zone 帶 iconOnce=true：圖標 pass 只畫一顆（區塊 fill/line 仍畫全部
-- 矩形），錨點為 iconRect（有給）否則 rects[1]。
--------------------------------------------------------------------------------
-- test:poi-convert:start
local function buildPoiConverted()
    local built = {}
    local data = MinidoracatMiniMapPOIData
    local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    -- iconsOn/blocksOn 宣告在資料檢查之外：檔尾的聚合旗標（ZR-1）要用——資料缺失
    -- 時 built 為空陣列、旗標仍照開關設定（空表怎麼設都不畫，語意一致）
    local iconsOn = getBoolOption("PoiIcons", true)
    local blocksOn = getBoolOption("PoiBlocks", false)
    if type(data) == "table" and type(cats) == "table" then
        local colorMode = getBoolOption("PoiColorIcons", false)
        local wholeOn = getBoolOption("PoiWholeBuilding", false)
        if iconsOn or blocksOn then
            -- 逐類別預取 Cat_ 勾選：1692 筆逐筆查 ModOptions 是 ~5k 次三層查找，類別僅 20 個
            local catOn = {}
            for key in pairs(cats) do catOn[key] = getBoolOption("Cat_" .. key, true) end
            for i = 1, #data do
                local e = data[i]
                if type(e) == "table" then
                    local cat = e.cat
                    local def = cat and cats[cat]
                    local rn, r = e.rn, e.r
                    if def and type(rn) == "number" and rn > 0 and type(r) == "table"
                        and catOn[cat] then
                        local color = def.color or { r = 0.7, g = 0.7, b = 0.7 }
                        -- 彩色模式染白（全彩不變色）；單色/回退模式染類別色。icon 契約不變。
                        local tex, isColor
                        if iconsOn then tex, isColor = iconTexture(cat, colorMode) end
                        -- 圖標關（或素材未齊）且區塊也關 → 這筆什麼都畫不出，不納入
                        if tex or blocksOn then
                            local rects = {}
                            for k = 1, rn do
                                local rc = r[k]
                                if type(rc) == "table"
                                    and type(rc.x) == "number" and type(rc.y) == "number"
                                    and type(rc.w) == "number" and type(rc.h) == "number"
                                    and rc.w > 0 and rc.h > 0 then
                                    rects[#rects + 1] = { x1 = rc.x, y1 = rc.y,
                                        x2 = rc.x + rc.w, y2 = rc.y + rc.h }
                                end
                            end
                            if rects[1] then
                                -- 整棟外框模式：rects 換成單一 b（外框只會 ⊇ 房間聯集，
                                -- 實測 1692 筆有大半兩者相同、大型建物可差兩百倍面積）。
                                -- 三個「只影響區塊」的隔離（缺一即違反 UI 承諾）：
                                --   1. 要 blocksOn 才換——區塊沒畫時換幾何是零視覺效果卻
                                --      改行為（codex review blocker）
                                --   2. 圖標改錨 iconRect＝原最大房間，不跑到整棟中心
                                --   3. distRects 保留房間矩形供距離閘量測（見下）
                                local iconRect, distRects = nil, nil
                                local b = e.b
                                if wholeOn and blocksOn and type(b) == "table"
                                    and type(b.x) == "number" and type(b.y) == "number"
                                    and type(b.w) == "number" and type(b.h) == "number"
                                    and b.w > 0 and b.h > 0 then
                                    iconRect = rects[1]
                                    distRects = rects
                                    rects = { { x1 = b.x, y1 = b.y,
                                        x2 = b.x + b.w, y2 = b.y + b.h } }
                                end
                                -- 聯集框：縮放 LOD 的中距離檔位用（一棟一框取代
                                -- 逐房間矩形——2~3px/格下兩者視覺無異、成本 1/3）
                                local ux1, uy1 = rects[1].x1, rects[1].y1
                                local ux2, uy2 = rects[1].x2, rects[1].y2
                                for k = 2, #rects do
                                    local rc = rects[k]
                                    if rc.x1 < ux1 then ux1 = rc.x1 end
                                    if rc.y1 < uy1 then uy1 = rc.y1 end
                                    if rc.x2 > ux2 then ux2 = rc.x2 end
                                    if rc.y2 > uy2 then uy2 = rc.y2 end
                                end
                                built[#built + 1] = {
                                    id = "poi:" .. cat .. ":" .. i,
                                    rects = rects,
                                    lodRect = { x1 = ux1, y1 = uy1, x2 = ux2, y2 = uy2 },
                                    -- 圖標/名稱只錨定 rects[1]（烘焙端保證是最大合併矩形）；
                                    -- 無此旗標的 zone（Zones addon）維持每 rect 一圖標
                                    iconOnce = true,
                                    -- 整棟模式才非 nil：圖標改錨此矩形、距離閘改量此組
                                    -- 房間矩形（見上方）
                                    iconRect = iconRect,
                                    distRects = distRects,
                                    fill = { r = color.r, g = color.g, b = color.b },
                                    fillAlpha = blocksOn and POI_FILL_ALPHA or 0,
                                    -- 不帶 border/borderAlpha＝主檔 line pass 不畫框線，
                                    -- 該 pass 只為名稱跑；邊界辨識走 haloAlpha 底襯
                                    -- （見檔頭 POI_FILL_ALPHA 一節）
                                    haloAlpha = blocksOn and POI_HALO_ALPHA or nil,
                                    name = blocksOn and getText(def.nameKey) or nil,
                                    icon = tex and { tex = tex,
                                        r = isColor and 1 or color.r,
                                        g = isColor and 1 or color.g,
                                        b = isColor and 1 or color.b } or nil,
                                    category = cat,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    -- 聚合旗標（perf 稽核 ZR-1，主檔三 pass 據此整段跳過無效迴圈）：預設純圖標
    -- 模式下 fill/lines pass 每幀空掃全部 zone（雙表面 ~6.8k 次迭代/幀）。旗標＝
    -- 該 pass 有無任何可畫內容，與逐 zone 條件精確等價（fillAlpha／name 由
    -- blocksOn 全域一致決定、border 恆缺、icon 由 iconsOn 決定）；false＝跳過、
    -- nil（外部 provider 未聲明）＝照舊迭代。與內容同函式設定、隨 poiZones
    -- 原子替換，旗標與內容恆一致
    built.hasFill = blocksOn
    built.hasLine = blocksOn -- 名稱僅區塊模式存在；POI 恆無框線
    built.hasIcon = iconsOn
    poiZones = built -- 原子替換（provider 回此新參照）
end
-- test:poi-convert:end

-- 開關/類別勾選簽章：PoiIcons、PoiBlocks、PoiColorIcons、PoiWholeBuilding 與 20 類
-- Cat_ 的當前值串接（4＋ORDER 類別數，現 20 類共 24 值）。變動即重建（樣式與區塊
-- 形狀切換走此路，下一 tick 重載對應材質集/幾何）。
local function currentSig()
    local parts = { getBoolOption("PoiIcons", true) and "1" or "0",
        getBoolOption("PoiBlocks", false) and "1" or "0",
        getBoolOption("PoiColorIcons", false) and "1" or "0",
        getBoolOption("PoiWholeBuilding", false) and "1" or "0" }
    local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
    if type(order) == "table" then
        for i = 1, #order do
            parts[#parts + 1] = getBoolOption("Cat_" .. order[i], true) and "1" or "0"
        end
    end
    return table.concat(parts)
end

-- providerFn（主 MOD 每幀呼叫：世界＋小地圖）：只回快取，不重建。
local function zoneProvider()
    return poiZones
end

-- internal=true：本體內部 provider，不受主檔 ZoneLayer 總閘連坐，由自家開關控制；
-- 另受主檔的 POI 顯示距離閘連坐（沙盒 PoiDisplayDistance／全域上限 AllInfoDistance
-- ＋玩家自訂距離，取最小正值）——距離啟用時 zone 依玩家距離被裁，非本檔可見的邏輯。
MinidoracatMiniMapAPI.registerZoneProvider(OWN_PROVIDER_ID, zoneProvider, nil, true)

Events.OnGameStart.Add(function()
    -- 翻譯已載入、ModOptions 存檔值已套用 → 首建帶正確名稱與開關狀態
    buildPoiConverted()
    lastSig = currentSig()
end)

-- 沿 C2：快取重建只在簽章變動時（開關/類別勾選改動經齒輪面板/統一視窗/ESC 選項頁
-- 任一路徑寫回 ModOptions 後偵測到）。簽章比對 ~250ms 節流（perf 稽核 ZR-5，純
-- Lua 幀計數零 Java 呼叫）：每 tick 全量重讀 24 個選項的成本主體在比較「前」的
-- 重建（24 次三層查找＋25 個小配置/幀的 GC churn）；生效延遲 ≤250ms，各 UI 路徑
-- 本就寫回後才被偵測，不可感知。
local sigTick = 0
Events.OnTick.Add(function()
    sigTick = sigTick + 1
    if sigTick < 15 then return end
    sigTick = 0
    local sig = currentSig()
    if sig ~= lastSig then
        lastSig = sig
        buildPoiConverted()
    end
end)
