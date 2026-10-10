-- MinidoracatMiniMapParking.lua
-- 停車場圖層：把離線烘焙的停車場資料（原版 MinidoracatMiniMapParkingData，加上地圖包用
-- registerMapResources 的 spec.parking 註冊的地圖；合併與地圖優先序過濾在
-- shared/MinidoracatMiniMapResources.lua 的 parkingEntries）轉成主 MOD zone renderer 的 schema，
-- 以內部 provider 註冊（internal＝不受 ZoneLayer 總閘；跟內建 POI 同受 POI 顯示距離閘與 'poi' 功能閘）。
--
-- 一筆資料＝一個停車區：r＝各排車位（rects，細節檔逐排畫）、b＝整區範圍（lodRect，中距檔一區一框；
-- 拉遠只剩圖標）。一座停車場可由幾個停車區組成，只有 i == 1 那一區帶 P 圖標（釘在 b 的中心）。
-- 圖標大小、透明度跟資源點同一組設定（renderer 對 internal provider 一律用 PoiIconSize／PoiIconAlpha）。
--
-- 快取契約同 POI：providerFn 只回快取參照；OnGameStart 首建，之後 OnTick 每 15 tick 比對簽章
-- （ParkingLayer、PoiColorIcons、合併清單的表）變了才整表重建。
-- provider 在 OnGameStart 才註冊：圖標去重疊是同一螢幕格先畫先贏，排在 POI provider 之後＝資源點圖標優先。

local OWN_PROVIDER_ID = "MinidoracatMiniMapFor42.Parking"
local PARKING_COLOR = { r = 0.16, g = 0.44, b = 0.92 } -- 停車標誌藍
local PARKING_FILL_ALPHA = 0.30 -- 柏油上要看得出來，比 POI 區塊（0.20）濃一點
local PARKING_HALO_ALPHA = 0.55

if not (MinidoracatMiniMapAPI and MinidoracatMiniMapAPI.registerZoneProvider and MinidoracatMiniMapCore) then
    print("[MinidoracatMiniMapParking] no registerZoneProvider, parking layer disabled")
    return
end

local Core = MinidoracatMiniMapCore
local zones = {}     -- 轉好的 zone 陣列（provider 每幀回傳此參照）
local lastSig = nil

local function validRect(c)
    return type(c) == "table" and type(c.x) == "number" and type(c.y) == "number"
        and type(c.w) == "number" and type(c.h) == "number" and c.w > 0 and c.h > 0
end

local function toRect(c)
    return { x1 = c.x, y1 = c.y, x2 = c.x + c.w, y2 = c.y + c.h }
end

local function currentEntries()
    local Res = MinidoracatMiniMapResources
    return Res and Res.parkingEntries() or nil
end

local function build(data)
    local built, icon = {}, nil
    local on = Core.getBoolOption("ParkingLayer", true)
    if on and type(data) == "table" then
        local tex, isColor
        if Core.poiIconTexture then tex, isColor = Core.poiIconTexture("parking", Core.getBoolOption("PoiColorIcons", false)) end
        -- 彩色圖標染白（全彩不變色）；單色圖標染停車藍（同 POI）
        icon = tex and { tex = tex,
            r = isColor and 1 or PARKING_COLOR.r, g = isColor and 1 or PARKING_COLOR.g,
            b = isColor and 1 or PARKING_COLOR.b } or nil
        local tip = getText("UI_MinidoracatMiniMap_Parking")
        for i = 1, data.count or 0 do
            local e = data[i]
            local rn, r, b = e.rn, e.r, e.b
            if type(rn) == "number" and rn >= 1 and type(r) == "table" and validRect(b) then
                local rects = {}
                for k = 1, rn do
                    if validRect(r[k]) then rects[#rects + 1] = toRect(r[k]) end
                end
                if rects[1] then
                    local box = toRect(b)
                    local lead = e.i == 1
                    built[#built + 1] = {
                        id = "parking:" .. i,
                        rects = rects,
                        lodRect = box,
                        fill = PARKING_COLOR,
                        fillAlpha = PARKING_FILL_ALPHA,
                        haloAlpha = PARKING_HALO_ALPHA,
                        tip = tip,
                        category = "parking",
                        icon = lead and icon or nil,
                        iconOnce = lead or nil,
                        iconRect = lead and box or nil,
                    }
                end
            end
        end
    end
    built.hasFill = on
    built.hasLine = false
    built.hasIcon = icon ~= nil
    zones = built
end

local function currentSig(data)
    return (Core.getBoolOption("ParkingLayer", true) and "1" or "0")
        .. (Core.getBoolOption("PoiColorIcons", false) and "1" or "0") .. tostring(data)
end

local function rebuildIfChanged()
    local data = currentEntries()
    local sig = currentSig(data)
    if sig ~= lastSig then
        lastSig = sig
        build(data)
    end
end

local registered = false
Events.OnGameStart.Add(function()
    -- 同一次 Lua 載入再開第二局時 OnGameStart 會再觸發：provider 只註冊一次，否則每幀畫兩遍
    if not registered then
        registered = true
        MinidoracatMiniMapAPI.registerZoneProvider(OWN_PROVIDER_ID, function() return zones end, nil, true)
    end
    rebuildIfChanged()
end)

local sigTick = 0
Events.OnTick.Add(function()
    sigTick = sigTick + 1
    if sigTick < 15 then return end
    sigTick = 0
    rebuildIfChanged()
end)
