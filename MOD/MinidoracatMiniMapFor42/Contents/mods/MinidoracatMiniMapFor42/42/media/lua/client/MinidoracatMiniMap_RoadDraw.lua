-- MinidoracatMiniMap_RoadDraw.lua
-- 本檔範圍：自訂道路圖層（兩張地圖共用）、設定視窗預覽（Core.drawRoadsPreview）、世界地圖圖例的
-- 色塊與列（Core.roadsLegend、RD.drawLegendSample），以及右鍵命中（Core.roadMapHit）。
-- 呼叫點：_Nav.lua drawNavTargets 在導航路線之前呼叫 Core.drawCustomRoads（青色路線蓋在上面）；
-- 小地圖與世界地圖都經 drawNavTargets，所以一個入口管兩張地圖。
-- 資料只讀 RoadData 的 Core.roadsVisible(pn)（分割畫面每位玩家一份），依 Core.roadsRevision() 快取。
-- 畫法（ModOptions CustomRoadStyle，設計稿 minimap-road-style-1023）：
--   A 路面色帶：照路寬與路面畫成一條路（描邊＋填色，柏油拉近加黃色中線）；
--   B 描邊路廊：淡填色＋兩側米色邊線；C 地圖線條：固定 7／4 px 的描邊線。
--   別人分享的路：A、C 描邊改藍，B 邊線改淺藍；停用的路：淡化＋虛線邊（C 整體淡化）。
-- 幾何：路帶在世界座標往兩側推出半寬、轉角 miter（限 MITER 倍半寬）後投影成四邊形。投影是仿射的
-- （主檔 deriveAffine），直線、交點投影後不變，所以本檔在畫面座標解同一組 miter 交點：
-- 每段的畫面半寬＝世界半寬×（|det|×世界長／畫面長），結果與先推再投影相同；拉遠時夾到 CustomRoadMinWidth。
-- 效能（RoadsPerfE2E：瓶頸是繪製呼叫數，每次約 5 µs）：
--   1. 每幀量 3 點導出仿射係數（6 次跨界），之後只做算術；
--   2. 每條路在 revision 變時預算多層 RDP 簡化（容差逐層加倍），畫時挑「容差≈1 px」那層，
--      畫面上不到 1 px 的點再併掉；
--   3. 每幀繪製呼叫總預算 BUDGET：超過依序拿掉中線與虛線、拿掉描邊、改用更粗的層；
--      最粗一層每條路仍有兩端一段，不截掉任何一條；
--   4. drawPolygon 不裁切，整段包 setStencilRect／clearStencilRect（同 _Zones.lua），出錯也必定 clear。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.drawCustomRoads then return end
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end
local sqrt, floor = math.sqrt, math.floor

local function rgb(r, g, b) return { r = r / 255, g = g / 255, b = b / 255 } end
local RD = {
    -- 路面：fill＝A／B 填色、case＝描邊、line＝C 內線（dashed＝C 畫虛線）
    SURF = {
        paved = { fill = rgb(92, 94, 98), case = rgb(34, 34, 36), line = rgb(226, 226, 226), paved = true },
        gravel = { fill = rgb(166, 156, 136), case = rgb(70, 64, 52), line = rgb(205, 190, 160) },
        dirt = { fill = rgb(140, 104, 66), case = rgb(58, 40, 22), line = rgb(196, 150, 96), dashed = true },
        unknown = { fill = rgb(128, 124, 116), case = rgb(50, 48, 44), line = rgb(190, 186, 176) },
    },
    BLUE = rgb(47, 109, 181),        -- 別人分享的路：A、C 描邊
    CENTER = rgb(226, 200, 110),     -- 柏油中線
    OFF_EDGE = rgb(215, 215, 215),   -- A 停用：兩側虛線
    B_EDGE = rgb(243, 234, 208), B_EDGE_RECV = rgb(150, 190, 240),
    A_CASE = 1.6, A_CASE_RECV = 2.6, -- A 描邊比路面多推的 px
    CENTER_W = 1.2, CENTER_ON = 6, CENTER_OFF = 6,
    CENTER_MIN_SCALE = 3,            -- 每格 ≥ 這麼多 px 才畫中線
    A_OFF_FILL = 0.30, OFF_EDGE_W = 1.2, OFF_ON = 4, OFF_GAP = 4,
    B_FILL = 0.28, B_OFF_FILL = 0.12, B_EDGE_W = 1.6, B_OFF_EDGE = 0.6,
    C_CASE = 7, C_LINE = 4, C_ON = 8, C_GAP = 4, C_OFF = 0.4,
    MITER = 2,                       -- 轉角外推上限＝MITER×半寬
    DEFAULT_W = 4,                   -- 缺路寬時（同 _RoadRecord DEFAULT_W）
    BUDGET = 1200,                   -- 每幀繪製呼叫（drawPolygon；線也畫成四邊形）上限
    LOD_TOL0 = 0.5,                  -- 第 2 層的 RDP 容差（格），之後逐層加倍
    LOD_TOL_MAX = 65536,
    LABEL_PAD = 8,                   -- 路在畫面上至少比標籤長這麼多才寫名稱（拉遠時字不擠成一團）
    PREVIEW_S = 3,                   -- 設定預覽的每格 px（拉近看得到柏油中線）
    HIT_PX = 8,                      -- 右鍵命中半徑（畫面 px）
    -- 道路工具正在編輯的那條（_RoadTool.lua drawOverlay → RD.drawPolyline）：黑底＋淺色虛線
    UNDER = { r = 0.08, g = 0.08, b = 0.08, a = 0.85, w = 6 },
    OVER = { r = 0.953, g = 0.918, b = 0.816, a = 1, w = 2 },
    DASH_ON = 7, DASH_OFF = 5, MAX_DASH = 3000,
}
Core.RoadDraw = RD
local SURF = RD.SURF

-- 「顯示在」兩格（主檔 Core.LAYER_MAPS.customRoads）；表上沒有這列＝照畫
function RD.layerOn(surface)
    local lm = Core.LAYER_MAPS
    if not (lm and lm.customRoads and Core.layerOn) then return true end
    return Core.layerOn("customRoads", surface)
end

-- 多層簡化：levels[k]＝保留的原始點索引（遞增）＋ tol（格）。第 1 層原樣；之後容差逐層加倍，
-- 路寬或路面換類的點一律保留（每段顏色、寬度才對），沒變少的層不收；最後一層只留兩端（降級保底）。
-- RDP（世界座標、點到線段距離）只跑一次：切點與容差無關，所以記下每個點「還會被保留的最大容差」
-- （自己那一刀的距離與上層取小），容差 tol 那層＝重要度 > tol 的點，和逐層各跑一次 RDP 結果相同
-- （同 _RoadRecord.lua rdpImportance）。逐層跑時一條 300 點的路在 Kahlua 要 51–64 ms（E2E
-- share-road-persist-mp 1024c），登入或收到分享快照時整批重算會卡 1.4–1.5 秒。不遞迴（Kahlua 呼叫深度）
local stack, imp = {}, {}
function RD.buildLevels(pts, np, segW, segS)
    local HUGE = math.huge
    for i = 1, np do imp[i] = 0 end
    imp[1], imp[np] = HUGE, HUGE
    local top, a = 0, 1
    for i = 2, np do
        if i == np or segW[i - 1] ~= segW[i] or segS[i - 1] ~= segS[i] then
            imp[i] = HUGE
            stack[top + 1], stack[top + 2], stack[top + 3] = a, i, HUGE
            top = top + 3
            a = i
        end
    end
    while top > 0 do
        local i, j, pimp = stack[top - 2], stack[top - 1], stack[top]
        top = top - 3
        if j > i + 1 then
            local ax, ay = pts[i * 2 - 1], pts[i * 2]
            local dx, dy = pts[j * 2 - 1] - ax, pts[j * 2] - ay
            local l2 = dx * dx + dy * dy
            local best, bi = -1, nil
            for k = i + 1, j - 1 do
                local px, py = pts[k * 2 - 1] - ax, pts[k * 2] - ay
                local t = l2 > 0 and (px * dx + py * dy) / l2 or 0
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                local ex, ey = px - dx * t, py - dy * t
                local d2 = ex * ex + ey * ey
                if d2 > best then best, bi = d2, k end
            end
            local v = best < pimp and best or pimp
            imp[bi] = v
            stack[top + 1], stack[top + 2], stack[top + 3] = i, bi, v
            stack[top + 4], stack[top + 5], stack[top + 6] = bi, j, v
            top = top + 6
        end
    end
    local all = { tol = 0 }
    for i = 1, np do all[i] = i end
    local levels = { all }
    local tol = RD.LOD_TOL0
    while #levels[#levels] > 2 and tol <= RD.LOD_TOL_MAX do
        local t2, lv = tol * tol, { tol = tol }
        for i = 1, np do if imp[i] > t2 then lv[#lv + 1] = i end end
        if #lv < #levels[#levels] then levels[#levels + 1] = lv end
        tol = tol * 2
    end
    if #levels[#levels] > 2 then levels[#levels + 1] = { 1, np, tol = tol } end
    return levels
end

-- 一條路的繪製條目：世界點、各層、外接框、標籤與每幀重用的畫面座標陣列。
-- old＝上一版的同一條路（cacheFor 依同一組 pts 表或同 kind＋sid／id 找）：點、路寬、路面逐筆相同就沿用
-- 它的多層簡化（只有這三樣決定 levels；先比表本身，換了新表才逐筆比，不靠 rev）
local function sameArr(a, b, n)
    if a == b then return true end
    for i = 1, n do if a[i] ~= b[i] then return false end end
    return true
end
function RD.newEntry(road, kind, on, author, label, old)
    local pts = road.pts
    local np = floor(#pts / 2)
    local minx, miny, maxx, maxy = pts[1], pts[2], pts[1], pts[2]
    for k = 2, np do
        local x, y = pts[k * 2 - 1], pts[k * 2]
        if x < minx then minx = x elseif x > maxx then maxx = x end
        if y < miny then miny = y elseif y > maxy then maxy = y end
    end
    local segW, segS = road.segWidth or {}, road.segSurface or {}
    if label == nil then
        local name = road.name or ""
        if not on then
            label = getText("UI_MinidoracatMiniMap_RoadLabelOff", name)
        elseif kind == "received" and author then
            label = getText("UI_MinidoracatMiniMap_RoadLabelAuthor", name, author)
        elseif name ~= "" then
            label = name
        end
    end
    return { road = road, id = road.id, kind = kind, recv = kind == "received", off = not on,
        pts = pts, np = np, segW = segW, segS = segS,
        levels = old and old.np == np and sameArr(old.pts, pts, np * 2) and sameArr(old.segW, segW, np - 1)
            and sameArr(old.segS, segS, np - 1) and old.levels or RD.buildLevels(pts, np, segW, segS),
        minx = minx, miny = miny, maxx = maxx, maxy = maxy,
        label = label or nil, labelW = label and getTextManager():MeasureStringX(UIFont.Small, label) or 0,
        n = 0, px = {}, py = {}, wi = {}, hd = {}, sf = {}, nx = {}, ny = {}, ls = {}, vis = {} }
end

-- 每位玩家一份快取：roadsVisible 的結果轉成條目，revision 變了才重建；c.cnt 給圖例
local caches = {}
function RD.cacheFor(pn)
    if not Core.roadsVisible then return nil end
    local rev = Core.roadsRevision and Core.roadsRevision()
    local c = caches[pn]
    if c and rev ~= nil and c.rev == rev then return c end
    local list = Core.roadsVisible(pn) or {}
    -- 資料層改路一律整條換新表（_Roads.lua copyRoad），收到分享快照時更是整批換新表：上一版同一條路
    -- （同一組 pts 表，或同 kind＋sid／id）內容沒變就沿用多層簡化，只重算有變的那條。整批重算時，改一條路
    -- 要把 29 條×300 點全部重做，Kahlua 每次卡 1.5–2.7 秒；收快照、登入也各卡 1.4–1.5 秒（E2E share-road-persist-mp）
    local prev = {}
    for i = 1, c and c.n or 0 do
        local e = c[i]
        prev[e.pts] = e
        if e.key then prev[e.key] = e end
    end
    c = { rev = rev, n = 0, ownOn = 0, ownOff = 0, recvOn = 0, recvOff = 0 }
    for i = 1, #list do
        local e = list[i]
        local road = e and e.road
        local pts = road and road.pts
        if pts and #pts >= 4 then
            local on = e.enabled ~= false
            local id = road.sid or road.id
            local key = id ~= nil and (tostring(e.kind) .. ":" .. tostring(id)) or nil
            c.n = c.n + 1
            c[c.n] = RD.newEntry(road, e.kind, on, e.author, nil, prev[pts] or (key and prev[key]))
            c[c.n].key = key
            local bucket = (e.kind == "received" and "recv" or "own") .. (on and "On" or "Off")
            c[bucket] = c[bucket] + 1
        end
    end
    caches[pn] = c
    return c
end

-- 選項（每幀讀；契約鍵見 _Settings.lua 自訂道路分類）
function RD.readOptions(F)
    local style = Core.getComboIndex("CustomRoadStyle", 1)
    F.style = (style == 2 or style == 3) and style or 1
    F.alpha = Core.getSliderValue("CustomRoadAlpha", 85, 30, 100) / 100
    F.minPx = Core.getSliderValue("CustomRoadMinWidth", 3, 1, 6)
    F.names = Core.getBoolOption("CustomRoadNames", true) == true
    F.recv = Core.getBoolOption("CustomRoadReceived", true) == true
    F.dis = Core.getBoolOption("CustomRoadDisabled", true) == true
end

-- 投影第 k 層：畫面點（不到 1 px 的併掉，最後一點一定留）、每段半寬／路面／法線／長度／入鏡，
-- 並把這條的繪製呼叫數累進 F（base＝一定畫的、casec＝描邊級、dashc＝中線與虛線級、
-- solid＝拿掉虛線後停用路改畫實線邊的成本）。dash 數取上界 floor(長/週期)+2，預算只會高估
function RD.project(e, k, F)
    local lv = e.levels[k]
    local m = #lv
    local pts, px, py, wi = e.pts, e.px, e.py, e.wi
    local acx, acy, p0x, p0y = F.acx, F.acy, F.p0x, F.p0y
    local sxx, sxy, syx, syy = F.sxx, F.sxy, F.syx, F.syy
    local n, lx, ly = 0, 0, 0
    for j = 1, m do
        local i = lv[j]
        local dx, dy = pts[i * 2 - 1] - acx, pts[i * 2] - acy
        local x, y = p0x + dx * sxx + dy * syx, p0y + dx * sxy + dy * syy
        local ex, ey = x - lx, y - ly
        if n == 0 or ex * ex + ey * ey >= 1 then
            n = n + 1
            px[n], py[n], wi[n] = x, y, i
            lx, ly = x, y
        elseif j == m then
            if n == 1 then n = 2 end
            px[n], py[n], wi[n] = x, y, i
        end
    end
    e.n, e.k = n, k
    local style, minHalf, det, s = F.style, F.minPx / 2, F.det, F.s
    local x0, y0, x1, y1 = F.x0, F.y0, F.x1, F.y1
    local segW, segS, hd, sf, nxs, nys, ls, vis = e.segW, e.segS, e.hd, e.sf, e.nx, e.ny, e.ls, e.vis
    local off, center = e.off, style ~= 3 and not e.off and s >= RD.CENTER_MIN_SCALE
    local cPer, oPer, dPer = RD.CENTER_ON + RD.CENTER_OFF, RD.OFF_ON + RD.OFF_GAP, RD.C_ON + RD.C_GAP
    local V, len, base, casec, dashc, solid = 0, 0, 0, 0, 0, 0
    for q = 1, n - 1 do
        local a, b = wi[q], wi[q + 1]
        local dx, dy = px[q + 1] - px[q], py[q + 1] - py[q]
        local L = sqrt(dx * dx + dy * dy)
        local surf = SURF[segS[a]] or SURF.unknown
        local d
        if style == 3 then
            d = RD.C_LINE / 2
        else
            local wx, wy = pts[b * 2 - 1] - pts[a * 2 - 1], pts[b * 2] - pts[a * 2]
            local perp = L > 1e-6 and det * sqrt(wx * wx + wy * wy) / L or s
            d = (segW[a] or RD.DEFAULT_W) * perp / 2
            if d < minHalf then d = minHalf end
        end
        if L > 1e-6 then nxs[q], nys[q] = -dy / L, dx / L else nxs[q], nys[q] = 0, 1 end
        hd[q], sf[q], ls[q] = d, surf, L
        len = len + L
        local mg = d + 4
        local sx1, sx2 = px[q], px[q + 1]
        if sx1 > sx2 then sx1, sx2 = sx2, sx1 end
        local sy1, sy2 = py[q], py[q + 1]
        if sy1 > sy2 then sy1, sy2 = sy2, sy1 end
        local on = not (sx2 + mg < x0 or sx1 - mg > x1 or sy2 + mg < y0 or sy1 - mg > y1)
        vis[q] = on
        if on then
            V = V + 1
            base = base + 1
            if style == 1 then
                if off then
                    dashc = dashc + 2 * (floor((L + 4 * d) / oPer) + 2) -- 邊線比中線最多長兩個 miter
                    solid = solid + 2
                else
                    casec = casec + 1
                end
            elseif style == 2 then
                if off then
                    dashc = dashc + 2 * (floor((L + 4 * d) / oPer) + 2)
                    solid = solid + 2
                else
                    casec = casec + 2
                end
            else
                casec = casec + 1
                if surf.dashed then dashc = dashc + floor(L / dPer) + 2 end
            end
            if center and surf.paved then dashc = dashc + floor(L / cPer) + 2 end
        end
    end
    e.V, e.len = V, len
    F.base, F.casec = F.base + base, F.casec + casec
    F.dashc, F.solid = F.dashc + dashc, F.solid + solid
end

-- 本幀候選（模組層重用）：cand[i]＝條目、candK[i]＝容差≈1 px 的層
local cand, candK = {}, {}
local function pickLevel(e, tol)
    local lv = e.levels
    local k = 1
    while k < #lv and lv[k + 1].tol <= tol do k = k + 1 end
    return k
end

local function projectAll(F, nc, bump)
    F.base, F.casec, F.dashc, F.solid = 0, 0, 0, 0
    local maxed = true
    for i = 1, nc do
        local e = cand[i]
        local k, top = candK[i] + bump, #e.levels
        if k >= top then k = top else maxed = false end
        RD.project(e, k, F)
    end
    return maxed
end

-- 預算：先全畫；超過拿掉中線與虛線（F.dash）；再超過拿掉描邊（F.case）；仍超過就整批換粗一層。
-- 換層前用各條目前「入鏡段數÷層段數」的比例估下一層，跳到估計放得下的層再實算（通常只多算一次）
function RD.plan(F, nc)
    local tol = 1 / F.s
    for i = 1, nc do candK[i] = pickLevel(cand[i], tol) end
    local B = RD.BUDGET
    local maxed = projectAll(F, nc, 0)
    F.dash, F.case = true, true
    if F.base + F.casec + F.dashc <= B then return end
    F.dash = false
    if F.base + F.casec + F.solid <= B then return end
    F.case = false
    local bump = 0
    while F.base > B and not maxed do
        local step = 0
        repeat
            step = step + 1
            local est, all = 0, true
            for i = 1, nc do
                local e = cand[i]
                local lv, top = e.levels, #e.levels
                local k = candK[i] + bump + step
                if k >= top then k = top else all = false end
                local cur = #lv[e.k] - 1
                est = est + (e.V > 0 and math.ceil(e.V * (#lv[k] - 1) / (cur > 0 and cur or 1)) or 0)
            end
        until est <= B or all
        bump = bump + step
        maxed = projectAll(F, nc, bump)
    end
end

-- 繪製呼叫：jo＝地圖元件的 javaObject（直呼省掉 ISUIElement 包裝），nil＝走元件方法（設定預覽）
local function poly(el, jo, x1, y1, x2, y2, x3, y3, x4, y4, c, a)
    if jo then
        jo:DrawPolygon(nil, x1, y1, x2, y2, x3, y3, x4, y4, c.r, c.g, c.b, a)
    else
        el:drawPolygon(nil, x1, y1, x2, y2, x3, y3, x4, y4, c.r, c.g, c.b, a)
    end
end
-- 一段線畫成垂直於線、寬 w px 的四邊形。不用引擎 DrawLine：它把四角往 (±t, ∓t) 斜推
-- （GenericSpriteRenderState.renderline），實際寬約 2～2.8×t、兩端斜出去、座標還取整——
-- 實機 C 的泥土虛線比描邊寬、圖例的邊線變成斜紋（E2E road-style-sp 2026-10-23）
local function line(el, jo, x1, y1, x2, y2, w, c, a)
    local dx, dy = x2 - x1, y2 - y1
    local L = sqrt(dx * dx + dy * dy)
    if L < 1e-6 then return end
    local ox, oy = -dy / L * w / 2, dx / L * w / 2
    poly(el, jo, x1 + ox, y1 + oy, x2 + ox, y2 + oy, x2 - ox, y2 - oy, x1 - ox, y1 - oy, c, a)
end
-- 一段虛線；phase＝上一段留下的週期位置（轉角接得上），回傳新的 phase
local function dash(el, jo, x1, y1, x2, y2, L, w, c, a, on, gap, phase)
    if L < 0.5 then return phase end
    local ux, uy = (x2 - x1) / L, (y2 - y1) / L
    local period = on + gap
    local t = 0
    while t < L do
        local p = (phase + t) % period
        if p < on then
            local e = t + on - p
            if e > L then e = L end
            line(el, jo, x1 + ux * t, y1 + uy * t, x1 + ux * e, y1 + uy * e, w, c, a)
            t = e
        else
            t = t + period - p
        end
    end
    return (phase + L) % period
end

-- 轉角：兩段法線 n1、n2（半寬 d1、d2）的偏移線交點；平行時取平均，超過 MITER×較寬半寬就縮回
function RD.miter(n1x, n1y, d1, n2x, n2y, d2)
    local det = n1x * n2y - n1y * n2x
    local ox, oy
    if det > -1e-3 and det < 1e-3 then
        if n1x * n2x + n1y * n2y > 0 then
            ox, oy = (n1x * d1 + n2x * d2) / 2, (n1y * d1 + n2y * d2) / 2
        else
            ox, oy = n2x * d2, n2y * d2
        end
    else
        ox, oy = (d1 * n2y - d2 * n1y) / det, (n1x * d2 - n2x * d1) / det
    end
    local lim = RD.MITER * (d1 > d2 and d1 or d2)
    local l2 = ox * ox + oy * oy
    if l2 > lim * lim then
        local f = lim / sqrt(l2)
        ox, oy = ox * f, oy * f
    end
    return ox, oy
end

-- 路帶兩側的點（半寬＋extra px）寫進 LX/LY（左）、RX/RY（右）
local LX, LY, RX, RY = {}, {}, {}, {}
local function sides(e, extra)
    local px, py, hd, nxs, nys, n = e.px, e.py, e.hd, e.nx, e.ny, e.n
    local d = hd[1] + extra
    LX[1], LY[1] = px[1] + nxs[1] * d, py[1] + nys[1] * d
    RX[1], RY[1] = px[1] - nxs[1] * d, py[1] - nys[1] * d
    for k = 2, n - 1 do
        local ox, oy = RD.miter(nxs[k - 1], nys[k - 1], hd[k - 1] + extra, nxs[k], nys[k], hd[k] + extra)
        LX[k], LY[k], RX[k], RY[k] = px[k] + ox, py[k] + oy, px[k] - ox, py[k] - oy
    end
    d = hd[n - 1] + extra
    LX[n], LY[n] = px[n] + nxs[n - 1] * d, py[n] + nys[n - 1] * d
    RX[n], RY[n] = px[n] - nxs[n - 1] * d, py[n] - nys[n - 1] * d
end

-- 一條的四邊形帶：key＝"fill"／"case"／"line"（每段依路面取色），fixed＝整條同色（藍色描邊）
local function band(el, jo, e, extra, key, fixed, a)
    sides(e, extra)
    local sf, vis = e.sf, e.vis
    for k = 1, e.n - 1 do
        if vis[k] then
            poly(el, jo, LX[k], LY[k], LX[k + 1], LY[k + 1], RX[k + 1], RY[k + 1], RX[k], RY[k],
                fixed or sf[k][key], a)
        end
    end
end

-- 兩側邊線（已由 band／sides 算好 LX..RY）：dashed＝虛線
local function edgeLines(el, jo, e, w, c, a, dashed)
    local vis = e.vis
    local pl, pr = 0, 0
    for k = 1, e.n - 1 do
        if dashed then
            local dlx, dly, drx, dry = LX[k + 1] - LX[k], LY[k + 1] - LY[k], RX[k + 1] - RX[k], RY[k + 1] - RY[k]
            local ll, lr = sqrt(dlx * dlx + dly * dly), sqrt(drx * drx + dry * dry)
            if vis[k] then
                pl = dash(el, jo, LX[k], LY[k], LX[k + 1], LY[k + 1], ll, w, c, a, RD.OFF_ON, RD.OFF_GAP, pl)
                pr = dash(el, jo, RX[k], RY[k], RX[k + 1], RY[k + 1], lr, w, c, a, RD.OFF_ON, RD.OFF_GAP, pr)
            else
                pl, pr = (pl + ll) % (RD.OFF_ON + RD.OFF_GAP), (pr + lr) % (RD.OFF_ON + RD.OFF_GAP)
            end
        elseif vis[k] then
            line(el, jo, LX[k], LY[k], LX[k + 1], LY[k + 1], w, c, a)
            line(el, jo, RX[k], RY[k], RX[k + 1], RY[k + 1], w, c, a)
        end
    end
end

-- 中心線虛線：wantPaved＝柏油中線（只畫柏油段），否則 C 的泥土內線（只畫 dashed 段）；c＝nil 取該段內線色
local function centerDash(el, jo, e, w, c, a, on, gap, wantPaved)
    local px, py, vis, ls, sf = e.px, e.py, e.vis, e.ls, e.sf
    local phase = 0
    for k = 1, e.n - 1 do
        local hit = wantPaved and sf[k].paved or (not wantPaved and sf[k].dashed)
        if vis[k] and hit then
            phase = dash(el, jo, px[k], py[k], px[k + 1], py[k + 1], ls[k], w, c or sf[k].line, a, on, gap, phase)
        else
            phase = (phase + ls[k]) % (on + gap)
        end
    end
end

-- C 的內線：非泥土段畫四邊形，泥土段在 F.dash 時改畫粗虛線
local function cInner(el, jo, e, a, dashOn)
    sides(e, 0)
    local sf, vis = e.sf, e.vis
    for k = 1, e.n - 1 do
        if vis[k] and not (dashOn and sf[k].dashed) then
            poly(el, jo, LX[k], LY[k], LX[k + 1], LY[k + 1], RX[k + 1], RY[k + 1], RX[k], RY[k], sf[k].line, a)
        end
    end
    if dashOn then centerDash(el, jo, e, RD.C_LINE, nil, a, RD.C_ON, RD.C_GAP, false) end
end

-- 標籤：底下墊半透明黑底（地形淺色時也看得清）；x、y＝字的左上角
function RD.drawLabel(el, text, tw, x, y, a, tz, F)
    local th = getTextManager():getFontHeight(UIFont.Small) * tz
    if x > F.x1 or y > F.y1 or x + tw < F.x0 or y + th < F.y0 then return end
    el:drawRect(x - 3, y - 1, tw + 6, th + 2, 0.75, 0.07, 0.07, 0.07)
    Core.drawMapText(el, text, x, y, 0.953, 0.918, 0.816, a, UIFont.Small, tz)
end

-- 地圖標籤的左上角：路在畫面上一半長度的那一點；較平的路寫在路的上方置中，較陡的寫在右側，
-- 都離開路面（半寬＋描邊）
function RD.labelPos(e, tw, th)
    local px, py, ls = e.px, e.py, e.ls
    local rest, q = e.len / 2, 1
    while q < e.n - 1 and rest > ls[q] do
        rest, q = rest - ls[q], q + 1
    end
    local L = ls[q]
    local dx, dy = px[q + 1] - px[q], py[q + 1] - py[q]
    local t = L > 1e-6 and math.min(rest / L, 1) or 0
    local mx, my = px[q] + dx * t, py[q] + dy * t
    local ux, uy = 1, 0
    if L > 1e-6 then ux, uy = math.abs(dx / L), math.abs(dy / L) end
    local d = e.hd[q] + 3
    if uy <= ux then return mx - tw / 2, my - d / ux - th - 2 end
    return mx + d / uy + 4, my - th / 2
end
-- 這一批已寫的標籤底框（x1,y1,x2,y2 連續放；drawSet 每次從頭覆寫，模組層重用）
local labelBox = {}

-- 畫 cand[1..nc]（已 plan）：停用的先畫、啟用的蓋上去；每組依序 描邊 → 路面 → 中線／邊線，
-- 路口處別條的描邊不會蓋到這條的路面。labels＝寫名稱（F.names 另外管）
function RD.drawSet(el, jo, F, nc, labels)
    local style, A, s = F.style, F.alpha, F.s
    local center = F.dash and s >= RD.CENTER_MIN_SCALE
    for group = 1, 2 do
        local wantOff = group == 1
        if F.case and style ~= 2 then
            for i = 1, nc do
                local e = cand[i]
                if e.off == wantOff and e.V > 0 then
                    if style == 1 and not e.off then
                        band(el, jo, e, e.recv and RD.A_CASE_RECV or RD.A_CASE, "case", e.recv and RD.BLUE or nil, A)
                    elseif style == 3 then
                        band(el, jo, e, (RD.C_CASE - RD.C_LINE) / 2, "case", e.recv and RD.BLUE or nil,
                            A * (e.off and RD.C_OFF or 1))
                    end
                end
            end
        end
        for i = 1, nc do
            local e = cand[i]
            if e.off == wantOff and e.V > 0 then
                if style == 1 then
                    band(el, jo, e, 0, "fill", nil, A * (e.off and RD.A_OFF_FILL or 1))
                elseif style == 2 then
                    -- 預算拿掉邊線（F.case）時路廊只剩填色：改用 A 的濃度，否則 0.28 幾乎看不見路
                    -- （RoadsPerfE2E 世界地圖整片入鏡實測）
                    local f
                    if F.case then f = e.off and RD.B_OFF_FILL or RD.B_FILL else f = e.off and RD.A_OFF_FILL or 1 end
                    band(el, jo, e, 0, "fill", nil, A * f)
                else
                    cInner(el, jo, e, A * (e.off and RD.C_OFF or 1), F.dash)
                end
            end
        end
        if style ~= 3 then
            for i = 1, nc do
                local e = cand[i]
                if e.off == wantOff and e.V > 0 then
                    if e.off then
                        if F.dash or F.case then
                            sides(e, 0)
                            if style == 1 then
                                edgeLines(el, jo, e, RD.OFF_EDGE_W, RD.OFF_EDGE, A, F.dash)
                            else
                                edgeLines(el, jo, e, RD.B_EDGE_W, e.recv and RD.B_EDGE_RECV or RD.B_EDGE,
                                    A * RD.B_OFF_EDGE, F.dash)
                            end
                        end
                    else
                        if style == 2 and F.case then
                            sides(e, 0)
                            edgeLines(el, jo, e, RD.B_EDGE_W, e.recv and RD.B_EDGE_RECV or RD.B_EDGE, A, false)
                        end
                        if center then
                            centerDash(el, jo, e, RD.CENTER_W, RD.CENTER, A, RD.CENTER_ON, RD.CENTER_OFF, true)
                        end
                    end
                end
            end
        end
    end
    if not (labels and F.names) then return end
    local tz = Core.mapTextZoom and Core.mapTextZoom() or 1
    local th = getTextManager():getFontHeight(UIFont.Small) * tz
    -- 地圖標籤：跟這一批已寫的底框重疊就不寫（平行的路靠很近時字疊成一團）；啟用的路先寫，
    -- 不用於導航的最後。ponytail: 逐框比對 O(n²)，入鏡標籤上百時改格網分桶
    local nBox = 0
    for pass = 1, 2 do
        local wantOff = pass == 2
        for i = 1, nc do
            local e = cand[i]
            local tw = e.labelW * tz
            if e.label and e.V > 0 and e.off == wantOff then
                local a = e.off and 0.75 or 1
                if e.labelAt then
                    -- 預覽：標籤左上角固定（世界座標，投影同路），版面本來就不重疊
                    local dx, dy = e.labelAt[1] - F.acx, e.labelAt[2] - F.acy
                    RD.drawLabel(el, e.label, tw, F.p0x + dx * F.sxx + dy * F.syx, F.p0y + dx * F.sxy + dy * F.syy,
                        a, tz, F)
                elseif e.len >= tw + RD.LABEL_PAD then
                    local x, y = RD.labelPos(e, tw, th)
                    local x1, y1, x2, y2 = x - 3, y - 1, x + tw + 3, y + th + 1 -- 同 drawLabel 的底框
                    local free = true
                    for b = 1, nBox, 4 do
                        if x1 < labelBox[b + 2] and x2 > labelBox[b] and y1 < labelBox[b + 3] and y2 > labelBox[b + 1] then
                            free = false
                            break
                        end
                    end
                    if free then
                        labelBox[nBox + 1], labelBox[nBox + 2], labelBox[nBox + 3], labelBox[nBox + 4] = x1, y1, x2, y2
                        nBox = nBox + 4
                        RD.drawLabel(el, e.label, tw, x, y, a, tz, F)
                    end
                end
            end
        end
    end
end

-- 畫一批（地圖、預覽共用）：plan＋stencil 包住的 drawSet
local function render(el, jo, F, nc, labels, sx, sy, sw, sh)
    F.det = math.abs(F.sxx * F.syy - F.sxy * F.syx)
    RD.plan(F, nc)
    el:setStencilRect(sx, sy, sw, sh)
    local ok, err = pcall(RD.drawSet, el, jo, F, nc, labels)
    el:clearStencilRect()
    if not ok then error(err, 0) end
end

-- 主入口（_Nav.lua drawNavTargets）：inner＝小地圖 inner 或 ISWorldMap。分割畫面只畫該 pn 的路。
-- 道路工具作用中的這張世界地圖：圖層開關關著也畫（要看得到才吸附得準），正在編輯的那條交給工具畫
local F = {}
Core.drawCustomRoads = function(inner)
    local pn = inner.playerNum or 0
    local surface = inner == ISWorldMap_instance and "world" or "mini"
    local tool = surface == "world" and Core.roadToolOf and Core.roadToolOf(inner) or nil
    if not tool and not RD.layerOn(surface) then return end
    local c = RD.cacheFor(pn)
    if not c or c.n == 0 then return end
    RD.readOptions(F)
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local vx1, vx2, vy1, vy2 = Core.visibleWorldAABB(inner)
    local s = mapAPI:getWorldScale()
    if not (s and s > 0) then return end
    -- 外接框剔除的邊界：最寬路半寬 8 格＋描邊與最細寬度的 px 換成格
    local m = 8 + 8 / s
    vx1, vx2, vy1, vy2 = vx1 - m, vx2 + m, vy1 - m, vy2 + m
    local skip = tool and tool.roadId
    local nc = 0
    for i = 1, c.n do
        local e = c[i]
        if (F.recv or not e.recv) and (F.dis or not e.off) and not (skip and e.kind == "own" and e.id == skip)
            and not (e.maxx < vx1 or e.minx > vx2 or e.maxy < vy1 or e.miny > vy2) then
            nc = nc + 1
            cand[nc] = e
        end
    end
    if nc == 0 then return end
    local acx, acy = floor((vx1 + vx2) / 2), floor((vy1 + vy2) / 2)
    F.acx, F.acy = acx, acy
    F.p0x, F.p0y, F.sxx, F.sxy, F.syx, F.syy = Core.deriveAffine(mapAPI, acx, acy)
    F.s = s
    F.x0, F.y0, F.x1, F.y1 = 0, 0, w, h
    render(inner, inner.javaObject, F, nc, true, 0, 0, w, h)
end

-- 設定預覽（_Settings.lua 自訂道路分類）：元件矩形內固定比例（每格 PREVIEW_S px）畫範例道路，
-- 左欄柏油／碎石／泥土（標籤＝路面名），右欄別人分享的與不用於導航的各一條；標籤一律寫在路的下面
-- （窄到 280 px 也不跨欄）。畫法、透明度、最細寬度與三個開關都照目前設定。版面照高 136 px 排
-- （設定分類的兩倍高預覽）；條目依矩形大小建一次，大小不變就重用
local preview = { w = -1, h = -1 }
local PF = {}
function RD.buildPreview(w, h)
    local S = RD.PREVIEW_S
    local W, H = w / S, h / S
    local function road(x1, x2, y, width, surf, kind, on, label, labelAt)
        local e = RD.newEntry({ pts = { x1, y, x2, y }, segWidth = { width }, segSurface = { surf } },
            kind, on, nil, label)
        e.labelAt = labelAt
        return e
    end
    local gap = 3 / S -- 標籤與路緣的距離（3 px）
    local lx2, rx1 = W * 0.45, W * 0.53
    local list = {}
    local surfs = { { "paved", 6, 0.14 }, { "gravel", 5, 0.45 }, { "dirt", 4, 0.76 } }
    for i = 1, 3 do
        local y = H * surfs[i][3]
        list[i] = road(2, lx2, y, surfs[i][2], surfs[i][1], "own", true,
            getText("UI_MinidoracatMiniMap_RoadSurface_" .. surfs[i][1]), { 3, y + surfs[i][2] / 2 + gap })
    end
    local ry1, ry2 = H * 0.14, H * 0.55
    list[4] = road(rx1, W - 2, ry1, 5, "gravel", "received", true,
        getText("UI_MinidoracatMiniMap_RoadLegendReceived"), { rx1 + 1, ry1 + 2.5 + gap })
    list[5] = road(rx1, W - 2, ry2, 4, "dirt", "own", false,
        getText("UI_MinidoracatMiniMap_RoadLabelOff", getText("UI_MinidoracatMiniMap_RoadSurface_dirt")),
        { rx1 + 1, ry2 + 2 + gap })
    preview.w, preview.h, preview.list = w, h, list
end
Core.drawRoadsPreview = function(el, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    if preview.w ~= w or preview.h ~= h then RD.buildPreview(w, h) end
    RD.readOptions(PF)
    local S = RD.PREVIEW_S
    PF.acx, PF.acy, PF.p0x, PF.p0y = 0, 0, x, y
    PF.sxx, PF.sxy, PF.syx, PF.syy, PF.s = S, 0, 0, S, S
    PF.x0, PF.y0, PF.x1, PF.y1 = x, y, x + w, y + h
    local nc = 0
    for i = 1, #preview.list do
        local e = preview.list[i]
        if (PF.recv or not e.recv) and (PF.dis or not e.off) then
            nc = nc + 1
            cand[nc] = e
        end
    end
    if nc == 0 then return end
    render(el, nil, PF, nc, true, x, y, w, h)
end

-- 世界地圖圖例（_Legend.lua）：要列哪幾列。"road"＝有任何一條會畫，"received"／"off"＝開關開著
-- 且真的有那種路。回傳模組層重用表 { n=, [1..n]=列種類 } 或 nil
local legendRows = {}
Core.roadsLegend = function(pn)
    if not RD.layerOn("world") then return nil end
    local c = RD.cacheFor(pn)
    if not c or c.n == 0 then return nil end
    local recv = Core.getBoolOption("CustomRoadReceived", true) == true
    local dis = Core.getBoolOption("CustomRoadDisabled", true) == true
    local recvN = recv and (c.recvOn + (dis and c.recvOff or 0)) or 0
    local offN = dis and (c.ownOff + (recv and c.recvOff or 0)) or 0
    if c.ownOn + recvN + offN == 0 then return nil end
    local n = 1
    legendRows[1] = "road"
    if recvN > 0 then n = n + 1; legendRows[n] = "received" end
    if offN > 0 then n = n + 1; legendRows[n] = "off" end
    legendRows.n = n
    return legendRows
end

-- 圖例色塊（_Legend.lua）：在 (x,y,w,h) 畫一列的樣本，與地圖同一套畫法（單位方形仿射：路寬 0.6＝0.6h px）。
-- "road"：A、C 三種路面各一小段，B 一段路廊；"received"：分享的路；"off"：不用於導航的路。
-- 圖例底色是深色，不套地圖的透明度與最細寬度
local samples
local LF = { acx = 0, acy = 0, s = 1, alpha = 1, minPx = 0, names = false, recv = true, dis = true }
function RD.drawLegendSample(el, x, y, w, h, which)
    if not samples then
        local function road(x1, x2, surf, kind, on)
            return RD.newEntry({ pts = { x1, 0.5, x2, 0.5 }, segWidth = { 0.6 }, segSurface = { surf } },
                kind, on, nil, false)
        end
        samples = {
            three = { road(0, 0.3, "paved", "own", true), road(0.35, 0.65, "gravel", "own", true),
                road(0.7, 1, "dirt", "own", true) },
            one = { road(0, 1, "paved", "own", true) },
            received = { road(0, 1, "gravel", "received", true) },
            off = { road(0, 1, "dirt", "own", false) },
        }
    end
    LF.style = Core.getComboIndex("CustomRoadStyle", 1)
    if LF.style ~= 2 and LF.style ~= 3 then LF.style = 1 end
    local list = samples[which] or (LF.style == 2 and samples.one or samples.three)
    LF.p0x, LF.p0y, LF.sxx, LF.sxy, LF.syx, LF.syy = x, y, w, 0, 0, h
    LF.x0, LF.y0, LF.x1, LF.y1 = x, y, x + w, y + h
    for i = 1, #list do cand[i] = list[i] end
    LF.det = w * h
    RD.plan(LF, #list)
    RD.drawSet(el, nil, LF, #list, false)
end

-- 道路工具正在編輯的那條（_RoadTool.lua drawOverlay）：黑底＋淺色虛線，逐點 worldToUI、Core.clipSegment 裁切。
-- view＝{minx,maxx,miny,maxy}（nil＝不剔除）；segBudget＝最多畫幾段。回傳用掉的段數
local dashBudget = 0
local function dashLine(inner, x1, y1, x2, y2, st, on, off, phase)
    local dx, dy = x2 - x1, y2 - y1
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.5 then return phase end
    if dashBudget <= 0 then
        inner:drawLine(nil, x1, y1, x2, y2, st.w, st.a, st.r, st.g, st.b)
        return phase
    end
    local ux, uy = dx / len, dy / len
    local period = on + off
    local t = 0
    while t < len do
        local p = (phase + t) % period
        if p < on then
            local e = t + on - p
            if e > len then e = len end
            inner:drawLine(nil, x1 + ux * t, y1 + uy * t, x1 + ux * e, y1 + uy * e, st.w, st.a, st.r, st.g, st.b)
            dashBudget = dashBudget - 1
            t = e
        else
            t = t + period - p
        end
    end
    return (phase + len) % period
end
local projX, projY = {}, {}
function RD.drawPolyline(inner, pts, np, under, over, on, off, view, segBudget)
    local mapAPI = inner.mapAPI
    local clip = Core.clipSegment
    local w, h = inner.width, inner.height
    local used = 0
    dashBudget = RD.MAX_DASH
    for k = 1, np do projX[k] = nil end
    for k = 2, np do
        local ax, ay, bx, by = pts[k * 2 - 3], pts[k * 2 - 2], pts[k * 2 - 1], pts[k * 2]
        local live = true
        if view then
            local sminx, smaxx = ax, bx
            if sminx > smaxx then sminx, smaxx = smaxx, sminx end
            local sminy, smaxy = ay, by
            if sminy > smaxy then sminy, smaxy = smaxy, sminy end
            live = not (smaxx < view[1] or sminx > view[2] or smaxy < view[3] or sminy > view[4])
        end
        if live and used < segBudget then
            if not projX[k - 1] then
                projX[k - 1], projY[k - 1] = mapAPI:worldToUIX(ax, ay), mapAPI:worldToUIY(ax, ay)
            end
            projX[k], projY[k] = mapAPI:worldToUIX(bx, by), mapAPI:worldToUIY(bx, by)
            used = used + 1
        end
    end
    for pass = 1, 2 do
        local phase = 0
        for k = 2, np do
            local ux1, ux2 = projX[k - 1], projX[k]
            if ux1 and ux2 then
                local x1, y1, x2, y2 = ux1, projY[k - 1], ux2, projY[k]
                if clip then x1, y1, x2, y2 = clip(x1, y1, x2, y2, w, h) end
                if x1 then
                    if pass == 1 then
                        inner:drawLine(nil, x1, y1, x2, y2, under.w, under.a, under.r, under.g, under.b)
                    else
                        phase = dashLine(inner, x1, y1, x2, y2, over, on, off, phase)
                    end
                end
            end
        end
    end
    return used
end

-- 地圖右鍵命中（_Nav.lua mapMenuFill）：這張地圖不畫自訂道路就不判定（同收藏 placeAt）。
-- 命中半徑是畫面 HIT_PX 換成世界格；資料端 Core.roadsAt 決定是哪一條
Core.roadMapHit = function(target, wx, wy)
    if not Core.roadsAt then return nil end
    local surface = target == ISWorldMap_instance and "world" or "mini"
    if not RD.layerOn(surface) then return nil end
    local mapAPI = target.mapAPI
    local ax, ay = mapAPI:worldToUIX(wx, wy), mapAPI:worldToUIY(wx, wy)
    local bx, by = mapAPI:worldToUIX(wx + 8, wy), mapAPI:worldToUIY(wx + 8, wy)
    local ppu = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) / 8
    if ppu <= 0 then return nil end
    local ok, hit = pcall(Core.roadsAt, target.playerNum or 0, wx, wy, RD.HIT_PX / ppu)
    if not ok then
        log("road hit test failed: " .. tostring(hit))
        return nil
    end
    return hit
end

Events.OnGameStart.Add(function()
    for k in pairs(caches) do caches[k] = nil end
end)
