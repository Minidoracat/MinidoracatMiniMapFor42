-- MinidoracatMiniMapPOI.lua
-- 主 MOD 內建 POI 的 client 層：把小地圖資源版的烘焙資料（原版 MinidoracatMiniMapPOIData 1669 筆
-- 20 類，加上地圖包用 registerMapResources 註冊的地圖；v3 逐房間矩形：r[1]=最大合併矩形為圖標錨點、
-- 區塊畫主樓層各房間）轉成
-- 主 MOD zone renderer 的 schema，並以「內部 provider」註冊
-- （registerZoneProvider("MinidoracatMiniMapFor42.POI", fn, nil, internal=true)——POI 有自己的
-- PoiIcons/PoiBlocks/類別勾選，不走 per-provider 母開關，且 internal 使其不受 ZoneLayer 總閘連坐）。
--
-- 檔名字母序在 MinidoracatMiniMap.lua 之後載入，故 registerZoneProvider 已就緒，
-- ModOptions（PoiIcons/PoiBlocks/Cat_*）也已由主檔在 MinidoracatMiniMap 命名空間註冊。
--
-- 資源版本（ModOptions PoiSource／沙盒 PoiSourceDefault，effectiveSource 解析）：小地圖資源＝上述
-- 烘焙資料（本檔原本的路徑；合併與地圖優先序過濾在 shared/MinidoracatMiniMapResources.lua）；房間資料＝
-- 同一個 shared 檔執行期讀 RoomDef 的結果，含地圖 MOD，由 buildRoomConverted 轉成同一種 zone（說明見該函式）。
--
-- 顯示模式（兩顆開關獨立）：
--   PoiIcons（預設開）→ zone 帶 icon = { tex, r, g, b }（圖標即識別，主檔 iconPass 繪）
--   PoiBlocks（預設關）→ zone 帶 fillAlpha（類別色半透明填色，無框線）＋
--     name（getText(nameKey)）
--   兩者皆關 or 該類別未勾 → 該 zone 不納入
-- 區塊形狀（PoiWholeBuilding，預設開，0.14.2 起）：關＝逐房間矩形、開＝整棟一框（資料
-- 的 e.b）。缺 b 或 b 尺寸非正的條目自動退回逐房間。
-- 嚴格限定為「區塊模式的外觀選項」，三個隔離缺一即違反 UI 承諾：
--   1. 需 blocksOn 才換幾何——區塊沒畫時（alpha=0 早退）換幾何是零視覺效果卻連帶
--      改掉距離閘，玩家會看到圖標無故提早出現
--   2. 圖標走 iconRect 錨在最大房間，不跑到整棟框中心（實測商場藥局房間 17x12
--      vs 整棟 273x156，中心離實際店面可差上百格）
--   3. 距離閘走 distRects＝原房間矩形，可見距離完全不受此開關影響
-- 圖標模式不帶 name：1669 個標籤會爆地圖。fillAlpha 於非區塊模式為 0，主檔 fill
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
-- 例外：無 lodRect 的地標豁免條目（見 POI_LOD_MAX_EDGE）底襯全檔位畫——中距整棟
-- 同框時沒暗邊＝「有染色卻看不出區域」（地堡實測回饋）。
local POI_FILL_ALPHA = 0.20
local POI_HALO_ALPHA = 0.55

-- 大型地標不參與縮放 LOD（沿 Zones addon attachLodRect 的 LOD_MAX_EDGE=100
-- 同一判準）：畫的幾何聯集最長邊 >100 格的條目不附 lodRect、任何縮放照畫
-- （含名稱）。均一 px/格 門檻對地標是誤傷——March Ridge 地堡 (5522,12407)
-- 177×110 在 1px/格 仍是 177px 的可辨識色塊，卻被「已是色點」的拉遠檔藏掉；
-- 而名稱要 >=6px/格 才畫，屆時地堡已是 1062px、超出視窗——地標從不存在
-- 「整棟＋名稱」同框的縮放（實測回饋，2026-08-14）。影響面：整棟外框模式
-- 20 筆、逐房間模式 5 筆（1669 筆實算），遠距多畫成本可忽略；其餘照走 LOD。
-- 附帶：這些條目不進圖標去重疊（該機制只作用於 lodRect zone）——地標圖標
-- 本就不該被鄰格圖標吃掉。
local POI_LOD_MAX_EDGE = 100

-- 版本守衛：同 MOD 內兩檔，理論上恆成立；仍防呆——無 registerZoneProvider 直接降級。
if not (MinidoracatMiniMapAPI and MinidoracatMiniMapAPI.registerZoneProvider) then
    print("[" .. MODULE .. "] no registerZoneProvider, POI disabled")
    return
end

--------------------------------------------------------------------------------
-- 狀態（module-level upvalue；closure 以參照捕捉）
--------------------------------------------------------------------------------
local poiZones = {}   -- 轉好的 zone 陣列（provider 每幀回傳此參照）
-- 世界地圖圖例（_Legend.lua 讀）：與 poiZones 同一次建置、同一組選項＝圖例列出的類別、
-- 彩色／單色貼圖與地圖上畫的完全一致；OnTick 暫停（單機開世界地圖）時兩者一起停在舊值
local poiLegend = { count = 0, basement = false }
local lastSig = nil   -- 上次建置時的開關/類別簽章；OnTick 比對變動才重建
-- 房間資料版最近一次建置用的建築清單（buildingsIn 的副本；搜尋讀它，不另外再查一次）
local roomList, roomCount = nil, 0

-- log 是離線測試接縫（test_zone_render 抽 test:poi-icon 區段注入 stub 驗 log-once）
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

-- 下拉選項的索引（1 起）；缺選項或值不是數字回 default
local function getComboOption(id, default)
    if not optsCache then
        local opts = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions(OPTIONS_NAMESPACE)
        if not opts then return default end
        optsCache = opts
    end
    local opt = optsCache:getOption(id)
    local v = opt and opt:getValue()
    if type(v) ~= "number" then return default end
    return v
end

-- 目前生效的資源版本："minimap"（離線烘焙，原版地圖）或 "rooms"（執行期 RoomDef，含地圖 MOD）。
-- PoiSource：1＝依伺服器設定（沙盒 PoiSourceDefault：1 小地圖資源、2 房間資料）、2＝小地圖資源、3＝房間資料
local function effectiveSource()
    local v = getComboOption("PoiSource", 1)
    if v == 2 then return "minimap" end
    if v == 3 then return "rooms" end
    local P = MinidoracatMiniMapPolicy
    local d = P and P.readNumber and P.readNumber("PoiSourceDefault", 1) or 1
    return d == 2 and "rooms" or "minimap"
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
-- 小地圖資源 → renderer schema（OnGameStart 建一次；翻譯此時已載入，getText 可用）。
-- 消費契約（v3 逐房間矩形）：MinidoracatMiniMapResources.minimapEntries() 回 POIData 形狀的陣列，每項
-- { cat, rn, r={ {x,y,w,h},.. }, b={x,y,w,h}|nil }（世界 square 座標；r 按面積
-- 大→小、r[1] 為圖標/名稱錨點——注意是「最大合併後矩形」，相鄰房間已在烘焙端
-- 併塊；b＝整棟建築外框，非 r 的聯集；迭代用 rn，Kahlua # 不可信）。未知類別
-- key、rn 非正、或某矩形欄位非 number/尺寸非正 → 略過該矩形；整筆無合法矩形 →
-- 略過該項。zone 帶 iconOnce=true：圖標 pass 只畫一顆（區塊 fill/line 仍畫全部
-- 矩形），錨點為 iconRect（有給）否則 rects[1]。
--------------------------------------------------------------------------------
-- test:poi-convert:start
-- 圖例：只列真的畫得出圖標的類別（勾選中且材質在），照 ORDER 顯示順序；
-- 貼圖與染色同地圖上的 zone（彩色染白、單色染類別色）。兩種資源版本共用
local function appendLegend(legend, cats, catOn, colorMode)
    local order = MinidoracatMiniMapPOICategories.ORDER
    if type(order) ~= "table" then return end
    for i = 1, #order do
        local cat = order[i]
        local def = cats[cat]
        if def and catOn[cat] then
            local tex, isColor = iconTexture(cat, colorMode)
            if tex then
                local color = def.color or { r = 0.7, g = 0.7, b = 0.7 }
                legend.count = legend.count + 1
                legend[legend.count] = { name = getText(def.nameKey), tex = tex,
                    r = isColor and 1 or color.r, g = isColor and 1 or color.g,
                    b = isColor and 1 or color.b }
            end
        end
    end
end

-- 房間資料版（shared/MinidoracatMiniMapResources.lua 的掃描結果，一筆＝一筆 BuildingDef）：
-- 每個勾選中的類別一顆圖標，釘在該類最大的房間；區塊一律整棟外框（判定單位就是整棟，
-- PoiWholeBuilding 不作用），而且一筆只畫一塊——填色、底襯與名稱只放在 ORDER 最前的類別那個
-- zone，其餘類別的 zone 只帶圖標（同一個外框疊兩層填色會變色、名稱會疊字）。多類時名稱與
-- 停留提示是「A / B」；單類不帶 tip，提示照小地圖資源版的類別名（含地下室後綴）。
-- 距離閘量各類最大的房間（distRects＝這筆所有顯示中類別的落點，整筆一起出現或隱藏；
-- 落點都在外框內，符合 internal 的 distRects ⊆ lodRect 快排前提）；最長邊超過
-- POI_LOD_MAX_EDGE 的不附 lodRect（地標）。
-- 還沒掃完時 buildingsIn 回 nil（"pending"）＝這次空白，掃完由簽章觸發重建。
local ROOM_WORLD = 100000000 -- 查全圖用的半邊長（世界格），buildingsIn 的合法值域內
local function buildRoomConverted()
    local built = {}
    local legend = { count = 0, basement = false }
    local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
    local iconsOn = getBoolOption("PoiIcons", true)
    local blocksOn = getBoolOption("PoiBlocks", false)
    local API = MinidoracatMiniMapResourceAPI
    local list, n = nil, 0
    if API and API.buildingsIn then
        list, n = API.buildingsIn(-ROOM_WORLD, -ROOM_WORLD, 2 * ROOM_WORLD, 2 * ROOM_WORLD, "rooms")
        if not list then n = 0 end
    end
    roomList, roomCount = list, n -- 搜尋（_Search.lua）讀同一份
    if list and type(cats) == "table" and type(order) == "table" and (iconsOn or blocksOn) then
        local colorMode = getBoolOption("PoiColorIcons", false)
        local catOn, names, texs, colored = {}, {}, {}, {}
        for i = 1, #order do
            local key = order[i]
            local def = cats[key]
            if def then
                catOn[key] = getBoolOption("Cat_" .. key, true)
                names[key] = getText(def.nameKey)
                if iconsOn then texs[key], colored[key] = iconTexture(key, colorMode) end
            end
        end
        local hits = {}
        for bi = 1, n do
            local b = list[bi]
            local hn = 0
            for i = 1, #order do
                local key = order[i]
                if catOn[key] and b.cats[key] then
                    hn = hn + 1
                    hits[hn] = key
                end
            end
            if hn > 0 then
                local joined = names[hits[1]]
                for k = 2, hn do joined = joined .. " / " .. names[hits[k]] end
                local whole = { x1 = b.x, y1 = b.y, x2 = b.x + b.w, y2 = b.y + b.h }
                local lodRect = nil
                if (b.w > b.h and b.w or b.h) <= POI_LOD_MAX_EDGE then lodRect = whole end
                local spots = {}
                for k = 1, hn do
                    local a = b.anchors[hits[k]]
                    spots[k] = { x1 = a.x, y1 = a.y, x2 = a.x + a.w, y2 = a.y + a.h }
                end
                for k = 1, hn do
                    local key = hits[k]
                    local block = k == 1 and blocksOn
                    local tex = texs[key]
                    if tex or block then
                        local a = b.anchors[key]
                        local color = cats[key].color or { r = 0.7, g = 0.7, b = 0.7 }
                        local isColor = colored[key]
                        built[#built + 1] = {
                            id = "room:" .. key .. ":" .. bi,
                            rects = { whole },
                            lodRect = lodRect,
                            iconOnce = true,
                            iconRect = spots[k],
                            distRects = spots,
                            fill = { r = color.r, g = color.g, b = color.b },
                            fillAlpha = block and POI_FILL_ALPHA or 0,
                            haloAlpha = block and POI_HALO_ALPHA or nil,
                            name = block and joined or nil,
                            tip = hn > 1 and joined or nil,
                            icon = tex and { tex = tex,
                                r = isColor and 1 or color.r,
                                g = isColor and 1 or color.g,
                                b = isColor and 1 or color.b } or nil,
                            category = key,
                            basement = a.basement or nil,
                        }
                        if tex and a.basement then legend.basement = true end
                    end
                end
            end
        end
        if iconsOn then appendLegend(legend, cats, catOn, colorMode) end
    end
    built.hasFill = blocksOn
    built.hasLine = blocksOn
    built.hasIcon = iconsOn
    poiZones = built
    poiLegend = legend
end

-- source：effectiveSource() 的結果；nil 或 "minimap" 走離線烘焙資料（下方原本的路徑）
local function buildPoiConverted(source)
    if source == "rooms" then return buildRoomConverted() end
    local built = {}
    local legend = { count = 0, basement = false }
    -- 原版加已註冊的地圖，已照引擎的地圖優先序過濾（shared/MinidoracatMiniMapResources.lua）
    local Res = MinidoracatMiniMapResources
    local data = Res and Res.minimapEntries() or nil
    local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    -- iconsOn/blocksOn 宣告在資料檢查之外：檔尾的聚合旗標（ZR-1）要用——資料缺失
    -- 時 built 為空陣列、旗標仍照開關設定（空表怎麼設都不畫，語意一致）
    local iconsOn = getBoolOption("PoiIcons", true)
    local blocksOn = getBoolOption("PoiBlocks", false)
    if type(data) == "table" and type(cats) == "table" then
        local colorMode = getBoolOption("PoiColorIcons", false)
        local wholeOn = getBoolOption("PoiWholeBuilding", true)
        if iconsOn or blocksOn then
            -- 逐類別預取 Cat_ 勾選：1669 筆逐筆查 ModOptions 是 ~5k 次三層查找，類別僅 20 個
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
                                -- 實測 1669 筆有大半兩者相同、大型建物可差兩百倍面積）。
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
                                -- 地標豁免（見 POI_LOD_MAX_EDGE）：最長邊超標不附
                                -- lodRect＝不參與 LOD、全縮放可見。以「畫的幾何」為準
                                -- ——整棟外框模式量整棟、逐房間模式量觸發房聯集，
                                -- LOD 藏的是它畫的東西，量測對象一致才語意正確
                                local lodW, lodH = ux2 - ux1, uy2 - uy1
                                local lodRect = nil
                                if (lodW > lodH and lodW or lodH) <= POI_LOD_MAX_EDGE then
                                    lodRect = { x1 = ux1, y1 = uy1, x2 = ux2, y2 = uy2 }
                                end
                                built[#built + 1] = {
                                    id = "poi:" .. cat .. ":" .. i,
                                    rects = rects,
                                    lodRect = lodRect,
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
                                    -- 地下條目（B42 basement；資料 u=1＝主分類房的
                                    -- **主樓層**在地下——dominant floor，跨層同類房取
                                    -- 面積最大層）：圖標 pass 加「↓」角標——地上是別的
                                    -- 建築（如民宅），無標注會被當標錯（2026-08-20
                                    -- West Point 地下酒吧玩家回報）
                                    basement = (e.u == 1) or nil,
                                }
                                if tex and e.u == 1 then legend.basement = true end
                            end
                        end
                    end
                end
            end
            if iconsOn then appendLegend(legend, cats, catOn, colorMode) end
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
    poiLegend = legend
end
-- test:poi-convert:end

-- 開關/類別勾選簽章：資源版本（房間資料版另帶掃描是否完成）、PoiIcons、PoiBlocks、
-- PoiColorIcons、PoiWholeBuilding 與 20 類 Cat_ 的當前值串接。變動即重建（樣式與區塊
-- 形狀切換走此路，下一 tick 重載對應材質集/幾何）。房間資料版沒掃完時 prepare 會開始
-- 背景掃描；掃完那一次簽章從 P 變 R，觸發重建。回傳第二值＝生效的資源版本
local function currentSig()
    local source = effectiveSource()
    local ready = "-"
    if source == "rooms" then
        local API = MinidoracatMiniMapResourceAPI
        ready = (API and API.prepare and API.prepare("rooms")) and "R" or "P"
    end
    local parts = { source, ready, getBoolOption("PoiIcons", true) and "1" or "0",
        getBoolOption("PoiBlocks", false) and "1" or "0",
        getBoolOption("PoiColorIcons", false) and "1" or "0",
        getBoolOption("PoiWholeBuilding", true) and "1" or "0" }
    local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
    if type(order) == "table" then
        for i = 1, #order do
            parts[#parts + 1] = getBoolOption("Cat_" .. order[i], true) and "1" or "0"
        end
    end
    return table.concat(parts), source
end

-- providerFn（主 MOD 每幀呼叫：世界＋小地圖）：只回快取，不重建。
-- internal=true：本體內部 provider，不受主檔 ZoneLayer 總閘連坐，由自家開關控制；
-- 另受主檔的 POI 顯示距離閘連坐（沙盒 PoiDisplayDistance／全域上限 AllInfoDistance
-- ＋玩家自訂距離，取最小正值）——距離啟用時 zone 依玩家距離被裁，非本檔可見的邏輯。
MinidoracatMiniMapAPI.registerZoneProvider(OWN_PROVIDER_ID, function() return poiZones end, nil, true)

-- 跨檔匯出（主檔先載、Core 已建好）：設定視窗類別格與世界地圖圖例都經此取圖，
-- 彩色／單色與地圖同一套選擇（彩色缺檔回退單色時 isColor＝false，呼叫端照樣染類別色）
local Core = MinidoracatMiniMapCore
if Core then
    Core.poiIconTexture = iconTexture
    Core.poiLegend = function() return poiLegend end
    -- 設定視窗（說明文字、整棟開關變灰）與搜尋讀生效版本；搜尋另讀房間資料版的建築清單
    Core.poiSource = effectiveSource
    Core.poiRoomBuildings = function() return roomList, roomCount end
end

Events.OnGameStart.Add(function()
    -- 翻譯已載入、ModOptions 存檔值已套用 → 首建帶正確名稱與開關狀態
    local sig, source = currentSig()
    buildPoiConverted(source)
    lastSig = sig
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
    local sig, source = currentSig()
    if sig ~= lastSig then
        lastSig = sig
        buildPoiConverted(source)
    end
end)
