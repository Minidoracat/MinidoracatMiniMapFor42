-- MinidoracatMiniMapPOI.lua
-- 主 MOD 內建 POI 的 client 層：把 MinidoracatMiniMapPOIData（1704 筆 20 類，
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
--   PoiBlocks（預設關）→ zone 帶 fillAlpha/borderAlpha（類別色）＋ name（getText(nameKey)）
--   兩者皆關 or 該類別未勾 → 該 zone 不納入
-- 圖標模式不帶 name：1704 個標籤會爆地圖。fillAlpha/borderAlpha 於非區塊模式為 0，
-- 主檔 fill/line pass 對 alpha==0 早退。
--
-- 快取契約（沿主檔 zone provider C2）：providerFn 只回快取參照、絕不重建；快取僅在
-- OnGameStart 首建、以及 OnTick 偵測到開關/類別勾選簽章變動時重建（三時點）。

local MODULE = "MinidoracatMiniMapPOI"
local OWN_PROVIDER_ID = "MinidoracatMiniMapFor42.POI"
local OPTIONS_NAMESPACE = "MinidoracatMiniMap" -- 主 MOD 的 ModOptions 命名空間（見主檔）

local POI_FILL_ALPHA = 0.20
local POI_BORDER_ALPHA = 0.85

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
local function getBoolOption(id, default)
    local opts = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions(OPTIONS_NAMESPACE)
    if not opts then return default end
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
-- { cat, rn, r={ {x,y,w,h},.. } }（世界 square 座標；r 按面積大→小、r[1] 為圖標/
-- 名稱錨點——注意是「最大合併後矩形」，相鄰房間已在烘焙端併塊；迭代用 rn，
-- Kahlua # 不可信）。未知類別 key、rn 非正、或某矩形欄位
-- 非 number/尺寸非正 → 略過該矩形；整筆無合法矩形 → 略過該項。zone 帶
-- iconOnce=true：圖標 pass 只在 rects[1] 畫一顆（區塊 fill/line 仍畫全部矩形）。
--------------------------------------------------------------------------------
-- test:poi-convert:start
local function buildPoiConverted()
    local built = {}
    local data = MinidoracatMiniMapPOIData
    local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    if type(data) == "table" and type(cats) == "table" then
        local iconsOn = getBoolOption("PoiIcons", true)
        local blocksOn = getBoolOption("PoiBlocks", false)
        local colorMode = getBoolOption("PoiColorIcons", false)
        if iconsOn or blocksOn then
            -- 逐類別預取 Cat_ 勾選：1704 筆逐筆查 ModOptions 是 ~5k 次三層查找，類別僅 20 個
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
                                    fill = { r = color.r, g = color.g, b = color.b },
                                    fillAlpha = blocksOn and POI_FILL_ALPHA or 0,
                                    border = { r = color.r, g = color.g, b = color.b },
                                    borderAlpha = blocksOn and POI_BORDER_ALPHA or 0,
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
    poiZones = built -- 原子替換（provider 回此新參照）
end
-- test:poi-convert:end

-- 開關/類別勾選簽章：PoiIcons、PoiBlocks、PoiColorIcons 與 20 類 Cat_ 的當前值串接
-- （3＋ORDER 類別數，現 20 類共 23 值）。變動即重建（樣式切換走此路，下一 tick 重載對應材質集）。
local function currentSig()
    local parts = { getBoolOption("PoiIcons", true) and "1" or "0",
        getBoolOption("PoiBlocks", false) and "1" or "0",
        getBoolOption("PoiColorIcons", false) and "1" or "0" }
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

-- internal=true：本體內部 provider，不受主檔 ZoneLayer 總閘連坐，只由自家開關控制。
MinidoracatMiniMapAPI.registerZoneProvider(OWN_PROVIDER_ID, zoneProvider, nil, true)

Events.OnGameStart.Add(function()
    -- 翻譯已載入、ModOptions 存檔值已套用 → 首建帶正確名稱與開關狀態
    buildPoiConverted()
    lastSig = currentSig()
end)

-- 沿 C2：快取重建只在簽章變動時（開關/類別勾選改動經齒輪面板/統一視窗/ESC 選項頁
-- 任一路徑寫回 ModOptions 後，下一 tick 偵測到）。clean 時每幀一次字串比較，成本可忽略。
Events.OnTick.Add(function()
    local sig = currentSig()
    if sig ~= lastSig then
        lastSig = sig
        buildPoiConverted()
    end
end)
