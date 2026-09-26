-- Marker provider API（原型，markerApiVersion 2）：addon 以 per-player 快取提供動態點位，
-- 本 MOD 只渲染。與 zone provider 的差別：providerFn 收到畫面擁有者 playerNum 與表面，
-- 讓同一 addon 依 slot 交出不同的名單（例如 VehicleManager 只給該玩家有權看的車）。
-- 契約（完整說明見 docs/addon-api.md §3.14）：
--   registerMarkerProvider(ownerModId, providerFn)；同 owner 重註冊＝取代（不重複畫）。
--   providerFn(playerNum, surface) → { revision=number, markers={ marker, ... } } | nil
--     surface＝"mini"｜"world"；每幀被呼叫，必須回傳快取表，不做網路 I/O、不掃車、不每幀重建。
--     markers 為連續陣列；本 MOD 只讀不改。revision 由 provider 自行遞增（渲染端目前不快取）。
--   marker v1＝{ id=string, x=, y=(世界 square 座標), texture=<Texture>, r=, g=, b=(0-1),
--             label=string|nil(已翻譯), state="live"｜其他（非 live 全部圖層以 0.55 透明度畫） }
--   v2 選用欄位（additive）：scale=number（夾 1..2.5）、badge={ texture=, r=, g=, b=, a= }
--     （圖示下方底圖，邊長＋6）、ring={ r=, g=, b=, a= }（需 badge.texture，同貼圖邊長＋10）、
--     labelColor={ r=, g=, b= }（預設白，一律加 1px 黑陰影）。
--   provider 或單一 marker 出錯只影響該 provider，依 owner 每場 log 一次。
-- 層序：主檔在 MiniMap 自有載具／動物／殭屍點之後、座標列／導航之前呼叫。
-- 載入序：字母序在主檔之後，主檔已建好 MinidoracatMiniMapCore／MinidoracatMiniMapAPI。
local Core = MinidoracatMiniMapCore
local API = MinidoracatMiniMapAPI
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

local providers = {} -- { { owner=, fn=, errLogged= }, ... }

API.markerApiVersion = 2
function API.registerMarkerProvider(ownerModId, providerFn)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(providerFn) ~= "function" then
        log("registerMarkerProvider bad arguments (need ownerModId string, providerFn function)")
        return
    end
    for i = 1, #providers do
        if providers[i].owner == ownerModId then providers[i] = { owner = ownerModId, fn = providerFn }; return end
    end
    providers[#providers + 1] = { owner = ownerModId, fn = providerFn }
end

local SIZE = { mini = 12, world = 16 }
local WHITE = { r = 1, g = 1, b = 1 } -- labelColor 預設（模組常數：每幀路徑不配置 table）

local function drawProvider(inner, provider, pn, surface)
    local res = provider.fn(pn, surface)
    local markers = type(res) == "table" and res.markers
    if type(markers) ~= "table" then return end
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local base = SIZE[surface]
    local fh -- 字高首次有 label 才查（隨 UI 字型倍率變動，不可硬編碼）
    -- ponytail: 每個 marker 各投影一次（2 次 Java 呼叫）；個人車隊量級足夠，上百點再改 deriveAffine
    for i = 1, #markers do
        local m = markers[i]
        if m.texture then
            local s = base
            local scale = m.scale
            if type(scale) == "number" and scale > 1 then
                s = math.floor(base * math.min(scale, 2.5) + 0.5)
            end
            local badge = m.badge
            if type(badge) ~= "table" or not badge.texture then badge = nil end
            local ring = badge and m.ring
            if type(ring) ~= "table" then ring = nil end
            local outer = ring and s + 10 or badge and s + 6 or s
            local cx = mapAPI:worldToUIX(m.x, m.y)
            local cy = mapAPI:worldToUIY(m.x, m.y)
            local ox, oy = cx - outer / 2, cy - outer / 2
            if ox >= 1 and oy >= 1 and ox + outer <= w - 1 and oy + outer <= h - 1 then
                local a = m.state == "live" and 1 or 0.55
                if ring then
                    inner:drawTextureScaled(badge.texture, ox, oy, outer, outer, (ring.a or 1) * a,
                        ring.r or 1, ring.g or 1, ring.b or 1)
                end
                if badge then
                    local bs = s + 6
                    inner:drawTextureScaled(badge.texture, cx - bs / 2, cy - bs / 2, bs, bs, (badge.a or 1) * a,
                        badge.r or 1, badge.g or 1, badge.b or 1)
                end
                inner:drawTextureScaled(m.texture, cx - s / 2, cy - s / 2, s, s, a, m.r or 1, m.g or 1, m.b or 1)
                if m.label then
                    fh = fh or getTextManager():getFontHeight(UIFont.Small)
                    local lc = type(m.labelColor) == "table" and m.labelColor or WHITE
                    local lx, ly = ox + outer + 2, cy - fh / 2
                    inner:drawText(m.label, lx + 1, ly + 1, 0, 0, 0, a, UIFont.Small)
                    inner:drawText(m.label, lx, ly, lc.r or 1, lc.g or 1, lc.b or 1, a, UIFont.Small)
                end
            end
        end
    end
end

local function drawMarkers(inner, surface)
    if #providers == 0 then return end
    local pn = inner.playerNum or 0
    for i = 1, #providers do
        local provider = providers[i]
        local ok, err = pcall(drawProvider, inner, provider, pn, surface)
        if not ok and not provider.errLogged then
            provider.errLogged = true
            log("marker provider " .. provider.owner .. " failed: " .. tostring(err))
        end
    end
end

-- 主檔 prerender wrap 經 Core 查表呼叫（模組缺席時 pcall(nil) 回 false、log-once）
Core.drawMarkers = drawMarkers
