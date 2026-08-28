-- 導航路線核心（NavCore：cell gate／交點切割／端點吸附／A*）離線回歸測試。
-- 仿 test_layer_tail.lua：抽 _NavRoute.lua 的 navroute-core 標記區段離線跑
-- （區段純標準 Lua、零 stub；winnerOf 由測試注入）。
-- 用法：lua scripts/test_nav_route.lua
local srcPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"

local file = assert(io.open(srcPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local body = assert(source:match("%-%- test:navroute%-core:start\n(.-)\n%-%- test:navroute%-core:end"),
    "找不到 navroute-core 測試區段")

local compile = loadstring or load
local mod = assert(compile(body .. "\nreturn NavCore\n", "navroute-core"))()

-- 建圖 helper：小 budget 分幀推進（驗證狀態機可中斷續跑）＋迴圈上限保險
local function buildAll(streets, winnerOf, budget)
    local b = mod.newBuild(streets, winnerOf)
    for _ = 1, 100000 do
        if mod.step(b, budget or 500) then return b.graph end
    end
    error("build 未在迴圈上限內完成")
end

local function route(g, sx, sy, tx, ty)
    return mod.findRoute(g, sx, sy, tx, ty)
end

--------------------------------------------------------------------------------
-- 一、幾何原語
--------------------------------------------------------------------------------
do
    local d2, t = mod.projPointSeg(50, 10, 0, 0, 100, 0)
    assert(math.abs(d2 - 100) < 1e-9 and math.abs(t - 0.5) < 1e-9, "投影：中點垂距")
    d2, t = mod.projPointSeg(-10, 0, 0, 0, 100, 0)
    assert(t == 0 and math.abs(d2 - 100) < 1e-9, "投影：clamp 到起端")
    local ct, cu = mod.segCross(0, 0, 100, 0, 50, -50, 50, 50)
    assert(ct and math.abs(ct - 0.5) < 1e-9 and math.abs(cu - 0.5) < 1e-9, "交點：十字正中")
    assert(mod.segCross(0, 0, 100, 0, 0, 10, 100, 10) == nil, "交點：平行不交")
    -- 端點觸碰回 clamp 後切點（t≈0/1 子段由 stepCut 的 CUT_MERGE 門檻併回端點）
    ct, cu = mod.segCross(0, 0, 100, 0, 100, 0, 100, 100)
    assert(ct == 1 and cu == 0, "交點：端點觸碰回 clamp 切點")
    local buf = {}
    local n = mod.cellBoundaryTs(200, 10, 600, 10, buf)
    assert(n == 4 and buf[1] == 0 and buf[n] == 1, "cell 切點：跨 256/512 兩界＋首尾")
end

--------------------------------------------------------------------------------
-- 二、十字連通（vanilla 市區主流畫法：兩街中段互穿；X 不連＝市區癱瘓）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "H", src = "M", pts = { 0, 100, 200, 100 } },
        { name = "V", src = "M", pts = { 100, 0, 100, 200 } },
    }, nil, 37) -- 質數小 budget：驗證跨階段中斷續跑
    local r = route(g, 10, 100, 100, 190)
    assert(r, "十字：可尋路")
    assert(r.len > 165 and r.len < 195, "十字：長度 ≈180，實得 " .. tostring(r.len))
end

--------------------------------------------------------------------------------
-- 三、T 字端點吸附（codex review 指定案例：支路端點距主線 1.0 格——投影切點與
-- 支路端點超出 0.5 格量化，必須靠 epMove 吸附才連通）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "Main", src = "M", pts = { 0, 100, 200, 100 } },
        { name = "Branch", src = "M", pts = { 50, 101, 50, 180 } },
    }, nil)
    local r = route(g, 10, 100, 50, 170)
    assert(r, "T 字：端點離主線 1 格仍連通")
    assert(r.len > 100 and r.len < 122, "T 字：長度 ≈110，實得 " .. tostring(r.len))
end

--------------------------------------------------------------------------------
-- 四、跨街近端點互吸合流（0.36 格斷口跨量化格；互吸交換不收斂的回歸守護——
-- 合流必須單向往小 key 根）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "A", src = "M", pts = { 0, 0, 50, 0 } },
        { name = "B", src = "M", pts = { 50.3, 0.2, 100, 0 } },
    }, nil)
    local r = route(g, 10, 0, 90, 0)
    assert(r, "端點合流：0.36 格斷口連通")
    assert(r.len > 75 and r.len < 85, "端點合流：長度 ≈80，實得 " .. tostring(r.len))
end

--------------------------------------------------------------------------------
-- 五、長段近端 T 字（比例邊距盲區回歸：500 格幹道、支路投影距幹道端點 5 格
-- ——舊比例判定 2%＝10 格會誤入端點分支漏切）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "Hwy", src = "M", pts = { 0, 0, 500, 0 } },
        { name = "Spur", src = "M", pts = { 5, 1, 5, 80 } },
    }, nil)
    local r = route(g, 490, 0, 5, 70)
    assert(r, "長段近端 T：連通")
    assert(r.len > 545 and r.len < 565, "長段近端 T：長度 ≈555，實得 " .. tostring(r.len))
end

--------------------------------------------------------------------------------
-- 六、cell gate：勝出過濾裁段／勝者保留／fail-open（多來源 fixture——
-- claude review：抽取遍歷所有來源、gate 按 cell 勝出裁）
--------------------------------------------------------------------------------
do
    local streets = {
        { name = "Long", src = "A", pts = { 0, 10, 600, 10 } },    -- 跨 cell 0/1/2
        { name = "BOnly", src = "B", pts = { 260, 20, 500, 20 } }, -- cell 1 內
    }
    local winner = function(cx, cy)
        if cx == 1 and cy == 0 then return "B" end
        return "A"
    end
    local g = buildAll(streets, winner)
    assert(route(g, 10, 10, 590, 10) == nil, "gate：敗者中段被裁＝斷連")
    local rb = route(g, 270, 20, 490, 20)
    assert(rb and rb.len > 200 and rb.len < 240, "gate：勝者段保留可尋路")
    local g2 = buildAll(streets, nil)
    local r2 = route(g2, 10, 10, 590, 10)
    assert(r2 and r2.len > 570 and r2.len < 600, "gate：fail-open 全段保留")
    -- 未知來源（src=nil，byIndex 兜底收入的翻譯 MOD 全量容器）：winnerOf 有效
    -- 時必須 fail-open 不裁——漏此分支＝LangFor42 環境整份路網被裁光（回歸）
    local g3 = buildAll({
        { name = "ZhAll", src = nil, pts = { 0, 10, 600, 10 } },
    }, winner)
    local r3 = route(g3, 10, 10, 590, 10)
    assert(r3 and r3.len > 570 and r3.len < 600, "gate：src=nil fail-open 不裁")
    -- SP carrier dir 回歸（codex review）：LangFor42 的 'Riverside, KY' 在 SP
    -- 會進 lot dirs、byRel 命中成 src——但該 dir 無 lotheader＝無裁決立場，
    -- winnerOf 三參契約（src 該 cell 無 lot → 回 nil fail-open）必須傳遞 src
    local seenSrc = nil
    local carrierWinner = function(cx, cy, src)
        seenSrc = src
        if src == "Riverside, KY" then return nil end -- 模擬 carrier：無 lotheader
        return "Muldraugh, KY"
    end
    local g4 = buildAll({
        { name = "ZhAll2", src = "Riverside, KY", pts = { 0, 10, 600, 10 } },
    }, carrierWinner)
    assert(seenSrc == "Riverside, KY", "gate：winnerOf 收到第三參 src")
    local r4 = route(g4, 10, 10, 590, 10)
    assert(r4 and r4.len > 570 and r4.len < 600, "gate：carrier src fail-open 不裁")
end
--------------------------------------------------------------------------------
-- 七、斷連兩島 → nil（snap 各自命中但 A* 無路；不可錯給直線假路徑）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "I1", src = "M", pts = { 0, 0, 50, 0 } },
        { name = "I2", src = "M", pts = { 1000, 0, 1050, 0 } },
    }, nil)
    assert(route(g, 10, 0, 1040, 0) == nil, "兩島：不可達回 nil")
end

--------------------------------------------------------------------------------
-- 八、distToRoute 增量投影（偏航檢測的量測面）
--------------------------------------------------------------------------------
do
    local g = buildAll({ { name = "S", src = "M", pts = { 0, 0, 100, 0 } } }, nil)
    local r = route(g, 0, 0, 100, 0)
    assert(r, "直線：可尋路")
    local d = mod.distToRoute(r, 50, 10, 1)
    assert(math.abs(d - 10) < 0.6, "distToRoute：偏距 10，實得 " .. tostring(d))
    local d2v = mod.distToRoute(r, 30, 0.2, 1)
    assert(d2v < 0.6, "distToRoute：路上點 ≈0")
end

--------------------------------------------------------------------------------
-- 九、複合吸附×交點座標一致（codex 執行反例回歸：支路穿越主線且端點在主線
-- 附近被吸附——切點若在移動後幾何上重插 t，同一交點會分裂成兩節點）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "Main", src = "M", pts = { 0, 10, 100, 10 } },
        { name = "Cross", src = "M", pts = { 50, 9.3, 50, 80 } }, -- 端點距主線 0.7、穿越主線
    }, nil)
    local r = route(g, 5, 10, 50, 70)
    assert(r, "複合吸附：交點不分裂、可尋路")
    assert(r.len > 100 and r.len < 115, "複合吸附：長度 ≈105，實得 " .. tostring(r.len))
end

--------------------------------------------------------------------------------
-- 十、跨桶 T 字（codex 反例回歸：主線 y=-1、支路端點 y=0 分居 64 格桶界，
-- 配對 bucket 未外擴 T_TOL 時永不相遇）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "Main", src = "M", pts = { 0, -1, 200, -1 } },
        { name = "Spur", src = "M", pts = { 80, 0, 80, 60 } },
    }, nil)
    local r = route(g, 10, -1, 80, 50)
    assert(r, "跨桶 T 字：bucket 外擴後連通")
end

--------------------------------------------------------------------------------
-- 十一、budget 硬上限（codex 反例回歸：單一密集桶不可原子跑完——step(b,1)
-- 必須在 pairs 階段留下桶內游標中斷點）
--------------------------------------------------------------------------------
do
    local streets = {}
    for i = 1, 14 do -- 14 條街同桶交錯：C(14,2)=91 對
        if i % 2 == 1 then
            streets[#streets + 1] = { name = "H" .. i, src = "M", pts = { 0, i * 4, 60, i * 4 } }
        else
            streets[#streets + 1] = { name = "V" .. i, src = "M", pts = { i * 4, 0, i * 4, 60 } }
        end
    end
    local b = mod.newBuild(streets, nil)
    local sawPairCursor = false
    for _ = 1, 200000 do
        if mod.step(b, 1) then break end
        if b.phase == "pairs" and b.pii then sawPairCursor = true end
    end
    assert(b.phase == "done", "budget=1：最終完成")
    assert(sawPairCursor, "budget=1：pairs 桶內游標曾中斷（硬上限生效）")
    local r = route(b.graph, 2, 4, 56, 4)
    assert(r, "budget=1：分幀建圖結果可尋路")
end

--------------------------------------------------------------------------------
-- 十二、同 graph 連續兩次 findRoute 一致（A* 臨時注入回滾回歸：reached 路徑
-- 的回滾＋generation stamp 重用是最易寫錯處）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "H", src = "M", pts = { 0, 100, 200, 100 } },
        { name = "V", src = "M", pts = { 100, 0, 100, 200 } },
    }, nil)
    local r1 = route(g, 10, 100, 100, 190)
    local r2 = route(g, 10, 100, 100, 190)
    assert(r1 and r2, "連續尋路：兩次都成功")
    assert(math.abs(r1.len - r2.len) < 1e-6, "連續尋路：結果一致（回滾乾淨）")
    local r3 = route(g, 100, 10, 190, 100) -- 不同起終再驗一次
    assert(r3 and r3.len > 165 and r3.len < 195, "連續尋路：異參第三次正常")
end

--------------------------------------------------------------------------------
-- 十三、終點次近候選（codex review：最近段是孤島、次近段可達不可回 nil）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "Main", src = "M", pts = { 0, 0, 300, 0 } },
        { name = "Island", src = "M", pts = { 100, 30, 140, 30 } }, -- 孤島（不連 Main）
    }, nil)
    -- 目標 (120,25)：距孤島 5、距 Main 25——最近孤島、次近主網
    local r = route(g, 10, 0, 120, 25)
    assert(r, "終點候選：孤島最近時仍取可達次近段")
    -- 起點在 Main 上，孤島與 Main 斷連：可達路線終錨必在 Main（y=0）
    assert(math.abs(r.ey - 0) < 1.0, "終點候選：終錨落在可達主網")
end

--------------------------------------------------------------------------------
-- 十四、Railroad 謂詞（英文 token／幾何簽名／真街道不誤殺）
--------------------------------------------------------------------------------
do
    assert(mod.isRailroadStreet("Northern Railroad (Muldraugh - Doe Valley)", 0, 0),
        "railroad：英文 token 命中")
    assert(mod.isRailroadStreet("南方鐵路（馬爾卓）", 12664.5, 4476.5),
        "railroad：譯名下幾何簽名命中（vanilla 首點）")
    assert(not mod.isRailroadStreet("Railway St", 500, 500), "railroad：Railway St 不誤殺")
    assert(not mod.isRailroadStreet("鐵路街", 500, 500), "railroad：中文真街道不誤殺")
end

--------------------------------------------------------------------------------
-- 十五、負座標世界（bucket/quant key 偏移回歸：地圖包負世界座標合法）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "H", src = "M", pts = { -500, -300, -100, -300 } },
        { name = "V", src = "M", pts = { -300, -500, -300, -100 } },
    }, nil)
    local r = route(g, -480, -300, -300, -120)
    assert(r, "負座標：十字連通")
    assert(r.len > 330 and r.len < 390, "負座標：長度合理，實得 " .. tostring(r.len))
end
--------------------------------------------------------------------------------
-- 十六、路寬容差（MP 實測根因回歸，codex 定位）：streets.xml 是道路中心線，
-- 寬路支路端點停在路緣——白鴿街(w8)端點 (12936,3528) 距麻雀街(w6)中心線
-- y=3531 有 3 格，固定 1.5 容差接不上（整個住宅區懸空 noroad）；容差改
-- 兩路半寬和（4+3+0.5=7.5）後必須連通。fixture 帶 width＝守住抽取→builder
-- 的 width 傳遞鏈（width 欄位缺失時整套退化成固定 5.5 的死碼）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "Sparrow St", src = "M", width = 6, pts = { 12800, 3531, 13000, 3531 } },
        { name = "Dove St", src = "M", width = 8, pts = { 12936, 3528, 12936, 3400 } },
    }, nil)
    local r = route(g, 12820, 3531, 12936, 3420)
    assert(r, "路寬容差：w8 支路端點距 w6 幹道 3 格仍連通")
    assert(r.len > 215 and r.len < 240, "路寬容差：長度 ≈227，實得 " .. tostring(r.len))
    -- 對照：無 width（預設半寬 2.5+2.5+0.5=5.5）在 3 格斷口也該連——驗證
    -- 預設值不比舊 1.5 更嚴
    local g2 = buildAll({
        { name = "A", src = "M", pts = { 0, 0, 200, 0 } },
        { name = "B", src = "M", pts = { 100, 4, 100, 80 } }, -- 端點距中心線 4 格
    }, nil)
    assert(route(g2, 10, 0, 100, 70), "路寬容差：預設半寬涵蓋 4 格斷口")
end

--------------------------------------------------------------------------------
-- 十七、雙線公路互通（MP 實測繞遠根因之二回歸）：vanilla 分隔帶公路畫成兩條
-- 平行 polyline（實測中央帶 10 格），支路端點只畫到近側線——路口間隙容差
-- （ATTACH_SLACK=4.5）必須讓「南線、北線、支路」三方在路口互通，否則 A* 沿
-- 南線繞到遠端迴轉頭折返（離線 repro ratio 8.94 → 修後 1.15）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "HwyS", src = "M", width = 6, pts = { 12200, 3455, 12960, 3455 } },
        { name = "HwyN", src = "M", width = 6, pts = { 12200, 3445, 12960, 3445 } },
        { name = "Feeder", src = "M", width = 6, pts = { 12932, 3531, 12932, 3455 } }, -- 停南線
        { name = "Artery", src = "M", width = 8, pts = { 12936, 3442, 12936, 3000 } }, -- 幹道接北線端
    }, nil)
    local r = route(g, 12932, 3520, 12936, 3050)
    assert(r, "雙線公路：支路→南線→北線→幹道連通")
    local straight = math.sqrt((12936 - 12932) ^ 2 + (3050 - 3520) ^ 2)
    assert(r.len < straight * 1.3, "雙線公路：不繞行（len=" .. tostring(r.len) .. "）")
end

--------------------------------------------------------------------------------
-- 十八、深野外 nearestSnap fallback（2026-08-20 軍事基地實測回歸）：目標離
-- 路網超過 SNAP_RING 上限 160 格→ring 全空，須改導到「路網最近點」而非整條
-- noroad（實案：Muldraugh(12895,3498)→基地(5783,12484) 終點離最近路 >160）。
-- 起點側同理；graph 空仍回 nil（繪製端另有直線 fallback）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "Lone Rd", src = "M", width = 6, pts = { 0, 0, 400, 0 } },
    }, nil)
    -- 終點在路網外 500 格（>160 上限）
    local r = route(g, 10, 0, 200, 500)
    assert(r, "深野外終點：nearestSnap 須回路線")
    assert(math.abs(r.ex - 200) < 1 and math.abs(r.ey) < 1,
        "深野外終點：路線終錨＝路網最近投影點 (200,0)，實得 ("
        .. tostring(r.ex) .. "," .. tostring(r.ey) .. ")")
    -- 起點也在路網外：雙向 fallback
    local r2 = route(g, 200, -300, 380, 900)
    assert(r2, "深野外起訖：雙向 nearestSnap 須回路線")
    -- graph 空＝真 noroad 仍 nil
    local g0 = buildAll({}, nil)
    assert(route(g0, 0, 0, 10, 10) == nil, "空 graph 仍回 nil（繪製端直線 fallback 接手）")
end

--------------------------------------------------------------------------------
-- 十九、雙線公路 Z 字＝已知行為（斷口橋接已撤回 2026-08-20——「端點對齊＋
-- 距離」合成路會把排屋後巷/圍籬/河岸誤接成可走，導錯路實害 > Z 字視覺瑕疵。
-- 本案例鎖「不橋接」的真實拓撲：縱街被雙線帶切開時，路線借遠處貫穿點過帶
-- ＝合法繞行；嚴謹橋接需驗證「兩端切線同軸＋縫隙內確有橫穿道路」才可重做）
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "N Street", src = "M", width = 6, pts = { 12513, 3000, 12513, 3442 } },
        { name = "HwyN", src = "M", width = 6, pts = { 12224, 3445, 12932, 3445 } },
        { name = "HwyS", src = "M", width = 6, pts = { 12224, 3455, 12932, 3455 } },
        { name = "S Street", src = "M", width = 6, pts = { 12513, 3458, 12513, 3899 } },
        -- 遠處貫穿點（過帶唯一通道；縱街端點距公路 3 格由 attach 半寬和接上）
        { name = "Cross", src = "M", width = 6, pts = { 12900, 3400, 12900, 3500 } },
    }, nil)
    local r = route(g, 12513, 3050, 12513, 3850)
    assert(r, "雙線帶：縱街經貫穿點連通（attach 接上兩線）")
    -- 不橋接＝允許繞行（借 12900 貫穿點）；上限鎖「有連通」而非「直穿」
    assert(r.len > (3850 - 3050), "雙線帶：繞行長度必大於直線（未憑空造路）")
end

--------------------------------------------------------------------------------
-- 二十、折線繪製段級剔除（2026-08-20 拖動路線消失回歸）：舊點級哨兵把
-- 「前一節離屏、後一節穿窗」的線段誤砍。抽 drawRoutePolyline 原始碼＋stub
-- （正交恆等投影：世界＝UI 座標），斷言穿窗長段必畫
--------------------------------------------------------------------------------
do
    local drawBody = source:match("(local projX, projY = {}, {}.-\nend)\n\nlocal function drawApproach")
    assert(drawBody, "找不到 drawRoutePolyline 區段（結構變了？同步更新錨點）")
    local lines = {}
    local prelude = [[
local sqrt = math.sqrt
local floor = math.floor
local function dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end
local ROUTE_UNDER = { w = 3, a = 0.5, r = 0, g = 0, b = 0 }
local ROUTE_OVER = { w = 1, a = 0.9, r = 0, g = 1, b = 1 }
local function logf() end
local Core = {
    visibleWorldAABB = function(inner) return 0, inner.width, 0, inner.height end,
    clipSegment = nil,
}
]]
    local chunk = assert((loadstring or load)(prelude .. drawBody ..
        "\nreturn drawRoutePolyline", "route-draw"))
    local drawRoutePolyline = chunk()
    local inner = {
        width = 100, height = 100,
        drawLine = function(self, _, x1, y1, x2, y2) lines[#lines + 1] = { x1, y1, x2, y2 } end,
    }
    local mapAPI = {
        worldToUIX = function(_, x, y) return x end,
        worldToUIY = function(_, x, y) return y end,
        uiToWorldX = function(_, x, y) return x end,
        uiToWorldY = function(_, x, y) return y end,
    }
    -- 縱線三頂點：起點與第二點都在窗外上方，第二→第三節縱貫視窗（0..100）
    local route = { pts = { 50, -1000, 50, -500, 50, 1500 } }
    drawRoutePolyline(inner, route, mapAPI, 1, 50, -1000)
    local crossing = false
    for i = 1, #lines do
        local l = lines[i]
        if l[1] == 50 and l[3] == 50 and math.min(l[2], l[4]) <= 0
            and math.max(l[2], l[4]) >= 100 then
            crossing = true
        end
    end
    assert(crossing, "段級剔除：前節離屏、後節穿窗的線段必畫（舊點級哨兵誤砍）")
    -- 全離屏路線：零繪製（剔除仍生效）
    lines = {}
    local route2 = { pts = { 500, 500, 500, 900, 500, 1500 } }
    drawRoutePolyline(inner, route2, mapAPI, 1, 500, 500)
    assert(#lines == 0, "段級剔除：全離屏路線零繪製（實得 " .. #lines .. " 條）")
end

--------------------------------------------------------------------------------
-- 十四、避讓圈 detour（nav API v3：blocked 改道）——回字形雙路：直路 vs 繞路，
-- 堵點蓋直路中段 → 繞路勝出；無堵點 → 直路。目標貼堵點（軟封鎖仍可達）。
--------------------------------------------------------------------------------
do
    local g = buildAll({
        { name = "Straight", src = "M", pts = { 0, 0, 200, 0 } },
        { name = "DetourW", src = "M", pts = { 0, 0, 0, 60 } },
        { name = "DetourN", src = "M", pts = { 0, 60, 200, 60 } },
        { name = "DetourE", src = "M", pts = { 200, 60, 200, 0 } },
    }, nil)
    -- 無避讓：直路 ≈190
    local r0 = mod.findRoute(g, 5, 0, 195, 0)
    assert(r0, "避讓：基準路線存在")
    assert(r0.len < 250, "避讓：無堵點走直路（len ≈190，實得 " .. tostring(r0.len) .. "）")
    -- 堵點在直路中段 (100,0) r=12：繞北環 ≈310（190+120），必須勝過吃罰的直路
    local r1 = mod.findRoute(g, 5, 0, 195, 0, 100, 0, 12)
    assert(r1, "避讓：detour 路線存在")
    assert(r1.len > 250 and r1.len < 400,
        "避讓：堵點蓋直路 → 繞北環（len ≈310，實得 " .. tostring(r1.len) .. "）")
    -- 目標貼堵點：軟封鎖不是硬移除，仍要給路（吃罰照走）
    local r2 = mod.findRoute(g, 5, 0, 102, 0, 100, 0, 12)
    assert(r2, "避讓：目標在堵點圈內仍可達（軟封鎖）")
end

print("test_nav_route: 全數通過")
