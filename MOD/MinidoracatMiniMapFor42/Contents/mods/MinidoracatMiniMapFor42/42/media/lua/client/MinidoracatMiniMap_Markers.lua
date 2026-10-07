-- Marker provider API（原型，markerApiVersion 3）：addon 以 per-player 快取提供動態點位，
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
--   v3 選用欄位：layer=<id>，以 (provider owner, id) 查 settings v5 登記的圖層：該表面關閉＝不畫；
--     基準邊長改用圖層大小（px，取代「標記大小」）；圖層有名稱且該表面名稱關＝不畫 label。
--     未登記的 id 或沒有 layer＝v2 行為。圖層值只存在本 MOD 的 ModOptions 文字欄 MarkerLayers。
--   provider 或單一 marker 出錯只影響該 provider，依 owner 每場 log 一次。
-- 層序：主檔在 MiniMap 自有載具／動物／殭屍點之後、座標列／導航之前呼叫。
-- 載入序：字母序在主檔之後、_Settings 之前，主檔已建好 MinidoracatMiniMapCore／MinidoracatMiniMapAPI。
local Core = MinidoracatMiniMapCore
local API = MinidoracatMiniMapAPI
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

local providers = {} -- { { owner=, fn=, errLogged= }, ... }

API.markerApiVersion = 3
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

--------------------------------------------------------------------------------
-- 圖層偏好（v3）：settings v5 的 spec.layers 經 Core.registerMarkerLayers 登記預設值；
-- 玩家改過的層存 ModOptions 文字欄 MarkerLayers：
--   "<owner>/<id>=<mini 0|1>,<world 0|1>,<size>,<namesMini 0|1>,<namesWorld 0|1>;..."
-- 只存與預設不同的層；未登記 owner 的條目原樣保留（addon 晚到或暫時停用不丟值）。
-- Core.markerLayer 每次呼叫只比對原字串，變了才重解析（重解析才配置 table）。
--------------------------------------------------------------------------------
local layerDefs = {}      -- owner → { [id] = { default = <layer spec>, prefs = <快取表> } }
local overrides = {}      -- "owner/id" → { mini, world, size, namesMini, namesWorld }
local overrideOrder = {}  -- 序列化順序（解析序＋新增序；不 table.sort）
local layerRaw            -- 最後解析的原字串（nil＝下次必重解析）

local function readLayersRaw()
    local mo = Core.modOptions
    local opt = mo and mo:getOption("MarkerLayers")
    local v = opt and opt:getValue()
    return type(v) == "string" and v or ""
end

local function flag(s) return s == "1" end

local function parseLayers(raw)
    overrides, overrideOrder = {}, {}
    for entry in raw:gmatch("[^;]+") do
        local owner, id, mini, world, size, nm, nw =
            entry:match("^%s*(.-)/([%w_%-]+)=([01]),([01]),(%d+),([01]),([01])%s*$")
        size = tonumber(size)
        if owner and owner ~= "" and size and size >= 8 and size <= 48 then
            local key = owner .. "/" .. id
            if not overrides[key] then overrideOrder[#overrideOrder + 1] = key end
            overrides[key] = { flag(mini), flag(world), size - size % 1, flag(nm), flag(nw) }
        end
    end
end

-- 預設＋覆寫 → 快取表（就地改寫，呼叫端可長期持有同一張表）
local function resolvePrefs(owner, rec)
    local d, p = rec.default, rec.prefs
    local o = overrides[owner .. "/" .. d.id]
    p.show.mini, p.show.world = d.show.mini, d.show.world
    p.size = d.size
    if p.names then p.names.mini, p.names.world = d.names.mini, d.names.world end
    if o then
        p.show.mini, p.show.world, p.size = o[1], o[2], o[3]
        if p.names then p.names.mini, p.names.world = o[4], o[5] end
    end
end

local function syncLayers()
    local raw = readLayersRaw()
    if raw == layerRaw then return end
    layerRaw = raw
    parseLayers(raw)
    for owner, defs in pairs(layerDefs) do
        for _, rec in pairs(defs) do resolvePrefs(owner, rec) end
    end
end

-- Settings 註冊期呼叫（registerSettingsSection 驗證後的 layers 陣列；空陣列＝清除該 owner）
function Core.registerMarkerLayers(owner, layers)
    local defs
    for i = 1, #layers do
        local d = layers[i]
        defs = defs or {}
        defs[d.id] = { default = d, prefs = { show = { mini = true, world = true }, size = 16,
            names = d.names and { mini = true, world = true } or nil } }
    end
    layerDefs[owner] = defs
    layerRaw = nil -- 新登記的層要套用既有覆寫
end

-- (owner, id) → { show = { mini, world }, size, names = { mini, world } | nil }（快取表，勿改）；
-- 未登記＝nil
local function markerLayer(owner, id)
    local defs = layerDefs[owner]
    local rec = defs and defs[id]
    if not rec then return nil end
    syncLayers()
    return rec.prefs
end
Core.markerLayer = markerLayer

local function writeLayers()
    local parts = {}
    for i = 1, #overrideOrder do
        local key = overrideOrder[i]
        local o = overrides[key]
        parts[#parts + 1] = string.format("%s=%d,%d,%d,%d,%d", key, o[1] and 1 or 0,
            o[2] and 1 or 0, o[3], o[4] and 1 or 0, o[5] and 1 or 0)
    end
    local raw = table.concat(parts, ";")
    local mo = Core.modOptions
    local opt = mo and mo:getOption("MarkerLayers")
    if not opt then return false end
    opt:setValue(raw)
    if mo.apply then mo:apply() end
    PZAPI.ModOptions:save()
    return true
end

local function dropOverride(key)
    overrides[key] = nil
    for i = #overrideOrder, 1, -1 do
        if overrideOrder[i] == key then table.remove(overrideOrder, i) end
    end
end

-- field＝"showMini"｜"showWorld"｜"size"｜"namesMini"｜"namesWorld"；回 true＝已寫入。
-- 與預設相同的層從字串移除（只存玩家改過的層）
function Core.setMarkerLayer(owner, id, field, value)
    local p = markerLayer(owner, id)
    if not p then return false end
    local v = { p.show.mini, p.show.world, p.size,
        p.names and p.names.mini or false, p.names and p.names.world or false }
    if field == "showMini" then v[1] = value == true
    elseif field == "showWorld" then v[2] = value == true
    elseif field == "size" then
        if type(value) ~= "number" or value ~= value then return false end
        value = value - value % 1
        v[3] = value < 8 and 8 or value > 48 and 48 or value
    elseif field == "namesMini" and p.names then v[4] = value == true
    elseif field == "namesWorld" and p.names then v[5] = value == true
    else return false end
    local d = layerDefs[owner][id].default
    local key = owner .. "/" .. id
    if v[1] == d.show.mini and v[2] == d.show.world and v[3] == d.size
            and (not d.names or (v[4] == d.names.mini and v[5] == d.names.world)) then
        dropOverride(key)
    else
        if not overrides[key] then overrideOrder[#overrideOrder + 1] = key end
        overrides[key] = v
    end
    layerRaw = nil
    return writeLayers()
end

-- 「重設此分類」：移除該 owner 全部覆寫；回 true＝字串有變並已寫入
function Core.resetMarkerLayers(owner)
    syncLayers()
    local prefix = owner .. "/"
    local changed = false
    for i = #overrideOrder, 1, -1 do
        local key = overrideOrder[i]
        if key:sub(1, #prefix) == prefix and not key:find("/", #prefix + 1, true) then
            overrides[key] = nil
            table.remove(overrideOrder, i)
            changed = true
        end
    end
    if not changed then return false end
    layerRaw = nil
    return writeLayers()
end

--------------------------------------------------------------------------------
-- 繪製
--------------------------------------------------------------------------------
local SIZE = { mini = 12, world = 16 }
local WHITE = { r = 1, g = 1, b = 1 } -- labelColor 預設（模組常數：每幀路徑不配置 table）

-- 單一 marker：(cx, cy)＝UI 座標中心；sizePx＝基準大小（px／16 倍率，16＝原 12／16px）；
-- label＝要畫的字（nil＝不畫）；tz＝地圖文字倍率（nil＝現讀 Core.mapTextZoom）。
-- 地圖與設定預覽共用；最外層超出 inner 邊界（留 1px）整顆不畫。回 true＝有畫
local function drawMarkerAt(inner, m, cx, cy, surface, sizePx, label, tz)
    local w, h = inner.width, inner.height
    local k = sizePx / 16
    local s = SIZE[surface] * k
    local scale = m.scale
    if type(scale) == "number" and scale > 1 then
        s = s * math.min(scale, 2.5)
    end
    s = s + 0.5
    s = s - s % 1 -- floor(基準 × scale + 0.5)；純 Lua（值恆正）
    local badge = m.badge
    if type(badge) ~= "table" or not badge.texture then badge = nil end
    local ring = badge and m.ring
    if type(ring) ~= "table" then ring = nil end
    local pad6, pad10 = 6 * k, 10 * k -- badge／ring 外擴量同比例
    local outer = ring and s + pad10 or badge and s + pad6 or s
    local ox, oy = cx - outer / 2, cy - outer / 2
    if not (ox >= 1 and oy >= 1 and ox + outer <= w - 1 and oy + outer <= h - 1) then return false end
    local a = m.state == "live" and 1 or 0.55
    if ring then
        inner:drawTextureScaled(badge.texture, ox, oy, outer, outer, (ring.a or 1) * a,
            ring.r or 1, ring.g or 1, ring.b or 1)
    end
    if badge then
        local bs = s + pad6
        inner:drawTextureScaled(badge.texture, cx - bs / 2, cy - bs / 2, bs, bs, (badge.a or 1) * a,
            badge.r or 1, badge.g or 1, badge.b or 1)
    end
    inner:drawTextureScaled(m.texture, cx - s / 2, cy - s / 2, s, s, a, m.r or 1, m.g or 1, m.b or 1)
    if label then
        tz = tz or Core.mapTextZoom()
        -- 字高隨 UI 字型倍率變動，不可硬編碼
        local fh = getTextManager():getFontHeight(UIFont.Small) * tz
        local lc = type(m.labelColor) == "table" and m.labelColor or WHITE
        local lx, ly = ox + outer + 2, cy - fh / 2
        -- 右側放不下（字會被視窗右緣切掉）就改放最外層左側；左側也放不下才維持右側
        local tw = getTextManager():MeasureStringX(UIFont.Small, label) * tz
        if lx + tw > w - 1 and ox - 2 - tw >= 1 then lx = ox - 2 - tw end
        Core.drawMapText(inner, label, lx + 1, ly + 1, 0, 0, 0, a, UIFont.Small, tz)
        Core.drawMapText(inner, label, lx, ly, lc.r or 1, lc.g or 1, lc.b or 1, a, UIFont.Small, tz)
    end
    return true
end
Core.drawMarkerAt = drawMarkerAt

local function drawProvider(inner, provider, pn, surface)
    local res = provider.fn(pn, surface)
    local markers = type(res) == "table" and res.markers
    if type(markers) ~= "table" then return end
    local mapAPI = inner.mapAPI
    local owner = provider.owner
    -- 沒有圖層的 marker 跟玩家「標記大小」；標籤跟「地圖文字大小」（每 provider 讀一次）
    local defSize = Core.markerIconSize()
    local tz = Core.mapTextZoom()
    -- ponytail: 每個 marker 各投影一次（2 次 Java 呼叫）；個人車隊量級足夠，上百點再改 deriveAffine
    for i = 1, #markers do
        local m = markers[i]
        if m.texture then
            local lay = m.layer ~= nil and markerLayer(owner, m.layer) or nil
            if not lay then
                drawMarkerAt(inner, m, mapAPI:worldToUIX(m.x, m.y), mapAPI:worldToUIY(m.x, m.y),
                    surface, defSize, m.label, tz)
            elseif lay.show[surface] then
                local label = m.label
                if lay.names and lay.names[surface] == false then label = nil end
                drawMarkerAt(inner, m, mapAPI:worldToUIX(m.x, m.y), mapAPI:worldToUIY(m.x, m.y),
                    surface, lay.size, label, tz)
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
