-- MinidoracatMiniMap_ClearedUI.lua — 資源點「去過／已清空」的介面：角標、停留提示、地圖右鍵、世界右鍵、搜尋用的狀態字
-- 資料在 _Cleared.lua（Core.Cleared）。地圖代碼：1 去過、2 已清空、3 隊友已清空、4 已刷新。
-- 角標是預先產生的小貼圖（scripts/make_cleared_badges.py；白色形狀＋深色描邊，繪製時染色）：
-- 去過＝白點、已清空＝白勾（隊友青勾）、已刷新＝綠三角，畫在圖標左上（右下是地下室角標）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready and Core.Cleared) or Core.clearedTip then return end
local CL = Core.Cleared

local UI = {
    TEX = { "media/ui/minimap_badge_visited.png", "media/ui/minimap_badge_cleared.png",
        "media/ui/minimap_badge_cleared.png", "media/ui/minimap_badge_refreshed.png" },
    COLOR = { { 1, 1, 1 }, { 1, 1, 1 }, { 0.35, 0.9, 1 }, { 0.4, 0.95, 0.45 } },
    tex = {},
    NAME_MAX = 40,
}
CL.UI = UI
-- 搜尋結果切成「顯示已清空」時，已清空那一列的圓點變灰（_Search.lua）
Core.CLEARED_DOT = { r = 0.5, g = 0.5, b = 0.5 }

-- 角標：size＝圖標邊長；角標約圖標的一半、夾在 [6, 12] px
Core.clearedBadge = function(el, code, ix, iy, size, a)
    local t = UI.tex[code]
    if t == nil then
        t = getTexture(UI.TEX[code]) or false
        UI.tex[code] = t
    end
    if not t then return end
    local bs = math.floor(size * 0.5)
    if bs < 6 then bs = 6 end
    if bs > 12 then bs = 12 end
    local c = UI.COLOR[code]
    el:drawTextureScaled(t, ix - 1, iy - 1, bs, bs, a, c[1], c[2], c[3])
end

-- zone 的建築外框（POI 建置時寫 bx/by/bw/bh）
function UI.box(z)
    if not z.bw then return nil end
    return { x = z.bx, y = z.by, w = z.bw, h = z.bh }
end

function UI.ago(h)
    local d = math.floor((CL.now() - h) / 24)
    if d < 1 then return getText("UI_MinidoracatMiniMap_ClearedToday") end
    if d < 2 then return getText("UI_MinidoracatMiniMap_ClearedYesterday") end
    return getText("UI_MinidoracatMiniMap_ClearedDaysAgo", string.format("%d", d))
end

function UI.progress(text, s, n)
    if s <= 0 then return text end
    if n > 0 then
        return getText("UI_MinidoracatMiniMap_ClearedTipProgress", text, string.format("%d", math.min(s, n)),
            string.format("%d", n))
    end
    return getText("UI_MinidoracatMiniMap_ClearedTipProgressN", text, string.format("%d", s))
end

-- 狀態那一段（不含名稱）：提示與搜尋共用。回 text 或 nil
function UI.stateText(own, team)
    if own and own.ch > 0 then
        return UI.progress(getText("UI_MinidoracatMiniMap_ClearedStateCleared",
            getText(own.cs == "a" and "UI_MinidoracatMiniMap_ClearedByAuto" or "UI_MinidoracatMiniMap_ClearedByManual"),
            UI.ago(own.ch)), own.s, own.n)
    end
    if team and team.m.ch > 0 then
        return getText("UI_MinidoracatMiniMap_ClearedStateTeam", team.a, UI.ago(team.m.ch))
    end
    local text
    if own and own.rh > 0 then
        text = getText("UI_MinidoracatMiniMap_ClearedStateRefreshed", UI.ago(own.rh))
    elseif own and own.vh > 0 then
        text = UI.progress(getText("UI_MinidoracatMiniMap_ClearedStateVisited", UI.ago(own.vh)), own.s, own.n)
    end
    if team and team.m.s > 0 then
        local t = getText("UI_MinidoracatMiniMap_ClearedStateTeamProgress", team.a, string.format("%d", team.m.s),
            string.format("%d", team.m.n))
        text = text and getText("UI_MinidoracatMiniMap_ClearedJoin", text, t) or t
    end
    return text
end

-- 停留提示（_Zones.lua drawZoneIcon，只在指標壓在內建資源點圖標上時）
Core.clearedTip = function(pn, z, base)
    local box = UI.box(z)
    if not (box and base) then return base end
    local own, team = CL.lookup(pn, box)
    local st = UI.stateText(own, team)
    if not st then return base end
    return getText("UI_MinidoracatMiniMap_ClearedTip", base, st)
end

-- 搜尋（_Search.lua）：狀態字與代碼
Core.clearedSearchState = function(pn, box)
    local code, mine, own, team = CL.code(pn, box)
    if not code then return nil, nil, false end
    return UI.stateText(own, team), code, mine
end

function UI.apply(payload)
    if payload.op == "forget" then
        Core.clearedForget(payload.pn, payload.box)
    else
        Core.clearedSet(payload.pn, payload.box, payload.op == "set")
    end
end

-- 標為已清空／取消已清空／忘記這裡（只能取消自己標的）
Core.clearedMenuFill = function(menu, pn, box)
    local _, _, own = CL.code(pn, box)
    if own and own.ch > 0 then
        menu:addOption(getText("UI_MinidoracatMiniMap_ClearedUnset"), { op = "unset", pn = pn, box = box }, UI.apply)
    else
        menu:addOption(getText("UI_MinidoracatMiniMap_ClearedSet"), { op = "set", pn = pn, box = box }, UI.apply)
    end
    if own then
        menu:addOption(getText("UI_MinidoracatMiniMap_ClearedForget"), { op = "forget", pn = pn, box = box }, UI.apply)
    end
end

function UI.title(name)
    if #name > UI.NAME_MAX then name = name:sub(1, UI.NAME_MAX - 1) .. "..." end
    return getText("UI_MinidoracatMiniMap_ClearedMenuOf", name)
end

function UI.catName(key)
    local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    local def = cats and cats[key]
    return def and getText(def.nameKey) or key
end

-- 地圖右鍵（_Nav.lua Core.mapMenuFill）：游標下的內建資源點圖標（_Zones.lua 最後一幀命中的那顆）
-- 只認最近一次 prerender 畫的那顆：圖標 pass 那一幀沒跑（圖層關）時幀號已經往前走，舊的命中不算
Core.poiIconAt = function(inner)
    local z = inner and inner._minidoracatPoiHit
    if z and inner._minidoracatPoiHitFrame == inner._minidoracatFrame and UI.box(z) then return z end
    return nil
end

-- 「資源點：名稱 ▸」：標記三項＋加入收藏...（在圖標位置）
Core.clearedMapMenu = function(context, pn, z)
    local box = UI.box(z)
    local name = z.tip or UI.catName(z.category)
    local sub = Core.mapSubMenu(context, nil, UI.title(name)) or context
    Core.clearedMenuFill(sub, pn, box)
    local r = z.iconRect or (z.rects and z.rects[1])
    if r and Core.placesPromptAdd then
        sub:addOption(getText("UI_MinidoracatMiniMap_PlaceAdd"), pn, Core.placesPromptAdd,
            math.floor((r.x1 + r.x2) / 2) + 0.5, math.floor((r.y1 + r.y2) / 2) + 0.5, name)
    end
end

-- 世界右鍵（_Places.lua onFillWorld）：點到的那格在資源點建築裡才列
Core.clearedWorldMenu = function(pn, context, x, y, z)
    local cell = getCell()
    local sq = cell and cell:getGridSquare(math.floor(x), math.floor(y), z)
    local def = sq and sq:getBuildingDef()
    if not (def and CL.isPoi(def)) then return end
    local API = MinidoracatMiniMapResourceAPI
    local cats = API and API.buildingCategories(def)
    local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
    local name
    for i = 1, order and #order or 0 do
        if cats and cats[order[i]] then
            name = name and (name .. " / " .. UI.catName(order[i])) or UI.catName(order[i])
        end
    end
    local sub = Core.mapSubMenu(context, nil, UI.title(name or "?")) or context
    Core.clearedMenuFill(sub, pn, CL.defBox(def))
end
